//! Streaming XMLTV parser. Provider guides run to hundreds of MB (one real
//! provider: 195 MB, ~60 s to download), so the guide is parsed while it
//! downloads and only the channels and time window the app shows are kept.
//! Memory stays proportional to what is kept, not to the download.

use std::borrow::Cow;
use std::collections::HashMap;

use quick_xml::events::{BytesStart, Event};
use quick_xml::reader::Reader;
use url::Url;

use crate::epg::{self, Programme};
use crate::time::{self, Timestamp};

#[derive(Debug, Default)]
pub struct Guide {
    /// XMLTV channel id → first display name.
    pub channel_names: HashMap<String, String>,
    /// XMLTV channel id → programmes sorted by start.
    pub programmes: HashMap<String, Vec<Programme>>,
}

impl Guide {
    pub fn now_next(&self, channel_id: &str, at: Timestamp) -> epg::NowNext {
        self.programmes
            .get(channel_id)
            .map(|list| epg::now_next_sorted(list, at))
            .unwrap_or_default()
    }

    pub fn programme_count(&self) -> usize {
        self.programmes.values().map(Vec::len).sum()
    }
}

/// What to keep while parsing. The default keeps everything.
pub struct Filter {
    keep_channel: Box<dyn Fn(&str) -> bool + Send + Sync>,
    window: Option<(Timestamp, Timestamp)>,
    descriptions: bool,
}

impl Default for Filter {
    fn default() -> Self {
        Filter {
            keep_channel: Box::new(|_| true),
            window: None,
            descriptions: true,
        }
    }
}

impl Filter {
    /// Only these XMLTV channel ids. Checked before any text is allocated.
    pub fn channels(mut self, keep: impl Fn(&str) -> bool + Send + Sync + 'static) -> Self {
        self.keep_channel = Box::new(keep);
        self
    }

    /// Only programmes overlapping `[from, to)`.
    pub fn window(mut self, from: Timestamp, to: Timestamp) -> Self {
        self.window = Some((from, to));
        self
    }

    /// Drop descriptions; they are most of a guide's memory.
    pub fn without_descriptions(mut self) -> Self {
        self.descriptions = false;
        self
    }
}

/// Parse a complete document already in memory.
pub fn parse(xml: &[u8], filter: Filter) -> crate::Result<Guide> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(true);
    let mut builder = Builder::new(filter);
    let mut buf = Vec::with_capacity(1024);
    loop {
        let event = reader.read_event_into(&mut buf).map_err(|e| {
            crate::Error::Xmltv(format!("at byte {}: {e}", reader.buffer_position()))
        })?;
        if builder.handle(event) {
            break;
        }
        buf.clear();
    }
    Ok(builder.finish())
}

/// Download and parse in one pass; the document is never held in memory.
/// Returns the guide and the number of bytes downloaded.
pub async fn fetch(
    http: &reqwest::Client,
    url: Url,
    filter: Filter,
) -> crate::Result<(Guide, u64)> {
    use futures_util::TryStreamExt;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};

    let res = http.get(url).send().await?;
    if !res.status().is_success() {
        return Err(crate::Error::Status {
            what: "XMLTV guide",
            status: res.status().as_u16(),
        });
    }
    let bytes = Arc::new(AtomicU64::new(0));
    let counter = bytes.clone();
    let stream = res
        .bytes_stream()
        .inspect_ok(move |chunk| {
            counter.fetch_add(chunk.len() as u64, Ordering::Relaxed);
        })
        .map_err(|e| std::io::Error::other(e.without_url()));
    let body = tokio_util::io::StreamReader::new(stream);
    let mut reader = Reader::from_reader(tokio::io::BufReader::with_capacity(256 * 1024, body));
    reader.config_mut().trim_text(true);
    let mut builder = Builder::new(filter);
    let mut buf = Vec::with_capacity(1024);
    loop {
        let event = reader.read_event_into_async(&mut buf).await.map_err(|e| {
            crate::Error::Xmltv(format!("at byte {}: {e}", reader.buffer_position()))
        })?;
        if builder.handle(event) {
            break;
        }
        buf.clear();
    }
    Ok((builder.finish(), bytes.load(Ordering::Relaxed)))
}

#[derive(Clone, Copy, PartialEq)]
enum Field {
    None,
    ChannelName,
    Title,
    Desc,
}

#[derive(Default)]
struct Pending {
    channel: String,
    start: Option<i64>,
    stop: Option<i64>,
    title: Option<String>,
    desc: Option<String>,
}

/// The parsing state machine, shared by the in-memory and streaming drivers.
struct Builder {
    filter: Filter,
    guide: Guide,
    field: Field,
    channel_id: Option<String>,
    programme: Option<Pending>,
}

impl Builder {
    fn new(filter: Filter) -> Self {
        Builder {
            filter,
            guide: Guide::default(),
            field: Field::None,
            channel_id: None,
            programme: None,
        }
    }

    /// Returns true at end of document.
    fn handle(&mut self, event: Event<'_>) -> bool {
        match event {
            Event::Start(e) => match e.local_name().as_ref() {
                b"channel" => self.channel_id = attr(&e, b"id"),
                b"display-name" if self.channel_id.is_some() => self.field = Field::ChannelName,
                b"programme" => self.programme = self.start_programme(&e),
                b"title" if self.programme.is_some() => self.field = Field::Title,
                b"desc" if self.programme.is_some() && self.filter.descriptions => {
                    self.field = Field::Desc
                }
                _ => {}
            },
            Event::Text(t) => {
                if self.field != Field::None {
                    let text = t
                        .unescape()
                        .unwrap_or_else(|_| String::from_utf8_lossy(&t).into_owned().into());
                    self.store_text(text);
                }
            }
            Event::CData(c) => {
                if self.field != Field::None {
                    self.store_text(String::from_utf8_lossy(&c).into_owned().into());
                }
            }
            Event::End(e) => match e.local_name().as_ref() {
                b"display-name" | b"title" | b"desc" => self.field = Field::None,
                b"channel" => self.channel_id = None,
                b"programme" => {
                    if let Some(p) = self.programme.take() {
                        self.finish_programme(p);
                    }
                }
                _ => {}
            },
            Event::Empty(e) if e.local_name().as_ref() == b"programme" => {
                if let Some(p) = self.start_programme(&e) {
                    self.finish_programme(p);
                }
            }
            Event::Eof => return true,
            _ => {}
        }
        false
    }

    fn start_programme(&self, e: &BytesStart<'_>) -> Option<Pending> {
        let mut p = Pending::default();
        for a in e.attributes().with_checks(false).flatten() {
            match a.key.as_ref() {
                b"channel" => p.channel = String::from_utf8_lossy(&a.value).into_owned(),
                b"start" => p.start = time::parse_xmltv(&a.value),
                b"stop" => p.stop = time::parse_xmltv(&a.value),
                _ => {}
            }
        }
        if p.channel.is_empty() || !(self.filter.keep_channel)(&p.channel) {
            return None;
        }
        if let (Some((from, to)), Some(start), Some(stop)) = (self.filter.window, p.start, p.stop)
            && (stop <= from || start >= to)
        {
            return None;
        }
        Some(p)
    }

    fn store_text(&mut self, text: Cow<'_, str>) {
        match self.field {
            Field::ChannelName => {
                if let Some(id) = &self.channel_id {
                    self.guide
                        .channel_names
                        .entry(id.clone())
                        .or_insert_with(|| text.into_owned());
                }
            }
            // XMLTV allows one title/desc per language; the first one wins.
            Field::Title => {
                if let Some(p) = self.programme.as_mut().filter(|p| p.title.is_none()) {
                    p.title = Some(text.into_owned());
                }
            }
            Field::Desc => {
                if let Some(p) = self.programme.as_mut().filter(|p| p.desc.is_none()) {
                    p.desc = Some(text.into_owned());
                }
            }
            Field::None => {}
        }
    }

    fn finish_programme(&mut self, p: Pending) {
        // Without a stop time the end is unknown; providers that omit stop
        // also misorder, so skip rather than guess.
        let (Some(start), Some(stop)) = (p.start, p.stop) else {
            return;
        };
        self.guide
            .programmes
            .entry(p.channel)
            .or_default()
            .push(Programme {
                start,
                stop,
                title: p.title.unwrap_or_default(),
                description: p.desc,
            });
    }

    fn finish(mut self) -> Guide {
        for list in self.guide.programmes.values_mut() {
            epg::sort_and_dedupe(list);
            list.shrink_to_fit();
        }
        self.guide
    }
}

fn attr(e: &BytesStart<'_>, name: &[u8]) -> Option<String> {
    e.attributes()
        .with_checks(false)
        .flatten()
        .find(|a| a.key.as_ref() == name)
        .map(|a| match a.unescape_value() {
            Ok(v) => v.into_owned(),
            Err(_) => String::from_utf8_lossy(&a.value).into_owned(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOC: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="test">
  <channel id="bbc1.uk"><display-name>BBC One</display-name><display-name>BBC1</display-name></channel>
  <programme start="20261010110000 +0000" stop="20261010120000 +0000" channel="bbc1.uk">
    <title lang="en">News &amp; Weather</title><title lang="cy">Newyddion</title>
    <desc>Headlines.</desc>
  </programme>
  <programme start="20261010130000 +0100" stop="20261010130000 +0000" channel="bbc1.uk">
    <title><![CDATA[Bargain Hunt]]></title>
  </programme>
  <programme start="20261010110000 +0000" stop="20261010120000 +0000" channel="bbc1.uk">
    <title lang="en">News &amp; Weather</title>
  </programme>
  <programme start="20261010110000 +0000" stop="20261010120000 +0000" channel="skip.me"><title>x</title></programme>
  <programme start="20261010110000 +0000" stop="20261010120000 +0000" channel="bad.entity"><title>Caf&eacute;</title></programme>
</tv>"#;

    #[test]
    fn parses_names_titles_offsets_and_filters() {
        let g = parse(
            DOC.as_bytes(),
            Filter::default().channels(|id| id != "skip.me"),
        )
        .unwrap();
        assert_eq!(g.channel_names["bbc1.uk"], "BBC One");
        let list = &g.programmes["bbc1.uk"];
        assert_eq!(list.len(), 2, "duplicate removed");
        assert_eq!(list[0].title, "News & Weather");
        assert_eq!(list[0].description.as_deref(), Some("Headlines."));
        assert_eq!(list[1].title, "Bargain Hunt");
        assert_eq!(list[1].start, list[0].stop, "+0100 normalised to UTC");
        assert!(!g.programmes.contains_key("skip.me"));
        assert_eq!(g.programmes["bad.entity"][0].title, "Caf&eacute;");

        let nn = g.now_next("bbc1.uk", list[0].start + 60);
        assert_eq!(nn.now.unwrap().title, "News & Weather");
        assert_eq!(nn.next.unwrap().title, "Bargain Hunt");
    }

    #[test]
    fn window_and_description_filters() {
        let eleven = 1_791_630_000; // 2026-10-10 11:00 UTC
        let g = parse(
            DOC.as_bytes(),
            Filter::default()
                .window(eleven + 3600, eleven + 7200)
                .without_descriptions(),
        )
        .unwrap();
        let list = &g.programmes["bbc1.uk"];
        assert_eq!(list.len(), 1, "11:00-12:00 is outside the window");
        assert_eq!(list[0].title, "Bargain Hunt");

        let g = parse(DOC.as_bytes(), Filter::default().without_descriptions()).unwrap();
        assert!(
            g.programmes["bbc1.uk"]
                .iter()
                .all(|p| p.description.is_none())
        );
    }
}

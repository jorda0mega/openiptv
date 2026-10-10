//! Streaming XMLTV parser. Provider guides are often 50–300 MB, so this reads
//! events without building a DOM and keeps only what the UI shows.

use std::borrow::Cow;
use std::collections::HashMap;

use quick_xml::events::{BytesStart, Event};
use quick_xml::reader::Reader;

use crate::epg::{self, Programme};
use crate::time;

#[derive(Debug, Default)]
pub struct Guide {
    /// XMLTV channel id → first display name.
    pub channel_names: HashMap<String, String>,
    /// XMLTV channel id → programmes sorted by start.
    pub programmes: HashMap<String, Vec<Programme>>,
}

impl Guide {
    pub fn now_next(&self, channel_id: &str, at: time::Timestamp) -> epg::NowNext {
        self.programmes
            .get(channel_id)
            .map(|list| epg::now_next_sorted(list, at))
            .unwrap_or_default()
    }

    pub fn programme_count(&self) -> usize {
        self.programmes.values().map(Vec::len).sum()
    }
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

/// Parse a full XMLTV document. `keep` filters channel ids before any
/// programme text is allocated, so callers can restrict to channels they show.
pub fn parse(xml: &[u8], keep: impl Fn(&str) -> bool) -> crate::Result<Guide> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(true);

    let mut guide = Guide::default();
    let mut buf = Vec::with_capacity(1024);
    let mut field = Field::None;
    let mut channel_id: Option<String> = None;
    let mut programme: Option<Pending> = None;

    loop {
        let event = reader.read_event_into(&mut buf).map_err(|e| {
            crate::Error::Xmltv(format!("at byte {}: {e}", reader.buffer_position()))
        })?;
        match event {
            Event::Start(e) => match e.local_name().as_ref() {
                b"channel" => channel_id = attr(&e, b"id"),
                b"display-name" if channel_id.is_some() => field = Field::ChannelName,
                b"programme" => programme = start_programme(&e, &keep),
                b"title" if programme.is_some() => field = Field::Title,
                b"desc" if programme.is_some() => field = Field::Desc,
                _ => {}
            },
            Event::Text(t) => {
                if field != Field::None {
                    let text = t
                        .unescape()
                        .unwrap_or_else(|_| String::from_utf8_lossy(&t).into_owned().into());
                    store_text(field, text, &channel_id, &mut programme, &mut guide);
                }
            }
            Event::CData(c) => {
                if field != Field::None {
                    let text = String::from_utf8_lossy(&c).into_owned().into();
                    store_text(field, text, &channel_id, &mut programme, &mut guide);
                }
            }
            Event::End(e) => match e.local_name().as_ref() {
                b"display-name" | b"title" | b"desc" => field = Field::None,
                b"channel" => channel_id = None,
                b"programme" => {
                    if let Some(p) = programme.take() {
                        finish_programme(p, &mut guide);
                    }
                }
                _ => {}
            },
            Event::Empty(e) if e.local_name().as_ref() == b"programme" => {
                if let Some(p) = start_programme(&e, &keep) {
                    finish_programme(p, &mut guide);
                }
            }
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }

    for list in guide.programmes.values_mut() {
        epg::sort_and_dedupe(list);
    }
    Ok(guide)
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

fn start_programme(e: &BytesStart<'_>, keep: &impl Fn(&str) -> bool) -> Option<Pending> {
    let mut p = Pending::default();
    for a in e.attributes().with_checks(false).flatten() {
        match a.key.as_ref() {
            b"channel" => p.channel = String::from_utf8_lossy(&a.value).into_owned(),
            b"start" => p.start = time::parse_xmltv(&a.value),
            b"stop" => p.stop = time::parse_xmltv(&a.value),
            _ => {}
        }
    }
    (!p.channel.is_empty() && keep(&p.channel)).then_some(p)
}

fn store_text(
    field: Field,
    text: Cow<'_, str>,
    channel_id: &Option<String>,
    programme: &mut Option<Pending>,
    guide: &mut Guide,
) {
    match field {
        Field::ChannelName => {
            if let Some(id) = channel_id {
                guide
                    .channel_names
                    .entry(id.clone())
                    .or_insert_with(|| text.into_owned());
            }
        }
        // XMLTV allows one title/desc per language; the first one wins.
        Field::Title => {
            if let Some(p) = programme.as_mut().filter(|p| p.title.is_none()) {
                p.title = Some(text.into_owned());
            }
        }
        Field::Desc => {
            if let Some(p) = programme.as_mut().filter(|p| p.desc.is_none()) {
                p.desc = Some(text.into_owned());
            }
        }
        Field::None => {}
    }
}

fn finish_programme(p: Pending, guide: &mut Guide) {
    // Without a stop time the programme's end is unknown; the next programme's
    // start would fix it, but providers that omit stop also misorder, so skip.
    let (Some(start), Some(stop)) = (p.start, p.stop) else {
        return;
    };
    guide
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
        let g = parse(DOC.as_bytes(), |id| id != "skip.me").unwrap();
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
}

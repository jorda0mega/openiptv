//! App-level operations shared by every client (web relay, iOS, tvOS,
//! Fire TV): sign-in, home rows, live channels with now/next, stream URLs.
//! Screens should render from what these return immediately and refresh in
//! the background; nothing here blocks on the full TV guide.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};

use serde::Serialize;
use url::Url;

use crate::artwork::{self, Context, Shape};
use crate::emby::{Device, EmbyClient, Item, PlaybackEvent};
use crate::emby_connect::ConnectClient;
use crate::epg::{self, NowNext, Programme};
use crate::time::{self, Timestamp};
use crate::xmltv::{self, Guide};
use crate::xtream::{self, Account, Category, Channel, Credentials, StreamFormat, XtreamClient};
use crate::{Error, Result};

// ------------------------------------------------------------------ Emby ---

pub enum EmbyLogin {
    /// An emby.media account; the first linked server (or the named one) is used.
    Connect {
        user: String,
        password: String,
        server: Option<String>,
    },
    Direct {
        url: String,
        user: String,
        password: String,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct Row {
    pub title: String,
    pub shape: &'static str,
    pub aspect: f64,
    pub cards: Vec<Card>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Card {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub subtitle: Option<String>,
    /// Try in order; move to the next on load error.
    pub images: Vec<CardImage>,
    /// 0–100 for partly watched items.
    pub progress: Option<f64>,
    /// Movies, episodes, series and seasons can be played (series and
    /// seasons start the next unwatched episode).
    pub playable: bool,
}

/// What a client needs to play one Emby item.
#[derive(Debug, Clone, Serialize)]
pub struct Playback {
    pub item_id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub url: String,
    /// Resume point, if partly watched.
    pub start_seconds: Option<f64>,
    pub duration_seconds: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CardImage {
    pub url: String,
    /// Letterbox instead of crop (logos, mismatched shapes).
    pub contain: bool,
}

pub struct EmbyAccount {
    client: EmbyClient,
    pub server_name: String,
}

const LATEST_LIBRARIES: usize = 8;

impl EmbyAccount {
    pub async fn sign_in(http: &reqwest::Client, device: Device, login: EmbyLogin) -> Result<Self> {
        match login {
            EmbyLogin::Direct {
                url,
                user,
                password,
            } => {
                let mut client =
                    EmbyClient::new(http.clone(), &url, device).map_err(|_| Error::Auth)?;
                let info = client.public_info().await?;
                client.login(&user, &password).await?;
                Ok(EmbyAccount {
                    client,
                    server_name: info.server_name.unwrap_or_default(),
                })
            }
            EmbyLogin::Connect {
                user,
                password,
                server,
            } => {
                let connect = ConnectClient::new(http.clone(), &device.client, &device.version);
                let session = connect.login(&user, &password).await?;
                let servers = connect.servers(&session).await?;
                let chosen = match &server {
                    Some(name) => servers.iter().find(|s| s.name.eq_ignore_ascii_case(name)),
                    None => servers.first(),
                }
                .ok_or(Error::NoSession)?;
                let mut last = Error::NoSession;
                for address in chosen.addresses() {
                    let Ok(mut client) = EmbyClient::new(http.clone(), address, device.clone())
                    else {
                        continue;
                    };
                    match client.public_info().await {
                        Ok(_) => {
                            client
                                .exchange(&session.user_id, &chosen.access_key)
                                .await?;
                            return Ok(EmbyAccount {
                                client,
                                server_name: chosen.name.clone(),
                            });
                        }
                        Err(e) => last = e,
                    }
                }
                Err(last)
            }
        }
    }

    pub fn client(&self) -> &EmbyClient {
        &self.client
    }

    /// Continue Watching, Next Up and Latest per movie/TV library, fetched
    /// in parallel. Empty rows are dropped.
    pub async fn home(&self, card_width_px: u32) -> Result<Vec<Row>> {
        let c = &self.client;
        let views = c.views().await?;
        let libraries: Vec<&Item> = views
            .iter()
            .filter(|v| matches!(v.collection_type.as_deref(), Some("movies" | "tvshows")))
            .take(LATEST_LIBRARIES)
            .collect();

        let latest =
            futures_util::future::join_all(libraries.iter().map(|lib| c.latest(Some(&lib.id), 16)));
        let (resume, next_up, latest) = tokio::join!(c.resume(12), c.next_up(12), latest);

        let mut rows = Vec::new();
        self.push_row(
            &mut rows,
            "Continue Watching",
            resume?,
            Context::Landscape,
            card_width_px,
        );
        self.push_row(
            &mut rows,
            "Next Up",
            next_up?,
            Context::Landscape,
            card_width_px,
        );
        for (lib, items) in libraries.iter().zip(latest) {
            // One slow or broken library shouldn't blank the home screen.
            if let Ok(items) = items {
                let title = format!("Latest in {}", lib.name);
                self.push_row(&mut rows, &title, items, Context::Poster, card_width_px);
            }
        }
        Ok(rows)
    }

    fn push_row(
        &self,
        rows: &mut Vec<Row>,
        title: &str,
        items: Vec<Item>,
        context: Context,
        width: u32,
    ) {
        if items.is_empty() {
            return;
        }
        let shape = artwork::list_shape(&items, context);
        let cards = items
            .iter()
            .map(|i| self.card(i, context, shape, width))
            .collect();
        rows.push(Row {
            title: title.to_owned(),
            shape: shape_name(shape),
            aspect: shape.aspect(),
            cards,
        });
    }

    fn card(&self, item: &Item, context: Context, shape: Shape, width: u32) -> Card {
        let width = if shape == Shape::Landscape {
            width * 16 / 10
        } else {
            width
        };
        let images = artwork::candidates(item, context)
            .iter()
            .map(|c| CardImage {
                url: self.client.image_url(&c.image, width, Some(shape)).into(),
                contain: c.fit(shape) == artwork::Fit::Contain,
            })
            .collect();
        let (title, subtitle) = match item.kind.as_str() {
            "Episode" => {
                let code = match (item.parent_index_number, item.index_number) {
                    (Some(s), Some(e)) => format!("S{s}:E{e} · "),
                    _ => String::new(),
                };
                (
                    item.series_name
                        .clone()
                        .unwrap_or_else(|| item.name.clone()),
                    Some(format!("{code}{}", item.name)),
                )
            }
            _ => (
                item.name.clone(),
                item.production_year.map(|y| y.to_string()),
            ),
        };
        Card {
            id: item.id.clone(),
            kind: item.kind.clone(),
            title,
            subtitle,
            images,
            progress: item
                .user_data
                .as_ref()
                .and_then(|u| u.played_percentage)
                .filter(|p| *p > 0.0 && *p < 100.0),
            playable: matches!(
                item.kind.as_str(),
                "Movie" | "Episode" | "Video" | "MusicVideo" | "Series" | "Season"
            ),
        }
    }

    /// Resolve an item to something playable: series and seasons become the
    /// next episode to watch; partly watched items resume.
    pub async fn playback(&self, id: &str) -> Result<Playback> {
        let c = &self.client;
        let mut item = c.item(id).await?;
        match item.kind.as_str() {
            "Series" => {
                item = c
                    .episode_to_play(&item.id, None)
                    .await?
                    .ok_or(Error::NoSession)?;
            }
            "Season" => {
                let series = item.series_id.clone().unwrap_or_default();
                item = c
                    .episode_to_play(&series, Some(&item.id))
                    .await?
                    .ok_or(Error::NoSession)?;
            }
            _ => {}
        }
        let url = c.stream_url(&item.id).ok_or(Error::NoSession)?;
        let resume = item
            .user_data
            .as_ref()
            .filter(|u| !u.played)
            .and_then(|u| u.playback_position_ticks)
            .filter(|t| *t > 0)
            .map(|t| t as f64 / 1e7);
        let (title, subtitle) = match item.kind.as_str() {
            "Episode" => {
                let code = match (item.parent_index_number, item.index_number) {
                    (Some(s), Some(e)) => format!("S{s}:E{e} · "),
                    _ => String::new(),
                };
                (
                    item.series_name
                        .clone()
                        .unwrap_or_else(|| item.name.clone()),
                    Some(format!("{code}{}", item.name)),
                )
            }
            _ => (
                item.name.clone(),
                item.production_year.map(|y| y.to_string()),
            ),
        };
        Ok(Playback {
            item_id: item.id.clone(),
            title,
            subtitle,
            url: url.into(),
            start_seconds: resume,
            duration_seconds: item.run_time_ticks.map(|t| t as f64 / 1e7),
        })
    }

    pub async fn report(
        &self,
        event: PlaybackEvent,
        item_id: &str,
        position_seconds: f64,
    ) -> Result<()> {
        let ticks = (position_seconds.max(0.0) * 1e7) as i64;
        self.client.report_playback(event, item_id, ticks).await
    }
}

fn shape_name(shape: Shape) -> &'static str {
    match shape {
        Shape::Portrait => "portrait",
        Shape::Square => "square",
        Shape::FourThree => "fourThree",
        Shape::Landscape => "landscape",
    }
}

// --------------------------------------------------------------- Live TV ---

#[derive(Debug, Clone, Serialize)]
pub struct CategoryInfo {
    pub id: String,
    pub name: String,
    pub channels: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChannelInfo {
    pub id: i64,
    pub number: Option<i64>,
    pub name: String,
    pub logo: Option<String>,
    pub category: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ShowInfo {
    pub title: String,
    pub start: Timestamp,
    pub stop: Timestamp,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct NowNextInfo {
    pub now: Option<ShowInfo>,
    pub next: Option<ShowInfo>,
    /// Unix seconds when this stops being correct.
    pub refresh_at: Option<Timestamp>,
    /// "guide" (XMLTV), "panel" (short EPG) or "none".
    pub source: &'static str,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct GuideStatus {
    pub state: &'static str,
    pub channels: usize,
    pub programmes: usize,
    pub bytes: u64,
    pub seconds: f64,
    pub error: Option<String>,
}

pub struct LiveTv {
    client: XtreamClient,
    pub account: Account,
    categories: Vec<Category>,
    channels: Vec<Channel>,
    by_id: HashMap<i64, usize>,
    guide: RwLock<Option<Arc<Guide>>>,
    guide_status: Mutex<GuideStatus>,
    /// Short-EPG answers, kept until they stop being true.
    panel_cache: Mutex<HashMap<i64, (Timestamp, Vec<Programme>)>>,
}

impl LiveTv {
    pub async fn sign_in(http: &reqwest::Client, creds: Credentials) -> Result<Self> {
        let client = XtreamClient::new(http.clone(), creds);
        let (account, categories, channels) = tokio::join!(
            client.account(),
            client.live_categories(),
            client.live_channels(None)
        );
        let (account, categories, mut channels) = (account?, categories?, channels?);
        // Drop "Account Info"-style categories and any channel that spells
        // out the login; they can leak credentials and aren't watchable.
        let hidden: std::collections::HashSet<&str> = categories
            .iter()
            .filter(|c| looks_like_account_info(&c.category_name))
            .map(|c| c.category_id.as_str())
            .collect();
        channels.retain(|c| {
            !client.mentions_credentials(&c.name)
                && !looks_like_account_info(&c.name)
                && c.category_id
                    .as_deref()
                    .is_none_or(|id| !hidden.contains(id))
        });
        let by_id = channels
            .iter()
            .enumerate()
            .map(|(i, c)| (c.stream_id, i))
            .collect();
        Ok(LiveTv {
            client,
            account,
            categories,
            channels,
            by_id,
            guide: RwLock::new(None),
            guide_status: Mutex::new(GuideStatus {
                state: "not loaded",
                ..GuideStatus::default()
            }),
            panel_cache: Mutex::new(HashMap::new()),
        })
    }

    pub fn categories(&self) -> Vec<CategoryInfo> {
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for c in &self.channels {
            if let Some(cat) = &c.category_id {
                *counts.entry(cat.as_str()).or_default() += 1;
            }
        }
        self.categories
            .iter()
            .map(|c| CategoryInfo {
                id: c.category_id.clone(),
                name: c.category_name.clone(),
                channels: counts.get(c.category_id.as_str()).copied().unwrap_or(0),
            })
            .filter(|c| c.channels > 0)
            .collect()
    }

    /// Channels in provider order, optionally one category and/or matching a
    /// case-insensitive search.
    pub fn channels(&self, category: Option<&str>, query: Option<&str>) -> Vec<ChannelInfo> {
        let query = query.map(str::to_lowercase).filter(|q| !q.is_empty());
        self.channels
            .iter()
            .filter(|c| category.is_none_or(|cat| c.category_id.as_deref() == Some(cat)))
            .filter(|c| {
                query
                    .as_ref()
                    .is_none_or(|q| c.name.to_lowercase().contains(q.as_str()))
            })
            .map(|c| ChannelInfo {
                id: c.stream_id,
                number: c.number,
                name: c.name.clone(),
                logo: c.logo.clone(),
                category: c.category_id.clone(),
            })
            .collect()
    }

    pub fn channel(&self, id: i64) -> Option<&Channel> {
        self.by_id.get(&id).map(|&i| &self.channels[i])
    }

    pub fn stream_url(&self, id: i64) -> Url {
        let format = if self.account.supports(StreamFormat::Hls)
            && !self.account.supports(StreamFormat::Ts)
        {
            StreamFormat::Hls
        } else {
            StreamFormat::Ts
        };
        self.client.live_url(id, format)
    }

    pub fn guide_status(&self) -> GuideStatus {
        self.guide_status.lock().expect("poisoned").clone()
    }

    /// Download and parse the full guide in the background-friendly
    /// streaming way, keeping `[now - 3h, now + hours_ahead)` for channels
    /// this account can watch.
    pub async fn refresh_guide(
        &self,
        http: &reqwest::Client,
        hours_ahead: i64,
        descriptions: bool,
    ) -> Result<()> {
        let started = std::time::Instant::now();
        self.guide_status.lock().expect("poisoned").state = "loading";
        let ids: std::collections::HashSet<String> = self
            .channels
            .iter()
            .filter_map(|c| c.epg_id.clone())
            .collect();
        let now = time::now();
        let mut filter = xmltv::Filter::default()
            .channels(move |id| ids.contains(id))
            .window(now - 3 * 3600, now + hours_ahead * 3600);
        if !descriptions {
            filter = filter.without_descriptions();
        }
        let result = xmltv::fetch(http, self.client.xmltv_url(), filter).await;
        let mut status = self.guide_status.lock().expect("poisoned");
        status.seconds = started.elapsed().as_secs_f64();
        match result {
            Ok((guide, bytes)) => {
                *status = GuideStatus {
                    state: "ready",
                    channels: guide.programmes.len(),
                    programmes: guide.programme_count(),
                    bytes,
                    seconds: status.seconds,
                    error: None,
                };
                *self.guide.write().expect("poisoned") = Some(Arc::new(guide));
                Ok(())
            }
            Err(e) => {
                status.state = "failed";
                status.error = Some(e.to_string());
                Err(e)
            }
        }
    }

    /// Now/next for each channel: the full guide when it knows, otherwise the
    /// panel's short EPG (fetched concurrently and cached until it expires).
    pub async fn now_next(&self, ids: &[i64]) -> HashMap<i64, NowNextInfo> {
        let now = time::now();
        let guide = self.guide.read().expect("poisoned").clone();
        let mut out = HashMap::new();
        let mut missing = Vec::new();
        for &id in ids {
            let from_guide = guide.as_ref().and_then(|g| {
                let epg_id = self.channel(id)?.epg_id.as_deref()?;
                let nn = g.now_next(epg_id, now);
                nn.now
                    .as_ref()
                    .is_some_and(|p| !is_placeholder(&p.title))
                    .then_some(nn)
            });
            match from_guide {
                Some(nn) => {
                    out.insert(id, info(nn, "guide"));
                }
                None => missing.push(id),
            }
        }

        let offset = self.account.panel_utc_offset();
        let fetches = missing.iter().map(|&id| async move {
            if let Some((until, list)) = self.panel_cache.lock().expect("poisoned").get(&id)
                && now < *until
            {
                return (id, list.clone());
            }
            let list: Vec<Programme> = self
                .client
                .short_epg(id, 4, offset)
                .await
                .map(|l| l.into_iter().map(|l| l.programme).collect())
                .unwrap_or_default();
            // Cache empties briefly so a channel without data isn't re-asked
            // on every scroll, but is re-checked soon.
            let until = epg::now_next(&list, now).refresh_at.unwrap_or(now + 300);
            self.panel_cache
                .lock()
                .expect("poisoned")
                .insert(id, (until, list.clone()));
            (id, list)
        });
        for (id, list) in futures_util::future::join_all(fetches).await {
            let nn = epg::now_next(&list, now);
            let source = if nn.now.is_some() || nn.next.is_some() {
                "panel"
            } else {
                "none"
            };
            out.insert(id, info(nn, source));
        }
        out
    }
}

/// Guide filler that says nothing about what's on; treat as missing data.
fn is_placeholder(title: &str) -> bool {
    let t = title.trim().to_lowercase();
    // Short markers must be the whole title; phrases may appear anywhere.
    t.is_empty()
        || ["tba", "tbd", "n/a", "no info", "to be announced"].contains(&t.as_str())
        || [
            "no information",
            "information available",
            "no programme",
            "no program",
            "not available",
        ]
        .iter()
        .any(|p| t.contains(p))
}

/// Panels often list account details (login, expiry, connections) as fake
/// channels; they are useless to watch and can leak the login.
fn looks_like_account_info(name: &str) -> bool {
    let name = name.to_lowercase();
    [
        "username",
        "user name",
        "user:",
        "password",
        "pass:",
        "expire",
        "expiry",
        "max conn",
        "active conn",
        "account info",
    ]
    .iter()
    .any(|marker| name.contains(marker))
}

fn info(nn: NowNext, source: &'static str) -> NowNextInfo {
    let show = |p: Programme| ShowInfo {
        title: p.title,
        start: p.start,
        stop: p.stop,
    };
    NowNextInfo {
        now: nn.now.map(show),
        next: nn.next.map(show),
        refresh_at: nn.refresh_at,
        source,
    }
}

/// Convenience for clients that read the same environment as the probe.
pub fn xtream_credentials(url: &str, user: &str, password: &str) -> Result<Credentials> {
    xtream::Credentials::new(url, user, password).map_err(|_| Error::Auth)
}

#[cfg(test)]
mod tests {
    use super::{is_placeholder, looks_like_account_info};

    #[test]
    fn spots_placeholder_titles() {
        for t in [
            "No Information Available",
            "TBA",
            "To Be Announced",
            "",
            "No information available for this channel",
        ] {
            assert!(is_placeholder(t), "{t:?}");
        }
        for t in ["BBC News", "Taboo", "Tbaar's Kitchen", "Information Age"] {
            assert!(!is_placeholder(t), "{t:?}");
        }
    }

    #[test]
    fn hides_account_info_channels() {
        for name in [
            "Username: abc",
            "PASSWORD - x",
            "Expire Date: 2027-01-01",
            "Max Connections: 1",
            "Account Info",
        ] {
            assert!(looks_like_account_info(name), "{name}");
        }
        for name in ["BBC One HD", "The Expanse 24/7", "USA Network", "Info Wars"] {
            assert!(!looks_like_account_info(name), "{name}");
        }
    }
}

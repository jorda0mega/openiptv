//! Xtream Codes `player_api.php` client.
//!
//! The API is undocumented and panels differ, so every response goes through
//! the lenient decoders and URLs are always built from the login host rather
//! than the `server_info.url` the panel advertises (often wrong behind CDNs).

use base64::Engine;
use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use serde::Deserialize;
use url::Url;

use crate::epg::Programme;
use crate::{Error, Result, http, lenient, time};

#[derive(Clone)]
pub struct Credentials {
    pub server: Url,
    pub username: String,
    pub password: String,
}

impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credentials")
            .field("server", &self.server.as_str())
            .field("username", &self.username)
            .finish_non_exhaustive()
    }
}

impl Credentials {
    /// Accepts `http://host:port`, with or without a trailing slash or path.
    pub fn new(
        server: &str,
        username: &str,
        password: &str,
    ) -> std::result::Result<Self, url::ParseError> {
        let mut server = Url::parse(server.trim())?;
        if !server.path().ends_with('/') {
            let path = format!("{}/", server.path());
            server.set_path(&path);
        }
        server.set_query(None);
        Ok(Credentials {
            server,
            username: username.to_owned(),
            password: password.to_owned(),
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Account {
    #[serde(default)]
    pub user_info: UserInfo,
    #[serde(default)]
    pub server_info: ServerInfo,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct UserInfo {
    #[serde(default, deserialize_with = "lenient::flag")]
    pub auth: bool,
    #[serde(default, deserialize_with = "lenient::string")]
    pub status: String,
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    pub exp_date: Option<i64>,
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    pub max_connections: Option<i64>,
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    pub active_cons: Option<i64>,
    #[serde(default, deserialize_with = "lenient::string_list")]
    pub allowed_output_formats: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ServerInfo {
    #[serde(default, deserialize_with = "lenient::opt_string")]
    pub timezone: Option<String>,
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    pub timestamp_now: Option<i64>,
    #[serde(default, deserialize_with = "lenient::opt_string")]
    pub time_now: Option<String>,
}

impl Account {
    pub fn supports(&self, format: StreamFormat) -> bool {
        let allowed = &self.user_info.allowed_output_formats;
        // Panels that omit the list generally serve everything.
        allowed.is_empty()
            || allowed
                .iter()
                .any(|f| f.eq_ignore_ascii_case(format.extension()))
    }

    /// The panel's UTC offset in seconds, derived from its own clock
    /// (`time_now` wall clock vs `timestamp_now`), rounded to 15 minutes.
    pub fn panel_utc_offset(&self) -> Option<i64> {
        let wall = time::parse_wall_clock(self.server_info.time_now.as_deref()?)?;
        let raw = wall - self.server_info.timestamp_now?;
        Some((raw as f64 / 900.0).round() as i64 * 900)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamFormat {
    /// HLS: plays in AVPlayer with hardware decode, PiP and AirPlay.
    Hls,
    /// Raw MPEG-TS: lowest latency, needs an FFmpeg-based player on Apple.
    Ts,
}

impl StreamFormat {
    pub fn extension(self) -> &'static str {
        match self {
            StreamFormat::Hls => "m3u8",
            StreamFormat::Ts => "ts",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Category {
    #[serde(default, deserialize_with = "lenient::string")]
    pub category_id: String,
    #[serde(default, deserialize_with = "lenient::string")]
    pub category_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Channel {
    pub stream_id: i64,
    pub number: Option<i64>,
    pub name: String,
    pub logo: Option<String>,
    pub epg_id: Option<String>,
    pub category_id: Option<String>,
    /// Days of catch-up the provider keeps, if any.
    pub catchup_days: Option<i64>,
}

#[derive(Deserialize)]
struct RawChannel {
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    stream_id: Option<i64>,
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    num: Option<i64>,
    #[serde(default, deserialize_with = "lenient::string")]
    name: String,
    #[serde(default, deserialize_with = "lenient::opt_string")]
    stream_icon: Option<String>,
    #[serde(default, deserialize_with = "lenient::opt_string")]
    epg_channel_id: Option<String>,
    #[serde(default, deserialize_with = "lenient::opt_string")]
    category_id: Option<String>,
    #[serde(default, deserialize_with = "lenient::flag")]
    tv_archive: bool,
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    tv_archive_duration: Option<i64>,
}

impl RawChannel {
    fn into_channel(self) -> Option<Channel> {
        Some(Channel {
            stream_id: self.stream_id?,
            number: self.num,
            name: self.name.trim().to_owned(),
            logo: self.stream_icon.filter(|u| u.starts_with("http")),
            epg_id: self.epg_channel_id.map(|s| s.trim().to_owned()),
            category_id: self.category_id,
            catchup_days: self
                .tv_archive
                .then_some(self.tv_archive_duration)
                .flatten(),
        })
    }
}

#[derive(Deserialize)]
struct ShortEpg {
    #[serde(default, deserialize_with = "lenient::seq")]
    epg_listings: Vec<RawListing>,
}

#[derive(Deserialize)]
pub(crate) struct RawListing {
    #[serde(default, deserialize_with = "lenient::string")]
    title: String,
    #[serde(default, deserialize_with = "lenient::opt_string")]
    description: Option<String>,
    #[serde(default, deserialize_with = "lenient::opt_i64")]
    start_timestamp: Option<i64>,
    #[serde(
        default,
        alias = "end_timestamp",
        deserialize_with = "lenient::opt_i64"
    )]
    stop_timestamp: Option<i64>,
    #[serde(default, deserialize_with = "lenient::opt_string")]
    start: Option<String>,
    #[serde(default, alias = "stop", deserialize_with = "lenient::opt_string")]
    end: Option<String>,
}

/// A guide entry plus how its times were obtained, for diagnostics.
#[derive(Debug, Clone)]
pub struct Listing {
    pub programme: Programme,
    /// Seconds between the wall-clock strings (read in the panel's timezone)
    /// and the unix timestamps. Non-zero means the panel is inconsistent.
    pub wall_clock_skew: Option<i64>,
}

impl RawListing {
    fn into_listing(self, panel_offset: Option<i64>) -> Option<Listing> {
        let wall = |s: &Option<String>| {
            let t = time::parse_wall_clock(s.as_deref()?)?;
            Some(t - panel_offset?)
        };
        let (wall_start, wall_stop) = (wall(&self.start), wall(&self.end));
        // Unix timestamps are timezone-proof; the strings are a fallback.
        let start = self.start_timestamp.or(wall_start)?;
        let stop = self.stop_timestamp.or(wall_stop)?;
        let wall_clock_skew = match (self.start_timestamp, wall_start) {
            (Some(ts), Some(w)) => Some(w - ts),
            _ => None,
        };
        Some(Listing {
            programme: Programme {
                start,
                stop,
                title: decode_text(&self.title),
                description: self
                    .description
                    .as_deref()
                    .map(decode_text)
                    .filter(|d| !d.is_empty()),
            },
            wall_clock_skew,
        })
    }
}

const BASE64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

/// EPG text is base64 on most panels and plain on some; decode only when the
/// result is clean UTF-8 text so plain titles like "News" survive.
pub fn decode_text(s: &str) -> String {
    let t = s.trim();
    if let Ok(bytes) = BASE64.decode(t)
        && let Ok(text) = String::from_utf8(bytes)
        && !text.chars().any(|c| c.is_control() && !c.is_whitespace())
    {
        return text.trim().to_owned();
    }
    t.to_owned()
}

#[derive(Clone)]
pub struct XtreamClient {
    http: reqwest::Client,
    creds: Credentials,
}

impl XtreamClient {
    pub fn new(http: reqwest::Client, creds: Credentials) -> Self {
        XtreamClient { http, creds }
    }

    pub fn api_url(&self, params: &[(&str, &str)]) -> Url {
        let mut url = self
            .creds
            .server
            .join("player_api.php")
            .expect("relative path");
        url.query_pairs_mut()
            .append_pair("username", &self.creds.username)
            .append_pair("password", &self.creds.password)
            .extend_pairs(params);
        url
    }

    async fn get(&self, params: &[(&str, &str)], what: &'static str) -> Result<bytes::Bytes> {
        http::fetch(self.http.get(self.api_url(params)), what).await
    }

    pub async fn account(&self) -> Result<Account> {
        let account: Account = http::decode(&self.get(&[], "account").await?, "account")?;
        if !account.user_info.auth {
            return Err(Error::Auth);
        }
        Ok(account)
    }

    pub async fn live_categories(&self) -> Result<Vec<Category>> {
        let body = self
            .get(&[("action", "get_live_categories")], "live categories")
            .await?;
        lenient::seq_from_slice(&body, "live categories")
    }

    /// All live channels in provider order. Pass a category to fetch one group.
    pub async fn live_channels(&self, category_id: Option<&str>) -> Result<Vec<Channel>> {
        let mut params = vec![("action", "get_live_streams")];
        if let Some(id) = category_id {
            params.push(("category_id", id));
        }
        let body = self.get(&params, "live streams").await?;
        parse_channels(&body)
    }

    /// Current and upcoming programmes for one channel, straight from the
    /// panel. Fresher than XMLTV and cheap enough to call on focus/zap.
    pub async fn short_epg(
        &self,
        stream_id: i64,
        limit: u32,
        panel_offset: Option<i64>,
    ) -> Result<Vec<Listing>> {
        let (id, limit) = (stream_id.to_string(), limit.to_string());
        let body = self
            .get(
                &[
                    ("action", "get_short_epg"),
                    ("stream_id", &id),
                    ("limit", &limit),
                ],
                "short EPG",
            )
            .await?;
        parse_short_epg(&body, panel_offset)
    }

    pub fn xmltv_url(&self) -> Url {
        let mut url = self.creds.server.join("xmltv.php").expect("relative path");
        url.query_pairs_mut()
            .append_pair("username", &self.creds.username)
            .append_pair("password", &self.creds.password);
        url
    }

    /// True when `text` contains this account's username or password.
    /// Many panels ship an "Account Info" category whose channel names are
    /// the login details; those must never reach a screen.
    pub fn mentions_credentials(&self, text: &str) -> bool {
        let text = text.to_lowercase();
        [&self.creds.username, &self.creds.password]
            .iter()
            .map(|s| s.trim().to_lowercase())
            .filter(|s| s.chars().count() >= 4)
            .any(|s| text.contains(&s))
    }

    pub fn live_url(&self, stream_id: i64, format: StreamFormat) -> Url {
        let mut url = self.creds.server.clone();
        url.path_segments_mut()
            .expect("http url")
            .pop_if_empty()
            .extend([
                "live",
                &self.creds.username,
                &self.creds.password,
                &format!("{stream_id}.{}", format.extension()),
            ]);
        url
    }
}

pub fn parse_channels(body: &[u8]) -> Result<Vec<Channel>> {
    let raw: Vec<RawChannel> = lenient::seq_from_slice(body, "live streams")?;
    Ok(raw
        .into_iter()
        .filter_map(RawChannel::into_channel)
        .collect())
}

pub fn parse_short_epg(body: &[u8], panel_offset: Option<i64>) -> Result<Vec<Listing>> {
    let epg: ShortEpg = http::decode(body, "short EPG")?;
    Ok(epg
        .epg_listings
        .into_iter()
        .filter_map(|l| l.into_listing(panel_offset))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_urls_with_escaped_credentials() {
        let creds = Credentials::new("http://tv.example.com:8080", "me", "p@ss/word").unwrap();
        let x = XtreamClient::new(reqwest::Client::new(), creds);
        assert_eq!(
            x.live_url(42, StreamFormat::Hls).as_str(),
            "http://tv.example.com:8080/live/me/p@ss%2Fword/42.m3u8"
        );
        assert_eq!(
            x.api_url(&[("action", "get_live_streams")]).as_str(),
            "http://tv.example.com:8080/player_api.php?username=me&password=p%40ss%2Fword&action=get_live_streams"
        );
        let nested = Credentials::new("https://cdn.example.com/panel", "me", "pw").unwrap();
        let x = XtreamClient::new(reqwest::Client::new(), nested);
        assert_eq!(
            x.xmltv_url().as_str(),
            "https://cdn.example.com/panel/xmltv.php?username=me&password=pw"
        );
    }

    #[test]
    fn spots_credentials_in_channel_names() {
        let creds = Credentials::new("http://tv.example.com", "jdoe2026", "Pa55word").unwrap();
        let x = XtreamClient::new(reqwest::Client::new(), creds);
        assert!(x.mentions_credentials("Username: JDOE2026"));
        assert!(x.mentions_credentials("pass pa55word"));
        assert!(!x.mentions_credentials("BBC One HD"));
        let short = Credentials::new("http://tv.example.com", "abc", "xy").unwrap();
        let x = XtreamClient::new(reqwest::Client::new(), short);
        assert!(
            !x.mentions_credentials("abc news"),
            "too short to match safely"
        );
    }

    #[test]
    fn decodes_base64_but_keeps_plain_text() {
        assert_eq!(decode_text("TmV3cyAmIFdlYXRoZXI="), "News & Weather");
        assert_eq!(decode_text("TmV3cyAmIFdlYXRoZXI"), "News & Weather");
        assert_eq!(decode_text("News"), "News");
        assert_eq!(decode_text("Match of the Day"), "Match of the Day");
        assert_eq!(decode_text("Q2Fmw6k="), "Café");
    }
}

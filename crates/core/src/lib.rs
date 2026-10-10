//! Shared core for the OpenIPTV clients (iOS, tvOS, Fire TV, web).
//!
//! Everything that is not UI or video decoding lives here so every platform
//! gets the same parsing, EPG and artwork behaviour.

pub mod app;
pub mod artwork;
pub mod emby;
pub mod emby_connect;
pub mod epg;
pub mod http;
mod lenient;
pub mod time;
pub mod xmltv;
pub mod xtream;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Transport failure. The URL is stripped because Xtream URLs embed credentials.
    #[error("network error: {0}")]
    Http(reqwest::Error),
    #[error("{what} returned HTTP {status}")]
    Status { what: &'static str, status: u16 },
    #[error("could not decode {what}: {source}")]
    Decode {
        what: &'static str,
        #[source]
        source: serde_json::Error,
    },
    #[error("credentials were rejected")]
    Auth,
    #[error("that server address isn't valid")]
    InvalidAddress,
    #[error("not logged in")]
    NoSession,
    #[error("invalid XMLTV: {0}")]
    Xmltv(String),
}

impl From<reqwest::Error> for Error {
    fn from(err: reqwest::Error) -> Self {
        Error::Http(err.without_url())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

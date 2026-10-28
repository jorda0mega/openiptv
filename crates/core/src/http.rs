//! One shared HTTP client per process, tuned for many small API calls to a
//! handful of hosts. Reusing it keeps TCP/TLS connections warm, which is most
//! of the latency on a cold request.

use std::time::Duration;

pub const USER_AGENT: &str = concat!("Zapline/", env!("CARGO_PKG_VERSION"));

/// Per-request deadline for metadata calls. Streams are not subject to it.
pub const API_TIMEOUT: Duration = Duration::from_secs(15);

pub fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(Duration::from_secs(5))
        .pool_idle_timeout(Duration::from_secs(90))
        .pool_max_idle_per_host(8)
        .tcp_nodelay(true)
        .tcp_keepalive(Duration::from_secs(30))
        .http2_adaptive_window(true)
        .build()
        .expect("static reqwest configuration is valid")
}

/// Fetch a URL and return its body, mapping non-2xx statuses to [`crate::Error::Status`].
pub(crate) async fn fetch(
    req: reqwest::RequestBuilder,
    what: &'static str,
) -> crate::Result<bytes::Bytes> {
    let res = req.timeout(API_TIMEOUT).send().await?;
    let status = res.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err(crate::Error::Auth);
    }
    if !status.is_success() {
        return Err(crate::Error::Status {
            what,
            status: status.as_u16(),
        });
    }
    Ok(res.bytes().await?)
}

pub(crate) fn decode<T: serde::de::DeserializeOwned>(
    body: &[u8],
    what: &'static str,
) -> crate::Result<T> {
    serde_json::from_slice(body).map_err(|source| crate::Error::Decode { what, source })
}

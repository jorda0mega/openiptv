//! openiptv-edge: serves the web app and relays what browsers can't fetch
//! themselves (Xtream streams are plain HTTP without CORS).
//!
//! Logins come from the environment, the same variables as `openiptv-probe`.
//! Run it under `op run` so they come straight from 1Password and only ever
//! live in this process's memory.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::Json;
use axum::Router;
use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use futures_util::StreamExt;
use openiptv_core::app::{EmbyAccount, EmbyLogin, LiveTv, Row};
use openiptv_core::emby::Device;
use openiptv_core::http;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tower_http::compression::CompressionLayer;
use tower_http::services::{ServeDir, ServeFile};

const HOME_TTL: Duration = Duration::from_secs(60);
const GUIDE_REFRESH: Duration = Duration::from_secs(6 * 3600);

struct Edge {
    http: reqwest::Client,
    emby: Result<EmbyAccount, String>,
    live: Result<Arc<LiveTv>, String>,
    home: tokio::sync::Mutex<Option<(Instant, Arc<Vec<Row>>)>>,
    /// The provider allows a limited number of connections, so only one
    /// relay runs at a time; starting a channel stops the previous one.
    stream: Mutex<Option<tokio::task::AbortHandle>>,
    last_zap: Mutex<Option<Value>>,
}

type Shared = Arc<Edge>;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

fn emby_login() -> Option<EmbyLogin> {
    if let Some(user) = env("OPENIPTV_EMBY_CONNECT_USER") {
        return Some(EmbyLogin::Connect {
            user,
            password: env("OPENIPTV_EMBY_CONNECT_PASS").unwrap_or_default(),
            server: env("OPENIPTV_EMBY_SERVER"),
        });
    }
    Some(EmbyLogin::Direct {
        url: env("OPENIPTV_EMBY_URL")?,
        user: env("OPENIPTV_EMBY_USER").unwrap_or_default(),
        password: env("OPENIPTV_EMBY_PASS").unwrap_or_default(),
    })
}

async fn live_login(http: &reqwest::Client) -> Result<LiveTv, String> {
    let (Some(urls), Some(user), Some(pass)) = (
        env("OPENIPTV_XTREAM_URL"),
        env("OPENIPTV_XTREAM_USER"),
        env("OPENIPTV_XTREAM_PASS"),
    ) else {
        return Err("not configured".into());
    };
    // Several candidate addresses may be given; the first that accepts wins.
    let mut last = "no server address".to_string();
    for url in urls.split_whitespace() {
        let creds = match openiptv_core::app::xtream_credentials(url, &user, &pass) {
            Ok(c) => c,
            Err(e) => {
                last = e.to_string();
                continue;
            }
        };
        match LiveTv::sign_in(http, creds).await {
            Ok(live) => return Ok(live),
            Err(e) => last = e.to_string(),
        }
    }
    Err(last)
}

#[tokio::main]
async fn main() {
    let http = http::client();
    let device = Device {
        client: "OpenIPTV Web".into(),
        name: "openiptv-edge".into(),
        id: "openiptv-edge".into(),
        version: env!("CARGO_PKG_VERSION").into(),
    };
    let started = Instant::now();
    let (emby, live) = tokio::join!(
        async {
            match emby_login() {
                Some(login) => EmbyAccount::sign_in(&http, device, login)
                    .await
                    .map_err(|e| e.to_string()),
                None => Err("not configured".to_string()),
            }
        },
        live_login(&http)
    );
    match &emby {
        Ok(a) => eprintln!("emby: signed in to {}", a.server_name),
        Err(e) => eprintln!("emby: {e}"),
    }
    match &live {
        Ok(l) => eprintln!("live: {} channels", l.channels(None, None).len()),
        Err(e) => eprintln!("live: {e}"),
    }
    eprintln!("ready in {} ms", started.elapsed().as_millis());

    let edge = Arc::new(Edge {
        http: http.clone(),
        emby,
        live: live.map(Arc::new),
        home: tokio::sync::Mutex::new(None),
        stream: Mutex::new(None),
        last_zap: Mutex::new(None),
    });

    // Full guide in the background, then every few hours. Never on the
    // request path: it can take a minute or more to download.
    if let Ok(live) = &edge.live {
        let (live, http) = (live.clone(), http.clone());
        tokio::spawn(async move {
            loop {
                match live.refresh_guide(&http, 24, true).await {
                    Ok(()) => {
                        let s = live.guide_status();
                        eprintln!(
                            "guide: {} programmes for {} channels ({:.0} MB) in {:.0} s",
                            s.programmes,
                            s.channels,
                            s.bytes as f64 / 1e6,
                            s.seconds
                        );
                    }
                    Err(e) => eprintln!("guide: {e}"),
                }
                tokio::time::sleep(GUIDE_REFRESH).await;
            }
        });
    }

    let web_dir = env("OPENIPTV_WEB_DIR").unwrap_or_else(|| "web/dist".into());
    let app = Router::new()
        .route("/api/status", get(status))
        .route("/api/home", get(home))
        .route("/api/live/categories", get(categories))
        .route("/api/live/channels", get(channels))
        .route("/api/live/nownext", get(now_next))
        .route("/live/{file}", get(relay))
        .fallback_service(
            ServeDir::new(&web_dir).fallback(ServeFile::new(format!("{web_dir}/index.html"))),
        )
        .layer(CompressionLayer::new())
        .with_state(edge);

    let addr: SocketAddr = env("OPENIPTV_EDGE_ADDR")
        .unwrap_or_else(|| "127.0.0.1:8787".into())
        .parse()
        .expect("OPENIPTV_EDGE_ADDR must be host:port");
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind address");
    eprintln!("listening on http://{addr}");
    axum::serve(listener, app).await.expect("server");
}

fn error(status: StatusCode, message: impl Into<String>) -> Response {
    (status, Json(json!({ "error": message.into() }))).into_response()
}

fn live(edge: &Edge) -> Result<&Arc<LiveTv>, Box<Response>> {
    edge.live.as_ref().map_err(|e| {
        Box::new(error(
            StatusCode::SERVICE_UNAVAILABLE,
            format!("live TV: {e}"),
        ))
    })
}

async fn status(State(edge): State<Shared>) -> Json<Value> {
    let emby = match &edge.emby {
        Ok(a) => json!({ "ok": true, "server": a.server_name }),
        Err(e) => json!({ "ok": false, "error": e }),
    };
    let live = match &edge.live {
        Ok(l) => json!({
            "ok": true,
            "channels": l.channels(None, None).len(),
            "maxConnections": l.account.user_info.max_connections,
            "formats": l.account.user_info.allowed_output_formats,
            "guide": l.guide_status(),
        }),
        Err(e) => json!({ "ok": false, "error": e }),
    };
    let last_zap = edge.last_zap.lock().expect("poisoned").clone();
    Json(json!({ "emby": emby, "live": live, "lastZap": last_zap }))
}

#[derive(Deserialize)]
struct HomeQuery {
    width: Option<u32>,
}

async fn home(State(edge): State<Shared>, Query(q): Query<HomeQuery>) -> Response {
    let account = match &edge.emby {
        Ok(a) => a,
        Err(e) => return error(StatusCode::SERVICE_UNAVAILABLE, format!("Emby: {e}")),
    };
    let mut cache = edge.home.lock().await;
    if let Some((at, rows)) = cache.as_ref()
        && at.elapsed() < HOME_TTL
    {
        return Json(rows.as_ref().clone()).into_response();
    }
    let started = Instant::now();
    match account.home(q.width.unwrap_or(240).clamp(120, 800)).await {
        Ok(rows) => {
            let rows = Arc::new(rows);
            *cache = Some((Instant::now(), rows.clone()));
            let mut res = Json(rows.as_ref().clone()).into_response();
            res.headers_mut().insert(
                "Server-Timing",
                format!("emby;dur={}", started.elapsed().as_millis())
                    .parse()
                    .expect("header"),
            );
            res
        }
        Err(e) => error(StatusCode::BAD_GATEWAY, e.to_string()),
    }
}

async fn categories(State(edge): State<Shared>) -> Response {
    match live(&edge) {
        Ok(l) => Json(l.categories()).into_response(),
        Err(r) => *r,
    }
}

#[derive(Deserialize)]
struct ChannelQuery {
    category: Option<String>,
    q: Option<String>,
}

async fn channels(State(edge): State<Shared>, Query(q): Query<ChannelQuery>) -> Response {
    match live(&edge) {
        Ok(l) => Json(l.channels(q.category.as_deref(), q.q.as_deref())).into_response(),
        Err(r) => *r,
    }
}

#[derive(Deserialize)]
struct NowNextQuery {
    ids: String,
}

async fn now_next(State(edge): State<Shared>, Query(q): Query<NowNextQuery>) -> Response {
    let l = match live(&edge) {
        Ok(l) => l,
        Err(r) => return *r,
    };
    let ids: Vec<i64> = q
        .ids
        .split(',')
        .filter_map(|s| s.trim().parse().ok())
        .take(100)
        .collect();
    let map: HashMap<String, _> = l
        .now_next(&ids)
        .await
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
    Json(map).into_response()
}

/// Relay one live channel. Stops any previous relay first so the provider's
/// connection limit is never exceeded, and retries briefly while the panel
/// notices the old connection is gone.
async fn relay(State(edge): State<Shared>, Path(file): Path<String>) -> Response {
    let l = match live(&edge) {
        Ok(l) => l.clone(),
        Err(r) => return *r,
    };
    let Some(id) = file
        .strip_suffix(".ts")
        .unwrap_or(&file)
        .parse::<i64>()
        .ok()
        .filter(|id| l.channel(*id).is_some())
    else {
        return error(StatusCode::NOT_FOUND, "unknown channel");
    };
    if let Some(previous) = edge.stream.lock().expect("poisoned").take() {
        previous.abort();
    }

    let started = Instant::now();
    let url = l.stream_url(id);
    let mut attempt = 0;
    let upstream = loop {
        attempt += 1;
        match edge.http.get(url.clone()).send().await {
            Ok(res) if res.status().is_success() => break res,
            Ok(res) if attempt < 4 => {
                eprintln!("relay {id}: HTTP {} (attempt {attempt})", res.status());
            }
            Ok(res) => {
                return error(
                    StatusCode::BAD_GATEWAY,
                    format!("provider HTTP {}", res.status()),
                );
            }
            Err(e) if attempt < 4 => {
                eprintln!("relay {id}: {} (attempt {attempt})", e.without_url())
            }
            Err(e) => return error(StatusCode::BAD_GATEWAY, e.without_url().to_string()),
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
    };
    let headers_ms = started.elapsed().as_millis();

    let (tx, rx) = mpsc::channel::<Result<bytes::Bytes, std::io::Error>>(32);
    let edge_for_task = edge.clone();
    let task = tokio::spawn(async move {
        let mut body = upstream.bytes_stream();
        let mut first = true;
        while let Some(chunk) = body.next().await {
            if first {
                first = false;
                let zap = json!({
                    "channel": id,
                    "attempts": attempt,
                    "headersMs": headers_ms,
                    "firstBytesMs": started.elapsed().as_millis(),
                });
                eprintln!("relay {id}: {zap}");
                *edge_for_task.last_zap.lock().expect("poisoned") = Some(zap);
            }
            let chunk = chunk.map_err(|e| std::io::Error::other(e.without_url()));
            if tx.send(chunk).await.is_err() {
                break; // viewer went away; dropping `body` closes the provider connection
            }
        }
    });
    *edge.stream.lock().expect("poisoned") = Some(task.abort_handle());

    Response::builder()
        .header(header::CONTENT_TYPE, "video/mp2t")
        .header(header::CACHE_CONTROL, "no-store")
        .header("Server-Timing", format!("upstream;dur={headers_ms}"))
        .body(Body::from_stream(
            tokio_stream::wrappers::ReceiverStream::new(rx),
        ))
        .expect("valid response")
}

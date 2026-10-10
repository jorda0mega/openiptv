//! openiptv-edge: serves the web app and relays what browsers can't fetch
//! themselves (Xtream streams are plain HTTP without CORS).
//!
//! Logins come from the environment (the same variables as
//! `openiptv-probe`) or from signing in in the web app, and only ever live in
//! this process's memory.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use axum::Json;
use axum::Router;
use axum::body::Body;
use axum::extract::{ConnectInfo, Path, Query, Request, State};
use axum::http::{StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use futures_util::StreamExt;
use openiptv_core::app::{EmbyAccount, EmbyLogin, LiveTv, Row};
use openiptv_core::emby::{Device, PlaybackEvent};
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
    device: Device,
    /// Signed-in accounts, held only in memory. Set from the environment at
    /// startup or by signing in from the web app; never written to disk.
    emby: RwLock<Result<Arc<EmbyAccount>, String>>,
    live: RwLock<Result<Arc<LiveTv>, String>>,
    home: tokio::sync::Mutex<Option<(Instant, Arc<Vec<Row>>)>>,
    /// The provider allows a limited number of connections, so only one
    /// relay runs at a time; starting a channel stops the previous one.
    stream: Mutex<Option<tokio::task::AbortHandle>>,
    last_zap: Mutex<Option<Value>>,
    /// Required from other devices; see `require_key`.
    key: String,
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
                Some(login) => EmbyAccount::sign_in(&http, device.clone(), login)
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
        device,
        emby: RwLock::new(emby.map(Arc::new)),
        live: RwLock::new(live.map(Arc::new)),
        home: tokio::sync::Mutex::new(None),
        stream: Mutex::new(None),
        last_zap: Mutex::new(None),
        key: env("OPENIPTV_EDGE_KEY").unwrap_or_else(random_key),
    });

    if let Ok(live) = edge.live.read().expect("poisoned").clone() {
        spawn_guide(edge.clone(), live);
    }

    let web_dir = env("OPENIPTV_WEB_DIR").unwrap_or_else(|| "web/dist".into());
    let app = Router::new()
        .route("/api/status", get(status))
        .route("/api/home", get(home))
        .route("/api/live/categories", get(categories))
        .route("/api/live/channels", get(channels))
        .route("/api/live/nownext", get(now_next))
        .route("/api/emby/play/{id}", get(emby_play))
        .route("/api/emby/progress", post(emby_progress))
        .route("/api/signin/emby", post(signin_emby))
        .route("/api/signin/xtream", post(signin_xtream))
        .route("/api/signout", post(signout))
        .route("/live/{file}", get(relay))
        .fallback_service(
            ServeDir::new(&web_dir).fallback(ServeFile::new(format!("{web_dir}/index.html"))),
        )
        .layer(CompressionLayer::new())
        .layer(middleware::from_fn_with_state(edge.clone(), require_key))
        .with_state(edge.clone());

    let addr: SocketAddr = env("OPENIPTV_EDGE_ADDR")
        .unwrap_or_else(|| "127.0.0.1:8787".into())
        .parse()
        .expect("OPENIPTV_EDGE_ADDR must be host:port");
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind address");
    eprintln!("listening on http://{addr}");
    if !addr.ip().is_loopback() {
        let ip = lan_ip().map_or_else(|| "<this-mac-ip>".into(), |ip| ip.to_string());
        eprintln!(
            "web on your phone (same Wi-Fi), open once: http://{ip}:{}/?key={}",
            addr.port(),
            edge.key
        );
    }
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
    .expect("server");
}

/// Other devices (a phone on the same Wi-Fi) must present the access key,
/// because this server holds the user's logins. Opening `/?key=…` once sets
/// a cookie; this machine itself is always trusted.
async fn require_key(
    State(edge): State<Shared>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    if peer.ip().is_loopback() {
        return next.run(req).await;
    }
    let cookie = format!("openiptv_key={}", edge.key);
    let offered = req
        .uri()
        .query()
        .and_then(|q| q.split('&').find_map(|p| p.strip_prefix("key=")));
    if offered == Some(edge.key.as_str()) {
        return Response::builder()
            .status(StatusCode::SEE_OTHER)
            .header(header::LOCATION, "/")
            .header(
                header::SET_COOKIE,
                format!("{cookie}; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000"),
            )
            .body(Body::empty())
            .expect("valid response");
    }
    let has_cookie = req
        .headers()
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .any(|c| c.trim() == cookie);
    if has_cookie {
        next.run(req).await
    } else {
        error(
            StatusCode::UNAUTHORIZED,
            "Open the link printed by openiptv-edge on this device first.",
        )
    }
}

fn emby(edge: &Edge) -> Result<Arc<EmbyAccount>, Box<Response>> {
    edge.emby
        .read()
        .expect("poisoned")
        .clone()
        .map_err(|e| Box::new(error(StatusCode::SERVICE_UNAVAILABLE, format!("Emby: {e}"))))
}

/// Where and from what position to play an Emby item (series and seasons
/// resolve to the next episode). Paired devices then stream straight from
/// Emby, so video never passes through this Mac.
async fn emby_play(State(edge): State<Shared>, Path(id): Path<String>) -> Response {
    let account = match emby(&edge) {
        Ok(a) => a,
        Err(r) => return *r,
    };
    match account.playback(&id).await {
        Ok(p) => Json(p).into_response(),
        Err(e) => error(StatusCode::BAD_GATEWAY, e.to_string()),
    }
}

#[derive(Deserialize)]
struct ProgressReport {
    item_id: String,
    position_seconds: f64,
    event: String,
}

async fn emby_progress(State(edge): State<Shared>, Json(r): Json<ProgressReport>) -> Response {
    let account = match emby(&edge) {
        Ok(a) => a,
        Err(r) => return *r,
    };
    let event = match r.event.as_str() {
        "start" => PlaybackEvent::Started,
        "stop" => PlaybackEvent::Stopped,
        _ => PlaybackEvent::Progress,
    };
    if event == PlaybackEvent::Stopped {
        // Continue Watching changed; don't serve the cached rows.
        *edge.home.lock().await = None;
    }
    match account.report(event, &r.item_id, r.position_seconds).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => error(StatusCode::BAD_GATEWAY, e.to_string()),
    }
}

fn random_bytes<const N: usize>() -> [u8; N] {
    use std::io::Read;
    let mut bytes = [0u8; N];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .expect("read /dev/urandom");
    bytes
}

fn random_key() -> String {
    random_bytes::<16>()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The address other devices on the LAN reach this machine at. Connecting a
/// UDP socket sends nothing; it only selects the outgoing interface.
fn lan_ip() -> Option<std::net::IpAddr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:80").ok()?;
    Some(socket.local_addr().ok()?.ip())
}

fn error(status: StatusCode, message: impl Into<String>) -> Response {
    (status, Json(json!({ "error": message.into() }))).into_response()
}

fn live(edge: &Edge) -> Result<Arc<LiveTv>, Box<Response>> {
    edge.live.read().expect("poisoned").clone().map_err(|e| {
        Box::new(error(
            StatusCode::SERVICE_UNAVAILABLE,
            format!("live TV: {e}"),
        ))
    })
}

async fn status(State(edge): State<Shared>) -> Json<Value> {
    let emby = match emby(&edge) {
        Ok(a) => json!({ "ok": true, "server": a.server_name }),
        Err(_) => {
            json!({ "ok": false, "error": edge.emby.read().expect("poisoned").as_ref().err().cloned() })
        }
    };
    let live = match edge.live.read().expect("poisoned").as_ref() {
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
    let account = match emby(&edge) {
        Ok(a) => a,
        Err(r) => return *r,
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

/// Keeps the full guide fresh for as long as this live TV account is the
/// current one; stops when the user signs out or signs in elsewhere.
fn spawn_guide(edge: Shared, live: Arc<LiveTv>) {
    tokio::spawn(async move {
        loop {
            let current = edge.live.read().expect("poisoned").as_ref().ok().cloned();
            if !current.is_some_and(|c| Arc::ptr_eq(&c, &live)) {
                break;
            }
            match live.refresh_guide(&edge.http, 24, true).await {
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

#[derive(Deserialize)]
struct EmbySignIn {
    /// "server" (address + login) or "connect" (Emby Connect account).
    mode: String,
    url: Option<String>,
    username: String,
    password: String,
    server: Option<String>,
}

/// Sign in to Emby from the web app. The password is used once and dropped;
/// the session lives only in this process's memory.
async fn signin_emby(State(edge): State<Shared>, Json(req): Json<EmbySignIn>) -> Response {
    let login = if req.mode == "connect" {
        EmbyLogin::Connect {
            user: req.username,
            password: req.password,
            server: req.server.filter(|s| !s.trim().is_empty()),
        }
    } else {
        let Some(url) = req.url.filter(|u| !u.trim().is_empty()) else {
            return error(StatusCode::BAD_REQUEST, "Enter the server address.");
        };
        EmbyLogin::Direct {
            url,
            user: req.username,
            password: req.password,
        }
    };
    match EmbyAccount::sign_in(&edge.http, edge.device.clone(), login).await {
        Ok(account) => {
            let server = account.server_name.clone();
            *edge.emby.write().expect("poisoned") = Ok(Arc::new(account));
            *edge.home.lock().await = None;
            Json(json!({ "ok": true, "server": server })).into_response()
        }
        Err(e) => error(StatusCode::UNAUTHORIZED, e.to_string()),
    }
}

#[derive(Deserialize)]
struct XtreamSignIn {
    url: String,
    username: String,
    password: String,
}

/// Sign in to an Xtream Codes subscription from the web app; held in memory.
async fn signin_xtream(State(edge): State<Shared>, Json(req): Json<XtreamSignIn>) -> Response {
    let creds = match openiptv_core::app::xtream_credentials(&req.url, &req.username, &req.password)
    {
        Ok(c) => c,
        Err(_) => return error(StatusCode::BAD_REQUEST, "That server address isn't valid."),
    };
    match LiveTv::sign_in(&edge.http, creds).await {
        Ok(live) => {
            let live = Arc::new(live);
            let channels = live.channels(None, None).len();
            *edge.live.write().expect("poisoned") = Ok(live.clone());
            spawn_guide(edge.clone(), live);
            Json(json!({ "ok": true, "channels": channels })).into_response()
        }
        Err(e) => error(StatusCode::UNAUTHORIZED, e.to_string()),
    }
}

#[derive(Deserialize)]
struct SignOut {
    /// "emby", "live" or "all".
    what: String,
}

async fn signout(State(edge): State<Shared>, Json(req): Json<SignOut>) -> Response {
    if req.what == "emby" || req.what == "all" {
        *edge.emby.write().expect("poisoned") = Err("signed out".into());
        *edge.home.lock().await = None;
    }
    if req.what == "live" || req.what == "all" {
        if let Some(stream) = edge.stream.lock().expect("poisoned").take() {
            stream.abort();
        }
        *edge.live.write().expect("poisoned") = Err("signed out".into());
    }
    StatusCode::NO_CONTENT.into_response()
}

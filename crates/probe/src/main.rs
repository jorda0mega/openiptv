//! openiptv-probe: measure a real Emby server and Xtream provider before building UI.
//!
//! Answers the questions that decide the app's design: how fast each call is,
//! whether the provider offers HLS (native Apple playback) or only TS, how
//! accurate "now playing" is, and how much artwork Emby actually has.
//!
//! Credentials come from environment variables (see `scripts/probe.sh`).
//! Nothing is written to disk unless `--json PATH` is given, and that report
//! contains no credentials or stream URLs.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::time::{Duration, Instant};

use openiptv_core::artwork::{self, Context, Shape};
use openiptv_core::emby::{Device, EmbyClient, PublicInfo};
use openiptv_core::emby_connect::ConnectClient;
use openiptv_core::epg::{self, Programme};
use openiptv_core::xtream::{self, Account, Channel, Credentials, StreamFormat, XtreamClient};
use openiptv_core::{http, time, xmltv};
use serde_json::{Map, Value, json};
use url::Url;

type AnyResult<T> = Result<T, Box<dyn std::error::Error>>;
type Query<'a> = Vec<(&'a str, &'a str)>;

struct Options {
    samples: usize,
    json: Option<String>,
    xmltv: bool,
    streams: bool,
}

fn options() -> AnyResult<Options> {
    let mut o = Options {
        samples: 24,
        json: None,
        xmltv: true,
        streams: true,
    };
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--samples" => o.samples = args.next().ok_or("--samples needs a number")?.parse()?,
            "--json" => o.json = Some(args.next().ok_or("--json needs a path")?),
            "--skip-xmltv" => o.xmltv = false,
            "--skip-streams" => o.streams = false,
            "-h" | "--help" => {
                println!(
                    "openiptv-probe [--samples N] [--json PATH] [--skip-xmltv] [--skip-streams]\n\n\
                     env: OPENIPTV_EMBY_URL OPENIPTV_EMBY_USER OPENIPTV_EMBY_PASS\n     \
                     or OPENIPTV_EMBY_CONNECT_USER OPENIPTV_EMBY_CONNECT_PASS [OPENIPTV_EMBY_SERVER]\n     \
                     OPENIPTV_XTREAM_URL OPENIPTV_XTREAM_USER OPENIPTV_XTREAM_PASS"
                );
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument {other}").into()),
        }
    }
    Ok(o)
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

async fn timed<T>(f: impl Future<Output = T>) -> (T, Duration) {
    let start = Instant::now();
    let out = f.await;
    (out, start.elapsed())
}

fn ms(d: Duration) -> String {
    format!("{} ms", d.as_millis())
}

fn pct(part: usize, whole: usize) -> String {
    if whole == 0 {
        return "n/a".into();
    }
    format!("{:.0}%", part as f64 * 100.0 / whole as f64)
}

fn percentile(sorted: &[Duration], p: f64) -> Duration {
    if sorted.is_empty() {
        return Duration::ZERO;
    }
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

fn heading(s: &str) {
    println!("\n== {s} ==");
}

#[tokio::main]
async fn main() {
    let opts = match options() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let http = http::client();
    let mut report = Map::new();

    if env("OPENIPTV_XTREAM_URL").is_some() {
        let mut section = Map::new();
        if let Err(e) = probe_xtream(&http, &opts, &mut section).await {
            println!("  ✗ stopped: {e}");
            section.insert("error".into(), json!(e.to_string()));
        }
        report.insert("xtream".into(), Value::Object(section));
    } else {
        println!("(skipping Xtream: OPENIPTV_XTREAM_URL not set)");
    }

    if env("OPENIPTV_EMBY_URL").is_some() || env("OPENIPTV_EMBY_CONNECT_USER").is_some() {
        let mut section = Map::new();
        if let Err(e) = probe_emby(&http, &mut section).await {
            println!("  ✗ stopped: {e}");
            section.insert("error".into(), json!(e.to_string()));
        }
        report.insert("emby".into(), Value::Object(section));
    } else {
        println!("(skipping Emby: neither OPENIPTV_EMBY_URL nor OPENIPTV_EMBY_CONNECT_USER set)");
    }

    if let Some(path) = &opts.json {
        let body = serde_json::to_string_pretty(&Value::Object(report)).expect("serialisable");
        match std::fs::write(path, body) {
            Ok(()) => println!("\nwrote {path}"),
            Err(e) => eprintln!("could not write {path}: {e}"),
        }
    }
}

// ---------------------------------------------------------------- Xtream ---

async fn probe_xtream(
    http: &reqwest::Client,
    opts: &Options,
    out: &mut Map<String, Value>,
) -> AnyResult<()> {
    let servers = env("OPENIPTV_XTREAM_URL").ok_or("OPENIPTV_XTREAM_URL missing")?;
    let user = env("OPENIPTV_XTREAM_USER").ok_or("OPENIPTV_XTREAM_USER missing")?;
    let pass = env("OPENIPTV_XTREAM_PASS").ok_or("OPENIPTV_XTREAM_PASS missing")?;

    heading("Xtream account");
    // Several candidate addresses may be given (space-separated); use the
    // first one that accepts the login.
    let mut found = None;
    for server in servers.split_whitespace() {
        let host = Url::parse(server)
            .ok()
            .and_then(|u| u.host_str().map(str::to_owned))
            .unwrap_or_else(|| "?".into());
        let Ok(creds) = Credentials::new(server, &user, &pass) else {
            println!("  {host:<18} ✗ not a URL");
            continue;
        };
        let x = XtreamClient::new(http.clone(), creds);
        let (account, t) = timed(x.account()).await;
        match account {
            Ok(account) => {
                println!("  server             {host}");
                found = Some((x, account, t));
                break;
            }
            Err(e) => println!("  {host:<18} ✗ {e}"),
        }
    }
    let (x, account, t) = found.ok_or("no candidate server accepted the login")?;
    let local_now = time::now();
    let offset = account.panel_utc_offset();
    let clock_skew = account.server_info.timestamp_now.map(|ts| ts - local_now);
    let formats = &account.user_info.allowed_output_formats;
    println!("  login              {}", ms(t));
    println!("  status             {}", account.user_info.status);
    if let Some(exp) = account.user_info.exp_date {
        println!("  expires in         {} days", (exp - local_now) / 86_400);
    }
    println!(
        "  connections        {} of {}",
        account.user_info.active_cons.unwrap_or(0),
        account
            .user_info
            .max_connections
            .map_or("?".into(), |m| m.to_string())
    );
    println!(
        "  output formats     {}",
        if formats.is_empty() {
            "(not listed)".into()
        } else {
            formats.join(", ")
        }
    );
    println!(
        "  panel timezone     {} (UTC{:+.1}h)",
        account.server_info.timezone.as_deref().unwrap_or("?"),
        offset.unwrap_or(0) as f64 / 3600.0
    );
    if let Some(skew) = clock_skew {
        println!("  panel clock skew   {skew:+} s vs this machine");
    }
    out.insert(
        "account".into(),
        json!({
            "login_ms": t.as_millis(), "formats": formats, "hls": account.supports(StreamFormat::Hls),
            "max_connections": account.user_info.max_connections, "panel_utc_offset_s": offset,
            "clock_skew_s": clock_skew,
        }),
    );

    heading("Channels");
    let (cats, t_cats) = timed(x.live_categories()).await;
    let cats = cats?;
    let (body, t_dl) = timed(async {
        let res = http
            .get(x.api_url(&[("action", "get_live_streams")]))
            .send()
            .await?;
        res.error_for_status()?.bytes().await
    })
    .await;
    let body = body.map_err(|e| e.without_url())?;
    let parse_start = Instant::now();
    let channels = xtream::parse_channels(&body)?;
    let t_parse = parse_start.elapsed();
    let with_epg = channels.iter().filter(|c| c.epg_id.is_some()).count();
    let with_logo = channels.iter().filter(|c| c.logo.is_some()).count();
    let with_catchup = channels.iter().filter(|c| c.catchup_days.is_some()).count();
    println!("  categories         {} in {}", cats.len(), ms(t_cats));
    println!(
        "  channels           {} ({:.1} MB) downloaded in {}, parsed in {:.1} ms",
        channels.len(),
        body.len() as f64 / 1e6,
        ms(t_dl),
        t_parse.as_secs_f64() * 1e3
    );
    println!("  with guide id      {}", pct(with_epg, channels.len()));
    println!("  with logo          {}", pct(with_logo, channels.len()));
    println!("  with catch-up      {}", pct(with_catchup, channels.len()));
    out.insert(
        "channels".into(),
        json!({
            "categories": cats.len(), "count": channels.len(), "bytes": body.len(),
            "download_ms": t_dl.as_millis(), "parse_ms": t_parse.as_secs_f64() * 1e3,
            "with_epg_id": with_epg, "with_logo": with_logo, "with_catchup": with_catchup,
        }),
    );

    let sample = pick_sample(&channels, opts.samples);
    let short = probe_short_epg(&x, &sample, offset, out).await;

    if opts.xmltv
        && let Err(e) = probe_xmltv(http, &x, &sample, &short, out).await
    {
        println!("  ✗ XMLTV failed: {e}");
    }
    // Event and music channels are often off-air; test one that has a
    // programme on right now.
    let now = time::now();
    let on_air = sample.iter().find(|c| {
        short
            .get(&c.stream_id)
            .is_some_and(|p| epg::now_next(p, now).now.is_some())
    });
    if opts.streams
        && let Some(ch) = on_air.or(sample.first())
    {
        probe_streams(http, &x, &account, ch, out).await;
    }
    Ok(())
}

/// Evenly spaced channels that have a guide id, so the sample spans
/// categories instead of being the first N entries of one country.
fn pick_sample(channels: &[Channel], n: usize) -> Vec<Channel> {
    let candidates: Vec<&Channel> = channels.iter().filter(|c| c.epg_id.is_some()).collect();
    let pool = if candidates.is_empty() {
        channels.iter().collect()
    } else {
        candidates
    };
    if pool.len() <= n {
        return pool.into_iter().cloned().collect();
    }
    (0..n).map(|i| pool[i * pool.len() / n].clone()).collect()
}

async fn probe_short_epg(
    x: &XtreamClient,
    sample: &[Channel],
    offset: Option<i64>,
    out: &mut Map<String, Value>,
) -> HashMap<i64, Vec<Programme>> {
    heading(&format!(
        "Now playing via short EPG ({} channels)",
        sample.len()
    ));
    let mut latencies = Vec::new();
    let mut results = HashMap::new();
    let mut failures = 0;
    let mut skews: HashMap<i64, usize> = HashMap::new();
    let now = time::now();

    // 6 in flight mirrors what a guide screen fetches while scrolling.
    for chunk in sample.chunks(6) {
        let mut set = tokio::task::JoinSet::new();
        for ch in chunk {
            let (x, id) = (x.clone(), ch.stream_id);
            set.spawn(async move { (id, timed(x.short_epg(id, 4, offset)).await) });
        }
        while let Some(Ok((id, (res, t)))) = set.join_next().await {
            latencies.push(t);
            match res {
                Ok(listings) => {
                    for l in &listings {
                        if let Some(s) = l.wall_clock_skew {
                            *skews.entry(s).or_default() += 1;
                        }
                    }
                    results.insert(id, listings.into_iter().map(|l| l.programme).collect());
                }
                Err(_) => failures += 1,
            }
        }
    }
    latencies.sort();
    let with_now = results
        .values()
        .filter(|p: &&Vec<Programme>| epg::now_next(p, now).now.is_some())
        .count();
    let empty = results.values().filter(|p| p.is_empty()).count();
    println!(
        "  latency            p50 {} · p95 {} · max {}",
        ms(percentile(&latencies, 0.5)),
        ms(percentile(&latencies, 0.95)),
        ms(latencies.last().copied().unwrap_or_default())
    );
    println!(
        "  has a current show {} of channels",
        pct(with_now, sample.len())
    );
    println!("  empty guide        {empty} · failed calls {failures}");
    let inconsistent: Vec<_> = skews.iter().filter(|(s, _)| **s != 0).collect();
    if inconsistent.is_empty() {
        println!("  time strings       consistent with timestamps");
    } else {
        println!(
            "  time strings       ⚠ disagree with timestamps: {inconsistent:?} (skew s → count)"
        );
    }
    for ch in sample.iter().take(5) {
        let title = results
            .get(&ch.stream_id)
            .and_then(|p| epg::now_next(p, now).now)
            .map_or("—".to_string(), |p| p.title);
        println!("    {:<32} {}", truncate(&ch.name, 32), title);
    }
    out.insert(
        "short_epg".into(),
        json!({
            "sampled": sample.len(), "with_current": with_now, "empty": empty, "failed": failures,
            "p50_ms": percentile(&latencies, 0.5).as_millis(), "p95_ms": percentile(&latencies, 0.95).as_millis(),
            "inconsistent_time_strings": inconsistent.iter().map(|(s, c)| json!([s, c])).collect::<Vec<_>>(),
        }),
    );
    results
}

async fn probe_xmltv(
    http: &reqwest::Client,
    x: &XtreamClient,
    sample: &[Channel],
    short: &HashMap<i64, Vec<Programme>>,
    out: &mut Map<String, Value>,
) -> AnyResult<()> {
    heading("Full guide via XMLTV");
    const CAP: usize = 800 * 1024 * 1024;
    let start = Instant::now();
    let mut res = http
        .get(x.xmltv_url())
        .send()
        .await
        .map_err(|e| e.without_url())?;
    let ttfb = start.elapsed();
    if !res.status().is_success() {
        return Err(format!("HTTP {}", res.status()).into());
    }
    let mut body = Vec::new();
    while let Some(chunk) = res.chunk().await.map_err(|e| e.without_url())? {
        body.extend_from_slice(&chunk);
        if body.len() > CAP {
            return Err("guide larger than 800 MB; aborted".into());
        }
    }
    let t_dl = start.elapsed();
    let parse_start = Instant::now();
    let guide = xmltv::parse(&body, xmltv::Filter::default())?;
    let t_parse = parse_start.elapsed();
    println!(
        "  download           {:.1} MB, first byte {}, total {}",
        body.len() as f64 / 1e6,
        ms(ttfb),
        ms(t_dl)
    );
    println!(
        "  parse              {} channels, {} programmes in {} ms",
        guide.channel_names.len().max(guide.programmes.len()),
        guide.programme_count(),
        t_parse.as_millis()
    );

    // Same channel, two sources: when they disagree on what is on now, at
    // least one of them is wrong, and that is what users see as stale titles.
    let now = time::now();
    let (mut agree, mut disagree, mut only_xml, mut only_short, mut neither) = (0, 0, 0, 0, 0);
    let mut examples = Vec::new();
    for ch in sample {
        let Some(epg_id) = &ch.epg_id else { continue };
        let from_xml = guide.now_next(epg_id, now).now.map(|p| p.title);
        let from_short = short
            .get(&ch.stream_id)
            .and_then(|p| epg::now_next(p, now).now)
            .map(|p| p.title);
        match (from_xml, from_short) {
            (Some(a), Some(b)) if a.trim().eq_ignore_ascii_case(b.trim()) => agree += 1,
            (Some(a), Some(b)) => {
                disagree += 1;
                if examples.len() < 5 {
                    examples.push(format!(
                        "{}: XMLTV \"{a}\" vs short EPG \"{b}\"",
                        truncate(&ch.name, 28)
                    ));
                }
            }
            (Some(_), None) => only_xml += 1,
            (None, Some(_)) => only_short += 1,
            (None, None) => neither += 1,
        }
    }
    println!("  now-title          {agree} agree · {disagree} disagree");
    println!(
        "  current show from  XMLTV only {only_xml} · short EPG only {only_short} · neither {neither}"
    );
    for e in &examples {
        println!("    ⚠ {e}");
    }
    let unmatched: HashSet<&str> = sample
        .iter()
        .filter_map(|c| c.epg_id.as_deref())
        .filter(|id| !guide.programmes.contains_key(*id))
        .collect();
    if !unmatched.is_empty() {
        println!(
            "  guide ids absent   {} of the sampled ids have no XMLTV entry",
            unmatched.len()
        );
    }
    out.insert(
        "xmltv".into(),
        json!({
            "bytes": body.len(), "ttfb_ms": ttfb.as_millis(), "download_ms": t_dl.as_millis(),
            "parse_ms": t_parse.as_millis(), "programmes": guide.programme_count(),
            "now_agree": agree, "now_disagree": disagree, "now_only_xmltv": only_xml,
            "now_only_short_epg": only_short, "now_neither": neither,
            "sample_ids_missing": unmatched.len(),
        }),
    );
    Ok(())
}

/// Time until the first video bytes arrive: the floor for channel-switch speed.
/// Each attempt opens one provider connection and closes it immediately.
async fn probe_streams(
    http: &reqwest::Client,
    x: &XtreamClient,
    account: &Account,
    ch: &Channel,
    out: &mut Map<String, Value>,
) {
    heading(&format!("Stream start ({})", truncate(&ch.name, 40)));
    let mut results = Map::new();
    for format in [StreamFormat::Hls, StreamFormat::Ts] {
        let label = format.extension();
        if !account.supports(format) {
            println!("  {label:<5} not offered by provider");
            continue;
        }
        let url = x.live_url(ch.stream_id, format);
        let outcome = match format {
            StreamFormat::Ts => first_bytes(http, url).await.map(|(t, _)| t),
            StreamFormat::Hls => hls_first_segment(http, url).await,
        };
        match outcome {
            Ok(t) => {
                println!("  {label:<5} first video bytes after {}", ms(t));
                results.insert(label.into(), json!(t.as_millis()));
            }
            Err(e) => {
                println!("  {label:<5} ✗ {e}");
                results.insert(label.into(), json!(e.to_string()));
            }
        }
        // Give the panel time to release the connection slot.
        tokio::time::sleep(Duration::from_millis(1500)).await;
    }
    out.insert("stream_start_ms".into(), Value::Object(results));
}

async fn first_bytes(http: &reqwest::Client, url: Url) -> AnyResult<(Duration, Url)> {
    let start = Instant::now();
    let mut res = tokio::time::timeout(Duration::from_secs(15), http.get(url).send())
        .await
        .map_err(|_| "timed out")?
        .map_err(|e| e.without_url())?;
    if !res.status().is_success() {
        return Err(format!("HTTP {}", res.status()).into());
    }
    let final_url = res.url().clone();
    tokio::time::timeout(Duration::from_secs(15), res.chunk())
        .await
        .map_err(|_| "no data within 15 s")?
        .map_err(|e| e.without_url())?
        .ok_or("empty response")?;
    Ok((start.elapsed(), final_url))
}

/// Playlist → (variant playlist) → first segment bytes, the same hops a player makes.
async fn hls_first_segment(http: &reqwest::Client, url: Url) -> AnyResult<Duration> {
    let start = Instant::now();
    let mut playlist_url = url;
    for _ in 0..3 {
        let res = http
            .get(playlist_url.clone())
            .send()
            .await
            .map_err(|e| e.without_url())?;
        if !res.status().is_success() {
            return Err(format!("HTTP {}", res.status()).into());
        }
        let base = res.url().clone();
        let text = res.text().await.map_err(|e| e.without_url())?;
        let uris: Vec<&str> = text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect();
        let Some(first) = uris.first() else {
            return Err("playlist has no entries".into());
        };
        if text.contains("#EXT-X-STREAM-INF") {
            playlist_url = base.join(first)?;
            continue;
        }
        // Players start a few segments back from the live edge.
        let pick = uris[uris.len().saturating_sub(3)];
        first_bytes(http, base.join(pick)?).await?;
        return Ok(start.elapsed());
    }
    Err("too many nested playlists".into())
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_owned()
    } else {
        s.chars().take(max - 1).chain(['…']).collect()
    }
}

// ------------------------------------------------------------------ Emby ---

struct Connected {
    emby: EmbyClient,
    info: PublicInfo,
    info_time: Duration,
    /// Time from credentials to a usable server session.
    login_time: Duration,
}

async fn probe_emby(http: &reqwest::Client, out: &mut Map<String, Value>) -> AnyResult<()> {
    let device = Device {
        client: "Zapline Probe".into(),
        name: "openiptv-probe".into(),
        id: "openiptv-probe".into(),
        version: env!("CARGO_PKG_VERSION").into(),
    };
    let Connected {
        mut emby,
        info,
        info_time,
        login_time,
    } = match env("OPENIPTV_EMBY_CONNECT_USER") {
        Some(user) => connect_login(http, device, &user, out).await?,
        None => direct_login(http, device).await?,
    };

    // Always end the session, even if a later step fails.
    let result = probe_emby_home(http, &emby, out).await;
    if emby.logout().await.is_ok() {
        println!("  logged out         session closed on the server");
    }
    out.insert(
        "server".into(),
        json!({ "version": info.version, "info_ms": info_time.as_millis(), "login_ms": login_time.as_millis() }),
    );
    result
}

fn print_server(info: &PublicInfo, t: Duration) {
    println!(
        "  server             {} · Emby {} · {}",
        info.server_name.as_deref().unwrap_or("?"),
        info.version.as_deref().unwrap_or("?"),
        ms(t)
    );
}

async fn direct_login(http: &reqwest::Client, device: Device) -> AnyResult<Connected> {
    let server = env("OPENIPTV_EMBY_URL").ok_or("OPENIPTV_EMBY_URL missing")?;
    let mut emby = EmbyClient::new(http.clone(), &server, device)?;
    heading("Emby server");
    let (info, info_time) = timed(emby.public_info()).await;
    let info = info?;
    print_server(&info, info_time);
    let (session, login_time) = timed(emby.login(
        &env("OPENIPTV_EMBY_USER").ok_or("OPENIPTV_EMBY_USER missing")?,
        &env("OPENIPTV_EMBY_PASS").unwrap_or_default(),
    ))
    .await;
    session?;
    println!("  login              {}", ms(login_time));
    Ok(Connected {
        emby,
        info,
        info_time,
        login_time,
    })
}

/// Emby Connect account → linked server → server session, the same hops
/// the apps make for a shared server.
async fn connect_login(
    http: &reqwest::Client,
    device: Device,
    user: &str,
    out: &mut Map<String, Value>,
) -> AnyResult<Connected> {
    heading("Emby Connect");
    let connect = ConnectClient::new(http.clone(), &device.client, &device.version);
    let password = env("OPENIPTV_EMBY_CONNECT_PASS").unwrap_or_default();
    let (session, t_login) = timed(connect.login(user, &password)).await;
    let session = session?;
    println!("  account login      {}", ms(t_login));
    let (servers, t_servers) = timed(connect.servers(&session)).await;
    let servers = servers?;
    println!(
        "  linked servers     {} in {}: {}",
        servers.len(),
        ms(t_servers),
        servers
            .iter()
            .map(|s| s.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    let wanted = env("OPENIPTV_EMBY_SERVER");
    let server = match &wanted {
        Some(name) => servers.iter().find(|s| s.name.eq_ignore_ascii_case(name)),
        None => servers.first(),
    }
    .ok_or("no matching linked server (set OPENIPTV_EMBY_SERVER to a name above)")?;
    out.insert(
        "connect".into(),
        json!({ "login_ms": t_login.as_millis(), "servers": servers.len(), "servers_ms": t_servers.as_millis() }),
    );

    heading("Emby server");
    let mut last_error: Option<Box<dyn std::error::Error>> = None;
    for address in server.addresses() {
        let kind = if Some(address) == server.remote_address.as_deref() {
            "remote"
        } else {
            "local"
        };
        let mut emby = EmbyClient::new(http.clone(), address, device.clone())?;
        let (info, info_time) = timed(emby.public_info()).await;
        let info = match info {
            Ok(info) => info,
            Err(e) => {
                println!("  {kind} address     unreachable ({e})");
                last_error = Some(e.into());
                continue;
            }
        };
        print_server(&info, info_time);
        println!("  address            {kind}");
        let (exchanged, t_exchange) =
            timed(emby.exchange(&session.user_id, &server.access_key)).await;
        exchanged?;
        println!("  connect exchange   {}", ms(t_exchange));
        return Ok(Connected {
            emby,
            info,
            info_time,
            login_time: t_login + t_servers + t_exchange,
        });
    }
    Err(last_error.unwrap_or_else(|| "linked server has no address".into()))
}

async fn probe_emby_home(
    http: &reqwest::Client,
    emby: &EmbyClient,
    out: &mut Map<String, Value>,
) -> AnyResult<()> {
    heading("Home screen");
    let (views, t_views) = timed(emby.views()).await;
    let views = views?;
    println!(
        "  libraries          {} in {}: {}",
        views.len(),
        ms(t_views),
        views
            .iter()
            .map(|v| v.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    let (rows, t_home) = timed(async {
        tokio::join!(
            timed(emby.resume(12)),
            timed(emby.next_up(12)),
            timed(emby.latest(None, 16))
        )
    })
    .await;
    let ((resume, t_resume), (next_up, t_next_up), (latest, t_latest)) = rows;
    let (resume, next_up, latest) = (resume?, next_up?, latest?);
    println!(
        "  rows in parallel   {} until the slowest returned",
        ms(t_home)
    );
    println!(
        "    continue         {} items in {}",
        resume.len(),
        ms(t_resume)
    );
    println!(
        "    next up          {} items in {}",
        next_up.len(),
        ms(t_next_up)
    );
    println!(
        "    latest (all)     {} items in {}",
        latest.len(),
        ms(t_latest)
    );

    // Continue Watching is the slow row; time cheaper ways to ask for it,
    // one after another so they don't compete.
    let uid = emby
        .session()
        .map(|s| s.user_id.clone())
        .unwrap_or_default();
    let fields = "PrimaryImageAspectRatio,ProductionYear,BasicSyncInfo";
    let card = [
        ("Limit", "12"),
        ("Fields", fields),
        ("ImageTypeLimit", "1"),
        ("EnableImageTypes", "Primary,Backdrop,Thumb"),
    ];
    let resume_path = format!("Users/{uid}/Items/Resume");
    let items_path = format!("Users/{uid}/Items");
    let variants: [(&str, &str, Query); 3] = [
        (
            "resume, no total count",
            &resume_path,
            [
                &card[..],
                &[("MediaTypes", "Video"), ("EnableTotalRecordCount", "false")],
            ]
            .concat(),
        ),
        (
            "resume, no user data",
            &resume_path,
            [
                &card[..],
                &[
                    ("MediaTypes", "Video"),
                    ("EnableTotalRecordCount", "false"),
                    ("EnableUserData", "false"),
                ],
            ]
            .concat(),
        ),
        (
            "items filtered resumable",
            &items_path,
            [
                &card[..],
                &[
                    ("Filters", "IsResumable"),
                    ("Recursive", "true"),
                    ("SortBy", "DatePlayed"),
                    ("SortOrder", "Descending"),
                    ("IncludeItemTypes", "Movie,Episode"),
                    ("EnableTotalRecordCount", "false"),
                ],
            ]
            .concat(),
        ),
    ];
    let mut variant_times = Map::new();
    for (name, path, query) in variants {
        let (items, t) = timed(emby.query(path, &query, "continue watching")).await;
        match items {
            Ok(items) => println!("    {name:<26} {} items in {}", items.len(), ms(t)),
            Err(e) => println!("    {name:<26} ✗ {e}"),
        }
        variant_times.insert(name.into(), json!(t.as_millis()));
    }
    out.insert("resume_variants_ms".into(), Value::Object(variant_times));

    // The app shows "Latest" per library, like Emby does; time those too.
    let mut set = tokio::task::JoinSet::new();
    for lib in views
        .iter()
        .filter(|v| matches!(v.collection_type.as_deref(), Some("movies" | "tvshows")))
        .take(4)
    {
        let (emby, id, name) = (emby.clone(), lib.id.clone(), lib.name.clone());
        set.spawn(async move {
            let (items, t) = timed(emby.latest(Some(&id), 16)).await;
            (name, items.map(|i| i.len()), t)
        });
    }
    let mut per_library = Vec::new();
    while let Some(Ok(row)) = set.join_next().await {
        per_library.push(row);
    }
    per_library.sort_by(|a, b| a.0.cmp(&b.0));
    for (name, items, t) in &per_library {
        match items {
            Ok(n) => println!(
                "    latest in {:<17} {n} items in {}",
                truncate(name, 17),
                ms(*t)
            ),
            Err(e) => println!("    latest in {:<17} ✗ {e}", truncate(name, 17)),
        }
    }

    heading("Artwork (each row loaded the way the app will)");
    let rows = [
        ("continue watching", &resume, Context::Landscape),
        ("next up", &next_up, Context::Landscape),
        ("latest", &latest, Context::Poster),
    ];
    let (mut total, mut first, mut fallback, mut placeholder, mut with_ratio) = (0, 0, 0, 0, 0);
    let (mut image_times, mut image_bytes, mut cache_header) = (Vec::new(), 0usize, None);
    let (mut ttfbs, mut loaded_urls, mut http2) = (Vec::new(), Vec::new(), false);
    for (name, items, context) in rows {
        if items.is_empty() {
            continue;
        }
        let shape = artwork::list_shape(items, context);
        let width = if shape == Shape::Landscape { 480 } else { 360 };
        let mut set = tokio::task::JoinSet::new();
        for item in items.iter() {
            let urls = artwork::candidates(item, context)
                .iter()
                .map(|c| emby.image_url(&c.image, width, Some(shape)))
                .collect();
            set.spawn(load_first(http.clone(), urls));
        }
        let (mut row_first, mut row_fallback, mut row_none) = (0, 0, 0);
        while let Some(Ok(loaded)) = set.join_next().await {
            match loaded.used {
                Some(0) => row_first += 1,
                Some(_) => row_fallback += 1,
                None => row_none += 1,
            }
            if loaded.used.is_some() {
                image_times.push(loaded.elapsed);
                ttfbs.push(loaded.ttfb);
                image_bytes += loaded.bytes;
                http2 |= loaded.http2;
                cache_header = cache_header.or(loaded.cache_control);
                loaded_urls.extend(loaded.url);
            }
        }
        println!(
            "  {name:<18} {shape:?} cards: {row_first} first try · {row_fallback} via fallback · {row_none} placeholder"
        );
        total += items.len();
        first += row_first;
        fallback += row_fallback;
        placeholder += row_none;
        with_ratio += items
            .iter()
            .filter(|i| i.primary_image_aspect_ratio.is_some())
            .count();
    }
    println!(
        "  cover shown        {} of {total} cards ({fallback} only thanks to fallback, which Emby's web app lacks)",
        pct(first + fallback, total)
    );
    println!(
        "  aspect ratio sent  {} (lets the grid lay out before images load)",
        pct(with_ratio, total)
    );
    image_times.sort();
    ttfbs.sort();
    // Same URLs again: the server has now resized and cached them, so the
    // difference shows how much of the first load was server-side work.
    let mut set = tokio::task::JoinSet::new();
    for url in loaded_urls.iter().take(12).cloned() {
        set.spawn(load_first(http.clone(), vec![url]));
    }
    let mut warm = Vec::new();
    while let Some(Ok(loaded)) = set.join_next().await {
        if loaded.used.is_some() {
            warm.push(loaded.ttfb);
        }
    }
    warm.sort();
    if !image_times.is_empty() {
        println!(
            "  first load         p50 {} · max {} · avg {:.0} KB over {}",
            ms(percentile(&image_times, 0.5)),
            ms(*image_times.last().unwrap()),
            image_bytes as f64 / image_times.len() as f64 / 1024.0,
            if http2 { "HTTP/2" } else { "HTTP/1.1" }
        );
        println!(
            "  waiting on server  p50 {} before the first byte",
            ms(percentile(&ttfbs, 0.5))
        );
        println!(
            "  same images again  p50 {} before the first byte",
            ms(percentile(&warm, 0.5))
        );
        println!(
            "  cache-control      {}",
            cache_header
                .as_deref()
                .unwrap_or("(none: client must cache by tag)")
        );
    }

    out.insert(
        "home".into(),
        json!({
            "views_ms": t_views.as_millis(), "rows_parallel_ms": t_home.as_millis(),
            "resume_ms": t_resume.as_millis(), "next_up_ms": t_next_up.as_millis(), "latest_ms": t_latest.as_millis(),
            "latest_per_library_ms": per_library.iter().map(|(_, _, t)| t.as_millis()).collect::<Vec<_>>(),
            "resume": resume.len(), "next_up": next_up.len(), "latest": latest.len(),
        }),
    );
    out.insert(
        "artwork".into(),
        json!({
            "cards": total, "first_try": first, "via_fallback": fallback, "placeholder": placeholder,
            "with_aspect_ratio": with_ratio, "image_p50_ms": percentile(&image_times, 0.5).as_millis(),
            "image_ttfb_p50_ms": percentile(&ttfbs, 0.5).as_millis(), "image_warm_ttfb_p50_ms": percentile(&warm, 0.5).as_millis(),
            "http2": http2,
            "cache_control": cache_header,
        }),
    );
    Ok(())
}

struct Loaded {
    used: Option<usize>,
    url: Option<Url>,
    elapsed: Duration,
    /// Request start to response headers for the image that loaded.
    ttfb: Duration,
    http2: bool,
    bytes: usize,
    cache_control: Option<String>,
}

/// Try image candidates in order until one returns a real image, as the app does.
async fn load_first(http: reqwest::Client, urls: Vec<Url>) -> Loaded {
    let start = Instant::now();
    for (i, url) in urls.into_iter().enumerate() {
        let attempt = Instant::now();
        let Ok(res) = http.get(url.clone()).send().await else {
            continue;
        };
        let ttfb = attempt.elapsed();
        let http2 = res.version() == reqwest::Version::HTTP_2;
        let header = |name| {
            res.headers()
                .get(name)
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned)
        };
        let is_image =
            header(reqwest::header::CONTENT_TYPE).is_some_and(|t| t.starts_with("image/"));
        if !res.status().is_success() || !is_image {
            continue;
        }
        let cache_control = header(reqwest::header::CACHE_CONTROL);
        match res.bytes().await {
            Ok(body) if !body.is_empty() => {
                return Loaded {
                    used: Some(i),
                    url: Some(url),
                    elapsed: start.elapsed(),
                    ttfb,
                    http2,
                    bytes: body.len(),
                    cache_control,
                };
            }
            _ => continue,
        }
    }
    Loaded {
        used: None,
        url: None,
        elapsed: start.elapsed(),
        ttfb: Duration::ZERO,
        http2: false,
        bytes: 0,
        cache_control: None,
    }
}

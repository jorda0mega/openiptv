use openiptv_core::epg;
use openiptv_core::xtream::{self, Account, StreamFormat};

#[test]
fn channel_list_survives_mixed_types_and_bad_rows() {
    let channels = xtream::parse_channels(include_bytes!("fixtures/live_streams.json")).unwrap();
    let ids: Vec<i64> = channels.iter().map(|c| c.stream_id).collect();
    assert_eq!(ids, [101, 102, 104, 105], "row without id and non-object row dropped");

    let bbc = &channels[0];
    assert_eq!(bbc.epg_id.as_deref(), Some("BBCOne.uk"));
    assert_eq!(bbc.catchup_days, Some(7));
    assert_eq!(bbc.logo.as_deref(), Some("http://logos.example/bbc1.png"));

    let itv = &channels[1];
    assert_eq!(itv.name, "UK: ITV1");
    assert_eq!(itv.number, Some(2));
    assert_eq!(itv.category_id.as_deref(), Some("7"));
    assert_eq!(itv.epg_id, None);
    assert_eq!(itv.logo, None);
    assert_eq!(itv.catchup_days, None);

    let espn = &channels[2];
    assert_eq!(espn.epg_id, None, "empty string is no id");
    assert_eq!(espn.logo, None, "relative logo is unusable");
    assert_eq!(espn.catchup_days, Some(3));

    assert_eq!(channels[3].epg_id.as_deref(), Some("12345"));
}

#[test]
fn short_epg_prefers_timestamps_and_reports_panel_skew() {
    // Panel in UTC+1: wall clock 14:00 is 13:00 UTC = 1791637200.
    let listings = xtream::parse_short_epg(include_bytes!("fixtures/short_epg.json"), Some(3600)).unwrap();
    assert_eq!(listings.len(), 3);

    let first = &listings[0];
    assert_eq!(first.programme.title, "News at One");
    assert_eq!(first.programme.description.as_deref(), Some("The latest news."));
    assert_eq!(first.programme.start, 1_791_637_200);
    assert_eq!(first.wall_clock_skew, Some(0), "strings agree with timestamps");

    assert_eq!(listings[1].programme.title, "Plain Title");
    assert_eq!(listings[1].programme.description, None);

    let fallback = &listings[2];
    assert_eq!(fallback.programme.title, "No timestamps");
    assert_eq!(fallback.programme.start, 1_791_640_800, "wall clock shifted by panel offset");
    assert_eq!(fallback.wall_clock_skew, None);

    let programmes: Vec<_> = listings.into_iter().map(|l| l.programme).collect();
    let nn = epg::now_next(&programmes, 1_791_638_000);
    assert_eq!(nn.now.unwrap().title, "News at One");
    assert_eq!(nn.next.unwrap().title, "Plain Title");
    assert_eq!(nn.refresh_at, Some(1_791_639_000));
}

#[test]
fn account_formats_and_panel_offset() {
    let account: Account = serde_json::from_str(
        r#"{"user_info":{"auth":1,"status":"Active","exp_date":"1800000000","max_connections":"2","active_cons":"0","allowed_output_formats":["m3u8","ts"]},
            "server_info":{"url":"cdn.example","port":"80","timezone":"Europe/London","timestamp_now":1791637200,"time_now":"2026-10-10 14:00:03"}}"#,
    )
    .unwrap();
    assert!(account.user_info.auth);
    assert_eq!(account.user_info.max_connections, Some(2));
    assert!(account.supports(StreamFormat::Hls));
    assert_eq!(account.panel_utc_offset(), Some(3600));

    let ts_only: Account =
        serde_json::from_str(r#"{"user_info":{"auth":"1","allowed_output_formats":["ts"]},"server_info":{}}"#).unwrap();
    assert!(!ts_only.supports(StreamFormat::Hls));
    assert_eq!(ts_only.panel_utc_offset(), None);
}

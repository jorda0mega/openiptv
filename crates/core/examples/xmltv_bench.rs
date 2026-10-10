//! Parse a synthetic provider-sized XMLTV guide and report throughput.
//! `cargo run --release -p openiptv-core --example xmltv_bench -- 3000 7`
//! (channels, days of 30-minute programmes).

use std::fmt::Write;
use std::time::Instant;

fn main() {
    let mut args = std::env::args()
        .skip(1)
        .map(|a| a.parse::<usize>().expect("number"));
    let channels = args.next().unwrap_or(3000);
    let days = args.next().unwrap_or(7);
    let per_channel = days * 48;

    let mut xml = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n");
    for c in 0..channels {
        writeln!(
            xml,
            r#"<channel id="ch{c}.example"><display-name>Channel {c}</display-name></channel>"#
        )
        .unwrap();
    }
    let base = 1_791_590_400i64;
    for c in 0..channels {
        for p in 0..per_channel {
            let (s, e) = (base + p as i64 * 1800, base + (p as i64 + 1) * 1800);
            let fmt = |t: i64| {
                let d = t / 86_400 - 20_736; // days since 2026-10-10 (base date)
                let r = t % 86_400;
                format!(
                    "202610{:02}{:02}{:02}00 +0000",
                    10 + d,
                    r / 3600,
                    r % 3600 / 60
                )
            };
            writeln!(
                xml,
                r#"<programme start="{}" stop="{}" channel="ch{c}.example"><title lang="en">Programme {p} &amp; more</title><desc lang="en">A fairly typical one-line description of what happens in this episode.</desc></programme>"#,
                fmt(s),
                fmt(e)
            )
            .unwrap();
        }
    }
    xml.push_str("</tv>\n");

    let start = Instant::now();
    let guide = openiptv_core::xmltv::parse(xml.as_bytes(), |_| true).expect("valid");
    let elapsed = start.elapsed();
    let mb = xml.len() as f64 / 1e6;
    println!(
        "{mb:.0} MB, {} channels, {} programmes parsed in {} ms ({:.0} MB/s)",
        guide.programmes.len(),
        guide.programme_count(),
        elapsed.as_millis(),
        mb / elapsed.as_secs_f64()
    );
    let lookup = Instant::now();
    let mut hits = 0;
    for c in 0..channels {
        hits += guide
            .now_next(&format!("ch{c}.example"), base + 86_400)
            .now
            .is_some() as usize;
    }
    println!(
        "now/next for all {channels} channels in {} µs ({hits} hits)",
        lookup.elapsed().as_micros()
    );
}

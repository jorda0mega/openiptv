//! Dependency-free timestamp parsing. EPG data is parsed in bulk (hundreds of
//! thousands of programmes), so this avoids allocation and calendar libraries.

/// Unix seconds.
pub type Timestamp = i64;

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = month as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn digits(s: &[u8]) -> Option<i64> {
    if s.is_empty() || !s.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(s.iter().fold(0i64, |acc, d| acc * 10 + i64::from(d - b'0')))
}

fn civil_to_unix(y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64) -> Option<Timestamp> {
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || s > 60 {
        return None;
    }
    Some(days_from_civil(y, mo as u32, d as u32) * 86_400 + h * 3_600 + mi * 60 + s)
}

/// XMLTV time: `YYYYMMDDhhmm[ss] [+-hhmm]`. A missing offset means UTC.
pub fn parse_xmltv(s: &[u8]) -> Option<Timestamp> {
    let s = s.trim_ascii();
    let n = s.iter().take_while(|b| b.is_ascii_digit()).count();
    if n < 12 {
        return None;
    }
    let (y, mo, d) = (digits(&s[0..4])?, digits(&s[4..6])?, digits(&s[6..8])?);
    let (h, mi) = (digits(&s[8..10])?, digits(&s[10..12])?);
    let sec = if n >= 14 { digits(&s[12..14])? } else { 0 };
    let local = civil_to_unix(y, mo, d, h, mi, sec)?;
    Some(local - parse_offset(s[n..].trim_ascii()).unwrap_or(0))
}

/// `+hhmm` / `-hhmm` / `+hh:mm` → seconds east of UTC.
fn parse_offset(s: &[u8]) -> Option<i64> {
    let (sign, rest) = match s.first()? {
        b'+' => (1, &s[1..]),
        b'-' => (-1, &s[1..]),
        _ => return None,
    };
    let rest: Vec<u8> = rest.iter().copied().filter(|b| *b != b':').collect();
    if rest.len() < 4 {
        return None;
    }
    Some(sign * (digits(&rest[0..2])? * 3_600 + digits(&rest[2..4])? * 60))
}

/// `YYYY-MM-DD hh:mm:ss` read as if it were UTC. Xtream sends wall-clock
/// strings in the panel's timezone; subtract the panel's UTC offset afterwards.
pub fn parse_wall_clock(s: &str) -> Option<Timestamp> {
    let b = s.trim().as_bytes();
    if b.len() < 16 || b[4] != b'-' || b[7] != b'-' || b[13] != b':' {
        return None;
    }
    let sec = if b.len() >= 19 {
        digits(&b[17..19])?
    } else {
        0
    };
    civil_to_unix(
        digits(&b[0..4])?,
        digits(&b[5..7])?,
        digits(&b[8..10])?,
        digits(&b[11..13])?,
        digits(&b[14..16])?,
        sec,
    )
}

pub fn now() -> Timestamp {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xmltv_times() {
        assert_eq!(parse_xmltv(b"19700101000000 +0000"), Some(0));
        assert_eq!(parse_xmltv(b"20261010120000 +0100"), Some(1_791_630_000));
        assert_eq!(parse_xmltv(b"20261010110000"), Some(1_791_630_000));
        assert_eq!(parse_xmltv(b"202610101100 +0000"), Some(1_791_630_000));
        assert_eq!(parse_xmltv(b"20261010063000 -0430"), Some(1_791_630_000));
        assert_eq!(parse_xmltv(b"garbage"), None);
    }

    #[test]
    fn wall_clock() {
        assert_eq!(parse_wall_clock("2026-10-10 11:00:00"), Some(1_791_630_000));
        assert_eq!(parse_wall_clock("2026-10-10 11:00"), Some(1_791_630_000));
        assert_eq!(parse_wall_clock("10/10/2026"), None);
    }
}

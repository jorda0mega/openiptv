//! "What is on right now" — the logic behind live TV titles.
//!
//! Stale titles in IPTV apps come from three places: wall-clock strings parsed
//! in the wrong timezone, guide data cached past a programme boundary, and no
//! refresh when the programme changes while you watch. This module only deals
//! in UTC timestamps and always reports the exact moment the answer changes
//! (`refresh_at`), so clients can schedule one timer instead of polling.

use crate::time::Timestamp;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Programme {
    pub start: Timestamp,
    pub stop: Timestamp,
    pub title: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NowNext {
    pub now: Option<Programme>,
    pub next: Option<Programme>,
    /// When `now`/`next` stop being correct. `None` means no guide data ahead.
    pub refresh_at: Option<Timestamp>,
}

impl NowNext {
    fn from_refs(now: Option<&Programme>, next: Option<&Programme>) -> Self {
        let refresh_at = match (now, next) {
            (Some(c), Some(n)) => Some(c.stop.min(n.start)),
            (Some(c), None) => Some(c.stop),
            (None, Some(n)) => Some(n.start),
            (None, None) => None,
        };
        NowNext {
            now: now.cloned(),
            next: next.cloned(),
            refresh_at,
        }
    }
}

/// Now/next from an arbitrary (unsorted, possibly overlapping) list.
/// On overlap the programme that started most recently wins.
pub fn now_next(programmes: &[Programme], at: Timestamp) -> NowNext {
    let mut current: Option<&Programme> = None;
    let mut upcoming: Option<&Programme> = None;
    for p in programmes.iter().filter(|p| p.stop > p.start) {
        if p.start <= at && at < p.stop {
            if current.is_none_or(|c| p.start > c.start) {
                current = Some(p);
            }
        } else if p.start > at && upcoming.is_none_or(|u| p.start < u.start) {
            upcoming = Some(p);
        }
    }
    NowNext::from_refs(current, upcoming)
}

/// Now/next from a list sorted by `start` (as produced by [`sort_and_dedupe`]).
/// O(log n), which matters when rendering a full guide on a Fire TV stick.
pub fn now_next_sorted(programmes: &[Programme], at: Timestamp) -> NowNext {
    let i = programmes.partition_point(|p| p.start <= at);
    let current = i
        .checked_sub(1)
        .map(|j| &programmes[j])
        .filter(|p| at < p.stop);
    NowNext::from_refs(current, programmes.get(i))
}

/// Sort by start and drop exact duplicates and zero-length entries, which
/// several providers emit when merging guide sources.
pub fn sort_and_dedupe(programmes: &mut Vec<Programme>) {
    programmes.retain(|p| p.stop > p.start);
    programmes.sort_unstable_by_key(|a| (a.start, a.stop));
    programmes.dedup_by(|b, a| a.start == b.start && a.stop == b.stop && a.title == b.title);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(start: i64, stop: i64, title: &str) -> Programme {
        Programme {
            start,
            stop,
            title: title.into(),
            description: None,
        }
    }

    #[test]
    fn picks_current_and_next_and_boundary() {
        let list = vec![p(200, 300, "C"), p(0, 100, "A"), p(100, 200, "B")];
        let nn = now_next(&list, 150);
        assert_eq!(nn.now.unwrap().title, "B");
        assert_eq!(nn.next.unwrap().title, "C");
        assert_eq!(nn.refresh_at, Some(200));
    }

    #[test]
    fn boundary_belongs_to_the_new_programme() {
        let list = vec![p(0, 100, "A"), p(100, 200, "B")];
        assert_eq!(now_next(&list, 100).now.unwrap().title, "B");
    }

    #[test]
    fn gap_in_guide() {
        let list = vec![p(0, 100, "A"), p(150, 200, "B")];
        let nn = now_next(&list, 120);
        assert!(nn.now.is_none());
        assert_eq!(nn.next.unwrap().title, "B");
        assert_eq!(nn.refresh_at, Some(150));
    }

    #[test]
    fn overlap_prefers_latest_start() {
        let list = vec![p(0, 200, "Long"), p(100, 150, "Insert")];
        assert_eq!(now_next(&list, 120).now.unwrap().title, "Insert");
    }

    #[test]
    fn sorted_matches_unsorted() {
        let mut list = vec![
            p(200, 300, "C"),
            p(0, 100, "A"),
            p(100, 200, "B"),
            p(100, 200, "B"),
            p(50, 50, "zero"),
            p(400, 500, "E"),
        ];
        let raw = list.clone();
        sort_and_dedupe(&mut list);
        assert_eq!(list.len(), 4);
        for at in [-10, 0, 99, 100, 250, 350, 450, 600] {
            assert_eq!(now_next_sorted(&list, at), now_next(&raw, at), "at {at}");
        }
    }
}

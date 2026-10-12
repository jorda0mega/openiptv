//! Which image to show for an Emby item, and what to try next if it fails.
//!
//! The order follows Emby's own web client (docs/emby-client-behavior.md §2)
//! with one deliberate change: every usable candidate is returned, not just
//! the first. Emby's client has no load-error fallback, so a stale or missing
//! image leaves a blank card; clients here move to the next candidate instead.

use crate::emby::{ImageRef, Item};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Context {
    /// Poster or auto-shaped cards: library grids, "Latest" rows.
    Poster,
    /// 16:9 cards where a series' thumb or backdrop beats the episode still:
    /// Continue Watching, Next Up.
    Landscape,
    /// 16:9 cards for a show's own episode list: each episode's still (a
    /// frame from it) when it's wide, then the series' art as `Landscape`.
    Still,
    /// Full-width hero or page background.
    Backdrop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    Portrait,
    Square,
    FourThree,
    Landscape,
}

impl Shape {
    pub fn aspect(self) -> f64 {
        match self {
            Shape::Portrait => 2.0 / 3.0,
            Shape::Square => 1.0,
            Shape::FourThree => 4.0 / 3.0,
            Shape::Landscape => 16.0 / 9.0,
        }
    }

    fn from_ratio(ratio: f64) -> Shape {
        match ratio {
            r if r >= 1.5556 => Shape::Landscape,
            r if r >= 1.1333 => Shape::FourThree,
            r if r >= 0.8333 => Shape::Square,
            _ => Shape::Portrait,
        }
    }

    fn for_kind(kind: &str) -> Shape {
        match kind {
            "Movie" | "Series" | "Season" | "BoxSet" | "Trailer" => Shape::Portrait,
            "Episode" | "Video" | "Program" | "TvChannel" | "Recording" | "MusicVideo" => {
                Shape::Landscape
            }
            _ => Shape::Square,
        }
    }
}

/// Card shape for a whole row or grid, decided before any image loads so the
/// layout never jumps: the most common snapped `PrimaryImageAspectRatio`,
/// else the first item's type.
pub fn list_shape(items: &[Item], context: Context) -> Shape {
    if context != Context::Poster {
        return Shape::Landscape;
    }
    let order = [
        Shape::Portrait,
        Shape::Square,
        Shape::FourThree,
        Shape::Landscape,
    ];
    let mut counts = [0usize; 4];
    for ratio in items.iter().filter_map(|i| i.primary_image_aspect_ratio) {
        if ratio > 0.0 {
            counts[Shape::from_ratio(ratio) as usize] += 1;
        }
    }
    let (best, count) = counts
        .iter()
        .enumerate()
        .fold((0, 0), |acc, (i, &c)| if c > acc.1 { (i, c) } else { acc });
    if count > 0 {
        return order[best];
    }
    items
        .first()
        .map_or(Shape::Portrait, |i| Shape::for_kind(&i.kind))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fit {
    /// Fill the card, cropping the edges.
    Cover,
    /// Show the whole image, letterboxed.
    Contain,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub image: ImageRef,
    /// Expected width / height of this image.
    pub aspect: f64,
    /// Logos and channel art must never be cropped.
    letterbox: bool,
}

impl Candidate {
    /// Crop only when the image is close to the card's shape; a 16:9 still
    /// in a poster slot is letterboxed rather than butchered.
    pub fn fit(&self, card: Shape) -> Fit {
        if self.letterbox || (self.aspect - card.aspect()).abs() > 0.28 {
            Fit::Contain
        } else {
            Fit::Cover
        }
    }
}

/// Ordered image candidates for `item`; render the first that loads.
/// Empty means show a placeholder (icon + title).
pub fn candidates(item: &Item, context: Context) -> Vec<Candidate> {
    let mut chain = Chain {
        item,
        out: Vec::with_capacity(6),
    };
    match context {
        Context::Poster => chain.poster(),
        Context::Landscape | Context::Still => {
            if context == Context::Still
                && item.primary_image_aspect_ratio.unwrap_or(Shape::Landscape.aspect()) >= 1.2
            {
                chain.own_primary();
            }
            chain.own_thumb();
            if item.kind != "Photo" {
                chain.parent_thumb();
            }
            chain.own_backdrop();
            if item.kind == "Episode" {
                chain.parent_backdrop();
            }
            chain.own_primary();
            chain.poster();
        }
        Context::Backdrop => {
            chain.own_backdrop();
            chain.parent_backdrop();
            chain.own_thumb();
            chain.parent_thumb();
            chain.poster();
        }
    }
    chain.out
}

struct Chain<'a> {
    item: &'a Item,
    out: Vec<Candidate>,
}

impl Chain<'_> {
    /// Emby's default order for poster/auto cards.
    fn poster(&mut self) {
        self.own_primary();
        self.album_primary();
        self.parent_primary();
        self.series_primary();
        if self.item.kind == "Season" {
            self.own_thumb();
        }
        self.channel_primary();
        self.own_backdrop();
        self.own_thumb();
        self.parent_thumb();
        self.parent_backdrop();
    }

    fn push(
        &mut self,
        item_id: Option<&str>,
        image_type: &'static str,
        tag: Option<&str>,
        index: Option<u32>,
        aspect: f64,
        letterbox: bool,
    ) {
        let (Some(item_id), Some(tag)) = (
            item_id.filter(|s| !s.is_empty()),
            tag.filter(|s| !s.is_empty()),
        ) else {
            return;
        };
        let duplicate = self.out.iter().any(|c| {
            c.image.item_id == item_id && c.image.image_type == image_type && c.image.index == index
        });
        if !duplicate {
            self.out.push(Candidate {
                image: ImageRef {
                    item_id: item_id.to_owned(),
                    image_type,
                    tag: tag.to_owned(),
                    index,
                },
                aspect,
                letterbox,
            });
        }
    }

    fn own_primary(&mut self) {
        let i = self.item;
        let aspect = i
            .primary_image_aspect_ratio
            .filter(|r| *r > 0.0)
            .unwrap_or_else(|| Shape::for_kind(&i.kind).aspect());
        let tag = i.image_tags.get("Primary").map(String::as_str);
        let letterbox = i.kind == "TvChannel";
        self.push(Some(&i.id), "Primary", tag, None, aspect, letterbox);
    }

    fn own_thumb(&mut self) {
        let i = self.item;
        let tag = i.image_tags.get("Thumb").map(String::as_str);
        self.push(Some(&i.id), "Thumb", tag, None, 16.0 / 9.0, false);
    }

    fn own_backdrop(&mut self) {
        let i = self.item;
        let tag = i.backdrop_image_tags.first().map(String::as_str);
        self.push(Some(&i.id), "Backdrop", tag, Some(0), 16.0 / 9.0, false);
    }

    fn parent_thumb(&mut self) {
        let i = self.item;
        let (id, tag) = (
            i.parent_thumb_item_id.as_deref(),
            i.parent_thumb_image_tag.as_deref(),
        );
        self.push(id, "Thumb", tag, None, 16.0 / 9.0, false);
    }

    fn parent_backdrop(&mut self) {
        let i = self.item;
        let tag = i.parent_backdrop_image_tags.first().map(String::as_str);
        self.push(
            i.parent_backdrop_item_id.as_deref(),
            "Backdrop",
            tag,
            Some(0),
            16.0 / 9.0,
            false,
        );
    }

    fn parent_primary(&mut self) {
        let i = self.item;
        let aspect = if i.kind == "Episode" { 2.0 / 3.0 } else { 1.0 };
        self.push(
            i.parent_primary_image_item_id.as_deref(),
            "Primary",
            i.parent_primary_image_tag.as_deref(),
            None,
            aspect,
            false,
        );
    }

    fn series_primary(&mut self) {
        let i = self.item;
        self.push(
            i.series_id.as_deref(),
            "Primary",
            i.series_primary_image_tag.as_deref(),
            None,
            2.0 / 3.0,
            false,
        );
    }

    fn album_primary(&mut self) {
        let i = self.item;
        self.push(
            i.album_id.as_deref(),
            "Primary",
            i.album_primary_image_tag.as_deref(),
            None,
            1.0,
            false,
        );
    }

    fn channel_primary(&mut self) {
        let i = self.item;
        self.push(
            i.channel_id.as_deref(),
            "Primary",
            i.channel_primary_image_tag.as_deref(),
            None,
            16.0 / 9.0,
            true,
        );
    }
}

/// Requested widths snap to a fixed ladder so the same card at slightly
/// different sizes reuses one cached image.
const WIDTH_LADDER: [u32; 13] = [
    120, 160, 240, 320, 400, 480, 640, 720, 960, 1280, 1920, 2560, 3840,
];

pub fn bucket_width(px: u32) -> u32 {
    WIDTH_LADDER
        .iter()
        .copied()
        .find(|w| *w >= px)
        .unwrap_or(3840)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn episode() -> Item {
        Item {
            id: "ep".into(),
            kind: "Episode".into(),
            image_tags: HashMap::from([("Primary".into(), "still".into())]),
            primary_image_aspect_ratio: Some(1.7778),
            series_id: Some("series".into()),
            series_primary_image_tag: Some("poster".into()),
            parent_thumb_item_id: Some("series".into()),
            parent_thumb_image_tag: Some("sthumb".into()),
            parent_backdrop_item_id: Some("series".into()),
            parent_backdrop_image_tags: vec!["sback".into()],
            parent_primary_image_item_id: Some("season".into()),
            parent_primary_image_tag: Some("seasonposter".into()),
            ..Item::default()
        }
    }

    fn tags(list: &[Candidate]) -> Vec<&str> {
        list.iter().map(|c| c.image.tag.as_str()).collect()
    }

    #[test]
    fn episode_poster_order() {
        let c = candidates(&episode(), Context::Poster);
        assert_eq!(
            tags(&c),
            ["still", "seasonposter", "poster", "sthumb", "sback"]
        );
    }

    #[test]
    fn continue_watching_prefers_series_art_over_the_still() {
        let c = candidates(&episode(), Context::Landscape);
        assert_eq!(
            tags(&c),
            ["sthumb", "sback", "still", "seasonposter", "poster"]
        );
        assert_eq!(c[0].image.item_id, "series");
        assert_eq!(c[0].fit(Shape::Landscape), Fit::Cover);
    }

    #[test]
    fn episode_list_shows_the_episode_still_first() {
        let c = candidates(&episode(), Context::Still);
        assert_eq!(
            tags(&c),
            ["still", "sthumb", "sback", "seasonposter", "poster"]
        );
        assert_eq!(c[0].image.item_id, "ep");
        assert_eq!(c[0].fit(Shape::Landscape), Fit::Cover);
        // No still (or a portrait one): the series' wide art, as Landscape.
        let mut item = episode();
        item.image_tags.clear();
        assert_eq!(
            tags(&candidates(&item, Context::Still)),
            ["sthumb", "sback", "seasonposter", "poster"]
        );
    }

    #[test]
    fn episode_without_own_art_still_has_covers() {
        let mut item = episode();
        item.image_tags.clear();
        item.parent_primary_image_tag = None;
        let c = candidates(&item, Context::Poster);
        assert_eq!(tags(&c), ["poster", "sthumb", "sback"]);
        assert_eq!(c[0].fit(Shape::Portrait), Fit::Cover);
    }

    #[test]
    fn audio_falls_back_to_album_and_channels_letterbox() {
        let audio = Item {
            id: "a".into(),
            kind: "Audio".into(),
            album_id: Some("alb".into()),
            album_primary_image_tag: Some("cover".into()),
            ..Item::default()
        };
        assert_eq!(tags(&candidates(&audio, Context::Poster)), ["cover"]);

        let program = Item {
            id: "p".into(),
            kind: "Program".into(),
            channel_id: Some("ch".into()),
            channel_primary_image_tag: Some("logo".into()),
            ..Item::default()
        };
        let c = candidates(&program, Context::Poster);
        assert_eq!(c[0].fit(Shape::Landscape), Fit::Contain);
    }

    #[test]
    fn nothing_usable_means_placeholder() {
        let bare = Item {
            id: "x".into(),
            kind: "Movie".into(),
            image_tags: HashMap::from([("Primary".into(), String::new())]),
            ..Item::default()
        };
        assert!(candidates(&bare, Context::Poster).is_empty());
    }

    #[test]
    fn list_shape_uses_majority_ratio_then_type() {
        let item = |kind: &str, ratio: Option<f64>| Item {
            kind: kind.into(),
            primary_image_aspect_ratio: ratio,
            ..Item::default()
        };
        let posters = [
            item("Movie", Some(0.667)),
            item("Movie", Some(0.68)),
            item("Episode", Some(1.78)),
        ];
        assert_eq!(list_shape(&posters, Context::Poster), Shape::Portrait);
        assert_eq!(list_shape(&posters, Context::Landscape), Shape::Landscape);
        assert_eq!(
            list_shape(&[item("Episode", None)], Context::Poster),
            Shape::Landscape
        );
        assert_eq!(
            list_shape(&[item("MusicAlbum", None)], Context::Poster),
            Shape::Square
        );
        assert_eq!(list_shape(&[], Context::Poster), Shape::Portrait);
    }

    #[test]
    fn widths_snap_to_ladder() {
        assert_eq!(bucket_width(1), 120);
        assert_eq!(bucket_width(300), 320);
        assert_eq!(bucket_width(320), 320);
        assert_eq!(bucket_width(10_000), 3840);
    }
}

//! Emby client: login, home rows and image URLs.
//!
//! Home-row requests ask only for the fields the UI renders; Emby's default
//! item payload is several KB per item, which dominates time-to-first-paint on
//! slow servers.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use url::Url;

use crate::artwork::{self, Shape};
use crate::{Error, Result, http};

/// Fields every card needs: aspect ratio up front so the grid never reflows,
/// plus the parent/series image tags used for artwork fallbacks.
const CARD_FIELDS: &str = "PrimaryImageAspectRatio,ProductionYear,BasicSyncInfo";
const CARD_IMAGE_TYPES: &str = "Primary,Backdrop,Thumb";

#[derive(Debug, Clone)]
pub struct Device {
    pub client: String,
    pub name: String,
    pub id: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Session {
    pub user_id: String,
    pub access_token: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct PublicInfo {
    #[serde(default)]
    pub server_name: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub id: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct UserData {
    pub playback_position_ticks: Option<i64>,
    pub played_percentage: Option<f64>,
    pub played: bool,
    pub is_favorite: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Item {
    pub id: String,
    pub name: String,
    #[serde(rename = "Type")]
    pub kind: String,
    pub collection_type: Option<String>,
    pub series_name: Option<String>,
    pub series_id: Option<String>,
    pub season_id: Option<String>,
    pub parent_index_number: Option<i32>,
    pub index_number: Option<i32>,
    pub production_year: Option<i32>,
    pub run_time_ticks: Option<i64>,
    pub primary_image_aspect_ratio: Option<f64>,
    pub image_tags: HashMap<String, String>,
    pub backdrop_image_tags: Vec<String>,
    pub series_primary_image_tag: Option<String>,
    pub parent_thumb_item_id: Option<String>,
    pub parent_thumb_image_tag: Option<String>,
    pub parent_backdrop_item_id: Option<String>,
    pub parent_backdrop_image_tags: Vec<String>,
    pub parent_logo_item_id: Option<String>,
    pub parent_logo_image_tag: Option<String>,
    pub parent_primary_image_item_id: Option<String>,
    pub parent_primary_image_tag: Option<String>,
    pub album_id: Option<String>,
    pub album_primary_image_tag: Option<String>,
    pub channel_id: Option<String>,
    pub channel_primary_image_tag: Option<String>,
    pub user_data: Option<UserData>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ItemsPage {
    #[serde(default)]
    items: Vec<Item>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct AuthResult {
    access_token: String,
    user: AuthUser,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct AuthUser {
    id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ExchangeResult {
    local_user_id: String,
    access_token: String,
}

/// Image tags change whenever the artwork changes, so a URL that includes
/// the tag can be cached forever by the client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageRef {
    pub item_id: String,
    pub image_type: &'static str,
    pub tag: String,
    pub index: Option<u32>,
}

#[derive(Clone)]
pub struct EmbyClient {
    http: reqwest::Client,
    base: Url,
    device: Device,
    session: Option<Session>,
}

impl EmbyClient {
    /// `server` may be given with or without the `/emby` prefix.
    pub fn new(
        http: reqwest::Client,
        server: &str,
        device: Device,
    ) -> std::result::Result<Self, url::ParseError> {
        let mut base = Url::parse(server.trim())?;
        let path = base.path().trim_end_matches('/').to_owned();
        let path = if path.ends_with("/emby") {
            format!("{path}/")
        } else {
            format!("{path}/emby/")
        };
        base.set_path(&path);
        base.set_query(None);
        Ok(EmbyClient {
            http,
            base,
            device,
            session: None,
        })
    }

    pub fn with_session(mut self, session: Session) -> Self {
        self.session = Some(session);
        self
    }

    pub fn session(&self) -> Option<&Session> {
        self.session.as_ref()
    }

    fn url(&self, path: &str) -> Url {
        self.base.join(path).expect("relative path")
    }

    fn authorization(&self) -> String {
        let d = &self.device;
        let user = self.session.as_ref().map_or("", |s| s.user_id.as_str());
        format!(
            r#"Emby UserId="{user}", Client="{}", Device="{}", DeviceId="{}", Version="{}""#,
            d.client, d.name, d.id, d.version
        )
    }

    fn get(&self, url: Url) -> reqwest::RequestBuilder {
        let mut req = self
            .http
            .get(url)
            .header("X-Emby-Authorization", self.authorization())
            .header(reqwest::header::ACCEPT, "application/json");
        if let Some(s) = &self.session {
            req = req.header("X-Emby-Token", &s.access_token);
        }
        req
    }

    fn user_id(&self) -> Result<&str> {
        self.session
            .as_ref()
            .map(|s| s.user_id.as_str())
            .ok_or(Error::NoSession)
    }

    pub async fn public_info(&self) -> Result<PublicInfo> {
        let body = http::fetch(self.get(self.url("System/Info/Public")), "server info").await?;
        http::decode(&body, "server info")
    }

    pub async fn login(&mut self, username: &str, password: &str) -> Result<Session> {
        let req = self
            .http
            .post(self.url("Users/AuthenticateByName"))
            .header("X-Emby-Authorization", self.authorization())
            .header(reqwest::header::ACCEPT, "application/json")
            .form(&[("Username", username), ("Pw", password)]);
        let body = http::fetch(req, "login").await?;
        let auth: AuthResult = http::decode(&body, "login")?;
        let session = Session {
            user_id: auth.user.id,
            access_token: auth.access_token,
        };
        self.session = Some(session.clone());
        Ok(session)
    }

    /// Trade an Emby Connect server access key for a normal session as the
    /// Connect user's linked local account.
    pub async fn exchange(&mut self, connect_user_id: &str, access_key: &str) -> Result<Session> {
        let mut url = self.url("Connect/Exchange");
        url.query_pairs_mut()
            .append_pair("format", "json")
            .append_pair("ConnectUserId", connect_user_id);
        let req = self.get(url).header("X-Emby-Token", access_key);
        let body = http::fetch(req, "Connect exchange").await?;
        let auth: ExchangeResult = http::decode(&body, "Connect exchange")?;
        let session = Session {
            user_id: auth.local_user_id,
            access_token: auth.access_token,
        };
        self.session = Some(session.clone());
        Ok(session)
    }

    /// End the session so the access token stops working server-side.
    pub async fn logout(&mut self) -> Result<()> {
        let Some(session) = self.session.take() else {
            return Ok(());
        };
        let req = self
            .http
            .post(self.url("Sessions/Logout"))
            .header("X-Emby-Authorization", self.authorization())
            .header("X-Emby-Token", &session.access_token);
        http::fetch(req, "logout").await.map(|_| ())
    }

    /// Any item-list endpoint; returns the items whether the server answers
    /// with a bare array or an `{ Items: [...] }` page.
    pub async fn query(
        &self,
        path: &str,
        query: &[(&str, &str)],
        what: &'static str,
    ) -> Result<Vec<Item>> {
        let mut url = self.url(path);
        url.query_pairs_mut().extend_pairs(query);
        let body = http::fetch(self.get(url), what).await?;
        // Some endpoints return a bare array, others an `{ Items: [...] }` page.
        if body.first() == Some(&b'[') {
            http::decode(&body, what)
        } else {
            Ok(http::decode::<ItemsPage>(&body, what)?.items)
        }
    }

    /// The user's libraries (Movies, TV Shows, …).
    pub async fn views(&self) -> Result<Vec<Item>> {
        let path = format!("Users/{}/Views", self.user_id()?);
        self.query(&path, &[], "libraries").await
    }

    /// Continue Watching. Asks the item index for resumable items instead of
    /// `Items/Resume`: same 12 items on a real 4.9 server, but 846 ms instead
    /// of 2.1 s, because `Resume` slows down as libraries grow.
    pub async fn resume(&self, limit: u32) -> Result<Vec<Item>> {
        let path = format!("Users/{}/Items", self.user_id()?);
        let limit = limit.to_string();
        let filter = [
            ("Filters", "IsResumable"),
            ("Recursive", "true"),
            ("SortBy", "DatePlayed"),
            ("SortOrder", "Descending"),
            ("IncludeItemTypes", "Movie,Episode"),
        ];
        self.query(&path, &card_query(&limit, &filter), "continue watching")
            .await
    }

    pub async fn next_up(&self, limit: u32) -> Result<Vec<Item>> {
        let user = self.user_id()?.to_owned();
        let limit = limit.to_string();
        self.query(
            "Shows/NextUp",
            &card_query(&limit, &[("UserId", &user)]),
            "next up",
        )
        .await
    }

    /// Recently added, optionally within one library.
    pub async fn latest(&self, parent_id: Option<&str>, limit: u32) -> Result<Vec<Item>> {
        let path = format!("Users/{}/Items/Latest", self.user_id()?);
        let limit = limit.to_string();
        let extra: Vec<(&str, &str)> = parent_id.map(|p| ("ParentId", p)).into_iter().collect();
        self.query(&path, &card_query(&limit, &extra), "latest")
            .await
    }

    /// A sized image URL. Pass the rendered width × screen scale; it is
    /// snapped to a fixed ladder so nearby sizes share one cached image.
    /// Primary images also get a height bound from the card shape so the
    /// server returns art that fits the box. No token is needed.
    pub fn image_url(&self, image: &ImageRef, width_px: u32, card: Option<Shape>) -> Url {
        let path = match image.index {
            Some(i) => format!("Items/{}/Images/{}/{i}", image.item_id, image.image_type),
            None => format!("Items/{}/Images/{}", image.item_id, image.image_type),
        };
        let width = artwork::bucket_width(width_px);
        let mut url = self.url(&path);
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("tag", &image.tag)
                .append_pair("maxWidth", &width.to_string());
            if let (Some(shape), "Primary") = (card, image.image_type) {
                let height = (f64::from(width) / shape.aspect()).round() as u32;
                q.append_pair("maxHeight", &height.to_string());
            }
            let quality = if image.image_type == "Backdrop" {
                "70"
            } else {
                "90"
            };
            q.append_pair("quality", quality);
        }
        url
    }
}

fn card_query<'a>(limit: &'a str, extra: &[(&'a str, &'a str)]) -> Vec<(&'a str, &'a str)> {
    let mut q = vec![
        ("Limit", limit),
        ("Fields", CARD_FIELDS),
        ("ImageTypeLimit", "1"),
        ("EnableImageTypes", CARD_IMAGE_TYPES),
        ("EnableUserData", "true"),
        // Totals cost the server a full count; rows never show them.
        ("EnableTotalRecordCount", "false"),
    ];
    q.extend_from_slice(extra);
    q
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device() -> Device {
        Device {
            client: "OpenIPTV".into(),
            name: "Test".into(),
            id: "dev-1".into(),
            version: "0.1.0".into(),
        }
    }

    #[test]
    fn normalises_base_path() {
        for server in [
            "http://nas:8096",
            "http://nas:8096/",
            "http://nas:8096/emby",
            "http://nas:8096/emby/",
        ] {
            let c = EmbyClient::new(reqwest::Client::new(), server, device()).unwrap();
            assert_eq!(
                c.url("System/Info/Public").as_str(),
                "http://nas:8096/emby/System/Info/Public",
                "{server}"
            );
        }
        let proxied = EmbyClient::new(
            reqwest::Client::new(),
            "https://example.com/media",
            device(),
        )
        .unwrap();
        assert_eq!(
            proxied.url("Users/x/Views").as_str(),
            "https://example.com/media/emby/Users/x/Views"
        );
    }

    #[test]
    fn image_urls_include_tag_and_size() {
        let c = EmbyClient::new(reqwest::Client::new(), "http://nas:8096", device()).unwrap();
        let img = ImageRef {
            item_id: "abc".into(),
            image_type: "Primary",
            tag: "t1".into(),
            index: None,
        };
        assert_eq!(
            c.image_url(&img, 390, Some(Shape::Portrait)).as_str(),
            "http://nas:8096/emby/Items/abc/Images/Primary?tag=t1&maxWidth=400&maxHeight=600&quality=90"
        );
    }

    #[test]
    fn decodes_items_with_missing_fields() {
        let body = br#"{"Items":[{"Id":"1","Name":"Ep","Type":"Episode","SeriesId":"9","SeriesPrimaryImageTag":"s","ImageTags":{},"UserData":{"PlayedPercentage":42.5}}],"TotalRecordCount":1}"#;
        let page: ItemsPage = http::decode(body, "test").unwrap();
        let item = &page.items[0];
        assert_eq!(item.kind, "Episode");
        assert_eq!(item.series_primary_image_tag.as_deref(), Some("s"));
        assert!(item.image_tags.is_empty());
        assert_eq!(
            item.user_data.as_ref().unwrap().played_percentage,
            Some(42.5)
        );
    }
}

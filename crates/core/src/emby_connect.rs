//! Emby Connect: sign in with an emby.media account, list the servers linked
//! to it, then trade a server's access key for an ordinary server session
//! (`EmbyClient::exchange`). This is how people who use a shared server log
//! in without knowing its address.

use serde::Deserialize;

use crate::{Result, http};

const CONNECT: &str = "https://connect.emby.media/service/";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectSession {
    pub user_id: String,
    pub access_token: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ConnectServer {
    pub name: String,
    /// The server's own id, the same as `PublicInfo::id`.
    #[serde(default)]
    pub system_id: Option<String>,
    #[serde(rename = "Url", default)]
    pub remote_address: Option<String>,
    #[serde(default)]
    pub local_address: Option<String>,
    /// Exchanged at the server for a user session.
    pub access_key: String,
}

impl ConnectServer {
    /// Addresses to try, best first. Remote comes first because a server
    /// shared with you is usually not on your network; the apps will race
    /// both and keep whichever answers.
    pub fn addresses(&self) -> Vec<&str> {
        [
            self.remote_address.as_deref(),
            self.local_address.as_deref(),
        ]
        .into_iter()
        .flatten()
        .filter(|a| !a.trim().is_empty())
        .collect()
    }
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

#[derive(Clone)]
pub struct ConnectClient {
    http: reqwest::Client,
    /// `X-Application`, e.g. `OpenIPTV/0.1.0`.
    application: String,
}

impl ConnectClient {
    pub fn new(http: reqwest::Client, app_name: &str, app_version: &str) -> Self {
        ConnectClient {
            http,
            application: format!("{app_name}/{app_version}"),
        }
    }

    pub async fn login(&self, name_or_email: &str, password: &str) -> Result<ConnectSession> {
        let req = self
            .http
            .post(format!("{CONNECT}user/authenticate"))
            .header("X-Application", &self.application)
            .header(reqwest::header::ACCEPT, "application/json")
            .form(&[("nameOrEmail", name_or_email), ("rawpw", password)]);
        let auth: AuthResult = http::decode(
            &http::fetch(req, "Emby Connect login").await?,
            "Emby Connect login",
        )?;
        Ok(ConnectSession {
            user_id: auth.user.id,
            access_token: auth.access_token,
        })
    }

    /// Servers linked to the account.
    pub async fn servers(&self, session: &ConnectSession) -> Result<Vec<ConnectServer>> {
        let req = self
            .http
            .get(format!("{CONNECT}servers"))
            .query(&[("userId", session.user_id.as_str())])
            .header("X-Application", &self.application)
            .header("X-Connect-UserToken", &session.access_token)
            .header(reqwest::header::ACCEPT, "application/json");
        let body = http::fetch(req, "Emby Connect servers").await?;
        http::decode(&body, "Emby Connect servers")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_servers_and_orders_addresses() {
        let body = br#"[{"Id":"7","SystemId":"abc","Name":"Friend's Emby","Url":"https://emby.example.net","LocalAddress":"http://192.168.1.5:8096","AccessKey":"k","UserType":"Guest"},
                        {"Id":"8","Name":"Local only","Url":"","LocalAddress":"http://10.0.0.2:8096","AccessKey":"k2"}]"#;
        let servers: Vec<ConnectServer> = http::decode(body, "test").unwrap();
        assert_eq!(servers[0].system_id.as_deref(), Some("abc"));
        assert_eq!(
            servers[0].addresses(),
            ["https://emby.example.net", "http://192.168.1.5:8096"]
        );
        assert_eq!(servers[1].addresses(), ["http://10.0.0.2:8096"]);
    }
}

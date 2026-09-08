//! PikPak drive-API captcha token flow.
//!
//! Every request to `api-drive.mypikpak.com/drive/v1/*` must carry an
//! `X-Captcha-Token` header. The token is obtained from
//! `POST https://user.mypikpak.com/v1/shield/captcha/init` and requires
//! a chained-MD5 signature proving the client knows the app package
//! identity + a hard-coded salt table.
//!
//! The server rotates captcha tokens; it returns error_code `9` on drive
//! endpoints when the current token has expired, at which point the
//! client must re-init and retry.
//!
//! This implementation caches the token per-action (the captcha is bound
//! to the request method + path it was issued for) and transparently
//! re-inits when the cached one stops working.
//!
//! The MD5 chain algorithm and salt table come from the upstream
//! `pikpakcli` project. See `cmd/pikpakcli/internal/pikpak/captcha_token.go`
//! in that repo.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use md5::{Digest, Md5};
use serde::Deserialize;
use tokio::sync::RwLock;

use crate::auth::{TokenManager, DESKTOP_CLIENT_ID};
use crate::error::{Error, Result};

/// Package metadata must match the OAuth client that issued the refresh token.
const CLIENT_PACKAGE_NAME: &str = "mypikpak.com";
const WEB_CLIENT_VERSION: &str = "2.0.0";
const DESKTOP_CLIENT_VERSION: &str = "undefined";

/// Current PikPak Web salt table used to build `captcha_sign`.
/// Empty strings are meaningful and must remain in sequence.
const WEB_SALTS: &[&str] = &[
    "C9qPpZLN8ucRTaTiUMWYS9cQvWOE",
    "+r6CQVxjzJV6LCV",
    "F",
    "pFJRC",
    "9WXYIDGrwTCz2OiVlgZa90qpECPD6olt",
    "/750aCr4lm/Sly/c",
    "RB+DT/gZCrbV",
    "",
    "CyLsf7hdkIRxRm215hl",
    "7xHvLi2tOYP0Y92b",
    "ZGTXXxu8E/MIWaEDB+Sm/",
    "1UI3",
    "E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO",
    "ihtqpG6FMt65+Xk+tWUH2",
    "NhXXU9rg4XXdzo7u5o",
];

/// Current first-party desktop salt table. Keeping this profile separate from
/// the Web chain is what lets the GUI use a desktop OAuth session without
/// falling back to Safari's client identity.
const DESKTOP_SALTS: &[&str] = &[
    "KHBJ07an7ROXDoK7Db",
    "G6n399rSWkl7WcQmw5rpQInurc1DkLmLJqE",
    "JZD1A3M4x+jBFN62hkr7VDhkkZxb9g3rWqRZqFAAb",
    "fQnw/AmSlbbI91Ik15gpddGgyU7U",
    "/Dv9JdPYSj3sHiWjouR95NTQff",
    "yGx2zuTjbWENZqecNI+edrQgqmZKP",
    "ljrbSzdHLwbqcRn",
    "lSHAsqCkGDGxQqqwrVu",
    "TsWXI81fD1",
    "vk7hBjawK/rOSrSWajtbMk95nfgf3",
];

#[derive(Clone, Copy)]
struct CaptchaProfile {
    client_version: &'static str,
    package_name: &'static str,
    salts: &'static [&'static str],
}

fn captcha_profile(client_id: &str) -> CaptchaProfile {
    if client_id == DESKTOP_CLIENT_ID {
        CaptchaProfile {
            client_version: DESKTOP_CLIENT_VERSION,
            package_name: CLIENT_PACKAGE_NAME,
            salts: DESKTOP_SALTS,
        }
    } else {
        CaptchaProfile {
            client_version: WEB_CLIENT_VERSION,
            package_name: CLIENT_PACKAGE_NAME,
            salts: WEB_SALTS,
        }
    }
}

/// How long to trust a freshly issued captcha token before refreshing
/// proactively. PikPak doesn't advertise a TTL; pikpakcli re-inits on
/// demand when it sees error_code 9.
const PROACTIVE_REFRESH: Duration = Duration::from_secs(60 * 30); // 30 min

/// Manages captcha tokens for drive-API actions.
///
/// Cheap to clone.
#[derive(Clone)]
pub(crate) struct CaptchaManager {
    inner: Arc<CaptchaManagerInner>,
}

struct CaptchaManagerInner {
    http: reqwest::Client,
    init_endpoint: String,
    client_id: String,
    device_id: String,
    profile: CaptchaProfile,
    tokens: TokenManager,
    /// Cache of (action -> cached captcha).
    cache: RwLock<HashMap<String, CachedCaptcha>>,
}

#[derive(Clone)]
struct CachedCaptcha {
    token: String,
    refresh_after: Instant,
}

impl CaptchaManager {
    pub(crate) fn new(
        http: reqwest::Client,
        init_endpoint: impl Into<String>,
        client_id: impl Into<String>,
        device_id: impl Into<String>,
        tokens: TokenManager,
    ) -> Self {
        let client_id = client_id.into();
        let profile = captcha_profile(&client_id);
        Self {
            inner: Arc::new(CaptchaManagerInner {
                http,
                init_endpoint: init_endpoint.into(),
                client_id,
                device_id: device_id.into(),
                profile,
                tokens,
                cache: RwLock::new(HashMap::new()),
            }),
        }
    }

    /// Return a captcha token for the given action (e.g. `"GET:/drive/v1/files"`).
    pub(crate) async fn token_for(&self, action: &str) -> Result<String> {
        {
            let cache = self.inner.cache.read().await;
            if let Some(c) = cache.get(action) {
                if Instant::now() < c.refresh_after {
                    return Ok(c.token.clone());
                }
            }
        }

        self.refresh(action, None).await
    }

    /// Force a fresh captcha token for the given action. Optionally pass the
    /// previous token so the server can invalidate it. Returns the new token.
    pub(crate) async fn refresh(&self, action: &str, previous: Option<&str>) -> Result<String> {
        let mut cache = self.inner.cache.write().await;

        // Double-check inside the write lock: another task may have already
        // refreshed while we were waiting. If `previous` is supplied and the
        // cached token is still the same token that just failed, force a real
        // refresh instead of returning the known-bad token.
        if let Some(c) = cache.get(action) {
            let already_replaced = previous.is_none_or(|prev| prev != c.token);
            if already_replaced && Instant::now() < c.refresh_after {
                return Ok(c.token.clone());
            }
        }

        let user_id = self.inner.tokens.user_id().await?;
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis().to_string())
            .unwrap_or_else(|_| "0".to_string());

        let sign = captcha_sign(
            &self.inner.client_id,
            &self.inner.device_id,
            &timestamp,
            self.inner.profile,
        );

        let body = serde_json::json!({
            "action": action,
            "captcha_token": previous.unwrap_or(""),
            "client_id": self.inner.client_id,
            "device_id": self.inner.device_id,
            "meta": {
                "captcha_sign": sign,
                "user_id": user_id,
                "package_name": self.inner.profile.package_name,
                "client_version": self.inner.profile.client_version,
                "timestamp": timestamp,
            },
            "redirect_uri": "xlaccsdk01://xbase.cloud/callback?state=harbor",
        });

        let access = self.inner.tokens.access_token().await?;
        let url = format!(
            "{}?client_id={}",
            self.inner.init_endpoint, self.inner.client_id,
        );

        tracing::debug!(action = %action, "initializing captcha token");
        let resp = self
            .inner
            .http
            .post(&url)
            .bearer_auth(&access)
            .header("X-Device-Id", &self.inner.device_id)
            .json(&body)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let text = resp.text().await.unwrap_or_default();
            return Err(Error::Api {
                status,
                message: text,
            });
        }

        let parsed: CaptchaInitResponse = resp.json().await?;
        if parsed.url.as_deref().is_some_and(|url| !url.is_empty()) {
            return Err(Error::Auth(
                "PikPak requires additional verification in the official web app".to_string(),
            ));
        }
        if parsed.captcha_token.is_empty() {
            return Err(Error::Auth(
                "PikPak returned an empty verification token".to_string(),
            ));
        }
        let cached = CachedCaptcha {
            token: parsed.captcha_token.clone(),
            refresh_after: Instant::now() + PROACTIVE_REFRESH,
        };
        cache.insert(action.to_string(), cached);
        Ok(parsed.captcha_token)
    }
}

#[derive(Debug, Deserialize)]
struct CaptchaInitResponse {
    #[serde(default)]
    captcha_token: String,
    #[serde(default)]
    url: Option<String>,
}

/// Compute the `captcha_sign` string used in the captcha init body.
///
/// Formula (from pikpakcli):
/// ```text
/// s0 = client_id + client_version + package_name + device_id + timestamp_ms
/// for salt in SALTS:
///     s_next = hex(md5(s_prev + salt))
/// result = "1." + s_final
/// ```
fn captcha_sign(
    client_id: &str,
    device_id: &str,
    timestamp: &str,
    profile: CaptchaProfile,
) -> String {
    let mut s = String::with_capacity(128);
    s.push_str(client_id);
    s.push_str(profile.client_version);
    s.push_str(profile.package_name);
    s.push_str(device_id);
    s.push_str(timestamp);

    for salt in profile.salts {
        let mut hasher = Md5::new();
        hasher.update(s.as_bytes());
        hasher.update(salt.as_bytes());
        let digest = hasher.finalize();
        s = hex::encode(digest);
    }

    format!("1.{s}")
}

/// Build the first-party Web captcha signature used by anonymous public-share
/// requests. Public shares do not have an account access token or user id, so
/// they cannot use [`CaptchaManager`], but the signing profile is identical to
/// PikPak Web's profile.
pub(crate) fn anonymous_web_captcha_sign(device_id: &str, timestamp: &str) -> String {
    captcha_sign(
        crate::auth::DEFAULT_CLIENT_ID,
        device_id,
        timestamp,
        captcha_profile(crate::auth::DEFAULT_CLIENT_ID),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_is_deterministic_and_prefixed() {
        let profile = captcha_profile("web-client");
        let s1 = captcha_sign("id", "dev", "1700000000000", profile);
        let s2 = captcha_sign("id", "dev", "1700000000000", profile);
        assert_eq!(s1, s2, "identical inputs must produce identical signs");
        assert!(s1.starts_with("1."), "sign must have the '1.' prefix");
        // The body after the prefix is the final MD5 hex -> 32 chars.
        assert_eq!(s1.len(), 2 + 32);
    }

    #[test]
    fn sign_changes_on_any_input_change() {
        let profile = captcha_profile("web-client");
        let base = captcha_sign("id", "dev", "1700000000000", profile);
        assert_ne!(base, captcha_sign("ID", "dev", "1700000000000", profile));
        assert_ne!(base, captcha_sign("id", "DEV", "1700000000000", profile));
        assert_ne!(base, captcha_sign("id", "dev", "1700000000001", profile));
    }

    #[test]
    fn web_profile_has_complete_algorithm_chain() {
        let profile = captcha_profile("web-client");
        assert_eq!(profile.package_name, "mypikpak.com");
        assert_eq!(profile.client_version, "2.0.0");
        assert_eq!(profile.salts.len(), 15);
    }

    #[test]
    fn desktop_client_selects_the_desktop_algorithm_chain() {
        let profile = captcha_profile(DESKTOP_CLIENT_ID);
        assert_eq!(profile.package_name, "mypikpak.com");
        assert_eq!(profile.client_version, "undefined");
        assert_eq!(profile.salts.len(), 10);
    }
}

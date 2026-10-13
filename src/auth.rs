//! OAuth2 refresh-token flow for PikPak.
//!
//! PikPak uses a long-lived refresh token (obtainable from the web UI's
//! local storage) which we exchange for a short-lived access token. The
//! access token is attached as `Authorization: Bearer <token>` on every
//! subsequent API call.
//!
//! Endpoint: `POST https://user.mypikpak.com/v1/auth/token`
//!
//! Request body (JSON):
//! ```json
//! { "client_id": "...", "client_secret": "...",
//!   "grant_type": "refresh_token", "refresh_token": "..." }
//! ```
//!
//! Response body (JSON):
//! ```json
//! { "access_token": "...", "refresh_token": "...",
//!   "expires_in": 7200, "sub": "<user_id>" }
//! ```
//!
//! PikPak *rotates* the refresh token on each exchange. Standalone callers can
//! read [`TokenManager::current_refresh_token`] and persist it after a command;
//! multi-process frontends can configure a shared token store, which serializes
//! refreshes and publishes each replacement immediately.
//!
//! PikPak rejects this request when it looks browser-originated because the
//! OAuth application secret is part of the payload. The Web client profile
//! therefore uses an explicitly empty `User-Agent` for the token exchange,
//! matching the current AList PikPak implementation. Drive and captcha
//! requests continue to use the configured Web `User-Agent`.

use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use reqwest::header::USER_AGENT;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::error::{Error, Result};

/// OAuth client credentials used by PikPak Web. These identify the
/// *application*, not the user. The standalone CLI defaults to the Web
/// profile so existing Web refresh-token configurations remain compatible.
///
/// Client secrets come from local build configuration or runtime environment,
/// never from committed source. Callers can also override via
/// [`ClientBuilder::credentials`](crate::ClientBuilder::credentials)
/// if PikPak rotates them.
/// Default PikPak Web OAuth client id.
pub const DEFAULT_CLIENT_ID: &str = "YUMx5nI8ZU8Ap8pm";
/// Default PikPak Web OAuth client secret.
pub const DEFAULT_CLIENT_SECRET: &str = match option_env!("PIKPAK_WEB_CLIENT_SECRET") {
    Some(value) => value,
    None => "",
};

/// PikPak's first-party desktop client identity. The macOS GUI obtains a
/// desktop authorization code from PikPak's official signed-in page and then
/// uses this distinct client profile so refreshing the app session cannot
/// rotate or revoke Safari's Web-client token chain.
pub const DESKTOP_CLIENT_ID: &str = "YvtoWO6GNHiuCl7x";
/// Public application secret paired with [`DESKTOP_CLIENT_ID`].
pub const DESKTOP_CLIENT_SECRET: &str = match option_env!("PIKPAK_DESKTOP_CLIENT_SECRET") {
    Some(value) => value,
    None => "",
};

/// OAuth client credentials for the PikPak auth server.
///
/// These are application identifiers rather than per-user credentials.
/// Defaults are the Web-profile crate constants.
#[derive(Debug, Clone)]
pub struct OAuthCredentials {
    /// OAuth client id.
    pub client_id: String,
    /// OAuth client secret.
    pub client_secret: String,
}

impl Default for OAuthCredentials {
    fn default() -> Self {
        Self {
            client_id: DEFAULT_CLIENT_ID.to_string(),
            client_secret: std::env::var("PIKPAK_WEB_CLIENT_SECRET")
                .unwrap_or_else(|_| DEFAULT_CLIENT_SECRET.to_string()),
        }
    }
}

impl OAuthCredentials {
    /// Construct credentials from explicit values.
    pub fn new(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
        }
    }
}

/// A cached access token plus its expiry instant and owning user id.
#[derive(Debug, Clone)]
struct CachedToken {
    access_token: String,
    refresh_token: String,
    user_id: String,
    /// Wall-clock deadline after which we must refresh. We refresh a minute
    /// before the server-reported expiry to absorb clock skew.
    refresh_at: Instant,
}

/// Token manager: keeps the current access token and refreshes it on demand.
///
/// Cheap to clone — internally shares state behind an `Arc<RwLock<_>>` so
/// concurrent requests share a single refresh call.
#[derive(Clone)]
pub struct TokenManager {
    inner: Arc<TokenManagerInner>,
}

#[derive(Debug)]
struct TokenManagerInner {
    http: reqwest::Client,
    auth_endpoint: String,
    credentials: OAuthCredentials,
    device_id: String,
    cached: RwLock<Option<CachedToken>>,
    /// Initial refresh token supplied by the caller. Kept so that after a
    /// rotation we can recover if the in-memory cache is reset.
    initial_refresh_token: String,
    /// Optional process-shared store used by the macOS app. Every refresh is
    /// serialized through its lock file and reloads the newest token before
    /// contacting PikPak, so independent browser/scanner processes cannot
    /// spend the same rotating token concurrently.
    shared_refresh_store: Option<SharedRefreshTokenStore>,
    personal_access_token: Option<String>,
    personal_user_id: RwLock<Option<String>>,
}

impl std::fmt::Debug for TokenManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TokenManager")
            .field("personal_access_token", &self.is_personal_access_token())
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone)]
struct SharedRefreshTokenStore {
    token_path: PathBuf,
    lock_path: PathBuf,
}

struct SharedRefreshTokenGuard {
    _lock_file: File,
    token_path: PathBuf,
}

/// Private, optional access-token cache shared by short-lived GUI helpers.
/// The refresh-token file stays authoritative for compatibility with older
/// helpers. A cache from another session/client/device is never reused.
#[derive(Deserialize, Serialize)]
struct SharedSession {
    version: u8,
    auth_endpoint: String,
    client_id: String,
    device_id: String,
    access_token: String,
    refresh_token: String,
    user_id: String,
    issued_at: u64,
    refresh_at: u64,
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

impl SharedRefreshTokenStore {
    async fn lock(&self) -> Result<SharedRefreshTokenGuard> {
        let _stage = crate::download_waits::Stage::enter(crate::download_waits::Kind::AuthFileLock);
        let token_path = self.token_path.clone();
        let lock_path = self.lock_path.clone();
        tokio::task::spawn_blocking(move || {
            if let Some(parent) = lock_path.parent() {
                std::fs::create_dir_all(parent)?;
            }

            let mut options = OpenOptions::new();
            options.create(true).read(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let lock_file = options.open(&lock_path)?;
            lock_file.lock()?;

            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o600))?;
            }

            Ok(SharedRefreshTokenGuard {
                _lock_file: lock_file,
                token_path,
            })
        })
        .await
        .map_err(|error| Error::Auth(format!("shared session lock task failed: {error}")))?
        .map_err(|error: std::io::Error| {
            Error::Auth(format!("could not lock the shared session: {error}"))
        })
    }
}

impl SharedRefreshTokenGuard {
    fn cache_path(&self) -> PathBuf {
        let mut name = self
            .token_path
            .file_name()
            .unwrap_or_default()
            .to_os_string();
        name.push(".session.json");
        self.token_path.with_file_name(name)
    }

    fn read_session(&self) -> Option<SharedSession> {
        let path = self.cache_path();
        let metadata = std::fs::symlink_metadata(&path).ok()?;
        if !metadata.file_type().is_file() || metadata.len() > 65_536 {
            return None;
        }
        serde_json::from_slice(&std::fs::read(path).ok()?).ok()
    }

    fn write_session(&self, session: &SharedSession) -> std::io::Result<()> {
        write_private_atomic(&self.cache_path(), &serde_json::to_string(session)?)
    }

    fn reject_access(&self, rejected: &str) -> Result<()> {
        if self
            .read_session()
            .is_some_and(|session| session.access_token == rejected)
        {
            std::fs::remove_file(self.cache_path()).map_err(|error| {
                Error::Auth(format!(
                    "could not clear the rejected access cache: {error}"
                ))
            })?;
        }
        Ok(())
    }

    fn read_token(&self) -> Result<String> {
        let token = std::fs::read_to_string(&self.token_path)
            .map_err(|error| Error::Auth(format!("could not read the shared session: {error}")))?;
        let token = token.trim().to_string();
        if token.is_empty() {
            return Err(Error::Auth("the shared session is empty".into()));
        }
        Ok(token)
    }

    fn write_token(&self, token: &str) -> Result<()> {
        write_private_atomic(&self.token_path, token).map_err(|error| {
            Error::Auth(format!(
                "could not save the rotated shared session: {error}"
            ))
        })
    }
}

fn write_private_atomic(path: &Path, value: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    if path.exists() {
        let metadata = std::fs::symlink_metadata(path)?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "session path is not a regular file",
            ));
        }
    }

    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("refresh-token");
    let temporary = path.with_file_name(format!(
        ".{filename}.tmp-{}-{}",
        std::process::id(),
        std::thread::current().name().unwrap_or("auth")
    ));

    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(value.as_bytes())?;
    file.sync_all()?;
    drop(file);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&temporary, path)?;
    Ok(())
}

impl TokenManager {
    /// Create a new token manager. Does not contact the network.
    pub fn new(
        http: reqwest::Client,
        auth_endpoint: impl Into<String>,
        credentials: OAuthCredentials,
        device_id: impl Into<String>,
        refresh_token: impl Into<String>,
    ) -> Self {
        Self::new_with_shared_store(
            http,
            auth_endpoint,
            credentials,
            device_id,
            refresh_token,
            None,
        )
    }

    pub(crate) fn new_with_shared_store(
        http: reqwest::Client,
        auth_endpoint: impl Into<String>,
        credentials: OAuthCredentials,
        device_id: impl Into<String>,
        refresh_token: impl Into<String>,
        shared_refresh_store: Option<(PathBuf, PathBuf)>,
    ) -> Self {
        let refresh_token = refresh_token.into();
        Self {
            inner: Arc::new(TokenManagerInner {
                http,
                auth_endpoint: auth_endpoint.into(),
                credentials,
                device_id: device_id.into(),
                cached: RwLock::new(None),
                initial_refresh_token: refresh_token,
                shared_refresh_store: shared_refresh_store.map(|(token_path, lock_path)| {
                    SharedRefreshTokenStore {
                        token_path,
                        lock_path,
                    }
                }),
                personal_access_token: None,
                personal_user_id: RwLock::new(None),
            }),
        }
    }

    /// A PAT is sent directly as a bearer credential. It is never exchanged,
    /// refreshed or written into an OAuth refresh-token store.
    pub(crate) fn personal_access_token(
        http: reqwest::Client,
        auth_endpoint: String,
        device_id: String,
        token: String,
    ) -> Self {
        Self {
            inner: Arc::new(TokenManagerInner {
                http,
                auth_endpoint,
                device_id,
                credentials: OAuthCredentials::new("", ""),
                cached: RwLock::new(None),
                initial_refresh_token: String::new(),
                shared_refresh_store: None,
                personal_access_token: Some(token),
                personal_user_id: RwLock::new(None),
            }),
        }
    }

    pub fn is_personal_access_token(&self) -> bool {
        self.inner.personal_access_token.is_some()
    }

    /// Only accept identity from an authenticated account-service response.
    /// A locally decoded, unsigned JWT claim is not an identity check.
    pub(crate) async fn confirm_user_id(&self, user_id: &str) -> Result<()> {
        if user_id.trim().is_empty() {
            return Err(Error::Auth(
                "account profile is missing its identity".into(),
            ));
        }
        if self.is_personal_access_token() {
            let mut cached = self.inner.personal_user_id.write().await;
            if cached
                .as_deref()
                .is_some_and(|previous| previous != user_id)
            {
                return Err(Error::Auth("account profile identity mismatch".into()));
            }
            *cached = Some(user_id.to_owned());
        } else if self.user_id().await? != user_id {
            return Err(Error::Auth("account profile identity mismatch".into()));
        }
        Ok(())
    }

    /// Return a currently-valid access token, refreshing if needed.
    pub async fn access_token(&self) -> Result<String> {
        if let Some(token) = &self.inner.personal_access_token {
            return Ok(token.clone());
        }
        // Fast path: still valid.
        {
            let guard = crate::download_waits::track(crate::download_waits::Kind::AuthLock, self.inner.cached.read()).await;
            if let Some(t) = guard.as_ref() {
                if Instant::now() < t.refresh_at {
                    return Ok(t.access_token.clone());
                }
            }
        }

        // Slow path: acquire write lock and refresh. Double-check inside the
        // write lock in case another task refreshed while we were waiting.
        let mut guard = crate::download_waits::track(crate::download_waits::Kind::AuthLock, self.inner.cached.write()).await;
        if let Some(t) = guard.as_ref() {
            if Instant::now() < t.refresh_at {
                return Ok(t.access_token.clone());
            }
        }

        let fresh = self.refresh_now(&mut guard).await?;
        Ok(fresh)
    }

    /// Expire the cached access token so the next [`access_token`] call
    /// refreshes it. The newest rotated refresh token remains cached; dropping
    /// the whole entry would incorrectly fall back to the stale initial token.
    ///
    /// [`access_token`]: Self::access_token
    pub async fn invalidate(&self) {
        let access = self
            .inner
            .cached
            .read()
            .await
            .as_ref()
            .map(|token| token.access_token.clone());
        if let Some(access) = access {
            let _ = self.reject_access_token(&access).await;
        }
    }

    /// Invalidate only the token used by the rejected request. An older 401
    /// must not expire a replacement already obtained by another request or
    /// process. The refresh token is retained in both cases.
    pub async fn reject_access_token(&self, rejected: &str) -> Result<()> {
        let mut guard = self.inner.cached.write().await;
        if let Some(token) = guard
            .as_mut()
            .filter(|token| token.access_token == rejected)
        {
            token.refresh_at = Instant::now();
        }
        if let Some(store) = &self.inner.shared_refresh_store {
            store.lock().await?.reject_access(rejected)?;
        }
        Ok(())
    }

    /// Return the `sub` (user id) claim from the current token, refreshing
    /// if necessary. Used by the captcha flow to bind requests to a user.
    pub async fn user_id(&self) -> Result<String> {
        if let Some(token) = &self.inner.personal_access_token {
            let mut cached = self.inner.personal_user_id.write().await;
            if let Some(user_id) = &*cached {
                return Ok(user_id.clone());
            }
            let base = self
                .inner
                .auth_endpoint
                .strip_suffix("/auth/token")
                .ok_or_else(|| Error::Auth("invalid account service endpoint".into()))?;
            let response = self
                .inner
                .http
                .get(format!("{base}/user/me"))
                .bearer_auth(token)
                .header("X-Device-Id", &self.inner.device_id)
                .timeout(Duration::from_secs(8))
                .send()
                .await?
                .error_for_status()?;
            let profile: crate::types::AccountProfile = response.json().await?;
            if profile.sub.trim().is_empty() {
                return Err(Error::Auth(
                    "account profile is missing its identity".into(),
                ));
            }
            *cached = Some(profile.sub.clone());
            return Ok(profile.sub);
        }
        // Trigger a refresh if needed, then read the cache.
        let _ = self.access_token().await?;
        let guard = self.inner.cached.read().await;
        guard
            .as_ref()
            .map(|t| t.user_id.clone())
            .ok_or(Error::TokenExpired)
    }

    /// Return the most recently issued refresh token (rotated on each
    /// exchange), or the initial one if we haven't refreshed yet.
    pub async fn current_refresh_token(&self) -> String {
        let guard = self.inner.cached.read().await;
        guard
            .as_ref()
            .map(|t| t.refresh_token.clone())
            .unwrap_or_else(|| self.inner.initial_refresh_token.clone())
    }

    /// Perform the actual refresh call. Caller holds the write lock.
    async fn refresh_now(
        &self,
        guard: &mut tokio::sync::RwLockWriteGuard<'_, Option<CachedToken>>,
    ) -> Result<String> {
        let shared_guard = match self.inner.shared_refresh_store.as_ref() {
            Some(store) => Some(store.lock().await?),
            None => None,
        };
        let current_refresh = match shared_guard.as_ref() {
            Some(store) => store.read_token()?,
            None => guard
                .as_ref()
                .map(|t| t.refresh_token.clone())
                .unwrap_or_else(|| self.inner.initial_refresh_token.clone()),
        };

        if let Some(store) = shared_guard.as_ref() {
            if let Some(session) = store.read_session() {
                let now = unix_seconds();
                if session.version == 1
                    && session.auth_endpoint == self.inner.auth_endpoint
                    && session.client_id == self.inner.credentials.client_id
                    && session.device_id == self.inner.device_id
                    && session.refresh_token == current_refresh
                    && !session.access_token.is_empty()
                    && !session.user_id.is_empty()
                    && session.issued_at <= now
                    && now < session.refresh_at
                    && !guard.as_ref().is_some_and(|old| {
                        old.access_token == session.access_token && old.refresh_at <= Instant::now()
                    })
                {
                    let access = session.access_token.clone();
                    **guard = Some(CachedToken {
                        access_token: session.access_token,
                        refresh_token: session.refresh_token,
                        user_id: session.user_id,
                        refresh_at: Instant::now() + Duration::from_secs(session.refresh_at - now),
                    });
                    return Ok(access);
                }
            }
        }

        let req = self.refresh_request(&current_refresh);

        tracing::debug!(endpoint = %self.inner.auth_endpoint, "refreshing access token");
        let resp = crate::download_waits::track(crate::download_waits::Kind::AuthHeaders, req.send()).await?;
        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            return Err(refresh_error(status, &body));
        }

        let body: RefreshResponse = crate::download_waits::track(crate::download_waits::Kind::AuthBody, resp.json()).await?;
        if body.access_token.is_empty() || body.refresh_token.is_empty() || body.sub.is_empty() {
            return Err(Error::Auth(
                "PikPak returned an incomplete session; the saved credential was kept".into(),
            ));
        }
        let effective_ttl = body
            .expires_in
            .saturating_sub((body.expires_in / 10).min(60));
        if let Some(store) = shared_guard.as_ref() {
            // Publish the replacement while the inter-process lock is still
            // held. A second engine will then read this token, never the one
            // that the current refresh request just consumed.
            store.write_token(&body.refresh_token)?;
            let now = unix_seconds();
            let session = SharedSession {
                version: 1,
                auth_endpoint: self.inner.auth_endpoint.clone(),
                client_id: self.inner.credentials.client_id.clone(),
                device_id: self.inner.device_id.clone(),
                access_token: body.access_token.clone(),
                refresh_token: body.refresh_token.clone(),
                user_id: body.sub.clone(),
                issued_at: now,
                refresh_at: now.saturating_add(effective_ttl),
            };
            if store.write_session(&session).is_err() {
                // The rotating credential is already durable. An optional
                // cache failure must never turn a successful refresh into logout.
                tracing::warn!("could not cache the shared access token; refresh token saved");
            }
        }
        let refresh_at = Instant::now() + Duration::from_secs(effective_ttl);
        let access = body.access_token.clone();
        **guard = Some(CachedToken {
            access_token: body.access_token,
            refresh_token: body.refresh_token,
            user_id: body.sub,
            refresh_at,
        });
        Ok(access)
    }

    /// Whether refreshes are immediately coordinated through a shared file.
    pub fn uses_shared_refresh_store(&self) -> bool {
        self.inner.shared_refresh_store.is_some()
    }

    fn refresh_request(&self, current_refresh: &str) -> reqwest::RequestBuilder {
        self.inner
            .http
            .post(&self.inner.auth_endpoint)
            // PikPak's token endpoint expects refresh exchanges without the
            // drive/captcha User-Agent, for both Web and desktop profiles.
            .header(USER_AGENT, "")
            .header("X-Device-Id", &self.inner.device_id)
            .query(&[("client_id", &self.inner.credentials.client_id)])
            .json(&serde_json::json!({
                "client_id": self.inner.credentials.client_id,
                "client_secret": self.inner.credentials.client_secret,
                "grant_type": "refresh_token",
                "refresh_token": current_refresh,
            }))
    }
}

fn refresh_error(status: u16, body: &str) -> Error {
    let value: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    let rejected = value["error"].as_str() == Some("invalid_grant")
        || value["error_code"].as_u64() == Some(4126);
    if (status == 400 || status == 401) && rejected {
        Error::SessionRejected("PikPak rejected the saved refresh credential. Sign in again.")
    } else {
        Error::Auth(format!("status {status}: {body}"))
    }
}

#[derive(Debug, Deserialize)]
struct RefreshResponse {
    access_token: String,
    refresh_token: String,
    expires_in: u64,
    sub: String,
}

#[cfg(test)]
#[path = "auth_session_tests.rs"]
mod session_tests;

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use reqwest::header::USER_AGENT;

    use super::{
        write_private_atomic, CachedToken, OAuthCredentials, SharedRefreshTokenStore, TokenManager,
        DEFAULT_CLIENT_ID,
    };

    #[test]
    fn default_credentials_match_web_token_profile() {
        let credentials = OAuthCredentials::default();
        assert_eq!(credentials.client_id, "YUMx5nI8ZU8Ap8pm");
        assert_eq!(credentials.client_id, DEFAULT_CLIENT_ID);
    }

    #[test]
    fn web_refresh_suppresses_browser_user_agent() {
        let http = reqwest::Client::builder()
            .user_agent("Mozilla/5.0 browser profile")
            .build()
            .unwrap();
        let manager = TokenManager::new(
            http,
            "https://user.mypikpak.com/v1/auth/token",
            OAuthCredentials::default(),
            "device-id",
            "refresh-token",
        );

        let request = manager.refresh_request("refresh-token").build().unwrap();

        assert_eq!(request.headers().get(USER_AGENT).unwrap(), "");
    }

    #[tokio::test]
    async fn invalidating_access_keeps_the_rotated_refresh_token() {
        let manager = TokenManager::new(
            reqwest::Client::new(),
            "https://user.mypikpak.com/v1/auth/token",
            OAuthCredentials::default(),
            "device-id",
            "initial-refresh",
        );
        *manager.inner.cached.write().await = Some(CachedToken {
            access_token: "rejected-access".into(),
            refresh_token: "latest-rotated-refresh".into(),
            user_id: "user".into(),
            refresh_at: Instant::now() + Duration::from_secs(600),
        });

        manager.invalidate().await;

        assert_eq!(
            manager.current_refresh_token().await,
            "latest-rotated-refresh"
        );
        let guard = manager.inner.cached.read().await;
        assert!(guard.as_ref().unwrap().refresh_at <= Instant::now());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn shared_store_serializes_and_publishes_rotation() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "pikpak-shared-session-test-{}-{unique}",
            std::process::id()
        ));
        let token_path = directory.join("refresh-token");
        let lock_path = directory.join("refresh-token.lock");
        write_private_atomic(&token_path, "first-token").unwrap();
        let store = SharedRefreshTokenStore {
            token_path: token_path.clone(),
            lock_path,
        };

        let first_guard = store.lock().await.unwrap();
        let waiting_store = store.clone();
        let waiting = tokio::spawn(async move {
            let guard = waiting_store.lock().await.unwrap();
            guard.read_token().unwrap()
        });
        tokio::time::sleep(Duration::from_millis(25)).await;
        assert!(!waiting.is_finished());

        first_guard.write_token("second-token").unwrap();
        drop(first_guard);
        assert_eq!(waiting.await.unwrap(), "second-token");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&token_path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}

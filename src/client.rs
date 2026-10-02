//! Top-level API client: wraps a [`reqwest::Client`] with a token manager
//! and a captcha manager, and exposes high-level operations.

use std::collections::HashSet;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use md5::{Digest, Md5};
use reqwest::header::{CONTENT_LENGTH, RANGE, REFERER};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::auth::{OAuthCredentials, TokenManager, DESKTOP_CLIENT_ID};
use crate::captcha::CaptchaManager;
use crate::error::{Error, Result};
use crate::types::{deserialize_string_to_u64, AccountProfile, FileInfo, FilePage, Quota};

/// PikPak user/auth service base URL. Overridable via
/// [`ClientBuilder::auth_base_url`].
const DEFAULT_AUTH_BASE: &str = "https://user.mypikpak.com";

/// PikPak drive API base URL. Overridable via
/// [`ClientBuilder::api_base_url`].
const DEFAULT_API_BASE: &str = "https://api-drive.mypikpak.com";

/// Default request timeout applied to every HTTP call.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Browser User-Agent matching the default Web OAuth/captcha profile used by
/// standalone CLI configurations.
const DEFAULT_USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36";

/// User-Agent advertised by PikPak's first-party desktop client profile.
const DESKTOP_USER_AGENT: &str = "MainWindow Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
     AppleWebKit/537.36 (KHTML, like Gecko) PikPak/2.6.11.4955 \
     Chrome/100.0.4896.160 Electron/18.3.15 Safari/537.36";

/// Public API surface: every PikPak operation goes through this struct.
///
/// Construct via [`ClientBuilder`]. Cheap to clone.
#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    upload_http: reqwest::Client,
    download_http: reqwest::Client,
    guest_download_http: reqwest::Client,
    pub(crate) api_base: String,
    auth_base: String,
    device_id: String,
    tokens: TokenManager,
    captcha: CaptchaManager,
    proxy: Option<String>,
    content_mode: crate::ContentMode,
    guest: std::sync::Arc<crate::guest::GuestState>,
}

/// Result returned after PikPak accepts a server-side shared-item restore.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShareRestoreResult {
    pub restore_status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore_task_id: Option<String>,
    pub saved_count: usize,
}

/// Builder for [`Client`].
pub struct ClientBuilder {
    refresh_token: Option<String>,
    personal_access_token: Option<String>,
    credentials: OAuthCredentials,
    device_id: Option<String>,
    auth_base_url: String,
    api_base_url: String,
    timeout: Duration,
    user_agent: String,
    proxy: Option<String>,
    shared_refresh_store: Option<(PathBuf, PathBuf)>,
}

impl Default for ClientBuilder {
    fn default() -> Self {
        Self {
            refresh_token: None,
            personal_access_token: None,
            credentials: OAuthCredentials::default(),
            device_id: None,
            auth_base_url: DEFAULT_AUTH_BASE.into(),
            api_base_url: DEFAULT_API_BASE.into(),
            timeout: DEFAULT_TIMEOUT,
            user_agent: DEFAULT_USER_AGENT.into(),
            proxy: None,
            shared_refresh_store: None,
        }
    }
}

impl ClientBuilder {
    /// Start a new builder.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the refresh token (required).
    pub fn refresh_token(mut self, token: impl Into<String>) -> Self {
        self.refresh_token = Some(token.into());
        self
    }

    /// Authenticate with an official Personal Access Token, without OAuth
    /// refresh or first-party captcha exchanges. Mutually exclusive with a
    /// refresh token and its shared rotation store.
    pub fn personal_access_token(mut self, token: impl Into<String>) -> Self {
        self.personal_access_token = Some(token.into());
        self
    }

    /// Override OAuth client id / secret. Defaults match upstream pikpakcli.
    pub fn credentials(mut self, c: OAuthCredentials) -> Self {
        if c.client_id == DESKTOP_CLIENT_ID && self.user_agent == DEFAULT_USER_AGENT {
            self.user_agent = DESKTOP_USER_AGENT.into();
        }
        self.credentials = c;
        self
    }

    /// Override the device id. If unset, a deterministic fallback is derived
    /// from the initial refresh token. Long-lived frontends should persist and
    /// provide an explicit id because refresh tokens rotate.
    pub fn device_id(mut self, id: impl Into<String>) -> Self {
        self.device_id = Some(id.into());
        self
    }

    /// Override the OAuth service base URL.
    pub fn auth_base_url(mut self, url: impl Into<String>) -> Self {
        self.auth_base_url = url.into();
        self
    }

    /// Override the Drive API base URL.
    pub fn api_base_url(mut self, url: impl Into<String>) -> Self {
        self.api_base_url = url.into();
        self
    }

    /// Set the request timeout (default: 30s).
    pub fn timeout(mut self, t: Duration) -> Self {
        self.timeout = t;
        self
    }

    /// Set a custom User-Agent header (default: the PikPak Web browser UA).
    pub fn user_agent(mut self, ua: impl Into<String>) -> Self {
        self.user_agent = ua.into();
        self
    }

    /// Route all requests through an HTTP(S) proxy.
    pub fn proxy(mut self, url: impl Into<String>) -> Self {
        self.proxy = Some(url.into());
        self
    }

    /// Coordinate refresh-token rotation through a process-shared token file
    /// and advisory lock file. This is intended for GUI frontends that launch
    /// more than one short-lived engine process.
    pub fn shared_refresh_token_store(
        mut self,
        token_path: impl Into<PathBuf>,
        lock_path: impl Into<PathBuf>,
    ) -> Self {
        self.shared_refresh_store = Some((token_path.into(), lock_path.into()));
        self
    }

    /// Finalize and build the [`Client`].
    pub fn build(self) -> Result<Client> {
        if self.personal_access_token.is_some()
            && (self.refresh_token.is_some() || self.shared_refresh_store.is_some()) {
            return Err(Error::Auth("choose either a Personal Access Token or an OAuth refresh token".into()));
        }
        let personal_access_token = self.personal_access_token;
        let credential = personal_access_token.as_ref().or(self.refresh_token.as_ref())
            .ok_or(Error::NotConfigured("refresh_token or personal_access_token"))?;
        if credential.trim().is_empty() || credential.chars().any(char::is_whitespace) {
            return Err(Error::Auth("the configured credential is empty or contains whitespace".into()));
        }

        let device_id = self
            .device_id
            .unwrap_or_else(|| device_id_from(credential));

        let build_http = |timeout: Duration| -> Result<reqwest::Client> {
            let mut builder = reqwest::Client::builder()
                .no_proxy()
                .timeout(timeout)
                .user_agent(if personal_access_token.is_some() { "MyCloudDriver" } else { &self.user_agent });
            if let Some(proxy) = self.proxy.as_deref() {
                builder = builder.proxy(reqwest::Proxy::all(proxy)?);
            }
            Ok(builder.build()?)
        };
        let http = build_http(self.timeout)?;
        // Drive metadata requests should fail quickly, while a slow upload is
        // allowed enough time to finish an individual OSS part. Both clients
        // retain the same proxy configuration.
        let upload_http = build_http(Duration::from_secs(15 * 60))?;
        // An original may take much longer than a metadata request. Bound
        // connection/inactivity instead of timing out a healthy large file.
        let build_download = |guest: bool| -> Result<reqwest::Client> {
            let mut download_builder = reqwest::Client::builder()
                // GUI helpers may inherit shell/system proxy variables. Only an
                // explicitly chosen app/CLI proxy may route these requests.
                .no_proxy()
                .user_agent(if guest { DEFAULT_USER_AGENT } else { &self.user_agent })
                .connect_timeout(Duration::from_secs(20))
                .read_timeout(Duration::from_secs(90))
                // Keep reusable connections between waves of originals. This is
                // an idle-socket bound; active bodies have separate admission.
                .pool_max_idle_per_host(32)
                .pool_idle_timeout(Duration::from_secs(30));
            if let Some(proxy) = self.proxy.as_deref() {
                download_builder = download_builder.proxy(reqwest::Proxy::all(proxy)?);
            }
            if guest {
                let mut headers = reqwest::header::HeaderMap::new();
                headers.insert(REFERER, reqwest::header::HeaderValue::from_static("https://mypikpak.com/"));
                download_builder = download_builder.default_headers(headers);
            }
            Ok(download_builder.build()?)
        };
        let download_http = build_download(false)?;
        let guest_download_http = build_download(true)?;

        let auth_base = self.auth_base_url.trim_end_matches('/');
        let auth_endpoint = format!("{auth_base}/v1/auth/token");
        let captcha_endpoint = format!("{auth_base}/v1/shield/captcha/init");

        let tokens = if let Some(token) = personal_access_token {
            TokenManager::personal_access_token(http.clone(), auth_endpoint, device_id.clone(), token)
        } else { TokenManager::new_with_shared_store(
            http.clone(),
            auth_endpoint,
            self.credentials.clone(),
            &device_id,
            self.refresh_token.expect("credential checked above"),
            self.shared_refresh_store,
        ) };

        let captcha = CaptchaManager::new(
            http.clone(),
            captcha_endpoint,
            &self.credentials.client_id,
            &device_id,
            tokens.clone(),
        );

        Ok(Client {
            http,
            upload_http,
            download_http,
            guest_download_http,
            api_base: self.api_base_url,
            auth_base: self.auth_base_url,
            device_id,
            tokens,
            captcha,
            proxy: self.proxy,
            content_mode: crate::ContentMode::User,
            guest: Default::default(),
        })
    }
}

impl Client {
    /// Select anonymous original-share URLs for content operations. Metadata,
    /// quota, uploads and account mutations retain their normal authorization.
    pub fn with_guest_mode(mut self, enabled: bool) -> Self {
        self.content_mode = if enabled { crate::ContentMode::Guest } else { crate::ContentMode::User };
        self
    }

    pub fn guest_mode(&self) -> bool { self.content_mode == crate::ContentMode::Guest }

    pub fn with_content_mode(mut self, mode: crate::ContentMode) -> Self {
        self.content_mode = mode;
        self
    }

    pub fn content_mode(&self) -> crate::ContentMode { self.content_mode }

    /// Links downloads use the same policy as saved account files. The guest
    /// and account clients keep separate authorization and captcha sessions.
    pub fn share_client(&self, url: &str, pass_code: &str, token: &str) -> Result<crate::ShareClient> {
        use crate::ContentMode;
        match self.content_mode {
            ContentMode::Guest => self.anonymous_share_client(url, pass_code, token),
            ContentMode::User => Ok(crate::ShareClient::new_authenticated(url, pass_code, token, self.clone())?
                .with_endpoints(&self.api_base, &self.auth_base)),
            ContentMode::Dynamic => {
                let user = self.clone().with_content_mode(ContentMode::User).share_client(url, pass_code, token)?;
                Ok(self.anonymous_share_client(url, pass_code, token)?.with_user_fallback(user))
            }
        }
    }

    /// A separate transport/session: never copy account authorization headers.
    pub fn anonymous_share_client(&self, url: &str, pass_code: &str, token: &str) -> Result<crate::ShareClient> {
        Ok(crate::ShareClient::new(url, pass_code, token, None, self.proxy.as_deref())?
            .with_endpoints(&self.api_base, &self.auth_base))
    }

    /// Convenience for [`ClientBuilder::new`].
    pub fn builder() -> ClientBuilder {
        ClientBuilder::new()
    }

    /// Return the device id currently associated with this client.
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    /// Return the [`TokenManager`] so callers can read the rotated
    /// refresh token and persist it.
    pub fn tokens(&self) -> &TokenManager {
        &self.tokens
    }

    /// Return a handle to the underlying HTTP client for direct requests
    /// (e.g. downloading file content).
    pub fn http_client(&self) -> &reqwest::Client {
        &self.http
    }

    /// Return the HTTP client used for potentially long-running OSS uploads.
    /// It inherits the configured proxy but has a longer per-request timeout.
    pub fn upload_http_client(&self) -> &reqwest::Client {
        &self.upload_http
    }

    /// Direct original downloads use inactivity limits, with the same proxy
    /// and user agent as metadata requests. No account headers are attached.
    pub fn download_http_client(&self) -> &reqwest::Client {
        if self.content_mode.tries_guest() { &self.guest_download_http } else { &self.download_http }
    }

    /// Read the signed-in user's display name from PikPak's account service.
    /// This is supplemental UI metadata, so keep its timeout shorter than a
    /// Drive request and never expose the rest of the account response.
    pub async fn account_profile(&self) -> Result<AccountProfile> {
        for attempt in 0..2 {
            let token = self.tokens.access_token().await?;
            let response = self.http
                .get(format!("{}/v1/user/me", self.auth_base.trim_end_matches('/')))
                .bearer_auth(&token)
                .header("X-Device-Id", &self.device_id)
                .timeout(Duration::from_secs(8))
                .send().await?;
            if response.status() == reqwest::StatusCode::UNAUTHORIZED {
                if self.tokens.is_personal_access_token() {
                    return Err(Error::SessionRejected("Personal Access Token expired or revoked. Replace it in Settings > Accounts."));
                }
                if attempt == 0 {
                    self.tokens.reject_access_token(&token).await?;
                    continue;
                }
            }
            let mut profile: AccountProfile = response.error_for_status()?.json().await?;
            profile.name = profile.name.trim().to_owned();
            self.tokens.confirm_user_id(&profile.sub).await?;
            return Ok(profile);
        }
        unreachable!("the second account request returns its result")
    }

    /// Return the user's storage quota.
    pub async fn quota(&self) -> Result<Quota> {
        let action = "GET:/drive/v1/about";
        let url = format!("{}/drive/v1/about", self.api_base.trim_end_matches('/'));

        let resp = self.drive_get(&url, action, &[]).await?;
        let body: AboutResponse = serde_json::from_str(&resp)?;
        Ok(Quota {
            total: body.quota.limit,
            used: body.quota.usage,
        })
    }

    /// Return storage and account-wide monthly transfer counters.
    pub async fn quota_details(&self) -> Result<crate::QuotaDetails> {
        // Reuse the drive connection for the quantity request instead of
        // opening concurrent TLS connections for two small metadata reads.
        let storage = self.quota().await?;
        let transfer = self.transfer_quota().await?;
        Ok(crate::QuotaDetails { storage, transfer })
    }

    /// The official web app reads monthly traffic from the quantity service.
    /// Desktop sessions do not consistently expose these counters in /about.
    pub async fn transfer_quota(&self) -> Result<crate::TransferQuota> {
        let url = format!("{}/vip/v1/quantity/list", self.api_base.trim_end_matches('/'));
        let mut refreshed_auth = false;
        let mut network_retries = 0;
        loop {
            let access = self.tokens.access_token().await?;
            let request = self.http.get(&url)
                .query(&[("type", "transfer")])
                .bearer_auth(&access)
                .header("X-Device-Id", &self.device_id)
                .timeout(Duration::from_secs(10))
                .send().await;
            let response = match request {
                Ok(response) => response,
                Err(error) if network_retries < 2 && (error.is_connect() || error.is_timeout() || error.is_request() || error.is_body()) => {
                    network_retries += 1;
                    tokio::time::sleep(Duration::from_millis(250 * network_retries)).await;
                    continue;
                }
                Err(error) => return Err(error.into()),
            };
            if response.status() == reqwest::StatusCode::UNAUTHORIZED && !refreshed_auth && !self.tokens.is_personal_access_token() {
                refreshed_auth = true;
                self.tokens.reject_access_token(&access).await?;
                continue;
            }
            if response.status().is_server_error() && network_retries < 2 {
                network_retries += 1;
                tokio::time::sleep(Duration::from_millis(250 * network_retries)).await;
                continue;
            }
            let body: Value = response.error_for_status()?.json().await?;
            if !body["base"].is_object() || !body["transfer"].is_object() {
                return Err(Error::Api { status: 200, message: "PikPak returned unrecognized transfer counters".into() });
            }
            return Ok(crate::TransferQuota::from_quantity(&body));
        }
    }

    /// List the direct children of a folder. Pass `""` for the root.
    pub async fn list_folder(&self, parent_id: &str) -> Result<Vec<FileInfo>> {
        let action = "GET:/drive/v1/files";
        let url = format!("{}/drive/v1/files", self.api_base.trim_end_matches('/'));

        let mut all = Vec::new();
        let mut page_token: Option<String> = None;
        let mut seen_page_tokens = HashSet::new();

        loop {
            let mut params: Vec<(&str, String)> = vec![
                ("parent_id", parent_id.to_string()),
                ("limit", "500".to_string()),
                ("thumbnail_size", "SIZE_MEDIUM".to_string()),
                ("with_audit", "false".to_string()),
                (
                    "filters",
                    r#"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#.to_string(),
                ),
            ];
            if let Some(t) = page_token.as_deref() {
                params.push(("page_token", t.to_string()));
            }

            let resp = self.drive_get(&url, action, &params).await?;
            if self.content_mode.tries_guest() { self.guest.remember_listing(&resp); }
            let body: ListResponse = serde_json::from_str(&resp)?;
            all.extend(body.files);

            match validated_next_page_token(body.next_page_token, &mut seen_page_tokens)? {
                Some(token) => page_token = Some(token),
                None => break,
            }
        }

        Ok(all)
    }

    /// Upload recovery must also see incomplete placeholders. The normal
    /// Browser listing deliberately filters those out.
    pub(crate) async fn list_upload_candidates(&self, parent_id: &str) -> Result<Vec<FileInfo>> {
        let url = format!("{}/drive/v1/files", self.api_base.trim_end_matches('/'));
        let mut all = Vec::new();
        let mut page: Option<String> = None;
        let mut seen = HashSet::new();
        loop {
            let mut query = vec![("parent_id", parent_id.to_string()), ("limit", "500".into()),
                ("filters", r#"{"trashed":{"eq":false}}"#.into())];
            if let Some(token) = &page { query.push(("page_token", token.to_string())); }
            let response = self.drive_get(&url, "GET:/drive/v1/files", &query).await?;
            let body: ListResponse = serde_json::from_str(&response)?;
            all.extend(body.files);
            if all.len() > 200_000 { return Err(Error::InvalidPath("upload recovery folder is too large")); }
            page = validated_next_page_token(body.next_page_token, &mut seen)?;
            if page.is_none() { return Ok(all); }
        }
    }

    /// List one bounded page of direct folder children for an interactive UI.
    /// The limit is clamped to PikPak's observed 1...=500 range.
    pub async fn list_folder_page(
        &self,
        parent_id: &str,
        page_token: Option<&str>,
        limit: usize,
    ) -> Result<FilePage> {
        let action = "GET:/drive/v1/files";
        let url = format!("{}/drive/v1/files", self.api_base.trim_end_matches('/'));
        let mut params: Vec<(&str, String)> = vec![
            ("parent_id", parent_id.to_string()),
            ("limit", limit.clamp(1, 500).to_string()),
            ("thumbnail_size", "SIZE_LARGE".to_string()),
            ("with_audit", "true".to_string()),
            (
                "filters",
                r#"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#.to_string(),
            ),
        ];
        if let Some(token) = page_token.filter(|value| !value.is_empty()) {
            params.push(("page_token", token.to_string()));
        }

        let resp = self.drive_get(&url, action, &params).await?;
        if self.content_mode.tries_guest() { self.guest.remember_listing(&resp); }
        let body: ListResponse = serde_json::from_str(&resp)?;
        Ok(FilePage {
            files: body.files,
            next_page_token: body.next_page_token.filter(|value| !value.is_empty()),
        })
    }

    /// Move files or folders to PikPak's Trash. This is recoverable from the
    /// official PikPak clients until the Trash is emptied.
    pub async fn trash_files(&self, ids: &[String]) -> Result<()> {
        if ids.is_empty() {
            return Err(Error::InvalidPath("at least one file id is required"));
        }

        let action = "POST:/drive/v1/files:batchTrash";
        let url = format!(
            "{}/drive/v1/files:batchTrash",
            self.api_base.trim_end_matches('/'),
        );
        let body = serde_json::json!({ "ids": ids });
        self.drive_request(reqwest::Method::POST, &url, action, &[], Some(&body))
            .await?;
        Ok(())
    }

    /// Move files or folders below another PikPak folder. An empty
    /// `parent_id` targets the drive root.
    pub async fn move_files(&self, ids: &[String], parent_id: &str) -> Result<()> {
        if ids.is_empty() {
            return Err(Error::InvalidPath("at least one file id is required"));
        }
        if ids.iter().any(|id| id == parent_id) {
            return Err(Error::InvalidPath("a folder cannot be moved inside itself"));
        }

        let action = "POST:/drive/v1/files:batchMove";
        let url = format!(
            "{}/drive/v1/files:batchMove",
            self.api_base.trim_end_matches('/'),
        );
        let body = batch_move_body(ids, parent_id);
        self.drive_request(reqwest::Method::POST, &url, action, &[], Some(&body))
            .await?;
        Ok(())
    }

    /// Restore the same cloud IDs from Trash; never recreate or re-upload them.
    pub async fn untrash_files(&self, ids: &[String]) -> Result<()> {
        if ids.is_empty() { return Err(Error::InvalidPath("at least one file id is required")); }
        let action = "POST:/drive/v1/files:batchUntrash";
        let url = format!("{}/drive/v1/files:batchUntrash", self.api_base.trim_end_matches('/'));
        self.drive_request(reqwest::Method::POST, &url, action, &[], Some(&serde_json::json!({"ids": ids}))).await?;
        Ok(())
    }

    pub async fn file_undo_state(&self, id: &str) -> Result<crate::file_undo::CloudFileState> {
        Ok(serde_json::from_value(self.file_metadata(id).await?)?)
    }

    /// Refresh an original's metadata without downloading its content.
    pub async fn file_metadata(&self, id: &str) -> Result<serde_json::Value> {
        let mut url = reqwest::Url::parse(&format!("{}/drive/v1/files/", self.api_base.trim_end_matches('/')))
            .map_err(|_| Error::InvalidPath("invalid drive endpoint"))?;
        url.path_segments_mut().map_err(|_| Error::InvalidPath("invalid drive endpoint"))?.pop_if_empty().push(id);
        let response = self.drive_get(url.as_str(), "GET:/drive/v1/files/:id", &[]).await?;
        Ok(serde_json::from_str(&response)?)
    }

    /// Include unfinished upload placeholders when checking a folder before undo.
    pub async fn folder_has_live_children(&self, id: &str) -> Result<bool> {
        let url = format!("{}/drive/v1/files", self.api_base.trim_end_matches('/'));
        let query = [("parent_id", id.to_string()), ("limit", "1".to_string()),
            ("filters", serde_json::json!({"trashed":{"eq":false}}).to_string())];
        let response = self.drive_get(&url, "GET:/drive/v1/files", &query).await?;
        let page: crate::FilePage = serde_json::from_str(&response)?;
        Ok(!page.files.is_empty() || page.next_page_token.is_some_and(|token| !token.is_empty()))
    }

    /// Rename one PikPak file or folder without changing its parent. PikPak's
    /// Drive service uses the same item endpoint for both kinds, so callers do
    /// not need to fetch or guess the item's type first.
    pub async fn rename_file(&self, file_id: &str, name: &str) -> Result<()> {
        let file_id = file_id.trim();
        if file_id.is_empty() {
            return Err(Error::InvalidPath("file id must not be empty"));
        }
        let name = name.trim();
        if name.is_empty() {
            return Err(Error::InvalidPath("file name must not be empty"));
        }

        let action = "PATCH:/drive/v1/files/:id";
        let url = format!(
            "{}/drive/v1/files/{}",
            self.api_base.trim_end_matches('/'),
            file_id,
        );
        let body = rename_file_body(name);
        self.drive_request(reqwest::Method::PATCH, &url, action, &[], Some(&body))
            .await?;
        Ok(())
    }

    /// Create one folder below `parent_id` and return the new opaque folder
    /// id. Folder trees are built a level at a time so local directory uploads
    /// can preserve their structure without flattening file names.
    pub async fn create_folder(&self, parent_id: &str, name: &str) -> Result<String> {
        self.create_folder_retry(parent_id, name, true).await
    }

    pub(crate) async fn create_folder_once(&self, parent_id: &str, name: &str) -> Result<String> {
        self.create_folder_retry(parent_id, name, false).await
    }

    async fn create_folder_retry(&self, parent_id: &str, name: &str, retry_network: bool) -> Result<String> {
        if name.trim().is_empty() {
            return Err(Error::InvalidPath("folder name must not be empty"));
        }

        let action = "POST:/drive/v1/files";
        let url = format!("{}/drive/v1/files", self.api_base.trim_end_matches('/'));
        let body = serde_json::json!({
            "kind": "drive#folder",
            "parent_id": parent_id,
            "name": name
        });
        let response = self
            .drive_request_with_retry(reqwest::Method::POST, &url, action, &[], Some(&body), retry_network)
            .await?;
        let response: CreateFolderResponse = serde_json::from_str(&response)?;
        response
            .file
            .and_then(|file| file.id)
            .or(response.id)
            .filter(|id| !id.trim().is_empty())
            .ok_or_else(|| Error::Api {
                status: 502,
                message: "PikPak created a folder without returning its id".to_string(),
            })
    }

    /// Resolve the GCID required by PikPak's cloud-extraction service. Folder
    /// listings normally include it as `hash`; fetching fresh file metadata is
    /// a safe fallback for an older cached row that omitted that field.
    pub async fn resolve_archive_gcid(&self, file_id: &str, hinted_gcid: &str) -> Result<String> {
        let file_id = file_id.trim();
        if file_id.is_empty() {
            return Err(Error::InvalidPath("archive file id must not be empty"));
        }
        if let Some(gcid) = normalized_gcid(hinted_gcid) {
            return Ok(gcid);
        }

        let detail = self.get_file_detail(file_id).await?;
        if let Some(gcid) = detail.hash.as_deref().and_then(normalized_gcid) {
            return Ok(gcid);
        }
        if let Ok(url) = url::Url::parse(&detail.web_content_link) {
            if let Some(gcid) = url
                .query_pairs()
                .find(|(key, _)| key.eq_ignore_ascii_case("gcid"))
                .and_then(|(_, value)| normalized_gcid(&value))
            {
                return Ok(gcid);
            }
        }

        Err(Error::InvalidPath(
            "PikPak did not provide the archive content identifier required for cloud extraction",
        ))
    }

    /// Inspect one directory inside a ZIP, RAR, or 7z file without
    /// downloading the archive. An empty `path` lists its root.
    pub async fn list_archive(
        &self,
        file_id: &str,
        gcid: &str,
        path: &str,
        password: &str,
    ) -> Result<ArchiveListing> {
        let file_id = file_id.trim();
        let gcid = normalized_gcid(gcid).ok_or(Error::InvalidPath(
            "archive GCID must be a 40-character hexadecimal value",
        ))?;
        if file_id.is_empty() {
            return Err(Error::InvalidPath("archive file id must not be empty"));
        }

        let action = "POST:/decompress/v1/list";
        let url = format!("{}/decompress/v1/list", self.api_base.trim_end_matches('/'),);
        let body = serde_json::json!({
            "gcid": gcid,
            "path": path,
            "file_id": file_id,
            "password": password,
        });
        let response = self
            .drive_request(reqwest::Method::POST, &url, action, &[], Some(&body))
            .await?;
        serde_json::from_str(&response).map_err(|error| Error::Api {
            status: 502,
            message: format!("PikPak returned unreadable archive contents: {error}"),
        })
    }

    /// Start PikPak's server-side extraction task. `files` contains untouched
    /// entry objects returned by [`Client::list_archive`].
    pub async fn start_archive_extraction(
        &self,
        file_id: &str,
        gcid: &str,
        password: &str,
        files: &[Value],
    ) -> Result<ArchiveExtractionTask> {
        if files.is_empty() {
            return Err(Error::InvalidPath(
                "at least one archive entry must be selected",
            ));
        }
        let gcid = normalized_gcid(gcid).ok_or(Error::InvalidPath(
            "archive GCID must be a 40-character hexadecimal value",
        ))?;
        let body = archive_extract_body(file_id.trim(), &gcid, password, files);
        let action = "POST:/decompress/v1/decompress";
        let url = format!(
            "{}/decompress/v1/decompress",
            self.api_base.trim_end_matches('/'),
        );
        let response = self
            .drive_request(reqwest::Method::POST, &url, action, &[], Some(&body))
            .await?;
        serde_json::from_str(&response).map_err(|error| Error::Api {
            status: 502,
            message: format!("PikPak returned an unreadable extraction task: {error}"),
        })
    }

    /// Read the latest server-side extraction percentage and result file id.
    pub async fn archive_extraction_progress(
        &self,
        task_id: &str,
    ) -> Result<ArchiveExtractionProgress> {
        let task_id = task_id.trim();
        if task_id.is_empty() {
            return Err(Error::InvalidPath(
                "archive extraction task id must not be empty",
            ));
        }
        let action = "GET:/decompress/v1/progress";
        let url = format!(
            "{}/decompress/v1/progress",
            self.api_base.trim_end_matches('/'),
        );
        let response = self
            .drive_get(&url, action, &[("task_id", task_id.to_string())])
            .await?;
        serde_json::from_str(&response).map_err(|error| Error::Api {
            status: 502,
            message: format!("PikPak returned unreadable extraction progress: {error}"),
        })
    }

    /// Create a PikPak file upload task. The service either completes an
    /// instant upload from the GCID, or returns temporary OSS credentials for
    /// sending the local bytes. Callers must never persist those credentials.
    pub async fn create_upload_task(
        &self,
        parent_id: &str,
        name: &str,
        size: u64,
        gcid: &str,
    ) -> Result<UploadTask> {
        self.create_upload_task_retry(parent_id, name, size, gcid, true).await
    }

    pub(crate) async fn create_upload_task_once(&self, parent_id: &str, name: &str, size: u64, gcid: &str) -> Result<UploadTask> {
        self.create_upload_task_retry(parent_id, name, size, gcid, false).await
    }

    async fn create_upload_task_retry(&self, parent_id: &str, name: &str, size: u64, gcid: &str, retry_network: bool) -> Result<UploadTask> {
        if name.trim().is_empty() {
            return Err(Error::InvalidPath("upload file name must not be empty"));
        }
        if gcid.len() != 40 || !gcid.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(Error::InvalidPath(
                "upload GCID must be a 40-character hex digest",
            ));
        }

        let action = "POST:/drive/v1/files";
        let url = format!("{}/drive/v1/files", self.api_base.trim_end_matches('/'));
        let body = serde_json::json!({
            "kind": "drive#file",
            "name": name,
            "size": size,
            "hash": gcid.to_ascii_uppercase(),
            "upload_type": "UPLOAD_TYPE_RESUMABLE",
            "objProvider": { "provider": "UPLOAD_TYPE_UNKNOWN" },
            "parent_id": parent_id,
            "folder_type": "NORMAL"
        });
        let response = self
            .drive_request_with_retry(reqwest::Method::POST, &url, action, &[], Some(&body), retry_network)
            .await?;
        let response: UploadTaskResponse = serde_json::from_str(&response)?;
        let file = response.file.ok_or_else(|| Error::Api {
            status: 502,
            message: "PikPak returned an upload task without file metadata".to_string(),
        })?;
        let completed = file.phase.as_deref() == Some("PHASE_TYPE_COMPLETE");
        if !completed && response.resumable.is_none() {
            return Err(Error::Api {
                status: 502,
                message: "PikPak returned an incomplete upload task without a transfer method"
                    .to_string(),
            });
        }
        Ok(UploadTask {
            file_id: file.id,
            completed,
            oss: response.resumable.map(|resumable| resumable.params),
        })
    }

    /// Reconcile a response lost during shutdown without recreating a file
    /// whose server-side upload already finished. No storage keys are saved.
    pub async fn completed_upload_matches(&self, file_id: &str, gcid: &str, size: u64) -> Result<bool> {
        match self.get_file_detail(file_id).await {
            Ok(detail) if detail.phase.as_deref() == Some("PHASE_TYPE_COMPLETE") => {
                if detail.size == size && detail.hash.as_deref().is_some_and(|value| value.eq_ignore_ascii_case(gcid)) {
                    Ok(true)
                } else {
                    Err(Error::Api { status: 409, message: "saved upload is complete but its identity could not be verified; it was not uploaded again".into() })
                }
            }
            Ok(_) => Ok(false),
            Err(Error::Api { status: 404, .. }) => Ok(false),
            Err(Error::Api { ref message, .. }) if message.contains("file_not_found") => Ok(false),
            Err(error) => Err(error),
        }
    }

    /// Execute a GET against the drive API with bearer auth + captcha token.
    ///
    /// If the server returns error_code 9 (captcha expired), refreshes the
    /// captcha and retries exactly once.
    async fn drive_get(&self, url: &str, action: &str, query: &[(&str, String)]) -> Result<String> {
        self.drive_request(reqwest::Method::GET, url, action, query, None)
            .await
    }

    /// Execute an authenticated drive request, applying the same bounded
    /// retries to reads and mutations. Mutating callers provide a JSON body;
    /// GET callers leave it empty.
    pub(crate) async fn drive_request(
        &self,
        method: reqwest::Method,
        url: &str,
        action: &str,
        query: &[(&str, String)],
        body: Option<&Value>,
    ) -> Result<String> {
        self.drive_request_with_retry(method, url, action, query, body, true).await
    }

    /// Creating a task or share is not idempotent. A lost response must not
    /// silently submit the same mutation again. Definitive auth rejections
    /// can still refresh credentials once before the service accepts it.
    pub(crate) async fn drive_request_with_retry(
        &self, method: reqwest::Method, url: &str, action: &str,
        query: &[(&str, String)], body: Option<&Value>, retry_network: bool,
    ) -> Result<String> {
        // 401 and captcha-expiry each get one targeted retry; transient
        // network failures and 5xx/429 get bounded exponential-backoff retries.
        let mut auth_retried = false;
        let mut captcha_retried = false;
        let mut net_retries: u32 = 0;

        loop {
            let access = self.tokens.access_token().await?;
            let captcha = if self.tokens.is_personal_access_token() { None }
                else { Some(self.captcha.token_for(action).await?) };

            let mut request = self
                .http
                .request(method.clone(), url)
                .bearer_auth(&access)
                .header("X-Device-Id", &self.device_id);
            if let Some(captcha) = &captcha { request = request.header("X-Captcha-Token", captcha); }
            if !query.is_empty() {
                request = request.query(query);
            }
            if let Some(body) = body {
                request = request.json(body);
            }
            let send = request.send().await;

            let resp = match send {
                Ok(r) => r,
                Err(e) if retry_network && is_transient(&e) && net_retries < MAX_NET_RETRIES => {
                    let delay = backoff_delay(net_retries);
                    tracing::debug!(action = %action, error = %e, ?delay, "transient network error, retrying");
                    net_retries += 1;
                    tokio::time::sleep(delay).await;
                    continue;
                }
                Err(e) => return Err(e.into()),
            };

            let status = resp.status();
            let retry_after = crate::download_policy::retry_after(resp.headers());
            let text = match resp.text().await {
                Ok(t) => t,
                Err(e) if retry_network && is_transient(&e) && net_retries < MAX_NET_RETRIES => {
                    let delay = backoff_delay(net_retries);
                    net_retries += 1;
                    tokio::time::sleep(delay).await;
                    continue;
                }
                Err(e) => return Err(e.into()),
            };

            if status.is_success() {
                return Ok(text);
            }

            if self.tokens.is_personal_access_token() && status == reqwest::StatusCode::UNAUTHORIZED {
                return Err(Error::SessionRejected("Personal Access Token expired or revoked. Replace it in Settings > Accounts."));
            }

            if status == reqwest::StatusCode::UNAUTHORIZED && !auth_retried {
                tracing::debug!(
                    action = %action,
                    "access token rejected, invalidating and retrying"
                );
                auth_retried = true;
                self.tokens.reject_access_token(&access).await?;
                continue;
            }

            if !captcha_retried && !self.tokens.is_personal_access_token() {
                if let Ok(err) = serde_json::from_str::<ApiError>(&text) {
                    if err.error_code == 9 {
                        tracing::debug!(
                            action = %action,
                            "captcha expired, refreshing and retrying"
                        );
                        captcha_retried = true;
                        let _ = self.captcha.refresh(action, captcha.as_deref()).await?;
                        continue;
                    }
                }
            }

            // Server-side transient failures (5xx, 429) are worth a backoff retry.
            if crate::download_policy::transient_status(status.as_u16())
                && retry_network && net_retries < MAX_NET_RETRIES
            {
                let delay = backoff_delay(net_retries).max(retry_after.unwrap_or_default());
                tracing::debug!(action = %action, status = %status.as_u16(), ?delay, "server error, retrying");
                net_retries += 1;
                tokio::time::sleep(delay).await;
                continue;
            }

            if crate::download_policy::transient_status(status.as_u16()) {
                if let Some(delay) = retry_after { return Err(Error::RetryAfter { status: status.as_u16(), delay }); }
            }
            return Err(Error::Api {
                status: status.as_u16(),
                message: text.replace(&access, "[credential redacted]"),
            });
        }
    }

    /// Restore selected files or folders from a PikPak share into the user's
    /// default "Pack From Shared" area. PikPak performs this copy server-side,
    /// so whole folders are accepted as one recursive restore root.
    pub async fn restore_shared_files(
        &self,
        share_id: &str,
        pass_code_token: &str,
        file_ids: &[String],
    ) -> Result<ShareRestoreResult> {
        let share_id = share_id.trim();
        if share_id.is_empty() {
            return Err(Error::InvalidPath("share id must not be empty"));
        }
        let mut seen = HashSet::new();
        let file_ids = file_ids
            .iter()
            .map(|id| id.trim())
            .filter(|id| !id.is_empty() && seen.insert((*id).to_string()))
            .collect::<Vec<_>>();
        if file_ids.is_empty() {
            return Err(Error::InvalidPath(
                "at least one shared file or folder is required",
            ));
        }

        let action = "POST:/drive/v1/share/restore";
        let url = format!(
            "{}/drive/v1/share/restore",
            self.api_base.trim_end_matches('/'),
        );
        let body = serde_json::json!({
            "kind": "drive#file",
            "share_id": share_id,
            "pass_code_token": pass_code_token,
            "file_ids": file_ids,
        });
        let response = self
            .drive_request(reqwest::Method::POST, &url, action, &[], Some(&body))
            .await?;
        let value: Value = serde_json::from_str(&response).map_err(|error| Error::Api {
            status: 502,
            message: format!("PikPak returned unreadable restore data: {error}"),
        })?;
        let error_code = value
            .get("error_code")
            .and_then(|value| {
                value
                    .as_i64()
                    .or_else(|| value.as_str().and_then(|code| code.parse().ok()))
            })
            .unwrap_or(0);
        if error_code != 0 {
            let message = value
                .get("error_description")
                .or_else(|| value.get("error"))
                .and_then(Value::as_str)
                .filter(|message| !message.trim().is_empty())
                .unwrap_or("PikPak rejected the shared-item save request");
            return Err(Error::Api {
                status: 400,
                message: message.to_string(),
            });
        }
        let restore_status = value
            .get("restore_status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if restore_status.is_empty() || restore_status == "RESTORE_UNKNOWN" {
            let message = value
                .get("share_status_text")
                .and_then(Value::as_str)
                .filter(|message| !message.trim().is_empty())
                .unwrap_or("PikPak returned an unknown save status");
            return Err(Error::Api {
                status: 502,
                message: message.to_string(),
            });
        }
        Ok(ShareRestoreResult {
            restore_status,
            restore_task_id: value
                .get("restore_task_id")
                .and_then(Value::as_str)
                .filter(|id| !id.trim().is_empty())
                .map(str::to_string),
            saved_count: file_ids.len(),
        })
    }

    /// Resolve a Unix-style path (e.g. `"/My Pack/videos"`) to the
    /// corresponding folder id by walking each path segment.
    ///
    /// Returns `Ok(id)` on success. An empty path or `"/"` resolves to the
    /// root (empty string, matching PikPak convention).
    pub async fn resolve_path(&self, path: &str) -> Result<String> {
        let normalized = path.trim_matches('/');
        if normalized.is_empty() {
            return Ok(String::new());
        }

        let segments: Vec<&str> = normalized.split('/').filter(|s| !s.is_empty()).collect();
        let mut parent_id = String::new();

        for seg in &segments {
            let children = self.list_folder(&parent_id).await?;
            let found = children
                .iter()
                .find(|f| f.kind.is_folder() && f.name == *seg);

            match found {
                Some(f) => parent_id = f.id.clone(),
                None => {
                    return Err(Error::NotFound {
                        path: path.to_string(),
                        segment: (*seg).to_string(),
                    });
                }
            }
        }

        Ok(parent_id)
    }

    /// Resolve a path to a [`FileInfo`]. If the path points to a file
    /// (i.e. the last segment is a file, not a folder), returns that file's
    /// info; otherwise returns the folder's info.
    pub async fn resolve_path_info(&self, path: &str) -> Result<FileInfo> {
        let normalized = path.trim_matches('/');
        if normalized.is_empty() {
            return Err(Error::InvalidPath("path must not be empty"));
        }

        let segments: Vec<&str> = normalized.split('/').filter(|s| !s.is_empty()).collect();
        let mut parent_id = String::new();

        for (i, seg) in segments.iter().enumerate() {
            let is_last = i == segments.len() - 1;
            let children = self.list_folder(&parent_id).await?;
            // Middle segments must be folders; only the final segment may be
            // a file. Restricting the search avoids matching a same-named
            // file that happens to precede the intended folder.
            let found = if is_last {
                children.iter().find(|f| f.name == **seg)
            } else {
                children
                    .iter()
                    .find(|f| f.kind.is_folder() && f.name == **seg)
            };

            match found {
                Some(f) => {
                    if is_last {
                        return Ok(f.clone());
                    }
                    parent_id = f.id.clone();
                }
                None => {
                    return Err(Error::NotFound {
                        path: path.to_string(),
                        segment: (*seg).to_string(),
                    });
                }
            }
        }

        unreachable!("resolve_path_info loop must return inside")
    }

    /// Get a download URL for a file by its id.
    pub async fn similarity_file_revision(&self, file_id: &str, parent_id: &str) -> Result<(u64, Option<String>)> {
        if self.content_mode.tries_guest() {
            if let Some(file) = self.content_mode.guest_result(self.guest_metadata(file_id, Some(parent_id), true).await)? {
                let file = file.info;
                return Ok((file.size, file.hash.filter(|s| !s.trim().is_empty())
                    .or_else(|| file.modified_time.filter(|s| !s.trim().is_empty()))));
            }
        }
        let body = self.get_file_detail(file_id).await?;
        if body.trashed { return Err(Error::Api { status:404, message:"The original is in Trash".into() }); }
        Ok((body.size, body.hash.filter(|s| !s.trim().is_empty())
            .or_else(|| body.modified_time.filter(|s| !s.trim().is_empty()))))
    }

    /// Bind a similarity original to the revision returned with its signed URL.
    pub(crate) async fn similarity_download_info(&self, file_id: &str, parent_id: &str) -> Result<(DownloadInfo, Option<String>)> {
        if self.content_mode.tries_guest() {
            if let Some((download, file)) = self.content_mode.guest_result(self.guest_download_info(file_id, Some(parent_id)).await)? {
                return Ok((download, file.info.hash));
            }
        }
        let body = self.get_file_detail(file_id).await?;
        if body.trashed { return Err(Error::Api { status:404, message:"The original is in Trash".into() }); }
        let revision = body.hash.filter(|s| !s.trim().is_empty())
            .or_else(|| body.modified_time.filter(|s| !s.trim().is_empty()));
        Ok((DownloadInfo { web_content_link: body.web_content_link, name: body.name, size: body.size }, revision))
    }

    /// Get a download URL for a file by its id.
    pub async fn get_download_url(&self, file_id: &str) -> Result<DownloadInfo> {
        if self.content_mode.tries_guest() {
            if let Some((download, _)) = self.content_mode.guest_result(self.guest_download_info(file_id, None).await)? {
                return Ok(download);
            }
        }
        let body = self.get_file_detail(file_id).await?;

        Ok(DownloadInfo {
            web_content_link: body.web_content_link,
            name: body.name,
            size: body.size,
        })
    }

    /// Get display metadata and a short-lived content link suitable for an
    /// on-demand image, audio, or video preview.
    pub async fn get_preview_info(&self, file_id: &str) -> Result<PreviewInfo> {
        self.get_preview_info_in_parent(file_id, None).await
    }

    pub async fn get_preview_info_in_parent(&self, file_id: &str, parent_id: Option<&str>) -> Result<PreviewInfo> {
        if self.content_mode.tries_guest() {
            if let Some((download, file)) = self.content_mode.guest_result(self.guest_download_info(file_id, parent_id).await)? {
                return Ok(crate::share::original_preview(&file.info, download.web_content_link));
            }
        }
        let body = self.get_file_detail(file_id).await?;
        let mut sources = preview_sources(&body.medias, &body.web_content_link);
        enrich_avi_source_codec(
            &self.http,
            &body.name,
            body.mime_type.as_deref(),
            &mut sources,
            None,
        )
        .await;
        let content_link = sources
            .first()
            .map(|source| source.url.clone())
            .ok_or(Error::InvalidPath("file has no preview or content link"))?;

        Ok(PreviewInfo {
            name: body.name,
            size: body.size,
            mime_type: body.mime_type,
            thumbnail_link: body.thumbnail_link,
            icon_link: body.icon_link,
            content_link,
            sources,
        })
    }

    /// Resolve in the known account folder even when the quota blocks the
    /// account file-details endpoint. A saved ID alone cannot identify a share.
    pub async fn get_download_url_for_file(&self, file: &FileInfo) -> Result<DownloadInfo> {
        if self.content_mode.tries_guest() {
            if let Some((download, _)) = self.content_mode.guest_result(self.guest_download_info(&file.id, file.parent_id.as_deref()).await)? {
                return Ok(download);
            }
        }
        // Use the saved account ID after a failed guest lookup, never an
        // unverified original-share ID. Do not repeat the guest attempt here.
        let body = self.get_file_detail(&file.id).await?;
        Ok(DownloadInfo { web_content_link: body.web_content_link, name: body.name, size: body.size })
    }

    async fn guest_download_info(&self, file_id: &str, parent_id: Option<&str>) -> Result<(DownloadInfo, crate::guest::GuestFile)> {
        let file = self.guest_metadata(file_id, parent_id, false).await?;
        let download = self.guest.download(&file, self).await?;
        Ok((download, file))
    }

    async fn guest_metadata(&self, file_id: &str, parent_id: Option<&str>, fresh: bool) -> Result<crate::guest::GuestFile> {
        if !fresh {
            if let Some(file) = self.guest.cached(file_id, parent_id) { return Ok(file); }
        }
        let parent = parent_id.ok_or(Error::Guest("The file's folder is unknown. Refresh its folder and try again."))?;
        let url = format!("{}/drive/v1/files", self.api_base.trim_end_matches('/'));
        let mut token: Option<String> = None;
        let mut seen = HashSet::new();
        loop {
            let mut query = vec![("parent_id", parent.to_string()), ("limit", "500".into()),
                ("filters", serde_json::json!({"id":{"eq":file_id},"trashed":{"eq":false},
                    "phase":{"eq":"PHASE_TYPE_COMPLETE"}}).to_string())];
            if let Some(token) = &token { query.push(("page_token", token.clone())); }
            let raw = self.drive_get(&url, "GET:/drive/v1/files", &query).await?;
            #[derive(Deserialize)]
            struct Page { files: Vec<crate::guest::GuestFile>, #[serde(default)] next_page_token: Option<String> }
            let page: Page = serde_json::from_str(&raw)?;
            self.guest.remember_listing(&raw);
            if let Some(file) = page.files.into_iter().find(|file| file.info.id == file_id
                && file.info.parent_id.as_deref().unwrap_or("") == parent) { return Ok(file); }
            match validated_next_page_token(page.next_page_token, &mut seen)? {
                Some(next) => token = Some(next),
                None => return Err(Error::Api { status: 404, message: "The file is no longer in this folder. Refresh it and try again.".into() }),
            }
        }
    }

    async fn get_file_detail(&self, file_id: &str) -> Result<FileDetailResponse> {
        let action = "GET:/drive/v1/files/:id";
        let url = format!(
            "{}/drive/v1/files/{}",
            self.api_base.trim_end_matches('/'),
            file_id,
        );

        let query = [
            ("_magic", "2021".to_string()),
            ("thumbnail_size", "SIZE_LARGE".to_string()),
            // Ask PikPak to issue fresh signed content/media links. Without
            // FETCH the detail response can contain a cached link that still
            // looks valid but is rejected when AVPlayer opens it.
            ("usage", "FETCH".to_string()),
        ];
        let resp = self.drive_get(&url, action, &query).await?;
        Ok(serde_json::from_str(&resp)?)
    }
}

fn batch_move_body(ids: &[String], parent_id: &str) -> Value {
    serde_json::json!({
        "ids": ids,
        "to": {
            "parent_id": parent_id,
        }
    })
}

fn rename_file_body(name: &str) -> Value {
    serde_json::json!({ "name": name })
}

/// A repeated page token means the server has not proven that the listing is
/// complete. Returning partial children would be especially unsafe for the
/// empty-folder cleanup, so fail closed instead of looping or accepting it.
fn validated_next_page_token(
    next: Option<String>,
    seen: &mut HashSet<String>,
) -> Result<Option<String>> {
    let Some(token) = next.filter(|token| !token.is_empty()) else {
        return Ok(None);
    };
    if !seen.insert(token.clone()) {
        return Err(Error::IncompleteListing(
            "PikPak repeated a folder page token",
        ));
    }
    Ok(Some(token))
}

/// Download info returned by the API for a single file.
#[derive(Debug, Clone)]
pub struct DownloadInfo {
    /// Direct download URL (time-limited).
    pub web_content_link: String,
    /// File name.
    pub name: String,
    /// File size in bytes.
    pub size: u64,
}

/// Result of creating a PikPak upload task.
#[derive(Debug, Clone)]
pub struct UploadTask {
    /// Server-side file id, when the task response includes one.
    pub file_id: Option<String>,
    /// Whether PikPak completed the file server-side from its GCID.
    pub completed: bool,
    /// Temporary Alibaba OSS credentials. `None` means PikPak completed an
    /// instant upload from content already present in its storage.
    pub oss: Option<OssUploadParams>,
}

/// Short-lived object-storage parameters returned for one upload task.
/// Values stay in memory and are intentionally not serializable.
#[derive(Debug, Clone, Deserialize)]
pub struct OssUploadParams {
    pub access_key_id: String,
    pub access_key_secret: String,
    pub bucket: String,
    pub endpoint: String,
    pub key: String,
    pub security_token: String,
}

/// Metadata and a time-limited URL for an on-demand media preview.
#[derive(Debug, Clone, Serialize)]
pub struct PreviewInfo {
    /// File name.
    pub name: String,
    /// File size in bytes.
    pub size: u64,
    /// Server-reported MIME type.
    pub mime_type: Option<String>,
    /// Large thumbnail URL, when available.
    pub thumbnail_link: Option<String>,
    /// Generic icon URL, when available.
    pub icon_link: Option<String>,
    /// Preferred media-stream URL, falling back to the download URL.
    pub content_link: String,
    /// Ordered playback candidates. Native clients should try the next source
    /// when AVFoundation rejects or times out on the preferred PikPak stream.
    pub sources: Vec<PreviewSource>,
}

/// One short-lived playback candidate returned by PikPak.
#[derive(Debug, Clone, Serialize)]
pub struct PreviewSource {
    /// Signed playback URL. Never persist or log this value.
    pub url: String,
    /// PikPak's quality label, such as `Original` or `1080P`.
    pub label: Option<String>,
    /// Whether PikPak marks this as the original file rather than a transcode.
    pub is_origin: bool,
    /// Reported video codec, when present.
    pub video_codec: Option<String>,
    /// Reported audio codec, when present.
    pub audio_codec: Option<String>,
}

/// Raw archive listing returned by PikPak. Entry objects intentionally remain
/// JSON so extraction can send the first-party wire representation back
/// unchanged even when PikPak adds fields.
#[derive(Debug, Clone, Deserialize)]
pub struct ArchiveListing {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub status_text: String,
    #[serde(default)]
    pub files: Vec<Value>,
    #[serde(default)]
    pub task_id: Option<String>,
    #[serde(default)]
    pub title: String,
}

/// Response returned when PikPak accepts a cloud-extraction task.
#[derive(Debug, Clone, Deserialize)]
pub struct ArchiveExtractionTask {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub status_text: String,
    #[serde(default)]
    pub task_id: String,
}

/// Latest state of a PikPak cloud-extraction task.
#[derive(Debug, Clone, Deserialize)]
pub struct ArchiveExtractionProgress {
    #[serde(default, deserialize_with = "deserialize_f64_number_or_string")]
    pub progress: f64,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub error_description: String,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub file_id: String,
    #[serde(default, deserialize_with = "deserialize_u64_number_or_string")]
    pub expires_in: u64,
}

fn deserialize_f64_number_or_string<'de, D>(deserializer: D) -> std::result::Result<f64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    match value {
        None | Some(Value::Null) => Ok(0.0),
        Some(Value::Number(number)) => number
            .as_f64()
            .ok_or_else(|| serde::de::Error::custom("archive progress is not a finite number")),
        Some(Value::String(value)) => value.parse::<f64>().map_err(serde::de::Error::custom),
        Some(_) => Err(serde::de::Error::custom(
            "archive progress must be a number or numeric string",
        )),
    }
}

fn deserialize_u64_number_or_string<'de, D>(deserializer: D) -> std::result::Result<u64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    match value {
        None | Some(Value::Null) => Ok(0),
        Some(Value::Number(number)) => number
            .as_u64()
            .ok_or_else(|| serde::de::Error::custom("archive retry delay is not an integer")),
        Some(Value::String(value)) => value.parse::<u64>().map_err(serde::de::Error::custom),
        Some(_) => Err(serde::de::Error::custom(
            "archive retry delay must be an integer or numeric string",
        )),
    }
}

/// Derive a deterministic fallback device id from the supplied refresh token.
/// GUI clients should provide and persist an explicit device id because PikPak
/// rotates refresh tokens.
fn device_id_from(refresh_token: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(refresh_token.as_bytes());
    hex::encode(hasher.finalize())
}

/// Maximum retries for transient network / server errors (per request).
const MAX_NET_RETRIES: u32 = 4;

/// Exponential backoff for retry attempt `n` (0-based): 300ms, 600ms, 1.2s,
/// 2.4s, ... capped at 10s.
fn backoff_delay(attempt: u32) -> Duration {
    let ms = 300u64.saturating_mul(1u64 << attempt.min(5));
    Duration::from_millis(ms.min(10_000))
}

/// Whether a reqwest error is a transient network condition worth retrying.
fn is_transient(err: &reqwest::Error) -> bool {
    err.is_timeout() || err.is_connect() || err.is_request() || err.is_body()
}

#[derive(Debug, Deserialize)]
struct ApiError {
    #[serde(default)]
    error_code: i64,
    #[serde(default)]
    #[allow(dead_code)]
    error: String,
}

#[derive(Debug, Deserialize)]
struct AboutResponse {
    quota: AboutQuota,
}

#[derive(Debug, Deserialize)]
struct AboutQuota {
    #[serde(deserialize_with = "deserialize_string_to_u64")]
    limit: u64,
    #[serde(deserialize_with = "deserialize_string_to_u64")]
    usage: u64,
}

#[derive(Debug, Deserialize)]
struct ListResponse {
    files: Vec<FileInfo>,
    #[serde(default)]
    next_page_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UploadTaskResponse {
    #[serde(default)]
    resumable: Option<UploadResumableResponse>,
    #[serde(default)]
    file: Option<UploadFileResponse>,
}

/// PikPak has returned both a top-level file object and a nested `file`
/// object for this endpoint in different client generations. Accept both
/// shapes, but require a concrete id before any child upload is attempted.
#[derive(Debug, Deserialize)]
struct CreateFolderResponse {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    file: Option<UploadFileResponse>,
}

#[derive(Debug, Deserialize)]
struct UploadResumableResponse {
    params: OssUploadParams,
}

#[derive(Debug, Deserialize)]
struct UploadFileResponse {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    phase: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FileDetailResponse {
    #[serde(default)]
    trashed: bool,
    #[serde(default)]
    modified_time: Option<String>,
    #[serde(default)]
    phase: Option<String>,
    #[serde(default)]
    name: String,
    #[serde(default, deserialize_with = "deserialize_string_to_u64")]
    size: u64,
    #[serde(default)]
    web_content_link: String,
    #[serde(default)]
    mime_type: Option<String>,
    #[serde(default)]
    thumbnail_link: Option<String>,
    #[serde(default)]
    icon_link: Option<String>,
    #[serde(default)]
    hash: Option<String>,
    #[serde(default)]
    medias: Vec<MediaResponse>,
}

fn normalized_gcid(value: &str) -> Option<String> {
    let value = value.trim();
    (value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| value.to_ascii_uppercase())
}

fn archive_extract_body(file_id: &str, gcid: &str, password: &str, files: &[Value]) -> Value {
    serde_json::json!({
        "gcid": gcid,
        "password": password,
        "file_id": file_id,
        "files": files,
        // Match PikPak's first-party behavior: create the extracted result
        // beside the source archive in its current cloud folder.
        "default_parent": true,
    })
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct MediaResponse {
    #[serde(default)]
    is_origin: bool,
    #[serde(default)]
    is_default: bool,
    #[serde(default)]
    is_visible: Option<bool>,
    #[serde(default)]
    need_more_quota: bool,
    #[serde(default)]
    media_name: String,
    #[serde(default)]
    resolution_name: String,
    #[serde(default)]
    video: Option<MediaVideoResponse>,
    #[serde(default)]
    link: Option<MediaLinkResponse>,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct MediaVideoResponse {
    #[serde(default)]
    video_codec: String,
    #[serde(default)]
    audio_codec: String,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct MediaLinkResponse {
    #[serde(default)]
    url: String,
}

pub(crate) fn preview_sources(
    medias: &[MediaResponse],
    web_content_link: &str,
) -> Vec<PreviewSource> {
    let usable = |media: &&MediaResponse| {
        !media.need_more_quota
            && media
                .link
                .as_ref()
                .is_some_and(|link| !link.url.trim().is_empty() && preview_link_is_fresh(&link.url))
    };
    let visible = |media: &&MediaResponse| media.is_visible.unwrap_or(true);

    // PikPak media links are occasionally invalid or incompatible with a
    // native player. Prefer every server-side transcode before an original
    // container: this is essential for AVI/MKV files whose legacy codecs are
    // not handled by AVFoundation. Keep original/direct links as fallbacks.
    let ordered = medias
        .iter()
        .filter(usable)
        .filter(visible)
        .filter(|media| media.is_default && !media.is_origin)
        .chain(
            medias
                .iter()
                .filter(usable)
                .filter(visible)
                .filter(|media| !media.is_default && !media.is_origin),
        )
        .chain(
            medias
                .iter()
                .filter(usable)
                .filter(visible)
                .filter(|media| media.is_default && media.is_origin),
        )
        .chain(
            medias
                .iter()
                .filter(usable)
                .filter(visible)
                .filter(|media| !media.is_default && media.is_origin),
        );

    let mut seen = HashSet::new();
    let mut sources = Vec::new();
    for media in ordered {
        let Some(url) = media.link.as_ref().map(|link| link.url.trim()) else {
            continue;
        };
        if !seen.insert(url.to_string()) {
            continue;
        }
        let label = if !media.media_name.trim().is_empty() {
            Some(media.media_name.trim().to_string())
        } else if !media.resolution_name.trim().is_empty() {
            Some(media.resolution_name.trim().to_string())
        } else {
            None
        };
        let (video_codec, audio_codec) = media.video.as_ref().map_or((None, None), |video| {
            (
                nonempty_trimmed(&video.video_codec),
                nonempty_trimmed(&video.audio_codec),
            )
        });
        sources.push(PreviewSource {
            url: url.to_string(),
            label,
            is_origin: media.is_origin,
            video_codec,
            audio_codec,
        });
    }

    let direct = web_content_link.trim();
    if !direct.is_empty() && preview_link_is_fresh(direct) && seen.insert(direct.to_string()) {
        let direct_source = PreviewSource {
            url: direct.to_string(),
            label: Some("Direct file".to_string()),
            is_origin: true,
            video_codec: None,
            audio_codec: None,
        };
        sources.push(direct_source);
    }
    sources
}

/// Visibility controls PikPak's playback menu, not original-file access. The
/// guest API can issue an allowed original with is_visible=false. Honor the
/// original and quota flags instead of reusing the transcode-first menu.
pub(crate) fn original_download_url(medias: &[MediaResponse], direct: &str) -> Option<String> {
    let usable = |url: &str| !url.trim().is_empty() && preview_link_is_fresh(url);
    if usable(direct) { return Some(direct.trim().to_string()); }
    medias.iter().filter(|media| media.is_origin && !media.need_more_quota)
        .filter_map(|media| media.link.as_ref().map(|link| link.url.trim()))
        .find(|url| usable(url)).map(str::to_string)
}

/// Inspect only the bounded AVI header when PikPak has not supplied codec
/// metadata. Knowing the FourCC lets the native UI avoid a guaranteed
/// AVPlayer failure for legacy codecs without downloading the media file.
pub(crate) async fn enrich_avi_source_codec(
    http: &reqwest::Client,
    name: &str,
    mime_type: Option<&str>,
    sources: &mut [PreviewSource],
    referer: Option<&str>,
) {
    const AVI_HEADER_PROBE_BYTES: usize = 256 * 1024;
    let is_avi = name.to_ascii_lowercase().ends_with(".avi")
        || mime_type.is_some_and(|mime| {
            let mime = mime.to_ascii_lowercase();
            mime.contains("avi") || mime.contains("msvideo")
        });
    if !is_avi {
        return;
    }
    let Some(index) = sources
        .iter()
        .position(|source| source.is_origin && source.video_codec.is_none())
    else {
        return;
    };

    let mut request = http
        .get(&sources[index].url)
        .header(RANGE, format!("bytes=0-{}", AVI_HEADER_PROBE_BYTES - 1));
    if let Some(referer) = referer {
        request = request.header(REFERER, referer);
    }
    let Ok(response) = request.send().await else {
        return;
    };
    if response.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        return;
    }
    let bounded_length = response
        .headers()
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<usize>().ok())
        .is_some_and(|length| length <= AVI_HEADER_PROBE_BYTES);
    if !bounded_length {
        return;
    }
    let Ok(bytes) = response.bytes().await else {
        return;
    };
    if bytes.len() > AVI_HEADER_PROBE_BYTES {
        return;
    }
    let Some(codec) = avi_video_fourcc(&bytes) else {
        return;
    };
    for source in sources
        .iter_mut()
        .filter(|source| source.is_origin && source.video_codec.is_none())
    {
        source.video_codec = Some(codec.clone());
    }
}

fn avi_video_fourcc(header: &[u8]) -> Option<String> {
    if header.len() < 12 || &header[0..4] != b"RIFF" || &header[8..12] != b"AVI " {
        return None;
    }
    let position = header.windows(4).position(|window| window == b"vids")?;
    let raw = header.get(position + 4..position + 8)?;
    if !raw
        .iter()
        .all(|byte| byte.is_ascii_graphic() || *byte == b' ')
    {
        return None;
    }
    let codec = std::str::from_utf8(raw).ok()?.trim().to_ascii_uppercase();
    (!codec.is_empty()).then_some(codec)
}

fn preview_link_is_fresh(value: &str) -> bool {
    let Ok(url) = url::Url::parse(value) else {
        return true;
    };
    let expiry = url
        .query_pairs()
        .find(|(key, _)| key.eq_ignore_ascii_case("expire") || key.eq_ignore_ascii_case("expires"))
        .and_then(|(_, value)| value.parse::<u64>().ok());
    let Some(expiry) = expiry else {
        return true;
    };
    let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else {
        return true;
    };
    expiry > now.as_secs().saturating_add(10)
}

fn nonempty_trimmed(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(test)]
mod preview_tests {
    use std::collections::HashSet;

    use super::{
        archive_extract_body, avi_video_fourcc, batch_move_body, normalized_gcid, preview_sources,
        rename_file_body, validated_next_page_token, ArchiveExtractionProgress, Client,
        ClientBuilder, CreateFolderResponse, MediaLinkResponse, MediaResponse, MediaVideoResponse,
        DESKTOP_USER_AGENT,
    };
    use crate::auth::{OAuthCredentials, DESKTOP_CLIENT_ID, DESKTOP_CLIENT_SECRET};
    use crate::error::Error;

    #[tokio::test]
    async fn account_profile_uses_authenticated_user_service_and_minimal_fields() {
        use std::io::{Read, Write};
        for (body, success, name) in [
            (r#"{"sub":"profile-user","name":"  Taylor Chen  ","email":"private@example.test"}"#, true, "Taylor Chen"),
            (r#"{"sub":"profile-user","name":null}"#, true, ""),
            (r#"{"sub":"profile-user"}"#, true, ""),
            (r#"{"sub":"wrong-account","name":"Someone Else"}"#, false, ""),
        ] {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let server = std::thread::spawn(move || {
                for index in 0..2 {
                    let (mut socket, _) = listener.accept().unwrap();
                    socket.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
                    let mut request = String::new();
                    let mut buffer = [0_u8; 4096];
                    while !request.contains("\r\n\r\n") {
                        let count = socket.read(&mut buffer).unwrap();
                        assert!(count > 0);
                        request.push_str(&String::from_utf8_lossy(&buffer[..count]));
                    }
                    let response = if index == 0 {
                        assert!(request.starts_with("POST /v1/auth/token"));
                        r#"{"access_token":"fixture-access","refresh_token":"fixture-next","expires_in":3600,"sub":"profile-user"}"#
                    } else {
                        assert!(request.starts_with("GET /v1/user/me "));
                        assert!(request.to_lowercase().contains("authorization: bearer fixture-access"));
                        assert!(request.to_lowercase().contains("x-device-id: fixture-device"));
                        body
                    };
                    write!(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", response.len(), response).unwrap();
                }
            });
            let client = Client::builder().refresh_token("fixture-refresh").device_id("fixture-device")
                .auth_base_url(format!("http://{address}")).build().unwrap();
            let result = client.account_profile().await;
            assert_eq!(result.is_ok(), success);
            if let Ok(profile) = result {
                assert_eq!(profile.name, name);
                let encoded = serde_json::to_value(profile).unwrap();
                assert_eq!(encoded.as_object().unwrap().len(), 2);
                assert!(encoded.get("email").is_none());
            }
            server.join().unwrap();
        }
    }

    #[test]
    fn repeated_folder_page_token_fails_closed() {
        let mut seen = HashSet::new();
        assert_eq!(
            validated_next_page_token(Some("page-a".to_string()), &mut seen).unwrap(),
            Some("page-a".to_string())
        );
        assert_eq!(
            validated_next_page_token(Some("page-b".to_string()), &mut seen).unwrap(),
            Some("page-b".to_string())
        );
        assert!(matches!(
            validated_next_page_token(Some("page-a".to_string()), &mut seen),
            Err(Error::IncompleteListing(_))
        ));
    }

    #[test]
    fn explicit_device_identity_survives_refresh_token_changes() {
        let first = Client::builder()
            .refresh_token("first-refresh-token")
            .device_id("persistent-app-device")
            .build()
            .unwrap();
        let rotated = Client::builder()
            .refresh_token("rotated-refresh-token")
            .device_id("persistent-app-device")
            .build()
            .unwrap();

        assert_eq!(first.device_id(), rotated.device_id());
        assert_eq!(first.device_id(), "persistent-app-device");
    }

    #[test]
    fn desktop_credentials_select_the_desktop_user_agent() {
        let builder = ClientBuilder::new().credentials(OAuthCredentials::new(
            DESKTOP_CLIENT_ID,
            DESKTOP_CLIENT_SECRET,
        ));
        assert_eq!(builder.user_agent, DESKTOP_USER_AGENT);
    }

    #[test]
    fn folder_creation_response_accepts_both_known_shapes() {
        let nested: CreateFolderResponse =
            serde_json::from_str(r#"{"file":{"id":"nested-id"}}"#).unwrap();
        assert_eq!(
            nested.file.and_then(|file| file.id).as_deref(),
            Some("nested-id")
        );

        let direct: CreateFolderResponse = serde_json::from_str(r#"{"id":"direct-id"}"#).unwrap();
        assert_eq!(direct.id.as_deref(), Some("direct-id"));
    }

    #[test]
    fn batch_move_payload_matches_the_drive_contract() {
        let ids = vec!["file-a".to_string(), "folder-b".to_string()];
        assert_eq!(
            batch_move_body(&ids, "destination-folder"),
            serde_json::json!({
                "ids": ["file-a", "folder-b"],
                "to": { "parent_id": "destination-folder" }
            })
        );
        assert_eq!(
            batch_move_body(&ids, "")["to"]["parent_id"],
            serde_json::Value::String(String::new())
        );
    }

    #[test]
    fn rename_payload_matches_the_drive_contract() {
        assert_eq!(
            rename_file_body("Renamed folder"),
            serde_json::json!({ "name": "Renamed folder" })
        );
    }

    #[test]
    fn cloud_extraction_payload_matches_the_first_party_contract() {
        let files = vec![serde_json::json!({
            "index": 0,
            "name": "Photos",
            "kind": "drive#folder",
        })];
        assert_eq!(
            archive_extract_body(
                "archive-file",
                "0123456789ABCDEF0123456789ABCDEF01234567",
                "secret",
                &files,
            ),
            serde_json::json!({
                "gcid": "0123456789ABCDEF0123456789ABCDEF01234567",
                "password": "secret",
                "file_id": "archive-file",
                "files": files,
                "default_parent": true,
            })
        );
    }

    #[test]
    fn archive_progress_accepts_numeric_and_string_service_values() {
        let numeric: ArchiveExtractionProgress = serde_json::from_value(serde_json::json!({
            "progress": 42.5,
            "expires_in": 3
        }))
        .unwrap();
        assert_eq!(numeric.progress, 42.5);
        assert_eq!(numeric.expires_in, 3);

        let string: ArchiveExtractionProgress = serde_json::from_value(serde_json::json!({
            "progress": "99",
            "expires_in": "5"
        }))
        .unwrap();
        assert_eq!(string.progress, 99.0);
        assert_eq!(string.expires_in, 5);
    }

    #[test]
    fn archive_gcid_is_validated_and_normalized() {
        assert_eq!(
            normalized_gcid("0123456789abcdef0123456789abcdef01234567").as_deref(),
            Some("0123456789ABCDEF0123456789ABCDEF01234567")
        );
        assert!(normalized_gcid("not-a-gcid").is_none());
    }

    fn media(
        url: &str,
        is_origin: bool,
        is_default: bool,
        is_visible: Option<bool>,
    ) -> MediaResponse {
        MediaResponse {
            is_origin,
            is_default,
            is_visible,
            need_more_quota: false,
            media_name: String::new(),
            resolution_name: String::new(),
            video: Some(MediaVideoResponse {
                video_codec: "h264".to_string(),
                audio_codec: "aac".to_string(),
            }),
            link: Some(MediaLinkResponse {
                url: url.to_string(),
            }),
        }
    }

    #[test]
    fn preview_prefers_all_transcodes_before_original_and_direct_sources() {
        let streams = [
            media("https://example.test/first", false, false, Some(true)),
            media("https://example.test/original", true, false, Some(true)),
            media("https://example.test/default", false, true, Some(true)),
        ];
        let sources = preview_sources(&streams, "https://example.test/direct");
        assert_eq!(
            sources
                .iter()
                .map(|source| source.url.as_str())
                .collect::<Vec<_>>(),
            vec![
                "https://example.test/default",
                "https://example.test/first",
                "https://example.test/original",
                "https://example.test/direct",
            ]
        );
    }

    #[test]
    fn preview_ignores_empty_unavailable_and_duplicate_links() {
        let streams = [
            media("", false, true, Some(true)),
            media("https://example.test/fallback", false, false, Some(true)),
            media("https://example.test/hidden", true, false, Some(false)),
        ];
        let mut quota_locked = media("https://example.test/locked", false, false, Some(true));
        quota_locked.need_more_quota = true;
        let mut all = streams.to_vec();
        all.push(quota_locked);
        let sources = preview_sources(&all, "https://example.test/fallback");
        assert_eq!(
            sources
                .iter()
                .map(|source| source.url.as_str())
                .collect::<Vec<_>>(),
            vec!["https://example.test/fallback"]
        );
        assert_eq!(sources[0].video_codec.as_deref(), Some("h264"));
        assert_eq!(sources[0].audio_codec.as_deref(), Some("aac"));
    }

    #[test]
    fn preview_ignores_already_expired_signed_links() {
        let streams = [media(
            "https://example.test/media?expire=1",
            false,
            true,
            Some(true),
        )];
        let sources = preview_sources(&streams, "https://example.test/direct");
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].url, "https://example.test/direct");
    }

    #[test]
    fn avi_header_probe_extracts_video_fourcc() {
        let header = b"RIFF\x00\x01\x02\x03AVI LISTxxxxstrhxxxxvidsFMP4more-data";
        assert_eq!(avi_video_fourcc(header).as_deref(), Some("FMP4"));
    }

    #[test]
    fn avi_header_probe_rejects_non_avi_and_invalid_codec_bytes() {
        assert_eq!(avi_video_fourcc(b"not an avi file"), None);
        let invalid = b"RIFF\x00\x01\x02\x03AVI LISTxxxxvids\x00\x01\x02\x03";
        assert_eq!(avi_video_fourcc(invalid), None);
    }
}

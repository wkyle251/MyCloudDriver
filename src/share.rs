//! Browsing and downloading of PikPak share links.
//!
//! The client can either use PikPak's anonymous public-share session or an
//! authenticated [`Client`]. Guest Mode uses an anonymous session for content;
//! restoring items still uses the app-owned desktop account, independently of
//! Safari's Web token chain.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use md5::{Digest, Md5};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{Mutex, RwLock};
use url::Url;

use crate::auth::DEFAULT_CLIENT_ID;
use crate::captcha::anonymous_web_captcha_sign;
use crate::client::{
    enrich_avi_source_codec, original_download_url, preview_sources, DownloadInfo, MediaResponse,
    PreviewInfo,
};
use crate::error::{Error, Result};
use crate::types::FileInfo;

const API_BASE: &str = "https://api-drive.mypikpak.com";
const AUTH_BASE: &str = "https://user.mypikpak.com";
const WEB_CLIENT_VERSION: &str = "2.0.0";
const WEB_PACKAGE_NAME: &str = "mypikpak.com";
const WEB_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36";
const CAPTCHA_REFRESH_AFTER: Duration = Duration::from_secs(30 * 60);
const SHARE_FILTERS: &str = r#"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#;

/// Parsed, validated public-share identity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedShareLink {
    pub share_id: String,
    pub initial_parent_id: String,
}

impl ParsedShareLink {
    /// Accept only PikPak's official share hosts and `/s/<share-id>` path.
    pub fn parse(raw: &str) -> Result<Self> {
        let url = Url::parse(raw.trim()).map_err(|error| {
            Error::InvalidShareLink(format!("the URL could not be parsed ({error})"))
        })?;
        if url.scheme() != "https" {
            return Err(Error::InvalidShareLink(
                "use an https://mypikpak.com/s/... link".to_string(),
            ));
        }
        let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
        if host != "mypikpak.com"
            && host != "www.mypikpak.com"
            && host != "mypikpak.net"
            && host != "www.mypikpak.net"
        {
            return Err(Error::InvalidShareLink(
                "the host must be mypikpak.com or mypikpak.net".to_string(),
            ));
        }
        let parts: Vec<_> = url
            .path_segments()
            .into_iter()
            .flatten()
            .filter(|part| !part.is_empty())
            .collect();
        if parts.first().copied() != Some("s") || parts.get(1).is_none_or(|id| id.is_empty()) {
            return Err(Error::InvalidShareLink(
                "expected https://mypikpak.com/s/<share-id>".to_string(),
            ));
        }
        // PikPak Web appends every breadcrumb id while navigating a shared
        // tree. The API needs only the final folder id. Older parsing accepted
        // exactly one id and silently made valid deep links impossible to
        // open from the native app.
        Ok(Self {
            share_id: parts[1].to_string(),
            initial_parent_id: parts
                .get(2..)
                .and_then(|ids| ids.last())
                .copied()
                .unwrap_or_default()
                .to_string(),
        })
    }
}

/// One page returned to native browser integrations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShareBrowsePage {
    pub files: Vec<FileInfo>,
    #[serde(default)]
    pub next_page_token: Option<String>,
    pub share_id: String,
    #[serde(default)]
    pub pass_code_token: String,
    #[serde(default)]
    pub parent_id: String,
    #[serde(default)]
    pub folder_name: String,
}

#[derive(Clone)]
pub struct ShareClient {
    inner: Arc<ShareClientInner>,
    verification_cache: Option<std::path::PathBuf>,
}

struct ShareClientInner {
    http: reqwest::Client,
    download_http: reqwest::Client,
    api_base: String,
    auth_base: String,
    device_id: String,
    link: ParsedShareLink,
    pass_code: String,
    pass_code_token: RwLock<String>,
    captcha_tokens: RwLock<HashMap<String, CachedCaptcha>>,
    captcha_refresh: Mutex<()>,
    account: Option<crate::client::Client>,
    user_fallback: Option<ShareClient>,
}

#[derive(Clone)]
struct CachedCaptcha {
    token: String,
    refresh_after: Instant,
}

impl ShareClient {
    pub fn new(
        raw_url: &str,
        pass_code: impl Into<String>,
        pass_code_token: impl Into<String>,
        device_id: Option<&str>,
        proxy: Option<&str>,
    ) -> Result<Self> {
        let link = ParsedShareLink::parse(raw_url)?;
        let device_id = device_id
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| fallback_device_id(&link.share_id));
        let mut builder = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(30))
            .user_agent(WEB_USER_AGENT);
        let mut download_builder = reqwest::Client::builder()
            .no_proxy()
            .user_agent(WEB_USER_AGENT)
            .connect_timeout(Duration::from_secs(20))
            .read_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(32)
            .pool_idle_timeout(Duration::from_secs(30));
        if let Some(proxy) = proxy.map(str::trim).filter(|value| !value.is_empty()) {
            builder = builder.proxy(reqwest::Proxy::all(proxy)?);
            download_builder = download_builder.proxy(reqwest::Proxy::all(proxy)?);
        }
        Ok(Self {
            inner: Arc::new(ShareClientInner {
                http: builder.build()?,
                download_http: download_builder.build()?,
                api_base: API_BASE.to_string(),
                auth_base: AUTH_BASE.to_string(),
                device_id,
                link,
                pass_code: pass_code.into(),
                pass_code_token: RwLock::new(pass_code_token.into()),
                captcha_tokens: RwLock::new(HashMap::new()),
                captcha_refresh: Mutex::new(()),
                account: None,
                user_fallback: None,
            }),
            verification_cache: None,
        })
    }

    /// Build a share client backed by an independently authenticated PikPak
    /// account client. With Guest Mode off, the native app's requests
    /// share its persistent desktop device id and coordinated refresh-token
    /// store, while Safari's Web session remains completely separate.
    pub fn new_authenticated(
        raw_url: &str,
        pass_code: impl Into<String>,
        pass_code_token: impl Into<String>,
        account: crate::client::Client,
    ) -> Result<Self> {
        let link = ParsedShareLink::parse(raw_url)?;
        let device_id = account.device_id().to_string();
        Ok(Self {
            inner: Arc::new(ShareClientInner {
                http: account.http_client().clone(),
                download_http: account.download_http_client().clone(),
                api_base: API_BASE.to_string(),
                auth_base: AUTH_BASE.to_string(),
                device_id,
                link,
                pass_code: pass_code.into(),
                pass_code_token: RwLock::new(pass_code_token.into()),
                captcha_tokens: RwLock::new(HashMap::new()),
                captcha_refresh: Mutex::new(()),
                account: Some(account),
                user_fallback: None,
            }),
            verification_cache: None,
        })
    }

    pub fn parsed_link(&self) -> &ParsedShareLink {
        &self.inner.link
    }

    pub(crate) fn with_verification_cache(mut self, path: Option<std::path::PathBuf>) -> Self {
        self.verification_cache = path;
        self
    }

    pub(crate) fn with_user_fallback(mut self, user: ShareClient) -> Self {
        Arc::get_mut(&mut self.inner)
            .expect("new share client is not shared yet")
            .user_fallback = Some(user);
        self
    }

    pub(crate) fn with_endpoints(mut self, api_base: &str, auth_base: &str) -> Self {
        let inner = Arc::get_mut(&mut self.inner).expect("new share client is not shared yet");
        inner.api_base = api_base.to_string();
        inner.auth_base = auth_base.to_string();
        self
    }

    pub fn http_client(&self) -> &reqwest::Client {
        &self.inner.http
    }

    pub fn download_http_client(&self) -> &reqwest::Client {
        &self.inner.download_http
    }

    pub fn user_fallback(&self) -> Option<Self> {
        self.inner.user_fallback.clone()
    }

    pub async fn pass_code_token(&self) -> String {
        self.inner.pass_code_token.read().await.clone()
    }

    pub async fn list_folder_page(
        &self,
        parent_id: &str,
        page_token: Option<&str>,
        limit: usize,
    ) -> Result<ShareBrowsePage> {
        let result = self
            .list_folder_page_inner(parent_id, page_token, limit)
            .await;
        if result.is_err() {
            if let Some(user) = &self.inner.user_fallback {
                return user
                    .list_folder_page_inner(parent_id, page_token, limit)
                    .await;
            }
        }
        result
    }

    async fn list_folder_page_inner(
        &self,
        parent_id: &str,
        page_token: Option<&str>,
        limit: usize,
    ) -> Result<ShareBrowsePage> {
        self.ensure_pass_code_token_if_supplied().await?;
        let page = self
            .request_share_detail(parent_id, page_token, limit)
            .await?;
        let folder_name = page
            .file_info
            .as_ref()
            .map(|file| file.info.name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "Shared Link".to_string());
        Ok(ShareBrowsePage {
            files: page.files.into_iter().map(|file| file.info).collect(),
            next_page_token: nonempty(page.next_page_token),
            share_id: self.inner.link.share_id.clone(),
            pass_code_token: self.pass_code_token().await,
            parent_id: parent_id.to_string(),
            folder_name,
        })
    }

    /// Open the folder encoded in a shared URL, falling back to the share root
    /// when PikPak Web has left stale breadcrumb ids in a copied deep link.
    /// A genuine access-code, authentication, or network failure is returned
    /// immediately; only the API's explicit file-not-found response falls back.
    pub async fn list_initial_folder_page(
        &self,
        page_token: Option<&str>,
        limit: usize,
    ) -> Result<ShareBrowsePage> {
        let parent_id = self.inner.link.initial_parent_id.as_str();
        if parent_id.is_empty() {
            return self.list_folder_page("", page_token, limit).await;
        }
        match self.list_folder_page(parent_id, page_token, limit).await {
            Ok(page) => Ok(page),
            Err(error) if page_token.is_none() && is_missing_share_target(&error) => {
                self.list_folder_page("", None, limit).await
            }
            Err(error) => Err(error),
        }
    }

    pub async fn list_folder(&self, parent_id: &str) -> Result<Vec<FileInfo>> {
        let mut files = Vec::new();
        let mut page_token: Option<String> = None;
        let mut seen = HashSet::new();
        loop {
            let page = self
                .list_folder_page(parent_id, page_token.as_deref(), 200)
                .await?;
            files.extend(page.files);
            let Some(next) = page.next_page_token.filter(|token| !token.is_empty()) else {
                break;
            };
            if !seen.insert(next.clone()) {
                return Err(Error::IncompleteListing(
                    "PikPak repeated a public-share folder page token",
                ));
            }
            page_token = Some(next);
        }
        Ok(files)
    }

    /// Metadata for one selected share item, without resolving a download URL.
    pub async fn file_info(&self, file_id: &str) -> Result<FileInfo> {
        match self.get_file_detail(file_id).await {
            Ok(file) => Ok(file.info),
            Err(error) => {
                if let Some(user) = &self.inner.user_fallback {
                    return user.get_file_detail(file_id).await.map(|file| file.info);
                }
                Err(error)
            }
        }
    }

    pub async fn get_download_url(&self, file_id: &str) -> Result<DownloadInfo> {
        let result = self.get_download_url_inner(file_id).await;
        if result
            .as_ref()
            .is_err_and(|error| !crate::content_mode::guest_lookup_transient(error))
        {
            if let Some(user) = &self.inner.user_fallback {
                return user.get_download_url_inner(file_id).await;
            }
        }
        result
    }

    /// Refresh this route's signed URL without consuming account quota when
    /// Guest metadata is temporarily unavailable or its URL has expired.
    pub async fn get_download_url_on_current_route(&self, file_id: &str) -> Result<DownloadInfo> {
        self.get_download_url_inner(file_id).await
    }

    async fn get_download_url_inner(&self, file_id: &str) -> Result<DownloadInfo> {
        let _stage = crate::download_waits::Stage::enter(crate::download_waits::Kind::DownloadUrl);
        let detail = self.get_file_detail(file_id).await?;
        let web_content_link = original_content_link(&detail)
            .ok_or(Error::InvalidPath("shared file has no content link"))?;
        let source_revision = crate::client::download_revision(
            detail.info.hash.as_deref(),
            detail.info.modified_time.as_deref(),
        );
        Ok(DownloadInfo {
            web_content_link,
            name: detail.info.name,
            size: detail.info.size,
            source_revision,
        })
    }

    pub async fn get_preview_info(&self, file_id: &str) -> Result<PreviewInfo> {
        let result = self.get_preview_info_inner(file_id).await;
        if result.is_err() {
            if let Some(user) = &self.inner.user_fallback {
                return user.get_preview_info_inner(file_id).await;
            }
        }
        result
    }

    async fn get_preview_info_inner(&self, file_id: &str) -> Result<PreviewInfo> {
        let detail = self.get_file_detail(file_id).await?;
        if self.inner.account.is_none() {
            let url = original_content_link(&detail).ok_or(Error::Guest(
                "The public share did not provide an original download URL.",
            ))?;
            return Ok(original_preview(&detail.info, url));
        }
        let direct = detail.web_content_link.clone();
        let mut sources = preview_sources(&detail.medias, &direct);
        enrich_avi_source_codec(
            &self.inner.http,
            &detail.info.name,
            detail.info.mime_type.as_deref(),
            &mut sources,
            Some("https://mypikpak.com/"),
        )
        .await;
        let content_link = sources
            .first()
            .map(|source| source.url.clone())
            .or_else(|| preferred_content_link(&detail))
            .ok_or(Error::InvalidPath(
                "shared file has no preview or content link",
            ))?;
        Ok(PreviewInfo {
            name: detail.info.name,
            size: detail.info.size,
            mime_type: detail.info.mime_type,
            thumbnail_link: detail.info.thumbnail_link,
            icon_link: detail.info.icon_link,
            content_link,
            sources,
        })
    }

    /// Verify the source mapping before exposing any URL to the transfer or
    /// preview pipeline. The account's saved filename remains the destination.
    pub(crate) async fn get_verified_original(
        &self,
        original_id: &str,
        saved: &FileInfo,
    ) -> Result<DownloadInfo> {
        debug_assert!(self.inner.account.is_none());
        let detail = self.get_file_detail(original_id).await?;
        if detail.info.id != original_id
            || !detail.info.kind.is_file()
            || detail.info.size != saved.size
            || !matching_content_ids(saved.hash.as_deref(), detail.info.hash.as_deref())
        {
            return Err(Error::Guest(
                "The original shared file no longer matches this saved file. Guest access stopped.",
            ));
        }
        let web_content_link = original_content_link(&detail).ok_or(Error::Guest(
            "The public share did not provide an original download URL.",
        ))?;
        Ok(DownloadInfo {
            web_content_link,
            name: saved.name.clone(),
            size: saved.size,
            source_revision: crate::client::download_revision(
                detail.info.hash.as_deref(),
                detail.info.modified_time.as_deref(),
            ),
        })
    }

    async fn get_file_detail(&self, file_id: &str) -> Result<ShareFile> {
        self.ensure_pass_code_token_if_supplied().await?;
        let token = self.pass_code_token().await;
        let query = vec![
            ("share_id", self.inner.link.share_id.clone()),
            ("file_id", file_id.to_string()),
            ("pass_code_token", token),
        ];
        let value = self
            .request_json("/drive/v1/share/file_info", &query)
            .await?;
        let response: ShareResponse = serde_json::from_value(value)?;
        self.check_share_status(&response).await?;
        response.file_info.ok_or_else(|| {
            Error::Share("PikPak returned no metadata for this shared file".to_string())
        })
    }

    async fn request_share_detail(
        &self,
        parent_id: &str,
        page_token: Option<&str>,
        limit: usize,
    ) -> Result<ShareResponse> {
        let mut exchanged_passcode = false;
        loop {
            let token = self.pass_code_token().await;
            let query = vec![
                ("share_id", self.inner.link.share_id.clone()),
                ("parent_id", parent_id.to_string()),
                ("pass_code_token", token),
                ("thumbnail_size", "SIZE_LARGE".to_string()),
                ("with_audit", "true".to_string()),
                ("limit", limit.clamp(1, 500).to_string()),
                ("page_token", page_token.unwrap_or_default().to_string()),
                ("filters", SHARE_FILTERS.to_string()),
            ];
            let value = self.request_json("/drive/v1/share/detail", &query).await?;
            let response: ShareResponse = serde_json::from_value(value)?;
            match response.share_status.as_str() {
                "" | "OK" => return Ok(response),
                "PASS_CODE_EMPTY" | "PASS_CODE_ERROR"
                    if !self.inner.pass_code.trim().is_empty() && !exchanged_passcode =>
                {
                    self.exchange_pass_code().await?;
                    exchanged_passcode = true;
                }
                "PASS_CODE_EMPTY" => {
                    return Err(Error::Share(
                        "this shared folder needs an access code".to_string(),
                    ));
                }
                "PASS_CODE_ERROR" => {
                    return Err(Error::Share(
                        "the access code for this shared folder is incorrect".to_string(),
                    ));
                }
                _ => return Err(share_status_error(&response)),
            }
        }
    }

    async fn check_share_status(&self, response: &ShareResponse) -> Result<()> {
        match response.share_status.as_str() {
            "" | "OK" => Ok(()),
            "PASS_CODE_EMPTY" => Err(Error::Share(
                "this shared folder needs an access code".to_string(),
            )),
            "PASS_CODE_ERROR" => Err(Error::Share(
                "the access code for this shared folder is incorrect".to_string(),
            )),
            _ => Err(share_status_error(response)),
        }
    }

    async fn ensure_pass_code_token_if_supplied(&self) -> Result<()> {
        if self.inner.pass_code.trim().is_empty()
            || !self.inner.pass_code_token.read().await.is_empty()
        {
            return Ok(());
        }
        self.exchange_pass_code().await
    }

    async fn exchange_pass_code(&self) -> Result<()> {
        let query = vec![
            ("share_id", self.inner.link.share_id.clone()),
            ("pass_code", self.inner.pass_code.clone()),
            ("thumbnail_size", "SIZE_LARGE".to_string()),
            ("limit", "100".to_string()),
        ];
        let value = self.request_json("/drive/v1/share", &query).await?;
        let response: ShareResponse = serde_json::from_value(value)?;
        self.check_share_status(&response).await?;
        if response.pass_code_token.trim().is_empty() {
            return Err(Error::Share(
                "PikPak did not accept the supplied access code".to_string(),
            ));
        }
        *self.inner.pass_code_token.write().await = response.pass_code_token;
        Ok(())
    }

    async fn request_json(&self, path: &str, query: &[(impl AsRef<str>, String)]) -> Result<Value> {
        use crate::download_waits::{track, Kind, Stage};
        let _stage = Stage::enter(Kind::GuestMetadata);
        let action = format!("GET:{path}");
        let url = format!("{}{path}", self.inner.api_base.trim_end_matches('/'));
        if let Some(account) = &self.inner.account {
            let query = query
                .iter()
                .map(|(key, value)| (key.as_ref(), value.clone()))
                .collect::<Vec<_>>();
            let text = account
                .drive_request(reqwest::Method::GET, &url, &action, &query, None)
                .await?;
            let value: Value = serde_json::from_str(&text).map_err(|error| {
                Error::Share(format!("PikPak returned unreadable share data: {error}"))
            })?;
            if api_error_code(&value) != 0 {
                return Err(api_error(StatusCode::OK, &value, &text));
            }
            return Ok(value);
        }
        let mut failed_token: Option<String> = None;
        for attempt in 0..2 {
            let captcha = if attempt == 0 {
                track(Kind::GuestCaptcha, self.captcha_for(&action)).await?
            } else {
                track(Kind::GuestCaptcha, self.refresh_captcha(&action, failed_token.as_deref()))
                    .await?
            };
            let request = self
                .inner
                .http
                .get(&url)
                .header("X-Client-ID", DEFAULT_CLIENT_ID)
                .header("X-Device-ID", &self.inner.device_id)
                .header("X-Captcha-Token", &captcha)
                .query(
                    &query
                        .iter()
                        .map(|(key, value)| (key.as_ref(), value.as_str()))
                        .collect::<Vec<_>>(),
                );
            let response = track(Kind::GuestHeaders, request.send()).await?;
            let status = response.status();
            crate::download_waits::response(true, status.as_u16());
            if crate::download_policy::transient_status(status.as_u16()) {
                if let Some(delay) = crate::download_policy::retry_after(response.headers()) {
                    return Err(Error::RetryAfter {
                        status: status.as_u16(),
                        delay,
                    });
                }
                return Err(Error::Api {
                    status: status.as_u16(),
                    message: "The shared-file service is temporarily unavailable".into(),
                });
            }
            let text = track(Kind::GuestBody, response.text()).await?;
            let value: Value = serde_json::from_str(&text).map_err(|error| {
                Error::Share(format!(
                    "PikPak returned unreadable share data (HTTP {}): {error}",
                    status.as_u16()
                ))
            })?;
            if api_error_code(&value) == 9 && attempt == 0 {
                failed_token = Some(captcha);
                continue;
            }
            if !status.is_success() || api_error_code(&value) != 0 {
                return Err(api_error(status, &value, &text));
            }
            return Ok(value);
        }
        Err(Error::Share(
            "PikPak repeatedly rejected public-share verification".to_string(),
        ))
    }

    async fn captcha_for(&self, action: &str) -> Result<String> {
        if let Some(cached) = self.inner.captcha_tokens.read().await.get(action) {
            if Instant::now() < cached.refresh_after {
                return Ok(cached.token.clone());
            }
        }
        self.refresh_captcha(action, None).await
    }

    async fn refresh_captcha(&self, action: &str, previous: Option<&str>) -> Result<String> {
        use crate::download_waits::{track, Kind};
        let _refresh = track(Kind::GuestRefreshLock, self.inner.captcha_refresh.lock()).await;
        if let Some(cached) = self.inner.captcha_tokens.read().await.get(action) {
            if Instant::now() < cached.refresh_after && previous != Some(cached.token.as_str()) {
                return Ok(cached.token.clone());
            }
        }
        self.inner.captcha_tokens.write().await.remove(action);
        if let Some(token) = crate::request_verification::verified_token(
            self.verification_cache.as_deref(), DEFAULT_CLIENT_ID, &self.inner.device_id, action, previous,
        ) {
            self.inner.captcha_tokens.write().await.insert(action.into(), CachedCaptcha {
                token: token.clone(), refresh_after: Instant::now() + Duration::from_secs(30),
            });
            return Ok(token);
        }
        let timestamp = crate::captcha::anonymous_web_captcha_timestamp();
        let body = serde_json::json!({
            "action": action,
            "captcha_token": previous.unwrap_or(""),
            "client_id": DEFAULT_CLIENT_ID,
            "device_id": self.inner.device_id,
            "meta": {
                "captcha_sign": anonymous_web_captcha_sign(&self.inner.device_id, &timestamp),
                "client_version": WEB_CLIENT_VERSION,
                "package_name": WEB_PACKAGE_NAME,
                "timestamp": timestamp,
                "user_id": "",
            },
            "redirect_uri": "",
        });
        let url = format!(
            "{}/v1/shield/captcha/init",
            self.inner.auth_base.trim_end_matches('/')
        );
        let response = track(Kind::GuestRefreshHeaders, self
            .inner
            .http
            .post(url)
            .header("X-Client-ID", DEFAULT_CLIENT_ID)
            .header("X-Device-ID", &self.inner.device_id)
            .header("X-Captcha-Token", previous.unwrap_or(""))
            .json(&body)
            .send())
            .await?;
        let status = response.status();
        let text = track(Kind::GuestRefreshBody, response.text()).await?;
        let value: Value = serde_json::from_str(&text).map_err(|error| {
            Error::Share(format!(
                "PikPak returned unreadable verification data (HTTP {}): {error}",
                status.as_u16()
            ))
        })?;
        if !status.is_success() || api_error_code(&value) != 0 {
            return Err(api_error(status, &value, &text));
        }
        if let Some(url) = value.get("url").and_then(Value::as_str).filter(|url| !url.is_empty()) {
            return Err(Error::VerificationRequired(crate::VerificationChallenge::new(
                url, DEFAULT_CLIENT_ID, &self.inner.device_id, action,
            )?));
        }
        let token = value
            .get("captcha_token")
            .and_then(Value::as_str)
            .filter(|token| !token.is_empty())
            .ok_or_else(|| {
                Error::Share("PikPak returned an empty public-share verification token".to_string())
            })?
            .to_string();
        self.inner.captcha_tokens.write().await.insert(
            action.to_string(),
            CachedCaptcha {
                token: token.clone(),
                refresh_after: Instant::now() + CAPTCHA_REFRESH_AFTER,
            },
        );
        Ok(token)
    }
}

#[derive(Debug, Deserialize)]
struct ShareResponse {
    #[serde(default)]
    share_status: String,
    #[serde(default)]
    share_status_text: String,
    #[serde(default)]
    file_info: Option<ShareFile>,
    #[serde(default)]
    files: Vec<ShareFile>,
    #[serde(default)]
    next_page_token: Option<String>,
    #[serde(default)]
    pass_code_token: String,
}

#[derive(Debug, Deserialize)]
struct ShareFile {
    #[serde(flatten)]
    info: FileInfo,
    #[serde(default)]
    web_content_link: String,
    #[serde(default)]
    medias: Vec<MediaResponse>,
}

fn preferred_content_link(file: &ShareFile) -> Option<String> {
    if !file.web_content_link.trim().is_empty() {
        return Some(file.web_content_link.clone());
    }
    preview_sources(&file.medias, "")
        .first()
        .map(|source| source.url.clone())
}

fn matching_content_ids(saved: Option<&str>, original: Option<&str>) -> bool {
    match (saved, original) {
        (Some(saved), Some(original)) => {
            !saved.trim().is_empty() && saved.trim().eq_ignore_ascii_case(original.trim())
        }
        _ => false,
    }
}

fn original_content_link(file: &ShareFile) -> Option<String> {
    original_download_url(&file.medias, &file.web_content_link)
}

pub(crate) fn original_preview(file: &FileInfo, url: String) -> PreviewInfo {
    PreviewInfo {
        name: file.name.clone(),
        size: file.size,
        mime_type: file.mime_type.clone(),
        thumbnail_link: None,
        icon_link: file.icon_link.clone(),
        content_link: url.clone(),
        sources: vec![crate::PreviewSource {
            url,
            label: Some("Original · Guest".into()),
            is_origin: true,
            video_codec: None,
            audio_codec: None,
        }],
    }
}

fn fallback_device_id(share_id: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(b"pikpak-public-share:");
    hasher.update(share_id.as_bytes());
    hex::encode(hasher.finalize())
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.is_empty())
}

fn api_error_code(value: &Value) -> i64 {
    value
        .get("error_code")
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str().and_then(|code| code.parse().ok()))
        })
        .unwrap_or(0)
}

fn api_error(status: StatusCode, value: &Value, raw: &str) -> Error {
    let message = value
        .get("error_description")
        .or_else(|| value.get("error"))
        .and_then(Value::as_str)
        .filter(|message| !message.is_empty())
        .unwrap_or(raw);
    Error::Api {
        status: status.as_u16(),
        message: message.to_string(),
    }
}

fn share_status_error(response: &ShareResponse) -> Error {
    let detail = if response.share_status_text.trim().is_empty() {
        response.share_status.as_str()
    } else {
        response.share_status_text.as_str()
    };
    Error::Share(detail.to_string())
}

fn is_missing_share_target(error: &Error) -> bool {
    match error {
        Error::Api { status: 404, .. } => true,
        Error::Api { message, .. } => {
            let message = message.to_ascii_lowercase();
            message.contains("file_not_found")
                || message.contains("file or folder is not found")
                || message.contains("\"error_code\":5")
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_share_hosts_and_optional_folder() {
        let root = ParsedShareLink::parse("https://mypikpak.com/s/abc123?source=copy").unwrap();
        assert_eq!(root.share_id, "abc123");
        assert_eq!(root.initial_parent_id, "");

        let folder =
            ParsedShareLink::parse("https://www.mypikpak.net/s/share-id/folder-id").unwrap();
        assert_eq!(folder.share_id, "share-id");
        assert_eq!(folder.initial_parent_id, "folder-id");

        let nested = ParsedShareLink::parse(
            "https://mypikpak.com/s/share-id/ancestor-id/child-id/deep-folder-id",
        )
        .unwrap();
        assert_eq!(nested.share_id, "share-id");
        assert_eq!(nested.initial_parent_id, "deep-folder-id");
    }

    #[test]
    fn rejects_spoofed_hosts_and_non_share_paths() {
        assert!(ParsedShareLink::parse("https://mypikpak.com.example/s/abc").is_err());
        assert!(ParsedShareLink::parse("https://mypikpak.com/files/abc").is_err());
        assert!(ParsedShareLink::parse("http://mypikpak.com/s/abc").is_err());
    }

    #[test]
    fn fallback_device_is_stable_and_web_shaped() {
        let first = fallback_device_id("same-share");
        let second = fallback_device_id("same-share");
        assert_eq!(first, second);
        assert_eq!(first.len(), 32);
        assert!(first.chars().all(|character| character.is_ascii_hexdigit()));
    }

    #[test]
    fn error_code_accepts_number_and_string() {
        assert_eq!(api_error_code(&serde_json::json!({"error_code": 9})), 9);
        assert_eq!(api_error_code(&serde_json::json!({"error_code": "10"})), 10);
        assert_eq!(api_error_code(&serde_json::json!({})), 0);
    }

    #[test]
    fn only_explicit_missing_targets_are_safe_to_fallback() {
        assert!(is_missing_share_target(&Error::Api {
            status: 404,
            message: "missing".to_string(),
        }));
        assert!(is_missing_share_target(&Error::Api {
            status: 200,
            message: r#"{"error":"file_not_found","error_code":5}"#.to_string(),
        }));
        assert!(!is_missing_share_target(&Error::Api {
            status: 401,
            message: "authentication required".to_string(),
        }));
        assert!(!is_missing_share_target(&Error::Share(
            "PASS_CODE_ERROR".to_string()
        )));
    }
}

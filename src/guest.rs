//! Original-share resolution for Guest Mode. Account credentials are used only
//! for folder metadata; content URLs are issued by an anonymous share client.
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::{Client, DownloadInfo, Error, FileInfo, ParsedShareLink, Result, ShareClient};

const METADATA_LIFETIME: Duration = Duration::from_secs(30);
const MAX_FILES: usize = 2048;
const MAX_SHARES: usize = 64;

#[cfg(test)]
#[path = "guest_tests.rs"]
mod tests;

#[derive(Clone, Deserialize)]
pub(crate) struct GuestFile {
    #[serde(flatten)]
    pub info: FileInfo,
    #[serde(default)]
    params: Option<SourceParams>,
}

#[derive(Clone, Default, Deserialize)]
struct SourceParams {
    #[serde(default)]
    original_file_id: String,
    #[serde(default)]
    original_share_id: String,
    #[serde(default)]
    url: String,
}

#[derive(Default)]
pub(crate) struct GuestState {
    files: Mutex<HashMap<String, (Instant, GuestFile)>>,
    shares: Mutex<HashMap<String, (Instant, ShareClient)>>,
    pub(crate) download_shares: crate::download_share::DownloadShares,
}

impl GuestState {
    pub fn remember_listing(&self, raw: &str) {
        #[derive(Deserialize)]
        struct Page {
            files: Vec<GuestFile>,
        }
        let Ok(page) = serde_json::from_str::<Page>(raw) else {
            return;
        };
        let mut files = self.files.lock().unwrap();
        files.retain(|_, (at, _)| at.elapsed() < METADATA_LIFETIME);
        for file in page.files {
            if files.len() >= MAX_FILES {
                evict_oldest(&mut files);
            }
            files.insert(file.info.id.clone(), (Instant::now(), file));
        }
    }

    pub fn cached(&self, id: &str, parent: Option<&str>) -> Option<GuestFile> {
        self.files
            .lock()
            .unwrap()
            .get(id)
            .filter(|(at, file)| {
                at.elapsed() < METADATA_LIFETIME
                    && parent
                        .is_none_or(|parent| file.info.parent_id.as_deref().unwrap_or("") == parent)
            })
            .map(|(_, file)| file.clone())
    }

    fn share(&self, file: &GuestFile, account: &Client) -> Result<(ShareClient, String)> {
        let source = file.params.as_ref().ok_or(Error::Guest(
            "This file has no original public share. Use an available shared link, or choose User or Dynamic mode in the sidebar."))?;
        if source.original_file_id.trim().is_empty() || source.original_share_id.trim().is_empty() {
            return Err(Error::Guest("This file has no original public share. Use an available shared link, or choose User or Dynamic mode in the sidebar."));
        }
        let link = ParsedShareLink::parse(&source.url)
            .map_err(|_| Error::Guest("The file's original share link is missing or invalid."))?;
        if link.share_id != source.original_share_id {
            return Err(Error::Guest(
                "The original share does not match this saved file's metadata.",
            ));
        }
        if file
            .info
            .hash
            .as_deref()
            .is_none_or(|hash| hash.trim().is_empty())
        {
            return Err(Error::Guest(
                "PikPak did not provide a content ID to verify the original shared file.",
            ));
        }
        let mut shares = self.shares.lock().unwrap();
        if let Some((at, client)) = shares.get_mut(&link.share_id) {
            *at = Instant::now();
            return Ok((client.clone(), source.original_file_id.clone()));
        }
        let client = account.anonymous_share_client(&source.url, "", "")?;
        if shares.len() >= MAX_SHARES {
            evict_oldest(&mut shares);
        }
        shares.insert(link.share_id, (Instant::now(), client.clone()));
        Ok((client, source.original_file_id.clone()))
    }

    pub async fn download(&self, file: &GuestFile, account: &Client) -> Result<DownloadInfo> {
        let (share, original_id) = self.share(file, account)?;
        share.get_verified_original(&original_id, &file.info).await
    }

    /// Only explicit downloads create links. Previews and scans keep their
    /// existing read-only original-share lookup.
    pub async fn download_task(&self, file: &GuestFile, account: &Client) -> Result<DownloadInfo> {
        let original = match self.share(file, account) {
            Ok((share, original_id)) => share.get_verified_original(&original_id, &file.info).await,
            Err(error) => Err(error),
        };
        let error = match original {
            Ok(download) => return Ok(download),
            // An outage or throttle does not establish that a link is gone.
            Err(error) if crate::content_mode::guest_lookup_transient(&error) => return Err(error),
            Err(error) => error,
        };
        let url = self.download_share(&file.info, account, share_unavailable_reason(&error)).await?;
        let share = self.share_for_url(&url, account)?;
        // A new link must identify the selected account copy, never the
        // expired original's ID or an unverified same-named file.
        let download = share.get_verified_original(&file.info.id, &file.info).await?;
        tracing::info!(file_id = %file.info.id, "Download share ready; downloading from the share link.");
        Ok(download)
    }

    fn share_for_url(&self, url: &str, account: &Client) -> Result<ShareClient> {
        let link = ParsedShareLink::parse(url)?;
        let mut shares = self.shares.lock().unwrap();
        if let Some((at, client)) = shares.get_mut(&link.share_id) {
            *at = Instant::now();
            return Ok(client.clone());
        }
        let client = account.anonymous_share_client(url, "", "")?;
        if shares.len() >= MAX_SHARES {
            evict_oldest(&mut shares);
        }
        shares.insert(link.share_id, (Instant::now(), client.clone()));
        Ok(client)
    }
}

fn share_unavailable_reason(error: &Error) -> &'static str {
    match error {
        Error::Share(message) => {
            let message = message.to_ascii_lowercase();
            if message.contains("expir") { "expired" }
            else if message.contains("delet") { "deleted" }
            else if message.contains("pass_code") || message.contains("access code") { "access code required" }
            else { "no longer available" }
        }
        Error::Api { status: 404, .. } => "not found",
        Error::Api { status: 401 | 403, .. } => "access denied",
        _ => "original unavailable",
    }
}

fn evict_oldest<T>(cache: &mut HashMap<String, (Instant, T)>) {
    if let Some(key) = cache
        .iter()
        .min_by_key(|(_, (at, _))| *at)
        .map(|(key, _)| key.clone())
    {
        cache.remove(&key);
    }
}

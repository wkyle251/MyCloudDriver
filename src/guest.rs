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

//! Public links for explicit account downloads whose original share is unavailable.
//! Creation uses the account session; URL resolution and content use Guest.
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    duplicate_cache::DuplicateCache, guest::GuestState, Client, Error, FileInfo, ParsedShareLink,
    Result,
};

#[cfg(test)]
#[path = "download_share_tests.rs"]
mod tests;

struct Link {
    url: Option<String>,
    attempted: Instant,
}
struct Inventory {
    started: Instant,
    shares: Vec<Value>,
}
#[derive(Default)]
struct State {
    // None is a durable intent, including an interrupted/lost POST response.
    links: HashMap<String, Link>,
    created: HashMap<String, String>,
    inventory: Option<Inventory>,
}
pub(crate) struct DownloadShares {
    state: Mutex<State>,
    keys: Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>>,
    refresh: tokio::sync::Mutex<()>,
    started: Instant,
}
impl Default for DownloadShares {
    fn default() -> Self {
        Self {
            state: Mutex::new(State::default()),
            keys: Mutex::new(HashMap::new()),
            refresh: tokio::sync::Mutex::new(()),
            started: Instant::now(),
        }
    }
}
impl DownloadShares {
    fn cached(&self, key: &str) -> Option<String> {
        self.state
            .lock()
            .unwrap()
            .links
            .get(key)
            .and_then(|link| link.url.clone())
    }
    fn key_lock(&self, key: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut keys = self.keys.lock().unwrap();
        keys.retain(|_, lock| lock.strong_count() != 0);
        if let Some(lock) = keys.get(key).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(tokio::sync::Mutex::new(()));
        keys.insert(key.into(), Arc::downgrade(&lock));
        lock
    }
    fn remember(&self, key: &str, id: &str, url: Option<&str>, attempted: Instant) {
        let mut state = self.state.lock().unwrap();
        state.links.insert(
            key.into(),
            Link {
                url: url.map(str::to_owned),
                attempted,
            },
        );
        if let Some(url) = url {
            state.created.insert(id.into(), url.into());
        }
    }
    // Some(None) means a sufficiently recent, complete inventory found no
    // match. An uncertain POST requires a scan started after its intent; old
    // intents restored by this helper can all share its first reconciliation.
    fn inventory_match(
        &self,
        file: &FileInfo,
        suffix: &str,
        after: Option<Instant>,
    ) -> Option<Option<String>> {
        let state = self.state.lock().unwrap();
        if let Some(url) = state.created.get(&file.id) {
            return Some(Some(url.clone()));
        }
        let inventory = state.inventory.as_ref()?;
        if after.is_some_and(|after| inventory.started < after) {
            return None;
        }
        Some(inventory.shares.iter().find_map(|share| {
            let matching_title = share["title"]
                .as_str()
                .is_some_and(|title| title.ends_with(suffix));
            let matching_file = share["file_ids"]
                .as_array()
                .is_some_and(|ids| ids.iter().any(|id| id.as_str() == Some(&file.id)));
            if matching_title || matching_file {
                public_share_url(share).ok()
            } else {
                None
            }
        }))
    }
    async fn reconcile(
        &self,
        account: &Client,
        file: &FileInfo,
        suffix: &str,
        after: Option<Instant>,
    ) -> Result<Option<String>> {
        if let Some(found) = self.inventory_match(file, suffix, after) {
            return Ok(found);
        }
        let _refresh = crate::download_waits::track(
            crate::download_waits::Kind::ShareInventoryWait,
            self.refresh.lock(),
        )
        .await;
        if let Some(found) = self.inventory_match(file, suffix, after) {
            return Ok(found);
        }
        let started = Instant::now();
        let shares = crate::download_waits::track(
            crate::download_waits::Kind::ShareInventory,
            owned_shares(account),
        )
        .await?;
        self.state.lock().unwrap().inventory = Some(Inventory { started, shares });
        Ok(self.inventory_match(file, suffix, after).flatten())
    }
}

impl GuestState {
    pub(crate) async fn download_share(
        &self,
        file: &FileInfo,
        account: &Client,
        reason: &str,
    ) -> Result<String> {
        use crate::download_waits::{track, Kind, Stage};
        let hash = file
            .hash
            .as_deref()
            .filter(|hash| !hash.trim().is_empty())
            .ok_or(Error::Guest(
                "PikPak did not provide a content ID to verify a new download share.",
            ))?;
        if !file.kind.is_file() || file.id.trim().is_empty() {
            return Err(Error::Guest(
                "Only a selected account file can get a download share.",
            ));
        }
        let identity =
            serde_json::to_vec(&(&file.id, file.size, hash.trim().to_ascii_lowercase()))?;
        let key = hex::encode(ring::digest::digest(&ring::digest::SHA256, &identity));
        let suffix = format!(" [MyCloudDriver {key}]");
        let title = format!(
            "{}{}",
            file.name
                .chars()
                .take(200 - suffix.len())
                .collect::<String>(),
            suffix
        );
        let state = &self.download_shares;
        if let Some(url) = state.cached(&key) {
            tracing::info!(file_id = %file.id, "Share link unavailable: {reason}; reusing your download share link.");
            return Ok(url);
        }

        let cache = track(Kind::ShareCache, account.duplicate_cache()).await;
        if cache.is_none() && account.uses_persistent_metadata_cache() {
            return Err(cache_unavailable());
        }
        // Confirmed links never wait behind inventory HTTP or an unrelated
        // creation. The persistent lookup also bypasses cross-helper locks.
        if let Some(cache) = &cache {
            if let Some(Some(url)) = cache
                .download_share(&key)
                .map_err(|_| cache_unavailable())?
            {
                state.remember(&key, &file.id, Some(&url), state.started);
                return Ok(url);
            }
        }
        let key_lock = state.key_lock(&key);
        let _key = track(Kind::ShareLock, key_lock.lock()).await;
        if let Some(url) = state.cached(&key) {
            return Ok(url);
        }
        // Only the same source identity serializes across helpers. A slow
        // cloud operation must not lock every other file in the account.
        let process_wait = Stage::enter(Kind::ShareProcessLock);
        let _lease = if let Some(cache) = &cache {
            let path = cache
                .path()
                .with_extension(format!("download-share-{key}.lock"));
            Some(loop {
                match crate::download_network::Network::locked_file(
                    &path,
                    rustix::fs::FlockOperation::NonBlockingLockExclusive,
                ) {
                    Ok(file) => break file,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                    Err(_) => return Err(cache_unavailable()),
                }
            })
        } else {
            None
        };
        drop(process_wait);
        if let Some(cache) = &cache {
            if let Some(link) = cache
                .download_share(&key)
                .map_err(|_| cache_unavailable())?
            {
                let attempted = state
                    .state
                    .lock()
                    .unwrap()
                    .links
                    .get(&key)
                    .map_or(state.started, |link| link.attempted);
                state.remember(&key, &file.id, link.as_deref(), attempted);
            }
        }
        if let Some(url) = state.cached(&key) {
            tracing::info!(file_id = %file.id, "Share link unavailable: {reason}; reusing your download share link.");
            return Ok(url);
        }

        let attempted = state
            .state
            .lock()
            .unwrap()
            .links
            .get(&key)
            .map(|link| link.attempted);
        if let Some(url) = state.reconcile(account, file, &suffix, attempted).await? {
            remember(cache.as_ref(), &key, Some(&url))?;
            state.remember(&key, &file.id, Some(&url), state.started);
            tracing::info!(file_id = %file.id, "Share link unavailable: {reason}; reusing your download share link.");
            return Ok(url);
        }
        if attempted.is_some() {
            // A cancelled or uncertain POST may already have created a link.
            // Reconcile My Shares, never create duplicates on automatic retry.
            return Err(Error::Guest("A previous download share creation could not be confirmed. Dynamic mode will use User access."));
        }

        remember(cache.as_ref(), &key, None)?;
        state.remember(&key, &file.id, None, Instant::now());
        tracing::info!(file_id = %file.id, "Share link unavailable: {reason}; creating a new share link to download.");
        let result = track(
            Kind::ShareCreate,
            account.management_request(
                Method::POST,
                "/share",
                &[],
                Some(json!({
                    "file_ids":[file.id], "title":title, "expiration_days":-1,
                    "restore_limit":-1, "share_to":"publiclink", "pass_code_option":"NOT_REQUIRED"
                })),
            ),
        )
        .await;
        let value = match result {
            Ok(value) => value,
            Err(error) => {
                // A definite rejection permits a later retry, including the
                // provider's 429 cooldown. Ambiguous outcomes retain intent.
                if error.mutation_was_rejected() {
                    if let Some(cache) = &cache {
                        cache
                            .forget_download_share(&key)
                            .map_err(|_| cache_unavailable())?;
                    }
                    state.state.lock().unwrap().links.remove(&key);
                }
                return Err(error);
            }
        };
        let url = public_share_url(&value)?;
        remember(cache.as_ref(), &key, Some(&url))?;
        state.remember(&key, &file.id, Some(&url), state.started);
        Ok(url)
    }
}

fn remember(cache: Option<&DuplicateCache>, key: &str, url: Option<&str>) -> Result<()> {
    if let Some(cache) = cache {
        cache
            .remember_download_share(key, url)
            .map_err(|_| cache_unavailable())?;
    }
    Ok(())
}

fn cache_unavailable() -> Error {
    Error::Guest("Download share tracking is unavailable. Dynamic mode will use User access.")
}

fn public_share_url(value: &Value) -> Result<String> {
    if value["pass_code"]
        .as_str()
        .is_some_and(|code| !code.is_empty())
        || value["pass_code_option"] == "REQUIRED"
        || value["share_to"] == "encryptedlink"
        || value["share_status"]
            .as_str()
            .is_some_and(|status| !status.is_empty() && status != "OK")
    {
        return Err(Error::Guest(
            "The download share is not publicly accessible.",
        ));
    }
    let id = value["share_id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or(Error::Guest(
            "PikPak did not confirm the download share ID.",
        ))?;
    let url = value["share_url"]
        .as_str()
        .filter(|url| !url.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("https://mypikpak.com/s/{id}"));
    let parsed = ParsedShareLink::parse(&url)?;
    if parsed.share_id != id {
        return Err(Error::Guest(
            "PikPak returned a mismatched download share link.",
        ));
    }
    Ok(url)
}

async fn owned_shares(account: &Client) -> Result<Vec<Value>> {
    let mut shares = Vec::new();
    let mut token = String::new();
    let mut seen = HashSet::new();
    loop {
        let value = crate::download_waits::track(
            crate::download_waits::Kind::ShareInventoryPage,
            account.management_request(
                Method::GET,
                "/share/list",
                &[("limit", "100".into()), ("page_token", token)],
                None,
            ),
        )
        .await?;
        shares.extend(
            value["data"]
                .as_array()
                .ok_or(Error::Guest(
                    "PikPak returned an unreadable My Shares list; no download share was created.",
                ))?
                .iter()
                .cloned(),
        );
        token = match value.get("next_page_token") {
            None | Some(Value::Null) => String::new(),
            Some(Value::String(token)) => token.clone(),
            _ => {
                return Err(Error::IncompleteListing(
                    "PikPak returned an invalid My Shares page token",
                ))
            }
        };
        if token.is_empty() {
            return Ok(shares);
        }
        if !seen.insert(token.clone()) {
            return Err(Error::IncompleteListing(
                "PikPak repeated a My Shares page token",
            ));
        }
    }
}

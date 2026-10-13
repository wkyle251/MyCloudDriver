//! Exact duplicate filtering for files selected from a public share link.
//! Folder restores retain PikPak's existing recursive behavior. Source share
//! IDs never become account inventory entries; only account listings do.
use std::{
    collections::{HashMap, HashSet},
    fs::File,
    path::Path,
    time::Duration,
};

use anyhow::{bail, Context, Result};
use futures_util::{stream, StreamExt, TryStreamExt};
use serde_json::{json, Value};

use crate::{duplicate_cache::DuplicateCache, Client, FileInfo, ShareClient};

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct Identity {
    kind: u8,
    hash: String,
    size: u64,
}

fn identity(file: &FileInfo) -> Option<Identity> {
    if !file.kind.is_file() {
        return None;
    }
    let normalized = |value: Option<&str>| {
        value
            .map(str::trim)
            .filter(|hash| !hash.is_empty())
            .map(str::to_ascii_lowercase)
    };
    let (kind, hash) = if let Some(hash) = normalized(file.hash.as_deref()) {
        (0, hash)
    } else {
        (1, normalized(file.md5_checksum.as_deref())?)
    };
    Some(Identity {
        kind,
        hash,
        size: file.size,
    })
}

fn cached_file_is_missing(error: &crate::Error) -> bool {
    match error {
        crate::Error::Api { status: 404, .. } => true,
        crate::Error::Api {
            status: 400,
            message,
        } => serde_json::from_str::<Value>(message).is_ok_and(|value| {
            (value["error"] == "file_in_recycle_bin" && value["error_code"] == 9)
                || (value["error"] == "file_not_found" && value["error_code"] == 5)
        }),
        _ => false,
    }
}

trait Backend {
    async fn source_info(&self, id: &str) -> Result<FileInfo>;
    fn exact_candidates(&self, file: &FileInfo) -> Result<Vec<FileInfo>>;
    async fn live_file(&self, id: &str) -> Result<Option<FileInfo>>;
    async fn restore(&self, ids: &[String]) -> Result<Value>;
}

struct AccountBackend<'a> {
    account: &'a Client,
    share: &'a ShareClient,
    pass_token: &'a str,
    cache: Option<&'a DuplicateCache>,
}

impl Backend for AccountBackend<'_> {
    async fn source_info(&self, id: &str) -> Result<FileInfo> {
        Ok(self.share.file_info(id).await?)
    }
    fn exact_candidates(&self, file: &FileInfo) -> Result<Vec<FileInfo>> {
        if let Some(cache) = self.cache {
            match cache.find_exact(file) {
                Ok(files) => return Ok(files),
                Err(error) => {
                    tracing::warn!(%error, "exact duplicate cache unavailable; retaining shared selection")
                }
            }
        }
        Ok(Vec::new())
    }
    async fn live_file(&self, id: &str) -> Result<Option<FileInfo>> {
        let mut value = match self.account.file_metadata(id).await {
            Ok(value) => value,
            Err(error) if cached_file_is_missing(&error) => {
                self.remove_cached(id);
                return Ok(None);
            }
            Err(error) => return Err(error.into()),
        };
        if value["trashed"] == true {
            self.remove_cached(id);
            return Ok(None);
        }
        // Missing liveness/size fields are insufficient proof for skipping.
        // A changed file can safely replace its old cache identity.
        if value["id"].as_str() != Some(id)
            || value["trashed"] != false
            || value["kind"] != "drive#file"
            || (value
                .get("phase")
                .is_some_and(|phase| phase != "PHASE_TYPE_COMPLETE"))
            || value["size"]
                .as_u64()
                .or_else(|| value["size"].as_str()?.parse().ok())
                .is_none()
        {
            return Ok(None);
        }
        if let Some(size) = value["size"].as_u64() {
            value["size"] = json!(size.to_string());
        }
        Ok(Some(serde_json::from_value(value)?))
    }
    async fn restore(&self, ids: &[String]) -> Result<Value> {
        let token = self.share.pass_code_token().await;
        // Metadata access may have exchanged or refreshed the passcode token.
        let token = if token.trim().is_empty() {
            self.pass_token
        } else {
            &token
        };
        let saved = self
            .account
            .restore_shared_files(&self.share.parsed_link().share_id, token, ids)
            .await?;
        Ok(serde_json::to_value(saved)?)
    }
}

impl AccountBackend<'_> {
    fn remove_cached(&self, id: &str) {
        if let Some(cache) = self.cache {
            if let Err(error) = cache.remove(&[id.to_string()]) {
                tracing::warn!(%error, "could not evict stale duplicate-cache entry");
            }
        }
    }
}

fn selected_ids(ids: &[String]) -> Result<Vec<String>> {
    let mut seen = HashSet::new();
    let ids: Vec<_> = ids
        .iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty() && seen.insert(id.clone()))
        .collect();
    if ids.is_empty() {
        bail!("at least one shared file or folder is required");
    }
    Ok(ids)
}

async fn apply(backend: &impl Backend, ids: &[String]) -> Result<Value> {
    let ids = selected_ids(ids)?;
    // Bounded concurrency matters for large selections, while preserving
    // request order so the same copy is always retained within a selection.
    let files: Vec<_> = stream::iter(ids.iter())
        .map(|id| async move {
            let file = backend
                .source_info(id)
                .await
                .context("read selected shared item metadata")?;
            if file.id != *id {
                bail!("PikPak returned metadata for a different selected shared item");
            }
            Ok::<_, anyhow::Error>(file)
        })
        .buffered(8)
        .try_collect()
        .await?;
    let selected: HashMap<_, _> = files.iter().map(|file| (file.id.as_str(), file)).collect();
    let mut verified = HashMap::<String, Option<FileInfo>>::new();
    let mut seen_content = HashSet::new();
    let mut restore_ids = Vec::new();
    let mut skipped = Vec::new();
    let mut overlaps = Vec::new();
    for file in &files {
        // Parent and child selections should not create two copies. Only use
        // ancestry we already know; never traverse a selected folder to filter it.
        let mut parent = file.parent_id.as_deref();
        let mut ancestors = HashSet::new();
        let mut covered = false;
        while let Some(id) = parent.filter(|id| !id.is_empty()) {
            if !ancestors.insert(id) {
                bail!("PikPak returned cyclic shared folder ancestry");
            }
            let Some(ancestor) = selected.get(id) else {
                break;
            };
            if ancestor.kind.is_folder() {
                covered = true;
                break;
            }
            parent = ancestor.parent_id.as_deref();
        }
        if covered {
            overlaps.push(file.id.clone());
            continue;
        }
        let Some(key) = identity(file) else {
            restore_ids.push(file.id.clone());
            continue;
        };
        if !seen_content.insert(key.clone()) {
            skipped.push(file.id.clone());
            continue;
        }
        let mut exists = false;
        for candidate in backend
            .exact_candidates(file)
            .context("look up exact file identities in the account cache")?
        {
            if !verified.contains_key(&candidate.id) {
                let live = backend
                    .live_file(&candidate.id)
                    .await
                    .context("verify a cached duplicate before skipping the shared file")?;
                verified.insert(candidate.id.clone(), live);
            }
            if verified
                .get(&candidate.id)
                .and_then(Option::as_ref)
                .and_then(identity)
                .as_ref()
                == Some(&key)
            {
                exists = true;
                break;
            }
        }
        if exists {
            skipped.push(file.id.clone());
        } else {
            restore_ids.push(file.id.clone());
        }
    }
    let mut result = if restore_ids.is_empty() {
        json!({"restore_status":"RESTORE_SKIPPED_DUPLICATES","saved_count":0})
    } else {
        backend
            .restore(&restore_ids)
            .await
            .context("save shared selection failed")?
    };
    result["saved_count"] = json!(restore_ids.len());
    result["skipped_duplicate_count"] = json!(skipped.len());
    result["skipped_duplicate_ids"] = json!(skipped);
    result["skipped_overlap_count"] = json!(overlaps.len());
    result["processed_file_ids"] = json!(ids);
    Ok(result)
}

async fn account_save_lock(path: &Path) -> Result<File> {
    let path = path.with_extension("share-save.lock");
    // A nonblocking lock with async backoff does not block a Tokio worker or
    // strand a background blocking waiter after the save future is cancelled.
    let lock = rustix::fs::openat(
        rustix::fs::CWD,
        &path,
        rustix::fs::OFlags::CREATE
            | rustix::fs::OFlags::RDWR
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
    )?;
    let file = File::from(lock);
    if !file.metadata()?.is_file() {
        bail!("shared-save lock is not a regular file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    loop {
        match rustix::fs::flock(&file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => return Ok(file),
            Err(rustix::io::Errno::WOULDBLOCK) => {
                tokio::time::sleep(Duration::from_millis(100)).await
            }
            Err(error) => return Err(error.into()),
        }
    }
}

/// Saves link selections, skipping only verified exact file matches. Whole
/// folder saves are deliberately left intact. Accepted restores remain a
/// success even if supplemental destination-cache refresh requests fail.
pub async fn save_unique_shared_files(
    account: &Client,
    share: &ShareClient,
    pass_token: &str,
    ids: &[String],
) -> Result<Value> {
    let cache = account.duplicate_cache().await;
    let _lock = match &cache {
        Some(cache) => Some(account_save_lock(cache.path()).await?),
        None => None,
    };
    let backend = AccountBackend {
        account,
        share,
        pass_token,
        cache: cache.as_ref(),
    };
    let mut result = apply(&backend, ids).await?;
    result["duplicate_cache_enabled"] = json!(cache.is_some());
    if result["saved_count"].as_u64().unwrap_or(0) > 0 {
        let status = result["restore_status"].as_str().unwrap_or("");
        let unfinished = !status.eq_ignore_ascii_case("RESTORE_COMPLETE")
            && !status.eq_ignore_ascii_case("COMPLETE");
        let mut parents = Vec::new();
        if let Ok(entries) = account.list_folder("").await {
            parents = entries
                .into_iter()
                .filter(|entry| entry.kind.is_folder() && entry.name == "Pack From Shared")
                .map(|entry| entry.id)
                .collect();
            for parent in &parents {
                if let Err(error) = account.list_folder(parent).await {
                    tracing::warn!(%error, "could not refresh shared-save destination cache");
                }
            }
            if !parents.is_empty() {
                result["cache_parent_ids"] = json!(&parents);
            }
        }
        if unfinished {
            result["duplicate_cache_refresh_needed"] = json!(true);
            if let Some(cache) = &cache {
                // Share restore has no supported completion polling endpoint.
                // Keep its branch incomplete until an explicit refresh after
                // the save finishes; never treat a pending source as a live file.
                let task = result["restore_task_id"]
                    .as_str()
                    .filter(|id| !id.is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| {
                        let stamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|time| time.as_nanos())
                            .unwrap_or_default();
                        format!("{}-{stamp}", share.parsed_link().share_id)
                    });
                let task = format!("share-restore:{task}");
                if parents.is_empty() {
                    parents.push(String::new());
                }
                for parent in &parents {
                    if let Err(error) = cache.mark_pending_folder(parent, &task) {
                        tracing::warn!(%error, "could not keep asynchronous share destination incomplete");
                    }
                }
            }
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[derive(Default)]
    struct Fake {
        source: HashMap<String, FileInfo>,
        cached: Vec<FileInfo>,
        live: HashMap<String, Option<FileInfo>>,
        metadata_reads: Mutex<Vec<String>>,
        restored: Mutex<Vec<Vec<String>>>,
        fail_verification: bool,
    }
    impl Backend for Fake {
        async fn source_info(&self, id: &str) -> Result<FileInfo> {
            Ok(self.source[id].clone())
        }
        fn exact_candidates(&self, file: &FileInfo) -> Result<Vec<FileInfo>> {
            Ok(self
                .cached
                .iter()
                .filter(|candidate| identity(candidate) == identity(file))
                .cloned()
                .collect())
        }
        async fn live_file(&self, id: &str) -> Result<Option<FileInfo>> {
            self.metadata_reads.lock().unwrap().push(id.to_string());
            if self.fail_verification {
                bail!("temporarily unavailable");
            }
            Ok(self.live.get(id).cloned().flatten())
        }
        async fn restore(&self, ids: &[String]) -> Result<Value> {
            self.restored.lock().unwrap().push(ids.to_vec());
            Ok(json!({"restore_status":"RESTORE_COMPLETE","saved_count":ids.len()}))
        }
    }
    fn file(id: &str, hash: Option<&str>, size: u64) -> FileInfo {
        serde_json::from_value(
            json!({"id":id,"name":"same.bin","kind":"drive#file", "size":size.to_string(),
            "parent_id":"", "hash":hash}),
        )
        .unwrap()
    }
    fn fixture(files: Vec<FileInfo>) -> Fake {
        Fake {
            source: files
                .into_iter()
                .map(|file| (file.id.clone(), file))
                .collect(),
            ..Default::default()
        }
    }
    fn ids(values: &[&str]) -> Vec<String> {
        values.iter().map(|id| id.to_string()).collect()
    }
    fn wire(file: &FileInfo) -> Value {
        let mut value = serde_json::to_value(file).unwrap();
        value["size"] = json!(file.size.to_string());
        value
    }

    #[test]
    fn only_explicit_missing_or_trash_errors_evict_cached_content() {
        assert!(cached_file_is_missing(&crate::Error::Api {
            status: 404,
            message: "".into()
        }));
        for (status, message, expected) in [
            (
                400,
                r#"{"error":"file_in_recycle_bin","error_code":9}"#,
                true,
            ),
            (400, r#"{"error":"file_not_found","error_code":5}"#, true),
            (
                400,
                r#"{"error":"file_in_recycle_bin","error_code":99}"#,
                false,
            ),
            (
                403,
                r#"{"error":"file_in_recycle_bin","error_code":9}"#,
                false,
            ),
        ] {
            assert_eq!(
                cached_file_is_missing(&crate::Error::Api {
                    status,
                    message: message.into()
                }),
                expected
            );
        }
    }

    #[tokio::test]
    async fn verified_exact_duplicate_needs_no_restore() {
        let mut fake = fixture(vec![file("share-a", Some(" ABC "), 9)]);
        let cached = file("account-copy", Some("abc"), 9);
        fake.cached = vec![cached.clone()];
        fake.live.insert(cached.id.clone(), Some(cached));
        let result = apply(&fake, &ids(&["share-a", "share-a"])).await.unwrap();
        assert_eq!(result["saved_count"], 0);
        assert_eq!(result["skipped_duplicate_count"], 1);
        assert!(fake.restored.lock().unwrap().is_empty());
        assert_eq!(*fake.metadata_reads.lock().unwrap(), vec!["account-copy"]);
    }

    #[tokio::test]
    async fn changed_and_deleted_cached_copies_are_saved() {
        for current in [
            None,
            Some(file("account-copy", Some("different"), 9)),
            Some(file("account-copy", Some("same"), 10)),
        ] {
            let mut fake = fixture(vec![file("new", Some("same"), 9)]);
            fake.cached = vec![file("account-copy", Some("same"), 9)];
            fake.live.insert("account-copy".into(), current);
            let result = apply(&fake, &ids(&["new"])).await.unwrap();
            assert_eq!(result["saved_count"], 1);
            assert_eq!(result["skipped_duplicate_count"], 0);
            assert_eq!(*fake.restored.lock().unwrap(), vec![ids(&["new"])]);
        }
    }

    #[tokio::test]
    async fn hashless_same_names_and_different_sizes_are_not_skipped() {
        let fake = fixture(vec![
            file("a", None, 9),
            file("b", Some(" "), 9),
            file("c", Some("same"), 9),
            file("d", Some("same"), 10),
        ]);
        let result = apply(&fake, &ids(&["a", "b", "c", "d"])).await.unwrap();
        assert_eq!(result["saved_count"], 4);
        assert_eq!(result["skipped_duplicate_count"], 0);
        assert!(fake.metadata_reads.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn duplicate_files_in_selection_are_skipped_and_folders_pass_through() {
        let mut folder = file("folder", Some("same"), 9);
        folder.kind = crate::FileKind::Folder;
        let fake = fixture(vec![
            folder,
            file("a", Some("same"), 9),
            file("b", Some("SAME"), 9),
        ]);
        let result = apply(&fake, &ids(&["folder", "a", "b"])).await.unwrap();
        assert_eq!(result["saved_count"], 2);
        assert_eq!(result["skipped_duplicate_count"], 1);
        assert_eq!(*fake.restored.lock().unwrap(), vec![ids(&["folder", "a"])]);
    }

    #[tokio::test]
    async fn selected_folder_covers_known_direct_child_without_traversal() {
        let mut folder = file("folder", None, 0);
        folder.kind = crate::FileKind::Folder;
        let mut child = file("child", Some("same"), 9);
        child.parent_id = Some("folder".into());
        let fake = fixture(vec![folder, child]);
        let result = apply(&fake, &ids(&["child", "folder"])).await.unwrap();
        assert_eq!(result["saved_count"], 1);
        assert_eq!(result["skipped_overlap_count"], 1);
        assert_eq!(*fake.restored.lock().unwrap(), vec![ids(&["folder"])]);
        assert!(fake.metadata_reads.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn unable_to_verify_a_cached_match_prevents_restore() {
        let mut fake = fixture(vec![file("new", Some("same"), 9)]);
        fake.cached = vec![file("account-copy", Some("same"), 9)];
        fake.fail_verification = true;
        assert!(apply(&fake, &ids(&["new"])).await.is_err());
        assert!(fake.restored.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn md5_fallback_never_overrides_a_present_content_hash() {
        let mut a = file("a", None, 9);
        a.md5_checksum = Some("MD5".into());
        let mut b = file("b", None, 9);
        b.md5_checksum = Some("md5".into());
        let mut c = file("c", Some("gcid"), 9);
        c.md5_checksum = Some("md5".into());
        let fake = fixture(vec![a, b, c]);
        let result = apply(&fake, &ids(&["a", "b", "c"])).await.unwrap();
        assert_eq!(result["saved_count"], 2);
        assert_eq!(result["skipped_duplicate_count"], 1);
        assert_eq!(*fake.restored.lock().unwrap(), vec![ids(&["a", "c"])]);
    }

    struct HttpFixture {
        account: Client,
        share: ShareClient,
        requests: Arc<Mutex<Vec<(String, String, Value)>>>,
        fail_destination_listing: Arc<AtomicBool>,
        restore_status: Arc<Mutex<String>>,
        task: tokio::task::JoinHandle<()>,
        _directory: tempfile::TempDir,
    }
    impl Drop for HttpFixture {
        fn drop(&mut self) {
            self.task.abort();
        }
    }
    impl HttpFixture {
        async fn new(source: Vec<FileInfo>, existing: Vec<FileInfo>) -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let requests = Arc::new(Mutex::new(Vec::new()));
            let records = requests.clone();
            let fail_destination_listing = Arc::new(AtomicBool::new(false));
            let fail_lists = fail_destination_listing.clone();
            let restore_status = Arc::new(Mutex::new("RESTORE_COMPLETE".to_string()));
            let save_status = restore_status.clone();
            let sources: HashMap<_, _> = source
                .into_iter()
                .map(|file| (file.id.clone(), file))
                .collect();
            let mut remote: Vec<Value> = existing
                .into_iter()
                .map(|file| {
                    let mut value = wire(&file);
                    value["parent_id"] = json!("other-folder");
                    value["trashed"] = json!(false);
                    value["phase"] = json!("PHASE_TYPE_COMPLETE");
                    value
                })
                .collect();
            remote.extend([
                json!({"id":"pack-folder","name":"Pack From Shared","kind":"drive#folder","parent_id":"","trashed":false,"phase":"PHASE_TYPE_COMPLETE"}),
                json!({"id":"other-folder","name":"Other","kind":"drive#folder","parent_id":"","trashed":false,"phase":"PHASE_TYPE_COMPLETE"}),
            ]);
            let task = tokio::spawn(async move {
                loop {
                    let (mut socket, _) = listener.accept().await.unwrap();
                    let mut request = Vec::new();
                    let (end, length) = loop {
                        let mut buffer = [0; 4096];
                        let count = socket.read(&mut buffer).await.unwrap();
                        if count == 0 {
                            break (0, 0);
                        }
                        request.extend_from_slice(&buffer[..count]);
                        if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                            let header = String::from_utf8_lossy(&request[..end]);
                            let length = header
                                .lines()
                                .find_map(|line| {
                                    line.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .and_then(|value| value.trim().parse::<usize>().ok())
                                })
                                .unwrap_or(0);
                            if request.len() >= end + 4 + length {
                                break (end + 4, length);
                            }
                        }
                    };
                    if end == 0 {
                        continue;
                    }
                    let header = String::from_utf8_lossy(&request[..end]);
                    let mut first = header.lines().next().unwrap().split_whitespace();
                    let method = first.next().unwrap();
                    let url = url::Url::parse(&format!("http://fixture{}", first.next().unwrap()))
                        .unwrap();
                    let body: Value =
                        serde_json::from_slice(&request[end..end + length]).unwrap_or(Value::Null);
                    records.lock().unwrap().push((
                        method.to_string(),
                        url.path().to_string(),
                        body.clone(),
                    ));
                    let mut status = 200;
                    let response = match (method, url.path()) {
                        ("GET", "/v1/user/me") => json!({"sub":"fixture-account","name":"Fixture"}),
                        ("GET", "/drive/v1/share/file_info") => {
                            let id = url
                                .query_pairs()
                                .find(|(key, _)| key == "file_id")
                                .unwrap()
                                .1
                                .to_string();
                            json!({"share_status":"OK","file_info":wire(&sources[&id])})
                        }
                        ("GET", "/drive/v1/files") => {
                            let parent = url
                                .query_pairs()
                                .find(|(key, _)| key == "parent_id")
                                .unwrap()
                                .1
                                .to_string();
                            if fail_lists.load(Ordering::SeqCst) {
                                status = 400;
                                json!({"error":"fixture_listing_unavailable"})
                            } else {
                                json!({"files":remote.iter().filter(|file| file["parent_id"] == parent && file["trashed"] == false).cloned().collect::<Vec<_>>()})
                            }
                        }
                        ("POST", "/drive/v1/share/restore") => {
                            for id in body["file_ids"].as_array().unwrap() {
                                let id = id.as_str().unwrap();
                                let mut value = wire(&sources[id]);
                                value["id"] = json!(format!("saved-{id}"));
                                value["parent_id"] = json!("pack-folder");
                                value["trashed"] = json!(false);
                                value["phase"] = json!("PHASE_TYPE_COMPLETE");
                                remote.push(value);
                            }
                            json!({"restore_status":save_status.lock().unwrap().clone(),"restore_task_id":"fixture-restore-task"})
                        }
                        ("GET", path) if path.starts_with("/drive/v1/files/") => {
                            let id = path.rsplit('/').next().unwrap();
                            match remote.iter().find(|file| file["id"] == id) {
                                Some(file) => file.clone(),
                                None => {
                                    status = 404;
                                    json!({"error":"file_not_found"})
                                }
                            }
                        }
                        route => panic!("unexpected link-save fixture route {route:?}"),
                    };
                    let bytes = serde_json::to_vec(&response).unwrap();
                    let header = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", bytes.len());
                    socket.write_all(header.as_bytes()).await.unwrap();
                    socket.write_all(&bytes).await.unwrap();
                }
            });
            let directory = tempfile::tempdir().unwrap();
            let account = Client::builder()
                .personal_access_token("fixture-access")
                .api_base_url(&base)
                .auth_base_url(&base)
                .build()
                .unwrap()
                .with_duplicate_cache_directory(directory.path().to_path_buf());
            let share = ShareClient::new_authenticated(
                "https://mypikpak.com/s/fixture-share",
                "",
                "fixture-pass",
                account.clone(),
            )
            .unwrap()
            .with_endpoints(&base, &base);
            account.list_folder("").await.unwrap();
            account.list_folder("other-folder").await.unwrap();
            requests.lock().unwrap().clear();
            Self {
                account,
                share,
                requests,
                fail_destination_listing,
                restore_status,
                task,
                _directory: directory,
            }
        }
    }

    #[tokio::test]
    async fn link_save_fixture_updates_inventory_and_reuses_it_without_relisting() {
        let fixture = HttpFixture::new(
            vec![
                file("old", Some("old-hash"), 9),
                file("new", Some("new-hash"), 10),
            ],
            vec![file("existing", Some("old-hash"), 9)],
        )
        .await;
        let first = save_unique_shared_files(
            &fixture.account,
            &fixture.share,
            "fixture-pass",
            &ids(&["old", "new"]),
        )
        .await
        .unwrap();
        assert_eq!(first["saved_count"], 1);
        assert_eq!(first["skipped_duplicate_count"], 1);
        assert_eq!(first["cache_parent_ids"], json!(["pack-folder"]));
        let requests = fixture.requests.lock().unwrap().clone();
        assert_eq!(
            requests
                .iter()
                .find(|(method, path, _)| method == "POST" && path == "/drive/v1/share/restore")
                .unwrap()
                .2["file_ids"],
            json!(["new"])
        );
        let cache = fixture.account.duplicate_cache().await.unwrap();
        assert_eq!(
            cache
                .find_exact(&file("new", Some("new-hash"), 10))
                .unwrap()[0]
                .id,
            "saved-new"
        );
        fixture.requests.lock().unwrap().clear();
        let second = save_unique_shared_files(
            &fixture.account,
            &fixture.share,
            "fixture-pass",
            &ids(&["new"]),
        )
        .await
        .unwrap();
        assert_eq!(second["saved_count"], 0);
        assert_eq!(second["skipped_duplicate_count"], 1);
        let requests = fixture.requests.lock().unwrap();
        assert!(requests
            .iter()
            .any(|(_, path, _)| path == "/drive/v1/files/saved-new"));
        assert!(!requests
            .iter()
            .any(|(method, path, _)| method == "POST" || path == "/drive/v1/files"));
    }

    #[tokio::test]
    async fn concurrent_link_saves_recheck_the_cache_after_the_account_lock() {
        let fixture = HttpFixture::new(vec![file("new", Some("new-hash"), 10)], vec![]).await;
        let selected = ids(&["new"]);
        let (first, second) = tokio::join!(
            save_unique_shared_files(&fixture.account, &fixture.share, "fixture-pass", &selected),
            save_unique_shared_files(&fixture.account, &fixture.share, "fixture-pass", &selected)
        );
        let first = first.unwrap();
        let second = second.unwrap();
        assert_eq!(
            first["saved_count"].as_u64().unwrap() + second["saved_count"].as_u64().unwrap(),
            1
        );
        assert_eq!(
            first["skipped_duplicate_count"].as_u64().unwrap()
                + second["skipped_duplicate_count"].as_u64().unwrap(),
            1
        );
        assert_eq!(
            fixture
                .requests
                .lock()
                .unwrap()
                .iter()
                .filter(|(method, path, _)| method == "POST" && path == "/drive/v1/share/restore")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn accepted_restore_stays_successful_when_destination_refresh_fails() {
        let fixture = HttpFixture::new(vec![file("new", Some("new-hash"), 10)], vec![]).await;
        fixture
            .fail_destination_listing
            .store(true, Ordering::SeqCst);
        let result = save_unique_shared_files(
            &fixture.account,
            &fixture.share,
            "fixture-pass",
            &ids(&["new"]),
        )
        .await
        .unwrap();
        assert_eq!(result["saved_count"], 1);
        assert_eq!(result["restore_status"], "RESTORE_COMPLETE");
        assert_eq!(
            fixture
                .requests
                .lock()
                .unwrap()
                .iter()
                .filter(|(method, path, _)| method == "POST" && path == "/drive/v1/share/restore")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn missing_account_copy_is_evicted_before_restoring_the_shared_file() {
        let fixture = HttpFixture::new(vec![file("new", Some("new-hash"), 10)], vec![]).await;
        let cache = fixture.account.duplicate_cache().await.unwrap();
        cache
            .upsert_files(
                "other-folder",
                &[file("no-longer-live", Some("new-hash"), 10)],
            )
            .unwrap();
        let result = save_unique_shared_files(
            &fixture.account,
            &fixture.share,
            "fixture-pass",
            &ids(&["new"]),
        )
        .await
        .unwrap();
        assert_eq!(result["saved_count"], 1);
        assert_eq!(result["skipped_duplicate_count"], 0);
        let matches = cache
            .find_exact(&file("new", Some("new-hash"), 10))
            .unwrap();
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].id, "saved-new");
    }

    #[tokio::test]
    async fn asynchronous_restore_keeps_destination_uncached_until_explicit_refresh() {
        let fixture = HttpFixture::new(vec![file("new", Some("new-hash"), 10)], vec![]).await;
        *fixture.restore_status.lock().unwrap() = "RESTORE_RUNNING".into();
        let result = save_unique_shared_files(
            &fixture.account,
            &fixture.share,
            "fixture-pass",
            &ids(&["new"]),
        )
        .await
        .unwrap();
        assert_eq!(result["duplicate_cache_refresh_needed"], true);
        let cache = fixture.account.duplicate_cache().await.unwrap();
        assert_eq!(
            cache.pending_task_ids().unwrap(),
            vec!["share-restore:fixture-restore-task"]
        );
        assert!(cache.folder("pack-folder").unwrap().is_none());
        fixture.requests.lock().unwrap().clear();
        fixture
            .account
            .list_folder("pack-folder")
            .await
            .unwrap();
        assert_eq!(
            fixture
                .requests
                .lock()
                .unwrap()
                .iter()
                .filter(|(_, path, _)| path == "/drive/v1/files")
                .count(),
            1
        );
        assert!(
            cache.folder("pack-folder").unwrap().is_none(),
            "A listing while the share task is pending cannot become a complete snapshot"
        );
        // Observing completion clears the share marker; a new listing can then
        // populate the inventory used by subsequent shared saves.
        cache
            .complete_pending_task("share-restore:fixture-restore-task")
            .unwrap();
        fixture
            .account
            .list_folder("pack-folder")
            .await
            .unwrap();
        assert!(cache.folder("pack-folder").unwrap().is_some());
        fixture.requests.lock().unwrap().clear();
        fixture
            .account
            .list_folder("pack-folder")
            .await
            .unwrap();
        assert_eq!(fixture.requests.lock().unwrap().iter()
            .filter(|(_, path, _)| path == "/drive/v1/files").count(), 1,
            "folder listings always fetch current metadata");
    }
}

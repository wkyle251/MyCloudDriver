use super::*;
use std::cmp::Ordering as SortOrder;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::sync::Mutex;

use crate::duplicate_admission::{Admission, Mode as AdmissionMode};

#[path = "duplicate_discovery.rs"]
mod discovery;

#[path = "duplicate_read_gate.rs"]
mod read_gate;
#[path = "duplicate_local_hashes.rs"]
mod local_hashes;

#[cfg(test)]
#[path = "duplicate_cross_drive_tests.rs"]
mod tests;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum DuplicateSource { Pikpak, Local }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct LocalIdentity {
    device: u64, inode: u64, size: u64, modified_seconds: i64, modified_nanoseconds: i64,
    #[serde(default)] changed_seconds: i64,
    #[serde(default)] changed_nanoseconds: i64,
}
impl LocalIdentity {
    fn of(metadata: &std::fs::Metadata) -> Self {
        Self { device: metadata.dev(), inode: metadata.ino(), size: metadata.len(),
            modified_seconds: metadata.mtime(), modified_nanoseconds: metadata.mtime_nsec(),
            changed_seconds: metadata.ctime(), changed_nanoseconds: metadata.ctime_nsec() }
    }
}

#[derive(Deserialize)]
pub(super) struct CloudFolder { pub id: String, pub path: String }
#[derive(Deserialize)]
pub(super) struct Scope {
    pub cloud_folders: Vec<CloudFolder>,
    pub local_paths: Vec<PathBuf>,
}

pub(super) async fn scan(client: &Client, scope: Scope, progress_json: bool) -> Result<DuplicateScan> {
    anyhow::ensure!(!scope.cloud_folders.is_empty() || !scope.local_paths.is_empty(), "Choose at least one folder to compare");
    let mut candidates = Vec::new();
    let (mut folders, mut failed) = (0usize, 0usize);
    let mut seen = HashSet::new();
    let mut paths = Vec::new();
    for root in scope.cloud_folders {
        paths.push(format!("PikPak: {}", root.path));
        let (scanned, skipped, files) = collect_duplicate_candidates(client, &root.id, &root.path, progress_json).await?;
        folders += scanned; failed += skipped;
        candidates.extend(files.into_iter().filter(|file| seen.insert(file.id.clone())));
    }
    let local = discovery::collect(&scope.local_paths, candidates.len(), folders, failed, progress_json).await?;
    folders += local.folders;
    failed += local.failed;
    paths.extend(scope.local_paths.iter().map(|path| path.display().to_string()));
    let cache_directory = client.duplicate_cache_directory().map(PathBuf::from);
    let cache = tokio::task::spawn_blocking(move || local_hashes::HashCache::open(cache_directory.as_deref())).await?;
    collect_local_candidates(local.files, &mut candidates, folders, &mut failed, progress_json,
        AdmissionMode::Automatic, move |path, identity, md5, progress, reader| {
            cache.hash(path, identity, md5, progress, reader)
        }).await?;
    let root_path = if paths.len() == 1 { let path = paths.remove(0); path.strip_prefix("PikPak: ").unwrap_or(&path).to_owned() }
        else { paths.join(" • ") };
    let mut result = build_duplicate_scan(root_path, folders, candidates);
    result.failed_folders = failed;
    Ok(result)
}

#[derive(Clone, Serialize, Deserialize)]
struct LocalHashes {
    gcid: String,
    md5: Option<String>,
}

struct LocalScanProgress {
    enabled: bool,
    scanned_files: usize,
    folders: usize,
    failed: usize,
    last: Instant,
    bytes: Arc<AtomicU64>,
    active_files: usize,
    pending_files: usize,
    current_path: PathBuf,
}

impl LocalScanProgress {
    fn report(&mut self, path: &StdPath, force: bool) {
        if !self.enabled || (!force && self.last.elapsed() < Duration::from_millis(250)) {
            return;
        }
        // Serialize progress with completed counts so a slower worker cannot
        // publish an old snapshot after another worker has finished.
        self.current_path = path.to_owned();
        emit_duplicate_progress(true, DuplicateProgressEvent::LocalHashProgress {
            scanned_files: self.scanned_files, scanned_folders: self.folders,
            discovered_folders: self.folders, pending_folders: 0,
            failed_folders: self.failed, current_path: &path.to_string_lossy(),
            hashed_bytes: self.bytes.load(Ordering::Relaxed),
            active_files: self.active_files, pending_files: self.pending_files,
        });
        self.last = Instant::now();
    }

    fn heartbeat(&mut self) {
        if !self.enabled { return; }
        let path = self.current_path.clone();
        self.report(&path, false);
    }
}

async fn collect_local_candidates<H>(
    local: Vec<(PathBuf, LocalIdentity)>, candidates: &mut Vec<DuplicateCandidate>,
    folders: usize, failed: &mut usize, progress_json: bool, concurrency: impl Into<AdmissionMode>, hash: H,
) -> Result<()>
where
    H: Fn(&StdPath, &mut LocalIdentity, bool, &mut dyn FnMut(u64), &read_gate::Reader) -> Result<LocalHashes> + Send + Sync + 'static,
{
    let has_local_files = !local.is_empty();
    let mut sizes = HashMap::<u64, usize>::new();
    for size in candidates.iter().map(|file| file.size).chain(local.iter().map(|(_, identity)| identity.size)) {
        *sizes.entry(size).or_default() += 1;
    }
    // GCID is enough for local/local and ordinary local/PikPak matches.
    // Only spend CPU on MD5 for sizes with a cloud record that needs it.
    let md5_sizes: HashSet<_> = candidates.iter().filter(|file| {
        normalized_digest(file.content_hash.as_deref()).is_none()
            && normalized_digest(file.md5_checksum.as_deref()).is_some()
    }).map(|file| file.size).collect();
    let completed_bytes = Arc::new(AtomicU64::new(0));
    let progress = Arc::new(Mutex::new(LocalScanProgress {
        enabled: progress_json, scanned_files: candidates.len(), folders, failed: *failed, last: Instant::now(),
        bytes: completed_bytes.clone(), active_files: 0, pending_files: local.len(),
        current_path: local.first().map(|(path, _)| path.clone()).unwrap_or_default(),
    }));
    // Switch the UI from discovery to content checks before a slow first read.
    if let Some((path, _)) = local.first() {
        progress.lock().unwrap_or_else(|error| error.into_inner()).report(path, true);
    }
    let hash = Arc::new(hash);
    let mut pending = local.into_iter();
    let mut running = tokio::task::JoinSet::new();
    let mut last_path = PathBuf::new();
    let initial = std::thread::available_parallelism().map(usize::from).unwrap_or(1);
    let mut admission = Admission::new(concurrency.into(), initial, true);
    let gate = Arc::new(read_gate::ReadGate::default());
    let _close_readers = read_gate::CloseOnDrop(gate.clone());
    let mut ticker = tokio::time::interval(Duration::from_millis(250));
    loop {
        let active = gate.active();
        let limit = admission.update(Instant::now(), completed_bytes.load(Ordering::Relaxed), active,
            pending.len() > 0 || running.len() > active);
        gate.limit(limit);
        {
            let mut state = progress.lock().unwrap_or_else(|error| error.into_inner());
            state.active_files = gate.active();
            state.pending_files = pending.len() + running.len().saturating_sub(state.active_files);
            state.heartbeat();
        }
        while running.len() < limit {
            let Some((path, mut identity)) = pending.next() else { break };
            // A unique size cannot have a duplicate; never read its contents.
            if sizes[&identity.size] == 1 {
                last_path = path.clone();
                candidates.push(local_candidate(path, identity, None));
                let mut state = progress.lock().unwrap_or_else(|error| error.into_inner());
                state.scanned_files = candidates.len();
                state.pending_files = pending.len();
                state.report(&last_path, false);
                continue;
            }
            let md5 = md5_sizes.contains(&identity.size);
            let hash = hash.clone(); let progress = progress.clone();
            let completed_bytes = completed_bytes.clone();
            let gate = gate.clone();
            {
                let mut state = progress.lock().unwrap_or_else(|error| error.into_inner());
                state.active_files = running.len() + 1; state.pending_files = pending.len();
            }
            running.spawn_blocking(move || {
                let reader = gate.register();
                let mut last_read = 0;
                let result = hash(&path, &mut identity, md5, &mut |read| {
                    completed_bytes.fetch_add(read.saturating_sub(last_read), Ordering::Relaxed);
                    last_read = read;
                    if progress_json {
                        progress.lock().unwrap_or_else(|error| error.into_inner()).report(&path, false);
                    }
                }, &reader);
                (path, identity, result)
            });
        }
        if running.is_empty() {
            if pending.len() == 0 { break; }
            // Critical pressure can pause new work without spinning or losing
            // the inventory. The next sample resumes admission after recovery.
            ticker.tick().await;
            continue;
        }
        let result = tokio::select! {
            result = running.join_next() => result,
            _ = ticker.tick() => continue,
        };
        let Some(result) = result else { break };
        let (path, identity, hashes) = result.context("local duplicate hashing worker failed")?;
        last_path = path.clone();
        match hashes {
            Ok(hashes) => candidates.push(local_candidate(path, identity, Some(hashes))),
            Err(error) => {
                *failed += 1;
                eprintln!("warning: skipped local duplicate candidate {}: {error}", path.display());
            }
        }
        let mut state = progress.lock().unwrap_or_else(|error| error.into_inner());
        state.scanned_files = candidates.len(); state.failed = *failed;
        state.active_files = gate.active();
        state.pending_files = pending.len() + running.len().saturating_sub(state.active_files);
        state.report(&last_path, false);
    }
    if has_local_files {
        progress.lock().unwrap_or_else(|error| error.into_inner()).report(&last_path, true);
    }
    Ok(())
}

fn local_candidate(path: PathBuf, identity: LocalIdentity, hashes: Option<LocalHashes>) -> DuplicateCandidate {
    let (content_hash, md5_checksum) = hashes.map(|hashes| (Some(hashes.gcid), hashes.md5)).unwrap_or_default();
    DuplicateCandidate {
        id: format!("local:{}", path.display()), name: path.file_name().unwrap_or_default().to_string_lossy().into(),
        path: path.to_string_lossy().into(), size: identity.size, modified_time: None,
        content_hash, md5_checksum, source: DuplicateSource::Local,
        folder_created_time: None, local_identity: Some(identity),
    }
}

#[cfg(test)]
fn hash_local(path: &StdPath, before: &LocalIdentity) -> Result<(String, String)> {
    let hashes = hash_local_reporting(path, before, true, |_| {})?;
    Ok((hashes.gcid, hashes.md5.unwrap()))
}

fn hash_local_reporting(path: &StdPath, before: &LocalIdentity, needs_md5: bool, mut progress: impl FnMut(u64)) -> Result<LocalHashes> {
    hash_local_controlled(path, before, needs_md5, &mut progress, || Ok(()))
}

fn hash_local_controlled(path: &StdPath, before: &LocalIdentity, needs_md5: bool,
    mut progress: impl FnMut(u64), mut ready: impl FnMut() -> Result<()>) -> Result<LocalHashes> {
    use std::io::Read;
    use md5::{Digest, Md5};
    let mut file = OpenOptions::new().read(true).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32).open(path)?;
    anyhow::ensure!(file.metadata()?.is_file() && LocalIdentity::of(&file.metadata()?) == *before, "file changed before hashing");
    let mut gcid = pikpak::upload::GcidHasher::new(before.size);
    let mut md5 = needs_md5.then(Md5::new); let mut read = 0u64; let mut buffer = vec![0u8; 256 * 1024];
    progress(0);
    let mut last_progress = std::time::Instant::now();
    loop {
        ready()?;
        let count = file.read(&mut buffer)?;
        if count == 0 { break; }
        gcid.update(&buffer[..count]);
        if let Some(md5) = &mut md5 { md5.update(&buffer[..count]); }
        read += count as u64;
        anyhow::ensure!(read <= before.size, "file grew during hashing");
        if last_progress.elapsed() >= Duration::from_millis(250) {
            progress(read); last_progress = std::time::Instant::now();
        }
    }
    let after = std::fs::symlink_metadata(path)?;
    anyhow::ensure!(read == before.size && after.is_file() && !after.file_type().is_symlink()
        && LocalIdentity::of(&after) == *before && LocalIdentity::of(&file.metadata()?) == *before, "file changed during hashing");
    progress(read);
    Ok(LocalHashes { gcid: gcid.finish(), md5: md5.map(|md5| hex::encode(md5.finalize())) })
}

pub(super) fn keeper_order(a: &DuplicateCandidate, b: &DuplicateCandidate) -> SortOrder {
    // Disk copies precede PikPak. Within PikPak, prefer older folders as keepers.
    (a.source == DuplicateSource::Pikpak).cmp(&(b.source == DuplicateSource::Pikpak))
        .then_with(|| match (&a.folder_created_time, &b.folder_created_time) {
            (Some(a), Some(b)) => a.cmp(b), (None, Some(_)) => SortOrder::Less,
            (Some(_), None) => SortOrder::Greater, _ => SortOrder::Equal,
        })
        .then_with(|| a.path.to_lowercase().cmp(&b.path.to_lowercase())).then_with(|| a.id.cmp(&b.id))
}

pub(super) fn group_candidates(candidates: Vec<DuplicateCandidate>) -> Vec<(DuplicateMatchKind, Vec<DuplicateCandidate>)> {
    fn root(parents: &mut [usize], mut index: usize) -> usize {
        while parents[index] != index { parents[index] = parents[parents[index]]; index = parents[index]; }
        index
    }
    let mut parents: Vec<_> = (0..candidates.len()).collect();
    let mut keys = HashMap::new();
    let mut exact = HashSet::new();
    for (index, candidate) in candidates.iter().enumerate() {
        let mut identifiers = Vec::new();
        if let Some(digest) = normalized_digest(candidate.content_hash.as_deref()) {
            identifiers.push(DuplicateKey::Exact { algorithm: "pikpak_gcid", digest, size: candidate.size });
        }
        if identifiers.is_empty() || candidate.source == DuplicateSource::Local {
            if let Some(digest) = normalized_digest(candidate.md5_checksum.as_deref()) {
                identifiers.push(DuplicateKey::Exact { algorithm: "md5", digest, size: candidate.size });
            }
        }
        if identifiers.is_empty() {
            // An un-hashed local singleton must not become a metadata match.
            identifiers.push(DuplicateKey::Metadata { normalized_name: if candidate.source == DuplicateSource::Local {
                candidate.id.clone()
            } else { candidate.name.trim().to_lowercase() }, size: candidate.size });
        } else { exact.insert(index); }
        for key in identifiers {
            if let Some(previous) = keys.insert(key, index) {
                let parent = root(&mut parents, previous); let current = root(&mut parents, index);
                parents[current] = parent;
            }
        }
    }
    let mut groups: HashMap<usize, (DuplicateMatchKind, Vec<DuplicateCandidate>)> = HashMap::new();
    for (index, candidate) in candidates.into_iter().enumerate() {
        let parent = root(&mut parents, index);
        let kind = if exact.contains(&index) { DuplicateMatchKind::ExactContent } else { DuplicateMatchKind::MatchingNameAndSize };
        groups.entry(parent).or_insert_with(|| (kind, Vec::new())).1.push(candidate);
    }
    groups.into_values().collect()
}

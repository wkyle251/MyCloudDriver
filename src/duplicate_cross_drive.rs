use super::*;
use std::cmp::Ordering as SortOrder;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

#[cfg(test)]
#[path = "duplicate_cross_drive_tests.rs"]
mod tests;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum DuplicateSource { Pikpak, Local }

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(super) struct LocalIdentity {
    device: u64, inode: u64, size: u64, modified_seconds: i64, modified_nanoseconds: i64,
}
impl LocalIdentity {
    fn of(metadata: &std::fs::Metadata) -> Self {
        Self { device: metadata.dev(), inode: metadata.ino(), size: metadata.len(),
            modified_seconds: metadata.mtime(), modified_nanoseconds: metadata.mtime_nsec() }
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
    let local = collect_local_files(&scope.local_paths, &mut folders, &mut failed).await?;
    paths.extend(scope.local_paths.iter().map(|path| path.display().to_string()));
    let mut sizes = HashMap::<u64, usize>::new();
    for size in candidates.iter().map(|file| file.size).chain(local.iter().map(|(_, identity)| identity.size)) {
        *sizes.entry(size).or_default() += 1;
    }
    for (path, identity) in local {
        // A unique size cannot have a duplicate anywhere in the selected drives.
        // Preserve it in the scan count without reading potentially huge bytes.
        let hashes = if sizes[&identity.size] > 1 {
            let task_path = path.clone(); let before = identity.clone();
            let scanned_files = candidates.len();
            let failed_folders = failed;
            match tokio::task::spawn_blocking(move || {
                hash_local_reporting(&task_path, &before, || {
                    emit_duplicate_progress(progress_json, DuplicateProgressEvent::ScanProgress {
                        scanned_files, scanned_folders: folders, discovered_folders: folders,
                        pending_folders: 0, failed_folders, current_path: &task_path.to_string_lossy(),
                    });
                })
            }).await? {
                Ok(hashes) => Some(hashes),
                Err(error) => { failed += 1; eprintln!("warning: skipped local duplicate candidate {}: {error}", path.display()); continue; }
            }
        } else { None };
        emit_duplicate_progress(progress_json, DuplicateProgressEvent::ScanProgress {
            scanned_files: candidates.len() + 1, scanned_folders: folders, discovered_folders: folders,
            pending_folders: 0, failed_folders: failed, current_path: &path.to_string_lossy(),
        });
        candidates.push(DuplicateCandidate {
            id: format!("local:{}", path.display()), name: path.file_name().unwrap_or_default().to_string_lossy().into(),
            path: path.to_string_lossy().into(), size: identity.size, modified_time: None,
            content_hash: hashes.as_ref().map(|hashes| hashes.0.clone()), md5_checksum: hashes.map(|hashes| hashes.1),
            source: DuplicateSource::Local, folder_created_time: None, local_identity: Some(identity),
        });
    }
    let root_path = if paths.len() == 1 { let path = paths.remove(0); path.strip_prefix("PikPak: ").unwrap_or(&path).to_owned() }
        else { paths.join(" • ") };
    let mut result = build_duplicate_scan(root_path, folders, candidates);
    result.failed_folders = failed;
    Ok(result)
}

async fn collect_local_files(roots: &[PathBuf], folders: &mut usize, failed: &mut usize) -> Result<Vec<(PathBuf, LocalIdentity)>> {
    let roots = roots.to_owned();
    let (files, read_folders, failures) = tokio::task::spawn_blocking(move || -> Result<_> {
        let mut pending = roots.clone(); let mut seen = HashSet::new(); let mut files = Vec::new();
        let (mut read_folders, mut failures) = (0, 0);
        while let Some(path) = pending.pop() {
            if !roots.contains(&path) && path.file_name().is_some_and(|name| name.to_string_lossy().starts_with('.')) { continue; }
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(error) => {
                    if roots.contains(&path) { return Err(error).with_context(|| format!("read selected disk folder {}", path.display())); }
                    failures += 1; continue;
                }
            };
            if metadata.file_type().is_symlink() { continue; }
            let canonical = match std::fs::canonicalize(&path) {
                Ok(path) => path,
                Err(error) if roots.contains(&path) => return Err(error).with_context(|| format!("resolve selected disk folder {}", path.display())),
                Err(_) => { failures += 1; continue; }
            };
            if !seen.insert(canonical.clone()) { continue; }
            if metadata.is_dir() {
                match std::fs::read_dir(&canonical) {
                    Ok(entries) => {
                        read_folders += 1;
                        for entry in entries {
                            match entry { Ok(entry) => pending.push(entry.path()), Err(_) => failures += 1 }
                        }
                    }
                    Err(error) if roots.contains(&path) => return Err(error).with_context(|| format!("read selected disk folder {}", path.display())),
                    Err(_) => failures += 1,
                }
            } else if metadata.is_file() { files.push((canonical, LocalIdentity::of(&metadata))); }
        }
        Ok((files, read_folders, failures))
    }).await??;
    *folders += read_folders; *failed += failures;
    Ok(files)
}

#[cfg(test)]
fn hash_local(path: &StdPath, before: &LocalIdentity) -> Result<(String, String)> {
    hash_local_reporting(path, before, || {})
}

fn hash_local_reporting(path: &StdPath, before: &LocalIdentity, mut progress: impl FnMut()) -> Result<(String, String)> {
    use std::io::Read;
    use md5::{Digest, Md5};
    let mut file = OpenOptions::new().read(true).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32).open(path)?;
    anyhow::ensure!(file.metadata()?.is_file() && LocalIdentity::of(&file.metadata()?) == *before, "file changed before hashing");
    let mut gcid = pikpak::upload::GcidHasher::new(before.size);
    let mut md5 = Md5::new(); let mut read = 0u64; let mut buffer = vec![0u8; 256 * 1024];
    progress();
    let mut last_progress = std::time::Instant::now();
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 { break; }
        gcid.update(&buffer[..count]); md5.update(&buffer[..count]); read += count as u64;
        anyhow::ensure!(read <= before.size, "file grew during hashing");
        if last_progress.elapsed() >= Duration::from_millis(250) {
            progress(); last_progress = std::time::Instant::now();
        }
    }
    let after = std::fs::symlink_metadata(path)?;
    anyhow::ensure!(read == before.size && after.is_file() && !after.file_type().is_symlink()
        && LocalIdentity::of(&after) == *before && LocalIdentity::of(&file.metadata()?) == *before, "file changed during hashing");
    Ok((gcid.finish(), hex::encode(md5.finalize())))
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

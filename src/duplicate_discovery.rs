//! Discover disk candidates without serializing network metadata requests.
use super::*;
use std::collections::VecDeque;
use tokio::sync::mpsc;

const ENTRY_BATCH: usize = 64;

pub(super) struct Inventory {
    pub files: Vec<(PathBuf, LocalIdentity)>,
    pub folders: usize,
    pub failed: usize,
}

enum Job {
    Root(PathBuf),
    Directory { path: PathBuf, selected: bool },
    Entries(Vec<PathBuf>),
}

struct EntryBatch {
    directory: PathBuf,
    paths: Vec<PathBuf>,
}

#[derive(Default)]
struct ReadResult {
    files: Vec<(PathBuf, LocalIdentity)>,
    directories: Vec<(PathBuf, bool)>,
    folders: usize,
    settled_folders: usize,
    inspected: u64,
    failed: usize,
}

#[derive(Clone)]
struct Progress {
    files: usize,
    folders: usize,
    discovered_folders: usize,
    pending_folders: usize,
    failed: usize,
    current_path: PathBuf,
}

pub(super) async fn collect(
    roots: &[PathBuf],
    cloud_files: usize,
    cloud_folders: usize,
    cloud_failed: usize,
    enabled: bool,
) -> Result<Inventory> {
    collect_with(roots, AdmissionMode::Automatic, read_job, |progress| {
        emit_duplicate_progress(
            enabled,
            DuplicateProgressEvent::LocalDiscoveryProgress {
                scanned_files: cloud_files + progress.files,
                scanned_folders: cloud_folders + progress.folders,
                discovered_folders: cloud_folders + progress.discovered_folders,
                pending_folders: progress.pending_folders,
                failed_folders: cloud_failed + progress.failed,
                current_path: &progress.current_path.to_string_lossy(),
            },
        );
    })
    .await
}

async fn collect_with<W, P>(
    roots: &[PathBuf],
    concurrency: impl Into<AdmissionMode>,
    worker: W,
    mut progress: P,
) -> Result<Inventory>
where
    W: Fn(Job, mpsc::Sender<EntryBatch>) -> Result<ReadResult> + Send + Sync + 'static,
    P: FnMut(Progress) + Send,
{
    let mut inventory = Inventory {
        files: Vec::new(),
        folders: 0,
        failed: 0,
    };
    let Some(first) = roots.first() else {
        return Ok(inventory);
    };
    let initial = std::thread::available_parallelism()
        .map(usize::from)
        .unwrap_or(1);
    let mut admission = Admission::new(concurrency.into(), initial, false);
    let (sender, mut receiver) = mpsc::channel(initial.saturating_mul(2).max(1));
    let mut pending: VecDeque<_> = roots.iter().cloned().map(Job::Root).collect();
    let mut running = tokio::task::JoinSet::new();
    let worker = Arc::new(worker);
    let mut seen_files = HashSet::new();
    let mut seen_directories = HashSet::new();
    let mut inspected = 0u64;
    let mut settled_folders = 0usize;
    let mut current_path = first.clone();
    let mut last_report = None;
    let mut ticker = tokio::time::interval(Duration::from_millis(250));

    loop {
        let finished = pending.is_empty() && running.is_empty() && receiver.is_empty();
        let now = Instant::now();
        if finished
            || last_report
                .is_none_or(|last: Instant| now.duration_since(last) >= Duration::from_millis(250))
        {
            progress(Progress {
                files: inventory.files.len(),
                folders: inventory.folders,
                discovered_folders: seen_directories.len(),
                pending_folders: seen_directories.len().saturating_sub(settled_folders),
                failed: inventory.failed,
                current_path: current_path.clone(),
            });
            last_report = Some(now);
        }
        if finished {
            return Ok(inventory);
        }
        let limit = admission.update(
            now,
            inspected,
            running.len(),
            !pending.is_empty() || !receiver.is_empty(),
        );
        while running.len() < limit {
            let Some(job) = pending.pop_front() else {
                break;
            };
            let worker = worker.clone();
            let sender = sender.clone();
            running.spawn_blocking(move || worker(job, sender));
        }
        tokio::select! {
            Some(batch) = receiver.recv(), if !running.is_empty() || !receiver.is_empty() => {
                current_path = batch.directory;
                pending.push_back(Job::Entries(batch.paths));
            }
            Some(result) = running.join_next(), if !running.is_empty() => {
                let result = result.context("local duplicate discovery worker failed")??;
                inventory.folders += result.folders;
                inventory.failed += result.failed;
                settled_folders += result.settled_folders;
                inspected = inspected.saturating_add(result.inspected);
                for (path, selected) in result.directories {
                    if seen_directories.insert(path.clone()) {
                        current_path = path.clone();
                        pending.push_back(Job::Directory { path, selected });
                    }
                }
                for (path, identity) in result.files {
                    if seen_files.insert(path.clone()) { inventory.files.push((path, identity)); }
                }
            }
            _ = ticker.tick() => {}
        }
    }
}

fn read_job(job: Job, sender: mpsc::Sender<EntryBatch>) -> Result<ReadResult> {
    let mut result = ReadResult::default();
    match job {
        Job::Root(path) => {
            let metadata = std::fs::symlink_metadata(&path)
                .with_context(|| format!("read selected disk folder {}", path.display()))?;
            if metadata.file_type().is_symlink() {
                return Ok(result);
            }
            // Only selected roots need full resolution. Descendants already
            // have canonical parents, and entry symlinks are never followed.
            let path = std::fs::canonicalize(&path)
                .with_context(|| format!("resolve selected disk folder {}", path.display()))?;
            result.inspected = 1;
            if metadata.is_dir() {
                result.directories.push((path, true));
            } else if metadata.is_file() {
                result.files.push((path, LocalIdentity::of(&metadata)));
            }
        }
        Job::Entries(paths) => {
            for path in paths {
                result.inspected += 1;
                match std::fs::symlink_metadata(&path) {
                    Ok(metadata) if metadata.file_type().is_symlink() => {}
                    Ok(metadata) if metadata.is_dir() => result.directories.push((path, false)),
                    Ok(metadata) if metadata.is_file() => {
                        result.files.push((path, LocalIdentity::of(&metadata)))
                    }
                    Ok(_) => {}
                    Err(_) => result.failed += 1,
                }
            }
        }
        Job::Directory { path, selected } => {
            result.settled_folders = 1;
            // Recheck directories before opening them, including entries that
            // changed type while their metadata request was queued.
            let entries = std::fs::symlink_metadata(&path).and_then(|metadata| {
                if !metadata.is_dir() || metadata.file_type().is_symlink() {
                    return Err(std::io::Error::other("directory changed during discovery"));
                }
                std::fs::read_dir(&path)
            });
            let entries = match entries {
                Ok(entries) => entries,
                Err(error) if selected => {
                    return Err(error)
                        .with_context(|| format!("read selected disk folder {}", path.display()))
                }
                Err(_) => {
                    result.failed = 1;
                    return Ok(result);
                }
            };
            result.folders = 1;
            let mut paths = Vec::with_capacity(ENTRY_BATCH);
            for entry in entries {
                match entry {
                    Ok(entry) if !entry.file_name().to_string_lossy().starts_with('.') => {
                        paths.push(entry.path())
                    }
                    Ok(_) => {}
                    Err(_) => result.failed += 1,
                }
                if paths.len() == ENTRY_BATCH {
                    sender
                        .blocking_send(EntryBatch {
                            directory: path.clone(),
                            paths,
                        })
                        .context("local duplicate discovery was cancelled")?;
                    paths = Vec::with_capacity(ENTRY_BATCH);
                }
            }
            if !paths.is_empty() {
                sender
                    .blocking_send(EntryBatch {
                        directory: path,
                        paths,
                    })
                    .context("local duplicate discovery was cancelled")?;
            }
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Condvar;

    #[derive(Clone, Default)]
    struct Gate(Arc<(Mutex<bool>, Condvar)>);

    impl Gate {
        fn wait(&self) {
            let (lock, changed) = &*self.0;
            let ready = lock.lock().unwrap();
            let (ready, _) = changed
                .wait_timeout_while(ready, Duration::from_secs(5), |ready| !*ready)
                .unwrap();
            assert!(*ready, "generated metadata request was never released");
        }

        fn release(&self) {
            let (lock, changed) = &*self.0;
            *lock.lock().unwrap() = true;
            changed.notify_all();
        }
    }

    struct Release(Gate);
    impl Drop for Release {
        fn drop(&mut self) {
            self.0.release();
        }
    }

    #[tokio::test]
    async fn discovery_reports_immediately_and_keeps_reporting_during_a_blocked_storage_call() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_owned();
        let gate = Gate::default();
        let _release = Release(gate.clone());
        let blocked = gate.clone();
        let (updates, mut received) = mpsc::unbounded_channel();
        let scan = tokio::spawn(async move {
            collect_with(
                &[root],
                1,
                move |job, sender| {
                    if matches!(job, Job::Root(_)) {
                        blocked.wait();
                    }
                    read_job(job, sender)
                },
                move |progress| {
                    updates.send(progress).unwrap();
                },
            )
            .await
        });
        for _ in 0..2 {
            let progress = tokio::time::timeout(Duration::from_secs(2), received.recv())
                .await
                .unwrap()
                .unwrap();
            assert_eq!(
                (progress.files, progress.folders, progress.failed),
                (0, 0, 0)
            );
            assert!(!progress.current_path.as_os_str().is_empty());
        }
        assert!(
            !scan.is_finished(),
            "progress must arrive before the blocked request returns"
        );
        gate.release();
        let inventory = scan.await.unwrap().unwrap();
        assert_eq!(
            (inventory.files.len(), inventory.folders, inventory.failed),
            (0, 1, 0)
        );
    }

    #[tokio::test]
    async fn metadata_requests_overlap_with_bounded_workers_and_match_serial_discovery() {
        let directory = tempfile::tempdir().unwrap();
        let count = ENTRY_BATCH * 6;
        for index in 0..count {
            std::fs::write(
                directory.path().join(format!("R{index:04}q8")),
                b"generated",
            )
            .unwrap();
        }
        let root = directory.path().to_owned();
        let roots = vec![root.clone()];
        let gate = Gate::default();
        let _release = Release(gate.clone());
        let blocked = gate.clone();
        let active = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let (worker_active, worker_peak) = (active.clone(), peak.clone());
        let (entered, mut started) = mpsc::unbounded_channel();
        let scan = tokio::spawn(async move {
            collect_with(
                &roots,
                3,
                move |job, sender| {
                    if matches!(job, Job::Entries(_)) {
                        let active = worker_active.fetch_add(1, Ordering::SeqCst) + 1;
                        worker_peak.fetch_max(active, Ordering::SeqCst);
                        entered.send(()).unwrap();
                        blocked.wait();
                        let result = read_job(job, sender);
                        worker_active.fetch_sub(1, Ordering::SeqCst);
                        result
                    } else {
                        read_job(job, sender)
                    }
                },
                |_| {},
            )
            .await
        });
        for _ in 0..3 {
            tokio::time::timeout(Duration::from_secs(3), started.recv())
                .await
                .unwrap()
                .unwrap();
        }
        assert_eq!(peak.load(Ordering::SeqCst), 3);
        gate.release();
        let mut parallel = scan.await.unwrap().unwrap();
        let mut serial = collect_with(&[root], 1, read_job, |_| {}).await.unwrap();
        assert_eq!(
            (parallel.files.len(), parallel.folders, parallel.failed),
            (count, 1, 0)
        );
        assert_eq!(active.load(Ordering::SeqCst), 0);
        assert_eq!(peak.load(Ordering::SeqCst), 3);
        parallel.files.sort_by(|left, right| left.0.cmp(&right.0));
        serial.files.sort_by(|left, right| left.0.cmp(&right.0));
        assert_eq!(parallel.files, serial.files);
    }

    #[tokio::test]
    async fn overlapping_roots_hidden_entries_and_symlinks_keep_the_existing_scan_scope() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("N8xQ");
        let nested = root.join("B7vK");
        std::fs::create_dir_all(&nested).unwrap();
        let original = root.join("F9pA");
        std::fs::write(&original, b"generated").unwrap();
        std::fs::write(nested.join("H6sW"), b"generated").unwrap();
        std::fs::write(root.join(".D5rZ"), b"excluded").unwrap();
        let explicitly_selected = root.join(".C4uY");
        std::fs::write(&explicitly_selected, b"selected").unwrap();
        std::fs::hard_link(&original, root.join("J3mT")).unwrap();
        std::os::unix::fs::symlink(&nested, root.join("L2aV")).unwrap();
        let roots = vec![
            root.clone(),
            nested.clone(),
            nested.join(".."),
            explicitly_selected.clone(),
        ];
        let inventory = collect_with(&roots, 4, read_job, |_| {}).await.unwrap();
        assert_eq!(
            (inventory.files.len(), inventory.folders, inventory.failed),
            (4, 2, 0)
        );
        assert!(inventory
            .files
            .iter()
            .all(|(path, _)| path.starts_with(std::fs::canonicalize(&root).unwrap())));
        assert!(inventory
            .files
            .iter()
            .any(|(path, _)| *path == std::fs::canonicalize(explicitly_selected.clone()).unwrap()));
        assert!(!inventory
            .files
            .iter()
            .any(|(path, _)| path.file_name().unwrap() == ".D5rZ"));
        let identities: Vec<_> = inventory
            .files
            .iter()
            .map(|(_, identity)| (identity.device, identity.inode))
            .collect();
        assert_eq!(
            identities
                .iter()
                .filter(|identity| **identity
                    == (
                        LocalIdentity::of(&std::fs::metadata(&original).unwrap()).device,
                        LocalIdentity::of(&std::fs::metadata(&original).unwrap()).inode
                    ))
                .count(),
            2,
            "separate hard links remain separate copies"
        );
    }

    #[tokio::test]
    async fn missing_selected_roots_abort_and_removed_children_leave_a_partial_inventory() {
        let directory = tempfile::tempdir().unwrap();
        assert!(
            collect_with(&[directory.path().join("Q1tU")], 2, read_job, |_| {})
                .await
                .is_err()
        );
        std::fs::write(directory.path().join("W2eR"), b"generated").unwrap();
        let inventory = collect_with(
            &[directory.path().to_owned()],
            2,
            |job, sender| {
                if let Job::Entries(paths) = &job {
                    for path in paths {
                        std::fs::remove_file(path).unwrap();
                    }
                }
                read_job(job, sender)
            },
            |_| {},
        )
        .await
        .unwrap();
        assert_eq!(
            (inventory.files.len(), inventory.folders, inventory.failed),
            (0, 1, 1)
        );
    }

    #[test]
    fn a_directory_replaced_by_a_symlink_is_not_traversed() {
        let directory = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let link = directory.path().join("E3cN");
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();
        let (sender, mut receiver) = mpsc::channel(1);
        let result = read_job(
            Job::Directory {
                path: link,
                selected: false,
            },
            sender,
        )
        .unwrap();
        assert_eq!(
            (result.folders, result.settled_folders, result.failed),
            (0, 1, 1)
        );
        assert!(receiver.try_recv().is_err());
    }
}

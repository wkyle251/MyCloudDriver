//! Per-process private controls. Polling keeps cancellation responsive even when
//! a peer stops sending bytes; paused futures are retained without being polled.
use std::{collections::HashMap, future::Future, path::{Path, PathBuf}, sync::{Mutex, OnceLock}, time::{Duration, Instant}};
use serde::Deserialize;
use std::sync::{atomic::{AtomicU64, Ordering}, Arc};
use pikpak::download_connections::Connections;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Action { Pause, Cancel }
#[derive(Default, Deserialize)]
struct Document { #[serde(default)] actions: HashMap<String, Action> }
struct Cache { read_at: Instant, document: Document }
static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();

#[derive(Debug)]
pub struct Cancelled;
impl std::fmt::Display for Cancelled { fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "Transfer cancelled by user") } }
impl std::error::Error for Cancelled {}

pub fn enabled() -> bool { std::env::var_os("MYCLOUDDRIVER_TRANSFER_CONTROL").is_some() }
static SCOPES: OnceLock<Mutex<HashMap<String, Vec<String>>>> = OnceLock::new();
/// Live queue IDs isolate the same cloud file in different selections. Group
/// and path controls also apply before a folder has finished discovering files.
pub fn set_scope(id: &str, keys: Vec<String>) {
    SCOPES.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner()).insert(id.into(), keys);
}
pub fn remove_scope(id: &str) {
    if let Some(scopes) = SCOPES.get() { scopes.lock().unwrap_or_else(|e| e.into_inner()).remove(id); }
}
pub fn action(id: &str) -> Option<Action> {
    let scopes = SCOPES.get().and_then(|scopes| scopes.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()).unwrap_or_default();
    std::iter::once(id).chain(scopes.iter().map(String::as_str)).filter_map(read_action).fold(None, |previous, next| {
        if previous == Some(Action::Cancel) || next == Action::Cancel { Some(Action::Cancel) } else { Some(next) }
    })
}
fn read_action(id: &str) -> Option<Action> {
    let path = PathBuf::from(std::env::var_os("MYCLOUDDRIVER_TRANSFER_CONTROL")?);
    let cache = CACHE.get_or_init(|| Mutex::new(Cache { read_at: Instant::now() - Duration::from_secs(1), document: Document::default() }));
    let mut cache = cache.lock().unwrap_or_else(|error| error.into_inner());
    if cache.read_at.elapsed() >= Duration::from_millis(100) {
        cache.read_at = Instant::now();
        if let Ok(data) = std::fs::read(&path) {
            if data.len() <= 16 * 1024 * 1024 {
                if let Ok(document) = serde_json::from_slice::<Document>(&data) { cache.document = document; }
            }
        }
    }
    let scoped = if id.starts_with("path:") {
        cache.document.actions.iter().filter(|(key, _)| key.starts_with("path:") && (id == key.as_str() || id.starts_with(&(key.to_string() + "/"))))
            .map(|(_, action)| *action).fold(None, |previous, next| {
                if previous == Some(Action::Cancel) || next == Action::Cancel { Some(Action::Cancel) } else { Some(next) }
            })
    } else { cache.document.actions.get(id).copied() };
    match (cache.document.actions.get("*"), scoped.as_ref()) {
        (Some(Action::Cancel), _) | (_, Some(Action::Cancel)) => Some(Action::Cancel),
        (Some(Action::Pause), _) | (_, Some(Action::Pause)) => Some(Action::Pause),
        _ => None,
    }
}
pub async fn run<T>(id: &str, future: impl Future<Output = T>) -> Result<T, Cancelled> {
    run_controlled(|| action(id), future).await
}

async fn run_controlled<T>(read_action: impl Fn() -> Option<Action>, future: impl Future<Output = T>) -> Result<T, Cancelled> {
    tokio::pin!(future);
    loop {
        match read_action() {
            Some(Action::Cancel) => return Err(Cancelled),
            Some(Action::Pause) => tokio::time::sleep(Duration::from_millis(100)).await,
            None => tokio::select! {
                biased;
                _ = tokio::time::sleep(Duration::from_millis(100)) => {},
                value = &mut future => return Ok(value),
            },
        }
    }
}

/// Only the known partial sibling is eligible. Reject links and directories;
/// completed files never enter this function. Called after pending writes flush.
pub async fn remove_partial(path: &Path) -> anyhow::Result<()> {
    match tokio::fs::symlink_metadata(path).await {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => { tokio::fs::remove_file(path).await?; }
        Ok(_) => anyhow::bail!("Refusing to remove a non-regular partial file"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
        Err(error) => return Err(error.into()),
    }
    crate::download_transport::remove_state(path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn one_expired_download_does_not_reduce_healthy_capacity() {
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let healthy = Arc::new(tokio::sync::Barrier::new(4));
        let transfer = schedule(
            (0..5).collect(), Concurrency::download(4, Arc::new(AtomicU64::new(0))),
            |id| {
                let attempts = attempts.clone(); let healthy = healthy.clone();
                async move {
                    if id == 0 {
                        if attempts.fetch_add(1, Ordering::SeqCst) == 0 {
                            return Err(anyhow::Error::new(pikpak::download_policy::HttpFailure {
                                status: 403, retry_after: None,
                            }).context(Retry("Refresh the synthetic expired link".into())));
                        }
                    } else { healthy.wait().await; }
                    Ok(())
                }
            },
            |id| format!("speed-retry-{id}"), |_, result| { result.unwrap(); }, |_, _, _| {},
        );
        tokio::time::timeout(Duration::from_secs(4), transfer).await
            .expect("A single failed file throttled four healthy downloads").unwrap();
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn output_ownership_and_queued_pause_are_isolated_in_a_child_process() {
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "transfer_control::tests::ownership_and_fairness_child", "--ignored", "--nocapture"])
            .output().unwrap();
        assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stdout).to_string() + &String::from_utf8_lossy(&result.stderr));
    }
    #[tokio::test]
    #[ignore = "launched in an isolated process because it configures helper environment"]
    async fn ownership_and_fairness_child() {
        let root = tempfile::tempdir().unwrap();
        let locks = root.path().join("locks");
        let control = root.path().join("control.json");
        std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_LOCKS", &locks);
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "window-a-account-x");
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
        let output = root.path().join("film.mp4");
        let partial = root.path().join("film.mp4.part");
        let lease = output_lock(&output, "cloud-file").await.unwrap();
        assert!(same_output(&output, &root.path().join("FILM.MP4")).unwrap());
        assert!(!same_output(&output, &root.path().join("another.mp4")).unwrap());
        claim_partial(&partial, "cloud-file").unwrap();
        std::fs::write(&partial, b"owned partial").unwrap();
        // An active writer blocks a cancelled waiter, who must never unlink.
        std::fs::write(&control, br#"{"actions":{"other-file":"cancel"}}"#).unwrap();
        tokio::time::sleep(Duration::from_millis(110)).await;
        assert!(output_lock(&output, "other-file").await.unwrap_err().is::<Cancelled>());
        assert!(partial.exists());
        drop(lease);
        // Even with no active writer, a second session cannot claim or delete it.
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "window-b-account-x");
        let lease = output_lock(&output, "cloud-file").await.unwrap();
        assert!(claim_partial(&partial, "cloud-file").is_err());
        remove_owned_partial(&partial, "cloud-file").await.unwrap();
        assert_eq!(std::fs::read(&partial).unwrap(), b"owned partial");
        drop(lease);
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "window-a-account-x");
        let lease = output_lock(&output, "cloud-file").await.unwrap();
        remove_owned_partial(&partial, "cloud-file").await.unwrap();
        assert!(!partial.exists()); drop(lease);
        // Consolidating windows admits only explicitly imported owners, with
        // the same cloud file ID, and rewrites ownership under the output lock.
        let lease = output_lock(&output, "cloud-file").await.unwrap();
        claim_partial(&partial, "cloud-file").unwrap();
        std::fs::write(&partial, b"imported progress").unwrap();
        drop(lease);
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "shared-account-x");
        std::env::set_var("MYCLOUDDRIVER_IMPORTED_TRANSFER_OWNERS", "window-a-account-x");
        let lease = output_lock(&output, "cloud-file").await.unwrap();
        assert!(claim_partial(&partial, "wrong-file").is_err());
        claim_partial(&partial, "cloud-file").unwrap();
        std::env::remove_var("MYCLOUDDRIVER_IMPORTED_TRANSFER_OWNERS");
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "shared-account-y");
        assert!(claim_partial(&partial, "cloud-file").is_err());
        remove_owned_partial(&partial, "cloud-file").await.unwrap();
        assert_eq!(std::fs::read(&partial).unwrap(), b"imported progress");
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "shared-account-x");
        remove_owned_partial(&partial, "cloud-file").await.unwrap();
        assert!(!partial.exists()); drop(lease);
        // A paused queue entry leaves the sole worker free for healthy work.
        std::fs::write(&control, br#"{"actions":{"paused":"pause"}}"#).unwrap();
        tokio::time::sleep(Duration::from_millis(110)).await;
        let resume = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(350)).await;
            std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        });
        let mut order = Vec::new();
        schedule(vec!["paused", "healthy"], Concurrency::download(1, Arc::new(AtomicU64::new(0))), |value| async move { Ok(value) },
            |value| value.to_string(), |value, _| order.push(value), |_, _, _| {}).await.unwrap();
        resume.await.unwrap();
        assert_eq!(order, vec!["healthy", "paused"]);
    }
    #[tokio::test]
    async fn failed_file_waits_in_queue_and_does_not_starve_healthy_file() {
        use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
        // Both fixed upload slots and adaptive download slots must release
        // failed attempts so healthy work can proceed during retry delays.
        for policy in [Concurrency::from(1), Concurrency::download(1, Arc::new(AtomicU64::new(0)))] {
            let attempts = Arc::new(AtomicUsize::new(0));
            let mut order = Vec::new();
            let mut retries = 0;
            schedule(vec![0usize, 1], policy, |value| {
                let attempts = attempts.clone();
                async move {
                    if value == 0 && attempts.fetch_add(1, Ordering::SeqCst) == 0 { return Err(Retry("temporary failure".into()).into()); }
                    Ok(())
                }
            }, |value| value.to_string(), |value, result| { result.unwrap(); order.push(value); },
                |_, attempt, delay| { retries += 1; assert_eq!(attempt, 1); assert_eq!(delay.as_secs(), 1); }).await.unwrap();
            assert_eq!(order, vec![1, 0]); assert_eq!(retries, 1);
        }
    }

    #[tokio::test]
    async fn pause_retains_work_and_cancel_drops_it_without_blocking_other_work() {
        use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
        let state = Arc::new(AtomicUsize::new(1));
        let reader = state.clone();
        let first = tokio::spawn(async move {
            run_controlled(|| match reader.load(Ordering::SeqCst) { 1 => Some(Action::Pause), 2 => Some(Action::Cancel), _ => None }, std::future::ready(42)).await
        });
        tokio::time::sleep(Duration::from_millis(130)).await;
        assert!(!first.is_finished(), "paused ready work must not execute");
        assert_eq!(run_controlled(|| None, std::future::ready(7)).await.unwrap(), 7);
        state.store(0, Ordering::SeqCst);
        assert_eq!(first.await.unwrap().unwrap(), 42);
        let state = Arc::new(AtomicUsize::new(0));
        let reader = state.clone();
        let waiting = tokio::spawn(async move {
            run_controlled(|| if reader.load(Ordering::SeqCst) == 2 { Some(Action::Cancel) } else { None }, std::future::pending::<()>()).await
        });
        state.store(2, Ordering::SeqCst);
        assert!(tokio::time::timeout(Duration::from_secs(1), waiting).await.unwrap().unwrap().is_err());
    }

    #[tokio::test]
    async fn partial_cleanup_never_removes_completed_file_or_symlink_target() {
        let dir = tempfile::tempdir().unwrap();
        let completed = dir.path().join("movie.mp4");
        let partial = dir.path().join("movie.mp4.part");
        std::fs::write(&completed, b"complete").unwrap();
        std::fs::write(&partial, b"partial").unwrap();
        remove_partial(&partial).await.unwrap();
        assert_eq!(std::fs::read(&completed).unwrap(), b"complete");
        std::os::unix::fs::symlink(&completed, &partial).unwrap();
        assert!(remove_partial(&partial).await.is_err());
        assert_eq!(std::fs::read(&completed).unwrap(), b"complete");
    }
}

/// All app sessions share this advisory lock namespace. A cancelled waiter
/// never owns (and therefore never removes) another session's partial file.
pub async fn output_lock(output: &Path, id: &str) -> anyhow::Result<Option<std::fs::File>> {
    use rustix::fs::{flock, openat, FlockOperation, Mode, OFlags, CWD};
    let Some(directory) = std::env::var_os("MYCLOUDDRIVER_TRANSFER_LOCKS").map(PathBuf::from) else { return Ok(None); };
    std::fs::create_dir_all(&directory)?;
    let parent = output.parent().unwrap_or(Path::new(".")).canonicalize()?;
    let normalized = parent.join(output.file_name().unwrap_or_default()).to_string_lossy().to_lowercase();
    let key = hex::encode(ring::digest::digest(&ring::digest::SHA256, normalized.as_bytes()).as_ref());
    let descriptor = openat(CWD, directory.join(key), OFlags::CREATE | OFlags::RDWR | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::RUSR | Mode::WUSR)?;
    let file = std::fs::File::from(descriptor);
    loop {
        match flock(&file, FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => return Ok(Some(file)),
            Err(error) if error == rustix::io::Errno::WOULDBLOCK => {
                if action(id) == Some(Action::Cancel) { return Err(Cancelled.into()); }
                if action(id) == Some(Action::Pause) { return Err(Paused.into()); }
                return Err(Retry("Destination is being written by another window".into()).into());
            }
            Err(error) => return Err(error.into()),
        }
    }
}

#[derive(Debug)]
pub struct Paused;
impl std::fmt::Display for Paused { fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "Transfer paused by user") } }
impl std::error::Error for Paused {}
#[derive(Debug)]
pub struct Retry(pub String);
impl std::fmt::Display for Retry { fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{}", self.0) } }
impl std::error::Error for Retry {}

/// A transfer attempt releases its worker on pause. Call only at boundaries
/// where dropping the future cannot leave a local write unfinished.
pub async fn interruptible<T>(id: &str, future: impl Future<Output = T>) -> anyhow::Result<T> {
    tokio::pin!(future);
    loop {
        match action(id) {
            Some(Action::Cancel) => return Err(Cancelled.into()),
            Some(Action::Pause) => return Err(Paused.into()),
            None => tokio::select! {
                biased;
                _ = tokio::time::sleep(Duration::from_millis(100)) => {},
                value = &mut future => return Ok(value),
            },
        }
    }
}

/// Downloads probe the useful file count up to the configured maximum.
/// Other transfers retain their fixed allocation.
pub struct Concurrency {
    maximum: usize,
    throughput: Option<(Connections, Arc<AtomicU64>)>,
}

impl From<usize> for Concurrency {
    fn from(maximum: usize) -> Self { Self { maximum: maximum.max(1), throughput: None } }
}

impl Concurrency {
    /// File and range trials compare the same process-wide original-body bytes.
    /// The caller separately retains its queue's UI progress counter.
    pub fn download(maximum: usize, _received: Arc<AtomicU64>) -> Self {
        let network = pikpak::download_network::Network::shared();
        Self { maximum: maximum.max(1), throughput: Some((
            Connections::new(maximum, Instant::now())
                .with_absolute_gain().with_coordinator(network.trials()),
            network.received_counter())) }
    }

    /// Uploads and downloads use separate counters and admission pools.
    pub fn adaptive(maximum: usize, transferred: Arc<AtomicU64>) -> Self {
        Self { maximum: maximum.max(1), throughput: Some((Connections::new(maximum, Instant::now()), transferred)) }
    }

    fn back_off(&mut self, until: Instant) {
        if let Some((connections, _)) = &mut self.throughput { connections.back_off(until); }
    }

    fn limit(&mut self, active: usize, has_demand: bool) -> usize {
        let Some((connections, received)) = &mut self.throughput else { return self.maximum; };
        connections.active = active;
        if has_demand {
            connections.observe(Instant::now(), received.load(Ordering::Relaxed), || true);
        } else {
            connections.idle(Instant::now());
        }
        connections.limit
    }
}

/// Only active attempts have Tokio tasks. Retry delays and paused files live
/// in the plain queue, so even a large failed batch cannot starve healthy files.
pub async fn schedule<T, R, Run, Fut, ID, Settled, Retrying>(
    items: Vec<T>, workers: impl Into<Concurrency>, run: Run, id: ID,
    settled: Settled, retrying: Retrying,
) -> anyhow::Result<()>
where
    T: Clone + Send + 'static, R: Send + 'static,
    Run: FnMut(T) -> Fut, Fut: Future<Output = anyhow::Result<R>> + Send + 'static,
    ID: Fn(&T) -> String, Settled: FnMut(T, anyhow::Result<R>),
    Retrying: FnMut(&T, u32, Duration),
{
    let (sender, receiver) = tokio::sync::mpsc::unbounded_channel();
    for item in items { sender.send(item).map_err(|_| anyhow::anyhow!("Download queue closed"))?; }
    drop(sender);
    schedule_stream(receiver, workers, run, id, settled, retrying).await
}

pub async fn schedule_stream<T, R, Run, Fut, ID, Settled, Retrying>(
    mut incoming: tokio::sync::mpsc::UnboundedReceiver<T>, workers: impl Into<Concurrency>, mut run: Run, id: ID,
    mut settled: Settled, mut retrying: Retrying,
) -> anyhow::Result<()>
where
    T: Clone + Send + 'static, R: Send + 'static,
    Run: FnMut(T) -> Fut, Fut: Future<Output = anyhow::Result<R>> + Send + 'static,
    ID: Fn(&T) -> String, Settled: FnMut(T, anyhow::Result<R>),
    Retrying: FnMut(&T, u32, Duration),
{
    use std::collections::VecDeque;
    struct Entry<T> { item: T, attempt: u32, ready: Instant }
    let mut pending = VecDeque::<Entry<T>>::new();
    let mut closed = false;
    let mut running = tokio::task::JoinSet::new();
    let mut concurrency = workers.into();
    while !closed || !pending.is_empty() || !running.is_empty() {
        // A bounded drain prevents a busy producer from starving active bodies.
        for _ in 0..256 {
            match incoming.try_recv() {
                Ok(item) => pending.push_back(Entry { item, attempt: 0, ready: Instant::now() }),
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => { closed = true; break; }
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
            }
        }
        let has_demand = pending.iter().any(|entry| action(&id(&entry.item)).is_none() && entry.ready <= Instant::now());
        // Recheck while bodies are still in flight, not just on completion.
        // A reduced allowance drains naturally; no active task is aborted.
        let limit = concurrency.limit(running.len(), has_demand);
        while running.len() < limit {
            let next = pending.iter().position(|entry| {
                let action = action(&id(&entry.item));
                action == Some(Action::Cancel) || (action != Some(Action::Pause) && entry.ready <= Instant::now())
            });
            let Some(index) = next else { break; };
            let entry = pending.remove(index).unwrap();
            let future = run(entry.item.clone());
            running.spawn(async move { (entry, future.await) });
        }
        if closed && pending.is_empty() && running.is_empty() { break; }
        tokio::select! {
            item = incoming.recv(), if !closed => {
                match item {
                    Some(item) => pending.push_back(Entry { item, attempt: 0, ready: Instant::now() }),
                    None => closed = true,
                }
            }
            joined = running.join_next(), if !running.is_empty() => {
                let (mut entry, result) = joined.unwrap()?;
                match result {
                    Err(error) if error.is::<Paused>() => { entry.ready = Instant::now(); pending.push_back(entry); }
                    Err(error) if error.is::<Retry>() => {
                        entry.attempt = entry.attempt.saturating_add(1);
                        let delay = Duration::from_secs((1u64 << entry.attempt.saturating_sub(1).min(6)).min(60))
                            .max(pikpak::download_policy::delay(&error).unwrap_or_default());
                        retrying(&entry.item, entry.attempt, delay);
                        entry.ready = Instant::now() + delay;
                        if pikpak::download_policy::reduce_concurrency(&error) {
                            concurrency.back_off(entry.ready);
                        }
                        pending.push_back(entry);
                    }
                    result => settled(entry.item, result),
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {},
        }
    }
    Ok(())
}

#[derive(serde::Serialize, Deserialize)]
struct PartialOwner { owner: String, file_id: String, #[serde(default)] output_path: Option<String> }

fn matches_owner(previous: &PartialOwner, owner: &str, id: &str) -> bool {
    previous.file_id == id && (previous.owner == owner || std::env::var("MYCLOUDDRIVER_IMPORTED_TRANSFER_OWNERS")
        .is_ok_and(|owners| owners.split(',').any(|candidate| !candidate.is_empty() && candidate == previous.owner)))
}
fn lock_path(output: &Path) -> anyhow::Result<Option<PathBuf>> {
    let Some(directory) = std::env::var_os("MYCLOUDDRIVER_TRANSFER_LOCKS").map(PathBuf::from) else { return Ok(None); };
    let parent = output.parent().unwrap_or(Path::new(".")).canonicalize()?;
    let normalized = parent.join(output.file_name().unwrap_or_default()).to_string_lossy().to_lowercase();
    let key = hex::encode(ring::digest::digest(&ring::digest::SHA256, normalized.as_bytes()).as_ref());
    Ok(Some(directory.join(key)))
}
/// Server URL filenames may differ only in case from metadata. They share one
/// macOS destination lease; acquiring it twice would block the same transfer.
pub fn same_output(first: &Path, second: &Path) -> anyhow::Result<bool> {
    match (lock_path(first)?, lock_path(second)?) {
        (Some(first), Some(second)) => Ok(first == second),
        _ => Ok(first == second),
    }
}

fn partial_output(partial: &Path) -> anyhow::Result<PathBuf> {
    let filename = partial.file_name().and_then(|value| value.to_str()).and_then(|value| value.strip_suffix(".part"))
        .ok_or_else(|| anyhow::anyhow!("Invalid partial filename"))?;
    Ok(partial.with_file_name(filename))
}
/// Called under this output's exclusive lease, before opening a partial writer.
/// The stable window/account owner keeps a queued cancellation from deleting a
/// different paused window's file, even when nobody currently holds the lock.
pub fn claim_partial(partial: &Path, id: &str) -> anyhow::Result<()> {
    use std::io::{Seek, Write};
    let Some(owner) = std::env::var("MYCLOUDDRIVER_TRANSFER_OWNER").ok() else { return Ok(()); };
    let Some(path) = lock_path(&partial_output(partial)?)? else { return Ok(()); };
    let previous = std::fs::read(&path).ok().and_then(|bytes| serde_json::from_slice::<PartialOwner>(&bytes).ok());
    if partial.exists() || crate::download_transport::has_parts(partial) {
        match previous {
            Some(previous) if matches_owner(&previous, &owner, id) => {},
            None if std::env::var_os("MYCLOUDDRIVER_CLAIM_LEGACY_PARTS").is_some() => {},
            _ => anyhow::bail!("This partial download belongs to another transfer. Waiting for its owner to finish or cancel."),
        }
    }
    let descriptor = rustix::fs::openat(rustix::fs::CWD, &path,
        rustix::fs::OFlags::RDWR | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC, rustix::fs::Mode::empty())?;
    let mut file = std::fs::File::from(descriptor);
    file.set_len(0)?; file.rewind()?;
    let output = partial_output(partial)?;
    let output = output.parent().unwrap_or(Path::new(".")).canonicalize()?.join(output.file_name().unwrap_or_default());
    file.write_all(&serde_json::to_vec(&PartialOwner { owner, file_id: id.to_string(), output_path: Some(output.to_string_lossy().into_owned()) })?)?;
    file.sync_data()?;
    Ok(())
}
pub async fn remove_owned_partial(partial: &Path, id: &str) -> anyhow::Result<()> {
    if let Ok(owner) = std::env::var("MYCLOUDDRIVER_TRANSFER_OWNER") {
        let Some(path) = lock_path(&partial_output(partial)?)? else { return Ok(()); };
        let previous = std::fs::read(path).ok().and_then(|bytes| serde_json::from_slice::<PartialOwner>(&bytes).ok());
        if !previous.is_some_and(|previous| matches_owner(&previous, &owner, id)) { return Ok(()); }
    }
    remove_partial(partial).await
}

static COUNTERS: OnceLock<Mutex<HashMap<String, Arc<AtomicU64>>>> = OnceLock::new();
pub fn forget_network_counter(id: &str) {
    if let Some(counters) = COUNTERS.get() { counters.lock().unwrap_or_else(|e| e.into_inner()).remove(id); }
}
pub fn network_counter(id: &str) -> Arc<AtomicU64> {
    let mut counters = COUNTERS.get_or_init(|| Mutex::new(HashMap::new())).lock().unwrap_or_else(|error| error.into_inner());
    counters.entry(id.to_string()).or_default().clone()
}

//! Per-process private controls. Polling keeps cancellation responsive even when
//! a peer stops sending bytes; paused futures are retained without being polled.
use pikpak::download_connections::Connections;
use serde::Deserialize;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use unicode_normalization::UnicodeNormalization;

fn normalized_output_key(output: &Path) -> anyhow::Result<String> {
    let parent = output.parent().unwrap_or(Path::new(".")).canonicalize()?;
    Ok(parent
        .join(output.file_name().unwrap_or_default())
        .to_string_lossy()
        .nfd()
        .collect::<String>()
        .to_lowercase()
        .nfd()
        .collect())
}

#[cfg(any(not(test), target_os = "macos"))]
fn default_output_lock_directory(home: Option<PathBuf>) -> PathBuf {
    #[cfg(target_os = "macos")]
    if let Some(home) = home {
        return home.join("Library/Application Support/My PikPak for Mac/TransferLocks");
    }
    #[cfg(not(target_os = "macos"))]
    let _ = home;
    std::env::temp_dir().join(format!(
        "myclouddriver-transfer-locks-{}",
        rustix::process::getuid().as_raw()
    ))
}

pub(crate) fn output_lock_directory() -> PathBuf {
    if let Some(directory) = std::env::var_os("MYCLOUDDRIVER_TRANSFER_LOCKS") {
        return directory.into();
    }
    #[cfg(not(test))]
    {
        default_output_lock_directory(std::env::var_os("HOME").map(PathBuf::from))
    }
    #[cfg(test)]
    {
        // Unit tests never access the user's real app support/transfer cache.
        static TEST_LOCKS: OnceLock<tempfile::TempDir> = OnceLock::new();
        TEST_LOCKS
            .get_or_init(|| {
                tempfile::Builder::new()
                    .prefix("pikpak-synthetic-locks-")
                    .tempdir()
                    .unwrap()
            })
            .path()
            .to_owned()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Pause,
    Cancel,
}
#[derive(Default, Deserialize, PartialEq, Eq)]
struct Document {
    #[serde(default)]
    actions: HashMap<String, Action>,
    #[serde(default)]
    drain: bool,
    #[serde(default)]
    receive_only_pause: bool,
}
struct Cache {
    read_at: Instant,
    document: Document,
}
static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
pub(crate) fn changes() -> &'static tokio::sync::Notify {
    static CHANGED: OnceLock<tokio::sync::Notify> = OnceLock::new();
    CHANGED.get_or_init(tokio::sync::Notify::new)
}

/// Normal Quit stops admission/reception, but lets existing RAM consumers
/// finish their writes and synced checkpoints. The marker is helper-private.
pub(crate) fn draining() -> bool {
    let _ = read_action("*");
    CACHE.get().is_some_and(|cache| cache.lock().unwrap_or_else(|e| e.into_inner()).document.drain)
}

/// Download Pause stops HTTP reception, while disk consumers/checks continue.
/// Legacy controls (including uploads) keep their original Pause semantics.
fn receive_only_pause() -> bool {
    let _ = read_action("*");
    CACHE.get().is_some_and(|cache| cache.lock().unwrap_or_else(|e| e.into_inner()).document.receive_only_pause)
}

pub(crate) fn pause_receiving(id: &str) -> bool {
    draining() || (receive_only_pause() && action(id) == Some(Action::Pause))
}

pub(crate) fn disk_action(id: &str) -> Option<Action> {
    match action(id) {
        Some(Action::Pause) if receive_only_pause() && (!draining() || crate::download_buffer::prefetching(id)) => None,
        action => action,
    }
}

#[derive(Debug)]
pub struct Cancelled;
impl std::fmt::Display for Cancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Transfer cancelled by user")
    }
}
impl std::error::Error for Cancelled {}

pub fn enabled() -> bool {
    std::env::var_os("MYCLOUDDRIVER_TRANSFER_CONTROL").is_some()
}
static SCOPES: OnceLock<Mutex<HashMap<String, Vec<String>>>> = OnceLock::new();
static RETIRED_SCOPES: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
static RETRY_ORIGINS: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();

#[cfg(test)]
#[path = "transfer_retry_tests.rs"]
mod retry_tests;

fn is_uuid_root(root: &str) -> bool {
    root.len() == 36
        && root.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn canonical_root(root: &str) -> String {
    if is_uuid_root(root) {
        root.to_ascii_uppercase()
    } else {
        root.to_owned()
    }
}

fn ownership_aliases(id: &str) -> [String; 3] {
    let (root, suffix) = if let Some(root) = id.strip_prefix("root:") {
        (root, None)
    } else {
        id.split_once(':')
            .map_or((id, None), |(root, suffix)| (root, Some(suffix)))
    };
    let canonical = canonical_root(root);
    let lowercase = if is_uuid_root(&canonical) {
        canonical.to_ascii_lowercase()
    } else {
        canonical.clone()
    };
    let join = |root: String| {
        if id.starts_with("root:") {
            format!("root:{root}")
        } else if let Some(suffix) = suffix {
            format!("{root}:{suffix}")
        } else {
            root
        }
    };
    [id.to_owned(), join(canonical), join(lowercase)]
}

fn ownership_action(id: &str) -> Option<Action> {
    ownership_aliases(id)
        .iter()
        .filter_map(|id| action(id))
        .fold(None, |previous, next| {
            if previous == Some(Action::Cancel) || next == Action::Cancel {
                Some(Action::Cancel)
            } else {
                Some(next)
            }
        })
}

/// The private native inbox carries the persisted retry ancestry. Replacing
/// the graph on each poll avoids retaining relationships from removed roots.
pub fn set_retry_origins(origins: &HashMap<String, String>) -> anyhow::Result<()> {
    let mut validated = HashMap::with_capacity(origins.len());
    for (root, previous) in origins {
        for id in [root, previous] {
            anyhow::ensure!(
                !id.is_empty()
                    && id.len() <= 64
                    && id
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'),
                "Invalid download retry ancestry identity"
            );
        }
        let root = canonical_root(root);
        let previous = canonical_root(previous);
        if let Some(existing) = validated.insert(root, previous.clone()) {
            anyhow::ensure!(existing == previous, "Conflicting download retry ancestry");
        }
    }
    *RETRY_ORIGINS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|error| error.into_inner()) = validated;
    Ok(())
}

fn retry_ancestry(root: &str) -> Option<Vec<String>> {
    let origins = RETRY_ORIGINS
        .get()?
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let mut ancestry = Vec::new();
    let mut visited = HashSet::new();
    let mut current = canonical_root(root);
    loop {
        // Reject an unreasonable imported chain rather than spending an
        // unbounded amount of work deciding whether it can release ownership.
        if ancestry.len() >= 8_192 {
            return None;
        }
        if !visited.insert(current.clone()) {
            return None;
        }
        ancestry.push(current.clone());
        match origins.get(&current) {
            Some(previous) => current = previous.clone(),
            None => return Some(ancestry),
        }
    }
}

fn retry_can_adopt(previous_id: &str, previous_root: Option<&str>, root_id: Option<&str>) -> bool {
    let (Some(previous_root), Some(root)) = (previous_root, root_id) else {
        return false;
    };
    let Some(ancestry) = retry_ancestry(root) else {
        return false;
    };
    if !ancestry.contains(&canonical_root(previous_root)) {
        return false;
    }
    // A known retry may bypass only the restored folder reservation, never
    // its actual queued or active file body. UUID casing can change on import.
    let body_aliases = ownership_aliases(previous_id);
    if SCOPES.get().is_some_and(|scopes| {
        let scopes = scopes.lock().unwrap_or_else(|error| error.into_inner());
        body_aliases.iter().any(|id| scopes.contains_key(id))
    }) {
        return false;
    }
    ownership_action(previous_id).is_none()
        && ancestry
            .iter()
            .all(|root| ownership_action(&format!("root:{root}")).is_none())
}
struct OutputReference {
    target: String,
    tree: bool,
}
static OUTPUT_REFERENCES: OnceLock<Mutex<HashMap<String, OutputReference>>> = OnceLock::new();

fn reference_key(path: &Path) -> anyhow::Result<String> {
    // New descendants or an unavailable mount can lack a canonical path.
    // Resolve its nearest existing ancestor without creating anything.
    let mut ancestor = path;
    let mut tail = Vec::new();
    let base = loop {
        match ancestor.canonicalize() {
            Ok(base) => break base,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                tail.push(ancestor.file_name().ok_or(error)?);
                ancestor = ancestor
                    .parent()
                    .ok_or_else(|| anyhow::anyhow!("Invalid download output reference"))?;
            }
            Err(error) => return Err(error.into()),
        }
    };
    let path = tail
        .into_iter()
        .rev()
        .fold(base, |path, name| path.join(name));
    Ok(path
        .to_string_lossy()
        .nfd()
        .collect::<String>()
        .to_lowercase()
        .nfd()
        .collect())
}

pub fn set_output_reference(root: &str, target: &Path, tree: bool) -> anyhow::Result<()> {
    let target = reference_key(target)?;
    OUTPUT_REFERENCES
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .insert(root.into(), OutputReference { target, tree });
    Ok(())
}

pub fn remove_output_reference(root: &str) {
    if let Some(references) = OUTPUT_REFERENCES.get() {
        references
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(root);
    }
}

fn output_references(output: &Path) -> anyhow::Result<Vec<String>> {
    let key = reference_key(output)?;
    Ok(OUTPUT_REFERENCES
        .get()
        .map(|references| {
            references
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .iter()
                .filter(|(_, reference)| {
                    reference.target == key
                        || reference.tree
                            && key.starts_with(
                                &(reference.target.trim_end_matches('/').to_owned() + "/"),
                            )
                })
                .map(|(root, _)| root.clone())
                .collect()
        })
        .unwrap_or_default())
}

fn legacy_claim_is_reserved(output: &Path, root: Option<&str>) -> anyhow::Result<bool> {
    let mut references = output_references(output)?
        .into_iter()
        .filter(|candidate| action(&format!("root:{candidate}")) != Some(Action::Cancel))
        .collect::<Vec<_>>();
    // Paused selections retain their work. Otherwise one deterministic winner
    // permits legacy migration without mutually blocking overlapping roots.
    references.sort_by_key(|candidate| {
        (
            action(&format!("root:{candidate}")) != Some(Action::Pause),
            candidate.clone(),
        )
    });
    Ok(references
        .first()
        .is_some_and(|candidate| Some(candidate.as_str()) != root))
}

fn other_output_is_live(output: &Path, root: Option<&str>) -> anyhow::Result<bool> {
    Ok(output_references(output)?.iter().any(|candidate| {
        Some(candidate.as_str()) != root
            && action(&format!("root:{candidate}")) != Some(Action::Cancel)
    }))
}
/// Live queue IDs isolate the same cloud file in different selections. Group
/// and path controls also apply before a folder has finished discovering files.
pub fn set_scope(id: &str, keys: Vec<String>) {
    if let Some(retired) = RETIRED_SCOPES.get() {
        retired.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
    }
    SCOPES
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id.into(), keys);
}
pub fn remove_scope(id: &str) {
    if let Some(scopes) = SCOPES.get() {
        scopes.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
    }
}
/// A terminal body releases its checkpoint to explicit retries even when other
/// work keeps the same folder selection alive. Missing restored bodies do not.
pub fn retire_scope(id: &str) {
    if let Some(root) = transfer_root(id) {
        RETIRED_SCOPES
            .get_or_init(Default::default)
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.into(), root);
    }
    remove_scope(id);
}
pub fn clear_retired_scopes(root: &str) {
    if let Some(retired) = RETIRED_SCOPES.get() {
        retired
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|_, previous_root| previous_root != root);
    }
}
pub fn action(id: &str) -> Option<Action> {
    let scopes = SCOPES
        .get()
        .and_then(|scopes| {
            scopes
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(id)
                .cloned()
        })
        .unwrap_or_default();
    std::iter::once(id)
        .chain(scopes.iter().map(String::as_str))
        .filter_map(read_action)
        .fold(None, |previous, next| {
            if previous == Some(Action::Cancel) || next == Action::Cancel {
                Some(Action::Cancel)
            } else {
                Some(next)
            }
        })
}
fn read_action(id: &str) -> Option<Action> {
    let path = PathBuf::from(std::env::var_os("MYCLOUDDRIVER_TRANSFER_CONTROL")?);
    let cache = CACHE.get_or_init(|| {
        Mutex::new(Cache {
            read_at: Instant::now() - Duration::from_secs(1),
            document: Document::default(),
        })
    });
    let mut cache = cache.lock().unwrap_or_else(|error| error.into_inner());
    let mut changed = false;
    if cache.read_at.elapsed() >= Duration::from_millis(100) {
        cache.read_at = Instant::now();
        if let Ok(data) = std::fs::read(&path) {
            if data.len() <= 16 * 1024 * 1024 {
                if let Ok(document) = serde_json::from_slice::<Document>(&data) {
                    changed = cache.document != document;
                    cache.document = document;
                }
            }
        }
    }
    let scoped = if id.starts_with("path:") {
        cache
            .document
            .actions
            .iter()
            .filter(|(key, _)| {
                key.starts_with("path:")
                    && (id == key.as_str() || id.starts_with(&(key.to_string() + "/")))
            })
            .map(|(_, action)| *action)
            .fold(None, |previous, next| {
                if previous == Some(Action::Cancel) || next == Action::Cancel {
                    Some(Action::Cancel)
                } else {
                    Some(next)
                }
            })
    } else {
        cache.document.actions.get(id).copied()
    };
    let result = match (cache.document.actions.get("*"), scoped.as_ref()) {
        (Some(Action::Cancel), _) | (_, Some(Action::Cancel)) => Some(Action::Cancel),
        (Some(Action::Pause), _) | (_, Some(Action::Pause)) => Some(Action::Pause),
        _ if cache.document.drain => Some(Action::Pause),
        _ => None,
    };
    drop(cache);
    if changed { changes().notify_waiters(); }
    result
}

/// Avoid walking every queued file's scoped controls when no cancellation
/// exists. Pause and Cancel are still rechecked at dispatch and I/O boundaries.
fn cancellation_pending() -> bool {
    let _ = read_action("*");
    CACHE.get().is_some_and(|cache| cache.lock().unwrap_or_else(|e| e.into_inner())
        .document.actions.values().any(|action| *action == Action::Cancel))
}
pub async fn run<T>(id: &str, future: impl Future<Output = T>) -> Result<T, Cancelled> {
    run_controlled(|| action(id), future).await
}

async fn run_controlled<T>(
    read_action: impl Fn() -> Option<Action>,
    future: impl Future<Output = T>,
) -> Result<T, Cancelled> {
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
    match crate::download_fs::metadata_async(path).await {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            crate::download_fs::remove_file(path)?;
        }
        Ok(_) => anyhow::bail!("Refusing to remove a non-regular partial file"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    crate::download_transport::remove_state(path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn memory_pressure_backs_off_admission_once_and_keeps_live_streams() {
        let now = Instant::now(); let mut workers = Concurrency::adaptive(256, Arc::new(AtomicU64::new(0)));
        workers.throughput.as_mut().unwrap().0.limit = 128;
        workers.observe_resources(100, true, Some((2, 100)), now);
        assert_eq!(workers.limit(), 64);
        for seconds in 1..20 { workers.observe_resources(100, true, Some((2, 50)), now + Duration::from_secs(seconds)); }
        assert_eq!(workers.limit(), 64, "A sustained warning cannot halve admission on every scheduler pass");
        assert_eq!(workers.throughput.as_ref().unwrap().0.active, 100, "Lower admission leaves the existing bodies alive");
        workers.observe_resources(60, true, Some((1, 5)), now + Duration::from_secs(20));
        assert_eq!(workers.limit(), 64, "Stall recovery must not be counted as a new concurrency gain");
        workers.observe_resources(60, true, Some((1, 0)), now + Duration::from_secs(21));
        assert_eq!(workers.limit(), 64, "Normal operation resumes with a fresh throughput trial");
        assert!(!workers.memory_backoff);
    }
    #[test]
    fn scheduler_still_cancels_queued_scopes_while_other_work_is_paused() {
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "transfer_control::tests::scheduler_cancel_child", "--ignored", "--nocapture"])
            .output().unwrap();
        assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
    }
    #[tokio::test]
    #[ignore = "isolated scheduler controls; launched by parent regression"]
    async fn scheduler_cancel_child() {
        use std::sync::atomic::AtomicUsize;
        let directory = tempfile::tempdir().unwrap();let path = directory.path().join("controls.json");
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &path);
        std::fs::write(&path, br#"{"actions":{"*":"pause"}}"#).unwrap();
        assert!(!cancellation_pending(), "Pause must not trigger a full queued-cancellation census");
        set_scope("generated-cancel-1", vec!["root:generated-cancelled".into()]);
        set_scope("generated-cancel-2", vec!["path:generated-folder/nested".into()]);
        let controls = path.clone();let completed = Arc::new(AtomicUsize::new(0));let observed = completed.clone();
        let edit = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            std::fs::write(&controls, br#"{"actions":{"*":"pause","root:generated-cancelled":"cancel","path:generated-folder":"cancel","generated-cancel-3":"cancel"}}"#).unwrap();
            tokio::time::timeout(Duration::from_secs(3), async {
                while observed.load(Ordering::SeqCst) != 3 { tokio::time::sleep(Duration::from_millis(10)).await; }
            }).await.expect("Queued scoped cancels must be dispatched despite Pause");
            std::fs::write(&controls, br#"{"actions":{}}"#).unwrap();
        });
        tokio::time::timeout(Duration::from_secs(5), schedule(vec![0, 1, 2, 3], 1,
            |index| async move {
                if index != 0 { assert_eq!(action(&format!("generated-cancel-{index}")), Some(Action::Cancel));Err(Cancelled.into()) }
                else { assert!(action("generated-cancel-0").is_none());Ok(()) }
            }, |index| format!("generated-cancel-{index}"), |index, result| {
                if index != 0 { assert!(result.unwrap_err().is::<Cancelled>());completed.fetch_add(1, Ordering::SeqCst); }
                else { result.unwrap(); }
            }, |_, _, _| panic!("Control changes are not network retries"))).await.unwrap().unwrap();
        edit.await.unwrap();assert_eq!(completed.load(Ordering::SeqCst), 3);assert!(!cancellation_pending());
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn default_cli_namespace_matches_the_gui_transfer_lock_directory() {
        let home = PathBuf::from("/synthetic-home");
        assert_eq!(
            default_output_lock_directory(Some(home.clone())),
            home.join("Library/Application Support/My PikPak for Mac/TransferLocks")
        );
        assert!(default_output_lock_directory(None)
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("myclouddriver-transfer-locks-"));
    }
    #[test]
    fn standalone_cli_output_leases_are_isolated_in_a_child_process() {
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "transfer_control::tests::standalone_output_lease_child",
                "--ignored",
            ])
            .env_remove("MYCLOUDDRIVER_TRANSFER_LOCKS")
            .env_remove("MYCLOUDDRIVER_TRANSFER_CONTROL")
            .env_remove("MYCLOUDDRIVER_TRANSFER_OWNER")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
    #[tokio::test]
    #[ignore = "launched by standalone_cli_output_leases_are_isolated_in_a_child_process"]
    async fn standalone_output_lease_child() {
        let root = tempfile::tempdir().unwrap();
        let composed = root.path().join("caf\u{e9}.bin");
        let decomposed = root.path().join("cafe\u{301}.bin");
        let first = output_lock(&composed, "first-file")
            .await
            .unwrap()
            .expect("CLI transfers must always own a destination lease");
        assert!(same_output(&composed, &decomposed).unwrap());
        assert!(output_lock(&decomposed, "second-file")
            .await
            .unwrap_err()
            .is::<Retry>());
        drop(first);
        let second = output_lock(&decomposed, "second-file")
            .await
            .unwrap()
            .unwrap();
        drop(second);
        // This unique synthetic destination cannot share a real transfer key.
        std::fs::remove_file(lock_path(&composed).unwrap().unwrap()).unwrap();
    }
    #[tokio::test]
    async fn one_expired_download_does_not_reduce_healthy_capacity() {
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let healthy = Arc::new(tokio::sync::Barrier::new(4));
        let transfer = schedule(
            (0..5).collect(),
            Concurrency::download(4, Arc::new(AtomicU64::new(0))),
            |id| {
                let attempts = attempts.clone();
                let healthy = healthy.clone();
                async move {
                    if id == 0 {
                        if attempts.fetch_add(1, Ordering::SeqCst) == 0 {
                            return Err(anyhow::Error::new(pikpak::download_policy::HttpFailure {
                                status: 403,
                                retry_after: None,
                            })
                            .context(Retry("Refresh the synthetic expired link".into())));
                        }
                    } else {
                        healthy.wait().await;
                    }
                    Ok(())
                }
            },
            |id| format!("speed-retry-{id}"),
            |_, result| {
                result.unwrap();
            },
            |_, _, _| {},
        );
        tokio::time::timeout(Duration::from_secs(4), transfer)
            .await
            .expect("A single failed file throttled four healthy downloads")
            .unwrap();
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn steady_receive_with_frequent_completions_still_expands_admission() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "transfer_control::tests::admission_replacement_child", "--ignored", "--nocapture"])
            .output().unwrap();
        assert!(output.status.success(), "{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    }

    #[tokio::test]
    #[ignore = "isolated synthetic receive counter and private controls"]
    async fn admission_replacement_child() {
        use std::sync::atomic::AtomicUsize;
        let directory = tempfile::tempdir().unwrap();
        let control = directory.path().join("control.json");
        std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
        std::env::set_var("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS", directory.path().join("connections"));
        let network = pikpak::download_network::Network::shared();
        let active = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let observed_peak = peak.clone();
        let pool = tokio::spawn(schedule(
            (0..1000).collect(), Concurrency::download(16, network.received_counter()),
            move |id| {
                let network = network.clone(); let active = active.clone(); let peak = peak.clone();
                async move {
                    crate::download_verification::ready_to_receive(&format!("generated-admission-{id}")).await?;
                    struct Active(Arc<AtomicUsize>);
                    impl Drop for Active { fn drop(&mut self) { self.0.fetch_sub(1, Ordering::Relaxed); } }
                    let count = active.fetch_add(1, Ordering::Relaxed) + 1;
                    let _active = Active(active); peak.fetch_max(count, Ordering::Relaxed);
                    // Short files keep a continuous receive stream, while a
                    // completed worker is replaced every 400 ms. No user data
                    // or network connection is used by this regression test.
                    for _ in 0..20 { tokio::time::sleep(Duration::from_millis(20)).await; network.record(32 << 10); }
                    Ok(())
                }
            }, |id| format!("generated-admission-{id}"), |_, result| { result.unwrap(); }, |_, _, _| {}
        ));
        let expanded = tokio::time::timeout(Duration::from_secs(9), async {
            while observed_peak.load(Ordering::Relaxed) < 6 { tokio::time::sleep(Duration::from_millis(20)).await; }
        }).await.is_ok();
        pool.abort(); let _ = pool.await;
        assert!(expanded, "Continuous receive with replacement work stayed at {} active transfers", observed_peak.load(Ordering::Relaxed));
    }

    #[test]
    fn completions_at_the_sample_interval_do_not_hold_downloads_at_four_workers() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "transfer_control::tests::sample_interval_replacement_child", "--ignored", "--nocapture"])
            .output().unwrap();
        assert!(output.status.success(), "{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    }

    #[tokio::test]
    #[ignore = "isolated generated receive counter and admission diagnostics"]
    async fn sample_interval_replacement_child() {
        let directory = tempfile::tempdir().unwrap();
        let control = directory.path().join("control.json");
        std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
        std::env::set_var("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS", directory.path().join("connections"));
        let network = pikpak::download_network::Network::shared();
        let pool = tokio::spawn(schedule(
            (0..1000).collect(), Concurrency::download(16, network.received_counter()),
            move |id| {
                let network = network.clone();
                async move {
                    crate::download_verification::ready_to_receive(&format!("generated-sample-admission-{id}")).await?;
                    let end = tokio::time::Instant::now() + Duration::from_millis(500);
                    let mut timer = tokio::time::interval(Duration::from_millis(20));
                    while tokio::time::Instant::now() < end {
                        timer.tick().await;
                        network.record(64 << 10);
                    }
                    Ok(())
                }
            }, |id| format!("generated-sample-admission-{id}"), |_, result| { result.unwrap(); }, |_, _, _| {}
        ));
        let expanded = tokio::time::timeout(Duration::from_secs(12), async {
            while download_scheduler_snapshot().limit <= 4 { tokio::time::sleep(Duration::from_millis(20)).await; }
        }).await.is_ok();
        let final_state = download_scheduler_snapshot();
        pool.abort(); let _ = pool.await;
        assert!(expanded, "Immediately replaceable downloads remained at limit={} with {} queued files",
            final_state.limit, final_state.queued_files);
    }


    #[test]
    fn output_ownership_and_queued_pause_are_isolated_in_a_child_process() {
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "transfer_control::tests::ownership_and_fairness_child",
                "--ignored",
                "--nocapture",
            ])
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stdout).to_string()
                + &String::from_utf8_lossy(&result.stderr)
        );
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
        let composed = root.path().join("caf\u{e9}.mp4");
        let decomposed = root.path().join("cafe\u{301}.mp4");
        assert!(same_output(&composed, &decomposed).unwrap());
        let unicode_lease = output_lock(&composed, "unicode-writer").await.unwrap();
        std::fs::write(&control, br#"{"actions":{"unicode-waiter":"cancel"}}"#).unwrap();
        tokio::time::sleep(Duration::from_millis(110)).await;
        assert!(output_lock(&decomposed, "unicode-waiter")
            .await
            .unwrap_err()
            .is::<Cancelled>());
        drop(unicode_lease);
        let final_output = root.path().join("cancelled-completion.bin");
        let complete_partial = root.path().join("cancelled-completion.bin.part");
        std::fs::write(&complete_partial, b"new").unwrap();
        let download = pikpak::DownloadInfo {
            web_content_link: "unused".into(),
            name: "cancelled-completion.bin".into(),
            size: 3,
            source_revision: Some("gcid:synthetic".into()),
        };
        let source = crate::download_receipt::Source::from_download(
            "account:fixture".into(),
            "fixture-id",
            &download,
            3,
        );
        let error = crate::download_receipt::finish(
            &complete_partial,
            &final_output,
            source,
            "unicode-waiter",
        )
        .await
        .unwrap_err();
        assert!(error.is::<Cancelled>());
        assert!(!final_output.exists());
        assert!(complete_partial.exists());
        claim_partial(&partial, "cloud-file").unwrap();
        std::fs::write(&partial, b"owned partial").unwrap();
        // An active writer blocks a cancelled waiter, who must never unlink.
        std::fs::write(&control, br#"{"actions":{"other-file":"cancel"}}"#).unwrap();
        tokio::time::sleep(Duration::from_millis(110)).await;
        assert!(output_lock(&output, "other-file")
            .await
            .unwrap_err()
            .is::<Cancelled>());
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
        assert!(!partial.exists());
        drop(lease);
        // Consolidating windows admits only explicitly imported owners, with
        // the same cloud file ID, and rewrites ownership under the output lock.
        let lease = output_lock(&output, "cloud-file").await.unwrap();
        claim_partial(&partial, "cloud-file").unwrap();
        std::fs::write(&partial, b"imported progress").unwrap();
        drop(lease);
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "shared-account-x");
        std::env::set_var(
            "MYCLOUDDRIVER_IMPORTED_TRANSFER_OWNERS",
            "window-a-account-x",
        );
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
        assert!(!partial.exists());
        drop(lease);
        // Separate live selections can share one file/output in this window.
        // A queued child's Cancel must preserve a paused folder's checkpoint,
        // even though neither selection currently holds the output lease.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let client = pikpak::Client::builder()
            .refresh_token("synthetic-refresh")
            .api_base_url(&base)
            .auth_base_url(&base)
            .build()
            .unwrap();
        for shared in [false, true] {
            let name = if shared {
                "overlap-shared.bin"
            } else {
                "overlap-account.bin"
            };
            let output = root.path().join(name);
            let partial = root.path().join(format!("{name}.part"));
            let lease = output_lock(&output, "paused-folder-body").await.unwrap();
            set_scope("paused-folder-body", vec!["root:paused-folder".into()]);
            claim_partial_as(&partial, "overlap-file", "paused-folder-body").unwrap();
            std::fs::write(&partial, b"abc").unwrap();
            crate::download_transport::seed_resume(&partial, "overlap-file", 8, "\"synthetic\"");
            drop(lease);
            set_scope("cancelled-child-body", vec!["root:child-selection".into()]);
            let lease = output_lock(&output, "cancelled-child-body").await.unwrap();
            assert!(
                claim_partial_as(&partial, "overlap-file", "cancelled-child-body")
                    .unwrap_err()
                    .is::<Retry>(),
                "An overlapping child adopted a still-live folder's checkpoint"
            );
            drop(lease);
            std::fs::write(
                &control,
                br#"{"actions":{"cancelled-child-body":"cancel"}}"#,
            )
            .unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            let file = serde_json::from_value(
                serde_json::json!({"id":"overlap-file", "parent_id":"generated-folder",
                "name":name, "size":"8", "kind":"drive#file"}),
            )
            .unwrap();
            let received = Arc::new(AtomicU64::new(0));
            let result = if shared {
                let share = client
                    .share_client("https://mypikpak.com/s/generated", "", "")
                    .unwrap();
                crate::download_share_file_as(
                    &share,
                    &file,
                    root.path(),
                    false,
                    false,
                    received,
                    "cancelled-child-body",
                )
                .await
            } else {
                crate::download_file_as(
                    &client,
                    &file,
                    root.path(),
                    false,
                    false,
                    received,
                    "cancelled-child-body",
                    None,
                )
                .await
            };
            result.unwrap();
            assert_eq!(
                std::fs::read(&partial)
                    .expect("Cancelling the child deleted the paused folder's prefix"),
                b"abc"
            );
            assert!(crate::download_transport::saved_bytes(&partial, "overlap-file", 8).await >= 3);
            // Restored paused discovery has not recreated the old Body ID.
            remove_scope("paused-folder-body");
            set_scope(
                "path:paused-folder:/Generated",
                vec!["root:paused-folder".into()],
            );
            std::fs::write(&control, br#"{"actions":{"root:paused-folder":"pause"}}"#).unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            let lease = output_lock(&output, "cancelled-child-body").await.unwrap();
            assert!(
                claim_partial_as(&partial, "overlap-file", "cancelled-child-body")
                    .unwrap_err()
                    .is::<Retry>()
            );
            remove_scope("path:paused-folder:/Generated");
            assert!(
                claim_partial_as(&partial, "overlap-file", "cancelled-child-body")
                    .unwrap_err()
                    .is::<Retry>(),
                "Inbox ordering bypassed the persisted root's Pause"
            );
            // Once the previous selection is no longer live or paused, a new
            // retry ID may resume its checkpoint rather than discard it.
            std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            claim_partial_as(&partial, "overlap-file", "cancelled-child-body").unwrap();
            let manifest: serde_json::Value = serde_json::from_slice(
                &std::fs::read(lock_path(&output).unwrap().unwrap()).unwrap(),
            )
            .unwrap();
            assert!(
                manifest
                    .as_object()
                    .unwrap()
                    .values()
                    .all(serde_json::Value::is_string),
                "Swift cleanup requires string-only ownership fields"
            );
            remove_owned_partial_as(&partial, "overlap-file", "paused-folder-body")
                .await
                .unwrap();
            assert_eq!(
                std::fs::read(&partial).unwrap(),
                b"abc",
                "The retired ID removed a rebound checkpoint"
            );
            remove_owned_partial_as(&partial, "overlap-file", "cancelled-child-body")
                .await
                .unwrap();
            assert!(!partial.exists());
            remove_scope("cancelled-child-body");
            drop(lease);
            // Old manifests have no selection IDs. A restored paused folder's
            // actual output tree still reserves its progress from a child.
            let lease = output_lock(&output, "legacy-folder-body").await.unwrap();
            claim_partial(&partial, "overlap-file").unwrap();
            std::fs::write(&partial, b"abc").unwrap();
            set_scope("legacy-child-body", vec!["root:b-legacy-child".into()]);
            set_output_reference("a-legacy-folder", root.path(), true).unwrap();
            set_output_reference("b-legacy-child", &output, false).unwrap();
            set_output_reference("unrelated-root", &root.path().join("elsewhere.bin"), false)
                .unwrap();
            std::fs::write(&control, br#"{"actions":{"root:a-legacy-folder":"pause"}}"#).unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            assert!(
                claim_partial_as(&partial, "overlap-file", "legacy-child-body")
                    .unwrap_err()
                    .is::<Retry>()
            );
            remove_owned_partial_as(&partial, "overlap-file", "legacy-child-body")
                .await
                .unwrap();
            assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
            // With two active overlaps, one consistent winner can migrate the
            // legacy checkpoint; the contender cannot cause a mutual wait.
            std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            set_scope("legacy-folder-body", vec!["root:a-legacy-folder".into()]);
            assert!(
                claim_partial_as(&partial, "overlap-file", "legacy-child-body")
                    .unwrap_err()
                    .is::<Retry>()
            );
            claim_partial_as(&partial, "overlap-file", "legacy-folder-body").unwrap();
            remove_owned_partial_as(&partial, "overlap-file", "legacy-folder-body")
                .await
                .unwrap();
            assert_eq!(
                std::fs::read(&partial).unwrap(),
                b"abc",
                "The surviving overlapping root lost shared progress"
            );
            remove_output_reference("a-legacy-folder");
            remove_scope("legacy-folder-body");
            std::fs::write(
                &control,
                br#"{"actions":{"root:a-legacy-folder":"cancel"}}"#,
            )
            .unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            claim_partial_as(&partial, "overlap-file", "legacy-child-body").unwrap();
            remove_owned_partial_as(&partial, "overlap-file", "legacy-child-body")
                .await
                .unwrap();
            assert!(
                !partial.exists(),
                "An unrelated root blocked the current selection's cleanup"
            );
            remove_output_reference("b-legacy-child");
            remove_output_reference("unrelated-root");
            remove_scope("legacy-child-body");
            drop(lease);
            // A terminal failed child can be retried without waiting for the
            // rest of its folder, including a different paused child.
            set_scope("root:failed-folder", vec!["root:failed-folder".into()]);
            set_scope("failed-folder-body", vec!["root:failed-folder".into()]);
            set_scope("paused-sibling-body", vec!["root:failed-folder".into()]);
            set_scope("retry-child-body", vec!["root:retry-child".into()]);
            set_output_reference("failed-folder", root.path(), true).unwrap();
            set_output_reference("retry-child", &output, false).unwrap();
            std::fs::write(&control, br#"{"actions":{"paused-sibling-body":"pause"}}"#).unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            let lease = output_lock(&output, "failed-folder-body").await.unwrap();
            claim_partial_as(&partial, "overlap-file", "failed-folder-body").unwrap();
            std::fs::write(&partial, b"abc").unwrap();
            crate::download_transport::seed_resume(&partial, "overlap-file", 8, "\"synthetic\"");
            assert!(
                claim_partial_as(&partial, "overlap-file", "retry-child-body")
                    .unwrap_err()
                    .is::<Retry>()
            );
            retire_scope("failed-folder-body");
            // Re-registering that body revokes retirement, and root teardown
            // clears it so missing bodies in a restored root remain reserved.
            set_scope("failed-folder-body", vec!["root:failed-folder".into()]);
            assert!(
                claim_partial_as(&partial, "overlap-file", "retry-child-body")
                    .unwrap_err()
                    .is::<Retry>()
            );
            retire_scope("failed-folder-body");
            clear_retired_scopes("failed-folder");
            assert!(
                claim_partial_as(&partial, "overlap-file", "retry-child-body")
                    .unwrap_err()
                    .is::<Retry>()
            );
            set_scope("failed-folder-body", vec!["root:failed-folder".into()]);
            retire_scope("failed-folder-body");
            assert_eq!(action("paused-sibling-body"), Some(Action::Pause));
            claim_partial_as(&partial, "overlap-file", "retry-child-body").unwrap();
            assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
            assert!(crate::download_transport::saved_bytes(&partial, "overlap-file", 8).await >= 3);
            remove_owned_partial_as(&partial, "overlap-file", "failed-folder-body")
                .await
                .unwrap();
            assert_eq!(
                std::fs::read(&partial).unwrap(),
                b"abc",
                "The retired failed body deleted its retry's prefix"
            );
            remove_output_reference("failed-folder");
            remove_scope("root:failed-folder");
            remove_scope("paused-sibling-body");
            clear_retired_scopes("failed-folder");
            remove_owned_partial_as(&partial, "overlap-file", "retry-child-body")
                .await
                .unwrap();
            assert!(!partial.exists());
            remove_output_reference("retry-child");
            remove_scope("retry-child-body");
            drop(lease);
        }
        assert!(
            tokio::time::timeout(Duration::from_millis(25), listener.accept())
                .await
                .is_err(),
            "Cancelled metadata unexpectedly called the provider"
        );
        // A paused queue entry leaves the sole worker free for healthy work.
        std::fs::write(&control, br#"{"actions":{"paused":"pause"}}"#).unwrap();
        tokio::time::sleep(Duration::from_millis(110)).await;
        let resume = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(350)).await;
            std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        });
        let mut order = Vec::new();
        schedule(
            vec!["paused", "healthy"],
            Concurrency::download(1, Arc::new(AtomicU64::new(0))),
            |value| async move { Ok(value) },
            |value| value.to_string(),
            |value, _| order.push(value),
            |_, _, _| {},
        )
        .await
        .unwrap();
        resume.await.unwrap();
        assert_eq!(order, vec!["healthy", "paused"]);
    }
    #[tokio::test]
    async fn failed_file_waits_in_queue_and_does_not_starve_healthy_file() {
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        // Both fixed upload slots and adaptive download slots must release
        // failed attempts so healthy work can proceed during retry delays.
        for policy in [
            Concurrency::from(1),
            Concurrency::download(1, Arc::new(AtomicU64::new(0))),
        ] {
            let attempts = Arc::new(AtomicUsize::new(0));
            let mut order = Vec::new();
            let mut retries = 0;
            schedule(
                vec![0usize, 1],
                policy,
                |value| {
                    let attempts = attempts.clone();
                    async move {
                        if value == 0 && attempts.fetch_add(1, Ordering::SeqCst) == 0 {
                            return Err(Retry("temporary failure".into()).into());
                        }
                        Ok(())
                    }
                },
                |value| value.to_string(),
                |value, result| {
                    result.unwrap();
                    order.push(value);
                },
                |_, attempt, delay| {
                    retries += 1;
                    assert_eq!(attempt, 1);
                    assert_eq!(delay.as_secs(), 1);
                },
            )
            .await
            .unwrap();
            assert_eq!(order, vec![1, 0]);
            assert_eq!(retries, 1);
        }
    }

    #[tokio::test]
    async fn pause_retains_work_and_cancel_drops_it_without_blocking_other_work() {
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        let state = Arc::new(AtomicUsize::new(1));
        let reader = state.clone();
        let first = tokio::spawn(async move {
            run_controlled(
                || match reader.load(Ordering::SeqCst) {
                    1 => Some(Action::Pause),
                    2 => Some(Action::Cancel),
                    _ => None,
                },
                std::future::ready(42),
            )
            .await
        });
        tokio::time::sleep(Duration::from_millis(130)).await;
        assert!(!first.is_finished(), "paused ready work must not execute");
        assert_eq!(
            run_controlled(|| None, std::future::ready(7))
                .await
                .unwrap(),
            7
        );
        state.store(0, Ordering::SeqCst);
        assert_eq!(first.await.unwrap().unwrap(), 42);
        let state = Arc::new(AtomicUsize::new(0));
        let reader = state.clone();
        let waiting = tokio::spawn(async move {
            run_controlled(
                || {
                    if reader.load(Ordering::SeqCst) == 2 {
                        Some(Action::Cancel)
                    } else {
                        None
                    }
                },
                std::future::pending::<()>(),
            )
            .await
        });
        state.store(2, Ordering::SeqCst);
        assert!(tokio::time::timeout(Duration::from_secs(1), waiting)
            .await
            .unwrap()
            .unwrap()
            .is_err());
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
    let _stage = pikpak::download_waits::Stage::enter(pikpak::download_waits::Kind::OutputLease);
    use rustix::fs::{flock, openat, FlockOperation, Mode, OFlags};
    use std::os::unix::fs::PermissionsExt;
    crate::download_fs::validate(output)?;
    let directory = output_lock_directory();
    let namespace = crate::download_fs::directory(&directory, true)?;
    namespace.set_permissions(std::fs::Permissions::from_mode(0o700))?;
    let normalized = normalized_output_key(output)?;
    let key =
        hex::encode(ring::digest::digest(&ring::digest::SHA256, normalized.as_bytes()).as_ref());
    let descriptor = openat(
        &namespace,
        key,
        OFlags::CREATE | OFlags::RDWR | OFlags::NONBLOCK | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR,
    )?;
    let file = std::fs::File::from(descriptor);
    if !file.metadata()?.is_file() {
        anyhow::bail!("Invalid download destination lock");
    }
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    match flock(&file, FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => Ok(Some(file)),
        Err(error) if error == rustix::io::Errno::WOULDBLOCK => {
            if action(id) == Some(Action::Cancel) {
                return Err(Cancelled.into());
            }
            if disk_action(id) == Some(Action::Pause) {
                return Err(Paused.into());
            }
            Err(Retry("Destination is being written by another window".into()).into())
        }
        Err(error) => Err(error.into()),
    }
}

#[derive(Debug)]
pub struct Paused;
impl std::fmt::Display for Paused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Transfer paused by user")
    }
}
impl std::error::Error for Paused {}
#[derive(Debug)]
pub struct Retry(pub String);
impl std::fmt::Display for Retry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for Retry {}

/// A transfer attempt releases its worker on pause. Call only at boundaries
/// where dropping the future cannot leave a local write unfinished.
pub async fn interruptible<T>(id: &str, future: impl Future<Output = T>) -> anyhow::Result<T> {
    interruptible_inner(id, future, || action(id)).await
}

/// Only a RAM consumer may continue through Quit's drain. Cancel has priority.
pub(crate) async fn drainable<T>(id: &str, future: impl Future<Output = T>) -> anyhow::Result<T> {
    interruptible_inner(id, future, || match action(id) {
        Some(Action::Pause) if draining() || receive_only_pause() => None,
        action => action,
    }).await
}

pub(crate) async fn disk_interruptible<T>(id: &str, future: impl Future<Output = T>) -> anyhow::Result<T> {
    interruptible_inner(id, future, || disk_action(id)).await
}

/// A deferred local check may need fresh source metadata before reopening its
/// journal. This exception never admits an HTTP content body while paused.
pub(crate) fn metadata_interruptible<'a, T: 'a>(id: &'a str, future: impl Future<Output = T> + 'a) -> impl Future<Output = anyhow::Result<T>> + 'a {
    // Keep large provider futures off the task stack while first waiting for
    // setup admission; both stages remain cancellable by the same controls.
    let future = Box::pin(future);
    async move {
        let control = || {
            if disk_readers().lock().unwrap().contains_key(id) { disk_action(id) } else { action(id) }
        };
        interruptible_inner(id, crate::download_verification::prepare_metadata(), control).await?;
        interruptible_inner(id, future, control).await
    }
}

async fn interruptible_inner<T>(_id: &str, future: impl Future<Output = T>, control: impl Fn() -> Option<Action>) -> anyhow::Result<T> {
    tokio::pin!(future);
    loop {
        match control() {
            Some(Action::Cancel) => return Err(Cancelled.into()),
            Some(Action::Pause) => return Err(Paused.into()),
            _ => tokio::select! {
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
    report_download: bool,
    memory_backoff: bool,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct DownloadSchedulerSnapshot {
    pub limit: usize,
    pub network_workers: usize,
    pub queued_files: usize,
    pub has_ready: bool,
    pub task_capacity: usize,
    pub task_capacity_reached: bool,
    pub receiving_waiters: usize,
}
fn download_scheduler_metrics() -> &'static Mutex<DownloadSchedulerSnapshot> {
    static METRICS: OnceLock<Mutex<DownloadSchedulerSnapshot>> = OnceLock::new();
    METRICS.get_or_init(Default::default)
}
pub(crate) fn download_scheduler_snapshot() -> DownloadSchedulerSnapshot {
    *download_scheduler_metrics().lock().unwrap_or_else(|error| error.into_inner())
}
struct DownloadSchedulerReporting(bool);
impl Drop for DownloadSchedulerReporting {
    fn drop(&mut self) {
        if self.0 {
            *download_scheduler_metrics().lock().unwrap_or_else(|error| error.into_inner()) = DownloadSchedulerSnapshot::default();
        }
    }
}

fn disk_readers() -> &'static Mutex<HashMap<String, usize>> {
    static READERS: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    READERS.get_or_init(Default::default)
}
/// Verification, its preparation, and draining a completed HTTP body to disk
/// do not occupy a network worker. Their output leases and tasks remain alive.
pub(crate) struct DiskReadPhase(String);
impl DiskReadPhase {
    pub(crate) fn enter(id: &str) -> Self {
        crate::download_verification::release_receiving_for_read(id);
        Self::retain(id)
    }
    // Admission owns its attempt mutex and has already released the slot.
    // Keeping an existing disk phase must not re-enter that mutex.
    pub(crate) fn retain(id: &str) -> Self {
        *disk_readers().lock().unwrap().entry(id.into()).or_default() += 1;
        Self(id.into())
    }
}
impl Drop for DiskReadPhase {
    fn drop(&mut self) {
        let mut readers = disk_readers().lock().unwrap();
        if let Some(count) = readers.get_mut(&self.0) {
            *count -= 1;
            if *count == 0 { readers.remove(&self.0); }
        }
    }
}
fn parked_reads(ids: &HashSet<String>) -> usize {
    let readers = disk_readers().lock().unwrap();
    ids.iter().filter(|id| readers.contains_key(*id)).count()
}

fn download_task_capacity() -> usize {
    static CAPACITY: OnceLock<usize> = OnceLock::new();
    *CAPACITY.get_or_init(|| {
        use rustix::process::{getrlimit, setrlimit, Resource, Rlimit};
        let limits = getrlimit(Resource::Nofile);
        let current = limits.current.unwrap_or(10_240);
        let desired = current.max(10_240).min(limits.maximum.unwrap_or(10_240));
        if desired > current {
            let _ = setrlimit(Resource::Nofile, Rlimit { current: Some(desired), maximum: limits.maximum });
        }
        // Live RAM consumers retain output/lock/checkpoint descriptors. Bound
        // those by the actual process allowance, independently of the 64
        // verifier preparation slots and the shared payload byte budget.
        (getrlimit(Resource::Nofile).current.unwrap_or(desired).saturating_sub(256) / 8)
            .max(1).min(usize::MAX as u64) as usize
    })
}

impl From<usize> for Concurrency {
    fn from(maximum: usize) -> Self {
        Self {
            maximum: maximum.max(1),
            throughput: None,
            report_download: false,
            memory_backoff: false,
        }
    }
}

impl Concurrency {
    /// File and range trials compare the same process-wide original-body bytes.
    /// The caller separately retains its queue's UI progress counter.
    pub fn download(maximum: usize, _received: Arc<AtomicU64>) -> Self {
        let network = pikpak::download_network::Network::shared();
        let maximum = maximum.max(1).min(network.limit());
        Self {
            maximum,
            throughput: Some((
                Connections::new(maximum, Instant::now())
                    .with_absolute_gain()
                    .with_coordinator(network.trials()),
                network.received_counter(),
            )),
            report_download: true,
            memory_backoff: false,
        }
    }

    /// Uploads and downloads use separate counters and admission pools.
    pub fn adaptive(maximum: usize, transferred: Arc<AtomicU64>) -> Self {
        Self {
            maximum: maximum.max(1),
            throughput: Some((Connections::new(maximum, Instant::now()), transferred)),
            report_download: false,
            memory_backoff: false,
        }
    }

    fn back_off(&mut self, until: Instant) {
        if let Some((connections, _)) = &mut self.throughput {
            connections.back_off(until);
        }
    }

    fn limit(&self) -> usize {
        self.throughput.as_ref().map_or(self.maximum, |(connections, _)| connections.limit)
    }

    fn observe(&mut self, active: usize, has_demand: bool) {
        let buffer = self.report_download.then(crate::download_buffer::snapshot);
        self.observe_resources(active, has_demand, buffer.as_ref().map(|value| (value.pressure, value.waiting_receivers)), Instant::now());
    }

    fn observe_resources(&mut self, active: usize, has_demand: bool, resources: Option<(u32, usize)>, now: Instant) {
        let Some((connections, received)) = &mut self.throughput else {
            return;
        };
        connections.active = active;
        if let Some((pressure, waiting)) = resources {
            if pressure >= 2 && !self.memory_backoff {
                // Reduce new admission once per warning; existing HTTP bodies
                // stay alive. Do not turn disk/RAM stall recovery into a false
                // throughput gain that doubles the number of receivers.
                connections.limit_for_resources((connections.limit / 2).max(4).min(self.maximum), now);
            }
            self.memory_backoff = pressure >= 2;
            if pressure >= 2 || waiting > 0 { connections.idle(now); return; }
            connections.limit_for_resources(self.maximum, now);
        }
        if has_demand {
            connections.observe(now, received.load(Ordering::Relaxed), || true);
        } else {
            connections.idle(now);
        }
    }
}

/// Only active attempts have Tokio tasks. Retry delays and paused files live
/// in the plain queue, so even a large failed batch cannot starve healthy files.
pub async fn schedule<T, R, Run, Fut, ID, Settled, Retrying>(
    items: Vec<T>,
    workers: impl Into<Concurrency>,
    run: Run,
    id: ID,
    settled: Settled,
    retrying: Retrying,
) -> anyhow::Result<()>
where
    T: Clone + Send + 'static,
    R: Send + 'static,
    Run: FnMut(T) -> Fut,
    Fut: Future<Output = anyhow::Result<R>> + Send + 'static,
    ID: Fn(&T) -> String,
    Settled: FnMut(T, anyhow::Result<R>),
    Retrying: FnMut(&T, u32, Duration),
{
    let (sender, receiver) = tokio::sync::mpsc::unbounded_channel();
    for item in items {
        sender
            .send(item)
            .map_err(|_| anyhow::anyhow!("Download queue closed"))?;
    }
    drop(sender);
    schedule_stream(receiver, workers, run, id, settled, retrying).await
}

pub async fn schedule_stream<T, R, Run, Fut, ID, Settled, Retrying>(
    mut incoming: tokio::sync::mpsc::UnboundedReceiver<T>,
    workers: impl Into<Concurrency>,
    mut run: Run,
    id: ID,
    mut settled: Settled,
    mut retrying: Retrying,
) -> anyhow::Result<()>
where
    T: Clone + Send + 'static,
    R: Send + 'static,
    Run: FnMut(T) -> Fut,
    Fut: Future<Output = anyhow::Result<R>> + Send + 'static,
    ID: Fn(&T) -> String,
    Settled: FnMut(T, anyhow::Result<R>),
    Retrying: FnMut(&T, u32, Duration),
{
    use std::collections::VecDeque;
    struct Entry<T> {
        item: T,
        attempt: u32,
        ready: Instant,
        read_wait: Option<crate::download_verification::Deferred>,
    }
    let mut pending = VecDeque::<Entry<T>>::new();
    let mut closed = false;
    let mut running = tokio::task::JoinSet::new();
    let mut concurrency = workers.into();
    let network_slots = concurrency.report_download.then(|| crate::download_verification::NetworkSlots::new(concurrency.limit()));
    // Setup and ready-to-receive lookahead stay bounded independently of
    // adaptive HTTP-body concurrency. Setup waits never consume body slots.
    let setup_slots = concurrency.report_download.then(|| crate::download_verification::NetworkSlots::new(64));
    let _reporting = DownloadSchedulerReporting(concurrency.report_download);
    let mut running_ids = HashSet::new();
    let mut drain_failed = false;
    while !closed || !pending.is_empty() || !running.is_empty() {
        let mut dispatch = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::SchedulerPass, "");
        if draining() {
            incoming.close(); closed = true; pending.clear();
            if running.is_empty() { break; }
        }
        // A bounded drain prevents a busy producer from starving active bodies.
        for _ in 0..if closed { 0 } else { 256 } {
            match incoming.try_recv() {
                Ok(item) => pending.push_back(Entry {
                    item,
                    attempt: 0,
                    ready: Instant::now(),
                    read_wait: None,
                }),
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                    closed = true;
                    break;
                }
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
            }
        }
        // Recheck while bodies are still in flight, not just on completion.
        // A reduced allowance drains naturally; no active task is aborted.
        let parked = if concurrency.throughput.is_some() { parked_reads(&running_ids) } else { 0 };
        let task_capacity = if concurrency.throughput.is_some() { download_task_capacity() } else { concurrency.limit() };
        let limit = concurrency.limit().min(task_capacity);
        if let Some(slots) = &network_slots { slots.set_limit(limit); }
        let cancelling = cancellation_pending();
        let ram_drainers = if concurrency.throughput.is_some() { crate::download_verification::ram_drainers(&running_ids) } else { 0 };
        // Finished producers do not occupy verifier or receiving slots. Their
        // bytes remain bounded by shared RAM; descriptor admission is separate.
        let parked_allowance = ram_drainers.saturating_add(parked.saturating_sub(ram_drainers).min(64));
        while !draining() {
            // A queued verifier has separate admission from HTTP bodies. It
            // must get a turn even when useful receivers fill the network
            // target; FIFO read tickets and byte admission bound its resources.
            let read_next = pending.iter().position(|entry| entry.read_wait.as_ref().is_some_and(|wait| wait.ready())
                && entry.ready <= Instant::now() && disk_action(&id(&entry.item)).is_none());
            let network_room = setup_slots.as_ref().map_or(
                running.len() < limit.saturating_add(parked_allowance), |slots| slots.available()) && running.len() < task_capacity;
            // FIFO byte admission already bounds preparing/running verifiers.
            // Active HTTP bodies must not consume their independent allowance.
            // Verified partials wait for a receiving slot before opening HTTP.
            let read_room = read_next.is_some() && running.len() < task_capacity
                && (network_slots.is_some() || running.len() < limit.saturating_add(ram_drainers).saturating_add(64));
            let cancel_next = cancelling.then(|| pending.iter().position(|entry| action(&id(&entry.item)) == Some(Action::Cancel))).flatten();
            let cancel_room = cancel_next.is_some() && running.len() < task_capacity;
            if !network_room && !read_room && !cancel_room { break; }
            let next = if cancel_room { cancel_next } else if read_room { read_next } else { pending.iter().position(|entry| {
                entry.ready <= Instant::now()
                    && entry.read_wait.as_ref().is_none_or(|wait| wait.ready())
                    && action(&id(&entry.item)) != Some(Action::Pause)
            }) };
            let Some(index) = next else {
                break;
            };
            let mut entry = pending.remove(index).unwrap();
            let setup_slot = if entry.read_wait.is_none() && !cancel_room {
                setup_slots.as_ref().and_then(|slots| slots.try_acquire())
            } else { None };
            if setup_slots.is_some() && entry.read_wait.is_none() && !cancel_room && setup_slot.is_none() {
                pending.insert(index, entry);break;
            }
            running_ids.insert(id(&entry.item));
            let future = run(entry.item.clone());
            let scope = if let (Some(network),Some(setup))=(&network_slots,&setup_slots) {
                crate::download_verification::Scope::with_setup(id(&entry.item), entry.read_wait.take(), network.clone(), setup.clone(), setup_slot)
            } else { crate::download_verification::Scope::new(id(&entry.item), entry.read_wait.take()) };
            running.spawn(async move { let result = scope.run(future).await; (entry, result) });
        }
        // Sample occupied slots after replacing completed/disk-only work. A
        // completion is not an idle period when its replacement is ready:
        // observing before refill repeatedly invalidated the five-second
        // evidence window and could leave a busy queue at four workers.
        let has_demand = pending.iter().any(|entry| entry.ready <= Instant::now()
            && entry.read_wait.as_ref().is_none_or(|wait| wait.ready()) && action(&id(&entry.item)).is_none())
            || network_slots.as_ref().is_some_and(|slots| slots.waiting() != 0);
        let parked = if concurrency.throughput.is_some() { parked_reads(&running_ids) } else { 0 };
        let network_active = network_slots.as_ref().map_or(running.len().saturating_sub(parked), |slots| slots.active());
        // Ready bodies can be between a released slot and their next poll.
        // Count that immediate replacement demand for tuning, so frequent
        // completions do not reset its evidence window. Metadata waits are
        // outside this gate and never count as receiving capacity.
        let tuning_active = network_slots.as_ref().map_or(network_active,
            |slots| network_active.saturating_add(slots.waiting()).min(limit).max(network_active));
        concurrency.observe(tuning_active, has_demand);
        if concurrency.report_download {
            *download_scheduler_metrics().lock().unwrap_or_else(|error| error.into_inner()) = DownloadSchedulerSnapshot {
                limit: concurrency.limit().min(task_capacity), network_workers: network_active, queued_files: pending.len(), has_ready: has_demand,
                task_capacity, task_capacity_reached: running.len() >= task_capacity && has_demand,
                receiving_waiters: network_slots.as_ref().map_or(0, |slots| slots.waiting()),
            };
        }
        if closed && pending.is_empty() && running.is_empty() {
            break;
        }
        dispatch.complete(); drop(dispatch);
        tokio::select! {
            item = incoming.recv(), if !closed => {
                match item {
                    Some(item) => pending.push_back(Entry { item, attempt: 0, ready: Instant::now(), read_wait: None }),
                    None => closed = true,
                }
            }
            joined = running.join_next(), if !running.is_empty() => {
                let (mut entry, result) = joined.unwrap()?;
                running_ids.remove(&id(&entry.item));
                if draining() && result.as_ref().is_err_and(|error|
                    !error.is::<Paused>() && !error.is::<Cancelled>()
                        && !error.is::<crate::download_verification::Deferred>()) {
                    drain_failed = true;
                }
                match result {
                    Err(error) if error.is::<crate::download_verification::Deferred>() => {
                        entry.read_wait = error.downcast_ref::<crate::download_verification::Deferred>().cloned();
                        pending.push_back(entry);
                    }
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
    anyhow::ensure!(!drain_failed, "Could not save every download RAM buffer before shutdown; synced checkpoints were preserved");
    Ok(())
}

#[derive(serde::Serialize, Deserialize)]
struct PartialOwner {
    owner: String,
    file_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    output_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    transfer_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root_id: Option<String>,
}

fn matches_owner(previous: &PartialOwner, owner: &str, id: &str) -> bool {
    previous.file_id == id
        && (previous.owner == owner
            || std::env::var("MYCLOUDDRIVER_IMPORTED_TRANSFER_OWNERS").is_ok_and(|owners| {
                owners
                    .split(',')
                    .any(|candidate| !candidate.is_empty() && candidate == previous.owner)
            }))
}

fn transfer_root(id: &str) -> Option<String> {
    SCOPES.get().and_then(|scopes| {
        scopes
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .get(id)
            .and_then(|keys| {
                keys.iter()
                    .find_map(|key| key.strip_prefix("root:").map(str::to_owned))
            })
    })
}

fn claim_is_live(
    previous: &PartialOwner,
    transfer_id: &str,
    root_id: Option<&str>,
    held_lease: bool,
) -> bool {
    let Some(previous_id) = previous
        .transfer_id
        .as_deref()
        .filter(|id| *id != transfer_id)
    else {
        return false;
    };
    let previous_root = previous
        .root_id
        .as_deref()
        .or_else(|| previous_id.split_once(':').map(|(root, _)| root));
    let cross_root_retry = previous_root
        .zip(root_id)
        .is_some_and(|(previous, current)| {
            canonical_root(previous) != canonical_root(current)
                && retry_ancestry(current)
                    .is_some_and(|roots| roots.contains(&canonical_root(previous)))
        });
    // Durable retry ancestry is a stricter exception than legacy terminal
    // release. A cancelled/retired ancestor must not bypass its persisted
    // Pause/Cancel controls, nor can cleanup without a held lease take it.
    if cross_root_retry {
        return !held_lease
            || ownership_action(transfer_id).is_some()
            || !retry_can_adopt(previous_id, previous_root, root_id);
    }
    if RETIRED_SCOPES.get().is_some_and(|retired| {
        retired
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(previous_id)
            .is_some_and(|root| Some(root.as_str()) == previous_root)
    }) {
        return false;
    }
    let root_action = previous_root.and_then(|root| ownership_action(&format!("root:{root}")));
    let body_action = ownership_action(previous_id);
    if root_action == Some(Action::Cancel) || body_action == Some(Action::Cancel) {
        return false;
    }
    // A restored body may have a new path-derived ID within the same selection.
    if previous_root
        .zip(root_id)
        .is_some_and(|(previous, current)| canonical_root(previous) == canonical_root(current))
    {
        return false;
    }
    if SCOPES.get().is_some_and(|scopes| {
        let scopes = scopes.lock().unwrap_or_else(|error| error.into_inner());
        ownership_aliases(previous_id)
            .iter()
            .any(|id| scopes.contains_key(id))
            || previous_root.is_some_and(|root| {
                let aliases = ownership_aliases(&format!("root:{root}"));
                scopes
                    .values()
                    .any(|keys| aliases.iter().any(|key| keys.contains(key)))
            })
    }) {
        return true;
    }
    // Paused discovery can restore a root before recreating its body scopes.
    // Preserve that selection even if another inbox root is admitted first.
    root_action != Some(Action::Cancel)
        && (root_action == Some(Action::Pause) || body_action == Some(Action::Pause))
}
fn lock_path(output: &Path) -> anyhow::Result<Option<PathBuf>> {
    let directory = output_lock_directory();
    let normalized = normalized_output_key(output)?;
    let key =
        hex::encode(ring::digest::digest(&ring::digest::SHA256, normalized.as_bytes()).as_ref());
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
    let filename = partial
        .file_name()
        .and_then(|value| value.to_str())
        .and_then(|value| value.strip_suffix(".part"))
        .ok_or_else(|| anyhow::anyhow!("Invalid partial filename"))?;
    Ok(partial.with_file_name(filename))
}
/// Called under this output's exclusive lease, before opening a partial writer.
/// The stable window/account owner keeps a queued cancellation from deleting a
/// different paused window's file, even when nobody currently holds the lock.
#[cfg(test)]
pub fn claim_partial(partial: &Path, id: &str) -> anyhow::Result<()> {
    claim_partial_for(partial, id, None, None)
}

pub fn claim_partial_as(partial: &Path, id: &str, transfer_id: &str) -> anyhow::Result<()> {
    claim_partial_for(partial, id, Some(transfer_id), None)
}

/// A restored retry may release its ancestor's reservation only while holding
/// this exact output's exclusive lease. Completion cleanup without that proof
/// retains the original conservative ownership rules.
pub fn claim_partial_as_with_lease(
    partial: &Path,
    id: &str,
    transfer_id: &str,
    lease: &std::fs::File,
) -> anyhow::Result<()> {
    claim_partial_for(partial, id, Some(transfer_id), Some(lease))
}

fn validate_claim_lease(path: &Path, lease: &std::fs::File) -> anyhow::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let expected = crate::download_fs::metadata(path)?;
    let held = lease.metadata()?;
    anyhow::ensure!(
        held.is_file() && held.dev() == expected.dev() && held.ino() == expected.ino(),
        "Download ownership lease identifies a different output"
    );
    rustix::fs::flock(lease, rustix::fs::FlockOperation::NonBlockingLockExclusive)?;
    crate::download_fs::validate_open_file(path, &lease.metadata()?)?;
    Ok(())
}

fn claim_partial_for(
    partial: &Path,
    id: &str,
    transfer_id: Option<&str>,
    lease: Option<&std::fs::File>,
) -> anyhow::Result<()> {
    use std::io::{Seek, Write};
    crate::download_fs::validate(partial)?;
    let Some(owner) = std::env::var("MYCLOUDDRIVER_TRANSFER_OWNER").ok() else {
        return Ok(());
    };
    let Some(path) = lock_path(&partial_output(partial)?)? else {
        return Ok(());
    };
    if let Some(lease) = lease {
        validate_claim_lease(&path, lease)?;
    }
    let previous = std::fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<PartialOwner>(&bytes).ok());
    let root_id = transfer_id.and_then(transfer_root);
    if partial.exists() || crate::download_transport::has_parts(partial) {
        match previous {
            Some(previous) if matches_owner(&previous, &owner, id) => {
                if transfer_id.is_some_and(|transfer_id| claim_is_live(&previous, transfer_id, root_id.as_deref(), lease.is_some())) {
                    return Err(Retry("This output belongs to another queued or paused download selection".into()).into());
                }
                if previous.transfer_id.is_none() && transfer_id.is_some()
                    && legacy_claim_is_reserved(&partial_output(partial)?, root_id.as_deref())? {
                    return Err(Retry("This legacy output is reserved by another queued or paused download selection".into()).into());
                }
            },
            None if std::env::var_os("MYCLOUDDRIVER_CLAIM_LEGACY_PARTS").is_some() => {
                if transfer_id.is_some() && legacy_claim_is_reserved(&partial_output(partial)?, root_id.as_deref())? {
                    return Err(Retry("This legacy output is reserved by another queued or paused download selection".into()).into());
                }
            },
            _ => anyhow::bail!("This partial download belongs to another transfer. Waiting for its owner to finish or cancel."),
        }
    }
    let mut file = if let Some(lease) = lease {
        validate_claim_lease(&path, lease)?;
        lease.try_clone()?
    } else {
        let descriptor = rustix::fs::openat(
            rustix::fs::CWD,
            &path,
            rustix::fs::OFlags::RDWR | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )?;
        std::fs::File::from(descriptor)
    };
    file.set_len(0)?;
    file.rewind()?;
    let output = partial_output(partial)?;
    let output = output
        .parent()
        .unwrap_or(Path::new("."))
        .canonicalize()?
        .join(output.file_name().unwrap_or_default());
    file.write_all(&serde_json::to_vec(&PartialOwner {
        owner,
        file_id: id.to_string(),
        output_path: Some(output.to_string_lossy().into_owned()),
        transfer_id: transfer_id.map(str::to_owned),
        root_id,
    })?)?;
    file.sync_data()?;
    Ok(())
}
#[cfg(test)]
pub async fn remove_owned_partial(partial: &Path, id: &str) -> anyhow::Result<()> {
    remove_owned_partial_for(partial, id, None).await
}

pub async fn remove_owned_partial_as(
    partial: &Path,
    id: &str,
    transfer_id: &str,
) -> anyhow::Result<()> {
    remove_owned_partial_for(partial, id, Some(transfer_id)).await
}

async fn remove_owned_partial_for(
    partial: &Path,
    id: &str,
    transfer_id: Option<&str>,
) -> anyhow::Result<()> {
    if let Ok(owner) = std::env::var("MYCLOUDDRIVER_TRANSFER_OWNER") {
        let Some(path) = lock_path(&partial_output(partial)?)? else {
            return Ok(());
        };
        let previous = std::fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<PartialOwner>(&bytes).ok());
        if !previous.is_some_and(|previous| {
            matches_owner(&previous, &owner, id)
                && transfer_id
                    .is_none_or(|transfer_id| previous.transfer_id.as_deref() == Some(transfer_id))
        }) {
            return Ok(());
        }
    }
    if let Some(transfer_id) = transfer_id {
        if other_output_is_live(
            &partial_output(partial)?,
            transfer_root(transfer_id).as_deref(),
        )? {
            return Ok(());
        }
    }
    let publication_partial = partial.to_owned();
    let publication_id = id.to_owned();
    let publication_control = transfer_id.unwrap_or("").to_owned();
    tokio::task::spawn_blocking(move || {
        crate::download_receipt::cancel_pending_publication(
            &publication_partial,
            &publication_id,
            &publication_control,
        )
    })
    .await
    .map_err(|error| anyhow::anyhow!("Download publication cleanup worker stopped: {error}"))??;
    remove_partial(partial).await
}

static COUNTERS: OnceLock<Mutex<HashMap<String, Arc<AtomicU64>>>> = OnceLock::new();
pub fn forget_network_counter(id: &str) {
    if let Some(counters) = COUNTERS.get() {
        counters
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(id);
    }
}
pub fn network_counter(id: &str) -> Arc<AtomicU64> {
    let mut counters = COUNTERS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    counters.entry(id.to_string()).or_default().clone()
}

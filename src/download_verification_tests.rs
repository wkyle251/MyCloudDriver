//! Synthetic keys, generated lock namespaces and loopback transfers only.
use super::*;
use std::{
    path::Path,
    sync::atomic::{AtomicU64, AtomicUsize, Ordering},
    time::Instant,
};

fn unique_key() -> Key {
    static NEXT: AtomicU64 = AtomicU64::new(0xf000_0000_0000_0000);
    Key::Drive(NEXT.fetch_add(1, Ordering::Relaxed))
}

fn overrides() -> &'static Mutex<HashMap<String, Key>> {
    static VALUES: OnceLock<Mutex<HashMap<String, Key>>> = OnceLock::new();
    VALUES.get_or_init(Default::default)
}
pub(super) fn override_key(id: &str) -> Option<Key> {
    overrides().lock().unwrap().get(id).copied()
}

pub(crate) struct TestDrive {
    id: String,
    key: Key,
}
impl TestDrive {
    pub(crate) fn new(id: &str) -> Self {
        let key = unique_key();
        assert!(overrides().lock().unwrap().insert(id.into(), key).is_none());
        Self { id: id.into(), key }
    }
    pub(crate) async fn hold(&self) -> Guard {
        acquire_key(self.key, "generated-holder").await.unwrap()
    }
    pub(crate) fn sibling(&self, id: &str) -> Self {
        assert!(overrides().lock().unwrap().insert(id.into(), self.key).is_none());
        Self { id: id.into(), key: self.key }
    }
    pub(crate) async fn hold_read(&self, bytes: u64) -> Guard {
        acquire_key_read(self.key, &self.id, Some(bytes)).await.unwrap()
    }
}
impl Drop for TestDrive {
    fn drop(&mut self) {
        overrides().lock().unwrap().remove(&self.id);
    }
}

#[tokio::test]
async fn an_older_pending_read_runs_before_new_arrivals_and_every_waiter_advances() {
    let key = unique_key();
    let owner = acquire_key(key, "generated-fifo-owner").await.unwrap();
    let older = acquire_key_read(key, "generated-fifo-older", Some(1024));
    tokio::pin!(older);
    assert!(futures_util::poll!(&mut older).is_pending(), "The older verifier must be queued first");
    let mut newcomers = Vec::new();
    for _ in 0..32 {
        newcomers.push(tokio::spawn(async move {
            let guard = acquire_key_read(key, "generated-fifo-newcomer", Some(1024)).await.unwrap();
            let step = guard.chunk(1024, "generated-fifo-newcomer").await.unwrap();
            drop(step);
        }));
    }
    drop(owner);
    let guard = tokio::time::timeout(Duration::from_secs(2), &mut older).await.unwrap().unwrap();
    assert!(newcomers.iter().all(|task| !task.is_finished()), "New arrivals must not bypass the older FIFO reader");
    drop(guard.chunk(1024, "generated-fifo-older").await.unwrap());
    drop(guard);
    for task in newcomers {
        tokio::time::timeout(Duration::from_secs(2), task).await.unwrap().unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_and_blocking_verifiers_share_one_reader_but_other_drives_keep_running() {
    let key = unique_key();
    let first = acquire_key(key, "generated-first").await.unwrap();
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let mut readers = Vec::new();
    for index in 0..12 {
        let active = active.clone();
        let peak = peak.clone();
        readers.push(tokio::spawn(async move {
            let _guard = if index % 2 == 0 {
                tokio::task::spawn_blocking(move || acquire_key_blocking(key, "generated-blocking"))
                    .await
                    .unwrap()
                    .unwrap()
            } else {
                acquire_key(key, "generated-async").await.unwrap()
            };
            let count = active.fetch_add(1, Ordering::SeqCst) + 1;
            peak.fetch_max(count, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(3)).await;
            active.fetch_sub(1, Ordering::SeqCst);
        }));
    }
    let other = tokio::time::timeout(
        Duration::from_secs(1),
        acquire_key(unique_key(), "generated-other-disk"),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        peak.load(Ordering::SeqCst),
        0,
        "waiting verifiers must not start reading"
    );
    drop(other);
    drop(first);
    for reader in readers {
        tokio::time::timeout(Duration::from_secs(3), reader)
            .await
            .unwrap()
            .unwrap();
    }
    assert_eq!(
        peak.load(Ordering::SeqCst),
        1,
        "both reader implementations must share the drive queue"
    );
}

#[tokio::test]
async fn cancelled_waiter_and_failed_owner_release_the_queue() {
    let key = unique_key();
    let first = acquire_key(key, "generated-owner").await.unwrap();
    let waiting = tokio::spawn(async move { acquire_key(key, "generated-waiter").await });
    tokio::task::yield_now().await;
    waiting.abort();
    assert!(matches!(waiting.await, Err(error) if error.is_cancelled()));
    drop(first);
    let failed = tokio::spawn(async move {
        let _guard = acquire_key(key, "generated-failure").await.unwrap();
        Err::<(), _>("generated read error")
    });
    assert!(failed.await.unwrap().is_err());
    drop(
        tokio::time::timeout(
            Duration::from_secs(1),
            acquire_key(key, "generated-recovery"),
        )
        .await
        .unwrap()
        .unwrap(),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_drive_recovery_deduplicates_shared_disks_and_avoids_opposing_copy_deadlocks() {
    let first = unique_key();
    let second = unique_key();
    let mut tasks = Vec::new();
    for index in 0..12 {
        tasks.push(tokio::task::spawn_blocking(move || {
            let keys = if index % 2 == 0 {
                vec![first, second, first]
            } else {
                vec![second, first, second]
            };
            let guards = acquire_keys_blocking(keys, "generated-two-drive-copy").unwrap();
            assert_eq!(guards.len(), 2);
            std::thread::sleep(Duration::from_millis(3));
        }));
    }
    for task in tasks {
        tokio::time::timeout(Duration::from_secs(3), task)
            .await
            .unwrap()
            .unwrap();
    }
}

#[test]
fn queued_verification_honors_pause_and_cancel_in_an_isolated_process() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "download_verification::tests::control_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated transfer-control environment"]
async fn control_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("controls.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    for (index, action) in ["pause", "cancel"].into_iter().enumerate() {
        for blocking in [false, true] {
            std::fs::write(&control, b"{}").unwrap();
            // The controls reader caches for a short interval.
            tokio::time::sleep(Duration::from_millis(150)).await;
            let key = unique_key();
            let owner = acquire_key(key, "generated-owner").await.unwrap();
            let id = format!("generated-control-{index}-{blocking}");
            let waiting_id = id.clone();
            let waiting = tokio::spawn(async move {
                if blocking {
                    tokio::task::spawn_blocking(move || acquire_key_blocking(key, &waiting_id))
                        .await
                        .unwrap()
                } else {
                    acquire_key(key, &waiting_id).await
                }
            });
            tokio::time::sleep(Duration::from_millis(50)).await;
            std::fs::write(
                &control,
                serde_json::to_vec(&serde_json::json!({"actions": {id: action}})).unwrap(),
            )
            .unwrap();
            let result = tokio::time::timeout(Duration::from_secs(2), waiting)
                .await
                .unwrap()
                .unwrap();
            let error = match result {
                Err(error) => error,
                Ok(_) => panic!("queued verification ignored control"),
            };
            if action == "pause" {
                assert!(error.is::<crate::transfer_control::Paused>());
            } else {
                assert!(error.is::<crate::transfer_control::Cancelled>());
            }
            drop(owner);
            drop(acquire_key(key, "generated-recovery").await.unwrap());
        }
    }
}

async fn wait_for(path: &Path) {
    let until = Instant::now() + Duration::from_secs(3);
    while !path.exists() {
        assert!(
            Instant::now() < until,
            "generated child did not reach its checkpoint"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn helpers_share_the_process_lock_and_a_crash_releases_it() {
    use std::io::Read;
    let directory = tempfile::tempdir().unwrap();
    let locks = directory.path().join("verification");
    std::fs::create_dir(&locks).unwrap();
    let lock = File::create(locks.join("drive-ef00000000000001")).unwrap();
    rustix::fs::flock(&lock, rustix::fs::FlockOperation::LockExclusive).unwrap();
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "download_verification::tests::process_child",
            "--ignored",
            "--nocapture",
        ])
        .env("MYCLOUDDRIVER_TRANSFER_LOCKS", directory.path())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    wait_for(&directory.path().join("started")).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        !directory.path().join("acquired").exists(),
        "another process must respect the held drive lock"
    );
    drop(lock);
    wait_for(&directory.path().join("acquired")).await;
    child.kill().unwrap();
    let status = child.wait().unwrap();
    if status.success() {
        let mut error = String::new();
        child
            .stderr
            .take()
            .unwrap()
            .read_to_string(&mut error)
            .unwrap();
        panic!("child unexpectedly exited: {error}");
    }
    let lock = File::open(locks.join("drive-ef00000000000001")).unwrap();
    assert!(
        try_process_lock(&lock).unwrap(),
        "a terminated helper must not leave a stuck drive lock"
    );
}

#[tokio::test]
#[ignore = "launched with a generated namespace by helpers_share_the_process_lock_and_a_crash_releases_it"]
async fn process_child() {
    let directory =
        std::path::PathBuf::from(std::env::var_os("MYCLOUDDRIVER_TRANSFER_LOCKS").unwrap());
    std::fs::write(directory.join("started"), b"generated").unwrap();
    let _guard = acquire_key(Key::Drive(0xef00_0000_0000_0001), "generated-child")
        .await
        .unwrap();
    std::fs::write(directory.join("acquired"), b"generated").unwrap();
    // A bounded wait makes a failed parent harmless.
    tokio::time::sleep(Duration::from_secs(10)).await;
}

#[cfg(target_os = "macos")]
#[test]
fn native_device_lookup_uses_only_metadata_for_a_generated_file() {
    let directory = tempfile::tempdir().unwrap();
    let file = File::create(directory.path().join("generated.bin")).unwrap();
    let filesystem = rustix::fs::fstatfs(&file).unwrap();
    let bsd = unsafe { std::ffi::CStr::from_ptr(filesystem.f_mntfromname.as_ptr()) }
        .to_bytes()
        .strip_prefix(b"/dev/")
        .unwrap();
    let medium = native::medium(bsd);
    assert_ne!(
        medium,
        native::Medium::Unknown,
        "the generated fixture's APFS volume must resolve to its physical device"
    );
    if medium == native::Medium::SolidState {
        assert_eq!(key_for_fd(file.as_raw_fd()), None);
    }
    assert_eq!(native::medium(b"not-a-device"), native::Medium::Unknown);
}

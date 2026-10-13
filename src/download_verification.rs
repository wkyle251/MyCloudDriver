//! Coordinate read-back verification and disk phases, never network requests.
//! Rotating disks share one reader across volumes and helper processes. Known
//! SSDs bypass the queue. Unresolved local devices fall back to a volume key.
use std::{
    collections::HashMap,
    fs::File,
    future::Future,
    os::fd::AsRawFd,
    sync::{Arc, Mutex, OnceLock, Weak},
    task::{Context, Poll, Wake, Waker},
    time::Duration,
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

#[cfg(target_os = "macos")]
#[path = "download_verification_macos.rs"]
mod native;
#[cfg(test)]
#[path = "download_verification_tests.rs"]
mod tests;
#[path = "download_disk_traffic.rs"]
mod traffic;
#[path = "download_read_admission.rs"]
mod admission;
#[path = "download_receive_admission.rs"]
mod receive_admission;
pub(crate) use admission::{Deferred, Receiving, Scope, reserved_prefetch};
pub(crate) use admission::ready_to_receive;
pub(crate) use admission::prepare_metadata;
pub(crate) use admission::release_receiving_for_read;
pub(crate) use receive_admission::{NetworkSlots, NetworkSlot};
pub(crate) use admission::ram_drainers;
pub(crate) use admission::receive_ahead_candidate;
pub(crate) use traffic::snapshot as traffic_snapshot;
pub(crate) use traffic::{buffer_payload, BufferTask};

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Key {
    Drive(u64),
    Volume(u64),
}

pub(crate) struct Guard {
    // Release the process lock before waking the next local waiter.
    _process: Option<File>,
    _permit: OwnedSemaphorePermit,
    _phase: crate::transfer_control::DiskReadPhase,
    traffic: Option<traffic::ReadTask>,
}

impl Guard {
    pub(crate) async fn chunk(&self, bytes: u64, id: &str) -> anyhow::Result<Option<traffic::ReadStep>> {
        match &self.traffic { Some(task) => task.chunk(bytes, id).await.map(Some), None => Ok(None) }
    }
    pub(crate) fn chunk_blocking(&self, bytes: u64, id: &str) -> anyhow::Result<Option<traffic::ReadStep>> {
        match &self.traffic { Some(task) => task.chunk_blocking(bytes, id).map(Some), None => Ok(None) }
    }
}
pub(crate) async fn write_async(file: &tokio::fs::File, id: &str, force: bool) -> Option<traffic::WriteStep> {
    WriteGate::new(file, id).turn(force).await
}
#[derive(Clone)]
pub(crate) struct WriteGate { traffic: Option<Arc<traffic::Traffic>>, key: Option<Key>, id: String }
impl WriteGate {
    pub(crate) fn id(&self) -> &str { &self.id }
    pub(crate) fn new(file: &tokio::fs::File, id: &str) -> Self {
        let key = key_for_file(file.as_raw_fd(), id);
        let traffic = key.map(traffic::for_key);
        if let Some(gate) = &traffic { traffic::bind_writer(id, gate); }
        Self { traffic, key, id: id.into() }
    }
    pub(crate) async fn turn(&self, force: bool) -> Option<traffic::WriteStep> {
        match &self.traffic { Some(gate) => Some(gate.clone().write(force, &self.id).await), None => None }
    }
    pub(crate) async fn compare_turn(&self, bytes: usize) -> Option<traffic::WriteStep> {
        self.turn(false).await.map(|step| step.reading(bytes as u64))
    }
    pub(crate) fn key(&self) -> Option<Key> { self.key }
    pub(crate) async fn checkpoint_turn(&self) -> Option<traffic::WriteStep> {
        match &self.traffic { Some(gate) => Some(gate.clone().checkpoint(&self.id).await), None => None }
    }
}

fn semaphore(key: Key) -> Arc<Semaphore> {
    static GATES: OnceLock<Mutex<HashMap<Key, Weak<Semaphore>>>> = OnceLock::new();
    let mut gates = GATES.get_or_init(Default::default).lock().unwrap();
    if let Some(gate) = gates.get(&key).and_then(Weak::upgrade) {
        return gate;
    }
    gates.retain(|_, gate| gate.strong_count() > 0);
    let gate = Arc::new(Semaphore::new(1));
    gates.insert(key, Arc::downgrade(&gate));
    gate
}

fn check_control(id: &str) -> anyhow::Result<()> {
    match crate::transfer_control::disk_action(id) {
        Some(crate::transfer_control::Action::Cancel) => {
            Err(crate::transfer_control::Cancelled.into())
        }
        Some(crate::transfer_control::Action::Pause) => Err(crate::transfer_control::Paused.into()),
        None => crate::download_buffer::check_early_failure(id),
    }
}

fn process_lock_file(key: Key) -> std::io::Result<File> {
    use rustix::fs::{openat, Mode, OFlags};
    use std::os::unix::fs::PermissionsExt;
    let directory = crate::transfer_control::output_lock_directory().join("verification");
    let namespace = crate::download_fs::directory(&directory, true)?;
    namespace.set_permissions(std::fs::Permissions::from_mode(0o700))?;
    let name = match key {
        Key::Drive(id) => format!("drive-{id:016x}"),
        Key::Volume(id) => format!("volume-{id:016x}"),
    };
    let file = File::from(openat(
        &namespace,
        name,
        OFlags::CREATE | OFlags::RDWR | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR,
    )?);
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other("Invalid verification lock"));
    }
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

fn try_process_lock(file: &File) -> anyhow::Result<bool> {
    match rustix::fs::flock(file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => Ok(true),
        Err(error) if error == rustix::io::Errno::WOULDBLOCK => Ok(false),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
async fn acquire_key(key: Key, id: &str) -> anyhow::Result<Guard> {
    acquire_key_read(key, id, None).await
}
async fn acquire_key_read(key: Key, id: &str, bytes: Option<u64>) -> anyhow::Result<Guard> {
    acquire_key_read_size(key, id, bytes, bytes.unwrap_or(0)).await
}
async fn acquire_key_read_size(key: Key, id: &str, bytes: Option<u64>, file_bytes: u64) -> anyhow::Result<Guard> {
    check_control(id)?;
    let bytes = bytes.filter(|bytes| *bytes > 0);
    let admitted = bytes.map(|bytes| admission::admit(key, id, bytes, file_bytes)).transpose()?.flatten();
    let phase = crate::transfer_control::DiskReadPhase::enter(id);
    let traffic = admitted.or_else(|| bytes.map(|bytes| traffic::for_key(key).register_for(bytes, id)));
    check_control(id)?;
    if let Some(task) = &traffic { task.prepare(id).await?; }
    let semaphore = semaphore(key);
    let acquire = semaphore.acquire_owned(); tokio::pin!(acquire);
    let permit = loop {
        check_control(id)?;
        tokio::select! {
            result = &mut acquire => break result?,
            _ = tokio::time::sleep(Duration::from_millis(50)) => {},
        }
    };
    // A read-only/unavailable private lock namespace must not prevent a valid
    // download. The in-process queue still provides coordination in that case.
    let process = process_lock_file(key).ok();
    if let Some(file) = &process {
        loop {
            check_control(id)?;
            if try_process_lock(file).unwrap_or(true) {
                break;
            }
            crate::transfer_control::disk_interruptible(
                id,
                tokio::time::sleep(Duration::from_millis(50)),
            )
            .await?;
        }
    }
    Ok(Guard {
        _process: process,
        _permit: permit,
        _phase: phase,
        traffic,
    })
}

struct ThreadWake(std::thread::Thread);
impl Wake for ThreadWake {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.0.unpark();
    }
}

/// The receipt reader already runs on a blocking worker. Poll the same fair
/// semaphore without creating a runtime or blocking an async worker. Periodic
/// wakes keep Pause/Cancel responsive even while another process owns the disk.
fn acquire_key_blocking(key: Key, id: &str) -> anyhow::Result<Guard> {
    acquire_key_read_blocking(key, id, None)
}
fn acquire_key_read_blocking(key: Key, id: &str, bytes: Option<u64>) -> anyhow::Result<Guard> {
    acquire_key_read_size_blocking(key, id, bytes, bytes.unwrap_or(0))
}
fn acquire_key_read_size_blocking(key: Key, id: &str, bytes: Option<u64>, file_bytes: u64) -> anyhow::Result<Guard> {
    check_control(id)?;
    let bytes = bytes.filter(|bytes| *bytes > 0);
    let admitted = bytes.map(|bytes| admission::admit(key, id, bytes, file_bytes)).transpose()?.flatten();
    let phase = crate::transfer_control::DiskReadPhase::enter(id);
    let traffic = admitted.or_else(|| bytes.map(|bytes| traffic::for_key(key).register_for(bytes, id)));
    if let Some(task) = &traffic { task.prepare_blocking(id)?; }
    let waker = Waker::from(Arc::new(ThreadWake(std::thread::current())));
    let mut context = Context::from_waker(&waker);
    let mut pending = std::pin::pin!(semaphore(key).acquire_owned());
    let permit = loop {
        check_control(id)?;
        match pending.as_mut().poll(&mut context) {
            Poll::Ready(result) => break result?,
            Poll::Pending => std::thread::park_timeout(Duration::from_millis(50)),
        }
    };
    let process = process_lock_file(key).ok();
    if let Some(file) = &process {
        loop {
            check_control(id)?;
            if try_process_lock(file).unwrap_or(true) {
                break;
            }
            std::thread::park_timeout(Duration::from_millis(50));
        }
    }
    Ok(Guard {
        _process: process,
        _permit: permit,
        _phase: phase,
        traffic,
    })
}

pub(crate) async fn acquire_async(
    file: &tokio::fs::File,
    id: &str,
    bytes: u64,
) -> anyhow::Result<Option<Guard>> {
    match key_for_file(file.as_raw_fd(), id) {
        Some(key) => acquire_key_read_size(key, id, Some(bytes), file.metadata().await?.len()).await.map(Some),
        None => Ok(None),
    }
}

pub(crate) fn acquire_blocking(file: &File, id: &str, bytes: u64) -> anyhow::Result<Option<Guard>> {
    match key_for_file(file.as_raw_fd(), id) {
        Some(key) => acquire_key_read_size_blocking(key, id, Some(bytes), file.metadata()?.len()).map(Some),
        None => Ok(None),
    }
}

fn acquire_keys_blocking(mut keys: Vec<Key>, id: &str) -> anyhow::Result<Vec<Guard>> {
    // Copy recovery can verify two drives. A stable order prevents opposing
    // copies from holding one drive while each waits for the other.
    keys.sort_unstable();
    keys.dedup();
    keys.into_iter()
        .map(|key| acquire_key_blocking(key, id))
        .collect()
}

pub(crate) fn acquire_pair_blocking(
    first: &File,
    second: &File,
    id: &str,
) -> anyhow::Result<Vec<Guard>> {
    // Recovery compares two local files. Reserve its phase before taking any
    // reader lock so a queue of copy checks cannot exhaust HTTP admission.
    let mut charges = std::collections::BTreeMap::<Key, u64>::new();
    for file in [first, second] {
        if let Some(key) = key_for_file(file.as_raw_fd(), id) {
            let bytes = file.metadata()?.len();
            let charge = charges.entry(key).or_default();
            *charge = charge.saturating_add(bytes);
        }
    }
    for (key, bytes) in charges { drop(admission::admit(key, id, bytes, bytes)?); }
    let keys = [first, second]
        .into_iter()
        .filter_map(|file| key_for_file(file.as_raw_fd(), id))
        .collect();
    acquire_keys_blocking(keys, id)
}

fn key_for_file(raw: std::os::fd::RawFd, id: &str) -> Option<Key> {
    #[cfg(test)]
    if let Some(key) = tests::override_key(id) {
        return Some(key);
    }
    let _ = id;
    key_for_fd(raw)
}

#[cfg(test)]
pub(crate) use tests::TestDrive;

#[cfg(target_os = "macos")]
fn key_for_fd(raw: std::os::fd::RawFd) -> Option<Key> {
    use std::{ffi::CStr, os::fd::BorrowedFd, time::Instant};
    type Entry = (Instant, Option<Key>);
    static DEVICES: OnceLock<Mutex<HashMap<u64, Entry>>> = OnceLock::new();
    // Borrowed only for these synchronous metadata calls; never escapes into
    // a detached task whose descriptor could be closed or reused.
    let fd = unsafe { BorrowedFd::borrow_raw(raw) };
    let device = rustix::fs::fstat(fd).ok()?.st_dev as u64;
    let cache = DEVICES.get_or_init(Default::default);
    if let Some((_, key)) = cache
        .lock()
        .unwrap()
        .get(&device)
        .filter(|(at, _)| at.elapsed() < Duration::from_secs(30))
    {
        return *key;
    }
    let filesystem = rustix::fs::fstatfs(fd).ok()?;
    let mounted = unsafe { CStr::from_ptr(filesystem.f_mntfromname.as_ptr()) }.to_bytes();
    // Network shares do not have a local drive to coordinate.
    let bsd = mounted.strip_prefix(b"/dev/")?;
    let key = match native::medium(bsd) {
        native::Medium::Rotating(id) => Some(Key::Drive(id)),
        native::Medium::SolidState => None,
        native::Medium::Unknown => Some(Key::Volume(device)),
    };
    let mut devices = cache.lock().unwrap();
    devices.retain(|_, (at, _)| at.elapsed() < Duration::from_secs(30));
    devices.insert(device, (Instant::now(), key));
    key
}

#[cfg(not(target_os = "macos"))]
fn key_for_fd(_: std::os::fd::RawFd) -> Option<Key> {
    None
}

//! One bounded socket allowance for original downloads. App helpers share
//! advisory locks; process exit releases every slot, including after a crash.
use std::{
    collections::HashMap,
    fs::File,
    io::{self, Read, Seek, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

pub const RECEIVE_WINDOW: u64 = 256 * 1024;
const RANGE_STARTUP_TTL: Duration = Duration::from_secs(60);
const RANGE_STARTUP_MAX: usize = 4;
static KNOWN_COOLDOWN_UNTIL_MS: AtomicU64 = AtomicU64::new(0);

struct RangeStartup {
    channels: usize,
    measured: Instant,
    resource_generation: u64,
}
impl RangeStartup {
    fn fresh(&self, now: Instant, resource_generation: u64) -> bool {
        self.resource_generation == resource_generation
            && now.checked_duration_since(self.measured).is_some_and(|age| age < RANGE_STARTUP_TTL)
    }
}

pub fn known_cooldown_remaining_ms() -> u64 {
    KNOWN_COOLDOWN_UNTIL_MS.load(Ordering::Relaxed).saturating_sub(Network::now_millis())
}

fn descriptor_budget(descriptors: u64) -> usize {
    // Leave room for metadata, SQLite, journals and app-control pipes. An
    // active original needs a socket, staging/checkpoint files and lock files.
    usize::try_from(descriptors.saturating_sub(128) / 8).unwrap_or(usize::MAX)
        .clamp(1, Semaphore::MAX_PERMITS)
}

fn connection_budget() -> usize {
    static BUDGET: OnceLock<usize> = OnceLock::new();
    *BUDGET.get_or_init(|| {
        use rustix::process::{getrlimit, setrlimit, Resource, Rlimit};
        let limits = getrlimit(Resource::Nofile);
        // macOS GUI helpers can inherit a small soft limit. Raising this
        // process's soft allowance never changes the system or hard limit.
        let current = limits.current.unwrap_or(10_240);
        let desired = current.max(10_240).min(limits.maximum.unwrap_or(10_240));
        if desired > current {
            let _ = setrlimit(Resource::Nofile, Rlimit { current: Some(desired), maximum: limits.maximum });
        }
        descriptor_budget(getrlimit(Resource::Nofile).current.unwrap_or(desired))
    })
}

pub struct Network {
    trials: Arc<crate::download_trials::Coordinator>,
    limit: usize,
    slots: Arc<Semaphore>,
    directory: Option<PathBuf>,
    cursor: AtomicUsize,
    bytes: Arc<AtomicU64>,
    endpoint_active: Arc<AtomicUsize>,
    participants: Arc<AtomicUsize>,
    endpoint_participants: Arc<AtomicUsize>,
    cooldown_name: String,
    soft_limit: AtomicUsize,
    soft_until: Mutex<Instant>,
    cooldown: Mutex<(Instant, Instant)>,
    // This Network is bound to one serving origin. No URL, account metadata or
    // payload identity is retained in the short-lived performance evidence.
    range_startup: Mutex<Option<RangeStartup>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_budget_reserves_resources_without_a_sixty_four_cap() {
        assert_eq!(descriptor_budget(0), 1);
        assert_eq!(descriptor_budget(128), 1);
        assert_eq!(descriptor_budget(10_240), 1_264);
        assert!(descriptor_budget(u64::MAX) <= Semaphore::MAX_PERMITS);
    }

    #[test]
    fn accepted_range_evidence_is_bounded_expires_and_does_not_refresh_on_hits() {
        let _guard = crate::download_waits::range_startup_test_guard();
        let network = Network::new(16, None);
        let now = Instant::now();
        assert_eq!(network.range_startup_limit(8, now), 1);
        network.accept_range_trial(2, now);
        assert_eq!(network.range_startup_limit(8, now + Duration::from_secs(59)), 2);
        assert_eq!(network.range_startup_limit(8, now + RANGE_STARTUP_TTL), 1);
        network.accept_range_trial(16, now);
        assert_eq!(network.range_startup_limit(8, now), 4);
        assert_eq!(network.range_startup_limit(2, now), 2);
        assert_eq!(network.range_startup_limit(1, now), 1);
        network.clear_range_startup();
        assert_eq!(network.range_startup_limit(8, now), 1);
        network.accept_range_trial(2, now);
        assert_eq!(network.range_startup_limit(8, now - Duration::from_millis(1)), 1);
    }

    #[test]
    fn range_startup_is_per_origin_and_respects_shared_fair_share() {
        let _guard = crate::download_waits::range_startup_test_guard();
        let first = Network::for_url("http://range-startup-one.invalid/generated?token=one");
        let same_origin = Network::for_url("http://range-startup-one.invalid/another?token=two");
        let second = Network::for_url("http://range-startup-two.invalid/generated");
        let now = Instant::now();
        first.accept_range_trial(4, now);
        assert_eq!(same_origin.range_startup_limit(8, now), 4);
        assert_eq!(second.range_startup_limit(8, now), 1);
        let local = Network::new(4, None);
        local.accept_range_trial(4, now);
        let a = local.register();
        assert_eq!(local.range_startup_limit(8, now), 4);
        let b = local.register();
        assert_eq!(local.range_startup_limit(8, now), 2);
        let c = local.register();
        assert_eq!(local.range_startup_limit(8, now), 1);
        drop((a, b, c));
        assert_eq!(local.range_startup_limit(8, now), 4);
        first.clear_range_startup();
    }

    #[test]
    fn ram_waits_and_memory_warnings_invalidate_warm_evidence() {
        let _guard = crate::download_waits::range_startup_test_guard();
        let network = Network::new(8, None);
        let now = Instant::now();
        network.accept_range_trial(4, now);
        let waiting = crate::download_waits::Stage::enter(crate::download_waits::Kind::RamSharedLimit);
        drop(waiting);
        assert_eq!(network.range_startup_limit(8, now), 1, "A finished RAM stall still invalidates old evidence");
        network.accept_range_trial(4, now);
        crate::download_waits::range_memory_pressure(2);
        assert_eq!(network.range_startup_limit(8, now), 1);
        network.accept_range_trial(4, now);
        crate::download_waits::range_memory_pressure(1);
        assert_eq!(network.range_startup_limit(8, now), 1, "Cannot learn during an active warning");
    }

    #[test]
    fn provider_cooldown_discards_range_startup_and_cross_helper_cooldown_stays_effective() {
        let _guard = crate::download_waits::range_startup_test_guard();
        let directory = tempfile::tempdir().unwrap();
        let first = Network::new(4, Some(directory.path().to_path_buf()));
        let second = Network::new(4, Some(directory.path().to_path_buf()));
        let missed_cooldown = Network::new(4, Some(directory.path().to_path_buf()));
        let now = Instant::now();
        first.accept_range_trial(4, now);
        second.accept_range_trial(4, now);
        missed_cooldown.accept_range_trial(4, now);
        first.defer(Duration::from_millis(120)).unwrap();
        assert_eq!(first.range_startup_limit(8, now), 1);
        // The shared cooldown observer caches its control-file read for
        // 100 ms. Advance that observer without depending on sleep jitter.
        second.cooldown.lock().unwrap().1 = Instant::now();
        assert_eq!(second.range_startup_limit(8, now), 1);
        assert!(second.try_acquire().unwrap().is_none());
        std::thread::sleep(Duration::from_millis(160));
        assert_eq!(second.range_startup_limit(8, Instant::now()), 1);
        assert_eq!(missed_cooldown.range_startup_limit(8, Instant::now()), 1);
        missed_cooldown.accept_range_trial(4, Instant::now());
        assert!(missed_cooldown.range_startup.lock().unwrap().is_none(),
            "The provider's reduced-capacity period cannot teach a warm start");
        let _permit = second.try_acquire().unwrap().unwrap();
        assert!(second.try_acquire().unwrap().is_none(), "Warm evidence must never undo provider soft capacity");
    }

    #[test]
    fn metadata_cooldown_preserves_content_capacity_and_existing_shared_reductions() {
        let full = Network::new(4, None);
        full.defer_metadata(Duration::from_millis(30)).unwrap();
        assert!(full.try_acquire().unwrap().is_none(), "Metadata must publish the origin cooldown");
        std::thread::sleep(Duration::from_millis(60));
        let permits: Vec<_> = (0..4).map(|_| full.try_acquire().unwrap().unwrap()).collect();
        assert!(full.try_acquire().unwrap().is_none());
        drop(permits);

        let directory = tempfile::tempdir().unwrap();
        let content = Network::new(4, Some(directory.path().to_owned()));
        let metadata = Network::new(4, Some(directory.path().to_owned()));
        let permits: Vec<_> = (0..4).map(|_| content.try_acquire().unwrap().unwrap()).collect();
        content.defer(Duration::from_millis(30)).unwrap();
        drop(permits);
        metadata.defer_metadata(Duration::from_millis(30)).unwrap();
        std::thread::sleep(Duration::from_millis(130));
        let first = metadata.try_acquire().unwrap().unwrap();
        let second = metadata.try_acquire().unwrap().unwrap();
        assert!(metadata.try_acquire().unwrap().is_none(), "Metadata must not erase a content-driven capacity reduction");
        drop((first, second));
    }

    #[test]
    fn more_than_sixty_four_connections_share_and_release_the_same_budget() {
        let directory = tempfile::tempdir().unwrap();
        let first = Network::new(80, Some(directory.path().to_path_buf()));
        let second = Network::new(80, Some(directory.path().to_path_buf()));
        assert_eq!(first.limit, 80);
        let mut permits = Vec::new();
        for _ in 0..65 { permits.push(first.try_acquire().unwrap().unwrap()); }
        for _ in 65..80 { permits.push(second.try_acquire().unwrap().unwrap()); }
        assert!(first.try_acquire().unwrap().is_none());
        assert!(second.try_acquire().unwrap().is_none());
        drop(permits.pop());
        assert!(second.try_acquire().unwrap().is_some());
    }

    #[test]
    fn shared_slots_release_after_a_helper_is_killed() {
        let directory = tempfile::tempdir().unwrap();
        let network = Network::new(2, Some(directory.path().to_path_buf()));
        let first = network.try_acquire().unwrap().unwrap();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "download_network::tests::connection_lock_child"])
            .env("MYCLOUD_CONNECTION_TEST_DIRECTORY", directory.path())
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let started = Instant::now();
        while !directory.path().join("ready").exists() && started.elapsed() < Duration::from_secs(5)
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        let ready = directory.path().join("ready").exists();
        let bounded = network.try_acquire().unwrap().is_none();
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(
            ready && bounded,
            "Different helpers exceeded their shared allowance"
        );
        let second = network.try_acquire().unwrap().unwrap();
        assert!(network.try_acquire().unwrap().is_none());
        drop((first, second));
        assert!(network.try_acquire().unwrap().is_some());
    }

    #[test]
    fn connection_lock_child() {
        let Some(directory) = std::env::var_os("MYCLOUD_CONNECTION_TEST_DIRECTORY") else {
            return;
        };
        let directory = PathBuf::from(directory);
        let network = Network::new(2, Some(directory.clone()));
        let _permit = network.try_acquire().unwrap().unwrap();
        std::fs::write(directory.join("ready"), b"ready").unwrap();
        std::thread::sleep(Duration::from_secs(10));
    }

    #[test]
    fn cooldown_and_reduced_capacity_are_shared_between_helpers() {
        let directory = tempfile::tempdir().unwrap();
        let first = Network::new(4, Some(directory.path().to_path_buf()));
        let second = Network::new(4, Some(directory.path().to_path_buf()));
        let a = first.try_acquire().unwrap().unwrap();
        let b = first.try_acquire().unwrap().unwrap();
        first.defer(Duration::from_millis(120)).unwrap();
        assert!(second.try_acquire().unwrap().is_none());
        drop((a, b));
        std::thread::sleep(Duration::from_millis(160));
        let _one = second.try_acquire().unwrap().unwrap();
        assert!(
            second.try_acquire().unwrap().is_none(),
            "Retry immediately restored the rejected concurrency"
        );
    }
}

struct EndpointPermit(Arc<AtomicUsize>);
impl Drop for EndpointPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
pub struct Participant(Arc<AtomicUsize>, Arc<AtomicUsize>);
impl Drop for Participant {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
        self.1.fetch_sub(1, Ordering::AcqRel);
    }
}

pub struct Permit {
    _local: OwnedSemaphorePermit,
    _shared: Option<File>,
    _endpoint: EndpointPermit,
}

impl Network {
    pub fn shared() -> Arc<Self> {
        static NETWORK: OnceLock<Arc<Network>> = OnceLock::new();
        NETWORK
            .get_or_init(|| {
                Self::new(
                    connection_budget(),
                    std::env::var_os("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS").map(PathBuf::from),
                )
            })
            .clone()
    }

    pub fn new(limit: usize, directory: Option<PathBuf>) -> Arc<Self> {
        let limit = limit.max(1).min(connection_budget());
        Arc::new(Self {
            trials: crate::download_trials::Coordinator::new(directory.clone()),
            limit,
            slots: Arc::new(Semaphore::new(limit)),
            directory,
            cursor: AtomicUsize::new(0),
            bytes: Arc::new(AtomicU64::new(0)),
            endpoint_active: Arc::new(AtomicUsize::new(0)),
            cooldown_name: "cooldown".into(),
            participants: Arc::new(AtomicUsize::new(0)),
            endpoint_participants: Arc::new(AtomicUsize::new(0)),
            soft_limit: AtomicUsize::new(limit),
            soft_until: Mutex::new(Instant::now()),
            cooldown: Mutex::new((Instant::now(), Instant::now())),
            range_startup: Mutex::new(None),
        })
    }

    /// Cooldowns apply to the serving origin. Socket and byte counters still
    /// belong to the same pool, including across independent app helpers.
    pub fn for_url(link: &str) -> Arc<Self> {
        static ROUTES: OnceLock<Mutex<HashMap<String, Arc<Network>>>> = OnceLock::new();
        let Ok(url) = reqwest::Url::parse(link) else {
            return Self::shared();
        };
        let origin = url.origin().ascii_serialization();
        let mut routes = ROUTES.get_or_init(Default::default).lock().unwrap();
        if let Some(network) = routes.get(&origin) {
            return network.clone();
        }
        if routes.len() >= 1024 {
            routes.retain(|_, network| {
                Arc::strong_count(network) > 1
                    || network.cooldown.lock().unwrap().0 > Instant::now()
                    || *network.soft_until.lock().unwrap() > Instant::now()
            });
        }
        let shared = Self::shared();
        let network = Arc::new(Self {
            trials: shared.trials.clone(),
            limit: shared.limit,
            slots: shared.slots.clone(),
            directory: shared.directory.clone(),
            cursor: AtomicUsize::new(0),
            bytes: shared.bytes.clone(),
            endpoint_active: Arc::new(AtomicUsize::new(0)),
            participants: shared.participants.clone(),
            endpoint_participants: Arc::new(AtomicUsize::new(0)),
            cooldown_name: format!(
                "origin-{}",
                hex::encode(
                    ring::digest::digest(&ring::digest::SHA256, origin.as_bytes()).as_ref()
                )
            ),
            soft_limit: AtomicUsize::new(shared.limit),
            soft_until: Mutex::new(Instant::now()),
            cooldown: Mutex::new((Instant::now(), Instant::now())),
            range_startup: Mutex::new(None),
        });
        routes.insert(origin, network.clone());
        network
    }

    pub fn limit(&self) -> usize {
        self.limit
    }
    pub fn active(&self) -> usize {
        self.endpoint_active.load(Ordering::Acquire)
    }
    pub fn register(&self) -> Participant {
        self.participants.fetch_add(1, Ordering::AcqRel);
        self.endpoint_participants.fetch_add(1, Ordering::AcqRel);
        Participant(
            self.participants.clone(),
            self.endpoint_participants.clone(),
        )
    }
    pub fn fair_share(&self) -> usize {
        (self.limit / self.participants.load(Ordering::Acquire).max(1))
            .min(
                self.soft_limit.load(Ordering::Acquire)
                    / self.endpoint_participants.load(Ordering::Acquire).max(1),
            )
            .max(1)
    }
    pub(crate) fn range_startup_limit(&self, pieces: usize, now: Instant) -> usize {
        let (generation, blocked) = crate::download_waits::range_resources();
        if blocked || self.range_provider_constrained() {
            self.clear_range_startup();
            return 1;
        }
        let available = self.fair_share().min(pieces).max(1);
        let mut startup = self.range_startup.lock().unwrap();
        if startup.as_ref().is_some_and(|evidence| !evidence.fresh(now, generation)) {
            startup.take();
        }
        startup.as_ref().map_or(1, |evidence| evidence.channels.min(available))
    }
    /// Only the range controller's accepted throughput measurement calls this.
    /// A cache hit never refreshes the evidence or raises the shared allowance.
    pub(crate) fn accept_range_trial(&self, channels: usize, now: Instant) {
        let (generation, blocked) = crate::download_waits::range_resources();
        if channels < 2 || blocked || self.range_provider_constrained() {
            self.clear_range_startup();
            return;
        }
        *self.range_startup.lock().unwrap() = Some(RangeStartup {
            channels: channels.min(RANGE_STARTUP_MAX), measured: now, resource_generation: generation,
        });
    }
    pub(crate) fn clear_range_startup(&self) {
        self.range_startup.lock().unwrap().take();
    }
    fn range_provider_constrained(&self) -> bool {
        self.cooling_down().unwrap_or(true)
            || self.soft_limit.load(Ordering::Acquire) < self.limit
    }
    pub fn received(&self) -> u64 {
        self.bytes.load(Ordering::Relaxed)
    }
    pub fn trials(&self) -> Arc<crate::download_trials::Coordinator> {
        self.trials.clone()
    }
    pub fn received_counter(&self) -> Arc<AtomicU64> {
        self.bytes.clone()
    }
    pub fn record(&self, bytes: u64) {
        self.bytes.fetch_add(bytes, Ordering::Relaxed);
    }

    fn directory(&self) -> io::Result<Option<&Path>> {
        let Some(path) = self.directory.as_deref() else {
            return Ok(None);
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(path)?;
        }
        #[cfg(not(unix))]
        std::fs::create_dir_all(path)?;
        let metadata = std::fs::symlink_metadata(path)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(io::Error::other(
                "Download connection directory is not a regular directory",
            ));
        }
        Ok(Some(path))
    }

    pub(crate) fn locked_file(
        path: &Path,
        operation: rustix::fs::FlockOperation,
    ) -> io::Result<File> {
        let descriptor = rustix::fs::openat(
            rustix::fs::CWD,
            path,
            rustix::fs::OFlags::CREATE
                | rustix::fs::OFlags::RDWR
                | rustix::fs::OFlags::NOFOLLOW
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
        )?;
        let file = File::from(descriptor);
        if !file.metadata()?.is_file() {
            return Err(io::Error::other("Invalid download connection lock"));
        }
        rustix::fs::flock(&file, operation)?;
        Ok(file)
    }

    fn read_control(file: &mut File) -> io::Result<[u64; 3]> {
        let mut bytes = [0; 24];
        file.rewind()?;
        match file.read_exact(&mut bytes) {
            Ok(()) => Ok(std::array::from_fn(|index| {
                u64::from_le_bytes(bytes[index * 8..index * 8 + 8].try_into().unwrap())
            })),
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Ok([0; 3]),
            Err(error) => Err(error),
        }
    }

    fn now_millis() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }

    fn cooling_down(&self) -> io::Result<bool> {
        let mut state = self.cooldown.lock().unwrap();
        let now = Instant::now();
        if now >= *self.soft_until.lock().unwrap() {
            self.soft_limit.store(self.limit, Ordering::Release);
        }
        if now >= state.1 {
            if let Some(directory) = self.directory()? {
                let mut file = Self::locked_file(
                    &directory.join(&self.cooldown_name),
                    rustix::fs::FlockOperation::LockShared,
                )?;
                let [until, limited_until, limit] = Self::read_control(&mut file)?;
                let millis = until.saturating_sub(Self::now_millis()).min(86_400_000);
                KNOWN_COOLDOWN_UNTIL_MS.fetch_max(Self::now_millis().saturating_add(millis), Ordering::Relaxed);
                state.0 = state.0.max(now + Duration::from_millis(millis));
                if limited_until > Self::now_millis() && (1..=self.limit as u64).contains(&limit) {
                    self.soft_limit.fetch_min(limit as usize, Ordering::AcqRel);
                    let mut expires = self.soft_until.lock().unwrap();
                    *expires = (*expires).max(
                        now + Duration::from_millis(
                            limited_until
                                .saturating_sub(Self::now_millis())
                                .min(86_430_000),
                        ),
                    );
                }
            }
            state.1 = now + Duration::from_millis(100);
        }
        Ok(now < state.0)
    }

    pub fn defer(&self, delay: Duration) -> io::Result<()> {
        self.defer_with_capacity(delay, true)
    }

    /// Metadata backoff shares the serving-origin cooldown and descriptor
    /// pool, without treating API occupancy as content throughput evidence.
    pub(crate) fn defer_metadata(&self, delay: Duration) -> io::Result<()> {
        self.defer_with_capacity(delay, false)
    }

    fn defer_with_capacity(&self, delay: Duration, reduce_capacity: bool) -> io::Result<()> {
        self.clear_range_startup();
        let delay = delay.min(Duration::from_secs(86_400));
        crate::download_waits::cooldown_requested();
        KNOWN_COOLDOWN_UNTIL_MS.fetch_max(Self::now_millis().saturating_add(delay.as_millis() as u64), Ordering::Relaxed);
        let limit = reduce_capacity.then(|| (self.endpoint_active.load(Ordering::Acquire) / 2).max(1));
        if let Some(limit) = limit {
            self.soft_limit.fetch_min(limit, Ordering::AcqRel);
            *self.soft_until.lock().unwrap() = Instant::now() + delay + Duration::from_secs(30);
        }
        {
            let mut state = self.cooldown.lock().unwrap();
            state.0 = state.0.max(Instant::now() + delay);
        }
        if let Some(directory) = self.directory()? {
            let mut file = Self::locked_file(
                &directory.join(&self.cooldown_name),
                rustix::fs::FlockOperation::LockExclusive,
            )?;
            let previous = Self::read_control(&mut file)?;
            let now = Self::now_millis();
            let until = previous[0].max(now.saturating_add(delay.as_millis() as u64));
            let (limited_until, limit) = if let Some(limit) = limit {
                let limited_until = previous[1].max(until.saturating_add(30_000));
                let limit = if previous[1] > now && previous[2] > 0 {
                    previous[2].min(limit as u64)
                } else {
                    limit as u64
                };
                (limited_until, limit)
            } else {
                // Preserve a reduction already measured by actual downloads;
                // metadata alone does not create or extend that evidence.
                (previous[1], previous[2])
            };
            file.rewind()?;
            for value in [until, limited_until, limit] {
                file.write_all(&value.to_le_bytes())?;
            }
            file.set_len(24)?;
            file.sync_data()?;
        }
        Ok(())
    }

    pub fn try_acquire(&self) -> io::Result<Option<Permit>> {
        let Ok(local) = self.slots.clone().try_acquire_owned() else {
            crate::download_waits::connection_blocked(crate::download_waits::Kind::ContentBudget);
            return Ok(None);
        };
        self.finish_acquire(local)
    }

    fn finish_acquire(&self, local: OwnedSemaphorePermit) -> io::Result<Option<Permit>> {
        Ok(self.finish_acquire_reason(local)?.ok())
    }

    fn finish_acquire_reason(&self, local: OwnedSemaphorePermit) -> io::Result<Result<Permit, crate::download_waits::Kind>> {
        use crate::download_waits::{connection_blocked, Kind};
        if self.cooling_down()? {
            connection_blocked(Kind::EndpointCooldown);
            return Ok(Err(Kind::EndpointCooldown));
        }
        if self
            .endpoint_active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < self.soft_limit.load(Ordering::Acquire)).then_some(active + 1)
            })
            .is_err()
        {
            connection_blocked(Kind::EndpointCapacity);
            return Ok(Err(Kind::EndpointCapacity));
        }
        let endpoint = EndpointPermit(self.endpoint_active.clone());
        let shared = if let Some(directory) = self.directory()? {
            let start = self.cursor.fetch_add(1, Ordering::Relaxed);
            let mut found = None;
            for offset in 0..self.limit {
                let path =
                    directory.join(format!("slot-{}", start.wrapping_add(offset) % self.limit));
                match Self::locked_file(&path, rustix::fs::FlockOperation::NonBlockingLockExclusive)
                {
                    Ok(file) => {
                        found = Some(file);
                        break;
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => return Err(error),
                }
            }
            let Some(file) = found else {
                connection_blocked(Kind::SharedContentSlots);
                return Ok(Err(Kind::SharedContentSlots));
            };
            Some(file)
        } else {
            None
        };
        Ok(Ok(Permit {
            _local: local,
            _shared: shared,
            _endpoint: endpoint,
        }))
    }

    pub async fn acquire(&self) -> io::Result<Permit> {
        use crate::download_waits::{Kind, Stage};
        let _stage = crate::download_waits::Stage::enter(crate::download_waits::Kind::ContentPermit);
        let mut waiting: Option<(Kind, Stage)> = None;
        let set_wait = |waiting: &mut Option<(Kind, Stage)>, kind| {
            if waiting.as_ref().is_none_or(|(previous, _)| *previous != kind) {
                *waiting = Some((kind, Stage::enter(kind)));
            }
        };
        loop {
            if self.cooling_down()? {
                crate::download_waits::connection_blocked(crate::download_waits::Kind::EndpointCooldown);
                set_wait(&mut waiting, Kind::EndpointCooldown);
            } else {
                // Queued starts receive local slots before a busy range loop
                // can reacquire them for its next piece.
                if self.slots.available_permits() == 0 { set_wait(&mut waiting, Kind::ContentBudget); }
                let local = self
                    .slots
                    .clone()
                    .acquire_owned()
                    .await
                    .expect("Download pool remains open");
                match self.finish_acquire_reason(local)? {
                    Ok(permit) => return Ok(permit),
                    Err(kind) => set_wait(&mut waiting, kind),
                }
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
}

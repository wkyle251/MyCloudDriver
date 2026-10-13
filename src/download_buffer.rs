//! Bounded receive-ahead for disk stalls. RAM is never durable coverage.
//! Producers own HTTP streams; consumers alone update written coverage and
//! checkpoints. Dropping a consumer aborts its producer and releases all RAM.
use crate::{DownloadProgressContext, DlError};
use pikpak::download_ranges::{Chunk, Event, State, Transfer, Error as RangeError};
use std::{sync::{Arc, Weak, Mutex, OnceLock, atomic::{AtomicU64, AtomicUsize, Ordering}}, time::{Duration, Instant}};
use tokio::sync::{mpsc, Semaphore, OwnedSemaphorePermit};

// Admission granularity is separate from I/O batch size. Charging every small
// HTTP frame as 64 KiB can exhaust an 8 GiB allowance with only 512 MiB queued.
const QUANTUM: usize = 4 * 1024;
const RESPONSE_BATCH: usize = 1024 * 1024;
const RANGE_BATCH: usize = 64 * 1024;
const GIB: usize = 1 << 30;
static USED: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
static QUEUED_BYTES: AtomicUsize = AtomicUsize::new(0);
static WAITING_RECEIVERS: AtomicUsize = AtomicUsize::new(0);
static WAIT_COUNT: AtomicU64 = AtomicU64::new(0);
static WAIT_TOTAL_MS: AtomicU64 = AtomicU64::new(0);
static WAIT_MAX_MS: AtomicU64 = AtomicU64::new(0);
static PREFETCH_BYTES: AtomicUsize = AtomicUsize::new(0);
static PREFETCH_TASKS: AtomicUsize = AtomicUsize::new(0);
static PREFETCH_DISCARDED_BYTES: AtomicU64 = AtomicU64::new(0);
static PREFETCH_FINISHED: AtomicU64 = AtomicU64::new(0);
static PREFETCH_FAILED: AtomicU64 = AtomicU64::new(0);
static PREFETCH_EMPTY_ENDS: AtomicU64 = AtomicU64::new(0);

const PREFETCH_RECEIVERS: usize = 8;
const PREFETCH_CONTEXTS: usize = 64;
struct PrefetchSlots { receivers: Arc<Semaphore>, contexts: Arc<Semaphore> }
impl PrefetchSlots {
    fn new() -> Self {
        Self { receivers: Arc::new(Semaphore::new(PREFETCH_RECEIVERS)), contexts: Arc::new(Semaphore::new(PREFETCH_CONTEXTS)) }
    }
    fn acquire(&self) -> Option<PrefetchPermit> {
        let context = self.contexts.clone().try_acquire_owned().ok()?;
        let receiver = self.receivers.clone().try_acquire_owned().ok()?;
        Some(PrefetchPermit { receiver: Some(receiver), _context: context })
    }
}
fn prefetch_slots() -> &'static PrefetchSlots {
    static SLOTS: OnceLock<PrefetchSlots> = OnceLock::new();
    SLOTS.get_or_init(PrefetchSlots::new)
}
/// HTTP capacity and retained unverified contexts have different lifetimes.
/// Payload is additionally charged to the existing shared RAM byte budget.
pub(crate) struct PrefetchPermit { receiver: Option<OwnedSemaphorePermit>, _context: OwnedSemaphorePermit }

fn prefetch_owners() -> &'static Mutex<std::collections::HashMap<Arc<str>, usize>> {
    static OWNERS: OnceLock<Mutex<std::collections::HashMap<Arc<str>, usize>>> = OnceLock::new();
    OWNERS.get_or_init(Default::default)
}
pub(crate) fn prefetching(id: &str) -> bool {
    prefetch_owners().lock().unwrap().contains_key(id)
}
pub(crate) fn prefetch_slot(read_bytes: u64, incoming_bytes: u64) -> Option<PrefetchPermit> {
    // Tiny checks finish before speculative HTTP setup can help. Keep their
    // strict check-before-request behavior and avoid needless range requests.
    // Fully received pieces may still need an EOF replay. Their few proof
    // bytes must not occupy all slots ahead of genuinely unfinished payloads.
    if read_bytes < 1 << 20 || incoming_bytes < 1 << 20 { return None; }
    let permit = crate::download_verification::reserved_prefetch()
        .or_else(reserve_prefetch);
    if permit.is_none() {
        // Only a capacity miss can benefit from another receive-ahead dispatch.
        // Once a probe gets its slot, an unsupported or changed source must
        // wait for its disk check instead of probing again every five seconds.
        crate::download_verification::receive_ahead_candidate();
    }
    permit
}
pub(crate) fn reserve_prefetch() -> Option<PrefetchPermit> {
    receive_ahead_available().then(|| prefetch_slots().acquire()).flatten()
}
pub(crate) fn receive_ahead_available() -> bool {
    let slots = prefetch_slots();
    slots.receivers.available_permits() > 0 && slots.contexts.available_permits() > 0
        && budget().current().0.saturating_sub(USED.load(Ordering::Relaxed) * QUANTUM) >= 1 << 20
}
fn early_checks() -> &'static Mutex<std::collections::HashMap<Arc<str>, Weak<Prefetch>>> {
    static CHECKS: OnceLock<Mutex<std::collections::HashMap<Arc<str>, Weak<Prefetch>>>> = OnceLock::new();
    CHECKS.get_or_init(Default::default)
}
pub(crate) fn check_early_failure(id: &str) -> anyhow::Result<()> {
    let prefetch = early_checks().lock().unwrap().get(id).and_then(Weak::upgrade);
    if let Some(prefetch) = prefetch {
        let mut state = prefetch.state.lock().unwrap();
        if !state.ready && state.bytes == 0 && !state.verification_started {
            if let Some(error) = state.failure.take() {
                pikpak::download_waits::payload_event(pikpak::download_waits::PayloadEvent::EarlyEmptyRetry);
                return Err(error.context("Early reception ended; saved data remains unchanged"));
            }
        }
    }
    Ok(())
}
pub(crate) fn verification_started(id: &str) {
    let prefetch = early_checks().lock().unwrap().get(id).and_then(Weak::upgrade);
    if let Some(prefetch) = prefetch { prefetch.state.lock().unwrap().verification_started = true; }
}
struct PrefetchState { ready: bool, bytes: usize, payload: Option<crate::download_verification::BufferTask>, permit: Option<PrefetchPermit>, drain_owner: bool,
    failure: Option<anyhow::Error>, verification_started: bool }
struct Prefetch { owner: Option<Arc<str>>, state: Mutex<PrefetchState> }
impl Prefetch {
    fn new(owner: Option<Arc<str>>, permit: PrefetchPermit) -> Arc<Self> {
        PREFETCH_TASKS.fetch_add(1, Ordering::Relaxed);
        if let Some(owner) = &owner { *prefetch_owners().lock().unwrap().entry(owner.clone()).or_default() += 1; }
        let drain_owner = owner.is_some();
        let result = Arc::new(Self { owner, state: Mutex::new(PrefetchState { ready: false, bytes: 0, payload: None, permit: Some(permit), drain_owner, failure: None, verification_started: false }) });
        if let Some(owner) = &result.owner { early_checks().lock().unwrap().insert(owner.clone(), Arc::downgrade(&result)); }
        result
    }
    fn failed(&self, error: anyhow::Error) {
        let mut state = self.state.lock().unwrap();
        if !state.ready && state.bytes == 0 { state.failure = Some(error); }
    }
    fn unmark_owner(&self) {
        if let Some(owner) = &self.owner {
            let mut owners = prefetch_owners().lock().unwrap();
            if let Some(count) = owners.get_mut(owner) { *count -= 1; if *count == 0 { owners.remove(owner); } }
        }
    }
    fn unmark(&self, owner: bool) {
        PREFETCH_TASKS.fetch_sub(1, Ordering::Relaxed);
        if owner { self.unmark_owner(); }
    }
    fn activate(&self) {
        let mut state = self.state.lock().unwrap();
        if state.ready { return; }
        state.payload = self.owner.as_ref().and_then(|owner| crate::download_verification::buffer_payload(owner, state.bytes));
        PREFETCH_BYTES.fetch_sub(state.bytes, Ordering::Relaxed);
        state.ready = true;
        state.permit.take();
        let owner = std::mem::take(&mut state.drain_owner);
        self.unmark(owner);
    }
    fn receiver_finished(&self, failed: bool) {
        let mut state = self.state.lock().unwrap();
        // The queued bytes, owner marker and context survive HTTP EOF/error.
        // Pause/Quit still finishes their prerequisite checks and disk drain.
        if let Some(permit) = &mut state.permit { permit.receiver.take(); }
        PREFETCH_FINISHED.fetch_add(1, Ordering::Relaxed);
        if failed { PREFETCH_FAILED.fetch_add(1, Ordering::Relaxed); }
        if !state.ready && state.bytes == 0 {
            PREFETCH_EMPTY_ENDS.fetch_add(1, Ordering::Relaxed);
            // An ended empty receiver has no RAM to save. Ordinary Pause
            // still runs its checks, but Quit can persist the pending check
            // instead of waiting for a large prefix with nothing to drain.
            if std::mem::take(&mut state.drain_owner) { self.unmark_owner(); }
        }
    }
    fn release(&self, bytes: usize) {
        let mut state = self.state.lock().unwrap();
        state.bytes -= bytes;
        if state.ready { if let Some(payload) = &mut state.payload { payload.release(bytes); } }
        else {
            PREFETCH_BYTES.fetch_sub(bytes, Ordering::Relaxed);
            PREFETCH_DISCARDED_BYTES.fetch_add(bytes as u64, Ordering::Relaxed);
        }
    }
}
impl Drop for Prefetch {
    fn drop(&mut self) {
        if let Some(owner) = &self.owner {
            let mut checks = early_checks().lock().unwrap();
            if checks.get(owner).is_some_and(|weak| std::ptr::eq(weak.as_ptr(), self)) { checks.remove(owner); }
        }
        let state = self.state.get_mut().unwrap();
        let (ready, owner) = (state.ready, state.drain_owner);
        if !ready { self.unmark(owner); }
    }
}
// The producer owns this guard, not the future waiting for verification.
// Aborts and channel closure release capacity through the same drop path.
struct PrefetchReceiver { prefetch: Option<Arc<Prefetch>>, failed: bool }
impl Drop for PrefetchReceiver {
    fn drop(&mut self) { if let Some(prefetch) = &self.prefetch { prefetch.receiver_finished(self.failed); } }
}

struct ReceiveWait(Instant);
impl ReceiveWait {
    fn new() -> Self {
        WAITING_RECEIVERS.fetch_add(1, Ordering::Relaxed);
        WAIT_COUNT.fetch_add(1, Ordering::Relaxed);
        Self(Instant::now())
    }
}
impl Drop for ReceiveWait {
    fn drop(&mut self) {
        WAITING_RECEIVERS.fetch_sub(1, Ordering::Relaxed);
        let ms = self.0.elapsed().as_millis().min(u64::MAX as u128) as u64;
        WAIT_TOTAL_MS.fetch_add(ms, Ordering::Relaxed);
        WAIT_MAX_MS.fetch_max(ms, Ordering::Relaxed);
    }
}
// Count only acquisitions that actually suspend, including pressure and a
// per-transfer ceiling. Cancellation drops the guard and cannot leave a
// permanently reported waiter. A ready acquisition creates no metric event.
async fn measured_ram_wait<T>(future: impl std::future::Future<Output = T>) -> T {
    let mut future = std::pin::pin!(future);
    let mut waiting = None;
    std::future::poll_fn(|context| {
        let result = future.as_mut().poll(context);
        if result.is_pending() && waiting.is_none() { waiting = Some(ReceiveWait::new()); }
        result
    }).await
}
async fn measured_stage<T>(kind: pikpak::download_waits::Kind, future: impl std::future::Future<Output = T>) -> T {
    let mut future = std::pin::pin!(future);
    let mut waiting = None;
    std::future::poll_fn(|context| {
        let result = future.as_mut().poll(context);
        if result.is_pending() && waiting.is_none() { waiting = Some(pikpak::download_waits::Stage::enter(kind)); }
        result
    }).await
}

// Identify the already-budgeted RAM chunk a disk consumer is handling. Only
// an acquired disk lease reports it as writing; waiting chunks remain pending.
tokio::task_local! { static WRITING_PAYLOAD: usize; }
pub(crate) async fn write_chunk<T>(bytes: usize, future: impl std::future::Future<Output = T>) -> T {
    WRITING_PAYLOAD.scope(bytes, future).await
}
pub(crate) fn writing_payload() -> usize { WRITING_PAYLOAD.try_with(|bytes| *bytes).unwrap_or(0) }

pub(crate) fn range_write_batch(coordinated: bool) -> usize {
    if !coordinated { return pikpak::download_network::RECEIVE_WINDOW as usize; }
    (budget().current().0 / 64).clamp(QUANTUM, 4 << 20)
}
pub(crate) fn range_write_pressure() -> bool {
    let (limit, pressure) = budget().current();
    range_write_pressure_at(limit, pressure, USED.load(Ordering::Relaxed) * QUANTUM)
}
fn range_write_pressure_at(limit: usize, pressure: u32, reserved: usize) -> bool {
    // macOS reports normal pressure as 1; only warning/critical levels
    // should force small writes before the coordinated batch is full.
    pressure >= 2 || reserved.saturating_add(RANGE_BATCH) >= limit
}

fn physical_memory() -> Option<usize> {
    #[cfg(target_os = "macos")]
    {
        use std::ffi::{c_char, c_void};
        unsafe extern "C" { fn sysctlbyname(name: *const c_char, value: *mut c_void, size: *mut usize, new: *mut c_void, new_size: usize) -> i32; }
        let mut bytes = 0u64; let mut size = std::mem::size_of::<u64>();
        if unsafe { sysctlbyname(c"hw.memsize".as_ptr(), (&mut bytes as *mut u64).cast(), &mut size, std::ptr::null_mut(), 0) } == 0 {
            return usize::try_from(bytes).ok();
        }
    }
    None
}

#[derive(Clone, Copy)]
struct Policy { limit: usize }
impl Policy {
    fn new(physical: Option<usize>, cap: Option<usize>) -> Self {
        // This is only the outer bound. Pressure starts with a small allowance
        // and grows with actual demand; physical RAM is never allocated here.
        let limit = physical.unwrap_or(64 << 20).min(cap.unwrap_or(usize::MAX));
        Self { limit: limit.max(QUANTUM) / QUANTUM * QUANTUM }
    }
    fn environment() -> Self {
        let bytes = |name| std::env::var(name).ok().and_then(|value| value.parse::<usize>().ok()).filter(|bytes| *bytes >= QUANTUM);
        Self::new(physical_memory(), bytes("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES"))
    }
}
fn memory_pressure() -> u32 {
    #[cfg(target_os = "macos")]
    {
        use std::ffi::{c_char, c_void};
        unsafe extern "C" { fn sysctlbyname(name: *const c_char, value: *mut c_void, size: *mut usize, new: *mut c_void, new_size: usize) -> i32; }
        let mut level = 0u32; let mut size = std::mem::size_of::<u32>();
        if unsafe { sysctlbyname(c"kern.memorystatus_vm_pressure_level".as_ptr(), (&mut level as *mut u32).cast(), &mut size, std::ptr::null_mut(), 0) } == 0 {
            return level;
        }
        // Missing pressure information must not authorize a multi-GiB queue.
        2
    }
    #[cfg(not(target_os = "macos"))]
    { 1 }
}
const PRESSURE_RECOVERY_HOLD: Duration = Duration::from_secs(30);
struct Pressure { next: Instant, level: u32, allowed: usize, ceiling: usize, recover_after: Instant }
impl Pressure {
    fn new(now: Instant, cap: usize) -> Self {
        Self { next: now, level: 1, allowed: cap.min(GIB), ceiling: cap, recover_after: now }
    }
    fn update(&mut self, now: Instant, level: u32, cap: usize, used: usize) {
        if level >= 2 {
            self.recover_after = now + PRESSURE_RECOVERY_HOLD;
            if self.level < 2 {
                // Learn a safer ceiling instead of immediately refilling the
                // same queue that triggered pressure. The configured maximum
                // remains unchanged, and queued data is never discarded.
                let observed = if used >= GIB { used.min(self.allowed) } else { self.allowed };
                self.ceiling = self.ceiling.min(observed.saturating_sub(GIB).max(64 << 20)).min(cap);
                self.allowed = self.allowed.min((used / 2).max(64 << 20)).min(self.ceiling);
            }
            if level >= 4 { self.allowed = self.allowed.min(16 << 20).min(cap); }
            // A warning target is fixed for this pressure episode. Repeatedly
            // halving the remaining queue makes admission chase a moving
            // target and strands every receiver until pressure disappears.
        } else if now >= self.recover_after
            && (self.allowed < cap.min(GIB) || used >= self.allowed / 2) {
            // Grow only when the current buffer needs the space. An idle
            // session cannot silently raise its allowance to all physical RAM.
            // One pressure sample per second bounds growth to 128 MiB/s.
            self.allowed = self.allowed.saturating_add(128 << 20).min(self.ceiling).min(cap);
        }
        self.level = level;
        self.allowed = self.allowed.min(cap);
    }
}
struct Budget { policy: Policy, slots: Arc<Semaphore>, pressure: Mutex<Pressure> }
impl Budget {
    fn current(&self) -> (usize, u32) {
        let mut pressure = self.pressure.lock().unwrap();
        let now = Instant::now();
        if now >= pressure.next {
            pressure.next = now + Duration::from_secs(1);
            pressure.update(now, memory_pressure(), self.policy.limit, USED.load(Ordering::Relaxed) * QUANTUM);
        }
        pikpak::download_waits::range_memory_pressure(pressure.level);
        (pressure.allowed, pressure.level)
    }
    async fn acquire(&self, quanta: usize) -> OwnedSemaphorePermit {
        let slot = measured_stage(pikpak::download_waits::Kind::RamSharedLimit,
            self.slots.clone().acquire_many_owned(quanta as u32)).await.unwrap();
        let mut pressure_wait = None;
        loop {
            let allowed = self.current().0 / QUANTUM;
            let used = USED.load(Ordering::Relaxed);
            if used.saturating_add(quanta) <= allowed {
                if USED.compare_exchange_weak(used, used + quanta, Ordering::Relaxed, Ordering::Relaxed).is_ok() { return slot; }
                // Another receiver/drop changed the counter, not the amount
                // of available RAM. Retry instead of imposing a 50 ms stall
                // on a healthy connection with gigabytes of headroom.
                continue;
            }
            pressure_wait.get_or_insert_with(|| pikpak::download_waits::Stage::enter(pikpak::download_waits::Kind::RamPressure));
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
    fn per_transfer(&self) -> usize { self.policy.limit.min(2 * GIB) / QUANTUM }
}
fn budget() -> &'static Budget {
    static BUDGET: OnceLock<Budget> = OnceLock::new();
    BUDGET.get_or_init(|| {
        let policy = Policy::environment();
        Budget { policy, slots: Arc::new(Semaphore::new(policy.limit / QUANTUM)),
            pressure: Mutex::new(Pressure::new(Instant::now(), policy.limit)) }
    })
}
pub(crate) struct Snapshot {
    pub used: usize, pub reserved: usize, pub peak: usize, pub limit: usize, pub configured: usize, pub reserve: usize, pub pressure: u32,
    pub waiting_receivers: usize, pub wait_count: u64, pub wait_total_ms: u64, pub wait_max_ms: u64,
    pub prefetch_bytes: usize, pub prefetch_tasks: usize, pub prefetch_discarded_bytes: u64,
    pub prefetch_active_slots: usize, pub prefetch_contexts: usize,
    pub prefetch_receiver_limit: usize, pub prefetch_context_limit: usize,
    pub prefetch_finished: u64, pub prefetch_failed: u64, pub prefetch_empty_ends: u64,
}
pub(crate) fn snapshot() -> Snapshot {
    let budget = budget();
    let (limit, pressure) = budget.current();
    Snapshot { used: QUEUED_BYTES.load(Ordering::Relaxed), reserved: USED.load(Ordering::Relaxed) * QUANTUM, peak: PEAK.load(Ordering::Relaxed),
        // Keep the older heartbeat field for readers upgrading independently.
        limit, configured: budget.policy.limit, reserve: 0, pressure,
        waiting_receivers: WAITING_RECEIVERS.load(Ordering::Relaxed), wait_count: WAIT_COUNT.load(Ordering::Relaxed),
        wait_total_ms: WAIT_TOTAL_MS.load(Ordering::Relaxed), wait_max_ms: WAIT_MAX_MS.load(Ordering::Relaxed),
        prefetch_bytes: PREFETCH_BYTES.load(Ordering::Relaxed), prefetch_tasks: PREFETCH_TASKS.load(Ordering::Relaxed), prefetch_discarded_bytes: PREFETCH_DISCARDED_BYTES.load(Ordering::Relaxed),
        prefetch_active_slots: PREFETCH_RECEIVERS - prefetch_slots().receivers.available_permits(),
        prefetch_contexts: PREFETCH_CONTEXTS - prefetch_slots().contexts.available_permits(),
        prefetch_receiver_limit: PREFETCH_RECEIVERS, prefetch_context_limit: PREFETCH_CONTEXTS,
        prefetch_finished: PREFETCH_FINISHED.load(Ordering::Relaxed), prefetch_failed: PREFETCH_FAILED.load(Ordering::Relaxed),
        prefetch_empty_ends: PREFETCH_EMPTY_ENDS.load(Ordering::Relaxed) }
}
struct Lease {
    _global: OwnedSemaphorePermit,
    _local: OwnedSemaphorePermit,
    bytes: usize,
    quanta: usize,
    owner: Option<Arc<str>>,
    payload: Option<crate::download_verification::BufferTask>,
    prefetch: Option<Arc<Prefetch>>, prefetched: bool,
}
impl Lease {
    async fn acquire(local: &Arc<Semaphore>, quanta: usize) -> Self {
        let (local, global) = measured_ram_wait(async {
            let local = measured_stage(pikpak::download_waits::Kind::RamBodyLimit,
                local.clone().acquire_many_owned(quanta as u32)).await.unwrap();
            let global = budget().acquire(quanta).await;
            (local, global)
        }).await;
        Self { _global: global, _local: local, bytes: 0, quanta, owner: None, payload: None, prefetch: None, prefetched: false }
    }
    fn with_owner(mut self, owner: Option<Arc<str>>) -> Self { self.owner = owner; self }
    fn with_prefetch(mut self, prefetch: Option<Arc<Prefetch>>) -> Self { self.prefetch = prefetch; self }
    fn fill(&mut self, bytes: usize) {
        let needed = bytes.div_ceil(QUANTUM).max(1);
        let unused = self.quanta.saturating_sub(needed);
        if unused > 0 {
            drop(self._global.split(unused)); drop(self._local.split(unused));
            USED.fetch_sub(unused, Ordering::Relaxed); self.quanta -= unused;
        }
        self.bytes = bytes;
        if let Some(prefetch) = &self.prefetch {
            let mut state = prefetch.state.lock().unwrap();
            if !state.ready {
                state.bytes += bytes; self.prefetched = true;
                PREFETCH_BYTES.fetch_add(bytes, Ordering::Relaxed);
            }
        }
        if !self.prefetched { self.payload = self.owner.as_ref().and_then(|owner| crate::download_verification::buffer_payload(owner, bytes)); }
        let queued = QUEUED_BYTES.fetch_add(bytes, Ordering::Relaxed) + bytes;
        PEAK.fetch_max(queued, Ordering::Relaxed);
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if self.prefetched { if let Some(prefetch) = &self.prefetch { prefetch.release(self.bytes); } }
        USED.fetch_sub(self.quanta, Ordering::Relaxed); QUEUED_BYTES.fetch_sub(self.bytes, Ordering::Relaxed);
    }
}
pub(crate) struct BufferedBytes {
    bytes: bytes::Bytes,
    _lease: Lease,
}

fn finish_batch(batch: bytes::BytesMut) -> bytes::Bytes {
    // A timed partial flush must not retain its whole 1 MiB backing allocation
    // after admission refunds the unused bytes.
    if batch.len() < batch.capacity() { bytes::Bytes::copy_from_slice(&batch) }
    else { batch.freeze() }
}
impl std::ops::Deref for BufferedBytes {
    type Target = [u8];
    fn deref(&self) -> &[u8] { &self.bytes }
}
pub(crate) struct Response {
    receiver: mpsc::Receiver<Result<BufferedBytes, DlError>>,
    task: Option<tokio::task::JoinHandle<()>>,
    receiving: Option<crate::download_verification::Receiving>,
    prefetch: Option<Arc<Prefetch>>,
}
impl Response {
    pub fn new(response: reqwest::Response, received: impl Fn(u64) + Send + 'static) -> Self {
        Self::start(response, received, None, None)
    }
    pub fn new_prefetch(response: reqwest::Response, received: impl Fn(u64) + Send + 'static, permit: PrefetchPermit) -> Self {
        Self::start(response, received, Some(permit), None)
    }
    pub fn new_in_network(response: reqwest::Response, received: impl Fn(u64) + Send + 'static,
        network: (pikpak::download_network::Participant, pikpak::download_network::Permit), permit: Option<PrefetchPermit>) -> Self {
        Self::start(response, received, permit, Some(network))
    }
    fn start(mut response: reqwest::Response, received: impl Fn(u64) + Send + 'static, permit: Option<PrefetchPermit>,
        network: Option<(pikpak::download_network::Participant, pikpak::download_network::Permit)>) -> Self {
        let receiving = crate::download_verification::Receiving::current();
        let producer = receiving.as_ref().map(|receiving| receiving.producer());
        let owner = receiving.as_ref().map(|receiving| Arc::<str>::from(receiving.id()));
        let prefetch = permit.map(|permit| Prefetch::new(owner.clone(), permit));
        let receiving_prefetch = prefetch.clone();
        let (sender, receiver) = mpsc::channel(budget().per_transfer());
        let local = Arc::new(Semaphore::new(budget().per_transfer()));
        let task = tokio::spawn(async move {
            // Endpoint/channel capacity follows the socket, not the RAM
            // consumer's verification, writes or final checkpoint.
            let _network = network;
            let _producer = producer;
            let mut prefetch_receiver = PrefetchReceiver { prefetch: prefetch.clone(), failed: false };
            let quanta = budget().per_transfer().min(RESPONSE_BATCH / QUANTUM);
            let batch_size = quanta * QUANTUM;
            let mut lease = Lease::acquire(&local, quanta).await.with_owner(owner.clone()).with_prefetch(prefetch.clone());
            let mut batch = bytes::BytesMut::new();
            let mut due = Instant::now() + Duration::from_millis(25);
            let mut shutdown = tokio::time::interval(Duration::from_millis(100));
            shutdown.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                // Coalesce small HTTP frames without waiting for a complete
                // file. A slow connection flushes its partial batch in 25 ms.
                let next = tokio::select! {
                    biased;
                    _ = shutdown.tick() => {
                        if !crate::transfer_control::pause_receiving(owner.as_deref().unwrap_or("*")) { continue; }
                        // Include an already received partial batch in the
                        // Pause/Quit drain rather than aborting its task.
                        if !batch.is_empty() {
                            lease.fill(batch.len());
                            let _ = sender.send(Ok(BufferedBytes { bytes: finish_batch(batch), _lease: lease })).await;
                        }
                        return;
                    }
                    result = response.chunk() => Some(result),
                    _ = tokio::time::sleep_until(due.into()), if !batch.is_empty() => None,
                };
                match next {
                    None => {
                        lease.fill(batch.len());
                        if sender.send(Ok(BufferedBytes { bytes: finish_batch(batch), _lease: lease })).await.is_err() { return; }
                        lease = Lease::acquire(&local, quanta).await.with_owner(owner.clone()).with_prefetch(prefetch.clone());
                        batch = bytes::BytesMut::new();
                    }
                    Some(Ok(Some(bytes))) => {
                        received(bytes.len() as u64);
                        if batch.is_empty() && bytes.len() >= batch_size {
                            // Large HTTP frames already make efficient disk
                            // batches. Retain their storage without copying.
                            for offset in (0..bytes.len()).step_by(batch_size) {
                                let bytes = bytes.slice(offset..(offset + batch_size).min(bytes.len()));
                                lease.fill(bytes.len());
                                if sender.send(Ok(BufferedBytes { bytes, _lease: lease })).await.is_err() { return; }
                                lease = Lease::acquire(&local, quanta).await.with_owner(owner.clone()).with_prefetch(prefetch.clone());
                            }
                            continue;
                        }
                        let mut offset = 0;
                        while offset < bytes.len() {
                            if batch.is_empty() { due = Instant::now() + Duration::from_millis(25); batch.reserve(batch_size); }
                            let take = (batch_size - batch.len()).min(bytes.len() - offset);
                            batch.extend_from_slice(&bytes[offset..offset + take]); offset += take;
                            if batch.len() == batch_size {
                                lease.fill(batch.len());
                                if sender.send(Ok(BufferedBytes { bytes: batch.freeze(), _lease: lease })).await.is_err() { return; }
                                lease = Lease::acquire(&local, quanta).await.with_owner(owner.clone()).with_prefetch(prefetch.clone());
                                batch = bytes::BytesMut::new();
                            }
                        }
                    }
                    Some(result) => {
                        if !batch.is_empty() {
                            lease.fill(batch.len());
                            if sender.send(Ok(BufferedBytes { bytes: finish_batch(batch), _lease: lease })).await.is_err() { return; }
                        }
                        if let Err(error) = result {
                            prefetch_receiver.failed = true;
                            pikpak::download_waits::payload_event(if error.is_timeout() { pikpak::download_waits::PayloadEvent::Timeout }
                                else { pikpak::download_waits::PayloadEvent::Connection });
                            if let Some(prefetch) = &prefetch { prefetch.failed(pikpak::download_policy::Interrupted.into()); }
                            let _ = sender.send(Err(crate::classify(error, "Download stream interrupted"))).await;
                        }
                        return;
                    }
                }
            }
        });
        Self { receiver, task: Some(task), receiving, prefetch: receiving_prefetch }
    }
    pub fn activate(&self) { if let Some(prefetch) = &self.prefetch { prefetch.activate(); } }
    pub async fn chunk(&mut self) -> Result<Option<BufferedBytes>, DlError> {
        if let Some(result) = self.receiver.recv().await { return result.map(Some); }
        if let Some(task) = self.task.take() {
            task.await.map_err(|error| DlError::Fatal(anyhow::anyhow!("Download receive task stopped: {error}")))?;
        }
        Ok(None)
    }
    pub fn stop(&mut self) {
        self.receiving.take();
        if let Some(task) = &self.task { task.abort(); }
        self.receiver.close();
        while self.receiver.try_recv().is_ok() {}
    }
}
impl Drop for Response {
    fn drop(&mut self) { self.stop(); }
}

enum RangeEvent {
    Data(Chunk, Lease),
    PieceEof(usize),
    Drained(State),
    Finished(State, Result<(), RangeError>),
}
/// A range writer keeps this charge while it still owns the payload in RAM.
/// Moving bytes into a coalescing buffer does not create free receiving space.
pub(crate) struct RetainedPayload { _lease: Lease }
pub(crate) struct Ranges {
    receiver: mpsc::Receiver<RangeEvent>,
    task: tokio::task::JoinHandle<()>,
    written: State,
    pending: Option<Lease>,
    receiving: Option<crate::download_verification::Receiving>,
    prefetch: Option<Arc<Prefetch>>,
}
impl Ranges {
    pub fn new(transfer: Transfer, received: impl Fn(u64) + Send + 'static) -> Self { Self::start(transfer, received, None) }
    pub fn new_prefetch(transfer: Transfer, received: impl Fn(u64) + Send + 'static, permit: PrefetchPermit) -> Self { Self::start(transfer, received, Some(permit)) }
    fn start(mut transfer: Transfer, received: impl Fn(u64) + Send + 'static, permit: Option<PrefetchPermit>) -> Self {
        if permit.is_some() { transfer = transfer.with_streaming_fallback(); }
        let receiving = crate::download_verification::Receiving::current();
        let producer = receiving.as_ref().map(|receiving| receiving.producer());
        let owner = receiving.as_ref().map(|receiving| Arc::<str>::from(receiving.id()));
        let prefetch = permit.map(|permit| Prefetch::new(owner.clone(), permit));
        let receiving_prefetch = prefetch.clone();
        let written = transfer.state().clone();
        let (sender, receiver) = mpsc::channel(budget().per_transfer());
        let local = Arc::new(Semaphore::new(budget().per_transfer()));
        let task = tokio::spawn(async move {
            let _producer = producer;
            let mut prefetch_receiver = PrefetchReceiver { prefetch: prefetch.clone(), failed: false };
            let quanta = budget().per_transfer().min(RANGE_BATCH / QUANTUM);
            let batch_size = quanta * QUANTUM;
            let mut shutdown = tokio::time::interval(Duration::from_millis(100));
            shutdown.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                let lease = Lease::acquire(&local, quanta).await.with_owner(owner.clone()).with_prefetch(prefetch.clone());
                let next = tokio::select! {
                    biased;
                    _ = shutdown.tick() => {
                        drop(lease);
                        if crate::transfer_control::pause_receiving(owner.as_deref().unwrap_or("*")) {
                            let _ = sender.send(RangeEvent::Drained(transfer.state().clone())).await;
                            return;
                        }
                        continue;
                    }
                    next = transfer.next_event() => next,
                };
                match next {
                    Ok(Some(Event::Data(chunk))) => {
                        received(chunk.bytes.len() as u64);
                        let mut first = Some(lease);
                        for offset in (0..chunk.bytes.len()).step_by(batch_size) {
                            let mut lease = match first.take() { Some(lease) => lease, None => Lease::acquire(&local, quanta).await.with_owner(owner.clone()).with_prefetch(prefetch.clone()) };
                            let data = Chunk { index: chunk.index, offset: chunk.offset + offset as u64,
                                // Keep a compact allocation rather than a tiny
                                // view pinning a much larger HTTP receive frame.
                                bytes: bytes::Bytes::copy_from_slice(&chunk.bytes[offset..(offset + batch_size).min(chunk.bytes.len())]) };
                            lease.fill(data.bytes.len());
                            if sender.send(RangeEvent::Data(data, lease)).await.is_err() { return; }
                        }
                        transfer.accept(&chunk);
                    }
                    Ok(Some(Event::PieceEof(index))) => {
                        drop(lease);
                        if sender.send(RangeEvent::PieceEof(index)).await.is_err() { return; }
                    }
                    Ok(Some(Event::Skipped(bytes))) => { drop(lease); received(bytes); }
                    Ok(None) => { let _ = sender.send(RangeEvent::Finished(transfer.state().clone(), Ok(()))).await; return; }
                    Err(error) => {
                        prefetch_receiver.failed = true;
                        use pikpak::download_waits::PayloadEvent;
                        let (event, early): (PayloadEvent, anyhow::Error) = match &error {
                            RangeError::Http(failure) => (PayloadEvent::Interrupted, pikpak::download_policy::HttpFailure {
                                status: failure.status, retry_after: failure.retry_after }.into()),
                            RangeError::Network(error) => (if error.is_timeout() { PayloadEvent::Timeout } else { PayloadEvent::Connection }, pikpak::download_policy::Interrupted.into()),
                            RangeError::Sequential => (PayloadEvent::RangeValidation, pikpak::download_policy::Interrupted.into()),
                            RangeError::Unavailable(_) => (PayloadEvent::Unavailable, pikpak::download_policy::ContentUnavailable.into()),
                            RangeError::Io(error) => (PayloadEvent::Io, error.raw_os_error().map(std::io::Error::from_raw_os_error)
                                .unwrap_or_else(|| std::io::Error::from(error.kind())).into()),
                            RangeError::Incomplete(_) => (PayloadEvent::Interrupted, pikpak::download_policy::Interrupted.into()),
                        };
                        pikpak::download_waits::payload_event(event);
                        if let Some(prefetch) = &prefetch { prefetch.failed(early); }
                        let _ = sender.send(RangeEvent::Finished(transfer.state().clone(), Err(error))).await; return;
                    }
                }
            }
        });
        Self { receiver, task, written, pending: None, receiving, prefetch: receiving_prefetch }
    }
    pub fn activate(&self) { if let Some(prefetch) = &self.prefetch { prefetch.activate(); } }
    pub fn state(&self) -> &State { &self.written }
    pub async fn next(&mut self) -> Result<Option<Chunk>, RangeError> {
        assert!(self.pending.is_none());
        loop {
            return match self.receiver.recv().await {
                Some(RangeEvent::Data(chunk, lease)) => { self.pending = Some(lease); Ok(Some(chunk)) }
                Some(RangeEvent::PieceEof(index)) => {
                    self.written.accept_piece_eof(index)?;
                    continue;
                }
                Some(RangeEvent::Drained(state)) => {
                    if !self.written.same_received_coverage(&state) { return Err(RangeError::Sequential); }
                    self.written = state;
                    return Err(RangeError::Incomplete(pikpak::download_policy::Interrupted));
                }
                Some(RangeEvent::Finished(state, result)) => {
                    // All data events precede this event, and only accept() can
                    // advance written coverage. Network-only bytes never enter a
                    // journal, even on Pause, Cancel or a disk-write failure.
                    if !self.written.same_received_coverage(&state) { return Err(RangeError::Sequential); }
                    self.written = state;
                    result.map(|_| None)
                }
                None => Err(RangeError::Sequential),
            }
        }
    }
    pub fn accept_retaining(&mut self, chunk: &Chunk) -> Option<RetainedPayload> {
        self.written.accept_written(chunk).expect("validated receive-ahead coverage");
        self.pending.take().map(|lease| RetainedPayload { _lease: lease })
    }
    #[cfg(test)]
    pub fn accept(&mut self, chunk: &Chunk) {
        drop(self.accept_retaining(chunk));
    }
    pub fn stop(&mut self) {
        self.receiving.take();
        self.task.abort(); self.receiver.close();
        while self.receiver.try_recv().is_ok() {}
        self.pending.take();
    }
}
impl Drop for Ranges { fn drop(&mut self) { self.stop(); } }

impl DownloadProgressContext<'_> {
    pub(crate) fn receive_counter(&self) -> impl Fn(u64) + Send + 'static {
        let transferred = self.transferred_bytes.clone();
        let batch = self.batch_received_bytes.clone();
        move |bytes| {
            transferred.fetch_add(bytes, std::sync::atomic::Ordering::Relaxed);
            if let Some(counter) = &batch { counter.fetch_add(bytes, std::sync::atomic::Ordering::Relaxed); }
        }
    }
}

#[cfg(test)]
#[path = "download_buffer_tests.rs"]
mod tests;

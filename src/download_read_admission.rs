//! Park excess verification jobs without retaining an attempt, file handle or
//! network worker. A reservation covers a verification phase (possibly several
//! piece reads), and ends when streaming into RAM starts. Final read-back must
//! acquire a new reservation after the receive queue has drained.
use super::{traffic, Key, NetworkSlot, NetworkSlots};
use std::{
    collections::{HashMap, VecDeque},
    future::Future,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
    time::{Duration, Instant},
};

const MAX_TASKS: usize = 8;
const MAX_BYTES: u64 = 1 << 30;
static DEFERRALS: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
struct State {
    next: u64,
    active: HashMap<u64, u64>,
    preparing: std::collections::HashSet<u64>,
    receiving_preparing: std::collections::HashSet<u64>,
    waiting: VecDeque<Weak<Ticket>>,
}
#[derive(Default)]
struct Pool(Mutex<State>);
struct Ticket {
    pool: Arc<Pool>,
    key: Key,
    number: u64,
    bytes: AtomicU64,
    queued: Instant,
    read: Mutex<Option<traffic::ReadTask>>,
    receive_ahead: AtomicBool,
    receive_after: Mutex<Instant>,
}
struct Lease {
    pool: Arc<Pool>,
    number: u64,
}
struct Preparation {
    pool: Arc<Pool>,
    number: u64,
    receiving: bool,
    prefetch: Option<crate::download_buffer::PrefetchPermit>,
}
impl Drop for Preparation {
    fn drop(&mut self) {
        let mut state = self.pool.0.lock().unwrap();
        if self.receiving { state.receiving_preparing.remove(&self.number); }
        else { state.preparing.remove(&self.number); }
    }
}
impl Lease {
    fn resize(&self, bytes: u64) -> bool {
        let mut state = self.pool.0.lock().unwrap();
        let other = state
            .active
            .iter()
            .filter(|(number, _)| **number != self.number)
            .fold(0u64, |sum, (_, bytes)| sum.saturating_add(*bytes));
        if state.active.len() > 1 && other.saturating_add(bytes) > MAX_BYTES {
            return false;
        }
        state.active.insert(self.number, bytes);
        true
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.pool.0.lock().unwrap().active.remove(&self.number);
    }
}
impl State {
    fn preparation_room(&self) -> bool {
        // Prepared metadata is the next verifier, not eight extra contenders
        // for the same occupied slots. Keep the pipeline full without
        // reopening/checking seven files for every admission that completes.
        self.active.len().saturating_add(self.preparing.len()) < MAX_TASKS
    }
    fn first(&mut self) -> Option<Arc<Ticket>> {
        loop {
            let front = self.waiting.front()?;
            if let Some(ticket) = front.upgrade() {
                return Some(ticket);
            }
            self.waiting.pop_front();
        }
    }
    fn fits(&self, bytes: u64) -> bool {
        // One large original must always be able to progress on its own.
        self.active.is_empty()
            || (self.active.len() < MAX_TASKS
                && self
                    .active
                    .values()
                    .fold(0u64, |a, b| a.saturating_add(*b))
                    .saturating_add(bytes)
                    <= MAX_BYTES)
    }
}
impl Pool {
    #[cfg(test)]
    fn enqueue(self: &Arc<Self>, key: Key, bytes: u64, read_bytes: u64) -> Arc<Ticket> {
        self.enqueue_for(key, bytes, read_bytes, "")
    }
    fn enqueue_for(
        self: &Arc<Self>,
        key: Key,
        bytes: u64,
        read_bytes: u64,
        id: &str,
    ) -> Arc<Ticket> {
        let read = traffic::for_key(key).register_for(read_bytes, id);
        let mut state = self.0.lock().unwrap();
        let number = state.next;
        state.next = state.next.wrapping_add(1);
        let ticket = Arc::new(Ticket {
            pool: self.clone(),
            key,
            number,
            bytes: AtomicU64::new(bytes),
            queued: Instant::now(),
            read: Mutex::new(Some(read)),
            receive_ahead: AtomicBool::new(false),
            receive_after: Mutex::new(Instant::now()),
        });
        state.waiting.push_back(Arc::downgrade(&ticket));
        ticket
    }
    fn ready(&self, ticket: &Ticket) -> bool {
        let mut state = self.0.lock().unwrap();
        (state.preparation_room()
            && state
                .first()
                .is_some_and(|first| first.number == ticket.number)
            && state.fits(ticket.bytes.load(Ordering::Relaxed)))
            || self.receive_ready(&state, ticket)
    }
    fn receive_ready(&self, state: &State, ticket: &Ticket) -> bool {
        ticket.receive_ahead.load(Ordering::Relaxed) && state.receiving_preparing.len() < MAX_TASKS
            && Instant::now() >= *ticket.receive_after.lock().unwrap()
            && crate::download_buffer::receive_ahead_available()
    }
    fn prepare_receiving(self: &Arc<Self>, ticket: &Ticket) -> Option<Preparation> {
        let mut state = self.0.lock().unwrap();
        if !self.receive_ready(&state, ticket) { return None; }
        // Eligibility is only a hint. Own the actual receiver/context before
        // metadata starts so another dispatch cannot take it during setup.
        let prefetch = crate::download_buffer::reserve_prefetch()?;
        // A missed race gets one bounded retry, not a metadata spin loop.
        *ticket.receive_after.lock().unwrap() = Instant::now() + Duration::from_secs(5);
        state.receiving_preparing.insert(ticket.number);
        pikpak::download_waits::payload_event(pikpak::download_waits::PayloadEvent::DeferredRearm);
        Some(Preparation { pool: self.clone(), number: ticket.number, receiving: true, prefetch: Some(prefetch) })
    }
    fn prepare(self: &Arc<Self>, ticket: &Ticket) -> Option<Preparation> {
        let mut state = self.0.lock().unwrap();
        if !state.preparation_room()
            || !state
                .first()
                .is_some_and(|first| first.number == ticket.number)
            || !state.fits(ticket.bytes.load(Ordering::Relaxed))
        {
            return None;
        }
        state.waiting.pop_front();
        state.preparing.insert(ticket.number);
        Some(Preparation {
            pool: self.clone(),
            number: ticket.number,
            receiving: false,
            prefetch: None,
        })
    }
    fn requeue(&self, ticket: &Arc<Ticket>) {
        let mut state = self.0.lock().unwrap();
        if state.waiting.iter().any(|weak| {
            weak.upgrade()
                .is_some_and(|other| other.number == ticket.number)
        }) {
            return;
        }
        let index = state
            .waiting
            .iter()
            .position(|weak| {
                weak.upgrade()
                    .is_some_and(|other| other.queued > ticket.queued)
            })
            .unwrap_or(state.waiting.len());
        state.waiting.insert(index, Arc::downgrade(ticket));
    }
    fn claim(self: &Arc<Self>, ticket: &Ticket) -> Option<Lease> {
        let mut state = self.0.lock().unwrap();
        let bytes = ticket.bytes.load(Ordering::Relaxed);
        let preparing = state.preparing.contains(&ticket.number);
        if (!preparing
            && !state
                .first()
                .is_some_and(|first| first.number == ticket.number))
            || !state.fits(bytes)
        {
            return None;
        }
        if preparing {
            state.preparing.remove(&ticket.number);
        } else {
            state.waiting.pop_front();
        }
        state.active.insert(ticket.number, bytes);
        crate::download_telemetry::elapsed(
            crate::download_telemetry::Kind::ReadQueueWait,
            ticket.queued.elapsed(),
        );
        Some(Lease {
            pool: self.clone(),
            number: ticket.number,
        })
    }
}
fn pools() -> &'static Mutex<HashMap<Key, Weak<Pool>>> {
    static POOLS: OnceLock<Mutex<HashMap<Key, Weak<Pool>>>> = OnceLock::new();
    POOLS.get_or_init(Default::default)
}
fn pool(key: Key) -> Arc<Pool> {
    let mut pools = pools().lock().unwrap();
    if let Some(pool) = pools.get(&key).and_then(Weak::upgrade) {
        return pool;
    }
    pools.retain(|_, pool| pool.strong_count() != 0);
    let pool = Arc::new(Pool::default());
    pools.insert(key, Arc::downgrade(&pool));
    pool
}

/// Scheduler control flow, never a failed download or a timed network retry.
#[derive(Clone)]
pub(crate) struct Deferred(Arc<Ticket>);
impl Deferred {
    pub(crate) fn ready(&self) -> bool {
        self.0.pool.ready(&self.0)
    }
}
impl std::fmt::Debug for Deferred {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DeferredVerification")
    }
}
impl std::fmt::Display for Deferred {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Verification queued while other downloads receive")
    }
}
impl std::error::Error for Deferred {}

#[derive(Default)]
struct AttemptState {
    waiting: Option<Arc<Ticket>>,
    active: HashMap<Key, Lease>,
    receivers: usize,
    producers: usize,
    parked: Option<crate::transfer_control::DiskReadPhase>,
    network_slot: Option<NetworkSlot>,
    setup_slot: Option<NetworkSlot>,
    preparing: Option<Preparation>,
    preparation: Option<crate::download_telemetry::Operation>,
    receive_ahead: bool,
}
struct Attempt {
    id: String,
    state: Mutex<AttemptState>,
    network: Option<Arc<NetworkSlots>>,
    setup: Option<Arc<NetworkSlots>>,
}
fn attempts() -> &'static Mutex<HashMap<String, Weak<Attempt>>> {
    static ATTEMPTS: OnceLock<Mutex<HashMap<String, Weak<Attempt>>>> = OnceLock::new();
    ATTEMPTS.get_or_init(Default::default)
}
tokio::task_local! { static CURRENT: Arc<Attempt>; }

/// The ID registry also makes the same policy available to receipt checks on
/// blocking workers. Task-local state identifies RAM queues without paths.
pub(crate) struct Scope {
    id: String,
    attempt: Arc<Attempt>,
}
impl Scope {
    pub(crate) fn new(id: String, waiting: Option<Deferred>) -> Self {
        Self::with_network(id, waiting, None, None)
    }
    pub(crate) fn with_network(
        id: String,
        waiting: Option<Deferred>,
        network: Option<Arc<NetworkSlots>>,
        network_slot: Option<NetworkSlot>,
    ) -> Self {
        Self::with_pools(id, waiting, network, network_slot, None, None)
    }
    pub(crate) fn with_setup(
        id: String,
        waiting: Option<Deferred>,
        network: Arc<NetworkSlots>,
        setup: Arc<NetworkSlots>,
        setup_slot: Option<NetworkSlot>,
    ) -> Self {
        Self::with_pools(id, waiting, Some(network), None, Some(setup), setup_slot)
    }
    fn with_pools(
        id: String,
        waiting: Option<Deferred>,
        network: Option<Arc<NetworkSlots>>,
        network_slot: Option<NetworkSlot>,
        setup: Option<Arc<NetworkSlots>>,
        setup_slot: Option<NetworkSlot>,
    ) -> Self {
        // Retrying a deferred verifier can first wait for metadata or an
        // output lease. That entire preparation phase is disk work, rather
        // than an HTTP receiver, even before it re-enters the read guard.
        let parked = waiting
            .as_ref()
            .map(|_| crate::transfer_control::DiskReadPhase::retain(&id));
        let mut state = AttemptState {
            waiting: waiting.map(|wait| wait.0),
            parked,
            network_slot,
            setup_slot,
            ..AttemptState::default()
        };
        // Move the FIFO head into a bounded preparation pool, without taking
        // disk byte admission. Slow metadata for one oversized file must not
        // leave an idle disk while every ready check waits behind it.
        if let Some(ticket) = &state.waiting {
            if let Some(preparing) = ticket.pool.prepare(ticket).or_else(|| ticket.pool.prepare_receiving(ticket)) {
                // A changed source/journal may no longer qualify. Only the
                // current attempt's prefetch candidate can rearm receiving.
                ticket.receive_ahead.store(false, Ordering::Relaxed);
                state.preparing = Some(preparing);
                state.preparation = Some(crate::download_telemetry::Operation::new(
                    crate::download_telemetry::Kind::ReadPreparation,
                    &id,
                ));
            }
        }
        let attempt = Arc::new(Attempt {
            id: id.clone(),
            state: Mutex::new(state),
            network,
            setup,
        });
        attempts()
            .lock()
            .unwrap()
            .insert(id.clone(), Arc::downgrade(&attempt));
        Self { id, attempt }
    }
    pub(crate) async fn run<T>(&self, future: impl Future<Output = T>) -> T {
        CURRENT.scope(self.attempt.clone(), future).await
    }
}
impl Drop for Scope {
    fn drop(&mut self) {
        prepared(&mut self.attempt.state.lock().unwrap());
        let mut attempts = attempts().lock().unwrap();
        if attempts
            .get(&self.id)
            .is_some_and(|value| value.ptr_eq(&Arc::downgrade(&self.attempt)))
        {
            attempts.remove(&self.id);
        }
    }
}

fn prepared(state: &mut AttemptState) {
    if let Some(mut operation) = state.preparation.take() {
        operation.complete();
    }
}

pub(super) fn admit(
    key: Key,
    id: &str,
    read_bytes: u64,
    file_bytes: u64,
) -> anyhow::Result<Option<traffic::ReadTask>> {
    let attempt = attempts().lock().unwrap().get(id).and_then(Weak::upgrade);
    let Some(attempt) = attempt else {
        return Ok(None);
    };
    let mut state = attempt.state.lock().unwrap();
    prepared(&mut state);
    // A live RAM consumer must finish and checkpoint, never yield its attempt.
    // Reuse admission across a multi-piece resume so it cannot restart the
    // same first piece forever when the queue is busy.
    if state.receivers != 0 {
        let read = traffic::for_key(key).register_for(read_bytes, id);
        read.admitted();
        return Ok(Some(read));
    }
    // Disk work releases its receiving slot. A later HTTP body reacquires it
    // only after verification, outside the read reservation and disk locks.
    if attempt.network.is_some() {
        state
            .parked
            .get_or_insert_with(|| crate::transfer_control::DiskReadPhase::retain(id));
        state.network_slot.take();
        state.setup_slot.take();
    }
    let waiting = state.waiting.take().filter(|ticket| ticket.key == key);
    if state.active.contains_key(&key) {
        // A dispatch reservation still owns the original traffic ticket;
        // later reads in this same admitted phase register their own work.
        let Some(ticket) = waiting else {
            return Ok(None);
        };
        let bytes = ticket
            .bytes
            .fetch_max(file_bytes.max(read_bytes), Ordering::Relaxed)
            .max(file_bytes.max(read_bytes));
        if !state.active[&key].resize(bytes) {
            // Metadata can change during preparation. Keep the same ticket
            // and queue age, but wait for enough byte admission again.
            state.active.remove(&key);
            ticket
                .pool
                .0
                .lock()
                .unwrap()
                .waiting
                .push_front(Arc::downgrade(&ticket));
            DEFERRALS.fetch_add(1, Ordering::Relaxed);
            return Err(Deferred(ticket).into());
        }
        let read = ticket.read.lock().unwrap().take();
        if let Some(task) = &read {
            task.set_expected(read_bytes);
            task.admitted();
        }
        return Ok(read);
    }
    let ticket = waiting
        .unwrap_or_else(|| pool(key).enqueue_for(key, file_bytes.max(read_bytes), read_bytes, id));
    if state.receive_ahead { ticket.receive_ahead.store(true, Ordering::Relaxed); }
    // Re-evaluate a queued file that was extended/replaced while waiting.
    ticket
        .bytes
        .fetch_max(file_bytes.max(read_bytes), Ordering::Relaxed);
    let Some(lease) = ticket.pool.claim(&ticket) else {
        state.preparing.take();
        ticket.pool.requeue(&ticket);
        DEFERRALS.fetch_add(1, Ordering::Relaxed);
        return Err(Deferred(ticket).into());
    };
    state.preparing.take();
    state.active.insert(key, lease);
    state
        .parked
        .get_or_insert_with(|| crate::transfer_control::DiskReadPhase::retain(id));
    let read = ticket.read.lock().unwrap().take();
    if let Some(task) = &read {
        task.set_expected(read_bytes);
        task.admitted();
    }
    Ok(read)
}

/// A locally validated partial with missing payload may revisit receiving
/// admission, independently of the FIFO for disk-only verification work.
pub(crate) fn receive_ahead_candidate() {
    if let Ok(attempt) = CURRENT.try_with(Clone::clone) {
        let mut state = attempt.state.lock().unwrap();
        state.receive_ahead = true;
        if let Some(ticket) = &state.waiting { ticket.receive_ahead.store(true, Ordering::Relaxed); }
    }
}

pub(crate) fn reserved_prefetch() -> Option<crate::download_buffer::PrefetchPermit> {
    CURRENT.try_with(|attempt| {
        attempt.state.lock().unwrap().preparing.as_mut()
            .and_then(|preparing| preparing.prefetch.take())
    }).ok().flatten()
}

/// This boundary precedes content probes/HTTP bodies, after saved-data checks.
/// Waiting receivers cannot exhaust verifier dispatch or hold read admission.
pub(crate) async fn ready_to_receive(id: &str) -> anyhow::Result<()> {
    let attempt = CURRENT.try_with(Clone::clone).ok();
    let Some(attempt) = attempt else {
        return Ok(());
    };
    let Some(network) = &attempt.network else {
        return Ok(());
    };
    {
        let mut state = attempt.state.lock().unwrap();
        if state.network_slot.is_some() {
            return Ok(());
        }
        prepared(&mut state);
        state.active.clear();
        state.waiting.take();
        state.preparing.take();
        state
            .parked
            .get_or_insert_with(|| crate::transfer_control::DiskReadPhase::retain(id));
    }
    let slot = pikpak::download_waits::track(
        pikpak::download_waits::Kind::ReceivingSlot,
        crate::transfer_control::interruptible(id, network.acquire()),
    )
    .await?;
    let mut state = attempt.state.lock().unwrap();
    state.network_slot = Some(slot);
    state.setup_slot.take();
    state.parked.take();
    Ok(())
}

/// Metadata has its own bounded allowance. It neither borrows a receiving
/// slot nor holds a disk byte reservation while waiting for cloud setup.
pub(crate) async fn prepare_metadata() {
    let Some(attempt) = CURRENT.try_with(Clone::clone).ok() else {
        return;
    };
    let Some(setup) = &attempt.setup else {
        return;
    };
    {
        let mut state = attempt.state.lock().unwrap();
        if state.receivers != 0 || state.producers != 0 {
            return;
        }
        state.network_slot.take();
        // Prepared verifiers already have their independent eight-task
        // allowance. Ready bodies may fill every ordinary lookahead permit;
        // they must not prevent these checks from obtaining source metadata
        // and reaching an otherwise idle disk.
        if state.setup_slot.is_some() || state.preparing.is_some() {
            return;
        }
    }
    let slot =
        pikpak::download_waits::track(pikpak::download_waits::Kind::SetupPermit, setup.acquire())
            .await;
    attempt.state.lock().unwrap().setup_slot = Some(slot);
}

pub(crate) fn release_receiving_for_read(id: &str) {
    let attempt = attempts().lock().unwrap().get(id).and_then(Weak::upgrade);
    if let Some(attempt) = attempt {
        let mut state = attempt.state.lock().unwrap();
        if state.receivers == 0 && state.producers == 0 {
            state.network_slot.take();
        }
    }
}

/// Releasing read admission at this boundary gives older waiting checks a turn
/// while this attempt receives. stop()/Drop ends the streaming phase before
/// its mandatory final read-back can be deferred safely.
pub(crate) struct Receiving(Arc<Attempt>);
impl Receiving {
    pub(crate) fn id(&self) -> &str {
        &self.0.id
    }
    pub(crate) fn current() -> Option<Self> {
        CURRENT
            .try_with(|attempt| {
                let mut state = attempt.state.lock().unwrap();
                state.active.clear();
                state.waiting.take();
                state.parked.take();
                state.receivers += 1;
                Self(attempt.clone())
            })
            .ok()
    }
    pub(crate) fn producer(&self) -> Producer {
        self.0.state.lock().unwrap().producers += 1;
        Producer(self.0.clone())
    }
}
impl Drop for Receiving {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap();
        state.receivers -= 1;
        if state.producers == 0 {
            state.network_slot.take();
            state
                .parked
                .get_or_insert_with(|| crate::transfer_control::DiskReadPhase::retain(&self.0.id));
        }
    }
}

/// The HTTP producer can finish long before the consumer drains RAM or saves
/// its checkpoint. Release its network slot at producer completion, while the
/// Receiving token continues protecting the consumer from unsafe deferral.
pub(crate) struct Producer(Arc<Attempt>);
impl Drop for Producer {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap();
        state.producers -= 1;
        if state.producers == 0 {
            state.network_slot.take();
            state
                .parked
                .get_or_insert_with(|| crate::transfer_control::DiskReadPhase::retain(&self.0.id));
        }
    }
}

pub(super) fn snapshot() -> (usize, u64, usize, u64, u64) {
    let pools: Vec<_> = pools()
        .lock()
        .unwrap()
        .values()
        .filter_map(Weak::upgrade)
        .collect();
    let (mut active, mut active_bytes, mut queued, mut queued_bytes) = (0, 0u64, 0, 0u64);
    for pool in pools {
        let state = pool.0.lock().unwrap();
        active += state.active.len();
        active_bytes = state
            .active
            .values()
            .fold(active_bytes, |sum, bytes| sum.saturating_add(*bytes));
        for ticket in state.waiting.iter().filter_map(Weak::upgrade) {
            queued += 1;
            queued_bytes = queued_bytes.saturating_add(ticket.bytes.load(Ordering::Relaxed));
        }
    }
    (
        active,
        active_bytes,
        queued,
        queued_bytes,
        DEFERRALS.load(Ordering::Relaxed),
    )
}

pub(super) fn phases() -> (usize, usize, usize) {
    let attempts: Vec<_> = attempts()
        .lock()
        .unwrap()
        .values()
        .filter_map(Weak::upgrade)
        .collect();
    let (mut receiving, mut draining, mut disk_only) = (0, 0, 0);
    for attempt in attempts {
        let state = attempt.state.lock().unwrap();
        if state.producers != 0 {
            receiving += 1;
        } else if state.receivers != 0 {
            draining += 1;
        } else if state.parked.is_some() {
            disk_only += 1;
        }
    }
    (receiving, draining, disk_only)
}

pub(crate) fn ram_drainers(ids: &std::collections::HashSet<String>) -> usize {
    // Never hold the registry while taking an attempt's state mutex.
    let attempts: Vec<_> = attempts()
        .lock()
        .unwrap()
        .iter()
        .filter(|(id, _)| ids.contains(*id))
        .filter_map(|(_, value)| value.upgrade())
        .collect();
    attempts
        .iter()
        .filter(|attempt| {
            let state = attempt.state.lock().unwrap();
            state.producers == 0 && state.receivers != 0
        })
        .count()
}

#[cfg(test)]
#[path = "download_read_admission_tests.rs"]
mod tests;

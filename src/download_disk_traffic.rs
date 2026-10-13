//! HDD write batches alternate with bounded read turns. HTTP producers never enter
//! this gate. Read clocks start after previous I/O drains. Chunk boundaries let
//! verification pause without restarting its hash or discarding RAM payload.
use super::Key;
use std::{collections::{HashMap, HashSet, VecDeque}, sync::{Arc, Mutex, OnceLock, Weak, atomic::{AtomicU64, Ordering}}, time::{Duration, Instant}};
use tokio::sync::Notify;

const READ_WRITE_THRESHOLD_PERCENT: usize = 80;
const READ_WRITE_BATCH_MIN_BYTES: usize = 64 << 20;
const READ_WRITE_MAX_WAIT: Duration = Duration::from_secs(10);
const SMALL_WRITE_MAX_WAIT: Duration = Duration::from_secs(30);
const BACKLOG_BYTES: u64 = 1 << 30;
const BACKLOG_AGE: Duration = Duration::from_secs(60);
const IDLE_HANDOFF: Duration = Duration::from_millis(50);
const RECEIVE_IDLE_HANDOFF: Duration = Duration::from_secs(5);
const WRITE_LOCALITY_BYTES: u64 = 64 << 20;
const WRITE_LOCALITY_GAP: Duration = Duration::from_millis(2);
const CHECKPOINT_MAX_WAIT: Duration = Duration::from_secs(1);
static READ_TASKS_STARTED: AtomicU64 = AtomicU64::new(0);
static READ_TASKS_FINISHED: AtomicU64 = AtomicU64::new(0);
static READ_HANDOVERS: AtomicU64 = AtomicU64::new(0);
static READ_WORK_ADDED: AtomicU64 = AtomicU64::new(0);
static READ_WORK_PROCESSED: AtomicU64 = AtomicU64::new(0);
static READ_WORK_REMOVED: AtomicU64 = AtomicU64::new(0);

struct Job { remaining: u64, queued: Instant, started: bool, ready: bool, selected: bool, active: usize, owner: Option<Arc<str>> }
#[derive(Default)]
struct WritePool { queued: u64, selected: u64, next: u64, selected_through: u64 }
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase { Write, Read }
#[derive(Clone, Copy)]
enum ReadHandover { CohortFinished = 2, ControlRequest = 4, PendingWrites = 5, ReceiveIdle = 6, WriteLatency = 7 }
fn write_threshold(limit: usize) -> usize {
    (limit as u128 * READ_WRITE_THRESHOLD_PERCENT as u128 / 100) as usize
}
fn writable_limit(limit: usize, awaiting_checks: usize) -> usize {
    limit.saturating_sub(awaiting_checks)
}
fn selected_write_counter() -> &'static Arc<AtomicU64> {
    static COUNTER: OnceLock<Arc<AtomicU64>> = OnceLock::new();
    COUNTER.get_or_init(|| Arc::new(AtomicU64::new(0)))
}
struct State {
    jobs: HashMap<u64, Job>, order: VecDeque<u64>, next: u64, remaining: u64,
    phase: Phase, requested: Instant, since: Option<Instant>, last_io: Instant, last_received: Instant,
    readers: usize, waiting_readers: usize, runnable_jobs: usize,
    writers: usize, writing_bytes: u64, replay_readers: usize, replay_read_bytes: u64, next_writer: u64, write_queue: VecDeque<u64>,
    selected_write_counter: Arc<AtomicU64>, read_turns: u64, write_turns: u64,
    selected_owners: HashSet<Arc<str>>,
    write_pools: HashMap<Arc<str>, WritePool>, write_selection_started: bool,
    write_owners: HashMap<u64, Arc<str>>, preferred_writer: Option<Arc<str>>, preferred_bytes: u64,
    write_wakes: HashMap<u64, Arc<Notify>>,
    checkpoints: HashMap<u64, Instant>,
    write_dispatch_polls: u64,
    read_turn_timeouts: u64, read_turn_finishes: u64, read_turn_pressure_handoffs: u64, read_turn_control_handoffs: u64,
    last_read_handover_sequence: u64, last_read_handover_reason: u8, last_read_turn_ms: u64, last_read_remaining_bytes: u64,
    read_turn_write_handoffs: u64, read_turn_idle_handoffs: u64, observed_pending_write_bytes: u64, observed_buffer_limit_bytes: u64,
    read_turn_latency_handoffs: u64,
    last_read_pending_write_bytes: u64, last_read_buffer_limit_bytes: u64,
}
impl State {
    fn new(now: Instant) -> Self {
        Self { jobs: HashMap::new(), order: VecDeque::new(), next: 0, remaining: 0,
            phase: Phase::Write, requested: now, since: None, last_io: now, last_received: now,
            readers: 0, waiting_readers: 0, runnable_jobs: 0,
            writers: 0, writing_bytes: 0, replay_readers: 0, replay_read_bytes: 0, next_writer: 0, write_queue: VecDeque::new(),
            selected_write_counter: Arc::new(AtomicU64::new(0)), read_turns: 0, write_turns: 0, selected_owners: HashSet::new(),
            write_pools: HashMap::new(), write_selection_started: false,
            write_owners: HashMap::new(), preferred_writer: None, preferred_bytes: 0, write_wakes: HashMap::new(), checkpoints: HashMap::new(), write_dispatch_polls: 0,
            read_turn_timeouts: 0, read_turn_finishes: 0, read_turn_pressure_handoffs: 0, read_turn_control_handoffs: 0,
            last_read_handover_sequence: 0, last_read_handover_reason: 0, last_read_turn_ms: 0, last_read_remaining_bytes: 0,
            read_turn_write_handoffs: 0, read_turn_idle_handoffs: 0, observed_pending_write_bytes: 0, observed_buffer_limit_bytes: 0,
            read_turn_latency_handoffs: 0,
            last_read_pending_write_bytes: 0, last_read_buffer_limit_bytes: 0 }
    }
    fn prune(&mut self) {
        while self.order.front().is_some_and(|id| !self.jobs.contains_key(id)) { self.order.pop_front(); }
        if self.order.len() > self.jobs.len().saturating_mul(2).saturating_add(64) {
            self.order.retain(|id| self.jobs.contains_key(id));
        }
    }
    fn backlog(&mut self, now: Instant) -> bool {
        self.prune();
        self.remaining >= BACKLOG_BYTES || self.order.front().and_then(|id| self.jobs.get(id))
            .is_some_and(|job| now.saturating_duration_since(job.queued) >= BACKLOG_AGE)
    }
    fn select(&mut self, phase: Phase, now: Instant) {
        if self.phase != phase {
            self.phase = phase; self.requested = now; self.since = None;
            self.preferred_writer = None; self.preferred_bytes = 0;
            self.select_reads(phase == Phase::Read);
            if phase == Phase::Write { self.select_writes(); }
            else {
                self.write_selection_started = false;
                self.selected_write_counter.fetch_sub(self.selected_writes(), Ordering::Relaxed);
                for pool in self.write_pools.values_mut() { pool.selected = 0; }
                // Elapsed time is diagnostic only. Preparation gaps retain
                // the selected cohort until RAM needs a write turn.
                if self.writers == 0 { self.start(now); }
            }
        }
    }
    fn select_reads(&mut self, reading: bool) {
        self.selected_owners.clear();
        for job in self.jobs.values_mut() {
            job.selected = reading && job.remaining > 0;
            if job.selected { if let Some(owner) = &job.owner { self.selected_owners.insert(owner.clone()); } }
        }
    }
    fn select_writes(&mut self) {
        let previous = self.selected_writes();
        for pool in self.write_pools.values_mut() {
            pool.selected = pool.queued; pool.selected_through = pool.next;
        }
        self.selected_write_counter.fetch_add(self.selected_writes() - previous, Ordering::Relaxed);
        self.write_selection_started = true;
    }
    fn selected_writes(&self) -> u64 {
        self.write_pools.values().fold(0u64, |sum, pool| sum.saturating_add(pool.selected))
    }
    fn writer_eligible(&self, number: u64) -> bool {
        if self.checkpoints.contains_key(&number) { return true; }
        self.write_owners.get(&number).and_then(|owner| self.write_pools.get(owner))
            .is_none_or(|pool| pool.selected > 0 || pool.queued == 0)
    }
    fn next_write(&mut self, now: Instant) -> Option<u64> {
        // Payloads go first, but a shared checkpoint batch cannot wait forever
        // for a busy disk. One batch replaces hundreds of individual flushes.
        if let Some(number) = self.write_queue.iter().copied().find(|number|
            self.checkpoints.get(number).is_some_and(|queued| now.saturating_duration_since(*queued) >= CHECKPOINT_MAX_WAIT)) {
            self.preferred_writer = None; self.preferred_bytes = 0;
            return Some(number);
        }
        // Keep a short run on the same output rather than seeking between
        // dozens of files every 256 KiB. FIFO resumes after 64 MiB or an empty
        // producer; the entire selected batch drains before reads take over.
        if let Some(owner) = &self.preferred_writer {
            if self.preferred_bytes < WRITE_LOCALITY_BYTES
                && self.write_pools.get(owner).is_some_and(|pool| pool.selected > 0) {
                if let Some(number) = self.write_queue.iter().copied().find(|number|
                    !self.checkpoints.contains_key(number) && self.write_owners.get(number) == Some(owner) && self.writer_eligible(*number)) { return Some(number); }
                if now.saturating_duration_since(self.last_io) < WRITE_LOCALITY_GAP { return None; }
            }
        }
        self.preferred_writer = None; self.preferred_bytes = 0;
        self.write_queue.iter().copied().find(|number| !self.checkpoints.contains_key(number) && self.writer_eligible(*number))
            .or_else(|| self.write_queue.iter().copied().find(|number| self.writer_eligible(*number)))
    }
    fn coordinator(&mut self, now: Instant) -> Option<u64> {
        if self.writers != 0 { return None; }
        if self.phase == Phase::Write && self.readers == 0 {
            self.next_write(now).or_else(|| self.write_queue.front().copied())
        } else { self.write_queue.front().copied() }
    }
    fn start(&mut self, now: Instant) {
        if self.since.is_none() {
            self.since = Some(now);
            match self.phase { Phase::Read => self.read_turns += 1, Phase::Write => self.write_turns += 1 }
        }
    }
    fn tick(&mut self, now: Instant, pending_write: usize, limit: usize) {
        self.observed_pending_write_bytes = pending_write as u64;
        self.observed_buffer_limit_bytes = limit as u64;
        let reading = self.readers > 0 || self.waiting_readers > 0 || self.runnable_jobs > 0;
        let selected = self.jobs.values().any(|job| job.selected && job.remaining > 0);
        if self.phase == Phase::Write && !self.write_selection_started { self.select_writes(); }
        let writing = self.writers > 0 || !self.write_queue.is_empty();
        // Do not mistake the tiny gap between a consumer's chunks for an
        // empty RAM queue. Selected reads keep their turn during preparation
        // gaps while receiving flows. If receiving stops below the threshold,
        // waiting RAM consumers/checkpoints must still get a chance to drain.
        let cohort_empty = !self.write_pools.is_empty() && self.selected_writes() == 0;
        let payload_waiting = self.write_queue.iter().any(|number| !self.checkpoints.contains_key(number));
        let write_empty = self.selected_writes() == 0 && (!payload_waiting || (cohort_empty && self.writers == 0)) && self.writers == 0 && (pending_write == 0 || self.since.is_none()
            || now.saturating_duration_since(self.last_io) >= IDLE_HANDOFF);
        let read_empty = !selected && self.readers == 0 && (self.since.is_none()
            || now.saturating_duration_since(self.last_io) >= IDLE_HANDOFF);
        match self.phase {
            Phase::Read if pending_write > write_threshold(limit) => self.finish_read(now, ReadHandover::PendingWrites),
            Phase::Read if !self.write_queue.is_empty()
                && now.saturating_duration_since(self.last_received.max(self.since.unwrap_or(self.requested))) >= RECEIVE_IDLE_HANDOFF
                => self.finish_read(now, ReadHandover::ReceiveIdle),
            // With large RAM allowances the pressure threshold can be many
            // GiB away. Batch useful writes after ten seconds of reading,
            // even when cloud reception keeps the idle handoff from firing.
            Phase::Read if self.write_wait_target(pending_write).is_some_and(|target|
                now.saturating_duration_since(self.since.unwrap_or(self.requested)) >= target)
                => self.finish_read(now, ReadHandover::WriteLatency),
            // New checks can fill an emptied cohort without an unnecessary
            // write turn below the threshold. With no reads left, drain even
            // a small RAM tail and recovery checkpoints instead of stranding it.
            Phase::Read if read_empty && self.remaining > 0 => self.select_reads(true),
            Phase::Read if read_empty => self.finish_read(now, ReadHandover::CohortFinished),
            // A write batch has no deadline, even with an old verification
            // backlog. New receiving remains pending and cannot enlarge it.
            Phase::Write if reading && write_empty => self.select(Phase::Read, now),
            _ => {}
        }
        // With no runnable reader, receive arrivals can drain immediately;
        // otherwise a completed writing cohort yields to the read turn.
        if self.phase == Phase::Write && !reading && self.writers == 0 && self.selected_writes() == 0 {
            self.select_writes();
        }
        if !reading && !writing && pending_write == 0 && !selected { self.since = None; self.requested = now; }
    }
    fn finish_read(&mut self, now: Instant, reason: ReadHandover) {
        self.last_read_handover_sequence = READ_HANDOVERS.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        self.last_read_handover_reason = reason as u8;
        self.last_read_turn_ms = self.since.map_or(0, |since| now.saturating_duration_since(since).as_millis().min(u64::MAX as u128) as u64);
        self.last_read_remaining_bytes = self.jobs.values().filter(|job| job.selected)
            .fold(0u64, |sum, job| sum.saturating_add(job.remaining));
        self.last_read_pending_write_bytes = self.observed_pending_write_bytes;
        self.last_read_buffer_limit_bytes = self.observed_buffer_limit_bytes;
        match reason {
            ReadHandover::CohortFinished => self.read_turn_finishes += 1,
            ReadHandover::ControlRequest => self.read_turn_control_handoffs += 1,
            ReadHandover::PendingWrites => self.read_turn_write_handoffs += 1,
            ReadHandover::ReceiveIdle => self.read_turn_idle_handoffs += 1,
            ReadHandover::WriteLatency => self.read_turn_latency_handoffs += 1,
        }
        self.select(Phase::Write, now);
    }
    fn force_write(&mut self, now: Instant) {
        if self.phase == Phase::Read { self.finish_read(now, ReadHandover::ControlRequest); }
    }
    fn write_wait_target(&self, pending_write: usize) -> Option<Duration> {
        if self.write_queue.is_empty() { None }
        else if pending_write >= READ_WRITE_BATCH_MIN_BYTES || !self.checkpoints.is_empty() { Some(READ_WRITE_MAX_WAIT) }
        else if pending_write > 0 { Some(SMALL_WRITE_MAX_WAIT) }
        else { None }
    }
}
impl Drop for State {
    fn drop(&mut self) { self.selected_write_counter.fetch_sub(self.selected_writes(), Ordering::Relaxed); }
}

pub(super) struct Traffic { state: Mutex<State>, changed: Notify }
impl Traffic {
    fn new() -> Self {
        let mut state = State::new(Instant::now()); state.selected_write_counter = selected_write_counter().clone();
        Self { state: Mutex::new(state), changed: Notify::new() }
    }
    fn changed(&self) {
        let (writer, reading) = {
            // A wakeup is not an admission or a clock tick. Advancing the
            // phase here can empty a cohort between one file's piece checks.
            let mut state = self.state.lock().unwrap();
            let now = Instant::now();
            // Exactly one waiter maintains the idle/locality/control clock.
            // An active disk operation wakes its successor on completion.
            let next = state.coordinator(now);
            (next.and_then(|number| state.write_wakes.get(&number).cloned()), state.phase == Phase::Read && state.writers == 0)
        };
        if let Some(writer) = writer { writer.notify_one(); }
        if reading { self.changed.notify_waiters(); }
    }
}
fn gates() -> &'static Mutex<HashMap<Key, Weak<Traffic>>> {
    static GATES: OnceLock<Mutex<HashMap<Key, Weak<Traffic>>>> = OnceLock::new();
    GATES.get_or_init(Default::default)
}
fn bindings() -> &'static Mutex<HashMap<Arc<str>, Weak<Traffic>>> {
    static BINDINGS: OnceLock<Mutex<HashMap<Arc<str>, Weak<Traffic>>>> = OnceLock::new();
    BINDINGS.get_or_init(Default::default)
}
pub(super) fn bind_writer(id: &str, gate: &Arc<Traffic>) {
    if id.is_empty() { return; }
    let mut bindings = bindings().lock().unwrap();
    bindings.retain(|_, gate| gate.strong_count() > 0);
    bindings.insert(Arc::from(id), Arc::downgrade(gate));
}
pub(crate) struct BufferTask { traffic: Arc<Traffic>, owner: Arc<str>, sequence: u64, bytes: u64 }
impl BufferTask {
    pub(crate) fn release(&mut self, bytes: usize) {
        let bytes = (bytes as u64).min(self.bytes);
        let mut state = self.traffic.state.lock().unwrap();
        let counter = state.selected_write_counter.clone();
        if let Some(pool) = state.write_pools.get_mut(&self.owner) {
            pool.queued = pool.queued.saturating_sub(bytes);
            if self.sequence <= pool.selected_through {
                let removed = bytes.min(pool.selected); pool.selected -= removed;
                counter.fetch_sub(removed, Ordering::Relaxed);
            }
            if pool.queued == 0 { state.write_pools.remove(&self.owner); }
        }
        self.bytes -= bytes;
        drop(state); self.traffic.changed();
    }
}
pub(crate) fn buffer_payload(owner: &Arc<str>, bytes: usize) -> Option<BufferTask> {
    let gate = bindings().lock().unwrap().get(owner).and_then(Weak::upgrade)?;
    Some(gate.buffer(owner.clone(), bytes as u64))
}
impl Traffic {
    fn buffer(self: &Arc<Self>, owner: Arc<str>, bytes: u64) -> BufferTask {
        let mut state = self.state.lock().unwrap();
        if bytes > 0 { state.last_received = Instant::now(); }
        let pool = state.write_pools.entry(owner.clone()).or_default();
        pool.next = pool.next.wrapping_add(1); pool.queued = pool.queued.saturating_add(bytes);
        let sequence = pool.next;
        BufferTask { traffic: self.clone(), owner, sequence, bytes }
    }
}
impl Drop for BufferTask {
    fn drop(&mut self) {
        let mut state = self.traffic.state.lock().unwrap();
        let counter = state.selected_write_counter.clone();
        let mut changed = false;
        if let Some(pool) = state.write_pools.get_mut(&self.owner) {
            pool.queued = pool.queued.saturating_sub(self.bytes);
            if self.sequence <= pool.selected_through {
                let removed = self.bytes.min(pool.selected); pool.selected -= removed;
                counter.fetch_sub(removed, Ordering::Relaxed);
            }
            changed = pool.selected == 0;
            if pool.queued == 0 { state.write_pools.remove(&self.owner); }
        }
        drop(state); if changed { self.traffic.changed(); }
    }
}
pub(super) fn for_key(key: Key) -> Arc<Traffic> {
    let mut gates = gates().lock().unwrap();
    if let Some(gate) = gates.get(&key).and_then(Weak::upgrade) { return gate; }
    gates.retain(|_, gate| gate.strong_count() > 0);
    let gate = Arc::new(Traffic::new()); gates.insert(key, Arc::downgrade(&gate)); gate
}
fn tick(state: &mut State) {
    let buffer = crate::download_buffer::snapshot();
    // Receive-ahead awaiting verification cannot be written yet. Switching
    // away from its prerequisite reads would deadlock a full RAM queue.
    let pending = (buffer.used.saturating_sub(buffer.prefetch_bytes) as u64)
        .saturating_sub(selected_write_counter().load(Ordering::Relaxed));
    state.tick(Instant::now(), pending.min(usize::MAX as u64) as usize, writable_limit(buffer.limit, buffer.prefetch_bytes));
}
impl Traffic {
    #[cfg(test)]
    pub(super) fn register(self: &Arc<Self>, bytes: u64) -> ReadTask {
        self.register_inner(bytes, None)
    }
    pub(super) fn register_for(self: &Arc<Self>, bytes: u64, id: &str) -> ReadTask {
        self.register_inner(bytes, (!id.is_empty()).then(|| Arc::from(id)))
    }
    fn register_inner(self: &Arc<Self>, bytes: u64, owner: Option<Arc<str>>) -> ReadTask {
        let mut state = self.state.lock().unwrap();
        let id = state.next; state.next = state.next.wrapping_add(1);
        state.remaining = state.remaining.saturating_add(bytes);
        READ_WORK_ADDED.fetch_add(bytes, Ordering::Relaxed);
        state.order.push_back(id);
        // Multiple piece checks/final verification are continuations of one
        // selected file, rather than newly arriving files for the next turn.
        let selected = state.phase == Phase::Read && owner.as_ref().is_some_and(|owner| state.selected_owners.contains(owner));
        state.jobs.insert(id, Job { remaining: bytes, queued: Instant::now(), started: false, ready: false, selected, active: 0, owner });
        ReadTask { traffic: self.clone(), id }
    }
    pub(super) async fn write(self: Arc<Self>, force: bool, id: &str) -> WriteStep {
        self.write_kind(force, id, false).await
    }
    pub(super) async fn checkpoint(self: Arc<Self>, id: &str) -> WriteStep {
        self.write_kind(false, id, true).await
    }
    async fn write_kind(self: Arc<Self>, force: bool, id: &str, checkpoint: bool) -> WriteStep {
        let wake = Arc::new(Notify::new());
        let number = {
            let mut state = self.state.lock().unwrap();
            let number = state.next_writer; state.next_writer = state.next_writer.wrapping_add(1);
            state.write_queue.push_back(number); state.write_owners.insert(number, Arc::from(id));
            state.write_wakes.insert(number, wake.clone());
            if checkpoint { state.checkpoints.insert(number, Instant::now()); }
            number
        };
        let _waiting = WriteWait { traffic: self.clone(), number };
        self.changed();
        loop {
            let notified = wake.notified(); tokio::pin!(notified); notified.as_mut().enable();
            let control = crate::transfer_control::changes().notified(); tokio::pin!(control); control.as_mut().enable();
            // Scope lookup and control-file refresh must not hold the disk
            // queue mutex, particularly during Pause/Quit with many writers.
            let draining = crate::transfer_control::draining();
            let forced = force || draining || crate::transfer_control::disk_action(id).is_some();
            let mut retry_in = None;
            let mut successor = None;
            {
                let mut state = self.state.lock().unwrap();
                state.write_dispatch_polls = state.write_dispatch_polls.saturating_add(1);
                tick(&mut state);
                if forced { state.force_write(Instant::now()); }
                // Normal Quit stops HTTP first. Select the remaining finite
                // RAM tail as well so its final checkpoint can drain safely.
                if draining { state.select_writes(); }
                if state.phase == Phase::Write && state.readers == 0 && state.writers == 0
                    && state.next_write(Instant::now()) == Some(number) {
                    state.write_queue.retain(|candidate| *candidate != number); state.start(Instant::now()); state.writers = 1;
                    let bytes = crate::download_buffer::writing_payload() as u64;
                    state.writing_bytes = bytes;
                    return WriteStep { traffic: self.clone(), bytes, owner: Arc::from(id), replay_bytes: None };
                }
                let coordinator = state.coordinator(Instant::now());
                if coordinator == Some(number) {
                    retry_in = Some(if state.phase == Phase::Write && state.preferred_writer.is_some()
                        && state.last_io.elapsed() < WRITE_LOCALITY_GAP { WRITE_LOCALITY_GAP } else { IDLE_HANDOFF });
                } else {
                    // Checkpoint deadlines and cohort changes can displace
                    // the notified writer before it is polled. Hand the wake
                    // to the new coordinator before parking; no active I/O
                    // remains to do so when the disk is already idle.
                    successor = coordinator.and_then(|next| state.write_wakes.get(&next).cloned());
                }
            }
            if let Some(successor) = successor { successor.notify_one(); }
            tokio::select! {
                _ = &mut notified => {},
                _ = &mut control => {},
                _ = async { match retry_in { Some(delay) => tokio::time::sleep(delay).await, None => std::future::pending::<()>().await } } => {},
            }
        }
    }
}
struct WriteWait { traffic: Arc<Traffic>, number: u64 }
impl Drop for WriteWait {
    fn drop(&mut self) {
        let mut state = self.traffic.state.lock().unwrap();
        state.write_queue.retain(|number| *number != self.number); state.write_owners.remove(&self.number); state.write_wakes.remove(&self.number);
        state.checkpoints.remove(&self.number);
        drop(state);
        self.traffic.changed();
    }
}
pub(crate) struct WriteStep { traffic: Arc<Traffic>, bytes: u64, owner: Arc<str>, replay_bytes: Option<u64> }
impl WriteStep {
    // A prefix comparison consumes already received RAM. It uses the same
    // exclusive drain lane as writes so a full RAM queue cannot deadlock on
    // a reader permit, but is reported as actual reading, not payload writing.
    pub(super) fn reading(mut self, bytes: u64) -> Self {
        let mut state = self.traffic.state.lock().unwrap();
        state.replay_readers += 1; state.replay_read_bytes = state.replay_read_bytes.saturating_add(bytes);
        self.replay_bytes = Some(bytes); drop(state); self
    }
}
impl Drop for WriteStep {
    fn drop(&mut self) {
        let mut state = self.traffic.state.lock().unwrap(); state.writers -= 1;
        if let Some(bytes) = self.replay_bytes {
            state.replay_readers -= 1; state.replay_read_bytes = state.replay_read_bytes.saturating_sub(bytes);
        }
        state.writing_bytes = state.writing_bytes.saturating_sub(self.bytes);
        if state.preferred_writer.as_ref() == Some(&self.owner) {
            state.preferred_bytes = state.preferred_bytes.saturating_add(self.bytes);
        } else { state.preferred_writer = Some(self.owner.clone()); state.preferred_bytes = self.bytes; }
        state.last_io = Instant::now(); drop(state); self.traffic.changed();
    }
}
pub(super) struct ReadTask { traffic: Arc<Traffic>, id: u64 }
struct ReadWait(Arc<Traffic>);
impl ReadWait {
    fn new(task: &ReadTask) -> Self {
        let mut state = task.traffic.state.lock().unwrap();
        state.waiting_readers += 1;
        if let Some(job) = state.jobs.get_mut(&task.id) {
            if !job.ready { job.ready = true; state.runnable_jobs += 1; }
        }
        drop(state); task.traffic.changed(); Self(task.traffic.clone())
    }
}
impl Drop for ReadWait {
    fn drop(&mut self) { self.0.state.lock().unwrap().waiting_readers -= 1; self.0.changed(); }
}
impl ReadTask {
    // Byte admission can finish out of order while an older selected file
    // waits for source metadata. A ready check must not reserve that byte
    // allowance and then wait for the older cohort to finish: the older
    // file may need the same allowance. Join the current read turn when
    // admitted, retaining the existing write exclusion and RAM threshold.
    pub(super) fn admitted(&self) {
        let mut state = self.traffic.state.lock().unwrap();
        if state.phase == Phase::Read {
            let owner = state.jobs.get_mut(&self.id).and_then(|job| {
                if job.remaining > 0 { job.selected = true; }
                job.owner.clone()
            });
            if let Some(owner) = owner { state.selected_owners.insert(owner); }
        }
        drop(state); self.traffic.changed();
    }
    pub(super) fn set_expected(&self, bytes: u64) {
        let mut state = self.traffic.state.lock().unwrap();
        if let Some(job) = state.jobs.get_mut(&self.id) {
            let old = job.remaining; job.remaining = bytes;
            if bytes > old { READ_WORK_ADDED.fetch_add(bytes - old, Ordering::Relaxed); }
            else { READ_WORK_REMOVED.fetch_add(old - bytes, Ordering::Relaxed); }
            state.remaining = state.remaining.saturating_sub(old).saturating_add(bytes);
        }
    }
    fn can_prepare(&self) -> bool {
        let mut state = self.traffic.state.lock().unwrap(); tick(&mut state);
        state.phase == Phase::Read && state.writers == 0
            && state.jobs.get(&self.id).is_some_and(|job| job.selected)
    }
    // Enter the ready pool before waiting for the per-drive reader semaphore.
    // A new arrival waits outside that semaphore until its selected turn, so
    // it cannot hold the only reader slot in front of the current pool.
    pub(super) async fn prepare(&self, id: &str) -> anyhow::Result<()> {
        let _waiting = ReadWait::new(self);
        loop {
            let notified = self.traffic.changed.notified(); tokio::pin!(notified); notified.as_mut().enable();
            super::check_control(id)?;
            if self.can_prepare() { return Ok(()); }
            tokio::select! { _ = &mut notified => {}, _ = tokio::time::sleep(IDLE_HANDOFF) => {} }
        }
    }
    pub(super) fn prepare_blocking(&self, id: &str) -> anyhow::Result<()> {
        let _waiting = ReadWait::new(self);
        loop {
            super::check_control(id)?;
            if self.can_prepare() { return Ok(()); }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn try_chunk(&self, bytes: u64) -> Option<ReadStep> {
        let mut state = self.traffic.state.lock().unwrap(); tick(&mut state);
        if state.phase != Phase::Read || state.writers > 0 { return None; }
        let job = state.jobs.get_mut(&self.id)?;
        // A buffered EOF probe can follow the last accounted byte. It still
        // obeys the read phase, but must not wait for a new nonempty cohort.
        if !job.selected && job.remaining > 0 { return None; }
        if !job.started { READ_TASKS_STARTED.fetch_add(1, Ordering::Relaxed); }
        job.started = true; job.active += 1;
        state.start(Instant::now()); state.readers += 1;
        Some(ReadStep { traffic: self.traffic.clone(), id: self.id, bytes })
    }
    pub(super) async fn chunk(&self, bytes: u64, id: &str) -> anyhow::Result<ReadStep> {
        let _waiting = ReadWait::new(self);
        loop {
            let notified = self.traffic.changed.notified(); tokio::pin!(notified); notified.as_mut().enable();
            super::check_control(id)?;
            if let Some(step) = self.try_chunk(bytes) { return Ok(step); }
            tokio::select! { _ = &mut notified => {}, _ = tokio::time::sleep(IDLE_HANDOFF) => {} }
        }
    }
    pub(super) fn chunk_blocking(&self, bytes: u64, id: &str) -> anyhow::Result<ReadStep> {
        let _waiting = ReadWait::new(self);
        loop {
            super::check_control(id)?;
            if let Some(step) = self.try_chunk(bytes) { return Ok(step); }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for ReadTask {
    fn drop(&mut self) {
        let mut state = self.traffic.state.lock().unwrap();
        if let Some(job) = state.jobs.remove(&self.id) {
            READ_WORK_REMOVED.fetch_add(job.remaining, Ordering::Relaxed);
            state.remaining = state.remaining.saturating_sub(job.remaining);
            if job.ready { state.runnable_jobs -= 1; }
            if job.started && job.remaining == 0 { READ_TASKS_FINISHED.fetch_add(1, Ordering::Relaxed); }
        }
        state.prune(); drop(state); self.traffic.changed();
    }
}
pub(crate) struct ReadStep { traffic: Arc<Traffic>, id: u64, bytes: u64 }
impl Drop for ReadStep {
    fn drop(&mut self) {
        let mut state = self.traffic.state.lock().unwrap(); state.readers -= 1;
        if let Some(job) = state.jobs.get_mut(&self.id) {
            let read = self.bytes.min(job.remaining);
            READ_WORK_PROCESSED.fetch_add(read, Ordering::Relaxed);
            job.remaining -= read; job.active -= 1;
            let done = job.remaining == 0 && job.ready;
            if done { job.ready = false; }
            state.remaining = state.remaining.saturating_sub(read);
            if done { state.runnable_jobs -= 1; }
        }
        state.last_io = Instant::now(); drop(state); self.traffic.changed();
    }
}

#[derive(Default, serde::Serialize)]
pub(crate) struct Snapshot {
    read_work_added_bytes: u64, read_work_processed_bytes: u64, read_work_removed_bytes: u64,
    prefetch_bytes: usize, prefetch_tasks: usize, prefetch_discarded_bytes: u64,
    prefetch_active_slots: usize, prefetch_contexts: usize,
    prefetch_receiver_limit: usize, prefetch_context_limit: usize,
    prefetch_finished: u64, prefetch_failed: u64, prefetch_empty_ends: u64,
    pending_read_bytes: u64, reading_bytes: u64, pending_read_tasks: usize, reading_tasks: usize,
    waiting_read_bytes: u64, waiting_read_tasks: usize, oldest_waiting_read_ms: u64,
    pending_write_bytes: u64, writing_bytes: u64, writing_tasks: usize, waiting_writers: usize,
    read_drives: usize, write_drives: usize, batch_remaining_bytes: u64,
    turn_elapsed_ms: u64, switch_wait_ms: u64, read_turns: u64, write_turns: u64, backlog_drives: usize,
    turn_target_ms: u64, ready_read_tasks: usize, ready_read_bytes: u64,
    active_read_tasks: usize, active_read_bytes: u64,
    oldest_pending_ms: u64, read_tasks_started: u64, read_tasks_finished: u64,
    admitted_read_tasks: usize, admitted_read_bytes: u64,
    deferred_read_tasks: usize, deferred_read_bytes: u64, read_admission_deferrals: u64,
    receiving_tasks: usize, ram_draining_tasks: usize, disk_only_tasks: usize,
    file_worker_limit: usize, file_network_workers: usize, queued_downloads: usize, download_has_ready: bool,
    active_write_tasks: usize, active_write_bytes: u64, file_task_capacity: usize, file_task_capacity_reached: bool,
    ram_waiting_receivers: usize, ram_wait_count: u64, ram_wait_total_ms: u64, ram_wait_max_ms: u64,
    checkpoint_batches: u64, checkpoint_batched_files: u64, checkpoint_barriers: u64,
    checkpoint_batch_total_ms: u64, checkpoint_batch_pending: usize,
    receiving_admission_waiters: usize,
    read_turn_timeouts: u64, read_turn_finishes: u64, read_turn_pressure_handoffs: u64, read_turn_control_handoffs: u64,
    last_read_handover_sequence: u64, last_read_handover_reason: u8, last_read_turn_ms: u64, last_read_remaining_bytes: u64,
    read_write_threshold_percent: usize, read_write_threshold_bytes: u64, read_turn_write_handoffs: u64, read_turn_idle_handoffs: u64,
    read_turn_latency_handoffs: u64,
    last_read_pending_write_bytes: u64, last_read_buffer_limit_bytes: u64,
    write_dispatch_polls: u64, eligible_waiting_writers: usize,
}
impl Snapshot {
    fn include(&mut self, state: &mut State, now: Instant) {
        let result = self;
        for job in state.jobs.values() {
            if job.active > 0 {
                result.active_read_tasks += 1; result.active_read_bytes = result.active_read_bytes.saturating_add(job.remaining);
            }
            if job.ready && job.active == 0 && job.remaining > 0 {
                result.ready_read_tasks += 1; result.ready_read_bytes = result.ready_read_bytes.saturating_add(job.remaining);
            }
            if job.remaining > 0 && job.active == 0 {
                // Selecting a cohort does not start its disk reads. Include
                // selected but deferred checks in the queue and its wait age.
                result.waiting_read_tasks += 1;
                result.waiting_read_bytes = result.waiting_read_bytes.saturating_add(job.remaining);
                result.oldest_waiting_read_ms = result.oldest_waiting_read_ms.max(
                    now.saturating_duration_since(job.queued).as_millis().min(u64::MAX as u128) as u64);
            }
            if job.remaining > 0 && (job.selected || job.active > 0) {
                result.reading_bytes = result.reading_bytes.saturating_add(job.remaining); result.reading_tasks += 1;
            } else if job.remaining > 0 {
                result.pending_read_bytes = result.pending_read_bytes.saturating_add(job.remaining);
                result.pending_read_tasks += 1;
                result.oldest_pending_ms = result.oldest_pending_ms.max(now.saturating_duration_since(job.queued).as_millis().min(u64::MAX as u128) as u64);
            }
        }
        result.writing_bytes = result.writing_bytes.saturating_add(state.selected_writes().max(state.writing_bytes));
        result.writing_tasks += state.write_pools.values().filter(|pool| pool.selected > 0).count().max(state.writers);
        result.active_read_tasks += state.replay_readers;
        result.active_read_bytes = result.active_read_bytes.saturating_add(state.replay_read_bytes);
        if state.replay_readers == 0 { result.active_write_bytes = result.active_write_bytes.saturating_add(state.writing_bytes); }
        result.active_write_tasks += state.writers.saturating_sub(state.replay_readers); result.waiting_writers += state.write_queue.len();
        result.write_dispatch_polls = result.write_dispatch_polls.saturating_add(state.write_dispatch_polls);
        result.eligible_waiting_writers += state.write_queue.iter().filter(|number| state.writer_eligible(**number)).count();
        result.backlog_drives += usize::from(state.backlog(now));
        result.read_turns += state.read_turns; result.write_turns += state.write_turns;
        result.read_turn_timeouts += state.read_turn_timeouts; result.read_turn_finishes += state.read_turn_finishes;
        result.read_turn_pressure_handoffs += state.read_turn_pressure_handoffs; result.read_turn_control_handoffs += state.read_turn_control_handoffs;
        result.read_turn_write_handoffs += state.read_turn_write_handoffs;
        result.read_turn_idle_handoffs += state.read_turn_idle_handoffs;
        result.read_turn_latency_handoffs += state.read_turn_latency_handoffs;
        if state.phase == Phase::Read {
            if let Some(target) = state.write_wait_target(state.observed_pending_write_bytes.min(usize::MAX as u64) as usize) {
                result.turn_target_ms = result.turn_target_ms.max(target.as_millis() as u64);
            }
        }
        if state.last_read_handover_sequence > result.last_read_handover_sequence {
            result.last_read_handover_sequence = state.last_read_handover_sequence;
            result.last_read_handover_reason = state.last_read_handover_reason;
            result.last_read_turn_ms = state.last_read_turn_ms;
            result.last_read_remaining_bytes = state.last_read_remaining_bytes;
            result.last_read_pending_write_bytes = state.last_read_pending_write_bytes;
            result.last_read_buffer_limit_bytes = state.last_read_buffer_limit_bytes;
        }
        if let Some(since) = state.since { result.turn_elapsed_ms = result.turn_elapsed_ms.max(now.saturating_duration_since(since).as_millis().min(u64::MAX as u128) as u64); }
        else if state.readers > 0 || state.writers > 0 { result.switch_wait_ms = result.switch_wait_ms.max(now.saturating_duration_since(state.requested).as_millis().min(u64::MAX as u128) as u64); }
        if state.readers > 0 || (state.writers == 0 && state.phase == Phase::Read) {
            result.read_drives += 1;
        }
        else { result.write_drives += 1; }
    }
}
pub(crate) fn snapshot() -> Snapshot {
    let gates: Vec<_> = gates().lock().unwrap().values().filter_map(Weak::upgrade).collect();
    let mut result = Snapshot { read_work_added_bytes: READ_WORK_ADDED.load(Ordering::Relaxed),
        read_work_processed_bytes: READ_WORK_PROCESSED.load(Ordering::Relaxed), read_work_removed_bytes: READ_WORK_REMOVED.load(Ordering::Relaxed),
        read_tasks_started: READ_TASKS_STARTED.load(Ordering::Relaxed),
        read_tasks_finished: READ_TASKS_FINISHED.load(Ordering::Relaxed),
        ..Snapshot::default() };
    (result.checkpoint_batches, result.checkpoint_batched_files, result.checkpoint_barriers,
        result.checkpoint_batch_total_ms, result.checkpoint_batch_pending) = crate::download_checkpoint::snapshot();
    (result.admitted_read_tasks, result.admitted_read_bytes, result.deferred_read_tasks,
        result.deferred_read_bytes, result.read_admission_deferrals) = super::admission::snapshot();
    (result.receiving_tasks, result.ram_draining_tasks, result.disk_only_tasks) = super::admission::phases();
    let now = Instant::now();
    for gate in gates {
        let mut state = gate.state.lock().unwrap();
        if state.jobs.is_empty() && state.writers == 0 && state.write_queue.is_empty() && state.write_pools.is_empty() { continue; }
        result.include(&mut state, now);
    }
    let scheduler = crate::transfer_control::download_scheduler_snapshot();
    result.file_worker_limit = scheduler.limit; result.file_network_workers = scheduler.network_workers;
    result.queued_downloads = scheduler.queued_files; result.download_has_ready = scheduler.has_ready;
    result.file_task_capacity = scheduler.task_capacity; result.file_task_capacity_reached = scheduler.task_capacity_reached;
    result.receiving_admission_waiters = scheduler.receiving_waiters;
    let buffer = crate::download_buffer::snapshot();
    result.read_write_threshold_percent = READ_WRITE_THRESHOLD_PERCENT;
    result.read_write_threshold_bytes = write_threshold(writable_limit(buffer.limit, buffer.prefetch_bytes)) as u64;
    result.prefetch_bytes = buffer.prefetch_bytes; result.prefetch_tasks = buffer.prefetch_tasks;
    result.prefetch_discarded_bytes = buffer.prefetch_discarded_bytes;
    result.prefetch_active_slots = buffer.prefetch_active_slots; result.prefetch_contexts = buffer.prefetch_contexts;
    result.prefetch_receiver_limit = buffer.prefetch_receiver_limit; result.prefetch_context_limit = buffer.prefetch_context_limit;
    result.prefetch_finished = buffer.prefetch_finished; result.prefetch_failed = buffer.prefetch_failed;
    result.prefetch_empty_ends = buffer.prefetch_empty_ends;
    result.ram_waiting_receivers = buffer.waiting_receivers; result.ram_wait_count = buffer.wait_count;
    result.ram_wait_total_ms = buffer.wait_total_ms; result.ram_wait_max_ms = buffer.wait_max_ms;
    let used = buffer.used.saturating_sub(buffer.prefetch_bytes) as u64;
    result.writing_bytes = result.writing_bytes.min(used);
    result.pending_write_bytes = used.saturating_sub(result.writing_bytes);
    result
}

#[cfg(test)]
#[path = "download_disk_traffic_tests.rs"]
mod tests;

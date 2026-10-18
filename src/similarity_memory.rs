//! Download RAM admission. Streaming originals claim small receive windows;
//! a one-resource Banker's check prevents incomplete buffers from deadlocking.
use super::*;
use filetwin_core::memory_control::ExternalMemory;
use std::sync::{
    atomic::{AtomicU32, AtomicU64},
    Mutex,
};

pub(super) const RECEIVE_WINDOW: u64 = 256 * 1024;
pub(super) const FORECAST_SECONDS: f64 = 2.0;
pub(super) const ANALYSIS_HEADROOM: u64 = 512 << 20;
const INITIAL_RATE: f64 = 1024.0 * 1024.0;

#[derive(Debug, thiserror::Error)]
#[error("Original cannot fit in available system memory. No disk copy was created.")]
pub(super) struct Limit;

#[derive(Default)]
struct State {
    used: u64,
    next_id: u64,
    streams: HashMap<u64, Stream>,
    usage: Option<Arc<ExternalMemory>>,
}
struct Stream {
    claim: u64,
    reserved: u64,
    rate: f64,
    updated: Instant,
    done: bool,
    processing_extra: u64,
}
impl State {
    fn add(&mut self, bytes: u64) {
        self.used += bytes;
        self.publish();
    }
    fn release(&mut self, bytes: u64) {
        self.used -= bytes;
        self.publish();
    }
    fn publish(&self) {
        if let Some(usage) = &self.usage {
            usage.used.store(self.used, Ordering::Release);
            usage.incomplete.store(
                self.streams
                    .values()
                    .filter(|stream| stream.reserved > 0 && !stream.done)
                    .count() as u64,
                Ordering::Release,
            );
        }
    }
    // Work is free RAM. A finished original can release its allocation after
    // analysis; then the smallest remaining claim can finish. Reject a grant
    // unless that sequence can eventually drain every partially held input.
    fn safe(&self, limit: u64) -> bool {
        let Some(mut work) = limit.checked_sub(self.used) else {
            return false;
        };
        let mut pending: Vec<_> = self
            .streams
            .values()
            .filter(|s| s.reserved > 0)
            .map(|s| {
                (
                    (if s.done { 0 } else { s.claim - s.reserved }) + s.processing_extra,
                    s.reserved,
                )
            })
            .collect();
        pending.sort_unstable();
        for (need, held) in pending {
            if need > work {
                return false;
            }
            work += held;
        }
        true
    }
    fn rate(stream: &Stream, now: Instant) -> f64 {
        // A stalled or RAM-paused stream must not keep a stale fast forecast.
        stream.rate
            * (-(now.saturating_duration_since(stream.updated).as_secs_f64() - 1.0).max(0.0) / 3.0)
                .exp()
    }
    fn forecast(&self, now: Instant) -> u64 {
        self.used.saturating_add(
            self.streams
                .values()
                .filter(|s| !s.done && s.reserved > 0)
                .map(|s| {
                    ((Self::rate(s, now) * FORECAST_SECONDS * 1.5) as u64).min(s.claim - s.reserved)
                })
                .sum::<u64>(),
        )
    }
}

pub(super) struct Budget {
    state: Mutex<State>,
    pub waiting: AtomicU64,
    ceiling: AtomicU64,
    pressure: AtomicU32,
    required: AtomicU64,
    pub usage: Arc<ExternalMemory>,
}
#[cfg(test)]
pub(super) struct Lease {
    budget: Arc<Budget>,
    reserved: u64,
    pub capacity: u64,
}
#[cfg(test)]
impl Drop for Lease {
    fn drop(&mut self) {
        self.budget.state.lock().unwrap().release(self.reserved);
    }
}
#[cfg(test)]
impl Lease {
    pub fn shrink_to(&mut self, capacity: u64) {
        if capacity < self.reserved {
            self.budget.state.lock().unwrap().used -= self.reserved - capacity;
            self.reserved = capacity;
            self.capacity = capacity;
        }
    }
}
struct Waiting<'a>(&'a AtomicU64);
impl<'a> Waiting<'a> {
    fn new(value: &'a AtomicU64) -> Self {
        value.fetch_add(1, Ordering::Relaxed);
        Self(value)
    }
}
impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

pub(super) struct StreamLease {
    budget: Arc<Budget>,
    id: u64,
    pub capacity: u64,
}
impl Drop for StreamLease {
    fn drop(&mut self) {
        let mut state = self.budget.state.lock().unwrap();
        if let Some(stream) = state.streams.remove(&self.id) {
            state.release(stream.reserved);
        }
    }
}
impl filetwin_core::memory_input::OriginalReservation for StreamLease {
    fn bytes(&self) -> u64 {
        let state = self.budget.state.lock().unwrap();
        let stream = &state.streams[&self.id];
        assert!(
            stream.done,
            "Only completed originals can change RAM budgets"
        );
        stream.claim
    }
    fn release(&self) {
        let mut state = self.budget.state.lock().unwrap();
        let stream = state.streams.get_mut(&self.id).unwrap();
        assert!(stream.done);
        let bytes = stream.reserved;
        stream.reserved = 0;
        state.release(bytes);
    }
    fn try_reacquire(&self) -> bool {
        let mut state = self.budget.state.lock().unwrap();
        let stream = &state.streams[&self.id];
        assert!(stream.done);
        if stream.reserved != 0 {
            return true;
        }
        let bytes = stream.claim;
        if bytes > self.budget.limit().saturating_sub(state.used) {
            return false;
        }
        state.add(bytes);
        state.streams.get_mut(&self.id).unwrap().reserved = bytes;
        if state.safe(self.budget.limit()) {
            return true;
        }
        state.release(bytes);
        state.streams.get_mut(&self.id).unwrap().reserved = 0;
        false
    }
}
impl StreamLease {
    pub fn reserved(&self) -> u64 {
        self.budget.state.lock().unwrap().streams[&self.id].reserved
    }
    pub fn try_reserve(&self, target: u64) -> Result<bool> {
        if target > self.capacity {
            return Err(Limit.into());
        }
        Ok(self.try_grow(target, false))
    }
    pub fn observe_rate(&self, rate: f64) {
        let mut state = self.budget.state.lock().unwrap();
        let stream = state.streams.get_mut(&self.id).unwrap();
        stream.rate = if rate.is_finite() { rate.max(0.0) } else { 0.0 };
        stream.updated = Instant::now();
    }
    fn try_grow(&self, target: u64, admission: bool) -> bool {
        let mut state = self.budget.state.lock().unwrap();
        let now = Instant::now();
        let old = state.streams[&self.id].reserved;
        let target = self
            .budget
            .charged(target)
            .min(state.streams[&self.id].claim);
        if target <= old {
            return true;
        }
        let delta = target - old;
        // Publish the safe completion requirement even while pressure blocks
        // admission, so the governor can grow rather than reject a large file.
        // Evaluate the hypothetical grant privately. Shared usage must contain
        // only real reservations, since the analysis scheduler reads it without
        // taking this mutex.
        state.used += delta;
        state.streams.get_mut(&self.id).unwrap().reserved = target;
        let required = Budget::minimum_for(&state);
        state.used -= delta;
        state.streams.get_mut(&self.id).unwrap().reserved = old;
        self.budget.required.fetch_max(required, Ordering::Relaxed);
        let pressure = self.budget.pressure.load(Ordering::Acquire);
        if pressure >= 4 || (admission && pressure >= 2) {
            return false;
        }
        if required > self.budget.limit() {
            return false;
        }
        if admission
            && state.streams.values().any(|s| s.reserved > 0 && !s.done)
            && state.forecast(now).saturating_add(delta)
                > self.budget.limit() - self.budget.limit() / 10
        {
            return false;
        }
        state.streams.get_mut(&self.id).unwrap().reserved = target;
        state.add(delta);
        true
    }
    pub async fn grow(&self, target: u64, cancel: &AtomicBool) -> Result<()> {
        check_cancel(cancel)?;
        if target > self.capacity {
            return Err(Limit.into());
        }
        if self.try_grow(target, false) {
            return Ok(());
        }
        let _waiting = Waiting::new(&self.budget.waiting);
        loop {
            check_cancel(cancel)?;
            if self.try_grow(target, false) {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    pub fn finish(&self, bytes: u64) {
        let mut state = self.budget.state.lock().unwrap();
        let stream = state.streams.get_mut(&self.id).unwrap();
        let kept = self.budget.charged(bytes).min(stream.reserved);
        let released = stream.reserved - kept;
        stream.reserved = kept;
        stream.claim = kept;
        stream.processing_extra = self.budget.processing_extra(kept);
        stream.done = true;
        stream.rate = 0.0;
        state.release(released);
    }
}
impl Budget {
    fn processing_extra(&self, claim: u64) -> u64 {
        if self.ceiling.load(Ordering::Acquire) == 0 {
            return 0;
        }
        let headroom = ANALYSIS_HEADROOM.min(self.ceiling() / 4);
        claim
            .saturating_add(headroom)
            .min(
                self.ceiling()
                    .saturating_add(headroom)
                    .saturating_sub(claim),
            )
            .saturating_sub(headroom)
    }
    pub fn new(limit: u64) -> Arc<Self> {
        let usage = Arc::new(ExternalMemory::default());
        usage.limit.store(limit, Ordering::Release);
        Arc::new(Self {
            state: Mutex::new(State {
                usage: Some(usage.clone()),
                ..State::default()
            }),
            waiting: AtomicU64::new(0),
            ceiling: AtomicU64::new(0),
            pressure: AtomicU32::new(1),
            required: AtomicU64::new(0),
            usage,
        })
    }
    pub fn enable_automatic(&self, ceiling: u64) {
        self.ceiling.store(ceiling, Ordering::Release);
    }
    pub fn ceiling(&self) -> u64 {
        match self.ceiling.load(Ordering::Acquire) {
            0 => self.limit(),
            value => value,
        }
    }
    pub fn take_required(&self) -> u64 {
        self.required.swap(0, Ordering::Relaxed)
    }
    pub fn auto_resize(&self, limit: u64, pressure: u32) {
        self.pressure.store(pressure, Ordering::Release);
        self.usage
            .limit
            .store(limit.min(self.ceiling()), Ordering::Release);
    }
    pub fn auto_reduce(&self, limit: u64, pressure: u32) {
        self.pressure.store(pressure, Ordering::Release);
        if limit < self.limit() {
            self.auto_resize(limit, pressure);
        }
    }
    pub fn limit(&self) -> u64 {
        self.usage.limit.load(Ordering::Acquire)
    }
    pub fn minimum_limit(&self) -> u64 {
        let state = self.state.lock().unwrap();
        Self::minimum_for(&state)
    }
    fn minimum_for(state: &State) -> u64 {
        let mut released = 0u64;
        let mut minimum = state.used;
        let mut pending: Vec<_> = state
            .streams
            .values()
            .filter(|s| s.reserved > 0)
            .map(|s| {
                (
                    (if s.done { 0 } else { s.claim - s.reserved }) + s.processing_extra,
                    s.reserved,
                )
            })
            .collect();
        pending.sort_unstable();
        for (need, held) in pending {
            minimum = minimum.max(state.used.saturating_sub(released).saturating_add(need));
            released += held;
        }
        minimum
    }
    pub fn resize(&self, limit: u64) -> Result<()> {
        let state = self.state.lock().unwrap();
        if limit < Self::minimum_for(&state) {
            bail!("The retained downloads need more RAM to finish. Resume before reducing Download RAM.");
        }
        self.usage.limit.store(limit, Ordering::Release);
        Ok(())
    }
    /// A completed, independently evictable media range. Unlike an incomplete
    /// original it needs no further RAM to make progress or release its lease.
    pub fn try_cache(self: &Arc<Self>, bytes: u64) -> Option<StreamLease> {
        if bytes == 0 || self.pressure.load(Ordering::Acquire) >= 2 { return None; }
        let reserved = self.charged(bytes);
        let mut state = self.state.lock().unwrap();
        if reserved > self.limit().saturating_sub(state.used) { return None; }
        state.next_id += 1;
        let id = state.next_id;
        state.streams.insert(id, Stream { claim: reserved, reserved, rate: 0.0,
            updated: Instant::now(), done: true, processing_extra: 0 });
        state.add(reserved);
        if !state.safe(self.limit()) {
            state.streams.remove(&id);
            state.release(reserved);
            return None;
        }
        Some(StreamLease { budget: self.clone(), id, capacity: bytes })
    }
    pub async fn cache(self: &Arc<Self>, bytes: u64, cancel: &AtomicBool) -> Result<StreamLease> {
        if bytes == 0 || bytes > self.ceiling() { return Err(Limit.into()); }
        let _waiting = Waiting::new(&self.waiting);
        loop {
            check_cancel(cancel)?;
            if let Some(lease) = self.try_cache(bytes) { return Ok(lease); }
            self.required.fetch_max(self.used().saturating_add(self.charged(bytes))
                .saturating_add(ANALYSIS_HEADROOM), Ordering::Relaxed);
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    pub fn cache_target(&self, readers: u64) -> u64 {
        if self.pressure.load(Ordering::Acquire) >= 2 { RECEIVE_WINDOW }
        else { (self.limit() / readers.max(1) / 2).max(RECEIVE_WINDOW) }
    }
    pub fn used(&self) -> u64 {
        self.state.lock().unwrap().used
    }
    pub fn forecast(&self) -> u64 {
        self.state.lock().unwrap().forecast(Instant::now())
    }
    pub fn has_forecast_room(&self) -> bool {
        self.forecast() < self.limit() - self.limit() / 10
    }
    fn charged(&self, bytes: u64) -> u64 {
        // Apple Silicon commits 16 KiB pages. Tiny logical budgets are used by
        // unit tests only; production settings are always many megabytes.
        let page = if self.limit() >= 16 * 1024 || self.ceiling.load(Ordering::Acquire) >= 16 * 1024
        {
            16 * 1024
        } else {
            1
        };
        bytes.saturating_add(page - 1) / page * page
    }
    pub async fn stream(self: &Arc<Self>, size: u64, cancel: &AtomicBool) -> Result<StreamLease> {
        let capacity = if size == 0 {
            // A temporarily closed automatic bank is not an empty original.
            // Preserve the usual allowance-based unknown-size capacity once
            // the governor reopens admission; do not claim all physical RAM.
            let _waiting = Waiting::new(&self.waiting);
            let limit = loop {
                check_cancel(cancel)?;
                let limit = self.limit();
                if limit > 0 || self.ceiling.load(Ordering::Acquire) == 0 { break limit; }
                self.required.fetch_max(RECEIVE_WINDOW, Ordering::Relaxed);
                tokio::time::sleep(Duration::from_millis(20)).await;
            };
            if limit < 16384 {
                limit
            } else {
                limit / 16384 * 16384
            }
        } else {
            size
        };
        let claim = self.charged(capacity);
        if claim == 0 || claim > self.ceiling() {
            return Err(Limit.into());
        }
        // Keep a completion path through decoding, not just through receiving
        // bytes. One original may need a reader copy as well. The shared
        // analysis headroom covers the first decoder; additional reader RAM
        // participates in the same Banker's check as the original's claim.
        let processing_extra = self.processing_extra(claim);
        let id = {
            let mut state = self.state.lock().unwrap();
            state.next_id += 1;
            let id = state.next_id;
            let rates: Vec<_> = state
                .streams
                .values()
                .filter(|s| !s.done && s.reserved > 0)
                .map(|s| State::rate(s, Instant::now()))
                .filter(|v| *v > 0.0)
                .collect();
            let rate = if rates.is_empty() {
                INITIAL_RATE
            } else {
                rates.iter().sum::<f64>() / rates.len() as f64
            };
            state.streams.insert(
                id,
                Stream {
                    claim,
                    reserved: 0,
                    rate,
                    updated: Instant::now(),
                    done: false,
                    processing_extra,
                },
            );
            id
        };
        let lease = StreamLease {
            budget: self.clone(),
            id,
            capacity,
        };
        let target = capacity.min(RECEIVE_WINDOW);
        let _waiting = Waiting::new(&self.waiting);
        loop {
            check_cancel(cancel)?;
            if claim > self.ceiling() {
                return Err(Limit.into());
            }
            if claim > self.limit() {
                self.required.fetch_max(
                    self.used()
                        .saturating_add(claim)
                        .saturating_add(processing_extra),
                    Ordering::Relaxed,
                );
            }
            if lease.try_grow(target, true) {
                return Ok(lease);
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    /// Test helper to model RAM already held by a completed original.
    #[cfg(test)]
    pub async fn reserve(self: &Arc<Self>, size: u64, cancel: &AtomicBool) -> Result<Lease> {
        let capacity = if size == 0 { self.limit() } else { size };
        let reserved = (capacity <= self.limit() && capacity > 0)
            .then_some(capacity)
            .ok_or(Limit)?;
        let _waiting = Waiting::new(&self.waiting);
        loop {
            check_cancel(cancel)?;
            {
                let mut state = self.state.lock().unwrap();
                if reserved <= self.limit().saturating_sub(state.used) {
                    state.add(reserved);
                    if state.safe(self.limit()) {
                        return Ok(Lease {
                            budget: self.clone(),
                            reserved,
                            capacity,
                        });
                    }
                    state.release(reserved);
                }
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn zero_automatic_source_bank_retains_leases_and_blocks_new_admission() {
        use super::*;
        let budget = Budget::new(8 << 20);
        budget.enable_automatic(16 << 20);
        let cancel = AtomicBool::new(false);
        let original = budget.stream(2 << 20, &cancel).await.unwrap();
        original.grow(1 << 20, &cancel).await.unwrap();
        for pressure in [2, 4] {
            budget.auto_resize(0, pressure);
            assert_eq!(budget.limit(), 0, "A closed source bank must not reserve a phantom byte");
            assert_eq!(budget.used(), 1 << 20, "Closing admission must retain existing leases");
            assert!(!original.try_reserve(2 << 20).unwrap());
            assert!(budget.try_cache(1).is_none());
            assert!(!budget.has_forecast_room());
            for size in [1 << 20, 0] {
                assert!(tokio::time::timeout(Duration::from_millis(30), budget.stream(size, &cancel)).await.is_err(),
                    "A closed automatic bank must wait rather than admit or reject an original");
            }
            assert_eq!(budget.waiting.load(Ordering::Acquire), 0);
            assert_eq!(budget.usage.used.load(Ordering::Acquire), 1 << 20);
        }
        drop(original);
        assert_eq!(budget.used(), 0);
        assert_eq!(budget.usage.committed(), 0);
    }

    #[tokio::test]
    async fn unknown_size_auto_stream_waits_at_zero_then_uses_the_reopened_allowance() {
        use super::*;
        let budget = Budget::new(8 << 20);
        budget.enable_automatic(16 << 20);
        budget.auto_resize(0, 4);
        let cancel = Arc::new(AtomicBool::new(false));
        let ram = budget.clone(); let stop = cancel.clone();
        let pending = tokio::spawn(async move { ram.stream(0, &stop).await });
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(!pending.is_finished(), "Temporary zero allowance must not fail an unknown-size source");
        assert!(budget.take_required() > 0);
        cancel.store(true, Ordering::Release);
        assert!(tokio::time::timeout(Duration::from_millis(100), pending).await.unwrap().unwrap().is_err());
        assert_eq!(budget.waiting.load(Ordering::Acquire), 0);
        let ram = budget.clone();
        let pending = tokio::spawn(async move { ram.stream(0, &AtomicBool::new(false)).await });
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(!pending.is_finished());
        budget.auto_resize(4 << 20, 1);
        tokio::time::timeout(Duration::from_millis(100), async {
            while budget.take_required() < 8 << 20 { tokio::time::sleep(Duration::from_millis(5)).await; }
        }).await.unwrap();
        // The first positive allowance fixes capacity; more source-bank room
        // supplies its existing reader-completion requirement, not a new claim.
        budget.auto_resize(8 << 20, 1);
        let original = tokio::time::timeout(Duration::from_millis(100), pending).await.unwrap().unwrap().unwrap();
        assert_eq!(original.capacity, 4 << 20);
        assert!(original.capacity < budget.ceiling());
        drop(original);
        assert_eq!(budget.used(), 0);
        assert_eq!(budget.waiting.load(Ordering::Acquire), 0);
    }

    #[tokio::test]
    async fn rejected_receive_windows_never_publish_ungranted_ram() {
        use super::*;
        let budget = Budget::new(8 << 20);
        let cancel = AtomicBool::new(false);
        let first = budget.stream(8 << 20, &cancel).await.unwrap();
        let second = budget.stream(4 << 20, &cancel).await.unwrap();
        second.grow(4 << 20, &cancel).await.unwrap();
        second.finish(4 << 20);
        let done = Arc::new(AtomicBool::new(false));
        let stop = done.clone();
        let usage = budget.usage.clone();
        let observer = std::thread::spawn(move || {
            let mut peak = 0;
            while !stop.load(Ordering::Acquire) {
                peak = peak.max(usage.used.load(Ordering::Acquire));
            }
            peak
        });
        for _ in 0..20_000 {
            assert!(!first.try_reserve(8 << 20).unwrap());
        }
        done.store(true, Ordering::Release);
        assert!(
            observer.join().unwrap() <= 8 << 20,
            "An ungranted window entered shared accounting"
        );
        assert_eq!(budget.usage.used.load(Ordering::Acquire), budget.used());
        drop((first, second));
    }
    #[tokio::test]
    async fn automatic_prefetch_leaves_a_completion_path_through_reader_copies() {
        use super::*;
        use filetwin_core::memory_input::OriginalReservation;
        let budget = Budget::new(31 << 30);
        budget.enable_automatic((64 << 30) - ANALYSIS_HEADROOM);
        let cancel = AtomicBool::new(false);
        let first = budget.stream(8 << 30, &cancel).await.unwrap();
        first.grow(8 << 30, &cancel).await.unwrap();
        first.finish(8 << 30);
        let second = budget.stream(8 << 30, &cancel).await.unwrap();
        second.grow(8 << 30, &cancel).await.unwrap();
        second.finish(8 << 30);
        assert_eq!(budget.minimum_limit(), 24 << 30);
        let third = budget.stream(8 << 30, &cancel).await.unwrap();
        assert!(
            !third.try_reserve(8 << 30).unwrap(),
            "Receive windows may overlap, but must leave a reader-copy completion path"
        );
        assert_eq!(budget.used(), (16 << 30) + RECEIVE_WINDOW);
        first.release();
        assert!(third.try_reserve(8 << 30).unwrap());
        drop((first, second, third));
        assert_eq!(budget.used(), 0);
    }
    #[tokio::test]
    async fn automatic_large_claim_waits_for_growth_and_pressure_keeps_partial_bytes() {
        use super::*;
        let budget = Budget::new(1 << 20);
        budget.enable_automatic(16 << 20);
        let cancel = Arc::new(AtomicBool::new(false));
        let ram = budget.clone();
        let stop = cancel.clone();
        let pending = tokio::spawn(async move { ram.stream(8 << 20, &stop).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            !pending.is_finished(),
            "A soft allowance must not reject a large original"
        );
        assert!(budget.take_required() >= 8 << 20);
        budget.auto_resize(16 << 20, 1);
        let lease = pending.await.unwrap().unwrap();
        lease.grow(2 << 20, &cancel).await.unwrap();
        budget.auto_resize(1 << 20, 4);
        assert!(!lease.try_reserve(3 << 20).unwrap());
        assert_eq!(budget.used(), 2 << 20);
        assert_eq!(budget.usage.used.load(Ordering::Acquire), budget.used());
        budget.auto_resize(16 << 20, 2);
        assert!(
            lease.try_reserve(3 << 20).unwrap(),
            "Existing downloads may finish at warning pressure"
        );
        let next = budget.stream(1 << 20, &cancel);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), next)
                .await
                .is_err(),
            "Warning must stop new downloads"
        );
        drop(lease);
        budget.auto_resize(16 << 20, 1);
        let lease = budget.stream(1 << 20, &cancel).await.unwrap();
        drop(lease);
        assert_eq!(budget.used(), 0);
        assert_eq!(budget.usage.used.load(Ordering::Acquire), 0);
    }
    #[tokio::test]
    async fn completed_original_handoff_frees_download_capacity_and_retries_without_double_release()
    {
        use filetwin_core::memory_input::OriginalReservation;
        let budget = super::Budget::new(40 << 30);
        let cancel = super::AtomicBool::new(false);
        let mut originals = Vec::new();
        for _ in 0..5 {
            let lease = budget.stream(8 << 30, &cancel).await.unwrap();
            lease.grow(8 << 30, &cancel).await.unwrap();
            lease.finish(8 << 30);
            originals.push(lease);
        }
        assert_eq!(budget.used(), 40 << 30);
        originals[0].release();
        originals[0].release();
        assert_eq!(originals[0].bytes(), 8 << 30);
        assert_eq!(budget.used(), 32 << 30);
        let next = budget.stream(8 << 30, &cancel).await.unwrap();
        next.grow(8 << 30, &cancel).await.unwrap();
        next.finish(8 << 30);
        assert_eq!(budget.used(), 40 << 30);
        assert!(!originals[0].try_reacquire());
        assert_eq!(budget.used(), 40 << 30);
        drop(next);
        assert!(originals[0].try_reacquire());
        assert!(originals[0].try_reacquire());
        assert_eq!(budget.used(), 40 << 30);
        originals[0].release();
        assert_eq!(budget.minimum_limit(), 32 << 30);
        drop(originals);
        assert_eq!(budget.used(), 0);
    }

    #[tokio::test]
    async fn resizing_preserves_partial_buffers_and_rejects_deadlock() {
        let budget = super::Budget::new(16 << 20);
        let cancel = super::AtomicBool::new(false);
        let first = budget.stream(8 << 20, &cancel).await.unwrap();
        let second = budget.stream(8 << 20, &cancel).await.unwrap();
        first.grow(4 << 20, &cancel).await.unwrap();
        second.grow(4 << 20, &cancel).await.unwrap();
        assert_eq!(budget.minimum_limit(), 12 << 20);
        assert!(
            budget.resize(8 << 20).is_err(),
            "Both partials would wait forever"
        );
        assert_eq!(budget.limit(), 16 << 20);
        budget.resize(12 << 20).unwrap();
        first.grow(8 << 20, &cancel).await.unwrap();
        first.finish(8 << 20);
        drop(first);
        second.grow(8 << 20, &cancel).await.unwrap();
        second.finish(8 << 20);
        drop(second);
        assert_eq!(budget.used(), 0);
        budget.resize(1 << 20).unwrap();
    }

    use super::*;
    const GIB: u64 = 1 << 30;
    const MIB: u64 = 1 << 20;

    #[tokio::test]
    async fn twelve_videos_and_120_images_overlap_and_drain_within_twelve_gb() {
        // Logical GB claims exercise the user's example without allocating GB
        // of test data. Includes slow consumers and changing arrival order.
        let budget = Budget::new(12 * GIB);
        let cancel = AtomicBool::new(false);
        let mut inputs = Vec::new();
        for index in 0..132 {
            let size = if index < 12 { GIB } else { GIB / 10 };
            let lease =
                tokio::time::timeout(Duration::from_millis(100), budget.stream(size, &cancel))
                    .await
                    .unwrap()
                    .unwrap();
            lease.observe_rate(2.0 * MIB as f64);
            inputs.push((Some(lease), 0u64, None));
        }
        assert!(
            inputs
                .iter()
                .map(|(lease, _, _)| lease.as_ref().unwrap().capacity)
                .sum::<u64>()
                > budget.limit()
        );
        assert!(budget.used() < GIB, "Admission reserved entire originals");
        let mut completed = 0;
        for tick in 0..2000 {
            let mut advanced = false;
            for offset in 0..inputs.len() {
                let index = (offset + tick * 17) % inputs.len();
                let (slot, written, ready_at) = &mut inputs[index];
                let Some(lease) = slot.as_ref() else {
                    continue;
                };
                if let Some(release_at) = *ready_at {
                    if tick >= release_at {
                        *slot = None;
                        completed += 1;
                        advanced = true;
                    }
                    continue;
                }
                let target =
                    (*written + if index < 12 { 64 * MIB } else { 8 * MIB }).min(lease.capacity);
                if lease.try_grow(target, false) {
                    *written = target;
                    advanced = true;
                    lease.observe_rate(if tick % 4 == 0 {
                        500.0 * MIB as f64
                    } else {
                        MIB as f64
                    });
                    if *written == lease.capacity {
                        lease.finish(*written);
                        *ready_at = Some(tick + 3);
                    }
                }
                assert!(budget.used() <= budget.limit());
                assert!(budget.state.lock().unwrap().safe(budget.limit()));
            }
            if completed == inputs.len() {
                break;
            }
            assert!(
                advanced || inputs.iter().any(|(_, _, at)| at.is_some()),
                "Partial downloads deadlocked"
            );
        }
        assert_eq!(completed, 132);
        assert_eq!(budget.used(), 0);
    }

    #[tokio::test]
    async fn rejects_unsafe_partial_growth_and_unblocks_after_an_original_finishes() {
        let budget = Budget::new(10 * MIB);
        let cancel = AtomicBool::new(false);
        let a = budget.stream(8 * MIB, &cancel).await.unwrap();
        let b = budget.stream(8 * MIB, &cancel).await.unwrap();
        assert!(a.try_grow(4 * MIB, false));
        assert!(b.try_grow(2 * MIB, false));
        // This would leave 3 MB free while both files need at least 4 MB.
        assert!(!b.try_grow(3 * MIB, false));
        assert_eq!(budget.used(), 6 * MIB);
        assert!(a.try_grow(8 * MIB, false));
        a.finish(8 * MIB);
        assert!(!b.try_grow(3 * MIB, false)); // Ready original still owns its bytes.
        drop(a);
        assert!(b.try_grow(8 * MIB, false));
        b.finish(8 * MIB);
        drop(b);
        assert_eq!(budget.used(), 0);
    }

    #[tokio::test]
    async fn speed_forecast_gates_new_starts_but_never_stops_existing_completion() {
        let budget = Budget::new(12 * GIB);
        let cancel = AtomicBool::new(false);
        let a = budget.stream(11 * GIB, &cancel).await.unwrap();
        a.observe_rate(8.0 * GIB as f64);
        assert!(budget.forecast() > 10 * GIB);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), budget.stream(GIB, &cancel))
                .await
                .is_err()
        );
        assert_eq!(
            budget.state.lock().unwrap().streams.len(),
            1,
            "Dropped admission retained a claim"
        );
        assert!(
            a.try_grow(11 * GIB, false),
            "Forecast blocked an existing completion"
        );
        a.finish(11 * GIB);
        drop(a);
        let b = budget.stream(GIB, &cancel).await.unwrap();
        drop(b);
        assert_eq!(budget.used(), 0);
    }

    #[tokio::test]
    async fn unknown_sizes_and_cancellation_cannot_strand_ram() {
        let budget = Budget::new(4 * MIB);
        let cancel = AtomicBool::new(false);
        let unknown = budget.stream(0, &cancel).await.unwrap();
        assert_eq!(unknown.capacity, 4 * MIB);
        // Two unbounded originals cannot both make promises to consume the
        // whole pool. The waiter holds nothing until the first one finishes.
        assert!(
            tokio::time::timeout(Duration::from_millis(50), budget.stream(0, &cancel))
                .await
                .is_err()
        );
        assert!(unknown.try_grow(MIB, false));
        unknown.finish(MIB);
        let known = budget.stream(MIB, &cancel).await.unwrap();
        cancel.store(true, Ordering::Release);
        assert!(known.grow(MIB, &cancel).await.is_err());
        drop((known, unknown));
        assert_eq!(budget.used(), 0);
        assert_eq!(budget.waiting.load(Ordering::Relaxed), 0);
    }
    #[tokio::test]
    async fn originals_wait_for_ram_and_release_on_drop_or_cancel() {
        let budget = Budget::new(20);
        let cancel = AtomicBool::new(false);
        let first = budget.reserve(20, &cancel).await.unwrap();
        assert_eq!(budget.used(), 20);
        let pending = budget.reserve(5, &cancel);
        let stop = async {
            tokio::time::sleep(Duration::from_millis(40)).await;
            cancel.store(true, Ordering::Release);
        };
        let (result, _) = tokio::join!(pending, stop);
        assert!(result.is_err());
        assert_eq!(budget.waiting.load(Ordering::Relaxed), 0);
        drop(first);
        assert_eq!(budget.used(), 0);
        cancel.store(false, Ordering::Release);
        assert!(budget.reserve(21, &cancel).await.is_err());
        let unknown = budget.reserve(0, &cancel).await.unwrap();
        assert_eq!(unknown.capacity, 20);
    }
    #[tokio::test]
    async fn byte_budget_fits_variable_file_sizes_and_reclaims_unknown_length_headroom() {
        let budget = Budget::new(12);
        let cancel = AtomicBool::new(false);
        let first = budget.reserve(3, &cancel).await.unwrap();
        let second = budget.reserve(5, &cancel).await.unwrap();
        let third = budget.reserve(4, &cancel).await.unwrap();
        assert_eq!(budget.used(), 12);
        drop(second);
        assert_eq!(budget.used(), 7);
        let fourth = budget.reserve(2, &cancel).await.unwrap();
        assert_eq!(budget.used(), 9);
        drop((first, third, fourth));
        let mut unknown = budget.reserve(0, &cancel).await.unwrap();
        assert_eq!(budget.used(), 12);
        unknown.shrink_to(4);
        assert_eq!(budget.used(), 4);
        let next = budget.reserve(8, &cancel).await.unwrap();
        assert_eq!(budget.used(), 12);
        drop((unknown, next));
        assert_eq!(budget.used(), 0);
    }
}

//! Scan admission uses the download throughput controller and host pressure
//! signal. Capacity comes from RAM/descriptors, not a fixed file count.
use pikpak::download_connections::Connections;
use std::time::{Duration, Instant};

#[derive(Clone, Copy)]
pub(super) enum Mode {
    Automatic,
    Fixed(usize),
}

impl From<usize> for Mode {
    fn from(value: usize) -> Self { Self::Fixed(value.max(1)) }
}

pub(super) struct Admission {
    pool: Connections,
    automatic: bool,
    capacity: usize,
    resource_limit: usize,
    level: u32,
    next_pressure: Instant,
    recover_after: Instant,
}

impl Admission {
    pub fn new(mode: Mode, initial: usize, byte_throughput: bool) -> Self {
        let now = Instant::now();
        let (automatic, capacity, initial) = match mode {
            Mode::Automatic => {
                // Leave descriptors for the runtime/API and charge a streaming
                // buffer plus thread overhead, without allocating physical RAM.
                let descriptors = rustix::process::getrlimit(rustix::process::Resource::Nofile)
                    .current.and_then(|value| usize::try_from(value).ok()).unwrap_or(256);
                let memory = crate::download_buffer::physical_memory().unwrap_or(64 << 20);
                let capacity = (descriptors / 2).min(memory / (2 << 20)).max(1);
                // I/O concurrency is unrelated to the number of CPU cores.
                // Start gently, then measure both larger and smaller pools.
                (true, capacity, if byte_throughput { initial.min(2) } else { initial })
            }
            Mode::Fixed(limit) => (false, limit.max(1), limit.max(1)),
        };
        Self::with_capacity(automatic, capacity, initial, byte_throughput, now)
    }

    fn with_capacity(automatic: bool, capacity: usize, initial: usize, bytes: bool, now: Instant) -> Self {
        let pool = Connections::with_initial(capacity, initial, now);
        Self {
            pool: if bytes { pool.with_absolute_gain().with_bidirectional_trials() } else { pool },
            automatic, capacity, resource_limit: capacity, level: 1,
            next_pressure: now, recover_after: now,
        }
    }

    pub fn update(&mut self, now: Instant, completed: u64, active: usize, waiting: bool) -> usize {
        if self.automatic && now >= self.next_pressure {
            self.next_pressure = now + Duration::from_secs(1);
            self.pressure(now, crate::download_buffer::memory_pressure());
        }
        self.observe(now, completed, active, waiting)
    }

    fn observe(&mut self, now: Instant, completed: u64, active: usize, waiting: bool) -> usize {
        if self.automatic {
            if self.level >= 4 { return 0; }
            if self.level < 2 && now >= self.recover_after { self.resource_limit = self.capacity; }
            self.pool.limit_for_resources(self.resource_limit, now);
            // The caller refills immediately after observing a completion.
            // A queued backlog keeps this stage saturated across that brief
            // gap. Sampling the just-finished task count would invalidate
            // every throughput window for small files and prevent all trials.
            self.pool.active = if waiting { active.max(self.pool.limit) } else { active };
            self.pool.observe(now, completed, || waiting);
        }
        self.pool.limit
    }

    fn pressure(&mut self, now: Instant, level: u32) {
        if level >= 2 {
            self.recover_after = now + Duration::from_secs(30);
            // A warning episode has one target: repeatedly halving would
            // prevent the remaining work from ever draining.
            if self.level < 2 { self.resource_limit = (self.pool.limit / 2).max(1); }
            if level >= 4 { self.resource_limit = 1; }
            self.pool.limit_for_resources(self.resource_limit, now);
        }
        self.level = level;
    }

    pub fn throttled(&mut self, now: Instant) {
        if !self.automatic { return; }
        self.resource_limit = (self.pool.limit / 2).max(1);
        self.recover_after = now + Duration::from_secs(30);
        self.pool.limit_for_resources(self.resource_limit, now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grows_past_forty_when_measured_throughput_keeps_improving() {
        let start = Instant::now();
        let mut admission = Admission::with_capacity(true, 256, 18, true, start);
        let mut bytes = 0;
        let mut peak = 0;
        for tick in 0..240 {
            let active = admission.pool.limit;
            bytes += active as u64 * 1_000_000;
            peak = peak.max(admission.observe(start + Duration::from_millis(tick * 500), bytes, active, true));
        }
        assert!(peak > 40);
        assert!(peak <= 256);
    }

    #[test]
    fn pressure_pauses_admission_and_recovery_keeps_a_cooldown() {
        let now = Instant::now();
        let mut admission = Admission::with_capacity(true, 256, 18, true, now);
        admission.pressure(now, 2);
        assert_eq!(admission.observe(now, 0, 18, true), 9);
        admission.pressure(now + Duration::from_secs(1), 2);
        assert_eq!(admission.observe(now + Duration::from_secs(1), 0, 9, true), 9);
        admission.pressure(now + Duration::from_secs(2), 4);
        assert_eq!(admission.observe(now + Duration::from_secs(2), 0, 9, true), 0);
        admission.pressure(now + Duration::from_secs(3), 1);
        assert_eq!(admission.observe(now + Duration::from_secs(3), 0, 0, true), 1);
        assert_eq!(admission.resource_limit, 1);
        admission.observe(now + Duration::from_secs(33), 1, 1, true);
        assert_eq!(admission.resource_limit, 256);
    }

    #[test]
    fn api_throttling_reduces_new_admission_and_fixed_benchmarks_stay_fixed() {
        let now = Instant::now();
        let mut admission = Admission::with_capacity(true, 256, 18, false, now);
        admission.throttled(now);
        assert_eq!(admission.observe(now, 10, 18, true), 9);
        let mut fixed = Admission::new(Mode::Fixed(40), 1, true);
        fixed.throttled(now);
        assert_eq!(fixed.update(now, 0, 0, true), 40);
    }

    #[test]
    fn unchanged_throughput_rejects_growth_instead_of_filling_ram_with_workers() {
        let start = Instant::now();
        let mut admission = Admission::with_capacity(true, 256, 18, true, start);
        let mut peak = 0;
        for tick in 0..240 {
            let active = admission.pool.limit;
            peak = peak.max(admission.observe(start + Duration::from_millis(tick * 500), tick * 100_000_000, active, true));
        }
        assert!(peak > 18, "a trial should run before concluding the disk is saturated");
        assert!(peak < 40, "no measured gain must not create an unbounded worker pool");
        assert_eq!(admission.pool.limit, 1, "equal throughput should retain fewer readers");
    }

    #[test]
    fn slower_disk_recovers_from_an_excessive_initial_reader_count() {
        let start = Instant::now();
        let mut admission = Admission::with_capacity(true, 256, 18, true, start);
        let mut bytes = 0;
        for tick in 0..360 {
            let active = admission.pool.limit;
            // Model a disk whose seek contention increases with reader count.
            bytes += 100_000_000 / active as u64;
            admission.observe(start + Duration::from_millis(tick * 500), bytes, active, true);
        }
        assert!(admission.pool.limit <= 2, "smaller trials must recover throughput");
    }

    #[test]
    fn short_file_completion_gaps_do_not_prevent_throughput_trials() {
        let start = Instant::now();
        let mut admission = Admission::with_capacity(true, 256, 2, true, start);
        let mut bytes = 0;
        let mut peak = 0;
        for tick in 0..480 {
            let target = admission.pool.limit;
            bytes += target as u64 * 1_000_000;
            // Each observation happens just after a file finishes, before
            // its replacement is admitted from the still-full pending queue.
            peak = peak.max(admission.observe(start + Duration::from_millis(tick * 500),
                bytes, target.saturating_sub(1), true));
        }
        assert!(peak > 40, "a persistent backlog must allow useful growth");
    }
}

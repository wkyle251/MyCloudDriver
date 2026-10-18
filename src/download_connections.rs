//! Rolling throughput-based admission for downloads to disk, similarity RAM and uploads.
//! Lower limits affect admission only: active transfers retain their slots.
use crate::download_trials::{Coordinator, Lease, Participant};
use std::{
    collections::VecDeque,
    sync::Arc,
    time::{Duration, Instant},
};

const INITIAL_CONNECTIONS: usize = 4;
const SAMPLE_WINDOW: Duration = Duration::from_secs(5);
const SAMPLE_INTERVAL: Duration = Duration::from_millis(500);
const SETTLE_TIME: Duration = Duration::from_secs(2);
const IDLE_GAP: Duration = Duration::from_secs(1);
const MAX_TRIAL_TIME: Duration = Duration::from_secs(12);
const MIN_RELATIVE_GAIN: f64 = 1.10;
const MIN_ABSOLUTE_GAIN: f64 = 1_000_000.0;
const STABLE_SWING: f64 = 0.20;

enum MinimumGain {
    TenPercent,
    OneMegabytePerSecond,
}

struct Sample {
    at: Instant,
    bytes: u64,
}
#[derive(Default)]
struct Rolling {
    samples: VecDeque<Sample>,
}
struct Rate {
    mean: f64,
    stable: bool,
    flowing: bool,
}

impl Rolling {
    fn clear(&mut self) {
        self.samples.clear();
    }
    fn push(&mut self, now: Instant, bytes: u64) {
        self.samples.push_back(Sample { at: now, bytes });
        while self.samples.len() > 2
            && now.saturating_duration_since(self.samples[1].at) >= SAMPLE_WINDOW
        {
            self.samples.pop_front();
        }
    }
    fn bytes_at(&self, at: Instant) -> Option<f64> {
        let mut previous = self.samples.front()?;
        if previous.at > at {
            return None;
        }
        // Work relative to the oldest byte count to retain precision on long sessions.
        let base = previous.bytes;
        for next in self.samples.iter().skip(1) {
            if next.at >= at {
                let fraction = at.saturating_duration_since(previous.at).as_secs_f64()
                    / next.at.saturating_duration_since(previous.at).as_secs_f64();
                return Some(
                    previous.bytes.saturating_sub(base) as f64
                        + next.bytes.saturating_sub(previous.bytes) as f64 * fraction,
                );
            }
            previous = next;
        }
        Some(previous.bytes.saturating_sub(base) as f64)
    }
    fn rate(&self, now: Instant) -> Option<Rate> {
        let end = self.bytes_at(now)?;
        let middle = self.bytes_at(now.checked_sub(SAMPLE_WINDOW / 2)?)?;
        let start = self.bytes_at(now.checked_sub(SAMPLE_WINDOW)?)?;
        let first = middle - start;
        let second = end - middle;
        let mean = (end - start) / SAMPLE_WINDOW.as_secs_f64();
        let flowing = self.samples.len() >= 2
            && self.samples.back()?.bytes > self.samples[self.samples.len() - 2].bytes;
        Some(Rate {
            mean,
            flowing,
            stable: mean > 0.0 && (first - second).abs() <= (first + second) * 0.5 * STABLE_SWING,
        })
    }
}

struct Probe {
    previous_limit: usize,
    baseline_rate: f64,
    started: Instant,
    lease: Option<Lease>,
}
struct Plateau {
    rate: f64,
    failures: u32,
}

/// A completed measurement, never a speculative admission change. Callers may
/// retain a small warm start only after observing an accepted trial.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TrialOutcome {
    Accepted(usize),
    Rejected,
}

pub struct Connections {
    pub active: usize,
    pub limit: usize,
    ceiling: usize,
    resource_limit: usize,
    samples: Rolling,
    probe: Option<Probe>,
    last_poll: Option<Instant>,
    next_sample: Instant,
    settle_until: Instant,
    valid_since: Instant,
    stable_since: Option<Instant>,
    plateau: Option<Plateau>,
    proven_gain: bool,
    minimum_gain: MinimumGain,
    coordinator: Option<Participant>,
    generation: Option<u64>,
    trial_outcome: Option<TrialOutcome>,
    bidirectional: bool,
    lower_next: bool,
}

impl Connections {
    pub fn new(ceiling: usize, now: Instant) -> Self {
        Self::with_initial(ceiling, INITIAL_CONNECTIONS, now)
    }
    pub fn with_initial(ceiling: usize, initial: usize, now: Instant) -> Self {
        let ceiling = ceiling.max(1);
        Self {
            active: 0,
            limit: ceiling.min(initial.max(1)),
            ceiling,
            resource_limit: ceiling,
            samples: Rolling::default(),
            probe: None,
            last_poll: None,
            next_sample: now,
            settle_until: now,
            valid_since: now,
            stable_since: None,
            plateau: None,
            proven_gain: false,
            minimum_gain: MinimumGain::TenPercent,
            coordinator: None,
            generation: None,
            trial_outcome: None,
            bidirectional: false,
            lower_next: false,
        }
    }
    /// Normal downloads retain a trial only when aggregate throughput increases
    /// by at least 1 MB/s (1,000,000 bytes/s), regardless of the baseline rate.
    /// Call when constructing the controller, before collecting measurements.
    pub fn with_absolute_gain(mut self) -> Self {
        self.minimum_gain = MinimumGain::OneMegabytePerSecond;
        self
    }
    /// File reads can get slower with more readers (especially on rotating
    /// disks). Alternate growth with smaller trials; an equal-rate smaller
    /// pool is useful because it leaves the disk and host less contention.
    pub fn with_bidirectional_trials(mut self) -> Self {
        self.bidirectional = true;
        self
    }
    pub fn with_coordinator(mut self, coordinator: Arc<Coordinator>) -> Self {
        self.coordinator = Some(coordinator.register());
        self
    }
    pub(crate) fn take_trial_outcome(&mut self) -> Option<TrialOutcome> {
        self.trial_outcome.take()
    }
    fn invalidate_window(&mut self, now: Instant) {
        self.valid_since = now;
        self.stable_since = None;
    }
    fn abandon_probe(&mut self, now: Instant) {
        if let Some(probe) = self.probe.take() {
            self.limit = probe.previous_limit;
            // This also invalidates a successor if our old lease already expired.
            if let Some(coordinator) = &self.coordinator {
                coordinator.invalidate(now);
            }
            drop(probe);
        }
        self.invalidate_window(now);
    }
    /// No queued demand, pause or cancellation: preserve live permits, release
    /// trial ownership and avoid a stale baseline when demand returns.
    pub fn idle(&mut self, now: Instant) {
        self.abandon_probe(now);
        if let Some(coordinator) = &self.coordinator {
            coordinator.withdraw();
        }
        self.samples.clear();
        self.last_poll = None;
        self.generation = None;
        self.settle_until = self.settle_until.max(now + SETTLE_TIME);
    }
    pub fn limit_for_resources(&mut self, maximum: usize, now: Instant) {
        let maximum = maximum.max(1);
        self.resource_limit = maximum;
        if self.limit > maximum {
            self.abandon_probe(now);
            self.limit = self.limit.min(maximum);
            if let Some(coordinator) = &self.coordinator {
                coordinator.invalidate(now);
            }
            self.samples.clear();
            self.settle_until = self.settle_until.max(now + SETTLE_TIME);
        }
    }

    /// Polls can be frequent; bounded history and decisions update twice a second.
    /// The history keeps sliding during a plateau. A trial must use a complete
    /// fresh window after settling, with no intervening trial from another pool.
    pub fn observe(&mut self, now: Instant, bytes: u64, has_room: impl FnOnce() -> bool) {
        if self
            .last_poll
            .is_some_and(|last| now.saturating_duration_since(last) > IDLE_GAP)
            || self
                .samples
                .samples
                .back()
                .is_some_and(|last| bytes < last.bytes)
        {
            self.idle(now);
            self.plateau = None;
            self.next_sample = now;
        }
        self.last_poll = Some(now);
        if now < self.next_sample {
            return;
        }
        self.next_sample = now + SAMPLE_INTERVAL;
        self.samples.push(now, bytes);

        if let Some(probe) = &self.probe {
            if now.saturating_duration_since(probe.started) >= MAX_TRIAL_TIME {
                self.reject(now);
                return;
            }
            if let Some(lease) = &probe.lease {
                match lease.valid(now) {
                    Some(true) => {}
                    Some(false) => {
                        self.abandon_probe(now);
                        return;
                    }
                    None => {
                        self.invalidate_window(now);
                        return;
                    }
                }
            }
        }
        if self.active != self.limit || now < self.settle_until {
            self.invalidate_window(now.max(self.settle_until));
            if let Some(coordinator) = &self.coordinator {
                coordinator.withdraw();
            }
            return;
        }
        if !has_room() {
            self.abandon_probe(now);
            self.plateau = None;
            if let Some(coordinator) = &self.coordinator {
                coordinator.withdraw();
            }
            return;
        }
        if self.probe.is_none() {
            if self.limit >= self.ceiling.min(self.resource_limit)
                && !(self.bidirectional && self.limit > 1)
            {
                if let Some(coordinator) = &self.coordinator {
                    coordinator.withdraw();
                }
                return;
            }
            if let Some(coordinator) = &self.coordinator {
                let Some(generation) = coordinator.snapshot(now) else {
                    self.invalidate_window(now);
                    return;
                };
                if self.generation != Some(generation) {
                    self.generation = Some(generation);
                    self.invalidate_window(now);
                }
            }
        }
        if now.saturating_duration_since(self.valid_since) < SAMPLE_WINDOW {
            return;
        }
        let Some(rate) = self.samples.rate(now) else {
            return;
        };
        if !rate.flowing || rate.mean == 0.0 {
            self.abandon_probe(now);
            return;
        }
        if !rate.stable {
            self.stable_since = None;
            return;
        }

        if let Some(probe) = &self.probe {
            let smaller = self.limit < probe.previous_limit;
            let minimum_rate = if smaller { probe.baseline_rate * 0.98 } else { match self.minimum_gain {
                MinimumGain::TenPercent => probe.baseline_rate * MIN_RELATIVE_GAIN,
                MinimumGain::OneMegabytePerSecond => probe.baseline_rate + MIN_ABSOLUTE_GAIN,
            } };
            if rate.mean < minimum_rate {
                self.reject(now);
            } else {
                self.probe = None;
                self.plateau = None;
                self.proven_gain = !smaller;
                self.trial_outcome = Some(TrialOutcome::Accepted(self.limit));
                // This measured window is valid for the next standalone trial.
                // Coordinated controllers must first observe the new generation.
                self.stable_since = None;
            }
            return;
        }
        if self
            .plateau
            .as_ref()
            .is_some_and(|p| (rate.mean - p.rate).abs() > p.rate * STABLE_SWING)
        {
            self.plateau = None;
            self.stable_since = None;
        }
        let stable_since = *self.stable_since.get_or_insert(now);
        // Require 5, 10, then 20 seconds of fresh stable evidence after repeated
        // failed trials. A changed rate bypasses this extra plateau evidence.
        let extra = self.plateau.as_ref().map_or(Duration::ZERO, |p| {
            SAMPLE_WINDOW * ((1u32 << p.failures.saturating_sub(1).min(2)) - 1)
        });
        if now.saturating_duration_since(stable_since) < extra {
            return;
        }
        let lease = if let Some(coordinator) = &self.coordinator {
            let Some(lease) = coordinator.acquire(now, self.generation.unwrap()) else {
                return;
            };
            Some(lease)
        } else {
            None
        };
        self.probe = Some(Probe {
            previous_limit: self.limit,
            baseline_rate: rate.mean,
            started: now,
            lease,
        });
        let smaller = self.bidirectional && self.limit > 1
            && (self.lower_next || self.limit >= self.ceiling.min(self.resource_limit));
        if self.bidirectional { self.lower_next = !smaller; }
        self.limit = if smaller {
            (self.limit / 2).max(1)
        } else if self.proven_gain || self.limit < INITIAL_CONNECTIONS {
            self.limit.saturating_mul(2)
        } else {
            self.limit.saturating_add((self.limit / 4).max(2))
        }
        .min(self.ceiling)
        .min(self.resource_limit);
        self.invalidate_window(now);
        self.settle_until = now + SETTLE_TIME;
    }

    fn reject(&mut self, now: Instant) {
        let Some(probe) = &self.probe else {
            return;
        };
        let baseline = probe.baseline_rate;
        self.trial_outcome = Some(TrialOutcome::Rejected);
        let failures = self
            .plateau
            .as_ref()
            .filter(|p| (baseline - p.rate).abs() <= p.rate * STABLE_SWING)
            .map_or(1, |p| p.failures.saturating_add(1));
        self.abandon_probe(now);
        self.plateau = Some(Plateau {
            rate: baseline,
            failures,
        });
        self.proven_gain = false;
        self.settle_until = now + SETTLE_TIME;
    }
    pub fn back_off(&mut self, until: Instant) {
        // Halve the actual admission allowance, including a trial in progress.
        let maximum = (self.limit / 2).max(1);
        self.idle(Instant::now());
        self.limit = maximum;
        if let Some(coordinator) = &self.coordinator {
            coordinator.invalidate(Instant::now());
        }
        self.plateau = None;
        self.proven_gain = false;
        self.settle_until = self.settle_until.max(until + SETTLE_TIME);
    }
}

#[cfg(test)]
#[path = "download_connections_tests.rs"]
mod tests;

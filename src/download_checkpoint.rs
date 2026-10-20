//! How often a running download saves its progress.
//!
//! A save flushes buffered pieces before publishing their recovery journal. HDD
//! writers on the same volume share two full drive-cache barriers: one before
//! journal publication and one after the journals and directories are synced.
//! This preserves data-before-journal durability while avoiding several full
//! cache flushes per small file. Internal SSDs retain their frequent save path.
//! Busy external writers prioritize received chunks ahead of the soft timer,
//! with a mandatory save after 512 MiB or sixty seconds of unsaved progress.
//! A crash or unplug fetches again only bytes absent from a durable checkpoint.

use std::time::{Duration, Instant};

#[path = "download_checkpoint_batch.rs"]
mod batch;
pub(crate) use batch::{commit, commit_guarded, snapshot};

#[cfg(test)]
#[path = "download_checkpoint_tests.rs"]
mod tests;

/// Legacy single-destination helpers use this environment value. The continuous
/// queue supplies the same kind per root and binds it to the validated anchor.
pub(crate) const DESTINATION_ENVIRONMENT: &str = "MYCLOUDDRIVER_DOWNLOAD_DESTINATION";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CheckpointPolicy {
    pub interval: Duration,
    /// Save sooner once this much received data is unsaved.
    pub unsaved_bytes: u64,
}

impl CheckpointPolicy {
    pub const FREQUENT: Self = Self { interval: Duration::from_secs(1), unsaved_bytes: u64::MAX };
    pub const RELAXED: Self = Self { interval: Duration::from_secs(20), unsaved_bytes: 512 << 20 };

    pub fn for_destination(kind: Option<&str>) -> Self {
        match kind {
            Some("external") | Some("network") => Self::RELAXED,
            _ => Self::FREQUENT,
        }
    }

    /// The policy for this process, decided once from the environment the native app started it with.
    pub fn current() -> Self {
        static CURRENT: std::sync::OnceLock<CheckpointPolicy> = std::sync::OnceLock::new();
        *CURRENT.get_or_init(|| Self::for_destination(std::env::var(DESTINATION_ENVIRONMENT).ok().as_deref()))
    }
}

/// When the next save is due. Pure state over `Instant`s, so it is tested without waiting.
#[derive(Debug)]
pub(crate) struct CheckpointSchedule {
    policy: CheckpointPolicy,
    due_at: Instant,
    unsaved: u64,
    hard_due_at: Instant,
}

impl CheckpointSchedule {
    pub fn new(policy: CheckpointPolicy, now: Instant) -> Self {
        Self { policy, due_at: now + policy.interval, unsaved: 0, hard_due_at: now + Duration::from_secs(60) }
    }

    pub fn due_at(&self) -> Instant {
        self.due_at
    }

    /// A busy HDD consumer drains already received chunks ahead of its soft
    /// timer. This bound still saves after 512 MiB or sixty seconds; internal
    /// destinations keep their existing one-second deadline.
    pub fn must_save(&self, now: Instant) -> bool {
        self.unsaved >= self.policy.unsaved_bytes || now >= self.hard_due_at
            || (self.policy == CheckpointPolicy::FREQUENT && now >= self.due_at)
    }

    /// Records received data; enough of it makes the save due now, and an overdue save is never pushed back.
    pub fn received(&mut self, bytes: u64, now: Instant) {
        self.unsaved = self.unsaved.saturating_add(bytes);
        if self.unsaved >= self.policy.unsaved_bytes {
            self.due_at = self.due_at.min(now);
        }
    }

    pub fn saved(&mut self, now: Instant) {
        self.due_at = now + self.policy.interval;
        self.hard_due_at = now + Duration::from_secs(60);
        self.unsaved = 0;
    }
}

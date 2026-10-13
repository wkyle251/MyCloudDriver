//! Bounded aggregate diagnostics, independent of data writes and progress UI.
//! No paths, names, URLs, credentials or response bodies enter these events.
use std::{
    sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Mutex, OnceLock},
    time::{Duration, Instant},
};
use serde::Serialize;

static ENABLED: AtomicBool = AtomicBool::new(false);
static ACTIVE: [AtomicU64; 28] = [const { AtomicU64::new(0) }; 28];

#[derive(Clone, Copy)]
pub(crate) enum Kind { ResumeRead, FinalRead, Checkpoint, CacheHit, CacheMiss, CheckpointWait, CheckpointSync, PayloadWrite,
    ReadPreparation, ReadQueueWait, ReadGateWait, ReadTurnWait, ReadIo, ReadHash, SchedulerPass, ReplayRead,
    ResumeNew, ResumeMissing, ResumeUnverified, ResumeLength, ResumeRevision, ResumeSource, ResumeValidator,
    ResumeRange, ResumeAccepted, ResumeFull, ResumePromoted, ResumeTail }
impl Kind {
    fn index(self) -> usize { self as usize }
    fn name(self) -> &'static str {
        match self {
            Self::ResumeRead => "resume_read", Self::FinalRead => "final_read",
            Self::Checkpoint => "checkpoint", Self::CacheHit => "retry_cache_hit",
            Self::CacheMiss => "retry_cache_miss",
            Self::CheckpointWait => "checkpoint_wait", Self::CheckpointSync => "checkpoint_sync", Self::PayloadWrite => "payload_write",
            Self::ReadPreparation => "read_preparation", Self::ReadQueueWait => "read_queue_wait",
            Self::ReadGateWait => "read_gate_wait", Self::ReadTurnWait => "read_turn_wait",
            Self::ReadIo => "read_io", Self::ReadHash => "read_hash", Self::SchedulerPass => "scheduler_pass",
            Self::ReplayRead => "replay_read",
            Self::ResumeNew => "resume_plan_new", Self::ResumeMissing => "resume_plan_missing",
            Self::ResumeUnverified => "resume_plan_unverified", Self::ResumeLength => "resume_plan_length",
            Self::ResumeRevision => "resume_plan_revision", Self::ResumeSource => "resume_plan_source",
            Self::ResumeValidator => "resume_plan_validator", Self::ResumeRange => "resume_plan_range",
            Self::ResumeAccepted => "resume_plan_accepted", Self::ResumeFull => "resume_plan_full",
            Self::ResumePromoted => "resume_plan_promoted", Self::ResumeTail => "resume_plan_tail",
        }
    }
}
const KINDS: [Kind; 28] = [Kind::ResumeRead, Kind::FinalRead, Kind::Checkpoint, Kind::CacheHit, Kind::CacheMiss,
    Kind::CheckpointWait, Kind::CheckpointSync, Kind::PayloadWrite, Kind::ReadPreparation, Kind::ReadQueueWait,
    Kind::ReadGateWait, Kind::ReadTurnWait, Kind::ReadIo, Kind::ReadHash, Kind::SchedulerPass, Kind::ReplayRead,
    Kind::ResumeNew, Kind::ResumeMissing, Kind::ResumeUnverified, Kind::ResumeLength, Kind::ResumeRevision,
    Kind::ResumeSource, Kind::ResumeValidator, Kind::ResumeRange, Kind::ResumeAccepted, Kind::ResumeFull,
    Kind::ResumePromoted, Kind::ResumeTail];

#[derive(Default, Serialize)]
struct Metric {
    count: u64,
    bytes: u64,
    elapsed_ms: u64,
    max_ms: u64,
    failed: u64,
    active: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    transfer_id: Option<String>,
}
#[derive(Default)]
struct Stats { metrics: [Metric; 28] }
impl Stats {
    fn add(&mut self, kind: Kind, id: &str, bytes: u64, elapsed: Duration, failed: bool) {
        let metric = &mut self.metrics[kind.index()];
        let millis = elapsed.as_millis().min(u64::MAX as u128) as u64;
        metric.count = metric.count.saturating_add(1);
        metric.bytes = metric.bytes.saturating_add(bytes);
        metric.elapsed_ms = metric.elapsed_ms.saturating_add(millis);
        metric.failed = metric.failed.saturating_add(u64::from(failed));
        if millis >= metric.max_ms {
            metric.max_ms = millis;
            // Only one example per fixed metric, regardless of queue size.
            metric.transfer_id = (!id.is_empty()).then(|| id.chars().take(256).collect());
        }
    }
    fn drain(&mut self) -> std::collections::BTreeMap<&'static str, Metric> {
        KINDS.into_iter().zip(std::mem::take(&mut self.metrics))
            .map(|(kind, mut metric)| { metric.active = ACTIVE[kind.index()].load(Ordering::Relaxed); (kind, metric) })
            .filter(|(_, metric)| metric.count != 0 || metric.active != 0 || metric.bytes != 0)
            .map(|(kind, metric)| (kind.name(), metric)).collect()
    }
}
fn stats() -> &'static Mutex<Stats> {
    static STATS: OnceLock<Mutex<Stats>> = OnceLock::new();
    STATS.get_or_init(Default::default)
}
#[cfg(test)]
pub(crate) fn test_metrics() -> serde_json::Value {
    serde_json::to_value(stats().lock().unwrap().drain()).unwrap()
}

/// Count actual bytes read, including a partial read before an error. Waiting
/// for the HDD verification gate is included in latency, not in byte counts.
pub(crate) struct Operation {
    kind: Kind, id: String, start: Instant, complete: bool, enabled: bool,
}
impl Operation {
    pub fn new(kind: Kind, id: &str) -> Self {
        let enabled = ENABLED.load(Ordering::Relaxed);
        if enabled { ACTIVE[kind.index()].fetch_add(1, Ordering::Relaxed); }
        Self { kind, id: if enabled { id.chars().take(256).collect() } else { String::new() },
            start: Instant::now(), complete: false, enabled }
    }
    pub fn add_bytes(&mut self, bytes: u64) {
        if self.enabled {
            let mut stats = stats().lock().unwrap();
            let metric = &mut stats.metrics[self.kind.index()];
            metric.bytes = metric.bytes.saturating_add(bytes);
        }
    }
    pub fn complete(&mut self) { self.complete = true; }
    /// Admission is scheduler control flow, not a failed integrity read.
    pub fn deferred(&mut self) {
        if self.enabled { ACTIVE[self.kind.index()].fetch_sub(1, Ordering::Relaxed); self.enabled = false; }
    }
}
impl Drop for Operation {
    fn drop(&mut self) {
        if self.enabled {
            ACTIVE[self.kind.index()].fetch_sub(1, Ordering::Relaxed);
            stats().lock().unwrap().add(self.kind, &self.id, 0, self.start.elapsed(), !self.complete);
        }
    }
}
pub(crate) fn cache(hit: bool, bytes: u64) {
    if ENABLED.load(Ordering::Relaxed) {
        stats().lock().unwrap().add(if hit { Kind::CacheHit } else { Kind::CacheMiss }, "", bytes, Duration::ZERO, false);
    }
}

pub(crate) fn elapsed(kind: Kind, elapsed: Duration) {
    if ENABLED.load(Ordering::Relaxed) { stats().lock().unwrap().add(kind, "", 0, elapsed, false); }
}

/// Fixed aggregate reason codes only; never retain source identifiers or headers.
pub(crate) fn resume(kind: Kind, bytes: u64) {
    if ENABLED.load(Ordering::Relaxed) {
        stats().lock().unwrap().add(kind, "", bytes, Duration::ZERO, false);
    }
}

/// A separate observer remains responsive if Tokio's blocking pool or async
/// workers stall. Its single bounded numeric file never contains payload data.
struct SetupObserver { stop: std::sync::Arc<AtomicBool>, thread: Option<std::thread::JoinHandle<()>> }
impl SetupObserver {
    fn start() -> Option<Self> {
        let directory = std::path::PathBuf::from(std::env::var_os("HOME")?)
            .join("Library/Logs/MyCloudDriver/Downloads");
        Self::start_in(directory)
    }
    fn start_in(directory: std::path::PathBuf) -> Option<Self> {
        let metadata = std::fs::symlink_metadata(&directory).ok()?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() { return None; }
        let stop = std::sync::Arc::new(AtomicBool::new(false)); let stopped = stop.clone();
        let thread = std::thread::Builder::new().name("download-setup-diagnostics".into()).spawn(move || {
            use std::{io::Write, os::unix::fs::OpenOptionsExt, time::{SystemTime, UNIX_EPOCH}};
            let mut sequence = 0u64;
            while !stopped.load(Ordering::Relaxed) {
                let row = serde_json::json!({"version":1,"helper_pid":std::process::id(),
                    "updated_at":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64(),
                    "waits":pikpak::download_waits::snapshot()});
                if let Ok(bytes) = serde_json::to_vec(&row) {
                    if bytes.len() <= 65536 {
                        let temporary = directory.join(format!(".setup-waits-{}-{sequence}.tmp", std::process::id()));
                        sequence = sequence.wrapping_add(1);
                        if let Ok(mut file) = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary) {
                            let written = file.write_all(&bytes).is_ok(); drop(file);
                            if written { let _ = std::fs::rename(&temporary, directory.join("setup-waits-v1.json")); }
                            let _ = std::fs::remove_file(&temporary);
                        }
                    }
                }
                std::thread::park_timeout(Duration::from_secs(1));
            }
        }).ok()?;
        Some(Self { stop, thread:Some(thread) })
    }
}
impl Drop for SetupObserver {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() { thread.thread().unpark(); }
    }
}

pub(crate) struct Telemetry { task: Option<tokio::task::JoinHandle<()>>, _setup: Option<SetupObserver> }
impl Telemetry {
    pub fn start(enabled: bool) -> Self {
        if !enabled { return Self { task:None, _setup:None }; }
        ENABLED.store(true, Ordering::Relaxed);
        pikpak::download_waits::enable(true);
        let setup = SetupObserver::start();
        let counter = pikpak::download_network::Network::shared().received_counter();
        Self { task:Some(tokio::spawn(async move {
            let mut timer = tokio::time::interval(Duration::from_secs(1));
            timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut last_summary = Instant::now();
            loop {
                timer.tick().await;
                let diagnostics = if last_summary.elapsed() >= Duration::from_secs(10) {
                    last_summary = Instant::now();
                    Some(stats().lock().unwrap().drain())
                } else { None };
                // Diagnostics sample received bytes independently of per-file
                // progress publication and disk flush completion.
                let buffer = crate::download_buffer::snapshot();
                let disk_traffic = crate::download_verification::traffic_snapshot();
                let mut receive_diagnostics = pikpak::download_waits::receive_diagnostics();
                receive_diagnostics.insert("connection_known_cooldown_remaining_ms".into(), pikpak::download_network::known_cooldown_remaining_ms());
                let event = serde_json::json!({"event":"network_sample",
                    "received_bytes":counter.load(Ordering::Relaxed), "diagnostics":diagnostics,
                    "buffered_bytes":buffer.used,"buffer_reserved_bytes":buffer.reserved,"buffer_peak_bytes":buffer.peak,"buffer_limit_bytes":buffer.limit,
                    "buffer_configured_bytes":buffer.configured,"buffer_reserve_bytes":buffer.reserve,"buffer_memory_pressure":buffer.pressure,
                    "disk_traffic":disk_traffic, "receive_diagnostics":receive_diagnostics});
                let mut output = std::io::stdout().lock();
                use std::io::Write;
                let _ = writeln!(output, "{}{}", crate::DOWNLOAD_PROGRESS_PREFIX, event);
                let _ = output.flush();
            }
        })), _setup:setup }
    }
}
impl Drop for Telemetry {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() { task.abort(); ENABLED.store(false, Ordering::Relaxed); pikpak::download_waits::enable(false); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn setup_observer_publishes_one_private_numeric_snapshot_and_stops_cleanly() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("setup-waits-v1.json");
        let mut observer = SetupObserver::start_in(directory.path().to_owned()).unwrap();
        let deadline = Instant::now()+Duration::from_secs(3);
        while !path.exists() && Instant::now()<deadline { std::thread::sleep(Duration::from_millis(10)); }
        let row: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(row["version"], 1);
        assert_eq!(row["helper_pid"], std::process::id());
        assert!(row["updated_at"].as_f64().unwrap()>0.0);
        for metric in row["waits"]["stages"].as_object().unwrap().values() {
            assert!(metric.as_object().unwrap().values().all(serde_json::Value::is_u64));
        }
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let thread = observer.thread.take().unwrap();
        drop(observer); thread.thread().unpark(); thread.join().unwrap();
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
        let link = directory.path().join("linked");
        std::os::unix::fs::symlink(directory.path(), &link).unwrap();
        assert!(SetupObserver::start_in(link).is_none());
    }
    #[test]
    fn summaries_keep_exact_counts_and_only_one_bounded_example_per_kind() {
        let mut stats = Stats::default();
        for _ in 0..100_000 { stats.add(Kind::ResumeRead, "opaque-id", 256, Duration::from_millis(2), false); }
        stats.add(Kind::Checkpoint, "slow-id", 0, Duration::from_secs(4), true);
        let summary = stats.drain();
        assert_eq!(summary["resume_read"].count, 100_000);
        assert_eq!(summary["resume_read"].bytes, 25_600_000);
        assert_eq!(summary["checkpoint"].max_ms, 4_000);
        assert_eq!(summary["checkpoint"].failed, 1);
        assert!(serde_json::to_vec(&summary).unwrap().len() < 512);
        assert!(stats.drain().is_empty());
    }
    #[test]
    fn anonymous_stage_timings_keep_maxima_without_requiring_a_transfer_id() {
        let mut stats = Stats::default();
        stats.add(Kind::SchedulerPass, "", 0, Duration::from_millis(87), false);
        stats.add(Kind::SchedulerPass, "", 0, Duration::from_millis(2), false);
        stats.add(Kind::ReadQueueWait, "", 0, Duration::from_secs(400), false);
        let summary = stats.drain();
        assert_eq!(summary["scheduler_pass"].max_ms, 87);
        assert_eq!(summary["scheduler_pass"].elapsed_ms, 89);
        assert_eq!(summary["read_queue_wait"].max_ms, 400_000);
        assert!(summary.values().all(|metric| metric.transfer_id.is_none()));
    }
}

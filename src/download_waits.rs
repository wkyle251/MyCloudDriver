//! Anonymous setup-wait diagnostics. Fixed stage names and numeric counters
//! only; no transfer identity, paths, URLs, credentials or response contents.
use serde::Serialize;
use std::{
    collections::{BTreeMap, HashMap},
    future::Future,
    sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
        Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

static ENABLED: AtomicBool = AtomicBool::new(false);
// Admission safety is independent of whether diagnostics are enabled. A RAM
// stall invalidates warm-start evidence even if it ends before the next poll.
static RANGE_RESOURCE_GENERATION: AtomicU64 = AtomicU64::new(0);
static RANGE_RESOURCE_WAITS: AtomicUsize = AtomicUsize::new(0);
static RANGE_MEMORY_PRESSURE: AtomicU32 = AtomicU32::new(1);

pub fn range_memory_pressure(level: u32) {
    let previous = RANGE_MEMORY_PRESSURE.swap(level, Ordering::AcqRel);
    if level >= 2 && previous < 2 {
        RANGE_RESOURCE_GENERATION.fetch_add(1, Ordering::AcqRel);
    }
}
pub(crate) fn range_resources() -> (u64, bool) {
    let before = RANGE_RESOURCE_GENERATION.load(Ordering::Acquire);
    let blocked = RANGE_RESOURCE_WAITS.load(Ordering::Acquire) > 0
        || RANGE_MEMORY_PRESSURE.load(Ordering::Acquire) >= 2;
    let after = RANGE_RESOURCE_GENERATION.load(Ordering::Acquire);
    // A short wait may both begin and end between the two loads. Never admit
    // from the old generation merely because its active gauge is already zero.
    (after, blocked || before != after)
}
#[cfg(test)]
pub(crate) fn range_startup_test_guard() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|error| error.into_inner())
}

static RANGE_ACTIVE: AtomicU64 = AtomicU64::new(0);
static RANGE_LIMIT: AtomicU64 = AtomicU64::new(0);
static RANGE_HEADER_ACTIVE: AtomicU64 = AtomicU64::new(0);
static RANGE_HEADER_COUNT: AtomicU64 = AtomicU64::new(0);
static RANGE_HEADER_TOTAL_MS: AtomicU64 = AtomicU64::new(0);
static RANGE_HEADER_MAX_MS: AtomicU64 = AtomicU64::new(0);
static RANGE_HEADER_FAILED: AtomicU64 = AtomicU64::new(0);
static RANGE_TRIAL_ACCEPTED: AtomicU64 = AtomicU64::new(0);
static RANGE_TRIAL_REJECTED: AtomicU64 = AtomicU64::new(0);
static RANGE_STARTUP_REUSED: AtomicU64 = AtomicU64::new(0);

/// These gauges count live range request permits and controller admission,
/// including headers still in flight. They are not file-worker counts.
pub(crate) struct RangeChannel;
impl RangeChannel {
    pub(crate) fn new() -> Self {
        RANGE_ACTIVE.fetch_add(1, Ordering::Relaxed); Self
    }
}
impl Drop for RangeChannel {
    fn drop(&mut self) { RANGE_ACTIVE.fetch_sub(1, Ordering::Relaxed); }
}
#[derive(Default)]
pub(crate) struct RangeAdmission { limit: u64 }
impl RangeAdmission {
    pub(crate) fn set(&mut self, limit: usize) {
        let limit = limit as u64;
        if limit >= self.limit { RANGE_LIMIT.fetch_add(limit - self.limit, Ordering::Relaxed); }
        else { RANGE_LIMIT.fetch_sub(self.limit - limit, Ordering::Relaxed); }
        self.limit = limit;
    }
}
impl Drop for RangeAdmission {
    fn drop(&mut self) { RANGE_LIMIT.fetch_sub(self.limit, Ordering::Relaxed); }
}
struct RangeHeader { started: Instant, success: bool }
impl Drop for RangeHeader {
    fn drop(&mut self) {
        let elapsed = millis(self.started.elapsed());
        RANGE_HEADER_ACTIVE.fetch_sub(1, Ordering::Relaxed);
        RANGE_HEADER_COUNT.fetch_add(1, Ordering::Relaxed);
        RANGE_HEADER_TOTAL_MS.fetch_add(elapsed, Ordering::Relaxed);
        RANGE_HEADER_MAX_MS.fetch_max(elapsed, Ordering::Relaxed);
        if !self.success { RANGE_HEADER_FAILED.fetch_add(1, Ordering::Relaxed); }
    }
}
pub(crate) async fn range_headers(
    future: impl Future<Output = reqwest::Result<reqwest::Response>>,
) -> reqwest::Result<reqwest::Response> {
    RANGE_HEADER_ACTIVE.fetch_add(1, Ordering::Relaxed);
    let mut measured = RangeHeader { started: Instant::now(), success: false };
    let result = future.await;
    measured.success = result.as_ref().is_ok_and(|response| response.status().is_success());
    result
}
pub(crate) fn range_trial(accepted: bool) {
    if accepted { RANGE_TRIAL_ACCEPTED.fetch_add(1, Ordering::Relaxed); }
    else { RANGE_TRIAL_REJECTED.fetch_add(1, Ordering::Relaxed); }
}
pub(crate) fn range_startup_reused() { RANGE_STARTUP_REUSED.fetch_add(1, Ordering::Relaxed); }

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    DownloadUrl,
    AccountMetadata,
    AccountToken,
    AccountCaptcha,
    AccountHeaders,
    AccountBody,
    AccountBackoff,
    GuestMetadata,
    GuestCaptcha,
    GuestHeaders,
    GuestBody,
    GuestRefreshLock,
    GuestRefreshHeaders,
    GuestRefreshBody,
    ShareLock,
    ShareCache,
    ShareProcessLock,
    ShareInventory,
    ShareInventoryWait,
    ShareInventoryPage,
    ShareCreate,
    CacheOpen,
    SetupPermit,
    ReceivingSlot,
    ContentPermit,
    ContentHeaders,
    RangeProbe,
    FsOpen,
    FsMetadata,
    OutputLease,
    AccountCaptchaLock,
    AccountCaptchaHeaders,
    AccountCaptchaBody,
    AuthLock,
    AuthFileLock,
    AuthHeaders,
    AuthBody,
    RamBodyLimit,
    RamSharedLimit,
    RamPressure,
    ContentBudget,
    EndpointCooldown,
    EndpointCapacity,
    SharedContentSlots,
}
impl Kind {
    fn name(self) -> &'static str {
        match self {
            Self::DownloadUrl => "download_url",
            Self::AccountMetadata => "account_metadata",
            Self::AccountToken => "account_token",
            Self::AccountCaptcha => "account_captcha",
            Self::AccountHeaders => "account_headers",
            Self::AccountBody => "account_body",
            Self::AccountBackoff => "account_backoff",
            Self::GuestMetadata => "guest_metadata",
            Self::GuestCaptcha => "guest_captcha",
            Self::GuestHeaders => "guest_headers",
            Self::GuestBody => "guest_body",
            Self::GuestRefreshLock => "guest_refresh_lock",
            Self::GuestRefreshHeaders => "guest_refresh_headers",
            Self::GuestRefreshBody => "guest_refresh_body",
            Self::ShareLock => "share_lock",
            Self::ShareCache => "share_cache",
            Self::ShareProcessLock => "share_process_lock",
            Self::ShareInventory => "share_inventory",
            Self::ShareInventoryWait => "share_inventory_wait",
            Self::ShareInventoryPage => "share_inventory_page",
            Self::ShareCreate => "share_create",
            Self::CacheOpen => "cache_open",
            Self::SetupPermit => "setup_permit",
            Self::ReceivingSlot => "receiving_slot",
            Self::ContentPermit => "content_permit",
            Self::ContentHeaders => "content_headers",
            Self::RangeProbe => "range_probe",
            Self::FsOpen => "fs_open",
            Self::FsMetadata => "fs_metadata",
            Self::OutputLease => "output_lease",
            Self::AccountCaptchaLock => "account_captcha_lock",
            Self::AccountCaptchaHeaders => "account_captcha_headers",
            Self::AccountCaptchaBody => "account_captcha_body",
            Self::AuthLock => "auth_lock",
            Self::AuthFileLock => "auth_file_lock",
            Self::AuthHeaders => "auth_headers",
            Self::AuthBody => "auth_body",
            Self::RamBodyLimit => "ram_body_limit",
            Self::RamSharedLimit => "ram_shared_limit",
            Self::RamPressure => "ram_pressure",
            Self::ContentBudget => "connection_budget",
            Self::EndpointCooldown => "connection_cooldown",
            Self::EndpointCapacity => "connection_endpoint_capacity",
            Self::SharedContentSlots => "connection_shared_slots",
        }
    }
}

#[derive(Clone, Default, Serialize)]
pub struct Metric {
    count: u64,
    total_ms: u64,
    max_ms: u64,
    active: u64,
    oldest_ms: u64,
}
#[derive(Default)]
struct State {
    next: u64,
    active: HashMap<u64, (&'static str, Instant)>,
    completed: BTreeMap<&'static str, Metric>,
    responses: BTreeMap<&'static str, u64>,
}
fn millis(duration: Duration) -> u64 {
    duration.as_millis().min(u64::MAX as u128) as u64
}
impl State {
    fn enter(&mut self, name: &'static str, now: Instant) -> u64 {
        let number = self.next;
        self.next = self.next.wrapping_add(1);
        self.active.insert(number, (name, now));
        number
    }
    fn finish(&mut self, number: u64, now: Instant) {
        if let Some((name, start)) = self.active.remove(&number) {
            let elapsed = millis(now.saturating_duration_since(start));
            let metric = self.completed.entry(name).or_default();
            metric.count = metric.count.saturating_add(1);
            metric.total_ms = metric.total_ms.saturating_add(elapsed);
            metric.max_ms = metric.max_ms.max(elapsed);
        }
    }
    fn snapshot(&self, now: Instant) -> Snapshot {
        let mut stages = self.completed.clone();
        for (name, start) in self.active.values() {
            let metric = stages.entry(name).or_default();
            metric.active = metric.active.saturating_add(1);
            metric.oldest_ms = metric
                .oldest_ms
                .max(millis(now.saturating_duration_since(*start)));
        }
        Snapshot {
            stages,
            responses: self.responses.clone(),
        }
    }
}
fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(Default::default)
}
pub fn enable(enabled: bool) {
    ENABLED.store(enabled, Ordering::Relaxed);
}
pub struct Stage { diagnostic: Option<u64>, resource: bool }
impl Stage {
    pub fn enter(kind: Kind) -> Self {
        let resource = matches!(kind, Kind::RamBodyLimit | Kind::RamSharedLimit | Kind::RamPressure);
        if resource {
            RANGE_RESOURCE_WAITS.fetch_add(1, Ordering::AcqRel);
            RANGE_RESOURCE_GENERATION.fetch_add(1, Ordering::AcqRel);
        }
        Self { resource, diagnostic: ENABLED.load(Ordering::Relaxed).then(|| {
            state()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .enter(kind.name(), Instant::now())
        }) }
    }
}
impl Drop for Stage {
    fn drop(&mut self) {
        if self.resource { RANGE_RESOURCE_WAITS.fetch_sub(1, Ordering::AcqRel); }
        if let Some(number) = self.diagnostic {
            state()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .finish(number, Instant::now());
        }
    }
}
pub async fn track<T>(kind: Kind, future: impl Future<Output = T>) -> T {
    let _stage = Stage::enter(kind);
    future.await
}
#[derive(Serialize)]
pub struct Snapshot {
    stages: BTreeMap<&'static str, Metric>,
    responses: BTreeMap<&'static str, u64>,
}
pub fn snapshot() -> Snapshot {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .snapshot(Instant::now())
}

/// Numeric categories deliberately exclude endpoint strings and error text.
pub fn response(guest: bool, status: u16) {
    if !ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let name = match (guest, status) {
        (false, 200..=299) => "account_success",
        (true, 200..=299) => "guest_success",
        (false, 429) => "account_429",
        (true, 429) => "guest_429",
        (false, 500..=599) => "account_5xx",
        (true, 500..=599) => "guest_5xx",
        (false, 401 | 403) => "account_auth",
        (true, 401 | 403) => "guest_auth",
        (false, _) => "account_other",
        (true, _) => "guest_other",
    };
    let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
    let value = state.responses.entry(name).or_default();
    *value = value.saturating_add(1);
}

fn counter(name: &'static str) {
    if !ENABLED.load(Ordering::Relaxed) { return; }
    let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
    let value = state.responses.entry(name).or_default();
    *value = value.saturating_add(1);
}

pub enum PayloadEvent { Timeout, Connection, RangeValidation, Io, Interrupted, Unavailable,
    StreamingFallback, EarlyEmptyRetry, DeferredRearm }
pub fn payload_event(event: PayloadEvent) {
    counter(match event {
        PayloadEvent::Timeout => "payload_timeout", PayloadEvent::Connection => "payload_connection",
        PayloadEvent::RangeValidation => "payload_range_validation", PayloadEvent::Io => "payload_io",
        PayloadEvent::Interrupted => "payload_interrupted", PayloadEvent::Unavailable => "payload_unavailable",
        PayloadEvent::StreamingFallback => "payload_streaming_fallback",
        PayloadEvent::EarlyEmptyRetry => "payload_early_empty_retry", PayloadEvent::DeferredRearm => "payload_deferred_rearm",
    });
}
pub fn payload_response(status: u16) {
    counter(match status { 200..=299 => "payload_http_success", 429 => "payload_http_429",
        500..=599 => "payload_http_5xx", 401 | 403 => "payload_http_auth", 416 => "payload_http_416", _ => "payload_http_other" });
}
pub fn connection_blocked(kind: Kind) {
    counter(match kind {
        Kind::ContentBudget => "connection_budget_blocked_polls",
        Kind::EndpointCooldown => "connection_cooldown_blocked_polls",
        Kind::EndpointCapacity => "connection_endpoint_blocked_polls",
        Kind::SharedContentSlots => "connection_shared_blocked_polls",
        _ => return,
    });
}
pub fn cooldown_requested() { counter("connection_cooldown_events"); }

/// Fixed numeric keys only. These cumulative counters also enter the rotated
/// application log, so a week-long run can be investigated after the fact.
pub fn receive_diagnostics() -> BTreeMap<String, u64> {
    let snapshot = snapshot();
    let mut result = BTreeMap::new();
    for kind in [Kind::RamBodyLimit, Kind::RamSharedLimit, Kind::RamPressure, Kind::ContentBudget,
        Kind::EndpointCooldown, Kind::EndpointCapacity, Kind::SharedContentSlots] {
        let name = kind.name();
        let metric = snapshot.stages.get(name).cloned().unwrap_or_default();
        for (suffix, value) in [("count", metric.count), ("active", metric.active), ("total_ms", metric.total_ms),
            ("max_ms", metric.max_ms), ("oldest_ms", metric.oldest_ms)] {
            result.insert(format!("{name}_{suffix}"), value);
        }
    }
    result.extend(snapshot.responses.into_iter().filter(|(name, _)| name.starts_with("payload_") || name.starts_with("connection_"))
        .map(|(name, value)| (name.into(), value)));
    for (name, counter) in [
        ("range_active_channels", &RANGE_ACTIVE), ("range_admission_limit", &RANGE_LIMIT),
        ("range_header_active", &RANGE_HEADER_ACTIVE), ("range_header_count", &RANGE_HEADER_COUNT),
        ("range_header_total_ms", &RANGE_HEADER_TOTAL_MS), ("range_header_max_ms", &RANGE_HEADER_MAX_MS),
        ("range_header_failed", &RANGE_HEADER_FAILED), ("range_trial_accepted", &RANGE_TRIAL_ACCEPTED),
        ("range_trial_rejected", &RANGE_TRIAL_REJECTED), ("range_startup_reused", &RANGE_STARTUP_REUSED),
    ] { result.insert(name.into(), counter.load(Ordering::Relaxed)); }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn anonymous_stages_report_live_age_and_release_cancelled_waits() {
        let mut state = State::default();
        let now = Instant::now();
        let first = state.enter(Kind::ShareLock.name(), now);
        let second = state.enter(Kind::ShareLock.name(), now + Duration::from_secs(2));
        let live = state.snapshot(now + Duration::from_secs(8));
        assert_eq!(live.stages["share_lock"].active, 2);
        assert_eq!(live.stages["share_lock"].oldest_ms, 8000);
        state.finish(first, now + Duration::from_secs(9));
        state.finish(second, now + Duration::from_secs(12));
        let done = state.snapshot(now + Duration::from_secs(20));
        let metric = &done.stages["share_lock"];
        assert_eq!(
            (
                metric.active,
                metric.oldest_ms,
                metric.count,
                metric.total_ms,
                metric.max_ms
            ),
            (0, 0, 2, 19000, 10000)
        );
        let json = serde_json::to_value(done).unwrap();
        assert!(json["stages"]["share_lock"]
            .as_object()
            .unwrap()
            .values()
            .all(serde_json::Value::is_u64));
        assert!(state.active.is_empty());
    }

    #[test]
    fn range_safety_observes_ram_stalls_even_without_diagnostics() {
        let _guard = range_startup_test_guard();
        let before = range_resources().0;
        for kind in [Kind::RamBodyLimit, Kind::RamSharedLimit, Kind::RamPressure] {
            let stage = Stage::enter(kind);
            assert!(range_resources().1);
            drop(stage);
        }
        assert!(!range_resources().1);
        assert!(range_resources().0 >= before + 3);
        range_memory_pressure(2);
        assert!(range_resources().1);
        let warning = range_resources().0;
        range_memory_pressure(2);
        assert_eq!(range_resources().0, warning, "One warning episode invalidates evidence once");
        range_memory_pressure(1);
        assert!(!range_resources().1);
    }

    #[test]
    fn range_diagnostics_have_fixed_numeric_keys_only() {
        let result = receive_diagnostics();
        for name in ["range_active_channels", "range_admission_limit", "range_header_active", "range_header_count",
            "range_header_total_ms", "range_header_max_ms", "range_header_failed", "range_trial_accepted",
            "range_trial_rejected", "range_startup_reused"] {
            assert!(result.contains_key(name));
        }
        let json = serde_json::to_value(result).unwrap();
        assert!(json.as_object().unwrap().values().all(serde_json::Value::is_u64));
    }
}

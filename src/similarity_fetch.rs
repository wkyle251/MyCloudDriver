//! Bounded, cancellable acquisition of private cloud originals.
use super::*;
use filetwin_core::memory_input::MemoryInput;
use std::sync::{atomic::AtomicU64, Mutex};
#[path = "similarity_downloads.rs"]
mod downloads;
pub(super) use downloads::Ticket;
#[path = "similarity_fetch_password.rs"]
mod password_probe;
#[path = "similarity_fetch_seekable.rs"]
mod seekable;
pub(super) use seekable::prepare as prepare_seekable;
use crate::download_connections::Connections;
use crate::{
    download_network::Network,
    download_ranges::{self, State as RangeState, Transfer as RangeTransfer},
};
#[cfg(test)]
#[path = "similarity_dynamic_tests.rs"]
mod dynamic_tests;
#[cfg(test)]
#[path = "similarity_range_tests.rs"]
mod range_tests;

#[cfg(test)]
#[tokio::test]
async fn personal_access_token_similarity_ram_fallback_uses_pat_and_releases_memory() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    fixture.guest_denied.store(true, Ordering::SeqCst);
    let client = Client::builder()
        .personal_access_token("account-access")
        .device_id("pat-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_content_mode(crate::ContentMode::Dynamic);
    let item = CloudItem {
        id: "saved-id".into(),
        name: "saved-name.bin".into(),
        size: 8,
        path: "/Saved/saved-name.bin".into(),
        is_folder: false,
        revision: Some("ABCDEF".into()),
        ancestors: vec![CloudAncestor {
            id: "saved-folder".into(),
            name: "Saved".into(),
        }],
    };
    let fetches = Fetches::with_memory(4, 16);
    let (original, revision) =
        download_versioned(&client, &item, &AtomicBool::new(false), &fetches, |_, _| {
            Ok(())
        })
        .await
        .unwrap();
    assert_eq!(original.as_ref().as_ref(), b"abcdefgh");
    assert_eq!(revision.as_deref(), Some("ABCDEF"));
    assert_eq!(fetches.memory.used(), 8);
    drop(original);
    assert_eq!(fetches.memory.used(), 0);
    let requests = fixture.requests.lock().unwrap();
    assert!(!requests
        .iter()
        .any(|r| r.starts_with("POST /v1/auth/token")));
    assert!(requests.iter().any(|r| r.starts_with("GET /guest-body/")));
    assert!(requests.iter().any(|r| r.starts_with("GET /user-body/")));
    assert!(requests
        .iter()
        .filter(|r| r.contains("authorization:"))
        .all(|r| r.contains("authorization: Bearer account-access")
            && !r.contains("x-captcha-token:")));
}

#[cfg(test)]
#[tokio::test]
async fn guest_similarity_download_refreshes_expired_url_with_account_identity() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.expired.store(true, Ordering::SeqCst);
    let client = Client::builder()
        .refresh_token("account-refresh")
        .device_id("account-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_guest_mode(true);
    let item = CloudItem {
        id: "saved-id".into(),
        name: "saved-name.bin".into(),
        size: 8,
        path: "/Saved/saved-name.bin".into(),
        is_folder: false,
        revision: Some("ABCDEF".into()),
        ancestors: vec![CloudAncestor {
            id: "saved-folder".into(),
            name: "Saved".into(),
        }],
    };
    let fetches = Fetches::with_memory(4, 16);
    let original = download(&client, &item, &AtomicBool::new(false), &fetches, |_, _| {
        Ok(())
    })
    .await
    .unwrap();
    assert_eq!(original.as_ref().as_ref(), b"abcdefgh");
    assert_eq!(fetches.memory.used(), 8);
    drop(original);
    assert_eq!(fetches.memory.used(), 0);
    fixture.assert_anonymous_content();
    assert_eq!(
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /drive/v1/share/file_info"))
            .count(),
        2
    );
}

#[cfg(test)]
#[tokio::test]
async fn content_mode_similarity_ram_uses_user_fallback_for_missing_share_and_denied_body() {
    for mode in [crate::ContentMode::User, crate::ContentMode::Dynamic] {
        for missing_source in [true, false] {
            let fixture = crate::guest_fixture::Fixture::new().await;
            fixture.user_available.store(true, Ordering::SeqCst);
            if missing_source {
                fixture.saved.lock().unwrap()["params"] = serde_json::Value::Null;
            } else {
                fixture.guest_denied.store(true, Ordering::SeqCst);
            }
            let client = Client::builder()
                .refresh_token("account-refresh")
                .device_id("account-device")
                .api_base_url(&fixture.base)
                .auth_base_url(&fixture.base)
                .build()
                .unwrap()
                .with_content_mode(mode);
            let item = CloudItem {
                id: "saved-id".into(),
                name: "saved-name.bin".into(),
                size: 8,
                path: "/Saved/saved-name.bin".into(),
                is_folder: false,
                revision: Some("ABCDEF".into()),
                ancestors: vec![CloudAncestor {
                    id: "saved-folder".into(),
                    name: "Saved".into(),
                }],
            };
            let fetches = Fetches::with_memory(4, 16);
            let (original, revision) =
                download_versioned(&client, &item, &AtomicBool::new(false), &fetches, |_, _| {
                    Ok(())
                })
                .await
                .unwrap();
            assert_eq!(original.as_ref().as_ref(), b"abcdefgh");
            assert_eq!(revision.as_deref(), Some("ABCDEF"));
            assert_eq!(fetches.memory.used(), 8);
            drop(original);
            assert_eq!(fetches.memory.used(), 0);
            assert_eq!(client.content_mode(), mode);
            let requests = fixture.requests.lock().unwrap();
            assert!(requests.iter().any(|r| r.starts_with("GET /user-body/")));
            assert_eq!(
                requests
                    .iter()
                    .filter(|r| r.starts_with("GET /guest-body/"))
                    .count(),
                usize::from(mode == crate::ContentMode::Dynamic && !missing_source)
            );
        }
    }
}

#[cfg(test)]
#[test]
fn content_mode_similarity_parallel_denial_retains_fallback_status() {
    let error = crate::download_ranges::Error::Http(crate::download_policy::HttpFailure {
        status: 403,
        retry_after: None,
    });
    let failure = Failure::from_error(error.into(), "download");
    assert_eq!(failure.status, Some(403));
    assert_eq!(failure.operation, "download");
    assert!(failure.retryable);
}

pub(super) const MAX_DOWNLOADS: usize = 64;
const MAX_ATTEMPTS: u32 = 5;

pub(super) struct Fetches {
    #[cfg(test)]
    initial_range_connections: usize,
    connections: Mutex<Connections>,
    cooldown: Mutex<Instant>,
    pub waiting: AtomicU64,
    pub retrying: AtomicU64,
    pub active: AtomicU64,
    pub metadata: AtomicU64,
    pub range_active: AtomicU64,
    pub range_metadata: AtomicU64,
    pub range_retrying: AtomicU64,
    pub sampled_files: AtomicU64,
    pub sampled_original_bytes: AtomicU64,
    pub sampled_received_bytes: AtomicU64,
    pub limit: usize,
    pub memory: Arc<memory::Budget>,
    downloads: Arc<downloads::Downloads>,
    received_bytes: AtomicU64,
    seekable_readers: AtomicU64,
    pub retry_forever: bool,
    pub control: filetwin_core::api::CancellationToken,
}
struct Permit<'a>(&'a Fetches);
impl Drop for Permit<'_> {
    fn drop(&mut self) {
        self.0.release_connection();
    }
}
struct OwnedPermit(Arc<Fetches>);
impl Drop for OwnedPermit {
    fn drop(&mut self) { self.0.release_connection(); }
}
impl Permit<'_> {
    fn retaining(self, owner: Arc<Fetches>) -> OwnedPermit {
        assert!(std::ptr::eq(self.0, owner.as_ref()));
        // Transfer the existing entitlement, without a second admission or
        // releasing the only slot that can complete this original.
        std::mem::forget(self);
        OwnedPermit(owner)
    }
}

struct Counter<'a>(&'a AtomicU64);
impl<'a> Counter<'a> {
    fn new(value: &'a AtomicU64) -> Self {
        value.fetch_add(1, Ordering::Relaxed);
        Self(value)
    }
}
impl Drop for Counter<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Fetches {
    fn release_connection(&self) {
        let mut connections = self.connections.lock().unwrap();
        connections.active -= 1;
        if self.waiting.load(Ordering::Relaxed) == 0 { connections.idle(Instant::now()); }
    }
    #[cfg(test)]
    pub fn new(workers: usize) -> Self {
        Self::with_memory(workers, 256 << 20)
    }
    pub fn with_memory(workers: usize, memory_bytes: u64) -> Self {
        let limit = workers.clamp(1, MAX_DOWNLOADS);
        Self {
            #[cfg(test)]
            initial_range_connections: 1,
            connections: Mutex::new(
                Connections::new(limit, Instant::now())
                    .with_coordinator(Network::shared().trials()),
            ),
            cooldown: Mutex::new(Instant::now()),
            waiting: AtomicU64::new(0),
            retrying: AtomicU64::new(0),
            active: AtomicU64::new(0),
            metadata: AtomicU64::new(0),
            range_active: AtomicU64::new(0),
            range_metadata: AtomicU64::new(0),
            range_retrying: AtomicU64::new(0),
            sampled_files: AtomicU64::new(0),
            sampled_original_bytes: AtomicU64::new(0),
            sampled_received_bytes: AtomicU64::new(0),
            limit,
            memory: memory::Budget::new(memory_bytes),
            downloads: Arc::new(downloads::Downloads::default()),
            received_bytes: AtomicU64::new(0),
            seekable_readers: AtomicU64::new(0),
            retry_forever: false,
            control: Default::default(),
        }
    }
    async fn acquire(&self, cancel: &AtomicBool) -> Result<Permit<'_>> {
        let _waiting = Counter::new(&self.waiting);
        loop {
            control::wait(&self.control, cancel).await?;
            let until = *self.cooldown.lock().unwrap();
            wait(cancel, tokio::time::sleep_until(until.into())).await?;
            if let Some(permit) = self.try_acquire() {
                return Ok(permit);
            }
            wait(cancel, tokio::time::sleep(Duration::from_millis(10))).await?;
        }
    }
    fn try_acquire(&self) -> Option<Permit<'_>> {
        if *self.cooldown.lock().unwrap() <= Instant::now() {
            let mut connections = self.connections.lock().unwrap();
            connections.observe(Instant::now(), Network::shared().received(), || {
                self.memory.has_forecast_room()
            });
            if connections.active < connections.limit {
                connections.active += 1;
                return Some(Permit(self));
            }
        }
        None
    }
    async fn acquire_stream(
        &self,
        size: u64,
        cancel: &AtomicBool,
        ticket: &downloads::Ticket,
    ) -> Result<(memory::StreamLease, Permit<'_>)> {
        loop {
            control::wait(&self.control, cancel).await?;
            ticket.phase("waiting_memory");
            let lease = self.memory.stream(size, cancel).await?;
            control::wait(&self.control, cancel).await?;
            // Never hold original RAM while awaiting a connection. Otherwise
            // Banker's completion order could depend on a file that cannot
            // get a connection because all connected files await its RAM.
            if let Some(permit) = self.try_acquire() {
                return Ok((lease, permit));
            }
            drop(lease);
            ticket.phase("queued");
            let _waiting = Counter::new(&self.waiting);
            wait(cancel, tokio::time::sleep(Duration::from_millis(25))).await?;
        }
    }
    fn defer_requests(&self, delay: Duration) {
        let mut until = self.cooldown.lock().unwrap();
        *until = (*until).max(Instant::now() + delay);
        let mut connections = self.connections.lock().unwrap();
        connections.back_off(*until);
    }
    pub fn connection_limit(&self) -> usize {
        self.connections.lock().unwrap().limit
    }
    pub fn download_progress(&self) -> Value {
        self.downloads.snapshot()
    }
    pub fn track(&self, name: &str, size: u64) -> downloads::Ticket {
        self.downloads.start(name, size)
    }
}

/// Waiting for capacity or a provider's retry delay must not be treated as a
/// timed-out network request. Cancellation still interrupts these waits.
async fn wait<T>(cancel: &AtomicBool, future: impl Future<Output = T>) -> Result<T> {
    tokio::pin!(future);
    loop {
        check_cancel(cancel)?;
        tokio::select! {
            value = &mut future => return Ok(value),
            _ = tokio::time::sleep(Duration::from_millis(50)) => {},
        }
    }
}

/// This error carries only fixed categories and status codes, never a signed
/// URL, token, raw server response or private local pathname.
#[derive(Debug, Clone, thiserror::Error)]
#[error("Original fetch failed ({kind})")]
pub(super) struct Failure {
    pub kind: &'static str,
    pub status: Option<u16>,
    pub operation: &'static str,
    pub attempts: u32,
    retryable: bool,
    retry_after: Option<Duration>,
    protected: Option<password::Protected>,
    memory_target: Option<u64>,
}

impl Failure {
    fn new(kind: &'static str, operation: &'static str, retryable: bool) -> Self {
        Self {
            kind,
            operation,
            retryable,
            status: None,
            attempts: 1,
            retry_after: None,
            protected: None,
            memory_target: None,
        }
    }
    fn memory_wait(target: u64) -> Self {
        Self {
            memory_target: Some(target),
            ..Self::new("memory_wait", "memory", true)
        }
    }
    fn http(status: u16, operation: &'static str, retry_after: Option<Duration>) -> Self {
        Self {
            status: Some(status),
            retry_after,
            ..Self::new(
                "http",
                operation,
                status == 408
                    || status == 429
                    || status >= 500
                    || (operation == "download" && matches!(status, 401 | 403)),
            )
        }
    }
    fn from_error(error: anyhow::Error, operation: &'static str) -> Self {
        let mut result = Self::new("unavailable", operation, false);
        for cause in error.chain() {
            if let Some(failure) = cause.downcast_ref::<Failure>() {
                result = failure.clone();
                result.operation = operation;
            }
            if cause.is::<memory::Limit>() {
                result = Self::new("memory_limit", operation, false);
            }
            if cause.is::<crate::download_policy::Interrupted>() {
                result = Self::new("incomplete", operation, true);
            }
            if cause.is::<crate::download_policy::ContentUnavailable>() {
                result = Self::new("content_unavailable", operation, false);
            }
            if cause.is::<crate::download_policy::PartialContent>() {
                result = Self::new("partial_content", operation, true);
            }
            if let Some(http) = cause.downcast_ref::<crate::download_policy::HttpFailure>() {
                result = Self::http(http.status, operation, http.retry_after);
            }
            if let Some(crate::download_ranges::Error::Http(http)) =
                cause.downcast_ref::<crate::download_ranges::Error>()
            {
                result = Self::http(http.status, operation, http.retry_after);
            }
            if let Some(api) = cause.downcast_ref::<crate::Error>() {
                match api {
                    crate::Error::Api { status, .. } => {
                        result = Self::http(*status, operation, None)
                    }
                    crate::Error::RetryAfter { status, delay } => {
                        result = Self::http(*status, operation, Some(*delay))
                    }
                    crate::Error::Auth(_)
                    | crate::Error::SessionRejected(_)
                    | crate::Error::TokenExpired => {
                        result = Self::new("authentication", operation, false)
                    }
                    crate::Error::Guest(_) | crate::Error::Share(_) => {
                        result = Self::new("guest_unavailable", operation, false)
                    }
                    _ => {}
                }
            }
            if let Some(http) = cause.downcast_ref::<reqwest::Error>() {
                result = if let Some(status) = http.status() {
                    Self::http(status.as_u16(), operation, None)
                } else if http.is_timeout() {
                    Self::new("timeout", operation, true)
                } else if http.is_connect() {
                    Self::new("connection", operation, true)
                } else if http.is_body() {
                    Self::new("incomplete", operation, true)
                } else if http.is_builder() {
                    Self::new("invalid_link", operation, false)
                } else {
                    Self::new("network", operation, true)
                };
            }
            if cause.is::<tokio::time::error::Elapsed>() {
                result = Self::new("timeout", operation, true);
            }
            if let Some(io) = cause.downcast_ref::<std::io::Error>() {
                match io.raw_os_error() {
                    Some(23 | 24) => result = Self::new("open_file_limit", operation, true),
                    Some(28) => result = Self::new("disk_full", operation, false),
                    _ => match io.kind() {
                        std::io::ErrorKind::PermissionDenied => {
                            result = Self::new("permission", operation, false)
                        }
                        std::io::ErrorKind::NotFound => {
                            result = Self::new("missing_file", operation, false)
                        }
                        _ => {}
                    },
                }
            }
        }
        result
    }
}

fn retry_after(headers: &reqwest::header::HeaderMap) -> Option<Duration> {
    let value = headers.get(reqwest::header::RETRY_AFTER)?.to_str().ok()?;
    if let Ok(seconds) = value.trim().parse::<u64>() {
        // Refuse unreasonable values instead of overflowing Instant. A long
        // provider cooldown is terminal below; it is never retried early.
        return Some(Duration::from_secs(seconds.min(86_400)));
    }
    httpdate::parse_http_date(value).ok().map(|when| {
        when.duration_since(std::time::SystemTime::now())
            .unwrap_or_default()
    })
}

#[cfg(test)]
pub(super) async fn download(
    client: &Client,
    item: &CloudItem,
    cancel: &AtomicBool,
    fetches: &Fetches,
    progress: impl FnMut(u64, u64) -> Result<()>,
) -> Result<Arc<MemoryInput>> {
    download_versioned(client, item, cancel, fetches, progress)
        .await
        .map(|(input, _)| input)
}

pub(super) async fn download_versioned(
    client: &Client,
    item: &CloudItem,
    cancel: &AtomicBool,
    fetches: &Fetches,
    mut progress: impl FnMut(u64, u64) -> Result<()>,
) -> Result<(Arc<MemoryInput>, Option<String>)> {
    let mut route = client.clone();
    let mut transferred = 0;
    let mut attempt = 0u32;
    let mut partial = None;
    let mut sequential_only = false;
    let ticket = fetches.downloads.start(&item.name, item.size);
    loop {
        control::wait(&fetches.control, cancel).await?;
        attempt = attempt.saturating_add(1);
        check_cancel(cancel)?;
        ticket.begin_attempt(attempt, transferred);
        let previously_received = partial
            .as_ref()
            .map_or(0, |input: &Partial<'_>| input.received());
        if let Some(input) = partial.as_ref() {
            let input: &Partial = input;
            ticket.sample(input.received(), input.expected, transferred);
        }
        let result = download_attempt(
            &route,
            item,
            fetches,
            cancel,
            &mut transferred,
            &mut progress,
            &ticket,
            &mut partial,
            &mut sequential_only,
        )
        .await;
        match result {
            Ok(()) => {
                let input = partial.take().expect("Completed RAM input");
                return Ok((
                    Arc::new(MemoryInput::from_buffer(input.data).with_reservation(input.lease)),
                    input.revision,
                ));
            }
            Err(mut failure) => {
                check_cancel(cancel)?;
                if let Some(protected) = failure.protected.take() {
                    return Err(protected.into());
                }
                if failure.kind == "partial_content" {
                    // A clean shorter response may be a provider's per-request
                    // range limit. Try the next Guest bytes before using quota.
                    if partial
                        .as_ref()
                        .is_some_and(|input| input.received() > previously_received)
                    {
                        attempt = attempt.saturating_sub(1);
                        continue;
                    }
                    // A replacement revision must not repeatedly reset the
                    // retry budget by returning the same small fresh prefix.
                    failure.kind = "incomplete";
                }
                if route.content_mode() == crate::ContentMode::Dynamic
                    && failure.operation == "download"
                    && (failure.kind == "content_unavailable"
                        || failure
                            .status
                            .is_some_and(|status| matches!(status, 401 | 403 | 404)))
                {
                    route = route.with_content_mode(crate::ContentMode::User);
                    // User metadata must prove the same original before the
                    // next attempt can reuse any retained guest coverage.
                    attempt = attempt.saturating_sub(1);
                    continue;
                }
                if failure.kind == "range_pause" {
                    ticket.phase("paused");
                    control::wait(&fetches.control, cancel).await?;
                    attempt = attempt.saturating_sub(1);
                    continue;
                }
                if let Some(target) = failure.memory_target {
                    // All HTTP bodies have been dropped by download_attempt.
                    // Retaining RAM while waiting cannot occupy every shared
                    // socket and prevent the next eligible original finishing.
                    ticket.phase("waiting_memory");
                    control::wait(&fetches.control, cancel).await?;
                    partial
                        .as_ref()
                        .expect("Retained RAM input")
                        .lease
                        .grow(target, cancel)
                        .await?;
                    attempt = attempt.saturating_sub(1);
                    continue;
                }
                if failure.kind == "range_fallback" {
                    attempt = attempt.saturating_sub(1);
                    continue;
                }
                // Keep partial bytes and their connection entitlement across
                // interruptions. A zero-byte failed request owns nothing.
                if partial.as_ref().is_some_and(|input| input.received() == 0) {
                    partial = None;
                }
                failure.attempts = attempt;
                if !failure.retryable
                    || (!fetches.retry_forever
                        && (attempt == MAX_ATTEMPTS
                            || failure
                                .retry_after
                                .is_some_and(|d| d > Duration::from_secs(300))))
                {
                    if fetches.retry_forever && failure.kind == "authentication" {
                        let _ = emit(
                            &json!({"event":"interrupted","reason":"Sign in to PikPak again, then resume this scan."}),
                        );
                    }
                    return Err(failure.into());
                }
                let delay =
                    Duration::from_millis((500u64 * (1 << (attempt - 1).min(6))).min(30_000))
                        .max(failure.retry_after.unwrap_or_default());
                // Cool down the scan as a whole when its download service is
                // busy. Unrelated CPU work continues; no slot is held asleep.
                if failure.status.is_some_and(|s| s == 429 || s >= 500) {
                    fetches.defer_requests(delay);
                }
                let _retrying = Counter::new(&fetches.retrying);
                ticket.retry(delay.as_secs());
                wait(cancel, tokio::time::sleep(delay)).await?;
            }
        }
    }
}

struct Partial<'a> {
    data: RamBuffer,
    lease: memory::StreamLease,
    // Retained partials must not lose their connection entitlement: otherwise
    // all connections could await RAM held by a disconnected partial.
    _connection: Permit<'a>,
    expected: u64,
    revision: Option<String>,
    source_revision: Option<String>,
    content_mode: crate::ContentMode,
    etag: Option<reqwest::header::HeaderValue>,
    ranges: Option<RangeState>,
}
impl Partial<'_> {
    fn received(&self) -> u64 {
        self.ranges
            .as_ref()
            .map_or(self.data.len() as u64, RangeState::received)
    }
}

/// The response future is kept while paused. The outer inactivity clock stops;
/// if the provider closes the socket, the next request resumes retained bytes.
async fn download_wait<T>(
    fetches: &Fetches,
    cancel: &AtomicBool,
    future: impl Future<Output = Result<T>>,
) -> Result<T> {
    download_wait_for(fetches, cancel, Duration::from_secs(90), future).await
}

async fn download_wait_for<T>(
    fetches: &Fetches,
    cancel: &AtomicBool,
    limit: Duration,
    future: impl Future<Output = Result<T>>,
) -> Result<T> {
    tokio::pin!(future);
    let mut deadline = Instant::now() + limit;
    loop {
        deadline += control::wait(&fetches.control, cancel).await?;
        tokio::select! {
            value = &mut future => return value,
            _ = tokio::time::sleep(Duration::from_millis(20)) => {
                if Instant::now() >= deadline { return Err(anyhow::Error::new(Failure::new("timeout", "download", true))); }
            }
        }
    }
}

async fn download_attempt<'a>(
    client: &Client,
    item: &CloudItem,
    fetches: &'a Fetches,
    cancel: &AtomicBool,
    transferred: &mut u64,
    progress: &mut impl FnMut(u64, u64) -> Result<()>,
    ticket: &downloads::Ticket,
    partial: &mut Option<Partial<'a>>,
    sequential_only: &mut bool,
) -> std::result::Result<(), Failure> {
    let (info, revision) = {
        let _connection = if partial.is_none() {
            Some(
                fetches
                    .acquire(cancel)
                    .await
                    .map_err(|e| Failure::from_error(e, "metadata"))?,
            )
        } else {
            None
        };
        let _metadata = Counter::new(&fetches.metadata);
        download_wait(fetches, cancel, async {
            client
                .similarity_download_info(
                    &item.id,
                    item.ancestors
                        .last()
                        .map(|parent| parent.id.as_str())
                        .unwrap_or(""),
                )
                .await
                .map_err(Into::into)
        })
        .await
        .map_err(|e| Failure::from_error(e, "metadata"))?
    };
    let url = reqwest::Url::parse(&info.web_content_link)
        .ok()
        .filter(|u| matches!(u.scheme(), "http" | "https"))
        .ok_or_else(|| Failure::new("invalid_link", "metadata", false))?;
    let expected = if info.size > 0 { info.size } else { item.size };
    let verified_source = partial.as_ref().is_some_and(|input| {
        input.expected == expected
            && crate::content_mode::matching_content_revision(
                input.source_revision.as_deref(),
                info.source_revision.as_deref(),
            )
    });
    // A changed original is a new input. Never join bytes from two revisions.
    if partial.as_ref().is_some_and(|input| {
        input.expected != expected
            || input.source_revision != info.source_revision
            || input.content_mode != client.content_mode() && !verified_source
    }) {
        *partial = None;
    }
    if partial.is_none() && password::archive_candidate(&info.name) {
        let _connection = fetches
            .acquire(cancel)
            .await
            .map_err(|e| Failure::from_error(e, "metadata"))?;
        let _metadata = Counter::new(&fetches.metadata);
        let protected = match download_wait(
            fetches,
            cancel,
            password_probe::check(client, &url, expected, fetches, transferred, progress),
        )
        .await
        {
            Ok(protected) => protected,
            Err(error) => {
                let failure = Failure::from_error(error, "download");
                // A slow/broken connection is not evidence of an unprotected
                // archive. Retry the check instead of starting a full download.
                if failure.retryable || failure.status.is_some() {
                    return Err(failure);
                }
                false
            }
        };
        check_cancel(cancel).map_err(|e| Failure::from_error(e, "metadata"))?;
        if protected {
            let mut failure = Failure::new("password", "metadata", false);
            failure.protected = Some(password::Protected {
                bytes: expected,
                revision,
            });
            return Err(failure);
        }
    }
    if partial.is_none() {
        let (lease, connection) = fetches
            .acquire_stream(expected, cancel, ticket)
            .await
            .map_err(|e| Failure::from_error(e, "memory"))?;
        let data = RamBuffer::new(lease.capacity).map_err(|e| Failure::from_error(e, "memory"))?;
        *partial = Some(Partial {
            data,
            lease,
            _connection: connection,
            expected,
            revision: revision.clone(),
            source_revision: info.source_revision,
            content_mode: client.content_mode(),
            etag: None,
            ranges: None,
        });
    }
    let input = partial.as_mut().unwrap();
    if input.content_mode != client.content_mode() {
        // Validators belong to one CDN resource. The matching GCID, rather
        // than a guest ETag, authorizes the first User suffix request.
        input.etag = None;
        input.content_mode = client.content_mode();
    }
    input.revision = revision;
    if !*sequential_only
        && (input.ranges.is_some()
            || expected >= download_ranges::MIN_PARALLEL_SIZE && input.data.len() == 0)
    {
        let network = Network::for_url(url.as_str());
        let etag = download_wait(fetches, cancel, async {
            download_ranges::probe(
                client.download_http_client(),
                url.as_str(),
                expected,
                None,
                &network,
            )
            .await
            .map_err(Into::into)
        })
        .await
        .map_err(|e| Failure::from_error(e, "download"))?;
        if etag.as_ref().is_none_or(|etag| {
            input
                .ranges
                .as_ref()
                .is_some_and(|ranges| ranges.etag() != etag)
                && !verified_source
        }) {
            if verified_source {
                // A User CDN without strong ETags can still serve a verified
                // prefix's missing suffix. Out-of-order bytes are discarded.
                input.data.len = input
                    .ranges
                    .as_ref()
                    .map_or(input.data.len(), |ranges| ranges.prefix() as usize);
                input.ranges = None;
                input.etag = None;
            } else {
                *partial = None;
            }
            *sequential_only = true;
            return Err(Failure::new("range_fallback", "download", true));
        }
        let etag = etag.unwrap();
        let mut state = input
            .ranges
            .take()
            .unwrap_or_else(|| RangeState::new(expected, etag.clone(), 0));
        if state.etag() != etag && !state.rebind_etag(&etag) {
            return Err(Failure::new("invalid_range", "download", false));
        }
        let result = parallel_download(
            client,
            url.as_str(),
            fetches,
            cancel,
            input,
            state,
            transferred,
            progress,
            ticket,
        )
        .await;
        if result
            .as_ref()
            .is_err_and(|failure| failure.kind == "range_fallback")
        {
            if verified_source {
                // Keep the contiguous verified prefix when this CDN ignores
                // ranges. The sequential reader validates a full 200 body.
                input.data.len = input
                    .ranges
                    .as_ref()
                    .map_or(0, |ranges| ranges.prefix() as usize);
                input.ranges = None;
                input.etag = None;
            } else {
                // Without identity proof, sequential verification starts fresh.
                *partial = None;
            }
            *sequential_only = true;
        }
        return result;
    }
    let capacity = input.lease.capacity;
    let offset = input.data.len() as u64;
    let mut request = client
        .download_http_client()
        .get(url.as_str())
        .header(reqwest::header::ACCEPT_ENCODING, "identity");
    let ranged = offset > 0 && (input.etag.is_some() || verified_source);
    if ranged {
        request = request.header(reqwest::header::RANGE, format!("bytes={offset}-"));
        if let Some(etag) = &input.etag {
            request = request.header(reqwest::header::IF_RANGE, etag.clone());
        }
    }
    let network = Network::for_url(url.as_str());
    let _participant = network.register();
    let _channel = wait(cancel, network.acquire())
        .await
        .map_err(|e| Failure::from_error(e, "download"))?
        .map_err(|e| Failure::from_error(e.into(), "download"))?;
    let _active = Counter::new(&fetches.active);
    ticket.phase("downloading");
    let response = download_wait(fetches, cancel, async {
        request.send().await.map_err(Into::into)
    })
    .await
    .map_err(|e| Failure::from_error(e, "download"))?;
    if !response.status().is_success() {
        if response.status() == reqwest::StatusCode::RANGE_NOT_SATISFIABLE
            && response
                .headers()
                .get(reqwest::header::CONTENT_RANGE)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.strip_prefix("bytes */"))
                .and_then(|value| value.parse::<u64>().ok())
                .is_some_and(|available| {
                    expected > 0 && available < expected && offset >= available
                })
        {
            return Err(Failure::new("content_unavailable", "download", false));
        }
        if matches!(response.status().as_u16(), 429 | 500..=599) {
            network
                .defer(retry_after(response.headers()).unwrap_or(Duration::from_secs(1)))
                .map_err(|e| Failure::from_error(e.into(), "download"))?;
        }
        return Err(Failure::http(
            response.status().as_u16(),
            "download",
            retry_after(response.headers()),
        ));
    }
    if response
        .headers()
        .get(reqwest::header::CONTENT_ENCODING)
        .is_some_and(|value| value != "identity")
    {
        return Err(Failure::new("invalid_response", "download", false));
    }
    let mut body_position = 0u64;
    let declared_length = response.content_length();
    let mut limited = response.status() == reqwest::StatusCode::OK
        && expected > 0
        && declared_length.is_some_and(|length| length < expected);
    let mut response_end = declared_length;
    if response.status() == reqwest::StatusCode::PARTIAL_CONTENT {
        let range = response
            .headers()
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .and_then(content_range);
        let Some((start, end, total)) = range else {
            return Err(Failure::new("invalid_range", "download", false));
        };
        limited = expected > 0 && end + 1 < expected;
        if (!ranged && offset != 0)
            || start != offset
            || (expected > 0 && total != expected)
            || (!limited && end + 1 != total)
            || total > capacity
            || declared_length.is_some_and(|len| len != end + 1 - start)
            || response
                .headers()
                .get(reqwest::header::ETAG)
                .is_some_and(|etag| {
                    input.etag.as_ref().is_some_and(|saved| etag != saved) && !verified_source
                })
        {
            return Err(Failure::new("invalid_range", "download", false));
        }
        body_position = offset;
        response_end = Some(end + 1);
    } else if response.status() != reqwest::StatusCode::OK {
        return Err(Failure::new("invalid_response", "download", false));
    }
    if expected > capacity
        || response
            .content_length()
            .is_some_and(|len| len > capacity - body_position)
    {
        return Err(Failure::new("memory_limit", "memory", false));
    }
    input.etag = response
        .headers()
        .get(reqwest::header::ETAG)
        .filter(|tag| {
            tag.to_str()
                .is_ok_and(|s| s.starts_with('"') && s.ends_with('"'))
        })
        .cloned();
    let mut stream = response.bytes_stream();
    let mut last = Instant::now();
    loop {
        control::wait(&fetches.control, cancel)
            .await
            .map_err(|e| Failure::from_error(e, "download"))?;
        // Reserve before polling, except when validating bytes already held.
        let target = (input.data.len() as u64)
            .saturating_add(memory::RECEIVE_WINDOW)
            .min(capacity);
        if body_position >= input.data.len() as u64 && target > input.lease.reserved() {
            if !input
                .lease
                .try_reserve(target)
                .map_err(|e| Failure::from_error(e, "memory"))?
            {
                return Err(Failure::memory_wait(target));
            }
        }
        let Some(chunk) = download_wait(fetches, cancel, async { Ok(stream.next().await) })
            .await
            .map_err(|e| Failure::from_error(e, "download"))?
        else {
            break;
        };
        let chunk = chunk.map_err(|e| Failure::from_error(e.into(), "download"))?;
        *transferred += chunk.len() as u64;
        fetches
            .received_bytes
            .fetch_add(chunk.len() as u64, Ordering::Relaxed);
        network.record(chunk.len() as u64);
        if response_end.is_some_and(|end| body_position.saturating_add(chunk.len() as u64) > end) {
            return Err(Failure::new("invalid_range", "download", false));
        }
        if body_position.saturating_add(chunk.len() as u64) > capacity {
            return Err(Failure::new("memory_limit", "memory", false));
        }
        for part in chunk.chunks(memory::RECEIVE_WINDOW as usize) {
            control::wait(&fetches.control, cancel)
                .await
                .map_err(|e| Failure::from_error(e, "download"))?;
            let duplicate = (input.data.len() as u64)
                .saturating_sub(body_position)
                .min(part.len() as u64) as usize;
            // Servers without byte ranges/strong validators can send the full
            // response. Verify its prefix against retained RAM before appending.
            if input.data.as_ref()[body_position as usize..body_position as usize + duplicate]
                != part[..duplicate]
            {
                // This is a full 200 response. The preceding prefix was
                // verified; replace the changed suffix with this response.
                input.data.len = body_position as usize;
            }
            let duplicate = (input.data.len() as u64)
                .saturating_sub(body_position)
                .min(part.len() as u64) as usize;
            let target = input.data.len() as u64 + (part.len() - duplicate) as u64;
            if target > input.lease.reserved() {
                if !input
                    .lease
                    .try_reserve(target)
                    .map_err(|e| Failure::from_error(e, "memory"))?
                {
                    return Err(Failure::memory_wait(target));
                }
            }
            input.data.append(&part[duplicate..]);
            body_position += part.len() as u64;
        }
        if last.elapsed() >= Duration::from_millis(250) || fetches.control.is_paused() {
            let speed = ticket.sample(input.data.len() as u64, expected, *transferred);
            input.lease.observe_rate(speed);
            progress(*transferred, expected).map_err(|e| Failure::from_error(e, "progress"))?;
            last = Instant::now();
        }
    }
    progress(*transferred, expected).map_err(|e| Failure::from_error(e, "progress"))?;
    if limited && response_end == Some(body_position) && body_position < input.data.len() as u64 {
        // A full 200 body only revalidated this shorter prefix. Its old tail
        // must not become accepted coverage for the subsequent User request.
        input.data.len = body_position as usize;
    }
    let written = input.data.len() as u64;
    if limited && response_end == Some(body_position) && body_position <= written {
        let can_resume = input.etag.is_some()
            || crate::content_mode::matching_content_revision(
                input.source_revision.as_deref(),
                input.source_revision.as_deref(),
            );
        let advances = written > offset && can_resume;
        return Err(Failure::new(
            if advances {
                "partial_content"
            } else {
                "content_unavailable"
            },
            "download",
            advances,
        ));
    }
    if body_position != written || (expected > 0 && expected != written) {
        return Err(Failure::new("incomplete", "download", true));
    }
    ticket.sample(
        written,
        if expected > 0 { expected } else { written },
        *transferred,
    );
    input.lease.finish(written);
    Ok(())
}

async fn parallel_download(
    client: &Client,
    url: &str,
    fetches: &Fetches,
    cancel: &AtomicBool,
    input: &mut Partial<'_>,
    state: RangeState,
    transferred: &mut u64,
    progress: &mut impl FnMut(u64, u64) -> Result<()>,
    ticket: &downloads::Ticket,
) -> std::result::Result<(), Failure> {
    let mut transfer = RangeTransfer::new(
        client.download_http_client(),
        url,
        None,
        state,
        Network::for_url(url),
    )
    .map_err(|e| Failure::from_error(e.into(), "download"))?;
    #[cfg(test)]
    transfer.set_test_initial_channels(fetches.initial_range_connections);
    let _active = Counter::new(&fetches.active);
    let mut last = Instant::now();
    ticket.phase("downloading");
    let result = loop {
        if let Err(error) = check_cancel(cancel) {
            break Err(Failure::from_error(error, "download"));
        }
        if fetches.control.is_paused() {
            break Err(Failure::new("range_pause", "download", true));
        }
        let target = transfer
            .state()
            .received()
            .saturating_add(transfer.buffer_headroom())
            .min(input.lease.capacity);
        match input.lease.try_reserve(target) {
            Ok(true) => {}
            Ok(false) => break Err(Failure::memory_wait(target)),
            Err(error) => break Err(Failure::from_error(error, "memory")),
        }
        let received = parallel_wait(fetches, cancel, async {
            transfer.next().await.map_err(Into::into)
        })
        .await;
        match received {
            Ok(Some(chunk)) => {
                // The mapping remains private until every range is complete.
                // Reservation includes pending receive buffers as well as data.
                input.data.write_at(chunk.offset as usize, &chunk.bytes);
                transfer.accept(&chunk);
                *transferred += chunk.bytes.len() as u64;
                fetches
                    .received_bytes
                    .fetch_add(chunk.bytes.len() as u64, Ordering::Relaxed);
                if last.elapsed() >= Duration::from_millis(250) || fetches.control.is_paused() {
                    let speed =
                        ticket.sample(transfer.state().received(), input.expected, *transferred);
                    input.lease.observe_rate(speed);
                    if let Err(error) = progress(*transferred, input.expected) {
                        break Err(Failure::from_error(error, "progress"));
                    }
                    last = Instant::now();
                }
            }
            Ok(None) => break Ok(()),
            Err(error)
                if error
                    .downcast_ref::<download_ranges::Error>()
                    .is_some_and(|e| matches!(e, download_ranges::Error::Sequential)) =>
            {
                break Err(Failure::new("range_fallback", "download", true));
            }
            Err(error) => {
                let failure = Failure::from_error(error, "download");
                if transfer.state().received() == 0
                    && (failure.kind == "content_unavailable"
                        || failure
                            .status
                            .is_some_and(|status| matches!(status, 401 | 403 | 404)))
                {
                    // A denied later piece can finish before the first Guest
                    // bytes arrive. Try the ordinary stream once so available
                    // prefix bytes are retained before an account handoff.
                    break Err(Failure::new("range_fallback", "download", true));
                }
                break Err(failure);
            }
        }
    };
    transfer.stop();
    input.ranges = Some(transfer.state().clone());
    ticket.sample(input.received(), input.expected, *transferred);
    result?;
    if !transfer.state().complete() || transfer.state().received() != input.expected {
        return Err(Failure::new("incomplete", "download", true));
    }
    input.data.len = input.expected as usize;
    input.lease.finish(input.expected);
    progress(*transferred, input.expected).map_err(|e| Failure::from_error(e, "progress"))?;
    Ok(())
}

async fn parallel_wait<T>(
    fetches: &Fetches,
    cancel: &AtomicBool,
    future: impl Future<Output = Result<T>>,
) -> Result<T> {
    tokio::pin!(future);
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        check_cancel(cancel)?;
        if fetches.control.is_paused() {
            return Err(Failure::new("range_pause", "download", true).into());
        }
        tokio::select! {
            value = &mut future => return value,
            _ = tokio::time::sleep(Duration::from_millis(20)) => {
                if Instant::now() >= deadline { return Err(Failure::new("timeout", "download", true).into()); }
            }
        }
    }
}

fn content_range(value: &str) -> Option<(u64, u64, u64)> {
    let (range, total) = value.strip_prefix("bytes ")?.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    let (start, end, total) = (
        start.parse().ok()?,
        end.parse::<u64>().ok()?,
        total.parse().ok()?,
    );
    (start <= end && end < total).then_some((start, end, total))
}

/// Anonymous mappings avoid both up-front physical allocation and the temporary
/// double allocation caused by growing a contiguous Vec. Only the written
/// prefix is ever exposed to the analysis readers.
pub(super) struct RamBuffer {
    mapping: memmap2::MmapMut,
    len: usize,
}
impl RamBuffer {
    pub fn new(capacity: u64) -> Result<Self> {
        let len = usize::try_from(capacity).map_err(|_| memory::Limit)?;
        Ok(Self {
            mapping: memmap2::MmapMut::map_anon(len.max(1))?,
            len: 0,
        })
    }
    pub fn append(&mut self, bytes: &[u8]) {
        self.mapping[self.len..self.len + bytes.len()].copy_from_slice(bytes);
        self.len += bytes.len();
    }
    fn write_at(&mut self, offset: usize, bytes: &[u8]) {
        self.mapping[offset..offset + bytes.len()].copy_from_slice(bytes);
    }
    pub fn len(&self) -> usize {
        self.len
    }
}
impl AsRef<[u8]> for RamBuffer {
    fn as_ref(&self) -> &[u8] {
        &self.mapping[..self.len]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn probe_status_and_cooldown_survive_error_wrapping() {
        let rejected = Failure::from_error(
            crate::Error::SessionRejected("fixture rejection").into(),
            "metadata",
        );
        assert_eq!(rejected.kind, "authentication");
        assert!(!rejected.retryable);
        let failure = Failure::http(429, "download", Some(Duration::from_secs(7)));
        let wrapped = Failure::from_error(failure.into(), "download");
        assert_eq!(wrapped.status, Some(429));
        assert_eq!(wrapped.retry_after, Some(Duration::from_secs(7)));
        assert!(wrapped.retryable);
    }
    use std::sync::atomic::AtomicUsize;
    use tokio::io::AsyncReadExt;

    #[derive(Clone)]
    struct Reply {
        status: u16,
        body: &'static str,
        length: Option<usize>,
        retry: Option<&'static str>,
        delay: Duration,
        chunk_size: usize,
        chunk_delay: Duration,
        headers: &'static str,
    }
    impl Reply {
        fn data(body: &'static str) -> Self {
            Self {
                status: 200,
                body,
                length: None,
                retry: None,
                delay: Duration::ZERO,
                chunk_size: 0,
                chunk_delay: Duration::ZERO,
                headers: "",
            }
        }
        fn status(status: u16) -> Self {
            Self {
                status,
                ..Self::data("private response with signature=secret and bearer=secret")
            }
        }
    }
    struct Fixture {
        client: Client,
        item: CloudItem,
        attempts: Arc<AtomicUsize>,
        metadata: Arc<AtomicUsize>,
        peak: Arc<AtomicUsize>,
        starts: Arc<Mutex<Vec<Instant>>>,
        requests: Arc<Mutex<Vec<String>>>,
        revision: Arc<AtomicUsize>,
        server: tokio::task::JoinHandle<()>,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.server.abort();
        }
    }
    async fn fixture(replies: Vec<Reply>, size: u64, metadata_timeout: Duration) -> Fixture {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let attempts = Arc::new(AtomicUsize::new(0));
        let metadata = Arc::new(AtomicUsize::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let starts = Arc::new(Mutex::new(Vec::new()));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let request_log = requests.clone();
        let revision = Arc::new(AtomicUsize::new(1));
        let server_revision = revision.clone();
        let state = (
            attempts.clone(),
            metadata.clone(),
            active,
            peak.clone(),
            starts.clone(),
        );
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    return;
                };
                let replies = replies.clone();
                let request_log = request_log.clone();
                let revision = server_revision.clone();
                let (attempts, metadata, active, peak, starts) = state.clone();
                tokio::spawn(async move {
                    let mut data = Vec::new();
                    let mut buffer = [0; 4096];
                    let header = loop {
                        let n = stream.read(&mut buffer).await.unwrap();
                        if n == 0 {
                            return;
                        }
                        data.extend_from_slice(&buffer[..n]);
                        let text = String::from_utf8_lossy(&data);
                        if let Some(end) = text.find("\r\n\r\n") {
                            let length = text[..end]
                                .lines()
                                .find_map(|line| {
                                    line.to_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|v| v.trim().parse::<usize>().unwrap())
                                })
                                .unwrap_or(0);
                            if data.len() >= end + 4 + length {
                                break text[..end].to_string();
                            }
                        }
                    };
                    let route = header.lines().next().unwrap();
                    let metadata_body;
                    let content = route.starts_with("GET /content?");
                    let reply = if route.starts_with("POST /v1/auth/token") {
                        Reply::data(
                            r#"{"access_token":"test-access","refresh_token":"test-refresh","expires_in":3600,"sub":"test-user"}"#,
                        )
                    } else if route.starts_with("POST /v1/shield/captcha/init") {
                        Reply::data(r#"{"captcha_token":"test-captcha","expires_in":3600}"#)
                    } else if route.starts_with("GET /drive/v1/files/file?") {
                        let attempt = metadata.fetch_add(1, Ordering::Relaxed) + 1;
                        let version = revision.load(Ordering::Acquire);
                        metadata_body = json!({"name":"sample.txt","size":size.to_string(),
                            "hash":if version == 0 { None } else { Some(format!("source-revision-{version}")) },
                            "web_content_link":format!("http://{address}/content?fresh={attempt}&signature=secret")}).to_string();
                        let wire = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                            metadata_body.len(),
                            metadata_body
                        );
                        let _ = stream.write_all(wire.as_bytes()).await;
                        return;
                    } else if content {
                        assert!(
                            !header.to_lowercase().contains("authorization:"),
                            "No credentials on original requests"
                        );
                        request_log.lock().unwrap().push(header.clone());
                        let attempt = attempts.fetch_add(1, Ordering::Relaxed);
                        starts.lock().unwrap().push(Instant::now());
                        peak.fetch_max(
                            active.fetch_add(1, Ordering::Relaxed) + 1,
                            Ordering::Relaxed,
                        );
                        replies[attempt.min(replies.len() - 1)].clone()
                    } else {
                        panic!("Unexpected fixture route");
                    };
                    tokio::time::sleep(reply.delay).await;
                    let extra = reply.headers;
                    let retry = reply
                        .retry
                        .map(|v| format!("Retry-After: {v}\r\n"))
                        .unwrap_or_default();
                    let wire = format!("HTTP/1.1 {} Fixture\r\nContent-Length: {}\r\n{retry}{extra}Connection: close\r\n\r\n", reply.status, reply.length.unwrap_or(reply.body.len()));
                    let _ = stream.write_all(wire.as_bytes()).await;
                    for chunk in reply.body.as_bytes().chunks(if reply.chunk_size > 0 {
                        reply.chunk_size
                    } else {
                        reply.body.len().max(1)
                    }) {
                        if stream.write_all(chunk).await.is_err() {
                            break;
                        }
                        tokio::time::sleep(reply.chunk_delay).await;
                    }
                    if content {
                        active.fetch_sub(1, Ordering::Relaxed);
                    }
                });
            }
        });
        let client = Client::builder()
            .refresh_token("test-refresh")
            .device_id("test-device")
            .api_base_url(format!("http://{address}"))
            .auth_base_url(format!("http://{address}"))
            .timeout(metadata_timeout)
            .build()
            .unwrap();
        Fixture {
            client,
            item: CloudItem {
                revision: None,
                id: "file".into(),
                name: "sample.txt".into(),
                path: "/sample.txt".into(),
                is_folder: false,
                size,
                ancestors: vec![],
            },
            attempts,
            metadata,
            peak,
            starts,
            requests,
            revision,
            server,
        }
    }

    #[tokio::test]
    async fn pause_keeps_partial_ram_and_resumes_the_same_http_response() {
        let body = Box::leak("retained bytes ".repeat(65536).into_boxed_str());
        let f = fixture(
            vec![Reply {
                chunk_size: 16384,
                chunk_delay: Duration::from_millis(15),
                ..Reply::data(body)
            }],
            body.len() as u64,
            Duration::from_secs(10),
        )
        .await;
        let fetches = Fetches::with_memory(8, 4 << 20);
        let cancel = AtomicBool::new(false);
        let run = download(&f.client, &f.item, &cancel, &fetches, |_, _| Ok(()));
        let pause = async {
            while fetches.download_progress()["items"][0]["received"]
                .as_u64()
                .unwrap_or(0)
                == 0
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            fetches.control.set_paused(true);
            tokio::time::sleep(Duration::from_millis(80)).await;
            let retained = fetches.memory.used();
            assert!(retained > 0 && retained < body.len() as u64);
            tokio::time::sleep(Duration::from_millis(700)).await;
            assert_eq!(
                fetches.memory.used(),
                retained,
                "Pause dropped or kept growing the original buffer"
            );
            assert_eq!(f.attempts.load(Ordering::Acquire), 1);
            fetches.control.set_paused(false);
        };
        let (result, _) = tokio::join!(run, pause);
        let data = result.unwrap();
        assert_eq!(data.as_ref().as_ref(), body.as_bytes());
        assert_eq!(
            f.attempts.load(Ordering::Acquire),
            1,
            "Pause restarted a healthy connection"
        );
        drop(data);
        assert_eq!(fetches.memory.used(), 0);
    }

    #[tokio::test]
    async fn paused_interrupted_download_resumes_validated_range_from_retained_bytes() {
        let first = Box::leak("a".repeat(512 << 10).into_boxed_str());
        let rest = Box::leak("b".repeat(512 << 10).into_boxed_str());
        let f = fixture(
            vec![
                Reply {
                    length: Some(1 << 20),
                    headers: "ETag: \"version-one\"\r\n",
                    ..Reply::data(first)
                },
                Reply {
                    status: 206,
                    headers:
                        "ETag: \"version-one\"\r\nContent-Range: bytes 524288-1048575/1048576\r\n",
                    ..Reply::data(rest)
                },
            ],
            1 << 20,
            Duration::from_secs(10),
        )
        .await;
        let fetches = Fetches::with_memory(1, 2 << 20);
        let cancel = AtomicBool::new(false);
        let run = download(&f.client, &f.item, &cancel, &fetches, |_, _| Ok(()));
        let pause = async {
            while fetches.retrying.load(Ordering::Acquire) == 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            fetches.control.set_paused(true);
            let retained = fetches.memory.used();
            assert!(retained >= 512 << 10);
            tokio::time::sleep(Duration::from_millis(750)).await;
            assert_eq!(f.attempts.load(Ordering::Acquire), 1);
            assert_eq!(fetches.memory.used(), retained);
            fetches.control.set_paused(false);
        };
        let (result, _) = tokio::join!(run, pause);
        let data = result.unwrap();
        assert_eq!(&data.as_ref().as_ref()[..512 << 10], first.as_bytes());
        assert_eq!(&data.as_ref().as_ref()[512 << 10..], rest.as_bytes());
        let headers = f.requests.lock().unwrap()[1].to_lowercase();
        assert!(headers.contains("range: bytes=524288-"));
        assert!(headers.contains("if-range: \"version-one\""));
        drop(data);
        assert_eq!(fetches.memory.used(), 0);
    }

    #[tokio::test]
    async fn clear_interrupts_a_paused_partial_and_releases_all_ram() {
        let body = Box::leak("x".repeat(1 << 20).into_boxed_str());
        let f = fixture(
            vec![Reply {
                chunk_size: 16384,
                chunk_delay: Duration::from_millis(20),
                ..Reply::data(body)
            }],
            1 << 20,
            Duration::from_secs(10),
        )
        .await;
        let fetches = Fetches::with_memory(1, 2 << 20);
        let cancel = AtomicBool::new(false);
        let run = download(&f.client, &f.item, &cancel, &fetches, |_, _| Ok(()));
        let clear = async {
            while fetches.download_progress()["items"][0]["received"]
                .as_u64()
                .unwrap_or(0)
                == 0
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            fetches.control.set_paused(true);
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert!(fetches.memory.used() > 0);
            cancel.store(true, Ordering::Release);
        };
        let (result, _) = tokio::join!(run, clear);
        assert!(result.is_err());
        assert_eq!(fetches.memory.used(), 0);
        assert_eq!(fetches.download_progress()["total"], 0);
        assert_eq!(fetches.connections.lock().unwrap().active, 0);
    }

    #[tokio::test]
    async fn slow_http_originals_overlap_beyond_full_size_budget_and_publish_speed() {
        let body = Box::leak("x".repeat(2 << 20).into_boxed_str());
        let f = fixture(
            vec![Reply {
                chunk_size: 16 << 10,
                chunk_delay: Duration::from_millis(50),
                ..Reply::data(body)
            }],
            2 << 20,
            Duration::from_secs(10),
        )
        .await;
        let fetches = Fetches::with_memory(8, 4 << 20);
        let cancel = AtomicBool::new(false);
        let copies: Vec<_> = (0..5).map(|_| f.item.clone()).collect();
        let running = futures_util::future::join_all(
            copies
                .iter()
                .map(|item| download(&f.client, item, &cancel, &fetches, |_, _| Ok(()))),
        );
        let observe = async {
            let began = Instant::now();
            loop {
                assert!(fetches.memory.used() <= 4 << 20);
                let event = fetches.download_progress();
                if f.attempts.load(Ordering::Acquire) >= 3 && event["speed"].as_f64().unwrap() > 0.0
                {
                    let items = event["items"].as_array().unwrap();
                    assert_eq!(items.len(), 5);
                    assert!(items
                        .iter()
                        .any(|item| item["received"].as_u64().unwrap() > 0));
                    assert!(
                        items
                            .iter()
                            .all(|item| item["received"].as_u64().unwrap() < 2 << 20),
                        "Expected overlap before any original finished"
                    );
                    break;
                }
                if began.elapsed() > Duration::from_secs(4) {
                    cancel.store(true, Ordering::Release);
                    panic!("Full-size reservation blocked extra downloads");
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            cancel.store(true, Ordering::Release);
        };
        let (results, _) = tokio::join!(running, observe);
        assert!(results.iter().all(Result::is_err));
        assert_eq!(fetches.memory.used(), 0);
        assert_eq!(fetches.download_progress()["total"], 0);
        assert_eq!(fetches.connections.lock().unwrap().active, 0);
    }

    #[test]
    fn live_body_throughput_grows_connections_before_any_original_finishes() {
        // Aggregate counters intentionally span one helper. Other parallel test
        // fixtures must not masquerade as this helper's changing bandwidth.
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "similarity::fetch::tests::live_body_throughput_child",
                "--ignored",
            ])
            .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[tokio::test]
    #[ignore = "isolated aggregate counters; launched by live_body_throughput_grows_connections_before_any_original_finishes"]
    async fn live_body_throughput_child() {
        let body = Box::leak("x".repeat(16 << 20).into_boxed_str());
        let f = fixture(
            vec![Reply {
                chunk_size: 8192,
                chunk_delay: Duration::from_millis(20),
                ..Reply::data(body)
            }],
            16 << 20,
            Duration::from_secs(10),
        )
        .await;
        let fetches = Fetches::with_memory(64, 256 << 20);
        let cancel = AtomicBool::new(false);
        let running = futures_util::future::join_all(
            (0..12).map(|_| download(&f.client, &f.item, &cancel, &fetches, |_, _| Ok(()))),
        );
        let observe = async {
            loop {
                if f.peak.load(Ordering::Acquire) >= 8 {
                    let snapshot = fetches.download_progress();
                    assert!(
                        snapshot["items"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .all(|row| { row["received"].as_u64().unwrap() < 16 << 20 }),
                        "Growth must not depend on completed originals"
                    );
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            cancel.store(true, Ordering::Release);
        };
        let (results, _) = tokio::time::timeout(Duration::from_secs(32), async {
            tokio::join!(running, observe)
        })
        .await
        .expect("Measured HTTP body traffic did not expand the admission limit");
        assert!(results.iter().all(Result::is_err));
        assert_eq!(fetches.download_progress()["total"], 0);
        assert_eq!(fetches.connections.lock().unwrap().active, 0);
        assert_eq!(fetches.memory.used(), 0);
    }

    #[tokio::test]
    async fn provider_backoff_preserves_existing_permits_and_delays_new_starts() {
        let fetches = Fetches::with_memory(64, 12 << 30);
        let cancel = AtomicBool::new(false);
        let mut held = Vec::new();
        for _ in 0..4 {
            held.push(fetches.acquire(&cancel).await.unwrap());
        }
        fetches.defer_requests(Duration::from_millis(100));
        assert_eq!(fetches.connection_limit(), 2);
        assert_eq!(fetches.connections.lock().unwrap().active, 4);
        assert!(fetches.try_acquire().is_none());
        held.truncate(1);
        assert!(
            fetches.try_acquire().is_none(),
            "Provider cooldown still applies with a free slot"
        );
        held.push(
            tokio::time::timeout(Duration::from_secs(1), fetches.acquire(&cancel))
                .await
                .unwrap()
                .unwrap(),
        );
        assert_eq!(fetches.connections.lock().unwrap().active, 2);
        drop(held);
        assert_eq!(fetches.connections.lock().unwrap().active, 0);
    }

    #[tokio::test]
    async fn a_file_waiting_for_a_connection_does_not_retain_a_ram_claim() {
        let fetches = Fetches::with_memory(1, 4 << 20);
        let cancel = AtomicBool::new(false);
        let held = fetches.acquire(&cancel).await.unwrap();
        let ticket = fetches.track("Queued video.mp4", 3 << 20);
        let pending = fetches.acquire_stream(3 << 20, &cancel, &ticket);
        let observe = async {
            tokio::time::sleep(Duration::from_millis(60)).await;
            assert_eq!(fetches.memory.used(), 0);
            drop(held);
        };
        let (result, _) = tokio::join!(pending, observe);
        let (lease, permit) = result.unwrap();
        assert!(lease.reserved() < lease.capacity);
        drop((lease, permit));
        assert_eq!(fetches.memory.used(), 0);
    }

    #[tokio::test]
    async fn fresh_cloud_scan_reuses_vectors_without_downloading_and_rechecks_revisions() {
        let content = "A garden with flowers, trees, and a small pond. The garden plan includes flowering plants and tall trees beside the pond.";
        let f = fixture(
            vec![Reply::data(content)],
            content.len() as u64,
            Duration::from_secs(10),
        )
        .await;
        let dir = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(dir.path());
        request.source = ScanSource::Cloud;
        request.local_paths.clear();
        request.cloud_items = vec![f.item.clone()];
        for (version, expected_downloads, expected_bytes) in [
            (1, 1, content.len() as u64),
            (1, 1, 0),
            (2, 2, content.len() as u64),
            (0, 3, content.len() as u64),
            (0, 4, content.len() as u64),
        ] {
            f.revision.store(version, Ordering::Release);
            scan(
                request.clone(),
                Some(&f.client),
                Arc::new(AtomicBool::new(false)),
            )
            .await
            .unwrap();
            let report: ScanReport =
                serde_json::from_slice(&std::fs::read(&request.report_path).unwrap()).unwrap();
            assert_eq!(report.analysed_files, 1, "{:?}", report.issues);
            assert_eq!(
                f.attempts.load(Ordering::Acquire),
                expected_downloads,
                "Original GETs for revision {version}"
            );
            assert_eq!(
                report.downloaded_bytes, expected_bytes,
                "Only an unchanged revision avoids the original GET"
            );
            assert_eq!(
                std::fs::read_dir(&request.temp_dir).unwrap().count(),
                0,
                "Originals never persist"
            );
        }
        // Same file ID and revision in another account must not use this index.
        request.data_dir = dir.path().join("other-account");
        f.revision.store(1, Ordering::Release);
        scan(
            request.clone(),
            Some(&f.client),
            Arc::new(AtomicBool::new(false)),
        )
        .await
        .unwrap();
        assert_eq!(f.attempts.load(Ordering::Acquire), 5);
    }

    #[tokio::test]
    async fn retries_503_honours_retry_after_and_refreshes_the_signed_link() {
        let f = fixture(
            vec![
                Reply {
                    retry: Some("1"),
                    ..Reply::status(503)
                },
                Reply::data("complete"),
            ],
            8,
            Duration::from_secs(10),
        )
        .await;
        let data = download(
            &f.client,
            &f.item,
            &AtomicBool::new(false),
            &Fetches::new(52),
            |_, _| Ok(()),
        )
        .await
        .unwrap();
        assert_eq!(data.as_ref().as_ref(), b"complete");
        assert_eq!(f.attempts.load(Ordering::Relaxed), 2);
        assert_eq!(f.metadata.load(Ordering::Relaxed), 2);
        let starts = f.starts.lock().unwrap();
        assert!(starts[1].duration_since(starts[0]) >= Duration::from_millis(950));
    }

    #[tokio::test]
    async fn incomplete_copy_is_restarted_without_contaminating_the_original() {
        let f = fixture(
            vec![
                Reply {
                    length: Some(8),
                    ..Reply::data("bad")
                },
                Reply::data("complete"),
            ],
            8,
            Duration::from_secs(10),
        )
        .await;
        let data = download(
            &f.client,
            &f.item,
            &AtomicBool::new(false),
            &Fetches::new(4),
            |_, _| Ok(()),
        )
        .await
        .unwrap();
        assert_eq!(data.as_ref().as_ref(), b"complete");
        assert_eq!(f.attempts.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn expired_content_link_gets_a_fresh_metadata_request() {
        let f = fixture(
            vec![Reply::status(403), Reply::data("complete")],
            8,
            Duration::from_secs(10),
        )
        .await;
        let data = download(
            &f.client,
            &f.item,
            &AtomicBool::new(false),
            &Fetches::new(4),
            |_, _| Ok(()),
        )
        .await
        .unwrap();
        assert_eq!(data.as_ref().as_ref(), b"complete");
        assert_eq!(f.metadata.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn permanent_errors_keep_status_without_private_server_details() {
        let f = fixture(vec![Reply::status(404)], 8, Duration::from_secs(10)).await;
        let error = download(
            &f.client,
            &f.item,
            &AtomicBool::new(false),
            &Fetches::new(4),
            |_, _| Ok(()),
        )
        .await
        .unwrap_err();
        let error = error.downcast_ref::<Failure>().unwrap();
        assert_eq!(error.status, Some(404));
        assert_eq!(error.attempts, 1);
        assert!(!format!("{error:?}").contains("secret"));
        assert_eq!(f.attempts.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn memory_admission_precedes_content_and_completed_buffers_release_the_reservation() {
        let f = fixture(vec![Reply::data("complete")], 8, Duration::from_secs(10)).await;
        let cancel = AtomicBool::new(false);
        let too_small = Fetches::with_memory(8, 7);
        let error = download(&f.client, &f.item, &cancel, &too_small, |_, _| Ok(()))
            .await
            .unwrap_err();
        assert_eq!(
            error.downcast_ref::<Failure>().unwrap().kind,
            "memory_limit"
        );
        assert_eq!(
            f.attempts.load(Ordering::Relaxed),
            0,
            "Content fetched before RAM admission"
        );
        assert_eq!(too_small.memory.used(), 0);
        let fetches = Fetches::with_memory(8, 16);
        let data = download(&f.client, &f.item, &cancel, &fetches, |_, _| Ok(()))
            .await
            .unwrap();
        assert_eq!(fetches.memory.used(), 8);
        assert_eq!(data.as_ref().as_ref(), b"complete");
        let weak = Arc::downgrade(&data);
        drop(data);
        assert!(weak.upgrade().is_none());
        assert_eq!(fetches.memory.used(), 0);
    }

    #[tokio::test]
    async fn exhausted_retries_preserve_safe_status_and_attempts_in_scan_coverage() {
        let f = fixture(vec![Reply::status(503)], 8, Duration::from_secs(10)).await;
        let dir = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(dir.path());
        request.source = ScanSource::Cloud;
        request.local_paths.clear();
        request.cloud_items = vec![f.item.clone()];
        scan(
            request.clone(),
            Some(&f.client),
            Arc::new(AtomicBool::new(false)),
        )
        .await
        .unwrap();
        let bytes = std::fs::read(&request.report_path).unwrap();
        let report: ScanReport = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(report.failed_files, 1);
        assert_eq!(report.analysed_files, 0);
        assert_eq!(f.attempts.load(Ordering::Relaxed), 5);
        assert!(report.issues[0].reason.contains("503"));
        assert!(!String::from_utf8_lossy(&bytes).contains("secret"));
        let db = rusqlite::Connection::open(
            request
                .data_dir
                .join("runs")
                .join(format!("{}.sqlite3", report.run_id.unwrap())),
        )
        .unwrap();
        let raw: String = db
            .query_row("SELECT diagnostic FROM files", [], |r| r.get(0))
            .unwrap();
        let diagnostic: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(diagnostic["fetch"]["attempts"], 5);
        assert_eq!(diagnostic["fetch"]["http_status"], 503);
        assert_eq!(diagnostic["fetch"]["operation"], "download");
        assert!(!raw.contains("secret"));
    }

    #[tokio::test]
    async fn download_capacity_is_independent_of_analysis_workers_and_metadata_timeout() {
        let f = fixture(
            vec![Reply {
                delay: Duration::from_millis(400),
                ..Reply::data("complete")
            }],
            8,
            Duration::from_millis(250),
        )
        .await;
        let dir = tempfile::tempdir().unwrap();
        let fetches = Fetches::new(52);
        let cancel = AtomicBool::new(false);
        let paths: Vec<_> = (0..20)
            .map(|i| dir.path().join(format!("original-{i}")))
            .collect();
        let results = futures_util::future::join_all(
            paths
                .iter()
                .map(|_| download(&f.client, &f.item, &cancel, &fetches, |_, _| Ok(()))),
        )
        .await;
        assert!(results.iter().all(Result::is_ok), "{results:?}");
        assert_eq!(
            f.peak.load(Ordering::Relaxed),
            4,
            "Downloads remain concurrent despite slow bodies and a shorter metadata timeout"
        );
        assert_eq!(
            fetches.connection_limit(),
            4,
            "Completed files alone must not expand the pool"
        );
        assert_eq!(
            fetches.received_bytes.load(Ordering::Relaxed),
            160,
            "Aggregate bytes survive removal of completed progress rows"
        );
        assert_eq!(fetches.waiting.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn recoverable_scan_keeps_retrying_beyond_the_old_attempt_limit() {
        let mut replies: Vec<_> = (0..5).map(|_| Reply::status(503)).collect();
        replies.push(Reply::data("complete"));
        let f = fixture(replies, 8, Duration::from_secs(10)).await;
        let mut fetches = Fetches::new(2);
        fetches.retry_forever = true;
        let data = download(
            &f.client,
            &f.item,
            &AtomicBool::new(false),
            &fetches,
            |_, _| Ok(()),
        )
        .await
        .unwrap();
        assert_eq!(data.as_ref().as_ref(), b"complete");
        assert_eq!(f.attempts.load(Ordering::Relaxed), 6);
        assert_eq!(fetches.retrying.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn cancellation_interrupts_retry_cooldown_and_waiting_for_capacity() {
        let f = fixture(
            vec![Reply {
                retry: Some("30"),
                ..Reply::status(503)
            }],
            8,
            Duration::from_secs(10),
        )
        .await;
        let mut fetches = Fetches::new(1);
        fetches.retry_forever = true;
        let cancel = AtomicBool::new(false);
        let running = download(&f.client, &f.item, &cancel, &fetches, |_, _| Ok(()));
        let stopping = async {
            while fetches.retrying.load(Ordering::Relaxed) == 0
                || f.attempts.load(Ordering::Relaxed) == 0
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert_eq!(
                fetches.memory.used(),
                0,
                "Backoff retained an incomplete original"
            );
            assert_eq!(
                fetches.connections.lock().unwrap().active,
                0,
                "Backoff retained a connection"
            );
            cancel.store(true, Ordering::Release);
        };
        let start = Instant::now();
        let (result, _) = tokio::join!(running, stopping);
        assert!(result.is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(fetches.retrying.load(Ordering::Relaxed), 0);
        assert_eq!(f.attempts.load(Ordering::Relaxed), 1);
        // A reserved download slot must not make cancellation wait for a file.
        let fetches = Fetches::new(1);
        let cancel = AtomicBool::new(false);
        let permit = fetches.acquire(&cancel).await.unwrap();
        cancel.store(true, Ordering::Release);
        assert!(fetches.acquire(&cancel).await.is_err());
        drop(permit);
        assert_eq!(fetches.waiting.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn a_file_waiting_for_ram_does_not_hold_the_only_connection() {
        let large = fixture(vec![Reply::data("12345678")], 8, Duration::from_secs(10)).await;
        let small = fixture(vec![Reply::data("1234")], 4, Duration::from_secs(10)).await;
        let fetches = Fetches::with_memory(1, 12);
        let cancel = AtomicBool::new(false);
        let held = fetches.memory.reserve(6, &cancel).await.unwrap();
        let pending = download(&large.client, &large.item, &cancel, &fetches, |_, _| Ok(()));
        let consume = async {
            while fetches.memory.waiting.load(Ordering::Acquire) == 0 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            let data = tokio::time::timeout(
                Duration::from_secs(2),
                download(&small.client, &small.item, &cancel, &fetches, |_, _| Ok(())),
            )
            .await
            .unwrap()
            .unwrap();
            assert_eq!(data.as_ref().as_ref(), b"1234");
            assert_eq!(large.attempts.load(Ordering::Acquire), 0);
            assert_eq!(fetches.memory.used(), 10);
            drop(data);
            drop(held);
        };
        let (result, _) = tokio::join!(pending, consume);
        let data = result.unwrap();
        assert_eq!(data.as_ref().as_ref(), b"12345678");
        drop(data);
        assert_eq!(fetches.memory.used(), 0);
    }

    #[tokio::test]
    async fn an_interrupted_download_releases_full_ram_to_a_waiting_download() {
        let stalled = fixture(
            vec![Reply {
                delay: Duration::from_secs(30),
                ..Reply::data("original")
            }],
            8,
            Duration::from_secs(10),
        )
        .await;
        let healthy = fixture(vec![Reply::data("complete")], 8, Duration::from_secs(10)).await;
        let fetches = Fetches::with_memory(2, 8);
        let cancel = AtomicBool::new(false);
        tokio::time::timeout(Duration::from_secs(3), async {
            let mut first = Box::pin(download(
                &stalled.client,
                &stalled.item,
                &cancel,
                &fetches,
                |_, _| Ok(()),
            ));
            while fetches.active.load(Ordering::Acquire) == 0 {
                tokio::select! {
                    _ = &mut first => panic!("Stalled download returned early"),
                    _ = tokio::time::sleep(Duration::from_millis(5)) => {},
                }
            }
            assert_eq!(fetches.memory.used(), 8);
            let mut waiting = Box::pin(download(
                &healthy.client,
                &healthy.item,
                &cancel,
                &fetches,
                |_, _| Ok(()),
            ));
            while fetches.memory.waiting.load(Ordering::Acquire) == 0 {
                tokio::select! {
                    _ = &mut first => panic!("Stalled download returned early"),
                    _ = &mut waiting => panic!("Waiting download exceeded Download RAM"),
                    _ = tokio::time::sleep(Duration::from_millis(5)) => {},
                }
            }
            assert_eq!(healthy.attempts.load(Ordering::Acquire), 0);
            // An interrupted/dropped request must release its lease even if
            // it never received a byte and no global cancellation flag is set.
            drop(first);
            let data = waiting.await.unwrap();
            assert_eq!(data.as_ref().as_ref(), b"complete");
            drop(data);
            assert_eq!(fetches.memory.used(), 0);
            assert_eq!(fetches.memory.waiting.load(Ordering::Acquire), 0);
            assert_eq!(fetches.connections.lock().unwrap().active, 0);
        })
        .await
        .expect("A waiting download did not reclaim the interrupted download's RAM");
    }
}

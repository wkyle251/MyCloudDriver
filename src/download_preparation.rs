//! Short-lived transfer-owned cloud setup. Only verification deferrals retain
//! it; Pause, failures and completion drop it. A separately scoped route hint
//! may survive a transient body retry, without retaining its signed URL or
//! bypassing the next cloud permission check. It never certifies local bytes.
use pikpak::{ContentMode, DownloadInfo, FileInfo};
use std::{
    io::{self, Write},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    },
    time::{Duration, SystemTime},
};

const TTL: Duration = Duration::from_secs(60);
const MAX_ENTRY_BYTES: usize = 32 << 10;
const MAX_BYTES: usize = 16 << 20;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct Key {
    pub(crate) scope: String,
    file: String,
    mode: Option<ContentMode>,
    size: u64,
    revision: Option<String>,
    referer: Option<String>,
    user_route_allowed: bool,
}
impl Key {
    pub(crate) fn new(scope: String, file: &str, mode: Option<ContentMode>) -> Self {
        Self {
            scope,
            file: file.into(),
            mode,
            size: 0,
            revision: None,
            referer: None,
            user_route_allowed: false,
        }
    }
    pub(crate) fn for_file(scope: String, file: &FileInfo, mode: Option<ContentMode>) -> Self {
        Self {
            scope,
            file: file.id.clone(),
            mode,
            size: file.size,
            revision: pikpak::client::download_revision(
                file.hash.as_deref(),
                file.modified_time.as_deref(),
            ),
            referer: None,
            user_route_allowed: true,
        }
    }
    pub(crate) fn for_probe(link: &str, file: &str, size: u64, revision: Option<&str>, referer: Option<&str>) -> Self {
        Self { scope: link.into(), file: file.into(), mode: None, size,
            revision: revision.map(str::to_owned), referer: referer.map(str::to_owned), user_route_allowed: false }
    }
    pub(crate) fn without_user_route(mut self) -> Self {
        self.user_route_allowed = false;
        self
    }
    fn bytes(&self) -> usize {
        self.scope
            .len()
            .saturating_add(self.file.len())
            .saturating_add(self.revision.as_ref().map_or(0, String::len))
            .saturating_add(self.referer.as_ref().map_or(0, String::len))
    }
}

struct Budget {
    used: AtomicUsize,
    maximum: usize,
}
static BUDGET: Budget = Budget {
    used: AtomicUsize::new(0),
    maximum: MAX_BYTES,
};
struct Reservation<'a> {
    budget: &'a Budget,
    bytes: usize,
}
impl Budget {
    fn reserve(&self, bytes: usize) -> Option<Reservation<'_>> {
        self.used
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                used.checked_add(bytes).filter(|next| *next <= self.maximum)
            })
            .ok()?;
        Some(Reservation {
            budget: self,
            bytes,
        })
    }
}
impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        self.budget.used.fetch_sub(self.bytes, Ordering::Relaxed);
    }
}

#[derive(Clone)]
struct Download {
    info: DownloadInfo,
    user_handoff: bool,
}
#[derive(Clone, PartialEq, Eq)]
struct UserRoute { size: u64, revision: Option<String> }
struct Cached<T> {
    key: Key,
    value: T,
    fetched: SystemTime,
    _reservation: Reservation<'static>,
}
struct Slot<T>(Mutex<Option<Cached<T>>>);
impl<T> Cached<T> {
    fn fresh(&self) -> bool {
        self.fetched.elapsed().is_ok_and(|age| age < TTL)
    }
}
impl<T> Default for Slot<T> {
    fn default() -> Self {
        Self(Mutex::new(None))
    }
}
impl<T: Clone> Slot<T> {
    fn get(&self, key: &Key) -> Option<T> {
        let mut slot = self.0.lock().unwrap();
        if slot
            .as_ref()
            .is_some_and(|entry| entry.key != *key || !entry.fresh())
        {
            slot.take();
        }
        slot.as_ref().map(|entry| entry.value.clone())
    }
    fn remember(&self, key: &Key, value: &T, bytes: usize) {
        let mut slot = self.0.lock().unwrap();
        slot.take();
        let bytes = bytes
            .saturating_add(key.bytes())
            .saturating_add(std::mem::size_of::<Cached<T>>());
        if bytes > MAX_ENTRY_BYTES {
            return;
        }
        let Some(reservation) = BUDGET.reserve(bytes) else {
            return;
        };
        *slot = Some(Cached {
            key: key.clone(),
            value: value.clone(),
            fetched: SystemTime::now(),
            _reservation: reservation,
        });
    }
    fn clear(&self) {
        self.0.lock().unwrap().take();
    }
}

#[derive(Default)]
pub(crate) struct State {
    download: Slot<Download>,
    resolved: Slot<FileInfo>,
    probe: Slot<Option<String>>,
    user_route: Slot<UserRoute>,
}
impl State {
    pub(crate) fn attempt(&self) -> Attempt<'_> {
        Attempt {
            state: self,
            deferred: false,
            body_retry: false,
        }
    }
    pub(crate) fn download(&self, key: &Key, user_handoff: bool) -> Option<DownloadInfo> {
        if user_handoff && !key.user_route_allowed {
            self.download.clear();
            return None;
        }
        self.download
            .get(key)
            .filter(|value| value.user_handoff == user_handoff)
            .map(|value| value.info)
    }
    pub(crate) fn user_handoff(&self, key: &Key) -> bool {
        self.user_route.get(key).is_some()
    }
    pub(crate) fn has_user_handoff(&self) -> bool {
        let mut slot = self.user_route.0.lock().unwrap();
        if slot.as_ref().is_some_and(|entry| !entry.fresh()) { slot.take(); }
        slot.is_some()
    }
    pub(crate) fn remember_download(&self, key: &Key, info: &DownloadInfo, user_handoff: bool) {
        if user_handoff && !key.user_route_allowed {
            self.download.clear();
            return;
        }
        let bytes = info
            .web_content_link
            .len()
            .saturating_add(info.name.len())
            .saturating_add(info.source_revision.as_ref().map_or(0, String::len));
        if bytes > MAX_ENTRY_BYTES {
            self.download.clear();
            return;
        }
        self.download.remember(
            key,
            &Download {
                info: info.clone(),
                user_handoff,
            },
            bytes,
        );
        if user_handoff && key.user_route_allowed {
            let route = UserRoute { size: info.size, revision: info.source_revision.clone() };
            let mut slot = self.user_route.0.lock().unwrap();
            if let Some(entry) = slot.as_mut().filter(|entry| entry.key == *key) {
                // Do not renew even an expired preference during a long User
                // attempt. Changed source metadata invalidates the hint until
                // the next attempt restores the original Guest-first policy.
                if entry.value != route { entry.fetched = SystemTime::UNIX_EPOCH; }
            } else {
                drop(slot);
                self.user_route.remember(key, &route, route.revision.as_ref().map_or(0, String::len));
            }
        }
    }
    pub(crate) fn resolved(&self, key: &Key) -> Option<FileInfo> {
        self.resolved.get(key)
    }
    pub(crate) fn remember_resolved(&self, key: &Key, file: &FileInfo) {
        // Count without allocating a second JSON document or retaining large
        // optional metadata. Cache refusal always takes the normal setup path.
        struct Size(usize);
        impl Write for Size {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.0 = self.0.saturating_add(bytes.len());
                if self.0 > MAX_ENTRY_BYTES {
                    return Err(io::Error::other("Setup entry too large"));
                }
                Ok(bytes.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let mut size = Size(0);
        if serde_json::to_writer(&mut size, file).is_ok() {
            self.resolved.remember(key, file, size.0);
        } else {
            self.resolved.clear();
        }
    }
    pub(crate) fn probe(&self, key: &Key) -> Option<Option<String>> {
        self.probe.get(key)
    }
    pub(crate) fn remember_probe(&self, key: &Key, etag: &Option<String>) {
        self.probe.remember(key, etag, etag.as_ref().map_or(0, String::len));
    }
}

pub(crate) struct Attempt<'a> {
    state: &'a State,
    deferred: bool,
    body_retry: bool,
}
impl Attempt<'_> {
    pub(crate) fn defer(&mut self) {
        self.deferred = true;
    }
    pub(crate) fn retry_body(&mut self, error: &anyhow::Error) {
        self.body_retry = error.is::<TransientBodyRetry>();
    }
}
impl Drop for Attempt<'_> {
    fn drop(&mut self) {
        if !self.deferred {
            self.state.download.clear();
            self.state.resolved.clear();
            self.state.probe.clear();
            if !self.body_retry {
                self.state.user_route.clear();
            }
        }
    }
}

/// Created only at the original-body transport boundary. A metadata outage or
/// an expired/denied signed URL must not preserve an earlier User route hint.
#[derive(Debug, thiserror::Error)]
#[error("The original body was temporarily interrupted")]
struct TransientBodyRetry;

#[derive(Debug, thiserror::Error)]
#[error("Guest metadata did not provide an available original route")]
struct GuestLookupUnavailable;

pub(crate) fn guest_lookup_failure(error: pikpak::Error, dynamic: bool) -> anyhow::Error {
    let unavailable = dynamic && !pikpak::content_mode::guest_lookup_transient(&error);
    let error = anyhow::Error::new(error);
    if unavailable { error.context(GuestLookupUnavailable) } else { error }
}
pub(crate) fn guest_route_unavailable(error: &anyhow::Error) -> bool {
    error.is::<GuestLookupUnavailable>()
}

pub(crate) fn body_failure(error: anyhow::Error) -> anyhow::Error {
    use pikpak::download_policy::{HttpFailure, Interrupted};
    let range_auth = |failure: &pikpak::download_ranges::Error| matches!(failure,
        pikpak::download_ranges::Error::Http(HttpFailure { status: 401 | 403, .. }));
    let api_auth = |failure: &pikpak::Error| matches!(failure,
        pikpak::Error::Api { status: 401 | 403, .. } | pikpak::Error::RetryAfter { status: 401 | 403, .. });
    // Typed anyhow contexts need direct downcasting, while transparent range
    // wrappers need an explicit variant match. Neither may hide authentication
    // failure behind the generic Interrupted marker used by body retries.
    let authentication_failure = error.downcast_ref::<HttpFailure>().is_some_and(|failure| matches!(failure.status, 401 | 403))
        || error.downcast_ref::<pikpak::download_ranges::Error>().is_some_and(range_auth)
        || error.downcast_ref::<pikpak::Error>().is_some_and(api_auth)
        || error.chain().any(|cause| {
        cause.downcast_ref::<HttpFailure>().is_some_and(|failure| matches!(failure.status, 401 | 403))
            || cause.downcast_ref::<pikpak::download_ranges::Error>().is_some_and(range_auth)
            || cause.downcast_ref::<pikpak::Error>().is_some_and(api_auth)
    });
    let transient = !authentication_failure && (error.is::<Interrupted>() || error.chain().any(|cause| {
        cause.is::<Interrupted>()
            || cause.downcast_ref::<HttpFailure>().is_some_and(|failure| pikpak::download_policy::transient_status(failure.status))
            || cause.downcast_ref::<reqwest::Error>().is_some_and(|failure|
                !failure.is_builder() && (failure.is_timeout() || failure.is_connect() || failure.is_request() || failure.is_body()))
            || cause.downcast_ref::<pikpak::download_ranges::Error>().is_some_and(|failure| match failure {
                pikpak::download_ranges::Error::Network(error) => !error.is_builder(),
                pikpak::download_ranges::Error::Http(failure) => pikpak::download_policy::transient_status(failure.status),
                pikpak::download_ranges::Error::Incomplete(_) => true,
                _ => false,
            })
    }));
    if transient { error.context(TransientBodyRetry) } else { error }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranged_http_retries_preserve_user_route_only_for_transient_body_failures() {
        use pikpak::download_policy::{HttpFailure, Interrupted};
        for status in [401, 403, 429, 503] {
            for interrupted_context in [false, true] {
                let state = State::default();
                let key = Key::for_file("account:generated".into(), &file(), Some(ContentMode::Dynamic));
                state.remember_download(&key, &info(), true);
                let fetched = state.user_route.0.lock().unwrap().as_ref().unwrap().fetched;
                let error = anyhow::Error::new(pikpak::download_ranges::Error::Http(HttpFailure {
                    status, retry_after: Some(Duration::from_secs(17)),
                })).context("generated range body response");
                let error = if interrupted_context { error.context(Interrupted) } else { error };
                assert!(pikpak::download_policy::retryable(&error));
                assert_eq!(pikpak::download_policy::delay(&error), Some(Duration::from_secs(17)));
                let error = body_failure(error);
                let mut attempt = state.attempt();attempt.retry_body(&error);drop(attempt);
                assert!(state.download(&key, true).is_none(), "Every body retry refreshes the signed URL");
                let retained = state.user_handoff(&key);
                assert_eq!(retained, matches!(status, 429 | 503), "HTTP {status}, interrupted={interrupted_context}");
                if retained { assert_eq!(state.user_route.0.lock().unwrap().as_ref().unwrap().fetched, fetched); }
            }
        }
    }

    #[test]
    fn ranged_early_eof_keeps_the_hint_but_authentication_context_still_invalidates_it() {
        use pikpak::download_policy::{HttpFailure, Interrupted};
        for authentication in [false, true] {
            let state = State::default();
            let key = Key::for_file("account:generated".into(), &file(), Some(ContentMode::Dynamic));
            state.remember_download(&key, &info(), true);
            let error = anyhow::Error::new(pikpak::download_ranges::Error::Incomplete(Interrupted))
                .context("generated range ended before its declared coverage");
            let error = if authentication { error.context(HttpFailure { status: 403, retry_after: None }) } else { error };
            assert!(pikpak::download_policy::retryable(&error));
            let mut attempt = state.attempt();attempt.retry_body(&body_failure(error));drop(attempt);
            assert_eq!(state.user_handoff(&key), !authentication);
            assert!(state.download(&key, true).is_none());
        }
    }

    #[test]
    fn body_retries_keep_only_the_scoped_user_hint_without_extending_it() {
        let state = State::default();
        let key = Key::for_file("account:generated".into(), &file(), Some(ContentMode::Dynamic));
        state.remember_download(&key, &info(), true);
        let fetched = state.user_route.0.lock().unwrap().as_ref().unwrap().fetched;
        for _ in 0..3 {
            let mut attempt = state.attempt();
            let error = body_failure(anyhow::Error::new(pikpak::download_policy::HttpFailure { status: 503, retry_after: None }));
            attempt.retry_body(&error);
            drop(attempt);
            assert!(state.download(&key, true).is_none(), "Body retries must refresh signed URLs and permissions");
            assert!(state.user_handoff(&key));
            state.remember_download(&key, &info(), true);
            assert_eq!(state.user_route.0.lock().unwrap().as_ref().unwrap().fetched, fetched);
        }
        state.user_route.0.lock().unwrap().as_mut().unwrap().fetched -= TTL;
        let expired = state.user_route.0.lock().unwrap().as_ref().unwrap().fetched;
        state.remember_download(&key, &info(), true);
        assert_eq!(state.user_route.0.lock().unwrap().as_ref().unwrap().fetched, expired, "Even expired hints cannot renew during a long User attempt");
        assert!(!state.user_handoff(&key));
    }
    #[test]
    fn user_route_hints_never_cross_account_share_source_revision_or_mode() {
        let state = State::default();
        let file = file();
        let key = Key::for_file("share:generated:account:first".into(), &file, Some(ContentMode::Dynamic));
        for other in [
            Key { scope: "share:generated:account:second".into(), ..key.clone() },
            Key { scope: "share:other:account:first".into(), ..key.clone() },
            Key { file: "other".into(), ..key.clone() },
            Key { size: 9, ..key.clone() },
            Key { revision: Some("gcid:OTHER".into()), ..key.clone() },
            Key { mode: Some(ContentMode::Guest), ..key.clone() },
        ] {
            state.remember_download(&key, &info(), true);
            assert!(!state.user_handoff(&other));
            assert!(!state.user_handoff(&key), "Mismatched lookup must discard the hint");
        }
        for changed in [DownloadInfo { size: 9, ..info() }, DownloadInfo { source_revision: Some("gcid:CHANGED".into()), ..info() }] {
            state.remember_download(&key, &info(), true);
            state.remember_download(&key, &changed, true);
            assert!(!state.user_handoff(&key), "Fresh URL metadata changes must invalidate the previous route hint too");
        }
        let anonymous = key.clone().without_user_route();
        state.remember_download(&anonymous, &info(), true);
        assert!(!state.user_handoff(&anonymous), "An unresolved account cannot authorize a reusable route preference");
        assert!(state.download(&anonymous, true).is_none(), "Unbound account URLs cannot survive verification deferrals either");
    }
    #[test]
    fn permission_metadata_and_control_failures_drop_user_preferences() {
        for error in [
            anyhow::Error::new(pikpak::download_policy::HttpFailure { status: 403, retry_after: None }),
            anyhow::Error::new(pikpak::download_policy::HttpFailure { status: 401, retry_after: None }),
            anyhow::Error::new(pikpak::Error::Api { status: 503, message: "generated metadata outage".into() }),
            anyhow::Error::new(crate::transfer_control::Paused),
        ] {
            let state = State::default();
            let key = Key::for_file("account:generated".into(), &file(), Some(ContentMode::Dynamic));
            state.remember_download(&key, &info(), true);
            let mut attempt = state.attempt();
            attempt.retry_body(&body_failure(error));
            drop(attempt);
            assert!(!state.user_handoff(&key));
        }
        let state = State::default();
        let key = Key::for_file("account:generated".into(), &file(), Some(ContentMode::Dynamic));
        state.remember_download(&key, &info(), true);
        drop(state.attempt());
        assert!(!state.user_handoff(&key), "Completion/cancellation/unclassified exits release the hint");
    }
    #[test]
    fn probes_are_bound_to_the_exact_request_expire_and_survive_only_deferrals() {
        let state = State::default();
        let key = Key::for_probe("https://example.invalid/original?sig=one", "generated", 8,
            Some("gcid:ONE"), Some("https://example.invalid/"));
        let mut attempt = state.attempt();
        state.remember_probe(&key, &Some("\"etag-one\"".into()));
        attempt.defer(); drop(attempt);
        assert_eq!(state.probe(&key), Some(Some("\"etag-one\"".into())));
        for changed in [
            Key { scope: "https://example.invalid/original?sig=two".into(), ..key.clone() },
            Key { file: "other".into(), ..key.clone() },
            Key { size: 9, ..key.clone() },
            Key { revision: Some("gcid:TWO".into()), ..key.clone() },
            Key { referer: None, ..key.clone() },
        ] {
            state.remember_probe(&key, &Some("\"etag-one\"".into()));
            assert!(state.probe(&changed).is_none());
        }
        state.remember_probe(&key, &None);
        assert_eq!(state.probe(&key), Some(None), "Unsupported ranges are a bounded cached result too");
        state.probe.0.lock().unwrap().as_mut().unwrap().fetched -= TTL;
        assert!(state.probe(&key).is_none(), "Cache hits must not extend the original expiry");
        state.remember_probe(&key, &Some("\"etag-one\"".into()));
        drop(state.attempt());
        assert!(state.probe(&key).is_none(), "Pause, failures and completion release cached setup");
    }
    fn info() -> DownloadInfo {
        DownloadInfo {
            web_content_link: "https://example.invalid/original?signature=generated".into(),
            name: "generated.bin".into(),
            size: 8,
            source_revision: Some("gcid:GENERATED".into()),
        }
    }
    fn file() -> FileInfo {
        serde_json::from_value(serde_json::json!({"id":"generated", "name":"generated.bin", "size":"8", "kind":"drive#file", "hash":"GENERATED"})).unwrap()
    }
    #[test]
    fn only_deferrals_retain_setup_and_hits_do_not_extend_its_expiry() {
        let state = State::default();
        let file = file();
        let key = Key::for_file(
            "account:generated".into(),
            &file,
            Some(ContentMode::Dynamic),
        );
        {
            let mut attempt = state.attempt();
            state.remember_download(&key, &info(), true);
            attempt.defer();
        }
        assert!(state.user_handoff(&key));
        assert!(state.download(&key, false).is_none());
        assert!(state.download(&key, true).is_some());
        let fetched = state.download.0.lock().unwrap().as_ref().unwrap().fetched;
        assert!(state.download(&key, true).is_some());
        assert_eq!(
            state.download.0.lock().unwrap().as_ref().unwrap().fetched,
            fetched
        );
        state.download.0.lock().unwrap().as_mut().unwrap().fetched -= TTL;
        state.user_route.0.lock().unwrap().as_mut().unwrap().fetched -= TTL;
        assert!(!state.user_handoff(&key));
        assert!(state.download(&key, true).is_none());
        state.remember_download(&key, &info(), true);
        state.download.0.lock().unwrap().as_mut().unwrap().fetched += TTL;
        assert!(
            state.download(&key, true).is_none(),
            "A clock rollback must invalidate setup"
        );
        state.remember_download(&key, &info(), false);
        drop(state.attempt());
        assert!(
            state.download(&key, false).is_none(),
            "Non-deferral exits must refresh cloud setup"
        );
    }
    #[test]
    fn changed_listing_invalidates_download_setup_and_resolved_paths_expire() {
        let state = State::default();
        let mut file = file();
        let key = Key::for_file(
            "account:generated".into(),
            &file,
            Some(ContentMode::Dynamic),
        );
        for revision in [false, true] {
            state.remember_download(&key, &info(), true);
            if revision {
                file.hash = Some("CHANGED".into());
            } else {
                file.size += 1;
            }
            assert!(!state.user_handoff(&Key::for_file(key.scope.clone(), &file, Some(ContentMode::Dynamic))));
            assert!(state
                .download(
                    &Key::for_file(key.scope.clone(), &file, Some(ContentMode::Dynamic)),
                    true
                )
                .is_none());
            file = self::file();
        }
        let path = Key::new(
            "path:generated.bin".into(),
            &file.id,
            Some(ContentMode::Dynamic),
        );
        state.remember_resolved(&path, &file);
        assert_eq!(state.resolved(&path).unwrap().id, file.id);
        state.resolved.0.lock().unwrap().as_mut().unwrap().fetched -= TTL;
        assert!(state.resolved(&path).is_none());
        state.remember_resolved(&path, &file);
        drop(state.attempt());
        assert!(state.resolved(&path).is_none());
    }
    #[test]
    fn setup_is_bound_to_source_and_mode_and_large_entries_are_not_retained() {
        let state = State::default();
        let key = Key::new(
            "account:first".into(),
            "generated",
            Some(ContentMode::Guest),
        );
        for other in [
            Key::new(
                "account:second".into(),
                "generated",
                Some(ContentMode::Guest),
            ),
            Key::new("share:first".into(), "generated", None),
            Key::new(
                "account:first".into(),
                "different",
                Some(ContentMode::Guest),
            ),
            Key::new("account:first".into(), "generated", Some(ContentMode::User)),
        ] {
            state.remember_download(&key, &info(), false);
            assert!(state.download(&other, false).is_none());
        }
        let mut large = info();
        large.web_content_link = "x".repeat(MAX_ENTRY_BYTES);
        state.remember_download(&key, &large, false);
        assert!(state.download(&key, false).is_none());
        let budget = Budget {
            used: AtomicUsize::new(0),
            maximum: 8,
        };
        let held = budget.reserve(8).unwrap();
        assert!(budget.reserve(1).is_none());
        drop(held);
        assert!(budget.reserve(8).is_some());
    }
}

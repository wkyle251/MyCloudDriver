//! Short-lived transfer-owned cloud setup. Only verification deferrals retain
//! it; Pause, failures and completion drop it. It never certifies local bytes.
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
}
impl Key {
    pub(crate) fn new(scope: String, file: &str, mode: Option<ContentMode>) -> Self {
        Self {
            scope,
            file: file.into(),
            mode,
            size: 0,
            revision: None,
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
        }
    }
    fn matches(&self, file: &FileInfo, mode: Option<ContentMode>) -> bool {
        self.file == file.id
            && self.mode == mode
            && self.size == file.size
            && self.revision
                == pikpak::client::download_revision(
                    file.hash.as_deref(),
                    file.modified_time.as_deref(),
                )
    }
    fn bytes(&self) -> usize {
        self.scope
            .len()
            .saturating_add(self.file.len())
            .saturating_add(self.revision.as_ref().map_or(0, String::len))
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
}
impl State {
    pub(crate) fn attempt(&self) -> Attempt<'_> {
        Attempt {
            state: self,
            deferred: false,
        }
    }
    pub(crate) fn download(&self, key: &Key, user_handoff: bool) -> Option<DownloadInfo> {
        self.download
            .get(key)
            .filter(|value| value.user_handoff == user_handoff)
            .map(|value| value.info)
    }
    pub(crate) fn user_handoff(&self, file: &FileInfo, mode: Option<ContentMode>) -> bool {
        let slot = self.download.0.lock().unwrap();
        slot.as_ref().is_some_and(|entry| {
            entry.fresh() && entry.key.matches(file, mode) && entry.value.user_handoff
        })
    }
    pub(crate) fn remember_download(&self, key: &Key, info: &DownloadInfo, user_handoff: bool) {
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
}

pub(crate) struct Attempt<'a> {
    state: &'a State,
    deferred: bool,
}
impl Attempt<'_> {
    pub(crate) fn defer(&mut self) {
        self.deferred = true;
    }
}
impl Drop for Attempt<'_> {
    fn drop(&mut self) {
        if !self.deferred {
            self.state.download.clear();
            self.state.resolved.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        assert!(state.user_handoff(&file, Some(ContentMode::Dynamic)));
        assert!(state.download(&key, false).is_none());
        assert!(state.download(&key, true).is_some());
        let fetched = state.download.0.lock().unwrap().as_ref().unwrap().fetched;
        assert!(state.download(&key, true).is_some());
        assert_eq!(
            state.download.0.lock().unwrap().as_ref().unwrap().fetched,
            fetched
        );
        state.download.0.lock().unwrap().as_mut().unwrap().fetched -= TTL;
        assert!(!state.user_handoff(&file, Some(ContentMode::Dynamic)));
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
            assert!(!state.user_handoff(&file, Some(ContentMode::Dynamic)));
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

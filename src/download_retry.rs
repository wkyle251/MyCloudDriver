//! Transfer-owned, disposable checksum contexts for unchanged durable staging.
//! A cache miss takes the existing verification path. Nothing is serialized:
//! a helper restart always verifies retained bytes again. An open descriptor
//! prevents inode reuse, and the complete journal plus file identity bind reuse.
use super::integrity::{Prefix, SavedIdentity};
use serde::Serialize;
use std::{
    fs::{File, Metadata},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Mutex,
    },
};

const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_ENTRY_BYTES: usize = 1024 * 1024;
const MAX_DESCRIPTORS: usize = 64;

struct Budget {
    bytes: AtomicUsize,
    descriptors: AtomicUsize,
    maximum_bytes: usize,
    maximum_descriptors: usize,
}

static BUDGET: Budget = Budget {
    bytes: AtomicUsize::new(0),
    descriptors: AtomicUsize::new(0),
    maximum_bytes: MAX_BYTES,
    maximum_descriptors: MAX_DESCRIPTORS,
};

struct Reservation<'a> {
    budget: &'a Budget,
    bytes: usize,
}
impl Budget {
    fn reserve(&self, bytes: usize) -> Option<Reservation<'_>> {
        self.descriptors
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                (used < self.maximum_descriptors).then(|| used + 1)
            })
            .ok()?;
        if self
            .bytes
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                used.checked_add(bytes)
                    .filter(|next| *next <= self.maximum_bytes)
            })
            .is_err()
        {
            self.descriptors.fetch_sub(1, Ordering::Relaxed);
            return None;
        }
        Some(Reservation {
            budget: self,
            bytes,
        })
    }
}
impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        self.budget.bytes.fetch_sub(self.bytes, Ordering::Relaxed);
        self.budget.descriptors.fetch_sub(1, Ordering::Relaxed);
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Prefix,
    Pieces,
}

struct Cached {
    kind: Kind,
    path: PathBuf,
    checkpoint: [u8; 32],
    identity: SavedIdentity,
    file: File,
    hashes: Vec<Prefix>,
    _reservation: Reservation<'static>,
}

pub(crate) struct RetryState {
    cached: Mutex<Option<Cached>>,
    final_verification_pending: AtomicBool,
    pub(crate) preparation: crate::download_preparation::State,
    #[cfg(test)]
    enabled: bool,
}
impl Default for RetryState {
    fn default() -> Self {
        Self {
            cached: Mutex::new(None),
            final_verification_pending: AtomicBool::new(false),
            preparation: Default::default(),
            #[cfg(test)]
            enabled: true,
        }
    }
}
impl std::fmt::Debug for RetryState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("RetryState").finish_non_exhaustive()
    }
}

fn checkpoint_key(value: &impl Serialize) -> Option<[u8; 32]> {
    let encoded = serde_json::to_vec(value).ok()?;
    ring::digest::digest(&ring::digest::SHA256, &encoded)
        .as_ref()
        .try_into()
        .ok()
}

impl RetryState {
    /// Scheduling hint only. This never certifies local bytes or skips a check.
    /// It survives a deferred final check along with this transfer's state.
    pub(crate) fn final_verification_pending(&self) -> bool {
        self.final_verification_pending.load(Ordering::Relaxed)
    }
    pub(crate) fn set_final_verification_pending(&self, pending: bool) {
        self.final_verification_pending.store(pending, Ordering::Relaxed);
    }

    pub(super) fn clear(&self) {
        self.cached.lock().unwrap().take();
    }

    fn get(&self, kind: Kind, path: &Path, checkpoint: &impl Serialize) -> Option<Vec<Prefix>> {
        #[cfg(test)]
        if !self.enabled {
            return None;
        }
        let key = checkpoint_key(checkpoint)?;
        let mut slot = self.cached.lock().unwrap();
        let Some(cached) = slot.as_ref() else {
            crate::download_telemetry::cache(false, 0);
            return None;
        };
        let unchanged = cached.kind == kind
            && cached.path == path
            && cached.checkpoint == key
            && cached.file.metadata().ok().is_some_and(|metadata| {
                SavedIdentity::of(&metadata) == Some(cached.identity)
                    && crate::download_fs::validate_open_file(path, &metadata).is_ok()
                    && crate::download_fs::metadata(path)
                        .ok()
                        .and_then(|m| SavedIdentity::of(&m))
                        == Some(cached.identity)
            });
        if !unchanged {
            slot.take();
            crate::download_telemetry::cache(false, 0);
            return None;
        }
        crate::download_telemetry::cache(true, cached.hashes.iter().map(|hash| hash.bytes).sum());
        Some(cached.hashes.clone())
    }

    pub(super) fn prefix(&self, path: &Path, checkpoint: &impl Serialize) -> Option<Prefix> {
        self.get(Kind::Prefix, path, checkpoint)?.into_iter().next()
    }

    pub(super) fn pieces(&self, path: &Path, checkpoint: &impl Serialize) -> Option<Vec<Prefix>> {
        self.get(Kind::Pieces, path, checkpoint)
    }

    async fn remember(
        &self,
        kind: Kind,
        path: &Path,
        checkpoint: &impl Serialize,
        file: &tokio::fs::File,
        metadata: &Metadata,
        hashes: &[Prefix],
    ) {
        #[cfg(test)]
        if !self.enabled {
            return;
        }
        // In-flight writers already need their contexts. Reserve a conservative
        // upper bound for the additional clones, including EOF rollback states,
        // frozen digests, path storage and allocator overhead.
        let bytes = hashes
            .len()
            .saturating_mul(
                std::mem::size_of::<Prefix>() + std::mem::size_of::<ring::digest::Context>() + 128,
            )
            .saturating_add(path.as_os_str().len())
            .saturating_add(1024);
        if hashes.iter().all(|hash| hash.bytes == 0) || bytes > MAX_ENTRY_BYTES {
            self.clear();
            return;
        }
        self.clear();
        let Some(reservation) = BUDGET.reserve(bytes) else {
            return;
        };
        let (Some(identity), Some(checkpoint)) =
            (SavedIdentity::of(metadata), checkpoint_key(checkpoint))
        else {
            return;
        };
        let Ok(held) = file.try_clone().await else {
            return;
        };
        let held = held.into_std().await;
        if held.metadata().ok().and_then(|m| SavedIdentity::of(&m)) != Some(identity)
            || crate::download_fs::validate_open_file(path, metadata).is_err()
        {
            return;
        }
        let mut hashes = hashes.to_vec();
        for hash in &mut hashes {
            hash.adopt_verified_metadata(metadata);
        }
        *self.cached.lock().unwrap() = Some(Cached {
            kind,
            path: path.into(),
            checkpoint,
            identity,
            file: held,
            hashes,
            _reservation: reservation,
        });
    }

    /// The caller just committed these incremental contexts after syncing data.
    pub(super) async fn remember_prefix(
        &self,
        path: &Path,
        checkpoint: &impl Serialize,
        file: &tokio::fs::File,
        metadata: &Metadata,
        hash: &Prefix,
    ) {
        self.remember(
            Kind::Prefix,
            path,
            checkpoint,
            file,
            metadata,
            std::slice::from_ref(hash),
        )
        .await;
    }

    pub(super) async fn remember_pieces(
        &self,
        path: &Path,
        checkpoint: &impl Serialize,
        file: &tokio::fs::File,
        metadata: &Metadata,
        hashes: &[Prefix],
    ) {
        self.remember(Kind::Pieces, path, checkpoint, file, metadata, hashes)
            .await;
    }

    /// Bind contexts produced by a read-back pass only if every proof still
    /// describes the file opened here. Allocation/FD failures are cache misses.
    pub(super) async fn remember_verified_prefix(
        &self,
        path: &Path,
        checkpoint: &impl Serialize,
        hash: &Prefix,
    ) {
        #[cfg(test)]
        if !self.enabled {
            return;
        }
        let Ok(file) = crate::download_fs::open_async(path, rustix::fs::OFlags::RDONLY).await
        else {
            return;
        };
        let Ok(metadata) = file.metadata().await else {
            return;
        };
        if hash.validate_restored(&metadata).is_ok() {
            self.remember_prefix(path, checkpoint, &file, &metadata, hash)
                .await;
        }
    }

    pub(super) async fn remember_verified_pieces(
        &self,
        path: &Path,
        checkpoint: &impl Serialize,
        hashes: &[Prefix],
    ) {
        #[cfg(test)]
        if !self.enabled {
            return;
        }
        let Ok(file) = crate::download_fs::open_async(path, rustix::fs::OFlags::RDONLY).await
        else {
            return;
        };
        let Ok(metadata) = file.metadata().await else {
            return;
        };
        if hashes
            .iter()
            .all(|hash| hash.validate_restored(&metadata).is_ok())
        {
            self.remember_pieces(path, checkpoint, &file, &metadata, hashes)
                .await;
        }
    }

    #[cfg(test)]
    pub(super) fn disabled() -> Self {
        Self {
            enabled: false,
            ..Self::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reservations_bound_memory_and_descriptors_and_release_both() {
        let budget = Budget {
            bytes: AtomicUsize::new(0),
            descriptors: AtomicUsize::new(0),
            maximum_bytes: 10,
            maximum_descriptors: 2,
        };
        let first = budget.reserve(6).unwrap();
        assert!(budget.reserve(5).is_none());
        assert_eq!(budget.descriptors.load(Ordering::Relaxed), 1);
        let second = budget.reserve(4).unwrap();
        assert!(budget.reserve(0).is_none());
        drop(first);
        assert_eq!(budget.bytes.load(Ordering::Relaxed), 4);
        drop(second);
        assert_eq!(budget.bytes.load(Ordering::Relaxed), 0);
        assert_eq!(budget.descriptors.load(Ordering::Relaxed), 0);
    }
}

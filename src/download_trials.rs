//! Serialize deliberate download-concurrency trials, including app helpers.
//! The short file lock protects a 24-byte expiring lease, never an HTTP body.
use std::{
    collections::VecDeque,
    io::{self, Read, Seek, Write},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const LEASE_TIME: Duration = Duration::from_secs(15);
const WAITER_TIME: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Record {
    generation: u64,
    owner: u64,
    until: u64,
}
struct Waiter {
    id: u64,
    seen: Instant,
    ready: bool,
}
#[derive(Default)]
struct Local {
    record: Record,
    waiting: VecDeque<Waiter>,
    millis: u64,
    releases: Vec<(u64, u64)>,
    invalidate: bool,
}

pub struct Coordinator {
    directory: Option<PathBuf>,
    local: Mutex<Local>,
    started: Instant,
    wall_millis: u64,
}

pub struct Participant {
    coordinator: Arc<Coordinator>,
    id: u64,
}
pub struct Lease {
    coordinator: Arc<Coordinator>,
    owner: u64,
    generation: u64,
}

impl Coordinator {
    pub fn new(directory: Option<PathBuf>) -> Arc<Self> {
        Arc::new(Self {
            directory,
            local: Mutex::new(Local::default()),
            started: Instant::now(),
            wall_millis: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64,
        })
    }

    pub fn register(self: &Arc<Self>) -> Participant {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Participant {
            coordinator: self.clone(),
            id: (u64::from(std::process::id()) << 32)
                | (NEXT.fetch_add(1, Ordering::Relaxed) & 0xffff_ffff),
        }
    }

    fn millis(&self, now: Instant) -> u64 {
        self.wall_millis
            .saturating_add(now.saturating_duration_since(self.started).as_millis() as u64)
    }

    fn access<T>(
        &self,
        local: &mut Local,
        now: Instant,
        change: impl FnOnce(&mut Record) -> T,
    ) -> io::Result<T> {
        let millis = self.millis(now).max(local.millis);
        local.millis = millis;
        let mut file = if let Some(directory) = &self.directory {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(directory)?;
            let metadata = std::fs::symlink_metadata(directory)?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(io::Error::other("Invalid download trial directory"));
            }
            Some(crate::download_network::Network::locked_file(
                &directory.join("concurrency-trial"),
                rustix::fs::FlockOperation::NonBlockingLockExclusive,
            )?)
        } else {
            None
        };
        let mut record = local.record;
        let mut repair = false;
        if let Some(file) = &mut file {
            match file.metadata()?.len() {
                0 => record = Record::default(),
                24 => {
                    let mut data = [0; 24];
                    file.read_exact(&mut data)?;
                    record = Record {
                        generation: u64::from_le_bytes(data[..8].try_into().unwrap()),
                        owner: u64::from_le_bytes(data[8..16].try_into().unwrap()),
                        until: u64::from_le_bytes(data[16..].try_into().unwrap()),
                    };
                }
                _ => {
                    // A helper can die during its first write. Internal partial
                    // lease state must not disable future trials permanently.
                    record = Record {
                        generation: millis,
                        ..Record::default()
                    };
                    repair = true;
                }
            }
        }
        let previous = record;
        if local.invalidate
            || local.releases.iter().any(|&(owner, generation)| {
                record.owner == owner && record.generation == generation
            })
        {
            record.owner = 0;
            record.until = 0;
            record.generation = record.generation.wrapping_add(1);
        }
        if record.owner != 0
            && (record.until <= millis
                || record.until > millis.saturating_add(2 * LEASE_TIME.as_millis() as u64))
        {
            record.owner = 0;
            record.until = 0;
            record.generation = record.generation.wrapping_add(1);
        }
        let result = change(&mut record);
        if previous != record || repair {
            if let Some(file) = &mut file {
                let mut data = [0; 24];
                data[..8].copy_from_slice(&record.generation.to_le_bytes());
                data[8..16].copy_from_slice(&record.owner.to_le_bytes());
                data[16..].copy_from_slice(&record.until.to_le_bytes());
                file.rewind()?;
                file.write_all(&data)?;
                if repair {
                    file.set_len(24)?;
                }
            }
        }
        local.record = record;
        local.releases.clear();
        local.invalidate = false;
        Ok(result)
    }
}

impl Participant {
    /// Observe the shared generation while maintaining our place among local
    /// contenders. Unavailable coordination only disables expansion.
    pub fn snapshot(&self, now: Instant) -> Option<u64> {
        let mut local = self.coordinator.local.lock().unwrap();
        local
            .waiting
            .retain(|w| now.saturating_duration_since(w.seen) <= WAITER_TIME);
        if let Some(waiter) = local.waiting.iter_mut().find(|w| w.id == self.id) {
            waiter.seen = now;
            waiter.ready = false;
        } else {
            local.waiting.push_back(Waiter {
                id: self.id,
                seen: now,
                ready: false,
            });
        }
        self.coordinator
            .access(&mut local, now, |r| (r.owner == 0).then_some(r.generation))
            .ok()
            .flatten()
    }

    pub fn acquire(&self, now: Instant, generation: u64) -> Option<Lease> {
        let mut local = self.coordinator.local.lock().unwrap();
        local
            .waiting
            .retain(|w| now.saturating_duration_since(w.seen) <= WAITER_TIME);
        let waiter = local.waiting.iter_mut().find(|w| w.id == self.id)?;
        waiter.ready = true;
        waiter.seen = now;
        if local.waiting.iter().find(|w| w.ready).map(|w| w.id) != Some(self.id) {
            return None;
        }
        let until = self
            .coordinator
            .millis(now)
            .saturating_add(LEASE_TIME.as_millis() as u64);
        let token = self
            .coordinator
            .access(&mut local, now, |r| {
                if r.owner != 0 || r.generation != generation {
                    return None;
                }
                r.generation = r.generation.wrapping_add(1);
                r.owner = self.id;
                r.until = until;
                Some(r.generation)
            })
            .ok()
            .flatten()?;
        local.waiting.retain(|w| w.id != self.id);
        Some(Lease {
            coordinator: self.coordinator.clone(),
            owner: self.id,
            generation: token,
        })
    }

    pub fn withdraw(&self) {
        self.coordinator
            .local
            .lock()
            .unwrap()
            .waiting
            .retain(|w| w.id != self.id);
    }

    /// A forced admission change invalidates any measurement spanning it.
    pub fn invalidate(&self, now: Instant) {
        let mut local = self.coordinator.local.lock().unwrap();
        local.invalidate = true;
        let _ = self.coordinator.access(&mut local, now, |_| ());
    }
}
impl Drop for Participant {
    fn drop(&mut self) {
        self.withdraw();
    }
}

impl Lease {
    pub fn valid(&self, now: Instant) -> Option<bool> {
        let mut local = self.coordinator.local.lock().unwrap();
        self.coordinator
            .access(&mut local, now, |r| {
                r.owner == self.owner && r.generation == self.generation
            })
            .ok()
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        let mut local = self.coordinator.local.lock().unwrap();
        local.releases.push((self.owner, self.generation));
        let _ = self.coordinator.access(&mut local, Instant::now(), |_| ());
    }
}

#[cfg(test)]
#[path = "download_trials_tests.rs"]
mod tests;

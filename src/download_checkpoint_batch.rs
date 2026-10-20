//! Per-device group commit. Callers keep their live writer and await the final
//! barrier; cancellation cannot abort a dispatched durable save.
use crate::{
    download_fs::{self, CheckpointWrite},
    download_verification::{Key, WriteGate},
};
use std::{
    collections::{HashMap, VecDeque},
    fs::Metadata,
    path::Path,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
    time::{Duration, Instant},
};
use tokio::sync::{oneshot, OwnedSemaphorePermit, Semaphore};

#[cfg(test)]
#[path = "download_checkpoint_guard_tests.rs"]
mod guard_tests;

const MAX_PENDING: usize = 256;
const MAX_BATCH: usize = 128;
const COALESCE: Duration = Duration::from_millis(25);
static PENDING: AtomicUsize = AtomicUsize::new(0);
static BATCHES: AtomicU64 = AtomicU64::new(0);
static FILES: AtomicU64 = AtomicU64::new(0);
static BARRIERS: AtomicU64 = AtomicU64::new(0);
static ELAPSED_MS: AtomicU64 = AtomicU64::new(0);

pub(crate) fn snapshot() -> (u64, u64, u64, u64, usize) {
    (
        BATCHES.load(Ordering::Relaxed),
        FILES.load(Ordering::Relaxed),
        BARRIERS.load(Ordering::Relaxed),
        ELAPSED_MS.load(Ordering::Relaxed),
        PENDING.load(Ordering::Relaxed),
    )
}
struct Request {
    write: Option<CheckpointWrite>,
    gate: WriteGate,
    result: Option<oneshot::Sender<Result<(), Arc<std::io::Error>>>>,
    waiting: Option<crate::download_telemetry::Operation>,
    _permit: OwnedSemaphorePermit,
}
impl Drop for Request {
    fn drop(&mut self) {
        PENDING.fetch_sub(1, Ordering::Relaxed);
    }
}
#[derive(Default)]
struct State {
    queue: VecDeque<Request>,
    running: bool,
}
struct Pool {
    state: Mutex<State>,
    slots: Arc<Semaphore>,
    #[cfg(test)]
    batch_sizes: Mutex<Vec<usize>>,
}
impl Pool {
    fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
            slots: Arc::new(Semaphore::new(MAX_PENDING)),
            #[cfg(test)]
            batch_sizes: Mutex::new(Vec::new()),
        }
    }
}
fn pool(key: Key, device: u64) -> Arc<Pool> {
    static POOLS: OnceLock<Mutex<HashMap<(Key, u64), Weak<Pool>>>> = OnceLock::new();
    let mut pools = POOLS.get_or_init(Default::default).lock().unwrap();
    if let Some(pool) = pools.get(&(key, device)).and_then(Weak::upgrade) {
        return pool;
    }
    pools.retain(|_, pool| pool.strong_count() != 0);
    let pool = Arc::new(Pool::new());
    pools.insert((key, device), Arc::downgrade(&pool));
    pool
}
#[derive(Debug)]
struct SharedFailure(Arc<std::io::Error>);
impl std::fmt::Display for SharedFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(&self.0, f)
    }
}
impl std::error::Error for SharedFailure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.0.as_ref())
    }
}

pub(crate) async fn commit(
    gate: &WriteGate,
    data: &tokio::fs::File,
    metadata: Metadata,
    data_path: &Path,
    journal_path: &Path,
    journal: Vec<u8>,
) -> anyhow::Result<()> {
    commit_inner(gate, data, metadata, data_path, journal_path, journal, None).await
}

pub(crate) async fn commit_guarded(
    gate: &WriteGate,
    data: &tokio::fs::File,
    metadata: Metadata,
    data_path: &Path,
    journal_path: &Path,
    journal: Vec<u8>,
    precondition: download_fs::CheckpointPrecondition,
) -> anyhow::Result<()> {
    commit_inner(gate, data, metadata, data_path, journal_path, journal, Some(precondition)).await
}

async fn commit_inner(
    gate: &WriteGate,
    data: &tokio::fs::File,
    metadata: Metadata,
    data_path: &Path,
    journal_path: &Path,
    journal: Vec<u8>,
    precondition: Option<download_fs::CheckpointPrecondition>,
) -> anyhow::Result<()> {
    let Some(key) = gate.key() else {
        let mut saving = crate::download_telemetry::Operation::new(
            crate::download_telemetry::Kind::CheckpointSync,
            gate.id(),
        );
        data.sync_data().await?;
        download_fs::validate_open_file(data_path, &metadata)?;
        let journal_path = journal_path.to_owned();
        tokio::task::spawn_blocking(move || {
            if let Some(check) = precondition { check()?; }
            download_fs::atomic_write(&journal_path, &journal)
        })
            .await??;
        saving.complete();
        return Ok(());
    };
    use std::os::unix::fs::MetadataExt;
    let pool = pool(key, metadata.dev());
    let waiting = crate::download_telemetry::Operation::new(
        crate::download_telemetry::Kind::CheckpointWait,
        gate.id(),
    );
    let permit = pool.slots.clone().acquire_owned().await?;
    let file = data.try_clone().await?.into_std().await;
    let (sender, receiver) = oneshot::channel();
    PENDING.fetch_add(1, Ordering::Relaxed);
    let start = {
        let mut state = pool.state.lock().unwrap();
        state.queue.push_back(Request {
            write: Some(CheckpointWrite {
                data: file,
                data_path: data_path.to_owned(),
                metadata,
                journal_path: journal_path.to_owned(),
                journal,
                precondition,
            }),
            gate: gate.clone(),
            result: Some(sender),
            waiting: Some(waiting),
            _permit: permit,
        });
        let start = !state.running;
        state.running = true;
        start
    };
    if start {
        tokio::spawn(run(pool.clone()));
    }
    receiver
        .await
        .map_err(|_| anyhow::anyhow!("Checkpoint coordinator stopped"))?
        .map_err(|error| anyhow::Error::new(SharedFailure(error)))
}

async fn run(pool: Arc<Pool>) {
    loop {
        tokio::time::sleep(COALESCE).await;
        let gate = {
            let mut state = pool.state.lock().unwrap();
            let Some(request) = state.queue.front() else {
                state.running = false;
                return;
            };
            request.gate.clone()
        };
        let turn = gate.checkpoint_turn().await;
        // Include requests which accumulated while the payload writer was
        // busy. The number of retained duplicate descriptors stays bounded.
        let requests: Vec<_> = {
            let mut state = pool.state.lock().unwrap();
            let count = MAX_BATCH.min(state.queue.len());
            state.queue.drain(..count).collect()
        };
        #[cfg(test)]
        let measured_pool = pool.clone();
        let result = tokio::task::spawn_blocking(move || {
            let _turn = turn;
            let mut requests = requests;
            for request in &mut requests {
                if let Some(mut waiting) = request.waiting.take() {
                    waiting.complete();
                }
            }
            let mut saving = crate::download_telemetry::Operation::new(
                crate::download_telemetry::Kind::CheckpointSync,
                gate.id(),
            );
            let start = Instant::now();
            let writes: Vec<_> = requests
                .iter_mut()
                .map(|request| request.write.take().expect("Queued checkpoint must retain its write"))
                .collect();
            let result = download_fs::checkpoint_batch(&writes).map_err(Arc::new);
            if result.is_ok() {
                saving.complete();
                BATCHES.fetch_add(1, Ordering::Relaxed);
                FILES.fetch_add(writes.len() as u64, Ordering::Relaxed);
                BARRIERS.fetch_add(2, Ordering::Relaxed);
                #[cfg(test)]
                measured_pool.batch_sizes.lock().unwrap().push(writes.len());
            }
            ELAPSED_MS.fetch_add(
                start.elapsed().as_millis().min(u64::MAX as u128) as u64,
                Ordering::Relaxed,
            );
            let rejected = result.as_ref().err()
                .and_then(|error| error.get_ref())
                .and_then(|error| error.downcast_ref::<download_fs::CheckpointPreconditionFailure>())
                .map(|error| error.index);
            let mut requeue = Vec::new();
            for (index, (mut request, write)) in requests.into_iter().zip(writes).enumerate() {
                if rejected.is_some_and(|rejected| rejected != index) {
                    // No journals were renamed. Keep the caller, descriptor,
                    // capacity permit and original write; retry only the
                    // durable commit rather than restarting its download.
                    request.write = Some(write);
                    request.waiting = Some(crate::download_telemetry::Operation::new(
                        crate::download_telemetry::Kind::CheckpointWait,
                        request.gate.id(),
                    ));
                    requeue.push(request);
                } else if let Some(sender) = request.result.take() {
                    let _ = sender.send(result.clone());
                }
            }
            requeue
        })
        .await;
        match result {
            Ok(requeue) => {
                let mut state = pool.state.lock().unwrap();
                for request in requeue.into_iter().rev() { state.queue.push_front(request); }
            }
            Err(_) => {
                // Dropped senders report an error to callers; no durable state
                // is acknowledged after a failed blocking worker.
                let mut state = pool.state.lock().unwrap();
                state.running = false;
                state.queue.clear();
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_files_commit_together_and_cancelled_callers_do_not_abort_the_save() {
        // Standalone test binaries bypass the real receiver's startup. Use
        // its process-local descriptor allowance before opening 64 writers.
        let _network = pikpak::download_network::Network::new(1, None);
        let root = tempfile::tempdir().unwrap();
        let id = format!("generated-commit-{}", std::process::id());
        let drive = crate::download_verification::TestDrive::new(&id);
        let file = tokio::fs::File::create(root.path().join("generated-holder"))
            .await
            .unwrap();
        let holder_gate = WriteGate::new(&file, &id);
        let held = holder_gate.turn(false).await;
        let device = {
            use std::os::unix::fs::MetadataExt;
            file.metadata().await.unwrap().dev()
        };
        let pool = pool(holder_gate.key().unwrap(), device);
        let mut jobs = Vec::new();
        for index in 0..64 {
            let path = root.path().join(format!("generated-{index}.data"));
            let journal = root.path().join(format!("generated-{index}.journal"));
            let sub_id = format!("{id}-{index}");
            let sibling = drive.sibling(&sub_id);
            jobs.push(tokio::spawn(async move {
                let _drive = sibling;
                let mut data = tokio::fs::File::create(&path).await.unwrap();
                data.write_all(b"generated-payload").await.unwrap();
                data.flush().await.unwrap();
                let gate = WriteGate::new(&data, &sub_id);
                let metadata = data.metadata().await.unwrap();
                commit(
                    &gate,
                    &data,
                    metadata,
                    &path,
                    &journal,
                    b"generated-journal".to_vec(),
                )
                .await
            }));
        }
        tokio::time::timeout(Duration::from_secs(3), async {
            while pool.state.lock().unwrap().queue.len() < 64 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        jobs[0].abort();
        let _ = (&mut jobs[0]).await;
        drop(held);
        for job in jobs.into_iter().skip(1) {
            tokio::time::timeout(Duration::from_secs(5), job)
                .await
                .unwrap()
                .unwrap()
                .unwrap();
        }
        assert_eq!(
            std::fs::read(root.path().join("generated-0.journal")).unwrap(),
            b"generated-journal",
            "A cancelled waiter must not cancel a dispatched data-before-journal commit"
        );
        assert!(pool.state.lock().unwrap().queue.is_empty());
        assert_eq!(*pool.batch_sizes.lock().unwrap(), vec![64], "Concurrent files must share one durable commit, not sixty-four separate cache flush sequences");
        eprintln!(
            "GENERATED_GROUP_COMMIT {{\"files\":64,\"batches\":1,\"full_cache_barriers\":2}}"
        );
    }
}

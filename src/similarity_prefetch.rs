//! Originals arrive independently of FileTwin's analysis slots. Only completed
//! sources enter this bounded ready queue; their RAM leases travel with them.
use super::*;
use std::sync::{
    atomic::AtomicU64,
    mpsc::{self, Receiver, SyncSender, TrySendError},
    Condvar, Mutex,
};

#[derive(Default)]
struct Wake {
    generation: Mutex<u64>,
    changed: Condvar,
}
impl Wake {
    fn generation(&self) -> u64 { *self.generation.lock().unwrap() }
    fn notify(&self) {
        let mut generation = self.generation.lock().unwrap();
        *generation = generation.wrapping_add(1);
        self.changed.notify_all();
    }
    fn wait(&self, observed: u64, timeout: Duration) {
        let generation = self.generation.lock().unwrap();
        let _ = self.changed.wait_timeout_while(generation, timeout, |generation| *generation == observed).unwrap();
    }
}

#[derive(Default)]
pub(super) struct State {
    pub resolving: AtomicU64,
    pub cloud_resolving: AtomicU64,
    pub ready: AtomicU64,
    pub resolved_bytes: AtomicU64,
    pub resolved_cloud_bytes: AtomicU64,
    pub inventory: Arc<discovery::State>,
}
struct ReadyCount(Arc<State>);
impl Drop for ReadyCount {
    fn drop(&mut self) {
        self.0.ready.fetch_sub(1, Ordering::AcqRel);
    }
}
pub(super) struct Prepared<T> {
    pub file: scope::InputFile,
    pub result: Result<T>,
    _count: ReadyCount,
}
pub(super) enum Event<T> {
    File(Prepared<T>),
    Finished(ScanReport),
}
pub(super) struct Prefetch<T> {
    receive: Receiver<Event<T>>,
    pub state: Arc<State>,
    pub discovery: Arc<discovery::State>,
    stop: Arc<AtomicBool>,
    wake: Arc<Wake>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl<T> Drop for Prefetch<T> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.wake.notify();
        if let Some(worker) = self.worker.take() {
            let deadline = Instant::now() + Duration::from_millis(200);
            while !worker.is_finished() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(2));
            }
            if worker.is_finished() { let _ = worker.join(); }
        }
        // The receiver then drops any unconsumed original buffers and leases.
    }
}
impl<T> Prefetch<T> {
    pub fn poll(&self) -> Result<Option<Event<T>>> {
        match self.receive.try_recv() {
            Ok(value) => { self.wake.notify(); Ok(Some(value)) },
            Err(mpsc::TryRecvError::Empty) => Ok(None),
            Err(mpsc::TryRecvError::Disconnected) => {
                bail!("Original acquisition stopped before completing its inventory.")
            }
        }
    }
}
fn send<T>(sender: &SyncSender<T>, mut value: T, stop: &AtomicBool, wake: &Wake) -> Result<()> {
    loop {
        check_cancel(stop)?;
        let observed = wake.generation();
        match sender.try_send(value) {
            Ok(()) => return Ok(()),
            Err(TrySendError::Disconnected(_)) => bail!("Original acquisition stopped"),
            Err(TrySendError::Full(v)) => {
                value = v;
                wake.wait(observed, Duration::from_millis(25));
            }
        }
    }
}

pub(super) fn start<T: Send + 'static>(
    discovery: discovery::Discovery,
    cancel: Arc<AtomicBool>,
    downloads: usize,
    ready_limit: usize,
    resolve: impl Fn(&mut scope::InputFile, &AtomicBool) -> Result<T> + Send + Sync + 'static,
) -> Prefetch<T> {
    let state = Arc::new(State {
        inventory: discovery.state.clone(),
        ..State::default()
    });
    let stop = Arc::new(AtomicBool::new(false));
    let wake = Arc::new(Wake::default());
    let (send_ready, receive) = mpsc::sync_channel(ready_limit.max(1));
    let discovery_state = discovery.state.clone();
    let shared = state.clone();
    let stopped = stop.clone();
    let activity = wake.clone();
    let worker = std::thread::spawn(move || {
        // Cancellation is relayed even while discovery/ready queues are full.
        std::thread::scope(|scope| {
            // Only metadata waits here; originals still require the existing
            // byte leases. A bounded queue lets fast resolvers receive bursts.
            let (send_work, receive_work) = mpsc::sync_channel::<scope::InputFile>(downloads.max(1));
            let receive_work = Arc::new(Mutex::new(receive_work));
            let mut workers = Vec::new();
            for _ in 0..downloads.max(1) {
                let receive_work = receive_work.clone();
                let resolve = &resolve;
                let send_ready = &send_ready;
                let shared = &shared;
                let stopped = &stopped;
                let activity = &activity;
                workers.push(scope.spawn(move || loop {
                    if stopped.load(Ordering::Acquire) {
                        return;
                    }
                    let work = receive_work
                        .lock()
                        .unwrap()
                        .recv_timeout(Duration::from_millis(25));
                    let mut file = match work {
                        Ok(file) => file,
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    };
                    activity.notify();
                    shared.resolving.fetch_add(1, Ordering::AcqRel);
                    let cloud = file.cloud.is_some();
                    if cloud { shared.cloud_resolving.fetch_add(1, Ordering::AcqRel); }
                    let listed_bytes = file.display.bytes;
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        resolve(&mut file, stopped)
                    }))
                    .unwrap_or_else(|_| {
                        Err(anyhow::anyhow!(
                            "Original acquisition worker stopped unexpectedly"
                        ))
                    });
                    // Cached results, skips and fully acquired originals have
                    // no remaining download work. Count each source once, even
                    // while its original waits in RAM or is being analysed.
                    if !stopped.load(Ordering::Acquire) {
                        if file.display.bytes >= listed_bytes {
                            shared
                                .inventory
                                .file_bytes
                                .fetch_add(file.display.bytes - listed_bytes, Ordering::AcqRel);
                        } else {
                            shared
                                .inventory
                                .file_bytes
                                .fetch_sub(listed_bytes - file.display.bytes, Ordering::AcqRel);
                        }
                        shared
                            .resolved_bytes
                            .fetch_add(file.display.bytes, Ordering::AcqRel);
                        if cloud {
                            if file.display.bytes >= listed_bytes {
                                shared.inventory.cloud_file_bytes.fetch_add(file.display.bytes - listed_bytes, Ordering::AcqRel);
                            } else {
                                shared.inventory.cloud_file_bytes.fetch_sub(listed_bytes - file.display.bytes, Ordering::AcqRel);
                            }
                            shared.resolved_cloud_bytes.fetch_add(file.display.bytes, Ordering::AcqRel);
                        }
                    }
                    shared.ready.fetch_add(1, Ordering::AcqRel);
                    shared.resolving.fetch_sub(1, Ordering::AcqRel);
                    if cloud { shared.cloud_resolving.fetch_sub(1, Ordering::AcqRel); }
                    let value = Event::File(Prepared {
                        file,
                        result,
                        _count: ReadyCount(shared.clone()),
                    });
                    if send(send_ready, value, stopped, activity).is_err() {
                        return;
                    }
                }));
            }
            let mut pending = None;
            let mut inventory = None;
            loop {
                let observed = activity.generation();
                let mut advanced = false;
                if cancel.load(Ordering::Acquire) {
                    stopped.store(true, Ordering::Release);
                }
                if stopped.load(Ordering::Acquire) {
                    break;
                }
                if pending.is_none() && inventory.is_none() {
                    match discovery.poll() {
                        Ok(Some(discovery::Event::File(file))) => { pending = Some(file); advanced = true; },
                        Ok(Some(discovery::Event::Finished(report))) => inventory = Some(report),
                        Ok(None) => {}
                        Err(_) => {
                            stopped.store(true, Ordering::Release);
                            break;
                        }
                    }
                }
                if let Some(file) = pending.take() {
                    match send_work.try_send(file) {
                        Ok(()) => { advanced = true; }
                        Err(TrySendError::Full(file)) => pending = Some(file),
                        Err(TrySendError::Disconnected(_)) => {
                            stopped.store(true, Ordering::Release);
                            break;
                        }
                    }
                }
                // Finished inventory closes the work channel, while this thread
                // continues relaying cancellation until every resolver exits.
                if inventory.is_some() {
                    break;
                }
                if !advanced {
                    // Capacity changes wake immediately. Discovery itself may
                    // be waiting on a provider, so retain a short bounded poll
                    // for new metadata and cancellation without pacing files.
                    activity.wait(observed, Duration::from_millis(5));
                }
            }
            drop(send_work);
            while workers.iter().any(|worker| !worker.is_finished()) {
                if cancel.load(Ordering::Acquire) {
                    stopped.store(true, Ordering::Release);
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            for worker in workers {
                let _ = worker.join();
            }
            if let Some(report) = inventory {
                // Every result was sent before Finished. The consumer may still
                // have work in flight; FileTwin waits for that work itself.
                let mut event = Event::Finished(report);
                loop {
                    if cancel.load(Ordering::Acquire) || stopped.load(Ordering::Acquire) {
                        break;
                    }
                    match send_ready.try_send(event) {
                        Ok(()) => break,
                        Err(TrySendError::Disconnected(_)) => break,
                        Err(TrySendError::Full(value)) => {
                            event = value;
                            let observed = activity.generation();
                            activity.wait(observed, Duration::from_millis(25));
                        }
                    }
                }
            }
        });
    });
    Prefetch {
        receive,
        state,
        discovery: discovery_state,
        stop,
        wake,
        worker: Some(worker),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use filetwin_core::memory_input::MemoryInput;

    fn inventory(root: &Path, n: usize, cancel: Arc<AtomicBool>) -> discovery::Discovery {
        let request = super::super::tests::request(root);
        std::fs::create_dir_all(&request.local_paths[0]).unwrap();
        for i in 0..n {
            std::fs::write(request.local_paths[0].join(format!("{i}.txt")), b"test").unwrap();
        }
        let report: ScanReport = serde_json::from_value(json!({
            "source":"local","scope":[],"status":"running","threshold":0.9,"scanned_files":0,
            "analysed_files":0,"skipped_files":0,"downloaded_bytes":0,"total_groups":0,"groups":[],"issues":[],
            "truncated":false,"coverage":"","elapsed_seconds":0.0,"files":[],"scores_retained":0
        })).unwrap();
        discovery::start(
            request,
            None,
            root.to_owned(),
            tokio::runtime::Handle::current(),
            cancel,
            report,
        )
    }
    fn until(mut condition: impl FnMut() -> bool) {
        let started = Instant::now();
        while !condition() {
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "Pipeline did not advance"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn pause_and_resource_edit_keep_ready_originals_until_analysis_resumes() {
        use filetwin_core::{
            api::{CancellationToken, EncodeRequest, EncoderConfig, LiveResources},
            Encoder,
        };
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let token = CancellationToken::default();
        let _deadline = Deadline::new(cancel.clone(), token.clone());
        let budget = memory::Budget::new(4096);
        let ram = budget.clone();
        let runtime = tokio::runtime::Handle::current();
        let resolved = Arc::new(AtomicU64::new(0));
        let hits = resolved.clone();
        let sources = start(
            inventory(&root, 4, cancel.clone()),
            cancel,
            4,
            4,
            move |_, stop| {
                let lease = runtime.block_on(ram.reserve(1024, stop))?;
                hits.fetch_add(1, Ordering::AcqRel);
                Ok(Arc::new(
                    MemoryInput::new(
                        b"The original text, retained in memory while paused.".to_vec(),
                    )
                    .retaining(lease),
                ))
            },
        );
        until(|| sources.state.ready.load(Ordering::Acquire) == 4);
        token.set_paused(true);
        let mut config = EncoderConfig::new(root.join("no-models"), &root);
        config.memory_staging = true;
        config.memory_scheduling = true;
        config.memory_bytes = 1 << 30;
        config.workers = 8;
        let ready = sources.state.clone();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(150));
                assert_eq!(ready.ready.load(Ordering::Acquire), 4);
                assert_eq!(budget.used(), 4096);
                token.update_resources(LiveResources {
                    workers: 4,
                    memory_bytes: 512 << 20,
                    staging_bytes: 64 << 20,
                    total_memory_bytes: None, acquisition_paused: false, external_memory_bytes: None,
                });
                std::thread::sleep(Duration::from_millis(100));
                assert_eq!(budget.used(), 4096);
                token.set_paused(false);
            });
            let result = Encoder::new(config)
                .unwrap()
                .encode_stream(
                    &EncodeRequest::new(&root),
                    &token,
                    || next_source(&sources),
                    |_| {},
                )
                .unwrap();
            assert_eq!(result.summary.counts.files_ready, 4);
            assert_eq!(
                resolved.load(Ordering::Acquire),
                4,
                "Resume fetched ready inputs again"
            );
        });
        drop(sources);
        assert_eq!(budget.used(), 0);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn downloads_fill_a_bounded_ram_queue_while_the_consumer_is_busy() {
        let root = tempfile::tempdir().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let budget = memory::Budget::new(40); // Four 10-byte originals; native copies use analysis memory.
        let ram = budget.clone();
        let runtime = tokio::runtime::Handle::current();
        let originals = Arc::new(Mutex::new(Vec::new()));
        let seen = originals.clone();
        let sources = start(
            inventory(root.path(), 12, cancel.clone()),
            cancel,
            2,
            2,
            move |_, stop| {
                let lease = runtime.block_on(ram.reserve(10, stop))?;
                let data = Arc::new(MemoryInput::new(vec![0; 10]).retaining(lease));
                seen.lock().unwrap().push(Arc::downgrade(&data));
                Ok(data)
            },
        );
        let mut first = None;
        until(|| {
            if let Some(Event::File(file)) = sources.poll().unwrap() {
                first = Some(file.result.unwrap());
            }
            first.is_some()
        });
        // A busy analysis worker retains its input; downloaders still fill RAM.
        until(|| budget.used() == 40 && sources.state.ready.load(Ordering::Acquire) >= 2);
        assert!(sources.state.ready.load(Ordering::Acquire) <= 4); // Queue plus at most two sending producers.
        assert!(first.as_ref().unwrap().as_ref().as_ref().len() == 10);
        drop(first);
        let mut completed = 1;
        let mut finished = false;
        until(|| {
            assert!(budget.used() <= 40);
            match sources.poll().unwrap() {
                Some(Event::File(file)) => {
                    assert!(file.result.is_ok());
                    completed += 1;
                }
                Some(Event::Finished(_)) => finished = true,
                None => {}
            }
            finished
        });
        assert_eq!(completed, 12);
        drop(sources);
        assert_eq!(budget.used(), 0);
        assert!(originals
            .lock()
            .unwrap()
            .iter()
            .all(|data| data.upgrade().is_none()));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ram_ready_queue_is_limited_by_bytes_instead_of_download_worker_count() {
        let root = tempfile::tempdir().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let budget = memory::Budget::new(100);
        let ram = budget.clone();
        let runtime = tokio::runtime::Handle::current();
        let sources = start(
            inventory(root.path(), 20, cancel.clone()),
            cancel.clone(),
            2,
            READY_QUEUE_CAPACITY,
            move |_, stop| {
                let lease = runtime.block_on(ram.reserve(10, stop))?;
                Ok(Arc::new(MemoryInput::new(vec![0; 10]).retaining(lease)))
            },
        );
        // Two downloaders can fill ten ready originals while analysis is busy.
        // No eleventh original can reserve bytes until an input is released.
        until(|| {
            sources.state.ready.load(Ordering::Acquire) == 10
                && budget.waiting.load(Ordering::Acquire) > 0
        });
        assert_eq!(budget.used(), 100);
        let buffer = match sources.poll().unwrap() {
            Some(Event::File(first)) => first.result.unwrap(),
            _ => panic!("Expected a ready original"),
        };
        assert_eq!(budget.used(), 100); // A worker retains its original's lease.
        drop(buffer);
        until(|| sources.state.ready.load(Ordering::Acquire) == 10);
        assert_eq!(budget.used(), 100);
        cancel.store(true, Ordering::Release);
        drop(sources);
        assert_eq!(budget.used(), 0);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cancellation_releases_full_ready_queue_and_interrupts_ram_waiters() {
        let root = tempfile::tempdir().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let budget = memory::Budget::new(10);
        let ram = budget.clone();
        let runtime = tokio::runtime::Handle::current();
        let sources = start(
            inventory(root.path(), 200, cancel.clone()),
            cancel.clone(),
            4,
            1,
            move |_, stop| {
                let lease = runtime.block_on(ram.reserve(10, stop))?;
                Ok(Arc::new(MemoryInput::new(vec![0; 10]).retaining(lease)))
            },
        );
        until(|| {
            sources.state.ready.load(Ordering::Acquire) == 1
                && budget.waiting.load(Ordering::Acquire) > 0
        });
        let started = Instant::now();
        cancel.store(true, Ordering::Release);
        drop(sources);
        assert!(started.elapsed() < Duration::from_secs(1));
        assert_eq!(budget.used(), 0);
        assert_eq!(budget.waiting.load(Ordering::Acquire), 0);
    }

    // Exercise the real FileTwin consumer, not just manually dropping buffers.
    // A watchdog lives outside both queues so a regression fails instead of
    // leaving the test run stuck waiting for its own stalled coordinator.
    struct Deadline {
        done: Option<mpsc::Sender<()>>,
        thread: Option<std::thread::JoinHandle<()>>,
        expired: Arc<AtomicBool>,
    }
    impl Deadline {
        fn new(stop: Arc<AtomicBool>, token: filetwin_core::api::CancellationToken) -> Self {
            let (done, receive) = mpsc::channel();
            let expired = Arc::new(AtomicBool::new(false));
            let timed_out = expired.clone();
            let thread = std::thread::spawn(move || {
                if matches!(
                    receive.recv_timeout(Duration::from_secs(15)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    timed_out.store(true, Ordering::Release);
                    stop.store(true, Ordering::Release);
                    token.cancel();
                }
            });
            Self {
                done: Some(done),
                thread: Some(thread),
                expired,
            }
        }
    }
    impl Drop for Deadline {
        fn drop(&mut self) {
            self.done.take();
            if let Some(thread) = self.thread.take() {
                thread.join().unwrap();
            }
        }
    }

    fn next_source(
        sources: &Prefetch<Arc<MemoryInput>>,
    ) -> filetwin_core::Result<filetwin_core::api::EncodeSourcePoll> {
        use filetwin_core::api::{EncodeSource, EncodeSourcePoll};
        Ok(
            match sources
                .poll()
                .map_err(|_| filetwin_core::Error::invalid("Fixture acquisition stopped"))?
            {
                None => EncodeSourcePoll::Pending,
                Some(Event::Finished(_)) => EncodeSourcePoll::Complete,
                Some(Event::File(prepared)) => {
                    let key = prepared.file.path.file_name().unwrap().to_owned();
                    EncodeSourcePoll::Ready(match prepared.result {
                        Ok(data) => EncodeSource::from_memory(key, data),
                        Err(_) => EncodeSource::deferred(key, |_| {
                            Err(filetwin_core::Error::new(
                                filetwin_core::ErrorCode::ResourceBudgetTooSmall,
                                "memory",
                                "Fixture original exceeds Download RAM",
                            ))
                        }),
                    })
                }
            },
        )
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn full_ram_queue_drains_through_analysis_reuse_and_failures() {
        use filetwin_core::{
            api::{CancellationToken, EncodeRequest, EncoderConfig},
            Encoder,
        };
        // One analysis worker, many workers, a one-item/full ready queue, and
        // an original which fits Download RAM but cannot fit a decoder copy.
        for (workers, ready_limit, analysis_bytes) in
            [(1, 1, 1 << 30), (52, 64, 32 << 30), (4, 1, 32)]
        {
            let root = tempfile::tempdir().unwrap();
            let root = root.path().canonicalize().unwrap();
            let cancel = Arc::new(AtomicBool::new(false));
            let token = CancellationToken::default();
            let deadline = Deadline::new(cancel.clone(), token.clone());
            let budget = memory::Budget::new(4096);
            let ram = budget.clone();
            let runtime = tokio::runtime::Handle::current();
            let originals = Arc::new(Mutex::new(Vec::new()));
            let seen = originals.clone();
            let sources = start(
                inventory(&root, 96, cancel.clone()),
                cancel,
                12,
                ready_limit,
                move |file, stop| {
                    let index: usize = file
                        .path
                        .file_stem()
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .parse()
                        .unwrap();
                    let kind = index % 8;
                    let capacity = match kind {
                        0 => 0,
                        1 => 4097,
                        _ => 512 * (kind % 4 + 1),
                    };
                    let mut lease = runtime.block_on(ram.reserve(capacity as u64, stop))?;
                    let mut bytes = vec![
                        b' ';
                        if capacity == 0 {
                            512
                        } else {
                            capacity as usize
                        }
                    ];
                    let text =
                        b"Rain, wind and weather observations from the mountain research station. ";
                    for (i, byte) in bytes.iter_mut().enumerate() {
                        *byte = text[i % text.len()];
                    }
                    if kind == 2 {
                        bytes[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
                    }
                    if kind == 3 {
                        bytes[..8].copy_from_slice(&[0, 255, 3, 4, 0, 255, 3, 4]);
                    }
                    // Unknown-size originals release unused space after fetching.
                    lease.shrink_to(bytes.capacity() as u64);
                    let data = Arc::new(MemoryInput::new(bytes).retaining(lease));
                    seen.lock().unwrap().push(Arc::downgrade(&data));
                    Ok(data)
                },
            );
            until(|| {
                sources.state.ready.load(Ordering::Acquire) > 0
                    && budget.waiting.load(Ordering::Acquire) > 0
            });
            let mut config = EncoderConfig::new(root.join("no-models"), &root);
            config.memory_staging = true;
            config.workers = workers;
            config.memory_bytes = analysis_bytes;
            let mut peak_waiting = 0;
            let result = Encoder::new(config)
                .unwrap()
                .encode_stream(
                    &EncodeRequest::new(&root),
                    &token,
                    || next_source(&sources),
                    |_| {
                        assert!(budget.used() <= budget.limit());
                        peak_waiting = peak_waiting.max(budget.waiting.load(Ordering::Acquire));
                    },
                )
                .unwrap();
            drop(sources);
            assert!(
                !deadline.expired.load(Ordering::Acquire),
                "RAM queue stopped advancing"
            );
            assert!(!result.summary.cancelled);
            assert_eq!(result.summary.counts.files_processed, 96);
            assert_eq!(result.summary.counts.files_ready, 60);
            assert_eq!(result.summary.counts.files_failed, 36); // Oversize download + unavailable/impossible decoder + unsupported originals.
            assert_eq!(result.summary.counts.files_skipped, 0); // FileTwin records Unsupported as failed; app UI derives exclusions from record states.
            assert!(result.summary.counts.cache_hits > 0);
            assert!(peak_waiting > 0);
            assert_eq!(budget.used(), 0);
            assert_eq!(budget.waiting.load(Ordering::Acquire), 0);
            assert!(originals
                .lock()
                .unwrap()
                .iter()
                .all(|data| data.upgrade().is_none()));
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn checkpoint_failure_releases_full_ram_queue_and_waiting_downloads() {
        use filetwin_core::{
            api::{CancellationToken, EncodeRequest, EncoderConfig},
            Encoder, Error, ErrorCode,
        };
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let token = CancellationToken::default();
        let deadline = Deadline::new(cancel.clone(), token.clone());
        let budget = memory::Budget::new(1024);
        let ram = budget.clone();
        let runtime = tokio::runtime::Handle::current();
        let sources = start(
            inventory(&root, 100, cancel.clone()),
            cancel,
            8,
            1,
            move |_, stop| {
                let lease = runtime.block_on(ram.reserve(1024, stop))?;
                let data =
                    b"This text describes weather observations from a mountain research station. "
                        .repeat(8);
                Ok(Arc::new(MemoryInput::new(data).retaining(lease)))
            },
        );
        until(|| budget.used() == 1024 && budget.waiting.load(Ordering::Acquire) > 0);
        let mut config = EncoderConfig::new(root.join("models"), &root);
        config.memory_staging = true;
        config.workers = 4;
        let result = Encoder::new(config).unwrap().encode_stream_observed(
            &EncodeRequest::new(&root),
            &token,
            || next_source(&sources),
            |_| {},
            |_| {
                Err(Error::new(
                    ErrorCode::IoError,
                    "checkpoint",
                    "Fixture storage interruption",
                ))
            },
        );
        assert_eq!(result.unwrap_err().code, ErrorCode::IoError);
        // No GUI cancellation signal: acquisition must stop when its consumer
        // returns early, even if ready buffers currently own all Download RAM.
        drop(sources);
        assert!(!deadline.expired.load(Ordering::Acquire));
        assert_eq!(budget.used(), 0);
        assert_eq!(budget.waiting.load(Ordering::Acquire), 0);
    }
}

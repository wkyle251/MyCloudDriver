//! Metadata-only discovery runs beside the encoder. Cloud inventories spool to
//! a private temporary file, so counting can finish ahead of slow downloads.
use super::*;
use std::io::{BufRead, BufReader, Read};
use std::os::unix::fs::FileExt;
use std::sync::{
    atomic::AtomicU64,
    mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
    Mutex,
};

#[derive(Serialize, Deserialize)]
pub(super) enum Event {
    File(scope::InputFile),
    Finished(ScanReport),
}
const MAX_EVENT_BYTES: usize = 16 << 20;

struct Spool {
    file: std::fs::File,
    read: u64,
    written: u64,
}
impl Spool {
    fn push(&mut self, bytes: &[u8]) -> Result<()> {
        let end = self
            .written
            .checked_add(8 + bytes.len() as u64)
            .context("Inventory size overflow")?;
        self.file
            .write_all_at(&(bytes.len() as u64).to_le_bytes(), self.written)?;
        self.file.write_all_at(bytes, self.written + 8)?;
        self.written = end;
        Ok(())
    }
    fn pop(&mut self) -> Result<Option<Event>> {
        if self.read == self.written {
            return Ok(None);
        }
        let mut header = [0; 8];
        self.file.read_exact_at(&mut header, self.read)?;
        let size = u64::from_le_bytes(header);
        if size > MAX_EVENT_BYTES as u64 || self.written - self.read < 8 + size {
            bail!("The temporary file inventory is incomplete or damaged.");
        }
        let mut bytes = vec![0; size as usize];
        self.file.read_exact_at(&mut bytes, self.read + 8)?;
        let event = serde_json::from_slice(&bytes)?;
        self.read += 8 + size;
        Ok(Some(event))
    }
}
enum InventorySender {
    Memory(SyncSender<Event>),
    Disk(Arc<Mutex<Spool>>),
}
enum InventoryReceiver {
    Memory(Receiver<Event>),
    Disk(Arc<Mutex<Spool>>),
    Snapshot(Mutex<(VecDeque<scope::InputFile>, Option<ScanReport>)>),
}
struct ProducerDone(Arc<AtomicBool>);
impl Drop for ProducerDone {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
#[derive(Default)]
pub(super) struct State {
    pub found: AtomicU64,
    pub file_bytes: AtomicU64,
    pub cloud_file_bytes: AtomicU64,
    pub has_cloud: bool,
    pub queued: AtomicU64,
    pub complete: AtomicBool,
    stop: AtomicBool,
    control: filetwin_core::api::CancellationToken,
}
pub(super) struct Discovery {
    receiver: InventoryReceiver,
    producer_done: Arc<AtomicBool>,
    pub state: Arc<State>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Drop for Discovery {
    fn drop(&mut self) {
        self.state.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let deadline = Instant::now() + Duration::from_millis(200);
            while !worker.is_finished() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(2));
            }
            if worker.is_finished() { let _ = worker.join(); }
        }
    }
}
impl Discovery {
    pub fn from_snapshot(
        snapshot: inventory::Snapshot,
        control: filetwin_core::api::CancellationToken,
    ) -> Self {
        let found = snapshot.files.len() as u64;
        let bytes = snapshot.files.iter().map(|file| file.display.bytes).sum();
        let cloud_bytes = snapshot.files.iter().filter(|file| file.cloud.is_some()).map(|file| file.display.bytes).sum();
        let has_cloud = snapshot.files.iter().any(|file| file.cloud.is_some());
        Self {
            receiver: InventoryReceiver::Snapshot(Mutex::new((
                snapshot.files.into(),
                Some(snapshot.report),
            ))),
            producer_done: Arc::new(AtomicBool::new(true)),
            worker: None,
            state: Arc::new(State {
                found: AtomicU64::new(found),
                file_bytes: AtomicU64::new(bytes),
                cloud_file_bytes: AtomicU64::new(cloud_bytes),
                has_cloud,
                queued: AtomicU64::new(found),
                complete: AtomicBool::new(true),
                control,
                ..State::default()
            }),
        }
    }
    pub fn poll(&self) -> Result<Option<Event>> {
        let value =
            match &self.receiver {
                InventoryReceiver::Snapshot(snapshot) => {
                    let mut snapshot = snapshot.lock().unwrap();
                    if let Some(file) = snapshot.0.pop_front() {
                        Some(Event::File(file))
                    } else {
                        snapshot.1.take().map(Event::Finished)
                    }
                }
                InventoryReceiver::Memory(receiver) => match receiver.try_recv() {
                    Ok(value) => Some(value),
                    Err(TryRecvError::Empty) => None,
                    Err(TryRecvError::Disconnected) => {
                        bail!("File discovery stopped before completing its inventory.")
                    }
                },
                InventoryReceiver::Disk(spool) => {
                    let value = spool.lock().unwrap().pop()?;
                    if value.is_none() && self.producer_done.load(Ordering::Acquire) {
                        // Recheck after the producer's release: its last event may
                        // have been committed between the first read and this flag.
                        Some(
                            spool.lock().unwrap().pop()?.context(
                                "File discovery stopped before completing its inventory.",
                            )?,
                        )
                    } else {
                        value
                    }
                }
            };
        match value {
            Some(Event::File(file)) => {
                self.state.queued.fetch_sub(1, Ordering::AcqRel);
                Ok(Some(Event::File(file)))
            }
            event => Ok(event),
        }
    }
}

fn send(
    sender: &InventorySender,
    mut value: Event,
    state: &State,
    cancel: &AtomicBool,
) -> Result<()> {
    loop {
        control::wait_blocking(&state.control, &state.stop)?;
        check_cancel(cancel)?;
        if state.stop.load(Ordering::Acquire) {
            bail!("Discovery stopped");
        }
        let sender = match sender {
            InventorySender::Disk(spool) => {
                let bytes = serde_json::to_vec(&value)?;
                if bytes.len() > MAX_EVENT_BYTES {
                    bail!("A file inventory entry is too large.");
                }
                return spool.lock().unwrap().push(&bytes).context(
                    "Could not queue file metadata. Check available disk space, then resume.",
                );
            }
            InventorySender::Memory(sender) => sender,
        };
        match sender.try_send(value) {
            Ok(()) => return Ok(()),
            Err(TrySendError::Disconnected(_)) => bail!("Discovery stopped"),
            Err(TrySendError::Full(event)) => {
                value = event;
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

#[cfg(test)]
pub(super) fn start(
    request: ScanRequest,
    client: Option<Client>,
    temporary: PathBuf,
    runtime: tokio::runtime::Handle,
    cancel: Arc<AtomicBool>,
    report: ScanReport,
) -> Discovery {
    start_controlled(
        request,
        client,
        temporary,
        runtime,
        cancel,
        report,
        Default::default(),
    )
    .unwrap()
}

pub(super) fn start_controlled(
    request: ScanRequest,
    client: Option<Client>,
    temporary: PathBuf,
    runtime: tokio::runtime::Handle,
    cancel: Arc<AtomicBool>,
    mut report: ScanReport,
    control: filetwin_core::api::CancellationToken,
) -> Result<Discovery> {
    let (sender, receiver) =
        if !request.cloud_items.is_empty() || request.external_source_stream.is_some() {
            // Anonymous/0600/CLOEXEC file; only metadata enters it. Closing the last
            // handle removes it. Original contents retain their normal RAM leases.
            let spool = Arc::new(Mutex::new(Spool {
                file: tempfile::tempfile_in(&temporary).context(
                    "Could not create the temporary file inventory. Check available disk space.",
                )?,
                read: 0,
                written: 0,
            }));
            (
                InventorySender::Disk(spool.clone()),
                InventoryReceiver::Disk(spool),
            )
        } else {
            let (sender, receiver) = mpsc::sync_channel(128);
            (
                InventorySender::Memory(sender),
                InventoryReceiver::Memory(receiver),
            )
        };
    let producer_done = Arc::new(AtomicBool::new(false));
    let done = producer_done.clone();
    let state = Arc::new(State {
        control,
        has_cloud: !request.cloud_items.is_empty(),
        ..State::default()
    });
    let shared = state.clone();
    let worker = std::thread::spawn(move || {
        let _done = ProducerDone(done);
        let seen = Mutex::new(HashSet::new());
        let last_progress = Mutex::new(Instant::now());
        let _ = emit(&json!({"event":"discovery", "found":0, "complete":false}));
        let publish = |mut file: scope::InputFile| -> Result<()> {
            control::wait_blocking(&shared.control, &shared.stop)?;
            check_cancel(&cancel)?;
            if file.display.name.starts_with('.') || !seen.lock().unwrap().insert(file.display.id.clone()) {
                return Ok(());
            }
            file.capture_inventory_version();
            shared.found.fetch_add(1, Ordering::AcqRel);
            shared
                .file_bytes
                .fetch_add(file.display.bytes, Ordering::AcqRel);
            if file.cloud.is_some() {
                shared.cloud_file_bytes.fetch_add(file.display.bytes, Ordering::AcqRel);
            }
            shared.queued.fetch_add(1, Ordering::AcqRel);
            let mut last_progress = last_progress.lock().unwrap();
            if shared.found.load(Ordering::Acquire) == 1 || last_progress.elapsed() >= Duration::from_millis(250) {
                emit(
                    &json!({"event":"discovery", "found":shared.found.load(Ordering::Acquire),
                    "file_bytes":shared.file_bytes.load(Ordering::Acquire),
                    "queued":shared.queued.load(Ordering::Acquire), "complete":false}),
                )?;
                *last_progress = Instant::now();
            }
            drop(last_progress);
            send(&sender, Event::File(file), &shared, &cancel)
        };
        let mut staged = StagedCloud::new();
        let result = if !request.cloud_items.is_empty() && client.is_none() {
            Err(anyhow::anyhow!("Sign in to PikPak before scanning."))
        } else if !request.cloud_items.is_empty() {
            // Native metadata and PikPak pages feed one queue concurrently.
            // Neither provider can hide the other's inventory behind a slow
            // traversal; both must complete before this inventory is certified.
            std::thread::scope(|threads| {
                let native = request.external_source_stream.as_ref().map(|path| {
                    threads.spawn(|| read_external(path, &cancel, &shared, &mut |file| publish(file)))
                });
                let cloud = match client.as_ref() {
                    Some(client) => runtime.block_on(discover_cloud(
                        &request, client, &temporary, &shared.stop, &shared.control,
                        &mut staged, &mut |item| publish(scope::InputFile::cloud(item)),
                    )),
                    None => Err(anyhow::anyhow!("Sign in to PikPak before scanning.")),
                };
                let native = native.map(|thread| thread.join().unwrap_or_else(|_| {
                    Err(anyhow::anyhow!("Native drive discovery stopped unexpectedly."))
                })).transpose();
                cloud.and(native.map(|_| ()))
            })
        } else if let Some(path) = &request.external_source_stream {
            read_external(path, &cancel, &shared, &mut |file| publish(file))
        } else {
            scope::discover(&request, &staged, &shared.stop, &mut report, &mut |file| publish(file))
        };
        let missing_issues = staged.skipped.saturating_sub(staged.issues.len() as u64);
        let remaining = MAX_ISSUES.saturating_sub(report.issues.len());
        report
            .issues
            .extend(staged.issues.into_iter().take(remaining));
        report.skipped_files += staged.skipped;
        report.failed_files += staged.skipped;
        report.issue_summary.extend(staged.issue_summary);
        report.truncated |= missing_issues > 0;
        if let Err(error) = result {
            if !cancel.load(Ordering::Acquire) && !shared.stop.load(Ordering::Acquire) {
                if request.checkpoint_id.is_some() {
                    let _ = emit(
                        &json!({"event":"interrupted","reason":"The scan could not finish finding files. Check drive access, then resume."}),
                    );
                    cancel.store(true, Ordering::Release);
                    return;
                }
                scope::issue(&mut report, "Scan scope", &error.to_string());
            }
        }
        report.scanned_files = shared.found.load(Ordering::Acquire);
        shared.complete.store(true, Ordering::Release);
        let _ = emit(&json!({"event":"discovery", "found":report.scanned_files,
            "file_bytes":shared.file_bytes.load(Ordering::Acquire),
            "queued":shared.queued.load(Ordering::Acquire), "complete":true}));
        let _ = send(&sender, Event::Finished(report), &shared, &cancel);
    });
    Ok(Discovery {
        receiver,
        producer_done,
        state,
        worker: Some(worker),
    })
}

#[derive(Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
enum ExternalEvent {
    File { file: ExternalSource },
    Complete,
    Error { message: String },
}

fn read_external(
    path: &Path,
    cancel: &AtomicBool,
    state: &State,
    next: &mut dyn FnMut(scope::InputFile) -> Result<()>,
) -> Result<()> {
    let parent = path
        .parent()
        .context("Missing inventory directory")?
        .canonicalize()?;
    let path = parent.join(path.file_name().context("Missing inventory filename")?);
    let file = scope::open_secure(&path)?;
    if !file.metadata()?.is_file() {
        bail!("Invalid provider inventory");
    }
    let mut reader = BufReader::new(file);
    let mut pending = Vec::new();
    let mut last_input = Instant::now();
    loop {
        last_input += control::wait_blocking(&state.control, &state.stop)?;
        check_cancel(cancel)?;
        if state.stop.load(Ordering::Acquire) {
            bail!("Discovery stopped");
        }
        let remaining = 65_537usize.saturating_sub(pending.len());
        let read = Read::by_ref(&mut reader)
            .take(remaining as u64)
            .read_until(b'\n', &mut pending)?;
        if pending.len() > 65_536 {
            bail!("A provider inventory entry is too large.");
        }
        if read > 0 {
            last_input = Instant::now();
        }
        if pending.last() == Some(&b'\n') {
            let event: ExternalEvent = serde_json::from_slice(&pending)?;
            pending.clear();
            match event {
                ExternalEvent::Complete => return Ok(()),
                ExternalEvent::Error { message } => {
                    bail!("{}", message.chars().take(1000).collect::<String>())
                }
                ExternalEvent::File { file } => {
                    if file.id.is_empty()
                        || file.id.len() > 8192
                        || file.local_path.as_ref().is_some_and(|p| !p.is_absolute())
                    {
                        bail!("Invalid provider inventory entry");
                    }
                    next(scope::InputFile::external(file))?;
                }
            }
        } else {
            if last_input.elapsed() > Duration::from_secs(30 * 60) {
                bail!("The drive stopped responding while finding files.");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cloud_inventory_passes_200000_files_without_waiting_for_download_consumers() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        const TOTAL: u64 = 200_137;
        const ROOT_FILES: u64 = TOTAL - 3;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                tokio::spawn(async move {
                    let mut bytes = Vec::new();
                    let mut buffer = [0; 4096];
                    let route = loop {
                        let n = socket.read(&mut buffer).await.unwrap();
                        if n == 0 {
                            return;
                        }
                        bytes.extend_from_slice(&buffer[..n]);
                        let text = String::from_utf8_lossy(&bytes);
                        if let Some(end) = text.find("\r\n\r\n") {
                            let length = text[..end]
                                .lines()
                                .find_map(|line| {
                                    line.to_lowercase()
                                        .strip_prefix("content-length:")
                                        .and_then(|v| v.trim().parse::<usize>().ok())
                                })
                                .unwrap_or(0);
                            if bytes.len() >= end + 4 + length {
                                break text.lines().next().unwrap().to_owned();
                            }
                        }
                    };
                    let value = if route.contains("/auth/token") {
                        json!({"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"sub":"fixture-user"})
                    } else if route.contains("/shield/captcha/init") {
                        json!({"captcha_token":"fixture-captcha","expires_in":3600})
                    } else if route.contains("/drive/v1/files/root?") {
                        json!({"id":"root","name":"Fixture","kind":"drive#folder","trashed":false})
                    } else {
                        assert!(
                            route.contains("/drive/v1/files?"),
                            "Metadata-only fixture must never download an original"
                        );
                        let url = url::Url::parse(&format!(
                            "http://fixture{}",
                            route.split_whitespace().nth(1).unwrap()
                        ))
                        .unwrap();
                        let nested = url
                            .query_pairs()
                            .any(|(key, value)| key == "parent_id" && value == "nested");
                        let offset = url
                            .query_pairs()
                            .find(|(key, _)| key == "page_token")
                            .map(|(_, value)| value.parse::<u64>().unwrap())
                            .unwrap_or(0);
                        let start = if nested { ROOT_FILES } else { offset };
                        let end = if nested {
                            TOTAL
                        } else {
                            (offset + 500).min(ROOT_FILES)
                        };
                        let mut files: Vec<_> = (start..end)
                            .map(|i| {
                                json!({"id":format!("file-{i}"),"name":format!("{i}.bin"),
                            "kind":"drive#file","size":"1024","hash":"fixture-revision"})
                            })
                            .collect();
                        if !nested && offset == 0 {
                            files.extend([
                                json!({"id":"nested","name":"Nested","kind":"drive#folder","size":"0"}),
                                json!({"id":"root","name":"Cycle","kind":"drive#folder","size":"0"}),
                                json!({"id":"hidden","name":".hidden","kind":"drive#file","size":"999999"}),
                                json!({"id":"file-0","name":"duplicate.bin","kind":"drive#file","size":"1024"})]);
                        }
                        json!({"files":files,"next_page_token":if !nested && end<ROOT_FILES { Some(end.to_string()) } else { None }})
                    };
                    let body = value.to_string();
                    socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).as_bytes()).await.unwrap();
                });
            }
        });
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.source = ScanSource::Cloud;
        request.local_paths.clear();
        request.cloud_items = vec![CloudItem {
            id: "root".into(),
            name: "Fixture".into(),
            path: "/".into(),
            is_folder: true,
            size: 0,
            ancestors: vec![],
            revision: None,
        }];
        let client = Client::builder()
            .refresh_token("fixture-refresh")
            .device_id("fixture-device")
            .api_base_url(format!("http://{address}"))
            .auth_base_url(format!("http://{address}"))
            .build()
            .unwrap();
        let report=serde_json::from_value(json!({"source":"cloud","scope":[],"status":"running","threshold":0.9,
            "scanned_files":0,"analysed_files":0,"skipped_files":0,"downloaded_bytes":0,"total_groups":0,"groups":[],
            "issues":[],"files":[],"scores_retained":0,"truncated":false,"coverage":"","elapsed_seconds":0.0})).unwrap();
        let discovery = start(
            request,
            Some(client),
            root.path().into(),
            tokio::runtime::Handle::current(),
            Arc::new(AtomicBool::new(false)),
            report,
        );
        let deadline = Instant::now() + Duration::from_secs(60);
        while !discovery.state.complete.load(Ordering::Acquire) && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(
            discovery.state.complete.load(Ordering::Acquire),
            "A full metadata count must not wait for the 128-file download lookahead"
        );
        assert_eq!(discovery.state.found.load(Ordering::Acquire), TOTAL);
        assert_eq!(
            discovery.state.file_bytes.load(Ordering::Acquire),
            TOTAL * 1024
        );
        assert_eq!(discovery.state.queued.load(Ordering::Acquire), TOTAL);
        let InventoryReceiver::Disk(spool) = &discovery.receiver else {
            panic!("Cloud metadata must use the disk queue");
        };
        assert!(spool.lock().unwrap().written > 32 << 20);
        let mut count = 0;
        let mut last = false;
        loop {
            match discovery.poll().unwrap() {
                Some(Event::File(file)) => {
                    count += 1;
                    last |= file.cloud.unwrap().id == format!("file-{}", TOTAL - 1);
                }
                Some(Event::Finished(report)) => {
                    assert_eq!(report.scanned_files, TOTAL);
                    assert_eq!(report.skipped_files, 0);
                    assert!(report.issues.is_empty() && !report.truncated);
                    break;
                }
                None => {
                    assert!(Instant::now() < deadline + Duration::from_secs(60));
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        }
        assert_eq!(count, TOTAL);
        assert!(
            last,
            "Nested files after the former cap must reach analysis too"
        );
        assert_eq!(discovery.state.queued.load(Ordering::Acquire), 0);
        drop(discovery);
        server.abort();
    }

    #[test]
    fn disk_inventory_rejects_corrupt_frames_and_honours_pause_and_cancel() {
        let root = tempfile::tempdir().unwrap();
        let spool = Arc::new(Mutex::new(Spool {
            file: tempfile::tempfile_in(root.path()).unwrap(),
            read: 0,
            written: 0,
        }));
        let state = State::default();
        let cancel = AtomicBool::new(false);
        state.control.set_paused(true);
        std::thread::scope(|scope| {
            let producer = scope.spawn(|| {
                send(
                    &InventorySender::Disk(spool.clone()),
                    Event::File(scope::InputFile::external(ExternalSource {
                        provider: None,
                        content_kind: None,
                        id: "fixture".into(),
                        name: "fixture.txt".into(),
                        path: "/fixture.txt".into(),
                        size: 1,
                        local_path: None,
                        revision: None,
                    })),
                    &state,
                    &cancel,
                )
            });
            std::thread::sleep(Duration::from_millis(50));
            assert_eq!(
                spool.lock().unwrap().written,
                0,
                "Pausing must stop inventory admission"
            );
            cancel.store(true, Ordering::Release);
            state.control.set_paused(false);
            assert!(producer.join().unwrap().is_err());
        });
        let mut spool = spool.lock().unwrap();
        spool
            .file
            .write_all_at(&((MAX_EVENT_BYTES as u64) + 1).to_le_bytes(), 0)
            .unwrap();
        spool.written = 8;
        assert!(
            spool.pop().is_err(),
            "A damaged frame must not allocate an unbounded record"
        );
    }

    #[test]
    fn provider_stream_preserves_partial_lines_and_emits_before_completion() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("inventory.jsonl");
        let mut writer = File::create(&path).unwrap();
        let line = serde_json::to_vec(&json!({"event":"file", "file":{
            "id":"asset:one", "name":"one.txt", "path":"/Album/one.txt", "size":10, "local_path":null
        }})).unwrap();
        writer.write_all(&line[..12]).unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let cancel_reader = cancel.clone();
        let (sender, receiver) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            read_external(&path, &cancel_reader, &State::default(), &mut |file| {
                sender.send(file.display.id).unwrap();
                Ok(())
            })
        });
        assert!(receiver.recv_timeout(Duration::from_millis(50)).is_err());
        writer.write_all(&line[12..]).unwrap();
        writer.write_all(b"\n").unwrap();
        let received = receiver.recv_timeout(Duration::from_secs(2));
        writer.write_all(b"{\"event\":\"complete\"}\n").unwrap();
        if received.is_err() {
            cancel.store(true, Ordering::Release);
        }
        reader.join().unwrap().unwrap();
        assert_eq!(received.unwrap(), "asset:one");
    }

    #[test]
    fn invalid_or_failed_provider_stream_never_silently_looks_complete() {
        for bytes in [
            b"{\"event\":\"error\",\"message\":\"Library access was removed\"}\n".to_vec(),
            b"{not-json}\n".to_vec(),
            vec![b'x'; 65_537],
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("inventory.jsonl");
            std::fs::write(&path, bytes).unwrap();
            assert!(read_external(
                &path,
                &AtomicBool::new(false),
                &State::default(),
                &mut |_| Ok(())
            )
            .is_err());
        }
    }

    #[test]
    fn cancelling_an_idle_inventory_or_full_queue_does_not_wait_for_discovery() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("inventory.jsonl");
        std::fs::write(&path, []).unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        let worker = std::thread::spawn(move || {
            read_external(&path, &worker_cancel, &State::default(), &mut |_| Ok(()))
        });
        std::thread::sleep(Duration::from_millis(30));
        cancel.store(true, Ordering::Release);
        assert!(worker.join().unwrap().is_err());
        let (sender, _receiver) = mpsc::sync_channel(0);
        let file = scope::InputFile::external(ExternalSource {
            provider: None,
            content_kind: None,
            revision: None,
            id: "id".into(),
            name: "file".into(),
            path: "/file".into(),
            size: 0,
            local_path: None,
        });
        assert!(send(
            &InventorySender::Memory(sender),
            Event::File(file),
            &State::default(),
            &cancel
        )
        .is_err());
    }
}

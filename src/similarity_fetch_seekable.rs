//! On-demand, revision-bound media ranges. Original bytes stay in a leased RAM
//! cache; the decoder sees only FileTwin's private loopback transport.
use super::*;
use filetwin_core::memory_input::SeekableInput;
use reqwest::header;
use std::{io, sync::atomic::AtomicBool};

const BLOCK: u64 = crate::download_network::RECEIVE_WINDOW;

struct CachedBlock {
    start: u64,
    bytes: Vec<u8>,
    _lease: memory::StreamLease,
}
struct State {
    route: Client,
    info: crate::client::DownloadInfo,
    etag: Option<header::HeaderValue>,
    blocks: VecDeque<CachedBlock>,
    transferred: u64,
    admitted: bool,
}
struct Original {
    item: CloudItem,
    id: String,
    gcid: String,
    length: u64,
    fetches: Arc<Fetches>,
    runtime: tokio::runtime::Handle,
    downloaded: Arc<AtomicU64>,
    ticket: Ticket,
    valid: AtomicBool,
    failure: Mutex<Option<filetwin_core::Error>>,
    _entitlement: OwnedPermit,
    state: Mutex<State>,
}
impl Drop for Original {
    fn drop(&mut self) {
        self.fetches.seekable_readers.fetch_sub(1, Ordering::AcqRel);
    }
}

fn gcid(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    (value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| value.to_ascii_lowercase())
}
fn candidate(name: &str) -> bool {
    matches!(
        Path::new(name)
            .extension()
            .and_then(|s| s.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some(
            "mts"
                | "m2ts"
                | "mpeg"
                | "mpg"
                | "mkv"
                | "webm"
                | "mov"
                | "mp4"
                | "avi"
                | "wmv"
                | "asf"
                | "flv"
                | "m4v"
                | "3gp"
                | "3g2"
                | "mxf"
                | "vob"
                | "ogv"
                | "rm"
                | "rmvb"
                | "m2v"
                | "m4a"
                | "mka"
                | "mp3"
                | "aac"
                | "wav"
                | "flac"
                | "aiff"
                | "opus"
                | "ogg"
                | "oga"
                | "mp2"
                | "wma"
                | "ape"
                | "wv"
                | "caf"
                | "au"
                | "amr"
                | "ac3"
                | "eac3"
                | "dts"
                | "aif"
                | "m4b"
                | "ra"
        )
    )
}
fn checked_url(info: &crate::client::DownloadInfo) -> std::result::Result<reqwest::Url, Failure> {
    reqwest::Url::parse(&info.web_content_link)
        .ok()
        .filter(|u| {
            matches!(u.scheme(), "http" | "https")
                && u.username().is_empty()
                && u.password().is_none()
        })
        .ok_or_else(|| Failure::new("invalid_link", "metadata", false))
}
fn check(fetches: &Fetches, stop: &AtomicBool) -> std::result::Result<(), Failure> {
    if stop.load(Ordering::Acquire) || fetches.control.is_cancelled() {
        Err(Failure::new("cancelled", "download", false))
    } else {
        Ok(())
    }
}
/// Pausing aborts an HTTP attempt before the caller waits. No shared connection
/// is held asleep and no partially received block is ever made visible.
async fn network_wait<T>(
    fetches: &Fetches,
    stop: &AtomicBool,
    future: impl Future<Output = std::result::Result<T, Failure>>,
) -> std::result::Result<T, Failure> {
    tokio::pin!(future);
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        check(fetches, stop)?;
        if fetches.control.is_paused() {
            return Err(Failure::new("seek_pause", "download", true));
        }
        tokio::select! {
            value = &mut future => return value,
            _ = tokio::time::sleep(Duration::from_millis(20)) => {
                if Instant::now() >= deadline { return Err(Failure::new("timeout", "download", true)); }
            }
        }
    }
}
async fn unpaused(fetches: &Fetches, stop: &AtomicBool) -> std::result::Result<(), Failure> {
    loop {
        check(fetches, stop)?;
        if !fetches.control.is_paused() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
async fn metadata(
    client: &Client,
    item: &CloudItem,
    fetches: &Fetches,
    stop: &AtomicBool,
    entitled: bool,
    analysing: bool,
) -> std::result::Result<(crate::client::DownloadInfo, Option<String>), Failure> {
    let mut attempt = 0u32;
    loop {
        unpaused(fetches, stop).await?;
        let result = async {
            let _connection = if entitled {
                None
            } else {
                Some(
                    network_wait(fetches, stop, async {
                        fetches
                            .acquire(stop)
                            .await
                            .map_err(|e| Failure::from_error(e, "metadata"))
                    })
                    .await?,
                )
            };
            let _metadata = Counter::new(if analysing {
                &fetches.range_metadata
            } else {
                &fetches.metadata
            });
            network_wait(fetches, stop, async {
                client
                    .similarity_download_info(
                        &item.id,
                        item.ancestors.last().map(|p| p.id.as_str()).unwrap_or(""),
                    )
                    .await
                    .map_err(|e| Failure::from_error(e.into(), "metadata"))
            })
            .await
        }
        .await;
        match result {
            Err(error) if error.kind == "seek_pause" => continue,
            Ok(value) => return Ok(value),
            Err(mut error) => {
                attempt = attempt.saturating_add(1);
                error.attempts = attempt;
                if !error.retryable
                    || (!fetches.retry_forever
                        && (attempt >= MAX_ATTEMPTS
                            || error
                                .retry_after
                                .is_some_and(|delay| delay > Duration::from_secs(300))))
                {
                    return Err(error);
                }
                let delay = Duration::from_millis(
                    (500 * (1u64 << attempt.saturating_sub(1).min(6))).min(30_000),
                )
                .max(error.retry_after.unwrap_or_default());
                if error
                    .status
                    .is_some_and(|status| status == 429 || status >= 500)
                {
                    fetches.defer_requests(delay);
                }
                let _retrying = Counter::new(if analysing {
                    &fetches.range_retrying
                } else {
                    &fetches.retrying
                });
                let mut remaining = delay;
                while remaining > Duration::ZERO {
                    unpaused(fetches, stop).await?;
                    let part = remaining.min(Duration::from_millis(20));
                    tokio::time::sleep(part).await;
                    remaining = remaining.saturating_sub(part);
                }
            }
        }
    }
}

/// A non-media extension or an unverified content identity retains the existing
/// complete-original path. Unsupported initial ranges do the same.
pub(in crate::similarity) async fn prepare(
    client: &Client,
    item: &CloudItem,
    stop: &AtomicBool,
    fetches: Arc<Fetches>,
    runtime: tokio::runtime::Handle,
    downloaded: Arc<AtomicU64>,
) -> Result<Option<(Arc<dyn SeekableInput>, Option<String>)>> {
    if !candidate(&item.name) || item.size == 0 || gcid(item.revision.as_deref()).is_none() {
        return Ok(None);
    }
    let (info, revision) = metadata(client, item, &fetches, stop, false, false).await?;
    let Some(hash) = gcid(revision.as_deref()) else {
        return Ok(None);
    };
    if info.size == 0 {
        return Ok(None);
    }
    checked_url(&info)?;
    let ticket = fetches.track(&item.name, info.size);
    ticket.on_demand();
    ticket.phase("waiting_memory");
    let (lease, entitlement) = loop {
        unpaused(&fetches, stop).await?;
        let lease = fetches.memory.cache(BLOCK.min(info.size), stop).await?;
        if let Some(permit) = fetches.try_acquire() {
            break (lease, permit.retaining(fetches.clone()));
        }
        // A queued range reader must not retain RAM needed by a partial full
        // original which already owns every connection entitlement.
        drop(lease);
        let _waiting = Counter::new(&fetches.waiting);
        tokio::time::sleep(Duration::from_millis(25)).await;
    };
    let mut state = State {
        route: client.clone(),
        info,
        etag: None,
        blocks: VecDeque::new(),
        transferred: 0,
        admitted: false,
    };
    let mut block = CachedBlock {
        start: 0,
        bytes: Vec::new(),
        _lease: lease,
    };
    match fill(
        &mut state,
        item,
        &hash,
        &fetches,
        &downloaded,
        &ticket,
        &mut block,
        stop,
    )
    .await
    {
        Err(error) if matches!(error.kind, "seek_unsupported" | "seek_changed") => return Ok(None),
        Err(error) => return Err(error.into()),
        Ok(()) => {}
    }
    if !filetwin_core::memory_input::supports_seekable_media(
        &block.bytes[..block.bytes.len().min(4096)],
        Path::new(&item.name),
    ) {
        return Ok(None);
    }
    state.blocks.push_back(block);
    let length = state.info.size;
    state.admitted = true;
    fetches.sampled_files.fetch_add(1, Ordering::AcqRel);
    fetches
        .sampled_original_bytes
        .fetch_add(length, Ordering::AcqRel);
    fetches.seekable_readers.fetch_add(1, Ordering::AcqRel);
    let original = Original {
        item: item.clone(),
        id: format!("gcid:{hash}:{length}"),
        gcid: hash,
        length,
        fetches,
        runtime,
        downloaded,
        ticket,
        valid: AtomicBool::new(true),
        failure: Mutex::new(None),
        _entitlement: entitlement,
        state: Mutex::new(state),
    };
    Ok(Some((Arc::new(original), revision)))
}

async fn refresh(
    state: &mut State,
    item: &CloudItem,
    hash: &str,
    fetches: &Fetches,
    stop: &AtomicBool,
    user: bool,
) -> std::result::Result<(), Failure> {
    let route = if user {
        state
            .route
            .clone()
            .with_content_mode(crate::ContentMode::User)
    } else {
        state.route.clone()
    };
    let (info, revision) = metadata(&route, item, fetches, stop, true, state.admitted).await?;
    if info.size != state.info.size || gcid(revision.as_deref()).as_deref() != Some(hash) {
        return Err(Failure::new("seek_changed", "download", false));
    }
    checked_url(&info)?;
    if route.content_mode() != state.route.content_mode() {
        state.etag = None;
    }
    state.route = route;
    state.info = info;
    Ok(())
}
async fn fill(
    state: &mut State,
    item: &CloudItem,
    hash: &str,
    fetches: &Fetches,
    downloaded: &AtomicU64,
    ticket: &Ticket,
    block: &mut CachedBlock,
    stop: &AtomicBool,
) -> std::result::Result<(), Failure> {
    let mut attempt = 0u32;
    loop {
        unpaused(fetches, stop).await?;
        attempt = attempt.saturating_add(1);
        ticket.begin_attempt(attempt, state.transferred);
        let result = fetch_block(state, fetches, downloaded, ticket, block, stop).await;
        let mut failure = match result {
            Ok(()) => return Ok(()),
            Err(e) => e,
        };
        block.bytes.clear();
        if failure.kind == "seek_pause" {
            ticket.phase("paused");
            unpaused(fetches, stop).await?;
            attempt = attempt.saturating_sub(1);
            continue;
        }
        if state.route.content_mode() == crate::ContentMode::Dynamic
            && failure
                .status
                .is_some_and(|s| matches!(s, 401 | 403 | 404 | 416))
        {
            refresh(state, item, hash, fetches, stop, true).await?;
            attempt = attempt.saturating_sub(1);
            continue;
        }
        if failure.status.is_some_and(|s| matches!(s, 401 | 403))
            && (fetches.retry_forever || attempt < MAX_ATTEMPTS)
        {
            refresh(state, item, hash, fetches, stop, false).await?;
        } else if !failure.retryable || (!fetches.retry_forever && attempt >= MAX_ATTEMPTS) {
            failure.attempts = attempt;
            return Err(failure);
        }
        let delay =
            Duration::from_millis((500 * (1u64 << attempt.saturating_sub(1).min(6))).min(30_000))
                .max(failure.retry_after.unwrap_or_default());
        ticket.retry(delay.as_secs());
        let _retrying = Counter::new(if state.admitted {
            &fetches.range_retrying
        } else {
            &fetches.retrying
        });
        let until = Instant::now() + delay;
        while Instant::now() < until {
            unpaused(fetches, stop).await?;
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}
async fn fetch_block(
    state: &mut State,
    fetches: &Fetches,
    downloaded: &AtomicU64,
    ticket: &Ticket,
    block: &mut CachedBlock,
    stop: &AtomicBool,
) -> std::result::Result<(), Failure> {
    let url = checked_url(&state.info)?;
    let length = BLOCK.min(state.info.size - block.start);
    let end = block.start + length - 1;
    let network = Network::for_url(url.as_str());
    let _participant = network.register();
    let _network = network_wait(fetches, stop, async {
        network
            .acquire()
            .await
            .map_err(|e| Failure::from_error(e.into(), "download"))
    })
    .await?;
    let _active = Counter::new(if state.admitted {
        &fetches.range_active
    } else {
        &fetches.active
    });
    ticket.phase("downloading");
    let mut request = state
        .route
        .download_http_client()
        .get(url)
        .header(header::RANGE, format!("bytes={}-{}", block.start, end))
        .header(header::ACCEPT_ENCODING, "identity");
    if let Some(etag) = state
        .etag
        .as_ref()
        .filter(|etag| etag.as_bytes().starts_with(b"\"") && etag.as_bytes().ends_with(b"\""))
    {
        request = request.header(header::IF_RANGE, etag);
    }
    let response = network_wait(fetches, stop, async {
        request
            .send()
            .await
            .map_err(|e| Failure::from_error(e.without_url().into(), "download"))
    })
    .await?;
    if !response.status().is_success() {
        let status = response.status().as_u16();
        let delay = retry_after(response.headers());
        if status == 429 || status >= 500 {
            let delay = delay.unwrap_or(Duration::from_secs(1));
            let _ = network.defer(delay);
            fetches.defer_requests(delay);
        }
        return Err(Failure::http(status, "download", delay));
    }
    if response.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        return Err(Failure::new(
            if state.etag.is_some() {
                "seek_changed"
            } else {
                "seek_unsupported"
            },
            "download",
            false,
        ));
    }
    let range = response
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(content_range);
    if range != Some((block.start, end, state.info.size))
        || response.content_length().is_some_and(|n| n != length)
        || response
            .headers()
            .get(header::CONTENT_ENCODING)
            .is_some_and(|v| v != "identity")
    {
        return Err(Failure::new("seek_unsupported", "download", false));
    }
    let etag = response.headers().get(header::ETAG).cloned();
    if state
        .etag
        .as_ref()
        .is_some_and(|saved| etag.as_ref() != Some(saved))
    {
        return Err(Failure::new("seek_changed", "download", false));
    }
    block.bytes.clear();
    block
        .bytes
        .try_reserve_exact(length as usize)
        .map_err(|_| Failure::new("memory_limit", "memory", false))?;
    let mut stream = response.bytes_stream();
    while let Some(chunk) = network_wait(fetches, stop, async {
        stream
            .next()
            .await
            .transpose()
            .map_err(|e| Failure::from_error(e.without_url().into(), "download"))
    })
    .await?
    {
        let n = chunk.len() as u64;
        downloaded.fetch_add(n, Ordering::Relaxed);
        fetches.received_bytes.fetch_add(n, Ordering::Relaxed);
        fetches
            .sampled_received_bytes
            .fetch_add(n, Ordering::Relaxed);
        network.record(n);
        state.transferred = state.transferred.saturating_add(n);
        if n > length - block.bytes.len() as u64 {
            return Err(Failure::new("seek_unsupported", "download", false));
        }
        block.bytes.extend_from_slice(&chunk);
        ticket.sample(
            state.transferred.min(state.info.size),
            state.info.size,
            state.transferred,
        );
    }
    if block.bytes.len() as u64 != length {
        return Err(Failure::new("incomplete", "download", true));
    }
    if state.etag.is_none() {
        state.etag = etag;
    }
    Ok(())
}
impl SeekableInput for Original {
    fn len(&self) -> u64 {
        self.length
    }
    fn content_id(&self) -> &str {
        &self.id
    }
    fn current(&self) -> bool {
        self.valid.load(Ordering::Acquire) && !self.state.is_poisoned()
    }
    fn failure(&self) -> Option<filetwin_core::Error> {
        self.failure.lock().ok().and_then(|failure| failure.clone())
    }
    fn read_at(&self, offset: u64, bytes: &mut [u8], stop: &AtomicBool) -> io::Result<usize> {
        if bytes.is_empty() || offset >= self.length {
            return Ok(0);
        }
        self.runtime
            .block_on(unpaused(&self.fetches, stop))
            .map_err(|_| io::ErrorKind::Interrupted)?;
        let mut state = loop {
            check(&self.fetches, stop).map_err(|_| io::ErrorKind::Interrupted)?;
            match self.state.try_lock() {
                Ok(state) => break state,
                Err(std::sync::TryLockError::WouldBlock) => {
                    std::thread::sleep(Duration::from_millis(5))
                }
                Err(_) => return Err(io::ErrorKind::Other.into()),
            }
        };
        if !self.current() {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let target = self
            .fetches
            .memory
            .cache_target(self.fetches.seekable_readers.load(Ordering::Acquire));
        while state.blocks.len() > 1 && state.blocks.len() as u64 * BLOCK > target {
            state.blocks.pop_front();
        }
        let start = offset / BLOCK * BLOCK;
        let block = if let Some(i) = state.blocks.iter().position(|b| b.start == start) {
            state.blocks.remove(i).unwrap()
        } else {
            let mut block = if (state.blocks.len() as u64 + 1) * BLOCK <= target {
                self.fetches
                    .memory
                    .try_cache(BLOCK.min(self.length))
                    .map(|lease| CachedBlock {
                        start,
                        bytes: Vec::new(),
                        _lease: lease,
                    })
            } else {
                None
            }
            .unwrap_or_else(|| {
                state
                    .blocks
                    .pop_front()
                    .expect("An admitted reusable range block")
            });
            block.start = start;
            if let Err(error) = self.runtime.block_on(fill(
                &mut state,
                &self.item,
                &self.gcid,
                &self.fetches,
                &self.downloaded,
                &self.ticket,
                &mut block,
                stop,
            )) {
                // A server is also replaced for native decoder RAM retries.
                // Cancelling that server only abandons this partial block; it
                // must not invalidate the original retained for the retry.
                block.bytes.clear();
                block.start = u64::MAX;
                if !(error.kind == "cancelled" && stop.load(Ordering::Acquire)) {
                    let reason = if error.kind == "seek_changed" {
                        filetwin_core::Error::new(
                            filetwin_core::ErrorCode::SourceChanged,
                            "validation",
                            "Source changed during processing; vector discarded",
                        )
                    } else {
                        super::super::encoding::fetching_error(
                            &anyhow::Error::from(error.clone()),
                            error.kind == "cancelled",
                        )
                    };
                    *self.failure.lock().unwrap() = Some(reason);
                    self.valid.store(false, Ordering::Release);
                }
                state.blocks.push_back(block);
                return Err(io::Error::new(
                    if error.kind == "cancelled" {
                        io::ErrorKind::Interrupted
                    } else {
                        io::ErrorKind::InvalidData
                    },
                    "Could not read the verified media original",
                ));
            }
            block
        };
        let at = (offset - start) as usize;
        let n = bytes.len().min(block.bytes.len() - at);
        bytes[..n].copy_from_slice(&block.bytes[at..at + n]);
        state.blocks.push_back(block);
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::guest_fixture::{PartialFixture, PartialReply};
    const HASH: &str = "0123456789abcdef0123456789abcdef01234567";
    async fn fixture(
        total: usize,
        prefix: usize,
        mode: crate::ContentMode,
    ) -> (
        PartialFixture,
        Client,
        CloudItem,
        Arc<Fetches>,
        Arc<AtomicU64>,
    ) {
        let f = PartialFixture::new(total, prefix, PartialReply::CappedRange).await;
        for record in [&f.saved, &f.original] {
            let mut record = record.lock().unwrap();
            record["hash"] = json!(HASH);
            record["name"] = json!("generated.mp4");
        }
        f.config.lock().unwrap().user_hash = Some(HASH.into());
        let client = Client::builder()
            .personal_access_token("account-access")
            .device_id("generated-device")
            .api_base_url(&f.base)
            .auth_base_url(&f.base)
            .build()
            .unwrap()
            .with_content_mode(mode);
        let item = CloudItem {
            id: "saved-id".into(),
            name: "generated.mp4".into(),
            path: "/generated.mp4".into(),
            is_folder: false,
            size: total as u64,
            revision: Some(HASH.into()),
            ancestors: vec![CloudAncestor {
                id: "saved-folder".into(),
                name: "Generated".into(),
            }],
        };
        (
            f,
            client,
            item,
            Arc::new(Fetches::with_memory(4, 4 * BLOCK)),
            Arc::new(AtomicU64::new(0)),
        )
    }
    async fn original(
        client: &Client,
        item: &CloudItem,
        fetches: Arc<Fetches>,
        downloaded: Arc<AtomicU64>,
    ) -> Arc<dyn SeekableInput> {
        prepare(
            client,
            item,
            &AtomicBool::new(false),
            fetches,
            tokio::runtime::Handle::current(),
            downloaded,
        )
        .await
        .unwrap()
        .unwrap()
        .0
    }
    async fn read(input: Arc<dyn SeekableInput>, offset: u64, n: usize) -> io::Result<Vec<u8>> {
        tokio::task::spawn_blocking(move || {
            let mut bytes = vec![0; n];
            let n = input.read_at(offset, &mut bytes, &AtomicBool::new(false))?;
            bytes.truncate(n);
            Ok(bytes)
        })
        .await
        .unwrap()
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn distant_media_ranges_reuse_cache_without_download_or_hashing_the_gap() {
        let (f, c, item, fetches, downloaded) = fixture(
            (16 * BLOCK) as usize,
            (16 * BLOCK) as usize,
            crate::ContentMode::User,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded.clone()).await;
        assert_eq!(input.content_id(), format!("gcid:{HASH}:{}", item.size));
        let offset = 15 * BLOCK + 7;
        assert_eq!(
            read(input.clone(), offset, 16).await.unwrap(),
            f.content[offset as usize..offset as usize + 16]
        );
        let before = downloaded.load(Ordering::Acquire);
        assert_eq!(
            read(input.clone(), offset, 16).await.unwrap(),
            f.content[offset as usize..offset as usize + 16]
        );
        assert_eq!(downloaded.load(Ordering::Acquire), before);
        assert_eq!(before, 2 * BLOCK);
        assert!(fetches.memory.used() <= 2 * BLOCK);
        for request in f
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /user-body"))
        {
            assert!(request.to_ascii_lowercase().contains("range: bytes="));
            assert!(!request.to_ascii_lowercase().contains("authorization:"));
        }
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn guest_cap_falls_back_to_same_gcid_user_ranges_with_different_etag() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            BLOCK as usize,
            crate::ContentMode::Dynamic,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded.clone()).await;
        assert_eq!(fetches.connections.lock().unwrap().active, 1);
        let held: Vec<_> = (0..3).map(|_| fetches.try_acquire().unwrap()).collect();
        let offset = 7 * BLOCK + 3;
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), read(input.clone(), offset, 8))
                .await
                .unwrap()
                .unwrap(),
            f.content[offset as usize..offset as usize + 8]
        );
        assert_eq!(downloaded.load(Ordering::Acquire), 2 * BLOCK);
        let requests = f.requests.lock().unwrap();
        assert!(requests.iter().any(|r| r.starts_with("GET /guest-body")));
        assert!(requests.iter().any(|r| r.starts_with("GET /user-body")));
        drop(requests);
        drop(held);
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
        assert_eq!(fetches.connections.lock().unwrap().active, 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn changed_user_gcid_cannot_supply_a_later_range() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            BLOCK as usize,
            crate::ContentMode::Dynamic,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded.clone()).await;
        f.config.lock().unwrap().user_hash =
            Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into());
        assert!(read(input.clone(), 7 * BLOCK, 8).await.is_err());
        assert!(!input.current());
        assert_eq!(downloaded.load(Ordering::Acquire), BLOCK);
        assert!(!f
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.starts_with("GET /user-body")));
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ignored_initial_ranges_and_bad_total_fall_back_without_retained_ram() {
        for malformed in [false, true] {
            let (f, c, item, fetches, downloaded) = fixture(
                (8 * BLOCK) as usize,
                (8 * BLOCK) as usize,
                if malformed {
                    crate::ContentMode::Guest
                } else {
                    crate::ContentMode::User
                },
            )
            .await;
            if malformed {
                f.config.lock().unwrap().guest_invalid_range = true;
            } else {
                f.config.lock().unwrap().user_oversized_body = true;
            }
            assert!(prepare(
                &c,
                &item,
                &AtomicBool::new(false),
                fetches.clone(),
                tokio::runtime::Handle::current(),
                downloaded
            )
            .await
            .unwrap()
            .is_none());
            assert_eq!(fetches.memory.used(), 0);
            assert_eq!(fetches.seekable_readers.load(Ordering::Acquire), 0);
        }
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn etag_change_after_analysis_started_invalidates_the_source() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            (8 * BLOCK) as usize,
            crate::ContentMode::User,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        f.config.lock().unwrap().user_etag = Some("\"replacement\"".into());
        assert!(read(input.clone(), 7 * BLOCK, 8).await.is_err());
        assert!(!input.current());
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn memory_pressure_reuses_one_admitted_block_and_tiny_tail_does_not_underreserve() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK + 1) as usize,
            (8 * BLOCK + 1) as usize,
            crate::ContentMode::User,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        fetches.memory.auto_resize(BLOCK, 2);
        assert_eq!(
            read(input.clone(), 8 * BLOCK, 1).await.unwrap(),
            f.content[(8 * BLOCK) as usize..]
        );
        assert_eq!(fetches.memory.used(), BLOCK);
        assert_eq!(
            read(input.clone(), 2 * BLOCK, 16).await.unwrap(),
            f.content[(2 * BLOCK) as usize..(2 * BLOCK) as usize + 16]
        );
        assert_eq!(fetches.memory.used(), BLOCK);
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn server_stop_interrupts_paused_reads_and_releases_leases() {
        let (_f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            (8 * BLOCK) as usize,
            crate::ContentMode::User,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        fetches.control.set_paused(true);
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let reader = tokio::task::spawn_blocking(move || {
            let mut bytes = [0; 8];
            input.read_at(7 * BLOCK, &mut bytes, &stopping)
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        stop.store(true, Ordering::Release);
        assert!(tokio::time::timeout(Duration::from_secs(1), reader)
            .await
            .unwrap()
            .unwrap()
            .is_err());
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn transient_ranges_retry_without_account_handoff() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            (8 * BLOCK) as usize,
            crate::ContentMode::Dynamic,
        )
        .await;
        f.config.lock().unwrap().guest_ranges_complete = true;
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        f.config.lock().unwrap().guest_next_error = Some(503);
        assert!(read(input.clone(), 7 * BLOCK, 8).await.is_ok());
        assert!(!f
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.starts_with("GET /user-body")));
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stopping_one_server_read_keeps_the_original_valid_for_a_decoder_retry() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            (8 * BLOCK) as usize,
            crate::ContentMode::Guest,
        )
        .await;
        f.config.lock().unwrap().guest_ranges_complete = true;
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        fetches.memory.auto_resize(BLOCK, 2);
        assert!(read(input.clone(), BLOCK, 8).await.is_ok());
        f.config.lock().unwrap().delay_first_guest_range_ms = 3000;
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let first = input.clone();
        let reader = tokio::task::spawn_blocking(move || {
            let mut bytes = [0; 8];
            first.read_at(0, &mut bytes, &stopping)
        });
        let started = Instant::now();
        while f
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /guest-body") && r.contains("range: bytes=0-"))
            .count()
            < 2
        {
            assert!(started.elapsed() < Duration::from_secs(1));
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        stop.store(true, Ordering::Release);
        assert!(tokio::time::timeout(Duration::from_secs(1), reader)
            .await
            .unwrap()
            .unwrap()
            .is_err());
        assert!(input.current());
        assert!(input.failure().is_none());
        f.config.lock().unwrap().delay_first_guest_range_ms = 0;
        assert_eq!(read(input.clone(), 0, 8).await.unwrap(), f.content[..8]);
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
        assert_eq!(fetches.connections.lock().unwrap().active, 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_late_unavailable_range_retains_a_fetching_reason_instead_of_source_changed() {
        let (_f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            BLOCK as usize,
            crate::ContentMode::Guest,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        assert!(read(input.clone(), 7 * BLOCK, 8).await.is_err());
        assert!(!input.current());
        let error = input.failure().unwrap();
        assert_eq!(error.code, filetwin_core::ErrorCode::IoError);
        assert_eq!(error.stage, "fetching");
        assert_eq!(error.details["http_status"], 416);
        assert_eq!(error.details["attempts"], 1);
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn initial_metadata_retries_after_the_clients_transient_retry_budget() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            (8 * BLOCK) as usize,
            crate::ContentMode::User,
        )
        .await;
        f.config.lock().unwrap().user_metadata_failures = 5;
        let input = tokio::time::timeout(
            Duration::from_secs(15),
            original(&c, &item, fetches.clone(), downloaded),
        )
        .await
        .unwrap();
        assert!(input.current());
        assert!(
            f.requests
                .lock()
                .unwrap()
                .iter()
                .filter(|r| r.starts_with("GET /drive/v1/files/saved-id"))
                .count()
                >= 6
        );
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn user_handoff_metadata_retries_without_poisoning_an_unchanged_original() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            BLOCK as usize,
            crate::ContentMode::Dynamic,
        )
        .await;
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        f.config.lock().unwrap().user_metadata_failures = 5;
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(15), read(input.clone(), 7 * BLOCK, 8))
                .await
                .unwrap()
                .unwrap(),
            f.content[(7 * BLOCK) as usize..(7 * BLOCK) as usize + 8]
        );
        assert!(input.current());
        assert!(input.failure().is_none());
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn weak_etags_are_validated_without_sending_an_invalid_if_range_validator() {
        let (f, c, item, fetches, downloaded) = fixture(
            (8 * BLOCK) as usize,
            (8 * BLOCK) as usize,
            crate::ContentMode::User,
        )
        .await;
        f.config.lock().unwrap().user_etag = Some("W/\"generated\"".into());
        let input = original(&c, &item, fetches.clone(), downloaded).await;
        assert!(read(input.clone(), 7 * BLOCK, 8).await.is_ok());
        assert!(!f
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /user-body"))
            .any(|r| r.to_ascii_lowercase().contains("if-range:")));
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
}

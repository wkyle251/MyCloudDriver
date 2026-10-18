//! FileTwin 0.2 encoding, vector reuse and app-owned comparison publication.
use super::vector_cache::VectorCache;
use super::*;
use filetwin_core::{
    api::{
        CancellationToken, Counts, EncodeRequest, EncoderConfig, FilePath, FileRecord, FileState,
        Progress,
    },
    Encoder,
};
use scope::{issue, InputFile};

const NATIVE_PREPARERS: usize = 8;

#[cfg(test)]
#[path = "similarity_photos_tests.rs"]
mod photos_tests;

fn config(request: &ScanRequest, temporary: &Path) -> EncoderConfig {
    let mut config = EncoderConfig::new(&request.model_dir, temporary);
    config.runtime = request.runtime.clone();
    config.memory_scheduling = request.resources.memory_scheduling;
    config.workers = resources::prepare(request.resources.effective_workers());
    config.memory_bytes = request.resources.analysis_budget();
    config.memory_staging = true;
    config.staging_bytes = request.resources.download_budget();
    if request.resources.automatic_memory {
        config.memory_scheduling = true;
        config.memory_ceiling = Some(auto_memory::physical_memory());
        config.total_memory_bytes =
            Some(auto_memory::initial_budget(auto_memory::physical_memory()));
    }
    let cache = request.data_dir.join("inference-cache");
    if private_dir(&cache).is_ok() {
        config.inference_cache_dir = Some(cache);
    }
    config
}

fn progress(counts: &Counts, report: &ScanReport, stage: &str, elapsed: f64) -> Value {
    json!({"event":"progress","stage":stage,"completed":counts.files_processed,"total":counts.files_total,
        "counts":counts,"skipped":report.skipped_files.saturating_sub(counts.files_failed+counts.files_skipped),
        "downloaded_bytes":report.downloaded_bytes,"elapsed_seconds":elapsed,
        "discovery_complete":counts.files_total.is_some()})
}

fn encoding_progress(
    base: &Counts,
    update: &Progress,
    report: &ScanReport,
    elapsed: f64,
    fetches: &fetch::Fetches,
    sources: &prefetch::State,
) -> Value {
    let mut counts = base.clone();
    counts.files_processed += update.counts.files_processed;
    counts.files_ready += update.counts.files_ready;
    counts.files_failed += update.counts.files_failed;
    counts.files_skipped += update.counts.files_skipped;
    counts.vectors_encoded += update.counts.vectors_encoded;
    counts.cache_hits += update.counts.cache_hits;
    counts.bytes_read += update.counts.bytes_read;
    counts.bytes_hashed += update.counts.bytes_hashed;
    let mut event = progress(&counts, report, "analysing", elapsed);
    // Cached exclusions already contribute to the base counts. Only discovery
    // issues remain additional to the files counted by the encoder.
    event["skipped"] = report
        .skipped_files
        .saturating_sub(base.files_skipped + base.files_failed)
        .into();
    if let Some(work) = &update.work {
        event["work"] = serde_json::to_value(work).expect("Serializable phases");
        let resolving = sources.resolving.load(Ordering::Acquire);
        let waiting_memory = fetches
            .memory
            .waiting
            .load(Ordering::Relaxed)
            .min(resolving);
        let fetch_work = resolving - waiting_memory;
        let (fetching, metadata, retrying) = if report.source == ScanSource::Cloud || sources.inventory.has_cloud {
            let cloud_work = if report.source == ScanSource::Cloud && !sources.inventory.has_cloud {
                fetch_work
            } else { sources.cloud_resolving.load(Ordering::Acquire).min(fetch_work) };
            let active = fetches
                .active
                .load(Ordering::Relaxed)
                .min(fetches.limit as u64)
                .min(cloud_work);
            let metadata = fetches
                .metadata
                .load(Ordering::Relaxed)
                .min(cloud_work - active);
            let retrying = fetches
                .retrying
                .load(Ordering::Relaxed)
                .min(cloud_work - active - metadata);
            (active + fetch_work - cloud_work, metadata, retrying)
        } else {
            (fetch_work, 0, 0)
        };
        let ready = sources.ready.load(Ordering::Acquire);
        let undispatched = counts.files_discovered.saturating_sub(
            update.counts.files_discovered + base.files_processed + ready + resolving,
        );
        let waiting = undispatched + fetch_work - fetching - metadata - retrying;
        event["work"]["independent_downloads"] = true.into();
        // Prefetched paths/originals still need reading and hashing. Only the
        // pipeline queue has completed acquisition and can enter Analysis RAM.
        event["work"]["ready"] = work.ready.into();
        event["work"]["waiting_read"] = ready.into();
        event["work"]["resolving"] = metadata.into();
        event["work"]["waiting_memory"] = (work.waiting_memory + waiting_memory).into();
        event["work"]["original_memory_bytes"] =
            (fetches.memory.used() + work.original_memory_bytes).into();
        event["work"]["original_memory_limit"] = fetches.memory.limit().into();
        event["work"]["retained_download_minimum"] = fetches.memory.minimum_limit().into();
        event["work"]["analysis_memory_limit"] = work.memory_limit.into();
        event["work"]["analysis_memory_bytes"] = work
            .memory_in_use
            .saturating_sub(work.original_memory_bytes)
            .into();
        event["work"]["memory_in_use"] = (work.memory_in_use + fetches.memory.used()).into();
        event["work"]["memory_limit"] = (work.memory_limit + fetches.memory.limit()).into();
        event["work"]["original_storage"] = "memory".into();
        let range_fetching = fetches.range_active.load(Ordering::Relaxed);
        let range_metadata = fetches.range_metadata.load(Ordering::Relaxed);
        let range_retrying = fetches.range_retrying.load(Ordering::Relaxed);
        event["work"]["range_fetching"] = range_fetching.into();
        event["work"]["range_resolving"] = range_metadata.into();
        event["work"]["range_retrying"] = range_retrying.into();
        event["work"]["fetching"] = (fetching + range_fetching).into();
        event["work"]["resolving"] = (metadata + range_metadata).into();
        event["work"]["waiting_download"] = waiting.into();
        event["work"]["retrying_download"] = (retrying + range_retrying).into();
        event["work"]["download_limit"] = fetches.connection_limit().into();
        // Active excludes queued originals and all RAM/retry waits. Prefetch
        // downloads are separate jobs; range reads overlap an existing decoder
        // and therefore do not add another active analysis job.
        event["active"] =
            (fetching + metadata + work.fetching + work.reading + work.hashing + work.encoding)
                .into();
    } else {
        event["active"] = update
            .counts
            .files_discovered
            .saturating_sub(update.counts.files_processed)
            .into();
    }
    let downloads = fetches.download_progress();
    if report.source == ScanSource::Cloud || sources.inventory.has_cloud {
        let total = if sources.inventory.has_cloud {
            sources.inventory.cloud_file_bytes.load(Ordering::Acquire)
        } else { sources.inventory.file_bytes.load(Ordering::Acquire) };
        let sampled_files = fetches.sampled_files.load(Ordering::Acquire);
        let sampled_original_bytes = fetches.sampled_original_bytes.load(Ordering::Acquire);
        let ready = if sources.inventory.has_cloud { sources.resolved_cloud_bytes.load(Ordering::Acquire) }
            else { sources.resolved_bytes.load(Ordering::Acquire) }
            .saturating_sub(sampled_original_bytes)
            .saturating_add(downloads["cloud_full_received_bytes"].as_u64().unwrap_or(0)).min(total);
        event["cloud_data"] = json!({"ready_bytes":ready,"total_bytes":total,
            "inventory_complete":sources.inventory.complete.load(Ordering::Acquire),
            "on_demand":sampled_files>0,"sampled_files":sampled_files,
            "sampled_original_bytes":sampled_original_bytes,
            "sampled_received_bytes":fetches.sampled_received_bytes.load(Ordering::Relaxed)});
    }
    if report.source == ScanSource::Cloud || sources.inventory.has_cloud || downloads["total"].as_u64().unwrap_or(0) > 0 {
        event["downloads"] = downloads;
        event["downloads"]["forecast_bytes"] = fetches.memory.forecast().into();
        event["downloads"]["forecast_seconds"] = memory::FORECAST_SECONDS.into();
        event["downloads"]["strategy"] = "predictive".into();
    }
    event
}

enum ResolvedInput {
    Path(Option<tempfile::TempDir>),
    Memory(Arc<filetwin_core::memory_input::MemoryInput>),
    Reused(FileRecord),
    Cached(FileRecord),
    Seekable(Arc<dyn filetwin_core::memory_input::SeekableInput>),
    Excluded(FileRecord),
}

/// Provider downloads and exports are leased to a single encoder input. The
/// lease owns only this private directory, never an original returned by iCloud
/// or Local Disk. FileTwin releases it when that file's result is complete.
#[derive(Debug)]
struct RetryableProvider;
impl std::fmt::Display for RetryableProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("The drive connection was interrupted")
    }
}
impl std::error::Error for RetryableProvider {}

fn resolve_input(
    file: &mut InputFile,
    temporary: &Path,
    cancel: &AtomicBool,
    client: Option<&Client>,
    runtime: &tokio::runtime::Handle,
    downloaded: &std::sync::atomic::AtomicU64,
    fetches: &fetch::Fetches,
) -> Result<ResolvedInput> {
    control::wait_blocking(&fetches.control, cancel)?;
    if let Some(item) = &file.cloud {
        let mut previous = 0;
        let result = runtime.block_on(fetch::download_versioned(
            client.context("PikPak is not connected")?,
            item,
            cancel,
            fetches,
            |written, _expected| {
                downloaded.fetch_add(written.saturating_sub(previous), Ordering::Relaxed);
                previous = written;
                Ok(())
            },
        ));
        if let Some(protected) = result
            .as_ref()
            .err()
            .and_then(|e| e.downcast_ref::<password::Protected>())
        {
            let item = file.cloud.as_mut().unwrap();
            item.revision = protected.revision.clone();
            item.size = protected.bytes;
            file.display.bytes = protected.bytes;
            return Ok(ResolvedInput::Excluded(password::record(protected.bytes)));
        }
        let (data, revision) = result?;
        // Discovery can precede a long RAM wait. Journal the revision actually
        // resolved with this original, not potentially stale inventory metadata.
        let item = file.cloud.as_mut().unwrap();
        item.revision = revision;
        item.size = data.as_ref().as_ref().len() as u64;
        file.display.bytes = item.size;
        return Ok(ResolvedInput::Memory(data));
    }
    if file.external.is_none() {
        return Ok(ResolvedInput::Path(None));
    }
    if file.is_photos_source() {
        return resolve_photos_memory(file, temporary, cancel, runtime, fetches, downloaded);
    }
    let lease = tempfile::Builder::new()
        .prefix("source-")
        .tempdir_in(std::fs::canonicalize(temporary)?)?;
    let directory = lease.path().join("content");
    private_dir(&directory)?;
    let path = {
        let item = file.external.as_ref().expect("External source");
        let response_file = lease.path().join("source.json");
        emit(
            &json!({"event":"resolve_source", "id":item.id, "directory":directory, "response_file":response_file}),
        )?;
        let mut waiting = Instant::now();
        loop {
            waiting += control::wait_blocking(&fetches.control, cancel)?;
            check_cancel(cancel)?;
            if response_file.exists() {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Reply {
                    id: String,
                    path: Option<PathBuf>,
                    error: Option<String>,
                    retryable: Option<String>,
                }
                let response = scope::open_secure(&response_file)?;
                if response.metadata()?.len() > 64 * 1024 {
                    bail!("Invalid provider response");
                }
                let reply: Reply = serde_json::from_reader(response)?;
                if reply.id != item.id {
                    bail!("The provider returned a different file");
                }
                if reply.error.is_some() {
                    if reply.retryable.as_deref() == Some("true") {
                        return Err(RetryableProvider.into());
                    }
                    bail!("Could not fetch this original from the drive. Check access and retry.");
                }
                let path = reply
                    .path
                    .context("The provider did not return an original")?;
                if !path.is_absolute() {
                    bail!("The provider returned an invalid path");
                }
                break path;
            }
            if waiting.elapsed() > Duration::from_secs(30 * 60) {
                bail!("The drive did not return this original in time");
            }
            let delay = if waiting.elapsed() < Duration::from_secs(1) {
                1
            } else {
                25
            };
            std::thread::sleep(Duration::from_millis(delay));
        }
    };
    file.resolved(path)?;
    Ok(ResolvedInput::Path(Some(lease)))
}

/// A named pipe has a filesystem entry, but its content lives only in kernel
/// memory. Photos streams directly into the helper buffer, never an export file.
fn resolve_photos_memory(
    file: &InputFile,
    temporary: &Path,
    cancel: &AtomicBool,
    runtime: &tokio::runtime::Handle,
    fetches: &fetch::Fetches,
    downloaded: &std::sync::atomic::AtomicU64,
) -> Result<ResolvedInput> {
    let item = file.external.as_ref().unwrap();
    let size = if file.is_photos_preview() {
        0
    } else {
        item.size
    };
    let ticket = fetches.track(&item.name, size);
    ticket.native();
    let mut capacity = if size > 0 {
        size
    } else {
        photos_initial_capacity(fetches.memory.limit())?
    };
    if file.is_photos_preview() {
        capacity = capacity.min(8 << 20);
    }
    for attempt in 1.. {
        control::wait_blocking(&fetches.control, cancel)?;
        ticket.begin_attempt(attempt, 0);
        match resolve_photos_attempt(
            file, temporary, capacity, cancel, runtime, fetches, downloaded, &ticket,
        )? {
            PhotosAttempt::Complete(original) => return Ok(original),
            PhotosAttempt::LargerCapacity(required) => {
                if size > 0 || (file.is_photos_preview() && required > 8 << 20) {
                    return Err(memory::Limit.into());
                }
                // The provider has closed the failed pipe and acknowledged the
                // overflow. The attempt's partial buffer and claim are already
                // dropped, so a larger claim cannot deadlock against itself.
                capacity = photos_retry_capacity(capacity, required, fetches.memory.ceiling())?;
                if file.is_photos_preview() {
                    capacity = capacity.min(8 << 20);
                }
            }
        }
    }
    unreachable!("Capacity doubles on every retry and cannot exceed Download RAM")
}

fn photos_initial_capacity(limit: u64) -> Result<u64> {
    // PhotoKit does not supply sizes on supported macOS versions. Give each
    // preparer a bounded possible maximum, while reserving only its receive
    // window. Claiming the full pool for every unknown file serializes them.
    let page = if limit >= 16 * 1024 { 16 * 1024 } else { 1 };
    let capacity = (limit / NATIVE_PREPARERS as u64 / page * page).max(page);
    if capacity > limit {
        return Err(memory::Limit.into());
    }
    Ok(capacity)
}

fn photos_retry_capacity(previous: u64, required: u64, limit: u64) -> Result<u64> {
    if required <= previous {
        bail!("Invalid Photos memory capacity response");
    }
    let page = if limit >= 16 * 1024 { 16 * 1024 } else { 1 };
    let limit = limit / page * page;
    if required > limit {
        return Err(memory::Limit.into());
    }
    let capacity = previous.saturating_mul(2).max(required).min(limit);
    Ok(capacity.saturating_add(page - 1) / page * page)
}

enum PhotosAttempt {
    Complete(ResolvedInput),
    LargerCapacity(u64),
}

#[allow(clippy::too_many_arguments)]
fn resolve_photos_attempt(
    file: &InputFile,
    temporary: &Path,
    capacity: u64,
    cancel: &AtomicBool,
    runtime: &tokio::runtime::Handle,
    fetches: &fetch::Fetches,
    downloaded: &std::sync::atomic::AtomicU64,
    ticket: &fetch::Ticket,
) -> Result<PhotosAttempt> {
    use std::io::Read;
    let item = file.external.as_ref().unwrap();
    let size = if file.is_photos_preview() {
        0
    } else {
        item.size
    };
    ticket.phase("waiting_memory");
    let reservation = runtime.block_on(fetches.memory.stream(capacity, cancel))?;
    let lease = tempfile::Builder::new()
        .prefix("source-")
        .tempdir_in(std::fs::canonicalize(temporary)?)?;
    let directory = lease.path().join("content");
    private_dir(&directory)?;
    let pipe = directory.join("original.pipe");
    filetwin_core::memory_input::create_pipe(&pipe)?;
    let mut reader = scope::open_secure(&pipe)?;
    let response_file = lease.path().join("source.json");
    emit(
        &json!({"event":"resolve_source", "id":item.id,"directory":directory,"response_file":response_file,
        "memory_pipe":pipe,"memory_capacity":reservation.capacity,"download_id":ticket.id()}),
    )?;
    let mut started = Instant::now();
    let mut bytes = fetch::RamBuffer::new(reservation.capacity)?;
    let mut buffer = [0u8; 64 * 1024];
    let mut sampled = Instant::now();
    ticket.phase("downloading");
    loop {
        started += control::wait_blocking(&fetches.control, cancel)?;
        check_cancel(cancel)?;
        let target = (bytes.len() as u64 + buffer.len() as u64).min(reservation.capacity);
        if target > reservation.reserved() {
            ticket.phase("waiting_memory");
            runtime.block_on(reservation.grow(target, cancel))?;
            ticket.phase("downloading");
        }
        let n = match reader.read(&mut buffer) {
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => 0,
            Err(e) => return Err(e.into()),
        };
        if n > 0 {
            if bytes.len() as u64 + n as u64 > reservation.capacity {
                return Err(memory::Limit.into());
            }
            bytes.append(&buffer[..n]);
            downloaded.fetch_add(n as u64, Ordering::Relaxed);
            if sampled.elapsed() >= Duration::from_millis(250) {
                reservation.observe_rate(ticket.sample(
                    bytes.len() as u64,
                    size,
                    bytes.len() as u64,
                ));
                sampled = Instant::now();
            }
            continue;
        }
        if response_file.exists() {
            let response = scope::open_secure(&response_file)?;
            if response.metadata()?.len() > 64 * 1024 {
                bail!("Invalid provider response");
            }
            let reply: Value = serde_json::from_reader(response)?;
            // Foundation returns /var URLs while Rust canonicalizes /private/var.
            // Both must identify this exact owned pipe, not just share a prefix.
            let returned_pipe = reply["path"]
                .as_str()
                .and_then(|p| std::fs::canonicalize(p).ok());
            if reply["id"].as_str() != Some(&item.id) {
                bail!("The provider returned a different file");
            }
            if reply["error"].is_string() && !reply["memory_required"].is_null() {
                let required = reply["memory_required"]
                    .as_str()
                    .and_then(|s| s.parse::<u64>().ok())
                    .filter(|&bytes| bytes > reservation.capacity)
                    .context("Invalid Photos memory capacity response")?;
                return Ok(PhotosAttempt::LargerCapacity(required));
            }
            if reply["error"].is_string() && reply["retryable"].as_str() == Some("true") {
                return Err(RetryableProvider.into());
            }
            if reply["error"].is_string()
                || returned_pipe.as_ref() != Some(&std::fs::canonicalize(&pipe)?)
            {
                if file.is_photos_preview() {
                    bail!(
                        "Photos could not provide this preview. Try Originals mode in a new scan."
                    );
                }
                bail!("The Photos original could not be streamed into memory.");
            }
            // The provider closes the pipe before publishing completion. Drain
            // once more: data may have arrived between the read and the reply.
            let n = reader.read(&mut buffer)?;
            if n > 0 {
                if bytes.len() as u64 + n as u64 > reservation.capacity {
                    return Err(memory::Limit.into());
                }
                bytes.append(&buffer[..n]);
                downloaded.fetch_add(n as u64, Ordering::Relaxed);
                continue;
            }
            if size > 0 && bytes.len() as u64 != size {
                bail!("The Photos original was incomplete.");
            }
            reservation.finish(bytes.len() as u64);
            return Ok(PhotosAttempt::Complete(ResolvedInput::Memory(Arc::new(
                filetwin_core::memory_input::MemoryInput::from_buffer(bytes)
                    .with_reservation(reservation),
            ))));
        }
        if started.elapsed() > Duration::from_secs(30 * 60) {
            bail!("Photos did not return the original in time.");
        }
        // macOS FIFOs can hold only 8 KiB. Sleeping after every empty read
        // throttles delivery even when PhotoKit already has the whole resource.
        // Wake as soon as bytes arrive, with a timeout for replies/cancellation.
        use rustix::event::{poll, PollFd, PollFlags, Timespec};
        let mut fds = [PollFd::new(&reader, PollFlags::IN)];
        match poll(
            &mut fds,
            Some(&Timespec {
                tv_sec: 0,
                tv_nsec: 100_000_000,
            }),
        ) {
            Ok(_) => {}
            Err(rustix::io::Errno::INTR) => continue,
            Err(error) => return Err(error.into()),
        }
        if fds[0].revents().contains(PollFlags::HUP) && !fds[0].revents().contains(PollFlags::IN) {
            // EOF may precede the app's completion reply. Avoid spinning on
            // an already closed writer while that reply is being published.
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

pub(super) fn safe_extension(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(16)
        .collect()
}

fn sync_discovery(counts: &mut Counts, state: &discovery::State) {
    counts.files_discovered = state.found.load(Ordering::Acquire);
    counts.files_total = state
        .complete
        .load(Ordering::Acquire)
        .then_some(counts.files_discovered);
}

struct Pass {
    files: Vec<InputFile>,
    counts: Counts,
    complete: bool,
}

#[allow(clippy::too_many_arguments)]
pub(super) fn run(
    request: &ScanRequest,
    temporary: &Path,
    cancel: &Arc<AtomicBool>,
    report: &mut ScanReport,
    started: Instant,
    client: Option<&Client>,
    runtime: &tokio::runtime::Handle,
) -> Result<()> {
    let checkpoint = checkpoint::Checkpoint::open(request)?;
    let mut fetches =
        fetch::Fetches::with_memory(fetch::MAX_DOWNLOADS, request.resources.download_budget());
    if request.resources.automatic_memory {
        let physical = auto_memory::physical_memory();
        fetches
            .memory
            .enable_automatic(physical.saturating_sub(memory::ANALYSIS_HEADROOM.min(physical / 4)));
    }
    fetches.retry_forever = request.checkpoint_id.is_some();
    let control = control::Control::new(request, cancel.clone(), Some(fetches.memory.clone()));
    let token = control.token.clone();
    fetches.control = token.clone();
    let fetches = Arc::new(fetches);
    let initial_report = report.clone();
    let downloaded = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let mut saved = checkpoint
        .as_ref()
        .map(|c| c.sealed())
        .transpose()?
        .flatten();
    // An unsealed (including user-finished) inventory can be rediscovered in a
    // different order. Reuse vectors, but never reuse scores with old ordinals.
    if saved.is_none() {
        if let Some(checkpoint) = &checkpoint {
            checkpoint.invalidate_inventory()?;
        }
    }
    let mut snapshot = None;
    let capture = |previous: &[InputFile]| {
        inventory::capture(request, temporary, &control.acquisition_cancel, client, runtime, &token, initial_report.clone())
        .and_then(|snapshot| { inventory::validate_removals(previous, &snapshot.files)?; Ok(snapshot) })
        .map_err(|error| {
            if !cancel.load(Ordering::Acquire) && !token.is_finishing() {
                let _ = emit(&json!({"event":"interrupted", "reason":"The scan could not verify file changes. Check drive access, then resume; completed analysis is saved."}));
            }
            error
        })
    };
    for round in 0..=8 {
        let pass = if let Some(saved) = saved.take() {
            acceleration::announce(
                checkpoint
                    .as_ref()
                    .unwrap()
                    .backend()?
                    .unwrap_or(filetwin_core::profile::Backend::Cpu),
                0,
                false,
            )?;
            *report = saved.report;
            report.status = "completed".into();
            downloaded.store(report.downloaded_bytes, Ordering::Relaxed);
            emit(&json!({"event":"restored_inventory"}))?;
            Pass {
                files: saved.files,
                counts: saved.counts,
                complete: true,
            }
        } else {
            *report = initial_report.clone();
            run_pass(
                request,
                temporary,
                cancel,
                report,
                started,
                client,
                runtime,
                checkpoint.clone(),
                fetches.clone(),
                downloaded.clone(),
                snapshot.take(),
                control.acquisition_cancel.clone(),
            )?
        };
        if token.is_finishing() {
            report.status = "finished".into();
            return publish_resuming(
                request,
                &pass.files,
                &pass.counts,
                cancel,
                report,
                started,
                checkpoint.as_deref(),
                Some(&token),
            );
        }
        if !pass.complete || cancel.load(Ordering::Acquire) || token.is_cancelled() {
            if token.is_cancelled() {
                cancel.store(true, Ordering::Release);
            }
            if checkpoint.is_some() && !cancel.load(Ordering::Acquire) {
                emit(
                    &json!({"event":"interrupted","reason":"The scan could not finish listing this scope. Check drive access, then resume; completed analysis is saved."}),
                )?;
                cancel.store(true, Ordering::Release);
            }
            return publish_resuming(
                request,
                &pass.files,
                &pass.counts,
                cancel,
                report,
                started,
                checkpoint.as_deref(),
                Some(&token),
            );
        }
        // Check before expensive comparison, and again after it. A scan is a
        // snapshot of the last completed metadata check, never a live watcher.
        let finish_report = |report: &mut ScanReport| {
            report.status = "finished".into();
            publish_resuming(
                request,
                &pass.files,
                &pass.counts,
                cancel,
                report,
                started,
                checkpoint.as_deref(),
                Some(&token),
            )
        };
        let mut current = match capture(&pass.files) {
            Err(_) if token.is_finishing() => return finish_report(report),
            value => value?,
        };
        let mut changes = inventory::changes(&pass.files, &current.files);
        if !changes.any() {
            if let Some(checkpoint) = &checkpoint {
                checkpoint.seal(&pass.files, &pass.counts, report)?;
            }
            report.files.clear();
            report.groups.clear();
            report.total_groups = 0;
            report.run_id = None;
            report.result_revision = None;
            report.scores_retained = 0;
            publish_resuming(
                request,
                &pass.files,
                &pass.counts,
                cancel,
                report,
                started,
                checkpoint.as_deref(),
                Some(&token),
            )?;
            if cancel.load(Ordering::Acquire) || token.is_cancelled() {
                return Ok(());
            }
            current = match capture(&pass.files) {
                Err(_) if token.is_finishing() => return Ok(()), // published completed analysis above
                value => value?,
            };
            changes = inventory::changes(&pass.files, &current.files);
            if !changes.any() {
                return Ok(());
            }
        }
        if let Some(checkpoint) = &checkpoint {
            checkpoint.invalidate_inventory()?;
        }
        changes.announce(current.files.len())?;
        if round == 8 {
            emit(
                &json!({"event":"interrupted", "reason":"Files are still changing. Completed analysis is saved; resume when the folder settles."}),
            )?;
            cancel.store(true, Ordering::Release);
            report.status = "paused".into();
            report.files.clear();
            report.groups.clear();
            report.run_id = None;
            report.result_revision = None;
            report.scores_retained = 0;
            report.total_groups = 0;
            report.coverage = "Files changed repeatedly before the scan could finish. Completed analysis is saved.".into();
            return Ok(());
        }
        snapshot = Some(current);
    }
    unreachable!()
}

#[allow(clippy::too_many_arguments)]
fn run_pass(
    request: &ScanRequest,
    temporary: &Path,
    cancel: &Arc<AtomicBool>,
    report: &mut ScanReport,
    started: Instant,
    client: Option<&Client>,
    runtime: &tokio::runtime::Handle,
    checkpoint: Option<Arc<checkpoint::Checkpoint>>,
    fetches: Arc<fetch::Fetches>,
    downloaded: Arc<std::sync::atomic::AtomicU64>,
    snapshot: Option<inventory::Snapshot>,
    acquisition_cancel: Arc<AtomicBool>,
) -> Result<Pass> {
    use std::cell::RefCell;
    let token = fetches.control.clone();
    let files = RefCell::new(Vec::<InputFile>::new());
    let mut engine_config = config(request, temporary);
    let mut governor = request.resources.automatic_memory.then(|| {
        engine_config.external_memory = Some(fetches.memory.usage.clone());
        auto_memory::Governor::new(
            !request.cloud_items.is_empty()
                || request.external_source_stream.is_some()
                || !request.external_sources.is_empty(),
            engine_config.workers,
        )
    });
    acceleration::select(request, &mut engine_config, checkpoint.as_deref(), cancel)?;
    let backend = engine_config.backend;
    let encoder = Encoder::new(engine_config)?;
    let base = RefCell::new(Counts {
        files_discovered: 0,
        files_total: None,
        ..Counts::default()
    });
    let report = RefCell::new(report);
    let mut cache = VectorCache::load(&request.data_dir);
    let source_cache = Arc::new(source_cache::SourceCache::open(&request.data_dir).context(
        "Could not open the saved analysis cache. Check available storage, then resume.",
    )?);
    let cache_path = temporary.join("reuse.json");
    let mut input = EncodeRequest::new(temporary);
    if cache.write(&cache_path).is_ok() {
        input.vectors_file = Some(cache_path);
    }
    let discovery = if let Some(snapshot) = snapshot {
        discovery::Discovery::from_snapshot(snapshot, token.clone())
    } else {
        discovery::start_controlled(
            request.clone(),
            client.cloned(),
            temporary.to_owned(),
            runtime.clone(),
            acquisition_cancel.clone(),
            (*report.borrow()).clone(),
            token.clone(),
        )?
    };
    let mut inventory_finished = false;
    let mut discovery_failed = false;
    let mut selected = HashSet::new();
    let sources = {
        let temporary = temporary.to_owned();
        let client = client.cloned();
        let runtime = runtime.clone();
        let downloaded = downloaded.clone();
        let fetches = fetches.clone();
        let checkpoint = checkpoint.clone();
        let source_cache = source_cache.clone();
        let families = request.families.clone();
        let has_cloud = !request.cloud_items.is_empty();
        let remote = has_cloud
            || request.external_source_stream.is_some()
            || !request.external_sources.is_empty();
        // Metadata/RAM waiters do not tie up the transport pool. A bounded
        // lookahead lets smaller originals fit while larger ones wait for RAM.
        let producers = if has_cloud {
            (fetches.limit * 2).max(if request.external_source_stream.is_some() { NATIVE_PREPARERS } else { 1 })
        } else if remote {
            NATIVE_PREPARERS
        } else {
            1
        };
        // Every PikPak original owns a byte reservation. Let that reservation
        // bound the ready queue, independent of worker or connection counts.
        // Path-only sources retain a small metadata queue without pre-reading.
        let ready_limit = if has_cloud {
            READY_QUEUE_CAPACITY
        } else {
            request.resources.effective_workers()
        };
        prefetch::start(
            discovery,
            acquisition_cancel.clone(),
            producers,
            ready_limit,
            move |file, stop| {
                control::wait_blocking(&fetches.control, stop)?;
                if let Some(record) = checkpoint
                    .as_ref()
                    .map(|c| c.reused(file))
                    .transpose()?
                    .flatten()
                {
                    if !file.is_photos_preview() {
                        file.display.bytes = record.bytes.unwrap_or(file.display.bytes);
                    }
                    return Ok(ResolvedInput::Reused(record));
                }
                let preview_families = vec!["image".to_owned()];
                let reuse_families = if file.is_photos_preview() {
                    &preview_families
                } else {
                    &families
                };
                if let Ok(Some(record)) = source_cache.reused(file, backend, reuse_families) {
                    if !file.is_photos_preview() {
                        file.display.bytes = record.bytes.unwrap_or(file.display.bytes);
                    }
                    return Ok(ResolvedInput::Cached(record));
                }
                if families.iter().any(|family| matches!(family.as_str(), "audio" | "video")) {
                    if let (Some(item), Some(client)) = (file.cloud.as_ref(), client.as_ref()) {
                        if let Some((original, revision)) = runtime.block_on(fetch::prepare_seekable(
                            client, item, stop, fetches.clone(), runtime.clone(), downloaded.clone(),
                        ))? {
                            let item = file.cloud.as_mut().unwrap();
                            item.revision = revision;
                            item.size = original.len();
                            file.display.bytes = item.size;
                            return Ok(ResolvedInput::Seekable(original));
                        }
                    }
                }
                let mut attempt = 0u32;
                loop {
                    let result = resolve_input(
                        file,
                        &temporary,
                        stop,
                        client.as_ref(),
                        &runtime,
                        &downloaded,
                        &fetches,
                    );
                    if !fetches.retry_forever
                        || !result
                            .as_ref()
                            .err()
                            .is_some_and(|e| e.is::<RetryableProvider>())
                    {
                        if attempt > 0 {
                            let _ = emit(&json!({"event":"network_wait","waiting":false}));
                        }
                        break result;
                    }
                    // Each attempt owns a fresh pipe/buffer. Partial Photos
                    // bytes must never be appended to the next original.
                    let delay = (500u64 * (1 << attempt.min(6))).min(30_000);
                    let _ = emit(
                        &json!({"event":"network_wait","waiting":true,"retry_seconds":delay / 1000}),
                    );
                    let until = Instant::now() + Duration::from_millis(delay);
                    while Instant::now() < until {
                        check_cancel(stop)?;
                        std::thread::sleep(Duration::from_millis(25));
                    }
                    attempt = attempt.saturating_add(1);
                }
            },
        )
    };
    emit(&progress(
        &base.borrow(),
        &report.borrow(),
        "analysing",
        started.elapsed().as_secs_f64(),
    ))?;
    // One invocation keeps native workers/models alive. Acquisition fills a
    // bounded RAM queue independently; FileTwin only pulls completed sources.
    let result = encoder.encode_stream_observed(&input, &token, || {
        loop {
            if token.is_finishing() { return Ok(filetwin_core::api::EncodeSourcePoll::Pending); }
            if cancel.load(Ordering::Acquire) {
                token.cancel();
                return Err(filetwin_core::Error::new(filetwin_core::ErrorCode::Cancelled, "input", "Scan cancelled"));
            }
            if inventory_finished { return Ok(filetwin_core::api::EncodeSourcePoll::Complete); }
            let next = match sources.poll() {
                Err(_) if token.is_finishing() => return Ok(filetwin_core::api::EncodeSourcePoll::Pending),
                value => value.map_err(|_| filetwin_core::Error::new(filetwin_core::ErrorCode::IoError, "discovery", "Original acquisition stopped unexpectedly"))?,
            };
            let prepared = match next {
                Some(prefetch::Event::File(prepared)) => prepared,
                Some(prefetch::Event::Finished(inventory)) => {
                    inventory_finished = true;
                    discovery_failed = inventory.failed_files > 0;
                    let mut report = report.borrow_mut();
                    report.scanned_files = inventory.scanned_files;
                    report.skipped_files += inventory.skipped_files;
                    report.unsupported_files += inventory.unsupported_files;
                    report.failed_files += inventory.failed_files;
                    report.issue_summary.extend(inventory.issue_summary);
                    let remaining = MAX_ISSUES.saturating_sub(report.issues.len());
                    report.issues.extend(inventory.issues.into_iter().take(remaining));
                    report.truncated |= inventory.truncated;
                    continue;
                }
                None => return Ok(filetwin_core::api::EncodeSourcePoll::Pending),
            };
            let mut file = prepared.file;
            let mut files = files.borrow_mut();
            let i = files.len();
            file.display.engine_index = Some(i as u64);
            files.push(file);
            { let mut base = base.borrow_mut(); sync_discovery(&mut base, &sources.discovery); }
            let file = &mut files[i];
            let extension = if file.is_photos_preview() { "jpg".to_owned() } else { safe_extension(&file.display.name) };
            let key = format!("{i:08}.{extension}");
            let source = match prepared.result {
                Ok(resolved @ (ResolvedInput::Reused(_) | ResolvedInput::Cached(_) | ResolvedInput::Excluded(_))) => {
                    let already_cached = matches!(&resolved, ResolvedInput::Cached(_));
                    let record = match resolved {
                        ResolvedInput::Reused(record) | ResolvedInput::Cached(record) | ResolvedInput::Excluded(record) => record,
                        _ => unreachable!(),
                    };
                    // Keep this scan independently resumable even if another
                    // saved scan is cleared after providing a cached vector.
                    if !already_cached {
                        source_cache.completed(file, &record).map_err(|_| filetwin_core::Error::new(
                            filetwin_core::ErrorCode::IoError,"checkpoint","Could not cache reused analysis. Check available storage, then resume."))?;
                    }
                    if let Some(checkpoint) = &checkpoint {
                        checkpoint.completed(file, &record).map_err(|_| filetwin_core::Error::new(
                            filetwin_core::ErrorCode::IoError,"checkpoint","Could not save reused analysis."))?;
                    }
                    file.display.family = record.family.clone().unwrap_or_else(|| "other".into());
                    let ready = record.state == FileState::Ready;
                    file.display.state = if ready { "ready" } else { "excluded" }.into();
                    if let Some(bytes) = record.bytes { if !file.is_photos_preview() { file.display.bytes = bytes; } }
                    if !ready {
                        scope::classified_issue(&mut report.borrow_mut(), &file.display.path,
                            &error_reason(record.error.as_ref()), "unsupported");
                    }
                    let mut counts = base.borrow_mut();
                    counts.files_processed += 1; counts.cache_hits += u64::from(record.reused);
                    if ready { counts.files_ready += 1; } else { counts.files_skipped += 1; }
                    file.record = Some(record);
                    continue;
                }
                Ok(ResolvedInput::Memory(data)) => filetwin_core::api::EncodeSource::from_memory(key, data),
                Ok(ResolvedInput::Seekable(data)) => filetwin_core::api::EncodeSource::from_seekable(key, data),
                Ok(ResolvedInput::Path(lease)) => {
                    let mut source = filetwin_core::api::EncodeSource::new(key, file.path.clone());
                    if let Some(lease) = lease { source = source.retaining(lease); }
                    source
                }
                // Preserve a per-file diagnostic in FileTwin's normal result
                // path; this resolver reports an already-completed failure.
                Err(error) => filetwin_core::api::EncodeSource::deferred(key,
                    move |stop| Err(fetching_error(&error, stop.is_cancelled()))),
            }.with_families(if file.is_photos_preview() { vec!["image".into()] } else { request.families.clone() });
            selected.insert(i);
            return Ok(filetwin_core::api::EncodeSourcePoll::Ready(source));
        }
    }, |update| {
        { let mut base = base.borrow_mut(); sync_discovery(&mut base, &sources.discovery); }
        report.borrow_mut().downloaded_bytes = downloaded.load(Ordering::Relaxed);
        if cancel.load(Ordering::Acquire) { token.cancel(); }
        if let (Some(governor), Some(work)) = (&mut governor, &update.work) {
            governor.update(work, &fetches.memory, &token);
        }
        let mut event = encoding_progress(&base.borrow(), update, &report.borrow(), started.elapsed().as_secs_f64(), &fetches, &sources.state);
        if let Some(governor) = &governor { governor.annotate(&mut event); }
        if let Some(checkpoint) = &checkpoint { event["session_statistics"] = checkpoint.statistics(); }
        if emit(&event).is_err() {
            token.cancel();
        }
    }, |record| {
        let i = record.path.to_path_buf()?.file_stem().and_then(|s| s.to_str()).and_then(|s| s.parse::<usize>().ok())
            .ok_or_else(|| filetwin_core::Error::invalid("Invalid checkpoint file key"))?;
        if let Some(checkpoint) = &checkpoint {
            checkpoint.completed(&files.borrow()[i], record).map_err(|_| filetwin_core::Error::new(
                filetwin_core::ErrorCode::IoError,"checkpoint","Could not save completed work. Check available storage, then resume."))?;
        }
        source_cache.completed(&files.borrow()[i], record).map_err(|_| filetwin_core::Error::new(
            filetwin_core::ErrorCode::IoError,"checkpoint","Could not cache completed analysis. Check available storage, then resume."))?;
        Ok(())
    });
    let mut files = files.into_inner();
    let report = report.into_inner();
    report.downloaded_bytes = downloaded.load(Ordering::Relaxed);
    report.scanned_files = sources.discovery.found.load(Ordering::Acquire);
    let mut counts = base.into_inner();
    sync_discovery(&mut counts, &sources.discovery);
    drop(sources); // Cancel/join acquisition and release queued originals before publishing results.
    let complete_encoding = result
        .as_ref()
        .is_ok_and(|bundle| bundle.complete && !bundle.summary.cancelled);
    match result {
        Ok(bundle) => {
            counts.bytes_read += bundle.summary.counts.bytes_read;
            counts.bytes_hashed += bundle.summary.counts.bytes_hashed;
            counts.cache_hits += bundle.summary.counts.cache_hits;
            counts.vectors_encoded += bundle.summary.counts.vectors_encoded;
            for mut record in bundle.files {
                let path = record.path.to_path_buf()?;
                let i: usize = path
                    .file_stem()
                    .and_then(|n| n.to_str())
                    .context("Invalid encoded file path")?
                    .parse()?;
                if !selected.remove(&i) {
                    bail!("FileTwin returned a file outside the selected scope.");
                }
                let file = &mut files[i];
                counts.files_processed += 1;
                if let Some(bytes) = record.bytes {
                    if !file.is_photos_preview() {
                        file.display.bytes = bytes;
                    }
                }
                // The core verifies each original before it releases its lease.
                // Completed cloud/Photos originals have already been removed.
                file.display.family = record.family.clone().unwrap_or_else(|| "other".into());
                file.display.state = match record.state {
                    FileState::Ready => "ready",
                    FileState::Skipped | FileState::Unsupported => "excluded",
                    _ => "failed",
                }
                .into();
                if record.state == FileState::Ready {
                    counts.files_ready += 1;
                    cache.add(&record);
                } else {
                    if matches!(record.state, FileState::Skipped | FileState::Unsupported) {
                        counts.files_skipped += 1;
                    } else {
                        counts.files_failed += 1;
                    }
                    scope::classified_issue(
                        report,
                        &file.display.path,
                        &error_reason(record.error.as_ref()),
                        if matches!(record.state, FileState::Skipped | FileState::Unsupported) {
                            "unsupported"
                        } else {
                            "failed"
                        },
                    );
                }
                record.path = FilePath::Utf8(file.display.id.clone());
                file.record = Some(record);
            }
            if bundle.summary.cancelled {
                token.cancel();
            }
        }
        Err(_) if token.is_cancelled() || cancel.load(Ordering::Acquire) => {}
        Err(_) if checkpoint.is_some() => {
            // Preserve the per-file journal when the engine or checkpoint
            // writer stops; do not seal an incomplete inventory as finished.
            bail!("Analysis was interrupted. Completed files were saved; resume the scan to continue.");
        }
        Err(_) => {
            issue(report, "Scan", "Analysis stopped unexpectedly. Check the installed analysis components and available disk space, then retry.");
            for file in files.iter_mut().filter(|f| f.display.state == "pending") {
                file.display.state = "failed".into();
                counts.files_failed += 1;
                counts.files_processed += 1;
                issue(report, &file.display.path, "Analysis could not finish. Check the installed analysis components and available disk space, then retry.");
            }
        }
    }
    if token.is_cancelled() || cancel.load(Ordering::Acquire) {
        report.status = "cancelled".into();
    }
    report.analysed_files = counts.files_ready;
    for file in &files {
        if let Some(record) = &file.record {
            cache.add(record);
        }
    }
    let complete = report.status != "cancelled"
        && inventory_finished
        && !discovery_failed
        && complete_encoding;
    let _ = cache.save();
    Ok(Pass {
        files,
        counts,
        complete,
    })
}

pub(super) fn fetching_error(error: &anyhow::Error, cancelled: bool) -> filetwin_core::Error {
    use filetwin_core::{Error, ErrorCode};
    if cancelled {
        return Error::new(ErrorCode::Cancelled, "fetching", "Scan cancelled");
    }
    if error.is::<memory::Limit>() {
        return Error::new(
            ErrorCode::ResourceBudgetTooSmall,
            "memory",
            memory::Limit.to_string(),
        );
    }
    if let Some(failure) = error.downcast_ref::<fetch::Failure>() {
        let mut result = Error::new(
            ErrorCode::IoError,
            "fetching",
            "Could not fetch the original",
        );
        result.details = Box::new(
            json!({"fetch_kind":failure.kind,"http_status":failure.status,
            "operation":failure.operation,"attempts":failure.attempts}),
        );
        return result;
    }
    let mut kind = "unavailable";
    let mut status = None;
    for cause in error.chain() {
        if let Some(crate::Error::Api { status: code, .. }) = cause.downcast_ref::<crate::Error>() {
            status = Some(*code);
            kind = "http";
        }
        if let Some(http) = cause.downcast_ref::<reqwest::Error>() {
            if let Some(code) = http.status() {
                status = Some(code.as_u16());
                kind = "http";
            } else if http.is_timeout() {
                kind = "timeout";
            } else if http.is_connect() {
                kind = "connection";
            } else if http.is_body() {
                kind = "incomplete";
            } else if http.is_builder() {
                kind = "invalid_link";
            } else {
                kind = "network";
            }
        }
        if cause.is::<tokio::time::error::Elapsed>() {
            kind = "timeout";
        }
        if let Some(io) = cause.downcast_ref::<std::io::Error>() {
            match io.raw_os_error() {
                Some(23 | 24) => kind = "open_file_limit",
                Some(28) => kind = "disk_full",
                _ => match io.kind() {
                    std::io::ErrorKind::PermissionDenied => kind = "permission",
                    std::io::ErrorKind::NotFound => kind = "missing_file",
                    _ => {}
                },
            }
        }
    }
    let mut result = Error::new(
        ErrorCode::IoError,
        "fetching",
        "Could not fetch the original",
    );
    result.details = Box::new(json!({"fetch_kind":kind,"http_status":status}));
    result
}

pub(super) fn error_reason(error: Option<&filetwin_core::Error>) -> String {
    if error.is_some_and(|error| {
        error.code == filetwin_core::ErrorCode::UnsupportedFormat && error.stage == "password"
    }) {
        return "Password-protected file skipped. Its contents cannot be analysed without a password.".into();
    }
    use filetwin_core::ErrorCode::*;
    if error.is_some_and(|error| error.code == ResourceBudgetTooSmall && error.details["retry_after_drain"].as_bool() == Some(true)) {
        return "Other retained originals prevented this decoder retry. Retry this file after the rest of the scan finishes.".into();
    }
    if let Some(error) = error.filter(|e| e.stage == "fetching") {
        let reason = match error.details["fetch_kind"].as_str() {
            Some("open_file_limit") => Some("The scan reached this process's open-file limit while fetching originals."),
            Some("disk_full") => Some("There is not enough free disk space for the temporary original."),
            Some("memory_limit") => Some("This original cannot fit in available system memory. No disk copy was created."),
            Some("permission") => Some("The app does not have permission to read or save this original."),
            Some("authentication") => Some("PikPak could not authenticate the original download. Check login status in Settings → Accounts."),
            Some("guest_unavailable") => Some("Guest Mode could not access or verify this file's original public share. Use an available share or choose User or Dynamic mode in the sidebar."),
            Some("missing_file") => Some("The original or its temporary download is no longer available."),
            Some("invalid_link") => Some("PikPak did not return a usable original download link."),
            Some("timeout") => Some("Fetching this original timed out."),
            Some("connection") => Some("The connection to the drive could not be established."),
            Some("incomplete") => Some("The connection ended before the original finished downloading."),
            Some("network") => Some("A network error interrupted fetching this original."),
            _ => None,
        };
        if let Some(reason) = reason {
            return reason.into();
        }
        if let Some(status) = error.details["http_status"].as_u64() {
            return match status {
                429 => "PikPak limited the download requests (HTTP 429).".into(),
                401 => "PikPak rejected authentication for this original (HTTP 401). Check login status.".into(),
                403 => "PikPak refused this original download (HTTP 403).".into(),
                404 => "This original is no longer available from PikPak (HTTP 404).".into(),
                _ => format!("The drive returned HTTP {status} while fetching this original."),
            };
        }
        return "Could not fetch the original into memory. Check drive access and connection, then retry.".into();
    }
    if error.is_some_and(|e| {
        e.code == InsufficientContent && e.stage == "media" && e.message.contains("duration")
    }) {
        return "The video or audio file has no valid duration. FileTwin cannot sample its timeline; exact-copy matching is still available.".into();
    }
    match error.map(|e|e.code) {
        Some(RuntimeUnavailable|ModelIntegrity)=>"A required analysis component is missing or damaged. Rebuild the app with the verified FileTwin assets.",
        Some(SourceChanged)=>"This file changed during the scan. Run the scan again when changes have finished.",
        Some(WorkerTimeout)=>"Analysis of this file exceeded its time limit.",
        Some(UnsupportedFormat)=>"This file format is not supported for content similarity. Identical-content evidence is retained when available.",
        Some(InvalidText)=>"This is not supported UTF-8 text. Binary, encrypted and other text encodings can still be checked for identical copies.",
        Some(InsufficientContent)=>"No comparable content was found. Exact-copy matching is still available.",
        Some(UnselectedFamily)=>"Content type excluded from similarity analysis.",
        Some(DecodeFailed)=>"The file could not be decoded. It may be damaged or use an unsupported encoding; exact-copy matching is still available.",
        Some(WorkerFailed)=>"The analysis worker could not finish this file. Retry the scan; its exact-copy hash is retained when available.",
        Some(ResourceBudgetTooSmall)=>"This file and its decoder cannot fit in available system RAM. Originals are never spilled to disk.",
        _=>"The file could not be analysed. Check file access and the analysis components, then retry.",
    }.into()
}

#[cfg(test)]
fn publish(
    request: &ScanRequest,
    files: &[InputFile],
    counts: &Counts,
    cancel: &AtomicBool,
    report: &mut ScanReport,
    started: Instant,
) -> Result<()> {
    publish_resuming(request, files, counts, cancel, report, started, None, None)
}

/// A full original can prove both its SHA256 and its provider GCID. Join those
/// verified identities before grouping, so a native SHA copy also matches a
/// cloud original, including another sparse original with that same GCID.
/// A sparse original contributes only its GCID; it never invents a full hash.
fn exact_evidence(files: &[InputFile]) -> Vec<Option<String>> {
    fn representative(parents: &std::collections::BTreeMap<String, String>, id: &str) -> String {
        let mut current = id;
        while let Some(parent) = parents.get(current) {
            if parent == current { break; }
            current = parent;
        }
        current.to_owned()
    }
    let identities: Vec<_> = files.iter().map(InputFile::exact_identity).collect();
    let mut parents = std::collections::BTreeMap::<String, String>::new();
    for (file, identity) in files.iter().zip(&identities) {
        let Some(identity) = identity else { continue; };
        parents.entry(identity.clone()).or_insert_with(|| identity.clone());
        let Some(sha) = file.record.as_ref().and_then(|record| record.file_id.as_ref())
            .filter(|id| id.starts_with("sha256:")) else { continue; };
        parents.entry(sha.clone()).or_insert_with(|| sha.clone());
        let first = representative(&parents, identity);
        let second = representative(&parents, sha);
        if first != second {
            let (root, child) = if first < second { (first, second) } else { (second, first) };
            parents.insert(child, root);
        }
    }
    identities.into_iter().map(|identity| identity.map(|id| representative(&parents, &id))).collect()
}

fn publish_resuming(
    request: &ScanRequest,
    files: &[InputFile],
    counts: &Counts,
    cancel: &AtomicBool,
    report: &mut ScanReport,
    started: Instant,
    checkpoint: Option<&checkpoint::Checkpoint>,
    token: Option<&CancellationToken>,
) -> Result<()> {
    // Pausing during analysis leaves the incremental file journal intact;
    // there is no need to build a partial matrix that will immediately change.
    if cancel.load(Ordering::Acquire) && checkpoint.is_some() {
        report.files = files.iter().map(|f| f.display.clone()).collect();
        report.status = "paused".into();
        return Ok(());
    }
    let writer = if let Some(checkpoint) = checkpoint {
        store::MatrixWriter::resume(&request.data_dir, &checkpoint.comparison_directory()?)?
    } else {
        store::MatrixWriter::new(&request.data_dir)?
    };
    let mut profiles = std::collections::BTreeMap::<&str, Vec<(usize, &FileRecord)>>::new();
    let mut hashes = std::collections::BTreeMap::<String, Vec<MatchedFile>>::new();
    let exact_identities = exact_evidence(files);
    let mut inventory_bytes = 0;
    for (i, file) in files.iter().enumerate() {
        if let Some(token) = token {
            if token.is_paused() {
                writer.checkpoint()?;
                let _ = control::wait_blocking(token, cancel);
            }
        }
        // A preview digest identifies the JPEG representation, never the
        // original asset. Persist no digest so later regrouping is safe too.
        let preview_record = file
            .record
            .as_ref()
            .filter(|_| file.is_photos_preview())
            .map(|record| {
                let mut record = record.clone();
                record.file_id = None;
                record
            });
        let exact_identity=exact_identities[i].clone();
        writer.file_with_digest(
            i,
            &file.display,
            preview_record.as_ref().or(file.record.as_ref()),
            exact_identity.as_deref(),
        )?;
        let bytes = serde_json::to_vec(&file.display)?.len();
        if inventory_bytes + bytes < 40 * 1024 * 1024 {
            inventory_bytes += bytes;
            report.files.push(file.display.clone());
            if let Some(id) = exact_identity.filter(|_|request.exact_duplicates) {
                hashes.entry(id).or_default().push(file.display.clone());
            }
        } else {
            report.truncated = true;
        }
        if let Some(record) = &file.record {
            if record.state == FileState::Ready && record.vector.is_some() {
                if let Some(profile) = record.profile_id.as_deref() {
                    profiles.entry(profile).or_default().push((i, record));
                }
            }
        }
    }
    let profiles = comparison::profiles(&profiles)?;
    let prepared = if checkpoint.is_some() {
        writer.prepare_controlled(&profiles,cancel,token)
    } else { writer.prepare(&profiles) };
    if let Err(error) = prepared {
        if checkpoint.is_some() && cancel.load(Ordering::Acquire) {
            // An interrupted old-format upgrade rolls back as one transaction;
            // its previously committed comparisons remain available to resume.
            report.status = "paused".into();
            return Ok(());
        }
        return Err(error);
    }
    let previously_compared = writer.saved_scores()?;
    let total = comparison::total(&profiles)?;
    let comparison = |count: u64, stage: &str| {
        let mut event = progress(counts, report, stage, started.elapsed().as_secs_f64());
        if let Some(checkpoint) = checkpoint {
            event["session_statistics"] = checkpoint.statistics();
        }
        event["completed"] = count.into();
        event["total"] = total.into();
        event["counts"]["pairs_processed"] = count.into();
        event["counts"]["pairs_total"] = total.into();
        event["counts"]["pairs_compared"] = count.into();
        event["counts"]["scores_retained"] = count.into();
        event["counts"]["comparison_limit"] = Value::Null;
        event["counts"]["comparisons_remaining"] = total.saturating_sub(count).into();
        event
    };
    emit(&comparison(previously_compared, "comparison"))?;
    let compared = if report.status == "cancelled" {
        previously_compared
    } else {
        comparison::run(
            &profiles,
            &writer,
            previously_compared,
            request.resources.effective_workers(),
            cancel,
            token,
            |count| emit(&comparison(count, "comparison")),
        )?
    };
    let terminal = comparison(compared, "finishing");
    writer.checkpoint()?;
    if cancel.load(Ordering::Acquire) && checkpoint.is_some() {
        report.status = "paused".into();
        report.scores_retained = compared;
        return Ok(());
    }
    emit(&terminal)?;
    if compared < total && !cancel.load(Ordering::Acquire) && report.status != "cancelled" {
        bail!("Similarity comparison stopped before all compatible pairs were saved.");
    }
    report.scores_retained = compared;
    report.run_id = Some(writer.id.clone());
    report.result_revision = Some(1);
    report.coverage = format!(
        "{} of {} files analysed. {} of {} compatible comparisons saved.{}",
        counts.files_ready,
        report.scanned_files.max(files.len() as u64),
        compared,
        total,
        if cancel.load(Ordering::Acquire) || report.status == "cancelled" {
            " The scan was cancelled; these results are incomplete."
        } else {
            ""
        }
    );
    if report.status == "finished" {
        report.coverage.push_str(" Finished early at your request. This report covers completed analysis; resume to check the remaining files.");
    }
    if files.iter().any(InputFile::is_photos_preview) {
        report.coverage.push_str(" Apple Photos Fast Previews compares photo previews and video poster thumbnails. Matches describe appearance, not byte-identical originals or whole-video content.");
    }
    let mut members = 0;
    for (hash, group) in hashes.into_iter().filter(|(_, f)| f.len() > 1) {
        report.total_groups += 1;
        if report.groups.len() >= MAX_GROUPS || members + group.len() > MAX_MEMBERS {
            report.truncated = true;
            continue;
        }
        members += group.len();
        report.groups.push(MatchGroup {
            id: hash.into(),
            match_kind: "byte_identical".into(),
            family: "other".into(),
            minimum_score: None,
            member_count: group.len() as u64,
            members: group,
        });
    }
    writer.publish(&json!({"engine":"FileTwin 0.2","workers":request.resources.effective_workers(),"resources":request.resources,"counts":terminal["counts"],"coverage":report.coverage,
        "unsupported_files":report.unsupported_files,"failed_files":report.failed_files,"issue_summary":report.issue_summary}))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn report() -> ScanReport {
        ScanReport {
            source: ScanSource::Local,
            scope: vec![],
            status: "cancelled".into(),
            threshold: 0.9,
            scanned_files: 0,
            analysed_files: 0,
            skipped_files: 0,
            unsupported_files: 0,
            failed_files: 0,
            issue_summary: vec![],
            downloaded_bytes: 0,
            total_groups: 0,
            groups: vec![],
            issues: vec![],
            truncated: false,
            coverage: String::new(),
            elapsed_seconds: 0.0,
            files: vec![],
            run_id: None,
            result_revision: None,
            scores_retained: 0,
        }
    }
    #[test]
    fn observed_encoding_commits_each_file_before_cancellation() {
        let dir = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(dir.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        std::fs::create_dir_all(&request.local_paths[0]).unwrap();
        std::fs::write(
            request.local_paths[0].join("one.txt"),
            "A garden with flowers and trees. ".repeat(20),
        )
        .unwrap();
        let mut output = report();
        let files = scope::inventory(
            &request,
            &StagedCloud::new(),
            &AtomicBool::new(false),
            &mut output,
        )
        .unwrap();
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let encoder = Encoder::new(config(&request, dir.path())).unwrap();
        let cancel = CancellationToken::default();
        let mut sent = false;
        let mut completed = 0;
        let result = encoder.encode_stream_observed(
            &EncodeRequest::new(&request.local_paths[0]),
            &cancel,
            || {
                if sent {
                    return Ok(filetwin_core::api::EncodeSourcePoll::Complete);
                }
                sent = true;
                Ok(filetwin_core::api::EncodeSourcePoll::Ready(
                    filetwin_core::api::EncodeSource::new("0.txt", files[0].path.clone()),
                ))
            },
            |_| {},
            |record| {
                checkpoint.completed(&files[0], record).unwrap();
                completed += 1;
                cancel.cancel();
                Ok(())
            },
        );
        assert_eq!(completed, 1);
        assert!(result.unwrap().summary.cancelled);
        drop(checkpoint);
        assert!(checkpoint::Checkpoint::open(&request)
            .unwrap()
            .unwrap()
            .reused(&files[0])
            .unwrap()
            .is_some());
    }

    #[test]
    fn identical_preview_bytes_never_publish_original_digests() {
        let dir = tempfile::tempdir().unwrap();
        let request = super::super::tests::request(dir.path());
        let mut result = report();
        result.status = "completed".into();
        let files: Vec<_> = ["photo.jpg", "video.mov"]
            .iter()
            .enumerate()
            .map(|(i, name)| {
                let mut file = InputFile::external(ExternalSource {
                    provider: None,
                    id: format!("asset:{i}"),
                    name: (*name).into(),
                    path: format!("Photos/{name}"),
                    size: 50_000,
                    local_path: None,
                    revision: Some("revision".into()),
                    content_kind: Some(ExternalContentKind::PhotosPreview),
                });
                file.display.state = "ready".into();
                file.display.family = "image".into();
                file.record = Some(FileRecord {
                    path: filetwin_core::api::FilePath::Utf8("preview.jpg".into()),
                    file_id: Some(format!("sha256:{:064x}", 1)),
                    bytes: Some(123),
                    state: FileState::Ready,
                    family: Some("image".into()),
                    profile_id: None,
                    vector: None,
                    vector_sha256: None,
                    reused: false,
                    error: None,
                    extraction: None,
                });
                file
            })
            .collect();
        publish(
            &request,
            &files,
            &Counts {
                files_ready: 2,
                ..Counts::default()
            },
            &AtomicBool::new(false),
            &mut result,
            Instant::now(),
        )
        .unwrap();
        assert!(result.groups.is_empty());
        assert_eq!(result.files[1].name, "video.mov");
        assert_eq!(result.files[1].bytes, 50_000);
        assert!(result.coverage.contains("video poster thumbnails"));
        let saved = store::SavedMatrix::open(&request.data_dir, result.run_id.as_ref().unwrap(), 1)
            .unwrap();
        assert!(
            saved.files.iter().all(|file| file.digest.is_none()),
            "Regrouping must not regain preview hashes"
        );
    }

    #[test]
    fn cancelled_encoding_keeps_analysed_and_pending_inventory_without_fake_scores() {
        let dir = tempfile::tempdir().unwrap();
        let request = super::super::tests::request(dir.path());
        std::fs::create_dir_all(&request.local_paths[0]).unwrap();
        for name in ["a.txt", "b.txt", "c.txt"] {
            std::fs::write(
                request.local_paths[0].join(name),
                "A garden with flowers and trees. ".repeat(20),
            )
            .unwrap();
        }
        let cancel = AtomicBool::new(false);
        let mut result = report();
        let mut files =
            scope::inventory(&request, &StagedCloud::new(), &cancel, &mut result).unwrap();
        // The encoder can return completed records even if the user cancelled
        // before the app's comparison phase. Keep every occurrence in the tree.
        let encoder = Encoder::new(config(&request, dir.path())).unwrap();
        let mut sources = files.iter().map(|f| {
            filetwin_core::api::EncodeSource::new(f.path.file_name().unwrap(), f.path.clone())
        });
        let bundle = encoder
            .encode_sources(
                &EncodeRequest::new(&request.local_paths[0]),
                &CancellationToken::default(),
                || Ok(sources.next()),
                |_| {},
            )
            .unwrap();
        for file in files.iter_mut().take(2) {
            let record = bundle
                .files
                .iter()
                .find(|r| r.path.to_path_buf().unwrap().file_name() == file.path.file_name())
                .unwrap()
                .clone();
            file.display.state = "ready".into();
            file.display.family = "text".into();
            file.record = Some(record);
        }
        cancel.store(true, Ordering::Release);
        let counts = Counts {
            files_discovered: 3,
            files_total: Some(3),
            files_processed: 2,
            files_ready: 2,
            ..Counts::default()
        };
        publish(
            &request,
            &files,
            &counts,
            &cancel,
            &mut result,
            Instant::now(),
        )
        .unwrap();
        assert_eq!(result.files.len(), 3);
        assert_eq!(
            result.files.iter().filter(|f| f.state == "pending").count(),
            1
        );
        assert_eq!(result.groups[0].members.len(), 2);
        assert_eq!(result.scores_retained, 0);
        assert!(result.coverage.contains("cancelled"));
        let reference = result.files.iter().find(|f| f.state == "ready").unwrap();
        let row = score_row(
            ScoreRowRequest {
                data_dir: request.data_dir,
                run_id: result.run_id.unwrap(),
                result_revision: 1,
                file_id: reference.id.clone(),
                row_offset: reference.engine_index.unwrap(),
            },
            &AtomicBool::new(false),
        )
        .unwrap();
        assert!(row["entries"].as_array().unwrap().is_empty());
        assert_eq!(row["unavailable"]["not_computed"], 1);
        assert_eq!(row["unavailable"]["file_unavailable"], 1);
    }
    #[test]
    fn resumed_files_are_not_counted_as_waiting_downloads() {
        let base = Counts {
            files_discovered: 5,
            files_processed: 5,
            files_ready: 5,
            cache_hits: 5,
            ..Counts::default()
        };
        let update = Progress {
            work: Some(filetwin_core::api::WorkCounts::default()),
            stage: filetwin_core::api::Stage::Encoding,
            counts: Counts::default(),
            elapsed_seconds: 1.0,
        };
        let event = encoding_progress(
            &base,
            &update,
            &report(),
            1.0,
            &fetch::Fetches::new(2),
            &prefetch::State::default(),
        );
        assert_eq!(event["completed"], 5);
        assert_eq!(event["work"]["waiting_download"], 0);
        assert_eq!(event["counts"]["cache_hits"], 5);
    }

    #[test]
    fn cached_unsupported_results_are_not_reported_as_failed_downloads() {
        let base = Counts {
            files_processed: 2,
            files_skipped: 2,
            cache_hits: 2,
            ..Counts::default()
        };
        let update = Progress {
            stage: filetwin_core::api::Stage::Encoding,
            counts: Counts::default(),
            work: None,
            elapsed_seconds: 1.0,
        };
        let mut report = report();
        for _ in 0..2 {
            scope::classified_issue(
                &mut report,
                "archive.7z",
                "Unsupported content",
                "unsupported",
            );
        }
        let event = encoding_progress(
            &base,
            &update,
            &report,
            1.0,
            &fetch::Fetches::new(2),
            &prefetch::State::default(),
        );
        assert_eq!(event["counts"]["files_skipped"], 2);
        assert_eq!(event["counts"]["files_ready"], 0);
        assert_eq!(event["counts"]["files_failed"], 0);
        assert_eq!(
            event["skipped"], 0,
            "The UI adds this field to failed files"
        );
        assert_eq!(event["completed"], 2);
    }

    #[test]
    fn progress_adds_batch_work_without_resetting_totals_or_exposing_paths() {
        let base = Counts {
            files_discovered: 10,
            files_total: Some(10),
            files_processed: 4,
            files_ready: 3,
            ..Counts::default()
        };
        let update = Progress {
            work: None,
            stage: filetwin_core::api::Stage::Encoding,
            counts: Counts {
                files_discovered: 2,
                files_total: Some(2),
                files_processed: 2,
                files_ready: 2,
                vectors_encoded: 1,
                cache_hits: 1,
                ..Counts::default()
            },
            elapsed_seconds: 1.0,
        };
        let event = encoding_progress(
            &base,
            &update,
            &report(),
            5.0,
            &fetch::Fetches::new(2),
            &prefetch::State::default(),
        );
        assert_eq!(event["completed"], 6);
        assert_eq!(event["total"], 10);
        assert_eq!(event["counts"]["files_ready"], 5);
        assert_eq!(event["counts"]["cache_hits"], 1);
        assert_eq!(event["counts"]["vectors_encoded"], 1);
        assert!(event.get("current_file").is_none());
    }

    #[test]
    fn cloud_progress_does_not_count_download_or_ram_waits_as_analysis_workers() {
        let mut report = report();
        report.source = ScanSource::Cloud;
        let fetches = fetch::Fetches::new(52);
        fetches.active.store(4, Ordering::Relaxed);
        fetches.metadata.store(1, Ordering::Relaxed);
        fetches.retrying.store(1, Ordering::Relaxed);
        fetches.memory.waiting.store(2, Ordering::Relaxed);
        let sources = prefetch::State::default();
        sources.resolving.store(8, Ordering::Relaxed);
        sources.ready.store(10, Ordering::Relaxed);
        let update = Progress {
            stage: filetwin_core::api::Stage::Encoding,
            counts: Counts {
                files_discovered: 20,
                files_processed: 14,
                ..Default::default()
            },
            elapsed_seconds: 1.0,
            work: Some(filetwin_core::api::WorkCounts {
                reading: 2,
                encoding: 2,
                ready: 2,
                waiting_memory: 2,
                worker_limit: 52,
                ..Default::default()
            }),
        };
        let event = encoding_progress(
            &Counts {
                files_discovered: 200,
                ..Default::default()
            },
            &update,
            &report,
            1.0,
            &fetches,
            &sources,
        );
        assert_eq!(event["active"], 9);
        assert_eq!(event["work"]["encoding"], 2);
        assert_eq!(event["work"]["fetching"], 4);
        assert_eq!(event["work"]["ready"], 2);
        assert_eq!(event["work"]["waiting_read"], 10);
        assert_eq!(event["work"]["waiting_memory"], 4);
        assert_eq!(event["work"]["waiting_download"], 162);
        assert_eq!(event["work"]["retrying_download"], 1);
        assert_eq!(event["work"]["independent_downloads"], true);
        assert_eq!(event["counts"]["files_failed"], 0);
    }
    #[test]
    fn on_demand_media_progress_does_not_credit_an_entire_original_or_double_count_workers() {
        let mut report=report();report.source=ScanSource::Cloud;
        let fetches=fetch::Fetches::new(4);
        fetches.sampled_files.store(1,Ordering::Relaxed);fetches.sampled_original_bytes.store(1<<30,Ordering::Relaxed);
        fetches.sampled_received_bytes.store(256<<10,Ordering::Relaxed);fetches.range_active.store(1,Ordering::Relaxed);
        let sources=prefetch::State::default();sources.inventory.file_bytes.store(1<<30,Ordering::Relaxed);
        sources.resolved_bytes.store(1<<30,Ordering::Relaxed);
        let update=Progress{stage:filetwin_core::api::Stage::Encoding,counts:Counts::default(),elapsed_seconds:1.0,
            work:Some(filetwin_core::api::WorkCounts{encoding:1,..Default::default()})};
        let event=encoding_progress(&Counts::default(),&update,&report,1.0,&fetches,&sources);
        assert_eq!(event["cloud_data"]["on_demand"],true);assert_eq!(event["cloud_data"]["ready_bytes"],0);
        assert_eq!(event["cloud_data"]["sampled_received_bytes"],256<<10);
        assert_eq!(event["work"]["fetching"],1);assert_eq!(event["work"]["range_fetching"],1);
        assert_eq!(event["active"],1,"The same range-reading decoder is one analysis worker");
    }

    #[test]
    fn full_sha_evidence_bridges_native_and_sparse_cloud_without_inventing_hashes() {
        let gcid=format!("gcid:{}:123","ab".repeat(20));
        let sha=format!("sha256:{:064x}",1);
        let other_sha=format!("sha256:{:064x}",2);
        let record=|id:&str| FileRecord {path:FilePath::Utf8("generated".into()),file_id:Some(id.into()),bytes:Some(123),
            state:FileState::Ready,family:None,profile_id:None,vector:None,vector_sha256:None,reused:false,error:None,extraction:None};
        let cloud=|id:&str,hash:&str| {
            let mut file=InputFile::cloud(CloudItem{id:id.into(),name:"generated.mp4".into(),path:"/generated".into(),
                is_folder:false,size:123,ancestors:vec![],revision:Some("ab".repeat(20))});
            file.record=Some(record(hash));file
        };
        let native=|id:&str,hash:&str| {
            let mut file=InputFile::external(ExternalSource{provider:Some("local".into()),id:id.into(),name:"generated.mp4".into(),
                path:"/Native/generated".into(),size:123,local_path:None,revision:None,content_kind:None});
            file.record=Some(record(hash));file
        };
        let sparse=cloud("range",&gcid);
        let local=native("cross-native:local:copy",&sha);
        let unproven=exact_evidence(&[sparse.clone(),local.clone()]);
        assert_eq!(unproven,vec![Some(gcid.clone()),Some(sha.clone())],"Sparse bytes cannot prove a full SHA256");
        let full=cloud("full",&sha);
        let bridge=[sparse.clone(),local.clone(),full.clone()];
        for order in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
            let evidence=exact_evidence(&order.map(|index|bridge[index].clone()));
            assert!(evidence.iter().all(|id|id.as_ref()==Some(&gcid)),"Proof is independent of discovery order");
        }
        let mut preview=native("cross-native:photos:preview",&sha);
        preview.external.as_mut().unwrap().content_kind=Some(ExternalContentKind::PhotosPreview);
        let proven=exact_evidence(&[sparse,local,full,native("cross-native:local:different",&other_sha),preview]);
        assert_eq!(proven,vec![Some(gcid.clone()),Some(gcid.clone()),Some(gcid),Some(other_sha),None]);
    }

    #[test]
    fn mixed_progress_counts_only_cloud_originals_in_cloud_byte_totals() {
        let fetches=fetch::Fetches::new(4);
        let cloud=fetches.track("generated-cloud",100);cloud.sample(20,100,20);
        let native=fetches.track("generated-photos",1_000);native.native();native.sample(900,1_000,900);
        let mut inventory=discovery::State::default();inventory.has_cloud=true;
        let sources=prefetch::State { inventory:Arc::new(inventory),..Default::default() };
        sources.inventory.file_bytes.store(1_100,Ordering::Relaxed);
        sources.inventory.cloud_file_bytes.store(100,Ordering::Relaxed);
        let update=Progress{stage:filetwin_core::api::Stage::Encoding,counts:Counts::default(),elapsed_seconds:1.0,work:None};
        let event=encoding_progress(&Counts::default(),&update,&report(),1.0,&fetches,&sources);
        assert_eq!(event["cloud_data"]["total_bytes"],100);
        assert_eq!(event["cloud_data"]["ready_bytes"],20);
        assert_eq!(event["downloads"]["received_bytes"],920);
    }

}

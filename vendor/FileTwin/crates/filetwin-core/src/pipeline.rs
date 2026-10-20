//! Bounded source acquisition, hashing and encoding for live inventories.
//! Only the coordinator publishes results; slow I/O never runs on that thread.
use super::*;
use crate::memory_input::{MemoryInput, MemoryServer, OriginalReservation, Reader};
use std::{
    collections::VecDeque,
    sync::{
        Arc, Mutex, RwLock,
        atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
        mpsc,
    },
};

const FETCHING: u8 = 1;
const READING: u8 = 2;
const ENCODING: u8 = 3;
const WAITING: u8 = 4;
const HASHING: u8 = 5;
// More simultaneous seeks make external/network disks slower, regardless of
// the decoder RAM allowance. Reading must also leave analysis workers free.
const MAX_READERS: usize = 4;
type Phase = Arc<AtomicU8>;
type CacheKey = (String, String);

#[derive(Default)]
struct Bytes {
    read: AtomicU64,
    hashed: AtomicU64,
    acquired: AtomicU64,
}
struct Staging {
    used: Mutex<u64>,
    limit: AtomicU64,
    ceiling: Option<u64>,
    required: AtomicU64,
    minimum_required: AtomicU64,
    paused: AtomicBool,
    draining: AtomicBool,
    completion: Mutex<BTreeMap<(u64, u64), usize>>,
}
struct Reservation {
    budget: Arc<Staging>,
    bytes: u64,
    active: AtomicBool,
    completion_extra: Option<u64>,
}
impl Drop for Reservation {
    fn drop(&mut self) { self.release(); }
}
impl Reservation {
    fn new(budget: Arc<Staging>, bytes: u64) -> Self { Self { budget, bytes, active: AtomicBool::new(true), completion_extra: None } }
    fn split(&mut self, bytes: u64) -> Self {
        assert!(bytes <= self.bytes && self.active.load(Ordering::Acquire));
        assert!(self.completion_extra.is_none());
        self.bytes -= bytes;
        Self::new(self.budget.clone(), bytes)
    }
}
impl OriginalReservation for Reservation {
    fn bytes(&self) -> u64 { self.bytes }
    fn release(&self) {
        let mut used = self.budget.used.lock().unwrap();
        if self.active.swap(false, Ordering::AcqRel) {
            *used -= self.bytes;
            if let Some(extra) = self.completion_extra {
                let mut completion = self.budget.completion.lock().unwrap();
                Staging::untrack(&mut completion, extra, self.bytes);
            }
        }
    }
    fn try_reacquire(&self) -> bool {
        let mut used = self.budget.used.lock().unwrap();
        if self.active.load(Ordering::Acquire) { return true; }
        if self.bytes > self.budget.limit.load(Ordering::Acquire).saturating_sub(*used) { return false; }
        if let Some(extra) = self.completion_extra {
            let mut completion = self.budget.completion.lock().unwrap();
            *completion.entry((extra, self.bytes)).or_default() += 1;
            if Staging::minimum_for(used.saturating_add(self.bytes), &completion) > self.budget.limit.load(Ordering::Acquire) {
                Staging::untrack(&mut completion, extra, self.bytes); return false;
            }
        }
        *used += self.bytes; self.active.store(true, Ordering::Release); true
    }
}
impl Staging {
    fn untrack(completion: &mut BTreeMap<(u64, u64), usize>, extra: u64, bytes: u64) {
        let key = (extra, bytes);
        let count = completion.get_mut(&key).unwrap(); *count -= 1;
        if *count == 0 { completion.remove(&key); }
    }
    fn minimum_for(used: u64, completion: &BTreeMap<(u64, u64), usize>) -> u64 {
        let mut minimum = used; let mut released = 0u64;
        for (&(extra, bytes), &count) in completion {
            for _ in 0..count {
                minimum = minimum.max(used.saturating_sub(released).saturating_add(extra));
                released += bytes;
            }
        }
        minimum
    }
    fn new(limit: u64, ceiling: Option<u64>) -> Self {
        Self { used: Mutex::new(0), limit: AtomicU64::new(limit), ceiling,
            required: AtomicU64::new(0), minimum_required: AtomicU64::new(0),
            paused: AtomicBool::new(false), draining: AtomicBool::new(false), completion: Mutex::new(BTreeMap::new()) }
    }
    fn try_reserve(self: &Arc<Self>, bytes: u64) -> Option<Reservation> {
        let mut used = self.used.lock().unwrap();
        if bytes > self.limit.load(Ordering::Acquire).saturating_sub(*used) { return None; }
        *used += bytes;
        Some(Reservation::new(self.clone(), bytes))
    }
    fn used(&self) -> u64 { *self.used.lock().unwrap() }
    fn reserve(
        self: &Arc<Self>,
        bytes: u64,
        completion_extra: u64,
        cancel: &CancellationToken,
        phase: &Phase,
    ) -> Result<Reservation> {
        loop {
            read_checkpoint(cancel)?;
            if bytes > self.ceiling.unwrap_or_else(|| self.limit.load(Ordering::Acquire)) {
                return Err(Error::new(ErrorCode::ResourceBudgetTooSmall, "memory", "The adjusted RAM budget cannot fit this input."));
            }
            {
                let mut used = self.used.lock().unwrap();
                let mut completion = self.completion.lock().unwrap();
                *completion.entry((completion_extra, bytes)).or_default() += 1;
                let required = Self::minimum_for(used.saturating_add(bytes), &completion);
                if !self.paused.load(Ordering::Acquire)
                    && (!self.draining.load(Ordering::Acquire) || *used == 0)
                    && required <= self.limit.load(Ordering::Acquire) {
                    *used += bytes;
                    phase.store(READING, Ordering::Release);
                    let mut reservation = Reservation::new(self.clone(), bytes);
                    reservation.completion_extra = Some(completion_extra);
                    return Ok(reservation);
                }
                Self::untrack(&mut completion, completion_extra, bytes);
                self.required.fetch_max(required, Ordering::Relaxed);
                let _ = self.minimum_required.fetch_update(Ordering::Relaxed, Ordering::Relaxed,
                    |old| Some(if old == 0 { required } else { old.min(required) }));
            }
            phase.store(WAITING, Ordering::Release);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

struct Input {
    source: EncodeSource,
    file: Reader,
    revision: Option<Revision>,
    record: FileRecord,
    format: String,
    staged: Option<Arc<tempfile::NamedTempFile>>,
    memory_copy: Option<Arc<MemoryInput>>,
    _reservation: Option<Reservation>,
    analysis_reservation: Option<Reservation>,
    phase: Phase,
    allowance: u64,
    handoff_original: bool,
    analysis_started: bool,
}
impl Input {
    fn visual(&self) -> bool { matches!(self.record.family.as_deref(), Some("image" | "video")) }
    fn memory(&self) -> Option<&Arc<MemoryInput>> { self.memory_copy.as_ref().or(self.source.memory.as_ref()) }
    fn original_bytes(&self) -> u64 {
        if self.handoff_original { self.memory().map_or(0, |m| m.original_bytes()) } else { 0 }
    }
    fn transferred_bytes(&self) -> u64 {
        if self.handoff_original { self.memory().map_or(0, |m| m.analysis_bytes()) } else { 0 }
    }
    fn reader_copy_bytes(&self) -> u64 {
        if self.format == "utf8" { return 0; }
        // FFmpeg seeks the shared buffer over HTTP; it does not allocate a
        // second complete original. Image/document open_input() readers do.
        if self.handoff_original && self.original_bytes() > 0 && (matches!(self.format.as_str(), "media" | "heif_avif")
            || matches!(self.record.family.as_deref(), Some("audio" | "video"))) { return 0; }
        if self.memory_copy.is_some() || self.source.memory.is_some() { self.record.bytes.unwrap_or(0) } else { 0 }
    }
    fn fixed_bytes(&self) -> u64 { self.original_bytes().saturating_add(self.reader_copy_bytes()) }
    fn reservation_bytes(&self) -> u64 {
        let allowance = if self.record.error.is_some() { 1 << 20 } else { self.allowance };
        allowance.saturating_add(self.fixed_bytes()).saturating_sub(self.transferred_bytes())
    }
    fn current(&self) -> bool {
        match (&self.file, &self.revision) {
            (Reader::File(file), Some(revision)) => local::still_current(file, &self.source.path, revision),
            (Reader::Memory(_), None) => true,
            (Reader::Seekable(_), None) => self.source.seekable.as_ref().is_some_and(|s| s.current()),
            _ => false,
        }
    }
    fn changed(&mut self) {
        self.record.file_id = None;
        self.record.error = Some(self.source.seekable.as_ref().and_then(|s| s.failure()).unwrap_or_else(changed_error));
        self.record.state = FileState::Failed;
    }
}
fn changed_error() -> Error {
    Error::new(
        ErrorCode::SourceChanged,
        "validation",
        "Source changed during processing; vector discarded",
    )
}

#[cfg(test)]
mod admission_tests {
    use super::*;
    #[test]
    fn a_small_original_does_not_hide_larger_reader_completion_requirements() {
        let mut completion = BTreeMap::new();
        completion.insert((0, 512 << 20), 1);
        completion.insert((15 << 30, 15 << 30), 2);
        let used = (30 << 30) + (512 << 20);
        assert_eq!(Staging::minimum_for(used, &completion), 45 << 30);
        assert!(Staging::minimum_for(used, &completion) > (32 << 30) - (512 << 20));
        Staging::untrack(&mut completion, 15 << 30, 15 << 30);
        assert_eq!(Staging::minimum_for(used - (15 << 30), &completion), 30 << 30);
    }
}
fn blank(key: &Path) -> FileRecord {
    FileRecord {
        path: FilePath::from_path(key),
        file_id: None,
        bytes: None,
        state: FileState::Failed,
        family: None,
        profile_id: None,
        vector: None,
        vector_sha256: None,
        reused: false,
        error: None,
        extraction: None,
    }
}
fn unavailable(record: &mut FileRecord, error: Error) {
    record.state = match error.code {
        ErrorCode::UnsupportedFormat | ErrorCode::InvalidText | ErrorCode::InsufficientContent => {
            FileState::Unsupported
        }
        ErrorCode::UnselectedFamily => FileState::Skipped,
        _ => FileState::Failed,
    };
    record.error = Some(error);
}

enum Work {
    Read(EncodeSource, Phase),
    Hash(Input),
    Text(Input),
}
enum Event {
    Read(Result<Input>, PathBuf),
    Hash(Input, Result<()>),
    Text(Input, native::Outcome),
    Stopped,
}

fn read_checkpoint(cancel: &CancellationToken) -> Result<()> {
    while cancel.is_paused() {
        cancel.check()?;
        std::thread::sleep(Duration::from_millis(10));
    }
    cancel.check()
}

fn prepare(
    source: EncodeSource,
    phase: Phase,
    config: &EncoderConfig,
    staging: &Arc<Staging>,
    bytes: &Bytes,
    cancel: &CancellationToken,
) -> Result<Input> {
    read_checkpoint(cancel)?;
    phase.store(FETCHING, Ordering::Release);
    let source = source.resolve(cancel)?;
    if source.memory.is_none() && source.seekable.is_none() && !source.path.is_absolute() {
        return Err(Error::invalid("A resolved source must be an absolute path"));
    }
    phase.store(READING, Ordering::Release);
    let (mut file, revision, source_bytes) = if let Some(input) = &source.seekable {
        if !crate::valid_content_id(input.content_id(), Some(input.len())) || !input.content_id().starts_with("gcid:") {
            return Err(Error::invalid("Seekable media needs a verified provider GCID and original length"));
        }
        (Reader::seekable(input.clone()), None, input.len())
    } else if let Some(memory) = &source.memory {
        (Reader::memory(memory.clone()), None, memory.as_ref().as_ref().len() as u64)
    } else {
        let file = local::open_secure(&source.path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() { return Err(changed_error()); }
        let revision = Revision::of(&metadata);
        let len = revision.bytes;
        (Reader::File(file), Some(revision), len)
    };
    let mut prefix = [0u8; 4096];
    let n = file.read(&mut prefix)?;
    bytes.read.fetch_add(n as u64, Ordering::Relaxed);
    if source.memory.is_none() && source.seekable.is_none() { bytes.acquired.fetch_add(n as u64, Ordering::Relaxed); }
    file.seek(SeekFrom::Start(0))?;
    let (family, format) = detect_format(&prefix[..n], &source.path);
    if source.seekable.is_some() && format != "media" {
        return Err(Error::new(ErrorCode::UnsupportedFormat, "validation", "Seekable originals are restricted to media containers"));
    }
    // A container's sniffed family is only a hint. Probe its streams before
    // deciding whether it is audio or video, and constrain the worker profiles.
    let excluded = family != "unknown" && source.families.as_ref().is_some_and(|families| {
        if format == "media" {
            !families.iter().any(|v| matches!(v.as_str(), "audio" | "video"))
        } else {
            !families.iter().any(|v| v == family)
        }
    });
    let native = !excluded && format != "utf8" && family != "unknown";
    let required = source_bytes.saturating_add(2 * protocol::MAX_RESPONSE as u64);
    let needs_copy = source.memory.is_none() && source.seekable.is_none() && (native
        || (config.memory_scheduling && !excluded && format == "utf8"));
    let completion_extra = if config.memory_ceiling.is_some() && needs_copy {
        let reader_copy = if matches!(format, "utf8" | "media" | "heif_avif") || matches!(family, "audio" | "video") { 0 } else { source_bytes };
        let decoder = if matches!(family, "image" | "video") || format == "media" { 512 << 20 } else { 128 << 20 };
        reader_copy.saturating_add(decoder).saturating_sub(512 << 20)
    } else { 0 };
    let overflow = needs_copy && (required > staging.ceiling.unwrap_or_else(|| staging.limit.load(Ordering::Acquire))
        || config.memory_ceiling.is_some_and(|ceiling| required.saturating_add(completion_extra).saturating_add(512 << 20) > ceiling));
    let mut reservation = if needs_copy && !overflow {
        Some(staging.reserve(required, completion_extra, cancel, &phase)?)
    } else {
        None
    };
    // Acquisition owns only Read RAM. Analysis reserves its allowance after
    // this snapshot is complete, before the first hash calculation.
    let mut memory_copy = if needs_copy && !overflow && config.memory_staging {
        let mut data = Vec::new();
        data.try_reserve_exact(source_bytes as usize).map_err(|_| Error::new(ErrorCode::ResourceBudgetTooSmall, "memory", "Not enough RAM for the original; no disk copy was created"))?;
        Some(data)
    } else { None };
    let mut staged = if needs_copy && !overflow && !config.memory_staging {
        Some(tempfile::NamedTempFile::new_in(&config.temp_dir)?)
    } else {
        None
    };
    // In RAM scheduling mode acquisition only copies bytes. Hashing is a
    // separate analysis job, admitted after transferring the original's lease.
    let mut hash = (!config.memory_scheduling && source.seekable.is_none()).then(Sha256::new);
    let mut buffer = [0u8; 65536];
    let mut size = 0u64;
    let acquire = source.seekable.is_none() && (!config.memory_scheduling || memory_copy.is_some() || staged.is_some());
    while acquire {
        read_checkpoint(cancel)?;
        while staging.paused.load(Ordering::Acquire) {
            phase.store(WAITING, Ordering::Release);
            read_checkpoint(cancel)?;
            std::thread::sleep(Duration::from_millis(10));
        }
        phase.store(READING, Ordering::Release);
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        if size > source_bytes {
            return Err(changed_error());
        }
        if let Some(hash) = &mut hash {
            hash.update(&buffer[..n]);
            bytes.hashed.fetch_add(n as u64, Ordering::Relaxed);
        }
        bytes.read.fetch_add(n as u64, Ordering::Relaxed);
        if source.memory.is_none() && source.seekable.is_none() { bytes.acquired.fetch_add(n as u64, Ordering::Relaxed); }
        if let Some(staged) = &mut staged { staged.write_all(&buffer[..n])?; }
        if let Some(copy) = &mut memory_copy {
            if size > source_bytes { return Err(changed_error()); }
            copy.extend_from_slice(&buffer[..n]);
        }
    }
    if let Some(staged) = &mut staged {
        staged.flush()?;
    }
    if acquire && size != source_bytes { return Err(changed_error()); }
    let mut record = blank(&source.key);
    record.file_id = source.seekable.as_ref().map(|s| s.content_id().to_owned()).or_else(|| hash.map(|hash| format!("sha256:{:x}", hash.finalize())));
    record.bytes = Some(if acquire { size } else { source_bytes });
    record.family = (family != "unknown").then(|| family.into());
    if excluded {
        unavailable(
            &mut record,
            Error::new(
                ErrorCode::UnselectedFamily,
                "selection",
                "Content type excluded from similarity analysis",
            ),
        );
    } else if overflow {
        unavailable(
            &mut record,
            Error::new(
                ErrorCode::ResourceBudgetTooSmall,
                "staging",
                if config.memory_staging { "Original cannot fit in available system memory. No disk copy was created." } else { "File exceeds the private staging allowance" },
            ),
        );
    } else if family == "unknown" {
        unavailable(
            &mut record,
            Error::new(
                ErrorCode::UnsupportedFormat,
                "encoding",
                "Binary or unsupported content has no similarity reader; exact-content hash retained",
            ),
        );
    }
    let memory_copy = memory_copy.map(|data| {
        let memory = MemoryInput::new(data);
        Arc::new(if let Some(lease) = reservation.take() { memory.with_reservation(lease) } else { memory })
    });
    let mut input = Input {
        source,
        file,
        revision,
        record,
        format: format.into(),
        staged: staged.map(Arc::new),
        memory_copy,
        _reservation: reservation,
        analysis_reservation: None,
        phase,
        handoff_original: config.memory_scheduling,
        analysis_started: false,
        allowance: if config.memory_scheduling {
            if matches!(family, "image" | "video") || format == "media" { 512 << 20 } else { 128 << 20 }
        } else { config.memory_bytes / native::worker_count(config) as u64 },
    };
    // The native model cache includes its allowance. Round down to stable
    // 64 MiB bands so tiny differences in original size do not reload the
    // model for every image. Reader copies are charged at their exact size.
    if config.memory_scheduling {
        input.allowance = input.allowance.min(config.memory_ceiling.unwrap_or(config.memory_bytes).saturating_sub(input.fixed_bytes()));
    } else {
        input.allowance = (input.allowance.saturating_sub(input.reader_copy_bytes()) / (64 << 20) * (64 << 20))
            .max(512 << 20)
            .min(config.memory_bytes.saturating_sub(input.reader_copy_bytes()));
    }
    if !input.current() {
        input.changed();
    }
    Ok(input)
}

fn hash_input(mut input: Input, bytes: &Bytes, cancel: &CancellationToken) -> (Input, Result<()>) {
    let result = (|| {
        // Hash the RAM snapshot, never reread the network original after it
        // has been acquired. The original and scratch allowance belong to
        // Analysis RAM for this entire job and the following decoder job.
        let mut memory = input.memory().cloned().map(Reader::memory);
        let file = memory.as_mut().unwrap_or(&mut input.file);
        file.seek(SeekFrom::Start(0))?;
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 65536];
        let mut size = 0u64;
        loop {
            cancel.check()?;
            let n = file.read(&mut buffer)?;
            if n == 0 { break; }
            size += n as u64;
            if size > input.record.bytes.unwrap() { return Err(changed_error()); }
            hash.update(&buffer[..n]);
            bytes.read.fetch_add(n as u64, Ordering::Relaxed);
            bytes.hashed.fetch_add(n as u64, Ordering::Relaxed);
        }
        if size != input.record.bytes.unwrap() { return Err(changed_error()); }
        input.record.file_id = Some(format!("sha256:{:x}", hash.finalize()));
        Ok(())
    })();
    (input, result)
}

fn text(mut input: Input, bytes: &Bytes, cancel: &CancellationToken) -> (Input, native::Outcome) {
    input.phase.store(ENCODING, Ordering::Release);
    let outcome = (|| -> native::Outcome {
        let mut memory = input.memory().cloned().map(Reader::memory);
        let file = memory.as_mut().unwrap_or(&mut input.file);
        file.seek(SeekFrom::Start(0))?;
        match crate::text::encode(file, false, &mut || cancel.check()) {
            Ok(encoded) => {
                bytes.read.fetch_add(encoded.bytes_read, Ordering::Relaxed);
                Ok(protocol::Encoded {
                    family: "text".into(),
                    format: "text/plain; charset=utf-8".into(),
                    vector: encoded.vector,
                    extraction: json!({"coverage":"complete_source_text", "characters":encoded.characters}),
                })
            }
            Err(error) => {
                bytes.read.fetch_add(
                    error.details["bytes_read"].as_u64().unwrap_or(0),
                    Ordering::Relaxed,
                );
                Err(error)
            }
        }
    })();
    (input, outcome)
}

struct Pipeline<'a> {
    config: EncoderConfig,
    reader_config: Arc<RwLock<EncoderConfig>>,
    grow_readers: &'a mut dyn FnMut(usize),
    external_cancel: &'a CancellationToken,
    cancel: CancellationToken,
    read_cancel: CancellationToken,
    reads_in_flight: usize,
    finishing: bool,
    pool: Option<native::Pool>, // Stopped before native input leases are released.
    send: Option<mpsc::Sender<Work>>,
    send_text: Option<mpsc::Sender<Work>>,
    receive: mpsc::Receiver<Event>,
    jobs: HashMap<PathBuf, Phase>,
    queued: VecDeque<Input>,
    native: Vec<Option<Input>>,
    waiters: HashMap<CacheKey, Vec<FileRecord>>,
    cache: HashMap<CacheKey, FileRecord>,
    owners: HashSet<CacheKey>,
    profiles: BTreeMap<String, String>,
    counts: Counts,
    bytes: Arc<Bytes>,
    staging: Arc<Staging>,
    analysis: Arc<Staging>,
    records: Vec<FileRecord>,
    progress: &'a mut dyn FnMut(&Progress),
    completed: &'a mut dyn FnMut(&FileRecord) -> Result<()>,
    checkpoint_error: Option<Error>,
    started: Instant,
    last_progress: Instant,
    retry_blocked_since: Option<Instant>,
}
impl Drop for Pipeline<'_> {
    fn drop(&mut self) {
        self.cancel.cancel();
        self.read_cancel.cancel();
        self.send.take();
        self.send_text.take();
        self.pool.take();
    }
}
impl Pipeline<'_> {
    fn pool(&self) -> &native::Pool {
        self.pool.as_ref().unwrap()
    }
    fn work(&self) -> WorkCounts {
        let mut work = WorkCounts {
            memory_scheduling: self.config.memory_scheduling,
            accelerator_active: self.accelerator_active(),
            accelerator_limit: self.config.accelerator_capacity(),
            worker_limit: self.pool().capacity(),
            memory_limit: self.config.memory_bytes,
            memory_in_use: (if self.config.memory_scheduling { self.analysis.used() } else { self.pool().memory_in_use() })
                + if self.config.memory_staging { self.staging.used() } else { 0 },
            waiting_reuse: self.waiters.values().map(|v| v.len() as u64).sum(),
            ready: self.queued.len() as u64,
            original_memory_bytes: if self.config.memory_staging { *self.staging.used.lock().unwrap() } else { 0 },
            original_bytes_read: self.bytes.acquired.load(Ordering::Relaxed),
            staging_memory_required: self.staging.required.swap(0, Ordering::Relaxed),
            staging_memory_minimum: self.staging.minimum_required.swap(0, Ordering::Relaxed),
            staging_memory_limit: self.config.staging_bytes,
            ..WorkCounts::default()
        };
        work.analysis_memory_forecast = self.analysis.used();
        for input in self.queued.iter().filter(|input| input.analysis_reservation.is_none()) {
            work.analysis_memory_forecast = work.analysis_memory_forecast.saturating_add(input.reservation_bytes());
            work.analysis_growth_bytes = work.analysis_growth_bytes.saturating_add(input.reservation_bytes()
                .saturating_sub(input.original_bytes().saturating_sub(input.transferred_bytes())));
        }
        if let Some(input) = self.queued.iter().filter(|input| input.analysis_reservation.is_none())
            .min_by_key(|input| input.reservation_bytes().saturating_sub(input.original_bytes().saturating_sub(input.transferred_bytes()))) {
            work.analysis_memory_required = self.analysis.used().saturating_add(input.reservation_bytes());
            work.analysis_transfer_bytes = input.original_bytes().saturating_sub(input.transferred_bytes());
        }
        for phase in self.jobs.values() {
            match phase.load(Ordering::Acquire) {
                FETCHING => work.fetching += 1,
                READING => work.reading += 1,
                HASHING => work.hashing += 1,
                ENCODING => work.encoding += 1,
                WAITING => work.waiting_memory += 1,
                _ => {}
            }
        }
        // WAITING covers both readers blocked on RAM and decoded inputs in
        // the ready queue. Classify ready inputs by their actual constraint;
        // occupied accelerator slots are not a shortage of memory.
        work.waiting_memory = work.waiting_memory.saturating_sub(self.queued.len() as u64);
        let available = self.config.memory_bytes.saturating_sub(
            if self.config.memory_scheduling { self.analysis.used() } else { self.pool().memory_in_use() });
        for input in &self.queued {
            if input.analysis_reservation.is_none() && input.reservation_bytes() > available {
                work.waiting_memory += 1;
            } else if input.record.file_id.is_some() && input.format != "utf8" && self.free_slot(input).is_none() {
                if input.visual() && self.config.backend == profile::Backend::Coreml {
                    work.waiting_accelerator += 1;
                } else {
                    work.waiting_worker += 1;
                }
            }
        }
        work
    }
    fn emit(&mut self, force: bool) {
        if force || self.last_progress.elapsed() >= Duration::from_millis(100) {
            self.counts.bytes_read = self.bytes.read.load(Ordering::Relaxed);
            self.counts.bytes_hashed = self.bytes.hashed.load(Ordering::Relaxed);
            let work = self.work();
            (self.progress)(&Progress {
                stage: Stage::Encoding,
                counts: self.counts.clone(),
                work: Some(work),
                elapsed_seconds: self.started.elapsed().as_secs_f64(),
            });
            self.last_progress = Instant::now();
        }
    }
    fn check(&mut self) -> Result<()> {
        self.emit(false);
        if let Some(error) = self.checkpoint_error.take() { return Err(error); }
        self.external_cancel.check()?;
        self.cancel.check()
    }
    fn send(&self, work: Work) -> Result<()> {
        let sender = match &work { Work::Read(..) => &self.send, Work::Hash(..) | Work::Text(..) => &self.send_text };
        sender.as_ref().unwrap().send(work).map_err(|_| {
            Error::new(
                ErrorCode::WorkerFailed,
                "pipeline",
                "Input worker stopped unexpectedly",
            )
        })
    }
    fn record(&mut self, record: FileRecord) {
        if let Err(error) = (self.completed)(&record) {
            self.checkpoint_error = Some(error); return;
        }
        if let Ok(key) = record.path.to_path_buf() {
            self.jobs.remove(&key);
        }
        self.counts.files_processed += 1;
        match record.state {
            FileState::Ready => {
                self.counts.files_ready += 1;
                if record.reused {
                    self.counts.cache_hits += 1;
                } else {
                    self.counts.vectors_encoded += 1;
                }
                self.cache.insert(
                    (
                        record.file_id.clone().unwrap(),
                        record.profile_id.clone().unwrap(),
                    ),
                    record.clone(),
                );
            }
            FileState::Skipped => self.counts.files_skipped += 1,
            FileState::Unsupported | FileState::Failed => self.counts.files_failed += 1,
        }
        self.records.push(record);
    }
    fn candidates(&self, input: &Input) -> Vec<String> {
        if input.format == "media" {
            ["audio", "video"].into_iter()
                .filter(|family| input.source.families.as_ref().is_none_or(|selected| selected.iter().any(|v| v == family)))
                .map(|family| self.profiles[family].clone()).collect()
        } else {
            vec![self.profiles[input.record.family.as_deref().unwrap()].clone()]
        }
    }
    fn key(&self, input: &Input) -> CacheKey {
        (
            input.record.file_id.clone().unwrap(),
            self.candidates(input).join("|"),
        )
    }
    fn adjust_allowance(&self, input: &mut Input) -> Result<()> {
        let available = self.config.memory_ceiling.unwrap_or(self.config.memory_bytes).saturating_sub(input.fixed_bytes());
        let minimum = if input.record.error.is_some() || input.format == "utf8" { 1 << 20 }
            else if input.visual() || input.format == "media" { 512 << 20 }
            else { 128 << 20 };
        if minimum > available {
            return Err(Error::new(ErrorCode::ResourceBudgetTooSmall, "memory", "Analysis RAM must fit the original, reader copies and decoder together."));
        }
        input.allowance = input.allowance.min(available);
        Ok(())
    }
    fn update_resources(&mut self, limits: LiveResources) {
        self.config.workers = limits.workers.max(1);
        self.config.memory_bytes = limits.memory_bytes.max(1);
        // An unused source bank must really be empty. Even one phantom byte
        // would prevent a ready original from transferring at an exact fit.
        self.config.staging_bytes = limits.staging_bytes;
        self.config.total_memory_bytes = limits.total_memory_bytes;
        if let (Some(total), Some(external), Some(target)) = (limits.total_memory_bytes, &self.config.external_memory, limits.external_memory_bytes) {
            let analysis = self.analysis.used();
            self.config.staging_bytes = self.config.staging_bytes.min(total.saturating_sub(analysis)
                .saturating_sub(external.used.load(Ordering::Acquire).max(target)));
            self.staging.limit.store(self.config.staging_bytes, Ordering::Release);
            let available = total.saturating_sub(analysis)
                .saturating_sub(self.staging.used().max(self.config.staging_bytes));
            external.limit.store(target.min(available), Ordering::Release);
        }
        self.analysis.limit.store(self.config.memory_bytes, Ordering::Release);
        self.staging.limit.store(self.config.staging_bytes, Ordering::Release);
        self.staging.paused.store(limits.acquisition_paused, Ordering::Release);
        self.staging.draining.store(self.external_cancel.is_memory_draining(), Ordering::Release);
        *self.reader_config.write().unwrap() = self.config.clone();
        self.pool.as_mut().unwrap().update_resources(&self.config);
        if limits.acquisition_paused { self.pool.as_mut().unwrap().release_idle(); }
        let capacity = self.pool().capacity();
        self.native.resize_with(self.native.len().max(capacity), || None);
        (self.grow_readers)(capacity);
        // Keep all in-flight leases accounted for. A decrease can temporarily
        // leave usage above the new allowance; no new work is admitted until
        // enough of the existing work releases its reservation.
        let mut kept = VecDeque::new();
        while let Some(mut input) = self.queued.pop_front() {
            match self.adjust_allowance(&mut input) {
                Ok(()) => kept.push_back(input),
                Err(error) if input.record.file_id.is_none() => {
                    unavailable(&mut input.record, error);
                    self.record(input.record.clone());
                }
                Err(error) => self.finish(input, Err(error)),
            }
        }
        self.queued = kept;
        self.emit(true);
    }
    fn read(&mut self, mut input: Input) -> Result<()> {
        // A hashed input keeps its prepaid analysis allowance through decoding.
        // Its original must never move back into the acquisition budget.
        if !input.current() {
            input.changed();
        }
        if input.record.error.is_some() {
            self.record(input.record.clone());
            return Ok(());
        }
        let digest = input.record.file_id.clone().unwrap();
        if let Some(hit) = self
            .candidates(&input)
            .iter()
            .find_map(|p| self.cache.get(&(digest.clone(), p.clone())))
            .cloned()
        {
            let mut record = hit;
            record.path = input.record.path.clone();
            record.bytes = input.record.bytes;
            record.reused = true;
            self.record(record);
            return Ok(());
        }
        let key = self.key(&input);
        if self.owners.contains(&key) {
            // Its bytes and revision have been verified. Keep only occurrence
            // metadata, just as for a cache hit; release its original/copy now.
            self.jobs.remove(&input.source.key);
            self.waiters
                .entry(key)
                .or_default()
                .push(input.record.clone());
            return Ok(());
        }
        self.owners.insert(key);
        if input.format == "utf8" && !self.config.memory_scheduling {
            input.phase.store(ENCODING, Ordering::Release);
            self.send(Work::Text(input))?;
        } else {
            // A reader may finish after a live edit using an older snapshot.
            // Recheck against the current allowance before entering the queue.
            if let Err(error) = self.adjust_allowance(&mut input) {
                self.finish(input, Err(error));
                return Ok(());
            }
            input.phase.store(WAITING, Ordering::Release);
            self.queued.push_back(input);
        }
        Ok(())
    }
    fn finish(&mut self, mut input: Input, outcome: native::Outcome) {
        let key = self.key(&input);
        if !input.current() {
            input.changed();
        } else {
            match outcome {
                Ok(encoded) if input.source.families.as_ref().is_some_and(|selected| !selected.contains(&encoded.family)) => {
                    let mut error = Error::new(ErrorCode::UnselectedFamily, "selection", "Detected media family was not selected");
                    error.details = Box::new(serde_json::json!({"family":encoded.family}));
                    unavailable(&mut input.record, error);
                }
                Ok(encoded) => {
                    input.record.state = FileState::Ready;
                    input.record.family = Some(encoded.family.clone());
                    input.record.profile_id = Some(self.profiles[&encoded.family].clone());
                    input.record.vector_sha256 =
                        Some(profile::digest_hex(&profile::vector_bytes(&encoded.vector)));
                    input.record.vector = Some(encoded.vector);
                    input.record.extraction = Some(encoded.extraction);
                }
                Err(error) => unavailable(&mut input.record, error),
            }
        }
        self.owners.remove(&key);
        for mut occurrence in self.waiters.remove(&key).unwrap_or_default() {
            if input.record.state == FileState::Ready {
                let mut reused = input.record.clone();
                reused.path = occurrence.path;
                reused.bytes = occurrence.bytes;
                reused.reused = true;
                self.record(reused);
            } else {
                unavailable(&mut occurrence, input.record.error.clone().unwrap());
                self.record(occurrence);
            }
        }
        self.record(input.record.clone());
    }
    fn drain(&mut self) -> Result<()> {
        while let Ok(event) = self.receive.try_recv() {
            self.check()?;
            match event {
                Event::Read(result, key) => {
                    self.reads_in_flight = self.reads_in_flight.saturating_sub(1);
                    if self.finishing {
                        self.jobs.remove(&key);
                        // Discard unfinished acquisitions, without reporting
                        // cancellation as a failed file. Resume will retry them.
                        continue;
                    }
                    match result {
                        Ok(mut input) if self.config.memory_scheduling && input.record.file_id.is_none() => {
                            if let Err(error) = self.adjust_allowance(&mut input) {
                                unavailable(&mut input.record, error);
                                self.record(input.record.clone());
                            } else {
                                input.phase.store(WAITING, Ordering::Release);
                                self.queued.push_back(input);
                            }
                        }
                        Ok(input) => self.read(input)?,
                        Err(error) => {
                            let mut record = blank(&key);
                            unavailable(&mut record, error);
                            self.record(record);
                        }
                    }
                }
                Event::Hash(mut input, result) => {
                    if let Err(error) = result {
                        unavailable(&mut input.record, error);
                        self.record(input.record.clone());
                    } else { self.read(input)?; }
                }
                Event::Text(input, outcome) => self.finish(input, outcome),
                Event::Stopped => {
                    return Err(Error::new(
                        ErrorCode::WorkerFailed,
                        "pipeline",
                        "An input worker stopped unexpectedly",
                    ));
                }
            }
        }
        while let Some((slot, outcome)) = self.pool.as_mut().unwrap().poll() {
            self.check()?;
            let mut input = self.native[slot].take().unwrap();
            // Decoder copies are gone after poll() stops the request's memory
            // server. Keep the original accounted for while waiting to retry.
            input.analysis_reservation.take();
            if let Err(error) = &outcome {
                // Borrow unused shared memory for readers that need more than
                // the initial allowance. No other job's reservation is exceeded.
                let decoder_limit = self.config.memory_ceiling.unwrap_or(self.config.memory_bytes).saturating_sub(input.fixed_bytes());
                if !self.finishing && error.code == ErrorCode::ResourceBudgetTooSmall
                    && input.allowance < decoder_limit
                    && input.current()
                {
                    let required = error.details["required_memory_bytes"]
                        .as_u64()
                        .unwrap_or(input.allowance.saturating_mul(2));
                    if required <= decoder_limit {
                        input.allowance = required
                            .max(input.allowance.saturating_mul(2))
                            .min(decoder_limit);
                        input.phase.store(WAITING, Ordering::Release);
                        self.queued.push_front(input);
                        continue;
                    }
                }
            }
            self.finish(input, outcome);
        }
        if self.staging.paused.load(Ordering::Acquire) { self.pool.as_mut().unwrap().release_idle(); }
        Ok(())
    }
    fn accelerator_active(&self) -> usize {
        if self.config.backend != profile::Backend::Coreml { return 0; }
        self.native.iter().flatten().filter(|input| input.visual()).count()
    }
    fn free_slot(&self, input: &Input) -> Option<usize> {
        let capacity = self.pool().capacity();
        if self.pool().active() >= capacity { return None; }
        let slots = &self.native[..capacity];
        if self.config.backend != profile::Backend::Coreml { return slots.iter().position(Option::is_none); }
        // Keep visual models in a stable set of persistent workers. In memory
        // scheduling mode this set grows with the analysis RAM allowance; the
        // per-input reservation still decides which ready files can run.
        if input.visual() {
            if self.accelerator_active() >= self.config.accelerator_capacity() { return None; }
            slots.iter().take(self.config.accelerator_capacity()).position(Option::is_none)
        } else {
            slots.iter().rposition(Option::is_none)
        }
    }
    fn shared_memory_fits(&self, input: &Input) -> bool {
        let Some(total) = self.config.total_memory_bytes else { return true; };
        if input.analysis_reservation.is_some() { return true; }
        // Source banks may temporarily exceed a reduced allowance. Reserve
        // room for both held originals and any new acquisition still allowed.
        // Credit only this input's original during its zero-copy handoff.
        let sources = self.staging.used().max(self.config.staging_bytes)
            .saturating_add(self.config.external_memory.as_ref().map_or(0, |memory| memory.committed()));
        let committed = self.analysis.used().saturating_add(sources);
        let transfer = input.original_bytes().saturating_sub(input.transferred_bytes());
        input.reservation_bytes().saturating_sub(transfer) <= total.saturating_sub(committed)
    }
    fn dispatch(&mut self) -> Result<()> {
        let draining = self.external_cancel.is_memory_draining();
        loop {
            if draining && (self.pool().active() > 0 || self.jobs.values().any(|phase|
                matches!(phase.load(Ordering::Acquire), HASHING | ENCODING))) { break; }
            let available = self.config.memory_bytes.saturating_sub(if self.config.memory_scheduling { self.analysis.used() } else { self.pool().memory_in_use() });
            // A large original waiting for RAM must not block smaller ready
            // files that fit. Choose the oldest ready input that can run now.
            let eligible = |input: &Input| {
                (!self.external_cancel.is_finishing() || input.analysis_started)
                    && (input.analysis_reservation.is_some() || input.reservation_bytes() <= available)
                    && self.shared_memory_fits(input)
                    && (input.record.file_id.is_none() || input.format == "utf8" || self.free_slot(input).is_some())
            };
            let index = if draining {
                self.queued.iter().enumerate().filter(|(_, input)| eligible(input))
                    .min_by_key(|(index, input)| (input.analysis_reservation.is_none(),
                        input.reservation_bytes().saturating_sub(input.original_bytes().saturating_sub(input.transferred_bytes())), *index))
                    .map(|(index, _)| index)
            } else { self.queued.iter().position(eligible) };
            let Some(index) = index else { break; };
            let mut input = self.queued.remove(index).unwrap();
            if self.config.memory_scheduling && input.analysis_reservation.is_none() {
                let Some(mut reservation) = self.analysis.try_reserve(input.reservation_bytes()) else {
                    // A reader may have acquired RAM since the fit check.
                    self.queued.insert(index, input);
                    break;
                };
                let transfer = input.original_bytes().saturating_sub(input.transferred_bytes());
                if transfer > 0 {
                    let original = reservation.split(transfer);
                    input.memory().unwrap().move_to_analysis(original);
                }
                input.analysis_reservation = Some(reservation);
            }
            if input.record.file_id.is_none() {
                input.analysis_started = true;
                input.phase.store(HASHING, Ordering::Release);
                self.send(Work::Hash(input))?;
                if draining { break; }
                continue;
            }
            if input.format == "utf8" {
                input.phase.store(ENCODING, Ordering::Release);
                self.send(Work::Text(input))?;
                if draining { break; }
                continue;
            }
            let target_slot = self.free_slot(&input).expect("Admitted native slot");
            let profiles: BTreeMap<_, _> = self.profiles.iter()
                .filter(|(family, _)| input.source.families.as_ref().is_none_or(|selected| selected.contains(family)))
                .map(|(family, id)| (family.clone(), id.clone())).collect();
            let family = if input.format == "media" {
                if profiles.contains_key("video") { "video" } else { "audio" }
            } else { input.record.family.as_deref().unwrap() };
            let mut runtime_config = self.config.clone();
            runtime_config.workers = 1;
            runtime_config.memory_bytes = input.allowance;
            if let Err(error) = native::validate_runtime(&runtime_config, family, &input.format) {
                self.finish(input, Err(error));
                continue;
            }
            let (path, memory_input, lease): (_, _, Box<dyn std::any::Any + Send>) =
                if let Some(original) = input.source.seekable.clone() {
                    let server = MemoryServer::new_seekable(original)?;
                    (input.source.key.clone(), Some(server.location.clone()), Box::new(server))
                } else if let Some(memory) = input.memory_copy.clone().or_else(|| input.file.data()) {
                    let server = MemoryServer::new(memory)?;
                    (input.source.key.clone(), Some(server.location.clone()), Box::new(server))
                } else {
                    let copy = input.staged.as_ref().unwrap().clone();
                    (copy.path().to_owned(), None, Box::new(copy))
                };
            let request = protocol::Request {
                version: protocol::VERSION,
                path,
                memory_input,
                format: input.format.clone(),
                profile_id: self.profiles[family].clone(),
                profiles,
                model_dir: self.config.model_dir.clone(),
                runtime: self.config.runtime.clone(),
                memory_bytes: input.allowance,
                parent_pid: std::process::id(),
                inference_cache_dir: Some(self.config.inference_cache_dir.clone().unwrap_or_else(|| self.config.temp_dir.join("inference-cache"))),
            };
            input.phase.store(ENCODING, Ordering::Release);
            let slot = self
                .pool
                .as_mut()
                .unwrap()
                .submit_reserved_at(target_slot, native::Prepared {
                    request,
                    bytes: input.record.bytes.unwrap(),
                    _staged: lease,
                });
            self.native[slot] = Some(input);
            if draining { break; }
        }
        Ok(())
    }
    fn release_blocked_retry(&mut self) {
        let automatic = self.config.memory_ceiling.is_some();
        let at_capacity = self.config.memory_ceiling.is_none_or(|ceiling|
            self.config.total_memory_bytes.is_some_and(|total| total >= ceiling)
                && !self.staging.paused.load(Ordering::Acquire));
        let active = self.pool().active() > 0 || self.jobs.values()
            .any(|phase| matches!(phase.load(Ordering::Acquire), FETCHING | READING | HASHING | ENCODING));
        let available = self.config.memory_bytes.saturating_sub(self.analysis.used());
        if !at_capacity || active || self.queued.is_empty()
            || self.queued.iter().any(|input| input.reservation_bytes() <= available && self.shared_memory_fits(input)) {
            self.retry_blocked_since = None; return;
        }
        if let Some(ceiling) = self.config.memory_ceiling {
            let analysis = self.analysis.used();
            let staging = self.staging.used();
            let external = self.config.external_memory.as_ref();
            let actual = analysis.saturating_add(staging)
                .saturating_add(external.map_or(0, |memory| memory.used.load(Ordering::Acquire)));
            let can_rebalance = self.queued.iter().any(|input| {
                let transfer = input.original_bytes().saturating_sub(input.transferred_bytes());
                input.reservation_bytes() <= ceiling.saturating_sub(analysis)
                    && input.reservation_bytes().saturating_sub(transfer) <= ceiling.saturating_sub(actual)
            });
            let can_complete_download = external.is_some_and(|memory|
                memory.incomplete.load(Ordering::Acquire) > 0
                    && analysis.saturating_add(staging).saturating_add(memory.completion_required.load(Ordering::Acquire)) <= ceiling);
            if can_rebalance || can_complete_download {
                self.retry_blocked_since = None; return;
            }
        }
        // Give the governor and source lookahead a full turn before deciding
        // the physical working set cannot make progress. Never fail a file
        // merely because a temporary soft allowance is smaller than it needs.
        let blocked = self.retry_blocked_since.get_or_insert_with(Instant::now);
        if automatic && blocked.elapsed() < Duration::from_millis(250) { return; }
        if let Some(index) = self.queued.iter().enumerate().filter(|(_, input)| input.transferred_bytes() > 0)
            .max_by_key(|(_, input)| input.transferred_bytes()).map(|(index, _)| index) {
            let input = self.queued.remove(index).unwrap();
            let mut error = Error::new(ErrorCode::ResourceBudgetTooSmall, "memory",
                "Retained originals leave too little memory for this decoder retry. Retry this file after the remaining analysis finishes.");
            error.details = Box::new(serde_json::json!({"retry_after_drain":true}));
            self.finish(input, Err(error));
            self.retry_blocked_since = None;
        }
    }
    fn process(&mut self, next: &mut dyn FnMut() -> Result<EncodeSourcePoll>) -> Result<()> {
        let mut keys = HashSet::new();
        let mut complete = false;
        self.emit(true);
        loop {
            self.check()?;
            if self.external_cancel.is_finishing() && !self.finishing {
                self.finishing = true;
                self.read_cancel.cancel();
                self.queued.retain(|input| input.analysis_started);
                self.jobs.retain(|key, phase| matches!(phase.load(Ordering::Acquire), HASHING | ENCODING)
                    || self.queued.iter().any(|input| &input.source.key == key));
            }
            self.pool.as_mut().unwrap().pause_tick(self.external_cancel.is_paused());
            self.drain()?;
            if let Some(resources) = self.external_cancel.take_resources() { self.update_resources(resources); }
            if self.finishing {
                self.dispatch()?;
                self.release_blocked_retry();
                // Only jobs already admitted to analysis are allowed to finish.
                // Blocked network reads are abandoned, never joined here.
                if self.jobs.is_empty() { break; }
                std::thread::sleep(Duration::from_millis(2));
                continue;
            }
            self.read_cancel.set_paused(self.external_cancel.is_paused());
            if self.external_cancel.is_paused() {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            self.dispatch()?;
            self.read_cancel.set_paused(self.external_cancel.is_paused());
            // Automatic admission allows a bounded read lookahead even when
            // every processing slot holds a waiting retry. A smaller ready
            // original can then run and free RAM for those retries.
            let lookahead = if self.config.memory_ceiling.is_some() { MAX_READERS } else { 0 };
            while !complete && self.jobs.len() < self.pool().capacity().saturating_add(lookahead) && self.reads_in_flight < MAX_READERS {
                self.check()?;
                if self.external_cancel.is_paused() || self.external_cancel.is_finishing() { break; }
                let source = match next()? {
                    EncodeSourcePoll::Pending => break,
                    EncodeSourcePoll::Complete => {
                        complete = true;
                        self.counts.files_total = Some(self.counts.files_discovered);
                        break;
                    }
                    EncodeSourcePoll::Ready(source) => source,
                };
                if source.key.as_os_str().is_empty()
                    || !source
                        .key
                        .components()
                        .all(|c| matches!(c, std::path::Component::Normal(_)))
                    || !keys.insert(source.key.clone())
                {
                    return Err(Error::invalid(
                        "Stream sources require unique relative keys",
                    ));
                }
                let phase = Arc::new(AtomicU8::new(FETCHING));
                self.jobs.insert(source.key.clone(), phase.clone());
                self.counts.files_discovered += 1;
                self.reads_in_flight += 1;
                self.send(Work::Read(source, phase))?;
            }
            self.release_blocked_retry();
            self.emit(false);
            if complete && self.jobs.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        self.emit(true);
        Ok(())
    }
}

pub(super) fn encode(
    config: &EncoderConfig,
    request: &EncodeRequest,
    external_cancel: &CancellationToken,
    next: &mut dyn FnMut() -> Result<EncodeSourcePoll>,
    mut progress: impl FnMut(&Progress),
    mut completed: impl FnMut(&FileRecord) -> Result<()>,
) -> Result<VectorFile> {
    let root = local::resolve_root(&request.directory)?;
    if !local::open_secure(&root)?.metadata()?.is_dir() {
        return Err(Error::invalid("Input must be a directory"));
    }
    let mut cache = HashMap::new();
    if let Some(path) = &request.vectors_file {
        for file in vector_file::read_vectors(&local::resolve_root(path)?)?
            .files
            .into_iter()
            .filter(|r| r.state == FileState::Ready)
        {
            cache.insert(
                (
                    file.file_id.clone().unwrap(),
                    file.profile_id.clone().unwrap(),
                ),
                file,
            );
        }
    }
    if let Some(path) = &request.output_file {
        vector_file::validate_output(&local::resolve_root(path)?)?;
    }
    let temporary = Arc::new(tempfile::Builder::new()
        .prefix("filetwin-")
        .tempdir_in(&config.temp_dir)?);
    let started = Instant::now();
    let mut config = config.clone();
    config.temp_dir = temporary.path().canonicalize()?;
    let mut final_work = WorkCounts::default();
    let mut workers = Vec::new();
    let result = (|| -> Result<VectorFile> {
        let capacity = native::worker_count(&config);
        let bytes = Arc::new(Bytes::default());
        let staging = Arc::new(Staging::new(config.staging_bytes, config.memory_ceiling));
        let analysis = Arc::new(Staging::new(config.memory_bytes, config.memory_ceiling));
        let reader_config = Arc::new(RwLock::new(config.clone()));
        let cancel = CancellationToken::default();
        let read_cancel = CancellationToken::default();
        let (send, receive_read) = mpsc::channel::<Work>();
        let receive_read = Arc::new(Mutex::new(receive_read));
        let (send_text, receive_work) = mpsc::channel::<Work>();
        let receive_work = Arc::new(Mutex::new(receive_work));
        let (events, receive) = mpsc::channel();
        let mut spawn_worker = |receive_work: Arc<Mutex<mpsc::Receiver<Work>>>, worker_cancel: CancellationToken| {
            let events = events.clone();
            let reader_config = reader_config.clone();
            let staging = staging.clone();
            let bytes = bytes.clone(); let temporary = temporary.clone();
            workers.push(std::thread::spawn(move || {
                let _temporary = temporary;
                loop {
                    let work = { receive_work.lock().unwrap().recv() };
                    let Ok(work) = work else { break; };
                    if worker_cancel.is_cancelled() { break; }
                    let config = reader_config.read().unwrap().clone();
                    let event = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match work {
                        Work::Read(source, phase) => {
                            let key = source.key.clone();
                            Event::Read(prepare(source, phase, &config, &staging, &bytes, &worker_cancel), key)
                        }
                        Work::Hash(input) => {
                            let (input, result) = hash_input(input, &bytes, &worker_cancel);
                            Event::Hash(input, result)
                        }
                        Work::Text(input) => {
                            let (input, outcome) = text(input, &bytes, &worker_cancel);
                            Event::Text(input, outcome)
                        }
                    })).unwrap_or(Event::Stopped);
                    if events.send(event).is_err() { break; }
                }
            }));
        };
        for _ in 0..MAX_READERS { spawn_worker(receive_read.clone(), read_cancel.clone()); }
        let mut reader_count = 0;
        let mut grow_readers = |wanted: usize| {
            for _ in reader_count..wanted { spawn_worker(receive_work.clone(), cancel.clone()); }
            reader_count = reader_count.max(wanted);
        };
        grow_readers(capacity);
        let profiles = profile::experimental_profiles_for(config.backend)
            .into_iter()
            .map(|p| (p.family, p.profile_id))
            .collect();
        let mut pipeline = Pipeline {
            staging: staging.clone(),
            analysis: analysis.clone(),
            config: config.clone(),
            reader_config: reader_config.clone(),
            grow_readers: &mut grow_readers,
            external_cancel,
            cancel: cancel.clone(),
            read_cancel: read_cancel.clone(), reads_in_flight: 0, finishing: false,
            pool: Some(native::Pool::new(&config)),
            send: Some(send),
            send_text: Some(send_text),
            receive,
            jobs: HashMap::new(),
            queued: VecDeque::new(),
            native: (0..capacity).map(|_| None).collect(),
            waiters: HashMap::new(),
            cache,
            owners: HashSet::new(),
            profiles,
            counts: Counts::default(),
            bytes: bytes.clone(),
            records: Vec::new(),
            progress: &mut progress,
            completed: &mut completed,
            checkpoint_error: None,
            started,
            last_progress: Instant::now(),
            retry_blocked_since: None,
        };
        let cancelled = match pipeline.process(next) {
            Ok(()) => false,
            Err(e) if e.code == ErrorCode::Cancelled => true,
            Err(e) => return Err(e),
        };
        pipeline.emit(true);
        final_work = pipeline.work();
        let mut files = std::mem::take(&mut pipeline.records);
        files.sort_by_key(|r| r.path.to_path_buf().expect("Generated relative key"));
        Ok(VectorFile {
            format: VECTOR_FILE_FORMAT.into(),
            schema_version: SCHEMA_VERSION,
            directory: FilePath::from_path(&root),
            complete: !cancelled && !pipeline.finishing,
            files,
            summary: Summary {
                counts: pipeline.counts.clone(),
                elapsed_seconds: started.elapsed().as_secs_f64(),
                backend: config.backend,
                workers: pipeline.pool().capacity(),
                cancelled,
            },
        })
    })();
    // Cooperative workers normally stop immediately. Never let a kernel read
    // on an unavailable share hold Finish/Cancel indefinitely. Detached workers
    // retain their input and private directory until they can exit safely.
    let deadline = Instant::now() + Duration::from_millis(200);
    while workers.iter().any(|w| !w.is_finished()) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(2));
    }
    for worker in workers {
        if worker.is_finished() { let _ = worker.join(); }
    }
    drop(temporary);
    let mut result = result?;
    result.summary.elapsed_seconds = started.elapsed().as_secs_f64();
    progress(&Progress {
        stage: if result.summary.cancelled {
            Stage::Cancelled
        } else {
            Stage::Completed
        },
        counts: result.summary.counts.clone(),
        work: Some(WorkCounts { memory_scheduling: final_work.memory_scheduling,
            worker_limit: final_work.worker_limit, memory_limit: final_work.memory_limit,
            original_bytes_read: final_work.original_bytes_read,
            accelerator_limit: final_work.accelerator_limit, ..WorkCounts::default() }),
        elapsed_seconds: result.summary.elapsed_seconds,
    });
    Ok(result)
}

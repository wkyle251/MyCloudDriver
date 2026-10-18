//! Small typed interface shared by the CLI, Rust hosts and portable vector files.
use crate::{Error, ErrorCode, Result, profile::Backend};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

pub const VECTOR_FILE_FORMAT: &str = "filetwin-vectors";
pub const SCHEMA_VERSION: u32 = 1;
pub const MAX_VECTOR_FILE_BYTES: u64 = 512 * 1024 * 1024;

/// The host provides native paths. The library never searches PATH or downloads assets.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RuntimeConfig {
    pub worker_path: Option<PathBuf>,
    pub ffmpeg_path: Option<PathBuf>,
    pub ffprobe_path: Option<PathBuf>,
    pub onnxruntime_path: Option<PathBuf>,
    pub pdfium_path: Option<PathBuf>,
    pub inference_threads: u32,
    pub cuda_device_id: i32,
    pub cuda_library_dirs: Vec<PathBuf>,
}
impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            worker_path: None,
            ffmpeg_path: None,
            ffprobe_path: None,
            onnxruntime_path: None,
            pdfium_path: None,
            inference_threads: 2,
            cuda_device_id: 0,
            cuda_library_dirs: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct EncoderConfig {
    pub model_dir: PathBuf,
    /// Existing parent for disposable processing data; never created by encode.
    pub temp_dir: PathBuf,
    pub runtime: RuntimeConfig,
    pub backend: Backend,
    /// Stream scheduler uses per-file RAM reservations. `workers` is then
    /// only the host's operating-system resource ceiling, not a user quota.
    pub memory_scheduling: bool,
    pub workers: usize,
    /// Legacy CoreML slot limit. Memory scheduling derives slots from the RAM
    /// allowance instead; native decoder copies also have to fit at dispatch.
    pub accelerator_workers: usize,
    /// Optional host-owned compiled-model cache. Never contains scan originals.
    pub inference_cache_dir: Option<PathBuf>,
    /// Shared native admission allowance, not a hard total RSS/GPU memory ceiling.
    pub memory_bytes: u64,
    /// Automatic admission may wait above its current allowance, up to this
    /// physical ceiling. Fixed-budget hosts leave these fields unset.
    pub memory_ceiling: Option<u64>,
    pub total_memory_bytes: Option<u64>,
    pub external_memory: Option<Arc<crate::memory_control::ExternalMemory>>,
    /// Maximum simultaneous private source copies, including protocol reserves.
    pub staging_bytes: u64,
    /// Stage local native inputs in RAM in encode_sources/encode_stream.
    /// Directory encode rejects this mode. Remote memory sources always bypass disk.
    pub memory_staging: bool,
}
impl EncoderConfig {
    /// Potential visual capacity, bounded by the smallest visual decoder's
    /// allowance and the host's OS resource ceiling. Larger readers can admit
    /// fewer concurrent jobs. Reuse these slots to bound retained model caches.
    pub fn accelerator_capacity(&self) -> usize {
        if self.backend != Backend::Coreml { return 0; }
        let limit = if self.memory_scheduling {
            (self.memory_bytes / (512 << 20)).max(1) as usize
        } else { self.accelerator_workers };
        limit.min(crate::native::worker_count(self))
    }

    pub fn new(model_dir: impl Into<PathBuf>, temp_dir: impl Into<PathBuf>) -> Self {
        Self {
            model_dir: model_dir.into(),
            temp_dir: temp_dir.into(),
            runtime: RuntimeConfig::default(),
            backend: Backend::Cpu,
            memory_scheduling: false,
            workers: 2,
            accelerator_workers: 2,
            inference_cache_dir: None,
            memory_bytes: 2 << 30,
            memory_ceiling: None,
            total_memory_bytes: None,
            external_memory: None,
            staging_bytes: 10 << 30,
            memory_staging: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct EncodeRequest {
    pub directory: PathBuf,
    pub vectors_file: Option<PathBuf>,
    /// Reserve an output pathname so it is not included as a source. Encoding
    /// itself never writes the vector file; call write_vectors afterwards.
    pub output_file: Option<PathBuf>,
}
impl EncodeRequest {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
            vectors_file: None,
            output_file: None,
        }
    }
}

/// One explicitly selected input supplied only after a worker slot is free.
/// `key` is a unique relative result identifier; `path` is the readable source.
/// A retained guard can own a downloaded original and is dropped as soon as
/// its result is complete (or after workers stop on cancellation).
pub struct EncodeSource {
    pub key: PathBuf,
    pub path: PathBuf,
    pub(crate) memory: Option<Arc<crate::memory_input::MemoryInput>>,
    pub(crate) seekable: Option<Arc<dyn crate::memory_input::SeekableInput>>,
    guards: Vec<Box<dyn std::any::Any + Send>>,
    resolver: Option<Box<dyn FnOnce(&CancellationToken) -> Result<EncodeSource> + Send>>,
    pub(crate) families: Option<Vec<String>>,
}

/// A live inventory may temporarily have no input without being finished.
/// Pending lets native workers finish and publish progress during discovery.
pub enum EncodeSourcePoll {
    Ready(EncodeSource),
    Pending,
    Complete,
}
impl EncodeSource {
    pub fn new(key: impl Into<PathBuf>, path: impl Into<PathBuf>) -> Self {
        Self {
            key: key.into(),
            path: path.into(),
            memory: None,
            seekable: None,
            guards: Vec::new(),
            resolver: None,
            families: None,
        }
    }
    pub fn from_memory(key: impl Into<PathBuf>, memory: Arc<crate::memory_input::MemoryInput>) -> Self {
        let key = key.into();
        let mut source = Self::new(key.clone(), key);
        source.memory = Some(memory);
        source
    }
    /// Provider-verified seekable media. The implementation owns and bounds its
    /// range cache; this source does not imply a complete original in RAM.
    pub fn from_seekable(key: impl Into<PathBuf>, input: Arc<dyn crate::memory_input::SeekableInput>) -> Self {
        let key = key.into();
        let mut source = Self::new(key.clone(), key);
        source.seekable = Some(input);
        source
    }
    pub fn retaining(mut self, guard: impl std::any::Any + Send) -> Self {
        self.guards.push(Box::new(guard));
        self
    }
    /// Queue metadata now; acquire the original inside an admitted processing
    /// slot. The resolver must observe cancellation and retain its private copy.
    pub fn deferred(key: impl Into<PathBuf>, resolve: impl FnOnce(&CancellationToken) -> Result<EncodeSource> + Send + 'static) -> Self {
        let mut source = Self::new(key, PathBuf::new());
        source.resolver = Some(Box::new(resolve));
        source
    }
    pub fn with_families(mut self, families: Vec<String>) -> Self {
        self.families = Some(families);
        self
    }
    pub(crate) fn resolve(mut self, cancel: &CancellationToken) -> Result<Self> {
        if let Some(resolve) = self.resolver.take() {
            let mut resolved = resolve(cancel)?;
            resolved.key = self.key;
            resolved.families = self.families;
            resolved.guards.extend(self.guards);
            if resolved.resolver.is_some() { return Err(Error::invalid("Nested source resolvers are not supported")); }
            Ok(resolved)
        } else { Ok(self) }
    }
}

/// Scheduling changes never discard queued sources or their RAM leases.
#[derive(Debug, Clone)]
pub struct LiveResources {
    pub workers: usize,
    pub memory_bytes: u64,
    pub staging_bytes: u64,
    pub total_memory_bytes: Option<u64>,
    pub acquisition_paused: bool,
    /// Applied by the coordinator after its source allowance changes, so the
    /// two source banks cannot spend the same borrowed capacity concurrently.
    pub external_memory_bytes: Option<u64>,
}
#[derive(Debug, Default)]
struct LiveControl {
    paused: AtomicBool,
    memory_draining: AtomicBool,
    finishing: AtomicBool,
    resources: Mutex<Option<LiveResources>>,
}
#[derive(Debug, Default, Clone)]
pub struct CancellationToken(Arc<AtomicBool>, Arc<LiveControl>);
impl CancellationToken {
    pub fn set_paused(&self, paused: bool) { self.1.paused.store(paused, Ordering::Release); }
    pub fn is_paused(&self) -> bool { self.1.paused.load(Ordering::Acquire) }
    /// Host pressure may drain held inputs one at a time without user-pausing.
    pub fn set_memory_draining(&self, draining: bool) { self.1.memory_draining.store(draining, Ordering::Release); }
    pub fn is_memory_draining(&self) -> bool { self.1.memory_draining.load(Ordering::Acquire) }
    /// Stop admission, finish already analysing inputs and return a partial vector file.
    /// Unlike cancellation, completed vectors remain eligible for comparison.
    pub fn request_finish(&self) {
        self.1.finishing.store(true, Ordering::Release);
        self.set_paused(false);
    }
    pub fn is_finishing(&self) -> bool { self.1.finishing.load(Ordering::Acquire) }
    pub fn update_resources(&self, resources: LiveResources) { *self.1.resources.lock().unwrap() = Some(resources); }
    pub(crate) fn take_resources(&self) -> Option<LiveResources> { self.1.resources.lock().unwrap().take() }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
    /// Lets hosts pass the same cancellation flag to their existing I/O code.
    pub fn as_atomic(&self) -> &AtomicBool { &self.0 }
    pub(crate) fn check(&self) -> Result<()> {
        if self.is_cancelled() {
            Err(Error::new(
                ErrorCode::Cancelled,
                "encoding",
                "Encoding cancelled",
            ))
        } else {
            Ok(())
        }
    }
}

/// Normal paths are strings. Non-UTF-8 POSIX filenames remain lossless.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(untagged, deny_unknown_fields)]
pub enum FilePath {
    Utf8(String),
    Bytes { encoding: String, base64: String },
}
impl FilePath {
    pub fn from_path(path: &Path) -> Self {
        match path.to_str() {
            Some(s) => Self::Utf8(s.into()),
            None => Self::Bytes {
                encoding: "posix_bytes".into(),
                base64: STANDARD.encode(path.as_os_str().as_bytes()),
            },
        }
    }
    pub fn to_path_buf(&self) -> Result<PathBuf> {
        let bytes = match self {
            Self::Utf8(s) => s.as_bytes().to_vec(),
            Self::Bytes { encoding, base64 } if encoding == "posix_bytes" => STANDARD
                .decode(base64)
                .map_err(|_| Error::invalid("Invalid path Base64"))?,
            _ => return Err(Error::invalid("Unknown path encoding")),
        };
        if bytes.contains(&0) {
            return Err(Error::invalid("NUL in path"));
        }
        Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes)))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum FileState {
    Ready,
    Failed,
    Unsupported,
    Skipped,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FileRecord {
    /// Relative to VectorFile.directory. Paths are labels, never cache lookup keys.
    pub path: FilePath,
    /// SHA-256 of complete original bytes; identical copies share this identifier.
    pub file_id: Option<String>,
    pub bytes: Option<u64>,
    pub state: FileState,
    pub family: Option<String>,
    pub profile_id: Option<String>,
    pub vector: Option<Vec<f32>>,
    pub vector_sha256: Option<String>,
    pub reused: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<Error>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extraction: Option<Value>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Counts {
    pub files_discovered: u64,
    pub files_processed: u64,
    pub files_total: Option<u64>,
    pub files_ready: u64,
    pub files_failed: u64,
    pub files_skipped: u64,
    pub vectors_encoded: u64,
    pub cache_hits: u64,
    pub bytes_read: u64,
    pub bytes_hashed: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Discovering,
    Encoding,
    Completed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Progress {
    pub stage: Stage,
    pub counts: Counts,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work: Option<WorkCounts>,
    pub elapsed_seconds: f64,
}

/// Live phases of admitted files. Reuse waiters do not occupy worker slots.
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
pub struct WorkCounts {
    #[serde(default)]
    pub memory_scheduling: bool,
    #[serde(default)]
    pub accelerator_active: usize,
    #[serde(default)]
    pub accelerator_limit: usize,
    pub fetching: u64,
    pub reading: u64,
    /// Hashing has already handed its original over to Analysis RAM.
    #[serde(default)]
    pub hashing: u64,
    pub encoding: u64,
    /// All read sources ready for decoding, including those waiting for memory
    /// or a processing slot. The wait counters describe the current constraint.
    #[serde(default)]
    pub ready: u64,
    pub waiting_memory: u64,
    #[serde(default)]
    pub waiting_accelerator: u64,
    #[serde(default)]
    pub waiting_worker: u64,
    pub waiting_reuse: u64,
    pub worker_limit: usize,
    pub memory_in_use: u64,
    pub memory_limit: u64,
    #[serde(default)]
    pub original_memory_bytes: u64,
    /// Bytes acquired from source files, excluding hashing and decoder reads.
    #[serde(default)]
    pub original_bytes_read: u64,
    /// Current source/analysis admission demand, including held reservations.
    #[serde(default)]
    pub staging_memory_required: u64,
    #[serde(default)]
    pub analysis_memory_required: u64,
    /// Original bytes in the next analysis job; handoff does not copy them.
    #[serde(default)]
    pub analysis_transfer_bytes: u64,
    #[serde(default)]
    pub analysis_memory_forecast: u64,
    #[serde(default)]
    pub analysis_growth_bytes: u64,
    #[serde(default)]
    pub staging_memory_limit: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Summary {
    pub counts: Counts,
    pub elapsed_seconds: f64,
    pub backend: Backend,
    pub workers: usize,
    pub cancelled: bool,
}

/// This is both the returned result and the optional cache input for another run.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct VectorFile {
    pub format: String,
    pub schema_version: u32,
    pub directory: FilePath,
    /// False on cancellation or an incomplete directory listing. Individual
    /// decoding failures are represented in files even when traversal completes.
    pub complete: bool,
    pub files: Vec<FileRecord>,
    pub summary: Summary,
}

impl VectorFile {
    pub fn exit_code(&self) -> i32 {
        if self.summary.cancelled {
            130
        } else if !self.complete
            || self.summary.counts.files_failed > 0
            || self.summary.counts.files_skipped > 0
        {
            3
        } else {
            0
        }
    }
}

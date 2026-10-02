//! FileTwin content analysis with independent local and PikPak scan scopes.
//! Cloud originals are never modified. Only private temporary copies
//! are downloaded; account credentials and signed URLs never enter a report.

use crate::Client;
use anyhow::{bail, Context, Result};
#[cfg(test)]
use base64::{engine::general_purpose::STANDARD, Engine as _};
use filetwin_core::api::RuntimeConfig;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
#[cfg(test)]
use std::os::unix::ffi::OsStringExt;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    future::Future,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
#[cfg(test)]
use tokio::io::AsyncWriteExt;

const MAX_GROUPS: usize = 2_000;
const MAX_MEMBERS: usize = 20_000;
const MAX_ISSUES: usize = 500;
// Backpressure for prepared originals, not a limit on the scan inventory.
const READY_QUEUE_CAPACITY: usize = 100_000;

#[path = "similarity_groups.rs"]
mod grouping;
pub use grouping::{group_scores, GroupQuery};

#[path = "similarity_encode.rs"]
mod encoding;
#[path = "similarity_format.rs"]
#[cfg(test)]
mod format_filter;
#[path = "similarity_scope.rs"]
mod scope;
#[path = "similarity_store.rs"]
mod store;
#[path = "similarity_cache.rs"]
mod vector_cache;
#[path = "similarity_source_cache.rs"]
mod source_cache;
#[path = "similarity_password.rs"]
mod password;
#[path = "similarity_discovery.rs"]
mod discovery;
#[path = "similarity_inventory.rs"]
mod inventory;
#[path = "similarity_prefetch.rs"]
mod prefetch;
#[path = "similarity_fetch.rs"]
mod fetch;
#[path = "similarity_memory.rs"]
mod memory;
#[path = "similarity_control.rs"]
mod control;
#[path = "similarity_resources.rs"]
mod resources;
#[path = "similarity_checkpoint.rs"]
mod checkpoint;
#[path = "similarity_acceleration.rs"]
mod acceleration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanSource {
    Cloud,
    Local,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudAncestor {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudItem {
    pub id: String,
    pub name: String,
    pub path: String,
    pub is_folder: bool,
    pub size: u64,
    #[serde(default)]
    pub ancestors: Vec<CloudAncestor>,
    #[serde(default)]
    pub revision: Option<String>,
}

/// Provider inventory contains metadata only. The app resolves each ID when
/// an encoder slot requests it; no Photos export or iCloud download is eager.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExternalSource {
    pub id: String,
    pub name: String,
    pub path: String,
    pub size: u64,
    pub local_path: Option<PathBuf>,
    #[serde(default)]
    pub revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_kind: Option<ExternalContentKind>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExternalContentKind {
    #[serde(rename = "photos_preview_1024_v1")]
    PhotosPreview,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScanRequest {
    #[serde(default)]
    pub checkpoint_id: Option<String>,
    #[serde(default)]
    pub parent_pid: Option<u32>,
    pub source: ScanSource,
    #[serde(default)]
    pub local_paths: Vec<PathBuf>,
    #[serde(default)]
    pub cloud_items: Vec<CloudItem>,
    #[serde(default)]
    pub external_sources: Vec<ExternalSource>,
    #[serde(default)]
    pub external_source_stream: Option<PathBuf>,
    /// The host can provide a fresh provider inventory before finalization.
    #[serde(default)]
    pub refresh_inventory: bool,
    pub families: Vec<String>,
    pub threshold: f64,
    pub exact_duplicates: bool,
    /// Accepted for compatibility with older app requests. Dot-prefixed items
    /// are now always outside the similarity scan scope.
    #[serde(default)]
    pub include_hidden: bool,
    pub data_dir: PathBuf,
    pub model_dir: PathBuf,
    pub temp_dir: PathBuf,
    pub report_path: PathBuf,
    pub runtime: RuntimeConfig,
    /// New apps send a hardware-derived snapshot. Older request files retain
    /// their conservative defaults rather than unexpectedly increasing load.
    #[serde(default)]
    pub resources: ScanResources,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct ScanResources {
    pub acceleration: acceleration::Mode,
    /// Admit by per-file memory reservations; `workers` is legacy only.
    pub memory_scheduling: bool,
    pub workers: usize,
    pub memory_bytes: u64,
    /// Original buffers only. Native reader copies belong to analysis memory.
    pub download_memory_bytes: Option<u64>,
    /// Legacy request fields retained for compatibility; source acquisition
    /// now follows worker capacity and does not create input batches.
    pub batch_files: usize,
    pub batch_bytes: u64,
}

impl Default for ScanResources {
    fn default() -> Self {
        Self {
            acceleration: acceleration::Mode::Cpu,
            memory_scheduling: false,
            workers: 2,
            memory_bytes: 1024 * 1024 * 1024,
            download_memory_bytes: None,
            batch_files: 128,
            batch_bytes: 1024 * 1024 * 1024,
        }
    }
}

impl ScanResources {
    fn validate(&self) -> Result<()> {
        if !self.memory_scheduling && !(1..=64).contains(&self.workers) {
            bail!("Similarity workers must be a whole number from 1 to 64.");
        }
        if !((512 << 20)..=(1 << 40)).contains(&self.memory_bytes) {
            bail!("Similarity memory allowance must be from 512 MiB to 1 TiB.");
        }
        if self.download_memory_bytes.is_some_and(|bytes| bytes < (1 << 20) || bytes >= self.memory_bytes) {
            bail!("Download RAM must be positive and smaller than total scan memory.");
        }
        if !(1..=4096).contains(&self.batch_files) {
            bail!("Similarity input batches must contain from 1 to 4,096 files.");
        }
        if !((1 << 20)..=(1 << 40)).contains(&self.batch_bytes) {
            bail!("Similarity input batch size must be from 1 MiB to 1 TiB.");
        }
        Ok(())
    }

    /// Mirrors FileTwin's native admission rule; the allowance is not a hard
    /// ceiling for the entire process or its inference runtime's allocations.
    fn effective_workers(&self) -> usize {
        if self.memory_scheduling {
            return (self.analysis_budget() / (128 << 20)).clamp(1, 8192) as usize;
        }
        self.workers
            .min((self.analysis_budget() / (512 << 20)).max(1) as usize)
            .clamp(1, 64)
    }
    fn download_budget(&self) -> u64 { self.download_memory_bytes.unwrap_or((self.memory_bytes / 4).min(12 << 30)) }
    fn analysis_budget(&self) -> u64 { self.memory_bytes.saturating_sub(self.download_budget()) }
}

impl ScanRequest {
    pub fn validate(&self) -> Result<()> {
        if self.checkpoint_id.as_ref().is_some_and(|id| !checkpoint::valid_id(id)) { bail!("Invalid scan checkpoint identifier."); }
        self.resources.validate()?;
        if !self.threshold.is_finite() || !(0.0..=1.0).contains(&self.threshold) {
            bail!("The similarity score must be between 0 and 1.");
        }
        if self.families.is_empty()
            || self
                .families
                .iter()
                .any(|s| !["text", "image", "audio", "video"].contains(&s.as_str()))
        {
            bail!("Choose at least one supported content type.");
        }
        match self.source {
            ScanSource::Local
                if (self.local_paths.is_empty() && self.external_sources.is_empty() && self.external_source_stream.is_none())
                    || !self.cloud_items.is_empty()
                    || (!self.local_paths.is_empty() && (!self.external_sources.is_empty() || self.external_source_stream.is_some()))
                    || (!self.external_sources.is_empty() && self.external_source_stream.is_some()) =>
            {
                bail!("Choose local files or folders only for a local scan.")
            }
            ScanSource::Cloud
                if self.cloud_items.is_empty()
                    || !self.local_paths.is_empty()
                    || !self.external_sources.is_empty() =>
            {
                bail!("Choose PikPak files or folders only for a cloud scan.")
            }
            _ => {}
        }
        if self.source == ScanSource::Cloud && self.external_source_stream.is_some() {
            bail!("A PikPak scan cannot use a native drive inventory stream.");
        }
        if let Some(stream) = &self.external_source_stream {
            if !stream.is_absolute() || stream.parent().and_then(|p| p.canonicalize().ok()).is_none()
                || stream.parent().and_then(|p| p.canonicalize().ok())
                != self.temp_dir.parent().and_then(|p| p.canonicalize().ok()) {
                bail!("The provider inventory must be inside this scan's private request directory.");
            }
        }
        if self.local_paths.len() + self.cloud_items.len() > 1000 {
            bail!("Choose at most 1,000 scan roots.");
        }
        let mut external_ids = HashSet::new();
        if self.external_sources.iter().any(|file| {
                file.id.is_empty()
                    || file.id.len() > 8192
                    || !external_ids.insert(&file.id)
                    || file
                        .local_path
                        .as_ref()
                        .is_some_and(|path| !path.is_absolute())
            })
        {
            bail!("Choose files with unique provider identifiers and absolute local paths.");
        }
        for path in self.local_paths.iter().chain([
            &self.data_dir,
            &self.model_dir,
            &self.temp_dir,
            &self.report_path,
        ]) {
            if !path.is_absolute() {
                bail!("Scan paths must be absolute.");
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchedFile {
    pub id: String,
    pub name: String,
    pub path: String,
    pub bytes: u64,
    pub family: String,
    pub local_path: Option<String>,
    pub cloud_id: Option<String>,
    pub ancestors: Vec<CloudAncestor>,
    pub engine_index: Option<u64>,
    pub state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchGroup {
    pub id: String,
    pub match_kind: String,
    pub family: String,
    pub minimum_score: Option<f64>,
    pub member_count: u64,
    pub members: Vec<MatchedFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanIssue {
    pub path: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IssueSummary {
    pub category: String,
    pub reason: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanReport {
    pub source: ScanSource,
    pub scope: Vec<String>,
    pub status: String,
    pub threshold: f64,
    pub scanned_files: u64,
    pub analysed_files: u64,
    pub skipped_files: u64,
    #[serde(default)]
    pub unsupported_files: u64,
    #[serde(default)]
    pub failed_files: u64,
    #[serde(default)]
    pub issue_summary: Vec<IssueSummary>,
    pub downloaded_bytes: u64,
    pub total_groups: u64,
    pub groups: Vec<MatchGroup>,
    pub issues: Vec<ScanIssue>,
    pub truncated: bool,
    pub coverage: String,
    pub elapsed_seconds: f64,
    pub files: Vec<MatchedFile>,
    pub run_id: Option<String>,
    pub result_revision: Option<u64>,
    pub scores_retained: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScoreRowRequest {
    pub data_dir: PathBuf,
    pub run_id: String,
    pub result_revision: u64,
    pub file_id: String,
    pub row_offset: u64,
}

/// Query saved measurements only. Locators and temporary paths never leave this
/// adapter; the app joins opaque file IDs to its provider-specific inventory.
pub fn score_row(request: ScoreRowRequest, cancel: &AtomicBool) -> Result<Value> {
    check_cancel(cancel)?;
    let matrix =
        store::SavedMatrix::open(&request.data_dir, &request.run_id, request.result_revision)?;
    matrix.row(&request, cancel)
}

struct StagedCloud {
    files: HashMap<PathBuf, CloudItem>,
    discovered: u64,
    skipped: u64,
    issues: Vec<ScanIssue>,
    issue_summary: Vec<IssueSummary>,
}
impl StagedCloud {
    fn new() -> Self {
        Self {
            files: HashMap::new(),
            discovered: 0,
            skipped: 0,
            issues: vec![],
            issue_summary: vec![],
        }
    }
    fn skip(&mut self, path: &str, reason: &str) {
        self.skipped += 1;
        if let Some(summary) = self.issue_summary.iter_mut().find(|s| s.reason == reason) { summary.count += 1; }
        else { self.issue_summary.push(IssueSummary { category: "failed".into(), reason: reason.into(), count: 1 }); }
        if self.issues.len() < MAX_ISSUES {
            self.issues.push(ScanIssue {
                path: path.into(),
                reason: reason.into(),
            });
        }
    }
}

pub fn emit(event: &Value) -> Result<()> {
    let mut out = std::io::stdout().lock();
    serde_json::to_writer(&mut out, event)?;
    writeln!(out)?;
    out.flush()?;
    Ok(())
}

fn check_cancel(cancel: &AtomicBool) -> Result<()> {
    if cancel.load(Ordering::Acquire) {
        bail!("Scan cancelled.");
    }
    Ok(())
}

async fn cancellable<T>(cancel: &AtomicBool, future: impl Future<Output = Result<T>>) -> Result<T> {
    let timeout = tokio::time::timeout(Duration::from_secs(90), future);
    tokio::pin!(timeout);
    loop {
        check_cancel(cancel)?;
        tokio::select! {
            result = &mut timeout => return result.context("The cloud request timed out.")?,
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }
    }
}

fn private_dir(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    let meta = std::fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        bail!("A private scan directory is unavailable.");
    }
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

/// Called in a dedicated app helper process. Signal handling belongs to the
/// CLI, not FileTwin's embeddable library. Local scans never construct Client.
pub async fn scan(
    request: ScanRequest,
    client: Option<&Client>,
    cancel: Arc<AtomicBool>,
) -> Result<()> {
    request.validate()?;
    // A crashed/quitting GUI must not leave downloads or native children alive.
    struct ParentMonitor(Option<tokio::task::JoinHandle<()>>);
    impl Drop for ParentMonitor { fn drop(&mut self) { if let Some(task)=&self.0 { task.abort(); } } }
    let _monitor = ParentMonitor(request.parent_pid.map(|parent| {
        let stop=cancel.clone();
        tokio::spawn(async move { loop {
            if stop.load(Ordering::Acquire) { return; }
            if rustix::process::getppid().map_or(0, |pid| pid.as_raw_nonzero().get() as u32) != parent { stop.store(true,Ordering::Release); return; }
            tokio::time::sleep(Duration::from_millis(250)).await;
        } })
    }));
    private_dir(&request.data_dir)?;
    private_dir(&request.temp_dir)?;
    // A unique run directory makes cloud downloads, decoder staging and cleanup
    // independent from both transfers and a simultaneous scan of the other source.
    let temporary = tempfile::Builder::new()
        .prefix("similarity-")
        .tempdir_in(&request.temp_dir)?;
    let started = Instant::now();
    let mut report = ScanReport {
        source: request.source,
        scope: match request.source {
            ScanSource::Local => request
                .local_paths
                .iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect(),
            ScanSource::Cloud => request
                .cloud_items
                .iter()
                .map(|item| item.path.clone())
                .collect(),
        },
        status: "completed".into(),
        threshold: request.threshold,
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
    };
    if !cancel.load(Ordering::Acquire) {
        let run_request = request.clone();
        let run_path = temporary.path().to_owned();
        let run_cancel = cancel.clone();
        let run_client = client.cloned();
        let runtime = tokio::runtime::Handle::current();
        // Keep the async I/O driver alive while FileTwin's blocking worker pool
        // pulls cloud files. This also works with a current-thread runtime.
        report = tokio::task::spawn_blocking(move || -> Result<ScanReport> {
            encoding::run(
                &run_request,
                &run_path,
                &run_cancel,
                &mut report,
                started,
                run_client.as_ref(),
                &runtime,
            )?;
            Ok(report)
        })
        .await??;
    }

    if cancel.load(Ordering::Acquire) {
        report.status = if request.checkpoint_id.as_ref().is_some_and(|id| request.data_dir.join("checkpoints").join(id).join("pause").is_file()) { "paused" } else { "cancelled" }.into();
    } else if report.skipped_files > 0 && report.status == "completed" {
        report.status = if report.analysed_files == 0 && report.failed_files > 0 { "failed" } else { "partial" }.into();
    }
    if report.coverage.is_empty() {
        report.coverage = if report.status == "cancelled" {
            "The scan was cancelled; these results are incomplete."
        } else if report.skipped_files > 0 {
            "Some files or folders could not be scanned. Review the skipped items."
        } else {
            "The selected scope was scanned."
        }
        .into();
    }
    report.elapsed_seconds = started.elapsed().as_secs_f64();
    // Drop temporary original copies before reporting completion to the GUI.
    temporary
        .close()
        .context("Could not remove temporary scan copies.")?;
    write_report(&request.report_path, &report)?;
    emit(&json!({"event":"finished", "status":report.status}))?;
    Ok(())
}

#[cfg(test)]
async fn inventory_cloud(request: &ScanRequest, client: &Client, temp: &Path, cancel: &AtomicBool, staged: &mut StagedCloud) -> Result<()> {
    let mut files = HashMap::new();
    discover_cloud(request, client, temp, cancel, staged, &mut |item| {
        files.insert(temp.join(format!("cloud/{:08}", files.len())), item);
        Ok(())
    }).await?;
    staged.files = files;
    Ok(())
}

fn cloud_listing_error(error: &anyhow::Error) -> String {
    match error.downcast_ref::<crate::Error>() {
        Some(crate::Error::Auth(_) | crate::Error::SessionRejected(_) | crate::Error::TokenExpired | crate::Error::NotConfigured(_)) =>
            "PikPak could not authenticate this scan. Check login status in Settings → Accounts and try again.".into(),
        Some(crate::Error::Api { status: 401 | 403, .. }) =>
            "PikPak denied access to this folder. Check the connected account and its login status.".into(),
        Some(crate::Error::Api { status, .. }) => format!("PikPak could not list this folder (HTTP {status}). Try again shortly."),
        Some(crate::Error::Http(_)) => "Could not reach PikPak after retrying. Check your connection and proxy settings.".into(),
        Some(crate::Error::Parse(_)) => "PikPak returned an unreadable folder listing. Try again or update the app.".into(),
        _ => "Could not read this PikPak folder. Check access and try again.".into(),
    }
}

async fn list_scan_folder(client: &Client, id: &str, token: Option<&str>, cancel: &AtomicBool, retry_forever: bool) -> Result<crate::types::FilePage> {
    retry_scan_read(cancel, retry_forever, || async { client.list_folder_page(id, token, 500).await.map_err(Into::into) }).await
}

async fn retry_scan_read<T, F, Fut>(cancel: &AtomicBool, retry_forever: bool, mut read: F) -> Result<T>
where F: FnMut() -> Fut, Fut: std::future::Future<Output = Result<T>> {
    let mut attempt=0u32;
    loop {
        let result = cancellable(cancel, read()).await;
        let retry = match result.as_ref().err().and_then(|e| e.downcast_ref::<crate::Error>()) {
            Some(crate::Error::Http(_)) => true,
            Some(crate::Error::Api { status, .. } | crate::Error::RetryAfter { status, .. }) => crate::download_policy::transient_status(*status),
            _ => false,
        };
        if !retry || (!retry_forever && attempt == 2) {
            if result.is_ok() && attempt > 0 { let _=emit(&json!({"event":"network_wait","waiting":false})); }
            return result;
        }
        let delay=(300u64 * (1 << attempt.min(7))).min(30_000)
            .max(result.as_ref().err().and_then(crate::download_policy::delay).map(|delay| delay.as_millis() as u64).unwrap_or(0));
        let _=emit(&json!({"event":"network_wait","waiting":true,"retry_seconds":delay / 1000}));
        cancellable(cancel, async { tokio::time::sleep(Duration::from_millis(delay)).await; Ok(()) }).await?;
        attempt=attempt.saturating_add(1);
    }
}

async fn discover_cloud(
    request: &ScanRequest,
    client: &Client,
    temp: &Path,
    cancel: &AtomicBool,
    staged: &mut StagedCloud,
    next: &mut dyn FnMut(CloudItem) -> Result<()>,
) -> Result<()> {
    let _ = temp;
    let mut pending: VecDeque<_> = request.cloud_items.clone().into();
    let direct_items: HashSet<_> = request.cloud_items.iter().filter(|f| !f.id.is_empty()).map(|f| f.id.clone()).collect();
    let mut seen = HashSet::new();
    while let Some(mut item) = pending.pop_front() {
        check_cancel(cancel)?;
        if !seen.insert(item.id.clone()) {
            continue;
        }
        if item.name.starts_with('.') {
            continue;
        }
        if direct_items.contains(&item.id) {
            // Direct roots must still exist outside Trash. Fresh cloud
            // metadata also validates reuse for directly selected files.
            let revision = retry_scan_read(cancel, request.checkpoint_id.is_some(), || async {
                client.similarity_file_revision(&item.id, item.ancestors.last().map(|parent| parent.id.as_str()).unwrap_or("")).await.map_err(Into::into)
            }).await;
            let (size, revision) = match revision {
                Ok(value) => value,
                Err(error) if cloud_item_missing(&error) => continue,
                Err(error) => return Err(error),
            };
            item.size=size; item.revision=revision;
        }
        if !item.is_folder {
            staged.discovered += 1;
            next(item)?;
            continue;
        }
        let mut token: Option<String> = None;
        let mut tokens = HashSet::new();
        loop {
            let page = list_scan_folder(client, &item.id, token.as_deref(), cancel, request.checkpoint_id.is_some()).await;
            let page = match page {
                Ok(page) => { let _=emit(&json!({"event":"network_wait","waiting":false})); page },
                Err(error) => {
                    check_cancel(cancel)?;
                    if cloud_item_missing(&error) { break; }
                    if request.checkpoint_id.is_some() {
                        return Err(error.context("The drive could not finish finding files. Reconnect it, then resume."));
                    }
                    staged.skip(&item.path, &cloud_listing_error(&error));
                    break;
                }
            };
            for file in page.files {
                check_cancel(cancel)?;
                if file.name.starts_with('.') { continue; }
                let mut ancestors = item.ancestors.clone();
                if !item.id.is_empty() {
                    ancestors.push(CloudAncestor {
                        id: item.id.clone(),
                        name: item.name.clone(),
                    });
                }
                let child = CloudItem {
                    revision: file.hash.clone().filter(|s| !s.trim().is_empty())
                        .or_else(|| file.modified_time.clone().filter(|s| !s.trim().is_empty())),
                    id: file.id,
                    name: file.name.clone(),
                    path: format!("{}/{}", item.path.trim_end_matches('/'), file.name),
                    is_folder: file.kind.is_folder(),
                    size: file.size,
                    ancestors,
                };
                if child.is_folder {
                    pending.push_back(child);
                } else if seen.insert(child.id.clone()) {
                    staged.discovered += 1;
                    // Feed this page to workers before requesting the next
                    // page or descending into another folder.
                    next(child)?;
                }
            }
            token = page.next_page_token;
            match &token {
                None => break,
                Some(next) if !tokens.insert(next.clone()) => {
                    staged.skip(
                        &item.path,
                        "PikPak repeated a page token. This folder is incomplete.",
                    );
                    break;
                }
                _ => {}
            }
        }
    }
    Ok(())
}

fn cloud_item_missing(error: &anyhow::Error) -> bool {
    matches!(error.downcast_ref::<crate::Error>(), Some(crate::Error::Api { status:404 | 410, .. }))
}

#[cfg(test)]
fn value_path(value: &Value) -> Option<PathBuf> {
    let locator = &value["locator"];
    if let Some(path) = locator["root"].as_str() {
        return Some(path.into());
    }
    let encoded = locator["local_path"]["base64"].as_str()?;
    Some(std::ffi::OsString::from_vec(STANDARD.decode(encoded).ok()?).into())
}

#[cfg(test)]
fn matched_file(value: &Value, staged: &StagedCloud, source: ScanSource) -> Option<MatchedFile> {
    let path = value_path(value)?;
    let cloud = staged.files.get(&path);
    // Never leak a temporary local locator into a cloud result.
    if source == ScanSource::Cloud && cloud.is_none() {
        return None;
    }
    Some(MatchedFile {
        id: value["file_id"].as_str()?.into(),
        name: cloud.map(|f| f.name.clone()).unwrap_or_else(|| {
            path.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into()
        }),
        path: cloud
            .map(|f| f.path.clone())
            .unwrap_or_else(|| path.to_string_lossy().into()),
        bytes: value["bytes"].as_u64().unwrap_or(0),
        family: value["family"].as_str().unwrap_or("other").into(),
        // Non-UTF8 names remain visible but cannot be opened using a lossy path.
        local_path: if source == ScanSource::Local {
            path.to_str().map(String::from)
        } else {
            None
        },
        cloud_id: cloud.map(|f| f.id.clone()),
        ancestors: cloud.map(|f| f.ancestors.clone()).unwrap_or_default(),
        engine_index: None,
        state: value["state"].as_str().unwrap_or("ready").into(),
    })
}

fn write_report(path: &Path, report: &ScanReport) -> Result<()> {
    let parent = path.parent().context("Missing report directory")?;
    private_dir(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.as_file()
        .set_permissions(std::fs::Permissions::from_mode(0o600))?;
    serde_json::to_writer(&mut file, report)?;
    file.flush()?;
    file.persist(path)?;
    Ok(())
}

#[cfg(test)]
#[path = "similarity_adapter_tests.rs"]
mod adapter_tests;

#[cfg(test)]
mod tests {
    #[test]
    fn session_rejection_keeps_cloud_listing_authentication_guidance() {
        let error = anyhow::Error::new(crate::Error::SessionRejected("synthetic private detail"));
        let message = super::cloud_listing_error(&error);
        assert!(message.contains("Check login status"));
        assert!(!message.contains("private detail"));
    }

    use super::*;
    pub(super) fn request(root: &Path) -> ScanRequest {
        ScanRequest {
            checkpoint_id: None, parent_pid: None,
            source: ScanSource::Local,
            local_paths: vec![root.join("files")],
            cloud_items: vec![],
            external_sources: vec![],
            external_source_stream: None,
            refresh_inventory: false,
            families: vec!["text".into()],
            threshold: 0.85,
            exact_duplicates: true,
            include_hidden: false,
            data_dir: root.join("index"),
            model_dir: root.join("models"),
            temp_dir: root.join("tmp"),
            report_path: root.join("output/report.json"),
            runtime: RuntimeConfig::default(),
            resources: ScanResources::default(),
        }
    }
    #[test]
    fn native_inventory_accepts_more_than_100000_files_and_still_rejects_duplicate_ids() {
        let root=tempfile::tempdir().unwrap(); let mut request=request(root.path());
        request.local_paths.clear();
        request.external_sources=(0..100_137).map(|i|ExternalSource { content_kind: None,
            id:format!("asset-{i}"),name:format!("{i}.txt"),path:format!("/Library/{i}.txt"),
            size:1,local_path:None,revision:Some("revision".into()) }).collect();
        request.validate().unwrap();
        let mut report=serde_json::from_value(json!({"source":"local","scope":[],"status":"running","threshold":0.9,
            "scanned_files":0,"analysed_files":0,"skipped_files":0,"downloaded_bytes":0,"total_groups":0,"groups":[],
            "issues":[],"files":[],"scores_retained":0,"truncated":false,"coverage":"","elapsed_seconds":0.0})).unwrap();
        let mut count=0;
        scope::discover(&request,&StagedCloud::new(),&AtomicBool::new(false),&mut report,&mut |_|{count+=1;Ok(())}).unwrap();
        assert_eq!(count,100_137); assert_eq!(report.scanned_files,100_137); assert!(!report.truncated);
        request.external_sources.push(request.external_sources[0].clone());
        assert!(request.validate().is_err());
    }
    #[test]
    fn download_ram_is_an_independent_part_of_total_scan_memory() {
        let legacy: ScanResources = serde_json::from_value(json!({"workers":52,"memory_bytes":48u64 << 30})).unwrap();
        assert_eq!(legacy.download_budget(),12 << 30); assert_eq!(legacy.analysis_budget(),36 << 30);
        let mut limits: ScanResources = serde_json::from_value(json!({"workers":52,"memory_bytes":64u64 << 30,"download_memory_bytes":12u64 << 30})).unwrap();
        limits.validate().unwrap(); assert_eq!(limits.analysis_budget(),52 << 30); assert_eq!(limits.effective_workers(),52);
        limits.download_memory_bytes = Some(0); assert!(limits.validate().is_err());
        limits.download_memory_bytes = Some(64 << 30); assert!(limits.validate().is_err());
        limits.download_memory_bytes = Some(63 << 30); assert_eq!(limits.effective_workers(),2);
    }
    #[test]
    fn memory_scheduling_ignores_legacy_worker_preferences() {
        let mut limits = ScanResources { memory_scheduling:true, workers:1,
            memory_bytes:4 << 30, download_memory_bytes:Some(1 << 30), ..Default::default() };
        limits.validate().unwrap();
        let capacity = limits.effective_workers();
        assert_eq!(capacity,24);
        limits.workers = 0; limits.validate().unwrap(); assert_eq!(limits.effective_workers(),capacity);
        limits.workers = 64; assert_eq!(limits.effective_workers(),capacity);
        limits.memory_bytes = 2 << 30; assert_eq!(limits.effective_workers(),8);
    }
    #[test]
    fn rejects_mixed_sources_and_invalid_thresholds() {
        let dir = tempfile::tempdir().unwrap();
        let mut r = request(dir.path());
        assert!(r.validate().is_ok());
        r.source = ScanSource::Cloud;
        assert!(r.validate().is_err());
        r.source = ScanSource::Local;
        r.threshold = f64::NAN;
        assert!(r.validate().is_err());
        r.threshold = 0.05;
        assert!(r.validate().is_ok());
    }

    #[test]
    fn resource_requests_validate_integer_ranges_and_native_admission() {
        let dir = tempfile::tempdir().unwrap();
        let mut r = request(dir.path());
        r.resources.workers = 64;
        r.resources.memory_bytes = 512 << 20;
        assert!(r.validate().is_ok());
        assert_eq!(r.resources.effective_workers(), 1);
        r.resources.memory_bytes = 8 << 30;
        assert_eq!(r.resources.effective_workers(), 12); // 6 GiB analysis after 2 GiB originals.
        r.resources.workers = 4;
        assert_eq!(r.resources.effective_workers(), 4);
        for invalid in [0, 65] {
            r.resources.workers = invalid;
            assert!(r.validate().is_err());
        }
        r.resources = ScanResources::default();
        for field in ["workers", "memory_bytes", "download_memory_bytes", "batch_files", "batch_bytes"] {
            let mut json = serde_json::to_value(&r).unwrap();
            json["resources"][field] = 1.5.into();
            assert!(serde_json::from_value::<ScanRequest>(json).is_err());
            let mut json = serde_json::to_value(&r).unwrap();
            json["resources"][field] = 0.into();
            assert!(serde_json::from_value::<ScanRequest>(json)
                .unwrap()
                .validate()
                .is_err());
        }
        let mut legacy = serde_json::to_value(&r).unwrap();
        legacy.as_object_mut().unwrap().remove("resources");
        assert_eq!(
            serde_json::from_value::<ScanRequest>(legacy)
                .unwrap()
                .resources,
            ScanResources::default()
        );
    }
    #[tokio::test]
    async fn local_scan_finds_content_without_cloud_credentials_and_cleans_up() {
        let dir = tempfile::tempdir().unwrap();
        let r = request(dir.path());
        std::fs::create_dir(dir.path().join("files")).unwrap();
        let a = "A detailed project proposal describes the new garden, its trees, flowers and summer planting schedule. ".repeat(50);
        for (name, text) in [
            ("original.txt", a.clone()),
            ("copy.txt", a.clone()),
            ("edited.txt", format!("{a}\nRevision: add a pond.")),
            ("different.txt", "0123456789 ABCDEF!".repeat(100)),
        ] {
            std::fs::write(dir.path().join("files").join(name), text).unwrap();
        }
        scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
            .await
            .unwrap();
        let report: ScanReport =
            serde_json::from_slice(&std::fs::read(&r.report_path).unwrap()).unwrap();
        assert_eq!(report.scanned_files, 4);
        assert_eq!(
            report.analysed_files,
            4,
            "{}",
            serde_json::to_string_pretty(&report).unwrap()
        );
        assert!(report
            .groups
            .iter()
            .any(|g| g.match_kind == "byte_identical" && g.members.len() == 2));
        assert_eq!(
            report.files.len(),
            4,
            "Unmatched files remain in the tree inventory"
        );
        assert_eq!(report.scores_retained, 6);
        let original = report
            .files
            .iter()
            .find(|f| f.name == "original.txt")
            .unwrap();
        // Saved rows remain usable after originals have gone away. Changing a
        // display cutoff never re-reads source files or recomputes vectors.
        std::fs::remove_dir_all(&r.local_paths[0]).unwrap();
        let row = score_row(
            ScoreRowRequest {
                data_dir: r.data_dir.clone(),
                run_id: report.run_id.clone().unwrap(),
                result_revision: report.result_revision.unwrap(),
                file_id: original.id.clone(),
                row_offset: original.engine_index.unwrap(),
            },
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(row["entries"].as_array().unwrap().len(), 3);
        for entry in row["entries"].as_array().unwrap() {
            let other = report
                .files
                .iter()
                .find(|f| f.id == entry["file_id"])
                .unwrap();
            let score = entry["score"].as_f64().unwrap();
            match other.name.as_str() {
                "copy.txt" => assert_eq!(score, 1.0),
                "edited.txt" => assert!(score > 0.85 && score < 1.0),
                "different.txt" => assert!(score < 0.85, "Below-cutoff scores are retained"),
                _ => panic!("Unexpected reference or self score"),
            }
        }
        let before = std::fs::read(
            r.data_dir
                .join("runs")
                .join(format!("{}.sqlite3", report.run_id.as_ref().unwrap())),
        )
        .unwrap();
        for cutoff in [0.9, 0.05, 1.0] {
            let grouped = group_scores(
                GroupQuery {
                    data_dir: r.data_dir.clone(),
                    run_id: report.run_id.clone().unwrap(),
                    result_revision: report.result_revision.unwrap(),
                    minimum_score: cutoff,
                    include_identical: true,
                },
                &AtomicBool::new(false),
            )
            .unwrap();
            assert!(!grouped.groups.is_empty());
            assert!(grouped
                .groups
                .iter()
                .all(|g| g.identical || g.minimum_score.unwrap() >= cutoff));
            if cutoff == 1.0 {
                assert!(grouped
                    .groups
                    .iter()
                    .any(|g| g.identical && g.file_ids.len() == 2));
            }
            if cutoff == 0.9 {
                assert!(grouped.groups.iter().any(|g| g.file_ids.len() == 3));
            }
        }
        assert_eq!(
            before,
            std::fs::read(
                r.data_dir
                    .join("runs")
                    .join(format!("{}.sqlite3", report.run_id.as_ref().unwrap()))
            )
            .unwrap(),
            "Regrouping only reads the saved matrix, after originals are removed"
        );
        assert!(score_row(
            ScoreRowRequest {
                data_dir: r.data_dir.clone(),
                run_id: report.run_id.clone().unwrap(),
                result_revision: report.result_revision.unwrap(),
                file_id: "wrong-file".into(),
                row_offset: original.engine_index.unwrap()
            },
            &AtomicBool::new(false)
        )
        .is_err());
        assert!(report
            .groups
            .iter()
            .flat_map(|g| &g.members)
            .all(|f| f.cloud_id.is_none() && f.local_path.is_some()));
        assert_eq!(std::fs::read_dir(&r.temp_dir).unwrap().count(), 0);
        assert_eq!(
            std::fs::metadata(&r.report_path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[tokio::test]
    async fn cancellation_is_reported_without_an_empty_success() {
        let dir = tempfile::tempdir().unwrap();
        let r = request(dir.path());
        scan(r.clone(), None, Arc::new(AtomicBool::new(true)))
            .await
            .unwrap();
        let report: ScanReport =
            serde_json::from_slice(&std::fs::read(&r.report_path).unwrap()).unwrap();
        assert_eq!(report.status, "cancelled");
        assert_eq!(std::fs::read_dir(&r.temp_dir).unwrap().count(), 0);
    }

    #[test]
    fn cloud_results_map_to_originals_not_temporary_paths() {
        let mut staged = StagedCloud::new();
        staged.files.insert(
            PathBuf::from("/private/scan/0001.jpg"),
            CloudItem { revision: None,
                id: "cloud-1".into(),
                name: "Photo.jpg".into(),
                path: "/Albums/Photo.jpg".into(),
                is_folder: false,
                size: 123,
                ancestors: vec![],
            },
        );
        let value = json!({"file_id":"f1","family":"image","bytes":123,"locator":{"root":"/private/scan/0001.jpg"}});
        let file = matched_file(&value, &staged, ScanSource::Cloud).unwrap();
        assert_eq!(file.path, "/Albums/Photo.jpg");
        assert_eq!(file.cloud_id.as_deref(), Some("cloud-1"));
        assert!(file.local_path.is_none());
    }

    #[tokio::test]
    async fn cloud_scan_paginates_deduplicates_without_size_or_download_caps() {
        use std::sync::atomic::AtomicUsize;
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let content = "A project summary about a garden with trees and flowers. ".repeat(20);
        let size = content.len() as u64;
        let downloads = Arc::new(AtomicUsize::new(0));
        let download_count = downloads.clone();
        let server = tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let content = content.clone();
                let download_count = download_count.clone();
                tokio::spawn(async move {
                    let mut data = Vec::new();
                    let mut buffer = [0; 4096];
                    let header = loop {
                        let n = stream.read(&mut buffer).await.unwrap();
                        if n == 0 {
                            return;
                        }
                        data.extend_from_slice(&buffer[..n]);
                        let text = String::from_utf8_lossy(&data);
                        if let Some(end) = text.find("\r\n\r\n") {
                            let length = text[..end]
                                .lines()
                                .find_map(|l| {
                                    l.to_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|n| n.trim().parse::<usize>().unwrap())
                                })
                                .unwrap_or(0);
                            if data.len() >= end + 4 + length {
                                break text[..end].to_string();
                            }
                        }
                    };
                    let route = header.lines().next().unwrap();
                    let response = if route.starts_with("POST /v1/auth/token") {
                        json!({"access_token":"fixture-access", "refresh_token":"fixture-next", "expires_in":3600,"sub":"fixture-user"}).to_string()
                    } else if route.starts_with("POST /v1/shield/captcha/init") {
                        json!({"captcha_token":"fixture-captcha","expires_in":3600}).to_string()
                    } else if route.starts_with("GET /drive/v1/files?") {
                        assert!(
                            !route.contains("hidden"),
                            "Hidden folders must not be listed"
                        );
                        assert!(header
                            .to_lowercase()
                            .contains("authorization: bearer fixture-access"));
                        if route.contains("page_token=second") {
                            json!({"files":[{"id":"b","name":"copy.txt","kind":"drive#file","size":size.to_string()},
                                {"id":"big","name":"large.txt","kind":"drive#file","size":"2147483648"}],"next_page_token":null}).to_string()
                        } else {
                            json!({"files":[{"id":"a","name":"unsafe/../../escape.txt","kind":"drive#file","size":size.to_string()},
                                {"id":"dot-file","name":".DS_Store","kind":"drive#file","size":"1024"},
                                {"id":"hidden","name":".hidden","kind":"drive#folder"}],"next_page_token":"second"}).to_string()
                        }
                    } else if route.starts_with("GET /drive/v1/files/root?") {
                        json!({"id":"root","name":"Root","kind":"drive#folder","trashed":false}).to_string()
                    } else if route.starts_with("GET /drive/v1/files/a?")
                        || route.starts_with("GET /drive/v1/files/b?")
                        || route.starts_with("GET /drive/v1/files/big?")
                    {
                        json!({"id":"file","name":"unsafe/../../escape.txt","size":size.to_string(),"web_content_link":format!("http://{address}/content?signature=fixture-signed-url")}).to_string()
                    } else if route.starts_with("GET /content?") {
                        assert!(
                            !header.to_lowercase().contains("authorization:"),
                            "CDN requests must not receive account authorization"
                        );
                        download_count.fetch_add(1, Ordering::SeqCst);
                        content
                    } else {
                        panic!("Unexpected cloud request: {route}");
                    };
                    let _ = stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",response.len(),response).as_bytes()).await;
                });
            }
        });
        let client = Client::builder()
            .refresh_token("fixture-refresh")
            .device_id("fixture-device")
            .api_base_url(format!("http://{address}"))
            .auth_base_url(format!("http://{address}"))
            .build()
            .unwrap();
        let dir = tempfile::tempdir().unwrap();
        let mut r = request(dir.path());
        r.source = ScanSource::Cloud;
        r.include_hidden = true;
        r.local_paths.clear();
        r.cloud_items = vec![
            CloudItem { revision: None,
                id: "".into(),
                name: "PikPak".into(),
                path: "/".into(),
                is_folder: true,
                size: 0,
                ancestors: vec![],
            },
            CloudItem { revision: None,
                id: "a".into(),
                name: "unsafe/../../escape.txt".into(),
                path: "/../../escape.txt".into(),
                is_folder: false,
                size,
                ancestors: vec![],
            },
            CloudItem { revision: None,
                id: "explicit-dot-file".into(),
                name: ".gitignore".into(),
                path: "/.gitignore".into(),
                is_folder: false,
                size: 1024,
                ancestors: vec![],
            },
            CloudItem { revision: None,
                id: "hidden-root".into(),
                name: ".git".into(),
                path: "/.git".into(),
                is_folder: true,
                size: 0,
                ancestors: vec![],
            },
        ];
        let inventory = tempfile::tempdir_in(dir.path()).unwrap();
        let mut queued = StagedCloud::new();
        inventory_cloud(&r, &client, inventory.path(), &AtomicBool::new(false), &mut queued).await.unwrap();
        assert_eq!(queued.files.len(), 3);
        assert_eq!(downloads.load(Ordering::SeqCst), 0, "Cloud inventory must not fetch queued originals");
        assert!(queued.files.keys().all(|path| !path.exists()));
        inventory.close().unwrap();
        scan(r.clone(), Some(&client), Arc::new(AtomicBool::new(false)))
            .await
            .unwrap();
        let bytes = std::fs::read(&r.report_path).unwrap();
        let report: ScanReport = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(report.status, "completed");
        assert_eq!(report.analysed_files, 3);
        assert_eq!(downloads.load(Ordering::SeqCst), 3);
        assert_eq!(report.skipped_files, 0);
        assert!(report.issues.is_empty());
        assert_eq!(report.downloaded_bytes, size * 3);
        assert!(report
            .groups
            .iter()
            .any(|g| g.match_kind == "byte_identical"));
        assert!(report
            .groups
            .iter()
            .flat_map(|g| &g.members)
            .all(|f| f.cloud_id.is_some() && f.local_path.is_none()));
        let json = String::from_utf8(bytes).unwrap();
        assert!(!json.contains("fixture-access"));
        assert!(!json.contains("fixture-signed-url"));
        assert_eq!(std::fs::read_dir(&r.temp_dir).unwrap().count(), 0);
        assert!(!dir.path().join("escape.txt").exists());
        server.abort();
    }

    #[tokio::test]
    async fn cancellation_interrupts_a_stalled_cloud_request() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let signal = cancelled.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(30)).await;
            signal.store(true, Ordering::SeqCst);
        });
        let started = Instant::now();
        let result = cancellable(&cancelled, async {
            tokio::time::sleep(Duration::from_secs(20)).await;
            Ok(())
        })
        .await;
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}

//! FileTwin content analysis with independent local and PikPak scan scopes.
//! Cloud originals are never modified. Only private temporary copies
//! are downloaded; account credentials and signed URLs never enter a report.

use crate::Client;
use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use filetwin_core::{
    api::{
        Cache, CacheMode, EngineConfig, ExactDuplicates, Filters, JobEvent, JobRequest, JobSummary,
        Limits, ResultsQuery, RuntimeConfig,
    },
    Catalog, Engine, HostServices,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    future::Future,
    io::Write,
    os::unix::{
        ffi::OsStringExt,
        fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tokio::io::AsyncWriteExt;

const MAX_CLOUD_FILES: usize = 100_000;
const MAX_GROUPS: usize = 2_000;
const MAX_MEMBERS: usize = 20_000;
const MAX_ISSUES: usize = 500;

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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScanRequest {
    pub source: ScanSource,
    #[serde(default)]
    pub local_paths: Vec<PathBuf>,
    #[serde(default)]
    pub cloud_items: Vec<CloudItem>,
    pub families: Vec<String>,
    pub threshold: f64,
    pub exact_duplicates: bool,
    pub include_hidden: bool,
    pub data_dir: PathBuf,
    pub model_dir: PathBuf,
    pub temp_dir: PathBuf,
    pub report_path: PathBuf,
    pub runtime: RuntimeConfig,
}

impl ScanRequest {
    pub fn validate(&self) -> Result<()> {
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
            ScanSource::Local if self.local_paths.is_empty() || !self.cloud_items.is_empty() => {
                bail!("Choose local files or folders only for a local scan.")
            }
            ScanSource::Cloud if self.cloud_items.is_empty() || !self.local_paths.is_empty() => {
                bail!("Choose PikPak files or folders only for a cloud scan.")
            }
            _ => {}
        }
        if self.local_paths.len() + self.cloud_items.len() > 1000 {
            bail!("Choose at most 1,000 scan roots.");
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

#[derive(Debug, Serialize, Deserialize)]
pub struct ScanReport {
    pub source: ScanSource,
    pub scope: Vec<String>,
    pub status: String,
    pub threshold: f64,
    pub scanned_files: u64,
    pub analysed_files: u64,
    pub skipped_files: u64,
    pub downloaded_bytes: u64,
    pub total_groups: u64,
    pub groups: Vec<MatchGroup>,
    pub issues: Vec<ScanIssue>,
    pub truncated: bool,
    pub coverage: String,
    pub elapsed_seconds: f64,
}

struct StagedCloud {
    files: HashMap<PathBuf, CloudItem>,
    discovered: u64,
    skipped: u64,
    bytes: u64,
    issues: Vec<ScanIssue>,
}
impl StagedCloud {
    fn new() -> Self {
        Self {
            files: HashMap::new(),
            discovered: 0,
            skipped: 0,
            bytes: 0,
            issues: vec![],
        }
    }
    fn skip(&mut self, path: &str, reason: &str) {
        self.skipped += 1;
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
    private_dir(&request.data_dir)?;
    private_dir(&request.temp_dir)?;
    // A unique run directory makes cloud downloads, decoder staging and cleanup
    // independent from both transfers and a simultaneous scan of the other source.
    let temporary = tempfile::Builder::new()
        .prefix("similarity-")
        .tempdir_in(&request.temp_dir)?;
    let mut staged = StagedCloud::new();
    let started = Instant::now();
    let preparation = match request.source {
        ScanSource::Cloud => {
            let client = client.context("Sign in to PikPak before scanning cloud files.")?;
            stage_cloud(&request, client, temporary.path(), &cancel, &mut staged).await
        }
        ScanSource::Local => Ok(()),
    };
    if preparation.is_err() && !cancel.load(Ordering::Acquire) {
        preparation?;
    }
    let roots: Vec<PathBuf> = match request.source {
        ScanSource::Local => request.local_paths.clone(),
        ScanSource::Cloud => vec![temporary.path().join("cloud")],
    };
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
        scanned_files: staged.discovered,
        analysed_files: 0,
        skipped_files: staged.skipped,
        downloaded_bytes: staged.bytes,
        total_groups: 0,
        groups: vec![],
        issues: staged.issues.clone(),
        truncated: false,
        coverage: String::new(),
        elapsed_seconds: 0.0,
    };
    if !cancel.load(Ordering::Acquire)
        && (request.source == ScanSource::Local || !staged.files.is_empty())
    {
        let mut config = EngineConfig::new(&request.data_dir);
        config.temp_dir = temporary.path().join("workers");
        config.model_dir = request.model_dir.clone();
        config.runtime = request.runtime.clone();
        let engine = Engine::open(config, HostServices::default())?;
        let job = engine.submit(engine_request(&request, roots))?;
        let events = job.events();
        // No GUI thread is involved. The bounded event channel coalesces updates.
        while !job.is_finished() || !events.is_empty() {
            if cancel.load(Ordering::Acquire) {
                job.cancel();
            }
            if let Ok(JobEvent::Progress { data, .. }) =
                events.recv_timeout(Duration::from_millis(100))
            {
                if emit(&engine_progress(
                    &request,
                    &staged,
                    &data,
                    started.elapsed().as_secs_f64(),
                ))
                .is_err()
                {
                    job.cancel_for_output_failure();
                }
            }
        }
        let summary = job.wait()?;
        emit(
            &json!({"event":"progress", "stage":"finishing", "counts":summary.counts,
            "skipped":staged.skipped, "downloaded_bytes":staged.bytes, "elapsed_seconds":started.elapsed().as_secs_f64()}),
        )?;
        collect_report(&request, &staged, &summary, &mut report)?;
    }
    if cancel.load(Ordering::Acquire) {
        report.status = "cancelled".into();
    } else if report.skipped_files > 0 && report.status == "completed" {
        report.status = "partial".into();
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

fn engine_progress(
    request: &ScanRequest,
    staged: &StagedCloud,
    data: &Value,
    elapsed: f64,
) -> Value {
    let work = &data["work"];
    let current = &work["current_file"];
    let file = value_path(current).and_then(|path| {
        let name = if request.source == ScanSource::Cloud {
            staged.files.get(&path)?.name.clone()
        } else {
            path.file_name()?.to_string_lossy().into_owned()
        };
        Some(json!({"name":name, "bytes":current["bytes"]}))
    });
    // Cloud inventory has already completed before downloading. FileTwin's
    // quick inventory of the staged copies belongs to its analysis stage.
    let stage = if request.source == ScanSource::Cloud && data["stage"] == "inventory" {
        "analysing"
    } else if data["stage"] == "comparing" {
        "comparison"
    } else {
        data["stage"].as_str().unwrap_or("analysing")
    };
    json!({"event":"progress", "stage":stage, "counts":data["counts"],
        "completed":work["completed"], "total":work["total"], "current_file":file,
        "file_bytes_read":work["file_bytes_read"], "operation":work["operation"],
        "skipped":staged.skipped, "downloaded_bytes":staged.bytes, "elapsed_seconds":elapsed})
}

fn engine_request(request: &ScanRequest, roots: Vec<PathBuf>) -> JobRequest {
    let mut job = JobRequest::experimental_scan(roots, request.threshold);
    job.families = Some(request.families.clone());
    let profiles = job.profiles.as_mut().expect("experimental profiles");
    profiles.retain(|family, _| request.families.contains(family));
    job.matching
        .as_mut()
        .expect("matching")
        .threshold_overrides
        .retain(|id, _| profiles.values().any(|p| p == id));
    job.recursive = Some(true);
    job.filters = Some(Filters {
        include_hidden: request.include_hidden,
        ..Filters::default()
    });
    job.exact_duplicates = Some(if request.exact_duplicates {
        ExactDuplicates::Compute
    } else {
        ExactDuplicates::Off
    });
    // Refresh forces a content read even for same-size edits with preserved
    // timestamps. FileTwin's strict mode requires immutable revisions, which
    // its local adapter intentionally does not claim to provide.
    job.cache = Some(Cache {
        mode: CacheMode::Refresh,
        ..Cache::default()
    });
    job.limits = Some(Limits {
        memory_bytes: Some(512 * 1024 * 1024),
        // FileTwin requires a signed 64-bit staging allowance. Use its full
        // addressable range, so it does not impose another per-file size cap.
        // Original copies are streamed to disk; decoder memory stays bounded.
        staging_bytes: Some(i64::MAX as u64),
        result_bytes: Some(256 * 1024 * 1024),
        io_workers: Some(2),
        inference_workers: Some(1),
        wall_time_seconds: Some(24 * 60 * 60),
        ..Limits::default()
    });
    job
}

async fn stage_cloud(
    request: &ScanRequest,
    client: &Client,
    temp: &Path,
    cancel: &AtomicBool,
    staged: &mut StagedCloud,
) -> Result<()> {
    let directory = temp.join("cloud");
    private_dir(&directory)?;
    let mut pending: VecDeque<_> = request.cloud_items.clone().into();
    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    emit(&json!({"event":"progress", "stage":"inventory", "completed":0}))?;
    while let Some(item) = pending.pop_front() {
        check_cancel(cancel)?;
        if !seen.insert(item.id.clone()) {
            continue;
        }
        if !request.include_hidden && item.name.starts_with('.') {
            staged.skip(&item.path, "Hidden items are excluded from this scan.");
            continue;
        }
        if !item.is_folder {
            staged.discovered += 1;
            if candidates.len() >= MAX_CLOUD_FILES {
                staged.skip(
                    &item.path,
                    "The scan reached its 100,000-file limit. Choose a smaller folder.",
                );
                break;
            }
            candidates.push(item);
            continue;
        }
        let mut token: Option<String> = None;
        let mut tokens = HashSet::new();
        loop {
            let page = cancellable(cancel, async {
                client
                    .list_folder_page(&item.id, token.as_deref(), 500)
                    .await
                    .map_err(Into::into)
            })
            .await;
            let page = match page {
                Ok(page) => page,
                Err(_) => {
                    check_cancel(cancel)?;
                    staged.skip(&item.path, "Could not read this cloud folder. Check your connection and login, then retry.");
                    break;
                }
            };
            for file in page.files {
                let mut ancestors = item.ancestors.clone();
                if !item.id.is_empty() {
                    ancestors.push(CloudAncestor {
                        id: item.id.clone(),
                        name: item.name.clone(),
                    });
                }
                pending.push_back(CloudItem {
                    id: file.id,
                    name: file.name.clone(),
                    path: format!("{}/{}", item.path.trim_end_matches('/'), file.name),
                    is_folder: file.kind.is_folder(),
                    size: file.size,
                    ancestors,
                });
            }
            emit(
                &json!({"event":"progress", "stage":"inventory", "completed":staged.discovered, "pending":pending.len()}),
            )?;
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
            if seen.len() + pending.len() >= MAX_CLOUD_FILES * 2 {
                staged.skip(
                    &item.path,
                    "The cloud listing limit was reached. Choose a smaller scope.",
                );
                pending.clear();
                break;
            }
        }
    }
    let total = candidates.len();
    for (index, item) in candidates.into_iter().enumerate() {
        check_cancel(cancel)?;
        // Names and IDs are untrusted. Neither can become a filesystem path.
        let extension = Path::new(&item.name)
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .take(16)
            .collect::<String>();
        let path = directory.join(format!("{index:08}.{extension}"));
        emit(&download_progress(
            &item, staged, index, total, 0, item.size,
        ))?;
        match download_copy(client, &item, &path, cancel, staged, index, total).await {
            Ok(()) => {
                staged.files.insert(std::fs::canonicalize(&path)?, item);
            }
            Err(_) => {
                let _ = std::fs::remove_file(&path);
                check_cancel(cancel)?;
                staged.skip(&item.path, "Could not fetch a complete copy. Check your connection, login and available disk space, then retry.");
            }
        }
        emit(
            &json!({"event":"progress", "stage":"downloading", "completed":index+1,
            "total":total, "downloaded_bytes":staged.bytes, "skipped":staged.skipped}),
        )?;
    }
    Ok(())
}

fn download_progress(
    item: &CloudItem,
    staged: &StagedCloud,
    index: usize,
    total: usize,
    written: u64,
    expected: u64,
) -> Value {
    json!({"event":"progress", "stage":"downloading", "current_file":{"name":item.name,"bytes":expected},
        "completed":index, "total":total, "file_bytes_read":written, "operation":"downloading",
        "downloaded_bytes":staged.bytes, "skipped":staged.skipped})
}

#[allow(clippy::too_many_arguments)]
async fn download_copy(
    client: &Client,
    item: &CloudItem,
    path: &Path,
    cancel: &AtomicBool,
    staged: &mut StagedCloud,
    index: usize,
    total: usize,
) -> Result<()> {
    let info = cancellable(cancel, async {
        client.get_download_url(&item.id).await.map_err(Into::into)
    })
    .await?;
    let expected = if info.size > 0 { info.size } else { item.size };
    let response = cancellable(cancel, async {
        client
            .http_client()
            .get(&info.web_content_link)
            .send()
            .await?
            .error_for_status()
            .map_err(Into::into)
    })
    .await?;
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    let mut file = tokio::fs::File::from_std(file);
    let mut stream = response.bytes_stream();
    let mut written = 0u64;
    let mut last = Instant::now();
    while let Some(chunk) = cancellable(cancel, async { Ok(stream.next().await) }).await? {
        let chunk = chunk?;
        // Count received bytes even when a failed/inconsistent response is discarded.
        staged.bytes = staged.bytes.saturating_add(chunk.len() as u64);
        written += chunk.len() as u64;
        file.write_all(&chunk).await?;
        if last.elapsed() >= Duration::from_millis(250) {
            emit(&download_progress(
                item, staged, index, total, written, expected,
            ))?;
            last = Instant::now();
        }
    }
    file.flush().await?;
    if expected > 0 && expected != written {
        bail!("The cloud file changed or the download was incomplete.");
    }
    Ok(())
}

fn value_path(value: &Value) -> Option<PathBuf> {
    let locator = &value["locator"];
    if let Some(path) = locator["root"].as_str() {
        return Some(path.into());
    }
    let encoded = locator["local_path"]["base64"].as_str()?;
    Some(std::ffi::OsString::from_vec(STANDARD.decode(encoded).ok()?).into())
}

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
    })
}

fn visit_results(
    catalog: &Catalog,
    summary: &JobSummary,
    kind: &str,
    group: Option<&str>,
    mut visit: impl FnMut(Value) -> Result<bool>,
) -> Result<bool> {
    let mut cursor = None;
    loop {
        let page = catalog.results(ResultsQuery {
            run_id: summary.run_id.clone(),
            snapshot_id: None,
            result_revision: summary.result_revision,
            kind: kind.into(),
            group_id: group.map(String::from),
            page_size: Some(200),
            cursor,
            ..ResultsQuery::default()
        })?;
        for item in page.items {
            if !visit(item)? {
                return Ok(false);
            }
        }
        cursor = page.next_cursor;
        if cursor.is_none() {
            return Ok(true);
        }
    }
}

fn collect_report(
    request: &ScanRequest,
    staged: &StagedCloud,
    summary: &JobSummary,
    report: &mut ScanReport,
) -> Result<()> {
    report.status = match summary.status.as_str() {
        "cancelled" => "cancelled",
        "failed" => "failed",
        _ if summary.exit_code() == 3 => "partial",
        _ => "completed",
    }
    .into();
    report.scanned_files = if request.source == ScanSource::Cloud {
        staged.discovered
    } else {
        summary.counts.files_discovered
    };
    report.analysed_files = summary.counts.files_ready;
    report.skipped_files =
        staged.skipped + summary.counts.files_failed + summary.counts.files_excluded;
    report.total_groups = summary.counts.groups;
    report.coverage = format!(
        "Source coverage: {}. Comparison coverage: {}.{}",
        summary.completeness.source_coverage,
        summary.completeness.comparison_coverage,
        if staged.skipped > 0 {
            " Some cloud files or folders were skipped before analysis."
        } else {
            ""
        }
    );
    if let Some(error) = &summary.error {
        report.issues.push(ScanIssue {
            path: "Scan".into(),
            reason: format!("{}: {}", error.stage, error.message),
        });
    }
    if summary.result_revision.is_none() || summary.run_id.is_none() {
        return Ok(());
    }
    let catalog = Catalog::open_read_only(&request.data_dir)?;
    let mut member_count = 0;
    report.truncated = !visit_results(&catalog, summary, "groups", None, |group| {
        if report.groups.len() >= MAX_GROUPS || member_count >= MAX_MEMBERS {
            return Ok(false);
        }
        let id = group["group_id"]
            .as_str()
            .context("Missing match group ID")?;
        let mut members = Vec::new();
        visit_results(&catalog, summary, "members", Some(id), |file| {
            if member_count >= MAX_MEMBERS {
                return Ok(false);
            }
            if let Some(file) = matched_file(&file, staged, request.source) {
                members.push(file);
                member_count += 1;
            }
            Ok(true)
        })?;
        report.groups.push(MatchGroup {
            id: id.into(),
            match_kind: group["match_kind"].as_str().unwrap_or("").into(),
            family: group["family"].as_str().unwrap_or("other").into(),
            minimum_score: group["minimum_score"].as_f64(),
            member_count: group["member_count"].as_u64().unwrap_or(0),
            members,
        });
        Ok(true)
    })?;
    report.truncated |= report
        .groups
        .iter()
        .any(|g| g.members.len() < g.member_count as usize);
    let mut errors = HashMap::new();
    visit_results(&catalog, summary, "errors", None, |error| {
        if errors.len() >= MAX_ISSUES {
            return Ok(false);
        }
        if let (Some(id), Some(message)) = (error["file_id"].as_str(), error["message"].as_str()) {
            let reason = match error["code"].as_str().unwrap_or("") {
                "runtime_unavailable" if message.contains("FFmpeg") || message.contains("ffprobe") =>
                    "Install FFmpeg 9 with ffprobe on this Mac to analyse this file type.".to_string(),
                "runtime_unavailable" | "model_integrity" =>
                    "A required analysis component is missing or damaged. Rebuild the app with the verified FileTwin assets.".to_string(),
                "source_changed" => "This file changed during the scan. Run the scan again when changes have finished.".to_string(),
                "worker_timeout" => "Analysis of this file exceeded its time limit.".to_string(),
                _ => message.to_string(),
            };
            errors.insert(id.to_string(), reason);
        }
        Ok(true)
    })?;
    visit_results(&catalog, summary, "files", None, |file| {
        if report.issues.len() >= MAX_ISSUES {
            return Ok(false);
        }
        if file["state"].as_str() != Some("ready") {
            if let Some(path) = value_path(&file) {
                let path = staged
                    .files
                    .get(&path)
                    .map(|f| f.path.clone())
                    .unwrap_or_else(|| {
                        if request.source == ScanSource::Local {
                            path.to_string_lossy().into()
                        } else {
                            "Cloud file".into()
                        }
                    });
                let reason = file["file_id"]
                    .as_str()
                    .and_then(|id| errors.get(id).map(String::as_str))
                    .or(file["reason"].as_str())
                    .or(file["state"].as_str())
                    .unwrap_or("Could not analyse file")
                    .replace('_', " ");
                report.issues.push(ScanIssue { path, reason });
            }
        }
        Ok(true)
    })?;
    Ok(())
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
mod tests {
    use super::*;
    fn request(root: &Path) -> ScanRequest {
        ScanRequest {
            source: ScanSource::Local,
            local_paths: vec![root.join("files")],
            cloud_items: vec![],
            families: vec!["text".into()],
            threshold: 0.85,
            exact_duplicates: true,
            include_hidden: false,
            data_dir: root.join("index"),
            model_dir: root.join("models"),
            temp_dir: root.join("tmp"),
            report_path: root.join("output/report.json"),
            runtime: RuntimeConfig::default(),
        }
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
        let job = engine_request(&r, r.local_paths.clone());
        assert!(job.filters.unwrap().max_bytes.is_none());
        assert_eq!(job.limits.unwrap().staging_bytes, Some(i64::MAX as u64));
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
        assert!(report
            .groups
            .iter()
            .any(|g| g.match_kind == "similar_content" && g.members.len() == 3));
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
            CloudItem {
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
                        assert!(header
                            .to_lowercase()
                            .contains("authorization: bearer fixture-access"));
                        if route.contains("page_token=second") {
                            json!({"files":[{"id":"b","name":"copy.txt","kind":"drive#file","size":size.to_string()},
                                {"id":"big","name":"large.txt","kind":"drive#file","size":"2147483648"}],"next_page_token":null}).to_string()
                        } else {
                            json!({"files":[{"id":"a","name":"unsafe/../../escape.txt","kind":"drive#file","size":size.to_string()},
                                {"id":"hidden","name":".hidden","kind":"drive#folder"}],"next_page_token":"second"}).to_string()
                        }
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
        r.local_paths.clear();
        r.cloud_items = vec![
            CloudItem {
                id: "".into(),
                name: "PikPak".into(),
                path: "/".into(),
                is_folder: true,
                size: 0,
                ancestors: vec![],
            },
            CloudItem {
                id: "a".into(),
                name: "unsafe/../../escape.txt".into(),
                path: "/../../escape.txt".into(),
                is_folder: false,
                size,
                ancestors: vec![],
            },
        ];
        scan(r.clone(), Some(&client), Arc::new(AtomicBool::new(false)))
            .await
            .unwrap();
        let bytes = std::fs::read(&r.report_path).unwrap();
        let report: ScanReport = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(report.status, "partial");
        assert_eq!(report.analysed_files, 3);
        assert_eq!(downloads.load(Ordering::SeqCst), 3);
        assert_eq!(report.skipped_files, 1);
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

    #[test]
    fn progress_maps_cloud_names_and_never_exposes_staging_paths() {
        let dir = tempfile::tempdir().unwrap();
        let mut r = request(dir.path());
        r.source = ScanSource::Cloud;
        let path = dir.path().join("temporary-copy.txt");
        let mut staged = StagedCloud::new();
        staged.files.insert(
            path.clone(),
            CloudItem {
                id: "cloud-file".into(),
                name: "Original.txt".into(),
                path: "/Projects/Original.txt".into(),
                is_folder: false,
                size: 1200,
                ancestors: vec![],
            },
        );
        let data = json!({"stage":"analysing", "counts":{"files_ready":4},
            "work":{"completed":4,"total":16,"operation":"reading","file_bytes_read":600,
                "current_file":{"locator":{"root":path},"bytes":1200}}});
        let progress = engine_progress(&r, &staged, &data, 12.0);
        assert_eq!(progress["current_file"]["name"], "Original.txt");
        assert_eq!(progress["total"], 16);
        assert_eq!(progress["completed"], 4);
        assert_eq!(progress["file_bytes_read"], 600);
        assert!(!progress.to_string().contains("temporary-copy"));
    }

    #[test]
    fn local_inventory_has_a_stable_total_and_reports_all_comparison_work() {
        let dir = tempfile::tempdir().unwrap();
        let r = request(dir.path());
        let files = &r.local_paths[0];
        std::fs::create_dir_all(files.join("nested")).unwrap();
        std::fs::write(
            files.join("a.txt"),
            "a garden with flowers and trees".repeat(10),
        )
        .unwrap();
        std::fs::write(
            files.join("nested/b.txt"),
            "a garden with flowers and trees".repeat(10),
        )
        .unwrap();
        std::fs::write(files.join(".hidden.txt"), "hidden").unwrap();
        // A sparse file over the old 1 GiB cap is still examined. Unsupported
        // content may be skipped by the decoder, but never by a size filter.
        let mut large = std::fs::File::create(files.join("large.gz")).unwrap();
        large.write_all(&[0x1f, 0x8b]).unwrap();
        large.set_len(1024 * 1024 * 1024 + 1).unwrap();
        let mut job = engine_request(&r, r.local_paths.clone());
        job.exact_duplicates = Some(ExactDuplicates::Off);
        let engine = Engine::open(EngineConfig::new(&r.data_dir), HostServices::default()).unwrap();
        let handle = engine.submit(job).unwrap();
        let events = handle.events();
        let mut updates = Vec::new();
        while !handle.is_finished() || !events.is_empty() {
            if let Ok(JobEvent::Progress { data, .. }) =
                events.recv_timeout(Duration::from_millis(50))
            {
                updates.push(data);
            }
        }
        let summary = handle.wait().unwrap();
        assert_eq!(summary.counts.files_ready, 2);
        assert_eq!(summary.counts.files_failed, 1); // unsupported archive
        assert_eq!(summary.counts.files_excluded, 1); // hidden, not oversized
        let analysis: Vec<_> = updates
            .iter()
            .filter(|p| p["stage"] == "analysing")
            .collect();
        assert!(!analysis.is_empty());
        assert!(analysis.iter().all(|p| p["work"]["total"] == 3));
        assert_eq!(analysis.last().unwrap()["work"]["completed"], 3);
        assert!(updates.iter().any(|p| p["stage"] == "comparing"
            && p["work"]["total"] == 1
            && p["work"]["completed"] == 1));
        assert!(updates.iter().any(|p| p["stage"] == "grouping"
            && p["work"]["total"] == 2
            && p["work"]["completed"] == 2));
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

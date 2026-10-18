#[cfg(test)]
mod disk_download_tests;
#[cfg(test)]
mod download_name_tests;
mod download_fs;
mod download_checkpoint;
mod download_cleanup;
mod download_names;
mod download_preparation;
#[cfg(test)]
mod download_preparation_tests;
mod download_receipt;
#[cfg(test)]
mod download_speed_tests;
mod download_transport;
mod download_buffer;
mod download_telemetry;
mod download_verification;
mod duplicate_cross_drive;
mod duplicate_admission;
#[cfg(test)]
mod duplicate_scan_tests;
mod live_downloads;
mod transfer_control;
mod trash_selection;
#[cfg(test)]
mod upload_recovery_tests;
use std::collections::{HashMap, HashSet};
use std::fs::OpenOptions;
use std::future::Future;
use std::io::Write as _;
use std::path::{Path as StdPath, PathBuf};
use std::pin::Pin;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use futures_util::{stream::FuturesUnordered, StreamExt};
use humansize::{format_size, BINARY};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
#[cfg(test)]
use tokio::io::AsyncWriteExt;
#[cfg(test)]
mod guest_disk_tests;
#[cfg(test)]
mod guest_fixture;
use tracing_subscriber::EnvFilter;

use pikpak::auth::OAuthCredentials;
use pikpak::upload_checkpoint::{FolderCheckpoint, UploadCheckpoint};
use pikpak::{Client, Error as PikPakError, FileInfo, FileKind, ShareClient};

#[derive(Debug, Parser)]
#[command(
    name = "pikpak",
    version,
    about = "PikPak cloud storage CLI",
    after_help = "Config via .env or environment:\n  PIKPAK_REFRESH_TOKEN       refresh token from the web UI\n  PIKPAK_REFRESH_TOKEN_FILE  secure alternative containing the refresh token\n  PIKPAK_REFRESH_TOKEN_LOCK_FILE  coordinate rotation across processes\n  PIKPAK_ROTATED_TOKEN_FILE  optional secure output for a rotated token\n  PIKPAK_DEVICE_ID           persistent PikPak device identity\n  PIKPAK_PROXY               optional HTTP(S) proxy URL\n  PIKPAK_CLIENT_ID           optional override OAuth client id\n  PIKPAK_CLIENT_SECRET       optional override OAuth client secret"
)]
struct Cli {
    #[arg(long, global = true)]
    verbose: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Scan local or PikPak content using the bundled FileTwin engine.
    SimilarityScan(SimilarityScanArgs),
    /// Read one file's saved similarity scores without opening originals.
    SimilarityScores(SimilarityScanArgs),
    /// Regroup a saved score matrix without reading original files.
    SimilarityGroups(SimilarityScanArgs),
    /// Verify compared PikPak file metadata without changing files.
    SimilarityPreflight(SimilarityScanArgs),
    /// List files and directories.
    Ls(LsArgs),
    /// Return one JSON page of folder entries for an interactive browser.
    Browse(BrowseArgs),
    /// Stream a read-only, recursive name index for the quick-open palette.
    SearchIndex(SearchIndexArgs),
    /// Return one JSON page from a PikPak share link.
    ShareBrowse(ShareBrowseArgs),
    /// Save selected shared files or folders into this PikPak account.
    ShareSave(ShareSaveArgs),
    /// Return JSON metadata and a short-lived URL for previewing one file.
    Preview(PreviewArgs),
    /// Inspect a ZIP, RAR, or 7z file using PikPak's cloud extractor.
    ArchiveInspect(ArchiveInspectArgs),
    /// Extract selected archive entries beside the source file in PikPak.
    ArchiveExtract(ArchiveExtractArgs),
    /// Return preview metadata for a file in a public PikPak share.
    SharePreview(SharePreviewArgs),
    /// Calculate the recursive byte size of a folder.
    Measure(MeasureArgs),
    /// Calculate a public shared folder's recursive byte size.
    ShareMeasure(ShareMeasureArgs),
    /// Find duplicate files below a folder without downloading them.
    Duplicates(DuplicatesArgs),
    /// Move one or more files or folders to PikPak Trash.
    Trash(TrashArgs),
    /// Apply guarded Undo/Redo changes from the native app's private journal.
    UndoFiles(UndoFilesArgs),
    /// Move one or more files or folders below another PikPak folder.
    Move(MoveArgs),
    /// Rename one file or folder without moving it.
    Rename(RenameArgs),
    /// Merge two or more folders, keeping one folder as the destination.
    MergeFolders(MergeFoldersArgs),
    /// Create one folder below another PikPak folder.
    CreateFolder(CreateFolderArgs),
    /// Recursively move empty descendant folders to PikPak Trash.
    EmptyFolders(EmptyFoldersArgs),
    /// Recursively move exact .DS_Store files to PikPak Trash.
    DsStore(DsStoreArgs),
    /// Download files or folders.
    Download(DownloadArgs),
    /// Consume the native app’s live download queue.
    #[command(hide = true)]
    DownloadQueue(live_downloads::Args),
    /// Download selected files/folders from a public PikPak share.
    ShareDownload(ShareDownloadArgs),
    /// Upload local files or complete folder trees into a PikPak folder.
    Upload(UploadArgs),
    /// Upload verified files from the native torrent RAM buffer.
    #[command(hide = true)]
    TorrentRelay(ManagementArgs),
    /// View storage quota.
    Quota(QuotaArgs),
    /// Check the signed-in account and print its profile as JSON.
    Account,
    /// Check account identity and the browser's verification gate, without listing files.
    CheckConnection,
    /// Manage cloud tasks, owned shares, Trash and account details.
    Manage(ManagementArgs),
}

#[derive(Debug, Parser)]
struct ManagementArgs {
    /// Private JSON request from the native workspace. Credentials stay in their session file.
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Parser)]
struct SimilarityScanArgs {
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Parser)]
struct LsArgs {
    #[arg(long, default_value = "/")]
    path: String,
    #[arg(short = 'l', long)]
    long: bool,
    #[arg(short = 'h', long)]
    human: bool,
}

#[derive(Debug, Parser)]
struct BrowseArgs {
    /// Opaque parent folder id. An empty value means the PikPak root.
    #[arg(long, default_value = "")]
    parent_id: String,
    /// Opaque token returned by the previous page.
    #[arg(long)]
    page_token: Option<String>,
    /// Maximum entries returned in this page (clamped to 1...500).
    #[arg(long, default_value_t = 200)]
    limit: usize,
    /// Include a best-effort quota snapshot in the JSON response.
    #[arg(long, hide = true)]
    with_quota: bool,
}

#[derive(Debug, Parser)]
struct SearchIndexArgs {
    /// Concurrent folder-page requests; intentionally separate from transfers.
    #[arg(long, default_value_t = 4, value_parser = clap::value_parser!(u8).range(1..=8))]
    workers: u8,
}

#[derive(Debug, Parser)]
struct PreviewArgs {
    /// Opaque PikPak file id returned by `browse`.
    #[arg(long)]
    id: String,
    /// Account folder containing the file (required in Guest Mode). Use an empty ID for the root.
    #[arg(long, allow_hyphen_values = true)]
    parent_id: Option<String>,
}

#[derive(Debug, Parser)]
struct ArchiveInspectArgs {
    /// Owner-only JSON request file supplied by the native app.
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Parser)]
struct ArchiveExtractArgs {
    /// Owner-only JSON request file supplied by the native app.
    #[arg(long)]
    request_file: PathBuf,
    /// Emit prefixed JSON progress events for the native macOS UI.
    #[arg(long, hide = true)]
    progress_json: bool,
}

#[derive(Debug, Deserialize, Serialize)]
struct ArchiveInspectInput {
    file_id: String,
    #[serde(default)]
    gcid: String,
    #[serde(default)]
    password: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct ArchiveExtractInput {
    file_id: String,
    #[serde(default)]
    gcid: String,
    #[serde(default)]
    password: String,
    selected_indices: Vec<usize>,
}

#[derive(Debug, Serialize)]
struct ArchiveEntrySummary {
    index: usize,
    name: String,
    path: String,
    kind: String,
    size: u64,
}

#[derive(Debug, Serialize)]
struct ArchiveInspectionResult {
    title: String,
    status: String,
    status_text: String,
    ready: bool,
    required_password: bool,
    entries: Vec<ArchiveEntrySummary>,
}

#[derive(Debug, Serialize)]
struct ArchiveExtractionResult {
    archive_file_id: String,
    output_file_id: String,
    progress: f64,
    phase: String,
}

const ARCHIVE_PROGRESS_PREFIX: &str = "@pikpak-archive-progress:";

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum ArchiveProgressEvent<'a> {
    Started {
        status: &'a str,
    },
    Progress {
        progress: f64,
        phase: &'a str,
    },
    Completed {
        progress: f64,
        output_file_id: &'a str,
    },
}

fn emit_archive_progress(enabled: bool, event: ArchiveProgressEvent<'_>) {
    if !enabled {
        return;
    }
    if let Ok(json) = serde_json::to_string(&event) {
        let mut output = std::io::stderr().lock();
        let _ = writeln!(output, "{ARCHIVE_PROGRESS_PREFIX}{json}");
        let _ = output.flush();
    }
}

#[derive(Debug, Parser)]
struct ShareBrowseArgs {
    /// Owner-only JSON request file supplied by the native app.
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Parser)]
struct ShareSaveArgs {
    /// Owner-only JSON request file supplied by the native app.
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Parser)]
struct SharePreviewArgs {
    /// Owner-only JSON request file supplied by the native app.
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Parser)]
struct ShareMeasureArgs {
    /// Owner-only JSON request file supplied by the native app.
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct ShareAccessInput {
    url: String,
    #[serde(default)]
    pass_code: String,
    #[serde(default)]
    pass_code_token: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct ShareBrowseInput {
    #[serde(flatten)]
    access: ShareAccessInput,
    /// `None` means use an optional folder id embedded in the share URL.
    #[serde(default)]
    parent_id: Option<String>,
    #[serde(default)]
    page_token: Option<String>,
    #[serde(default = "default_share_page_limit")]
    limit: usize,
}

fn default_share_page_limit() -> usize {
    200
}

#[derive(Debug, Deserialize, Serialize)]
struct SharePreviewInput {
    #[serde(flatten)]
    access: ShareAccessInput,
    file_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct ShareMeasureInput {
    #[serde(flatten)]
    access: ShareAccessInput,
    folder_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct ShareSaveInput {
    #[serde(flatten)]
    access: ShareAccessInput,
    file_ids: Vec<String>,
}

#[derive(Debug, Parser)]
struct MeasureArgs {
    /// Opaque PikPak folder id returned by `browse`.
    #[arg(long)]
    id: String,
    /// Owner-only aggregate cache. Only unchanged subtrees may be included.
    #[arg(long, hide = true)]
    cache_file: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct DuplicatesArgs {
    /// Opaque folder id. An empty value scans the complete PikPak root.
    #[arg(long, default_value = "")]
    parent_id: String,
    /// Display path corresponding to parent-id; used only in result paths.
    #[arg(long, default_value = "/")]
    root_path: String,
    /// Emit prefixed JSON scan progress events for the native macOS UI.
    #[arg(long, hide = true)]
    progress_json: bool,
    /// Compare with a folder on this Mac or an external disk. Repeat as needed.
    #[arg(long = "local-path")]
    local_paths: Vec<PathBuf>,
    /// Private native-app scope containing multiple PikPak and disk folders.
    #[arg(long, hide = true)]
    scope_file: Option<PathBuf>,
}

#[derive(Debug, Parser)]
struct TrashArgs {
    /// Opaque PikPak file or folder id. Repeat this option for multiple items.
    #[arg(long = "id")]
    ids: Vec<String>,
    /// JSON array of opaque PikPak file ids (used for large native-app batches).
    #[arg(long)]
    ids_file: Option<PathBuf>,
    /// Confirm moving these items to PikPak Trash.
    #[arg(long)]
    yes: bool,
}

#[derive(Debug, Parser)]
struct UndoFilesArgs {
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Debug, Serialize)]
struct TrashResult {
    trashed_ids: Vec<String>,
}

#[derive(Debug, Parser)]
struct MoveArgs {
    /// Opaque PikPak file or folder id. Repeat this option for multiple items.
    #[arg(long = "id")]
    ids: Vec<String>,
    /// JSON array of opaque PikPak item ids (used for native-app batches).
    #[arg(long)]
    ids_file: Option<PathBuf>,
    /// Opaque destination folder id. An empty value moves to the drive root.
    #[arg(long, default_value = "")]
    to_parent_id: String,
}

#[derive(Debug, Serialize)]
struct MoveResult {
    moved_ids: Vec<String>,
    parent_id: String,
}

#[derive(Debug, Parser)]
struct RenameArgs {
    /// Opaque PikPak file or folder id returned by `browse`.
    #[arg(long)]
    id: String,
    /// New display name for the item.
    #[arg(long)]
    name: String,
}

#[derive(Debug, Serialize)]
struct RenameResult {
    id: String,
    name: String,
}

#[derive(Debug, Parser)]
struct MergeFoldersArgs {
    /// Folder that remains after the merge.
    #[arg(long)]
    destination_id: String,
    /// Folder whose direct children are moved into the destination. Repeat for
    /// every source folder that should disappear after a successful merge.
    #[arg(long = "source-id")]
    source_ids: Vec<String>,
    /// JSON array of source folder ids (used by the native macOS app).
    #[arg(long)]
    source_ids_file: Option<PathBuf>,
    /// Confirm that each source folder may be moved to PikPak Trash once it is
    /// verified empty.
    #[arg(long)]
    yes: bool,
    /// Emit machine-readable merge progress events on stderr.
    #[arg(long)]
    progress_json: bool,
}

#[derive(Debug, Serialize)]
struct MergeFoldersResult {
    destination_id: String,
    merged_source_ids: Vec<String>,
    moved_items: usize,
}

const MERGE_PROGRESS_PREFIX: &str = "@pikpak-merge-progress:";
const MERGE_MOVE_MAX_ROUNDS: u32 = 3;
const MERGE_VERIFY_MAX_ATTEMPTS: u32 = 8;

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum MergeProgressEvent<'a> {
    Preparing {
        source_count: usize,
        total_items: usize,
    },
    SourceStarted {
        source_id: &'a str,
        source_index: usize,
        source_count: usize,
        completed_sources: usize,
        moved_items: usize,
        total_items: usize,
        remaining_items: usize,
    },
    MoveSubmitted {
        source_id: &'a str,
        source_index: usize,
        source_count: usize,
        completed_sources: usize,
        moved_items: usize,
        total_items: usize,
        remaining_items: usize,
    },
    Verifying {
        source_id: &'a str,
        source_index: usize,
        source_count: usize,
        completed_sources: usize,
        moved_items: usize,
        total_items: usize,
        remaining_items: usize,
        attempt: u32,
        max_attempts: u32,
        retry_in_millis: u64,
    },
    SourceCompleted {
        source_id: &'a str,
        source_index: usize,
        source_count: usize,
        completed_sources: usize,
        moved_items: usize,
        total_items: usize,
        remaining_items: usize,
    },
    Completed {
        source_count: usize,
        completed_sources: usize,
        moved_items: usize,
        total_items: usize,
        remaining_items: usize,
    },
}

fn emit_merge_progress(enabled: bool, event: MergeProgressEvent<'_>) {
    if !enabled {
        return;
    }
    if let Ok(json) = serde_json::to_string(&event) {
        let mut output = std::io::stderr().lock();
        let _ = writeln!(output, "{MERGE_PROGRESS_PREFIX}{json}");
        let _ = output.flush();
    }
}

fn merge_verification_backoff(attempt: u32) -> Duration {
    let millis = 250u64.saturating_mul(1u64 << attempt.saturating_sub(1).min(4));
    Duration::from_millis(millis.min(3_000))
}

fn merge_source_is_missing(error: &PikPakError) -> bool {
    match error {
        PikPakError::Api { status: 404, .. } => true,
        PikPakError::Api { message, .. } => {
            let message = message.to_ascii_lowercase();
            message.contains("file_not_found")
                || message.contains("file or folder is not found")
                || message.contains("\"error_code\":5")
        }
        _ => false,
    }
}

#[derive(Debug, Parser)]
struct CreateFolderArgs {
    /// Opaque parent folder id. An empty value creates the folder at root.
    #[arg(long, default_value = "")]
    parent_id: String,
    /// Name of the folder to create.
    #[arg(long)]
    name: String,
}

#[derive(Debug, Serialize)]
struct CreateFolderResult {
    id: String,
    name: String,
    parent_id: String,
}

#[derive(Debug, Parser)]
struct EmptyFoldersArgs {
    /// Opaque folder id. An empty value scans the complete PikPak root.
    #[arg(long, default_value = "")]
    parent_id: String,
    /// Display path corresponding to parent-id; used only in progress/results.
    #[arg(long, default_value = "/")]
    root_path: String,
    /// Confirm moving the discovered empty folders to PikPak Trash.
    #[arg(long)]
    yes: bool,
    /// Emit prefixed JSON progress events for the native macOS UI.
    #[arg(long, hide = true)]
    progress_json: bool,
}

#[derive(Debug, Serialize)]
struct EmptyFolderCleanup {
    root_path: String,
    scanned_folders: usize,
    candidate_folders: usize,
    rechecked_folders: usize,
    skipped_non_empty_folders: usize,
    removed_folders: usize,
    removed_ids: Vec<String>,
}

#[derive(Debug, Clone)]
struct EmptyFolderNode {
    id: String,
    path: String,
    depth: usize,
    child_folder_ids: Vec<String>,
    contains_file: bool,
    has_uninspectable_child: bool,
}

#[derive(Debug, Parser)]
struct DsStoreArgs {
    /// Opaque folder id. An empty value scans the complete PikPak root.
    #[arg(long, default_value = "")]
    parent_id: String,
    /// Display path corresponding to parent-id; used only in results.
    #[arg(long, default_value = "/")]
    root_path: String,
    /// Confirm moving exact .DS_Store files to PikPak Trash.
    #[arg(long)]
    yes: bool,
}

#[derive(Debug, Serialize)]
struct DsStoreCleanup {
    root_path: String,
    scanned_folders: usize,
    candidate_files: usize,
    rechecked_files: usize,
    skipped_files: usize,
    removed_files: usize,
    removed_ids: Vec<String>,
}

#[derive(Debug, Clone)]
struct DsStoreCandidate {
    id: String,
    parent_id: String,
    path: String,
}

const EMPTY_FOLDER_PROGRESS_PREFIX: &str = "@pikpak-empty-folder-progress:";

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum EmptyFolderProgressEvent<'a> {
    ScanStarted {
        root_path: &'a str,
        discovered_folders: usize,
    },
    ScanProgress {
        scanned_folders: usize,
        discovered_folders: usize,
        current_path: &'a str,
    },
    DeleteStarted {
        empty_folders: usize,
    },
    DeleteProgress {
        checked_folders: usize,
        removed_folders: usize,
        skipped_folders: usize,
        empty_folders: usize,
        current_path: &'a str,
    },
}

fn emit_empty_folder_progress(enabled: bool, event: EmptyFolderProgressEvent<'_>) {
    if !enabled {
        return;
    }
    if let Ok(json) = serde_json::to_string(&event) {
        let mut output = std::io::stderr().lock();
        let _ = writeln!(output, "{EMPTY_FOLDER_PROGRESS_PREFIX}{json}");
        let _ = output.flush();
    }
}

#[derive(Debug, Clone)]
struct DuplicateCandidate {
    id: String,
    name: String,
    path: String,
    size: u64,
    modified_time: Option<String>,
    content_hash: Option<String>,
    md5_checksum: Option<String>,
    source: duplicate_cross_drive::DuplicateSource,
    folder_created_time: Option<String>,
    local_identity: Option<duplicate_cross_drive::LocalIdentity>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum DuplicateMatchKind {
    ExactContent,
    MatchingNameAndSize,
}

#[derive(Debug, Serialize)]
struct DuplicateFile {
    id: String,
    name: String,
    path: String,
    size: u64,
    modified_time: Option<String>,
    source: duplicate_cross_drive::DuplicateSource,
    folder_created_time: Option<String>,
    local_identity: Option<duplicate_cross_drive::LocalIdentity>,
}

#[derive(Debug, Serialize)]
struct DuplicateGroup {
    id: String,
    match_kind: DuplicateMatchKind,
    size: u64,
    copies: usize,
    reclaimable_bytes: u64,
    files: Vec<DuplicateFile>,
}

#[derive(Debug, Serialize)]
struct DuplicateScan {
    root_path: String,
    scanned_files: usize,
    scanned_folders: usize,
    failed_folders: usize,
    duplicate_files: usize,
    exact_groups: usize,
    possible_groups: usize,
    reclaimable_bytes: u64,
    groups: Vec<DuplicateGroup>,
}

const DUPLICATE_PROGRESS_PREFIX: &str = "@pikpak-duplicate-progress:";

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum DuplicateProgressEvent<'a> {
    ScanStarted {
        root_path: &'a str,
        discovered_folders: usize,
    },
    ScanProgress {
        scanned_files: usize,
        scanned_folders: usize,
        discovered_folders: usize,
        pending_folders: usize,
        failed_folders: usize,
        current_path: &'a str,
    },
    LocalDiscoveryProgress {
        scanned_files: usize,
        scanned_folders: usize,
        discovered_folders: usize,
        pending_folders: usize,
        failed_folders: usize,
        current_path: &'a str,
    },
    LocalHashProgress {
        scanned_files: usize,
        scanned_folders: usize,
        discovered_folders: usize,
        pending_folders: usize,
        failed_folders: usize,
        current_path: &'a str,
        hashed_bytes: u64,
        active_files: usize,
        pending_files: usize,
    },
    FolderRetrying {
        scanned_files: usize,
        scanned_folders: usize,
        discovered_folders: usize,
        pending_folders: usize,
        failed_folders: usize,
        current_path: &'a str,
        attempt: u32,
        max_attempts: u32,
        retry_in_millis: u64,
    },
    FolderSkipped {
        scanned_files: usize,
        scanned_folders: usize,
        discovered_folders: usize,
        pending_folders: usize,
        failed_folders: usize,
        current_path: &'a str,
    },
}

/// `Client::list_folder` already retries each individual HTTP request. A
/// duplicate scan adds one slower folder-level retry so a brief PikPak outage
/// does not discard everything collected earlier in a long recursive walk.
const DUPLICATE_FOLDER_MAX_ATTEMPTS: u32 = 2;

fn duplicate_folder_backoff(failed_attempt: u32) -> Duration {
    let millis = 3_000u64.saturating_mul(1u64 << failed_attempt.saturating_sub(1).min(2));
    Duration::from_millis(millis.min(12_000))
}

fn duplicate_error_requires_abort(error: &PikPakError) -> bool {
    matches!(
        error,
        PikPakError::Auth(_)
            | PikPakError::SessionRejected(_)
            | PikPakError::TokenExpired
            | PikPakError::NotConfigured(_)
    ) || matches!(error, PikPakError::Api { status: 401, .. })
}

fn duplicate_error_is_transient(error: &PikPakError) -> bool {
    match error {
        PikPakError::Http(error) => {
            error.is_timeout() || error.is_connect() || error.is_request() || error.is_body()
        }
        PikPakError::Api { status, .. } => *status == 429 || *status >= 500,
        PikPakError::RetryAfter { .. } => true,
        _ => false,
    }
}

#[derive(Debug, PartialEq, Eq)]
enum DuplicateFolderFailureAction {
    Abort,
    Retry(Duration),
    Skip,
}

fn duplicate_folder_failure_action(
    error: &PikPakError,
    attempt: u32,
    is_root: bool,
) -> DuplicateFolderFailureAction {
    if duplicate_error_requires_abort(error) {
        return DuplicateFolderFailureAction::Abort;
    }
    if duplicate_error_is_transient(error) && attempt < DUPLICATE_FOLDER_MAX_ATTEMPTS {
        let delay = match error {
            PikPakError::RetryAfter { delay, .. } => duplicate_folder_backoff(attempt).max(*delay),
            _ => duplicate_folder_backoff(attempt),
        };
        return DuplicateFolderFailureAction::Retry(delay);
    }
    if is_root {
        DuplicateFolderFailureAction::Abort
    } else {
        DuplicateFolderFailureAction::Skip
    }
}

fn emit_duplicate_progress(enabled: bool, event: DuplicateProgressEvent<'_>) {
    if !enabled {
        return;
    }
    if let Ok(json) = serde_json::to_string(&event) {
        let mut output = std::io::stderr().lock();
        let _ = writeln!(output, "{DUPLICATE_PROGRESS_PREFIX}{json}");
        let _ = output.flush();
    }
}

#[derive(Debug, Hash, PartialEq, Eq)]
enum DuplicateKey {
    Exact {
        algorithm: &'static str,
        digest: String,
        size: u64,
    },
    Metadata {
        normalized_name: String,
        size: u64,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct FolderMeasurement {
    #[serde(alias = "totalBytes")]
    total_bytes: u64,
    #[serde(alias = "fileCount")]
    file_count: u64,
    #[serde(alias = "folderCount")]
    folder_count: u64,
}

impl FolderMeasurement {
    fn add_file(&mut self, size: u64) {
        self.total_bytes = self.total_bytes.saturating_add(size);
        self.file_count = self.file_count.saturating_add(1);
    }

    fn add_folder(&mut self) {
        self.folder_count = self.folder_count.saturating_add(1);
    }

    fn add_descendant_folder(&mut self, child: &Self) {
        self.total_bytes = self.total_bytes.saturating_add(child.total_bytes);
        self.file_count = self.file_count.saturating_add(child.file_count);
        self.folder_count = self.folder_count.saturating_add(child.folder_count);
        self.add_folder();
    }
}

#[derive(Debug, Default, Serialize)]
struct FolderMeasurementReport {
    #[serde(flatten)]
    root: FolderMeasurement,
    /// Recursive measurements keyed by PikPak folder id. This includes the
    /// requested root and every descendant folder visited by the same scan.
    folders: HashMap<String, FolderMeasurement>,
    /// Direct entries of every listed folder. The app derives each entry's
    /// parent from these, so a separate parent map would only double the size
    /// of a large report.
    listings: HashMap<String, Vec<FolderSizeEntry>>,
    reused_folders: usize,
}

#[derive(Debug, Serialize)]
struct FolderSizeEntry {
    id: String,
    size: u64,
    is_folder: bool,
}

#[derive(Debug, Default, Deserialize)]
struct FolderMeasurementSeed {
    folders: HashMap<String, FolderMeasurement>,
}

#[derive(Debug, Parser)]
struct DownloadArgs {
    /// Remote path to download. Repeat --path to download multiple selections.
    #[arg(long = "path", required_unless_present = "roots_file")]
    paths: Vec<String>,
    /// Owner-only cached selection metadata supplied by the native app.
    #[arg(long, hide = true, conflicts_with = "paths")]
    roots_file: Option<PathBuf>,
    /// Local output directory.
    #[arg(long, default_value = "./downloads")]
    output: String,
    /// Maximum concurrent files; extra connections are kept when throughput improves.
    #[arg(short = 'j', long, default_value_t = 1)]
    jobs: usize,
    /// Emit prefixed JSON progress events for the native macOS UI.
    #[arg(long, hide = true)]
    progress_json: bool,
}

#[derive(Debug, Parser)]
struct ShareDownloadArgs {
    /// Owner-only JSON request file supplied by the native app.
    #[arg(long)]
    request_file: PathBuf,
    /// Local output directory.
    #[arg(long, default_value = "./downloads")]
    output: String,
    /// Maximum concurrent files; extra connections are kept when throughput improves.
    #[arg(short = 'j', long, default_value_t = 1)]
    jobs: usize,
    /// Emit prefixed JSON progress events for the native macOS UI.
    #[arg(long, hide = true)]
    progress_json: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct ShareDownloadRoot {
    id: String,
    name: String,
    #[serde(default)]
    size: u64,
    kind: FileKind,
    path: String,
    #[serde(default)]
    relative_parent: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct AccountDownloadInput {
    roots: Vec<AccountDownloadRootInput>,
}

#[derive(Debug, Deserialize)]
struct AccountDownloadRootInput {
    path: String,
    #[serde(default)]
    file: Option<FileInfo>,
    #[serde(default)]
    relative_parent: Option<Vec<String>>,
}

impl ShareDownloadRoot {
    fn file_info(&self) -> FileInfo {
        FileInfo {
            id: self.id.clone(),
            name: self.name.clone(),
            size: self.size,
            kind: self.kind,
            parent_id: None,
            mime_type: None,
            created_time: None,
            modified_time: None,
            file_extension: None,
            icon_link: None,
            thumbnail_link: None,
            file_category: None,
            hash: None,
            md5_checksum: None,
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct ShareDownloadInput {
    #[serde(flatten)]
    access: ShareAccessInput,
    roots: Vec<ShareDownloadRoot>,
}

#[derive(Debug, Parser)]
struct UploadArgs {
    /// Opaque destination folder id. An empty value means the PikPak root.
    #[arg(long, default_value = "")]
    parent_id: String,
    /// Local file or folder to upload. Repeat this option for multiple sources.
    #[arg(long = "input")]
    inputs: Vec<PathBuf>,
    /// JSON array of local paths (used by the native app for private batches).
    #[arg(long)]
    inputs_file: Option<PathBuf>,
    /// Private per-batch journal used to continue after the app exits.
    #[arg(long, hide = true)]
    checkpoint_dir: Option<PathBuf>,
    /// Maximum concurrent files; extra connections are kept when throughput improves.
    #[arg(short = 'j', long, default_value_t = 4)]
    jobs: usize,
    /// Emit prefixed JSON progress events for the native macOS UI.
    #[arg(long, hide = true)]
    progress_json: bool,
}

const DOWNLOAD_PROGRESS_PREFIX: &str = "@pikpak-progress:";
const DOWNLOAD_QUEUE_BATCH_SIZE: usize = 200;

fn bounded_download_workers(requested: usize, file_count: usize) -> usize {
    if file_count == 0 {
        return 0;
    }
    requested.max(1).min(file_count)
}

const UPLOAD_PROGRESS_PREFIX: &str = "@pikpak-upload-progress:";
const UPLOAD_QUEUE_BATCH_SIZE: usize = 200;
const MAX_UPLOAD_FILE_WORKERS: usize = 64;
/// One complete file attempt sits above the lower-level OSS request retries.
/// This catches a refreshed upload ticket, transient control-plane failure, or
/// an exhausted multipart session without retrying permanent local errors.
const MAX_UPLOAD_FILE_ATTEMPTS: u32 = 3;

fn bounded_upload_file_workers(requested: usize, file_count: usize) -> usize {
    if file_count == 0 {
        return 0;
    }
    requested.clamp(1, MAX_UPLOAD_FILE_WORKERS).min(file_count)
}

#[derive(Debug, Clone)]
struct UploadSource {
    upload_id: String,
    path: PathBuf,
    name: String,
    display_name: String,
    size: u64,
    remote_parent_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PlannedUploadSource {
    path: PathBuf,
    name: String,
    display_name: String,
    size: u64,
    parent_directory: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PlannedUploadDirectory {
    name: String,
    display_name: String,
    parent_directory: Option<usize>,
    depth: usize,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct LocalUploadPlan {
    directories: Vec<PlannedUploadDirectory>,
    files: Vec<PlannedUploadSource>,
    skipped_entries: usize,
}

#[derive(Debug, Serialize)]
struct UploadQueueItem {
    upload_id: String,
    name: String,
    total_bytes: u64,
    source_path: String,
}

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum UploadProgressEvent<'a> {
    DiscoveryStarted,
    FileCommitted {
        file_id: &'a str,
        parent_id: &'a str,
        name: &'a str,
    },
    Plan {
        total_files: usize,
        total_bytes: u64,
        total_folders: usize,
        file_workers: usize,
        multipart_workers: usize,
        skipped_entries: usize,
    },
    FolderProgress {
        created_folders: usize,
        total_folders: usize,
        name: &'a str,
        folder_id: &'a str,
        parent_id: &'a str,
    },
    QueueBatch {
        files: Vec<UploadQueueItem>,
    },
    FileHashing {
        upload_id: &'a str,
        name: &'a str,
        total_bytes: u64,
    },
    FileHashProgress {
        upload_id: &'a str,
        name: &'a str,
        hashed_bytes: u64,
        total_bytes: u64,
    },
    FileStarted {
        upload_id: &'a str,
        name: &'a str,
        uploaded_bytes: u64,
        total_bytes: u64,
    },
    FileProgress {
        upload_id: &'a str,
        name: &'a str,
        uploaded_bytes: u64,
        total_bytes: u64,
    },
    FileRetrying {
        upload_id: &'a str,
        name: &'a str,
        attempt: u32,
        max_attempts: u32,
        retry_in_millis: u64,
    },
    FileCompleted {
        upload_id: &'a str,
        name: &'a str,
        total_bytes: u64,
        instant: bool,
        parent_id: &'a str,
    },
    FileFailed {
        upload_id: &'a str,
        name: &'a str,
        total_bytes: u64,
        source_path: &'a str,
        parent_id: &'a str,
        error: &'a str,
    },
}

#[derive(Debug, Serialize)]
struct DownloadQueueItem<'a> {
    file_id: &'a str,
    name: &'a str,
    total_bytes: u64,
    /// Full remote path used to resolve this file again if the GUI retries
    /// only this queue entry after the original batch has finished.
    remote_path: &'a str,
    /// Exact local directory selected while flattening the remote tree. A
    /// one-file retry uses it so nested downloads resume beside their `.part`
    /// file instead of unexpectedly moving to the download root.
    output_directory: String,
}

#[derive(Debug, Clone)]
struct DownloadTask {
    file: FileInfo,
    output_directory: PathBuf,
    remote_path: String,
    retry_state: Arc<download_transport::RetryState>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum DownloadProgressEvent<'a> {
    BatchFailed {
        retryable: bool,
        retry_in_millis: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        destination_unavailable: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<&'a str>,
    },
    Plan {
        total_files: usize,
        total_bytes: u64,
    },
    QueueBatch {
        files: Vec<DownloadQueueItem<'a>>,
    },
    FileDequeued {
        file_id: &'a str,
        name: &'a str,
        total_bytes: u64,
    },
    FileStarted {
        file_id: &'a str,
        name: &'a str,
        downloaded_bytes: u64,
        transferred_bytes: u64,
        total_bytes: u64,
    },
    /// A finished file is being read to prove it is the original, for example after a backup was restored.
    /// No bytes are transferred, so the app shows verification instead of an idle download.
    FileVerifying {
        file_id: &'a str,
        name: &'a str,
        verified_bytes: u64,
        total_bytes: u64,
    },
    FileProgress {
        file_id: &'a str,
        name: &'a str,
        downloaded_bytes: u64,
        transferred_bytes: u64,
        total_bytes: u64,
    },
    FileRetrying {
        file_id: &'a str,
        name: &'a str,
        attempt: u32,
        retry_in_millis: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        destination_unavailable: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<&'a str>,
    },
    FileCompleted {
        file_id: &'a str,
        name: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        output_path: Option<&'a str>,
        downloaded_bytes: u64,
        transferred_bytes: u64,
        total_bytes: u64,
    },
    FileSkipped {
        file_id: &'a str,
        name: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        output_path: Option<&'a str>,
        downloaded_bytes: u64,
        transferred_bytes: u64,
        total_bytes: u64,
    },
    FileSourceTrashed {
        file_id: &'a str,
        name: &'a str,
        source_file_id: &'a str,
    },
    FileSourceCleanupFailed {
        file_id: &'a str,
        name: &'a str,
        error: &'a str,
    },
    FileFailed {
        error: &'a str,
        file_id: &'a str,
        name: &'a str,
        downloaded_bytes: u64,
        transferred_bytes: u64,
        total_bytes: u64,
        /// Why this file can never be fetched, when the failure proves it. Absent for anything that may clear.
        #[serde(skip_serializing_if = "Option::is_none")]
        permanent: Option<&'static str>,
    },
}

#[derive(Clone)]
struct DownloadProgressContext<'a> {
    enabled: bool,
    file_id: &'a str,
    file_name: &'a str,
    source_file_id: &'a str,
    source_revision: Option<String>,
    require_content_hash: bool,
    guest_range_fallback: bool,
    transferred_bytes: Arc<AtomicU64>,
    batch_received_bytes: Option<Arc<AtomicU64>>,
    retry_state: Arc<download_transport::RetryState>,
}

impl<'a> DownloadProgressContext<'a> {
    fn new(enabled: bool, file_id: &'a str, file_name: &'a str) -> Self {
        Self {
            enabled,
            file_id,
            file_name,
            source_file_id: file_id,
            source_revision: None,
            require_content_hash: false,
            guest_range_fallback: false,
            transferred_bytes: Arc::new(AtomicU64::new(0)),
            batch_received_bytes: None,
            retry_state: Arc::new(download_transport::RetryState::default()),
        }
    }

    fn transferred_bytes(&self) -> u64 {
        self.transferred_bytes.load(Ordering::Relaxed)
    }

    fn emit(&self, downloaded_bytes: u64, total_bytes: u64) {
        emit_download_progress(
            self.enabled,
            DownloadProgressEvent::FileProgress {
                file_id: self.file_id,
                name: self.file_name,
                downloaded_bytes,
                transferred_bytes: self.transferred_bytes(),
                total_bytes,
            },
        );
    }
}

fn emit_download_progress(enabled: bool, event: DownloadProgressEvent<'_>) {
    if !enabled {
        return;
    }
    if let Ok(json) = serde_json::to_string(&event) {
        let mut output = std::io::stdout().lock();
        let _ = writeln!(output, "{DOWNLOAD_PROGRESS_PREFIX}{json}");
        let _ = output.flush();
    }
}

fn emit_upload_progress(enabled: bool, event: UploadProgressEvent<'_>) {
    if !enabled {
        return;
    }
    if let Ok(json) = serde_json::to_string(&event) {
        let mut output = std::io::stdout().lock();
        let _ = writeln!(output, "{UPLOAD_PROGRESS_PREFIX}{json}");
        let _ = output.flush();
    }
}

fn emit_transfer_cancelled(enabled: bool, upload: bool, id: &str, name: &str, size: u64) {
    if !enabled {
        return;
    }
    let mut event =
        serde_json::json!({"event": "file_cancelled", "name": name, "total_bytes": size});
    event[if upload { "upload_id" } else { "file_id" }] = id.into();
    let prefix = if upload {
        UPLOAD_PROGRESS_PREFIX
    } else {
        DOWNLOAD_PROGRESS_PREFIX
    };
    let mut output = std::io::stdout().lock();
    let _ = writeln!(output, "{prefix}{event}");
    let _ = output.flush();
}

#[derive(Debug, Parser)]
struct QuotaArgs {
    /// Print raw byte counts.
    #[arg(long)]
    raw: bool,
    /// Print machine-readable quota JSON for native integrations.
    #[arg(long)]
    json: bool,
    /// Include best-effort account display metadata for the native sidebar.
    #[arg(long, hide = true, requires = "json")]
    with_profile: bool,
    /// Include monthly cloud-download, downstream and upload counters.
    #[arg(long, requires = "json")]
    with_transfer: bool,
}

#[tokio::main]
async fn main() -> ExitCode {
    let _ = dotenvy::dotenv();

    let cli = Cli::parse();
    let telemetry_enabled = matches!(&cli.command, Command::DownloadQueue(_))
        || matches!(&cli.command, Command::Download(args) if args.progress_json)
        || matches!(&cli.command, Command::ShareDownload(args) if args.progress_json);
    let _telemetry = download_telemetry::Telemetry::start(telemetry_enabled);

    let filter = if cli.verbose {
        EnvFilter::new("pikpak=debug")
    } else {
        EnvFilter::try_from_default_env().unwrap_or_else(|_| {
            EnvFilter::new("warn,pikpak::guest=info,pikpak::download_share=info")
        })
    };
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .init();

    match run(cli).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            if let Some(challenge) = e.chain().find_map(|cause| match cause.downcast_ref::<pikpak::Error>() {
                Some(pikpak::Error::VerificationRequired(challenge)) => Some(challenge), _ => None,
            }) {
                if let Ok(json) = serde_json::to_string(challenge) {
                    eprintln!("PikPak verification required: {json}");
                }
            }
            if let Some(reason) = rejected_session_reason(&e) {
                // A stable standalone diagnostic survives anyhow context
                // (e.g. "browse folder failed") without text heuristics in UI.
                eprintln!("PikPak session rejected: {reason}");
            }
            eprintln!("error: {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn rejected_session_reason(error: &anyhow::Error) -> Option<&'static str> {
    error
        .chain()
        .find_map(|cause| match cause.downcast_ref::<pikpak::Error>() {
            Some(pikpak::Error::SessionRejected(reason)) => Some(*reason),
            _ => None,
        })
}

async fn run(cli: Cli) -> Result<()> {
    // The local scanner is usable when signed out and needs no OAuth client.
    let command = match cli.command {
        Command::SimilarityGroups(args) => {
            let request = read_json_request(&args.request_file)?;
            let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
            signal_hook::flag::register(signal_hook::consts::SIGTERM, cancelled.clone())?;
            return pikpak::similarity::emit(&serde_json::to_value(
                pikpak::similarity::group_scores(request, &cancelled)?,
            )?);
        }
        Command::SimilarityScores(args) => {
            let request = read_json_request(&args.request_file)?;
            let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
            signal_hook::flag::register(signal_hook::consts::SIGTERM, cancelled.clone())?;
            return pikpak::similarity::emit(&pikpak::similarity::score_row(request, &cancelled)?);
        }
        Command::SimilarityScan(args) => {
            // Large native inventories use the metadata stream. Retain a byte
            // bound for request parsing, independently of the scan's file count.
            let request: pikpak::similarity::ScanRequest =
                read_json_request_bounded(&args.request_file, 64 * 1024 * 1024)?;
            request.validate()?;
            let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
            signal_hook::flag::register(signal_hook::consts::SIGTERM, cancelled.clone())?;
            signal_hook::flag::register(signal_hook::consts::SIGINT, cancelled.clone())?;
            if request.cloud_items.is_empty() {
                return pikpak::similarity::scan(request, None, cancelled).await;
            }
            let (client, token) = build_client()?;
            let result = pikpak::similarity::scan(request, Some(&client), cancelled).await;
            persist_rotated_token(&client, &token).await;
            return result;
        }
        command => command,
    };

    // Account operations use the app's independently persisted desktop OAuth
    // session. Guest Mode resolves content through separate anonymous shares;
    // neither session touches Safari's Web token chain.
    let (client, original_token) = build_client()?;
    let result = match command {
        Command::SimilarityScan(_) | Command::SimilarityScores(_) | Command::SimilarityGroups(_) => unreachable!("handled before account setup"),
        Command::Ls(args) => cmd_ls(&client, args).await,
        Command::Browse(args) => cmd_browse(&client, args).await,
        Command::SearchIndex(args) => {
            pikpak::search::index_account(client.clone(), args.workers as usize, |event| {
                let mut stdout = std::io::stdout().lock();
                serde_json::to_writer(&mut stdout, &event)?;
                writeln!(stdout)?;
                stdout.flush()
            }).await.map_err(Into::into)
        }
        Command::ShareBrowse(args) => cmd_share_browse(&client, args).await,
        Command::ShareSave(args) => cmd_share_save(&client, args).await,
        Command::Preview(args) => cmd_preview(&client, args).await,
        Command::ArchiveInspect(args) => cmd_archive_inspect(&client, args).await,
        Command::ArchiveExtract(args) => cmd_archive_extract(&client, args).await,
        Command::SharePreview(args) => cmd_share_preview(&client, args).await,
        Command::Measure(args) => cmd_measure(&client, args).await,
        Command::ShareMeasure(args) => cmd_share_measure(&client, args).await,
        Command::Duplicates(args) => cmd_duplicates(&client, args).await,
        Command::Trash(args) => cmd_trash(&client, args).await,
        Command::SimilarityPreflight(args) => cmd_similarity_preflight(&client, args).await,
        Command::UndoFiles(args) => {
            let request = serde_json::from_slice(&tokio::fs::read(args.request_file).await?)?;
            let result = pikpak::file_undo::undo_files(&client, request).await;
            println!("{}", serde_json::to_string(&result)?);
            Ok(())
        },
        Command::Move(args) => cmd_move(&client, args).await,
        Command::Rename(args) => cmd_rename(&client, args).await,
        Command::MergeFolders(args) => cmd_merge_folders(&client, args).await,
        Command::CreateFolder(args) => cmd_create_folder(&client, args).await,
        Command::EmptyFolders(args) => cmd_empty_folders(&client, args).await,
        Command::DsStore(args) => cmd_ds_store(&client, args).await,
        Command::Download(args) => cmd_download(&client, args).await,
        Command::DownloadQueue(args) => live_downloads::run(&client, args).await,
        Command::ShareDownload(args) => cmd_share_download(&client, args).await,
        Command::Upload(args) => cmd_upload(&client, args).await,
        Command::TorrentRelay(args) => async {
            let request: pikpak::torrent_relay::Request = read_json_request_bounded(&args.request_file, 64 * 1024 * 1024)?;
            let parent = request.parent_pid;
            let future = pikpak::torrent_relay::run(&client, request, Arc::new(|event| {
                let mut output = std::io::stdout().lock();
                let _ = writeln!(output, "@torrent-relay:{event}");
                let _ = output.flush();
            }));
            tokio::select! {
                result = transfer_control::run("*", future) => { result??; },
                _ = async move { loop {
                    if let Some(parent) = parent {
                        if rustix::process::getppid().map_or(0, |pid| pid.as_raw_nonzero().get() as u32) != parent { break; }
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                } } => anyhow::bail!("torrent app closed; resume from saved upload receipts"),
            }
            Ok(())
        }.await,
        Command::Quota(args) => cmd_quota(&client, args).await,
        Command::Account => cmd_account(&client, true).await,
        Command::CheckConnection => {
            client.check_drive_access().await.context("drive access check failed")?;
            cmd_account(&client, false).await
        },
        Command::Manage(args) => async {
            let request = read_json_request_bounded(&args.request_file, 1024 * 1024)?;
            let result = client.manage(request).await?;
            println!("{}", serde_json::to_string(&result)?);
            Ok(())
        }.await,
    };
    persist_rotated_token(&client, &original_token).await;
    result
}

fn read_json_request<T: DeserializeOwned>(path: &StdPath) -> Result<T> {
    read_json_request_bounded(path, 8 * 1024 * 1024)
}

fn read_json_request_bounded<T: DeserializeOwned>(path: &StdPath, max_bytes: u64) -> Result<T> {
    let metadata = std::fs::metadata(path)
        .with_context(|| format!("failed to inspect request file {}", path.display()))?;
    if metadata.len() > max_bytes {
        bail!("request file is unexpectedly large");
    }
    let data = std::fs::read(path)
        .with_context(|| format!("failed to read request file {}", path.display()))?;
    serde_json::from_slice(&data).context("request file is not valid JSON")
}

fn build_share_client(access: &ShareAccessInput, account: &Client) -> Result<ShareClient> {
    account
        .share_client(&access.url, &access.pass_code, &access.pass_code_token)
        .context("failed to prepare share client")
}

fn build_client() -> Result<(Client, String)> {
    build_client_with_proxy(None)
}

fn build_client_with_proxy(proxy: Option<&str>) -> Result<(Client, String)> {
    let personal_token = match std::env::var("PIKPAK_PERSONAL_ACCESS_TOKEN_FILE") {
        Ok(path) => Some(load_personal_access_token(&path)?),
        Err(std::env::VarError::NotPresent) => None,
        Err(_) => bail!("PIKPAK_PERSONAL_ACCESS_TOKEN_FILE is invalid"),
    };
    let is_personal = personal_token.is_some();
    let refresh_token = if is_personal {
        String::new()
    } else {
        load_refresh_token()?
    };
    let mut builder = if let Some(token) = personal_token {
        Client::builder().personal_access_token(token)
    } else {
        Client::builder().refresh_token(refresh_token.clone())
    };

    if let Ok(device_id) = std::env::var("PIKPAK_DEVICE_ID") {
        let device_id = device_id.trim();
        if !device_id.is_empty() {
            builder = builder.device_id(device_id);
        }
    }

    if let Some(path) = std::env::var_os("PIKPAK_VERIFICATION_CACHE_FILE").filter(|path| !path.is_empty()) {
        builder = builder.verification_cache(path);
    }

    if let (Ok(token_path), Ok(lock_path)) = (
        std::env::var("PIKPAK_REFRESH_TOKEN_FILE"),
        std::env::var("PIKPAK_REFRESH_TOKEN_LOCK_FILE"),
    ) {
        if !is_personal && !token_path.trim().is_empty() && !lock_path.trim().is_empty() {
            builder = builder.shared_refresh_token_store(token_path, lock_path);
        }
    }

    if let Some(proxy) = proxy
        .map(str::to_owned)
        .or_else(|| std::env::var("PIKPAK_PROXY").ok())
    {
        if !proxy.is_empty() {
            builder = builder.proxy(proxy);
        }
    }

    if let (Ok(id), Ok(secret)) = (
        std::env::var("PIKPAK_CLIENT_ID"),
        std::env::var("PIKPAK_CLIENT_SECRET"),
    ) {
        if !is_personal && !id.is_empty() && !secret.is_empty() {
            builder = builder.credentials(OAuthCredentials::new(id, secret));
        }
    }

    let mode = pikpak::ContentMode::from_settings(
        std::env::var("PIKPAK_CONTENT_MODE").ok().as_deref(),
        std::env::var("PIKPAK_GUEST_MODE").is_ok_and(|value| value == "1"),
    )?;
    let mut client = builder
        .build()
        .context("failed to build API client")?
        .with_content_mode(mode);
    let cache_directory = std::env::var_os("PIKPAK_DUPLICATE_CACHE_DIR")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| {
                let home = PathBuf::from(home);
                if cfg!(target_os = "macos") {
                    home.join("Library/Application Support/My PikPak for Mac/Duplicate Cache")
                } else {
                    std::env::var_os("XDG_CACHE_HOME")
                        .map(PathBuf::from)
                        .unwrap_or_else(|| home.join(".cache"))
                        .join("pikpak/duplicates")
                }
            })
        });
    if let Some(directory) = cache_directory {
        client = client.with_duplicate_cache_directory(directory);
    }
    Ok((client, refresh_token))
}

/// Explicit PAT configuration never falls back to an inherited OAuth session.
/// Keep secrets out of command arguments and process environment listings.
fn load_personal_access_token(path: &str) -> Result<String> {
    if path.trim().is_empty() {
        bail!("PIKPAK_PERSONAL_ACCESS_TOKEN_FILE is empty");
    }
    let metadata =
        std::fs::symlink_metadata(path).context("could not read the Personal Access Token file")?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        bail!("Personal Access Token must be stored in a regular private file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            bail!("Personal Access Token file must have private permissions (0600)");
        }
    }
    let token =
        std::fs::read_to_string(path).context("could not read the Personal Access Token file")?;
    let token = token.trim();
    if token.is_empty() || token.chars().any(char::is_whitespace) {
        bail!("Personal Access Token file is empty or contains whitespace");
    }
    Ok(token.to_owned())
}

/// Read the refresh token from a mode-0600 exchange file when configured.
/// This keeps the credential out of process arguments and environment listings
/// used by the macOS GUI. The legacy environment variable remains supported.
fn load_refresh_token() -> Result<String> {
    if let Ok(path) = std::env::var("PIKPAK_REFRESH_TOKEN_FILE") {
        if !path.trim().is_empty() {
            let token = std::fs::read_to_string(&path)
                .with_context(|| format!("failed to read PIKPAK_REFRESH_TOKEN_FILE at {path}"))?;
            let token = token.trim().to_string();
            if token.is_empty() {
                bail!("PIKPAK_REFRESH_TOKEN_FILE is empty");
            }
            return Ok(token);
        }
    }

    std::env::var("PIKPAK_REFRESH_TOKEN")
        .context("set PIKPAK_REFRESH_TOKEN_FILE, PIKPAK_REFRESH_TOKEN, or .env")
}

/// After a command runs, PikPak may have rotated the refresh token. Persist the
/// new value to `./.env` if present so the stored credential stays valid;
/// otherwise print it so the user can update their environment.
async fn persist_rotated_token(client: &Client, original: &str) {
    if client.tokens().is_personal_access_token() {
        return;
    }
    let current = client.tokens().current_refresh_token().await;
    if current == original {
        return;
    }

    if client.tokens().uses_shared_refresh_store() {
        eprintln!("note: refresh token rotated; shared session updated");
        return;
    }

    if let Ok(path) = std::env::var("PIKPAK_ROTATED_TOKEN_FILE") {
        if !path.trim().is_empty() {
            match write_secret_file(StdPath::new(&path), &current) {
                Ok(()) => eprintln!("note: refresh token rotated; secure credential updated"),
                Err(e) => eprintln!(
                    "warning: refresh token rotated but secure credential output failed ({e})"
                ),
            }
            return;
        }
    }

    match update_env_token(StdPath::new(".env"), &current) {
        Ok(true) => eprintln!("note: refresh token rotated; updated PIKPAK_REFRESH_TOKEN in .env"),
        Ok(false) => {
            eprintln!("note: refresh token rotated; update PIKPAK_REFRESH_TOKEN to:\n  {current}")
        }
        Err(e) => eprintln!(
            "warning: refresh token rotated but .env update failed ({e}); new token:\n  {current}"
        ),
    }
}

/// Atomically write a secret and restrict it to the current user on Unix.
fn write_secret_file(path: &StdPath, secret: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut temporary = path.as_os_str().to_os_string();
    temporary.push(format!(".tmp-{}", std::process::id()));
    let temporary = PathBuf::from(temporary);

    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }

    let mut file = options.open(&temporary)?;
    file.write_all(secret.as_bytes())?;
    file.sync_all()?;
    drop(file);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))?;
    }

    std::fs::rename(&temporary, path)?;
    Ok(())
}

/// Rewrite the `PIKPAK_REFRESH_TOKEN=` line in `env_path`, preserving every
/// other line. Returns `Ok(true)` if the key was found and rewritten, or
/// `Ok(false)` if the file is absent or has no such key.
fn update_env_token(env_path: &StdPath, new_token: &str) -> std::io::Result<bool> {
    if !env_path.exists() {
        return Ok(false);
    }
    let content = std::fs::read_to_string(env_path)?;
    let mut found = false;
    let mut out = String::with_capacity(content.len() + new_token.len());
    for line in content.lines() {
        if line.trim_start().starts_with("PIKPAK_REFRESH_TOKEN=") {
            out.push_str("PIKPAK_REFRESH_TOKEN=");
            out.push_str(new_token);
            found = true;
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    if !found {
        return Ok(false);
    }
    std::fs::write(env_path, out)?;
    Ok(true)
}

async fn cmd_ls(client: &Client, args: LsArgs) -> Result<()> {
    let parent_id = client.resolve_path(&args.path).await?;

    let files: Vec<pikpak::FileInfo> = client
        .list_folder(&parent_id)
        .await
        .context("list_folder failed")?;

    if files.is_empty() {
        println!("(empty)");
        return Ok(());
    }

    if args.long {
        println!("{:<10} {:>12} name", "kind", "size");
        println!("{}", "-".repeat(50));
        for f in &files {
            let kind = if f.kind.is_folder() { "folder" } else { "file" };
            let size = if args.human {
                format_size(f.size, BINARY)
            } else {
                f.size.to_string()
            };
            println!("{kind:<10} {size:>12} {}", f.name);
        }
    } else {
        for f in &files {
            let marker = if f.kind == FileKind::Folder { "/" } else { "" };
            println!("{}{}", f.name, marker);
        }
    }

    Ok(())
}

async fn cmd_browse(client: &Client, args: BrowseArgs) -> Result<()> {
    let page = client
        .list_folder_page(&args.parent_id, args.page_token.as_deref(), args.limit)
        .await
        .context("browse folder failed")?;
    if args.with_quota {
        // Capacity is supplemental browser metadata. A quota outage should not
        // hide an otherwise valid folder page from the native app.
        let (quota_result, profile) = tokio::join!(client.quota(), client.account_profile());
        let quota = match quota_result {
            Ok(quota) => Some(quota),
            Err(error) => {
                eprintln!("warning: storage quota unavailable: {error}");
                None
            }
        };
        // Folder-size results are cached by account in the native app. The
        // token has already been used by the browse request, so this reads the
        // cached `sub` claim without creating a second token rotation.
        let account_id = match client.tokens().user_id().await {
            Ok(account_id) => Some(account_id),
            Err(error) => {
                eprintln!("warning: account identity unavailable: {error}");
                None
            }
        };
        println!(
            "{}",
            serde_json::to_string(&serde_json::json!({
                "files": page.files,
                "next_page_token": page.next_page_token,
                "quota": quota,
                "account_id": account_id,
                "account_profile": profile.ok(),
            }))?
        );
    } else {
        println!("{}", serde_json::to_string(&page)?);
    }
    Ok(())
}

async fn cmd_share_browse(account: &Client, args: ShareBrowseArgs) -> Result<()> {
    let request: ShareBrowseInput = read_json_request(&args.request_file)?;
    let client = build_share_client(&request.access, account)?;
    let page = if let Some(parent_id) = request.parent_id {
        client
            .list_folder_page(&parent_id, request.page_token.as_deref(), request.limit)
            .await
    } else {
        client
            .list_initial_folder_page(request.page_token.as_deref(), request.limit)
            .await
    }
    .context("browse shared folder failed")?;
    println!("{}", serde_json::to_string(&page)?);
    Ok(())
}

async fn cmd_share_save(account: &Client, args: ShareSaveArgs) -> Result<()> {
    let request: ShareSaveInput = read_json_request(&args.request_file)?;
    let share_client = build_share_client(&request.access, account)?;
    let pass_code_token = if request.access.pass_code_token.trim().is_empty()
        && !request.access.pass_code.trim().is_empty()
    {
        let parent_id = share_client.parsed_link().initial_parent_id.clone();
        share_client
            .list_folder_page(&parent_id, None, 1)
            .await
            .context("validate shared-folder access code before save")?;
        share_client.pass_code_token().await
    } else {
        request.access.pass_code_token
    };
    let result = pikpak::share_save_duplicates::save_unique_shared_files(
        account,
        &share_client,
        &pass_code_token,
        &request.file_ids,
    )
    .await
    .context("save shared selection failed")?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

async fn cmd_preview(client: &Client, args: PreviewArgs) -> Result<()> {
    let preview = client
        .get_preview_info_in_parent(&args.id, args.parent_id.as_deref())
        .await
        .context("preview metadata failed")?;
    println!("{}", serde_json::to_string(&preview)?);
    Ok(())
}

async fn cmd_archive_inspect(client: &Client, args: ArchiveInspectArgs) -> Result<()> {
    let request: ArchiveInspectInput = read_json_request(&args.request_file)?;
    let gcid = client
        .resolve_archive_gcid(&request.file_id, &request.gcid)
        .await
        .context("resolve archive content identifier failed")?;
    let listing = client
        .list_archive(&request.file_id, &gcid, "", &request.password)
        .await
        .context("inspect cloud archive failed")?;
    let status = listing.status.trim().to_string();
    let normalized_status = status.to_ascii_uppercase();
    let required_password = matches!(
        normalized_status.as_str(),
        "PASS_WORD_EMPTY" | "PASS_WORD_ERROR" | "PASSWORD_EMPTY" | "PASSWORD_ERROR"
    );
    let ready = normalized_status == "OK" || (status.is_empty() && !listing.files.is_empty());
    let entries = if ready {
        listing
            .files
            .iter()
            .enumerate()
            .map(|(index, entry)| archive_entry_summary(entry, index))
            .collect()
    } else {
        Vec::new()
    };
    let title = if listing.title.trim().is_empty() {
        "Archive contents".to_string()
    } else {
        listing.title
    };
    println!(
        "{}",
        serde_json::to_string(&ArchiveInspectionResult {
            title,
            status,
            status_text: listing.status_text,
            ready,
            required_password,
            entries,
        })?
    );
    Ok(())
}

async fn cmd_archive_extract(client: &Client, args: ArchiveExtractArgs) -> Result<()> {
    const MAX_EXTRACTION_WAIT: Duration = Duration::from_secs(24 * 60 * 60);

    let request: ArchiveExtractInput = read_json_request(&args.request_file)?;
    let gcid = client
        .resolve_archive_gcid(&request.file_id, &request.gcid)
        .await
        .context("resolve archive content identifier failed")?;
    let listing = client
        .list_archive(&request.file_id, &gcid, "", &request.password)
        .await
        .context("recheck cloud archive before extraction")?;
    let status = listing.status.trim().to_ascii_uppercase();
    let listing_ready = status == "OK" || (status.is_empty() && !listing.files.is_empty());
    if !listing_ready {
        let message = nonempty_archive_message(&listing.status_text, "archive is not ready");
        bail!("PikPak could not open this archive [{status}]: {message}");
    }

    let mut selected_indices = request.selected_indices;
    selected_indices.sort_unstable();
    selected_indices.dedup();
    if selected_indices.is_empty() {
        bail!("select at least one archive entry to extract");
    }
    let mut selected_files = Vec::with_capacity(selected_indices.len());
    for index in selected_indices {
        let entry = listing.files.get(index).cloned().with_context(|| {
            format!(
                "archive entry {index} no longer exists; inspect the archive again before retrying"
            )
        })?;
        selected_files.push(entry);
    }

    let task = client
        .start_archive_extraction(&request.file_id, &gcid, &request.password, &selected_files)
        .await
        .context("start PikPak cloud extraction failed")?;
    let task_status = task.status.trim().to_ascii_uppercase();
    if task_status == "NEED_MORE_QUOTA" {
        bail!(
            "PikPak rejected cloud extraction [NEED_MORE_QUOTA]: Premium extraction quota is required"
        );
    }
    if task.task_id.trim().is_empty() {
        let message = nonempty_archive_message(
            &task.status_text,
            "PikPak did not return an extraction task id",
        );
        let code = if task_status.is_empty() {
            "MISSING_TASK_ID"
        } else {
            task_status.as_str()
        };
        bail!("PikPak rejected cloud extraction [{code}]: {message}");
    }
    emit_archive_progress(
        args.progress_json,
        ArchiveProgressEvent::Started {
            status: &task.status,
        },
    );

    let started = Instant::now();
    loop {
        if started.elapsed() >= MAX_EXTRACTION_WAIT {
            bail!("PikPak cloud extraction timed out after 24 hours");
        }
        let progress = client
            .archive_extraction_progress(&task.task_id)
            .await
            .context("check PikPak cloud extraction progress failed")?;
        let percentage = progress.progress.clamp(0.0, 100.0);
        emit_archive_progress(
            args.progress_json,
            ArchiveProgressEvent::Progress {
                progress: percentage,
                phase: &progress.phase,
            },
        );

        if progress.phase.eq_ignore_ascii_case("PHASE_TYPE_ERROR")
            || !progress.error_description.trim().is_empty()
        {
            let message = if !progress.error_description.trim().is_empty() {
                progress.error_description.trim()
            } else if !progress.message.trim().is_empty() {
                progress.message.trim()
            } else {
                "PikPak reported an unknown extraction error"
            };
            let code = if progress.phase.trim().is_empty() {
                "PHASE_TYPE_ERROR"
            } else {
                progress.phase.trim()
            };
            bail!("PikPak cloud extraction failed [{code}]: {message}");
        }

        if percentage >= 100.0 {
            emit_archive_progress(
                args.progress_json,
                ArchiveProgressEvent::Completed {
                    progress: percentage,
                    output_file_id: &progress.file_id,
                },
            );
            println!(
                "{}",
                serde_json::to_string(&ArchiveExtractionResult {
                    archive_file_id: request.file_id,
                    output_file_id: progress.file_id,
                    progress: percentage,
                    phase: progress.phase,
                })?
            );
            return Ok(());
        }

        tokio::time::sleep(Duration::from_secs(progress.expires_in.clamp(1, 10))).await;
    }
}

fn archive_entry_summary(entry: &serde_json::Value, index: usize) -> ArchiveEntrySummary {
    let path = archive_string_field(entry, "path").unwrap_or_default();
    // PikPak's first-party decompression response currently calls these
    // fields `filename` / `filesize`, while a few service variants use the
    // regular Drive names `name` / `size`. Accept both without rewriting the
    // raw entry that is later sent back to the extraction endpoint.
    let name = archive_string_field(entry, "filename")
        .or_else(|| archive_string_field(entry, "name"))
        .filter(|name| !name.trim().is_empty())
        .or_else(|| {
            path.trim_end_matches('/')
                .rsplit('/')
                .find(|part| !part.is_empty())
                .map(str::to_string)
        })
        .unwrap_or_else(|| format!("Entry {}", index + 1));
    let kind = archive_string_field(entry, "kind").unwrap_or_else(|| "drive#file".to_string());
    let size = entry
        .get("filesize")
        .or_else(|| entry.get("size"))
        .and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|size| size.parse().ok()))
        })
        .unwrap_or(0);
    ArchiveEntrySummary {
        index,
        name,
        path,
        kind,
        size,
    }
}

fn archive_string_field(entry: &serde_json::Value, field: &str) -> Option<String> {
    entry
        .get(field)
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn nonempty_archive_message<'a>(message: &'a str, fallback: &'a str) -> &'a str {
    let message = message.trim();
    if message.is_empty() {
        fallback
    } else {
        message
    }
}

async fn cmd_share_preview(account: &Client, args: SharePreviewArgs) -> Result<()> {
    let request: SharePreviewInput = read_json_request(&args.request_file)?;
    let client = build_share_client(&request.access, account)?;
    let preview = client
        .get_preview_info(&request.file_id)
        .await
        .context("shared preview metadata failed")?;
    println!("{}", serde_json::to_string(&preview)?);
    Ok(())
}

async fn cmd_share_measure(account: &Client, args: ShareMeasureArgs) -> Result<()> {
    let request: ShareMeasureInput = read_json_request(&args.request_file)?;
    let client = build_share_client(&request.access, account)?;
    let measurement = calculate_shared_folder_size(&client, &request.folder_id)
        .await
        .context("calculate shared folder size failed")?;
    println!("{}", serde_json::to_string(&measurement)?);
    Ok(())
}

async fn calculate_shared_folder_size(
    client: &ShareClient,
    root_id: &str,
) -> Result<FolderMeasurementReport> {
    let mut report = measure_folder_tree(
        root_id,
        FolderMeasurementSeed::default(),
        FOLDER_MEASUREMENT_CONCURRENCY,
        |id| async move { Ok(client.list_folder(&id).await?) },
    )
    .await?;
    // The app keeps only aggregate sizes for shared links, never their
    // listings, so don't send every entry of the shared tree back to it.
    report.listings.clear();
    Ok(report)
}

async fn cmd_measure(client: &Client, args: MeasureArgs) -> Result<()> {
    let seed = args
        .cache_file
        .as_ref()
        .map(|path| read_json_request(path))
        .transpose()?
        .unwrap_or_default();
    let measurement = measure_folder_tree(
        &args.id,
        seed,
        FOLDER_MEASUREMENT_CONCURRENCY,
        |id| async move { Ok(client.list_folder(&id).await?) },
    )
    .await
    .context("calculate folder size failed")?;
    println!("{}", serde_json::to_string(&measurement)?);
    Ok(())
}

/// Folder listings a size walk keeps in flight. A walk is bounded by request
/// latency, not bandwidth; search indexing uses the same worker count.
const FOLDER_MEASUREMENT_CONCURRENCY: usize = 4;

/// Walk a remote folder without downloading or creating local files. The
/// explicit stack avoids deeply recursive futures, while `visited` protects
/// against malformed cyclic results from the remote API. Up to `concurrency`
/// sibling folders are listed at once; any failed listing still fails the walk.
async fn measure_folder_tree<F, Fut>(
    root_id: &str,
    seed: FolderMeasurementSeed,
    concurrency: usize,
    mut list: F,
) -> Result<FolderMeasurementReport>
where
    F: FnMut(String) -> Fut,
    Fut: Future<Output = Result<Vec<FileInfo>>>,
{
    let mut pending = vec![root_id.to_string()];
    let mut visited = HashSet::from([root_id.to_string()]);
    let mut traversal_order = Vec::new();
    let mut direct_measurements = HashMap::new();
    let mut child_folders = HashMap::new();
    let mut listings = HashMap::new();
    let mut reused_folders = 0;
    let mut running = FuturesUnordered::new();

    loop {
        while running.len() < concurrency.max(1) {
            let Some(folder_id) = pending.pop() else {
                break;
            };
            // A folder is only discovered once its parent's listing finished,
            // so recording here still places every parent before its children.
            traversal_order.push(folder_id.clone());
            // Always refresh the requested root. A seed is an app-account-local
            // optimization, never permission to skip the changed folder itself.
            if folder_id != root_id {
                if let Some(cached) = seed.folders.get(&folder_id) {
                    direct_measurements.insert(folder_id, cached.clone());
                    reused_folders += 1;
                    continue;
                }
            }
            let listing = list(folder_id.clone());
            running.push(async move { (folder_id, listing.await) });
        }
        let Some((folder_id, entries)) = running.next().await else {
            break;
        };
        let entries = entries.with_context(|| format!("failed to inspect folder {folder_id}"))?;
        let mut direct_measurement = FolderMeasurement::default();
        let mut children = Vec::new();
        let mut direct_entries = Vec::new();
        let mut seen_entries = HashSet::new();

        for entry in entries {
            if entry.id.is_empty() || !seen_entries.insert(entry.id.clone()) {
                continue;
            }
            if entry.kind.is_folder() && visited.contains(&entry.id) {
                continue;
            }
            direct_entries.push(FolderSizeEntry {
                id: entry.id.clone(),
                size: entry.size,
                is_folder: entry.kind.is_folder(),
            });
            if entry.kind.is_folder() {
                if visited.insert(entry.id.clone()) {
                    children.push(entry.id.clone());
                    pending.push(entry.id);
                }
            } else {
                direct_measurement.add_file(entry.size);
            }
        }

        direct_measurements.insert(folder_id.clone(), direct_measurement);
        listings.insert(folder_id.clone(), direct_entries);
        child_folders.insert(folder_id, children);
    }

    let mut report = build_folder_measurement_report(
        root_id,
        direct_measurements,
        child_folders,
        &traversal_order,
    );
    report.listings = listings;
    report.reused_folders = reused_folders;
    Ok(report)
}

/// Convert direct file totals into recursive totals for the root and every
/// descendant. Parents are visited before children, so reversing the recorded
/// traversal order guarantees each child's aggregate is ready first.
fn build_folder_measurement_report(
    root_id: &str,
    direct_measurements: HashMap<String, FolderMeasurement>,
    child_folders: HashMap<String, Vec<String>>,
    traversal_order: &[String],
) -> FolderMeasurementReport {
    let mut folders = HashMap::with_capacity(traversal_order.len());

    for folder_id in traversal_order.iter().rev() {
        let mut measurement = direct_measurements
            .get(folder_id)
            .cloned()
            .unwrap_or_default();

        if let Some(children) = child_folders.get(folder_id) {
            for child_id in children {
                if let Some(child) = folders.get(child_id) {
                    measurement.add_descendant_folder(child);
                }
            }
        }

        folders.insert(folder_id.clone(), measurement);
    }

    let root = folders.get(root_id).cloned().unwrap_or_default();
    FolderMeasurementReport {
        root,
        folders,
        ..Default::default()
    }
}

async fn cmd_duplicates(client: &Client, args: DuplicatesArgs) -> Result<()> {
    let scope = if let Some(path) = args.scope_file {
        read_json_request_bounded(&path, 1024 * 1024).context("decode duplicate scan scope")?
    } else {
        duplicate_cross_drive::Scope {
            cloud_folders: vec![duplicate_cross_drive::CloudFolder { id: args.parent_id, path: args.root_path }],
            local_paths: args.local_paths,
        }
    };
    let scan = duplicate_cross_drive::scan(client, scope, args.progress_json)
    .await
    .context("scan for duplicate files failed")?;
    println!("{}", serde_json::to_string(&scan)?);
    Ok(())
}

async fn scan_duplicates(
    client: &Client,
    root_id: &str,
    root_path: &str,
    progress_json: bool,
) -> Result<DuplicateScan> {
    let (folders, failed, candidates) = collect_duplicate_candidates(client, root_id, root_path, progress_json).await?;
    let mut scan = build_duplicate_scan(normalize_remote_path(root_path), folders, candidates);
    scan.failed_folders = failed;
    Ok(scan)
}

async fn collect_duplicate_candidates(
    client: &Client,
    root_id: &str,
    root_path: &str,
    progress_json: bool,
) -> Result<(usize, usize, Vec<DuplicateCandidate>)> {
    // Scanning never reads or writes the persistent inventory used by other operations.
    let client = client.clone().without_duplicate_cache();
    let root_created = if root_id.is_empty() { None } else {
        client.file_metadata(root_id).await.ok().and_then(|value| value["created_time"].as_str().map(str::to_owned))
    };
    collect_duplicate_tree(root_id, root_path, root_created, progress_json, duplicate_admission::Mode::Automatic, move |id| {
        let client = client.clone();
        async move { client.list_folder(&id).await }
    }).await
}

struct DuplicateFolder {
    id: String,
    path: String,
    created_time: Option<String>,
    attempt: u32,
    retry_delay: Duration,
}

async fn collect_duplicate_tree<F, Fut>(
    root_id: &str, root_path: &str, root_created: Option<String>,
    progress_json: bool, concurrency: impl Into<duplicate_admission::Mode>, mut list: F,
) -> Result<(usize, usize, Vec<DuplicateCandidate>)>
where
    F: FnMut(String) -> Fut,
    Fut: Future<Output = std::result::Result<Vec<FileInfo>, PikPakError>>,
{
    let root_path = normalize_remote_path(root_path);
    let mut pending = vec![DuplicateFolder {
        id: root_id.to_owned(), path: root_path.clone(), created_time: root_created,
        attempt: 1, retry_delay: Duration::ZERO,
    }];
    let mut visited = HashSet::from([root_id.to_owned()]);
    let mut candidates = Vec::new();
    let (mut scanned_folders, mut failed_folders) = (0usize, 0usize);
    let mut running = FuturesUnordered::new();
    emit_duplicate_progress(progress_json, DuplicateProgressEvent::ScanStarted {
        root_path: &root_path, discovered_folders: visited.len(),
    });

    let initial = std::thread::available_parallelism().map(usize::from).unwrap_or(1);
    let mut admission = duplicate_admission::Admission::new(concurrency.into(), initial, false);
    let mut ticker = tokio::time::interval(Duration::from_millis(250));
    loop {
        let limit = admission.update(Instant::now(), (scanned_folders + failed_folders) as u64, running.len(), !pending.is_empty());
        while running.len() < limit {
            let Some(folder) = pending.pop() else { break };
            let listing = list(folder.id.clone());
            running.push(async move {
                // A folder's backoff occupies only its own slot. Other folder
                // requests and completed results keep moving during the delay.
                if !folder.retry_delay.is_zero() { tokio::time::sleep(folder.retry_delay).await; }
                (folder, listing.await)
            });
        }
        if running.is_empty() {
            if pending.is_empty() { break; }
            ticker.tick().await;
            continue;
        }
        let result = tokio::select! {
            result = running.next() => result,
            _ = ticker.tick() => continue,
        };
        let Some((mut folder, entries)) = result else { break };
        let entries = match entries {
            Ok(entries) => entries,
            Err(error) => {
                if matches!(&error, PikPakError::Api { status: 429, .. } | PikPakError::RetryAfter { .. }) {
                    admission.throttled(Instant::now());
                }
                match duplicate_folder_failure_action(&error, folder.attempt, folder.id == root_id) {
                    DuplicateFolderFailureAction::Retry(delay) => {
                        folder.attempt = folder.attempt.saturating_add(1);
                        folder.retry_delay = delay;
                        emit_duplicate_progress(progress_json, DuplicateProgressEvent::FolderRetrying {
                            scanned_files: candidates.len(), scanned_folders,
                            discovered_folders: visited.len(),
                            pending_folders: pending.len() + running.len() + 1,
                            failed_folders, current_path: &folder.path,
                            attempt: folder.attempt, max_attempts: DUPLICATE_FOLDER_MAX_ATTEMPTS,
                            retry_in_millis: u64::try_from(delay.as_millis()).unwrap_or(u64::MAX),
                        });
                        eprintln!("warning: PikPak temporarily failed while scanning {}; retrying attempt {} of {DUPLICATE_FOLDER_MAX_ATTEMPTS} in {:.1}s ({error})",
                            folder.path, folder.attempt, delay.as_secs_f64());
                        pending.push(folder);
                        continue;
                    }
                    DuplicateFolderFailureAction::Abort => {
                        return Err(anyhow::Error::new(error))
                            .with_context(|| format!("failed to inspect folder {}", folder.path));
                    }
                    DuplicateFolderFailureAction::Skip => {
                        failed_folders = failed_folders.saturating_add(1);
                        emit_duplicate_progress(progress_json, DuplicateProgressEvent::FolderSkipped {
                            scanned_files: candidates.len(), scanned_folders,
                            discovered_folders: visited.len(), pending_folders: pending.len() + running.len(),
                            failed_folders, current_path: &folder.path,
                        });
                        eprintln!("warning: skipped unavailable folder {} after {} attempt(s); partial scan will continue ({error})",
                            folder.path, folder.attempt);
                        continue;
                    }
                }
            }
        };
        scanned_folders = scanned_folders.saturating_add(1);
        for entry in entries {
            let path = join_remote_display_path(&folder.path, &entry.name);
            if entry.kind.is_folder() {
                if visited.insert(entry.id.clone()) {
                    pending.push(DuplicateFolder {
                        id: entry.id, path, created_time: entry.created_time,
                        attempt: 1, retry_delay: Duration::ZERO,
                    });
                }
            } else {
                candidates.push(DuplicateCandidate {
                    id: entry.id, name: entry.name, path, size: entry.size,
                    modified_time: entry.modified_time, content_hash: entry.hash,
                    md5_checksum: entry.md5_checksum, source: duplicate_cross_drive::DuplicateSource::Pikpak,
                    folder_created_time: folder.created_time.clone(), local_identity: None,
                });
            }
        }
        emit_duplicate_progress(progress_json, DuplicateProgressEvent::ScanProgress {
            scanned_files: candidates.len(), scanned_folders,
            discovered_folders: visited.len(), pending_folders: pending.len() + running.len(),
            failed_folders, current_path: &folder.path,
        });
    }
    Ok((scanned_folders, failed_folders, candidates))
}

fn build_duplicate_scan(
    root_path: String,
    scanned_folders: usize,
    candidates: Vec<DuplicateCandidate>,
) -> DuplicateScan {
    let scanned_files = candidates.len();
    let grouped = duplicate_cross_drive::group_candidates(candidates);

    let mut groups = Vec::new();
    for (key, mut members) in grouped {
        if members.len() < 2 {
            continue;
        }
        members.sort_by(duplicate_cross_drive::keeper_order);
        let match_kind = key;
        let size = members[0].size;
        let copies = members.len();
        let extra_copies = u64::try_from(members.iter().skip(1).filter(|file| file.source == duplicate_cross_drive::DuplicateSource::Pikpak).count()).unwrap_or(u64::MAX);
        let reclaimable_bytes = size.saturating_mul(extra_copies);
        groups.push(DuplicateGroup {
            id: String::new(),
            match_kind,
            size,
            copies,
            reclaimable_bytes,
            files: members
                .into_iter()
                .map(|file| DuplicateFile {
                    id: file.id,
                    name: file.name,
                    path: file.path,
                    size: file.size,
                    modified_time: file.modified_time,
                    source: file.source,
                    folder_created_time: file.folder_created_time,
                    local_identity: file.local_identity,
                })
                .collect(),
        });
    }

    groups.sort_by(|a, b| {
        b.reclaimable_bytes
            .cmp(&a.reclaimable_bytes)
            .then_with(|| b.size.cmp(&a.size))
            .then_with(|| a.files[0].path.cmp(&b.files[0].path))
    });
    for (index, group) in groups.iter_mut().enumerate() {
        group.id = format!("duplicate-group-{}", index + 1);
    }

    let duplicate_files = groups
        .iter()
        .fold(0usize, |total, group| total.saturating_add(group.copies));
    let exact_groups = groups
        .iter()
        .filter(|group| group.match_kind == DuplicateMatchKind::ExactContent)
        .count();
    let possible_groups = groups.len().saturating_sub(exact_groups);
    let reclaimable_bytes = groups
        .iter()
        .filter(|group| group.match_kind == DuplicateMatchKind::ExactContent)
        .fold(0u64, |total, group| {
            total.saturating_add(group.reclaimable_bytes)
        });

    DuplicateScan {
        root_path,
        scanned_files,
        scanned_folders,
        failed_folders: 0,
        duplicate_files,
        exact_groups,
        possible_groups,
        reclaimable_bytes,
        groups,
    }
}

fn normalized_digest(value: Option<&str>) -> Option<String> {
    let digest = value?.trim();
    (!digest.is_empty()).then(|| digest.to_ascii_lowercase())
}

fn normalize_remote_path(path: &str) -> String {
    let trimmed = path.trim_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        format!("/{trimmed}")
    }
}

fn join_remote_display_path(parent: &str, name: &str) -> String {
    if parent == "/" {
        format!("/{name}")
    } else {
        format!("{}/{name}", parent.trim_end_matches('/'))
    }
}

async fn cmd_similarity_preflight(client: &Client, args: SimilarityScanArgs) -> Result<()> {
    let files: Vec<trash_selection::Keeper> =
        read_json_request_bounded(&args.request_file, 64 * 1024 * 1024)?;
    trash_selection::verify_all(client, &files).await?;
    println!("{}", serde_json::json!({"verified_ids": files.iter().map(|file| &file.id).collect::<Vec<_>>()}));
    Ok(())
}

async fn cmd_trash(client: &Client, args: TrashArgs) -> Result<()> {
    if !args.yes {
        bail!("refusing to move items to Trash without --yes");
    }
    let selection = args
        .ids_file
        .map(|path| -> Result<trash_selection::Selection> {
            let encoded = std::fs::read_to_string(&path)
                .with_context(|| format!("failed to read ids file {}", path.display()))?;
            serde_json::from_str(&encoded)
                .context("ids file must contain a JSON string array or a guarded Trash selection")
        })
        .transpose()?;
    let request = trash_selection::Request::new(args.ids, selection)?;
    let outcome = trash_selection::execute(client, request).await?;
    println!(
        "{}",
        serde_json::to_string(&TrashResult {
            trashed_ids: outcome.confirmed
        })?
    );
    if let Some(error) = outcome.error {
        return Err(error);
    }
    Ok(())
}

async fn cmd_move(client: &Client, args: MoveArgs) -> Result<()> {
    const MOVE_BATCH_SIZE: usize = 100;

    let mut supplied_ids = args.ids;
    if let Some(path) = args.ids_file {
        let encoded = std::fs::read_to_string(&path)
            .with_context(|| format!("failed to read ids file {}", path.display()))?;
        let mut file_ids: Vec<String> =
            serde_json::from_str(&encoded).context("ids file must contain a JSON string array")?;
        supplied_ids.append(&mut file_ids);
    }

    let mut seen = HashSet::new();
    let ids: Vec<String> = supplied_ids
        .into_iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty() && seen.insert(id.clone()))
        .collect();
    if ids.is_empty() {
        bail!("at least one non-empty file id is required");
    }
    if ids.iter().any(|id| id == &args.to_parent_id) {
        bail!("a folder cannot be moved inside itself");
    }

    let mut confirmed = Vec::new();
    for batch in ids.chunks(MOVE_BATCH_SIZE) {
        if let Err(error) = client.move_files(batch, &args.to_parent_id).await {
            println!(
                "{}",
                serde_json::to_string(&MoveResult {
                    moved_ids: confirmed,
                    parent_id: args.to_parent_id,
                })?
            );
            return Err(error).context("move item batch to another PikPak folder failed");
        }
        confirmed.extend_from_slice(batch);
    }
    println!(
        "{}",
        serde_json::to_string(&MoveResult {
            moved_ids: confirmed,
            parent_id: args.to_parent_id,
        })?
    );
    Ok(())
}

async fn cmd_rename(client: &Client, args: RenameArgs) -> Result<()> {
    let id = args.id.trim();
    if id.is_empty() {
        bail!("a non-empty file or folder id is required");
    }
    let name = args.name.trim();
    if name.is_empty() {
        bail!("the new file or folder name must not be empty");
    }

    client
        .rename_file(id, name)
        .await
        .context("rename PikPak file or folder failed")?;
    println!(
        "{}",
        serde_json::to_string(&RenameResult {
            id: id.to_string(),
            name: name.to_string(),
        })?
    );
    Ok(())
}

/// Merge source folders one at a time. A source is moved to Trash only after
/// every direct child has been moved and a fresh server listing confirms that
/// the source is empty. This makes failures recoverable: an interrupted merge
/// can leave already-moved children in the destination, but never deletes a
/// source folder that still contains data.
async fn cmd_merge_folders(client: &Client, args: MergeFoldersArgs) -> Result<()> {
    const MOVE_BATCH_SIZE: usize = 100;

    if !args.yes {
        bail!("refusing to merge folders without --yes");
    }

    let destination_id = args.destination_id.trim().to_string();
    if destination_id.is_empty() {
        bail!("a non-empty destination folder id is required");
    }

    let mut supplied_ids = args.source_ids;
    if let Some(path) = args.source_ids_file {
        let encoded = std::fs::read_to_string(&path)
            .with_context(|| format!("failed to read source ids file {}", path.display()))?;
        let mut file_ids: Vec<String> = serde_json::from_str(&encoded)
            .context("source ids file must contain a JSON string array")?;
        supplied_ids.append(&mut file_ids);
    }

    let mut seen = HashSet::new();
    let source_ids: Vec<String> = supplied_ids
        .into_iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty() && id != &destination_id && seen.insert(id.clone()))
        .collect();
    if source_ids.is_empty() {
        bail!("at least one source folder distinct from the destination is required");
    }

    // Validate the destination before mutating any source. Listing a regular
    // file fails at the API layer, so only a real, readable folder can pass.
    client
        .list_folder(&destination_id)
        .await
        .context("validate merge destination folder failed")?;

    // Preflight every source before moving the first child. A stale or
    // unreadable selection therefore fails without partially merging an
    // otherwise valid earlier folder. An absent source is harmless during a
    // resumed merge because it has nothing left to move or delete.
    let source_count = source_ids.len();
    let mut planned_sources = Vec::with_capacity(source_count);
    let mut merged_source_ids = Vec::with_capacity(source_count);
    for source_id in source_ids {
        let children = match client.list_folder(&source_id).await {
            Ok(children) => children,
            Err(error) if merge_source_is_missing(&error) => {
                merged_source_ids.push(source_id);
                continue;
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("list merge source folder {source_id} failed"));
            }
        };
        let child_ids: Vec<String> = children.into_iter().map(|item| item.id).collect();
        if child_ids.iter().any(|id| id == &destination_id) {
            bail!("the destination folder is inside source folder {source_id}");
        }
        planned_sources.push((source_id, child_ids));
    }

    let mut total_items = planned_sources
        .iter()
        .map(|(_, child_ids)| child_ids.len())
        .sum::<usize>();
    let mut known_item_ids: HashSet<String> = planned_sources
        .iter()
        .flat_map(|(_, child_ids)| child_ids.iter().cloned())
        .collect();
    emit_merge_progress(
        args.progress_json,
        MergeProgressEvent::Preparing {
            source_count,
            total_items,
        },
    );

    let mut moved_item_ids = HashSet::new();
    let mut moved_items = 0usize;
    let mut completed_item_count = 0usize;

    for (source_id, child_ids) in planned_sources {
        let source_index = merged_source_ids.len() + 1;
        let mut source_known_item_ids: HashSet<String> = child_ids.iter().cloned().collect();
        let mut remaining_ids = child_ids;
        let mut source_disappeared = false;

        emit_merge_progress(
            args.progress_json,
            MergeProgressEvent::SourceStarted {
                source_id: &source_id,
                source_index,
                source_count,
                completed_sources: merged_source_ids.len(),
                moved_items,
                total_items,
                remaining_items: total_items.saturating_sub(completed_item_count),
            },
        );

        'move_rounds: for move_round in 1..=MERGE_MOVE_MAX_ROUNDS {
            for batch in remaining_ids.chunks(MOVE_BATCH_SIZE) {
                if let Err(error) = client.move_files(batch, &destination_id).await {
                    // A retry may race with an earlier acknowledged move. A
                    // fresh empty/missing listing is authoritative; otherwise
                    // preserve the source and surface the API failure.
                    match client.list_folder(&source_id).await {
                        Ok(items) if items.is_empty() => {
                            remaining_ids.clear();
                            break;
                        }
                        Err(list_error) if merge_source_is_missing(&list_error) => {
                            remaining_ids.clear();
                            source_disappeared = true;
                            break;
                        }
                        Ok(items) if move_round > 1 && merge_source_is_missing(&error) => {
                            // One child may already have left the source while
                            // its old row is still visible through the listing
                            // replica. Keep polling the authoritative source;
                            // the later empty check still gates Trash.
                            remaining_ids = items.into_iter().map(|item| item.id).collect();
                            break;
                        }
                        _ => {
                            return Err(error).with_context(|| {
                                format!(
                                    "move items from source folder {source_id} into destination failed"
                                )
                            });
                        }
                    }
                }
                for id in batch {
                    moved_item_ids.insert(id.clone());
                }
                moved_items = moved_item_ids.len();
            }

            emit_merge_progress(
                args.progress_json,
                MergeProgressEvent::MoveSubmitted {
                    source_id: &source_id,
                    source_index,
                    source_count,
                    completed_sources: merged_source_ids.len(),
                    moved_items,
                    total_items,
                    remaining_items: total_items.saturating_sub(completed_item_count),
                },
            );

            if remaining_ids.is_empty() && source_disappeared {
                break 'move_rounds;
            }

            let submitted_ids: HashSet<String> = remaining_ids.iter().cloned().collect();
            for attempt in 1..=MERGE_VERIFY_MAX_ATTEMPTS {
                let delay = merge_verification_backoff(attempt);
                emit_merge_progress(
                    args.progress_json,
                    MergeProgressEvent::Verifying {
                        source_id: &source_id,
                        source_index,
                        source_count,
                        completed_sources: merged_source_ids.len(),
                        moved_items,
                        total_items,
                        remaining_items: remaining_ids.len()
                            + total_items.saturating_sub(
                                completed_item_count.saturating_add(source_known_item_ids.len()),
                            ),
                        attempt,
                        max_attempts: MERGE_VERIFY_MAX_ATTEMPTS,
                        retry_in_millis: delay.as_millis() as u64,
                    },
                );
                tokio::time::sleep(delay).await;

                let remaining = match client.list_folder(&source_id).await {
                    Ok(items) => items,
                    Err(error) if merge_source_is_missing(&error) => {
                        source_disappeared = true;
                        Vec::new()
                    }
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!("verify merge source folder {source_id} failed")
                        });
                    }
                };
                remaining_ids = remaining.into_iter().map(|item| item.id).collect();
                if remaining_ids.is_empty() {
                    break 'move_rounds;
                }

                for id in &remaining_ids {
                    if known_item_ids.insert(id.clone()) {
                        total_items = total_items.saturating_add(1);
                    }
                    source_known_item_ids.insert(id.clone());
                }

                // Children which arrived during the merge were never part of
                // this round and should be moved immediately. Otherwise keep
                // polling because the listing can lag an acknowledged move.
                if remaining_ids.iter().any(|id| !submitted_ids.contains(id)) {
                    continue 'move_rounds;
                }
            }

            if remaining_ids.is_empty() {
                break;
            }
            if move_round == MERGE_MOVE_MAX_ROUNDS {
                bail!(
                    "source folder {source_id} still contains {} item(s) after {} move round(s) and {} verification attempt(s); it was kept and was not moved to Trash",
                    remaining_ids.len(),
                    MERGE_MOVE_MAX_ROUNDS,
                    MERGE_VERIFY_MAX_ATTEMPTS
                );
            }
        }

        if !source_disappeared {
            match client.trash_files(std::slice::from_ref(&source_id)).await {
                Ok(()) => {}
                Err(error) if merge_source_is_missing(&error) => {}
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("move empty merge source folder {source_id} to Trash failed")
                    });
                }
            }
        }
        completed_item_count = completed_item_count.saturating_add(source_known_item_ids.len());
        merged_source_ids.push(source_id.clone());
        emit_merge_progress(
            args.progress_json,
            MergeProgressEvent::SourceCompleted {
                source_id: &source_id,
                source_index,
                source_count,
                completed_sources: merged_source_ids.len(),
                moved_items,
                total_items,
                remaining_items: total_items.saturating_sub(completed_item_count),
            },
        );
    }

    emit_merge_progress(
        args.progress_json,
        MergeProgressEvent::Completed {
            source_count,
            completed_sources: merged_source_ids.len(),
            moved_items,
            total_items,
            remaining_items: 0,
        },
    );

    println!(
        "{}",
        serde_json::to_string(&MergeFoldersResult {
            destination_id,
            merged_source_ids,
            moved_items,
        })?
    );
    Ok(())
}

async fn cmd_create_folder(client: &Client, args: CreateFolderArgs) -> Result<()> {
    let name = args.name.trim();
    if name.is_empty() {
        bail!("folder name must not be empty");
    }

    let id = client
        .create_folder(&args.parent_id, name)
        .await
        .context("create PikPak folder failed")?;
    println!(
        "{}",
        serde_json::to_string(&CreateFolderResult {
            id,
            name: name.to_string(),
            parent_id: args.parent_id,
        })?
    );
    Ok(())
}

async fn cmd_empty_folders(client: &Client, args: EmptyFoldersArgs) -> Result<()> {
    if !args.yes {
        bail!("refusing to move empty folders to Trash without --yes");
    }

    let root_path = normalize_remote_path(&args.root_path);
    let mut pending = vec![(args.parent_id.clone(), root_path.clone(), 0usize)];
    let mut visited = HashSet::from([args.parent_id.clone()]);
    let mut nodes = Vec::new();

    emit_empty_folder_progress(
        args.progress_json,
        EmptyFolderProgressEvent::ScanStarted {
            root_path: &root_path,
            discovered_folders: 1,
        },
    );

    // Complete the entire read-only scan before moving anything. If PikPak
    // cannot inspect even one descendant, aborting here prevents us from
    // incorrectly treating an unavailable non-empty branch as empty.
    while let Some((folder_id, folder_path, depth)) = pending.pop() {
        let entries = client
            .list_folder(&folder_id)
            .await
            .with_context(|| format!("failed to inspect folder {folder_path}"))?;
        let mut child_folder_ids = Vec::new();
        let mut direct_child_ids = HashSet::new();
        let mut contains_file = false;
        let mut has_uninspectable_child = false;

        for entry in entries {
            if !entry.kind.is_folder() {
                contains_file = true;
                continue;
            }

            // Ignore duplicate rows in one server page, but conservatively
            // block deletion if a folder id appears elsewhere or forms a cycle.
            if !direct_child_ids.insert(entry.id.clone()) {
                continue;
            }
            if visited.insert(entry.id.clone()) {
                child_folder_ids.push(entry.id.clone());
                pending.push((
                    entry.id,
                    join_remote_display_path(&folder_path, &entry.name),
                    depth.saturating_add(1),
                ));
            } else {
                has_uninspectable_child = true;
            }
        }

        nodes.push(EmptyFolderNode {
            id: folder_id,
            path: folder_path.clone(),
            depth,
            child_folder_ids,
            contains_file,
            has_uninspectable_child,
        });
        emit_empty_folder_progress(
            args.progress_json,
            EmptyFolderProgressEvent::ScanProgress {
                scanned_folders: nodes.len(),
                discovered_folders: visited.len(),
                current_path: &folder_path,
            },
        );
    }

    let empty_ids = empty_folder_candidate_ids(&args.parent_id, &nodes);
    emit_empty_folder_progress(
        args.progress_json,
        EmptyFolderProgressEvent::DeleteStarted {
            empty_folders: empty_ids.len(),
        },
    );

    let node_by_id: HashMap<&str, &EmptyFolderNode> =
        nodes.iter().map(|node| (node.id.as_str(), node)).collect();
    let mut removed_ids = Vec::with_capacity(empty_ids.len());
    let mut skipped_non_empty_folders = 0usize;

    // Candidates are ordered deepest-first. Re-list each one immediately
    // before its individual Trash request. This second, complete emptiness
    // check closes the long scan-to-delete window: a new file, an undeleted
    // child, or any other visible entry keeps this folder and consequently
    // keeps each parent above it. An untrustworthy listing returns an error and
    // fails closed before that candidate can be removed.
    for (index, folder_id) in empty_ids.iter().enumerate() {
        let node = node_by_id
            .get(folder_id.as_str())
            .copied()
            .context("empty-folder candidate was missing from the completed scan")?;
        let current_entries = client
            .list_folder(folder_id)
            .await
            .with_context(|| format!("failed to recheck candidate folder {}", node.path))?;

        if current_entries.is_empty() {
            client
                .trash_files(std::slice::from_ref(folder_id))
                .await
                .with_context(|| {
                    format!("move verified empty folder {} to Trash failed", node.path)
                })?;
            removed_ids.push(folder_id.clone());
        } else {
            skipped_non_empty_folders = skipped_non_empty_folders.saturating_add(1);
        }

        emit_empty_folder_progress(
            args.progress_json,
            EmptyFolderProgressEvent::DeleteProgress {
                checked_folders: index.saturating_add(1),
                removed_folders: removed_ids.len(),
                skipped_folders: skipped_non_empty_folders,
                empty_folders: empty_ids.len(),
                current_path: &node.path,
            },
        );
    }

    println!(
        "{}",
        serde_json::to_string(&EmptyFolderCleanup {
            root_path,
            scanned_folders: nodes.len(),
            candidate_folders: empty_ids.len(),
            rechecked_folders: empty_ids.len(),
            skipped_non_empty_folders,
            removed_folders: removed_ids.len(),
            removed_ids,
        })?
    );
    Ok(())
}

/// Recursively discover exact `.DS_Store` files, then re-list every containing
/// folder immediately before deletion. Matching is deliberately case-sensitive
/// and excludes folders so this command cannot remove similarly named content.
async fn cmd_ds_store(client: &Client, args: DsStoreArgs) -> Result<()> {
    const TRASH_BATCH_SIZE: usize = 100;

    if !args.yes {
        bail!("refusing to move .DS_Store files to Trash without --yes");
    }

    let root_path = normalize_remote_path(&args.root_path);
    let mut pending = vec![(args.parent_id.clone(), root_path.clone())];
    let mut visited_folders = HashSet::from([args.parent_id.clone()]);
    let mut seen_file_ids = HashSet::new();
    let mut candidates = Vec::new();
    let mut scanned_folders = 0usize;

    // Finish the read-only traversal before changing anything. `list_folder`
    // validates pagination, so a partial listing aborts instead of silently
    // leaving the user with an incomplete cleanup result.
    while let Some((folder_id, folder_path)) = pending.pop() {
        let entries = client
            .list_folder(&folder_id)
            .await
            .with_context(|| format!("failed to inspect folder {folder_path}"))?;
        scanned_folders = scanned_folders.saturating_add(1);

        for entry in entries {
            if entry.kind.is_folder() {
                if !visited_folders.insert(entry.id.clone()) {
                    bail!(
                        "PikPak returned a repeated folder while scanning {}; no files were removed",
                        join_remote_display_path(&folder_path, &entry.name)
                    );
                }
                pending.push((
                    entry.id,
                    join_remote_display_path(&folder_path, &entry.name),
                ));
            } else if is_ds_store_file(entry.kind, &entry.name)
                && seen_file_ids.insert(entry.id.clone())
            {
                candidates.push(DsStoreCandidate {
                    id: entry.id,
                    parent_id: folder_id.clone(),
                    path: join_remote_display_path(&folder_path, &entry.name),
                });
            }
        }
    }

    let candidate_files = candidates.len();
    let mut parent_ids: Vec<String> = candidates
        .iter()
        .map(|candidate| candidate.parent_id.clone())
        .collect();
    parent_ids.sort();
    parent_ids.dedup();

    let mut rechecked_files = 0usize;
    let mut skipped_files = 0usize;
    let mut removed_ids = Vec::with_capacity(candidate_files);

    for parent_id in parent_ids {
        let parent_candidates: Vec<&DsStoreCandidate> = candidates
            .iter()
            .filter(|candidate| candidate.parent_id == parent_id)
            .collect();
        let current_entries = client.list_folder(&parent_id).await.with_context(|| {
            let path = parent_candidates
                .first()
                .map(|candidate| candidate.path.as_str())
                .unwrap_or(&root_path);
            format!("failed to recheck .DS_Store candidate near {path}")
        })?;
        let verified_ids: HashSet<&str> = current_entries
            .iter()
            .filter(|entry| is_ds_store_file(entry.kind, &entry.name))
            .map(|entry| entry.id.as_str())
            .collect();
        let mut confirmed = Vec::new();

        for candidate in parent_candidates {
            rechecked_files = rechecked_files.saturating_add(1);
            if verified_ids.contains(candidate.id.as_str()) {
                confirmed.push(candidate.id.clone());
            } else {
                skipped_files = skipped_files.saturating_add(1);
            }
        }

        for batch in confirmed.chunks(TRASH_BATCH_SIZE) {
            client
                .trash_files(batch)
                .await
                .context("move verified .DS_Store batch to PikPak Trash failed")?;
            removed_ids.extend(batch.iter().cloned());
        }
    }

    println!(
        "{}",
        serde_json::to_string(&DsStoreCleanup {
            root_path,
            scanned_folders,
            candidate_files,
            rechecked_files,
            skipped_files,
            removed_files: removed_ids.len(),
            removed_ids,
        })?
    );
    Ok(())
}

fn is_ds_store_file(kind: FileKind, name: &str) -> bool {
    kind.is_file() && name == ".DS_Store"
}

/// Determine which scanned folders are empty after recursively removing empty
/// descendants. The selected scan root is deliberately preserved.
fn empty_folder_candidate_ids(root_id: &str, nodes: &[EmptyFolderNode]) -> Vec<String> {
    let mut ordered: Vec<&EmptyFolderNode> = nodes.iter().collect();
    ordered.sort_by(|left, right| {
        right
            .depth
            .cmp(&left.depth)
            .then_with(|| left.path.cmp(&right.path))
    });

    let mut empty = HashSet::new();
    let mut candidates = Vec::new();
    for node in ordered {
        let is_empty = !node.contains_file
            && !node.has_uninspectable_child
            && node
                .child_folder_ids
                .iter()
                .all(|child_id| empty.contains(child_id));
        if is_empty {
            empty.insert(node.id.clone());
            if node.id != root_id {
                candidates.push(node.id.clone());
            }
        }
    }
    candidates
}

fn local_upload_name(path: &StdPath) -> Result<String> {
    path.file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .with_context(|| format!("local item has no usable UTF-8 name: {}", path.display()))
}

fn joined_upload_display_name(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

/// Walk one selected local directory without following symbolic links. The
/// directory entry is already in `plan.directories`; this function adds all
/// descendants with parent indices, keeping parents before their children.
fn scan_local_upload_directory(
    path: &StdPath,
    directory_index: usize,
    display_name: &str,
    plan: &mut LocalUploadPlan,
) -> Result<()> {
    let mut entries = std::fs::read_dir(path)
        .with_context(|| format!("read local upload folder {}", path.display()))?
        .collect::<std::result::Result<Vec<_>, _>>()
        .with_context(|| format!("read entries in local upload folder {}", path.display()))?;
    entries.sort_by_key(|entry| entry.file_name());

    for entry in entries {
        let child_path = entry.path();
        let file_type = entry
            .file_type()
            .with_context(|| format!("read local item type {}", child_path.display()))?;
        if file_type.is_symlink() {
            // Following directory links can escape the selected tree or loop
            // forever. Skipping links matches a safe recursive-copy default.
            plan.skipped_entries = plan.skipped_entries.saturating_add(1);
            continue;
        }

        let name = local_upload_name(&child_path)?;
        let child_display_name = joined_upload_display_name(display_name, &name);
        if file_type.is_dir() {
            let child_index = plan.directories.len();
            let depth = plan.directories[directory_index].depth.saturating_add(1);
            plan.directories.push(PlannedUploadDirectory {
                name,
                display_name: child_display_name.clone(),
                parent_directory: Some(directory_index),
                depth,
            });
            scan_local_upload_directory(&child_path, child_index, &child_display_name, plan)?;
        } else if file_type.is_file() {
            let metadata = entry
                .metadata()
                .with_context(|| format!("read local file metadata {}", child_path.display()))?;
            plan.files.push(PlannedUploadSource {
                path: child_path,
                name,
                display_name: child_display_name,
                size: metadata.len(),
                parent_directory: Some(directory_index),
            });
        } else {
            plan.skipped_entries = plan.skipped_entries.saturating_add(1);
        }
    }
    Ok(())
}

/// Resolve, de-duplicate, and recursively inspect every selected source before
/// any cloud mutation. If a directory and one of its descendants were both
/// selected in Finder, the descendant is included only once through the root.
fn discover_local_uploads(requested_inputs: Vec<PathBuf>) -> Result<LocalUploadPlan> {
    let mut candidates = Vec::with_capacity(requested_inputs.len());
    let mut seen = HashSet::new();
    for path in requested_inputs {
        let canonical = std::fs::canonicalize(&path)
            .with_context(|| format!("local upload source not found: {}", path.display()))?;
        if !seen.insert(canonical.clone()) {
            continue;
        }
        let metadata = std::fs::metadata(&canonical)
            .with_context(|| format!("read local upload metadata: {}", path.display()))?;
        if !metadata.is_file() && !metadata.is_dir() {
            bail!(
                "upload source is not a regular file or folder: {}",
                path.display()
            );
        }
        candidates.push((canonical, metadata.is_dir(), metadata.len()));
    }

    candidates.sort_by(|left, right| {
        left.0
            .components()
            .count()
            .cmp(&right.0.components().count())
            .then_with(|| left.0.cmp(&right.0))
    });

    let mut roots: Vec<(PathBuf, bool, u64)> = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let is_covered = roots.iter().any(|(root, is_directory, _)| {
            *is_directory && candidate.0 != *root && candidate.0.starts_with(root)
        });
        if !is_covered {
            roots.push(candidate);
        }
    }

    let mut plan = LocalUploadPlan::default();
    for (path, is_directory, size) in roots {
        let name = local_upload_name(&path)?;
        if is_directory {
            let directory_index = plan.directories.len();
            plan.directories.push(PlannedUploadDirectory {
                name: name.clone(),
                display_name: name.clone(),
                parent_directory: None,
                depth: 0,
            });
            scan_local_upload_directory(&path, directory_index, &name, &mut plan)?;
        } else {
            plan.files.push(PlannedUploadSource {
                path,
                name: name.clone(),
                display_name: name,
                size,
                parent_directory: None,
            });
        }
    }
    Ok(plan)
}

async fn create_remote_upload_directories(
    client: &Client,
    destination_id: &str,
    directories: &[PlannedUploadDirectory],
    jobs: usize,
    progress_json: bool,
    checkpoint: Option<Arc<UploadCheckpoint>>,
) -> Result<Vec<String>> {
    let mut remote_ids = vec![None; directories.len()];
    let mut created_folders = 0usize;
    let max_depth = directories.iter().map(|directory| directory.depth).max();

    for depth in 0..=max_depth.unwrap_or(0) {
        let mut pending = directories
            .iter()
            .enumerate()
            .filter(|(_, directory)| directory.depth == depth)
            .map(|(index, directory)| {
                let parent_id = match directory.parent_directory {
                    Some(parent_index) => remote_ids
                        .get(parent_index)
                        .and_then(Option::as_ref)
                        .cloned()
                        .with_context(|| {
                            format!(
                                "missing cloud parent while creating {}",
                                directory.display_name
                            )
                        })?,
                    None => destination_id.to_string(),
                };
                Ok((
                    index,
                    parent_id,
                    directory.name.clone(),
                    directory.display_name.clone(),
                ))
            })
            .collect::<Result<Vec<_>>>()?
            .into_iter();

        let mut set = tokio::task::JoinSet::new();
        for _ in 0..jobs.clamp(1, 4) {
            let Some((index, parent_id, name, display_name)) = pending.next() else {
                break;
            };
            let task_client = client.clone();
            let checkpoint = checkpoint.clone();
            set.spawn(async move {
                let result = resume_upload_folder(
                    &task_client,
                    index,
                    &parent_id,
                    &name,
                    checkpoint.as_deref(),
                )
                .await;
                (index, parent_id, display_name, result)
            });
        }

        let mut first_error = None;
        while let Some(joined) = set.join_next().await {
            let (index, parent_id, display_name, result) =
                joined.context("folder creation task panicked")?;
            match result {
                Ok(remote_id) => {
                    remote_ids[index] = Some(remote_id.clone());
                    created_folders = created_folders.saturating_add(1);
                    emit_upload_progress(
                        progress_json,
                        UploadProgressEvent::FolderProgress {
                            created_folders,
                            total_folders: directories.len(),
                            name: &display_name,
                            folder_id: &remote_id,
                            parent_id: &parent_id,
                        },
                    );
                }
                Err(error) => {
                    let error = anyhow::Error::from(error)
                        .context(format!("create cloud folder {display_name}"));
                    eprintln!("error: {error:#}");
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }

            if let Some((index, parent_id, name, display_name)) = pending.next() {
                let task_client = client.clone();
                let checkpoint = checkpoint.clone();
                set.spawn(async move {
                    let result = resume_upload_folder(
                        &task_client,
                        index,
                        &parent_id,
                        &name,
                        checkpoint.as_deref(),
                    )
                    .await;
                    (index, parent_id, display_name, result)
                });
            }
        }
        if let Some(error) = first_error {
            return Err(error);
        }
    }

    remote_ids
        .into_iter()
        .enumerate()
        .map(|(index, id)| {
            id.with_context(|| {
                format!(
                    "PikPak did not create planned folder {}",
                    directories[index].display_name
                )
            })
        })
        .collect()
}

async fn resume_upload_folder(
    client: &Client,
    index: usize,
    parent: &str,
    name: &str,
    checkpoint: Option<&UploadCheckpoint>,
) -> Result<String> {
    let Some(checkpoint) = checkpoint else {
        return Ok(client.create_folder(parent, name).await?);
    };
    if let Some(mut saved) = checkpoint.folder(index)? {
        if saved.parent_id != parent || saved.name != name {
            bail!("saved upload folder destination changed");
        }
        let children = client.list_folder(parent).await?;
        if let Some(id) = &saved.remote_id {
            if children
                .iter()
                .any(|item| item.id == *id && item.kind.is_folder())
            {
                return Ok(id.clone());
            }
            bail!("a folder created by this upload was moved or deleted; it was not recreated automatically");
        }
        // A quit may occur after the server creates a folder but before its
        // response reaches disk. Reconcile only IDs absent before that request.
        let matches: Vec<_> = children
            .iter()
            .filter(|item| {
                item.kind.is_folder() && item.name == name && !saved.previous_ids.contains(&item.id)
            })
            .collect();
        if matches.len() == 1 {
            saved.remote_id = Some(matches[0].id.clone());
            checkpoint.save_folder(index, &saved)?;
            return Ok(matches[0].id.clone());
        }
        return Err(PikPakError::MutationUncertain(
            "the folder is not uniquely visible in its recovery listing yet",
        )
        .into());
    }
    let previous_ids = client
        .list_folder(parent)
        .await?
        .into_iter()
        .filter(|item| item.kind.is_folder() && item.name == name)
        .map(|item| item.id)
        .collect();
    let mut saved = FolderCheckpoint {
        parent_id: parent.into(),
        name: name.into(),
        previous_ids,
        remote_id: None,
    };
    checkpoint.save_folder(index, &saved)?;
    let id = match client.create_folder(parent, name).await {
        Ok(id) => id,
        Err(error) => {
            if error.mutation_was_rejected() {
                checkpoint.clear_rejected_folder_intent(index)?;
            }
            return Err(error.into());
        }
    };
    saved.remote_id = Some(id.clone());
    checkpoint.save_folder(index, &saved)?;
    Ok(id)
}

async fn cmd_upload(client: &Client, args: UploadArgs) -> Result<()> {
    let mut requested_inputs = args.inputs;
    if let Some(inputs_file) = args.inputs_file {
        let contents = std::fs::read_to_string(&inputs_file).with_context(|| {
            format!("failed to read upload input list {}", inputs_file.display())
        })?;
        let paths: Vec<String> = serde_json::from_str(&contents)
            .with_context(|| format!("invalid upload input list {}", inputs_file.display()))?;
        requested_inputs.extend(paths.into_iter().map(PathBuf::from));
    }
    if requested_inputs.is_empty() {
        bail!("at least one local file or folder is required");
    }

    emit_upload_progress(args.progress_json, UploadProgressEvent::DiscoveryStarted);
    // Directory walking uses blocking filesystem calls and may inspect many
    // thousands of entries. Keep it off Tokio's network worker threads.
    let mut checkpoint = if let Some(directory) = args.checkpoint_dir {
        let account_id = client.tokens().user_id().await?;
        Some(UploadCheckpoint::open(
            directory,
            account_id,
            args.parent_id.clone(),
            requested_inputs.clone(),
        )?)
    } else {
        None
    };
    let saved_plan = checkpoint
        .as_ref()
        .map(|checkpoint| checkpoint.plan::<LocalUploadPlan>())
        .transpose()?
        .flatten();
    let plan = if let Some(plan) = saved_plan {
        plan
    } else {
        tokio::task::spawn_blocking(move || discover_local_uploads(requested_inputs))
            .await
            .context("local upload discovery task panicked")??
    };
    if let Some(checkpoint) = &mut checkpoint {
        checkpoint.initialize(&plan, plan.files.iter().map(|file| file.path.clone()))?;
    }
    let checkpoint = checkpoint.map(Arc::new);
    if plan.files.is_empty() && plan.directories.is_empty() {
        bail!("no uploadable local files or folders were found");
    }

    let requested_jobs = args.jobs.clamp(1, MAX_UPLOAD_FILE_WORKERS);
    let file_workers = bounded_upload_file_workers(args.jobs, plan.files.len());
    // Keep nested concurrency bounded: one huge file gets four parallel OSS
    // parts, while several simultaneous files share an approximately eight-
    // stream envelope instead of multiplying workers by four without limit.
    let multipart_workers = if file_workers == 0 {
        0
    } else {
        (8 / file_workers).clamp(1, 4)
    };
    let total_bytes = plan
        .files
        .iter()
        .fold(0u64, |total, source| total.saturating_add(source.size));
    emit_upload_progress(
        args.progress_json,
        UploadProgressEvent::Plan {
            total_files: plan.files.len(),
            total_bytes,
            total_folders: plan.directories.len(),
            file_workers,
            multipart_workers,
            skipped_entries: plan.skipped_entries,
        },
    );
    for (chunk_index, chunk) in plan.files.chunks(UPLOAD_QUEUE_BATCH_SIZE).enumerate() {
        emit_upload_progress(
            args.progress_json,
            UploadProgressEvent::QueueBatch {
                files: chunk
                    .iter()
                    .enumerate()
                    .map(|(index, source)| UploadQueueItem {
                        upload_id: (chunk_index * UPLOAD_QUEUE_BATCH_SIZE + index).to_string(),
                        name: source.display_name.clone(),
                        total_bytes: source.size,
                        source_path: source.path.to_string_lossy().into_owned(),
                    })
                    .collect(),
            },
        );
    }

    if plan.skipped_entries > 0 {
        println!(
            "Skipped {} symbolic link or special filesystem item(s)",
            plan.skipped_entries
        );
    }
    println!(
        "Discovered: {} file(s), {} folder(s), {} total bytes",
        plan.files.len(),
        plan.directories.len(),
        total_bytes
    );

    let remote_directory_ids = create_remote_upload_directories(
        client,
        &args.parent_id,
        &plan.directories,
        requested_jobs,
        args.progress_json,
        checkpoint.clone(),
    )
    .await?;

    let directory_count = plan.directories.len();
    let destination_id = args.parent_id.clone();
    let progress_json = args.progress_json;
    let sources: Vec<UploadSource> = plan
        .files
        .into_iter()
        .enumerate()
        .map(|(index, source)| {
            let remote_parent_id = source
                .parent_directory
                .map(|directory_index| remote_directory_ids[directory_index].clone())
                .unwrap_or_else(|| destination_id.clone());
            UploadSource {
                upload_id: index.to_string(),
                path: source.path,
                name: source.name,
                display_name: source.display_name,
                size: source.size,
                remote_parent_id,
            }
        })
        .collect();

    if sources.is_empty() {
        println!("Finished creating {directory_count} empty folder(s)");
        return Ok(());
    }

    println!(
        "Queued: {} file(s); at most {file_workers} active file upload(s), {multipart_workers} part(s) per large file",
        sources.len()
    );
    let source_count = sources.len();
    let mut first_error: Option<anyhow::Error> = None;
    let mut completed = 0usize;
    let batch_sent_bytes = Arc::new(AtomicU64::new(0));
    transfer_control::schedule(
        sources,
        transfer_control::Concurrency::adaptive(file_workers, batch_sent_bytes.clone()),
        |source: UploadSource| {
            let client = client.clone();
            let checkpoint = checkpoint.clone();
            let batch_sent_bytes = batch_sent_bytes.clone();
            async move {
                upload_one_file_with_retry(
                    &client,
                    &source,
                    progress_json,
                    multipart_workers,
                    checkpoint.as_deref(),
                    batch_sent_bytes,
                )
                .await
            }
        },
        |source| source.upload_id.clone(),
        |source, result| match result {
            Ok(instant) => {
                completed = completed.saturating_add(1);
                emit_upload_progress(
                    progress_json,
                    UploadProgressEvent::FileCompleted {
                        upload_id: &source.upload_id,
                        name: &source.display_name,
                        total_bytes: source.size,
                        instant,
                        parent_id: &source.remote_parent_id,
                    },
                );
                if instant {
                    println!("Uploaded instantly: {}", source.display_name);
                } else {
                    println!("Uploaded: {}", source.display_name);
                }
            }
            Err(error) if error.is::<transfer_control::Cancelled>() => {
                emit_transfer_cancelled(
                    progress_json,
                    true,
                    &source.upload_id,
                    &source.display_name,
                    source.size,
                );
            }
            Err(error) => {
                let failure_detail = format!("{error:#}");
                emit_upload_progress(
                    progress_json,
                    UploadProgressEvent::FileFailed {
                        upload_id: &source.upload_id,
                        name: &source.display_name,
                        total_bytes: source.size,
                        source_path: &source.path.to_string_lossy(),
                        parent_id: &source.remote_parent_id,
                        error: &failure_detail,
                    },
                );
                eprintln!(
                    "error: upload {} failed: {failure_detail}",
                    source.display_name
                );
                if first_error.is_none() {
                    first_error = Some(error);
                }
            }
        },
        |source, attempt, delay| {
            emit_upload_progress(
                progress_json,
                UploadProgressEvent::FileRetrying {
                    upload_id: &source.upload_id,
                    name: &source.display_name,
                    attempt,
                    max_attempts: 0,
                    retry_in_millis: delay.as_millis() as u64,
                },
            );
        },
    )
    .await?;

    if let Some(error) = first_error {
        bail!("uploaded {completed} of {source_count} file(s); first failure: {error:#}");
    }
    println!("Finished uploading {completed} file(s)");
    Ok(())
}

async fn upload_one_file_with_retry(
    client: &Client,
    source: &UploadSource,
    progress_json: bool,
    multipart_workers: usize,
    checkpoint: Option<&UploadCheckpoint>,
    batch_sent_bytes: Arc<AtomicU64>,
) -> Result<bool> {
    let mut attempt = 0u32;
    loop {
        attempt = attempt.saturating_add(1);
        let result = match transfer_control::interruptible(
            &source.upload_id,
            upload_one_file(
                client,
                source,
                progress_json,
                multipart_workers,
                checkpoint,
                batch_sent_bytes.clone(),
            ),
        )
        .await
        {
            Ok(result) => result,
            Err(cancelled) => {
                if cancelled.is::<transfer_control::Cancelled>() {
                    if let Some(checkpoint) = checkpoint {
                        let mut state = checkpoint.file(&source.path)?;
                        state.cancelled = true;
                        checkpoint.save_file(&source.path, &state)?;
                    }
                }
                return Err(cancelled);
            }
        };
        match result {
            Ok(instant) => return Ok(instant),
            Err(error) if error.is::<transfer_control::Cancelled>() => return Err(error),
            Err(error)
                if transfer_control::enabled() && upload_file_failure_is_retryable(&error) =>
            {
                return Err(error.context(transfer_control::Retry(
                    "Waiting to retry the upload".into(),
                )))
            }
            Err(error)
                if attempt < MAX_UPLOAD_FILE_ATTEMPTS
                    && upload_file_failure_is_retryable(&error) =>
            {
                let delay = if transfer_control::enabled() {
                    transfer_retry_delay(attempt)
                } else {
                    upload_file_retry_delay(attempt)
                };
                emit_upload_progress(
                    progress_json,
                    UploadProgressEvent::FileRetrying {
                        upload_id: &source.upload_id,
                        name: &source.display_name,
                        attempt: attempt.saturating_add(1),
                        max_attempts: if transfer_control::enabled() {
                            0
                        } else {
                            MAX_UPLOAD_FILE_ATTEMPTS
                        },
                        retry_in_millis: delay.as_millis() as u64,
                    },
                );
                eprintln!("Upload attempt {attempt} failed: {error:#}; waiting to retry");
                if let Err(cancelled) =
                    transfer_control::run(&source.upload_id, tokio::time::sleep(delay)).await
                {
                    if let Some(checkpoint) = checkpoint {
                        let mut state = checkpoint.file(&source.path)?;
                        state.cancelled = true;
                        checkpoint.save_file(&source.path, &state)?;
                    }
                    return Err(cancelled.into());
                }
            }
            Err(error) => return Err(error),
        }
    }
}

fn transfer_retry_delay(attempt: u32) -> Duration {
    Duration::from_secs(1u64 << attempt.saturating_sub(1).min(6)).min(Duration::from_secs(60))
}

fn upload_file_failure_is_retryable(error: &anyhow::Error) -> bool {
    if error.chain().any(|cause| {
        matches!(
            cause.downcast_ref::<PikPakError>(),
            Some(PikPakError::MutationUncertain(_))
        )
    }) {
        return false;
    }
    let message = format!("{error:#}").to_ascii_lowercase();
    let permanent_local_failure = [
        "permission denied",
        "no such file",
        "not found",
        "local file changed",
        "saved upload",
        "checkpoint",
        "unexpected eof",
        "calculate content identifier",
        "unsupported",
        "invalid upload",
        "insufficient storage",
        "storage quota",
    ]
    .iter()
    .any(|needle| message.contains(needle));
    if permanent_local_failure {
        return false;
    }

    // Authentication/captcha preparation carries typed provider failures. Its
    // error text says "API error 503", rather than the "HTTP 503" used by OSS,
    // so use the status directly when deciding whether a safe retry can run.
    if error
        .chain()
        .any(|cause| match cause.downcast_ref::<PikPakError>() {
            Some(PikPakError::Api { status, .. } | PikPakError::RetryAfter { status, .. }) => {
                pikpak::download_policy::transient_status(*status)
            }
            Some(PikPakError::Auth(message)) => message
                .strip_prefix("status ")
                .and_then(|message| message.split(':').next())
                .and_then(|status| status.parse::<u16>().ok())
                .is_some_and(pikpak::download_policy::transient_status),
            _ => false,
        })
    {
        return true;
    }

    [
        "timed out",
        "timeout",
        "connection",
        "temporar",
        "transport",
        "request failed",
        "response body",
        "upload storage",
        "http 408",
        "http 409",
        "http 425",
        "http 429",
        "http 500",
        "http 502",
        "http 503",
        "http 504",
    ]
    .iter()
    .any(|needle| message.contains(needle))
}

fn upload_file_retry_delay(failed_attempt: u32) -> Duration {
    Duration::from_millis(750u64.saturating_mul(1u64 << failed_attempt.saturating_sub(1).min(3)))
}

fn emit_upload_committed(source: &UploadSource, file_id: Option<&str>, enabled: bool) {
    if let Some(file_id) = file_id.filter(|id| !id.is_empty()) {
        emit_upload_progress(
            enabled,
            UploadProgressEvent::FileCommitted {
                file_id,
                parent_id: &source.remote_parent_id,
                name: &source.name,
            },
        );
    }
}

async fn discard_upload_placeholder(
    client: &Client,
    source: &UploadSource,
    gcid: &str,
    saved: &mut pikpak::upload_checkpoint::FileCheckpoint,
    checkpoint: Option<&UploadCheckpoint>,
) -> Result<()> {
    let id = saved
        .remote_file_id
        .clone()
        .context("saved upload discard is missing its owned file identity")?;
    if saved
        .discarding_remote_file_id
        .as_ref()
        .is_some_and(|discarding| discarding != &id)
    {
        bail!("saved upload discard belongs to a different remote file");
    }
    // Write the intent before Trash. If either its reply or the following
    // checkpoint update is lost, the same owned ID must be reconciled first.
    saved.discarding_remote_file_id = Some(id.clone());
    if let Some(checkpoint) = checkpoint {
        checkpoint.save_file(&source.path, saved)?;
    }
    client
        .discard_owned_incomplete_upload(&id, gcid, source.size)
        .await?;
    saved.remote_file_id = None;
    saved.discarding_remote_file_id = None;
    saved.creation_previous_ids = None;
    if let Some(checkpoint) = checkpoint {
        checkpoint.save_file(&source.path, saved)?;
    }
    Ok(())
}

async fn upload_one_file(
    client: &Client,
    source: &UploadSource,
    progress_json: bool,
    multipart_workers: usize,
    checkpoint: Option<&UploadCheckpoint>,
    batch_sent_bytes: Arc<AtomicU64>,
) -> Result<bool> {
    let mut saved = checkpoint
        .map(|checkpoint| checkpoint.file(&source.path))
        .transpose()?
        .unwrap_or_default();
    if saved
        .discarding_remote_file_id
        .as_ref()
        .is_some_and(|discarding| saved.remote_file_id.as_ref() != Some(discarding))
    {
        bail!("saved upload discard belongs to a different remote file");
    }
    if saved.cancelled {
        return Err(transfer_control::Cancelled.into());
    }
    if saved.completed {
        emit_upload_committed(source, saved.remote_file_id.as_deref(), progress_json);
        return Ok(true);
    }
    if let Some(checkpoint) = checkpoint {
        checkpoint.validate_source(&source.path)?;
    }
    if let (Some(checkpoint), Some(gcid)) = (checkpoint, saved.gcid.as_deref()) {
        if !checkpoint.has_source_identity(&source.path) {
            let verified =
                pikpak::upload::gcid_file(&source.path, source.size, Arc::new(|_| {})).await?;
            if !verified.eq_ignore_ascii_case(gcid) {
                bail!("local file changed since this upload was started; choose it as a new upload instead");
            }
        }
    }
    if saved.remote_file_id.is_none() {
        if let Some(previous) = &saved.creation_previous_ids {
            let gcid = saved
                .gcid
                .as_deref()
                .context("saved upload creation is missing its content identity")?;
            saved.remote_file_id = Some(
                client
                    .reconcile_upload_creation(
                        &source.remote_parent_id,
                        &source.name,
                        source.size,
                        gcid,
                        previous,
                    )
                    .await?,
            );
            if let Some(checkpoint) = checkpoint {
                checkpoint.save_file(&source.path, &saved)?;
            }
        }
    }
    if let (Some(file_id), Some(gcid)) = (&saved.remote_file_id, &saved.gcid) {
        if client
            .completed_upload_matches(file_id, gcid, source.size)
            .await?
        {
            saved.completed = true;
            // The placeholder may finish after the discard was armed but
            // before Trash was sent. Preserve the now-complete live upload.
            saved.discarding_remote_file_id = None;
            if let Some(checkpoint) = checkpoint {
                checkpoint.save_file(&source.path, &saved)?;
            }
            emit_upload_committed(source, saved.remote_file_id.as_deref(), progress_json);
            return Ok(true);
        }
    }
    emit_upload_progress(
        progress_json,
        UploadProgressEvent::FileHashing {
            upload_id: &source.upload_id,
            name: &source.display_name,
            total_bytes: source.size,
        },
    );
    let hashing_id = source.upload_id.clone();
    let hashing_name = source.display_name.clone();
    let hashing_size = source.size;
    let gcid = if let Some(gcid) = saved.gcid.clone() {
        gcid
    } else {
        pikpak::upload::gcid_file(
            &source.path,
            source.size,
            Arc::new(move |hashed_bytes| {
                emit_upload_progress(
                    progress_json,
                    UploadProgressEvent::FileHashProgress {
                        upload_id: &hashing_id,
                        name: &hashing_name,
                        hashed_bytes,
                        total_bytes: hashing_size,
                    },
                );
            }),
        )
        .await
        .with_context(|| format!("calculate content identifier for {}", source.name))?
    };
    if let Some(checkpoint) = checkpoint {
        checkpoint.validate_source(&source.path)?;
        saved.gcid = Some(gcid.clone());
        checkpoint.save_file(&source.path, &saved)?;
    }

    if saved.remote_file_id.is_some() {
        discard_upload_placeholder(client, source, &gcid, &mut saved, checkpoint).await?;
    }
    if let Some(checkpoint) = checkpoint {
        saved.creation_previous_ids = Some(
            client
                .upload_creation_snapshot(&source.remote_parent_id, &source.name)
                .await?,
        );
        checkpoint.save_file(&source.path, &saved)?;
    }
    let created = client
        .create_upload_task(&source.remote_parent_id, &source.name, source.size, &gcid)
        .await;
    let task = match created {
        Ok(task) => task,
        Err(error) => {
            if error.mutation_was_rejected() {
                saved.creation_previous_ids = None;
                if let Some(checkpoint) = checkpoint {
                    checkpoint.save_file(&source.path, &saved)?;
                }
            }
            return Err(error)
                .with_context(|| format!("create PikPak upload task for {}", source.display_name));
        }
    };
    saved.remote_file_id = task.file_id.clone();
    saved.creation_previous_ids = None;
    saved.completed = task.completed;
    if let Some(checkpoint) = checkpoint {
        checkpoint.save_file(&source.path, &saved)?;
    }
    if task.completed {
        emit_upload_committed(source, saved.remote_file_id.as_deref(), progress_json);
        return Ok(true);
    }
    let params = task
        .oss
        .context("PikPak upload task did not contain temporary upload storage")?;

    emit_upload_progress(
        progress_json,
        UploadProgressEvent::FileStarted {
            upload_id: &source.upload_id,
            name: &source.display_name,
            uploaded_bytes: 0,
            total_bytes: source.size,
        },
    );
    let upload_id = source.upload_id.clone();
    let upload_name = source.display_name.clone();
    let upload_size = source.size;
    let result = pikpak::upload::upload_to_oss_with_network(
        client.upload_http_client(),
        &params,
        &source.path,
        source.size,
        multipart_workers,
        Arc::new(move |uploaded_bytes| {
            emit_upload_progress(
                progress_json,
                UploadProgressEvent::FileProgress {
                    upload_id: &upload_id,
                    name: &upload_name,
                    uploaded_bytes,
                    total_bytes: upload_size,
                },
            );
        }),
        batch_sent_bytes,
    )
    .await;

    if result.is_err() {
        if let Some(file_id) = saved.remote_file_id.as_deref() {
            if client
                .completed_upload_matches(file_id, &gcid, source.size)
                .await
                .unwrap_or(false)
            {
                saved.completed = true;
                if let Some(checkpoint) = checkpoint {
                    checkpoint.save_file(&source.path, &saved)?;
                }
                emit_upload_committed(source, saved.remote_file_id.as_deref(), progress_json);
                return Ok(false);
            }
            if discard_upload_placeholder(client, source, &gcid, &mut saved, checkpoint)
                .await
                .is_err()
            {
                return Err(PikPakError::MutationUncertain(
                    "the existing upload needs confirmation before retry",
                )
                .into());
            }
        } else {
            return Err(PikPakError::MutationUncertain(
                "the existing upload needs confirmation before retry",
            )
            .into());
        }
    }
    result.with_context(|| format!("send {} to PikPak upload storage", source.display_name))?;
    if client.duplicate_cache().await.is_some() {
        if let Some(file_id) = saved.remote_file_id.as_deref() {
            // OSS can finish before PikPak publishes the completed entry. A
            // failed observation leaves its parent dirty for the next scan.
            let _ = client
                .completed_upload_matches(file_id, &gcid, source.size)
                .await;
        }
    }
    if let Some(checkpoint) = checkpoint {
        checkpoint.validate_source(&source.path)?;
        saved.completed = true;
        checkpoint.save_file(&source.path, &saved)?;
    }
    emit_upload_committed(source, saved.remote_file_id.as_deref(), progress_json);
    Ok(false)
}

async fn cmd_download(client: &Client, args: DownloadArgs) -> Result<()> {
    let progress_json = args.progress_json;
    let result = cmd_download_inner(client, args).await;
    if let Err(error) = &result {
        let destination_unavailable = pikpak::download_policy::destination_unavailable(error);
        let message = format!("{error:#}");
        emit_download_progress(
            progress_json,
            DownloadProgressEvent::BatchFailed {
                retryable: pikpak::download_policy::retryable(error),
                retry_in_millis: pikpak::download_policy::delay(error)
                    .map(|delay| delay.as_millis() as u64),
                destination_unavailable: destination_unavailable.then_some(true),
                error: destination_unavailable.then_some(message.as_str()),
            },
        );
    }
    result
}

async fn cmd_download_inner(client: &Client, args: DownloadArgs) -> Result<()> {
    let output_directory = download_fs::selected_directory(StdPath::new(&args.output))
        .context("failed to open selected output directory")?;
    let output = output_directory.as_path();

    let mut requested: Vec<AccountDownloadRootInput> = if let Some(path) = args.roots_file {
        read_json_request::<AccountDownloadInput>(&path)?.roots
    } else {
        args.paths
            .into_iter()
            .map(|path| AccountDownloadRootInput {
                path,
                file: None,
                relative_parent: None,
            })
            .collect()
    };
    for root in &mut requested {
        root.path = normalize_remote_path(&root.path);
    }
    let mut seen_paths = HashSet::new();
    requested.retain(|root| seen_paths.insert(root.path.clone()));
    requested.sort_by(|left, right| {
        remote_path_components(&left.path)
            .len()
            .cmp(&remote_path_components(&right.path).len())
    });

    // Resolve shallow paths first, then omit any later selection already
    // covered by a selected folder. This mirrors the GUI's inherited folder
    // selection and prevents duplicate transfers for parent + child paths.
    let mut roots: Vec<(String, pikpak::FileInfo, Option<Vec<String>>)> = Vec::new();
    for root in requested {
        if roots.iter().any(|(root_path, info, _)| {
            info.kind.is_folder() && remote_path_is_descendant(&root.path, root_path)
        }) {
            continue;
        }
        let info = match root.file {
            Some(file) if !file.id.is_empty() => file,
            _ => client
                .resolve_path_info(&root.path)
                .await
                .with_context(|| format!("failed to resolve download path {}", root.path))?,
        };
        roots.push((root.path, info, root.relative_parent));
    }
    if roots.is_empty() {
        bail!("at least one non-empty remote path is required");
    }

    let root_paths: Vec<String> = roots.iter().map(|(path, _, _)| path.clone()).collect();
    let common_parent_depth = common_download_parent_depth(&root_paths);

    // Flatten every selected root into one queue. Relative parent folders are
    // preserved when selections come from different expanded branches, which
    // prevents same-named files/folders from overwriting one another.
    let mut tasks: Vec<DownloadTask> = Vec::new();
    for (path, info, relative_parent) in roots {
        let destination = download_root_destination(
            output,
            &path,
            common_parent_depth,
            relative_parent.as_deref(),
        )?;
        download_fs::create_dir_all(&destination)
            .context("failed to create selected path destination")?;

        if info.kind.is_folder() {
            collect_folder(client, &info, &path, &destination, &mut tasks).await?;
        } else {
            tasks.push(DownloadTask {
                file: info,
                output_directory: destination,
                remote_path: path,
                retry_state: Arc::default(),
            });
        }
    }

    let total_files = tasks.len();
    let total_bytes = tasks
        .iter()
        .fold(0u64, |total, task| total.saturating_add(task.file.size));
    emit_download_progress(
        args.progress_json,
        DownloadProgressEvent::Plan {
            total_files,
            total_bytes,
        },
    );
    for chunk in tasks.chunks(DOWNLOAD_QUEUE_BATCH_SIZE) {
        emit_download_progress(
            args.progress_json,
            DownloadProgressEvent::QueueBatch {
                files: chunk
                    .iter()
                    .map(|task| DownloadQueueItem {
                        file_id: &task.file.id,
                        name: &task.file.name,
                        total_bytes: task.file.size,
                        remote_path: &task.remote_path,
                        output_directory: task.output_directory.to_string_lossy().into_owned(),
                    })
                    .collect(),
            },
        );
    }

    if tasks.is_empty() {
        println!("(nothing to download)");
        return Ok(());
    }

    // Keep the live task set bounded even when the CLI receives an excessive
    // value, and never create more workers than there are files to transfer.
    let jobs = bounded_download_workers(args.jobs, tasks.len());
    // Human terminal progress only reads cleanly with a single active
    // transfer. The GUI receives throttled structured progress at any worker
    // count instead.
    let show_progress = jobs == 1 && !args.progress_json;
    let progress_json = args.progress_json;

    println!(
        "Queued: {} file(s); at most {jobs} active download(s)",
        tasks.len()
    );

    // Measure actual body bytes across the whole batch, including retries and
    // completed files, without counting partial data already saved on disk.
    let batch_received_bytes = Arc::new(AtomicU64::new(0));
    let mut first_err: Option<anyhow::Error> = None;
    transfer_control::schedule(
        tasks,
        transfer_control::Concurrency::download(jobs, batch_received_bytes.clone()),
        |task: DownloadTask| {
            let client = client.clone();
            let batch_received_bytes = batch_received_bytes.clone();
            async move {
                emit_download_progress(
                    progress_json,
                    DownloadProgressEvent::FileDequeued {
                        file_id: &task.file.id,
                        name: &task.file.name,
                        total_bytes: task.file.size,
                    },
                );
                download_file_as_with_retry(
                    &client,
                    &task.file,
                    &task.output_directory,
                    show_progress,
                    progress_json,
                    batch_received_bytes,
                    &task.file.id,
                    None,
                    task.retry_state.clone(),
                )
                .await
            }
        },
        |task| task.file.id.clone(),
        |_, result| {
            if let Err(error) = result {
                if first_err.is_none() {
                    first_err = Some(error);
                }
            }
        },
        |task, attempt, delay| {
            emit_download_progress(
                progress_json,
                DownloadProgressEvent::FileRetrying {
                    file_id: &task.file.id,
                    name: &task.file.name,
                    attempt,
                    retry_in_millis: delay.as_millis() as u64,
                    destination_unavailable: None,
                    error: None,
                },
            );
        },
    )
    .await?;
    match first_err {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

async fn cmd_share_download(account: &Client, args: ShareDownloadArgs) -> Result<()> {
    let progress_json = args.progress_json;
    let result = cmd_share_download_inner(account, args).await;
    if let Err(error) = &result {
        let destination_unavailable = pikpak::download_policy::destination_unavailable(error);
        let message = format!("{error:#}");
        emit_download_progress(
            progress_json,
            DownloadProgressEvent::BatchFailed {
                retryable: pikpak::download_policy::retryable(error),
                retry_in_millis: pikpak::download_policy::delay(error)
                    .map(|delay| delay.as_millis() as u64),
                destination_unavailable: destination_unavailable.then_some(true),
                error: destination_unavailable.then_some(message.as_str()),
            },
        );
    }
    result
}

async fn cmd_share_download_inner(account: &Client, args: ShareDownloadArgs) -> Result<()> {
    let request: ShareDownloadInput = read_json_request(&args.request_file)?;
    let client = build_share_client(&request.access, account)?;
    let output_directory = download_fs::selected_directory(StdPath::new(&args.output))
        .context("failed to open selected output directory")?;
    let output = output_directory.as_path();

    let mut seen_ids = HashSet::new();
    let mut roots: Vec<ShareDownloadRoot> = request
        .roots
        .into_iter()
        .filter(|root| !root.id.trim().is_empty() && seen_ids.insert(root.id.clone()))
        .collect();
    roots.sort_by(|left, right| {
        remote_path_components(&left.path)
            .len()
            .cmp(&remote_path_components(&right.path).len())
    });
    let mut accepted: Vec<ShareDownloadRoot> = Vec::new();
    for root in roots {
        if accepted.iter().any(|ancestor| {
            ancestor.kind.is_folder() && remote_path_is_descendant(&root.path, &ancestor.path)
        }) {
            continue;
        }
        accepted.push(root);
    }
    if accepted.is_empty() {
        bail!("select at least one shared file or folder to download");
    }

    let root_paths: Vec<String> = accepted.iter().map(|root| root.path.clone()).collect();
    let common_parent_depth = common_download_parent_depth(&root_paths);
    let mut tasks: Vec<DownloadTask> = Vec::new();
    for root in accepted {
        let destination = download_root_destination(
            output,
            &root.path,
            common_parent_depth,
            root.relative_parent.as_deref(),
        )?;
        download_fs::create_dir_all(&destination)
            .context("failed to create shared path destination")?;
        let info = root.file_info();
        if info.kind.is_folder() {
            collect_share_folder(&client, &info, &root.path, &destination, &mut tasks).await?;
        } else {
            tasks.push(DownloadTask {
                file: info,
                output_directory: destination,
                remote_path: root.path,
                retry_state: Arc::default(),
            });
        }
    }

    let total_files = tasks.len();
    let total_bytes = tasks
        .iter()
        .fold(0u64, |total, task| total.saturating_add(task.file.size));
    emit_download_progress(
        args.progress_json,
        DownloadProgressEvent::Plan {
            total_files,
            total_bytes,
        },
    );
    for chunk in tasks.chunks(DOWNLOAD_QUEUE_BATCH_SIZE) {
        emit_download_progress(
            args.progress_json,
            DownloadProgressEvent::QueueBatch {
                files: chunk
                    .iter()
                    .map(|task| DownloadQueueItem {
                        file_id: &task.file.id,
                        name: &task.file.name,
                        total_bytes: task.file.size,
                        remote_path: &task.remote_path,
                        output_directory: task.output_directory.to_string_lossy().into_owned(),
                    })
                    .collect(),
            },
        );
    }
    if tasks.is_empty() {
        println!("(nothing to download)");
        return Ok(());
    }

    let jobs = bounded_download_workers(args.jobs, tasks.len());
    let show_progress = jobs == 1 && !args.progress_json;
    let progress_json = args.progress_json;
    println!(
        "Queued: {} shared file(s); at most {jobs} active download(s)",
        tasks.len()
    );

    let batch_received_bytes = Arc::new(AtomicU64::new(0));
    let mut first_err: Option<anyhow::Error> = None;
    transfer_control::schedule(
        tasks,
        transfer_control::Concurrency::download(jobs, batch_received_bytes.clone()),
        |task: DownloadTask| {
            let client = client.clone();
            let batch_received_bytes = batch_received_bytes.clone();
            async move {
                emit_download_progress(
                    progress_json,
                    DownloadProgressEvent::FileDequeued {
                        file_id: &task.file.id,
                        name: &task.file.name,
                        total_bytes: task.file.size,
                    },
                );
                download_share_file_as_with_retry(
                    &client,
                    &task.file,
                    &task.output_directory,
                    show_progress,
                    progress_json,
                    batch_received_bytes,
                    &task.file.id,
                    task.retry_state.clone(),
                )
                .await
            }
        },
        |task| task.file.id.clone(),
        |_, result| {
            if let Err(error) = result {
                if first_err.is_none() {
                    first_err = Some(error);
                }
            }
        },
        |task, attempt, delay| {
            emit_download_progress(
                progress_json,
                DownloadProgressEvent::FileRetrying {
                    file_id: &task.file.id,
                    name: &task.file.name,
                    attempt,
                    retry_in_millis: delay.as_millis() as u64,
                    destination_unavailable: None,
                    error: None,
                },
            );
        },
    )
    .await?;
    match first_err {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

fn remote_path_components(path: &str) -> Vec<String> {
    path.trim_matches('/')
        .split('/')
        .filter(|component| !component.is_empty())
        .map(str::to_string)
        .collect()
}

fn remote_path_is_descendant(path: &str, possible_ancestor: &str) -> bool {
    let path = remote_path_components(path);
    let ancestor = remote_path_components(possible_ancestor);
    path.len() > ancestor.len() && path.starts_with(&ancestor)
}

fn appending_remote_path_component(parent: &str, name: &str) -> String {
    let parent = parent.trim_end_matches('/');
    if parent.is_empty() {
        format!("/{name}")
    } else {
        format!("{parent}/{name}")
    }
}

fn common_download_parent_depth(paths: &[String]) -> usize {
    let parents: Vec<Vec<String>> = paths
        .iter()
        .map(|path| {
            let mut components = remote_path_components(path);
            components.pop();
            components
        })
        .collect();
    let Some(first) = parents.first() else {
        return 0;
    };
    (0..first.len())
        .take_while(|index| {
            parents
                .iter()
                .all(|components| components.get(*index) == first.get(*index))
        })
        .count()
}

fn download_root_destination(
    output: &StdPath,
    remote_path: &str,
    common_parent_depth: usize,
    relative_parent: Option<&[String]>,
) -> Result<PathBuf> {
    let components = remote_path_components(remote_path);
    let fallback: Vec<String> = components
        .iter()
        .take(components.len().saturating_sub(1))
        .skip(common_parent_depth)
        .cloned()
        .collect();
    let mut destination = output.to_path_buf();
    for component in relative_parent.unwrap_or(&fallback) {
        destination.push(safe_component(component)?);
    }
    Ok(destination)
}

/// Reduce a server-provided name to a single safe path component,
/// preventing path traversal via absolute paths, `..`, or embedded
/// separators, and leave room for the partial file's suffix.
fn safe_component(name: &str) -> Result<String> {
    download_names::component(name)
}

/// A download failure classified for retry: transient conditions are retried,
/// fatal ones abort immediately.
enum DlError {
    Retryable(anyhow::Error),
    Fatal(anyhow::Error),
}

impl DlError {
    fn into_inner(self) -> anyhow::Error {
        match self {
            DlError::Retryable(e) => e.context(pikpak::download_policy::Interrupted),
            DlError::Fatal(e) => e,
        }
    }
}

/// Maximum download attempts (initial try + retries) per file.
const MAX_DOWNLOAD_ATTEMPTS: u32 = 5;

fn signed_download_url_rejected(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        let failure = cause
            .downcast_ref::<pikpak::download_policy::HttpFailure>()
            .or_else(
                || match cause.downcast_ref::<pikpak::download_ranges::Error>() {
                    Some(pikpak::download_ranges::Error::Http(failure)) => Some(failure),
                    _ => None,
                },
            );
        failure.is_some_and(|failure| matches!(failure.status, 401 | 403))
    })
}

fn download_range_rejected(error: &anyhow::Error) -> bool {
    if error.is::<pikpak::download_policy::InvalidByteRange>() {
        return true;
    }
    error.chain().any(|cause| {
        cause.is::<pikpak::download_policy::InvalidByteRange>() || cause
            .downcast_ref::<pikpak::download_policy::HttpFailure>()
            .or_else(
                || match cause.downcast_ref::<pikpak::download_ranges::Error>() {
                    Some(pikpak::download_ranges::Error::Http(failure)) => Some(failure),
                    _ => None,
                },
            )
            .is_some_and(|failure| failure.status == 416)
    })
}

fn download_route_unavailable(error: &anyhow::Error) -> bool {
    pikpak::content_mode::content_access_denied(error) || download_range_rejected(error)
        || download_preparation::guest_route_unavailable(error)
}

fn explain_original_url_failure(error: anyhow::Error, user: bool, after_guest: bool) -> anyhow::Error {
    if user && error.downcast_ref::<PikPakError>().is_some_and(|error| matches!(error, PikPakError::InvalidDownloadUrl)) {
        error.context(if after_guest {
            "Guest access was unavailable; User Mode also provided no original URL after a fresh lookup"
        } else {
            "User Mode provided no original URL after a fresh lookup"
        })
    } else { error }
}

/// A helper holds filesystem identities for its lifetime. Ask the native queue
/// to revalidate the original volume before restarting a helper with new FDs.
fn download_destination_error(
    error: anyhow::Error,
    progress_json: bool,
    transfer_id: &str,
    name: &str,
) -> anyhow::Error {
    if !pikpak::download_policy::destination_unavailable(&error) {
        return error;
    }
    let message = format!("{error:#}");
    emit_download_progress(
        progress_json,
        DownloadProgressEvent::FileRetrying {
            file_id: transfer_id,
            name,
            attempt: 0,
            retry_in_millis: 1000,
            destination_unavailable: Some(true),
            error: Some(&message),
        },
    );
    if transfer_control::enabled() && !error.is::<transfer_control::Retry>() {
        error.context(transfer_control::Retry(
            "Waiting for the original download destination".into(),
        ))
    } else {
        error
    }
}

async fn download_file(
    client: &Client,
    file: &pikpak::FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    batch_received_bytes: Arc<AtomicU64>,
) -> Result<()> {
    download_file_as(
        client,
        file,
        output_dir,
        show_progress,
        progress_json,
        batch_received_bytes,
        &file.id,
        None,
    )
    .await
}

/// Receipt rejection can happen before the transport starts. Only the
/// receipt's independently verified original may contribute retained bytes;
/// an unverified partial length must never create apparent progress.
fn download_failure_progress_events<'a>(
    error: &anyhow::Error,
    transfer_id: &'a str,
    name: &'a str,
    fallback_total: u64,
    message: &'a str,
) -> Vec<DownloadProgressEvent<'a>> {
    let verified = error.downcast_ref::<download_receipt::VerifiedStagingProgress>();
    let mut events = Vec::with_capacity(if verified.is_some() { 2 } else { 1 });
    if let Some(progress) = verified {
        events.push(DownloadProgressEvent::FileStarted {
            file_id: transfer_id,
            name,
            downloaded_bytes: progress.downloaded_bytes,
            transferred_bytes: 0,
            total_bytes: progress.total_bytes,
        });
    }
    events.push(DownloadProgressEvent::FileFailed {
        error: message,
        file_id: transfer_id,
        name,
        downloaded_bytes: verified.map_or(0, |progress| progress.downloaded_bytes),
        transferred_bytes: 0,
        total_bytes: verified.map_or(fallback_total, |progress| progress.total_bytes),
        permanent: pikpak::download_policy::permanent_failure(error),
    });
    events
}

fn emit_download_failure_progress(
    enabled: bool,
    error: &anyhow::Error,
    transfer_id: &str,
    name: &str,
    fallback_total: u64,
) {
    let message = error
        .downcast_ref::<download_receipt::VerifiedStagingProgress>()
        .map(|progress| progress.failure.clone())
        .unwrap_or_else(|| format!("{error:#}"));
    for event in
        download_failure_progress_events(error, transfer_id, name, fallback_total, &message)
    {
        emit_download_progress(enabled, event);
    }
}

async fn download_file_as(
    client: &Client,
    file: &pikpak::FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    batch_received_bytes: Arc<AtomicU64>,
    transfer_id: &str,
    delete_after_download: Option<&AtomicBool>,
) -> Result<()> {
    download_file_as_with_retry(client, file, output_dir, show_progress, progress_json,
        batch_received_bytes, transfer_id, delete_after_download, Arc::default()).await
}

async fn download_file_as_with_retry(
    client: &Client,
    file: &pikpak::FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    batch_received_bytes: Arc<AtomicU64>,
    transfer_id: &str,
    delete_after_download: Option<&AtomicBool>,
    retry_state: Arc<download_transport::RetryState>,
) -> Result<()> {
    let mut preparation = retry_state.preparation.attempt();
    let expected = output_dir.join(safe_component(&file.name)?);
    let _output_lease = match transfer_control::output_lock(&expected, transfer_id).await {
        Ok(lease) => lease,
        Err(error) if error.is::<transfer_control::Cancelled>() => {
            emit_transfer_cancelled(progress_json, false, transfer_id, &file.name, file.size);
            return Ok(());
        }
        Err(error) => {
            return Err(download_destination_error(
                error,
                progress_json,
                transfer_id,
                &file.name,
            ))
        }
    };
    let original_mode = client.content_mode();
    let mut initialization_error = None;
    let mut account_handoff = false;
    if original_mode == pikpak::ContentMode::Dynamic && retry_state.preparation.has_user_handoff() {
        match transfer_control::metadata_interruptible(transfer_id, client.tokens().user_id()).await {
            Ok(Ok(account)) => {
                let key = download_preparation::Key::for_file(format!("account:{account}"), file, Some(original_mode));
                account_handoff = retry_state.preparation.user_handoff(&key);
            }
            Ok(Err(error)) => initialization_error = Some(anyhow::Error::new(error)),
            Err(error) => initialization_error = Some(error),
        }
    }
    let mut route = if account_handoff { client.clone().with_content_mode(pikpak::ContentMode::User) } else { client.clone() };
    let network_counter = transfer_control::network_counter(transfer_id);
    loop {
        // Keep the large transport/metadata state on the heap. Queue and
        // control wrappers otherwise embed every inner future in their own
        // stack frame, especially costly in unoptimized helpers and tests.
        let result = if let Some(error) = initialization_error.take() { Err(error) } else { Box::pin(download_file_inner(
            &route,
            file,
            output_dir,
            show_progress,
            progress_json,
            network_counter.clone(),
            batch_received_bytes.clone(),
            transfer_id,
            account_handoff,
            original_mode,
            _output_lease.as_ref(),
            retry_state.clone(),
        ))
        .await };
        match result {
            Ok(finished) => {
                // Only a download that is verified complete may lead to its source being moved to Trash.
                if let (Finished::Complete, Some(enabled)) = (finished, delete_after_download) {
                    download_cleanup::after_complete(
                        client, file, &expected, transfer_id, progress_json, enabled,
                    )
                    .await?;
                }
                return Ok(());
            }
            Err(error) if error.is::<transfer_control::Cancelled>() => {
                let partial = output_dir.join(format!("{}.part", safe_component(&file.name)?));
                transfer_control::remove_owned_partial_as(&partial, &file.id, transfer_id).await?;
                emit_transfer_cancelled(progress_json, false, transfer_id, &file.name, file.size);
                return Ok(());
            }
            Err(error) if error.is::<download_verification::Deferred>() => {
                preparation.defer();
                return Err(error);
            }
            Err(error) if error.is::<transfer_control::Paused>() => return Err(error),
            Err(error) if error.is::<transfer_control::Retry>() => return Err(error),
            Err(error) if pikpak::download_policy::destination_unavailable(&error) => {
                return Err(download_destination_error(
                    error,
                    progress_json,
                    transfer_id,
                    &file.name,
                ));
            }
            Err(error)
                if route.content_mode() == pikpak::ContentMode::Dynamic
                    && download_route_unavailable(&error) =>
            {
                // This route belongs to one file; other items keep trying guest.
                route = route.with_content_mode(pikpak::ContentMode::User);
                account_handoff = true;
                continue;
            }
            Err(error)
                if transfer_control::enabled() && pikpak::download_policy::retryable(&error) =>
            {
                preparation.retry_body(&error);
                return Err(error.context(transfer_control::Retry(
                    "Waiting to retry the download".into(),
                )));
            }
            Err(error) => {
                let error = explain_original_url_failure(error,
                    route.content_mode() == pikpak::ContentMode::User, account_handoff);
                if let Err(destination) = download_fs::validate(output_dir) {
                    if pikpak::download_policy::destination_io_interrupted(&destination) {
                        return Err(download_destination_error(
                            error.context(pikpak::download_policy::DestinationUnavailable),
                            progress_json,
                            transfer_id,
                            &file.name,
                        ));
                    }
                }
                emit_download_failure_progress(
                    progress_json,
                    &error,
                    transfer_id,
                    &file.name,
                    file.size,
                );
                return Err(error);
            }
        }
    }
}

/// Progress reporter for a full read of an existing file, or none when events are off.
fn verification_progress(
    progress_json: bool,
    transfer_id: &str,
    name: &str,
) -> Option<download_receipt::VerifyProgress> {
    if !progress_json {
        return None;
    }
    let (id, name) = (transfer_id.to_owned(), name.to_owned());
    Some(Arc::new(move |verified, total| {
        emit_download_progress(
            true,
            DownloadProgressEvent::FileVerifying {
                file_id: &id,
                name: &name,
                verified_bytes: verified,
                total_bytes: total,
            },
        );
    }))
}

/// Skips a finished file that its receipt already vouches for, from metadata alone, before a download link is
/// requested: the link would never be used. Anything the receipt cannot vouch for takes the normal route.
async fn skip_receipted_without_link(
    file: &FileInfo,
    file_path: &StdPath,
    scope: String,
    progress_json: bool,
    transfer_id: &str,
    output_lease: Option<&std::fs::File>,
) -> Result<bool> {
    let revision = pikpak::client::download_revision(file.hash.as_deref(), file.modified_time.as_deref());
    if file.size == 0 {
        return Ok(false);
    }
    let listed = pikpak::DownloadInfo {
        web_content_link: String::new(),
        name: file.name.clone(),
        size: file.size,
        source_revision: revision,
    };
    let mut source = download_receipt::Source::from_download(scope.clone(), &file.id, &listed, file.size);
    let mut published_output = download_receipt::completed_without_reading(file_path, &source, transfer_id).await?;
    if published_output.is_none() && file.hash.as_deref().is_none_or(|value| value.trim().is_empty()) {
        if let Some((output, recorded_source)) = download_receipt::completed_with_unknown_revision(
            file_path, &scope, &file.id, file.size, transfer_id,
        ).await? {
            published_output = Some(output);
            source = recorded_source;
        }
    }
    let Some(published_output) = published_output else {
        return Ok(false);
    };
    if let Some(lease) = output_lease {
        let _ = download_receipt::cleanup_completed_staging_async_with_lease(
            file_path,
            &source,
            transfer_id,
            lease,
        )
        .await;
    }
    println!(
        "Skipped (verified complete): {}",
        published_output.display()
    );
    emit_download_progress(
        progress_json,
        DownloadProgressEvent::FileSkipped {
            file_id: transfer_id,
            name: &file.name,
            output_path: published_output.to_str(),
            downloaded_bytes: file.size,
            transferred_bytes: 0,
            total_bytes: file.size,
        },
    );
    Ok(true)
}

/// Reports a file whose source is already in PikPak's recycle bin as skipped. The delivered copy is named only
/// when it is still in the output folder at its full size.
fn skip_recycled_source(
    file: &FileInfo,
    output_dir: &StdPath,
    progress_json: bool,
    transfer_id: &str,
) -> Result<()> {
    let delivered = output_dir.join(safe_component(&file.name)?);
    let delivered = std::fs::metadata(&delivered)
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() == file.size)
        .then_some(delivered);
    println!(
        "Skipped (already in PikPak's recycle bin, so it was downloaded before): {}",
        file.name
    );
    emit_download_progress(
        progress_json,
        DownloadProgressEvent::FileSkipped {
            file_id: transfer_id,
            name: &file.name,
            output_path: delivered.as_deref().and_then(StdPath::to_str),
            downloaded_bytes: file.size,
            transferred_bytes: 0,
            total_bytes: file.size,
        },
    );
    Ok(())
}

/// How a download call that did not fail ended.
enum Finished {
    /// The file is in the output folder, verified, and its PikPak source may be cleaned up if the user asked.
    Complete,
    /// The source was already in PikPak's recycle bin. Nothing was fetched and there is nothing left to clean up.
    SourceInRecycleBin,
}

async fn download_file_inner(
    client: &Client,
    file: &pikpak::FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    network_counter: Arc<AtomicU64>,
    batch_received_bytes: Arc<AtomicU64>,
    transfer_id: &str,
    account_handoff: bool,
    original_mode: pikpak::ContentMode,
    output_lease: Option<&std::fs::File>,
    retry_state: Arc<download_transport::RetryState>,
) -> Result<Finished> {
    let early_account =
        transfer_control::metadata_interruptible(transfer_id, client.tokens().user_id()).await??;
    let setup_key = download_preparation::Key::for_file(format!("account:{early_account}"), file, Some(original_mode));
    if skip_receipted_without_link(
        file,
        &output_dir.join(safe_component(&file.name)?),
        setup_key.scope.clone(),
        progress_json,
        transfer_id,
        output_lease,
    )
    .await?
    {
        return Ok(Finished::Complete);
    }
    let mut dl = if let Some(info) = retry_state.preparation.download(&setup_key, account_handoff) {
        info
    } else {
        // Keep the actual route visible to the outer per-file handoff loop.
        // Otherwise metadata fallback would issue a User URL while leaving
        // the retry state marked Guest and repeat setup after a body outage.
        let lookup = if client.content_mode() == pikpak::ContentMode::Dynamic {
            client.clone().with_content_mode(pikpak::ContentMode::Guest)
        } else { client.clone() };
        match transfer_control::metadata_interruptible(
            transfer_id,
            lookup.get_download_url_for_file(file),
        ).await? {
            Ok(dl) => {
                retry_state.preparation.remember_download(&setup_key, &dl, account_handoff);
                dl
            }
            // The app moves a source to PikPak's recycle bin only after its download completed, so a file found
            // there has already been delivered. It is skipped, not reported as an interrupted download.
            Err(error) if error.is_file_in_recycle_bin() => {
                skip_recycled_source(file, output_dir, progress_json, transfer_id)?;
                return Ok(Finished::SourceInRecycleBin);
            }
            Err(error) => return Err(download_preparation::guest_lookup_failure(error,
                client.content_mode() == pikpak::ContentMode::Dynamic)).context("failed to get download URL"),
        }
    };
    // Keep one destination through URL refresh and Guest/User handoff, even
    // if the cloud item is renamed while this download is running.
    dl.name.clone_from(&file.name);
    let size = if dl.size == 0 { file.size } else { dl.size };

    let file_path = output_dir.join(safe_component(&dl.name)?);
    let mut part = file_path.clone().into_os_string();
    part.push(".part");
    let part_path = PathBuf::from(part);
    let expected_name = safe_component(&file.name)?;
    let _renamed_output_lease =
        if !transfer_control::same_output(&file_path, &output_dir.join(&expected_name))? {
            transfer_control::output_lock(&file_path, transfer_id).await?
        } else {
            None
        };

    let source =
        download_receipt::Source::from_download(setup_key.scope.clone(), &file.id, &dl, size);
    if let Some(published_output) = download_receipt::ensure_available_path_async_replacing(
        &file_path,
        &source,
        transfer_id,
        verification_progress(progress_json, transfer_id, &dl.name),
        _renamed_output_lease.as_ref().or(output_lease),
    )
    .await?
    {
        if let Some(lease) = _renamed_output_lease.as_ref().or(output_lease) {
            // The destination is already verified. Cleanup is best effort:
            // a held ancestor, changed staging file, or disk error preserves
            // the original without turning completion into another failure.
            let _ = download_receipt::cleanup_completed_staging_async_with_lease(
                &file_path,
                &source,
                transfer_id,
                lease,
            )
            .await;
        }
        println!(
            "Skipped (verified complete): {}",
            published_output.display()
        );
        emit_download_progress(
            progress_json,
            DownloadProgressEvent::FileSkipped {
                file_id: transfer_id,
                name: &dl.name,
                output_path: published_output.to_str(),
                downloaded_bytes: size,
                transferred_bytes: 0,
                total_bytes: size,
            },
        );
        return Ok(Finished::Complete);
    }

    if let Some(lease) = _renamed_output_lease.as_ref().or(output_lease) {
        transfer_control::claim_partial_as_with_lease(&part_path, &file.id, transfer_id, lease)?;
    } else {
        transfer_control::claim_partial_as(&part_path, &file.id, transfer_id)?;
    }
    let existing_bytes = download_transport::saved_bytes(&part_path, &file.id, size).await;
    emit_download_progress(
        progress_json,
        DownloadProgressEvent::FileStarted {
            file_id: transfer_id,
            name: &dl.name,
            downloaded_bytes: if size > 0 {
                existing_bytes.min(size)
            } else {
                existing_bytes
            },
            transferred_bytes: network_counter.load(Ordering::Relaxed),
            total_bytes: size,
        },
    );

    println!("Downloading: {} ({})", dl.name, format_size(size, BINARY));

    // The download link is time-limited; refresh it on each retry.
    let mut link = dl.web_content_link.clone();
    let mut guest_url_refreshed = false;
    let mut attempt: u32 = 0;
    let mut progress = DownloadProgressContext::new(progress_json, transfer_id, &dl.name);
    progress.retry_state = retry_state.clone();
    progress.source_file_id = &file.id;
    progress.source_revision = dl.source_revision.clone();
    progress.require_content_hash =
        account_handoff || client.content_mode() == pikpak::ContentMode::Dynamic;
    progress.guest_range_fallback = client.content_mode() == pikpak::ContentMode::Dynamic;
    progress.transferred_bytes = network_counter;
    progress.batch_received_bytes = Some(batch_received_bytes);
    let verified = loop {
        attempt += 1;
        match download_attempt(
            client,
            &link,
            size,
            &part_path,
            show_progress,
            progress.clone(),
        )
        .await
        {
            Ok(verified) => break verified,
            Err(err) => {
                let retryable = matches!(err, DlError::Retryable(_));
                let e = err.into_inner();
                if e.is::<transfer_control::Paused>() || e.is::<download_verification::Deferred>() {
                    return Err(e);
                }
                if e.is::<transfer_control::Cancelled>() {
                    transfer_control::remove_owned_partial_as(&part_path, &file.id, transfer_id)
                        .await?;
                    return Err(e);
                }
                if client.content_mode() == pikpak::ContentMode::Dynamic
                    && download_route_unavailable(&e)
                {
                    if !guest_url_refreshed
                        && (signed_download_url_rejected(&e) || download_range_rejected(&e))
                    {
                        guest_url_refreshed = true;
                        let guest = client.clone().with_content_mode(pikpak::ContentMode::Guest);
                        match transfer_control::interruptible(
                            transfer_id,
                            guest.get_download_url_for_file(file),
                        )
                        .await?
                        {
                            Ok(fresh) => {
                                let fresh_size = if fresh.size == 0 {
                                    file.size
                                } else {
                                    fresh.size
                                };
                                anyhow::ensure!(fresh_size == size && (fresh.source_revision == dl.source_revision
                                    || pikpak::content_mode::matching_content_revision(fresh.source_revision.as_deref(), dl.source_revision.as_deref())),
                                    "The download source changed while refreshing its Guest URL; resume to retrieve the current original");
                                dl.web_content_link = fresh.web_content_link;
                                retry_state.preparation.remember_download(&setup_key, &dl, account_handoff);
                                link = dl.web_content_link.clone();
                                continue;
                            }
                            Err(error) => {
                                let error = anyhow::Error::new(error);
                                if pikpak::download_policy::retryable(&error) {
                                    return Err(error)
                                        .context("Failed to refresh the Guest download URL");
                                }
                            }
                        }
                    }
                    return Err(e);
                }
                if e.is::<pikpak::download_policy::PartialContent>() {
                    // A shorter response may still permit Guest access to the
                    // next range. Each continuation must advance saved bytes.
                    attempt = attempt.saturating_sub(1);
                    continue;
                }
                if retryable && attempt < MAX_DOWNLOAD_ATTEMPTS && !transfer_control::enabled() {
                    let delay = download_backoff(attempt - 1)
                        .max(pikpak::download_policy::delay(&e).unwrap_or_default());
                    eprintln!(
                        "  {}: attempt {attempt} failed ({e:#}); retrying in {:.1}s",
                        dl.name,
                        delay.as_secs_f64()
                    );
                    emit_download_progress(
                        progress_json,
                        DownloadProgressEvent::FileRetrying {
                            file_id: transfer_id,
                            name: &dl.name,
                            attempt,
                            retry_in_millis: delay.as_millis() as u64,
                            destination_unavailable: None,
                            error: None,
                        },
                    );
                    if let Err(cancelled) =
                        transfer_control::run(transfer_id, tokio::time::sleep(delay)).await
                    {
                        transfer_control::remove_owned_partial_as(
                            &part_path,
                            &file.id,
                            transfer_id,
                        )
                        .await?;
                        return Err(cancelled.into());
                    }
                    if let Ok(fresh) = client.get_download_url_for_file(file).await {
                        let fresh_size = if fresh.size == 0 {
                            file.size
                        } else {
                            fresh.size
                        };
                        anyhow::ensure!(fresh_size == size && fresh.source_revision == dl.source_revision,
                            "The download source changed while refreshing its URL; resume to retrieve the current original");
                        dl.web_content_link = fresh.web_content_link;
                        retry_state.preparation.remember_download(&setup_key, &dl, account_handoff);
                        link = dl.web_content_link.clone();
                    }
                    continue;
                }
                return Err(download_preparation::body_failure(e)).with_context(|| format!("failed to download {}", dl.name));
            }
        }
    };

    let completed_size = if size > 0 {
        size
    } else {
        download_fs::metadata_async(&part_path)
            .await
            .map(|metadata| metadata.len())
            .unwrap_or(0)
    };
    if let Err(cancelled) =
        transfer_control::disk_interruptible(transfer_id, std::future::ready(())).await
    {
        if cancelled.is::<transfer_control::Cancelled>() {
            transfer_control::remove_owned_partial_as(&part_path, &file.id, transfer_id).await?;
        }
        return Err(cancelled);
    }
    let published_output = match download_receipt::finish_resolved_verified(
        &part_path,
        &file_path,
        source,
        transfer_id,
        verified,
    )
    .await
    {
        Ok(output) => output,
        Err(error) => {
            if error.is::<transfer_control::Cancelled>() {
                transfer_control::remove_owned_partial_as(&part_path, &file.id, transfer_id)
                    .await?;
            }
            return Err(error);
        }
    };
    download_transport::remove_state(&part_path)?;
    println!("Saved: {}", published_output.display());
    emit_download_progress(
        progress_json,
        DownloadProgressEvent::FileCompleted {
            file_id: transfer_id,
            name: &dl.name,
            output_path: published_output.to_str(),
            downloaded_bytes: completed_size,
            transferred_bytes: progress.transferred_bytes(),
            total_bytes: completed_size,
        },
    );
    Ok(Finished::Complete)
}

/// A single download attempt. Resumes from an existing `.part` file via an HTTP
/// `Range` request when the server supports it, else restarts cleanly.
async fn download_attempt(
    client: &Client,
    link: &str,
    total: u64,
    part_path: &StdPath,
    show_progress: bool,
    progress: DownloadProgressContext<'_>,
) -> std::result::Result<Option<download_transport::VerifiedCompletion>, DlError> {
    download_attempt_with_http(
        client.download_http_client(),
        link,
        total,
        part_path,
        show_progress,
        progress,
        None,
    )
    .await
}

async fn download_attempt_with_http(
    http: &reqwest::Client,
    link: &str,
    total: u64,
    part_path: &StdPath,
    show_progress: bool,
    progress: DownloadProgressContext<'_>,
    referer: Option<&str>,
) -> std::result::Result<Option<download_transport::VerifiedCompletion>, DlError> {
    download_transport::attempt_for_publication(
        http,
        link,
        total,
        part_path,
        show_progress,
        progress,
        referer,
    )
    .await
}

/// Wrap an I/O error as a fatal download error with context.
fn fatal(err: impl std::error::Error + Send + Sync + 'static, ctx: &'static str) -> DlError {
    DlError::Fatal(anyhow::Error::new(err).context(ctx))
}

/// Classify a reqwest error as retryable (transient network) or fatal.
fn classify(err: reqwest::Error, ctx: &'static str) -> DlError {
    let transient = err.is_timeout()
        || err.is_connect()
        || err.is_request()
        || err.is_body()
        || err.is_decode();
    let e = anyhow::Error::new(err.without_url()).context(ctx);
    if transient {
        DlError::Retryable(e)
    } else {
        DlError::Fatal(e)
    }
}

/// Exponential backoff for download retry attempt `n` (0-based): 500ms, 1s, 2s,
/// ... capped at 15s.
fn download_backoff(attempt: u32) -> Duration {
    let ms = 500u64.saturating_mul(1u64 << attempt.min(5));
    Duration::from_millis(ms.min(15_000))
}

async fn download_share_file(
    client: &ShareClient,
    file: &FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    batch_received_bytes: Arc<AtomicU64>,
) -> Result<()> {
    download_share_file_as(
        client,
        file,
        output_dir,
        show_progress,
        progress_json,
        batch_received_bytes,
        &file.id,
    )
    .await
}

async fn download_share_file_as(
    client: &ShareClient,
    file: &FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    batch_received_bytes: Arc<AtomicU64>,
    transfer_id: &str,
) -> Result<()> {
    download_share_file_as_with_retry(client, file, output_dir, show_progress, progress_json,
        batch_received_bytes, transfer_id, Arc::default()).await
}

async fn download_share_file_as_with_retry(
    client: &ShareClient,
    file: &FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    batch_received_bytes: Arc<AtomicU64>,
    transfer_id: &str,
    retry_state: Arc<download_transport::RetryState>,
) -> Result<()> {
    let mut preparation = retry_state.preparation.attempt();
    let expected = output_dir.join(safe_component(&file.name)?);
    let _output_lease = match transfer_control::output_lock(&expected, transfer_id).await {
        Ok(lease) => lease,
        Err(error) if error.is::<transfer_control::Cancelled>() => {
            emit_transfer_cancelled(progress_json, false, transfer_id, &file.name, file.size);
            return Ok(());
        }
        Err(error) => {
            return Err(download_destination_error(
                error,
                progress_json,
                transfer_id,
                &file.name,
            ))
        }
    };
    let original_mode = client.content_mode();
    // Fresh Guest work has no reason to wait for the fallback account. Check
    // identity only for an existing User preference or actual User access.
    let mut initialization_error = None;
    let account = if original_mode == pikpak::ContentMode::User || retry_state.preparation.has_user_handoff() {
        match transfer_control::metadata_interruptible(transfer_id, client.download_account_id()).await {
            Ok(result) => result.ok().flatten(),
            Err(error) => { initialization_error = Some(error); None },
        }
    } else { None };
    let mut route_key = download_preparation::Key::for_file(
        format!("share:{}:account:{}", client.parsed_link().share_id, account.as_deref().unwrap_or("anonymous")),
        file, Some(original_mode));
    route_key = if account.is_some() { route_key } else { route_key.without_user_route() };
    let mut account_handoff = client.user_fallback().is_some()
        && retry_state.preparation.user_handoff(&route_key);
    let mut route = if account_handoff { client.user_fallback().expect("Deferred Dynamic share route") } else { client.clone() };
    let network_counter = transfer_control::network_counter(transfer_id);
    loop {
        let result = if let Some(error) = initialization_error.take() { Err(error) } else { Box::pin(download_share_file_inner(
            &route,
            file,
            output_dir,
            show_progress,
            progress_json,
            network_counter.clone(),
            batch_received_bytes.clone(),
            transfer_id,
            account_handoff,
            &route_key,
            _output_lease.as_ref(),
            retry_state.clone(),
        ))
        .await };
        match result {
            Ok(()) => return Ok(()),
            Err(error) if error.is::<transfer_control::Cancelled>() => {
                let partial = output_dir.join(format!("{}.part", safe_component(&file.name)?));
                transfer_control::remove_owned_partial_as(&partial, &file.id, transfer_id).await?;
                emit_transfer_cancelled(progress_json, false, transfer_id, &file.name, file.size);
                return Ok(());
            }
            Err(error) if error.is::<download_verification::Deferred>() => {
                preparation.defer();
                return Err(error);
            }
            Err(error) if error.is::<transfer_control::Paused>() => return Err(error),
            Err(error) if error.is::<transfer_control::Retry>() => return Err(error),
            Err(error) if pikpak::download_policy::destination_unavailable(&error) => {
                return Err(download_destination_error(
                    error,
                    progress_json,
                    transfer_id,
                    &file.name,
                ));
            }
            Err(error) if route.user_fallback().is_some() && download_route_unavailable(&error) => {
                route = route.user_fallback().expect("Dynamic share fallback");
                account_handoff = true;
                let account = match transfer_control::metadata_interruptible(transfer_id, route.download_account_id()).await {
                    Ok(result) => result.ok().flatten(),
                    Err(error) => { initialization_error = Some(error); continue; },
                };
                route_key = download_preparation::Key::for_file(
                    format!("share:{}:account:{}", client.parsed_link().share_id, account.as_deref().unwrap_or("anonymous")),
                    file, Some(original_mode));
                if account.is_none() { route_key = route_key.without_user_route(); }
                continue;
            }
            Err(error)
                if transfer_control::enabled() && pikpak::download_policy::retryable(&error) =>
            {
                preparation.retry_body(&error);
                return Err(error.context(transfer_control::Retry(
                    "Waiting to retry the download".into(),
                )));
            }
            Err(error) => {
                let error = explain_original_url_failure(error,
                    route.content_mode() == pikpak::ContentMode::User, account_handoff);
                if let Err(destination) = download_fs::validate(output_dir) {
                    if pikpak::download_policy::destination_io_interrupted(&destination) {
                        return Err(download_destination_error(
                            error.context(pikpak::download_policy::DestinationUnavailable),
                            progress_json,
                            transfer_id,
                            &file.name,
                        ));
                    }
                }
                emit_download_failure_progress(
                    progress_json,
                    &error,
                    transfer_id,
                    &file.name,
                    file.size,
                );
                return Err(error);
            }
        }
    }
}

async fn download_share_file_inner(
    client: &ShareClient,
    file: &FileInfo,
    output_dir: &StdPath,
    show_progress: bool,
    progress_json: bool,
    network_counter: Arc<AtomicU64>,
    batch_received_bytes: Arc<AtomicU64>,
    transfer_id: &str,
    account_handoff: bool,
    setup_key: &download_preparation::Key,
    output_lease: Option<&std::fs::File>,
    retry_state: Arc<download_transport::RetryState>,
) -> Result<()> {
    if skip_receipted_without_link(
        file,
        &output_dir.join(safe_component(&file.name)?),
        format!("share:{}", client.parsed_link().share_id),
        progress_json,
        transfer_id,
        output_lease,
    )
    .await?
    {
        return Ok(());
    }
    let mut detail = if let Some(info) = retry_state.preparation.download(&setup_key, account_handoff) {
        info
    } else {
        let info = transfer_control::metadata_interruptible(transfer_id, client.get_download_url_on_current_route(&file.id))
            .await?.map_err(|error| download_preparation::guest_lookup_failure(error, client.user_fallback().is_some()))
            .context("failed to get shared download URL")?;
        retry_state.preparation.remember_download(&setup_key, &info, account_handoff);
        info
    };
    let name = file.name.clone();
    let size = if detail.size == 0 {
        file.size
    } else {
        detail.size
    };
    let file_path = output_dir.join(safe_component(&name)?);
    let mut partial_name = file_path.clone().into_os_string();
    partial_name.push(".part");
    let part_path = PathBuf::from(partial_name);
    let expected_name = safe_component(&file.name)?;
    let _renamed_output_lease =
        if !transfer_control::same_output(&file_path, &output_dir.join(&expected_name))? {
            transfer_control::output_lock(&file_path, transfer_id).await?
        } else {
            None
        };

    let source = download_receipt::Source::from_download(
        format!("share:{}", client.parsed_link().share_id),
        &file.id,
        &detail,
        size,
    );
    if let Some(published_output) = download_receipt::ensure_available_path_async_replacing(
        &file_path,
        &source,
        transfer_id,
        verification_progress(progress_json, transfer_id, &name),
        _renamed_output_lease.as_ref().or(output_lease),
    )
    .await?
    {
        if let Some(lease) = _renamed_output_lease.as_ref().or(output_lease) {
            let _ = download_receipt::cleanup_completed_staging_async_with_lease(
                &file_path,
                &source,
                transfer_id,
                lease,
            )
            .await;
        }
        println!(
            "Skipped (verified complete): {}",
            published_output.display()
        );
        emit_download_progress(
            progress_json,
            DownloadProgressEvent::FileSkipped {
                file_id: transfer_id,
                name: &name,
                output_path: published_output.to_str(),
                downloaded_bytes: size,
                transferred_bytes: 0,
                total_bytes: size,
            },
        );
        return Ok(());
    }

    if let Some(lease) = _renamed_output_lease.as_ref().or(output_lease) {
        transfer_control::claim_partial_as_with_lease(&part_path, &file.id, transfer_id, lease)?;
    } else {
        transfer_control::claim_partial_as(&part_path, &file.id, transfer_id)?;
    }
    let existing_bytes = download_transport::saved_bytes(&part_path, &file.id, size).await;
    emit_download_progress(
        progress_json,
        DownloadProgressEvent::FileStarted {
            file_id: transfer_id,
            name: &name,
            downloaded_bytes: if size > 0 {
                existing_bytes.min(size)
            } else {
                existing_bytes
            },
            transferred_bytes: network_counter.load(Ordering::Relaxed),
            total_bytes: size,
        },
    );
    println!(
        "Downloading shared file: {} ({})",
        name,
        format_size(size, BINARY)
    );

    let mut link = detail.web_content_link.clone();
    let mut guest_url_refreshed = false;
    let mut attempt = 0u32;
    let mut progress = DownloadProgressContext::new(progress_json, transfer_id, &name);
    progress.retry_state = retry_state.clone();
    progress.source_file_id = &file.id;
    progress.source_revision = detail.source_revision.clone();
    progress.require_content_hash = account_handoff || client.user_fallback().is_some();
    progress.guest_range_fallback = client.user_fallback().is_some();
    progress.transferred_bytes = network_counter;
    progress.batch_received_bytes = Some(batch_received_bytes);
    let verified = loop {
        attempt += 1;
        match download_attempt_with_http(
            client.download_http_client(),
            &link,
            size,
            &part_path,
            show_progress,
            progress.clone(),
            Some("https://mypikpak.com/"),
        )
        .await
        {
            Ok(verified) => break verified,
            Err(error) => {
                let retryable = matches!(error, DlError::Retryable(_));
                let inner = error.into_inner();
                if inner.is::<transfer_control::Paused>() || inner.is::<download_verification::Deferred>() {
                    return Err(inner);
                }
                if inner.is::<transfer_control::Cancelled>() {
                    transfer_control::remove_owned_partial_as(&part_path, &file.id, transfer_id)
                        .await?;
                    return Err(inner);
                }
                if client.user_fallback().is_some() && download_route_unavailable(&inner) {
                    if !guest_url_refreshed
                        && (signed_download_url_rejected(&inner) || download_range_rejected(&inner))
                    {
                        guest_url_refreshed = true;
                        match transfer_control::interruptible(
                            transfer_id,
                            client.get_download_url_on_current_route(&file.id),
                        )
                        .await?
                        {
                            Ok(fresh) => {
                                let fresh_size = if fresh.size == 0 {
                                    file.size
                                } else {
                                    fresh.size
                                };
                                anyhow::ensure!(fresh_size == size && (fresh.source_revision == detail.source_revision
                                    || pikpak::content_mode::matching_content_revision(fresh.source_revision.as_deref(), detail.source_revision.as_deref())),
                                    "The shared download source changed while refreshing its Guest URL; resume to retrieve the current original");
                                detail.web_content_link = fresh.web_content_link;
                                retry_state.preparation.remember_download(&setup_key, &detail, account_handoff);
                                link = detail.web_content_link.clone();
                                continue;
                            }
                            Err(error) => {
                                let error = anyhow::Error::new(error);
                                if pikpak::download_policy::retryable(&error) {
                                    return Err(error).context(
                                        "Failed to refresh the Guest shared download URL",
                                    );
                                }
                            }
                        }
                    }
                    return Err(inner);
                }
                if inner.is::<pikpak::download_policy::PartialContent>() {
                    attempt = attempt.saturating_sub(1);
                    continue;
                }
                if retryable && attempt < MAX_DOWNLOAD_ATTEMPTS && !transfer_control::enabled() {
                    let delay = download_backoff(attempt - 1)
                        .max(pikpak::download_policy::delay(&inner).unwrap_or_default());
                    eprintln!(
                        "  {}: attempt {attempt} failed ({inner:#}); retrying in {:.1}s",
                        name,
                        delay.as_secs_f64()
                    );
                    emit_download_progress(
                        progress_json,
                        DownloadProgressEvent::FileRetrying {
                            file_id: transfer_id,
                            name: &name,
                            attempt,
                            retry_in_millis: delay.as_millis() as u64,
                            destination_unavailable: None,
                            error: None,
                        },
                    );
                    if let Err(cancelled) =
                        transfer_control::run(transfer_id, tokio::time::sleep(delay)).await
                    {
                        transfer_control::remove_owned_partial_as(
                            &part_path,
                            &file.id,
                            transfer_id,
                        )
                        .await?;
                        return Err(cancelled.into());
                    }
                    if let Ok(fresh) = client.get_download_url(&file.id).await {
                        let fresh_size = if fresh.size == 0 {
                            file.size
                        } else {
                            fresh.size
                        };
                        anyhow::ensure!(fresh_size == size && fresh.source_revision == detail.source_revision,
                            "The shared download source changed while refreshing its URL; resume to retrieve the current original");
                        detail.web_content_link = fresh.web_content_link;
                        retry_state.preparation.remember_download(&setup_key, &detail, account_handoff);
                        link = detail.web_content_link.clone();
                    }
                    continue;
                }
                return Err(download_preparation::body_failure(inner)).with_context(|| format!("failed to download {name}"));
            }
        }
    };

    let completed_size = if size > 0 {
        size
    } else {
        download_fs::metadata_async(&part_path)
            .await
            .map(|metadata| metadata.len())
            .unwrap_or(0)
    };
    if let Err(cancelled) =
        transfer_control::disk_interruptible(transfer_id, std::future::ready(())).await
    {
        if cancelled.is::<transfer_control::Cancelled>() {
            transfer_control::remove_owned_partial_as(&part_path, &file.id, transfer_id).await?;
        }
        return Err(cancelled);
    }
    let published_output = match download_receipt::finish_resolved_verified(
        &part_path,
        &file_path,
        source,
        transfer_id,
        verified,
    )
    .await
    {
        Ok(output) => output,
        Err(error) => {
            if error.is::<transfer_control::Cancelled>() {
                transfer_control::remove_owned_partial_as(&part_path, &file.id, transfer_id)
                    .await?;
            }
            return Err(error);
        }
    };
    download_transport::remove_state(&part_path)?;
    println!("Saved: {}", published_output.display());
    emit_download_progress(
        progress_json,
        DownloadProgressEvent::FileCompleted {
            file_id: transfer_id,
            name: &name,
            output_path: published_output.to_str(),
            downloaded_bytes: completed_size,
            transferred_bytes: progress.transferred_bytes(),
            total_bytes: completed_size,
        },
    );
    Ok(())
}

fn collect_share_folder<'a>(
    client: &'a ShareClient,
    folder: &'a FileInfo,
    remote_path: &'a str,
    output_dir: &'a StdPath,
    tasks: &'a mut Vec<DownloadTask>,
) -> Pin<Box<dyn Future<Output = Result<()>> + 'a>> {
    Box::pin(async move {
        let control_key = format!("path:{remote_path}");
        if transfer_control::run(&control_key, std::future::ready(()))
            .await
            .is_err()
        {
            return Ok(());
        }

        let dir_path = output_dir.join(safe_component(&folder.name)?);
        download_fs::create_dir_all(&dir_path).context("failed to create shared folder")?;
        println!("Scanning shared folder: {}", folder.name);
        for child in client.list_folder(&folder.id).await? {
            let child_remote_path = appending_remote_path_component(remote_path, &child.name);
            if child.kind.is_folder() {
                collect_share_folder(client, &child, &child_remote_path, &dir_path, tasks).await?;
            } else {
                tasks.push(DownloadTask {
                    file: child,
                    output_directory: dir_path.clone(),
                    remote_path: child_remote_path,
                    retry_state: Arc::default(),
                });
            }
        }
        Ok(())
    })
}

/// Recursively walk a remote folder, creating local directories and collecting
/// each file with its destination directory into `tasks`.
fn collect_folder<'a>(
    client: &'a Client,
    folder: &'a pikpak::FileInfo,
    remote_path: &'a str,
    output_dir: &'a StdPath,
    tasks: &'a mut Vec<DownloadTask>,
) -> Pin<Box<dyn Future<Output = Result<()>> + 'a>> {
    Box::pin(async move {
        let control_key = format!("path:{remote_path}");
        if transfer_control::run(&control_key, std::future::ready(()))
            .await
            .is_err()
        {
            return Ok(());
        }

        let dir_path = output_dir.join(safe_component(&folder.name)?);
        download_fs::create_dir_all(&dir_path).context("failed to create folder")?;

        println!("Scanning folder: {}", folder.name);

        let files: Vec<pikpak::FileInfo> = client.list_folder(&folder.id).await?;
        for f in files {
            let child_remote_path = appending_remote_path_component(remote_path, &f.name);
            if f.kind.is_folder() {
                collect_folder(client, &f, &child_remote_path, &dir_path, tasks).await?;
            } else {
                tasks.push(DownloadTask {
                    file: f,
                    output_directory: dir_path.clone(),
                    remote_path: child_remote_path,
                    retry_state: Arc::default(),
                });
            }
        }
        Ok(())
    })
}

async fn cmd_account(client: &Client, validate_personal_scope: bool) -> Result<()> {
    let profile = client
        .account_profile()
        .await
        .context("account check failed")?;
    if validate_personal_scope && client.tokens().is_personal_access_token() {
        client
            .list_folder_page("", None, 1)
            .await
            .context("Personal Access Token needs Read files permission")?;
    }
    println!("{}", serde_json::to_string(&profile)?);
    Ok(())
}

async fn cmd_quota(client: &Client, args: QuotaArgs) -> Result<()> {
    let details = if args.with_transfer {
        Some(
            client
                .quota_details()
                .await
                .context("quota details failed")?,
        )
    } else {
        None
    };
    let q = match details {
        Some(details) => details.storage,
        None => client.quota().await.context("quota failed")?,
    };

    if args.json {
        let mut output = serde_json::to_value(q)?;
        if let Some(details) = details {
            output["transfer"] = serde_json::to_value(details.transfer)?;
            output["account_id"] = client.tokens().user_id().await?.into();
        }
        if args.with_profile {
            let profile = client.account_profile().await.ok();
            output["account_profile"] = serde_json::to_value(profile)?;
        }
        println!("{output}");
        return Ok(());
    }

    let fmt = |n: u64| {
        if args.raw {
            n.to_string()
        } else {
            format_size(n, BINARY)
        }
    };

    println!("total: {}", fmt(q.total));
    println!("used:  {}", fmt(q.used));
    println!("free:  {}", fmt(q.free()));
    if let Some(r) = q.ratio() {
        println!("usage: {:.1}%", r * 100.0);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn remote_path_normalization_preserves_filename_whitespace() {
        assert_eq!(
            super::normalize_remote_path("/folder/file.txt "),
            "/folder/file.txt "
        );
        assert_eq!(
            super::normalize_remote_path(" leading/final "),
            "/ leading/final "
        );
    }
    #[test]
    fn rejected_session_diagnostic_survives_context_without_matching_other_errors() {
        assert!(super::duplicate_error_requires_abort(
            &pikpak::Error::SessionRejected("fixture rejection")
        ));
        let error = anyhow::Error::new(pikpak::Error::SessionRejected("fixture rejection"))
            .context("browse folder failed");
        assert_eq!(
            super::rejected_session_reason(&error),
            Some("fixture rejection")
        );
        let error = anyhow::Error::new(pikpak::Error::Auth("status 400: invalid_client".into()))
            .context("account check failed");
        assert_eq!(super::rejected_session_reason(&error), None);
        assert_eq!(
            super::rejected_session_reason(&anyhow::anyhow!(
                "a filename mentioning invalid_grant or 401"
            )),
            None
        );
    }

    #[test]
    fn app_transfer_retry_delay_has_no_attempt_ceiling_and_is_capped() {
        assert_eq!(super::transfer_retry_delay(1).as_secs(), 1);
        assert_eq!(super::transfer_retry_delay(4).as_secs(), 8);
        assert_eq!(super::transfer_retry_delay(1_000_000).as_secs(), 60);
        assert_eq!(super::transfer_retry_delay(u32::MAX).as_secs(), 60);
    }
    use clap::Parser as _;
    use std::collections::HashMap;

    use super::{
        archive_entry_summary, bounded_download_workers, bounded_upload_file_workers,
        build_duplicate_scan, build_folder_measurement_report, common_download_parent_depth,
        discover_local_uploads, empty_folder_candidate_ids, is_ds_store_file,
        remote_path_is_descendant, safe_component, upload_file_failure_is_retryable, Cli, Command,
        DownloadProgressEvent, DownloadQueueItem, DuplicateCandidate, DuplicateMatchKind,
        DuplicateProgressEvent, EmptyFolderNode, FileKind, FolderMeasurement, MergeProgressEvent,
        UploadProgressEvent,
    };

    #[test]
    fn removed_catalog_commands_are_not_exposed() {
        for command in [
            "open-source-catalog",
            "open-source-inspect",
            "open-source-save",
            "open-source-status",
        ] {
            let error = Cli::try_parse_from(["pikpak", command]).unwrap_err();
            assert_eq!(error.kind(), clap::error::ErrorKind::InvalidSubcommand);
        }
    }

    fn duplicate_candidate(
        id: &str,
        name: &str,
        path: &str,
        size: u64,
        content_hash: Option<&str>,
        md5_checksum: Option<&str>,
    ) -> DuplicateCandidate {
        DuplicateCandidate {
            id: id.to_string(),
            name: name.to_string(),
            path: path.to_string(),
            size,
            modified_time: None,
            content_hash: content_hash.map(str::to_string),
            md5_checksum: md5_checksum.map(str::to_string),
            source: crate::duplicate_cross_drive::DuplicateSource::Pikpak,
            folder_created_time: None,
            local_identity: None,
        }
    }

    #[test]
    fn duplicate_scan_matches_content_hash_across_different_names() {
        let scan = build_duplicate_scan(
            "/Movies".to_string(),
            3,
            vec![
                duplicate_candidate(
                    "a",
                    "original.mp4",
                    "/Movies/original.mp4",
                    1_000,
                    Some("ABCDEF"),
                    None,
                ),
                duplicate_candidate(
                    "b",
                    "copy.mp4",
                    "/Movies/Archive/copy.mp4",
                    1_000,
                    Some("abcdef"),
                    None,
                ),
            ],
        );

        assert_eq!(scan.scanned_files, 2);
        assert_eq!(scan.scanned_folders, 3);
        assert_eq!(scan.exact_groups, 1);
        assert_eq!(scan.possible_groups, 0);
        assert_eq!(scan.duplicate_files, 2);
        assert_eq!(scan.reclaimable_bytes, 1_000);
        assert_eq!(scan.groups[0].match_kind, DuplicateMatchKind::ExactContent);
        assert_eq!(scan.groups[0].copies, 2);
    }

    #[test]
    fn duplicate_scan_does_not_override_conflicting_hashes_with_name_match() {
        let scan = build_duplicate_scan(
            "/".to_string(),
            1,
            vec![
                duplicate_candidate("a", "same.bin", "/same.bin", 500, Some("hash-a"), None),
                duplicate_candidate(
                    "b",
                    "same.bin",
                    "/Elsewhere/same.bin",
                    500,
                    Some("hash-b"),
                    None,
                ),
            ],
        );

        assert!(scan.groups.is_empty());
        assert_eq!(scan.duplicate_files, 0);
    }

    #[test]
    fn duplicate_scan_marks_name_and_size_fallback_as_possible() {
        let scan = build_duplicate_scan(
            "/".to_string(),
            2,
            vec![
                duplicate_candidate("a", "Report.PDF", "/Report.PDF", 80, None, None),
                duplicate_candidate("b", "report.pdf", "/Old/report.pdf", 80, None, None),
            ],
        );

        assert_eq!(scan.exact_groups, 0);
        assert_eq!(scan.possible_groups, 1);
        assert_eq!(scan.reclaimable_bytes, 0);
        assert_eq!(
            scan.groups[0].match_kind,
            DuplicateMatchKind::MatchingNameAndSize
        );
        assert_eq!(scan.groups[0].reclaimable_bytes, 80);
    }

    #[test]
    fn download_progress_event_uses_stable_snake_case_json() {
        let value = serde_json::to_value(DownloadProgressEvent::FileProgress {
            file_id: "file-1",
            name: "video.mp4",
            downloaded_bytes: 25,
            transferred_bytes: 20,
            total_bytes: 100,
        })
        .unwrap();
        assert_eq!(value["event"], "file_progress");
        assert_eq!(value["file_id"], "file-1");
        assert_eq!(value["downloaded_bytes"], 25);
        assert_eq!(value["transferred_bytes"], 20);
        assert_eq!(value["total_bytes"], 100);
    }

    #[test]
    fn download_terminal_events_report_the_committed_output_path() {
        let output = "/generated destination/video (recovered \"copy\").mp4";
        for event in [
            DownloadProgressEvent::FileCompleted {
                file_id: "generated-transfer",
                name: "video.mp4",
                output_path: Some(output),
                downloaded_bytes: 8,
                transferred_bytes: 0,
                total_bytes: 8,
            },
            DownloadProgressEvent::FileSkipped {
                file_id: "generated-transfer",
                name: "video.mp4",
                output_path: Some(output),
                downloaded_bytes: 8,
                transferred_bytes: 0,
                total_bytes: 8,
            },
        ] {
            let value = serde_json::to_value(event).unwrap();
            assert_eq!(value["output_path"], output);
            assert_eq!(value["name"], "video.mp4");
            assert_eq!(value["file_id"], "generated-transfer");
            assert_eq!(value["downloaded_bytes"], 8);
            assert_eq!(value["transferred_bytes"], 0);
            assert_eq!(value["total_bytes"], 8);
            assert!(value.get("outputPath").is_none());
        }
        let legacy = serde_json::to_value(DownloadProgressEvent::FileCompleted {
            file_id: "generated-transfer",
            name: "video.mp4",
            output_path: None,
            downloaded_bytes: 8,
            transferred_bytes: 0,
            total_bytes: 8,
        })
        .unwrap();
        assert!(legacy.get("output_path").is_none());
    }

    #[tokio::test]
    async fn completed_staging_finalizes_and_reports_verified_path_without_cdn() {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("generated complete.bin");
        let partial = directory.path().join("generated complete.bin.part");
        let source_id = "generated-terminal-source";
        let transfer_id = "generated-terminal-transfer";
        std::fs::write(&partial, b"abcdefgh").unwrap();
        crate::download_transport::seed_resume(&partial, source_id, 8, "\"generated\"");
        let checkpoint = partial.with_file_name("generated complete.bin.part.resume.json");
        let mut state: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&checkpoint).unwrap()).unwrap();
        state["source_revision"] = "gcid:GENERATEDTERMINAL".into();
        state["require_content_hash"] = true.into();
        std::fs::write(&checkpoint, serde_json::to_vec(&state).unwrap()).unwrap();
        let mut progress =
            crate::DownloadProgressContext::new(false, transfer_id, "generated complete.bin");
        progress.source_file_id = source_id;
        progress.source_revision = Some("gcid:GENERATEDTERMINAL".into());
        progress.require_content_hash = true;
        let network = progress.transferred_bytes.clone();
        let recovered = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            crate::download_transport::attempt(
                &reqwest::Client::new(),
                "http://127.0.0.1:1/generated-unreachable-cdn",
                8,
                &partial,
                false,
                progress,
                None,
            ),
        )
        .await
        .unwrap();
        assert!(
            recovered.is_ok(),
            "Verified complete staging contacted the unreachable CDN"
        );
        assert_eq!(network.load(std::sync::atomic::Ordering::Relaxed), 0);
        let download = pikpak::DownloadInfo {
            web_content_link: "unused-generated".into(),
            name: "generated complete.bin".into(),
            size: 8,
            source_revision: Some("gcid:GENERATEDTERMINAL".into()),
        };
        let source = crate::download_receipt::Source::from_download(
            "account:generated-terminal".into(),
            source_id,
            &download,
            8,
        );
        let published = crate::download_receipt::finish_resolved(
            &partial,
            &output,
            source.clone(),
            transfer_id,
        )
        .await
        .unwrap();
        assert_eq!(published, output);
        assert_eq!(std::fs::read(&published).unwrap(), b"abcdefgh");
        assert!(!partial.exists());
        let on_retry = crate::download_receipt::ensure_available_path_async_with_control(
            &output,
            &source,
            transfer_id,
        )
        .await
        .unwrap();
        assert_eq!(on_retry.as_ref(), Some(&published));
        let completed = serde_json::to_value(DownloadProgressEvent::FileCompleted {
            file_id: transfer_id,
            name: "generated complete.bin",
            output_path: published.to_str(),
            downloaded_bytes: 8,
            transferred_bytes: 0,
            total_bytes: 8,
        })
        .unwrap();
        let skipped = serde_json::to_value(DownloadProgressEvent::FileSkipped {
            file_id: transfer_id,
            name: "generated complete.bin",
            output_path: on_retry.as_ref().and_then(|path| path.to_str()),
            downloaded_bytes: 8,
            transferred_bytes: 0,
            total_bytes: 8,
        })
        .unwrap();
        assert_eq!(completed["output_path"], skipped["output_path"]);
        assert_eq!(skipped["transferred_bytes"], 0);
    }

    #[test]
    fn receipt_failure_reports_only_verified_retained_bytes_before_failure() {
        use crate::{download_failure_progress_events, download_receipt, transfer_control};
        let message = "Download copy destination changed; it was preserved";
        let error = anyhow::anyhow!(message).context(download_receipt::VerifiedStagingProgress {
            downloaded_bytes: 8,
            total_bytes: 8,
            failure: message.into(),
        });
        let events: Vec<_> = download_failure_progress_events(
            &error,
            "generated-transfer",
            "generated.bin",
            4,
            message,
        )
        .into_iter()
        .map(|event| serde_json::to_value(event).unwrap())
        .collect();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["event"], "file_started");
        assert_eq!(events[1]["event"], "file_failed");
        for event in &events {
            assert_eq!(event["downloaded_bytes"], 8);
            assert_eq!(event["total_bytes"], 8);
            assert_eq!(event["transferred_bytes"], 0);
        }
        assert_eq!(events[1]["error"], message);
        for unverified in [
            anyhow::anyhow!(message),
            anyhow::anyhow!("Download copy staging file changed; it was preserved"),
        ] {
            let events: Vec<_> = download_failure_progress_events(
                &unverified,
                "generated-transfer",
                "generated.bin",
                8,
                message,
            )
            .into_iter()
            .map(|event| serde_json::to_value(event).unwrap())
            .collect();
            assert_eq!(events.len(), 1);
            assert_eq!(events[0]["event"], "file_failed");
            assert_eq!(events[0]["downloaded_bytes"], 0);
            assert_eq!(events[0]["transferred_bytes"], 0);
        }
        let paused = anyhow::Error::new(transfer_control::Paused).context(
            download_receipt::VerifiedStagingProgress {
                downloaded_bytes: 8,
                total_bytes: 8,
                failure: "Download paused".into(),
            },
        );
        assert!(paused.is::<transfer_control::Paused>());
    }

    #[test]
    fn failure_event_names_a_permanent_cause_only_when_one_is_proven() {
        use crate::download_failure_progress_events;
        use pikpak::download_policy::{self, HttpFailure};
        let event = |error: anyhow::Error| {
            let message = format!("{error:#}");
            let mut events: Vec<_> = download_failure_progress_events(&error, "id", "A.bin", 4, &message)
                .into_iter()
                .map(|event| serde_json::to_value(event).unwrap())
                .collect();
            assert_eq!(events.len(), 1);
            events.remove(0)
        };
        let gone = event(
            anyhow::Error::new(pikpak::Error::NotFound { path: "/A.bin".into(), segment: "A.bin".into() })
                .context("failed to download A.bin"),
        );
        assert_eq!(gone["event"], "file_failed");
        assert_eq!(gone["permanent"], download_policy::FILE_MISSING);
        assert_eq!(
            event(anyhow::Error::new(HttpFailure { status: 410, retry_after: None }))["permanent"],
            download_policy::CONTENT_GONE
        );
        assert_eq!(event(download_policy::SourceReplaced.into())["permanent"], download_policy::PATH_REPLACED);
        assert_eq!(event(download_policy::OriginalSizeMismatch { expected: 8, received: 9 }.into())["permanent"],
            download_policy::ORIGINAL_SIZE_MISMATCH);
        // Anything that may clear leaves the field out entirely, so older apps and newer ones agree.
        for transient in [
            anyhow::Error::new(HttpFailure { status: 503, retry_after: None }),
            anyhow::Error::new(std::io::Error::from(std::io::ErrorKind::StorageFull)),
            anyhow::anyhow!("The download source changed while refreshing its URL; resume"),
        ] {
            let event = event(transient);
            assert_eq!(event["event"], "file_failed");
            assert!(event.get("permanent").is_none(), "{event}");
        }
    }

    #[test]
    fn disk_interruption_progress_is_distinct_from_network_retry() {
        let ordinary = serde_json::to_value(DownloadProgressEvent::FileRetrying {
            file_id: "file-1",
            name: "generated.bin",
            attempt: 2,
            retry_in_millis: 2000,
            destination_unavailable: None,
            error: None,
        })
        .unwrap();
        assert!(ordinary.get("destination_unavailable").is_none());
        assert!(ordinary.get("error").is_none());
        let disk = serde_json::to_value(DownloadProgressEvent::FileRetrying {
            file_id: "file-1",
            name: "generated.bin",
            attempt: 0,
            retry_in_millis: 1000,
            destination_unavailable: Some(true),
            error: Some("Reconnect the original disk"),
        })
        .unwrap();
        assert_eq!(disk["event"], "file_retrying");
        assert_eq!(disk["destination_unavailable"], true);
        assert_eq!(disk["error"], "Reconnect the original disk");
    }

    #[test]
    fn merge_progress_event_uses_stable_snake_case_json() {
        let value = serde_json::to_value(MergeProgressEvent::Verifying {
            source_id: "source-1",
            source_index: 1,
            source_count: 2,
            completed_sources: 0,
            moved_items: 100,
            total_items: 117,
            remaining_items: 17,
            attempt: 2,
            max_attempts: 8,
            retry_in_millis: 500,
        })
        .unwrap();
        assert_eq!(value["event"], "verifying");
        assert_eq!(value["source_id"], "source-1");
        assert_eq!(value["remaining_items"], 17);
        assert_eq!(value["retry_in_millis"], 500);
    }

    #[test]
    fn merge_verification_backoff_is_short_and_bounded() {
        assert_eq!(
            super::merge_verification_backoff(1),
            std::time::Duration::from_millis(250)
        );
        assert!(super::merge_verification_backoff(4) > super::merge_verification_backoff(1));
        assert!(super::merge_verification_backoff(30) <= std::time::Duration::from_secs(3));
    }

    #[test]
    fn merge_resume_accepts_only_explicitly_missing_sources() {
        let missing = pikpak::Error::Api {
            status: 404,
            message: "not found".to_string(),
        };
        assert!(super::merge_source_is_missing(&missing));

        let service_failure = pikpak::Error::Api {
            status: 503,
            message: "temporarily unavailable".to_string(),
        };
        assert!(!super::merge_source_is_missing(&service_failure));
    }

    #[test]
    fn download_queue_events_include_file_metadata() {
        let value = serde_json::to_value(DownloadProgressEvent::QueueBatch {
            files: vec![DownloadQueueItem {
                file_id: "file-1",
                name: "video.mp4",
                total_bytes: 100,
                remote_path: "/My Pack/folder/video.mp4",
                output_directory: "/tmp/downloads/folder".to_string(),
            }],
        })
        .unwrap();
        assert_eq!(value["event"], "queue_batch");
        assert_eq!(value["files"][0]["file_id"], "file-1");
        assert_eq!(value["files"][0]["name"], "video.mp4");
        assert_eq!(value["files"][0]["total_bytes"], 100);
        assert_eq!(
            value["files"][0]["remote_path"],
            "/My Pack/folder/video.mp4"
        );
        assert_eq!(
            value["files"][0]["output_directory"],
            "/tmp/downloads/folder"
        );

        let value = serde_json::to_value(DownloadProgressEvent::FileDequeued {
            file_id: "file-1",
            name: "video.mp4",
            total_bytes: 100,
        })
        .unwrap();
        assert_eq!(value["event"], "file_dequeued");
        assert_eq!(value["file_id"], "file-1");
        assert_eq!(value["total_bytes"], 100);
    }

    #[test]
    fn duplicate_progress_event_uses_stable_snake_case_json() {
        let value = serde_json::to_value(DuplicateProgressEvent::ScanProgress {
            scanned_files: 120,
            scanned_folders: 4,
            discovered_folders: 10,
            pending_folders: 6,
            failed_folders: 1,
            current_path: "/My Pack/Videos",
        })
        .unwrap();
        assert_eq!(value["event"], "scan_progress");
        assert_eq!(value["scanned_files"], 120);
        assert_eq!(value["scanned_folders"], 4);
        assert_eq!(value["discovered_folders"], 10);
        assert_eq!(value["pending_folders"], 6);
        assert_eq!(value["failed_folders"], 1);
        assert_eq!(value["current_path"], "/My Pack/Videos");
    }

    #[test]
    fn duplicate_retry_progress_reports_delay_and_attempts() {
        let value = serde_json::to_value(DuplicateProgressEvent::FolderRetrying {
            scanned_files: 120,
            scanned_folders: 4,
            discovered_folders: 10,
            pending_folders: 6,
            failed_folders: 0,
            current_path: "/My Pack/Videos",
            attempt: 2,
            max_attempts: 2,
            retry_in_millis: 3_000,
        })
        .unwrap();
        assert_eq!(value["event"], "folder_retrying");
        assert_eq!(value["attempt"], 2);
        assert_eq!(value["max_attempts"], 2);
        assert_eq!(value["retry_in_millis"], 3_000);
    }

    #[test]
    fn duplicate_folder_backoff_is_bounded() {
        assert_eq!(
            super::duplicate_folder_backoff(1),
            std::time::Duration::from_secs(3)
        );
        assert!(super::duplicate_folder_backoff(2) > super::duplicate_folder_backoff(1));
        assert!(super::duplicate_folder_backoff(30) <= std::time::Duration::from_secs(12));
    }

    #[test]
    fn duplicate_folder_failure_policy_preserves_partial_scans() {
        let unavailable = pikpak::Error::Api {
            status: 503,
            message: "temporarily unavailable".to_string(),
        };
        assert_eq!(
            super::duplicate_folder_failure_action(&unavailable, 1, false),
            super::DuplicateFolderFailureAction::Retry(std::time::Duration::from_secs(3))
        );
        assert_eq!(
            super::duplicate_folder_failure_action(&unavailable, 2, false),
            super::DuplicateFolderFailureAction::Skip
        );

        let missing = pikpak::Error::Api {
            status: 404,
            message: "not found".to_string(),
        };
        assert_eq!(
            super::duplicate_folder_failure_action(&missing, 1, false),
            super::DuplicateFolderFailureAction::Skip
        );
        assert_eq!(
            super::duplicate_folder_failure_action(&missing, 1, true),
            super::DuplicateFolderFailureAction::Abort
        );

        let rejected = pikpak::Error::Api {
            status: 401,
            message: "unauthorized".to_string(),
        };
        assert_eq!(
            super::duplicate_folder_failure_action(&rejected, 1, false),
            super::DuplicateFolderFailureAction::Abort
        );
    }

    #[test]
    fn trash_cli_accepts_an_ids_file_without_inline_ids() {
        let cli = Cli::try_parse_from([
            "pikpak",
            "trash",
            "--ids-file",
            "/private/tmp/duplicate-ids.json",
            "--yes",
        ])
        .unwrap();
        let Command::Trash(args) = cli.command else {
            panic!("trash command should parse");
        };
        assert!(args.ids.is_empty());
        assert_eq!(
            args.ids_file.as_deref(),
            Some(std::path::Path::new("/private/tmp/duplicate-ids.json"))
        );
        assert!(args.yes);
    }

    #[test]
    fn move_cli_accepts_private_batch_and_root_destination() {
        let cli = Cli::try_parse_from([
            "pikpak",
            "move",
            "--ids-file",
            "/private/tmp/move-ids.json",
            "--to-parent-id",
            "",
        ])
        .unwrap();
        let Command::Move(args) = cli.command else {
            panic!("move command should parse");
        };
        assert!(args.ids.is_empty());
        assert_eq!(
            args.ids_file.as_deref(),
            Some(std::path::Path::new("/private/tmp/move-ids.json"))
        );
        assert!(args.to_parent_id.is_empty());
    }

    #[test]
    fn rename_cli_accepts_an_item_id_and_name() {
        let cli = Cli::try_parse_from([
            "pikpak",
            "rename",
            "--id",
            "item-1",
            "--name",
            "Renamed item.mp4",
        ])
        .unwrap();
        let Command::Rename(args) = cli.command else {
            panic!("rename command should parse");
        };
        assert_eq!(args.id, "item-1");
        assert_eq!(args.name, "Renamed item.mp4");
    }

    #[test]
    fn merge_folders_cli_accepts_private_source_batch() {
        let cli = Cli::try_parse_from([
            "pikpak",
            "merge-folders",
            "--destination-id",
            "folder-a",
            "--source-ids-file",
            "/private/tmp/merge-source-ids.json",
            "--yes",
            "--progress-json",
        ])
        .unwrap();
        let Command::MergeFolders(args) = cli.command else {
            panic!("merge-folders command should parse");
        };
        assert_eq!(args.destination_id, "folder-a");
        assert!(args.source_ids.is_empty());
        assert_eq!(
            args.source_ids_file.as_deref(),
            Some(std::path::Path::new("/private/tmp/merge-source-ids.json"))
        );
        assert!(args.yes);
        assert!(args.progress_json);
    }

    #[test]
    fn create_folder_and_ds_store_commands_parse_explicit_scopes() {
        let create = Cli::try_parse_from([
            "pikpak",
            "create-folder",
            "--parent-id",
            "parent-1",
            "--name",
            "New Folder",
        ])
        .unwrap();
        let Command::CreateFolder(create_args) = create.command else {
            panic!("create-folder command should parse");
        };
        assert_eq!(create_args.parent_id, "parent-1");
        assert_eq!(create_args.name, "New Folder");

        let cleanup = Cli::try_parse_from([
            "pikpak",
            "ds-store",
            "--parent-id",
            "folder-1",
            "--root-path",
            "/Archive",
            "--yes",
        ])
        .unwrap();
        let Command::DsStore(cleanup_args) = cleanup.command else {
            panic!("ds-store command should parse");
        };
        assert_eq!(cleanup_args.parent_id, "folder-1");
        assert_eq!(cleanup_args.root_path, "/Archive");
        assert!(cleanup_args.yes);
    }

    #[test]
    fn archive_commands_accept_only_private_request_files() {
        let inspect = Cli::try_parse_from([
            "pikpak",
            "archive-inspect",
            "--request-file",
            "/private/tmp/archive-inspect.json",
        ])
        .unwrap();
        let Command::ArchiveInspect(inspect_args) = inspect.command else {
            panic!("archive-inspect command should parse");
        };
        assert_eq!(
            inspect_args.request_file,
            std::path::PathBuf::from("/private/tmp/archive-inspect.json")
        );

        let extract = Cli::try_parse_from([
            "pikpak",
            "archive-extract",
            "--request-file",
            "/private/tmp/archive-extract.json",
            "--progress-json",
        ])
        .unwrap();
        let Command::ArchiveExtract(extract_args) = extract.command else {
            panic!("archive-extract command should parse");
        };
        assert!(extract_args.progress_json);
    }

    #[test]
    fn archive_entry_summary_accepts_first_party_and_drive_field_names() {
        let official = archive_entry_summary(
            &serde_json::json!({
                "filename": "Photos",
                "filesize": "4096",
                "kind": "drive#folder",
                "path": "/Photos/",
            }),
            0,
        );
        assert_eq!(official.name, "Photos");
        assert_eq!(official.size, 4096);
        assert_eq!(official.kind, "drive#folder");

        let drive_variant = archive_entry_summary(
            &serde_json::json!({
                "name": "clip.mp4",
                "size": 8192,
                "kind": "drive#file",
                "path": "/clip.mp4",
            }),
            1,
        );
        assert_eq!(drive_variant.name, "clip.mp4");
        assert_eq!(drive_variant.size, 8192);
    }

    #[test]
    fn ds_store_cleanup_matches_only_exact_regular_files() {
        assert!(is_ds_store_file(FileKind::File, ".DS_Store"));
        assert!(!is_ds_store_file(FileKind::Folder, ".DS_Store"));
        assert!(!is_ds_store_file(FileKind::File, ".ds_store"));
        assert!(!is_ds_store_file(FileKind::File, ".DS_Store.backup"));
        assert!(!is_ds_store_file(FileKind::File, "DS_Store"));
    }

    #[test]
    fn download_cli_accepts_repeated_paths() {
        let cli = Cli::try_parse_from([
            "pikpak",
            "download",
            "--path",
            "/My Pack/one.mp4",
            "--path",
            "/My Pack/two.mp4",
        ])
        .unwrap();
        let Command::Download(args) = cli.command else {
            panic!("download command should parse");
        };
        assert_eq!(args.paths, vec!["/My Pack/one.mp4", "/My Pack/two.mp4"]);
    }

    #[test]
    fn share_commands_accept_only_private_request_files() {
        let browse = Cli::try_parse_from([
            "pikpak",
            "share-browse",
            "--request-file",
            "/private/tmp/share.json",
        ])
        .unwrap();
        let Command::ShareBrowse(args) = browse.command else {
            panic!("share-browse command should parse");
        };
        assert_eq!(
            args.request_file,
            std::path::PathBuf::from("/private/tmp/share.json")
        );

        let download = Cli::try_parse_from([
            "pikpak",
            "share-download",
            "--request-file",
            "/private/tmp/share-download.json",
            "--jobs",
            "5",
            "--progress-json",
        ])
        .unwrap();
        let Command::ShareDownload(args) = download.command else {
            panic!("share-download command should parse");
        };
        assert_eq!(args.jobs, 5);
        assert!(args.progress_json);

        let save = Cli::try_parse_from([
            "pikpak",
            "share-save",
            "--request-file",
            "/private/tmp/share-save.json",
        ])
        .unwrap();
        let Command::ShareSave(args) = save.command else {
            panic!("share-save command should parse");
        };
        assert_eq!(
            args.request_file,
            std::path::PathBuf::from("/private/tmp/share-save.json")
        );
    }

    #[test]
    fn share_request_json_uses_api_field_names() {
        let request = super::ShareDownloadInput {
            access: super::ShareAccessInput {
                url: "https://mypikpak.com/s/example".to_string(),
                pass_code: "1234".to_string(),
                pass_code_token: "temporary".to_string(),
            },
            roots: vec![super::ShareDownloadRoot {
                id: "file-id".to_string(),
                name: "clip.mp4".to_string(),
                size: 42,
                kind: pikpak::FileKind::File,
                path: "/clip.mp4".to_string(),
                relative_parent: None,
            }],
        };
        let json = serde_json::to_value(request).unwrap();
        assert_eq!(json["pass_code"], "1234");
        assert_eq!(json["pass_code_token"], "temporary");
        assert_eq!(json["roots"][0]["kind"], "drive#file");

        let save = super::ShareSaveInput {
            access: super::ShareAccessInput {
                url: "https://mypikpak.com/s/example".to_string(),
                pass_code: "1234".to_string(),
                pass_code_token: "temporary".to_string(),
            },
            file_ids: vec!["folder-id".to_string(), "file-id".to_string()],
        };
        let json = serde_json::to_value(save).unwrap();
        assert_eq!(json["pass_code"], "1234");
        assert_eq!(json["pass_code_token"], "temporary");
        assert_eq!(json["file_ids"][1], "file-id");
    }

    #[test]
    fn cached_account_download_request_preserves_ids_and_destinations() {
        use clap::Parser;
        let cli = super::Cli::try_parse_from([
            "pikpak",
            "download",
            "--roots-file",
            "/tmp/roots.json",
            "--jobs",
            "32",
        ])
        .unwrap();
        assert!(
            matches!(cli.command, super::Command::Download(args) if args.paths.is_empty() && args.roots_file.is_some() && args.jobs == 32)
        );
        let request: super::AccountDownloadInput = serde_json::from_value(serde_json::json!({
            "roots": [{ "path": "/A/report.txt", "relative_parent": [],
                "file": { "id": "stable-id", "name": "report.txt", "kind": "drive#file", "size": "42" } }]
        })).unwrap();
        assert_eq!(request.roots[0].file.as_ref().unwrap().id, "stable-id");
        let output = std::path::Path::new("/tmp/test-output");
        assert_eq!(
            super::download_root_destination(output, "/A/report.txt", 0, Some(&[])).unwrap(),
            output
        );
        assert_eq!(
            super::download_root_destination(output, "/A/report.txt", 0, Some(&["A".into()]))
                .unwrap(),
            output.join("A")
        );
        assert!(
            super::download_root_destination(output, "/A/report.txt", 0, Some(&["..".into()]))
                .is_err()
        );
    }

    #[test]
    fn upload_cli_accepts_private_input_list_and_destination() {
        let cli = Cli::try_parse_from([
            "pikpak",
            "upload",
            "--parent-id",
            "folder-id",
            "--inputs-file",
            "/private/tmp/upload-inputs.json",
            "--progress-json",
        ])
        .unwrap();
        let Command::Upload(args) = cli.command else {
            panic!("upload command should parse");
        };
        assert_eq!(args.parent_id, "folder-id");
        assert!(args.inputs.is_empty());
        assert_eq!(
            args.inputs_file.as_deref(),
            Some(std::path::Path::new("/private/tmp/upload-inputs.json"))
        );
        assert!(args.progress_json);
        assert_eq!(args.jobs, 4);
    }

    #[test]
    fn upload_cli_accepts_bounded_worker_setting() {
        let cli = Cli::try_parse_from([
            "pikpak",
            "upload",
            "--input",
            "/private/tmp/folder",
            "--jobs",
            "12",
        ])
        .unwrap();
        let Command::Upload(args) = cli.command else {
            panic!("upload command should parse");
        };
        assert_eq!(
            args.inputs,
            vec![std::path::PathBuf::from("/private/tmp/folder")]
        );
        assert_eq!(args.jobs, 12);
    }

    #[test]
    fn upload_worker_count_is_bounded_and_never_exceeds_file_count() {
        assert_eq!(bounded_upload_file_workers(0, 100), 1);
        assert_eq!(bounded_upload_file_workers(16, 100), 16);
        assert_eq!(bounded_upload_file_workers(128, 100), 64);
        assert_eq!(bounded_upload_file_workers(64, 7), 7);
        assert_eq!(bounded_upload_file_workers(64, 0), 0);
    }

    #[test]
    fn download_worker_count_is_bounded_and_never_exceeds_file_count() {
        assert_eq!(bounded_download_workers(0, 100), 1);
        assert_eq!(bounded_download_workers(32, 100), 32);
        assert_eq!(bounded_download_workers(128, 100), 100);
        assert_eq!(bounded_download_workers(usize::MAX, 1_000), 1_000);
        assert_eq!(bounded_download_workers(64, 7), 7);
        assert_eq!(bounded_download_workers(64, 0), 0);
    }

    #[test]
    fn recursive_upload_discovery_scales_and_deduplicates_nested_selections() {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let test_directory =
            std::env::temp_dir().join(format!("pikpak-upload-plan-{}-{nonce}", std::process::id()));
        let selected_root = test_directory.join("Two Thousand Files");
        std::fs::create_dir_all(&selected_root).unwrap();
        for folder_index in 0..20 {
            let folder = selected_root.join(format!("batch-{folder_index:02}"));
            std::fs::create_dir(&folder).unwrap();
            for file_index in 0..100 {
                std::fs::write(folder.join(format!("item-{file_index:03}.bin")), []).unwrap();
            }
        }

        let nested_file = selected_root.join("batch-00/item-000.bin");
        let plan = discover_local_uploads(vec![selected_root.clone(), nested_file]).unwrap();
        assert_eq!(plan.files.len(), 2_000);
        assert_eq!(plan.directories.len(), 21);
        assert_eq!(plan.skipped_entries, 0);
        assert!(plan.files.iter().all(|file| {
            file.display_name.starts_with("Two Thousand Files/") && file.parent_directory.is_some()
        }));
        assert!(plan
            .directories
            .iter()
            .enumerate()
            .all(|(index, directory)| {
                directory
                    .parent_directory
                    .is_none_or(|parent_index| parent_index < index)
            }));

        let _ = std::fs::remove_dir_all(test_directory);
    }

    #[test]
    fn upload_progress_event_uses_stable_snake_case_json() {
        let event = UploadProgressEvent::FileProgress {
            upload_id: "7",
            name: "clip.mp4",
            uploaded_bytes: 512,
            total_bytes: 1024,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains(r#""event":"file_progress""#));
        assert!(json.contains(r#""upload_id":"7""#));
        assert!(json.contains(r#""uploaded_bytes":512"#));
        assert!(json.contains(r#""total_bytes":1024"#));
    }

    #[test]
    fn upload_failure_progress_includes_the_file_error() {
        let event = UploadProgressEvent::FileFailed {
            upload_id: "8",
            name: "large-video.mov",
            total_bytes: 2048,
            source_path: "/Users/test/large-video.mov",
            parent_id: "cloud-parent",
            error: "start multipart upload: TLS peer closed the connection",
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains(r#""event":"file_failed""#));
        assert!(json.contains(r#""upload_id":"8""#));
        assert!(
            json.contains(r#""error":"start multipart upload: TLS peer closed the connection""#)
        );
        assert!(json.contains(r#""source_path":"/Users/test/large-video.mov""#));
        assert!(json.contains(r#""parent_id":"cloud-parent""#));
    }

    #[test]
    fn upload_whole_file_retry_only_accepts_transient_failures() {
        assert!(upload_file_failure_is_retryable(&anyhow::anyhow!(
            "send file to PikPak upload storage: HTTP 503"
        )));
        assert!(upload_file_failure_is_retryable(&anyhow::anyhow!(
            "connection reset while sending response body"
        )));
        assert!(!upload_file_failure_is_retryable(&anyhow::anyhow!(
            "calculate content identifier: Permission denied"
        )));
        assert!(!upload_file_failure_is_retryable(&anyhow::anyhow!(
            "storage quota exceeded"
        )));
    }

    #[test]
    fn account_cli_checks_profile_without_transfer_arguments() {
        let cli = Cli::try_parse_from(["pikpak", "account"]).unwrap();
        assert!(matches!(cli.command, Command::Account));
    }

    #[test]
    fn quota_cli_accepts_structured_json_output() {
        let cli = Cli::try_parse_from(["pikpak", "quota", "--json"]).unwrap();
        let Command::Quota(args) = cli.command else {
            panic!("quota command should parse");
        };
        assert!(args.json);
        assert!(!args.raw);
        assert!(!args.with_transfer);
        let cli = Cli::try_parse_from(["pikpak", "quota", "--json", "--with-transfer"]).unwrap();
        let Command::Quota(args) = cli.command else {
            panic!("quota command should parse");
        };
        assert!(args.with_transfer);
        assert!(Cli::try_parse_from(["pikpak", "quota", "--with-transfer"]).is_err());
    }

    #[test]
    fn browse_cli_accepts_embedded_quota_output() {
        let cli = Cli::try_parse_from(["pikpak", "browse", "--with-quota"]).unwrap();
        let Command::Browse(args) = cli.command else {
            panic!("browse command should parse");
        };
        assert!(args.with_quota);
    }

    #[test]
    fn download_path_relationships_respect_component_boundaries() {
        assert!(remote_path_is_descendant(
            "/My Pack/Movies/clip.mp4",
            "/My Pack/Movies"
        ));
        assert!(!remote_path_is_descendant(
            "/My Pack/Movies 2/clip.mp4",
            "/My Pack/Movies"
        ));
        assert_eq!(
            common_download_parent_depth(&[
                "/My Pack/A/same.mp4".to_string(),
                "/My Pack/B/same.mp4".to_string(),
            ]),
            1
        );
    }

    #[test]
    fn recursive_empty_folder_candidates_are_deepest_first_and_preserve_root() {
        let nodes = vec![
            EmptyFolderNode {
                id: "root".to_string(),
                path: "/Scope".to_string(),
                depth: 0,
                child_folder_ids: vec!["a".to_string(), "b".to_string()],
                contains_file: false,
                has_uninspectable_child: false,
            },
            EmptyFolderNode {
                id: "a".to_string(),
                path: "/Scope/A".to_string(),
                depth: 1,
                child_folder_ids: vec!["c".to_string()],
                contains_file: false,
                has_uninspectable_child: false,
            },
            EmptyFolderNode {
                id: "c".to_string(),
                path: "/Scope/A/C".to_string(),
                depth: 2,
                child_folder_ids: vec![],
                contains_file: false,
                has_uninspectable_child: false,
            },
            EmptyFolderNode {
                id: "b".to_string(),
                path: "/Scope/B".to_string(),
                depth: 1,
                child_folder_ids: vec![],
                contains_file: true,
                has_uninspectable_child: false,
            },
        ];

        assert_eq!(
            empty_folder_candidate_ids("root", &nodes),
            vec!["c".to_string(), "a".to_string()]
        );
    }

    #[test]
    fn recursive_empty_folder_cleanup_blocks_uninspectable_branches() {
        let nodes = vec![
            EmptyFolderNode {
                id: "root".to_string(),
                path: "/Scope".to_string(),
                depth: 0,
                child_folder_ids: vec!["blocked".to_string()],
                contains_file: false,
                has_uninspectable_child: false,
            },
            EmptyFolderNode {
                id: "blocked".to_string(),
                path: "/Scope/Blocked".to_string(),
                depth: 1,
                child_folder_ids: vec![],
                contains_file: false,
                has_uninspectable_child: true,
            },
        ];

        assert!(empty_folder_candidate_ids("root", &nodes).is_empty());
    }

    #[test]
    fn recursive_empty_folder_cleanup_keeps_parent_of_non_empty_descendant() {
        let nodes = vec![
            EmptyFolderNode {
                id: "root".to_string(),
                path: "/Scope".to_string(),
                depth: 0,
                child_folder_ids: vec!["parent".to_string()],
                contains_file: false,
                has_uninspectable_child: false,
            },
            EmptyFolderNode {
                id: "parent".to_string(),
                path: "/Scope/Parent".to_string(),
                depth: 1,
                child_folder_ids: vec!["child".to_string()],
                contains_file: false,
                has_uninspectable_child: false,
            },
            EmptyFolderNode {
                id: "child".to_string(),
                path: "/Scope/Parent/Child".to_string(),
                depth: 2,
                child_folder_ids: vec![],
                contains_file: true,
                has_uninspectable_child: false,
            },
        ];

        assert!(empty_folder_candidate_ids("root", &nodes).is_empty());
    }

    #[test]
    fn recursive_empty_folder_cleanup_keeps_folder_with_missing_child_scan() {
        let nodes = vec![
            EmptyFolderNode {
                id: "root".to_string(),
                path: "/Scope".to_string(),
                depth: 0,
                child_folder_ids: vec!["candidate".to_string()],
                contains_file: false,
                has_uninspectable_child: false,
            },
            EmptyFolderNode {
                id: "candidate".to_string(),
                path: "/Scope/Candidate".to_string(),
                depth: 1,
                child_folder_ids: vec!["missing".to_string()],
                contains_file: false,
                has_uninspectable_child: false,
            },
        ];

        assert!(empty_folder_candidate_ids("root", &nodes).is_empty());
    }

    #[test]
    fn folder_measurement_counts_and_sums_safely() {
        let mut measurement = FolderMeasurement::default();
        measurement.add_file(10);
        measurement.add_file(25);
        measurement.add_folder();

        assert_eq!(measurement.total_bytes, 35);
        assert_eq!(measurement.file_count, 2);
        assert_eq!(measurement.folder_count, 1);

        measurement.total_bytes = u64::MAX;
        measurement.file_count = u64::MAX;
        measurement.folder_count = u64::MAX;
        measurement.add_file(1);
        measurement.add_folder();
        assert_eq!(measurement.total_bytes, u64::MAX);
        assert_eq!(measurement.file_count, u64::MAX);
        assert_eq!(measurement.folder_count, u64::MAX);
    }

    #[test]
    fn folder_measurement_report_contains_recursive_totals_for_every_folder() {
        let mut root_direct = FolderMeasurement::default();
        root_direct.add_file(5);
        let mut child_direct = FolderMeasurement::default();
        child_direct.add_file(10);
        let mut grandchild_direct = FolderMeasurement::default();
        grandchild_direct.add_file(20);

        let report = build_folder_measurement_report(
            "root",
            HashMap::from([
                ("root".to_string(), root_direct),
                ("child".to_string(), child_direct),
                ("empty".to_string(), FolderMeasurement::default()),
                ("grandchild".to_string(), grandchild_direct),
            ]),
            HashMap::from([
                (
                    "root".to_string(),
                    vec!["child".to_string(), "empty".to_string()],
                ),
                ("child".to_string(), vec!["grandchild".to_string()]),
                ("empty".to_string(), Vec::new()),
                ("grandchild".to_string(), Vec::new()),
            ]),
            &[
                "root".to_string(),
                "child".to_string(),
                "empty".to_string(),
                "grandchild".to_string(),
            ],
        );

        assert_eq!(report.root.total_bytes, 35);
        assert_eq!(report.root.file_count, 3);
        assert_eq!(report.root.folder_count, 3);
        assert_eq!(report.folders["root"], report.root);
        assert_eq!(report.folders["child"].total_bytes, 30);
        assert_eq!(report.folders["child"].file_count, 2);
        assert_eq!(report.folders["child"].folder_count, 1);
        assert_eq!(report.folders["grandchild"].total_bytes, 20);
        assert_eq!(report.folders["empty"], FolderMeasurement::default());
    }

    fn size_fixture_entry(id: &str, folder: bool, size: u64) -> super::FileInfo {
        serde_json::from_value(serde_json::json!({
            "id": id, "name": id, "size": size.to_string(),
            "kind": if folder { "drive#folder" } else { "drive#file" }
        }))
        .unwrap()
    }

    #[tokio::test]
    async fn folder_measurement_incremental_refresh_skips_one_thousand_unchanged_subtrees() {
        let mut seed = super::FolderMeasurementSeed::default();
        let mut root_entries = Vec::new();
        for i in 0..1_000 {
            let id = format!("cached-{i}");
            root_entries.push(size_fixture_entry(&id, true, 999_999));
            seed.folders.insert(
                id,
                FolderMeasurement {
                    total_bytes: 10,
                    file_count: 1,
                    folder_count: 0,
                },
            );
        }
        // Even a stale root in a seed must never suppress refreshing the root.
        seed.folders
            .insert("root".into(), FolderMeasurement::default());
        root_entries.push(size_fixture_entry("new-folder", true, 999_999));
        let mut calls = Vec::new();
        let report = super::measure_folder_tree("root", seed, 4, |id| {
            calls.push(id.clone());
            let entries = match id.as_str() {
                "root" => root_entries.clone(),
                "new-folder" => vec![size_fixture_entry("new-file", false, 25)],
                other => panic!("unnecessarily scanned {other}"),
            };
            async move { Ok(entries) }
        })
        .await
        .unwrap();
        assert_eq!(calls, ["root", "new-folder"]);
        assert_eq!(report.root.total_bytes, 10_025);
        assert_eq!(report.root.file_count, 1_001);
        assert_eq!(report.root.folder_count, 1_001);
        assert_eq!(report.reused_folders, 1_000);
        assert_eq!(report.listings.len(), 2);
        assert_eq!(report.listings["new-folder"][0].id, "new-file");
        assert_eq!(report.folders["new-folder"].total_bytes, 25);
    }

    #[tokio::test]
    async fn folder_measurement_rejects_partial_failure_and_deduplicates_entries() {
        let failure = super::measure_folder_tree("root", Default::default(), 4, |id| async move {
            if id == "root" {
                Ok(vec![size_fixture_entry("missing", true, 0)])
            } else {
                anyhow::bail!("fixture listing failed")
            }
        })
        .await;
        assert!(
            failure.is_err(),
            "a partial scan must never be persisted as a full size"
        );
        let report = super::measure_folder_tree("root", Default::default(), 4, |id| async move {
            if id == "root" {
                Ok(vec![size_fixture_entry("child", true, 0)])
            } else {
                Ok(vec![
                    size_fixture_entry("root", true, 0),
                    size_fixture_entry("file", false, 15),
                    size_fixture_entry("file", false, 15),
                ])
            }
        })
        .await
        .unwrap();
        assert_eq!(report.root.total_bytes, 15);
        assert_eq!(report.root.file_count, 1);
        assert_eq!(report.root.folder_count, 1);
        assert!(report
            .listings
            .values()
            .flatten()
            .all(|entry| entry.id != "root"));
    }

    #[tokio::test]
    async fn folder_measurement_lists_sibling_folders_concurrently() {
        use std::cell::Cell;
        use std::rc::Rc;
        // root -> 12 folders -> 1 nested folder each -> 1 file each. Later
        // listings finish first, so aggregation cannot rely on completion order.
        let in_flight = Rc::new(Cell::new(0usize));
        let peak = Rc::new(Cell::new(0usize));
        let report = super::measure_folder_tree("root", Default::default(), 4, |id| {
            let (in_flight, peak) = (in_flight.clone(), peak.clone());
            async move {
                in_flight.set(in_flight.get() + 1);
                peak.set(peak.get().max(in_flight.get()));
                let yields = if id == "root" {
                    1
                } else {
                    40 - id.len() % 7 * 5
                };
                for _ in 0..yields {
                    tokio::task::yield_now().await;
                }
                in_flight.set(in_flight.get() - 1);
                Ok(match id.as_str() {
                    "root" => (0..12)
                        .map(|i| size_fixture_entry(&format!("folder-{i}"), true, 0))
                        .collect(),
                    folder if folder.ends_with("-nested") => {
                        vec![size_fixture_entry(&format!("{folder}-file"), false, 7)]
                    }
                    folder => vec![
                        size_fixture_entry(&format!("{folder}-nested"), true, 0),
                        size_fixture_entry(&format!("{folder}-file"), false, 3),
                    ],
                })
            }
        })
        .await
        .unwrap();
        assert_eq!(
            peak.get(),
            4,
            "a wide tree must keep the listing pool full but bounded"
        );
        assert_eq!(in_flight.get(), 0);
        assert_eq!(report.root.total_bytes, 12 * 10);
        assert_eq!(report.root.file_count, 24);
        assert_eq!(report.root.folder_count, 24);
        assert_eq!(report.folders["folder-5"].total_bytes, 10);
        assert_eq!(report.folders["folder-5"].folder_count, 1);
        assert_eq!(report.folders["folder-5-nested"].total_bytes, 7);
        assert_eq!(report.listings.len(), 25);
    }

    #[tokio::test]
    async fn folder_measurement_failure_stops_concurrent_walk() {
        let failure = super::measure_folder_tree("root", Default::default(), 4, |id| async move {
            match id.as_str() {
                "root" => Ok((0..8)
                    .map(|i| size_fixture_entry(&format!("folder-{i}"), true, 0))
                    .collect()),
                "folder-3" => anyhow::bail!("fixture listing failed"),
                _ => {
                    tokio::task::yield_now().await;
                    Ok(vec![size_fixture_entry(&format!("{id}-file"), false, 1)])
                }
            }
        })
        .await;
        let message = format!(
            "{:#}",
            failure.expect_err("a failed sibling must fail the walk")
        );
        assert!(message.contains("folder-3"), "{message}");
    }

    #[test]
    fn folder_measurement_seed_accepts_native_cache_encoding() {
        let seed: super::FolderMeasurementSeed = serde_json::from_str(
            r#"{"folders":{"folder":{"totalBytes":40,"fileCount":2,"folderCount":1}}}"#,
        )
        .unwrap();
        assert_eq!(seed.folders["folder"].total_bytes, 40);
        let args = Cli::try_parse_from([
            "pikpak",
            "measure",
            "--id",
            "root",
            "--cache-file",
            "/tmp/cache.json",
        ])
        .unwrap();
        assert!(matches!(
            args.command,
            Command::Measure(super::MeasureArgs {
                cache_file: Some(_),
                ..
            })
        ));
        let event = UploadProgressEvent::FileCompleted {
            upload_id: "1",
            name: "fixture",
            total_bytes: 5,
            instant: true,
            parent_id: "destination",
        };
        let json = serde_json::to_value(event).unwrap();
        assert_eq!(json["parent_id"], "destination");
    }

    #[test]
    fn keeps_plain_names() {
        assert_eq!(safe_component("video.mp4").unwrap(), "video.mp4");
        assert_eq!(safe_component("My Pack").unwrap(), "My Pack");
    }

    #[test]
    fn strips_directory_traversal() {
        assert_eq!(safe_component("../../etc/passwd").unwrap(), "passwd");
        assert_eq!(safe_component("a/b/c.txt").unwrap(), "c.txt");
    }

    #[test]
    fn rejects_absolute_paths() {
        assert_eq!(safe_component("/etc/cron.d/x").unwrap(), "x");
    }

    #[test]
    fn rejects_names_without_a_basename() {
        assert!(safe_component("").is_err());
        assert!(safe_component("..").is_err());
        assert!(safe_component(".").is_err());
        assert!(safe_component("/").is_err());
    }

    use super::{download_backoff, update_env_token, write_secret_file};

    #[test]
    fn update_env_rewrites_token_line() {
        let dir = std::env::temp_dir().join(format!("pikpak-env-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let env_path = dir.join(".env");
        std::fs::write(
            &env_path,
            "PIKPAK_REFRESH_TOKEN=old\nPIKPAK_PROXY=http://x\n",
        )
        .unwrap();

        let changed = update_env_token(&env_path, "brand-new").unwrap();
        assert!(changed);

        let content = std::fs::read_to_string(&env_path).unwrap();
        assert!(content.contains("PIKPAK_REFRESH_TOKEN=brand-new"));
        assert!(content.contains("PIKPAK_PROXY=http://x"));
        assert!(!content.contains("=old"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn update_env_absent_file_is_noop() {
        let path = std::env::temp_dir().join("pikpak-does-not-exist-abc.env");
        let _ = std::fs::remove_file(&path);
        assert!(!update_env_token(&path, "x").unwrap());
    }

    #[test]
    fn update_env_without_key_returns_false() {
        let dir = std::env::temp_dir().join(format!("pikpak-env2-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let env_path = dir.join(".env");
        std::fs::write(&env_path, "PIKPAK_PROXY=http://x\n").unwrap();
        assert!(!update_env_token(&env_path, "x").unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn download_backoff_grows_and_caps() {
        assert!(download_backoff(0) < download_backoff(2));
        assert!(download_backoff(30) <= std::time::Duration::from_millis(15_000));
    }

    #[test]
    fn secret_file_is_private_and_exact() {
        let dir = std::env::temp_dir().join(format!("pikpak-secret-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rotated-token");
        write_secret_file(&path, "new-secret").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "new-secret");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    async fn spawn_range_server(full: Vec<u8>) -> std::net::SocketAddr {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let (mut sock, _) = match listener.accept().await {
                    Ok(v) => v,
                    Err(_) => return,
                };
                let full = full.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 2048];
                    let n = sock.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]);
                    let start = req
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("range: bytes=")
                                .map(|v| v.trim().trim_end_matches('-').to_string())
                        })
                        .and_then(|s| s.parse::<usize>().ok());

                    match start {
                        Some(s) if s >= full.len() => {
                            let body = b"range not satisfiable";
                            let hdr = format!(
                                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                body.len()
                            );
                            let _ = sock.write_all(hdr.as_bytes()).await;
                            let _ = sock.write_all(body).await;
                        }
                        Some(s) => {
                            let body = &full[s..];
                            let hdr = format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                                body.len(),
                                s,
                                full.len() - 1,
                                full.len()
                            );
                            let _ = sock.write_all(hdr.as_bytes()).await;
                            let _ = sock.write_all(body).await;
                        }
                        None => {
                            let hdr = format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                full.len()
                            );
                            let _ = sock.write_all(hdr.as_bytes()).await;
                            let _ = sock.write_all(&full).await;
                        }
                    }
                    let _ = sock.flush().await;
                });
            }
        });
        addr
    }

    #[test]
    fn download_pause_cancel_flushes_writes_and_resumes_in_isolation() {
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tests::download_pause_cancel_child",
                "--ignored",
                "--nocapture",
            ])
            .output()
            .unwrap();
        assert!(
            child.status.success(),
            "{}",
            String::from_utf8_lossy(&child.stdout).to_string()
                + &String::from_utf8_lossy(&child.stderr)
        );
    }
    #[tokio::test]
    #[ignore = "isolated environment configured by parent test"]
    async fn download_pause_cancel_child() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        std::env::remove_var("MYCLOUDDRIVER_TRANSFER_OWNER");
        let directory = tempfile::tempdir().unwrap();
        let control = directory.path().join("control.json");
        std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
        let partial = directory.path().join("file.part");
        let final_file = directory.path().join("completed.bin");
        std::fs::write(&final_file, b"finished file").unwrap();
        let full = vec![0x4au8; 2 * 1024 * 1024];
        let client = pikpak::Client::builder()
            .refresh_token("dummy")
            .build()
            .unwrap();
        for command in ["pause", "cancel"] {
            std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
            tokio::time::sleep(std::time::Duration::from_millis(110)).await;
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let bytes = full.clone();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = [0u8; 2048];
                let _ = socket.read(&mut request).await;
                let header = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    bytes.len()
                );
                socket.write_all(header.as_bytes()).await.unwrap();
                socket.write_all(&bytes[..65536]).await.unwrap();
                socket.flush().await.unwrap();
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            });
            let path = partial.clone();
            let instance = client.clone();
            let total = full.len() as u64;
            let attempt = tokio::spawn(async move {
                super::download_attempt(
                    &instance,
                    &format!("http://{address}/file"),
                    total,
                    &path,
                    false,
                    super::DownloadProgressContext::new(false, "controlled-file", "file"),
                )
                .await
            });
            for _ in 0..100 {
                if std::fs::metadata(&partial).is_ok_and(|value| value.len() == 65536) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
            assert_eq!(std::fs::metadata(&partial).unwrap().len(), 65536);
            std::fs::write(
                &control,
                format!(r#"{{"actions":{{"controlled-file":"{command}"}}}}"#),
            )
            .unwrap();
            let result = tokio::time::timeout(std::time::Duration::from_secs(2), attempt)
                .await
                .unwrap()
                .unwrap();
            let error = match result {
                Err(error) => error.into_inner(),
                Ok(_) => panic!("control should interrupt stalled I/O"),
            };
            server.abort();
            if command == "pause" {
                assert!(error.is::<super::transfer_control::Paused>());
                assert_eq!(std::fs::metadata(&partial).unwrap().len(), 65536);
                std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
                tokio::time::sleep(std::time::Duration::from_millis(110)).await;
                let address = spawn_range_server(full.clone()).await;
                let result = super::download_attempt(
                    &client,
                    &format!("http://{address}/file"),
                    total,
                    &partial,
                    false,
                    super::DownloadProgressContext::new(false, "controlled-file", "file"),
                )
                .await;
                assert!(result.is_ok());
                assert_eq!(std::fs::read(&partial).unwrap(), full);
                std::fs::remove_file(&partial).unwrap();
            } else {
                assert!(error.is::<super::transfer_control::Cancelled>());
                assert!(!partial.exists());
            }
            assert_eq!(std::fs::read(&final_file).unwrap(), b"finished file");
        }
    }

    #[tokio::test]
    async fn download_attempt_resumes_via_range() {
        let full: Vec<u8> = (0u8..32).collect();
        let addr = spawn_range_server(full.clone()).await;
        let client = pikpak::Client::builder()
            .refresh_token("dummy")
            .build()
            .unwrap();

        let dir = std::env::temp_dir().join(format!("pikpak-resume-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let part = dir.join("f.part");
        std::fs::write(&part, &full[..10]).unwrap();
        super::download_transport::seed_resume(
            &part,
            "test-file",
            full.len() as u64,
            "\"fixture\"",
        );

        let url = format!("http://{addr}/f");
        let progress = super::DownloadProgressContext::new(false, "test-file", "f");
        let res = super::download_attempt(
            &client,
            &url,
            full.len() as u64,
            &part,
            false,
            progress.clone(),
        )
        .await;
        assert!(res.is_ok(), "resume attempt should succeed");
        assert_eq!(
            progress.transferred_bytes(),
            (full.len() - 10) as u64,
            "speed accounting must exclude the bytes already in the part file"
        );

        let got = std::fs::read(&part).unwrap();
        assert_eq!(got, full, "resumed file must equal the full content");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn upload_restart_skips_completed_file_without_local_source_or_network() {
        use pikpak::upload_checkpoint::{FileCheckpoint, UploadCheckpoint};
        let directory =
            std::env::temp_dir().join(format!("pikpak-upload-restart-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("source.txt");
        std::fs::write(&path, b"already uploaded").unwrap();
        let mut checkpoint = UploadCheckpoint::open(
            directory.join("state"),
            "account".into(),
            "parent".into(),
            vec![path.clone()],
        )
        .unwrap();
        checkpoint
            .initialize(
                &serde_json::json!({"test": true}),
                [path.clone()].into_iter(),
            )
            .unwrap();
        checkpoint
            .save_file(
                &path,
                &FileCheckpoint {
                    gcid: Some("ABC".into()),
                    remote_file_id: Some("remote-file".into()),
                    completed: true,
                    cancelled: false,
                    ..Default::default()
                },
            )
            .unwrap();
        drop(checkpoint); // Old helper exited; next helper reads only durable files.
        std::fs::remove_file(&path).unwrap();
        let restored = UploadCheckpoint::open(
            directory.join("state"),
            "account".into(),
            "parent".into(),
            vec![path.clone()],
        )
        .unwrap();
        let client = pikpak::Client::builder()
            .refresh_token("dummy")
            .build()
            .unwrap();
        let source = super::UploadSource {
            upload_id: "0".into(),
            path: path.clone(),
            name: "source.txt".into(),
            display_name: "source.txt".into(),
            size: 16,
            remote_parent_id: "parent".into(),
        };
        let network = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
        assert!(super::upload_one_file(
            &client,
            &source,
            false,
            1,
            Some(&restored),
            network.clone()
        )
        .await
        .unwrap());
        assert_eq!(
            network.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "completed checkpoints must not inflate adaptive throughput"
        );
        // Incomplete entries must NOT quietly skip a missing/changed source.
        restored
            .save_file(&path, &FileCheckpoint::default())
            .unwrap();
        assert!(
            super::upload_one_file(&client, &source, false, 1, Some(&restored), network)
                .await
                .is_err()
        );
        drop(restored);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn download_attempt_restarts_on_416() {
        // Remote file is 4 bytes; the local part holds 6 stale bytes, so the
        // server answers 416. total is claimed larger than the part so we hit
        // the restart branch rather than the "already complete" shortcut.
        let full: Vec<u8> = vec![1, 2, 3, 4];
        let addr = spawn_range_server(full.clone()).await;
        let client = pikpak::Client::builder()
            .refresh_token("dummy")
            .build()
            .unwrap();

        let dir = std::env::temp_dir().join(format!("pikpak-416-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let part = dir.join("f.part");
        std::fs::write(&part, [9u8; 6]).unwrap();
        super::download_transport::seed_resume(&part, "test-file", 16, "\"fixture\"");

        let url = format!("http://{addr}/f");
        let progress = super::DownloadProgressContext::new(false, "test-file", "f");
        let res = super::download_attempt(&client, &url, 16, &part, false, progress.clone()).await;
        assert!(
            matches!(res, Err(super::DlError::Retryable(_))),
            "416 with a shorter remote file must return a retryable restart"
        );
        // Discard its validator; a full response verifies/replaces the retained
        // prefix. The 416 error body must never enter the partial file.
        assert_eq!(std::fs::metadata(&part).unwrap().len(), 6);
        assert!(!part.with_file_name("f.part.resume.json").exists());
        assert_eq!(
            progress.transferred_bytes(),
            0,
            "the 416 error body must not be counted as downloaded file data"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

//! Completion is bound to the cloud source and the exact local file identity.
//! Receipt checks preserve existing files. The download runner can explicitly
//! remove conflicting local files under its output lease and retry. A pending source-bound copy whose
//! filesystem identity changed can be recognized only after proving its full
//! bytes and the separately retained original. Initial ExFAT copies can resume
//! after exact creation provenance and every existing prefix byte are proven;
//! uncertain destinations remain unchanged while source-verified staging can
//! complete through an exclusive, journaled sibling recovery route.
use crate::download_fs;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};
use unicode_normalization::UnicodeNormalization;

/// Refuse because a file on disk no longer matches what this download recorded.
/// The download runner catches this marker and resets only this output's files.
macro_rules! conflict {
    ($($arg:tt)*) => {
        return Err(anyhow::Error::new(pikpak::download_policy::LocalFileConflict(format!($($arg)*))))
    };
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Source {
    scope: String,
    file_id: String,
    revision: Option<String>,
    size: u64,
}
impl Source {
    pub fn from_download(
        scope: String,
        file_id: &str,
        download: &pikpak::DownloadInfo,
        size: u64,
    ) -> Self {
        Self {
            scope,
            file_id: file_id.into(),
            revision: download.source_revision.clone(),
            size,
        }
    }
    #[cfg(test)]
    pub fn new(scope: String, file: &pikpak::FileInfo, size: u64) -> Self {
        let revision = file
            .hash
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .map(|s| format!("gcid:{}", s.trim().to_uppercase()))
            .or_else(|| {
                file.md5_checksum
                    .as_deref()
                    .filter(|s| !s.trim().is_empty())
                    .map(|s| format!("md5:{}", s.trim().to_uppercase()))
            })
            .or_else(|| {
                file.modified_time
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .map(|s| format!("modified:{s}"))
            });
        Self {
            scope,
            file_id: file.id.clone(),
            revision,
            size,
        }
    }
}

/// Retained progress is reported only after independently verifying the full
/// source-bound staging file. Context keeps typed controls and I/O errors in
/// the original anyhow chain; callers render `failure` without duplication.
#[derive(Debug)]
pub struct VerifiedStagingProgress {
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub failure: String,
}

impl std::fmt::Display for VerifiedStagingProgress {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.failure)
    }
}

impl std::error::Error for VerifiedStagingProgress {}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Identity {
    device: u64,
    inode: u64,
    size: u64,
    modified: i128,
    changed: i128,
}
impl Identity {
    fn read(metadata: &std::fs::Metadata) -> Result<Self> {
        use std::os::unix::fs::MetadataExt;
        if !metadata.is_file() {
            bail!("Download destination is not a regular file");
        }
        Ok(Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            size: metadata.len(),
            modified: i128::from(metadata.mtime()) * 1_000_000_000
                + i128::from(metadata.mtime_nsec()),
            changed: i128::from(metadata.ctime()) * 1_000_000_000
                + i128::from(metadata.ctime_nsec()),
        })
    }
    fn same_file(&self, current: &Self) -> bool {
        self.device == current.device && self.same_inode_metadata(current)
    }
    fn same_inode_size(&self, current: &Self) -> bool {
        self.inode == current.inode && self.size == current.size
    }
    /// Which part of a failed `same_inode_size` comparison differs, for a message that names no file.
    fn difference(&self, current: &Self) -> &'static str {
        if self.inode != current.inode {
            "file identity"
        } else {
            "size"
        }
    }
    fn same_object_size(&self, current: &Self) -> bool {
        self.device == current.device && self.same_inode_size(current)
    }
    fn same_device_size(&self, current: &Self) -> bool {
        self.device == current.device && self.size == current.size
    }
    /// Whether `current` can be vouched for from metadata alone, without reading it. The same file object is
    /// trusted only if neither its modification nor its change time moved, because any write moves the change
    /// time even when the modification time is put back. A copy has a new inode and a change time that cannot be
    /// compared with the original's, so its size and modification time are what remain.
    fn vouched_by_metadata(&self, current: &Self) -> bool {
        self.size == current.size
            && self.modified == current.modified
            && (self.inode != current.inode || self.changed == current.changed)
    }
    fn same_inode_metadata(&self, current: &Self) -> bool {
        self.inode == current.inode
            && self.size == current.size
            && self.modified == current.modified
    }
}

#[derive(Serialize, Deserialize)]
struct Receipt {
    version: u32,
    source: Source,
    local: Identity,
    sha256: String,
    committed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    copy: Option<CopyPublication>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    recovery: Option<RecoveryPublication>,
}

/// Duplicate checks trust a completed download's GCID without revalidating its
/// contents or comparing the old filesystem identity. The user assumes these
/// downloads are unmodified. The receipt must still belong to this filename.
pub(crate) struct DuplicateGcidReceipt {
    filename: std::ffi::OsString,
    recorded: std::time::SystemTime,
    receipt: Receipt,
}

impl DuplicateGcidReceipt {
    pub fn gcid_for(&self, output: &Path, metadata: &std::fs::Metadata) -> Option<String> {
        let receipt = &self.receipt;
        if receipt.version != 1 || !receipt.committed || !metadata.is_file() { return None; }
        let bound = if let Some(route) = &receipt.recovery {
            route.owned && valid_recovery_name(&route.output_name)
                && output.file_name() == route.output_name.file_name()
        } else {
            path(output, &receipt.source).ok()?.file_name()? == self.filename
        };
        if !bound { return None; }
        let gcid = receipt.source.revision.as_deref()?.strip_prefix("gcid:")?;
        (gcid.len() == 40 && gcid.bytes().all(|byte| byte.is_ascii_hexdigit()))
            .then(|| gcid.to_ascii_uppercase())
    }
}

pub(crate) struct DuplicateGcidReceiptIndex {
    receipts: Vec<DuplicateGcidReceipt>,
    by_inode: std::collections::HashMap<u64, Vec<usize>>,
    complete: bool,
}

impl DuplicateGcidReceiptIndex {
    pub fn gcid_for(&self, output: &Path, metadata: &std::fs::Metadata) -> Option<String> {
        use std::os::unix::fs::MetadataExt;
        if !self.complete { return duplicate_gcid_from_receipts(output, metadata); }
        // Inode is only a lookup hint. Copied files and other mount views can
        // have different inodes, so a miss searches the other receipt bindings.
        self.by_inode.get(&metadata.ino()).into_iter().flatten()
            .find_map(|&position| self.receipts[position].gcid_for(output, metadata))
            .or_else(|| self.receipts.iter().filter(|entry| entry.receipt.local.inode != metadata.ino())
                .find_map(|entry| entry.gcid_for(output, metadata)))
    }
}

fn duplicate_receipt_entries(parent: &Path) -> Option<std::fs::ReadDir> {
    let directory = parent.join(".myclouddriver-downloads");
    if !std::fs::symlink_metadata(&directory).is_ok_and(|meta| meta.is_dir() && !meta.file_type().is_symlink()) { return None; }
    std::fs::read_dir(directory).ok()
}

fn read_duplicate_gcid_receipt(entry: std::io::Result<std::fs::DirEntry>) -> Option<DuplicateGcidReceipt> {
    use std::os::unix::fs::OpenOptionsExt;
    let entry = entry.ok()?;
    let filename = entry.file_name(); let name = filename.to_str()?;
    if name.len() != 69 || !name.ends_with(".json") || !name.as_bytes()[..64].iter().all(u8::is_ascii_hexdigit) { return None; }
    if !entry.file_type().ok()?.is_file() { return None; }
    let file = std::fs::OpenOptions::new().read(true)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32).open(entry.path()).ok()?;
    let metadata = file.metadata().ok()?;
    if metadata.len() > 64 * 1024 { return None; }
    // JSON's stream reader requests one byte at a time. Buffer the bounded
    // receipt stream so those requests do not become individual read syscalls.
    let reader = std::io::BufReader::new(file.take(64 * 1024 + 1));
    let receipt: Receipt = serde_json::from_reader(reader).ok()?;
    if receipt.source.scope.len() > 512 || receipt.source.file_id.len() > 512 { return None; }
    Some(DuplicateGcidReceipt { filename, recorded: metadata.modified().ok()?, receipt })
}

/// Memory pressure and index size affect caching only, never GCID availability.
pub(crate) fn duplicate_gcid_from_receipts(output: &Path, metadata: &std::fs::Metadata) -> Option<String> {
    use std::os::unix::fs::MetadataExt;
    duplicate_receipt_entries(output.parent()?)?.filter_map(read_duplicate_gcid_receipt)
        .filter_map(|entry| {
            let gcid = entry.gcid_for(output, metadata)?;
            Some(((entry.receipt.local.inode == metadata.ino(), entry.recorded, std::cmp::Reverse(entry.filename)), gcid))
        }).max_by(|a, b| a.0.cmp(&b.0)).map(|(_, gcid)| gcid)
}

pub(crate) fn duplicate_gcid_receipts(parent: &Path) -> DuplicateGcidReceiptIndex {
    let mut index = DuplicateGcidReceiptIndex { receipts: vec![], by_inode: std::collections::HashMap::new(), complete: true };
    if let Some(entries) = duplicate_receipt_entries(parent) {
        for entry in entries {
            if index.receipts.len() >= 4096 || crate::download_buffer::memory_pressure() >= 2 {
                index.complete = false;
                break;
            }
            if let Some(receipt) = read_duplicate_gcid_receipt(entry) {
                index.receipts.push(receipt);
            }
        }
    }
    // Prefer the matching inode when available, and the latest completed
    // receipt if a filename has been downloaded from several cloud sources.
    index.receipts.sort_by(|a, b| b.recorded.cmp(&a.recorded).then_with(|| a.filename.cmp(&b.filename)));
    for (position, receipt) in index.receipts.iter().enumerate() {
        index.by_inode.entry(receipt.receipt.local.inode).or_default().push(position);
    }
    index
}

/// A source-bound route never replaces the selected destination. An intent
/// without recorded ownership cannot adopt a partial file left at this name.
#[derive(Serialize, Deserialize)]
struct RecoveryPublication {
    output_name: PathBuf,
    owned: bool,
}

/// On filesystems without exclusive rename or hard links, the original is
/// retained until this separately owned destination has been fully committed.
#[derive(Serialize, Deserialize)]
struct CopyPublication {
    partial_name: PathBuf,
    output: Identity,
    durable_bytes: u64,
    prefix_sha256: String,
}

#[derive(Serialize, Deserialize)]
struct PublicationPointer {
    version: u32,
    source: Source,
    original: Identity,
    sha256: String,
}

fn publication_pointer_path(partial: &Path) -> PathBuf {
    crate::download_names::sidecar(partial, ".publication.json")
}

fn save_publication_pointer(partial: &Path, receipt: &Receipt) -> Result<()> {
    let pointer_path = publication_pointer_path(partial);
    if let Some(previous) = load_publication_pointer(partial)? {
        if previous.version != 1
            || previous.source != receipt.source
            || !previous.original.same_inode_size(&receipt.local)
            || previous.sha256 != receipt.sha256
        {
            bail!("Download publication belongs to another source; it was preserved");
        }
    }
    download_fs::atomic_write(
        &pointer_path,
        &serde_json::to_vec(&PublicationPointer {
            version: 1,
            source: receipt.source.clone(),
            original: receipt.local.clone(),
            sha256: receipt.sha256.clone(),
        })?,
    )?;
    Ok(())
}

fn load_publication_pointer(partial: &Path) -> Result<Option<PublicationPointer>> {
    match download_fs::read(&publication_pointer_path(partial)) {
        Ok(bytes) => Ok(Some(
            serde_json::from_slice(&bytes)
                .context("Download publication pointer is damaged; it was preserved")?,
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn remove_publication_pointer(partial: &Path) -> Result<()> {
    match download_fs::remove_file(&publication_pointer_path(partial)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

/// Called only after the partial's selection/root ownership guards succeed.
/// The pointer supplies the source, never an arbitrary destination or receipt
/// path. An unrecorded or changed destination is preserved with the staging.
pub fn cancel_pending_publication(partial: &Path, file_id: &str, _transfer_id: &str) -> Result<()> {
    let Some(pointer) = load_publication_pointer(partial)? else {
        return Ok(());
    };
    if pointer.version != 1 || pointer.source.file_id != file_id {
        bail!("Download publication belongs to another source; cancellation preserved it");
    }
    let filename = partial
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_suffix(".part"))
        .context("Invalid publication staging filename")?;
    let output = partial.with_file_name(filename);
    let receipt_path = path(&output, &pointer.source)?;
    let receipt = load(&receipt_path)?
        .context("Download publication ownership is missing; cancellation preserved it")?;
    if receipt.version != 1 || receipt.source != pointer.source {
        bail!("Download publication receipt changed; cancellation preserved it");
    }
    let actual_output = receipt_output(&output, &receipt)?;
    if receipt.committed {
        // A completed destination is never deleted by Cancel.
        let mut original = match download_fs::open(partial, rustix::fs::OFlags::RDONLY) {
            Ok(original) => original,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return remove_publication_pointer(partial)
            }
            Err(error) => return Err(error.into()),
        };
        if !pointer
            .original
            .same_inode_size(&Identity::read(&original.metadata()?)?)
            || checksum(&mut original, "")? != pointer.sha256
        {
            bail!("Committed download staging changed; cancellation preserved it");
        }
        download_fs::validate_open_file(partial, &original.metadata()?)?;
        return remove_publication_pointer(partial);
    }
    if receipt.recovery.as_ref().is_some_and(|route| !route.owned) {
        match download_fs::metadata(partial) {
            Ok(_) if !full_pending_copy_staging_matches(&output, &receipt, "")? => {
                bail!("Unowned download recovery staging changed; cancellation preserved it");
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        // An unowned crash artifact, and the original conflicting output,
        // belong to neither this cancellation nor its cleanup worker.
        download_fs::remove_file(&receipt_path)?;
        return remove_publication_pointer(partial);
    }
    match download_fs::metadata(&actual_output) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
        Ok(_) => {
            let copy = receipt.copy.as_ref().context(
                "Download copy ownership was not recorded; cancellation preserved the destination",
            )?;
            if copy_partial_path(&output, copy)? != partial {
                bail!("Download publication staging changed; cancellation preserved it");
            }
            let mut original = download_fs::open(partial, rustix::fs::OFlags::RDONLY)?;
            download_fs::validate_open_file(partial, &original.metadata()?)?;
            if !pointer
                .original
                .same_inode_size(&Identity::read(&original.metadata()?)?)
                || checksum(&mut original, "")? != pointer.sha256
            {
                bail!("Download publication staging changed; cancellation preserved it");
            }
            // A cancelled control is deliberately not passed into this bounded
            // cleanup read; the typed Cancel must allow its own cleanup.
            let (destination, _) = verify_copy_prefix(
                &actual_output,
                &mut original,
                &receipt,
                "",
                rustix::fs::OFlags::RDONLY,
            )?;
            download_fs::validate_open_file(partial, &original.metadata()?)?;
            download_fs::validate_open_file(&actual_output, &destination.metadata()?)?;
            download_fs::remove_file(&actual_output)?;
            download_fs::sync_parent(&actual_output)?;
        }
    }
    download_fs::remove_file(&receipt_path)?;
    remove_publication_pointer(partial)
}

#[derive(Default)]
struct FinishOptions {
    #[cfg(test)]
    force_copy: bool,
    #[cfg(test)]
    fault: CopyFault,
}

#[cfg(test)]
#[derive(Clone, Copy, Default)]
enum CopyFault {
    #[default]
    None,
    BeforeOwnership,
    AfterBytes(u64),
    AfterCopyBeforeCommit,
    ChangeBeforePublication,
    StaleWriterInodeAfterBytes(u64),
    ReplaceDestinationDuringCopy(u64),
    ChangeDuringCopy {
        at: u64,
        original: bool,
        bytes: bool,
    },
}

impl FinishOptions {
    fn stale_writer_snapshot(
        &self,
        destination_identity: &mut Identity,
        receipt: &mut Receipt,
        position: u64,
    ) {
        #[cfg(test)]
        if matches!(self.fault, CopyFault::StaleWriterInodeAfterBytes(_)) && position == 0 {
            destination_identity.inode ^= 1;
            receipt.copy.as_mut().unwrap().output.inode ^= 1;
        }
        let _ = (destination_identity, receipt, position);
    }
    fn before_copy_chunk(&self, partial: &Path, output: &Path, position: u64) -> Result<()> {
        #[cfg(test)]
        if matches!(self.fault, CopyFault::ReplaceDestinationDuringCopy(at) if position == at) {
            let replacement = output.with_file_name("generated-concurrent-copy-replacement.bin");
            std::fs::write(&replacement, b"reserved")?;
            std::fs::rename(replacement, output)?;
        }
        #[cfg(test)]
        if let CopyFault::ChangeDuringCopy {
            at,
            original,
            bytes,
        } = self.fault
        {
            if position == at {
                let changed = if original { partial } else { output };
                let mut file = download_fs::open(changed, rustix::fs::OFlags::RDWR)?;
                if bytes {
                    file.write_all(b"CHANGED!")?;
                } else {
                    let modified = file.metadata()?.modified()? + std::time::Duration::from_secs(5);
                    file.set_times(std::fs::FileTimes::new().set_modified(modified))?;
                }
            }
        }
        let _ = (partial, output, position);
        Ok(())
    }
    fn force_copy(&self) -> bool {
        #[cfg(test)]
        {
            self.force_copy
        }
        #[cfg(not(test))]
        {
            false
        }
    }
    fn copy_limit(&self, position: u64, available: usize) -> usize {
        #[cfg(test)]
        if let CopyFault::AfterBytes(limit) | CopyFault::StaleWriterInodeAfterBytes(limit) =
            self.fault
        {
            return available.min(limit.saturating_sub(position) as usize);
        }
        let _ = position;
        available
    }
    fn before_ownership(&self) -> Result<()> {
        #[cfg(test)]
        if matches!(self.fault, CopyFault::BeforeOwnership) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Generated copy ownership interruption",
            )
            .into());
        }
        Ok(())
    }
    fn after_bytes(&self, position: u64) -> Result<()> {
        #[cfg(test)]
        if matches!(self.fault, CopyFault::AfterBytes(limit) | CopyFault::StaleWriterInodeAfterBytes(limit) if position >= limit)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Generated copy interruption",
            )
            .into());
        }
        let _ = position;
        Ok(())
    }
    fn before_commit(&self) -> Result<()> {
        #[cfg(test)]
        if matches!(self.fault, CopyFault::AfterCopyBeforeCommit) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Generated copy commit interruption",
            )
            .into());
        }
        Ok(())
    }
}

fn path(output: &Path, source: &Source) -> Result<PathBuf> {
    let name = output
        .file_name()
        .context("Invalid output filename")?
        .to_string_lossy()
        .nfd()
        .collect::<String>()
        .to_lowercase()
        .nfd()
        .collect::<String>();
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    digest.update(name.as_bytes());
    digest.update(&serde_json::to_vec(source)?);
    Ok(output
        .parent()
        .unwrap_or(Path::new("."))
        .join(".myclouddriver-downloads")
        .join(format!("{}.json", hex::encode(digest.finish()))))
}

fn load(path: &Path) -> Result<Option<Receipt>> {
    match download_fs::read(path) {
        Ok(bytes) => Ok(Some(
            serde_json::from_slice(&bytes)
                .context("Download receipt is damaged; it was preserved")?,
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn save(path: &Path, receipt: &Receipt) -> Result<()> {
    download_fs::create_dir_all(path.parent().unwrap())?;
    validate_receipt_source(path, &receipt.source)?;
    download_fs::atomic_write(path, &serde_json::to_vec(receipt)?)?;
    Ok(())
}

fn validate_receipt_source(path: &Path, source: &Source) -> Result<()> {
    if let Some(previous) = load(path)? {
        if previous.version != 1 || previous.source != *source {
            bail!("Download receipt belongs to another source; it was preserved");
        }
    }
    Ok(())
}

fn check_control(transfer_id: &str) -> Result<()> {
    match crate::transfer_control::disk_action(transfer_id) {
        Some(crate::transfer_control::Action::Cancel) => {
            Err(crate::transfer_control::Cancelled.into())
        }
        Some(crate::transfer_control::Action::Pause) => Err(crate::transfer_control::Paused.into()),
        None => Ok(()),
    }
}

/// Called with the bytes read so far and the file's size while a whole file is verified, so the app can show
/// that work as verification instead of an idle transfer.
pub type VerifyProgress = std::sync::Arc<dyn Fn(u64, u64) + Send + Sync>;

/// Reports at the start, about twice a second, and at the end.
struct VerifyReporter<'a> {
    progress: Option<&'a VerifyProgress>,
    total: u64,
    last: Option<std::time::Instant>,
}
impl<'a> VerifyReporter<'a> {
    fn new(progress: Option<&'a VerifyProgress>, total: u64) -> Self {
        let mut reporter = Self {
            progress,
            total,
            last: None,
        };
        reporter.report(0, true);
        reporter
    }
    fn report(&mut self, done: u64, force: bool) {
        let Some(progress) = self.progress else {
            return;
        };
        if force
            || self
                .last
                .is_none_or(|last| last.elapsed() >= std::time::Duration::from_millis(500))
        {
            progress(done, self.total);
            self.last = Some(std::time::Instant::now());
        }
    }
}

fn checksum(file: &mut std::fs::File, transfer_id: &str) -> Result<String> {
    checksum_observed(file, transfer_id, None)
}

fn checksum_observed(
    file: &mut std::fs::File,
    transfer_id: &str,
    progress: Option<&VerifyProgress>,
) -> Result<String> {
    let mut diagnostic = crate::download_telemetry::Operation::new(
        crate::download_telemetry::Kind::FinalRead, transfer_id);
    let verification = crate::download_verification::acquire_blocking(file, transfer_id, file.metadata()?.len())
        .inspect_err(|error| { if error.is::<crate::download_verification::Deferred>() { diagnostic.deferred(); } })?;
    let before = Identity::read(&file.metadata()?)?;
    let mut reporter = VerifyReporter::new(progress, before.size);
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = vec![0; 256 * 1024];
    let mut done = 0u64;
    loop {
        check_control(transfer_id)?;
        let _read_turn = verification.as_ref().map(|guard| guard.chunk_blocking(buffer.len() as u64, transfer_id)).transpose()?;
        let n = file.read(&mut buffer)?;
        diagnostic.add_bytes(n as u64);
        #[cfg(test)]
        crate::download_transport::completion_tests::record_read(transfer_id, n as u64);
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
        done += n as u64;
        reporter.report(done, false);
    }
    if !before.same_file(&Identity::read(&file.metadata()?)?) {
        bail!("Download file changed while verifying completion");
    }
    reporter.report(done, true);
    diagnostic.complete();
    Ok(hex::encode(digest.finish()))
}

fn digest_hex(context: &ring::digest::Context) -> String {
    hex::encode(context.clone().finish())
}

fn cleanup_committed_staging(output: &Path, receipt: &Receipt, transfer_id: &str) -> Result<()> {
    cleanup_committed_staging_with_lease(output, receipt, transfer_id, None)
}

fn cleanup_committed_staging_with_lease(
    output: &Path,
    receipt: &Receipt,
    transfer_id: &str,
    lease: Option<&std::fs::File>,
) -> Result<()> {
    let mut partial_name = output.as_os_str().to_owned();
    partial_name.push(".part");
    let partial = PathBuf::from(partial_name);
    let Some(pointer) = load_publication_pointer(&partial)? else {
        return Ok(());
    };
    if pointer.version != 1 || pointer.source != receipt.source || pointer.sha256 != receipt.sha256
    {
        return Ok(());
    }
    // Completion checks run before main's normal writer claim. Do not let
    // crash cleanup delete another paused selection's shared staging.
    let claim = match lease {
        Some(lease) => crate::transfer_control::claim_partial_as_with_lease(
            &partial,
            &receipt.source.file_id,
            transfer_id,
            lease,
        ),
        None => crate::transfer_control::claim_partial_as(
            &partial,
            &receipt.source.file_id,
            transfer_id,
        ),
    };
    if claim.is_err() {
        return Ok(());
    }
    let mut original = match download_fs::open(&partial, rustix::fs::OFlags::RDONLY) {
        Ok(original) => original,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return remove_publication_pointer(&partial)
        }
        Err(error) => return Err(error.into()),
    };
    let before = Identity::read(&original.metadata()?)?;
    if !pointer.original.same_inode_size(&before)
        || checksum(&mut original, transfer_id)? != pointer.sha256
    {
        // Preserve a replaced/edited staging file even though the separate
        // destination has already been proven complete.
        return Ok(());
    }
    check_control(transfer_id)?;
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    if !before.same_file(&Identity::read(&original.metadata()?)?) {
        return Ok(());
    }
    download_fs::remove_file(&partial)?;
    remove_publication_pointer(&partial)
}

pub async fn cleanup_completed_staging_async_with_lease(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    lease: &std::fs::File,
) -> Result<()> {
    let output = output.to_owned();
    let source = source.clone();
    let transfer_id = transfer_id.to_owned();
    let lease = lease.try_clone()?;
    tokio::task::spawn_blocking(move || {
        let Some(receipt) = load(&path(&output, &source)?)? else {
            return Ok(());
        };
        if receipt.version != 1 || receipt.source != source || !receipt.committed {
            return Ok(());
        }
        let actual_output = receipt_output(&output, &receipt)?;
        if receipt.recovery.as_ref().is_some_and(|route| !route.owned)
            || Identity::read(&download_fs::metadata(&actual_output)?)? != receipt.local
        {
            return Ok(());
        }
        cleanup_committed_staging_with_lease(&output, &receipt, &transfer_id, Some(&lease))
    })
    .await
    .context("Download staging cleanup worker stopped")?
}

fn copy_partial_path(output: &Path, copy: &CopyPublication) -> Result<PathBuf> {
    if copy.partial_name.file_name() != Some(copy.partial_name.as_os_str()) {
        bail!("Download copy receipt has an invalid staging filename; it was preserved");
    }
    Ok(output
        .parent()
        .unwrap_or(Path::new("."))
        .join(&copy.partial_name))
}

fn valid_recovery_name(name: &Path) -> bool {
    let valid_name = name.to_str().is_some_and(|name| {
        name.rsplit_once(" (Recovered ")
            .is_some_and(|(stem, tail)| {
                !stem.is_empty()
                    && stem.len() <= 120
                    && tail.split_once(')').is_some_and(|(nonce, extension)| {
                        nonce.len() == 32
                            && nonce.bytes().all(|byte| byte.is_ascii_hexdigit())
                            && (extension.is_empty()
                                || extension.starts_with('.') && extension.len() <= 33)
                    })
            })
    });
    name.file_name() == Some(name.as_os_str()) && valid_name
}

fn receipt_output(output: &Path, receipt: &Receipt) -> Result<PathBuf> {
    let Some(recovery) = receipt.recovery.as_ref() else {
        return Ok(output.to_owned());
    };
    let name = &recovery.output_name;
    if !valid_recovery_name(name) {
        bail!("Download recovery route is invalid; existing files were preserved");
    }
    let recovered = output.parent().unwrap_or(Path::new(".")).join(name);
    if crate::transfer_control::same_output(output, &recovered)? {
        bail!("Download recovery route refers to the original destination; it was preserved");
    }
    let mut partial_name = output.as_os_str().to_owned();
    partial_name.push(".part");
    let partial = PathBuf::from(partial_name);
    for protected in [
        partial.clone(),
        publication_pointer_path(&partial),
        crate::download_names::sidecar(&partial, ".resume.json"),
        path(output, &receipt.source)?,
        output
            .parent()
            .unwrap_or(Path::new("."))
            .join(".myclouddriver-downloads"),
    ] {
        if crate::transfer_control::same_output(&protected, &recovered)? {
            bail!(
                "Download recovery route overlaps protected staging or metadata; it was preserved"
            );
        }
    }
    if let Some(copy) = receipt.copy.as_ref() {
        if crate::transfer_control::same_output(&copy_partial_path(output, copy)?, &recovered)? {
            bail!("Download recovery route overlaps staging; it was preserved");
        }
    }
    Ok(recovered)
}

fn recovery_name(output: &Path) -> Result<PathBuf> {
    use ring::rand::SecureRandom;
    let mut nonce = [0; 16];
    ring::rand::SystemRandom::new()
        .fill(&mut nonce)
        .map_err(|_| anyhow::anyhow!("Cannot allocate an exclusive download recovery name"))?;
    let mut stem = output
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or("Download")
        .to_owned();
    while stem.len() > 120 {
        stem.pop();
    }
    let extension = output
        .extension()
        .and_then(|name| name.to_str())
        .filter(|name| name.len() <= 32);
    let name = format!(
        "{stem} (Recovered {}){}",
        hex::encode(nonce),
        extension
            .map(|extension| format!(".{extension}"))
            .unwrap_or_default()
    );
    Ok(name.into())
}

/// The caller has independently verified the full, pointer-bound original.
/// Journal intent precedes exclusive creation; an unowned crash artifact is
/// preserved and a fresh name chosen. Neither original nor alternate payload
/// is overwritten to recover uncertain ownership.
fn prepare_recovery_copy(
    output: &Path,
    receipt_path: &Path,
    receipt: &mut Receipt,
    transfer_id: &str,
) -> Result<()> {
    for _ in 0..64 {
        check_control(transfer_id)?;
        let candidate = match receipt.recovery.as_ref().filter(|route| !route.owned) {
            Some(_) => receipt_output(output, receipt)?,
            None => {
                receipt.recovery = Some(RecoveryPublication {
                    output_name: recovery_name(output)?,
                    owned: false,
                });
                save(receipt_path, receipt)?;
                receipt_output(output, receipt)?
            }
        };
        let destination = match download_fs::open(
            &candidate,
            rustix::fs::OFlags::RDWR | rustix::fs::OFlags::CREATE | rustix::fs::OFlags::EXCL,
        ) {
            Ok(destination) => destination,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                receipt.recovery = None;
                continue;
            }
            Err(error) => {
                return Err(error).context(
                    "Cannot create an exclusive recovery copy; existing files were preserved",
                )
            }
        };
        destination.sync_data()?;
        download_fs::validate_open_file(&candidate, &destination.metadata()?)?;
        let local = Identity::read(&destination.metadata()?)?;
        if local.size != 0 {
            bail!("Exclusive recovery copy changed before recording ownership; it was preserved");
        }
        let copy = receipt
            .copy
            .as_mut()
            .context("Missing recovery staging ownership")?;
        copy.output = local;
        copy.durable_bytes = 0;
        copy.prefix_sha256 = hex::encode(ring::digest::digest(&ring::digest::SHA256, &[]));
        receipt.recovery.as_mut().unwrap().owned = true;
        download_fs::sync_parent(&candidate)?;
        check_control(transfer_id)?;
        save(receipt_path, receipt)?;
        return Ok(());
    }
    bail!("Cannot reserve a unique download recovery copy; existing files were preserved")
}

fn valid_copy(receipt: &Receipt, copy: &CopyPublication, local: &Identity) -> bool {
    copy.output.inode == local.inode && valid_copy_shape(receipt, copy, local)
}

fn valid_copy_shape(receipt: &Receipt, copy: &CopyPublication, local: &Identity) -> bool {
    copy.durable_bytes == copy.output.size
        && copy.durable_bytes <= local.size
        && local.size <= receipt.local.size
        && hex::decode(&copy.prefix_sha256).is_ok_and(|digest| digest.len() == 32)
        && hex::decode(&receipt.sha256).is_ok_and(|digest| digest.len() == 32)
}

fn birth_timestamp(metadata: &std::fs::Metadata) -> Option<i128> {
    let created = metadata.created().ok()?;
    match created.duration_since(std::time::UNIX_EPOCH) {
        Ok(duration) => i128::try_from(duration.as_nanos()).ok(),
        Err(error) => i128::try_from(error.duration().as_nanos())
            .ok()
            .map(|value| -value),
    }
}

fn is_exfat_file(file: &std::fs::File) -> std::io::Result<bool> {
    #[cfg(target_os = "macos")]
    {
        let filesystem = rustix::fs::fstatfs(file)?;
        let name: Vec<u8> = filesystem
            .f_fstypename
            .iter()
            .copied()
            .take_while(|byte| *byte != 0)
            .map(|byte| byte as u8)
            .collect();
        Ok(name.eq_ignore_ascii_case(b"exfat"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = file;
        Ok(false)
    }
}

fn legacy_prefix_digest(
    original: &mut std::fs::File,
    destination: &mut std::fs::File,
    bytes: u64,
    transfer_id: &str,
) -> Result<ring::digest::Context> {
    check_control(transfer_id)?;
    original.rewind()?;
    destination.rewind()?;
    let mut expected = vec![0; bytes as usize];
    let mut actual = vec![0; bytes as usize];
    original.read_exact(&mut expected)?;
    destination.read_exact(&mut actual)?;
    check_control(transfer_id)?;
    if expected != actual {
        conflict!("Download copy prefix changed; destination and staging were preserved");
    }
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    digest.update(&actual);
    Ok(digest)
}

/// Call only with the identity proven by a full source-bound staging checksum.
/// Old ExFAT copies recorded an empty inode before its first allocation sync.
/// Exact creation provenance and all existing bytes must be verified before
/// refreshing that initial checkpoint. No payload is changed by this repair.
fn reconcile_initial_exfat_copy(
    output: &Path,
    original: &mut std::fs::File,
    verified_original: &Identity,
    receipt_path: &Path,
    receipt: &mut Receipt,
    transfer_id: &str,
    filesystem_is_exfat: &impl Fn(&std::fs::File) -> std::io::Result<bool>,
) -> Result<bool> {
    let Some(copy) = receipt.copy.as_ref() else {
        return Ok(false);
    };
    if receipt.committed
        || receipt.source.revision.is_none()
        || receipt.source.size != receipt.local.size
        || copy.durable_bytes != 0
        || copy.output.size != 0
        || copy.output.modified != copy.output.changed
        || !copy
            .prefix_sha256
            .eq_ignore_ascii_case(&hex::encode(ring::digest::digest(
                &ring::digest::SHA256,
                &[],
            )))
    {
        return Ok(false);
    }
    let partial = copy_partial_path(output, copy)?;
    let Some(pointer) = load_publication_pointer(&partial)? else {
        return Ok(false);
    };
    if pointer.version != 1
        || pointer.source != receipt.source
        || pointer.sha256 != receipt.sha256
        || !pointer.original.same_inode_size(verified_original)
        || !receipt.local.same_inode_size(verified_original)
    {
        return Ok(false);
    }
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    if !verified_original.same_file(&Identity::read(&original.metadata()?)?) {
        return Ok(false);
    }
    let mut destination = download_fs::open(output, rustix::fs::OFlags::RDONLY)?;
    let metadata = destination.metadata()?;
    let before = Identity::read(&metadata)?;
    download_fs::validate_open_file(output, &metadata)?;
    if before.inode == copy.output.inode
        || before.device != copy.output.device
        || before.size == 0
        || before.size > 256 * 1024
        || before.size >= receipt.local.size
        || birth_timestamp(&metadata) != Some(copy.output.modified)
        || !filesystem_is_exfat(&destination)?
    {
        return Ok(false);
    }
    let creation = copy.output.modified;
    legacy_prefix_digest(original, &mut destination, before.size, transfer_id)?;
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    download_fs::validate_open_file(output, &destination.metadata()?)?;
    if !verified_original.same_file(&Identity::read(&original.metadata()?)?)
        || !before.same_file(&Identity::read(&destination.metadata()?)?)
    {
        conflict!("Download copy changed while verifying legacy progress; it was preserved");
    }
    destination
        .sync_data()
        .context("Cannot sync verified legacy copy progress; staging was preserved")?;
    // A sync can itself update ExFAT's inode. Bind the current path to this
    // continuously held descriptor and re-read every byte after that sync.
    let synced_metadata = destination.metadata()?;
    let synced = Identity::read(&synced_metadata)?;
    download_fs::validate_open_file(output, &synced_metadata)?;
    if !before.same_device_size(&synced) || birth_timestamp(&synced_metadata) != Some(creation) {
        conflict!("Download copy changed while syncing legacy progress; it was preserved");
    }
    let digest = legacy_prefix_digest(original, &mut destination, synced.size, transfer_id)?;
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    download_fs::validate_open_file(output, &destination.metadata()?)?;
    if !verified_original.same_file(&Identity::read(&original.metadata()?)?)
        || !synced.same_file(&Identity::read(&destination.metadata()?)?)
    {
        conflict!("Download copy changed after syncing legacy progress; it was preserved");
    }
    check_control(transfer_id)?;
    let copy = receipt.copy.as_mut().unwrap();
    copy.output = synced;
    copy.durable_bytes = copy.output.size;
    copy.prefix_sha256 = digest_hex(&digest);
    save(receipt_path, receipt)?;
    Ok(true)
}

/// A stale recorded destination identity is not sufficient to resume writes.
/// It may nevertheless describe already complete bytes. Before recognizing
/// those bytes read-only, independently prove the retained, source-bound
/// original and its publication pointer. No unverified output is truncated.
fn full_pending_copy_staging_matches(
    output: &Path,
    receipt: &Receipt,
    transfer_id: &str,
) -> Result<bool> {
    let Some(copy) = receipt.copy.as_ref() else {
        return Ok(false);
    };
    let partial = copy_partial_path(output, copy)?;
    let Some(pointer) = load_publication_pointer(&partial)? else {
        return Ok(false);
    };
    if pointer.version != 1
        || pointer.source != receipt.source
        || pointer.sha256 != receipt.sha256
        || !pointer.original.same_inode_size(&receipt.local)
    {
        return Ok(false);
    }
    let mut original = match download_fs::open(&partial, rustix::fs::OFlags::RDONLY) {
        Ok(original) => original,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    let before = Identity::read(&original.metadata()?)?;
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    if !receipt.local.same_inode_size(&before) || !pointer.original.same_inode_size(&before) {
        return Ok(false);
    }
    if checksum(&mut original, transfer_id)? != receipt.sha256 {
        return Ok(false);
    }
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    Ok(before.same_file(&Identity::read(&original.metadata()?)?))
}

/// Verify only recorded bytes. A crash may have left an uncommitted tail; it
/// can be discarded after the owned inode and its durable prefix are proven.
fn verify_copy_prefix(
    output: &Path,
    original: &mut std::fs::File,
    receipt: &Receipt,
    transfer_id: &str,
    flags: rustix::fs::OFlags,
) -> Result<(std::fs::File, ring::digest::Context)> {
    let copy = receipt
        .copy
        .as_ref()
        .context("Missing download copy ownership")?;
    let mut destination = download_fs::open(output, flags)?;
    let _verification = crate::download_verification::acquire_pair_blocking(original, &destination, transfer_id)?;
    let before = Identity::read(&destination.metadata()?)?;
    download_fs::validate_open_file(output, &destination.metadata()?)?;
    if !valid_copy(receipt, copy, &before) {
        conflict!("Download copy destination changed; it was preserved");
    }
    let original_before = Identity::read(&original.metadata()?)?;
    if !receipt.local.same_inode_size(&original_before) {
        conflict!(
            "Download copy staging file changed; it was preserved ({} differs from the recorded copy)",
            receipt.local.difference(&original_before)
        );
    }
    original.rewind()?;
    destination.rewind()?;
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    let mut original_buffer = vec![0; 256 * 1024];
    let mut destination_buffer = vec![0; 256 * 1024];
    let mut remaining = copy.durable_bytes;
    while remaining > 0 {
        check_control(transfer_id)?;
        let length = remaining.min(original_buffer.len() as u64) as usize;
        original.read_exact(&mut original_buffer[..length])?;
        destination.read_exact(&mut destination_buffer[..length])?;
        if original_buffer[..length] != destination_buffer[..length] {
            conflict!("Download copy prefix changed; destination and staging were preserved");
        }
        digest.update(&destination_buffer[..length]);
        remaining -= length as u64;
    }
    if digest_hex(&digest) != copy.prefix_sha256
        || !before.same_file(&Identity::read(&destination.metadata()?)?)
        || !original_before.same_file(&Identity::read(&original.metadata()?)?)
    {
        conflict!("Download copy changed while verifying progress; it was preserved");
    }
    download_fs::validate_open_file(output, &destination.metadata()?)?;
    Ok((destination, digest))
}

fn pending_copy_available(output: &Path, source: &Source, transfer_id: &str) -> Result<bool> {
    pending_copy_available_with_recovery(output, source, transfer_id, &is_exfat_file, true)
}

fn nonregular_destination(error: &std::io::Error) -> bool {
    error
        .get_ref()
        .is_some_and(|cause| cause.is::<download_fs::NonRegularFile>())
}

#[cfg(test)]
fn pending_copy_available_with_filesystem(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    filesystem_is_exfat: &impl Fn(&std::fs::File) -> std::io::Result<bool>,
) -> Result<bool> {
    pending_copy_available_with_recovery(output, source, transfer_id, filesystem_is_exfat, false)
}

fn pending_copy_available_with_recovery(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    filesystem_is_exfat: &impl Fn(&std::fs::File) -> std::io::Result<bool>,
    allow_recovery: bool,
) -> Result<bool> {
    let receipt_path = path(output, source)?;
    let Some(mut receipt) = load(&receipt_path)? else {
        return Ok(false);
    };
    if receipt.version != 1
        || receipt.source != *source
        || receipt.committed
        || receipt.copy.is_none()
    {
        return Ok(false);
    }
    receipt_output(output, &receipt)?;
    let partial = copy_partial_path(output, receipt.copy.as_ref().unwrap())?;
    let mut expected_partial = output.as_os_str().to_owned();
    expected_partial.push(".part");
    if partial != PathBuf::from(expected_partial) {
        conflict!("Download recovery staging route changed; existing files were preserved");
    }
    let mut original = download_fs::open(&partial, rustix::fs::OFlags::RDONLY)?;
    let original_before = Identity::read(&original.metadata()?)?;
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    if !receipt.local.same_inode_size(&original_before) {
        conflict!(
            "Download copy staging file changed; it was preserved ({} differs from the recorded copy)",
            receipt.local.difference(&original_before)
        );
    }
    if checksum(&mut original, transfer_id)? != receipt.sha256 {
        conflict!("Download copy staging file changed; it was preserved (its contents differ from the recorded copy)");
    }
    let verified_original = Identity::read(&original.metadata()?)?;
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    if !original_before.same_file(&verified_original) {
        conflict!("Download copy staging changed during verification; it was preserved");
    }
    let pointer_matches = load_publication_pointer(&partial)?.is_some_and(|pointer| {
        pointer.version == 1
            && pointer.source == receipt.source
            && pointer.sha256 == receipt.sha256
            && pointer.original.same_inode_size(&verified_original)
    });
    let recovery_allowed = allow_recovery
        && pointer_matches
        && receipt.source.revision.is_some()
        && receipt.source.size == receipt.local.size
        && (receipt.recovery.is_some() || filesystem_is_exfat(&original)?);
    // A planned route has no partial-file ownership until its EXCL creation
    // is synced and journaled. Preserve any crash artifact at that name.
    if receipt.recovery.as_ref().is_some_and(|route| !route.owned) && recovery_allowed {
        prepare_recovery_copy(output, &receipt_path, &mut receipt, transfer_id)?;
    }
    let prefix = (|| {
        if receipt.recovery.is_none() {
            reconcile_initial_exfat_copy(
                output,
                &mut original,
                &verified_original,
                &receipt_path,
                &mut receipt,
                transfer_id,
                filesystem_is_exfat,
            )?;
        }
        let actual_output = receipt_output(output, &receipt)?;
        verify_copy_prefix(
            &actual_output,
            &mut original,
            &receipt,
            transfer_id,
            rustix::fs::OFlags::RDONLY,
        )
    })();
    if let Err(error) = prefix {
        let current = Identity::read(&original.metadata()?)?;
        download_fs::validate_open_file(&partial, &original.metadata()?)?;
        let pointer_matches = load_publication_pointer(&partial)?.is_some_and(|pointer| {
            pointer.version == 1
                && pointer.source == receipt.source
                && pointer.sha256 == receipt.sha256
                && pointer.original.same_inode_size(&verified_original)
        });
        if verified_original.same_file(&current) && pointer_matches {
            let unavailable = error.downcast_ref::<std::io::Error>().is_some_and(|error| {
                error.kind() != std::io::ErrorKind::NotFound
                    && error.raw_os_error() != Some(rustix::io::Errno::LOOP.raw_os_error())
                    && !nonregular_destination(error)
            });
            if recovery_allowed
                && !unavailable
                && !error.is::<crate::transfer_control::Paused>()
                && !error.is::<crate::transfer_control::Cancelled>()
                && !error.is::<crate::transfer_control::Retry>()
                && !error.is::<crate::download_verification::Deferred>()
            {
                prepare_recovery_copy(output, &receipt_path, &mut receipt, transfer_id)?;
                let actual_output = receipt_output(output, &receipt)?;
                verify_copy_prefix(
                    &actual_output,
                    &mut original,
                    &receipt,
                    transfer_id,
                    rustix::fs::OFlags::RDONLY,
                )?;
                download_fs::validate_open_file(&partial, &original.metadata()?)?;
                if !verified_original.same_file(&Identity::read(&original.metadata()?)?) {
                    bail!("Download staging changed while preparing recovery; both files were preserved");
                }
                return Ok(true);
            }
            let failure = format!("{error:#}");
            return Err(error.context(VerifiedStagingProgress {
                downloaded_bytes: verified_original.size,
                total_bytes: receipt.local.size,
                failure,
            }));
        }
        return Err(error);
    }
    download_fs::validate_open_file(&partial, &original.metadata()?)?;
    if !verified_original.same_file(&Identity::read(&original.metadata()?)?) {
        bail!("Download staging changed after progress verification; it was preserved");
    }
    Ok(true)
}

/// Missing legacy receipts or unknown remote revisions cannot establish that
/// a same-size file is the selected original.
#[cfg(test)]
pub fn completed(output: &Path, source: &Source) -> Result<bool> {
    completed_with_control(output, source, "")
}

fn completed_with_control(output: &Path, source: &Source, transfer_id: &str) -> Result<bool> {
    completed_observed(output, source, transfer_id, None)
}

fn completed_observed(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    progress: Option<&VerifyProgress>,
) -> Result<bool> {
    let receipt_path = path(output, source)?;
    let Some(mut receipt) = load(&receipt_path)? else {
        return Ok(false);
    };
    if receipt.version != 1 || receipt.source != *source {
        return Ok(false);
    }
    let actual_output = receipt_output(output, &receipt)?;
    if receipt.recovery.as_ref().is_some_and(|route| !route.owned) {
        return Ok(false);
    }
    let metadata = match download_fs::metadata(&actual_output) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error)
            if (error.raw_os_error() == Some(rustix::io::Errno::LOOP.raw_os_error())
                || nonregular_destination(&error))
                && !receipt.committed
                && receipt.copy.is_some() =>
        {
            return Ok(false)
        }
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file() && !receipt.committed && receipt.copy.is_some() {
        return Ok(false);
    }
    let local = Identity::read(&metadata)?;
    if source.revision.is_none() {
        return Ok(false);
    }
    if receipt.version != 1
        || receipt.source != *source
        || (source.size > 0 && local.size != source.size)
    {
        return Ok(false);
    }
    if receipt.committed {
        if receipt.local == local {
            cleanup_committed_staging(output, &receipt, transfer_id)?;
            return Ok(true);
        }
        // A remount changes the device number, and a backup restored onto another or a reformatted disk
        // changes the inode and times too. Identity cannot tell a copy of the download from another file, so
        // the bytes decide: the same size and the receipt's checksum, verified below before the receipt is
        // rebound to this file. Different bytes are never adopted.
        if receipt.local.size != local.size {
            return Ok(false);
        }
        // A file that metadata alone vouches for needs no read of the whole file, which matters for a restored
        // library of many large files: an untouched file, or a copy that kept its modification time as Finder,
        // `cp -p` and rsync do. Anything else is verified by its bytes below.
        if receipt.local.vouched_by_metadata(&local) {
            // The receipt is left as it is: rewriting it would cost the destination disk a temporary file, a
            // sync and a rename for every restored file, and the next check accepts it from metadata again.
            cleanup_committed_staging(output, &receipt, transfer_id)?;
            return Ok(true);
        }
    } else if let Some(copy) = &receipt.copy {
        if !valid_copy_shape(&receipt, copy, &local) || local.size != receipt.local.size {
            return Ok(false);
        }
        if copy.output.inode != local.inode
            && !full_pending_copy_staging_matches(output, &receipt, transfer_id)?
        {
            return Ok(false);
        }
    } else if !receipt.local.same_inode_metadata(&local) {
        // Crash between publishing and recording completion: only this
        // receipt's inode and verified bytes can be adopted. Publication can
        // change ctime, and a later remount can change the device number.
        return Ok(false);
    }
    let mut file = download_fs::open(&actual_output, rustix::fs::OFlags::RDONLY)?;
    download_fs::validate_open_file(&actual_output, &file.metadata()?)?;
    if Identity::read(&file.metadata()?)? != local {
        return Ok(false);
    }
    if checksum_observed(&mut file, transfer_id, progress)? != receipt.sha256 {
        return Ok(false);
    }
    download_fs::validate_open_file(&actual_output, &file.metadata()?)?;
    file.sync_data()
        .context("Cannot sync verified download before recording completion")?;
    download_fs::sync_parent(&actual_output)?;
    receipt.local = local;
    receipt.committed = true;
    receipt.copy = None;
    save(&receipt_path, &receipt)?;
    cleanup_committed_staging(output, &receipt, transfer_id)?;
    Ok(true)
}

/// True only when a committed receipt vouches for the file at `output` from metadata alone: its identity is
/// unchanged, or its size and modification time are. It never reads or writes the file, so a library of many
/// finished files is skipped at the speed of a stat, without spending a download link on each.
fn completed_from_metadata(output: &Path, source: &Source, transfer_id: &str) -> Result<bool> {
    let receipt_path = path(output, source)?;
    let Some(receipt) = load(&receipt_path)? else {
        return Ok(false);
    };
    if receipt.version != 1
        || receipt.source != *source
        || !receipt.committed
        || source.revision.is_none()
        || receipt.recovery.as_ref().is_some_and(|route| !route.owned)
    {
        return Ok(false);
    }
    let actual_output = receipt_output(output, &receipt)?;
    let Ok(metadata) = download_fs::metadata(&actual_output) else {
        return Ok(false);
    };
    let Ok(local) = Identity::read(&metadata) else {
        return Ok(false);
    };
    if (source.size > 0 && local.size != source.size) || !receipt.local.vouched_by_metadata(&local) {
        return Ok(false);
    }
    cleanup_committed_staging(output, &receipt, transfer_id)?;
    Ok(true)
}

/// The completed output when the metadata check above vouches for it; otherwise nothing, and the caller
/// takes the full route.
pub async fn completed_without_reading(
    output: &Path,
    source: &Source,
    transfer_id: &str,
) -> Result<Option<PathBuf>> {
    let output = output.to_owned();
    let source = source.clone();
    let transfer_id = transfer_id.to_owned();
    tokio::task::spawn_blocking(move || {
        if completed_from_metadata(&output, &source, &transfer_id)? {
            Ok(Some(published_output(&output, &source)?))
        } else {
            Ok(None)
        }
    })
    .await
    .context("Download receipt check worker stopped")?
}

/// Older saved queue entries can omit the GCID. Recover the completed receipt
/// for this exact account, source ID and size before requesting another URL.
/// This uses the download completion metadata checks, not the duplicate
/// scanner's assumption that all receipted contents remain unchanged.
pub async fn completed_source_from_history(
    output: &Path,
    scope: &str,
    file_id: &str,
    size: u64,
) -> Result<Option<Source>> {
    let (output, scope, file_id) = (output.to_owned(), scope.to_owned(), file_id.to_owned());
    tokio::task::spawn_blocking(move || {
        if !download_fs::metadata(&output).is_ok_and(|metadata| metadata.is_file()) { return Ok(None); }
        let Some(entries) = output.parent().and_then(duplicate_receipt_entries) else { return Ok(None) };
        for entry in entries.filter_map(read_duplicate_gcid_receipt) {
            let receipt = &entry.receipt;
            let source = &receipt.source;
            let gcid = source.revision.as_deref().and_then(|value| value.strip_prefix("gcid:"));
            if receipt.version != 1 || !receipt.committed || source.scope != scope || source.file_id != file_id
                || source.size != size || !gcid.is_some_and(|value| value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
                || path(&output, source)?.file_name() != Some(entry.filename.as_os_str()) { continue; }
            if receipt.recovery.as_ref().is_some_and(|route| !route.owned) { continue; }
            let actual = receipt_output(&output, receipt)?;
            let Ok(metadata) = download_fs::metadata(&actual) else { continue };
            let Ok(current) = Identity::read(&metadata) else { continue };
            if current.size == size && receipt.local.vouched_by_metadata(&current) { return Ok(Some(source.clone())); }
        }
        Ok(None)
    }).await.context("Download history check worker stopped")?
}

pub async fn completed_with_unknown_revision(
    output: &Path, scope: &str, file_id: &str, size: u64, transfer_id: &str,
) -> Result<Option<(PathBuf, Source)>> {
    let Some(source) = completed_source_from_history(output, scope, file_id, size).await? else { return Ok(None) };
    // Revalidate under the caller's output lease before cleaning staging or
    // reporting completion; the earlier history lookup itself is read-only.
    Ok(completed_without_reading(output, &source, transfer_id).await?.map(|path| (path, source)))
}

#[cfg(test)]
pub fn ensure_available(output: &Path, source: &Source) -> Result<bool> {
    ensure_available_with_control(output, source, "")
}

#[cfg(test)]
fn ensure_available_with_control(
    output: &Path,
    source: &Source,
    transfer_id: &str,
) -> Result<bool> {
    ensure_available_observed(output, source, transfer_id, None)
}

fn ensure_available_observed(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    progress: Option<&VerifyProgress>,
) -> Result<bool> {
    if completed_observed(output, source, transfer_id, progress)? {
        return Ok(true);
    }
    if pending_copy_available(output, source, transfer_id)? {
        return Ok(false);
    }
    match download_fs::metadata(output) {
        Ok(destination) => {
            // A file restored from a backup may have lost its receipt. If the cloud's content hash says its bytes
            // are the original, it is the finished download. Anything else is preserved and reported.
            if adopt_by_content_hash(output, source, transfer_id, progress)? {
                return Ok(true);
            }
            conflict!(
                "Destination already contains a different or unverified file: {}. Choose another destination or preserve that file before retrying. ({})",
                output.display(),
                refusal_detail(output, source, &destination)
            )
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).context("Cannot safely inspect download destination"),
    }
}

/// Why a file at the destination could not be proven to be this download, in words that name no file, so a
/// screenshot of the refusal is enough to tell a lost receipt from a changed cloud version or a different file.
fn refusal_detail(output: &Path, source: &Source, destination: &std::fs::Metadata) -> String {
    let receipt = match path(output, source).and_then(|receipt| load(&receipt)) {
        Ok(Some(_)) => "a receipt exists but does not vouch for this file",
        Ok(None) => "no receipt for this file and cloud version",
        Err(_) => "its receipt is unreadable",
    };
    let revision = match source.revision.as_deref() {
        Some(revision) if revision.starts_with("gcid:") => "content hash",
        Some(_) => "modified time only",
        None => "none",
    };
    let size = if destination.len() == source.size {
        "same size"
    } else {
        "different size"
    };
    format!("{receipt}; cloud revision: {revision}; {size}")
}

/// SHA-256 and PikPak GCID of the whole file in one read.
fn content_digests(
    file: &mut std::fs::File,
    size: u64,
    transfer_id: &str,
    progress: Option<&VerifyProgress>,
) -> Result<(String, String)> {
    let verification = crate::download_verification::acquire_blocking(file, transfer_id, size)?;
    let before = Identity::read(&file.metadata()?)?;
    let mut reporter = VerifyReporter::new(progress, before.size);
    let mut sha256 = ring::digest::Context::new(&ring::digest::SHA256);
    let mut gcid = pikpak::upload::GcidHasher::new(size);
    let mut buffer = vec![0; 256 * 1024];
    let mut done = 0u64;
    loop {
        check_control(transfer_id)?;
        let _read_turn = verification.as_ref().map(|guard| guard.chunk_blocking(buffer.len() as u64, transfer_id)).transpose()?;
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        sha256.update(&buffer[..count]);
        gcid.update(&buffer[..count]);
        done += count as u64;
        reporter.report(done, false);
    }
    if !before.same_file(&Identity::read(&file.metadata()?)?) {
        bail!("Download file changed while verifying completion");
    }
    reporter.report(done, true);
    Ok((hex::encode(sha256.finish()), gcid.finish()))
}

/// Records an existing destination file as this download's completed output when its content hash is the
/// source's own GCID and its size matches. Only a content-bound revision can prove that; a time-based or
/// unknown one cannot, and a same-size file is never assumed to be the original.
fn adopt_by_content_hash(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    progress: Option<&VerifyProgress>,
) -> Result<bool> {
    let Some(expected) = source
        .revision
        .as_deref()
        .and_then(|revision| revision.strip_prefix("gcid:"))
    else {
        return Ok(false);
    };
    if source.size == 0 {
        return Ok(false);
    }
    let Ok(mut file) = download_fs::open(output, rustix::fs::OFlags::RDONLY) else {
        return Ok(false);
    };
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() != source.size {
        return Ok(false);
    }
    download_fs::validate_open_file(output, &metadata)?;
    let local = Identity::read(&metadata)?;
    let (sha256, gcid) = content_digests(&mut file, source.size, transfer_id, progress)?;
    if !gcid.eq_ignore_ascii_case(expected) {
        return Ok(false);
    }
    download_fs::validate_open_file(output, &file.metadata()?)?;
    if Identity::read(&file.metadata()?)? != local {
        return Ok(false);
    }
    save(
        &path(output, source)?,
        &Receipt {
            version: 1,
            source: source.clone(),
            local,
            sha256,
            committed: true,
            copy: None,
            recovery: None,
        },
    )?;
    Ok(true)
}

fn published_output(output: &Path, source: &Source) -> Result<PathBuf> {
    let receipt =
        load(&path(output, source)?)?.context("Download completion receipt is missing")?;
    if receipt.version != 1
        || receipt.source != *source
        || !receipt.committed
        || receipt.recovery.as_ref().is_some_and(|route| !route.owned)
    {
        bail!("Download completion route is not verified");
    }
    receipt_output(output, &receipt)
}

pub async fn ensure_available_path_async_with_control(
    output: &Path,
    source: &Source,
    transfer_id: &str,
) -> Result<Option<PathBuf>> {
    ensure_available_path_async_observed(output, source, transfer_id, None).await
}

/// As above, reporting progress while a whole file has to be read to verify it.
pub async fn ensure_available_path_async_observed(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    progress: Option<VerifyProgress>,
) -> Result<Option<PathBuf>> {
    let output = output.to_owned();
    let source = source.clone();
    let transfer_id = transfer_id.to_owned();
    tokio::task::spawn_blocking(move || {
        if ensure_available_observed(&output, &source, &transfer_id, progress.as_ref())? {
            Ok(Some(published_output(&output, &source)?))
        } else {
            Ok(None)
        }
    })
    .await
    .context("Download receipt verification worker stopped")?
}

/// The normal download runner owns the selected output and replaces conflicting
/// regular files automatically. Verification still skips matching completed
/// files, and a healthy staging copy survives a stale publication receipt.
pub async fn ensure_available_path_async_replacing(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    progress: Option<VerifyProgress>,
    lease: Option<&std::fs::File>,
) -> Result<Option<PathBuf>> {
    let output = output.to_owned();
    let source = source.clone();
    let transfer_id = transfer_id.to_owned();
    let lease = lease.map(std::fs::File::try_clone).transpose()?;
    tokio::task::spawn_blocking(move || {
        let available = match ensure_available_observed(
            &output, &source, &transfer_id, progress.as_ref(),
        ) {
            Err(error) if error.is::<pikpak::download_policy::LocalFileConflict>()
                || (error.downcast_ref::<std::io::Error>().is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound)
                    && load(&path(&output, &source)?)?.is_some_and(|receipt|
                        receipt.version == 1 && receipt.source == source && !receipt.committed && receipt.copy.is_some())) => {
                reset_conflicting_download(&output, &source, &transfer_id, lease.as_ref())?;
                println!("Removed conflicting local download files; retrying automatically: {}", output.display());
                ensure_available_observed(&output, &source, &transfer_id, progress.as_ref())?
            }
            result => result?,
        };
        if available {
            Ok(Some(published_output(&output, &source)?))
        } else {
            Ok(None)
        }
    })
    .await
    .context("Download conflict recovery worker stopped")?
}

fn reset_conflicting_download(
    output: &Path,
    source: &Source,
    transfer_id: &str,
    lease: Option<&std::fs::File>,
) -> Result<()> {
    check_control(transfer_id)?;
    download_fs::validate(output)?;
    let mut partial_name = output.as_os_str().to_owned();
    partial_name.push(".part");
    let partial = PathBuf::from(partial_name);
    if let Some(lease) = lease {
        crate::transfer_control::claim_partial_as_with_lease(&partial, &source.file_id, transfer_id, lease)?;
    } else {
        crate::transfer_control::claim_partial_as(&partial, &source.file_id, transfer_id)?;
    }
    let receipt_path = path(output, source)?;
    let receipt = load(&receipt_path)?;
    let mut remove = vec![output.to_owned()];
    let mut discard_partial = false;
    if let Some(receipt) = &receipt {
        anyhow::ensure!(receipt.version == 1 && receipt.source == *source,
            "Cannot reset a download receipt belonging to another source");
        let actual_output = receipt_output(output, receipt)?;
        if receipt.recovery.as_ref().is_some_and(|route| route.owned) {
            remove.push(actual_output);
        }
        if let Some(copy) = &receipt.copy {
            anyhow::ensure!(copy_partial_path(output, copy)? == partial,
                "Cannot reset a download with a different staging route");
            // Restoring a disk can change the staging inode without changing
            // its bytes. Keep those bytes if the source-bound digest proves them.
            match download_fs::open(&partial, rustix::fs::OFlags::RDONLY) {
                Ok(mut original) => {
                    let before = Identity::read(&original.metadata()?)?;
                    download_fs::validate_open_file(&partial, &original.metadata()?)?;
                    discard_partial = before.size != receipt.local.size
                        || checksum(&mut original, transfer_id)? != receipt.sha256;
                    download_fs::validate_open_file(&partial, &original.metadata()?)?;
                    anyhow::ensure!(before == Identity::read(&original.metadata()?)?,
                        "Download staging changed during conflict recovery; retrying later");
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => discard_partial = true,
                Err(error) => return Err(error.into()),
            }
        }
    }
    let pointer_path = publication_pointer_path(&partial);
    if let Some(pointer) = load_publication_pointer(&partial)? {
        anyhow::ensure!(pointer.version == 1 && pointer.source == *source,
            "Cannot reset download publication metadata belonging to another source");
        remove.push(pointer_path);
    }
    if discard_partial {
        remove.push(partial.clone());
        for suffix in [".resume.json", ".ranges.json", ".ranges.data"] {
            remove.push(crate::download_names::sidecar(&partial, suffix));
        }
    }
    // Remove the receipt last. An interrupted cleanup can repeat from the same
    // source-bound journal without losing evidence about the staging copy.
    remove.push(receipt_path);
    let mut inspected = Vec::new();
    for path in remove {
        match download_fs::metadata(&path) {
            Ok(metadata) => inspected.push((path, Identity::read(&metadata)?)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("Cannot inspect conflicting download files; retrying later"),
        }
    }
    // Preflight every candidate before deleting anything. Directory-relative
    // no-follow I/O rejects symlinks, directories and replaced destination roots.
    for (path, before) in &inspected {
        check_control(transfer_id)?;
        anyhow::ensure!(*before == Identity::read(&download_fs::metadata(path)?)?,
            "A conflicting download file changed before cleanup; retrying later");
    }
    for (path, before) in inspected {
        check_control(transfer_id)?;
        anyhow::ensure!(before == Identity::read(&download_fs::metadata(&path)?)?,
            "A conflicting download file changed during cleanup; retrying later");
        download_fs::remove_file(&path)
            .context("Cannot delete conflicting download file; retrying automatically")?;
    }
    download_fs::sync_parent(output)?;
    Ok(())
}

/// Await the worker without dropping it on cancellation. It checks controls
/// during verification and immediately before its short atomic commit.
#[cfg(test)]
pub async fn finish(
    partial: &Path,
    output: &Path,
    source: Source,
    transfer_id: &str,
) -> Result<()> {
    finish_with_options(
        partial,
        output,
        source,
        transfer_id,
        FinishOptions::default(),
    )
    .await
}

#[cfg(test)]
pub async fn finish_resolved(
    partial: &Path,
    output: &Path,
    source: Source,
    transfer_id: &str,
) -> Result<PathBuf> {
    finish_resolved_verified(partial, output, source, transfer_id, None).await
}

/// Reuse a range download's in-process verification only while its exact file
/// revision still matches. A changed file or a restarted helper takes the
/// original full-checksum path.
pub async fn finish_resolved_verified(
    partial: &Path,
    output: &Path,
    source: Source,
    transfer_id: &str,
    verified: Option<crate::download_transport::VerifiedCompletion>,
) -> Result<PathBuf> {
    finish_with_verification(
        partial,
        output,
        source.clone(),
        transfer_id,
        FinishOptions::default(),
        verified,
    )
    .await?;
    published_output(output, &source)
}

#[cfg(test)]
async fn finish_with_options(
    partial: &Path,
    output: &Path,
    source: Source,
    transfer_id: &str,
    options: FinishOptions,
) -> Result<()> {
    finish_with_verification(partial, output, source, transfer_id, options, None).await
}

async fn finish_with_verification(
    partial: &Path,
    output: &Path,
    source: Source,
    transfer_id: &str,
    options: FinishOptions,
    verified: Option<crate::download_transport::VerifiedCompletion>,
) -> Result<()> {
    let partial = partial.to_owned();
    let output = output.to_owned();
    let transfer_id = transfer_id.to_owned();
    let pending = tokio::task::spawn_blocking(move || {
        use crate::download_telemetry::{Kind, Operation};
        download_fs::validate(&partial)?;
        let mut file = download_fs::open(&partial, rustix::fs::OFlags::RDONLY)?;
        download_fs::validate_open_file(&partial, &file.metadata()?)?;
        let metadata = file.metadata()?;
        let reused = verified
            .as_ref()
            .map(|proof| {
                proof.digest_if_unchanged(&metadata, &source.file_id, source.revision.as_deref())
            })
            .transpose()?
            .flatten();
        let already_durable = reused.is_some()
            && verified.as_ref().is_some_and(|proof| proof.durably_synced());
        if !already_durable {
            let mut timing = Operation::new(Kind::PublicationPayloadSync, &transfer_id);
            #[cfg(test)]
            crate::download_transport::completion_tests::record_publication_sync(&transfer_id);
            file.sync_data()
                .context("Cannot sync completed download before publication")?;
            timing.complete();
        }
        download_fs::validate_open_file(&partial, &file.metadata()?)?;
        let metadata = file.metadata()?;
        let local = Identity::read(&metadata)?;
        if source.size > 0 && source.size != local.size {
            bail!("Completed download has an unexpected size");
        }
        check_control(&transfer_id)?;
        // Even a sync can race an external writer. The reused digest must
        // still describe the exact retained descriptor after that wait.
        if reused.is_some() {
            verified.as_ref().unwrap().validate_unchanged(&metadata)?;
        }
        let verification_reused = reused.is_some();
        let sha256 = match reused {
            Some(digest) => digest,
            None => checksum(&mut file, &transfer_id)?,
        };
        if crate::download_transport::completed_digest(&partial, &source.file_id, local.size)?
            .is_some_and(|expected| expected != sha256)
        {
            bail!(
                "Completed download bytes changed before publication; staging file was preserved"
            );
        }
        // The legacy checksum path has no retained VerifiedCompletion. Bind
        // its proof to ctime too before awaiting a batched receipt save.
        if local != Identity::read(&file.metadata()?)? {
            bail!("Download staging file changed while verifying completion");
        }
        let receipt_path = path(&output, &source)?;
        if load(&receipt_path)?.is_some_and(|receipt| receipt.copy.is_some()) {
            // The same proof and recovery route apply to direct finalization
            // as to retries entering through destination availability.
            pending_copy_available(&output, &source, &transfer_id)?;
        }
        let previous = load(&receipt_path)?;
        let mut receipt = if let Some(previous) =
            previous.filter(|previous| previous.copy.is_some())
        {
            if previous.version != 1
                || previous.source != source
                || previous.committed
                || !previous.local.same_inode_size(&local)
                || previous.sha256 != sha256
                || copy_partial_path(&output, previous.copy.as_ref().unwrap())? != partial
            {
                bail!("Download copy staging or receipt changed; existing files were preserved");
            }
            previous
        } else {
            Receipt {
                version: 1,
                source,
                local,
                sha256,
                committed: false,
                copy: None,
                recovery: None,
            }
        };
        if receipt.copy.is_some() {
            let actual_output = receipt_output(&output, &receipt)?;
            return copy_publish(
                &partial,
                &actual_output,
                &mut file,
                &receipt_path,
                &mut receipt,
                &transfer_id,
                &options,
            ).map(|_| None);
        }
        Ok::<_, anyhow::Error>(Some(FinalPublication {
            partial, output, transfer_id, options, verified, verification_reused,
            file, identity: receipt.local.clone(), receipt_path, receipt,
        }))
    })
    .await
    .context("Download finalization worker stopped")??;
    let Some(pending) = pending else { return Ok(()); };
    let pending = save_final_receipt(pending).await?;
    let published = tokio::task::spawn_blocking(move || publish_final_receipt(pending))
        .await.context("Download publication worker stopped")??;
    if let Some(published) = published {
        // Publication has happened. Pause/Cancel must not interrupt recording
        // that outcome; the normal checkpoint coordinator finishes its save.
        save_final_receipt(published).await?;
    }
    Ok(())
}

/// Own the verified inode across the two asynchronous receipt commits.
/// `identity` includes ctime; only our controlled move replaces that binding.
struct FinalPublication {
    partial: PathBuf,
    output: PathBuf,
    transfer_id: String,
    options: FinishOptions,
    verified: Option<crate::download_transport::VerifiedCompletion>,
    verification_reused: bool,
    file: std::fs::File,
    identity: Identity,
    receipt_path: PathBuf,
    receipt: Receipt,
}

impl FinalPublication {
    fn payload_path(&self) -> &Path {
        if self.receipt.committed { &self.output } else { &self.partial }
    }
    fn validate_payload(&self) -> Result<std::fs::Metadata> {
        let metadata = self.file.metadata()?;
        download_fs::validate_open_file(self.payload_path(), &metadata)?;
        if self.identity != Identity::read(&metadata)? {
            bail!("Download staging file changed while saving its receipt");
        }
        Ok(metadata)
    }
}

async fn save_final_receipt(pending: FinalPublication) -> Result<FinalPublication> {
    use crate::download_telemetry::{Kind, Operation};
    let mut timing = Operation::new(
        if pending.receipt.committed { Kind::PublicationCommittedReceipt } else { Kind::PublicationPendingReceipt },
        &pending.transfer_id,
    );
    let (pending, file, metadata, bytes) = tokio::task::spawn_blocking(move || {
        let metadata = pending.validate_payload()?;
        download_fs::create_dir_all(pending.receipt_path.parent().unwrap())?;
        validate_receipt_source(&pending.receipt_path, &pending.receipt.source)?;
        let file = tokio::fs::File::from_std(pending.file.try_clone()?);
        let bytes = serde_json::to_vec(&pending.receipt)?;
        Ok::<_, anyhow::Error>((pending, file, metadata, bytes))
    }).await.context("Download receipt preparation stopped")??;
    let gate = crate::download_verification::WriteGate::new(&file, &pending.transfer_id);
    let guarded_path = pending.receipt_path.clone();
    let guarded_source = pending.receipt.source.clone();
    let precondition: download_fs::CheckpointPrecondition = std::sync::Arc::new(move || {
        validate_receipt_source(&guarded_path, &guarded_source).map_err(std::io::Error::other)
    });
    #[cfg(test)]
    batch_tests::before_receipt(&pending.transfer_id, pending.receipt.committed).await;
    if gate.key().is_some() {
        crate::download_checkpoint::commit_guarded(
            &gate, &file, metadata, pending.payload_path(), &pending.receipt_path, bytes, precondition,
        ).await?;
    } else {
        // Keep the existing SSD/network path: already durable data needs no
        // extra per-file payload sync merely to save its receipt.
        let path = pending.receipt_path.clone();
        tokio::task::spawn_blocking(move || {
            precondition()?;
            download_fs::atomic_write(&path, &bytes)
        })
            .await.context("Download receipt save stopped")??;
    }
    let pending = tokio::task::spawn_blocking(move || {
        pending.validate_payload()?;
        Ok::<_, anyhow::Error>(pending)
    }).await.context("Download receipt validation stopped")??;
    timing.complete();
    Ok(pending)
}

fn publish_final_receipt(pending: FinalPublication) -> Result<Option<FinalPublication>> {
    use crate::download_telemetry::{Kind, Operation};
    let FinalPublication {
        partial, output, transfer_id, options, verified, verification_reused,
        mut file, identity, receipt_path, mut receipt,
    } = pending;
    check_control(&transfer_id)?;
    #[cfg(test)]
    if matches!(options.fault, CopyFault::ChangeBeforePublication) {
        let modified = file.metadata()?.modified()?;
        std::fs::write(&partial, b"BAD-DATA")?;
        file.set_times(std::fs::FileTimes::new().set_modified(modified))?;
    }
    download_fs::validate_open_file(&partial, &file.metadata()?)?;
    if verification_reused {
        // Receipt writes can take time on an HDD. Reject even an edit
        // whose mtime was restored after we reused the earlier digest.
        verified
            .as_ref()
            .unwrap()
            .validate_unchanged(&file.metadata()?)?;
    }
    if identity != Identity::read(&file.metadata()?)? {
        bail!("Download staging file changed before publication");
    }
    let publication = {
        let mut timing = Operation::new(Kind::PublicationMove, &transfer_id);
        let result = if options.force_copy() {
            Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "Generated copy fallback",
            ))
        } else {
            download_fs::publish_no_replace(&partial, &output)
        };
        // An unsupported move is an unsuccessful move attempt even if
        // the existing copy fallback subsequently publishes the file.
        if result.is_ok() { timing.complete(); }
        result
    };
    if let Err(error) = publication {
        if download_fs::unsupported_operation(&error) {
            return copy_publish(
                &partial,
                &output,
                &mut file,
                &receipt_path,
                &mut receipt,
                &transfer_id,
                &options,
            ).map(|_| None);
        }
        return Err(error).context("Destination was preserved; cannot finalize download");
    }
    let published = Identity::read(&download_fs::metadata(&output)?)?;
    if !receipt.local.same_file(&published)
        || !published.same_file(&Identity::read(&file.metadata()?)?)
    {
        bail!("Download staging file changed during publication; destination was preserved");
    }
    receipt.local = published;
    receipt.committed = true;
    Ok(Some(FinalPublication {
        partial, output, transfer_id, options, verified, verification_reused,
        file, identity: receipt.local.clone(), receipt_path, receipt,
    }))
}

fn copy_checkpoint(
    output: &Path,
    destination: &std::fs::File,
    receipt_path: &Path,
    receipt: &mut Receipt,
    durable_bytes: u64,
    digest: &ring::digest::Context,
) -> Result<()> {
    download_fs::validate_open_file(output, &destination.metadata()?)?;
    destination
        .sync_data()
        .context("Cannot sync copied download; original staging was preserved")?;
    let local = Identity::read(&destination.metadata()?)?;
    // The retained writer's current path and exact length prove which object
    // was synced. Refresh the receipt instead of trusting a pre-write inode
    // snapshot, which need not be a permanent filesystem identifier.
    if local.size != durable_bytes {
        bail!("Download copy destination changed; original staging was preserved");
    }
    download_fs::validate_open_file(output, &destination.metadata()?)?;
    let copy = receipt.copy.as_mut().unwrap();
    copy.output = local;
    copy.durable_bytes = durable_bytes;
    copy.prefix_sha256 = digest_hex(digest);
    save(receipt_path, receipt)
}

fn copy_publish(
    partial: &Path,
    output: &Path,
    original: &mut std::fs::File,
    receipt_path: &Path,
    receipt: &mut Receipt,
    transfer_id: &str,
    options: &FinishOptions,
) -> Result<()> {
    check_control(transfer_id)?;
    download_fs::validate_open_file(partial, &original.metadata()?)?;
    let mut original_identity = Identity::read(&original.metadata()?)?;
    if !receipt.local.same_inode_size(&original_identity) {
        bail!("Download copy staging changed; existing files were preserved");
    }
    save_publication_pointer(partial, receipt)?;
    let (mut destination, mut digest) = if receipt.copy.is_some() {
        let (destination, digest) = verify_copy_prefix(
            output,
            original,
            receipt,
            transfer_id,
            rustix::fs::OFlags::RDWR,
        )?;
        let saved = receipt.copy.as_ref().unwrap().durable_bytes;
        // The durable prefix has been checked before dropping an interrupted
        // write's tail. Never truncate a replacement or a changed prefix.
        check_control(transfer_id)?;
        download_fs::validate_open_file(output, &destination.metadata()?)?;
        destination.set_len(saved)?;
        (destination, digest)
    } else {
        let destination = download_fs::open(
            output,
            rustix::fs::OFlags::RDWR | rustix::fs::OFlags::CREATE | rustix::fs::OFlags::EXCL,
        )
        .context("Destination was preserved; cannot create an exclusive download copy")?;
        options.before_ownership()?;
        download_fs::validate_open_file(output, &destination.metadata()?)?;
        let local = Identity::read(&destination.metadata()?)?;
        if local.size != 0 {
            bail!("New download copy changed before recording ownership; it was preserved");
        }
        receipt.copy = Some(CopyPublication {
            partial_name: partial
                .file_name()
                .context("Invalid staging filename")?
                .into(),
            output: local,
            durable_bytes: 0,
            prefix_sha256: hex::encode(ring::digest::digest(&ring::digest::SHA256, &[])),
        });
        destination.sync_data()?;
        download_fs::sync_parent(output)?;
        save(receipt_path, receipt)?;
        (
            destination,
            ring::digest::Context::new(&ring::digest::SHA256),
        )
    };
    let mut position = receipt.copy.as_ref().unwrap().durable_bytes;
    original.seek(SeekFrom::Start(position))?;
    destination.seek(SeekFrom::Start(position))?;
    let mut buffer = vec![0; 256 * 1024];
    let mut checkpoint_at = std::time::Instant::now();
    let mut checkpoint_bytes = position;
    let mut destination_identity = Identity::read(&destination.metadata()?)?;
    while position < receipt.local.size {
        check_control(transfer_id)?;
        options.before_copy_chunk(partial, output, position)?;
        options.stale_writer_snapshot(&mut destination_identity, receipt, position);
        download_fs::validate_open_file(partial, &original.metadata()?)?;
        download_fs::validate_open_file(output, &destination.metadata()?)?;
        // Timestamp changes alone do not prove that either payload changed.
        // Ownership and length stay strict during copying; both files' bytes
        // are independently verified before committing.
        if !original_identity.same_object_size(&Identity::read(&original.metadata()?)?)
            || !destination_identity.same_device_size(&Identity::read(&destination.metadata()?)?)
        {
            bail!("Download copy files changed; existing progress was preserved");
        }
        let available = (receipt.local.size - position).min(buffer.len() as u64) as usize;
        let length = options.copy_limit(position, available);
        if length == 0 {
            options.after_bytes(position)?;
            bail!("Download copy made no progress");
        }
        original.read_exact(&mut buffer[..length])?;
        destination.write_all(&buffer[..length]).context("Cannot copy completed download; original staging and saved copy progress were preserved")?;
        digest.update(&buffer[..length]);
        position += length as u64;
        destination_identity = Identity::read(&destination.metadata()?)?;
        let generated_fault = options.after_bytes(position);
        if position == receipt.local.size
            || position - checkpoint_bytes >= 16 * 1024 * 1024
            || checkpoint_at.elapsed() >= std::time::Duration::from_secs(1)
            || generated_fault.is_err()
        {
            copy_checkpoint(
                output,
                &destination,
                receipt_path,
                receipt,
                position,
                &digest,
            )?;
            checkpoint_at = std::time::Instant::now();
            checkpoint_bytes = position;
            destination_identity = Identity::read(&destination.metadata()?)?;
        }
        generated_fault?;
    }
    if !original_identity.same_object_size(&Identity::read(&original.metadata()?)?)
        || digest_hex(&digest) != receipt.sha256
    {
        bail!("Download staging changed while copying; both files were preserved");
    }
    // An edit behind the reader can leave the submitted copy digest intact.
    // Re-read the retained original too, so timestamp tolerance never allows
    // deleting modified staging merely because its copied bytes were valid.
    original.rewind()?;
    if checksum(original, transfer_id)? != receipt.sha256 {
        bail!("Download staging bytes changed while copying; both files were preserved");
    }
    download_fs::validate_open_file(partial, &original.metadata()?)?;
    let current_original = Identity::read(&original.metadata()?)?;
    if !original_identity.same_object_size(&current_original) {
        bail!("Download staging changed while verifying the copy; both files were preserved");
    }
    original_identity = current_original;
    // Reading the new inode verifies the persisted output, independently of
    // bytes submitted to its writer and before any completion is recorded.
    let verified_output = Identity::read(&destination.metadata()?)?;
    destination.rewind()?;
    if checksum(&mut destination, transfer_id)? != receipt.sha256
        || !verified_output.same_file(&Identity::read(&destination.metadata()?)?)
    {
        bail!("Download copy bytes changed before completion; both files were preserved");
    }
    copy_checkpoint(
        output,
        &destination,
        receipt_path,
        receipt,
        position,
        &digest,
    )?;
    download_fs::sync_parent(output)?;
    options.before_commit()?;
    check_control(transfer_id)?;
    download_fs::validate_open_file(output, &destination.metadata()?)?;
    let committed_output = Identity::read(&destination.metadata()?)?;
    if !verified_output.same_file(&committed_output) {
        bail!("Download copy changed after verification; both files were preserved");
    }
    receipt.local = committed_output;
    receipt.committed = true;
    receipt.copy = None;
    save(receipt_path, receipt)?;
    // Publication is durable now. A changed/replaced original is preserved;
    // it must never be removed merely because another inode was committed.
    download_fs::validate_open_file(partial, &original.metadata()?)?;
    if !original_identity.same_file(&Identity::read(&original.metadata()?)?) {
        bail!("Download committed, but staging changed; staging was preserved");
    }
    download_fs::remove_file(partial)?;
    remove_publication_pointer(partial)?;
    Ok(())
}

#[cfg(test)]
#[path = "download_receipt_copy_tests.rs"]
mod copy_tests;

#[cfg(test)]
#[path = "download_receipt_batch_tests.rs"]
mod batch_tests;

#[cfg(test)]
#[path = "download_receipt_identity_tests.rs"]
mod identity_tests;

#[cfg(test)]
#[path = "download_receipt_recovery_tests.rs"]
mod recovery_tests;

#[cfg(test)]
#[path = "download_receipt_restore_tests.rs"]
mod restore_tests;

#[cfg(all(test, target_os = "macos"))]
#[path = "download_disk_fixture.rs"]
mod disk_fixture;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_receipts_trust_recorded_gcid_but_require_the_bound_filename() {
        let root = tempfile::tempdir().unwrap(); let output = root.path().join("generated.bin");
        let bytes = b"abcdefgh"; std::fs::write(&output, bytes).unwrap();
        let mut hasher = pikpak::upload::GcidHasher::new(bytes.len() as u64); hasher.update(bytes);
        let gcid = hasher.finish();
        let source = Source { scope: "generated-account".into(), file_id: "generated-file".into(),
            revision: Some(format!("gcid:{gcid}")), size: bytes.len() as u64 };
        let receipt = Receipt { version: 1, source: source.clone(),
            local: Identity::read(&std::fs::metadata(&output).unwrap()).unwrap(),
            sha256: hex::encode(ring::digest::digest(&ring::digest::SHA256, bytes)), committed: true,
            copy: None, recovery: None };
        save(&path(&output, &source).unwrap(), &receipt).unwrap();
        let receipts = duplicate_gcid_receipts(root.path()); assert_eq!(receipts.receipts.len(), 1);
        assert_eq!(receipts.gcid_for(&output, &std::fs::metadata(&output).unwrap()), Some(gcid.clone()));
        assert!(receipts.gcid_for(&root.path().join("renamed.bin"), &std::fs::metadata(&output).unwrap()).is_none());
        let incomplete = DuplicateGcidReceiptIndex { receipts: vec![], by_inode: std::collections::HashMap::new(), complete: false };
        assert_eq!(incomplete.gcid_for(&output, &std::fs::metadata(&output).unwrap()), Some(gcid.clone()),
            "an index truncated by pressure or capacity still finds the receipt by streaming");
        let modified = std::fs::metadata(&output).unwrap().modified().unwrap();
        std::fs::write(&output, b"xxxxxxxx").unwrap();
        std::fs::File::options().write(true).open(&output).unwrap().set_modified(modified).unwrap();
        assert_eq!(receipts.gcid_for(&output, &std::fs::metadata(&output).unwrap()), Some(gcid));
    }

    #[test]
    fn duplicate_receipts_ignore_recorded_identity_and_accept_only_completed_bound_routes() {
        let root = tempfile::tempdir().unwrap(); let output = root.path().join("generated.bin");
        let bytes = b"abcdefgh"; std::fs::write(&output, bytes).unwrap();
        let metadata = std::fs::metadata(&output).unwrap();
        let mut hasher = pikpak::upload::GcidHasher::new(bytes.len() as u64); hasher.update(bytes);
        let gcid = hasher.finish();
        let source = Source { scope: "generated-account".into(), file_id: "generated-file".into(),
            revision: Some(format!("gcid:{gcid}")), size: bytes.len() as u64 };
        let filename = path(&output, &source).unwrap().file_name().unwrap().to_owned();
        let local = Identity::read(&metadata).unwrap();
        let mut receipt = DuplicateGcidReceipt { filename, recorded: std::time::SystemTime::now(), receipt: Receipt {
            version: 1, source, local: local.clone(),
            sha256: hex::encode(ring::digest::digest(&ring::digest::SHA256, bytes)), committed: true,
            copy: None, recovery: None,
        } };
        receipt.receipt.local.device ^= 1;
        assert_eq!(receipt.gcid_for(&output, &metadata), Some(gcid.clone()));
        let remounted = receipt.receipt.local.clone();
        for field in 0..4 {
            receipt.receipt.local = remounted.clone();
            match field {
                0 => receipt.receipt.local.inode ^= 1,
                1 => receipt.receipt.local.size += 1,
                2 => receipt.receipt.local.modified += 1,
                _ => receipt.receipt.local.changed += 1,
            }
            assert_eq!(receipt.gcid_for(&output, &metadata), Some(gcid.clone()), "changed field {field}");
        }
        receipt.receipt.local = remounted;
        let modified = metadata.modified().unwrap();
        std::fs::write(&output, b"xxxxxxxx").unwrap();
        std::fs::File::options().write(true).open(&output).unwrap().set_modified(modified).unwrap();
        assert_eq!(receipt.gcid_for(&output, &std::fs::metadata(&output).unwrap()), Some(gcid.clone()));
        receipt.receipt.committed = false;
        assert!(receipt.gcid_for(&output, &metadata).is_none());
        receipt.receipt.committed = true;
        receipt.receipt.source.revision = Some("gcid:invalid".into());
        receipt.filename = path(&output, &receipt.receipt.source).unwrap().file_name().unwrap().to_owned();
        assert!(receipt.gcid_for(&output, &metadata).is_none());
        receipt.receipt.source.revision = Some(format!("gcid:{gcid}"));
        let recovered = root.path().join("generated (Recovered 00000000000000000000000000000001).bin");
        std::fs::write(&recovered, bytes).unwrap();
        receipt.receipt.recovery = Some(RecoveryPublication { output_name: recovered.file_name().unwrap().into(), owned: false });
        assert!(receipt.gcid_for(&recovered, &std::fs::metadata(&recovered).unwrap()).is_none());
        receipt.receipt.recovery.as_mut().unwrap().owned = true;
        assert_eq!(receipt.gcid_for(&recovered, &std::fs::metadata(&recovered).unwrap()), Some(gcid));
        assert!(receipt.gcid_for(&output, &metadata).is_none());
    }

    #[test]
    fn duplicate_receipt_index_and_streaming_choose_the_same_latest_bound_source() {
        let root = tempfile::tempdir().unwrap(); let output = root.path().join("generated.bin");
        std::fs::write(&output, b"abcdefgh").unwrap();
        let metadata = std::fs::metadata(&output).unwrap();
        for (index, gcid) in ["AB".repeat(20), "CD".repeat(20)].iter().enumerate() {
            let source = Source { scope: "generated-account".into(), file_id: format!("generated-{index}"),
                revision: Some(format!("gcid:{gcid}")), size: 8 };
            let mut local = Identity::read(&metadata).unwrap(); local.inode ^= 1;
            let receipt = Receipt { version: 1, source: source.clone(), local, sha256: "00".repeat(32),
                committed: true, copy: None, recovery: None };
            let receipt_path = path(&output, &source).unwrap(); save(&receipt_path, &receipt).unwrap();
            let recorded = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000 + index as u64);
            std::fs::File::options().write(true).open(&receipt_path).unwrap().set_modified(recorded).unwrap();
        }
        let expected = Some("CD".repeat(20));
        assert_eq!(duplicate_gcid_receipts(root.path()).gcid_for(&output, &metadata), expected);
        assert_eq!(duplicate_gcid_from_receipts(&output, &metadata), expected);
    }
    fn source(scope: &str, id: &str) -> Source {
        let file = serde_json::from_value(serde_json::json!({"id":id,"name":"file.bin","kind":"drive#file","size":"8","hash":"synthetic-revision"})).unwrap();
        Source::new(scope.into(), &file, 8)
    }

    #[tokio::test]
    async fn reused_verification_rejects_edits_while_the_receipt_is_saved_even_with_restored_mtime() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.bin.part");
        let output = directory.path().join("generated.bin");
        let verified = crate::download_transport::completion_tests::completed_fixture(
            directory.path(),
            "completion-publication-race",
        )
        .await;
        let mut original = source("account:fixture", "original");
        original.revision = Some("gcid:FIXTURE".into());
        let error = finish_with_verification(
            &partial,
            &output,
            original,
            "completion-publication-race",
            FinishOptions {
                force_copy: false,
                fault: CopyFault::ChangeBeforePublication,
            },
            Some(verified),
        )
        .await
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("changed after verifying progress"),
            "{error:#}"
        );
        assert!(!output.exists());
        assert_eq!(std::fs::read(partial).unwrap(), b"BAD-DATA");
    }

    #[tokio::test]
    async fn reused_verification_retains_copy_fallback_and_interrupted_copy_recovery() {
        for interrupted in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("generated.bin.part");
            let output = directory.path().join("generated.bin");
            let verified = crate::download_transport::completion_tests::completed_fixture(
                directory.path(),
                "completion-copy-fallback",
            )
            .await;
            let mut original = source("account:fixture", "original");
            original.revision = Some("gcid:FIXTURE".into());
            let result = finish_with_verification(
                &partial,
                &output,
                original.clone(),
                "completion-copy-fallback",
                FinishOptions {
                    force_copy: true,
                    fault: if interrupted {
                        CopyFault::AfterBytes(4)
                    } else {
                        CopyFault::None
                    },
                },
                Some(verified),
            )
            .await;
            if interrupted {
                assert!(result.is_err());
                assert_eq!(std::fs::read(&output).unwrap(), b"abcd");
                finish_with_options(
                    &partial,
                    &output,
                    original.clone(),
                    "completion-copy-fallback",
                    FinishOptions {
                        force_copy: true,
                        fault: CopyFault::None,
                    },
                )
                .await
                .unwrap();
            } else {
                result.unwrap();
            }
            assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
            assert!(completed(&output, &original).unwrap());
            assert!(!partial.exists());
        }
    }

    #[tokio::test]
    async fn staging_mutation_after_transfer_is_preserved_without_publication() {
        for (replacement, unknown_size) in [(false, false), (true, false), (false, true)] {
            let temp = tempfile::tempdir().unwrap();
            let output = temp.path().join("file.bin");
            let partial = temp.path().join("file.bin.part");
            std::fs::write(&partial, b"NEW-DATA").unwrap();
            crate::download_transport::seed_resume(&partial, "file-a", 8, "\"original\"");
            if replacement {
                let changed = temp.path().join("replacement");
                std::fs::write(&changed, b"BAD-DATA").unwrap();
                std::fs::rename(changed, &partial).unwrap();
            } else {
                std::fs::write(&partial, b"BAD-DATA").unwrap();
            }
            let mut original = source("account:fixture", "file-a");
            if unknown_size {
                original.size = 0;
            }
            let error = finish(
                &partial,
                &output,
                original.clone(),
                "receipt-integrity-fixture",
            )
            .await
            .unwrap_err();
            assert!(error.to_string().contains("bytes changed"));
            assert!(!output.exists());
            assert_eq!(std::fs::read(&partial).unwrap(), b"BAD-DATA");
            assert!(load(&path(&output, &original).unwrap()).unwrap().is_none());
        }
    }
    #[tokio::test]
    async fn unrelated_destinations_are_preserved_and_completed_receipts_are_source_bound() {
        let temp = tempfile::tempdir().unwrap();
        let output = temp.path().join("file.bin");
        let partial = temp.path().join("file.bin.part");
        let original = source("account:a", "file-a");
        std::fs::write(&output, b"OLD-DATA").unwrap();
        assert!(ensure_available(&output, &original).is_err());
        assert_eq!(std::fs::read(&output).unwrap(), b"OLD-DATA");
        std::fs::remove_file(&output).unwrap();
        std::fs::write(&partial, b"NEW-DATA").unwrap();
        finish(&partial, &output, original.clone(), "receipt-test")
            .await
            .unwrap();
        assert!(ensure_available(&output, &original).unwrap());
        assert!(ensure_available(&output, &source("account:b", "file-a")).is_err());
        assert!(ensure_available(&output, &source("account:a", "file-b")).is_err());
        let modified = std::fs::metadata(&output).unwrap().modified().unwrap();
        std::fs::write(&output, b"EDITED!!").unwrap();
        std::fs::File::options()
            .write(true)
            .open(&output)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert!(ensure_available(&output, &original).is_err());
    }

    #[tokio::test]
    async fn completed_receipt_follows_verified_bytes_across_remounts_and_restores() {
        let temp = tempfile::tempdir().unwrap();
        let output = temp.path().join("file.bin");
        let partial = temp.path().join("file.bin.part");
        let original = source("account:a", "file-a");
        std::fs::write(&partial, b"NEW-DATA").unwrap();
        finish(&partial, &output, original.clone(), "receipt-remount-test")
            .await
            .unwrap();
        let receipt_path = path(&output, &original).unwrap();
        let initial = std::fs::read(&receipt_path).unwrap();
        // A different size, or a checksum that the bytes do not match, is never the file on disk. The checksum
        // is read only when the time differs, because an equal size and time are what let a file be vouched for
        // without reading it.
        for field in ["size", "checksum"] {
            let mut receipt: Receipt = serde_json::from_slice(&initial).unwrap();
            receipt.local.device ^= 1;
            match field {
                "size" => receipt.local.size += 1,
                "checksum" => {
                    receipt.sha256 = "00".repeat(32);
                    receipt.local.modified += 1;
                }
                _ => unreachable!(),
            }
            save(&receipt_path, &receipt).unwrap();
            let before = std::fs::read(&receipt_path).unwrap();
            assert!(
                !completed(&output, &original).unwrap(),
                "accepted changed {field}"
            );
            assert_eq!(std::fs::read(&output).unwrap(), b"NEW-DATA");
            assert_eq!(std::fs::read(&receipt_path).unwrap(), before);
        }
        // A remount changes the device; a restored backup also changes the inode and times. The bytes still
        // match the receipt's checksum, so the receipt follows the file.
        for field in ["device", "inode", "modified", "changed"] {
            let mut receipt: Receipt = serde_json::from_slice(&initial).unwrap();
            receipt.local.device ^= 1;
            match field {
                "device" => {}
                "inode" => receipt.local.inode ^= 1,
                "modified" => receipt.local.modified += 1,
                "changed" => receipt.local.changed += 1,
                _ => unreachable!(),
            }
            save(&receipt_path, &receipt).unwrap();
            let before = std::fs::read(&receipt_path).unwrap();
            assert!(
                completed(&output, &original).unwrap(),
                "refused verified bytes with changed {field}"
            );
            let current = Identity::read(&std::fs::metadata(&output).unwrap()).unwrap();
            if field == "modified" || field == "changed" {
                // The same file with a moved time: its bytes were read, and the receipt now follows the file.
                assert_eq!(load(&receipt_path).unwrap().unwrap().local, current);
            } else {
                // Untouched, or a copy with the same size and time: accepted from metadata alone, without
                // rewriting the receipt.
                assert_eq!(std::fs::read(&receipt_path).unwrap(), before, "{field}");
            }
            assert_eq!(std::fs::read(&output).unwrap(), b"NEW-DATA");
            assert!(completed(&output, &original).unwrap());
        }
    }

    #[tokio::test]
    async fn pending_publication_survives_remount_only_for_verified_owned_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let output = temp.path().join("file.bin");
        let partial = temp.path().join("file.bin.part");
        let original = source("account:a", "file-a");
        std::fs::write(&partial, b"NEW-DATA").unwrap();
        std::fs::write(&output, b"LATE-DATA").unwrap();
        assert!(finish(
            &partial,
            &output,
            original.clone(),
            "receipt-remount-pending-test"
        )
        .await
        .is_err());
        std::fs::remove_file(&output).unwrap();
        download_fs::publish_no_replace(&partial, &output).unwrap();
        let receipt_path = path(&output, &original).unwrap();
        let mut pending = load(&receipt_path).unwrap().unwrap();
        assert!(!pending.committed);
        pending.local.device ^= 1;
        pending.local.changed = Identity::read(&std::fs::metadata(&output).unwrap())
            .unwrap()
            .changed
            + 1;
        let initial = serde_json::to_vec(&pending).unwrap();
        for field in ["inode", "size", "modified", "checksum"] {
            let mut receipt: Receipt = serde_json::from_slice(&initial).unwrap();
            match field {
                "inode" => receipt.local.inode ^= 1,
                "size" => receipt.local.size += 1,
                "modified" => receipt.local.modified += 1,
                "checksum" => receipt.sha256 = "00".repeat(32),
                _ => unreachable!(),
            }
            save(&receipt_path, &receipt).unwrap();
            let before = std::fs::read(&receipt_path).unwrap();
            assert!(
                !completed(&output, &original).unwrap(),
                "accepted changed {field}"
            );
            assert_eq!(std::fs::read(&output).unwrap(), b"NEW-DATA");
            assert_eq!(std::fs::read(&receipt_path).unwrap(), before);
        }
        save(&receipt_path, &pending).unwrap();
        assert!(completed(&output, &original).unwrap());
        let committed = load(&receipt_path).unwrap().unwrap();
        assert!(committed.committed);
        assert_eq!(
            committed.local,
            Identity::read(&std::fs::metadata(&output).unwrap()).unwrap()
        );
        assert_eq!(std::fs::read(&output).unwrap(), b"NEW-DATA");
    }

    #[tokio::test]
    async fn publication_conflicts_and_crash_recovery_preserve_the_selected_identity() {
        let temp = tempfile::tempdir().unwrap();
        let output = temp.path().join("file.bin");
        let partial = temp.path().join("file.bin.part");
        let original = source("account:a", "file-a");
        std::fs::write(&partial, b"NEW-DATA").unwrap();
        // Another program creates a destination after the initial check.
        assert!(!ensure_available(&output, &original).unwrap());
        std::fs::write(&output, b"LATE-DATA").unwrap();
        assert!(finish(&partial, &output, original.clone(), "receipt-test")
            .await
            .is_err());
        assert_eq!(std::fs::read(&output).unwrap(), b"LATE-DATA");
        assert_eq!(std::fs::read(&partial).unwrap(), b"NEW-DATA");
        assert!(!completed(&output, &original).unwrap());
        // Simulate the crash window after publication, before marking the
        // already prepared receipt as committed.
        std::fs::remove_file(&output).unwrap();
        download_fs::publish_no_replace(&partial, &output).unwrap();
        assert!(completed(&output, &original).unwrap());
        assert!(
            load(&path(&output, &original).unwrap())
                .unwrap()
                .unwrap()
                .committed
        );
    }
}

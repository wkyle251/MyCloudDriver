//! Out-of-order disk data has its own filename. Only a complete, flushed range
//! map can replace the legacy contiguous .part file.
use super::*;
use crate::{download_range_rejected, download_route_unavailable};
use pikpak::{
    download_network::Network,
    download_ranges::{self, State, Transfer},
};
use std::collections::BTreeMap;

#[derive(Serialize, Deserialize)]
struct Journal {
    version: u32,
    file_id: String,
    ranges: State,
    #[serde(default)]
    source_revision: Option<String>,
    #[serde(default)]
    require_content_hash: bool,
    #[serde(default)]
    source_key: Option<String>,
    #[serde(default)]
    piece_sha256: Option<Vec<String>>,
    /// The staging file as the checkpoint left it, synced. While it is unchanged a resume trusts the digests of
    /// complete pieces instead of reading them back.
    #[serde(default)]
    data_identity: Option<integrity::SavedIdentity>,
}

fn sibling(part: &Path, suffix: &str) -> PathBuf {
    crate::download_names::sidecar(part, suffix)
}
fn journal_path(part: &Path) -> PathBuf {
    sibling(part, ".ranges.json")
}
fn data_path(part: &Path) -> PathBuf {
    sibling(part, ".ranges.data")
}

fn length(path: &Path) -> anyhow::Result<Option<u64>> {
    match crate::download_fs::metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            Ok(Some(metadata.len()))
        }
        Ok(_) => anyhow::bail!("Download checkpoint is not a regular file"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub(super) fn exists(part: &Path) -> bool {
    [journal_path(part), data_path(part)]
        .iter()
        .any(|path| crate::download_fs::metadata(path).is_ok())
}

fn load(part: &Path, file_id: &str, total: u64) -> anyhow::Result<Option<Journal>> {
    let path = journal_path(part);
    let Some(size) = length(&path)? else {
        return Ok(None);
    };
    if size > 2 * 1024 * 1024 {
        return Ok(None);
    }
    let Ok(journal) = serde_json::from_slice::<Journal>(&crate::download_fs::read(&path)?) else {
        return Ok(None);
    };
    Ok((journal.version == 1
        && journal.file_id == file_id
        && journal.ranges.valid()
        && journal.ranges.total() == total)
        .then_some(journal))
}

async fn length_async(path: &Path) -> anyhow::Result<Option<u64>> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || length(&path)).await?
}

async fn remove_async(part: &Path) -> anyhow::Result<()> {
    let part = part.to_owned();
    tokio::task::spawn_blocking(move || remove(&part)).await?
}

fn save_with_hashes(
    part: &Path,
    file_id: &str,
    state: &State,
    source_revision: Option<&str>,
    require_content_hash: bool,
    source_key: Option<&str>,
    piece_sha256: Vec<String>,
    data_identity: Option<integrity::SavedIdentity>,
) -> anyhow::Result<()> {
    crate::download_fs::atomic_write(
        &journal_path(part),
        &serde_json::to_vec(&Journal {
            version: 1,
            file_id: file_id.into(),
            ranges: state.clone(),
            source_revision: source_revision.map(str::to_owned),
            require_content_hash,
            source_key: source_key.map(str::to_owned),
            piece_sha256: Some(piece_sha256),
            data_identity,
        })?,
    )?;
    Ok(())
}

async fn save_with_hashes_async(
    part: &Path,
    file_id: &str,
    state: &State,
    source_revision: Option<&str>,
    require_content_hash: bool,
    source_key: Option<&str>,
    piece_sha256: Vec<String>,
    data_identity: Option<integrity::SavedIdentity>,
) -> anyhow::Result<()> {
    let part = part.to_owned();
    let file_id = file_id.to_owned();
    let state = state.clone();
    let source_revision = source_revision.map(str::to_owned);
    let source_key = source_key.map(str::to_owned);
    // Atomic publication includes blocking disk flushes. Await the complete
    // commit without occupying an async worker or dropping it on Pause/Cancel.
    tokio::task::spawn_blocking(move || {
        save_with_hashes(
            &part,
            &file_id,
            &state,
            source_revision.as_deref(),
            require_content_hash,
            source_key.as_deref(),
            piece_sha256,
            data_identity,
        )
    })
    .await?
}

#[cfg(test)]
fn save_with_revision(
    part: &Path,
    file_id: &str,
    state: &State,
    source_revision: Option<&str>,
    require_content_hash: bool,
    source_key: Option<&str>,
) -> anyhow::Result<()> {
    let data = if length(&data_path(part))?.is_some() {
        data_path(part)
    } else {
        part.to_owned()
    };
    let hashes = state
        .covered_ranges()
        .map(|(_, offset, bytes)| {
            if bytes == 0 {
                integrity::Prefix::new().digest()
            } else {
                integrity::fixture_digest(&data, offset, bytes)
            }
        })
        .collect();
    save_with_hashes(
        part,
        file_id,
        state,
        source_revision,
        require_content_hash,
        source_key,
        hashes,
        None,
    )
}

async fn read_hashes(
    path: &Path,
    state: &State,
    control_id: &str,
) -> Result<Vec<integrity::Prefix>, DlError> {
    let regions: Vec<_> = state.covered_ranges().map(|(_, offset, bytes)| (offset, bytes, false)).collect();
    if regions.iter().all(|(_, bytes, _)| *bytes == 0) {
        return Ok(regions.iter().map(|_| integrity::Prefix::new()).collect());
    }
    integrity::Prefix::read_regions(path, &regions, control_id).await
}

/// The hashes a resume starts from, and how many bytes it had to read back from the staging file to get them.
struct RestoredHashes {
    hashes: Vec<integrity::Prefix>,
    bytes_read: u64,
}

/// Rebuilds each piece's hash for a resume. While the staging file is exactly as the last checkpoint left it
/// (`saved_identity`, recorded after the data was synced) a complete piece is not read back: its digest from the
/// journal stands for it, so pausing and resuming a large download does not read the whole file from the disk again.
/// Anything else is read and hashed as it always was: a journal without an identity, a file that changed in any way, and
/// every partial piece, which will keep growing.
async fn restore_hashes(
    path: &Path,
    state: &State,
    saved_digests: &[String],
    saved_identity: Option<&integrity::SavedIdentity>,
    control_id: &str,
) -> Result<RestoredHashes, DlError> {
    let metadata = crate::download_fs::metadata_async(path)
        .await
        .map_err(|error| fatal(error, "Cannot inspect saved download progress"))?;
    let unchanged = saved_identity.is_some_and(|saved| integrity::SavedIdentity::of(&metadata).as_ref() == Some(saved));
    let mut hashes = Vec::new();
    let mut regions = Vec::new();
    let mut bytes_read = 0u64;
    for (position, (index, offset, bytes)) in state.covered_ranges().enumerate() {
        let trusted = unchanged && state.piece_complete(index);
        hashes.push(match saved_digests.get(position) {
            _ if bytes == 0 => Some(integrity::Prefix::new()),
            Some(digest) if trusted => Some(integrity::Prefix::frozen(bytes, digest.clone(), &metadata)),
            _ => {
                bytes_read = bytes_read.checked_add(bytes)
                    .ok_or_else(|| DlError::Fatal(anyhow::anyhow!("Invalid saved download region coverage")))?;
                regions.push((offset, bytes, state.needs_eof_replay(index)));
                None
            }
        });
    }
    let mut restored_regions = integrity::Prefix::read_regions(path, &regions, control_id).await?.into_iter();
    let hashes: Vec<_> = hashes.into_iter().map(|hash| hash.unwrap_or_else(|| restored_regions.next().expect("one restored context per saved region"))).collect();
    // Complete-piece journal proofs were bound to the initial metadata, while
    // freshly read regions carry the reader's final identity. Both must still
    // identify this same staging entry before any context reaches a writer.
    let after = crate::download_fs::metadata_async(path).await
        .map_err(|error| fatal(error, "Cannot inspect verified download progress"))?;
    for hash in &hashes { hash.validate_restored(&after)?; }
    let restored = RestoredHashes { hashes, bytes_read };
    Ok(restored)
}

fn prefix_proof(state: &State, digests: &[String]) -> Vec<(u64, u64, String)> {
    let prefix = state.prefix();
    state
        .covered_ranges()
        .filter(|(_, offset, bytes)| *offset < prefix && *bytes > 0)
        .map(|(index, offset, bytes)| (offset, bytes, digests[index].clone()))
        .collect()
}

/// The one full pass over a finished download: every piece is compared with its digest before the file is finalized.
/// A resume believes the saved digests of complete pieces it did not read back, so a failure here means the file was
/// damaged without leaving a trace outside it. The journal then stops vouching for the file: the next attempt reads
/// everything back, sees which pieces no longer match, and fetches them again instead of failing the same way.
async fn verify_finished_staging(
    part: &Path,
    file_id: &str,
    total: u64,
    saved: ResumeState,
    proof: &[(u64, u64, String)],
    control_id: &str,
) -> Result<VerifiedCompletion, DlError> {
    let result = async {
        // Shutdown can leave a valid partial checkpoint. Honor its control
        // before applying the complete-file coverage requirement below.
        transfer_control::disk_interruptible(control_id, std::future::ready(()))
            .await.map_err(DlError::Fatal)?;
        let data = data_path(part);
        let hash = integrity::Prefix::read_verified(&data, total, proof, control_id).await?;
        VerifiedCompletion::from_durable_checkpoint(&data, part, saved, hash, control_id).await
    }.await;
    match result {
        Ok(verified) => Ok(verified),
        Err(error) => {
            // Stopping a queued/in-progress check is not evidence of damage.
            // Retain synced complete-piece proof for the next helper; it still
            // performs the mandatory final read-back before publication.
            let interrupted = match &error {
                DlError::Fatal(cause) | DlError::Retryable(cause) =>
                    cause.is::<transfer_control::Paused>() || cause.is::<transfer_control::Cancelled>()
                        || cause.is::<crate::download_verification::Deferred>(),
            };
            if !interrupted {
                // A control arriving during a failed check must not turn a
                // paused/cancelled attempt into journal invalidation work.
                transfer_control::disk_interruptible(control_id, std::future::ready(()))
                    .await.map_err(DlError::Fatal)?;
                withdraw_trust(part, file_id, total).await;
            }
            Err(error)
        }
    }
}

/// Rewrites the journal without the staging file's identity, so a resume verifies every piece.
async fn withdraw_trust(part: &Path, file_id: &str, total: u64) {
    let Ok(Some(journal)) = load(part, file_id, total) else { return };
    if journal.data_identity.is_none() {
        return;
    }
    let _ = save_with_hashes_async(
        part,
        file_id,
        &journal.ranges,
        journal.source_revision.as_deref(),
        journal.require_content_hash,
        journal.source_key.as_deref(),
        journal.piece_sha256.clone().unwrap_or_default(),
        None,
    )
    .await;
}

async fn save_serial_prefix(
    part: &Path,
    data: &Path,
    saved: ResumeState,
    proof: &[(u64, u64, String)],
    control_id: &str,
    retry_state: Option<&RetryState>,
) -> Result<integrity::Prefix, DlError> {
    let bytes = saved.durable_bytes.unwrap_or(0);
    let hash = if bytes == 0 {
        integrity::Prefix::new()
    } else {
        integrity::Prefix::read_verified(data, bytes, proof, control_id)
            .await?
    };
    save_verified_prefix(part, data, saved, hash, retry_state).await
}

async fn save_verified_prefix(
    part: &Path,
    data: &Path,
    mut saved: ResumeState,
    hash: integrity::Prefix,
    retry_state: Option<&RetryState>,
) -> Result<integrity::Prefix, DlError> {
    if saved.durable_bytes != Some(hash.bytes) {
        return Err(DlError::Fatal(anyhow::anyhow!("Verified checkpoint changed size")));
    }
    saved.prefix_sha256 = Some(hash.digest());
    saved.save_async(part).await.map_err(DlError::Fatal)?;
    if let Some(retry_state) = retry_state {
        retry_state.remember_verified_prefix(data, &saved, &hash).await;
    }
    Ok(hash)
}

#[cfg(test)]
fn save(part: &Path, file_id: &str, state: &State) -> anyhow::Result<()> {
    save_with_revision(part, file_id, state, None, false, None)
}

pub(super) fn remove(part: &Path) -> anyhow::Result<()> {
    for path in [data_path(part), journal_path(part)] {
        if length(&path)?.is_some() {
            crate::download_fs::remove_file(&path)?;
        }
    }
    Ok(())
}

pub(super) fn saved_bytes(part: &Path, file_id: &str, total: u64) -> Option<u64> {
    let journal = load(part, file_id, total).ok()??;
    let size = length(&data_path(part)).ok()??;
    (size >= journal.ranges.extent() && size <= total).then(|| journal.ranges.received())
}

fn error(error: download_ranges::Error) -> DlError {
    let error = anyhow::Error::new(error);
    if download_policy::retryable(&error) {
        DlError::Retryable(error)
    } else {
        DlError::Fatal(error)
    }
}

struct Buffer {
    offset: u64,
    chunks: Vec<bytes::Bytes>,
    bytes: usize,
    retained: Vec<crate::download_buffer::RetainedPayload>,
}
struct Writer {
    file: tokio::fs::File,
    write_gate: crate::download_verification::WriteGate,
    buffers: BTreeMap<usize, Buffer>,
    hashes: Vec<integrity::Prefix>,
    offsets: Vec<u64>,
    checkpointed: Option<State>,
    synced_identity: Option<integrity::SavedIdentity>,
    total: u64,
}
impl Writer {
    async fn flush_completed(&mut self, state: &State) -> std::io::Result<()> {
        while let Some(index) = self
            .buffers
            .iter()
            .filter(|(index, _)| state.piece_complete(**index))
            .min_by_key(|(_, buffer)| buffer.offset)
            .map(|(index, _)| *index)
        {
            self.flush_piece(index).await?;
        }
        Ok(())
    }
    #[cfg(test)]
    async fn push(&mut self, chunk: &download_ranges::Chunk) -> std::io::Result<()> {
        self.push_retaining(chunk, None).await
    }
    async fn push_retaining(&mut self, chunk: &download_ranges::Chunk,
        retained: Option<crate::download_buffer::RetainedPayload>) -> std::io::Result<()> {
        if self.offsets[chunk.index] + self.hashes[chunk.index].bytes != chunk.offset {
            return Err(std::io::Error::other("Non-contiguous range checksum"));
        }
        let buffer = self.buffers.entry(chunk.index).or_insert_with(|| Buffer {
            offset: chunk.offset,
            chunks: Vec::new(), bytes: 0, retained: Vec::new(),
        });
        if buffer.offset + buffer.bytes as u64 != chunk.offset {
            return Err(std::io::Error::other("Non-contiguous range write"));
        }
        // Retain the compact receive allocation instead of copying it into
        // a second, uncharged per-file allocation while disk I/O is waiting.
        buffer.chunks.push(chunk.bytes.clone()); buffer.bytes += chunk.bytes.len();
        if let Some(retained) = retained { buffer.retained.push(retained); }
        let full = buffer.bytes >= crate::download_buffer::range_write_batch(self.write_gate.key().is_some());
        let end = self.offsets.get(chunk.index + 1).copied().unwrap_or(self.total);
        if chunk.offset + chunk.bytes.len() as u64 == end {
            self.hashes[chunk.index].update_for_replay(&chunk.bytes);
            self.flush_piece(chunk.index).await?;
        } else {
            self.hashes[chunk.index].update(&chunk.bytes);
            if full { self.flush_piece(chunk.index).await?; }
        }
        Ok(())
    }
    #[cfg(test)]
    fn retain(&mut self, index: usize, payload: Option<crate::download_buffer::RetainedPayload>) {
        if let (Some(buffer), Some(payload)) = (self.buffers.get_mut(&index), payload) {
            buffer.retained.push(payload);
        }
        // A full buffer was already written inside push(), so its current
        // receive lease can be released immediately after successful I/O.
    }
    async fn flush_piece(&mut self, index: usize) -> std::io::Result<()> {
        let bytes = self.buffers.get(&index).map_or(0, |buffer| buffer.bytes);
        if bytes == 0 { return Ok(()); }
        crate::download_buffer::write_chunk(bytes, async {
            let write_turn = self.write_gate.turn(false).await;
            let mut diagnostic = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::PayloadWrite, self.write_gate.id());
            let _write_turn = self.flush_piece_in_turn(index, write_turn).await?;
            diagnostic.add_bytes(bytes as u64); diagnostic.complete(); Ok(())
        }).await
    }
    async fn flush_piece_in_turn<T: Send + 'static>(&mut self, index: usize, turn: T) -> std::io::Result<T> {
        if !self.buffers.contains_key(&index) { return Ok(turn); }
        // SSD/network destinations have no exclusive physical-disk turn.
        // Preserve their existing small Tokio write pipeline; only coordinated
        // drives need the larger positional batch and detached turn ownership.
        if self.write_gate.key().is_none() {
            let buffer = &self.buffers[&index];
            let bytes = if buffer.chunks.len() == 1 {
                std::borrow::Cow::Borrowed(buffer.chunks[0].as_ref())
            } else {
                let mut bytes = Vec::with_capacity(buffer.bytes);
                for chunk in &buffer.chunks { bytes.extend_from_slice(chunk); }
                std::borrow::Cow::Owned(bytes)
            };
            self.file.seek(SeekFrom::Start(buffer.offset)).await?;
            self.file.write_all(&bytes).await?;
            drop(bytes);
            self.buffers.remove(&index);
            return Ok(turn);
        }
        // Clone only after admission, so parked writers need neither an extra
        // descriptor nor Tokio's internal write buffer. Positional writes do
        // not disturb any retained descriptor's seek position.
        let file = self.file.try_clone().await?.into_std().await;
        let buffer = self.buffers.remove(&index).unwrap();
        #[cfg(test)]
        let test_id = self.write_gate.id().to_owned();
        let (buffer, result, turn) = tokio::task::spawn_blocking(move || {
            use std::os::unix::fs::FileExt;
            #[cfg(test)]
            tests::before_batch(&test_id);
            // The blocking operation owns both the turn and retained RAM.
            // Dropping its async waiter cannot release either during I/O.
            let bytes = if buffer.chunks.len() == 1 { std::borrow::Cow::Borrowed(buffer.chunks[0].as_ref()) }
            else {
                let mut bytes = Vec::with_capacity(buffer.bytes);
                for chunk in &buffer.chunks { bytes.extend_from_slice(chunk); }
                std::borrow::Cow::Owned(bytes)
            };
            let result = file.write_all_at(&bytes, buffer.offset);
            drop(bytes);
            (buffer, result, turn)
        }).await.map_err(std::io::Error::other)?;
        if let Err(error) = result {
            self.buffers.insert(index, buffer);
            return Err(error);
        }
        drop(buffer);
        Ok(turn)
    }
    async fn flush_ready(&mut self) -> std::io::Result<()> {
        while let Some(index) = self.buffers.iter().min_by_key(|(_, buffer)| buffer.offset).map(|(index, _)| *index) {
            self.flush_piece(index).await?;
        }
        Ok(())
    }
    async fn checkpoint(
        &mut self,
        part: &Path,
        file_id: &str,
        state: &State,
        source_revision: Option<&str>,
        require_content_hash: bool,
        source_key: &str,
    ) -> anyhow::Result<()> {
        let mut diagnostic = crate::download_telemetry::Operation::new(
            crate::download_telemetry::Kind::Checkpoint, file_id);
        crate::download_fs::validate_open_file_async(&data_path(part), &self.file.metadata().await?).await?;
        // Keep checking destination identity during a stalled body, but do not
        // repeatedly flush the drive and replace an unchanged durable journal.
        if self.buffers.is_empty() && self.checkpointed.as_ref() == Some(state) {
            diagnostic.complete();
            return Ok(());
        }
        {
            let mut write_turn = self.write_gate.turn(false).await;
            while let Some(index) = self.buffers.iter().min_by_key(|(_, buffer)| buffer.offset).map(|(index, _)| *index) {
                write_turn = self.flush_piece_in_turn(index, write_turn).await?;
            }
            self.file.flush().await?;
            drop(write_turn);
        }
        let synced = self.file.metadata().await?;
        crate::download_fs::validate_open_file_async(&data_path(part), &synced).await?;
        if state
            .covered_ranges()
            .any(|(index, _, bytes)| self.hashes[index].bytes != bytes)
        {
            anyhow::bail!("Range checkpoint does not match its verified bytes");
        }
        let journal = serde_json::to_vec(&Journal {
            version: 1, file_id: file_id.into(), ranges: state.clone(),
            source_revision: source_revision.map(str::to_owned), require_content_hash,
            source_key: Some(source_key.into()),
            piece_sha256: Some(self.hashes.iter().map(integrity::Prefix::digest).collect()),
            data_identity: integrity::SavedIdentity::of(&synced),
        })?;
        crate::download_checkpoint::commit(&self.write_gate, &self.file, synced.clone(), &data_path(part), &journal_path(part), journal).await?;
        // Failed data or journal commits must remain eligible for another
        // checkpoint, even when no additional network bytes arrive.
        self.checkpointed = Some(state.clone());
        self.synced_identity = integrity::SavedIdentity::of(&synced);
        diagnostic.complete();
        Ok(())
    }
}

pub(super) enum Outcome {
    Complete(VerifiedCompletion),
    Sequential { staging_changed: bool },
}

async fn probe_etag(
    http: &reqwest::Client, link: &str, total: u64, referer: Option<&str>,
    progress: &DownloadProgressContext<'_>, network: &std::sync::Arc<Network>,
) -> Result<Option<String>, DlError> {
    let key = crate::download_preparation::Key::for_probe(
        link, progress.source_file_id, total, progress.source_revision.as_deref(), referer);
    let preparation = &progress.retry_state.preparation;
    if let Some(tag) = preparation.probe(&key) { return Ok(tag); }
    let probe = transfer_control::interruptible(
        progress.file_id, download_ranges::probe(http, link, total, referer, network),
    ).await.map_err(DlError::Fatal)?.map_err(error);
    match probe {
        Ok(tag) => {
            // A short-lived validator only avoids repeating setup; every
            // payload still validates If-Range, ETag and byte coverage.
            preparation.remember_probe(&key, &tag);
            Ok(tag)
        }
        Err(failure) if progress.guest_range_fallback && download_range_rejected(match &failure {
            DlError::Fatal(error) | DlError::Retryable(error) => error,
        }) => {
            preparation.remember_probe(&key, &None);
            Ok(None)
        },
        result => result,
    }
}

/// Conversion back from sparse pieces can rename, truncate, or extend the
/// original staging file. Its caller must re-read the new durable checkpoint
/// before resuming sequentially, even if no sparse journal existed on entry.
pub(super) async fn attempt_outcome(
    http: &reqwest::Client,
    link: &str,
    total: u64,
    part: &Path,
    show_progress: bool,
    progress: &DownloadProgressContext<'_>,
    referer: Option<&str>,
) -> Result<Outcome, DlError> {
    let inspection_part = part.to_owned();
    let inspection_id = progress.source_file_id.to_owned();
    // Directory traversal and small journal reads can block on a busy HDD.
    // Inspect them together away from the HTTP executor's worker threads.
    let (had_ranges, existing, mut journal, data_length, data_identity, serial_candidate) = tokio::task::spawn_blocking(move || {
        let had_ranges = exists(&inspection_part);
        if !had_ranges && total < download_ranges::MIN_PARALLEL_SIZE {
            return Ok((had_ranges, 0, None, None, None, None));
        }
        let existing = length(&inspection_part)?.unwrap_or(0);
        let journal = load(&inspection_part, &inspection_id, total)?;
        let data = data_path(&inspection_part);
        let data_length = length(&data)?;
        let data_identity = crate::download_fs::metadata(&data).ok().and_then(|metadata| integrity::SavedIdentity::of(&metadata));
        let serial_candidate = if !had_ranges && total >= download_ranges::MIN_PARALLEL_SIZE && existing > 0 && existing < total {
            ResumeState::load(&inspection_part, &inspection_id, total).ok().flatten()
        } else { None };
        Ok::<_, anyhow::Error>((had_ranges, existing, journal, data_length, data_identity, serial_candidate))
    }).await.map_err(|error| fatal(error, "Cannot inspect download checkpoints"))?.map_err(DlError::Fatal)?;
    if !had_ranges && total < download_ranges::MIN_PARALLEL_SIZE {
        return Ok(Outcome::Sequential {
            staging_changed: false,
        });
    }
    let current_source = source_key(link);
    let network = Network::for_url(link);
    let mut probed = None;
    let mut prefetched = None;
    // These are only request coordinates, never certified disk coverage. The
    // existing checksum checks below still finish before any RAM is written.
    let candidate = journal.as_ref().filter(|saved| {
        !saved.ranges.complete() && saved.ranges.received() > 0
            // Known local changes may alter the holes. Repair them first,
            // rather than spend bandwidth fetching against stale coordinates.
            && saved.data_identity.as_ref().is_none_or(|identity| Some(identity) == data_identity.as_ref())
            && saved.piece_sha256.as_ref().is_some_and(|hashes| hashes.len() == saved.ranges.covered_ranges().count())
            && data_length.is_some_and(|size| size >= saved.ranges.extent() && size <= total)
            && revisions_compatible(saved.source_revision.as_deref(), progress.source_revision.as_deref())
            && (!(saved.require_content_hash || progress.require_content_hash)
                || same_source(saved.source_key.as_deref(), &current_source, saved.ranges.etag())
                || pikpak::content_mode::matching_content_revision(saved.source_revision.as_deref(), progress.source_revision.as_deref()))
    }).map(|saved| (saved.ranges.clone(), saved.source_revision.clone())).or_else(|| {
        if had_ranges || total < download_ranges::MIN_PARALLEL_SIZE || existing == 0 || existing >= total { return None; }
        let saved = serial_candidate.as_ref()?;
        if saved.prefix_sha256.is_none() || saved.durable_bytes != Some(existing)
            || resume_plan(Some(&saved), true, existing, total, progress, link).is_err() { return None; }
        Some((State::new(total, saved.etag.clone(), existing), saved.source_revision.clone()))
    });
    if let Some((mut state, revision)) = candidate {
        if let Some(permit) = crate::download_buffer::prefetch_slot(state.received(), total.saturating_sub(state.received())) {
            crate::download_verification::ready_to_receive(progress.file_id).await.map_err(DlError::Fatal)?;
            let tag = probe_etag(http, link, total, referer, progress, &network).await?;
            if let Some(tag) = tag.as_deref().filter(|tag| state.etag() == *tag
                || pikpak::content_mode::matching_content_revision(revision.as_deref(), progress.source_revision.as_deref())) {
                if state.rebind_etag(tag) {
                    let transfer = Transfer::new(http, link, referer, state, network.clone()).map_err(error)?.with_absolute_gain();
                    prefetched = Some(crate::download_buffer::Ranges::new_prefetch(transfer, progress.receive_counter(), permit));
                }
            }
            probed = Some(tag);
        }
    }
    let mut retained_hashes = None;
    let mut completed_prefix = None;
    let mut healed = None;
    if let Some(saved) = &journal {
        if saved
            .piece_sha256
            .as_ref()
            .is_none_or(|digests| digests.len() != saved.ranges.covered_ranges().count())
        {
            restore_prefix(part, &saved.ranges)
                .await
                .map_err(DlError::Fatal)?;
            return Ok(Outcome::Sequential {
                staging_changed: true,
            });
        }
        let data = data_path(part);
        if length_async(&data).await
            .map_err(DlError::Fatal)?
            .is_some_and(|size| size >= saved.ranges.extent())
        {
            let digests = saved.piece_sha256.as_deref().unwrap_or(&[]);
            let mut hashes = if data_length == Some(total)
                && saved.ranges.complete() && saved.ranges.received() == total
                && pikpak::content_mode::matching_content_revision(
                    saved.source_revision.as_deref(), progress.source_revision.as_deref())
            {
                progress.retry_state.set_final_verification_pending(true);
                let partitions: Vec<_> = saved.ranges.covered_ranges().map(|(_, _, bytes)| bytes).collect();
                let (hash, pieces) = integrity::Prefix::read_complete_pieces(
                    &data, total, &partitions, progress.file_id).await?;
                completed_prefix = Some(hash);
                pieces
            } else {
                match progress.retry_state.pieces(&data, saved) {
                    Some(hashes) => hashes,
                    None => restore_hashes(&data, &saved.ranges, digests, saved.data_identity.as_ref(), progress.file_id).await?.hashes,
                }
            };
            if digests.len() == hashes.len() {
                // A piece whose bytes still match its digest is certified. One that no longer does is forgotten and
                // fetched again, and only that one: damage to a piece must not cost the rest of the file.
                let damaged: Vec<usize> = (0..hashes.len()).filter(|&index| digests[index] != hashes[index].digest()).collect();
                if !damaged.is_empty() {
                    // Repair changes the file: its aggregate proof cannot
                    // stand in for the mandatory final pass after new writes.
                    completed_prefix = None;
                    progress.retry_state.set_final_verification_pending(false);
                    let mut state = saved.ranges.clone();
                    for &index in &damaged {
                        state.forget_piece(index);
                        hashes[index] = integrity::Prefix::new();
                    }
                    // The journal says so before any new byte is written.
                    save_with_hashes_async(
                        part,
                        progress.source_file_id,
                        &state,
                        saved.source_revision.as_deref(),
                        saved.require_content_hash,
                        saved.source_key.as_deref(),
                        hashes.iter().map(integrity::Prefix::digest).collect(),
                        None,
                    )
                    .await
                    .map_err(DlError::Fatal)?;
                    healed = Some(state);
                } else {
                    progress.retry_state.remember_verified_pieces(&data, saved, &hashes).await;
                }
                retained_hashes = Some(hashes);
            } else {
                // Legacy coverage or altered sparse bytes cannot skip holes.
                // Keep only its contiguous prefix for remote byte comparison.
                restore_prefix(part, &saved.ranges)
                    .await
                    .map_err(DlError::Fatal)?;
                return Ok(Outcome::Sequential {
                    staging_changed: true,
                });
            }
        }
    }
    if let (Some(state), Some(journal)) = (healed, journal.as_mut()) {
        journal.ranges = state;
    }
    // A different original must never inherit sparse coverage, even if its CDN
    // happens to reuse the entity tag. A legacy contiguous prefix can instead
    // be compared against a complete response by the sequential path.
    if journal.as_ref().is_some_and(|journal| {
        !revisions_compatible(
            journal.source_revision.as_deref(),
            progress.source_revision.as_deref(),
        ) || (journal.require_content_hash || progress.require_content_hash)
            && !same_source(
                journal.source_key.as_deref(),
                &current_source,
                journal.ranges.etag(),
            )
            && !pikpak::content_mode::matching_content_revision(
                journal.source_revision.as_deref(),
                progress.source_revision.as_deref(),
            )
    }) {
        remove_async(part).await.map_err(DlError::Fatal)?;
        journal = None;
        retained_hashes = None;
    }
    let saved_part = part.to_owned();let saved_id = progress.source_file_id.to_owned();
    let saved = tokio::task::spawn_blocking(move || ResumeState::load(&saved_part, &saved_id, total)).await
        .map_err(|error| fatal(error, "Cannot inspect saved download progress"))?
        .map_err(DlError::Fatal)?
        .filter(|saved| saved.prefix_sha256.is_some())
        .filter(|saved| saved.durable_bytes == Some(existing))
        .filter(|saved| {
            revisions_compatible(
                saved.source_revision.as_deref(),
                progress.source_revision.as_deref(),
            )
        })
        .filter(|saved| {
            !(saved.require_content_hash || progress.require_content_hash)
                || same_source(saved.source_key.as_deref(), &current_source, &saved.etag)
                || pikpak::content_mode::matching_content_revision(
                    saved.source_revision.as_deref(),
                    progress.source_revision.as_deref(),
                )
        });

    if had_ranges
        && (journal.is_none()
            || data_length.is_some_and(|size| {
                size > total
                    || journal
                        .as_ref()
                        .is_some_and(|journal| size < journal.ranges.extent())
            }))
    {
        // Unverifiable staging data cannot certify holes as downloaded bytes.
        // Keep the independently validated legacy prefix, if one still exists.
        remove_async(part).await.map_err(DlError::Fatal)?;
        journal = None;
        retained_hashes = None;
    }
    if journal.is_none()
        && (total < download_ranges::MIN_PARALLEL_SIZE
            || existing >= total
            || existing > 0 && saved.is_none())
    {
        return Ok(Outcome::Sequential {
            staging_changed: false,
        });
    }
    if journal.as_ref().is_some_and(|journal| {
        data_length == Some(total)
            && journal.ranges.complete()
            && journal.ranges.received() == total
            && pikpak::content_mode::matching_content_revision(
                journal.source_revision.as_deref(),
                progress.source_revision.as_deref(),
            )
    }) {
        progress.retry_state.set_final_verification_pending(true);
        let journal = journal.unwrap();
        // The journal follows data sync. A complete original whose GCID still
        // matches fresh metadata needs publication, never another CDN probe.
        let file = crate::download_fs::open_async(&data_path(part), rustix::fs::OFlags::RDONLY)
            .await
            .map_err(|error| fatal(error, "Cannot open completed download pieces"))?;
        let opened = file
            .metadata()
            .await
            .map_err(|error| fatal(error, "Cannot inspect completed download pieces"))?;
        crate::download_fs::validate_open_file_async(&data_path(part), &opened).await
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        if opened.len() != total {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Completed download pieces changed size"
            )));
        }
        let saved = ResumeState {
                file_id: progress.source_file_id.into(),
                total,
                etag: journal.ranges.etag().into(),
                source_revision: progress.source_revision.clone(),
                require_content_hash: progress.require_content_hash,
                source_key: Some(current_source),
                durable_bytes: Some(total),
                unverified_tail: None,
                prefix_sha256: None,
            };
        let hash = match completed_prefix {
            Some(hash) => {
                hash.validate_restored(&opened)?;
                hash
            }
            None => {
                let proof = prefix_proof(&journal.ranges, journal.piece_sha256.as_ref().unwrap());
                integrity::Prefix::read_verified(&data_path(part), total, &proof, progress.file_id).await?
            }
        };
        crate::download_fs::validate_open_file_async(
            &data_path(part),
            &file
                .metadata()
                .await
                .map_err(|error| fatal(error, "Cannot inspect completed download pieces"))?,
        ).await
        .map_err(|error| fatal(error, "Download staging file changed"))?;
        let verified = VerifiedCompletion::from_durable_checkpoint(
            &data_path(part),
            part,
            saved,
            hash,
            progress.file_id,
        )
        .await?
        .rename(&data_path(part), part)
        .await?;
        remove_async(part).await.map_err(DlError::Fatal)?;
        progress.emit(total, total);
        return Ok(Outcome::Complete(verified));
    }
    let etag = match probed {
        Some(tag) => tag,
        None => {
            crate::download_verification::ready_to_receive(progress.file_id).await.map_err(DlError::Fatal)?;
            probe_etag(http, link, total, referer, progress, &network).await?
        }
    };
    let trusted = etag.as_ref().is_some_and(|tag| {
        journal.as_ref().map_or_else(
            || {
                existing == 0
                    || saved.as_ref().is_some_and(|saved| {
                        &saved.etag == tag
                            || pikpak::content_mode::matching_content_revision(
                                saved.source_revision.as_deref(),
                                progress.source_revision.as_deref(),
                            )
                    })
            },
            |journal| {
                journal.ranges.etag() == tag
                    || pikpak::content_mode::matching_content_revision(
                        journal.source_revision.as_deref(),
                        progress.source_revision.as_deref(),
                    )
            },
        )
    });
    if !trusted {
        let staging_changed = journal.is_some();
        if let Some(journal) = journal {
            let proof = prefix_proof(&journal.ranges, journal.piece_sha256.as_ref().unwrap());
            restore_prefix(part, &journal.ranges)
                .await
                .map_err(DlError::Fatal)?;
            if journal.ranges.prefix() > 0
                && pikpak::content_mode::matching_content_revision(
                    journal.source_revision.as_deref(),
                    progress.source_revision.as_deref(),
                )
            {
                save_serial_prefix(
                    part,
                    part,
                    ResumeState {
                        file_id: progress.source_file_id.into(),
                        total,
                        etag: String::new(),
                        source_revision: progress.source_revision.clone(),
                        require_content_hash: progress.require_content_hash,
                        source_key: Some(current_source.clone()),
                        durable_bytes: Some(journal.ranges.prefix()),
                        unverified_tail: None,
                        prefix_sha256: None,
                    },
                    &proof,
                    progress.file_id,
                    Some(&progress.retry_state),
                )
                .await?;
            }
        }
        return Ok(Outcome::Sequential { staging_changed });
    }
    let mut state = journal
        .map(|journal| journal.ranges)
        .unwrap_or_else(|| State::new(total, etag.clone().unwrap(), existing));
    if !state.rebind_etag(etag.as_deref().unwrap()) {
        return Err(DlError::Fatal(anyhow::anyhow!(
            "Invalid original entity tag"
        )));
    }
    if length_async(&data_path(part)).await.map_err(DlError::Fatal)?.is_none() {
        if existing != state.prefix()
            || existing > 0
                && saved.as_ref().is_none_or(|saved| {
                    saved.etag != state.etag()
                        && !pikpak::content_mode::matching_content_revision(
                            saved.source_revision.as_deref(),
                            progress.source_revision.as_deref(),
                        )
                })
        {
            remove(part).map_err(DlError::Fatal)?;
            return Ok(Outcome::Sequential {
                staging_changed: false,
            });
        }
        // The caller no longer verifies before range reception starts. A
        // contiguous prefix must still match its bound checksum before adoption.
        let mut hashes = if existing > 0 {
            let partitions: Vec<_> = state.covered_ranges().map(|(_, _, bytes)| bytes).collect();
            let Some((_, hashes)) = recover_durable_prefix_partitioned(part, progress.source_file_id, total,
                progress.file_id, &progress.retry_state, Some(&partitions)).await? else {
                return Ok(Outcome::Sequential { staging_changed: false });
            };
            hashes
        } else { read_hashes(part, &state, progress.file_id).await? };
        // Journal first: a crash before the rename can adopt the same validated
        // prefix again. No out-of-order writes happen until both exist.
        save_with_hashes_async(
            part,
            progress.source_file_id,
            &state,
            progress.source_revision.as_deref(),
            progress.require_content_hash,
            Some(&current_source),
            hashes.iter().map(integrity::Prefix::digest).collect(),
            None,
        )
        .await
        .map_err(DlError::Fatal)?;
        if length_async(part).await.map_err(DlError::Fatal)?.is_some() {
            crate::download_fs::rename_async(part, &data_path(part))
                .await
                .map_err(|e| fatal(e, "Cannot retain download prefix"))?;
            let moved = crate::download_fs::metadata_async(&data_path(part))
                .await
                .map_err(|error| fatal(error, "Cannot inspect retained download prefix"))?;
            for hash in &mut hashes {
                hash.adopt_renamed_metadata(&moved)?;
            }
        } else {
            crate::download_fs::open_async(
                &data_path(part),
                rustix::fs::OFlags::CREATE | rustix::fs::OFlags::EXCL | rustix::fs::OFlags::WRONLY,
            )
            .await
            .map_err(|e| fatal(e, "Cannot create download pieces"))?;
        }
        retained_hashes = Some(hashes);
    }
    let file = crate::download_fs::open_async(&data_path(part), rustix::fs::OFlags::RDWR)
        .await
        .map_err(|e| fatal(e, "Cannot open download pieces"))?;
    let transfer = Transfer::new(http, link, referer, state, network)
        .map_err(error)?
        .with_absolute_gain();
    let mut hashes = match retained_hashes {
        Some(hashes) => hashes,
        None => read_hashes(&data_path(part), transfer.state(), progress.file_id).await?,
    };
    // Restart replays the last byte of a piece whose EOF was not observed.
    // Reuse the state saved just before that byte during the first verification
    // read. Unknown/legacy contexts still take the conservative read path.
    for (index, offset, bytes) in transfer.state().covered_ranges() {
        if hashes[index].bytes != bytes && !hashes[index].rewind_for_replay(bytes) {
            hashes[index] =
                integrity::Prefix::read(&data_path(part), offset, bytes, progress.file_id).await?;
        }
    }
    // Damage can change the requested holes. Discard speculative bytes only
    // in that case; the healed journal is already durable before replacement.
    if prefetched.as_ref().is_some_and(|body| body.state() != transfer.state()) {
        prefetched = None;
    }
    if prefetched.is_none() {
        crate::download_verification::ready_to_receive(progress.file_id).await.map_err(DlError::Fatal)?;
    }
    let opened = file
        .metadata()
        .await
        .map_err(|error| fatal(error, "Cannot inspect resumed download pieces"))?;
    crate::download_fs::validate_open_file_async(&data_path(part), &opened).await
        .map_err(|error| fatal(error, "Download staging file changed"))?;
    for hash in &hashes {
        hash.validate_restored(&opened)?;
    }
    let mut writer = Writer {
        write_gate: crate::download_verification::WriteGate::new(&file, progress.file_id),
        file,
        buffers: BTreeMap::new(),
        hashes,
        checkpointed: None,
        synced_identity: None,
        total,
        offsets: transfer
            .state()
            .covered_ranges()
            .map(|(_, offset, _)| offset)
            .collect(),
    };
    // Reserve retry-cache space for interrupted transfers, rather than copies
    // that become stale while these live writer contexts keep advancing.
    progress.retry_state.clear();
    let mut transfer = match prefetched {
        Some(body) => { body.activate(); body },
        None => crate::download_buffer::Ranges::new(transfer, progress.receive_counter()),
    };
    // Saved every second on an internal disk, and every few seconds on an external disk or a network share.
    let mut schedule = crate::download_checkpoint::CheckpointSchedule::new(crate::download_fs::checkpoint_policy(part), Instant::now());
    let mut last_progress = Instant::now();
    progress.emit(transfer.state().received(), total);
    let result = loop {
        if !writer.buffers.is_empty() && crate::download_buffer::range_write_pressure() {
            if let Err(error) = writer.flush_ready().await { break Err(fatal(error, "Cannot flush buffered download pieces")); }
        }
        let received = tokio::select! {
            biased;
            _ = tokio::time::sleep_until(schedule.due_at().into()), if schedule.must_save(Instant::now()) => None,
            result = transfer_control::drainable(progress.file_id, transfer.next()) => Some(result),
            _ = tokio::time::sleep(Duration::from_millis(25)), if !writer.buffers.is_empty() => {
                if let Err(error) = writer.flush_ready().await { break Err(fatal(error, "Cannot flush buffered download pieces")); }
                continue;
            },
            _ = tokio::time::sleep_until(schedule.due_at().into()) => None,
        };
        let Some(received) = received else {
            if let Err(error) = writer
                .checkpoint(
                    part,
                    progress.source_file_id,
                    transfer.state(),
                    progress.source_revision.as_deref(),
                    progress.require_content_hash,
                    &current_source,
                )
                .await
            {
                break Err(DlError::Fatal(error));
            }
            progress.emit(transfer.state().received(), total);
            schedule.saved(Instant::now());
            continue;
        };
        let received = if received.is_ok() && !matches!(received, Ok(Ok(Some(_)))) && transfer_control::pause_receiving(progress.file_id)
            && (transfer_control::draining() || !transfer.state().complete()) {
            Err(transfer_control::Paused.into())
        } else { received };
        match received {
            Ok(Ok(Some(chunk))) => {
                if let Err(error) = writer.flush_completed(transfer.state()).await {
                    break Err(fatal(error, "Cannot flush completed download piece"));
                }
                let retained = transfer.accept_retaining(&chunk);
                if let Err(error) = crate::download_buffer::write_chunk(chunk.bytes.len(), writer.push_retaining(&chunk, retained)).await {
                    break Err(fatal(error, "Cannot write download pieces"));
                }
                schedule.received(chunk.bytes.len() as u64, Instant::now());
                if last_progress.elapsed() >= Duration::from_millis(250) {
                    progress.emit(transfer.state().received(), total);
                    if show_progress {
                        eprint!("\r  {} / {total} bytes", transfer.state().received());
                    }
                    last_progress = Instant::now();
                }
            }
            Ok(Ok(None)) => break Ok(true),
            Ok(Err(download_ranges::Error::Sequential)) => break Ok(false),
            Ok(Err(failure)) => {
                let failure = error(failure);
                let cause = match &failure {
                    DlError::Fatal(error) | DlError::Retryable(error) => error,
                };
                if progress.guest_range_fallback
                    && transfer.state().received() == 0
                    && download_route_unavailable(cause)
                {
                    // A denied later range must not bypass an available guest
                    // prefix before the first piece has been accepted.
                    break Ok(false);
                }
                break Err(failure);
            }
            Err(error) => break Err(DlError::Fatal(error)),
        }
    };
    transfer.stop();
    // Journal updates follow the file flush/sync. Even a failed piece retains
    // accepted prefixes in other pieces, without claiming buffered bytes.
    writer
        .checkpoint(
            part,
            progress.source_file_id,
            transfer.state(),
            progress.source_revision.as_deref(),
            progress.require_content_hash,
            &current_source,
        )
        .await
        .map_err(DlError::Fatal)?;
    let piece_digests = writer
        .hashes
        .iter()
        .map(integrity::Prefix::digest)
        .collect::<Vec<_>>();
    // Only interrupted transfers retain an additional set of contexts. The
    // successful path keeps its existing final read-back and no cache FD.
    if result.is_err() {
        if let (Some(identity), Ok(metadata)) = (writer.synced_identity, writer.file.metadata().await) {
            if integrity::SavedIdentity::of(&metadata) == Some(identity) {
                let checkpoint = Journal {
                    version: 1,
                    file_id: progress.source_file_id.into(),
                    ranges: transfer.state().clone(),
                    source_revision: progress.source_revision.clone(),
                    require_content_hash: progress.require_content_hash,
                    source_key: Some(current_source.clone()),
                    piece_sha256: Some(piece_digests.clone()),
                    data_identity: Some(identity),
                };
                progress.retry_state.remember_pieces(&data_path(part), &checkpoint, &writer.file, &metadata, &writer.hashes).await;
            }
        }
    }
    drop(writer);
    progress.emit(transfer.state().received(), total);
    match result {
        Ok(true) => {
            if !transfer.state().complete() || transfer.state().received() != total {
                return Err(DlError::Fatal(anyhow::anyhow!(
                    "Incomplete download range coverage"
                )));
            }
            progress.retry_state.set_final_verification_pending(true);
            let verified = verify_finished_staging(
                part,
                progress.source_file_id,
                total,
                ResumeState {
                    file_id: progress.source_file_id.into(),
                    total,
                    etag: transfer.state().etag().into(),
                    source_revision: progress.source_revision.clone(),
                    require_content_hash: progress.require_content_hash,
                    source_key: Some(current_source.clone()),
                    durable_bytes: Some(total),
                    unverified_tail: None,
                    prefix_sha256: None,
                },
                &prefix_proof(transfer.state(), &piece_digests),
                progress.file_id,
            )
            .await?;
            let verified = verified.rename(&data_path(part), part)
            .await?;
            remove(part).map_err(DlError::Fatal)?;
            if show_progress {
                eprintln!();
            }
            Ok(Outcome::Complete(verified))
        }
        Ok(false) => {
            restore_prefix(part, transfer.state())
                .await
                .map_err(DlError::Fatal)?;
            if transfer.state().prefix() > 0
                && pikpak::content_mode::matching_content_revision(
                    progress.source_revision.as_deref(),
                    progress.source_revision.as_deref(),
                )
            {
                save_serial_prefix(
                    part,
                    part,
                    ResumeState {
                        file_id: progress.source_file_id.into(),
                        total,
                        etag: String::new(),
                        source_revision: progress.source_revision.clone(),
                        require_content_hash: progress.require_content_hash,
                        source_key: Some(current_source),
                        durable_bytes: Some(transfer.state().prefix()),
                        unverified_tail: None,
                        prefix_sha256: None,
                    },
                    &prefix_proof(transfer.state(), &piece_digests),
                    progress.file_id,
                    Some(&progress.retry_state),
                )
                .await?;
            }
            Ok(Outcome::Sequential {
                staging_changed: true,
            })
        }
        Err(error) => {
            if matches!(&error, DlError::Fatal(error) if error.is::<transfer_control::Cancelled>())
            {
                transfer_control::remove_owned_partial_as(
                    part,
                    progress.source_file_id,
                    progress.file_id,
                )
                .await
                .map_err(DlError::Fatal)?;
            }
            Err(error)
        }
    }
}

async fn restore_prefix(part: &Path, state: &State) -> anyhow::Result<()> {
    if length_async(&data_path(part)).await?.is_some() {
        let file =
            crate::download_fs::open_async(&data_path(part), rustix::fs::OFlags::WRONLY).await?;
        crate::download_fs::validate_open_file_async(&data_path(part), &file.metadata().await?).await?;
        file.set_len(state.prefix()).await?;
        file.sync_data().await?;
        crate::download_fs::validate_open_file_async(&data_path(part), &file.metadata().await?).await?;
        drop(file);
        crate::download_fs::rename_async(&data_path(part), part).await?;
    }
    // Remove the old validator too. A changed/unsupported response must validate
    // this prefix using a full response before it can be trusted again.
    super::remove_state(part)
}

#[cfg(test)]
#[path = "download_parts_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "download_pause_tests.rs"]
mod pause_tests;

#[cfg(test)]
#[path = "download_prefetch_tests.rs"]
mod prefetch_tests;

#[cfg(test)]
#[path = "download_parts_transition_tests.rs"]
mod transition_tests;

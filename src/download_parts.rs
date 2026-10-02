//! Out-of-order disk data has its own filename. Only a complete, flushed range
//! map can replace the legacy contiguous .part file.
use super::*;
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
}

fn sibling(part: &Path, suffix: &str) -> PathBuf {
    let mut path = part.as_os_str().to_owned();
    path.push(suffix);
    PathBuf::from(path)
}
fn journal_path(part: &Path) -> PathBuf {
    sibling(part, ".ranges.json")
}
fn data_path(part: &Path) -> PathBuf {
    sibling(part, ".ranges.data")
}

fn length(path: &Path) -> anyhow::Result<Option<u64>> {
    match std::fs::symlink_metadata(path) {
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
        .any(|path| std::fs::symlink_metadata(path).is_ok())
}

fn load(part: &Path, file_id: &str, total: u64) -> anyhow::Result<Option<Journal>> {
    let path = journal_path(part);
    let Some(size) = length(&path)? else {
        return Ok(None);
    };
    if size > 2 * 1024 * 1024 {
        return Ok(None);
    }
    let Ok(journal) = serde_json::from_slice::<Journal>(&std::fs::read(path)?) else {
        return Ok(None);
    };
    Ok((journal.version == 1
        && journal.file_id == file_id
        && journal.ranges.valid()
        && journal.ranges.total() == total)
        .then_some(journal))
}

fn save(part: &Path, file_id: &str, state: &State) -> anyhow::Result<()> {
    use std::io::Write;
    length(&journal_path(part))?;
    let mut temporary = tempfile::NamedTempFile::new_in(part.parent().unwrap_or(Path::new(".")))?;
    serde_json::to_writer(
        &mut temporary,
        &Journal {
            version: 1,
            file_id: file_id.into(),
            ranges: state.clone(),
        },
    )?;
    temporary.flush()?;
    temporary.as_file().sync_all()?;
    temporary.persist(journal_path(part))?;
    Ok(())
}

pub(super) fn remove(part: &Path) -> anyhow::Result<()> {
    for path in [data_path(part), journal_path(part)] {
        if length(&path)?.is_some() {
            std::fs::remove_file(path)?;
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
    bytes: Vec<u8>,
}
struct Writer {
    file: tokio::fs::File,
    buffers: BTreeMap<usize, Buffer>,
}
impl Writer {
    async fn flush_completed(&mut self, state: &State) -> std::io::Result<()> {
        while let Some(index) = self
            .buffers
            .keys()
            .copied()
            .find(|index| state.piece_complete(*index))
        {
            self.flush_piece(index).await?;
        }
        Ok(())
    }
    async fn push(&mut self, chunk: &download_ranges::Chunk) -> std::io::Result<()> {
        let buffer = self.buffers.entry(chunk.index).or_insert_with(|| Buffer {
            offset: chunk.offset,
            bytes: Vec::with_capacity(pikpak::download_network::RECEIVE_WINDOW as usize),
        });
        if buffer.offset + buffer.bytes.len() as u64 != chunk.offset {
            return Err(std::io::Error::other("Non-contiguous range write"));
        }
        buffer.bytes.extend_from_slice(&chunk.bytes);
        if buffer.bytes.len() >= pikpak::download_network::RECEIVE_WINDOW as usize {
            self.flush_piece(chunk.index).await?;
        }
        Ok(())
    }
    async fn flush_piece(&mut self, index: usize) -> std::io::Result<()> {
        if let Some(buffer) = self.buffers.get(&index) {
            self.file.seek(SeekFrom::Start(buffer.offset)).await?;
            self.file.write_all(&buffer.bytes).await?;
            self.buffers.remove(&index);
        }
        Ok(())
    }
    async fn checkpoint(
        &mut self,
        part: &Path,
        file_id: &str,
        state: &State,
    ) -> anyhow::Result<()> {
        while let Some(index) = self.buffers.keys().next().copied() {
            self.flush_piece(index).await?;
        }
        self.file.flush().await?;
        self.file.sync_data().await?;
        save(part, file_id, state)
    }
}

/// `false` leaves a regular contiguous legacy partial for the sequential path.
pub(super) async fn attempt(
    http: &reqwest::Client,
    link: &str,
    total: u64,
    part: &Path,
    show_progress: bool,
    progress: &DownloadProgressContext<'_>,
    referer: Option<&str>,
) -> Result<bool, DlError> {
    let had_ranges = exists(part);
    if !had_ranges && total < download_ranges::MIN_PARALLEL_SIZE {
        return Ok(false);
    }
    let existing = length(part).map_err(DlError::Fatal)?.unwrap_or(0);
    let mut journal = load(part, progress.source_file_id, total).map_err(DlError::Fatal)?;
    let saved = ResumeState::load(part, progress.source_file_id, total);
    let data_length = length(&data_path(part)).map_err(DlError::Fatal)?;
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
        remove(part).map_err(DlError::Fatal)?;
        journal = None;
    }
    if journal.is_none()
        && (total < download_ranges::MIN_PARALLEL_SIZE
            || existing >= total
            || existing > 0 && saved.is_none())
    {
        return Ok(false);
    }
    let network = Network::for_url(link);
    let etag = transfer_control::interruptible(
        progress.file_id,
        download_ranges::probe(http, link, total, referer, &network),
    )
    .await
    .map_err(DlError::Fatal)?
    .map_err(error)?;
    let trusted = etag.as_ref().is_some_and(|tag| {
        journal.as_ref().map_or_else(
            || existing == 0 || saved.as_ref().is_some_and(|saved| &saved.etag == tag),
            |journal| journal.ranges.etag() == tag,
        )
    });
    if !trusted {
        if let Some(journal) = journal {
            restore_prefix(part, &journal.ranges)
                .await
                .map_err(DlError::Fatal)?;
        }
        return Ok(false);
    }
    let state = journal
        .map(|journal| journal.ranges)
        .unwrap_or_else(|| State::new(total, etag.unwrap(), existing));
    if length(&data_path(part)).map_err(DlError::Fatal)?.is_none() {
        if existing != state.prefix()
            || existing > 0
                && saved
                    .as_ref()
                    .is_none_or(|saved| saved.etag != state.etag())
        {
            remove(part).map_err(DlError::Fatal)?;
            return Ok(false);
        }
        // Journal first: a crash before the rename can adopt the same validated
        // prefix again. No out-of-order writes happen until both exist.
        save(part, progress.source_file_id, &state).map_err(DlError::Fatal)?;
        if length(part).map_err(DlError::Fatal)?.is_some() {
            tokio::fs::rename(part, data_path(part))
                .await
                .map_err(|e| fatal(e, "Cannot retain download prefix"))?;
        } else {
            tokio::fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(data_path(part))
                .await
                .map_err(|e| fatal(e, "Cannot create download pieces"))?;
        }
    }
    let file = tokio::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(data_path(part))
        .await
        .map_err(|e| fatal(e, "Cannot open download pieces"))?;
    let mut writer = Writer {
        file,
        buffers: BTreeMap::new(),
    };
    let mut transfer = Transfer::new(http, link, referer, state, network)
        .map_err(error)?
        .with_absolute_gain();
    let mut last_checkpoint = Instant::now();
    let mut last_progress = Instant::now();
    progress.emit(transfer.state().received(), total);
    let result = loop {
        let received = tokio::select! {
            result = transfer_control::interruptible(progress.file_id, transfer.next()) => Some(result),
            _ = tokio::time::sleep(Duration::from_secs(1).saturating_sub(last_checkpoint.elapsed())) => None,
        };
        let Some(received) = received else {
            if let Err(error) = writer
                .checkpoint(part, progress.source_file_id, transfer.state())
                .await
            {
                break Err(DlError::Fatal(error));
            }
            progress.emit(transfer.state().received(), total);
            last_checkpoint = Instant::now();
            continue;
        };
        match received {
            Ok(Ok(Some(chunk))) => {
                if let Err(error) = writer.flush_completed(transfer.state()).await {
                    break Err(fatal(error, "Cannot flush completed download piece"));
                }
                if let Err(error) = writer.push(&chunk).await {
                    break Err(fatal(error, "Cannot write download pieces"));
                }
                transfer.accept(&chunk);
                progress.add_transferred(chunk.bytes.len() as u64);
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
            Ok(Err(failure)) => break Err(error(failure)),
            Err(error) => break Err(DlError::Fatal(error)),
        }
    };
    transfer.stop();
    // Journal updates follow the file flush/sync. Even a failed piece retains
    // accepted prefixes in other pieces, without claiming buffered bytes.
    writer
        .checkpoint(part, progress.source_file_id, transfer.state())
        .await
        .map_err(DlError::Fatal)?;
    drop(writer);
    progress.emit(transfer.state().received(), total);
    match result {
        Ok(true) => {
            if !transfer.state().complete() || transfer.state().received() != total {
                return Err(DlError::Fatal(anyhow::anyhow!(
                    "Incomplete download range coverage"
                )));
            }
            ResumeState {
                file_id: progress.source_file_id.into(),
                total,
                etag: transfer.state().etag().into(),
            }
            .save(part)
            .map_err(DlError::Fatal)?;
            tokio::fs::rename(data_path(part), part)
                .await
                .map_err(|e| fatal(e, "Cannot finalize download pieces"))?;
            remove(part).map_err(DlError::Fatal)?;
            if show_progress {
                eprintln!();
            }
            Ok(true)
        }
        Ok(false) => {
            restore_prefix(part, transfer.state())
                .await
                .map_err(DlError::Fatal)?;
            Ok(false)
        }
        Err(error) => {
            if matches!(&error, DlError::Fatal(error) if error.is::<transfer_control::Cancelled>())
            {
                transfer_control::remove_owned_partial(part, progress.source_file_id)
                    .await
                    .map_err(DlError::Fatal)?;
            }
            Err(error)
        }
    }
}

async fn restore_prefix(part: &Path, state: &State) -> anyhow::Result<()> {
    if length(&data_path(part))?.is_some() {
        let file = tokio::fs::OpenOptions::new()
            .write(true)
            .open(data_path(part))
            .await?;
        file.set_len(state.prefix()).await?;
        file.sync_data().await?;
        drop(file);
        tokio::fs::rename(data_path(part), part).await?;
    }
    // Remove the old validator too. A changed/unsupported response must validate
    // this prefix using a full response before it can be trusted again.
    super::remove_state(part)
}

#[cfg(test)]
#[path = "download_parts_tests.rs"]
mod tests;

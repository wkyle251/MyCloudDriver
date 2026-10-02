//! Validated disk resume. Legacy partials are checked against a full response
//! before a validator is attached; crashes cannot bless an unverified prefix.
use super::{classify, fatal, transfer_control, DlError, DownloadProgressContext};
use pikpak::download_policy::{self, HttpFailure};
use reqwest::{header, StatusCode};
use serde::{Deserialize, Serialize};
use std::{
    io::SeekFrom,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufWriter};
#[path = "download_parts.rs"]
mod parts;

pub(super) fn has_parts(part: &Path) -> bool { parts::exists(part) }

pub(super) async fn saved_bytes(part: &Path, file_id: &str, total: u64) -> u64 {
    if let Some(bytes) = parts::saved_bytes(part, file_id, total) { return bytes; }
    tokio::fs::metadata(part).await.map(|metadata| metadata.len()).unwrap_or(0)
}

#[derive(Serialize, Deserialize)]
struct ResumeState {
    file_id: String,
    total: u64,
    etag: String,
}

fn state_path(part: &Path) -> PathBuf {
    let mut path = part.as_os_str().to_owned();
    path.push(".resume.json");
    PathBuf::from(path)
}

pub(super) fn remove_state(part: &Path) -> anyhow::Result<()> {
    let path = state_path(part);
    match std::fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.is_file() => std::fs::remove_file(path)?,
        Ok(_) => anyhow::bail!("Download resume metadata is not a regular file"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    parts::remove(part)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn server(
        status: u16,
        headers: &str,
        body: &[u8],
        slow: bool,
    ) -> (String, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/original", listener.local_addr().unwrap());
        let header = format!(
            "HTTP/1.1 {status} Test\r\nContent-Length: {}\r\n{headers}Connection: close\r\n\r\n",
            body.len()
        );
        let body = body.to_vec();
        let task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let mut chunk = [0; 4096];
                let count = socket.read(&mut chunk).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&chunk[..count]);
            }
            socket.write_all(header.as_bytes()).await.unwrap();
            for chunk in body.chunks(if slow { 1 } else { body.len().max(1) }) {
                if slow {
                    tokio::time::sleep(Duration::from_millis(40)).await;
                }
                if socket.write_all(chunk).await.is_err() {
                    break;
                }
            }
            String::from_utf8(request).unwrap().to_lowercase()
        });
        (url, task)
    }

    fn progress() -> DownloadProgressContext<'static> {
        DownloadProgressContext::new(false, "file", "original")
    }

    #[tokio::test]
    async fn download_legacy_changed_and_oversized_partials_are_repaired() {
        for old in [b"old".as_slice(), b"oversized stale content".as_slice()] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            std::fs::write(&partial, old).unwrap();
            let (url, request) = server(200, "ETag: \"current\"\r\n", b"NEW-DATA", false).await;
            let result = attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                progress(),
                None,
            )
            .await;
            assert!(result.is_ok());
            assert_eq!(std::fs::read(&partial).unwrap(), b"NEW-DATA");
            assert!(!request.await.unwrap().contains("\r\nrange:"));
            assert_eq!(
                ResumeState::load(&partial, "file", 8).unwrap().etag,
                "\"current\""
            );
        }
    }

    #[tokio::test]
    async fn download_validated_resume_and_ignored_range_are_safe() {
        for ignored in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            std::fs::write(&partial, b"NEW").unwrap();
            seed_resume(&partial, "file", 8, "\"current\"");
            let (url, request) = if ignored {
                server(200, "ETag: \"current\"\r\n", b"NEW-DATA", false).await
            } else {
                server(
                    206,
                    "ETag: \"current\"\r\nContent-Range: bytes 3-7/8\r\n",
                    b"-DATA",
                    false,
                )
                .await
            };
            let progress = progress();
            assert!(attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                progress.clone(),
                None
            )
            .await
            .is_ok());
            assert_eq!(std::fs::read(&partial).unwrap(), b"NEW-DATA");
            assert_eq!(progress.transferred_bytes(), if ignored { 8 } else { 5 });
            let request = request.await.unwrap();
            assert!(request.contains("range: bytes=3-"));
            assert!(request.contains("if-range: \"current\""));
        }
    }

    #[tokio::test]
    async fn download_rejects_bad_ranges_and_changed_validators_without_appending() {
        for headers in [
            "Content-Range: bytes 0-4/8\r\nETag: \"current\"\r\n",
            "Content-Range: bytes 3-7/8\r\nETag: \"changed\"\r\n",
            "ETag: \"current\"\r\n",
        ] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            std::fs::write(&partial, b"old").unwrap();
            seed_resume(&partial, "file", 8, "\"current\"");
            let (url, request) = server(206, headers, b"-DATA", false).await;
            assert!(attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                progress(),
                None
            )
            .await
            .is_err());
            assert_eq!(std::fs::read(&partial).unwrap(), b"old");
            assert!(ResumeState::load(&partial, "file", 8).is_none());
            request.await.unwrap();
        }
    }

    #[tokio::test]
    async fn download_416_requires_exact_size_and_matching_validator() {
        for (old, matching, success) in [
            (b"DATA".as_slice(), true, true),
            (b"DATA".as_slice(), false, false),
            (b"oversized".as_slice(), true, false),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            std::fs::write(&partial, old).unwrap();
            seed_resume(&partial, "file", 4, "\"current\"");
            let (url, request) = server(
                416,
                if matching {
                    "Content-Range: bytes */4\r\nETag: \"current\"\r\n"
                } else {
                    "Content-Range: bytes */4\r\n"
                },
                b"error page",
                false,
            )
            .await;
            assert_eq!(
                attempt(
                    &reqwest::Client::new(),
                    &url,
                    4,
                    &partial,
                    false,
                    progress(),
                    None
                )
                .await
                .is_ok(),
                success
            );
            assert_eq!(std::fs::read(&partial).unwrap(), old);
            request.await.unwrap();
        }
    }

    #[tokio::test]
    async fn download_long_bodies_outlive_metadata_timeout_for_account_and_share() {
        let account = pikpak::Client::builder()
            .refresh_token("fixture")
            .timeout(Duration::from_millis(60))
            .build()
            .unwrap();
        let share = pikpak::ShareClient::new_authenticated(
            "https://mypikpak.com/s/fixture",
            "",
            "",
            account.clone(),
        )
        .unwrap();
        for shared in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            let (url, request) = server(200, "", b"NEW-DATA", true).await;
            let result = if shared {
                super::super::download_attempt_with_http(
                    share.download_http_client(),
                    &url,
                    8,
                    &partial,
                    false,
                    progress(),
                    Some("https://mypikpak.com/"),
                )
                .await
            } else {
                super::super::download_attempt(&account, &url, 8, &partial, false, progress()).await
            };
            assert!(
                result.is_ok(),
                "Healthy download inherited the metadata timeout"
            );
            assert_eq!(std::fs::read(&partial).unwrap(), b"NEW-DATA");
            request.await.unwrap();
        }
    }

    #[tokio::test]
    async fn download_status_preserves_cooldown_and_stops_permanent_failure() {
        for status in [403, 408, 429, 503, 404] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            let (url, request) = server(
                status,
                "Retry-After: 120\r\n",
                b"private server body",
                false,
            )
            .await;
            let error = match attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                progress(),
                None,
            )
            .await
            {
                Err(error) => error.into_inner(),
                Ok(_) => panic!("HTTP error accepted"),
            };
            assert_eq!(download_policy::retryable(&error), status != 404);
            assert_eq!(
                download_policy::delay(&error),
                Some(Duration::from_secs(120))
            );
            assert!(!format!("{error:#}").contains("private server body"));
            request.await.unwrap();
        }
    }

    #[tokio::test]
    async fn download_interruption_does_not_validate_an_unchecked_legacy_prefix() {
        for legacy in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            if legacy {
                std::fs::write(&partial, b"NEW-xxxx").unwrap();
            }
            let (url, request) = server(200, "ETag: \"current\"\r\n", b"NEW", false).await;
            assert!(attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                progress(),
                None
            )
            .await
            .is_err());
            request.await.unwrap();
            assert_eq!(
                ResumeState::load(&partial, "file", 8).is_some(),
                !legacy,
                "Only bytes belonging entirely to the current response may receive its validator"
            );
            let (url, request) = if legacy {
                server(200, "ETag: \"current\"\r\n", b"NEW-DATA", false).await
            } else {
                server(
                    206,
                    "Content-Range: bytes 3-7/8\r\nETag: \"current\"\r\n",
                    b"-DATA",
                    false,
                )
                .await
            };
            assert!(attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                progress(),
                None
            )
            .await
            .is_ok());
            assert_eq!(std::fs::read(&partial).unwrap(), b"NEW-DATA");
            request.await.unwrap();
        }
    }
}

fn strong_etag(headers: &header::HeaderMap) -> Option<String> {
    headers
        .get(header::ETAG)?
        .to_str()
        .ok()
        .filter(|tag| tag.starts_with('"') && tag.ends_with('"'))
        .map(str::to_owned)
}

impl ResumeState {
    fn load(part: &Path, file_id: &str, total: u64) -> Option<Self> {
        let path = state_path(part);
        let metadata = std::fs::symlink_metadata(&path).ok()?;
        if !metadata.is_file() || metadata.len() > 16 * 1024 {
            return None;
        }
        let state: Self = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
        (state.file_id == file_id
            && state.total == total
            && total > 0
            && state.etag.starts_with('"')
            && state.etag.ends_with('"'))
        .then_some(state)
    }

    fn save(&self, part: &Path) -> anyhow::Result<()> {
        use std::io::Write;
        let mut temporary =
            tempfile::NamedTempFile::new_in(part.parent().unwrap_or(Path::new(".")))?;
        serde_json::to_writer(&mut temporary, self)?;
        temporary.flush()?;
        temporary.as_file().sync_all()?;
        temporary.persist(state_path(part))?;
        Ok(())
    }
}

#[cfg(test)]
pub(super) fn seed_resume(part: &Path, file_id: &str, total: u64, etag: &str) {
    ResumeState {
        file_id: file_id.into(),
        total,
        etag: etag.into(),
    }
    .save(part)
    .unwrap();
}

fn content_range(headers: &header::HeaderMap) -> Option<(u64, u64, u64)> {
    let value = headers
        .get(header::CONTENT_RANGE)?
        .to_str()
        .ok()?
        .strip_prefix("bytes ")?;
    let (range, total) = value.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    let (start, end, total) = (
        start.parse().ok()?,
        end.parse::<u64>().ok()?,
        total.parse().ok()?,
    );
    (start <= end && end < total).then_some((start, end, total))
}

pub(super) async fn attempt(
    http: &reqwest::Client,
    link: &str,
    total: u64,
    part: &Path,
    show_progress: bool,
    progress: DownloadProgressContext<'_>,
    referer: Option<&str>,
) -> Result<(), DlError> {
    if parts::attempt(http, link, total, part, show_progress, &progress, referer).await? { return Ok(()); }
    let network = pikpak::download_network::Network::for_url(link);
    let _participant = network.register();
    let _channel = transfer_control::interruptible(progress.file_id, network.acquire()).await
        .map_err(DlError::Fatal)?.map_err(|error| fatal(error, "Cannot reserve download connection"))?;
    let existing = match tokio::fs::symlink_metadata(part).await {
        Ok(metadata) if metadata.is_file() => metadata.len(),
        Ok(_) => {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Partial download is not a regular file"
            )))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
        Err(error) => return Err(fatal(error, "Cannot inspect partial download")),
    };
    let saved = ResumeState::load(part, progress.source_file_id, total);
    let ranged = existing > 0 && existing <= total && saved.is_some();
    let mut request = http.get(link).header(header::ACCEPT_ENCODING, "identity");
    if let Some(referer) = referer {
        request = request.header(header::REFERER, referer);
    }
    if ranged {
        request = request
            .header(header::RANGE, format!("bytes={existing}-"))
            .header(header::IF_RANGE, &saved.as_ref().unwrap().etag);
    }
    let mut response = transfer_control::interruptible(progress.file_id, request.send())
        .await
        .map_err(DlError::Fatal)?
        .map_err(|error| classify(error, "Download request failed"))?;
    let status = response.status();
    if status == StatusCode::RANGE_NOT_SATISFIABLE && ranged {
        let server_total = response
            .headers()
            .get(header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("bytes */"))
            .and_then(|value| value.parse::<u64>().ok());
        if existing == total
            && server_total == Some(total)
            && strong_etag(response.headers()).as_deref()
                == saved.as_ref().map(|state| state.etag.as_str())
        {
            return Ok(());
        }
        remove_state(part).map_err(DlError::Fatal)?;
        return Err(DlError::Retryable(anyhow::anyhow!(
            "The saved range changed; validating the original again"
        )));
    }
    if !status.is_success() {
        let failure = HttpFailure {
            status: status.as_u16(),
            retry_after: download_policy::retry_after(response.headers()),
        };
        if matches!(failure.status, 429 | 500..=599) {
            network.defer(failure.retry_after.unwrap_or(Duration::from_secs(1)))
                .map_err(|error| fatal(error, "Cannot defer download connections"))?;
        }
        let retry = download_policy::transient_status(failure.status)
            || matches!(failure.status, 401 | 403);
        return Err(if retry {
            DlError::Retryable(failure.into())
        } else {
            DlError::Fatal(failure.into())
        });
    }
    let response_etag = strong_etag(response.headers());
    let start = if status == StatusCode::PARTIAL_CONTENT {
        let valid = content_range(response.headers()).is_some_and(|(start, end, length)| {
            ranged
                && start == existing
                && end + 1 == length
                && length == total
                && response
                    .content_length()
                    .is_none_or(|length| length == total - start)
                && response.headers().get(header::ETAG).is_none_or(|tag| {
                    tag.to_str().ok() == saved.as_ref().map(|state| state.etag.as_str())
                })
        });
        if !valid {
            remove_state(part).map_err(DlError::Fatal)?;
            let error = anyhow::anyhow!("The download service returned an invalid byte range");
            return Err(if ranged {
                DlError::Retryable(error)
            } else {
                DlError::Fatal(error)
            });
        }
        existing
    } else if status == StatusCode::OK {
        remove_state(part).map_err(DlError::Fatal)?;
        0
    } else {
        return Err(DlError::Fatal(anyhow::anyhow!(
            "Unexpected download response HTTP {}",
            status.as_u16()
        )));
    };
    let expected = if total > 0 {
        total
    } else {
        response.content_length().unwrap_or(0)
    };
    let file = tokio::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(part)
        .await
        .map_err(|error| fatal(error, "Cannot open partial download"))?;
    // HTTP chunks can be only a few KiB. Coalesce them before Tokio dispatches
    // filesystem work, with at most 256 KiB buffered per active disk download.
    // Flush explicitly before legacy reads/truncation; seeks also flush.
    let mut out = BufWriter::with_capacity(256 * 1024, file);
    let mut written = existing;
    if start == 0 && expected > 0 && written > expected {
        out.get_mut().set_len(0)
            .await
            .map_err(|error| fatal(error, "Cannot reset oversized partial download"))?;
        written = 0;
    }
    let mut position = start;
    out.seek(SeekFrom::Start(position))
        .await
        .map_err(|error| fatal(error, "Cannot seek partial download"))?;
    let mut validator_saved = start > 0;
    let state = response_etag.map(|etag| ResumeState {
        file_id: progress.source_file_id.to_owned(),
        total: expected,
        etag,
    });
    if written == 0 {
        if let Some(state) = &state {
            state.save(part).map_err(DlError::Fatal)?;
            validator_saved = true;
        }
    }
    progress.emit(written, expected);
    let mut last = Instant::now();
    loop {
        let receive = transfer_control::interruptible(progress.file_id, response.chunk());
        tokio::pin!(receive);
        let received = loop {
            tokio::select! {
                result = &mut receive => break result,
                _ = tokio::time::sleep(Duration::from_millis(250).saturating_sub(last.elapsed())),
                    if !out.buffer().is_empty() => {
                    // A server can stall after a small chunk. Persist that
                    // chunk without waiting for another network read or Pause.
                    out.flush().await.map_err(|error| fatal(error, "Cannot flush download progress"))?;
                    progress.emit(written, expected);
                    if show_progress && expected > 0 { eprint!("\r  {written} / {expected} bytes"); }
                    last = Instant::now();
                }
            }
        };
        let chunk = match received {
            Ok(Ok(Some(chunk))) => chunk,
            Ok(Ok(None)) => break,
            result => {
                out.flush()
                    .await
                    .map_err(|error| fatal(error, "Cannot flush interrupted download"))?;
                drop(out);
                progress.emit(written, expected);
                return match result {
                    Err(error) => {
                        if error.is::<transfer_control::Cancelled>() {
                            transfer_control::remove_owned_partial(part, progress.source_file_id)
                                .await
                                .map_err(DlError::Fatal)?;
                        }
                        Err(DlError::Fatal(error))
                    }
                    Ok(Err(error)) => Err(classify(error, "Download stream interrupted")),
                    _ => unreachable!(),
                };
            }
        };
        progress.add_transferred(chunk.len() as u64);
        network.record(chunk.len() as u64);
        if expected > 0 && position.saturating_add(chunk.len() as u64) > expected {
            out.flush().await.map_err(|error| fatal(error, "Cannot flush interrupted download"))?;
            return Err(DlError::Fatal(anyhow::anyhow!(
                "The original exceeded its declared size; download was not finalized"
            )));
        }
        // Keep memory bounded even when adopting a multi-gigabyte legacy part.
        let duplicate = written.saturating_sub(position).min(chunk.len() as u64) as usize;
        let mut same = duplicate;
        if duplicate > 0 {
            let mut old = vec![0; duplicate];
            out.flush().await.map_err(|error| fatal(error, "Cannot flush before validating download"))?;
            out.read_exact(&mut old)
                .await
                .map_err(|error| fatal(error, "Cannot validate partial download"))?;
            if old != chunk[..duplicate] {
                // Previous chunks were compared. Discard every unverified byte
                // before writing this version, including the old trailing data.
                out.get_mut().set_len(position)
                    .await
                    .map_err(|error| fatal(error, "Cannot replace changed partial download"))?;
                out.seek(SeekFrom::Start(position))
                    .await
                    .map_err(|error| fatal(error, "Cannot seek changed download"))?;
                written = position;
                same = 0;
            }
        }
        out.write_all(&chunk[same..]).await.map_err(|error| {
            fatal(
                error,
                "Cannot write download; check storage and permissions",
            )
        })?;
        position += chunk.len() as u64;
        written = written.max(position);
        if !validator_saved && position >= written {
            if let Some(state) = &state {
                out.flush()
                    .await
                    .map_err(|error| fatal(error, "Cannot flush validated download"))?;
                state.save(part).map_err(DlError::Fatal)?;
                validator_saved = true;
            }
        }
        if last.elapsed() >= Duration::from_millis(250) || expected > 0 && written >= expected {
            // Keep pause/restart progress on disk as well as in the UI. Error
            // and pause exits above also flush before releasing the writer.
            out.flush().await.map_err(|error| fatal(error, "Cannot flush download progress"))?;
            progress.emit(written, expected);
            if show_progress && expected > 0 {
                eprint!("\r  {written} / {expected} bytes");
            }
            last = Instant::now();
        }
    }
    if expected == 0 && start == 0 && written > position {
        out.flush().await.map_err(|error| fatal(error, "Cannot flush changed download"))?;
        out.get_mut().set_len(position)
            .await
            .map_err(|error| fatal(error, "Cannot finalize changed download"))?;
        written = position;
    }
    out.flush()
        .await
        .map_err(|error| fatal(error, "Cannot flush completed download"))?;
    progress.emit(written, expected);
    if show_progress {
        eprintln!();
    }
    if position != written || expected > 0 && written != expected {
        return Err(DlError::Retryable(anyhow::anyhow!(
            "Download ended at {position} bytes; expected {expected}"
        )));
    }
    Ok(())
}

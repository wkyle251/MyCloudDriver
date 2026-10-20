//! Validated disk resume. Legacy partials are checked against a full response
//! before a validator is attached; crashes cannot bless an unverified prefix.
use super::{classify, fatal, transfer_control, DlError, DownloadProgressContext};
use pikpak::download_policy::{self, ContentUnavailable, HttpFailure, PartialContent};
use reqwest::{header, StatusCode};
use serde::{Deserialize, Serialize};
use std::{
    io::SeekFrom,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufWriter};
#[path = "download_integrity.rs"]
mod integrity;
#[path = "download_retry.rs"]
mod retry;
pub(crate) use retry::RetryState;
#[path = "download_parts.rs"]
mod parts;
#[cfg(all(test, target_os = "macos"))]
#[path = "download_disk_fixture.rs"]
mod disk_fixture;
#[cfg(test)]
#[path = "download_completion_tests.rs"]
pub(super) mod completion_tests;
#[cfg(test)]
#[path = "download_retry_tests.rs"]
mod retry_tests;

/// An in-process proof from the full piece-verification pass. Keeping the
/// original descriptor open prevents a replacement from inheriting its inode.
/// This is deliberately neither serializable nor cloneable: retries after a
/// restart still verify the bytes on disk.
pub(super) struct VerifiedCompletion {
    file: std::fs::File,
    hash: integrity::Prefix,
    file_id: String,
    revision: Option<String>,
    /// Only a successful data-before-journal commit in this process can set
    /// this. Reading an old journal or verifying copied bytes is insufficient.
    durably_synced: bool,
}

impl VerifiedCompletion {
    async fn from_prefix(
        path: &Path,
        hash: integrity::Prefix,
        file_id: &str,
        revision: Option<&str>,
    ) -> Result<Self, DlError> {
        let file = crate::download_fs::open_async(path, rustix::fs::OFlags::RDONLY)
            .await
            .map_err(|error| fatal(error, "Cannot retain verified download"))?;
        let metadata = file
            .metadata()
            .await
            .map_err(|error| fatal(error, "Cannot inspect verified download"))?;
        crate::download_fs::validate_open_file(path, &metadata)
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        hash.validate_restored(&metadata)?;
        if hash.bytes != metadata.len() {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Verified download changed size"
            )));
        }
        Ok(Self {
            file: file.into_std().await,
            hash,
            file_id: file_id.into(),
            revision: revision.map(str::to_owned),
            durably_synced: false,
        })
    }

    async fn from_durable_checkpoint(
        path: &Path,
        part: &Path,
        mut saved: ResumeState,
        hash: integrity::Prefix,
        control_id: &str,
    ) -> Result<Self, DlError> {
        crate::download_fs::validate(part)
            .map_err(|error| fatal(error, "Download staging path changed"))?;
        let file = crate::download_fs::open_async(path, rustix::fs::OFlags::RDONLY)
            .await.map_err(|error| fatal(error, "Cannot retain verified download"))?;
        let metadata = file.metadata().await
            .map_err(|error| fatal(error, "Cannot inspect verified download"))?;
        crate::download_fs::validate_open_file_async(path, &metadata).await
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        hash.validate_restored(&metadata)?;
        if saved.total == 0 || saved.durable_bytes != Some(saved.total)
            || hash.bytes != saved.total || metadata.len() != saved.total
        {
            return Err(DlError::Fatal(anyhow::anyhow!("Verified checkpoint changed size")));
        }
        saved.prefix_sha256 = Some(hash.digest());
        let journal = serde_json::to_vec(&saved)
            .map_err(|error| fatal(error, "Cannot save verified download checkpoint"))?;
        let gate = crate::download_verification::WriteGate::new(&file, control_id);
        // The read guard has already ended. Finalizers can therefore share
        // the normal bounded checkpoint write turn without holding a reader.
        crate::download_checkpoint::commit(
            &gate, &file, metadata, path, &state_path(part), journal,
        ).await.map_err(DlError::Fatal)?;
        let metadata = file.metadata().await
            .map_err(|error| fatal(error, "Cannot inspect saved download"))?;
        crate::download_fs::validate_open_file_async(path, &metadata).await
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        hash.validate_restored(&metadata)?;
        Ok(Self {
            file: file.into_std().await,
            hash,
            file_id: saved.file_id,
            revision: saved.source_revision,
            durably_synced: true,
        })
    }

    async fn rename(mut self, from: &Path, to: &Path) -> Result<Self, DlError> {
        let before = self
            .file
            .metadata()
            .map_err(|error| fatal(error, "Cannot inspect verified download"))?;
        self.hash.validate_restored(&before)?;
        crate::download_fs::validate_open_file(from, &before)
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        crate::download_fs::rename_async(from, to)
            .await
            .map_err(|error| fatal(error, "Cannot finalize download pieces"))?;
        let after = self
            .file
            .metadata()
            .map_err(|error| fatal(error, "Cannot inspect verified download"))?;
        crate::download_fs::validate_open_file(to, &after)
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        // Our controlled rename changes ctime, but must preserve the object,
        // length and modification time whose bytes were just verified.
        self.hash.adopt_renamed_metadata(&after)?;
        Ok(self)
    }

    pub(super) fn digest_if_unchanged(
        &self,
        metadata: &std::fs::Metadata,
        file_id: &str,
        revision: Option<&str>,
    ) -> anyhow::Result<Option<String>> {
        anyhow::ensure!(
            self.file_id == file_id && self.revision.as_deref() == revision,
            "Download verification belongs to a different source"
        );
        let held = self.file.metadata()?;
        Ok((self.hash.bytes == metadata.len()
            && self.hash.validate_restored(metadata).is_ok()
            && self.hash.validate_restored(&held).is_ok())
        .then(|| self.hash.digest()))
    }

    pub(super) fn validate_unchanged(&self, metadata: &std::fs::Metadata) -> anyhow::Result<()> {
        self.hash
            .validate_restored(metadata)
            .map_err(DlError::into_inner)
    }

    pub(super) fn durably_synced(&self) -> bool {
        self.durably_synced
    }
}

pub(super) fn has_parts(part: &Path) -> bool {
    parts::exists(part)
}

pub(super) async fn saved_bytes(part: &Path, file_id: &str, total: u64) -> u64 {
    if let Some(bytes) = parts::saved_bytes(part, file_id, total) {
        return bytes;
    }
    crate::download_fs::metadata_async(part)
        .await
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}

pub(super) fn completed_digest(
    part: &Path,
    file_id: &str,
    total: u64,
) -> anyhow::Result<Option<String>> {
    Ok(ResumeState::load(part, file_id, total)?
        .filter(|state| state.durable_bytes == Some(total))
        .and_then(|state| state.prefix_sha256))
}

#[derive(Clone, Serialize, Deserialize)]
struct ResumeState {
    file_id: String,
    total: u64,
    etag: String,
    #[serde(default)]
    source_revision: Option<String>,
    #[serde(default)]
    require_content_hash: bool,
    #[serde(default)]
    source_key: Option<String>,
    #[serde(default)]
    durable_bytes: Option<u64>,
    #[serde(default)]
    prefix_sha256: Option<String>,
    /// Bytes beyond durable_bytes are retained for comparison, never trusted
    /// as downloaded coverage. This prevents Pause from discarding an old tail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    unverified_tail: Option<u64>,
}

fn source_key(link: &str) -> String {
    hex::encode(ring::digest::digest(&ring::digest::SHA256, link.as_bytes()))
}

fn same_source(key: Option<&str>, current: &str, etag: &str) -> bool {
    !etag.is_empty() && key == Some(current)
}

fn revisions_compatible(saved: Option<&str>, current: Option<&str>) -> bool {
    match (saved, current) {
        (Some(saved), Some(current)) => {
            saved == current
                || pikpak::content_mode::matching_content_revision(Some(saved), Some(current))
        }
        (Some(_), None) => false,
        _ => true,
    }
}

fn resume_plan<'a>(
    saved: Option<&'a ResumeState>, restored: bool, existing: u64, total: u64,
    progress: &DownloadProgressContext<'_>, link: &str,
) -> Result<&'a ResumeState, crate::download_telemetry::Kind> {
    use crate::download_telemetry::Kind;
    if existing == 0 { return Err(Kind::ResumeNew); }
    let saved = saved.ok_or(Kind::ResumeMissing)?;
    if !restored { return Err(Kind::ResumeUnverified); }
    let durable = saved.durable_bytes.unwrap_or(u64::MAX);
    if existing > total || durable > existing
        || durable < existing && saved.unverified_tail.is_none_or(|tail| tail < existing) {
        return Err(Kind::ResumeLength);
    }
    if !revisions_compatible(saved.source_revision.as_deref(), progress.source_revision.as_deref()) {
        return Err(Kind::ResumeRevision);
    }
    let same_revision = pikpak::content_mode::matching_content_revision(
        saved.source_revision.as_deref(), progress.source_revision.as_deref());
    if (saved.require_content_hash || progress.require_content_hash)
        && !same_source(saved.source_key.as_deref(), &source_key(link), &saved.etag) && !same_revision {
        return Err(Kind::ResumeSource);
    }
    if saved.etag.is_empty() && !same_revision { return Err(Kind::ResumeValidator); }
    Ok(saved)
}

fn state_path(part: &Path) -> PathBuf {
    crate::download_names::sidecar(part, ".resume.json")
}

pub(super) fn remove_state(part: &Path) -> anyhow::Result<()> {
    let path = state_path(part);
    match crate::download_fs::metadata(&path) {
        Ok(metadata) if metadata.is_file() => crate::download_fs::remove_file(&path)?,
        Ok(_) => anyhow::bail!("Download resume metadata is not a regular file"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    parts::remove(part)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[cfg(target_os = "macos")]
    use super::disk_fixture::{copy_files, TestDisk};
    use super::*;

    async fn server(
        status: u16,
        headers: &str,
        body: &[u8],
        slow: bool,
    ) -> (String, tokio::task::JoinHandle<String>) {
        server_with_declared_length(status, headers, body, slow, body.len()).await
    }

    async fn server_with_declared_length(
        status: u16,
        headers: &str,
        body: &[u8],
        slow: bool,
        length: usize,
    ) -> (String, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/original", listener.local_addr().unwrap());
        let header = format!(
            "HTTP/1.1 {status} Test\r\nContent-Length: {}\r\n{headers}Connection: close\r\n\r\n",
            length
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

    fn fixture_hash(bytes: &[u8]) -> integrity::Prefix {
        let mut hash = integrity::Prefix::new();
        hash.update(bytes);
        hash
    }

    fn progress() -> DownloadProgressContext<'static> {
        DownloadProgressContext::new(false, "file", "original")
    }

    fn hashed_progress(revision: Option<&str>) -> DownloadProgressContext<'static> {
        let mut progress = progress();
        progress.source_revision = revision.map(str::to_owned);
        progress.require_content_hash = true;
        progress
    }

    #[tokio::test]
    async fn oversized_length_is_rejected_before_repeating_body_or_changing_saved_prefix() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("original.part");
        std::fs::write(&partial, b"abc").unwrap();
        seed_resume(&partial, "file", 8, "\"current\"");
        let checkpoint_before = std::fs::read(state_path(&partial)).unwrap();
        let (url, request) = server(200, "ETag: \"current\"\r\n", b"abcdefgh-extra", false).await;
        let progress = progress();
        let error = attempt(&reqwest::Client::new(), &url, 8, &partial, false, progress.clone(), None)
            .await.err().unwrap().into_inner();
        let mismatch = error.downcast_ref::<download_policy::OriginalSizeMismatch>().unwrap();
        assert_eq!(mismatch.expected, 8);
        assert_eq!(mismatch.received, 14);
        assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
        assert_eq!(std::fs::read(state_path(&partial)).unwrap(), checkpoint_before);
        assert_eq!(progress.transferred_bytes(), 0);
        assert!(crate::download_route_unavailable(&error));
        assert_eq!(download_policy::permanent_failure(&error), Some(download_policy::ORIGINAL_SIZE_MISMATCH));
        request.await.unwrap();
    }

    #[tokio::test]
    async fn oversized_chunked_body_cannot_leave_a_checkpoint_that_certifies_truncated_completion() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("original.part");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/original", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
            }
            socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nETag: \"current\"\r\nConnection: close\r\n\r\n8\r\nabcdefgh\r\n").await.unwrap();
            // Let the exact declared-size prefix become durable, then reveal
            // the extra bytes. Retrying must not publish that truncated prefix.
            tokio::time::sleep(Duration::from_millis(100)).await;
            let _ = socket.write_all(b"2\r\nij\r\n0\r\n\r\n").await;
        });
        let error = attempt(&reqwest::Client::new(), &url, 8, &partial, false,
            hashed_progress(Some("gcid:ABCDEF")), None).await.err().unwrap().into_inner();
        assert!(error.is::<download_policy::OriginalSizeMismatch>());
        assert!(!state_path(&partial).exists());
        assert!(completed_digest(&partial, "file", 8).unwrap().is_none());
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
        server.await.unwrap();
        let (url, request) = server_with_declared_length(200, "ETag: \"fixed\"\r\n", b"ABCDEFGH", false, 8).await;
        attempt(&reqwest::Client::new(), &url, 8, &partial, false,
            hashed_progress(Some("gcid:ABCDEF")), None).await.map_err(DlError::into_inner).unwrap();
        assert_eq!(std::fs::read(&partial).unwrap(), b"ABCDEFGH");
        assert!(!request.await.unwrap().contains("range:"), "Rejected bytes need a full response to validate them");
    }

    #[tokio::test]
    async fn capped_responses_keep_validated_prefixes_and_resume_across_cdn_tags() {
        for initial_status in [200, 206] {
            for tagged in [false, true] {
                let directory = tempfile::tempdir().unwrap();
                let partial = directory.path().join("original.part");
                let mut headers = if tagged {
                    "ETag: \"guest\"\r\n".to_owned()
                } else {
                    String::new()
                };
                if initial_status == 206 {
                    headers.push_str("Content-Range: bytes 0-2/8\r\n");
                }
                let (url, request) = server(initial_status, &headers, b"abc", false).await;
                let error = attempt(
                    &reqwest::Client::new(),
                    &url,
                    8,
                    &partial,
                    false,
                    hashed_progress(Some("gcid:ABCDEF")),
                    None,
                )
                .await
                .err()
                .unwrap()
                .into_inner();
                assert!(error.is::<PartialContent>());
                assert!(!pikpak::content_mode::content_access_denied(&error));
                assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
                request.await.unwrap();
                let headers = if tagged {
                    "ETag: \"user-cdn\"\r\nContent-Range: bytes 3-7/8\r\n"
                } else {
                    "Content-Range: bytes 3-7/8\r\n"
                };
                let (url, request) = server(206, headers, b"defgh", false).await;
                let progress = hashed_progress(Some("gcid:abcdef"));
                attempt(
                    &reqwest::Client::new(),
                    &url,
                    8,
                    &partial,
                    false,
                    progress.clone(),
                    None,
                )
                .await
                .map_err(DlError::into_inner)
                .unwrap();
                let request = request.await.unwrap();
                assert!(request.contains("range: bytes=3-\r\n"));
                assert!(!request.contains("if-range:"));
                assert_eq!(progress.transferred_bytes(), 5);
                assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
            }
        }
    }

    #[tokio::test]
    async fn capped_suffix_can_continue_on_guest_and_repeated_prefix_stops() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("original.part");
        std::fs::write(&partial, b"abc").unwrap();
        ResumeState {
            file_id: "file".into(),
            total: 8,
            etag: "\"guest\"".into(),
            source_revision: Some("gcid:ABCDEF".into()),
            require_content_hash: true,
            source_key: None,
            durable_bytes: Some(3),
            unverified_tail: None,
            prefix_sha256: Some(integrity::fixture_digest(&partial, 0, 3)),
        }
        .save(&partial)
        .unwrap();
        let (url, request) = server(
            206,
            "ETag: \"guest\"\r\nContent-Range: bytes 3-5/8\r\n",
            b"def",
            false,
        )
        .await;
        let error = attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            hashed_progress(Some("gcid:ABCDEF")),
            None,
        )
        .await
        .err()
        .unwrap()
        .into_inner();
        assert!(error.is::<PartialContent>());
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdef");
        assert!(request.await.unwrap().contains("range: bytes=3-\r\n"));
        let (url, request) = server(200, "ETag: \"guest\"\r\n", b"abcdef", false).await;
        let error = attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            hashed_progress(Some("gcid:ABCDEF")),
            None,
        )
        .await
        .err()
        .unwrap()
        .into_inner();
        assert!(error.is::<ContentUnavailable>());
        assert!(pikpak::content_mode::content_access_denied(&error));
        assert!(request.await.unwrap().contains("range: bytes=6-\r\n"));
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdef");
        let (url, request) = server(200, "ETag: \"guest\"\r\n", b"", false).await;
        let error = attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            hashed_progress(Some("gcid:ABCDEF")),
            None,
        )
        .await
        .err()
        .unwrap()
        .into_inner();
        assert!(error.is::<ContentUnavailable>());
        assert_eq!(
            std::fs::read(&partial).unwrap(),
            b"abcdef",
            "An empty response cannot erase a verified prefix"
        );
        assert!(request.await.unwrap().contains("range: bytes=6-\r\n"));
    }

    #[tokio::test]
    async fn cross_route_hash_mismatch_or_absence_cannot_reuse_an_equal_etag() {
        for (old_revision, revision) in [
            (Some("gcid:original"), Some("gcid:changed")),
            (Some("gcid:original"), None),
            (None, None),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            std::fs::write(&partial, b"abc").unwrap();
            ResumeState {
                file_id: "file".into(),
                total: 8,
                etag: "\"same-tag\"".into(),
                source_revision: old_revision.map(str::to_owned),
                require_content_hash: true,
                source_key: None,
                durable_bytes: Some(3),
                unverified_tail: None,
                prefix_sha256: Some(integrity::fixture_digest(&partial, 0, 3)),
            }
            .save(&partial)
            .unwrap();
            let (url, request) = server(200, "ETag: \"same-tag\"\r\n", b"NEW-DATA", false).await;
            attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                hashed_progress(revision),
                None,
            )
            .await
            .map_err(DlError::into_inner)
            .unwrap();
            assert!(!request.await.unwrap().contains("range:"));
            assert_eq!(std::fs::read(&partial).unwrap(), b"NEW-DATA");
        }
    }

    #[tokio::test]
    async fn explicit_416_cap_preserves_prefix_but_broken_body_does_not_trigger_handoff() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("original.part");
        let (url, request) =
            server_with_declared_length(200, "ETag: \"guest\"\r\n", b"abc", false, 8).await;
        let error = attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            hashed_progress(Some("gcid:ABCDEF")),
            None,
        )
        .await
        .err()
        .unwrap()
        .into_inner();
        assert!(!pikpak::content_mode::content_access_denied(&error));
        assert!(!error.is::<PartialContent>());
        assert!(download_policy::retryable(&error), "{error:#}");
        assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
        request.await.unwrap();
        for cap in [3, 0] {
            let (url, request) = server(
                416,
                &format!("Content-Range: bytes */{cap}\r\n"),
                b"",
                false,
            )
            .await;
            let error = attempt(
                &reqwest::Client::new(),
                &url,
                8,
                &partial,
                false,
                hashed_progress(Some("gcid:ABCDEF")),
                None,
            )
            .await
            .err()
            .unwrap()
            .into_inner();
            assert!(error.is::<ContentUnavailable>());
            assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
            assert!(ResumeState::load(&partial, "file", 8).unwrap().is_some());
            assert!(request.await.unwrap().contains("range: bytes=3-\r\n"));
        }
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
                ResumeState::load(&partial, "file", 8)
                    .unwrap()
                    .unwrap()
                    .etag,
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
    async fn interrupted_legacy_comparison_resumes_verified_prefix_and_repairs_unchecked_tail() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        std::fs::write(&part, b"abcXXXXX").unwrap();
        let (url, request) = server_with_declared_length(200, "ETag: \"first\"\r\n", b"abc", false, 8).await;
        let error = attempt(&reqwest::Client::new(), &url, 8, &part, false,
            hashed_progress(Some("gcid:GENERATED")), None).await.err().unwrap();
        assert!(matches!(error, DlError::Retryable(_)));
        assert!(!request.await.unwrap().contains("range:"));
        let saved = ResumeState::load(&part, "file", 8).unwrap().unwrap();
        assert_eq!(saved.durable_bytes, Some(3));
        assert_eq!(saved.unverified_tail, Some(8));
        assert_eq!(std::fs::read(&part).unwrap(), b"abcXXXXX");
        let (url, request) = server(206,
            "ETag: \"other-route\"\r\nContent-Range: bytes 3-7/8\r\n", b"defgh", false).await;
        let progress = hashed_progress(Some("gcid:generated"));
        attempt(&reqwest::Client::new(), &url, 8, &part, false, progress.clone(), None)
            .await.map_err(DlError::into_inner).unwrap();
        assert!(request.await.unwrap().contains("range: bytes=3-\r\n"));
        assert_eq!(progress.transferred_bytes(), 5);
        assert_eq!(std::fs::read(&part).unwrap(), b"abcdefgh");
        let saved = ResumeState::load(&part, "file", 8).unwrap().unwrap();
        assert_eq!(saved.durable_bytes, Some(8));
        assert_eq!(saved.unverified_tail, None);
    }

    #[tokio::test]
    async fn ignored_range_short_response_preserves_a_larger_verified_checkpoint() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        std::fs::write(&part, b"abcdef").unwrap();
        ResumeState {
            file_id: "file".into(), total: 8, etag: "\"old-route\"".into(),
            source_revision: Some("gcid:GENERATED".into()), require_content_hash: true,
            source_key: None, durable_bytes: Some(6), unverified_tail: None,
            prefix_sha256: Some(fixture_hash(b"abcdef").digest()),
        }.save(&part).unwrap();
        let (url, request) = server(200, "ETag: \"capped-route\"\r\n", b"abc", false).await;
        let error = attempt(&reqwest::Client::new(), &url, 8, &part, false,
            hashed_progress(Some("gcid:generated")), None).await.err().unwrap().into_inner();
        assert!(error.is::<ContentUnavailable>());
        assert!(request.await.unwrap().contains("range: bytes=6-\r\n"));
        let saved = ResumeState::load(&part, "file", 8).unwrap().unwrap();
        assert_eq!(saved.durable_bytes, Some(6), "A capped replay cannot demote the larger proven prefix");
        assert_eq!(saved.unverified_tail, None);
        assert_eq!(std::fs::read(&part).unwrap(), b"abcdef");
        let (url, request) = server(206,
            "ETag: \"suffix-route\"\r\nContent-Range: bytes 6-7/8\r\n", b"gh", false).await;
        let progress = hashed_progress(Some("gcid:GENERATED"));
        attempt(&reqwest::Client::new(), &url, 8, &part, false, progress.clone(), None)
            .await.map_err(DlError::into_inner).unwrap();
        assert!(request.await.unwrap().contains("range: bytes=6-\r\n"));
        assert_eq!(progress.transferred_bytes(), 2);
        assert_eq!(std::fs::read(&part).unwrap(), b"abcdefgh");
    }

    #[tokio::test]
    async fn recovery_retains_deliberate_unchecked_tail_but_discards_later_uncommitted_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        std::fs::write(&part, b"abcXXXXX??").unwrap();
        ResumeState {
            file_id: "file".into(), total: 12, etag: "\"generated\"".into(),
            source_revision: None, require_content_hash: false, source_key: None,
            durable_bytes: Some(3), prefix_sha256: Some(fixture_hash(b"abc").digest()), unverified_tail: Some(8),
        }.save(&part).unwrap();
        let restored = recover_durable_prefix(&part, "file", 12, "file").await.map_err(DlError::into_inner).unwrap().unwrap();
        assert_eq!(restored.bytes, 3);
        assert_eq!(std::fs::read(&part).unwrap(), b"abcXXXXX");
    }

    #[tokio::test]
    async fn an_unchecked_full_length_tail_cannot_certify_completion_from_416() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        std::fs::write(&part, b"abcXXXXX").unwrap();
        ResumeState {
            file_id: "file".into(), total: 8, etag: "\"generated\"".into(),
            source_revision: None, require_content_hash: false, source_key: None,
            durable_bytes: Some(3), prefix_sha256: Some(fixture_hash(b"abc").digest()), unverified_tail: Some(8),
        }.save(&part).unwrap();
        let (url, request) = server(416,
            "ETag: \"generated\"\r\nContent-Range: bytes */8\r\n", b"", false).await;
        assert!(attempt(&reqwest::Client::new(), &url, 8, &part, false, progress(), None).await.is_err());
        assert!(request.await.unwrap().contains("range: bytes=3-\r\n"));
        assert_eq!(std::fs::read(&part).unwrap(), b"abcXXXXX");
        assert!(completed_digest(&part, "file", 8).unwrap().is_none());
    }

    #[test]
    fn replayed_prefixes_drain_a_full_ram_budget_without_corrupting_saved_data() {
        let mut child = std::process::Command::new(std::env::current_exe().unwrap());
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().to_ascii_lowercase().ends_with("proxy") { child.env_remove(key); }
        }
        let result = child.env_remove("HOME").env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (4 << 20).to_string())
            .args(["--exact", "download_transport::tests::prefix_replay_child", "--ignored", "--nocapture"])
            .output().unwrap();
        assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "isolated generated prefix replay, RAM budget and diagnostics"]
    async fn prefix_replay_child() {
        let telemetry = crate::download_telemetry::Telemetry::start(true);
        for changed in [false, true] {
            let directory = tempfile::tempdir().unwrap(); let partial = directory.path().join("generated.part");
            let body = vec![b'N'; 12 << 20];
            std::fs::write(&partial, vec![if changed { b'X' } else { b'N' }; 5 << 20]).unwrap();
            let _drive = crate::download_verification::TestDrive::new("file");
            let (url, request) = server(200, "ETag: \"generated-current\"\r\n", &body, false).await;
            let progress = progress();
            let completed = tokio::time::timeout(Duration::from_secs(15), attempt(
                &reqwest::Client::new(), &url, body.len() as u64, &partial, false, progress.clone(), None,
            )).await.expect("A replay comparison must drain RAM even when it exceeds the disk handover threshold");
            assert!(completed.is_ok()); request.await.unwrap();
            assert_eq!(std::fs::read(&partial).unwrap(), body, "A changed prefix must still be replaced safely");
            assert_eq!(progress.transferred_bytes(), body.len() as u64);
            let metrics = crate::download_telemetry::test_metrics();
            let read = metrics["replay_read"]["bytes"].as_u64().unwrap();
            let written = metrics["payload_write"]["bytes"].as_u64().unwrap();
            assert!(read > 0 && read <= 5 << 20);
            assert_eq!(metrics["read_io"]["bytes"], read);
            assert_eq!(written, if changed { body.len() as u64 } else { body.len() as u64 - (5 << 20) });
            assert_eq!(metrics["replay_read"]["failed"], 0);
        }
        drop(telemetry);
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
            assert!(ResumeState::load(&partial, "file", 8).unwrap().is_none());
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
            let (url, request) =
                server_with_declared_length(200, "ETag: \"current\"\r\n", b"NEW", false, 8).await;
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
            let saved = ResumeState::load(&partial, "file", 8).unwrap().unwrap();
            assert_eq!(saved.durable_bytes, Some(3), "Only the compared or newly written prefix is certified");
            assert_eq!(saved.prefix_sha256, Some(fixture_hash(b"NEW").digest()));
            assert_eq!(saved.unverified_tail, legacy.then_some(8));
            assert!(completed_digest(&partial, "file", 8).unwrap().is_none(), "An unchecked tail cannot certify completion");
            let (url, request) = server(
                206, "Content-Range: bytes 3-7/8\r\nETag: \"current\"\r\n", b"-DATA", false,
            ).await;
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
            assert!(request.await.unwrap().contains("range: bytes=3-\r\n"));
        }
    }
    #[tokio::test]
    async fn durable_complete_original_finishes_without_a_content_request_only_with_matching_hash()
    {
        let http = reqwest::Client::builder()
            .no_proxy()
            .read_timeout(Duration::from_millis(200))
            .build()
            .unwrap();
        for tagged in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            std::fs::write(&partial, b"abcdefgh").unwrap();
            std::fs::File::open(&partial).unwrap().sync_data().unwrap();
            ResumeState {
                file_id: "file".into(),
                total: 8,
                etag: if tagged { "\"guest\"" } else { "" }.into(),
                source_revision: Some("gcid:ABCDEF".into()),
                require_content_hash: true,
                source_key: None,
                durable_bytes: Some(8),
                unverified_tail: None,
                prefix_sha256: Some(integrity::fixture_digest(&partial, 0, 8)),
            }
            .save(&partial)
            .unwrap();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}/capped-guest", listener.local_addr().unwrap());
            let progress = hashed_progress(Some("gcid:abcdef"));
            tokio::time::timeout(
                Duration::from_secs(1),
                attempt(&http, &url, 8, &partial, false, progress.clone(), None),
            )
            .await
            .unwrap()
            .map_err(DlError::into_inner)
            .unwrap();
            assert!(
                tokio::time::timeout(Duration::from_millis(25), listener.accept())
                    .await
                    .is_err()
            );
            assert_eq!(progress.transferred_bytes(), 0);
            assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
        }
        for (saved_revision, current_revision, durable_bytes, file_id) in [
            (Some("gcid:ABCDEF"), Some("gcid:ABCDEF"), None, "file"),
            (Some("gcid:OLD"), Some("gcid:ABCDEF"), Some(8), "file"),
            (None, Some("gcid:ABCDEF"), Some(8), "file"),
            (Some("gcid:ABCDEF"), None, Some(8), "file"),
            (
                Some("modified:unchanged"),
                Some("modified:unchanged"),
                Some(8),
                "file",
            ),
            (
                Some("gcid:ABCDEF"),
                Some("gcid:ABCDEF"),
                Some(8),
                "other-file",
            ),
            (Some("gcid:ABCDEF"), Some("gcid:ABCDEF"), Some(3), "file"),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            std::fs::write(&partial, b"abcdefgh").unwrap();
            ResumeState {
                file_id: file_id.into(),
                total: 8,
                etag: "\"guest\"".into(),
                source_revision: saved_revision.map(str::to_owned),
                require_content_hash: true,
                source_key: None,
                durable_bytes,
                unverified_tail: None,
                prefix_sha256: durable_bytes
                    .map(|bytes| integrity::fixture_digest(&partial, 0, bytes)),
            }
            .save(&partial)
            .unwrap();
            let (url, request) = server(200, "ETag: \"guest\"\r\n", b"abcdefgh", false).await;
            let progress = hashed_progress(current_revision);
            attempt(&http, &url, 8, &partial, false, progress.clone(), None)
                .await
                .map_err(DlError::into_inner)
                .unwrap();
            assert!(request.await.unwrap().starts_with("get "));
            assert_eq!(
                progress.transferred_bytes(),
                8,
                "Unproven complete checkpoint bypassed content validation"
            );
            assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
        }
    }

    #[tokio::test]
    async fn mid_body_socket_drop_preserves_confirmed_prefix_and_resumes_missing_bytes() {
        assert_interrupted_body_resumes(false).await;
    }

    #[tokio::test]
    async fn read_idle_timeout_preserves_confirmed_prefix_and_resumes_missing_bytes() {
        assert_interrupted_body_resumes(true).await;
    }

    async fn assert_interrupted_body_resumes(read_idle_timeout: bool) {
        for content_hash in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("original.part");
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}/original", listener.local_addr().unwrap());
            let (release, closed) = tokio::sync::oneshot::channel();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                    let mut chunk = [0; 4096];
                    let count = socket.read(&mut chunk).await.unwrap();
                    assert!(count > 0);
                    request.extend_from_slice(&chunk[..count]);
                }
                socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: \"guest\"\r\nConnection: close\r\n\r\nabc").await.unwrap();
                // Drop the socket without completing the declared body, or
                // retain it without sending bytes until the client times out.
                closed.await.unwrap();
                String::from_utf8(request).unwrap().to_lowercase()
            });
            let progress = if content_hash {
                hashed_progress(Some("gcid:ABCDEF"))
            } else {
                progress()
            };
            let http = reqwest::Client::builder()
                .no_proxy()
                .read_timeout(Duration::from_millis(if read_idle_timeout {
                    400
                } else {
                    3000
                }))
                .build()
                .unwrap();
            let result = if read_idle_timeout {
                let result = attempt(&http, &url, 8, &partial, false, progress.clone(), None).await;
                release.send(()).unwrap();
                result
            } else {
                let observer = async {
                    tokio::time::timeout(Duration::from_secs(2), async {
                        while progress.transferred_bytes() != 3 {
                            tokio::time::sleep(Duration::from_millis(5)).await;
                        }
                    })
                    .await
                    .expect("The socket was dropped before its prefix was consumed");
                    release.send(()).unwrap();
                };
                tokio::join!(
                    attempt(&http, &url, 8, &partial, false, progress.clone(), None),
                    observer
                )
                .0
            };
            let failure = result
                .err()
                .expect("Incomplete body unexpectedly completed");
            assert!(matches!(&failure, DlError::Retryable(_)));
            let error = failure.into_inner();
            assert!(download_policy::retryable(&error));
            assert!(
                error
                    .chain()
                    .filter_map(|cause| cause.downcast_ref::<reqwest::Error>())
                    .any(|cause| if read_idle_timeout {
                        cause.is_timeout()
                    } else {
                        cause.is_body() || cause.is_decode()
                    }),
                "Expected the selected body transport failure: {error:#}"
            );
            assert!(
                !pikpak::content_mode::content_access_denied(&error),
                "Network interruption triggered User handoff"
            );
            assert!(!error.is::<PartialContent>());
            assert_eq!(progress.transferred_bytes(), 3);
            assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
            let saved = ResumeState::load(&partial, "file", 8).unwrap().unwrap();
            assert_eq!(saved.durable_bytes, Some(3));
            assert_eq!(saved.etag, "\"guest\"");
            assert_eq!(
                saved.source_revision.as_deref(),
                if content_hash {
                    Some("gcid:ABCDEF")
                } else {
                    None
                }
            );
            assert!(!server.await.unwrap().contains("range:"));
            let (url, request) = server_with_declared_length(
                206,
                "ETag: \"guest\"\r\nContent-Range: bytes 3-7/8\r\n",
                b"defgh",
                false,
                5,
            )
            .await;
            attempt(&http, &url, 8, &partial, false, progress.clone(), None)
                .await
                .map_err(DlError::into_inner)
                .unwrap();
            let request = request.await.unwrap();
            assert!(request.contains("range: bytes=3-\r\n"));
            assert_eq!(request.contains("if-range: \"guest\"\r\n"), !content_hash);
            assert_eq!(
                progress.transferred_bytes(),
                8,
                "The confirmed prefix was downloaded again"
            );
            assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
            assert_eq!(
                ResumeState::load(&partial, "file", 8)
                    .unwrap()
                    .unwrap()
                    .durable_bytes,
                Some(8)
            );
        }
    }

    #[tokio::test]
    async fn hard_stop_uncommitted_tail_is_discarded_before_resuming() {
        let directory = tempfile::tempdir().unwrap();
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "download_transport::tests::hard_stop_checkpoint_child",
                "--ignored",
            ])
            .env("PIKPAK_DURABILITY_FIXTURE", directory.path())
            .output()
            .unwrap();
        assert!(
            child.status.success(),
            "{}",
            String::from_utf8_lossy(&child.stderr)
        );
        let partial = directory.path().join("original.part");
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcXXXXX");
        let (url, request) = server(
            206,
            "ETag: \"current\"\r\nContent-Range: bytes 3-7/8\r\n",
            b"defgh",
            false,
        )
        .await;
        attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            progress(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert!(request.await.unwrap().contains("range: bytes=3-\r\n"));
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
        assert_eq!(
            ResumeState::load(&partial, "file", 8)
                .unwrap()
                .unwrap()
                .durable_bytes,
            Some(8)
        );
    }

    #[test]
    #[ignore = "isolated hard stop; launched by hard_stop_uncommitted_tail_is_discarded_before_resuming"]
    fn hard_stop_checkpoint_child() {
        use std::io::{Seek, Write};
        let root = PathBuf::from(std::env::var_os("PIKPAK_DURABILITY_FIXTURE").unwrap());
        let partial = root.join("original.part");
        let mut file = crate::download_fs::open(
            &partial,
            rustix::fs::OFlags::CREATE | rustix::fs::OFlags::RDWR,
        )
        .unwrap();
        file.write_all(b"abc").unwrap();
        file.sync_data().unwrap();
        seed_resume(&partial, "file", 8, "\"current\"");
        file.seek(SeekFrom::End(0)).unwrap();
        file.write_all(b"XXXXX").unwrap();
        // The tail reached the filesystem, but no sync/checkpoint followed.
        // exit bypasses normal transfer cleanup, like an abrupt helper stop.
        std::process::exit(0);
    }

    #[tokio::test]
    async fn missing_destination_preserves_checkpoint_and_propagates_sidecar_io_error() {
        let directory = tempfile::tempdir().unwrap();
        let selected = directory.path().join("selected");
        std::fs::create_dir(&selected).unwrap();
        let selected = crate::download_fs::selected_directory(&selected).unwrap();
        let partial = selected.join("original.part");
        let file = crate::download_fs::open_async(
            &partial,
            rustix::fs::OFlags::CREATE | rustix::fs::OFlags::RDWR,
        )
        .await
        .unwrap();
        let mut out = BufWriter::new(file);
        out.write_all(b"abc").await.unwrap();
        let state = ResumeState {
            file_id: "file".into(),
            total: 8,
            etag: "\"current\"".into(),
            source_revision: None,
            require_content_hash: false,
            source_key: None,
            durable_bytes: None,
            unverified_tail: None,
            prefix_sha256: None,
        };
        checkpoint(&mut out, &partial, Some(&state), 3, &fixture_hash(b"abc"))
            .await
            .map_err(DlError::into_inner)
            .unwrap();
        let journal = std::fs::read(state_path(&partial)).unwrap();
        out.write_all(b"XXXXX").await.unwrap();
        let detached = directory.path().join("detached");
        std::fs::rename(&selected, &detached).unwrap();
        assert!(checkpoint(
            &mut out,
            &partial,
            Some(&state),
            8,
            &fixture_hash(b"abcdefgh")
        )
        .await
        .is_err());
        assert!(
            ResumeState::load(&partial, "file", 8).is_err(),
            "Unavailable storage was treated as absent metadata"
        );
        drop(out);
        assert!(
            !selected.exists(),
            "Checkpoint recreated an unavailable destination"
        );
        assert_eq!(
            std::fs::read(detached.join("original.part.resume.json")).unwrap(),
            journal
        );
        assert_eq!(
            std::fs::read(detached.join("original.part")).unwrap(),
            b"abc"
        );
        std::fs::rename(&detached, &selected).unwrap();
        let (url, request) = server(
            206,
            "ETag: \"current\"\r\nContent-Range: bytes 3-7/8\r\n",
            b"defgh",
            false,
        )
        .await;
        attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            progress(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert!(request.await.unwrap().contains("range: bytes=3-\r\n"));
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
    }

    #[tokio::test]
    async fn replaced_staging_file_preserves_previous_checkpoint() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("original.part");
        let file = crate::download_fs::open_async(
            &partial,
            rustix::fs::OFlags::CREATE | rustix::fs::OFlags::RDWR,
        )
        .await
        .unwrap();
        let mut out = BufWriter::new(file);
        let state = ResumeState {
            file_id: "file".into(),
            total: 8,
            etag: "\"current\"".into(),
            source_revision: None,
            require_content_hash: false,
            source_key: None,
            durable_bytes: None,
            unverified_tail: None,
            prefix_sha256: None,
        };
        out.write_all(b"abc").await.unwrap();
        checkpoint(&mut out, &partial, Some(&state), 3, &fixture_hash(b"abc"))
            .await
            .map_err(DlError::into_inner)
            .unwrap();
        let journal = std::fs::read(state_path(&partial)).unwrap();
        let held = directory.path().join("original.held");
        std::fs::rename(&partial, &held).unwrap();
        std::fs::write(&partial, b"XYZ").unwrap();
        out.write_all(b"defgh").await.unwrap();
        assert!(checkpoint(
            &mut out,
            &partial,
            Some(&state),
            8,
            &fixture_hash(b"abcdefgh")
        )
        .await
        .is_err());
        drop(out);
        assert_eq!(std::fs::read(state_path(&partial)).unwrap(), journal);
        assert_eq!(std::fs::read(&partial).unwrap(), b"XYZ");
        assert_eq!(std::fs::read(&held).unwrap(), b"abc");
    }

    #[tokio::test]
    async fn legacy_checkpoint_without_durable_length_validates_full_original() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("original.part");
        std::fs::write(&partial, b"abcXXXXX").unwrap();
        std::fs::write(
            state_path(&partial),
            br#"{"file_id":"file","total":8,"etag":"\"current\""}"#,
        )
        .unwrap();
        let (url, request) = server(200, "ETag: \"current\"\r\n", b"abcdefgh", false).await;
        attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            progress(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert!(!request.await.unwrap().contains("range:"));
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
        assert_eq!(
            ResumeState::load(&partial, "file", 8)
                .unwrap()
                .unwrap()
                .durable_bytes,
            Some(8)
        );
    }

    #[tokio::test]
    async fn stalled_stream_commits_durable_prefix_without_waiting_for_next_chunk() {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("original.part");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/original", listener.local_addr().unwrap());
        let (release, resume) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let mut chunk = [0; 4096];
                let count = socket.read(&mut chunk).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&chunk[..count]);
            }
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: \"current\"\r\nConnection: close\r\n\r\nabc").await.unwrap();
            resume.await.unwrap();
            socket.write_all(b"defgh").await.unwrap();
        });
        let observer = async {
            tokio::time::timeout(Duration::from_secs(4), async {
                loop {
                    if ResumeState::load(&partial, "file", 8)
                        .unwrap()
                        .is_some_and(|state| state.durable_bytes == Some(3))
                    {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            })
            .await
            .expect("Stalled body never committed its prefix");
            release.send(()).unwrap();
        };
        let http = reqwest::Client::new();
        let (result, ()) = tokio::join!(
            attempt(&http, &url, 8, &partial, false, progress(), None),
            observer
        );
        result.map_err(DlError::into_inner).unwrap();
        server.await.unwrap();
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
    }
    #[tokio::test]
    async fn changed_checkpoint_bytes_and_legacy_digests_require_remote_validation() {
        for prefix in [3, 8] {
            for mutation in ["replace", "edit", "legacy", "invalid_etag"] {
                let directory = tempfile::tempdir().unwrap();
                let partial = directory.path().join("original.part");
                std::fs::write(&partial, &b"abcdefgh"[..prefix]).unwrap();
                ResumeState {
                    file_id: "file".into(),
                    total: 8,
                    etag: "\"original\"".into(),
                    source_revision: Some("gcid:ORIGINAL".into()),
                    require_content_hash: true,
                    source_key: None,
                    durable_bytes: Some(prefix as u64),
                    unverified_tail: None,
                    prefix_sha256: Some(integrity::fixture_digest(&partial, 0, prefix as u64)),
                }
                .save(&partial)
                .unwrap();
                match mutation {
                    "replace" => {
                        let replacement = directory.path().join("replacement");
                        std::fs::write(&replacement, vec![b'X'; prefix]).unwrap();
                        std::fs::rename(replacement, &partial).unwrap();
                    }
                    "edit" => std::fs::write(&partial, vec![b'X'; prefix]).unwrap(),
                    "legacy" => {
                        let mut saved: serde_json::Value =
                            serde_json::from_slice(&std::fs::read(state_path(&partial)).unwrap())
                                .unwrap();
                        saved.as_object_mut().unwrap().remove("prefix_sha256");
                        std::fs::write(state_path(&partial), serde_json::to_vec(&saved).unwrap())
                            .unwrap();
                    }
                    "invalid_etag" => {
                        let mut saved: serde_json::Value =
                            serde_json::from_slice(&std::fs::read(state_path(&partial)).unwrap())
                                .unwrap();
                        saved["etag"] = serde_json::json!("\"bad\r\nIf-Range: forged\"");
                        std::fs::write(state_path(&partial), serde_json::to_vec(&saved).unwrap())
                            .unwrap();
                    }
                    _ => unreachable!(),
                }
                let (url, request) =
                    server(200, "ETag: \"original\"\r\n", b"abcdefgh", false).await;
                let progress = hashed_progress(Some("gcid:ORIGINAL"));
                attempt(
                    &reqwest::Client::new(),
                    &url,
                    8,
                    &partial,
                    false,
                    progress.clone(),
                    None,
                )
                .await
                .map_err(DlError::into_inner)
                .unwrap();
                assert!(
                    !request.await.unwrap().contains("range:"),
                    "{mutation} prefix {prefix} was trusted"
                );
                assert_eq!(progress.transferred_bytes(), 8);
                assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
                assert_eq!(
                    completed_digest(&partial, "file", 8).unwrap().unwrap(),
                    integrity::fixture_digest(&partial, 0, 8)
                );
            }
        }
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn unfinished_download_resumes_after_files_move_from_exfat_to_apfs() {
        let root = tempfile::tempdir().unwrap();
        let exfat = TestDisk::new(root.path(), "exfat", "ExFAT", 64);
        let before = exfat.mount.join("Videos");
        std::fs::create_dir_all(&before).unwrap();
        let partial = before.join("original.part");
        let (url, request) = server(200, "", b"abc", false).await;
        let error = attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &partial,
            false,
            hashed_progress(Some("gcid:ABCDEF")),
            None,
        )
        .await
        .err()
        .unwrap()
        .into_inner();
        assert!(error.is::<PartialContent>());
        request.await.unwrap();
        assert_eq!(std::fs::read(&partial).unwrap(), b"abc");
        assert!(before.join("original.part.resume.json").exists());

        // Back the unfinished files up, reformat the disk as APFS, then put them back.
        let backup = root.path().join("Backup");
        let names = copy_files(&before, &backup, "original.part");
        assert_eq!(names, ["original.part", "original.part.resume.json"]);
        drop(exfat);
        let apfs = TestDisk::new(root.path(), "apfs", "APFS", 64);
        let after = apfs.mount.join("Videos");
        copy_files(&backup, &after, "original.part");

        let restored = after.join("original.part");
        let (url, request) = server(206, "Content-Range: bytes 3-7/8\r\n", b"defgh", false).await;
        let progress = hashed_progress(Some("gcid:abcdef"));
        attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &restored,
            false,
            progress.clone(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        let request = request.await.unwrap();
        assert!(
            request.contains("range: bytes=3-\r\n"),
            "The restored prefix was not reused: {request}"
        );
        assert_eq!(progress.transferred_bytes(), 5);
        assert_eq!(std::fs::read(&restored).unwrap(), b"abcdefgh");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn part_restored_without_its_checkpoint_restarts_instead_of_trusting_unproven_bytes() {
        let root = tempfile::tempdir().unwrap();
        let apfs = TestDisk::new(root.path(), "apfs", "APFS", 64);
        let folder = apfs.mount.join("Videos");
        std::fs::create_dir_all(&folder).unwrap();
        let restored = folder.join("original.part");
        std::fs::write(&restored, b"abc").unwrap();
        let (url, request) = server(200, "ETag: \"user-cdn\"\r\n", b"abcdefgh", false).await;
        let progress = hashed_progress(Some("gcid:abcdef"));
        attempt(
            &reqwest::Client::new(),
            &url,
            8,
            &restored,
            false,
            progress.clone(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert!(!request.await.unwrap().contains("range:"));
        assert_eq!(progress.transferred_bytes(), 8);
        assert_eq!(std::fs::read(&restored).unwrap(), b"abcdefgh");
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
    fn load(part: &Path, file_id: &str, total: u64) -> anyhow::Result<Option<Self>> {
        let path = state_path(part);
        let metadata = match crate::download_fs::metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        if !metadata.is_file() || metadata.len() > 16 * 1024 {
            return Ok(None);
        }
        let Ok(state) = serde_json::from_slice::<Self>(&crate::download_fs::read(&path)?) else {
            return Ok(None);
        };
        Ok((state.file_id == file_id
            && state.total == total
            && total > 0
            && state.durable_bytes.is_none_or(|bytes| bytes <= total)
            && state.unverified_tail.is_none_or(|tail| tail <= total
                && state.durable_bytes.is_some_and(|bytes| bytes <= tail))
            && ((state.etag.starts_with('"')
                && state.etag.ends_with('"')
                && header::HeaderValue::from_str(&state.etag).is_ok())
                || state.etag.is_empty()
                    && pikpak::content_mode::matching_content_revision(
                        state.source_revision.as_deref(),
                        state.source_revision.as_deref(),
                    )))
        .then_some(state))
    }

    fn save(&self, part: &Path) -> anyhow::Result<()> {
        crate::download_fs::validate(part)?;
        crate::download_fs::atomic_write(&state_path(part), &serde_json::to_vec(self)?)?;
        Ok(())
    }

    async fn save_async(&self, part: &Path) -> anyhow::Result<()> {
        let state = self.clone();
        let part = part.to_owned();
        tokio::task::spawn_blocking(move || state.save(&part)).await?
    }
}

/// Physical length can include writes which preceded a failed sync or journal
/// commit. Only the recorded durable prefix is eligible for a Range request.
#[cfg(test)]
async fn recover_durable_prefix(
    part: &Path,
    file_id: &str,
    total: u64,
    control_id: &str,
) -> Result<Option<integrity::Prefix>, DlError> {
    recover_durable_prefix_cached(part, file_id, total, control_id, &RetryState::default()).await
}

async fn recover_durable_prefix_cached(
    part: &Path,
    file_id: &str,
    total: u64,
    control_id: &str,
    retry_state: &RetryState,
) -> Result<Option<integrity::Prefix>, DlError> {
    Ok(recover_durable_prefix_partitioned(part, file_id, total, control_id, retry_state, None)
        .await?.map(|result| result.0))
}

async fn recover_durable_prefix_partitioned(
    part: &Path,
    file_id: &str,
    total: u64,
    control_id: &str,
    retry_state: &RetryState,
    partitions: Option<&[u64]>,
) -> Result<Option<(integrity::Prefix, Vec<integrity::Prefix>)>, DlError> {
    let Some(saved) = ResumeState::load(part, file_id, total).map_err(DlError::Fatal)? else {
        return Ok(None);
    };
    let (Some(bytes), Some(digest)) = (saved.durable_bytes, saved.prefix_sha256.as_deref()) else {
        return Ok(None);
    };
    let metadata = match crate::download_fs::metadata_async(part).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(fatal(error, "Cannot inspect durable download progress")),
    };
    if metadata.len() < bytes {
        return Ok(None);
    }
    // An interrupted writer may have received every byte without observing
    // EOF. Its incremental context must never replace final disk read-back.
    let cached = (bytes < total && partitions.is_none()).then(|| retry_state.prefix(part, &saved)).flatten();
    let (mut verified, mut pieces) = match (partitions, cached) {
        (Some(partitions), _) => integrity::Prefix::read_partitioned(part, bytes, partitions, control_id).await?,
        (_, Some(hash)) => (hash, Vec::new()),
        _ => (integrity::Prefix::read(part, 0, bytes, control_id).await?, Vec::new()),
    };
    if verified.digest() != digest {
        // Preserve the contiguous data for the legacy full-response comparison.
        // A remote validator does not certify a locally modified prefix.
        crate::download_fs::remove_file(&state_path(part))
            .map_err(|error| fatal(error, "Cannot invalidate changed download checkpoint"))?;
        return Ok(None);
    }
    // Only a deliberately retained comparison tail may survive recovery.
    // Newly written data beyond the last journal boundary is still discarded.
    let retained = saved.unverified_tail.unwrap_or(bytes).min(metadata.len()).max(bytes);
    if metadata.len() > retained {
        crate::download_fs::validate(part)
            .map_err(|error| fatal(error, "Download destination is unavailable"))?;
        let file = crate::download_fs::open_async(part, rustix::fs::OFlags::RDWR)
            .await
            .map_err(|error| fatal(error, "Cannot recover durable download progress"))?;
        let opened = file
            .metadata()
            .await
            .map_err(|error| fatal(error, "Cannot inspect recovered download"))?;
        verified.validate_restored(&opened)?;
        crate::download_fs::validate_open_file(part, &opened)
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        file.set_len(retained)
            .await
            .map_err(|error| fatal(error, "Cannot discard uncommitted download tail"))?;
        file.sync_data()
            .await
            .map_err(|error| fatal(error, "Cannot sync recovered download progress"))?;
        let recovered = file
            .metadata()
            .await
            .map_err(|error| fatal(error, "Cannot inspect recovered download progress"))?;
        crate::download_fs::validate_open_file(part, &recovered)
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        verified.adopt_verified_metadata(&recovered);
        for piece in &mut pieces { piece.adopt_verified_metadata(&recovered); }
    }
    retry_state.remember_verified_prefix(part, &saved, &verified).await;
    Ok(Some((verified, pieces)))
}

struct CheckpointProof {
    state: ResumeState,
    metadata: std::fs::Metadata,
}

#[cfg(test)]
async fn checkpoint(
    out: &mut BufWriter<tokio::fs::File>, part: &Path, state: Option<&ResumeState>,
    durable_bytes: u64, hash: &integrity::Prefix,
) -> Result<Option<CheckpointProof>, DlError> {
    checkpoint_for_transfer(state.map_or("", |state| state.file_id.as_str()), out, part, state, durable_bytes, hash).await
}

async fn checkpoint_for_transfer(
    control_id: &str,
    out: &mut BufWriter<tokio::fs::File>,
    part: &Path,
    state: Option<&ResumeState>,
    durable_bytes: u64,
    hash: &integrity::Prefix,
) -> Result<Option<CheckpointProof>, DlError> {
    let mut diagnostic = crate::download_telemetry::Operation::new(
        crate::download_telemetry::Kind::Checkpoint, state.map_or("", |state| state.file_id.as_str()));
    let gate = crate::download_verification::WriteGate::new(out.get_ref(), control_id);
    let write_turn = gate.turn(false).await;
    let before = out.get_ref().metadata().await
        .map_err(|error| fatal(error, "Cannot inspect download staging file"))?;
    crate::download_fs::validate_open_file(part, &before)
    .map_err(|error| fatal(error, "Download destination is unavailable"))?;
    out.flush()
        .await
        .map_err(|error| fatal(error, "Cannot flush download progress"))?;
    crate::download_fs::validate(part)
        .map_err(|error| fatal(error, "Download destination is unavailable"))?;
    drop(write_turn);
    let synced = out.get_ref().metadata().await
        .map_err(|error| fatal(error, "Cannot inspect download staging file"))?;
    crate::download_fs::validate_open_file(part, &synced)
    .map_err(|error| fatal(error, "Download staging file changed"))?;
    if let Some(state) = state {
        if hash.bytes != durable_bytes {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Download checkpoint does not match its verified bytes"
            )));
        }
        let mut committed = state.clone();
        committed.durable_bytes = Some(durable_bytes);
        committed.prefix_sha256 = Some(hash.digest());
        committed.unverified_tail = (durable_bytes < synced.len()).then_some(synced.len());
        let journal = serde_json::to_vec(&committed).map_err(|error| fatal(error, "Cannot serialize download progress"))?;
        crate::download_checkpoint::commit(&gate, out.get_ref(), synced.clone(), part, &state_path(part), journal).await.map_err(DlError::Fatal)?;
        diagnostic.complete();
        return Ok(Some(CheckpointProof { state: committed, metadata: synced }));
    }
    let _turn = gate.checkpoint_turn().await;
    let mut saving = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::CheckpointSync, control_id);
    out.get_ref().sync_data().await.map_err(|error| fatal(error, "Cannot sync download progress"))?;
    saving.complete(); diagnostic.complete();
    Ok(None)
}

async fn flush_progress(out: &mut BufWriter<tokio::fs::File>, part: &Path, control_id: &str) -> Result<(), DlError> {
    let _write_turn = crate::download_verification::write_async(out.get_ref(), control_id, false).await;
    crate::download_fs::validate_open_file(
        part,
        &out.get_ref()
            .metadata()
            .await
            .map_err(|error| fatal(error, "Cannot inspect download staging file"))?,
    )
    .map_err(|error| fatal(error, "Download destination is unavailable"))?;
    out.flush()
        .await
        .map_err(|error| fatal(error, "Cannot flush download progress"))
}

async fn complete_durable_partial(
    part: &Path,
    file_id: &str,
    total: u64,
    source_revision: Option<&str>,
    verified: &integrity::Prefix,
) -> Result<bool, DlError> {
    let Some(saved) = ResumeState::load(part, file_id, total).map_err(DlError::Fatal)? else {
        return Ok(false);
    };
    if total == 0
        || saved.durable_bytes != Some(total)
        || !pikpak::content_mode::matching_content_revision(
            saved.source_revision.as_deref(),
            source_revision,
        )
    {
        return Ok(false);
    }
    let metadata = match crate::download_fs::metadata_async(part).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(fatal(error, "Cannot inspect completed download checkpoint")),
    };
    if !metadata.is_file() || metadata.len() != total {
        return Ok(false);
    }
    let file = crate::download_fs::open_async(part, rustix::fs::OFlags::RDONLY)
        .await
        .map_err(|error| fatal(error, "Cannot open completed download checkpoint"))?;
    let opened = file
        .metadata()
        .await
        .map_err(|error| fatal(error, "Cannot inspect completed download checkpoint"))?;
    crate::download_fs::validate_open_file(part, &opened)
        .map_err(|error| fatal(error, "Download staging file changed"))?;
    verified.validate_restored(&opened)?;
    Ok(opened.len() == total)
}

#[cfg(test)]
pub(super) fn seed_resume(part: &Path, file_id: &str, total: u64, etag: &str) {
    ResumeState {
        file_id: file_id.into(),
        total,
        etag: etag.into(),
        source_revision: None,
        require_content_hash: false,
        source_key: None,
        durable_bytes: crate::download_fs::metadata(part)
            .ok()
            .map(|metadata| metadata.len()),
        unverified_tail: None,
        prefix_sha256: Some(integrity::fixture_digest(
            part,
            0,
            crate::download_fs::metadata(part).unwrap().len(),
        )),
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

#[cfg(test)]
pub(super) async fn attempt(
    http: &reqwest::Client,
    link: &str,
    total: u64,
    part: &Path,
    show_progress: bool,
    progress: DownloadProgressContext<'_>,
    referer: Option<&str>,
) -> Result<(), DlError> {
    attempt_for_publication(http, link, total, part, show_progress, progress, referer)
        .await
        .map(|_| ())
}

async fn partial_length(part: &Path) -> Result<u64, DlError> {
    let length = match crate::download_fs::metadata_async(part).await {
        Ok(metadata) if metadata.is_file() => metadata.len(),
        Ok(_) => {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Partial download is not a regular file"
            )))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
        Err(error) => return Err(fatal(error, "Cannot inspect partial download")),
    };
    Ok(length)
}

pub(super) async fn attempt_for_publication(
    http: &reqwest::Client,
    link: &str,
    total: u64,
    part: &Path,
    show_progress: bool,
    progress: DownloadProgressContext<'_>,
    referer: Option<&str>,
) -> Result<Option<VerifiedCompletion>, DlError> {
    progress.retry_state.set_final_verification_pending(false);
    match parts::attempt_outcome(http, link, total, part, show_progress, &progress, referer).await? {
        parts::Outcome::Complete(verified) => {
            progress.retry_state.clear(); return Ok(Some(verified));
        }
        parts::Outcome::Sequential { .. } => {}
    }
    let mut existing = partial_length(part).await?;
    let mut checkpoint = ResumeState::load(part, progress.source_file_id, total).map_err(DlError::Fatal)?;
    if existing == total && total > 0 && checkpoint.as_ref().is_some_and(|saved| {
        saved.durable_bytes == Some(total) && saved.prefix_sha256.is_some()
            && pikpak::content_mode::matching_content_revision(
                saved.source_revision.as_deref(), progress.source_revision.as_deref())
    }) {
        progress.retry_state.set_final_verification_pending(true);
    }
    // A bound checkpoint supplies speculative HTTP coordinates. Its checksum
    // still has to pass before accepting those coordinates as disk coverage.
    let mut prefetch_permit = checkpoint.as_ref().filter(|saved| {
        saved.prefix_sha256.is_some() && saved.durable_bytes.is_some_and(|bytes| bytes > 0 && bytes < total)
            && resume_plan(Some(saved), true, existing, total, &progress, link).is_ok()
    }).and_then(|saved| crate::download_buffer::prefetch_slot(saved.durable_bytes.unwrap(), total.saturating_sub(saved.durable_bytes.unwrap())));
    let mut restored = if prefetch_permit.is_some() { None } else {
        let restored = recover_durable_prefix_cached(part, progress.source_file_id, total,
            progress.file_id, &progress.retry_state).await?;
        existing = partial_length(part).await?;
        checkpoint = ResumeState::load(part, progress.source_file_id, total).map_err(DlError::Fatal)?;
        restored
    };
    // A crash can leave a fully synced original awaiting receipt publication.
    // Fresh matching GCID metadata proves its identity without spending quota
    // or asking a capped Guest CDN to validate an already complete range.
    if restored.as_ref().is_some_and(|hash| hash.bytes == total)
        && complete_durable_partial(
            part,
            progress.source_file_id,
            total,
            progress.source_revision.as_deref(),
            restored.as_ref().unwrap(),
        )
        .await?
    {
        progress.emit(total, total);
        progress.retry_state.clear();
        return VerifiedCompletion::from_prefix(
            part,
            restored.unwrap(),
            progress.source_file_id,
            progress.source_revision.as_deref(),
        )
        .await
        .map(Some);
    }
    progress.retry_state.set_final_verification_pending(false);
    crate::download_verification::ready_to_receive(progress.file_id).await.map_err(DlError::Fatal)?;
    let network = pikpak::download_network::Network::for_url(link);
    let _participant = network.register();
    let _channel = transfer_control::interruptible(progress.file_id, network.acquire())
        .await
        .map_err(DlError::Fatal)?
        .map_err(|error| fatal(error, "Cannot reserve download connection"))?;
    let plan = resume_plan(checkpoint.as_ref(), restored.is_some() || prefetch_permit.is_some(), existing, total, &progress, link);
    crate::download_telemetry::resume(
        plan.as_ref().map_or_else(|kind| *kind, |_| crate::download_telemetry::Kind::ResumeRange), existing);
    let saved = plan.ok();
    let same_revision = saved.as_ref().is_some_and(|state| {
        pikpak::content_mode::matching_content_revision(
            state.source_revision.as_deref(),
            progress.source_revision.as_deref(),
        )
    });
    let ranged = saved.is_some();
    let resume_offset = saved.and_then(|state| state.durable_bytes).unwrap_or(0);
    if ranged && resume_offset < existing {
        crate::download_telemetry::resume(crate::download_telemetry::Kind::ResumeTail, existing - resume_offset);
    }
    let mut request = http.get(link).header(header::ACCEPT_ENCODING, "identity");
    if let Some(referer) = referer {
        request = request.header(header::REFERER, referer);
    }
    if ranged {
        request = request.header(header::RANGE, format!("bytes={resume_offset}-"));
        // Different guest/account CDNs may assign different entity tags to the
        // same verified original. Its GCID and size establish the byte identity.
        if !same_revision {
            request = request.header(header::IF_RANGE, &saved.as_ref().unwrap().etag);
        }
    }
    let response = transfer_control::interruptible(progress.file_id,
        pikpak::download_waits::track(pikpak::download_waits::Kind::ContentHeaders, request.send()))
        .await
        .map_err(DlError::Fatal)?
        .map_err(|error| {
            pikpak::download_waits::payload_event(if error.is_timeout() { pikpak::download_waits::PayloadEvent::Timeout }
                else { pikpak::download_waits::PayloadEvent::Connection });
            classify(error, "Download request failed")
        })?;
    let status = response.status();
    pikpak::download_waits::payload_response(status.as_u16());
    if ranged && matches!(status, StatusCode::OK | StatusCode::PARTIAL_CONTENT) {
        crate::download_telemetry::resume(if status == StatusCode::PARTIAL_CONTENT {
            crate::download_telemetry::Kind::ResumeAccepted
        } else { crate::download_telemetry::Kind::ResumeFull }, existing);
    }
    if status == StatusCode::RANGE_NOT_SATISFIABLE && ranged {
        let server_total = response
            .headers()
            .get(header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("bytes */"))
            .and_then(|value| value.parse::<u64>().ok());
        if resume_offset == total
            && server_total == Some(total)
            && (same_revision
                || strong_etag(response.headers()).as_deref()
                    == saved.as_ref().map(|state| state.etag.as_str()))
        {
            return Ok(None);
        }
        if resume_offset < total && server_total.is_some_and(|cap| cap <= resume_offset) {
            // The selected original is larger than the range available through
            // this route. Preserve the validated prefix for Dynamic's fallback.
            return Err(DlError::Fatal(ContentUnavailable.into()));
        }
        if resume_offset < total && progress.guest_range_fallback {
            // Some Guest CDNs omit the unsatisfied-range header. The prefix
            // has already passed checksum/source validation; retain it while
            // Dynamic refreshes Guest once and then requests the User suffix.
            return Err(DlError::Fatal(
                HttpFailure {
                    status: 416,
                    retry_after: download_policy::retry_after(response.headers()),
                }
                .into(),
            ));
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
            network
                .defer(failure.retry_after.unwrap_or(Duration::from_secs(1)))
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
    if response
        .headers()
        .get(header::CONTENT_ENCODING)
        .is_some_and(|encoding| encoding != "identity")
    {
        return Err(DlError::Fatal(anyhow::anyhow!(
            "The download service returned an encoded original"
        )));
    }
    let response_etag = strong_etag(response.headers());
    let response_range = content_range(response.headers());
    let declared_length = response.content_length();
    if status == StatusCode::OK && total > 0 && declared_length.is_some_and(|length| length > total) {
        // Reject a known oversized original before touching a retained prefix
        // or downloading it again. Dynamic can immediately use the User route.
        return Err(DlError::Fatal(download_policy::OriginalSizeMismatch {
            expected: total,
            received: declared_length.unwrap(),
        }.into()));
    }
    let start = if status == StatusCode::PARTIAL_CONTENT {
        let valid = response_range.is_some_and(|(start, end, length)| {
            start == if ranged { resume_offset } else { 0 }
                && length == total
                && declared_length.is_none_or(|length| length == end - start + 1)
                && (!ranged
                    || same_revision
                    || response.headers().get(header::ETAG).is_none_or(|tag| {
                        tag.to_str().ok() == saved.as_ref().map(|state| state.etag.as_str())
                    }))
        });
        if !valid {
            let error = anyhow::Error::new(download_policy::InvalidByteRange);
            if progress.guest_range_fallback {
                // A malformed Guest response cannot supply validated bytes.
                // Keep the proven prefix while Dynamic refreshes Guest once,
                // then switches this file to the User route in the same run.
                return Err(DlError::Fatal(error));
            }
            remove_state(part).map_err(DlError::Fatal)?;
            return Err(if ranged {
                DlError::Retryable(error)
            } else {
                DlError::Fatal(error)
            });
        }
        if ranged {
            resume_offset
        } else {
            0
        }
    } else if status == StatusCode::OK {
        // Keep the previous durable checkpoint until this full response has
        // validated its prefix or is about to replace changed bytes.
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
    let response_end = if status == StatusCode::PARTIAL_CONTENT {
        response_range.map(|(_, end, _)| end + 1)
    } else {
        declared_length
    };
    // A full/capped replay of the same entity does not invalidate its larger
    // proven checkpoint. Preserve that journal until comparison catches up;
    // a changed byte below the boundary explicitly demotes it before writing.
    let mut checkpoint_floor = if start == 0 && ranged && (same_revision
        || response_etag.as_deref() == saved.map(|state| state.etag.as_str())) {
        resume_offset
    } else { 0 };
    let mut raw_response = Some(response);
    let mut receive_channel = Some((_participant, _channel));
    let prefetched = if let Some(permit) = prefetch_permit.take() {
        let received = progress.receive_counter(); let receive_network = network.clone();
        Some(crate::download_buffer::Response::new_in_network(raw_response.take().unwrap(), move |bytes| {
            received(bytes); receive_network.record(bytes);
        }, receive_channel.take().unwrap(), Some(permit)))
    } else { None };
    if prefetched.is_some() {
        restored = recover_durable_prefix_cached(part, progress.source_file_id, total,
            progress.file_id, &progress.retry_state).await?;
        if restored.is_none() {
            checkpoint_floor = 0;
            if start > 0 {
                // A changed local prefix cannot be joined to a fetched suffix.
                // Recovery invalidated its journal; retry as a full comparison.
                drop(prefetched); drop(receive_channel);
                return Box::pin(attempt_for_publication(http, link, total, part, show_progress, progress, referer)).await;
            }
        }
    }
    let file =
        crate::download_fs::open_async(part, rustix::fs::OFlags::CREATE | rustix::fs::OFlags::RDWR)
            .await
            .map_err(|error| fatal(error, "Cannot open partial download"))?;
    if start > 0 {
        restored.as_ref().unwrap().validate_restored(
            &file
                .metadata()
                .await
                .map_err(|error| fatal(error, "Cannot inspect resumed download"))?,
        )?;
    }
    // HTTP chunks can be only a few KiB. Coalesce them before Tokio dispatches
    // filesystem work, with at most 256 KiB buffered per active disk download.
    // Flush explicitly before legacy reads/truncation; seeks also flush.
    let write_gate = crate::download_verification::WriteGate::new(&file, progress.file_id);
    let mut out = BufWriter::with_capacity(256 * 1024, file);
    let mut written = existing;
    if start == 0 && expected > 0 && written > expected {
        out.get_mut()
            .set_len(0)
            .await
            .map_err(|error| fatal(error, "Cannot reset oversized partial download"))?;
        written = 0;
    }
    let mut position = start;
    out.seek(SeekFrom::Start(position))
        .await
        .map_err(|error| fatal(error, "Cannot seek partial download"))?;
    let mut hash = if start > 0 {
        restored.unwrap()
    } else {
        integrity::Prefix::new()
    };
    let mut validator_saved = start > 0;
    let state = (response_etag.is_some()
        || pikpak::content_mode::matching_content_revision(
            progress.source_revision.as_deref(),
            progress.source_revision.as_deref(),
        ))
    .then(|| ResumeState {
        file_id: progress.source_file_id.to_owned(),
        total: expected,
        etag: response_etag.unwrap_or_default(),
        source_revision: progress.source_revision.clone(),
        require_content_hash: progress.require_content_hash,
        source_key: Some(source_key(link)),
        durable_bytes: None,
        unverified_tail: None,
        prefix_sha256: None,
    });
    if state.is_none() {
        crate::download_telemetry::resume(crate::download_telemetry::Kind::ResumeValidator, existing);
    }
    let mut response = match prefetched {
        Some(body) => { body.activate(); body },
        None => {
            let received = progress.receive_counter(); let receive_network = network.clone();
            crate::download_buffer::Response::new_in_network(raw_response.take().unwrap(), move |bytes| {
                received(bytes); receive_network.record(bytes);
            }, receive_channel.take().unwrap(), None)
        }
    };
    if written == 0 || start > 0 {
        if let Some(state) = &state {
            checkpoint_for_transfer(progress.file_id, &mut out, part, Some(state), position, &hash).await?;
            validator_saved = true;
        }
    }
    // The live writer owns the contexts now. Its next failed checkpoint can
    // cache them again; an old copy would become stale as soon as data grows.
    progress.retry_state.clear();
    progress.emit(written, expected);
    let mut last = Instant::now();
    // Saved every second on an internal disk, and every few seconds on an external disk or a network share.
    let mut schedule = crate::download_checkpoint::CheckpointSchedule::new(crate::download_fs::checkpoint_policy(part), Instant::now());
    let mut durable_bytes = if validator_saved { position } else { checkpoint_floor };
    loop {
        let received = {
          let receive = transfer_control::drainable(progress.file_id, response.chunk());
          tokio::pin!(receive);
          loop {
            tokio::select! {
                biased;
                _ = tokio::time::sleep_until(schedule.due_at().into()),
                    if position > durable_bytes && schedule.must_save(Instant::now()) => {
                    checkpoint_for_transfer(progress.file_id, &mut out, part, state.as_ref().filter(|_| validator_saved), position, &hash).await?;
                    durable_bytes = position;
                    schedule.saved(Instant::now());
                }
                result = &mut receive => break result,
                _ = tokio::time::sleep(Duration::from_millis(250).saturating_sub(last.elapsed())),
                    if !out.buffer().is_empty() => {
                    // A server can stall after a small chunk. Persist that
                    // chunk without waiting for another network read or Pause.
                    flush_progress(&mut out, part, progress.file_id).await?;
                    progress.emit(written, expected);
                    if show_progress && expected > 0 { eprint!("\r  {written} / {expected} bytes"); }
                    last = Instant::now();
                }
                _ = tokio::time::sleep_until(schedule.due_at().into()),
                    if position > durable_bytes => {
                    checkpoint_for_transfer(progress.file_id, &mut out, part, state.as_ref().filter(|_| validator_saved), position, &hash).await?;
                    durable_bytes = position;
                    schedule.saved(Instant::now());
                }
            }
          }
        };
        let received = if matches!(received, Ok(Ok(None))) && transfer_control::pause_receiving(progress.file_id)
            && (transfer_control::draining() || expected == 0 || written != expected) {
            Err(transfer_control::Paused.into())
        } else { received };
        let chunk = match received {
            Ok(Ok(Some(chunk))) => chunk,
            Ok(Ok(None)) => break,
            result => {
                response.stop();
                let committed = checkpoint_for_transfer(progress.file_id,
                    &mut out,
                    part,
                    state.as_ref().filter(|_| validator_saved),
                    position,
                    &hash,
                )
                .await?;
                if let Some(proof) = committed {
                    progress.retry_state.remember_prefix(part, &proof.state, out.get_ref(), &proof.metadata, &hash).await;
                }
                drop(out);
                progress.emit(written, expected);
                return match result {
                    Err(error) => {
                        if error.is::<transfer_control::Cancelled>() {
                            transfer_control::remove_owned_partial_as(
                                part,
                                progress.source_file_id,
                                progress.file_id,
                            )
                            .await
                            .map_err(DlError::Fatal)?;
                        }
                        Err(DlError::Fatal(error))
                    }
                    Ok(Err(_)) if transfer_control::pause_receiving(progress.file_id) => Err(DlError::Fatal(transfer_control::Paused.into())),
                    Ok(Err(error)) => Err(error),
                    _ => unreachable!(),
                };
            }
        };
        if (expected > 0 && position.saturating_add(chunk.len() as u64) > expected)
            || response_end.is_some_and(|end| position.saturating_add(chunk.len() as u64) > end)
        {
            checkpoint_for_transfer(progress.file_id,
                &mut out,
                part,
                state.as_ref().filter(|_| validator_saved),
                position,
                &hash,
            )
            .await?;
            // A streaming response without a usable length may reveal the
            // mismatch only here. Its prefix must never certify completion on
            // the next attempt; preserve the bytes for full revalidation.
            remove_state(part).map_err(DlError::Fatal)?;
            progress.retry_state.clear();
            return Err(DlError::Fatal(download_policy::OriginalSizeMismatch {
                expected: response_end.map_or(expected, |end| if expected > 0 { end.min(expected) } else { end }),
                received: position.saturating_add(chunk.len() as u64),
            }.into()));
        }
        // Keep memory bounded even when adopting a multi-gigabyte legacy part.
        let duplicate = written.saturating_sub(position).min(chunk.len() as u64) as usize;
        let mut same = duplicate;
        if duplicate > 0 {
            let mut old = vec![0; duplicate];
            crate::download_buffer::write_chunk(chunk.len(), async {
                let _read_turn = write_gate.compare_turn(duplicate).await;
                out.flush().await.map_err(|error| fatal(error, "Cannot flush partial download"))?;
                let mut replay = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::ReplayRead, progress.file_id);
                let mut io = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::ReadIo, progress.file_id);
                let mut offset = 0;
                while offset < duplicate {
                    let count = out.read(&mut old[offset..]).await
                        .map_err(|error| fatal(error, "Cannot validate partial download"))?;
                    if count == 0 { return Err(fatal(std::io::Error::from(std::io::ErrorKind::UnexpectedEof), "Cannot validate partial download")); }
                    offset += count; replay.add_bytes(count as u64); io.add_bytes(count as u64);
                }
                replay.complete(); io.complete(); Ok::<(), DlError>(())
            }).await?;
            if old != chunk[..duplicate] {
                checkpoint_floor = 0;
                // Previous chunks were compared. Discard every unverified byte
                // before writing this version, including the old trailing data.
                // Publish a smaller durable boundary before modifying the old
                // prefix. A hard stop cannot retain its now-unverified tail.
                if state.is_some() {
                    checkpoint_for_transfer(progress.file_id, &mut out, part, state.as_ref(), position, &hash).await?;
                } else {
                    remove_state(part).map_err(DlError::Fatal)?;
                }
                out.get_mut()
                    .set_len(position)
                    .await
                    .map_err(|error| fatal(error, "Cannot replace changed partial download"))?;
                out.seek(SeekFrom::Start(position))
                    .await
                    .map_err(|error| fatal(error, "Cannot seek changed download"))?;
                written = position;
                same = 0;
            }
        }
        crate::download_fs::validate(part)
            .map_err(|error| fatal(error, "Download destination is unavailable"))?;
        if same < chunk.len() { crate::download_buffer::write_chunk(chunk.len(), async {
            let _write_turn = write_gate.turn(false).await;
            let mut diagnostic = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::PayloadWrite, progress.file_id);
            out.write_all(&chunk[same..]).await.map_err(|error| {
                fatal(error, "Cannot write download; check storage and permissions")
            })?;
            // A coordinated drive must finish dispatched I/O before its disk
            // turn is released. SSD/network destinations have no such turn
            // and retain their existing pipeline; checkpoints flush both.
            if _write_turn.is_some() {
                out.get_mut().flush().await.map_err(|error| fatal(error, "Cannot flush partial download"))?;
            }
            diagnostic.add_bytes((chunk.len() - same) as u64); diagnostic.complete(); Ok::<(), DlError>(())
        }).await?; }
        hash.update(&chunk);
        position += chunk.len() as u64;
        written = written.max(position);
        schedule.received(chunk.len() as u64, Instant::now());
        if !validator_saved && position > 0 && position >= checkpoint_floor {
            if let Some(state) = &state {
                checkpoint_for_transfer(progress.file_id, &mut out, part, Some(state), position, &hash).await?;
                if position < written {
                    crate::download_telemetry::resume(crate::download_telemetry::Kind::ResumePromoted, position);
                }
                validator_saved = true;
                durable_bytes = position;
                schedule.saved(Instant::now());
            }
        }
        if last.elapsed() >= Duration::from_millis(250) || expected > 0 && written >= expected {
            // Keep pause/restart progress on disk as well as in the UI. Error
            // and pause exits above also flush before releasing the writer.
            flush_progress(&mut out, part, progress.file_id).await?;
            progress.emit(written, expected);
            if show_progress && expected > 0 {
                eprint!("\r  {written} / {expected} bytes");
            }
            last = Instant::now();
        }
    }
    let capped = expected > 0 && response_end.is_some_and(|end| end < expected && position == end);
    if capped && written > position && !same_revision {
        // A clean capped response verified only this prefix, never an old tail.
        out.flush()
            .await
            .map_err(|error| fatal(error, "Cannot flush limited download"))?;
        out.get_mut()
            .set_len(position)
            .await
            .map_err(|error| fatal(error, "Cannot retain limited download prefix"))?;
        written = position;
    }
    if expected == 0 && start == 0 && written > position {
        out.flush()
            .await
            .map_err(|error| fatal(error, "Cannot flush changed download"))?;
        out.get_mut()
            .set_len(position)
            .await
            .map_err(|error| fatal(error, "Cannot finalize changed download"))?;
        written = position;
    }
    let committed = checkpoint_for_transfer(progress.file_id,
        &mut out,
        part,
        state
            .as_ref()
            .filter(|_| validator_saved || capped && hash.bytes == written),
        position,
        &hash,
    )
    .await?;
    if capped || position != written || expected > 0 && written != expected {
        if let Some(proof) = committed {
            progress.retry_state.remember_prefix(part, &proof.state, out.get_ref(), &proof.metadata, &hash).await;
        }
    }
    progress.emit(written, expected);
    if show_progress {
        eprintln!();
    }
    if capped {
        let reusable = state.as_ref().is_some_and(|state| {
            pikpak::content_mode::matching_content_revision(
                state.source_revision.as_deref(),
                progress.source_revision.as_deref(),
            ) || same_source(state.source_key.as_deref(), &source_key(link), &state.etag)
                || !progress.require_content_hash && !state.etag.is_empty()
        });
        return Err(if position > resume_offset && reusable {
            DlError::Retryable(PartialContent.into())
        } else {
            DlError::Fatal(ContentUnavailable.into())
        });
    }
    if position != written || expected > 0 && written != expected {
        return Err(DlError::Retryable(anyhow::anyhow!(
            "Download ended at {position} bytes; expected {expected}"
        )));
    }
    progress.retry_state.clear();
    Ok(None)
}

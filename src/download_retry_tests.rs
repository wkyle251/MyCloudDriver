//! Generated staging files and loopback HTTP only. Count real verification
//! reads, and retain the final read-back independently of retry state.
use super::*;
use completion_tests::ReadCounter;
use std::sync::{Arc, Mutex};

const MIB: u64 = 1 << 20;

fn saved(bytes: &[u8], total: u64, id: &str) -> ResumeState {
    ResumeState {
        file_id: id.into(),
        total,
        etag: "\"synthetic\"".into(),
        source_revision: Some("gcid:SYNTHETIC".into()),
        require_content_hash: true,
        source_key: None,
        durable_bytes: Some(bytes.len() as u64),
        unverified_tail: None,
        prefix_sha256: Some(hex::encode(ring::digest::digest(
            &ring::digest::SHA256,
            bytes,
        ))),
    }
}

#[tokio::test]
async fn unchanged_prefix_is_read_once_across_retries_but_again_after_restart() {
    let id = "retry-unchanged-prefix";
    let reads = ReadCounter::new(id);
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let bytes = vec![0x5a; (8 * MIB) as usize];
    std::fs::write(&part, &bytes).unwrap();
    saved(&bytes, 16 * MIB, id).save_async(&part).await.unwrap();
    let retry = RetryState::default();
    for _ in 0..4 {
        let hash = recover_durable_prefix_cached(&part, id, 16 * MIB, id, &retry)
            .await
            .map_err(DlError::into_inner)
            .unwrap()
            .unwrap();
        assert_eq!(hash.bytes, 8 * MIB);
        assert_eq!(reads.bytes(), 8 * MIB);
    }
    drop(retry);
    recover_durable_prefix_cached(&part, id, 16 * MIB, id, &RetryState::default())
        .await
        .map_err(DlError::into_inner)
        .unwrap()
        .unwrap();
    assert_eq!(
        reads.bytes(),
        16 * MIB,
        "a restarted helper rechecks durable data"
    );
}

#[tokio::test]
async fn changed_data_replacement_and_checkpoint_never_reuse_old_contexts() {
    use std::{
        fs::{File, FileTimes, OpenOptions},
        io::{Seek, SeekFrom, Write},
    };
    for change in ["data", "replacement", "checkpoint"] {
        let id = format!("retry-invalidation-{change}");
        let reads = ReadCounter::new(&id);
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        let bytes = vec![0x5a; MIB as usize];
        std::fs::write(&part, &bytes).unwrap();
        let mut state = saved(&bytes, 2 * MIB, &id);
        state.save_async(&part).await.unwrap();
        let retry = RetryState::default();
        recover_durable_prefix_cached(&part, &id, 2 * MIB, &id, &retry)
            .await
            .map_err(DlError::into_inner)
            .unwrap()
            .unwrap();
        match change {
            "data" => {
                let modified = std::fs::metadata(&part).unwrap().modified().unwrap();
                let mut file = OpenOptions::new().write(true).open(&part).unwrap();
                file.seek(SeekFrom::Start(123)).unwrap();
                file.write_all(b"!").unwrap();
                file.sync_all().unwrap();
                file.set_times(FileTimes::new().set_modified(modified))
                    .unwrap();
            }
            "replacement" => {
                let replacement = directory.path().join("replacement");
                std::fs::write(&replacement, &bytes).unwrap();
                std::fs::rename(replacement, &part).unwrap();
            }
            _ => {
                state.prefix_sha256 = Some("00".repeat(32));
                state.save_async(&part).await.unwrap();
            }
        }
        let restored = recover_durable_prefix_cached(&part, &id, 2 * MIB, &id, &retry)
            .await
            .map_err(DlError::into_inner)
            .unwrap();
        assert_eq!(
            reads.bytes(),
            2 * MIB,
            "{change} must cause fresh verification"
        );
        if change == "replacement" {
            assert!(restored.is_some());
        } else {
            assert!(restored.is_none());
            assert!(
                !state_path(&part).exists(),
                "a changed prefix cannot retain its old certificate"
            );
        }
        assert_eq!(File::open(&part).unwrap().metadata().unwrap().len(), MIB);
    }
}

struct CappedServer {
    url: String,
    starts: Arc<Mutex<Vec<u64>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for CappedServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl CappedServer {
    async fn start(total: u64, cap: u64) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/generated", listener.local_addr().unwrap());
        let starts = Arc::new(Mutex::new(Vec::new()));
        let requests = starts.clone();
        let task = tokio::spawn(async move {
            let mut clients = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let (mut socket, _) = accepted.unwrap();
                        let requests = requests.clone();
                        clients.spawn(async move {
                            let mut request = Vec::new();
                            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                                let mut buffer = [0; 4096];
                                let count = socket.read(&mut buffer).await.unwrap();
                                if count == 0 { return; }
                                request.extend_from_slice(&buffer[..count]);
                            }
                            let text = String::from_utf8_lossy(&request).to_lowercase();
                            let start = text.lines().find_map(|line| line.strip_prefix("range: bytes="))
                                .and_then(|range| range.split_once('-')).map(|(start, _)| start.parse::<u64>().unwrap()).unwrap_or(0);
                            requests.lock().unwrap().push(start);
                            let end = (start + cap).min(total);
                            let header = format!("HTTP/1.1 206 Partial\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{total}\r\nETag: \"synthetic\"\r\nConnection: close\r\n\r\n", end - start, end - 1);
                            socket.write_all(header.as_bytes()).await.unwrap();
                            let chunk = [0x5a; 64 * 1024];
                            let mut position = start;
                            while position < end {
                                let count = (end - position).min(chunk.len() as u64) as usize;
                                socket.write_all(&chunk[..count]).await.unwrap();
                                position += count as u64;
                            }
                        });
                    }
                    done = clients.join_next(), if !clients.is_empty() => { done.unwrap().unwrap(); }
                }
            }
        });
        Self { url, starts, task }
    }
}

#[tokio::test]
async fn capped_responses_reuse_incremental_hashes_and_still_read_back_before_publication() {
    let id = "retry-capped-incremental";
    let reads = ReadCounter::new(id);
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.bin.part");
    let output = directory.path().join("generated.bin");
    let total = 8 * MIB;
    let server = CappedServer::start(total, 2 * MIB).await;
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let mut progress = DownloadProgressContext::new(false, id, "generated.bin");
    progress.source_revision = Some("gcid:SYNTHETIC".into());
    progress.require_content_hash = true;
    for _ in 0..3 {
        let result = attempt_for_publication(
            &http,
            &server.url,
            total,
            &part,
            false,
            progress.clone(),
            None,
        )
        .await;
        assert!(
            matches!(result, Err(DlError::Retryable(ref error)) if error.is::<PartialContent>())
        );
        assert_eq!(
            reads.bytes(),
            0,
            "accepted bytes should not be re-read on a capped retry"
        );
    }
    let verified = attempt_for_publication(
        &http,
        &server.url,
        total,
        &part,
        false,
        progress.clone(),
        None,
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap();
    assert!(
        verified.is_none(),
        "the serial completion still requires disk verification"
    );
    assert_eq!(reads.bytes(), 0);
    assert_eq!(
        *server.starts.lock().unwrap(),
        vec![0, 2 * MIB, 4 * MIB, 6 * MIB]
    );
    assert_eq!(
        progress
            .transferred_bytes
            .load(std::sync::atomic::Ordering::Relaxed),
        total
    );
    let file = serde_json::from_value(serde_json::json!({
        "id": id, "name": "generated.bin", "kind": "drive#file", "size": total.to_string(), "hash": "synthetic"
    })).unwrap();
    let source = crate::download_receipt::Source::new("account:synthetic".into(), &file, total);
    crate::download_receipt::finish_resolved_verified(&part, &output, source, id, verified)
        .await
        .unwrap();
    assert_eq!(
        reads.bytes(),
        total,
        "publication retains one complete read-back"
    );
    assert_eq!(std::fs::read(output).unwrap(), vec![0x5a; total as usize]);
}

#[tokio::test]
async fn interrupted_full_prefix_cannot_skip_final_read_back() {
    let id = "retry-complete-incremental";
    let reads = ReadCounter::new(id);
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let bytes = vec![0x5a; MIB as usize];
    std::fs::write(&part, &bytes).unwrap();
    let state = saved(&bytes, MIB, id);
    state.save_async(&part).await.unwrap();
    let mut incremental = integrity::Prefix::new();
    incremental.update(&bytes);
    let file = crate::download_fs::open_async(&part, rustix::fs::OFlags::RDONLY)
        .await
        .unwrap();
    let retry = Arc::new(RetryState::default());
    retry
        .remember_prefix(
            &part,
            &state,
            &file,
            &file.metadata().await.unwrap(),
            &incremental,
        )
        .await;
    let mut progress = DownloadProgressContext::new(false, id, "generated");
    progress.source_revision = state.source_revision;
    progress.retry_state = retry;
    let verified = attempt_for_publication(
        &reqwest::Client::new(),
        "http://127.0.0.1:9/unreachable",
        MIB,
        &part,
        false,
        progress,
        None,
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap()
    .unwrap();
    assert_eq!(reads.bytes(), MIB);
    assert_eq!(verified.hash.digest(), incremental.digest());
}

#[tokio::test]
#[ignore = "manual release benchmark using only generated files"]
async fn retry_read_benchmark() {
    let directory = tempfile::tempdir().unwrap();
    let bytes = vec![0x5a; (32 * MIB) as usize];
    for enabled in [false, true, true, false] {
        let id = format!("retry-benchmark-{enabled}");
        let reads = ReadCounter::new(&id);
        let part = directory.path().join("generated.part");
        std::fs::write(&part, &bytes).unwrap();
        saved(&bytes, 48 * MIB, &id)
            .save_async(&part)
            .await
            .unwrap();
        let retry = if enabled {
            RetryState::default()
        } else {
            RetryState::disabled()
        };
        let started = Instant::now();
        for _ in 0..8 {
            recover_durable_prefix_cached(&part, &id, 48 * MIB, &id, &retry)
                .await
                .map_err(DlError::into_inner)
                .unwrap()
                .unwrap();
        }
        println!(
            "BENCH retry_cache={enabled} read_mib={} elapsed_seconds={:.4}",
            reads.bytes() / MIB,
            started.elapsed().as_secs_f64()
        );
        assert_eq!(reads.bytes(), if enabled { 32 * MIB } else { 256 * MIB });
    }
}

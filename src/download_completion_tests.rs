//! Generated files and loopback HTTP only. Count bytes returned by the real
//! verification readers, so caching cannot conceal a duplicate full pass.
use super::*;
use crate::download_receipt::{self, Source};
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex, OnceLock,
};

#[path = "download_range_fixture.rs"]
mod fixture;

#[derive(Default)]
struct ReadCounts { bytes: AtomicU64, calls: AtomicU64 }
fn counters() -> &'static Mutex<HashMap<String, Arc<ReadCounts>>> {
    static COUNTERS: OnceLock<Mutex<HashMap<String, Arc<ReadCounts>>>> = OnceLock::new();
    COUNTERS.get_or_init(Mutex::default)
}

pub(crate) fn record_read(control_id: &str, bytes: u64) {
    if let Some(counter) = counters().lock().unwrap().get(control_id) {
        counter.bytes.fetch_add(bytes, Ordering::Relaxed);
        counter.calls.fetch_add(1, Ordering::Relaxed);
    }
}

pub(crate) struct ReadCounter {
    id: String,
    counts: Arc<ReadCounts>,
}
impl ReadCounter {
    pub(crate) fn new(id: &str) -> Self {
        let counts = Arc::new(ReadCounts::default());
        assert!(counters()
            .lock()
            .unwrap()
            .insert(id.into(), counts.clone())
            .is_none());
        Self {
            id: id.into(),
            counts,
        }
    }
    pub(crate) fn bytes(&self) -> u64 {
        self.counts.bytes.load(Ordering::Relaxed)
    }
    pub(crate) fn calls(&self) -> u64 {
        self.counts.calls.load(Ordering::Relaxed)
    }
}
impl Drop for ReadCounter {
    fn drop(&mut self) {
        counters().lock().unwrap().remove(&self.id);
    }
}

fn source(id: &str, revision: &str, bytes: u64) -> Source {
    let file = serde_json::from_value(serde_json::json!({
        "id": id, "name": "generated.bin", "kind": "drive#file",
        "size": bytes.to_string(), "hash": revision,
    }))
    .unwrap();
    Source::new("account:synthetic-completion".into(), &file, bytes)
}

/// Exercise the same full verification, durable digest and controlled rename
/// as a finished range download, with a small generated original.
pub(crate) async fn completed_fixture(directory: &Path, control_id: &str) -> VerifiedCompletion {
    let partial = directory.join("generated.bin.part");
    let data = directory.join("generated.bin.part.ranges.data");
    std::fs::write(&data, b"abcdefgh").unwrap();
    let digest = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh"));
    let hash = integrity::Prefix::read_verified(&data, 8, &[(0, 8, digest.clone())], control_id)
        .await
        .map_err(DlError::into_inner)
        .unwrap();
    ResumeState {
        file_id: "original".into(),
        total: 8,
        etag: "\"fixture\"".into(),
        source_revision: Some("gcid:FIXTURE".into()),
        require_content_hash: true,
        source_key: None,
        durable_bytes: Some(8),
        unverified_tail: None,
        prefix_sha256: Some(digest),
    }
    .save_async(&partial)
    .await
    .unwrap();
    VerifiedCompletion::from_prefix(&data, hash, "original", Some("gcid:FIXTURE"))
        .await
        .map_err(DlError::into_inner)
        .unwrap()
        .rename(&data, &partial)
        .await
        .map_err(DlError::into_inner)
        .unwrap()
}

#[tokio::test]
async fn account_and_shared_range_downloads_read_each_byte_once_before_publication() {
    for shared in [false, true] {
        let control_id = format!("single-completion-pass-{shared}");
        let reads = ReadCounter::new(&control_id);
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.bin.part");
        let output = directory.path().join("generated.bin");
        let remote = fixture::Fixture::new(fixture::SIZE).await;
        let original = source("original", "fixture-1", remote.size);
        let mut progress = DownloadProgressContext::new(false, &control_id, "generated.bin");
        progress.source_file_id = "original";
        progress.source_revision = Some("gcid:FIXTURE-1".into());
        let verified = crate::download_attempt_with_http(
            &reqwest::Client::builder().no_proxy().build().unwrap(),
            &remote.url,
            remote.size,
            &partial,
            false,
            progress,
            shared.then_some("https://mypikpak.com/"),
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap()
        .expect("range verification proof");
        assert_eq!(
            reads.bytes(),
            remote.size,
            "the piece verification reads the whole file once"
        );
        let published = download_receipt::finish_resolved_verified(
            &partial,
            &output,
            original.clone(),
            &control_id,
            Some(verified),
        )
        .await
        .unwrap();
        assert_eq!(published, output);
        assert_eq!(
            reads.bytes(),
            remote.size,
            "receipt creation must not read the file again"
        );
        assert!(
            download_receipt::completed_without_reading(&output, &original, &control_id)
                .await
                .unwrap()
                .is_some()
        );
        let expected = fixture::bytes(0, remote.size as usize, 1);
        assert_eq!(std::fs::read(&output).unwrap(), expected);
        println!(
            "{} range download: {} MiB verified for {} MiB downloaded",
            if shared { "Shared" } else { "Account" },
            reads.bytes() >> 20,
            remote.size >> 20
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn queued_hdd_verification_keeps_network_and_other_drive_transfers_running() {
    let id = "generated-queued-hdd-network";
    let drive = crate::download_verification::TestDrive::new(id);
    let owner = drive.hold().await;
    let reads = ReadCounter::new(id);
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("generated.bin.part");
    let remote = fixture::Fixture::new(fixture::SIZE).await;
    let progress = DownloadProgressContext::new(false, id, "generated.bin");
    let received = progress.transferred_bytes.clone();
    let url = remote.url.clone();
    let waiting_part = partial.clone();
    let waiting = tokio::spawn(async move {
        attempt_for_publication(&reqwest::Client::builder().no_proxy().build().unwrap(),
            &url, fixture::SIZE, &waiting_part, false, progress, None).await.map_err(DlError::into_inner)
    });
    tokio::time::timeout(Duration::from_secs(10), async {
        while received.load(Ordering::Relaxed) < remote.size {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.expect("queued verification stalled the network download");
    assert_eq!(reads.bytes(), 0, "a queued verifier must issue no file reads");
    assert!(!waiting.is_finished(), "completion must still await read-back verification");
    let other = directory.path().join("other-drive.bin.part");
    tokio::time::timeout(Duration::from_secs(10), attempt_for_publication(
        &reqwest::Client::builder().no_proxy().build().unwrap(), &remote.url, remote.size,
        &other, false, DownloadProgressContext::new(false, "generated-independent-drive", "generated.bin"), None,
    )).await.unwrap().map_err(DlError::into_inner).unwrap();
    drop(owner);
    let proof = tokio::time::timeout(Duration::from_secs(10), waiting).await.unwrap().unwrap().unwrap().unwrap();
    assert_eq!(reads.bytes(), remote.size, "the queued file still receives exactly one complete integrity pass");
    assert_eq!(proof.hash.digest(), hex::encode(ring::digest::digest(&ring::digest::SHA256, &fixture::bytes(0, remote.size as usize, 1))));
    assert_eq!(std::fs::read(&partial).unwrap(), std::fs::read(&other).unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streaming_ram_receives_while_the_same_disk_is_in_a_read_operation() {
    let read_id = "generated-traffic-read-operation";
    let write_id = "generated-traffic-download";
    let drive = crate::download_verification::TestDrive::new(read_id);
    let _writer_drive = drive.sibling(write_id);
    let reading = drive.hold_read(512 << 20).await;
    let read_operation = reading.chunk(256 << 10, read_id).await.unwrap();
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("generated.bin.part");
    let remote = fixture::Fixture::new(8 << 20).await;
    let progress = DownloadProgressContext::new(false, write_id, "generated.bin");
    let received = progress.transferred_bytes.clone();
    let waiting_part = partial.clone();
    let url = remote.url.clone();
    let download = tokio::spawn(async move {
        attempt_for_publication(&reqwest::Client::builder().no_proxy().build().unwrap(),
            &url, 8 << 20, &waiting_part, false, progress, None).await.map_err(DlError::into_inner)
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        while received.load(Ordering::Relaxed) < 1 << 20 { tokio::time::sleep(Duration::from_millis(10)).await; }
    }).await.expect("Disk read operation stalled the independent HTTP receiver");
    assert_eq!(std::fs::metadata(&partial).unwrap().len(), 0, "Writes must wait for the read operation to leave the drive");
    assert!(!download.is_finished());
    drop(read_operation); drop(reading);
    tokio::time::timeout(Duration::from_secs(5), download).await.unwrap().unwrap().unwrap();
    assert_eq!(std::fs::read(&partial).unwrap(), fixture::bytes(0, remote.size as usize, 1));
}

#[tokio::test]
async fn a_completed_checkpoint_is_freshly_read_once_after_restart() {
    let control_id = "completion-recovered-checkpoint";
    let reads = ReadCounter::new(control_id);
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("generated.bin.part");
    let output = directory.path().join("generated.bin");
    drop(completed_fixture(directory.path(), control_id).await);
    assert_eq!(reads.bytes(), 8);
    let mut progress = DownloadProgressContext::new(false, control_id, "generated.bin");
    progress.source_file_id = "original";
    progress.source_revision = Some("gcid:FIXTURE".into());
    let verified = attempt_for_publication(
        &reqwest::Client::builder().no_proxy().build().unwrap(),
        "http://127.0.0.1:9/unreachable-original",
        8,
        &partial,
        false,
        progress,
        None,
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap()
    .expect("fresh checkpoint verification");
    assert_eq!(
        reads.bytes(),
        16,
        "restart always verifies the retained bytes again"
    );
    download_receipt::finish_resolved_verified(
        &partial,
        &output,
        source("original", "fixture", 8),
        control_id,
        Some(verified),
    )
    .await
    .unwrap();
    assert_eq!(
        reads.bytes(),
        16,
        "the freshly verified checkpoint needs no second pass"
    );
    assert_eq!(std::fs::read(output).unwrap(), b"abcdefgh");
}

#[tokio::test]
async fn changed_metadata_and_lost_in_process_proofs_fall_back_to_a_full_checksum() {
    for lost_proof in [false, true] {
        let control_id = format!("completion-fallback-{lost_proof}");
        let reads = ReadCounter::new(&control_id);
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.bin.part");
        let output = directory.path().join("generated.bin");
        let verified = completed_fixture(directory.path(), &control_id).await;
        let proof = if lost_proof {
            drop(verified);
            None
        } else {
            let file = std::fs::File::open(&partial).unwrap();
            file.set_times(
                std::fs::FileTimes::new()
                    .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(123)),
            )
            .unwrap();
            Some(verified)
        };
        download_receipt::finish_resolved_verified(
            &partial,
            &output,
            source("original", "fixture", 8),
            &control_id,
            proof,
        )
        .await
        .unwrap();
        assert_eq!(
            reads.bytes(),
            16,
            "untrusted metadata or a missing proof requires another full read"
        );
        assert_eq!(std::fs::read(output).unwrap(), b"abcdefgh");
    }
}

#[tokio::test]
async fn edited_or_replaced_files_are_rechecked_and_preserved_without_publication() {
    use std::os::unix::fs::MetadataExt;
    for replacement in [false, true] {
        let control_id = format!("completion-mutation-{replacement}");
        let reads = ReadCounter::new(&control_id);
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.bin.part");
        let output = directory.path().join("generated.bin");
        let verified = completed_fixture(directory.path(), &control_id).await;
        let before = std::fs::metadata(&partial).unwrap();
        if replacement {
            let changed = directory.path().join("generated-replacement");
            std::fs::write(&changed, b"BAD-DATA").unwrap();
            std::fs::rename(changed, &partial).unwrap();
            assert_ne!(before.ino(), std::fs::metadata(&partial).unwrap().ino());
        } else {
            std::fs::write(&partial, b"BAD-DATA").unwrap();
            std::fs::File::open(&partial)
                .unwrap()
                .set_times(std::fs::FileTimes::new().set_modified(before.modified().unwrap()))
                .unwrap();
            let after = std::fs::metadata(&partial).unwrap();
            assert_eq!(
                (before.ino(), before.len(), before.modified().unwrap()),
                (after.ino(), after.len(), after.modified().unwrap())
            );
            assert_ne!(
                (before.ctime(), before.ctime_nsec()),
                (after.ctime(), after.ctime_nsec())
            );
        }
        let error = download_receipt::finish_resolved_verified(
            &partial,
            &output,
            source("original", "fixture", 8),
            &control_id,
            Some(verified),
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("bytes changed"), "{error:#}");
        assert_eq!(reads.bytes(), 16);
        assert!(!output.exists());
        assert_eq!(std::fs::read(partial).unwrap(), b"BAD-DATA");
    }
}

#[tokio::test]
async fn a_verification_proof_cannot_complete_a_different_source_or_revision() {
    for revision_change in [false, true] {
        let control_id = format!("completion-source-{revision_change}");
        let reads = ReadCounter::new(&control_id);
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.bin.part");
        let output = directory.path().join("generated.bin");
        let verified = completed_fixture(directory.path(), &control_id).await;
        let different = if revision_change {
            source("original", "different", 8)
        } else {
            source("other", "fixture", 8)
        };
        let error = download_receipt::finish_resolved_verified(
            &partial,
            &output,
            different,
            &control_id,
            Some(verified),
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("different source"), "{error:#}");
        assert_eq!(reads.bytes(), 8);
        assert!(!output.exists());
        assert_eq!(std::fs::read(partial).unwrap(), b"abcdefgh");
    }
}

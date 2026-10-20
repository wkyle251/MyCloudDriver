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
struct ReadCounts { bytes: AtomicU64, calls: AtomicU64, publication_syncs: AtomicU64 }
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

pub(crate) fn record_publication_sync(control_id: &str) {
    if let Some(counter) = counters().lock().unwrap().get(control_id) {
        counter.publication_syncs.fetch_add(1, Ordering::Relaxed);
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
    fn publication_syncs(&self) -> u64 {
        self.counts.publication_syncs.load(Ordering::Relaxed)
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
    completed_fixture_with_durability(directory, control_id, true).await
}

fn fixture_checkpoint() -> ResumeState {
    ResumeState {
        file_id: "original".into(),
        total: 8,
        etag: "\"fixture\"".into(),
        source_revision: Some("gcid:FIXTURE".into()),
        require_content_hash: true,
        source_key: None,
        durable_bytes: Some(8),
        unverified_tail: None,
        prefix_sha256: None,
    }
}

async fn completed_fixture_with_durability(directory: &Path, control_id: &str, durable: bool) -> VerifiedCompletion {
    let partial = directory.join("generated.bin.part");
    let data = directory.join("generated.bin.part.ranges.data");
    std::fs::write(&data, b"abcdefgh").unwrap();
    let digest = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh"));
    let hash = integrity::Prefix::read_verified(&data, 8, &[(0, 8, digest.clone())], control_id)
        .await
        .map_err(DlError::into_inner)
        .unwrap();
    let verified = if durable {
        VerifiedCompletion::from_durable_checkpoint(&data, &partial, fixture_checkpoint(), hash, control_id)
            .await.map_err(DlError::into_inner).unwrap()
    } else {
        let mut saved = fixture_checkpoint();
        saved.prefix_sha256 = Some(digest);
        saved.save_async(&partial).await.unwrap();
        VerifiedCompletion::from_prefix(&data, hash, "original", Some("gcid:FIXTURE"))
            .await.map_err(DlError::into_inner).unwrap()
    };
    verified
        .rename(&data, &partial)
        .await
        .map_err(DlError::into_inner)
        .unwrap()
}

#[tokio::test]
async fn only_an_unchanged_durable_completion_skips_the_publication_payload_sync() {
    for durable in [false, true] {
        let id = format!("generated-publication-sync-{durable}");
        let reads = ReadCounter::new(&id);
        let directory = tempfile::tempdir().unwrap();
        let verified = completed_fixture_with_durability(directory.path(), &id, durable).await;
        assert_eq!(verified.durably_synced(), durable);
        download_receipt::finish_resolved_verified(
            &directory.path().join("generated.bin.part"), &directory.path().join("generated.bin"),
            source("original", "fixture", 8), &id, Some(verified),
        ).await.unwrap();
        assert_eq!(reads.bytes(), 8, "Both paths still verify every byte exactly once");
        assert_eq!(reads.publication_syncs(), u64::from(!durable),
            "Only the successful in-process payload-and-journal commit replaces the publication sync");
    }
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
        assert_eq!(reads.publication_syncs(), 0, "The range checkpoint already synced this exact payload");
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

#[test]
fn final_checkpoints_share_durable_barriers_and_release_scoped_read_admission() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "download_transport::completion_tests::final_checkpoint_group_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(output.status.success(), "{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    println!("{}", String::from_utf8_lossy(&output.stdout));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated counters and generated completed files sharing one synthetic HDD"]
async fn final_checkpoint_group_child() {
    use std::sync::atomic::AtomicUsize;
    const GROUP: usize = 8;
    let directory = tempfile::tempdir().unwrap();
    let drive = crate::download_verification::TestDrive::new("generated-final-commit-holder");
    let holder = tokio::fs::File::create(directory.path().join("generated-holder")).await.unwrap();
    let gate = crate::download_verification::WriteGate::new(&holder, "generated-final-commit-holder");
    let ready = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(tokio::sync::Barrier::new(GROUP + 1));
    let verified = Arc::new(AtomicUsize::new(0));
    let publish = Arc::new(tokio::sync::Semaphore::new(0));
    let before = crate::download_checkpoint::snapshot();
    let mut jobs = Vec::new();
    for index in 0..GROUP {
        let id = format!("generated-final-group-{index}");
        let sibling = drive.sibling(&id);
        let folder = directory.path().join(format!("generated-group-{index}"));
        std::fs::create_dir(&folder).unwrap();
        let ready = ready.clone();
        let release = release.clone();
        let verified = verified.clone();
        let publish = publish.clone();
        jobs.push(tokio::spawn(async move {
            let _drive = sibling;
            let reads = ReadCounter::new(&id);
            let scope = crate::download_verification::Scope::new(id.clone(), None);
            scope.run(async {
                let data = folder.join("generated.bin.part.ranges.data");
                let part = folder.join("generated.bin.part");
                std::fs::write(&data, b"abcdefgh").unwrap();
                let digest = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh"));
                let hash = integrity::Prefix::read_verified(&data, 8, &[(0, 8, digest)], &id)
                    .await.map_err(DlError::into_inner).unwrap();
                ready.fetch_add(1, Ordering::Relaxed);
                release.wait().await;
                let proof = VerifiedCompletion::from_durable_checkpoint(&data, &part, fixture_checkpoint(), hash, &id)
                    .await.map_err(DlError::into_inner).unwrap();
                assert!(proof.durably_synced());
                let proof = proof.rename(&data, &part).await.map_err(DlError::into_inner).unwrap();
                verified.fetch_add(1, Ordering::Relaxed);
                publish.acquire_owned().await.unwrap().forget();
                download_receipt::finish_resolved_verified(
                    &part, &folder.join("generated.bin"), source("original", "fixture", 8), &id, Some(proof),
                ).await.unwrap();
            }).await;
            assert_eq!(reads.bytes(), 8);
            assert_eq!(reads.publication_syncs(), 0);
        }));
    }
    tokio::time::timeout(Duration::from_secs(10), async {
        while ready.load(Ordering::Relaxed) != GROUP { tokio::task::yield_now().await; }
    }).await.expect("Scoped final readers must complete before checkpoint admission");
    let held = gate.turn(false).await;
    release.wait().await;
    tokio::time::timeout(Duration::from_secs(5), async {
        while crate::download_checkpoint::snapshot().4 < GROUP { tokio::task::yield_now().await; }
    }).await.expect("All final checkpoints should queue behind the same held writer");
    assert!(jobs.iter().all(|job| !job.is_finished()));
    assert_eq!(crate::download_checkpoint::snapshot().0, before.0, "No durability may be acknowledged before the writer releases");
    drop(held);
    tokio::time::timeout(Duration::from_secs(10), async {
        while verified.load(Ordering::Relaxed) != GROUP { tokio::task::yield_now().await; }
    }).await.expect("The grouped final checkpoint must finish before publication");
    let after = crate::download_checkpoint::snapshot();
    assert_eq!((after.0 - before.0, after.1 - before.1, after.2 - before.2), (1, GROUP as u64, 2));
    publish.add_permits(GROUP);
    tokio::time::timeout(Duration::from_secs(10), async {
        for job in jobs { job.await.unwrap(); }
    }).await.expect("Final checkpoints must release every scoped read reservation");
    println!("GENERATED_FINAL_GROUP_COMMIT {{\"files\":{GROUP},\"batches\":1,\"full_cache_barriers\":2,\"publication_payload_syncs\":0}}");

    // More files than the eight read reservations: deferred readers remain
    // queued while the first group awaits its write turn. No network or RAM
    // arrival may be needed to make that checkpoint turn run.
    let start = std::time::Instant::now();
    let mut jobs = Vec::new();
    for index in 0..16 {
        let id = format!("generated-final-pressure-{index}");
        let sibling = drive.sibling(&id);
        let folder = directory.path().join(format!("generated-pressure-{index}"));
        std::fs::create_dir(&folder).unwrap();
        jobs.push(tokio::spawn(async move {
            let _drive = sibling;
            let reads = ReadCounter::new(&id);
            let mut waiting = None;
            let data = folder.join("generated.bin.part.ranges.data");
            let part = folder.join("generated.bin.part");
            std::fs::write(&data, b"abcdefgh").unwrap();
            let digest = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh"));
            loop {
                let scope = crate::download_verification::Scope::new(id.clone(), waiting.take());
                let result = scope.run(async {
                    let hash = integrity::Prefix::read_verified(&data, 8, &[(0, 8, digest.clone())], &id).await?;
                    VerifiedCompletion::from_durable_checkpoint(&data, &part, fixture_checkpoint(), hash, &id).await
                }).await;
                drop(scope);
                match result {
                    Ok(proof) => {
                        assert!(proof.durably_synced());
                        assert_eq!(reads.bytes(), 8);
                        break;
                    }
                    Err(error) => {
                        let error = error.into_inner();
                        let deferred = error.downcast_ref::<crate::download_verification::Deferred>()
                            .expect("Only admission deferral is expected").clone();
                        while !deferred.ready() { tokio::time::sleep(Duration::from_millis(10)).await; }
                        waiting = Some(deferred);
                    }
                }
            }
        }));
    }
    tokio::time::timeout(Duration::from_secs(20), async {
        for job in jobs { job.await.unwrap(); }
    }).await.expect("Queued finalizers must progress without HTTP reception or RAM pressure");
    println!("GENERATED_FINAL_ADMISSION {{\"files\":16,\"elapsed_ms\":{}}}", start.elapsed().as_millis());
}

#[tokio::test]
async fn a_failed_final_checkpoint_cannot_produce_a_durable_completion() {
    let directory = tempfile::tempdir().unwrap();
    let data = directory.path().join("generated.bin.part.ranges.data");
    let part = directory.path().join("generated.bin.part");
    std::fs::write(&data, b"abcdefgh").unwrap();
    std::fs::create_dir(state_path(&part)).unwrap();
    let id = "generated-final-commit-failure";
    let _drive = crate::download_verification::TestDrive::new(id);
    let digest = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh"));
    let hash = integrity::Prefix::read_verified(&data, 8, &[(0, 8, digest)], id)
        .await.map_err(DlError::into_inner).unwrap();
    assert!(VerifiedCompletion::from_durable_checkpoint(&data, &part, fixture_checkpoint(), hash, id).await.is_err());
    assert!(!part.exists(), "A failed commit must leave the generated staging file unpublished");
    assert_eq!(std::fs::read(data).unwrap(), b"abcdefgh");
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
    assert_eq!(reads.publication_syncs(), 1, "A restored serial proof must acquire its own durability");
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
        assert_eq!(reads.publication_syncs(), 1, "Changed or lost proof cannot suppress the payload sync");
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
        assert_eq!(reads.publication_syncs(), 1, "Edited or replaced data is outside the old durability proof");
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

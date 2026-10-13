use super::*;
use std::sync::atomic::Ordering;
#[path = "download_range_fixture.rs"]
mod fixture;

fn progress() -> DownloadProgressContext<'static> {
    DownloadProgressContext::new(false, "range-fixture", "generated.bin")
}

#[test]
fn coalescing_range_buffers_keep_their_ram_charge_until_disk_write() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().to_ascii_lowercase().ends_with("proxy") { child.env_remove(key); }
    }
    let result = child.env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (4 << 20).to_string())
        .args(["--exact", "download_transport::parts::tests::retained_range_ram_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated generated loopback ranges and RAM accounting"]
async fn retained_range_ram_child() {
    use crate::download_verification::{Scope, TestDrive};
    let id = "generated-retained-range-ram";
    let remote = fixture::Fixture::new(1 << 20).await;
    remote.hold_first.store(true, Ordering::Release);
    remote.hold_after_bytes.store(64 << 10, Ordering::Release);
    let directory = tempfile::tempdir().unwrap(); let part = directory.path().join("generated.part");
    let drive = TestDrive::new(id);
    let reader = drive.hold_read(512 << 20).await;
    let reading = reader.chunk(1, id).await.unwrap();
    let mut writer = checkpoint_writer(&part, &[]).await;
    writer.total = remote.size;
    writer.write_gate = crate::download_verification::WriteGate::new(&writer.file, id);
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let scope = Scope::new(id.into(), None);
    scope.run(async {
        let transfer = Transfer::new(&http, &remote.url, None, State::new(remote.size, "\"fixture-1\"".into(), 0),
            pikpak::download_network::Network::new(1, None)).unwrap();
        let received = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)); let counter = received.clone();
        let mut ranges = crate::download_buffer::Ranges::new(transfer, move |bytes| { counter.fetch_add(bytes, Ordering::Relaxed); });
        tokio::time::timeout(Duration::from_secs(3), async {
            while received.load(Ordering::Relaxed) < 64 << 10 { tokio::time::sleep(Duration::from_millis(5)).await; }
        }).await.unwrap();
        let chunk = ranges.next().await.unwrap().unwrap();
        assert!(chunk.bytes.len() < pikpak::download_network::RECEIVE_WINDOW as usize);
        writer.push(&chunk).await.unwrap();
        writer.retain(chunk.index, ranges.accept_retaining(&chunk));
        assert_eq!(crate::download_buffer::snapshot().used as u64, received.load(Ordering::Relaxed),
            "Copying into a range writer must not refund RAM while payload remains in memory");
        assert_eq!(writer.buffers[&chunk.index].chunks[0].as_ptr(), chunk.bytes.as_ptr(), "Partial writers share the compact receive allocation");
        assert_eq!(writer.file.metadata().await.unwrap().len(), 0, "The held reader has prevented physical writing");
        ranges.stop();
        assert_eq!(crate::download_buffer::snapshot().used, chunk.bytes.len(), "Only the writer's retained payload remains charged");
        drop(reading); drop(reader);
        writer.flush_piece(chunk.index).await.unwrap();
        assert_eq!(crate::download_buffer::snapshot().used, 0, "Successful physical output releases the retained RAM charge");
        assert_eq!(std::fs::read(data_path(&part)).unwrap(), fixture::bytes(chunk.offset, chunk.bytes.len(), 1));
    }).await;
}
fn assert_file(part: &Path, revision: usize) {
    use std::io::Read;
    let mut file = std::fs::File::open(part).unwrap();
    let mut offset = 0;
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer).unwrap();
        if count == 0 {
            break;
        }
        assert!(buffer[..count]
            .iter()
            .enumerate()
            .all(|(index, value)| *value == fixture::byte(offset + index as u64, revision)));
        offset += count as u64;
    }
    assert_eq!(offset, fixture::SIZE);
}

#[tokio::test]
async fn deferred_final_verification_preserves_durable_ranges_and_repairs_later_damage() {
    use crate::download_verification::{Scope, TestDrive, Deferred};
    use std::os::unix::fs::FileExt;
    for corrupt in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.part");
        let blocker_path = directory.path().join("generated-sparse-reservation");
        let blocker_file = std::fs::File::create(&blocker_path).unwrap();
        blocker_file.set_len(2 << 30).unwrap();
        let blocker_id = format!("generated-read-admission-owner-{corrupt}");
        let id = format!("generated-deferred-final-{corrupt}");
        let drive = TestDrive::new(&blocker_id);
        let _sibling = drive.sibling(&id);
        let blocker = Scope::new(blocker_id.clone(), None);
        let file = tokio::fs::File::from_std(blocker_file);
        drop(blocker.run(crate::download_verification::acquire_async(&file, &blocker_id, 2 << 30)).await.unwrap());
        // The phase owns the admission reservation, but no read or file lock
        // blocks writes. A fresh body must stream before its final check parks.
        let remote = fixture::Fixture::new(fixture::SIZE).await;
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let mut progress = DownloadProgressContext::new(false, &id, "generated.bin");
        progress.source_file_id = "range-fixture";
        progress.source_revision = Some("gcid:ORIGINAL".into());
        progress.require_content_hash = true;
        let first = Scope::new(id.clone(), None);
        let error = first.run(super::super::attempt_for_publication(&http, &remote.url, remote.size,
            &partial, false, progress.clone(), None)).await.err().expect("Final check should park").into_inner();
        let waiting = error.downcast_ref::<Deferred>().expect("Admission must propagate without retry/failure classification").clone();
        drop(error);
        drop(first);
        assert_eq!(progress.transferred_bytes(), remote.size);
        let saved = load(&partial, "range-fixture", remote.size).unwrap().unwrap();
        assert!(saved.ranges.complete());
        assert!(saved.data_identity.is_some(), "Deferral must not withdraw valid complete-piece proof");
        assert_eq!(std::fs::metadata(data_path(&partial)).unwrap().len(), remote.size);
        let journal = std::fs::read(journal_path(&partial)).unwrap();
        drop(blocker);
        assert!(waiting.ready());
        assert_eq!(std::fs::read(journal_path(&partial)).unwrap(), journal);
        if corrupt {
            std::fs::OpenOptions::new().write(true).open(data_path(&partial)).unwrap().write_all_at(&[0xff], 100).unwrap();
        }
        let ticket = if corrupt { Some(waiting) } else { drop(waiting); None };
        let mut resumed_progress = DownloadProgressContext::new(false, &id, "generated.bin");
        resumed_progress.source_file_id = "range-fixture";
        resumed_progress.source_revision = Some("gcid:ORIGINAL".into());
        resumed_progress.require_content_hash = true;
        let resumed = Scope::new(id.clone(), ticket);
        let verified = resumed.run(super::super::attempt_for_publication(&http, &remote.url, remote.size,
            &partial, false, resumed_progress.clone(), None)).await.map_err(DlError::into_inner).unwrap();
        assert!(verified.is_some(), "Final disk read-back remains mandatory");
        assert_file(&partial, 1);
        assert_eq!(resumed_progress.transferred_bytes(), if corrupt { 16 << 20 } else { 0 },
            "Intact parked data must not redownload; a damaged piece alone is repaired");
        assert!(!exists(&partial));
    }
}

#[tokio::test]
async fn eof_replay_reads_saved_bytes_once_and_still_repairs_a_corrupt_piece() {
    use std::os::unix::fs::FileExt;
    for corrupt in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        let remote = fixture::Fixture::new(fixture::SIZE).await;
        let piece = 16u64 << 20;
        std::fs::write(data_path(&part), fixture::bytes(0, piece as usize, 1)).unwrap();
        let mut state = serde_json::to_value(State::new(remote.size, "\"fixture-1\"".into(), piece)).unwrap();
        state["pieces"][0]["complete"] = false.into();
        let state: State = serde_json::from_value(state).unwrap();
        assert!(state.needs_eof_replay(0));
        let digests = state.covered_ranges().map(|(_, offset, bytes)| integrity::fixture_digest(&data_path(&part), offset, bytes)).collect();
        save_with_hashes(&part, "range-fixture", &state, None, false, None, digests, identity_of(&part)).unwrap();
        if corrupt {
            std::fs::OpenOptions::new().write(true).open(data_path(&part)).unwrap().write_all_at(&[0xff], 100).unwrap();
        }
        let id = format!("generated-eof-read-counter-{corrupt}");
        let reads = super::super::completion_tests::ReadCounter::new(&id);
        let mut progress = DownloadProgressContext::new(false, &id, "generated.bin");
        progress.source_file_id = "range-fixture";
        let received = progress.transferred_bytes.clone();
        super::super::attempt(
            &reqwest::Client::builder().no_proxy().build().unwrap(), &remote.url, remote.size,
            &part, false, progress, None,
        ).await.map_err(DlError::into_inner).unwrap();
        assert_eq!(reads.bytes(), piece + remote.size,
            "resume must read the saved piece once, then preserve the full final integrity pass");
        assert_eq!(received.load(Ordering::Relaxed), if corrupt { remote.size } else { remote.size - piece + 1 },
            "only a damaged piece is redownloaded; an intact EOF replay requests one byte");
        assert_file(&part, 1);
        assert!(!exists(&part));
        println!("EOF replay corrupt={corrupt}: {} MiB verification reads (previous intact path: 96 MiB minus one byte)", reads.bytes() >> 20);
    }
}

#[tokio::test]
async fn stalled_parallel_download_keeps_its_durable_journal_unchanged() {
    use std::os::unix::fs::MetadataExt;

    let remote = fixture::Fixture::new(1024 * 1024).await;
    remote.hold_first.store(true, Ordering::Release);
    remote.hold_after_bytes.store(64 * 1024, Ordering::Release);
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    // Retained range state exercises the parallel writer with just one piece,
    // so another connection cannot advance coverage during the stalled body.
    std::fs::write(data_path(&part), []).unwrap();
    save(
        &part,
        "range-fixture",
        &State::new(remote.size, "\"fixture-1\"".into(), 0),
    )
    .unwrap();
    let url = remote.url.clone();
    let download_part = part.clone();
    let total = remote.size;
    let download = tokio::spawn(async move {
        super::super::attempt(
            &reqwest::Client::builder().no_proxy().build().unwrap(),
            &url,
            total,
            &download_part,
            false,
            progress(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
    });
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if load(&part, "range-fixture", remote.size)
                .unwrap()
                .is_some_and(|journal| journal.ranges.received() == 64 * 1024)
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("The generated prefix never reached its durable checkpoint");

    // Keep the old inode open so an unnecessary atomic replacement cannot
    // reuse its identity and conceal another journal write.
    let journal = std::fs::File::open(journal_path(&part)).unwrap();
    let before = journal.metadata().unwrap();
    tokio::time::sleep(Duration::from_millis(2100)).await;
    let after = std::fs::metadata(journal_path(&part)).unwrap();
    let unchanged = before.ino() == after.ino()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec();

    remote.hold_first.store(false, Ordering::Release);
    tokio::time::timeout(Duration::from_secs(10), download)
        .await
        .expect("The generated download did not resume")
        .unwrap()
        .unwrap();
    assert_eq!(
        std::fs::read(&part).unwrap(),
        fixture::bytes(0, remote.size as usize, 1)
    );
    assert!(
        unchanged,
        "A stalled download rewrote a journal whose durable coverage had not changed"
    );
}

async fn checkpoint_writer(part: &Path, bytes: &[u8]) -> Writer {
    std::fs::write(data_path(part), bytes).unwrap();
    let mut hash = integrity::Prefix::new();
    hash.update(bytes);
    let file = crate::download_fs::open_async(&data_path(part), rustix::fs::OFlags::RDWR).await.unwrap();
    Writer {
        write_gate: crate::download_verification::WriteGate::new(&file, "generated-checkpoint-writer"),
        file,
        buffers: BTreeMap::new(),
        hashes: vec![hash],
        offsets: vec![0],
        checkpointed: None,
        synced_identity: None,
        total: bytes.len() as u64,
    }
}

#[tokio::test]
async fn range_checkpoint_retries_failed_eof_commit_without_new_bytes() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let complete = State::new(8, "\"fixture\"".into(), 8);
    let mut serialized = serde_json::to_value(&complete).unwrap();
    serialized["pieces"][0]["complete"] = false.into();
    let incomplete: State = serde_json::from_value(serialized).unwrap();
    let mut writer = checkpoint_writer(&part, b"abcdefgh").await;
    writer
        .checkpoint(&part, "range-fixture", &incomplete, None, false, "fixture")
        .await
        .unwrap();
    assert!(!load(&part, "range-fixture", 8)
        .unwrap()
        .unwrap()
        .ranges
        .complete());

    let journal = journal_path(&part);
    let backup = directory.path().join("previous-journal");
    std::fs::rename(&journal, &backup).unwrap();
    std::fs::create_dir(&journal).unwrap();
    assert!(writer
        .checkpoint(&part, "range-fixture", &complete, None, false, "fixture")
        .await
        .is_err());
    std::fs::remove_dir(&journal).unwrap();
    std::fs::rename(&backup, &journal).unwrap();

    writer
        .checkpoint(&part, "range-fixture", &complete, None, false, "fixture")
        .await
        .unwrap();
    let saved = load(&part, "range-fixture", 8).unwrap().unwrap();
    assert!(
        saved.ranges.complete(),
        "EOF must be committed even without new bytes"
    );
    assert_eq!(saved.ranges.received(), 8);
}

#[tokio::test]
async fn unchanged_range_checkpoint_still_rejects_replaced_staging() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let state = State::new(8, "\"fixture\"".into(), 3);
    let mut writer = checkpoint_writer(&part, b"abc").await;
    writer
        .checkpoint(&part, "range-fixture", &state, None, false, "fixture")
        .await
        .unwrap();
    let saved = std::fs::read(journal_path(&part)).unwrap();
    let preserved = directory.path().join("preserved-data");
    std::fs::rename(data_path(&part), &preserved).unwrap();
    std::fs::write(data_path(&part), b"replacement").unwrap();

    let error = writer
        .checkpoint(&part, "range-fixture", &state, None, false, "fixture")
        .await
        .unwrap_err();
    assert!(download_policy::destination_unavailable(&error));
    assert_eq!(std::fs::read(journal_path(&part)).unwrap(), saved);
    assert_eq!(std::fs::read(&preserved).unwrap(), b"abc");
    assert_eq!(std::fs::read(data_path(&part)).unwrap(), b"replacement");
}

#[tokio::test]
async fn newly_created_ranges_reverify_guest_checkpoint_before_sequential_user_suffix() {
    let prefix = 3 * 1024 * 1024;
    for (mode, sequential_start) in [(5, prefix), (6, 16 * 1024 * 1024)] {
        let remote = fixture::Fixture::new(fixture::SIZE).await;
        remote.mode.store(mode, Ordering::Release);
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        std::fs::write(&part, fixture::bytes(0, prefix as usize, 1)).unwrap();
        ResumeState {
            file_id: "range-fixture".into(),
            total: remote.size,
            etag: String::new(),
            source_revision: Some("gcid:GENERATEDORIGINAL".into()),
            require_content_hash: true,
            source_key: Some("previous-guest-route".into()),
            durable_bytes: Some(prefix),
            unverified_tail: None,
            prefix_sha256: Some(integrity::fixture_digest(&part, 0, prefix)),
        }
        .save(&part)
        .unwrap();
        assert!(!exists(&part));
        let mut context = progress();
        context.source_revision = Some("gcid:GENERATEDORIGINAL".into());
        context.require_content_hash = true;
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        super::super::attempt(
            &http,
            &remote.url,
            remote.size,
            &part,
            false,
            context.clone(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert_file(&part, 1);
        assert!(!exists(&part));
        assert_eq!(
            context.transferred_bytes(),
            remote.size - prefix,
            "User must retrieve only the missing suffix after sparse fallback"
        );
        let requests = remote.requests.lock().unwrap();
        assert!(
            requests
                .iter()
                .any(|request| request.start == 0 && request.end == 0),
            "A strong User ETag probe must create fresh sparse state"
        );
        assert!(
            requests
                .iter()
                .any(|request| request.start == prefix && request.end < remote.size - 1),
            "The bounded range must exercise fresh sparse conversion"
        );
        assert!(
            requests
                .iter()
                .any(|request| request.start == sequential_start && request.end == remote.size - 1),
            "User sequential continuation must reuse all verified Guest bytes"
        );
        assert!(
            requests.iter().all(|request| request.ranged),
            "A fallback must not spend User quota downloading the full original"
        );
        let saved = ResumeState::load(&part, "range-fixture", remote.size)
            .unwrap()
            .unwrap();
        assert_eq!(saved.durable_bytes, Some(remote.size));
        assert_eq!(
            saved.prefix_sha256.as_deref(),
            Some(integrity::fixture_digest(&part, 0, remote.size).as_str())
        );
    }
}

#[tokio::test]
async fn complete_range_journal_avoids_probe_only_for_a_matching_original_hash() {
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    for (saved_revision, current_revision, prefix, saved_file_id, complete) in [
        (
            Some("gcid:ORIGINAL"),
            Some("gcid:original"),
            8,
            "range-fixture",
            true,
        ),
        (None, Some("gcid:original"), 8, "range-fixture", false),
        (
            Some("gcid:OLD"),
            Some("gcid:original"),
            8,
            "range-fixture",
            false,
        ),
        (Some("gcid:ORIGINAL"), None, 8, "range-fixture", false),
        (
            Some("modified:unchanged"),
            Some("modified:unchanged"),
            8,
            "range-fixture",
            false,
        ),
        (
            Some("gcid:ORIGINAL"),
            Some("gcid:original"),
            8,
            "other-file",
            false,
        ),
        (
            Some("gcid:ORIGINAL"),
            Some("gcid:original"),
            3,
            "range-fixture",
            false,
        ),
    ] {
        let fixture = fixture::Fixture::new(8).await;
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.part");
        std::fs::write(data_path(&partial), fixture::bytes(0, 8, 1)).unwrap();
        std::fs::File::open(data_path(&partial))
            .unwrap()
            .sync_data()
            .unwrap();
        save_with_revision(
            &partial,
            saved_file_id,
            &State::new(8, "\"fixture-1\"".into(), prefix),
            saved_revision,
            true,
            None,
        )
        .unwrap();
        let mut progress = progress();
        progress.source_revision = current_revision.map(str::to_owned);
        progress.require_content_hash = true;
        super::super::attempt(
            &http,
            &fixture.url,
            8,
            &partial,
            false,
            progress.clone(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert_eq!(
            fixture.requests.lock().unwrap().is_empty(),
            complete,
            "Complete sparse data was trusted without GCID and coverage proof"
        );
        assert_eq!(progress.transferred_bytes() == 0, complete);
        assert_eq!(std::fs::read(&partial).unwrap(), fixture::bytes(0, 8, 1));
        assert!(!exists(&partial));
        assert_eq!(
            ResumeState::load(&partial, "range-fixture", 8)
                .unwrap()
                .unwrap()
                .durable_bytes,
            Some(8)
        );
    }
}

#[tokio::test]
async fn cross_cdn_ranges_keep_coverage_only_when_original_hash_matches() {
    use std::io::{Seek, Write};
    // These generated originals must stay on loopback, independently of the
    // host's proxy environment (as the production download client does).
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    for same_original in [true, false] {
        let fixture = fixture::Fixture::new(fixture::SIZE).await;
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        let old_etag = if same_original {
            "\"guest-cdn\""
        } else {
            "\"fixture-1\""
        };
        let mut state = serde_json::to_value(State::new(fixture.size, old_etag.into(), 0)).unwrap();
        for index in [1, 3] {
            state["pieces"][index]["received"] = (16u64 << 20).into();
            state["pieces"][index]["complete"] = true.into();
        }
        let state: State = serde_json::from_value(state).unwrap();
        let mut data = std::fs::File::create(data_path(&part)).unwrap();
        data.set_len(fixture.size).unwrap();
        for start in [16u64 << 20, 48u64 << 20] {
            data.seek(SeekFrom::Start(start)).unwrap();
            for offset in (start..start + (16 << 20)).step_by(65536) {
                data.write_all(&fixture::bytes(
                    offset,
                    65536,
                    if same_original { 1 } else { 2 },
                ))
                .unwrap();
            }
        }
        data.sync_all().unwrap();
        drop(data);
        save_with_revision(
            &part,
            "range-fixture",
            &state,
            Some("gcid:ORIGINAL"),
            true,
            None,
        )
        .unwrap();
        let mut progress = progress();
        progress.source_revision = Some(
            if same_original {
                "gcid:original"
            } else {
                "gcid:changed"
            }
            .into(),
        );
        progress.require_content_hash = true;
        super::super::attempt(
            &http,
            &fixture.url,
            fixture.size,
            &part,
            false,
            progress.clone(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap_or_else(|error| {
            panic!(
                "same_original={same_original}: {error:#}; requests={:?}",
                fixture.requests.lock().unwrap()
            )
        });
        assert_file(&part, 1);
        assert!(!exists(&part));
        assert_eq!(
            progress.transferred_bytes(),
            if same_original {
                32 << 20
            } else {
                fixture.size
            }
        );
        let requests = fixture.requests.lock().unwrap();
        assert_eq!(requests.len(), if same_original { 3 } else { 5 });
        assert!(requests
            .iter()
            .filter(|request| request.end > request.start)
            .all(|request| request.if_range.as_deref() == Some("\"fixture-1\"")));
    }
}

#[tokio::test]
async fn new_process_resumes_a_full_length_sparse_file_without_trusting_holes() {
    check_sparse_restart("generated.part", Journal::WithoutIdentity).await;
}

#[tokio::test]
async fn long_filename_sparse_restart_reuses_hashed_journal_and_only_missing_ranges() {
    check_sparse_restart(&format!("{}.bin.part", "range".repeat(49) + "x"), Journal::WithoutIdentity).await;
}

/// How the journal was saved before the process stopped.
#[derive(Clone, Copy)]
enum Journal {
    /// Older engines, which recorded no identity, so a resume reads every saved piece back.
    WithoutIdentity,
    /// This engine: the identity of the synced staging file, so a resume trusts the complete pieces.
    WithIdentity,
    /// This engine, but something touched the staging file afterwards, so a resume reads every piece back.
    ChangedAfterSave,
}

#[tokio::test]
async fn a_resume_that_trusts_saved_pieces_fetches_only_the_missing_range() {
    check_sparse_restart("generated.part", Journal::WithIdentity).await;
}

#[tokio::test]
async fn a_resume_of_a_touched_staging_file_still_fetches_only_the_missing_range() {
    check_sparse_restart("generated.part", Journal::ChangedAfterSave).await;
}

async fn check_sparse_restart(name: &str, journal: Journal) {
    use std::io::{Seek, Write};
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join(name);
    let mut state =
        serde_json::to_value(State::new(fixture.size, "\"fixture-1\"".into(), 0)).unwrap();
    for piece in state["pieces"].as_array_mut().unwrap().iter_mut().skip(1) {
        piece["received"] = (16u64 << 20).into();
        piece["complete"] = true.into();
    }
    let state: State = serde_json::from_value(state).unwrap();
    let mut data = std::fs::File::create(data_path(&part)).unwrap();
    data.set_len(fixture.size).unwrap();
    data.seek(SeekFrom::Start(16 << 20)).unwrap();
    for offset in (16 << 20..fixture.size).step_by(65536) {
        data.write_all(&fixture::bytes(offset, 65536, 1)).unwrap();
    }
    data.sync_all().unwrap();
    drop(data);
    match journal {
        Journal::WithoutIdentity => save(&part, "range-fixture", &state).unwrap(),
        Journal::WithIdentity | Journal::ChangedAfterSave => {
            let digests = state.covered_ranges().map(|(_, offset, bytes)| integrity::fixture_digest(&data_path(&part), offset, bytes)).collect();
            save_with_hashes(&part, "range-fixture", &state, None, false, None, digests, identity_of(&part)).unwrap();
            if matches!(journal, Journal::ChangedAfterSave) {
                std::fs::OpenOptions::new().write(true).open(data_path(&part)).unwrap()
                    .set_modified(std::time::SystemTime::now() + Duration::from_secs(120)).unwrap();
            }
        }
    }
    assert_eq!(
        saved_bytes(&part, "range-fixture", fixture.size),
        Some(48 << 20)
    );
    assert_eq!(
        std::fs::metadata(data_path(&part)).unwrap().len(),
        fixture.size
    );
    let path = part.clone();
    let url = fixture.url.clone();
    let child = tokio::task::spawn_blocking(move || {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "download_transport::parts::tests::resume_in_child",
            ])
            .env("MYCLOUD_RANGE_RESTART_PART", path)
            .env("MYCLOUD_RANGE_RESTART_URL", url)
            .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
            .output()
            .unwrap()
    })
    .await
    .unwrap();
    assert!(
        child.status.success(),
        "{}",
        String::from_utf8_lossy(&child.stderr)
    );
    assert_file(&part, 1);
    assert!(!exists(&part));
    let requests = fixture.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        2,
        "Restart downloaded previously completed ranges"
    );
    assert!(requests
        .iter()
        .any(|request| request.start == 0 && request.end == (16 << 20) - 1));
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn unfinished_ranges_resume_after_files_move_from_exfat_to_apfs() {
    use super::super::disk_fixture::{copy_files, TestDisk};
    use std::io::{Seek, Write};
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    let root = tempfile::tempdir().unwrap();
    let exfat = TestDisk::new(root.path(), "exfat", "ExFAT", 200);
    let before = exfat.mount.join("Videos");
    std::fs::create_dir_all(&before).unwrap();
    let part = before.join("generated.part");
    // Every piece after the first is done: 48 MiB held, the first 16 MiB still to fetch.
    let mut state =
        serde_json::to_value(State::new(fixture.size, "\"fixture-1\"".into(), 0)).unwrap();
    for piece in state["pieces"].as_array_mut().unwrap().iter_mut().skip(1) {
        piece["received"] = (16u64 << 20).into();
        piece["complete"] = true.into();
    }
    let state: State = serde_json::from_value(state).unwrap();
    let mut data = std::fs::File::create(data_path(&part)).unwrap();
    data.set_len(fixture.size).unwrap();
    data.seek(SeekFrom::Start(16 << 20)).unwrap();
    for offset in (16 << 20..fixture.size).step_by(65536) {
        data.write_all(&fixture::bytes(offset, 65536, 1)).unwrap();
    }
    data.sync_all().unwrap();
    drop(data);
    save(&part, "range-fixture", &state).unwrap();
    assert_eq!(saved_bytes(&part, "range-fixture", fixture.size), Some(48 << 20));

    // Back the unfinished files up, reformat the disk as APFS, then put them back.
    let backup = root.path().join("Backup");
    let names = copy_files(&before, &backup, "generated.part");
    assert_eq!(names, ["generated.part.ranges.data", "generated.part.ranges.json"]);
    drop(exfat);
    let apfs = TestDisk::new(root.path(), "apfs", "APFS", 200);
    let after = apfs.mount.join("Videos");
    copy_files(&backup, &after, "generated.part");
    let restored = after.join("generated.part");
    assert_eq!(saved_bytes(&restored, "range-fixture", fixture.size), Some(48 << 20));

    let path = restored.clone();
    let url = fixture.url.clone();
    let child = tokio::task::spawn_blocking(move || {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "download_transport::parts::tests::resume_in_child"])
            .env("MYCLOUD_RANGE_RESTART_PART", path)
            .env("MYCLOUD_RANGE_RESTART_URL", url)
            .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
            .output()
            .unwrap()
    })
    .await
    .unwrap();
    assert!(child.status.success(), "{}", String::from_utf8_lossy(&child.stderr));
    assert_file(&restored, 1);
    assert!(!exists(&restored));
    let requests = fixture.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        2,
        "Resume downloaded ranges that were already complete: {:?}",
        requests.iter().map(|request| (request.start, request.end)).collect::<Vec<_>>()
    );
    assert!(requests
        .iter()
        .any(|request| request.start == 0 && request.end == (16 << 20) - 1));
}

#[tokio::test]
async fn resume_in_child() {
    let Some(part) = std::env::var_os("MYCLOUD_RANGE_RESTART_PART") else {
        return;
    };
    let url = std::env::var("MYCLOUD_RANGE_RESTART_URL").unwrap();
    super::super::attempt(
        &reqwest::Client::new(),
        &url,
        fixture::SIZE,
        Path::new(&part),
        false,
        progress(),
        None,
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap();
}

#[test]
fn pause_resume_changed_original_and_cancel_are_isolated_in_children() {
    for mode in ["resume", "changed", "cancel"] {
        let directory = tempfile::tempdir().unwrap();
        let control = directory.path().join("control.json");
        std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "download_transport::parts::tests::pause_in_child",
            ])
            .env("MYCLOUD_RANGE_PAUSE_MODE", mode)
            .env("MYCLOUDDRIVER_TRANSFER_CONTROL", &control)
            .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
            .output()
            .unwrap();
        assert!(
            child.status.success(),
            "{mode}: {}\n{}",
            String::from_utf8_lossy(&child.stdout),
            String::from_utf8_lossy(&child.stderr)
        );
    }
}

#[tokio::test]
async fn pause_in_child() {
    let Ok(mode) = std::env::var("MYCLOUD_RANGE_PAUSE_MODE") else {
        return;
    };
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    fixture.hold_first.store(true, Ordering::Release);
    // Establish real flowing evidence before stalling the first piece. The
    // controller must not infer spare bandwidth from an already stopped body.
    fixture.chunk_delay_millis.store(50, Ordering::Release);
    fixture.hold_after_bytes.store(12 << 20, Ordering::Release);
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let control = PathBuf::from(std::env::var_os("MYCLOUDDRIVER_TRANSFER_CONTROL").unwrap());
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let progress = progress();
    let action = if mode == "cancel" { "cancel" } else { "pause" };
    let pause = async {
        tokio::time::timeout(Duration::from_secs(25), async {
            while progress.transferred_bytes() < 20 << 20 {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("Parallel range never started beside the stalled first piece");
        std::fs::write(
            &control,
            serde_json::to_vec(&serde_json::json!({"actions":{"range-fixture":action}})).unwrap(),
        )
        .unwrap();
    };
    let download = super::super::attempt(
        &http,
        &fixture.url,
        fixture.size,
        &part,
        false,
        progress.clone(),
        Some("https://mypikpak.com/"),
    );
    let (result, _) = tokio::join!(download, pause);
    let failure = result.err().unwrap().into_inner();
    assert!(fixture.peak.load(Ordering::Acquire) >= 2);
    if mode == "cancel" {
        assert!(failure.is::<transfer_control::Cancelled>());
        assert!(!exists(&part));
        assert!(!part.exists());
        return;
    }
    assert!(failure.is::<transfer_control::Paused>());
    let retained = load(&part, "range-fixture", fixture.size)
        .unwrap()
        .unwrap()
        .ranges;
    assert!(retained.received() > 16 << 20 && retained.received() < fixture.size);
    assert!(retained.prefix() < retained.received());
    assert!(
        !part.exists(),
        "Sparse data became a legacy contiguous prefix"
    );
    fixture.hold_first.store(false, Ordering::Release);
    fixture.chunk_delay_millis.store(0, Ordering::Release);
    if mode == "changed" {
        fixture.revision.store(2, Ordering::Release);
    }
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    tokio::time::sleep(Duration::from_millis(120)).await;
    let before = progress.transferred_bytes();
    super::super::attempt(
        &http,
        &fixture.url,
        fixture.size,
        &part,
        false,
        progress.clone(),
        Some("https://mypikpak.com/"),
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap();
    assert_file(&part, if mode == "changed" { 2 } else { 1 });
    assert!(!exists(&part));
    if mode == "resume" {
        assert!(progress.transferred_bytes() - before <= fixture.size - retained.received() + 4);
    }
    assert!(fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .all(|request| request.referer));
}

#[tokio::test]
async fn ignored_or_malformed_ranges_fall_back_to_validated_sequential_download() {
    for mode in [1, 2, 3] {
        let fixture = fixture::Fixture::new(fixture::SIZE).await;
        fixture.mode.store(mode, Ordering::Release);
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        super::super::attempt(
            &reqwest::Client::new(),
            &fixture.url,
            fixture.size,
            &part,
            false,
            progress(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert_file(&part, 1);
        assert!(!exists(&part));
        assert!(fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|request| !request.ranged));
    }
}

#[tokio::test]
async fn changed_sparse_checkpoint_bytes_and_legacy_digests_cannot_certify_coverage() {
    for prefix in [3, 8] {
        for mutation in ["replace", "edit", "legacy", "damaged_digests"] {
            let fixture = fixture::Fixture::new(8).await;
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join("generated.part");
            std::fs::write(data_path(&partial), fixture::bytes(0, prefix, 1)).unwrap();
            save_with_revision(
                &partial,
                "range-fixture",
                &State::new(8, "\"fixture-1\"".into(), prefix as u64),
                Some("gcid:ORIGINAL"),
                true,
                None,
            )
            .unwrap();
            match mutation {
                "replace" => {
                    let replacement = directory.path().join("replacement");
                    std::fs::write(&replacement, vec![b'X'; prefix]).unwrap();
                    std::fs::rename(replacement, data_path(&partial)).unwrap();
                }
                "edit" => std::fs::write(data_path(&partial), vec![b'X'; prefix]).unwrap(),
                "legacy" | "damaged_digests" => {
                    let mut saved: serde_json::Value =
                        serde_json::from_slice(&std::fs::read(journal_path(&partial)).unwrap())
                            .unwrap();
                    if mutation == "legacy" {
                        saved.as_object_mut().unwrap().remove("piece_sha256");
                    } else {
                        saved["piece_sha256"] = serde_json::json!([]);
                    }
                    std::fs::write(journal_path(&partial), serde_json::to_vec(&saved).unwrap())
                        .unwrap();
                }
                _ => unreachable!(),
            }
            let mut progress = progress();
            progress.source_revision = Some("gcid:ORIGINAL".into());
            progress.require_content_hash = true;
            super::super::attempt(
                &reqwest::Client::builder().no_proxy().build().unwrap(),
                &fixture.url,
                8,
                &partial,
                false,
                progress.clone(),
                None,
            )
            .await
            .map_err(DlError::into_inner)
            .unwrap();
            assert_eq!(
                progress.transferred_bytes(),
                8,
                "{mutation} sparse prefix {prefix} was trusted"
            );
            assert_eq!(std::fs::read(&partial).unwrap(), fixture::bytes(0, 8, 1));
            assert!(!exists(&partial));
        }
    }
}

#[tokio::test]
async fn sparse_aggregate_checksum_rejects_mutation_after_piece_verification() {
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("generated.part");
    std::fs::write(data_path(&partial), b"abcdefgh").unwrap();
    let state = State::new(8, "\"original\"".into(), 8);
    let hashes = read_hashes(&data_path(&partial), &state, "synthetic-control")
        .await
        .map_err(DlError::into_inner)
        .unwrap();
    let proof = prefix_proof(
        &state,
        &hashes
            .iter()
            .map(integrity::Prefix::digest)
            .collect::<Vec<_>>(),
    );
    std::fs::write(data_path(&partial), b"BAD-DATA").unwrap();
    assert!(save_serial_prefix(
        &partial,
        &data_path(&partial),
        ResumeState {
            file_id: "range-fixture".into(),
            total: 8,
            etag: "\"original\"".into(),
            source_revision: Some("gcid:ORIGINAL".into()),
            require_content_hash: true,
            source_key: None,
            durable_bytes: Some(8),
            unverified_tail: None,
            prefix_sha256: None
        },
        &proof,
        "synthetic-control",
        None,
    )
    .await
    .is_err());
    assert!(ResumeState::load(&partial, "range-fixture", 8)
        .unwrap()
        .is_none());
}

// MARK: Resuming without reading every saved byte again

const PIECE: u64 = 16 << 20;

#[test]
fn normal_shutdown_drains_received_ram_and_recreates_pending_work_on_resume() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().to_ascii_lowercase().ends_with("proxy") { child.env_remove(key); }
    }
    let result = child.env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (4 << 20).to_string())
        .args(["--exact", "download_transport::parts::tests::normal_shutdown_drain_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated shutdown controls and 4 MiB budget; launched by parent"]
async fn normal_shutdown_drain_child() {
    async fn wait_for(mut ready: impl FnMut() -> bool) {
        tokio::time::timeout(Duration::from_secs(10), async {
            while !ready() { tokio::time::sleep(Duration::from_millis(10)).await; }
        }).await.unwrap();
    }
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("generated-controls.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    std::fs::write(&control, br#"{"actions":{},"drain":false}"#).unwrap();
    let started = std::sync::Arc::new(tokio::sync::Notify::new());
    let release = std::sync::Arc::new(tokio::sync::Notify::new());
    let run_started = started.clone(); let run_release = release.clone();
    let failed_writer = tokio::spawn(async move {
        transfer_control::schedule(vec!["generated-failing-shutdown-writer"], 1,
            move |_| { let started = run_started.clone(); let release = run_release.clone(); async move {
                started.notify_one(); release.notified().await;
                Err::<(), _>(anyhow::anyhow!("generated disk write failure"))
            } }, |id| id.to_string(), |_, _| {}, |_, _, _| {}).await
    });
    started.notified().await;
    std::fs::write(&control, br#"{"actions":{},"drain":true}"#).unwrap();
    wait_for(transfer_control::draining).await;
    release.notify_one();
    assert!(tokio::time::timeout(Duration::from_secs(2), failed_writer).await.unwrap().unwrap().is_err(),
        "A failed buffer writer must not acknowledge a successful shutdown");
    for (id, total) in [("generated-shutdown-serial", 16 << 20), ("generated-shutdown-ranges", fixture::SIZE)] {
        std::fs::write(&control, br#"{"actions":{},"drain":false}"#).unwrap();
        wait_for(|| !transfer_control::draining()).await;
        let drive = crate::download_verification::TestDrive::new(id);
        let reader = drive.hold_read(1 << 20).await;
        let read_step = reader.chunk(256, id).await.unwrap();
        let remote = fixture::Fixture::new(total).await;
        let part = directory.path().join(format!("{id}.part"));
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let mut progress = DownloadProgressContext::new(false, id, "generated.bin");
        progress.source_file_id = "generated-drain-source";
        let received = progress.transferred_bytes.clone();
        let run_path = part.clone(); let url = remote.url.clone(); let run_http = http.clone();
        let attempt = tokio::spawn(async move {
            let scope = crate::download_verification::Scope::new(id.into(), None);
            scope.run(super::super::attempt(&run_http, &url, total, &run_path, false, progress, None)).await
        });
        wait_for(|| crate::download_buffer::snapshot().used >= 2 << 20).await;
        assert!(received.load(Ordering::Relaxed) >= 2 << 20);
        let pending_drive = drive.sibling("generated-shutdown-pending-reader");
        let probe_path = directory.path().join("generated-pending-read-probe");
        std::fs::write(&probe_path, vec![1; 1024]).unwrap();
        let probe = tokio::fs::File::open(probe_path).await.unwrap();
        let pending = tokio::spawn(async move {
            let _drive = pending_drive;
            crate::download_verification::acquire_async(&probe, "generated-shutdown-pending-reader", 1024).await
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!pending.is_finished());
        std::fs::write(&control, br#"{"actions":{"generated-cancelled":"cancel"},"drain":true}"#).unwrap();
        wait_for(transfer_control::draining).await;
        assert_eq!(transfer_control::action("generated-cancelled"), Some(transfer_control::Action::Cancel));
        assert_eq!(transfer_control::action(id), Some(transfer_control::Action::Pause));
        match tokio::time::timeout(Duration::from_secs(2), pending).await.unwrap().unwrap() {
            Err(error) => assert!(error.is::<transfer_control::Paused>()),
            Ok(_) => panic!("A pending verifier started reading during shutdown"),
        }
        drop(read_step); drop(reader);
        let error = tokio::time::timeout(Duration::from_secs(10), attempt).await.unwrap().unwrap()
            .err().expect("shutdown must preserve an unfinished checkpoint").into_inner();
        assert!(error.is::<transfer_control::Paused>(), "{error:#}");
        let accepted = received.load(Ordering::Relaxed);
        let durable = if total < download_ranges::MIN_PARALLEL_SIZE {
            ResumeState::load(&part, "generated-drain-source", total).unwrap().unwrap().durable_bytes.unwrap()
        } else { load(&part, "generated-drain-source", total).unwrap().unwrap().ranges.received() };
        assert_eq!(durable, accepted, "Every body byte received before normal shutdown must reach a synced checkpoint");
        assert!(durable > 0 && durable < total);
        if total >= download_ranges::MIN_PARALLEL_SIZE {
            let journal = load(&part, "generated-drain-source", total).unwrap().unwrap();
            let proof = prefix_proof(&journal.ranges, journal.piece_sha256.as_deref().unwrap());
            let interrupted = verify_finished_staging(&part, "generated-drain-source", total, ResumeState {
                file_id: "generated-drain-source".into(), total, etag: journal.ranges.etag().into(),
                source_revision: None, require_content_hash: false, source_key: None,
                unverified_tail: None,
                durable_bytes: Some(journal.ranges.prefix()), prefix_sha256: None,
            }, &proof, id).await.err().unwrap().into_inner();
            assert!(interrupted.is::<transfer_control::Paused>());
            assert_eq!(load(&part, "generated-drain-source", total).unwrap().unwrap().data_identity, journal.data_identity,
                "An interrupted checksum check must not invalidate synced completed-piece proof");
        }
        wait_for(|| crate::download_buffer::snapshot().used == 0).await;
        // New attempts must not be admitted while the helper is joining its writers.
        transfer_control::schedule(vec!["generated-not-admitted"], 1,
            |_| async { panic!("shutdown admitted new work"); #[allow(unreachable_code)] Ok(()) },
            |id| id.to_string(), |_, _| {}, |_, _, _| {}).await.unwrap();
        std::fs::write(&control, br#"{"actions":{},"drain":false}"#).unwrap();
        wait_for(|| !transfer_control::draining()).await;
        // A fresh retry state recreates checksum work from the on-disk journal.
        let mut resumed = DownloadProgressContext::new(false, id, "generated.bin");
        resumed.source_file_id = "generated-drain-source";
        let scope = crate::download_verification::Scope::new(id.into(), None);
        scope.run(super::super::attempt(&http, &remote.url, total, &part, false, resumed, None))
            .await.map_err(DlError::into_inner).unwrap();
        assert_eq!(std::fs::read(&part).unwrap(), fixture::bytes(0, total as usize, 1));
    }
}

#[tokio::test]
async fn streaming_ram_checkpoint_keeps_each_piece_eof_and_avoids_completed_piece_rereads() {
    use std::os::unix::fs::FileExt;
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated-eof-checkpoint.part");
    let remote = fixture::Fixture::new(fixture::SIZE).await;
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let file = std::fs::OpenOptions::new().create_new(true).read(true).write(true).open(data_path(&part)).unwrap();
    let initial = State::new(remote.size, "\"fixture-1\"".into(), 0);
    let mut hashes: Vec<_> = initial.covered_ranges().map(|_| integrity::Prefix::new()).collect();
    let transfer = Transfer::new(&http, &remote.url, None, initial, pikpak::download_network::Network::new(1, None)).unwrap();
    let mut buffered = crate::download_buffer::Ranges::new(transfer, |_| {});
    tokio::time::timeout(Duration::from_secs(15), async {
        while let Some(chunk) = buffered.next().await.unwrap() {
            if chunk.index > 0 {
                assert!(buffered.state().piece_complete(0),
                    "The disk checkpoint must learn the first piece's EOF before the whole file finishes");
            }
            file.write_all_at(&chunk.bytes, chunk.offset).unwrap();
            if chunk.offset + chunk.bytes.len() as u64 == (chunk.index as u64 + 1) * PIECE {
                hashes[chunk.index].update_for_replay(&chunk.bytes);
            } else { hashes[chunk.index].update(&chunk.bytes); }
            buffered.accept(&chunk);
            if chunk.index > 0 { break; }
        }
    }).await.unwrap();
    buffered.stop();
    let saved = buffered.state().clone();
    assert!(saved.piece_complete(0) && !saved.complete());
    file.sync_all().unwrap();
    let digests: Vec<_> = hashes.iter().map(integrity::Prefix::digest).collect();
    save_with_hashes(&part, "range-fixture", &saved, None, false, None, digests.clone(), identity_of(&part)).unwrap();
    drop(file);
    let restored = restore_hashes(&data_path(&part), &saved, &digests, identity_of(&part).as_ref(), "generated-eof-checkpoint")
        .await.map_err(DlError::into_inner).unwrap();
    assert_eq!(restored.bytes_read, saved.received() - PIECE,
        "A helper restart reads only the partial piece, skipping the completed 16 MiB piece");
    let id = "generated-eof-checkpoint-final-verification";
    let reads = super::super::completion_tests::ReadCounter::new(id);
    let mut context = DownloadProgressContext::new(false, id, "generated.bin");
    context.source_file_id = "range-fixture";
    super::super::attempt(&http, &remote.url, remote.size, &part, false, context, None)
        .await.map_err(DlError::into_inner).unwrap();
    assert_eq!(reads.bytes(), remote.size + saved.received() - PIECE,
        "The optimization must retain the entire final disk verification");
    assert_file(&part, 1);
}

#[tokio::test]
async fn interrupted_piece_and_eof_replay_reuse_contexts_without_losing_final_verification() {
    for prefix in [8 << 20, 16 << 20] {
        let id = format!("retry-range-prefix-{prefix}");
        let reads = super::super::completion_tests::ReadCounter::new(&id);
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        let remote = fixture::Fixture::new(fixture::SIZE).await;
        std::fs::write(data_path(&part), fixture::bytes(0, prefix as usize, 1)).unwrap();
        let mut state = serde_json::to_value(State::new(remote.size, "\"fixture-1\"".into(), prefix)).unwrap();
        state["pieces"][0]["complete"] = false.into();
        let state: State = serde_json::from_value(state).unwrap();
        save_with_revision(&part, "range-fixture", &state, Some("gcid:FIXTURE-1"), true, None).unwrap();
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let mut progress = DownloadProgressContext::new(false, &id, "generated.bin");
        progress.source_file_id = "range-fixture";
        progress.source_revision = Some("gcid:FIXTURE-1".into());
        progress.require_content_hash = true;
        remote.mode.store(4, Ordering::Release);
        for _ in 0..3 {
            assert!(super::super::attempt_for_publication(&http, &remote.url, remote.size, &part, false, progress.clone(), None).await.is_err());
            assert_eq!(reads.bytes(), prefix, "unchanged incomplete piece must be read only on the first attempt");
        }
        remote.mode.store(0, Ordering::Release);
        let proof = super::super::attempt_for_publication(&http, &remote.url, remote.size, &part, false, progress.clone(), None)
            .await.map_err(DlError::into_inner).unwrap().unwrap();
        assert_eq!(reads.bytes(), prefix + remote.size, "the final full verification is retained");
        assert_eq!(proof.hash.digest(), hex::encode(ring::digest::digest(&ring::digest::SHA256, &fixture::bytes(0, remote.size as usize, 1))));
        assert_eq!(progress.transferred_bytes.load(Ordering::Relaxed), remote.size - prefix + u64::from(prefix == PIECE));
        assert_file(&part, 1);
    }
}

/// Three whole pieces and a bit more, saved up to the middle of the third: two complete pieces and one partial.
fn resumed_staging(directory: &Path) -> (PathBuf, State, Vec<String>) {
    std::fs::create_dir_all(directory).unwrap();
    let part = directory.join("generated.part");
    let total = 3 * PIECE + 1_000;
    let data: Vec<u8> = (0..total).map(|index| (index % 251) as u8).collect();
    std::fs::write(data_path(&part), data).unwrap();
    let state = State::new(total, "\"fixture\"".into(), 2 * PIECE + (8 << 20));
    let digests = state.covered_ranges().map(|(_, offset, bytes)| integrity::fixture_digest(&data_path(&part), offset, bytes)).collect();
    (part, state, digests)
}

/// `DlError` has no `Debug`, so a failed restore is reported here.
async fn restored(path: &Path, state: &State, digests: &[String], identity: Option<&integrity::SavedIdentity>) -> RestoredHashes {
    match restore_hashes(path, state, digests, identity, "range-fixture").await {
        Ok(restored) => restored,
        Err(_) => panic!("restoring the saved hashes failed"),
    }
}

fn identity_of(part: &Path) -> Option<integrity::SavedIdentity> {
    integrity::SavedIdentity::of(&std::fs::metadata(data_path(part)).unwrap())
}

#[tokio::test]
async fn a_resume_trusts_complete_pieces_only_while_the_staging_file_is_exactly_as_saved() {
    let directory = tempfile::tempdir().unwrap();
    let (part, state, digests) = resumed_staging(directory.path());
    let saved = identity_of(&part);
    assert!(saved.is_some());
    let digests_of = |restored: &RestoredHashes| restored.hashes.iter().map(integrity::Prefix::digest).collect::<Vec<_>>();

    let trusted = restored(&data_path(&part), &state, &digests, saved.as_ref()).await;
    assert_eq!(trusted.bytes_read, 8 << 20, "only the partial piece is read back");
    assert_eq!(digests_of(&trusted), digests);
    assert_eq!(trusted.hashes.iter().map(|hash| hash.bytes).collect::<Vec<_>>(), vec![PIECE, PIECE, 8 << 20, 0], "two complete pieces, one partial, and the untouched tail");
    let opened = std::fs::metadata(data_path(&part)).unwrap();
    assert!(trusted.hashes.iter().all(|hash| hash.validate_restored(&opened).is_ok()), "a trusted piece is still bound to the file it was checked against");

    let legacy = restored(&data_path(&part), &state, &digests, None).await;
    assert_eq!(legacy.bytes_read, 40 << 20, "a journal without an identity verifies everything, as before");
    assert_eq!(digests_of(&legacy), digests);

    // Appending a byte changes the file, so nothing is trusted.
    let mut file = std::fs::OpenOptions::new().append(true).open(data_path(&part)).unwrap();
    std::io::Write::write_all(&mut file, b"!").unwrap();
    drop(file);
    let appended = restored(&data_path(&part), &state, &digests, saved.as_ref()).await;
    assert_eq!(appended.bytes_read, 40 << 20, "a changed file is read back in full");

    // Flipping a byte inside a complete piece must be caught even though the journal still says it was fine.
    let (other, state, digests) = resumed_staging(&directory.path().join("second"));
    let saved = identity_of(&other);
    {
        use std::os::unix::fs::FileExt;
        let file = std::fs::OpenOptions::new().write(true).open(data_path(&other)).unwrap();
        file.write_all_at(&[0xFF], 100).unwrap();
    }
    let corrupted = restored(&data_path(&other), &state, &digests, saved.as_ref()).await;
    assert_eq!(corrupted.bytes_read, 40 << 20);
    let found = digests_of(&corrupted);
    assert_ne!(found[0], digests[0], "the damaged piece no longer matches its saved digest");
    assert_eq!((&found[1], &found[2]), (&digests[1], &digests[2]));

    // A copy of the file is another file, however alike: it does not inherit the original's trust.
    let (third, state, digests) = resumed_staging(&directory.path().join("third"));
    let saved = identity_of(&third);
    let copy = directory.path().join("third-copy.part");
    std::fs::copy(data_path(&third), data_path(&copy)).unwrap();
    let copied = restored(&data_path(&copy), &state, &digests, saved.as_ref()).await;
    assert_eq!(copied.bytes_read, 40 << 20);
}

#[test]
fn a_verified_piece_cannot_take_more_bytes() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("piece");
    std::fs::write(&path, b"abc").unwrap();
    let metadata = std::fs::metadata(&path).unwrap();
    let frozen = integrity::Prefix::frozen(3, "aa".repeat(32), &metadata);
    assert_eq!((frozen.bytes, frozen.digest()), (3, "aa".repeat(32)));
    assert!(frozen.validate_restored(&metadata).is_ok());
    std::fs::write(&path, b"abcd").unwrap();
    assert!(frozen.validate_restored(&std::fs::metadata(&path).unwrap()).is_err(), "a file that changed after the check is refused");
    let mut frozen = frozen;
    assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| frozen.update(b"x"))).is_err());
}

#[tokio::test]
async fn every_checkpoint_records_the_staging_files_identity_after_the_sync() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let state = State::new(8, "\"fixture\"".into(), 3);
    let mut writer = checkpoint_writer(&part, b"abc").await;
    writer.checkpoint(&part, "range-fixture", &state, None, false, "fixture").await.unwrap();
    let saved = load(&part, "range-fixture", 8).unwrap().unwrap().data_identity;
    assert_eq!(saved, identity_of(&part), "the journal describes the file as it was when synced");
    assert!(saved.is_some());
    std::fs::OpenOptions::new().append(true).open(data_path(&part)).unwrap().set_len(8).unwrap();
    assert_ne!(saved, identity_of(&part), "any later change to the file no longer matches it");
}

#[test]
fn journals_without_an_identity_still_load() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let state = State::new(8, "\"fixture\"".into(), 3);
    std::fs::write(journal_path(&part), serde_json::to_vec(&serde_json::json!({
        "version": 1, "file_id": "range-fixture", "ranges": state, "piece_sha256": ["00"],
    })).unwrap()).unwrap();
    assert!(load(&part, "range-fixture", 8).unwrap().unwrap().data_identity.is_none());
}

fn finished_state(total: u64, state: &State) -> ResumeState {
    ResumeState {
        file_id: "range-fixture".into(), total, etag: state.etag().into(), source_revision: None, require_content_hash: false,
        unverified_tail: None,
        source_key: None, durable_bytes: Some(total), prefix_sha256: None,
    }
}

#[tokio::test]
async fn pieces_damaged_without_a_trace_fail_the_final_check_and_the_resume_no_longer_trusts_the_file() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let total = 2 * PIECE;
    let data: Vec<u8> = (0..total).map(|index| (index % 251) as u8).collect();
    std::fs::write(data_path(&part), &data).unwrap();
    let state = State::new(total, "\"fixture\"".into(), total);
    let digests: Vec<String> = state.covered_ranges().map(|(_, offset, bytes)| integrity::fixture_digest(&data_path(&part), offset, bytes)).collect();
    {
        // The file is damaged and then described as it now is, so its identity matches: nothing shows from outside.
        use std::os::unix::fs::FileExt;
        std::fs::OpenOptions::new().write(true).open(data_path(&part)).unwrap().write_all_at(&[0xFF], 100).unwrap();
    }
    save_with_hashes(&part, "range-fixture", &state, None, false, None, digests.clone(), identity_of(&part)).unwrap();
    let journal = load(&part, "range-fixture", total).unwrap().unwrap();
    let resumed = restored(&data_path(&part), &journal.ranges, journal.piece_sha256.as_ref().unwrap(), journal.data_identity.as_ref()).await;
    assert_eq!(resumed.bytes_read, 0, "a resume believes the saved digests while the file's identity matches");

    // The download then reaches its end: one full pass over the file compares every piece with its digest.
    let proof = prefix_proof(&state, &resumed.hashes.iter().map(integrity::Prefix::digest).collect::<Vec<_>>());
    let outcome = verify_finished_staging(&part, "range-fixture", total, finished_state(total, &state), &proof, "range-fixture").await;
    assert!(outcome.is_err(), "the final pass finds the damaged piece before the file is finalized");

    // And the next attempt cannot trust the same file again: it reads everything back and sees the damage.
    let journal = load(&part, "range-fixture", total).unwrap().unwrap();
    assert!(journal.data_identity.is_none(), "the failed check withdrew the trust");
    let next = restored(&data_path(&part), &journal.ranges, journal.piece_sha256.as_ref().unwrap(), journal.data_identity.as_ref()).await;
    assert_eq!(next.bytes_read, total, "everything is read back");
    assert_ne!(next.hashes[0].digest(), journal.piece_sha256.as_ref().unwrap()[0], "and the damaged piece no longer matches");
    assert_eq!(next.hashes[1].digest(), journal.piece_sha256.as_ref().unwrap()[1]);
}

#[tokio::test]
async fn an_undamaged_resumed_download_passes_the_final_check_and_keeps_its_journal() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let total = 2 * PIECE;
    std::fs::write(data_path(&part), (0..total).map(|index| (index % 251) as u8).collect::<Vec<u8>>()).unwrap();
    let state = State::new(total, "\"fixture\"".into(), total);
    let digests: Vec<String> = state.covered_ranges().map(|(_, offset, bytes)| integrity::fixture_digest(&data_path(&part), offset, bytes)).collect();
    save_with_hashes(&part, "range-fixture", &state, None, false, None, digests.clone(), identity_of(&part)).unwrap();
    let proof = prefix_proof(&state, &digests);
    let outcome = verify_finished_staging(&part, "range-fixture", total, finished_state(total, &state), &proof, "range-fixture").await;
    assert!(outcome.is_ok());
    assert!(load(&part, "range-fixture", total).unwrap().unwrap().data_identity.is_some(), "a passing check leaves the journal alone");
}

/// One attempt in a fresh process, as the app does after a failure: true when it succeeded.
async fn attempt_in_child(part: &Path, url: &str) -> bool {
    let (path, url) = (part.to_owned(), url.to_owned());
    tokio::task::spawn_blocking(move || {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "download_transport::parts::tests::resume_in_child"])
            .env("MYCLOUD_RANGE_RESTART_PART", path)
            .env("MYCLOUD_RANGE_RESTART_URL", url)
            .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
            .output()
            .unwrap()
            .status
            .success()
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn a_piece_damaged_without_a_trace_is_found_at_the_end_and_healed_by_the_next_attempt() {
    use std::io::{Seek, Write};
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let mut state = serde_json::to_value(State::new(fixture.size, "\"fixture-1\"".into(), 0)).unwrap();
    for piece in state["pieces"].as_array_mut().unwrap().iter_mut().skip(1) {
        piece["received"] = (16u64 << 20).into();
        piece["complete"] = true.into();
    }
    let state: State = serde_json::from_value(state).unwrap();
    let mut data = std::fs::File::create(data_path(&part)).unwrap();
    data.set_len(fixture.size).unwrap();
    data.seek(SeekFrom::Start(16 << 20)).unwrap();
    for offset in (16 << 20..fixture.size).step_by(65536) {
        data.write_all(&fixture::bytes(offset, 65536, 1)).unwrap();
    }
    data.sync_all().unwrap();
    drop(data);
    // The digests are those of the good data; then one byte of the second piece goes bad, and the journal is written
    // as if the damaged file were what was synced: its identity matches, so the resume believes it.
    let digests: Vec<String> = state.covered_ranges().map(|(_, offset, bytes)| integrity::fixture_digest(&data_path(&part), offset, bytes)).collect();
    {
        use std::os::unix::fs::FileExt;
        std::fs::OpenOptions::new().write(true).open(data_path(&part)).unwrap().write_all_at(&[0x5A, 0x5A], (16 << 20) + 1_000).unwrap();
    }
    save_with_hashes(&part, "range-fixture", &state, None, false, None, digests, identity_of(&part)).unwrap();

    assert!(!attempt_in_child(&part, &fixture.url).await, "the first attempt fetches the missing piece, then the final check finds the damage");
    let first = fixture.requests.lock().unwrap().len();
    assert!(exists(&part), "the staging data is kept for the next attempt");
    assert!(attempt_in_child(&part, &fixture.url).await, "the next attempt heals the file");
    assert_file(&part, 1);
    assert!(!exists(&part));
    let requests = fixture.requests.lock().unwrap();
    let healing: Vec<(u64, u64)> = requests[first..].iter().map(|request| (request.start, request.end)).collect();
    // Every resume starts with a one-byte probe of the original; beyond that only the damaged piece is fetched.
    let data: Vec<(u64, u64)> = healing.iter().copied().filter(|(start, end)| end > start).collect();
    assert_eq!(data, vec![(16 << 20, (32 << 20) - 1)], "only the damaged piece is fetched again, not the file: {healing:?}");
    assert!(healing.iter().all(|(start, end)| end == start || *start >= 16 << 20), "the saved pieces are not fetched again: {healing:?}");
}

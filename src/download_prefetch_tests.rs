//! Receive-ahead regressions use generated files and loopback HTTP only.
use super::*;
use crate::download_verification::{Scope, TestDrive};
use std::sync::{Arc, atomic::Ordering};
#[path = "download_range_fixture.rs"]
mod fixture;
const SOURCE: &str = "generated-receive-ahead-source";
async fn wait_for(mut ready: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(15), async {
        while !ready() { tokio::time::sleep(Duration::from_millis(10)).await; }
    }).await.expect("generated receive-ahead fixture timed out");
}
fn child(name: &str, ram: usize) {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", ram.to_string())
        .args(["--exact", name, "--ignored", "--nocapture"]).output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}
#[test]
fn finished_receivers_release_capacity_while_all_prefix_checks_are_blocked() {
    child("download_transport::parts::prefetch_tests::finished_receivers_do_not_block_the_ninth_download_child", 64 << 20);
}
#[test]
fn zero_byte_failed_receivers_release_capacity_before_verification() {
    child("download_transport::parts::prefetch_tests::empty_failed_receivers_do_not_block_healthy_receive_ahead_child", 128 << 20);
}

#[test]
fn sequential_fallback_receives_before_saved_prefix_verification() {
    child("download_transport::parts::prefetch_tests::streaming_fallback_before_verification_child", 128 << 20);
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated open-ended fallback and blocked physical reader"]
async fn streaming_fallback_before_verification_child() {
    let directory = tempfile::tempdir().unwrap();
    let remote = fixture::Fixture::new(fixture::SIZE).await;
    remote.mode.store(5, Ordering::Relaxed);
    let id = "generated-early-streaming-fallback";
    let drive = TestDrive::new(id);
    let reader = drive.hold_read(1 << 20).await;
    let step = reader.chunk(256, id).await.unwrap();
    let part = directory.path().join("generated.part");
    let original = fixture::bytes(0, 2 << 20, 1);
    std::fs::write(data_path(&part), &original).unwrap();
    let state = State::new(remote.size, "\"fixture-1\"".into(), original.len() as u64);
    let digests = state.covered_ranges().map(|(_, offset, bytes)| {
        let mut hash = integrity::Prefix::new(); hash.update(&fixture::bytes(offset, bytes as usize, 1)); hash.digest()
    }).collect();
    save_with_hashes(&part, SOURCE, &state, None, false, None, digests, None).unwrap();
    let journal = std::fs::read(journal_path(&part)).unwrap();
    let received = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let counter = received.clone(); let run_path = part.clone(); let url = remote.url.clone();
    let task = tokio::spawn(async move {
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let mut progress = DownloadProgressContext::new(false, id, "generated.bin");
        progress.source_file_id = SOURCE; progress.transferred_bytes = counter;
        Scope::new(id.into(), None).run(super::super::attempt(&http, &url, fixture::SIZE, &run_path, false, progress, None)).await
    });
    wait_for(|| received.load(Ordering::Relaxed) >= remote.size - original.len() as u64).await;
    assert!(!task.is_finished(), "RAM cannot become disk coverage before the saved prefix is checked");
    assert_eq!(std::fs::read(data_path(&part)).unwrap(), original);
    assert_eq!(std::fs::read(journal_path(&part)).unwrap(), journal);
    assert!(crate::download_buffer::snapshot().prefetch_bytes >= (remote.size - original.len() as u64) as usize);
    drop(step); drop(reader);
    tokio::time::timeout(Duration::from_secs(30), task).await.unwrap().unwrap().map_err(DlError::into_inner).unwrap();
    assert_eq!(std::fs::read(&part).unwrap(), fixture::bytes(0, remote.size as usize, 1));
    wait_for(|| crate::download_buffer::snapshot().used == 0 && crate::download_buffer::snapshot().prefetch_contexts == 0).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated receiving capacity and shared RAM budget"]
async fn finished_receivers_do_not_block_the_ninth_download_child() {
    let directory = tempfile::tempdir().unwrap();
    let total = 4 << 20;
    let prefix = 2 << 20;
    let remote = fixture::Fixture::new(total).await;
    let drive = TestDrive::new("generated-repro-held-read");
    let reader = drive.hold_read(1 << 20).await;
    let step = reader.chunk(256, "generated-repro-held-read").await.unwrap();
    let original = fixture::bytes(0, prefix as usize, 1);
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let mut jobs = Vec::new();
    let mut counters = Vec::new();
    for index in 0..9 {
        let id = format!("generated-unfinished-repro-{index}");
        let run_drive = drive.sibling(&id);
        let part = directory.path().join(format!("{id}.part"));
        std::fs::write(&part, &original).unwrap();
        let mut hash = integrity::Prefix::new(); hash.update(&original);
        ResumeState { file_id: SOURCE.into(), total, etag: "\"fixture-1\"".into(), source_revision: None,
            require_content_hash: false, source_key: Some(source_key(&remote.url)), durable_bytes: Some(prefix),
            unverified_tail: None, prefix_sha256: Some(hash.digest()) }.save(&part).unwrap();
        let received = Arc::new(std::sync::atomic::AtomicU64::new(0));
        counters.push(received.clone());
        let run_http = http.clone(); let url = remote.url.clone();
        jobs.push(tokio::spawn(async move {
            let _drive = run_drive;
            let mut progress = DownloadProgressContext::new(false, &id, "generated.bin"); progress.source_file_id = SOURCE;
            progress.transferred_bytes = received;
            Scope::new(id.clone(), None).run(super::super::attempt(&run_http, &url, total, &part, false, progress, None)).await
        }));
        if index < 8 {
            wait_for(|| counters[index].load(Ordering::Relaxed) >= total - prefix).await;
        }
    }
    // Verification stays blocked throughout; the ninth suffix must already
    // be in shared RAM rather than wait for a finished receiver's permit.
    wait_for(|| counters[8].load(Ordering::Relaxed) >= total - prefix).await;
    wait_for(|| crate::download_buffer::snapshot().prefetch_active_slots == 0).await;
    let buffer = crate::download_buffer::snapshot();
    assert_eq!(buffer.prefetch_tasks, 9);
    assert_eq!(buffer.prefetch_contexts, 9);
    assert_eq!(buffer.prefetch_bytes, 9 * (total - prefix) as usize);
    assert!(buffer.used < buffer.limit / 2 && buffer.waiting_receivers == 0);
    assert!(jobs.iter().all(|job| !job.is_finished()), "Every prefix check is still blocked");
    drop(step); drop(reader);
    for job in jobs {
        tokio::time::timeout(Duration::from_secs(20), job).await.unwrap().unwrap().map_err(DlError::into_inner).unwrap();
    }
    for index in 0..9 {
        let part = directory.path().join(format!("generated-unfinished-repro-{index}.part"));
        assert_eq!(std::fs::read(part).unwrap(), fixture::bytes(0, total as usize, 1));
    }
    wait_for(|| crate::download_buffer::snapshot().used == 0 && crate::download_buffer::snapshot().prefetch_contexts == 0).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated zero-byte failures and healthy receiving"]
async fn empty_failed_receivers_do_not_block_healthy_receive_ahead_child() {
    let directory = tempfile::tempdir().unwrap();
    let total = fixture::SIZE;
    let prefix = 2 << 20;
    let remote = fixture::Fixture::new(total).await;
    // Transient payload failure must be retried before the blocked checksum,
    // without changing the sparse data or its durable journal.
    remote.mode.store(4, Ordering::Relaxed);
    let drive = TestDrive::new("generated-repro-zero-ram-held-read");
    let reader = drive.hold_read(1 << 20).await;
    let step = reader.chunk(256, "generated-repro-zero-ram-held-read").await.unwrap();
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let mut jobs = Vec::new();
    let mut counters = Vec::new();
    for index in 0..9 {
        if index == 8 { remote.mode.store(0, Ordering::Relaxed); }
        let id = format!("generated-range-repro-{index}");
        let run_drive = drive.sibling(&id);
        let part = directory.path().join(format!("{id}.part"));
        std::fs::write(data_path(&part), fixture::bytes(0, prefix as usize, 1)).unwrap();
        let state = State::new(total, "\"fixture-1\"".into(), prefix);
        let digests = state.covered_ranges().map(|(_, offset, bytes)| {
            let mut hash = integrity::Prefix::new(); hash.update(&fixture::bytes(offset, bytes as usize, 1)); hash.digest()
        }).collect();
        save_with_hashes(&part, SOURCE, &state, None, false, None, digests, None).unwrap();
        let received = Arc::new(std::sync::atomic::AtomicU64::new(0));
        counters.push(received.clone());
        let run_http = http.clone(); let url = remote.url.clone();
        jobs.push(tokio::spawn(async move {
            let _drive = run_drive;
            let mut progress = DownloadProgressContext::new(false, &id, "generated.bin"); progress.source_file_id = SOURCE;
            progress.transferred_bytes = received;
            Scope::new(id.clone(), None).run(super::super::attempt(&run_http, &url, total, &part, false, progress, None)).await
        }));
        if index < 8 {
            wait_for(|| crate::download_buffer::snapshot().prefetch_failed == (index + 1) as u64
                && jobs[index].is_finished()).await;
        }
    }
    wait_for(|| counters[8].load(Ordering::Relaxed) >= 1 << 20).await;
    let buffer = crate::download_buffer::snapshot();
    assert_eq!(buffer.prefetch_tasks, 1);
    assert_eq!(buffer.prefetch_contexts, 1);
    assert_eq!(buffer.prefetch_failed, 8);
    assert_eq!(buffer.prefetch_empty_ends, 8);
    assert!(buffer.used < buffer.limit && buffer.waiting_receivers == 0);
    assert!(counters[..8].iter().all(|counter| counter.load(Ordering::Relaxed) == 0));
    assert!(jobs[..8].iter().all(|job| job.is_finished()), "Empty failures must not await disk verification");
    assert!(!jobs[8].is_finished(), "Healthy RAM still requires verification");
    drop(step); drop(reader);
    for job in &jobs { job.abort(); }
    for job in jobs { let _ = job.await; }
    wait_for(|| crate::download_buffer::snapshot().used == 0 && crate::download_buffer::snapshot().prefetch_tasks == 0).await;
}

#[test]
fn quit_preserves_empty_failed_prefetch_without_waiting_for_its_disk_check() {
    child("download_transport::parts::prefetch_tests::empty_prefetch_quit_child", 64 << 20);
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated normal Quit and generated empty failed prefetch"]
async fn empty_prefetch_quit_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("controls.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    std::fs::write(&control, r#"{"actions":{},"receive_only_pause":true,"drain":false}"#).unwrap();
    let id = "generated-empty-prefetch-quit";
    let remote = fixture::Fixture::new(fixture::SIZE).await;
    remote.mode.store(4, Ordering::Relaxed);
    let drive = TestDrive::new(id);
    let reader = drive.hold_read(1 << 20).await;
    let step = reader.chunk(256, id).await.unwrap();
    let part = directory.path().join("generated.part");
    let original = fixture::bytes(0, 2 << 20, 1);
    std::fs::write(data_path(&part), &original).unwrap();
    let state = State::new(remote.size, "\"fixture-1\"".into(), original.len() as u64);
    let digests = state.covered_ranges().map(|(_, offset, bytes)| {
        let mut hash = integrity::Prefix::new(); hash.update(&fixture::bytes(offset, bytes as usize, 1)); hash.digest()
    }).collect();
    save_with_hashes(&part, SOURCE, &state, None, false, None, digests, None).unwrap();
    let journal = std::fs::read(journal_path(&part)).unwrap();
    let run_path = part.clone(); let url = remote.url.clone();
    let attempt = tokio::spawn(async move {
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let mut progress = DownloadProgressContext::new(false, id, "generated.bin"); progress.source_file_id = SOURCE;
        Scope::new(id.into(), None).run(super::super::attempt(&http, &url, fixture::SIZE, &run_path, false, progress, None)).await
    });
    wait_for(|| crate::download_buffer::snapshot().prefetch_failed == 1
        && crate::download_buffer::snapshot().prefetch_active_slots == 0).await;
    assert_eq!(crate::download_buffer::snapshot().used, 0);
    assert!(!crate::download_buffer::prefetching(id), "An empty ended body has no RAM requiring Quit protection");
    wait_for(|| attempt.is_finished()).await;
    std::fs::write(&control, r#"{"actions":{"*":"pause"},"receive_only_pause":true,"drain":true}"#).unwrap();
    let result = tokio::time::timeout(Duration::from_secs(3), attempt).await
        .expect("Quit waited for a disk check despite having no accepted RAM").unwrap();
    assert!(pikpak::download_policy::retryable(&result.err().unwrap().into_inner()));
    // The read guard is still held, and the durable prefix/journal are intact
    // for the next process's normal resume and verification.
    assert_eq!(std::fs::read(data_path(&part)).unwrap(), original);
    assert_eq!(std::fs::read(journal_path(&part)).unwrap(), journal);
    drop(step); drop(reader);
    wait_for(|| crate::download_buffer::snapshot().prefetch_contexts == 0).await;
}

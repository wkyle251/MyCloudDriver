//! Generated files and a synthetic HDD only. One invalid receipt must fail
//! independently without making healthy callers retry completed payloads.
use super::*;
use std::{os::unix::fs::MetadataExt, sync::atomic::AtomicUsize};
use tokio::io::AsyncWriteExt;

#[test]
fn a_foreign_receipt_does_not_fail_the_other_members_of_its_checkpoint_batch() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "download_checkpoint::batch::guard_tests::mixed_guard_batch_child",
            "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(output.status.success(), "{}{}", String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr));
    println!("{}", String::from_utf8_lossy(&output.stdout));
}

async fn wait_for(mut ready: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while !ready() { tokio::time::sleep(Duration::from_millis(2)).await; }
    }).await.expect("Generated checkpoint requests did not advance");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated checkpoint counters and generated mixed-ownership batch"]
async fn mixed_guard_batch_child() {
    const COUNT: usize = 8;
    const FOREIGN: usize = 4;
    let _network = pikpak::download_network::Network::new(1, None);
    let root = tempfile::tempdir().unwrap();
    let holder_id = "generated-mixed-checkpoint-holder";
    let drive = crate::download_verification::TestDrive::new(holder_id);
    let holder = tokio::fs::File::create(root.path().join("generated-holder")).await.unwrap();
    let holder_gate = WriteGate::new(&holder, holder_id);
    let held = holder_gate.turn(false).await.unwrap();
    let pool = pool(holder_gate.key().unwrap(), holder.metadata().await.unwrap().dev());
    let before = snapshot();
    let calls = Arc::new(AtomicUsize::new(0));
    let mut guards = Vec::new();
    let mut jobs = Vec::new();
    for index in 0..COUNT {
        let data_path = root.path().join(format!("generated-{index}.data"));
        let journal_path = root.path().join(format!("generated-{index}.journal"));
        std::fs::write(&journal_path, b"generated-original-owner").unwrap();
        let id = format!("generated-mixed-checkpoint-{index}");
        let sibling = drive.sibling(&id);
        let calls = calls.clone();
        let checked = Arc::new(AtomicUsize::new(0));
        guards.push(checked.clone());
        jobs.push(tokio::spawn(async move {
            let _drive = sibling;
            let mut data = tokio::fs::File::create(&data_path).await.unwrap();
            data.write_all(b"generated-payload").await.unwrap();
            data.flush().await.unwrap();
            let gate = WriteGate::new(&data, &id);
            let metadata = data.metadata().await.unwrap();
            let guarded_path = journal_path.clone();
            let guard: download_fs::CheckpointPrecondition = Arc::new(move || {
                checked.fetch_add(1, Ordering::Relaxed);
                if std::fs::read(&guarded_path)? != b"generated-original-owner" {
                    return Err(std::io::Error::other("Generated foreign receipt owner"));
                }
                Ok(())
            });
            // There is deliberately one caller invocation: healthy requests
            // must finish inside the coordinator without retrying this work.
            calls.fetch_add(1, Ordering::Relaxed);
            commit_guarded(&gate, &data, metadata, &data_path, &journal_path,
                b"generated-new-checkpoint".to_vec(), guard).await
        }));
        // Keep the failing guard in the middle of the batch, after some
        // healthy journals have been staged but before any may be published.
        wait_for(|| pool.state.lock().unwrap().queue.len() == index + 1).await;
    }
    assert_eq!(snapshot().4 - before.4, COUNT);
    assert_eq!(pool.slots.available_permits(), MAX_PENDING - COUNT);
    assert!(jobs.iter().all(|job| !job.is_finished()));
    assert!(guards.iter().all(|checked| checked.load(Ordering::Relaxed) == 0));
    let foreign_path = root.path().join(format!("generated-{FOREIGN}.journal"));
    std::fs::write(&foreign_path, b"generated-foreign-receipt").unwrap();
    drop(held);
    for (index, job) in jobs.into_iter().enumerate() {
        let result = tokio::time::timeout(Duration::from_secs(10), job).await.unwrap().unwrap();
        if index == FOREIGN {
            assert!(result.is_err(), "Only the caller whose ownership guard failed must fail");
            assert!(format!("{:#}", result.unwrap_err()).contains("foreign"));
        } else {
            result.expect("Healthy callers must complete without retrying their checkpoint");
        }
        assert_eq!(std::fs::read(root.path().join(format!("generated-{index}.data"))).unwrap(),
            b"generated-payload");
        assert_eq!(std::fs::read(root.path().join(format!("generated-{index}.journal"))).unwrap(),
            if index == FOREIGN { b"generated-foreign-receipt".as_slice() }
            else { b"generated-new-checkpoint".as_slice() });
    }
    wait_for(|| {
        let state = pool.state.lock().unwrap();
        !state.running && state.queue.is_empty() && snapshot().4 == before.4
            && pool.slots.available_permits() == MAX_PENDING
    }).await;
    assert_eq!(calls.load(Ordering::Relaxed), COUNT, "No caller-level retry was allowed");
    assert_eq!(guards[FOREIGN].load(Ordering::Relaxed), 1,
        "The rejected member must be removed before retrying healthy requests");
    assert_eq!(*pool.batch_sizes.lock().unwrap(), vec![COUNT - 1],
        "Healthy members must still share one group commit");
    let after = snapshot();
    assert_eq!((after.0 - before.0, after.1 - before.1, after.2 - before.2),
        (1, (COUNT - 1) as u64, 2));

    // Exhausted or leaked admission permits would strand new work even after
    // all original callers resolved. Exercise the same retained pool again.
    let id = "generated-mixed-checkpoint-followup";
    let _sibling = drive.sibling(id);
    let data_path = root.path().join("generated-followup.data");
    let journal_path = root.path().join("generated-followup.journal");
    let mut data = tokio::fs::File::create(&data_path).await.unwrap();
    data.write_all(b"generated-followup-payload").await.unwrap();
    data.flush().await.unwrap();
    let gate = WriteGate::new(&data, id);
    tokio::time::timeout(Duration::from_secs(10), commit_guarded(&gate, &data,
        data.metadata().await.unwrap(), &data_path, &journal_path,
        b"generated-followup-checkpoint".to_vec(), Arc::new(|| Ok(()))))
        .await.unwrap().unwrap();
    wait_for(|| {
        let state = pool.state.lock().unwrap();
        !state.running && state.queue.is_empty() && snapshot().4 == before.4
            && pool.slots.available_permits() == MAX_PENDING
    }).await;
    assert_eq!(std::fs::read(&journal_path).unwrap(), b"generated-followup-checkpoint");
    assert_eq!(std::fs::read(&foreign_path).unwrap(), b"generated-foreign-receipt");
    assert_eq!(*pool.batch_sizes.lock().unwrap(), vec![COUNT - 1, 1]);
    println!("GENERATED_MIXED_RECEIPT_BATCH {{\"healthy_completed\":7,\"foreign_rejected\":1,\"caller_retries\":0,\"pending\":0,\"followup_completed\":1}}");
}

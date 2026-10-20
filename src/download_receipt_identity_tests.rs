//! Generated payloads only. Hold a synthetic HDD write turn after verification
//! to exercise identity and ownership checks across asynchronous receipt saves.
use super::*;
use std::time::Duration;

fn isolated(child: &str) {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", child, "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(output.status.success(), "{}{}", String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr));
}

async fn until(mut ready: impl FnMut() -> bool, message: &str) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while !ready() { tokio::time::sleep(Duration::from_millis(2)).await; }
    }).await.expect(message);
}

fn source() -> Source {
    Source {
        scope: "account:generated-receipt-race".into(),
        file_id: "generated-original".into(),
        revision: Some("gcid:GENERATED".into()),
        size: 8,
    }
}

fn edit_with_original_mtime(path: &Path) {
    let before = std::fs::metadata(path).unwrap();
    std::fs::write(path, b"BAD-DATA").unwrap();
    std::fs::File::options().write(true).open(path).unwrap()
        .set_modified(before.modified().unwrap()).unwrap();
    let after = std::fs::metadata(path).unwrap();
    let old = Identity::read(&before).unwrap();
    let new = Identity::read(&after).unwrap();
    assert_eq!((old.device, old.inode, old.size, old.modified),
        (new.device, new.inode, new.size, new.modified));
    assert_ne!(old.changed, new.changed, "The generated edit must move ctime");
}

#[test]
fn a_legacy_checksum_rejects_staging_edits_while_its_pending_receipt_waits() {
    isolated("download_receipt::identity_tests::pending_staging_identity_child");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated checkpoint counters and synthetic HDD publication gate"]
async fn pending_staging_identity_child() {
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("generated.bin.part");
    let output = directory.path().join("generated.bin");
    std::fs::write(&partial, b"abcdefgh").unwrap();
    let id = "generated-pending-staging-identity";
    let drive = crate::download_verification::TestDrive::new(id);
    let holder_id = "generated-pending-staging-holder";
    let _holder_drive = drive.sibling(holder_id);
    let holder = tokio::fs::File::create(directory.path().join("generated-holder")).await.unwrap();
    let gate = crate::download_verification::WriteGate::new(&holder, holder_id);
    let hook = super::batch_tests::ReceiptHook::new(id, false);
    let queued_partial = partial.clone();
    let queued_output = output.clone();
    let job = tokio::spawn(async move {
        // The legacy path must bind its fresh checksum to the retained inode
        // even though there is no transport VerifiedCompletion.
        finish_with_verification(&queued_partial, &queued_output, source(), id,
            FinishOptions::default(), None).await
    });
    until(|| hook.ready() == 1, "The legacy checksum must finish before its receipt is parked").await;
    let held = gate.turn(false).await.unwrap();
    let before = crate::download_checkpoint::snapshot().4;
    hook.release(1);
    until(|| crate::download_checkpoint::snapshot().4 > before,
        "The pending receipt must await the held HDD writer").await;
    assert!(!job.is_finished());
    edit_with_original_mtime(&partial);
    drop(held);
    let result = tokio::time::timeout(Duration::from_secs(10), job).await.unwrap().unwrap();
    assert!(result.is_err(), "A changed staging payload must not be published");
    assert!(!output.exists());
    assert_eq!(std::fs::read(&partial).unwrap(), b"BAD-DATA");
    assert!(!path(&output, &source()).unwrap().exists(),
        "A failed precommit identity check must not publish the pending receipt");
}

#[test]
fn committed_receipt_waits_reject_changed_or_replaced_published_payloads() {
    isolated("download_receipt::identity_tests::committed_payload_identity_child");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated checkpoint counters and synthetic HDD publication gate"]
async fn committed_payload_identity_child() {
    for replacement in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("generated.bin.part");
        let output = directory.path().join("generated.bin");
        std::fs::write(&partial, b"abcdefgh").unwrap();
        let id = format!("generated-committed-identity-{replacement}");
        let drive = crate::download_verification::TestDrive::new(&id);
        let holder_id = format!("generated-committed-holder-{replacement}");
        let _holder_drive = drive.sibling(&holder_id);
        let holder = tokio::fs::File::create(directory.path().join("generated-holder")).await.unwrap();
        let gate = crate::download_verification::WriteGate::new(&holder, &holder_id);
        let hook = super::batch_tests::ReceiptHook::new(&id, true);
        let queued_partial = partial.clone();
        let queued_output = output.clone();
        let job = tokio::spawn(async move {
            finish_with_verification(&queued_partial, &queued_output, source(), &id,
                FinishOptions::default(), None).await
        });
        until(|| hook.ready() == 1, "Publication must reach its committed receipt save").await;
        assert!(!partial.exists());
        assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
        let receipt_path = path(&output, &source()).unwrap();
        let pending_bytes = std::fs::read(&receipt_path).unwrap();
        assert!(!load(&receipt_path).unwrap().unwrap().committed);
        let held = gate.turn(false).await.unwrap();
        let before = crate::download_checkpoint::snapshot().4;
        hook.release(1);
        until(|| crate::download_checkpoint::snapshot().4 > before,
            "The committed receipt must await the held HDD writer").await;
        assert!(!job.is_finished());
        if replacement {
            let old = std::fs::metadata(&output).unwrap();
            let replacement_path = directory.path().join("generated-replacement");
            std::fs::write(&replacement_path, b"BAD-DATA").unwrap();
            std::fs::File::options().write(true).open(&replacement_path).unwrap()
                .set_modified(old.modified().unwrap()).unwrap();
            std::fs::rename(&replacement_path, &output).unwrap();
            assert_ne!(Identity::read(&old).unwrap().inode,
                Identity::read(&std::fs::metadata(&output).unwrap()).unwrap().inode);
        } else {
            edit_with_original_mtime(&output);
        }
        drop(held);
        let result = tokio::time::timeout(Duration::from_secs(10), job).await.unwrap().unwrap();
        assert!(result.is_err(), "A changed or replaced published payload must not report success");
        assert_eq!(std::fs::read(&output).unwrap(), b"BAD-DATA",
            "The externally changed destination must be preserved");
        assert_eq!(std::fs::read(&receipt_path).unwrap(), pending_bytes,
            "The committed receipt must not vouch for the changed payload");
        until(|| crate::download_checkpoint::snapshot().4 == 0,
            "The rejected checkpoint must release its queue reservation").await;
    }
}

#[test]
fn a_queued_pending_receipt_preserves_a_later_foreign_source_receipt() {
    isolated("download_receipt::identity_tests::queued_receipt_ownership_child");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated checkpoint counters and synthetic HDD publication gate"]
async fn queued_receipt_ownership_child() {
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("generated.bin.part");
    let output = directory.path().join("generated.bin");
    std::fs::write(&partial, b"abcdefgh").unwrap();
    let id = "generated-pending-source-ownership";
    let drive = crate::download_verification::TestDrive::new(id);
    let holder_id = "generated-pending-source-holder";
    let _holder_drive = drive.sibling(holder_id);
    let holder = tokio::fs::File::create(directory.path().join("generated-holder")).await.unwrap();
    let gate = crate::download_verification::WriteGate::new(&holder, holder_id);
    let hook = super::batch_tests::ReceiptHook::new(id, false);
    let queued_partial = partial.clone();
    let queued_output = output.clone();
    let job = tokio::spawn(async move {
        finish_with_verification(&queued_partial, &queued_output, source(), id,
            FinishOptions::default(), None).await
    });
    until(|| hook.ready() == 1, "The source-owned receipt must finish preparation").await;
    let held = gate.turn(false).await.unwrap();
    let before = crate::download_checkpoint::snapshot().4;
    hook.release(1);
    until(|| crate::download_checkpoint::snapshot().4 > before,
        "The source-owned receipt must await the held HDD writer").await;
    let receipt_path = path(&output, &source()).unwrap();
    let mut foreign_source = source();
    foreign_source.file_id = "generated-foreign-source".into();
    let foreign = Receipt {
        version: 1, source: foreign_source,
        local: Identity::read(&std::fs::metadata(&partial).unwrap()).unwrap(),
        sha256: hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh")),
        committed: false, copy: None, recovery: None,
    };
    save(&receipt_path, &foreign).unwrap();
    let foreign_bytes = std::fs::read(&receipt_path).unwrap();
    assert!(!job.is_finished());
    drop(held);
    let result = tokio::time::timeout(Duration::from_secs(10), job).await.unwrap().unwrap();
    assert!(result.is_err(), "A queued receipt must recheck source ownership when admitted");
    assert_eq!(std::fs::read(&receipt_path).unwrap(), foreign_bytes,
        "Receipt ownership changing during the wait must preserve the foreign receipt");
    assert!(!output.exists());
    assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
}

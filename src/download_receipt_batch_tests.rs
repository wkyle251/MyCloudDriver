//! Generated payloads only. Hooks pause real finalization between the checksum
//! and each receipt commit; production builds have no hook state or waits.
use super::*;
use std::{
    collections::HashMap,
    sync::{atomic::{AtomicUsize, Ordering}, Arc, Mutex, OnceLock, Weak},
    time::Duration,
};

struct HookState {
    ready: AtomicUsize,
    release: Arc<tokio::sync::Semaphore>,
}
type HookKey = (String, bool);
fn hooks() -> &'static Mutex<HashMap<HookKey, Weak<HookState>>> {
    static HOOKS: OnceLock<Mutex<HashMap<HookKey, Weak<HookState>>>> = OnceLock::new();
    HOOKS.get_or_init(Default::default)
}
pub(super) struct ReceiptHook {
    key: HookKey,
    state: Arc<HookState>,
}
impl ReceiptHook {
    pub(super) fn new(id: &str, committed: bool) -> Self {
        let key = (id.to_owned(), committed);
        let state = Arc::new(HookState {
            ready: AtomicUsize::new(0),
            release: Arc::new(tokio::sync::Semaphore::new(0)),
        });
        assert!(hooks().lock().unwrap().insert(key.clone(), Arc::downgrade(&state)).is_none());
        Self { key, state }
    }
    pub(super) fn ready(&self) -> usize { self.state.ready.load(Ordering::Relaxed) }
    pub(super) fn release(&self, count: usize) { self.state.release.add_permits(count); }
}
impl Drop for ReceiptHook {
    fn drop(&mut self) { hooks().lock().unwrap().remove(&self.key); }
}
pub(super) async fn before_receipt(id: &str, committed: bool) {
    let hook = hooks().lock().unwrap().get(&(id.to_owned(), committed)).and_then(Weak::upgrade);
    if let Some(hook) = hook {
        hook.ready.fetch_add(1, Ordering::Relaxed);
        hook.release.clone().acquire_owned().await.unwrap().forget();
    }
}
pub(super) async fn wait_for(mut ready: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while !ready() { tokio::time::sleep(Duration::from_millis(5)).await; }
    }).await.expect("Generated receipt stage did not advance");
}

fn fixture_source() -> Source {
    let file = serde_json::from_value(serde_json::json!({
        "id": "original", "name": "generated.bin", "kind": "drive#file",
        "size": "8", "hash": "fixture",
    })).unwrap();
    Source::new("account:generated-receipt-batch".into(), &file, 8)
}

#[test]
fn publication_receipts_batch_without_rereads_and_finish_after_post_move_controls() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "download_receipt::batch_tests::receipt_group_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
    println!("{}", String::from_utf8_lossy(&result.stdout));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated group counters, controls, and generated files on one synthetic HDD"]
async fn receipt_group_child() {
    use crate::download_transport::completion_tests::{completed_fixture, ReadCounter};
    use crate::download_verification::{Scope, TestDrive, WriteGate};
    const FILES: usize = 8;
    let directory = tempfile::tempdir().unwrap();
    let controls = directory.path().join("generated-controls.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &controls);
    std::fs::write(&controls, br#"{"actions":{},"drain":false}"#).unwrap();
    let holder_id = "generated-receipt-holder";
    let drive = TestDrive::new(holder_id);
    let holder = tokio::fs::File::create(directory.path().join("generated-holder")).await.unwrap();
    let gate = WriteGate::new(&holder, holder_id);
    let mut fixtures = Vec::new();
    for index in 0..FILES {
        let id = format!("generated-receipt-group-{index}");
        let sibling = drive.sibling(&id);
        let folder = directory.path().join(format!("generated-group-{index}"));
        std::fs::create_dir(&folder).unwrap();
        let scope = Scope::new(id.clone(), None);
        let reads = ReadCounter::new(&id);
        let proof = scope.run(completed_fixture(&folder, &id)).await;
        let pending_hook = ReceiptHook::new(&id, false);
        let committed_hook = ReceiptHook::new(&id, true);
        fixtures.push((id, sibling, folder, scope, reads, proof, pending_hook, committed_hook));
    }
    let before = crate::download_checkpoint::snapshot();
    let held = gate.turn(false).await;
    let mut jobs = Vec::new();
    let mut pending_hooks = Vec::new();
    let mut committed_hooks = Vec::new();
    let mut folders = Vec::new();
    for (id, sibling, folder, scope, reads, proof, pending_hook, committed_hook) in fixtures {
        folders.push(folder.clone());
        pending_hooks.push(pending_hook);
        committed_hooks.push(committed_hook);
        jobs.push(tokio::spawn(async move {
            let _drive = sibling;
            scope.run(finish_resolved_verified(
                &folder.join("generated.bin.part"), &folder.join("generated.bin"),
                fixture_source(), &id, Some(proof),
            )).await.unwrap();
            assert_eq!(reads.bytes(), 8, "Receipt batching must not add another full checksum");
            let receipt = load(&path(&folder.join("generated.bin"), &fixture_source()).unwrap()).unwrap().unwrap();
            assert!(receipt.committed);
            assert_eq!(std::fs::read(folder.join("generated.bin")).unwrap(), b"abcdefgh");
        }));
    }
    wait_for(|| pending_hooks.iter().all(|hook| hook.ready() == 1)).await;
    for hook in &pending_hooks { hook.release(1); }
    wait_for(|| crate::download_checkpoint::snapshot().4 == FILES).await;
    for folder in &folders {
        assert!(!folder.join("generated.bin").exists(), "No file can publish before its pending receipt is durable");
    }
    drop(held);
    wait_for(|| committed_hooks.iter().all(|hook| hook.ready() == 1)).await;
    let held = gate.turn(false).await;
    for folder in &folders {
        assert!(folder.join("generated.bin").exists());
        assert!(!load(&path(&folder.join("generated.bin"), &fixture_source()).unwrap()).unwrap().unwrap().committed);
    }
    for hook in &committed_hooks { hook.release(1); }
    wait_for(|| crate::download_checkpoint::snapshot().4 == FILES).await;
    assert!(jobs.iter().all(|job| !job.is_finished()), "Completion must await the committed receipt barrier");
    drop(held);
    tokio::time::timeout(Duration::from_secs(2), async {
        for job in jobs { job.await.unwrap(); }
    }).await.expect("Eight read reservations must not stall receipt commits");
    let after = crate::download_checkpoint::snapshot();
    assert_eq!((after.0 - before.0, after.1 - before.1, after.2 - before.2), (2, 16, 4));
    println!("GENERATED_RECEIPT_GROUP {{\"files\":8,\"receipt_commits\":16,\"batches\":2,\"full_cache_barriers\":4,\"previous_full_cache_barriers\":32,\"verified_bytes\":64}}");

    // An isolated finalizer must not wait for a cohort or a network arrival.
    let id = "generated-receipt-lone";
    let _lone_drive = drive.sibling(id);
    let folder = directory.path().join("generated-lone");
    std::fs::create_dir(&folder).unwrap();
    let proof = completed_fixture(&folder, id).await;
    let start = std::time::Instant::now();
    tokio::time::timeout(Duration::from_secs(1), finish_resolved_verified(
        &folder.join("generated.bin.part"), &folder.join("generated.bin"),
        fixture_source(), id, Some(proof),
    )).await.expect("A lone publication must not wait for a read-turn deadline").unwrap();
    println!("GENERATED_RECEIPT_LONE {{\"elapsed_ms\":{}}}", start.elapsed().as_millis());

    // Once the move has happened, recording completion must finish even if
    // Pause/Cancel arrives while the committed receipt is queued. Before the
    // move, Cancel still preserves the original staging file for its caller.
    for (committed, action) in [(true, "pause"), (true, "cancel"), (false, "cancel")] {
        let id = format!("generated-receipt-control-{committed}-{action}");
        let sibling = drive.sibling(&id);
        let folder = directory.path().join(format!("generated-control-{committed}-{action}"));
        std::fs::create_dir(&folder).unwrap();
        let proof = completed_fixture(&folder, &id).await;
        let hook = ReceiptHook::new(&id, committed);
        let run_folder = folder.clone();
        let run_id = id.clone();
        let job = tokio::spawn(async move {
            let _drive = sibling;
            finish_resolved_verified(
                &run_folder.join("generated.bin.part"), &run_folder.join("generated.bin"),
                fixture_source(), &run_id, Some(proof),
            ).await
        });
        wait_for(|| hook.ready() == 1).await;
        let held = gate.turn(false).await;
        hook.release(1);
        wait_for(|| crate::download_checkpoint::snapshot().4 > 0).await;
        let mut actions = serde_json::Map::new();
        actions.insert(id.clone(), serde_json::json!(action));
        std::fs::write(&controls, serde_json::to_vec(&serde_json::json!({
            "actions": actions, "drain": false,
        })).unwrap()).unwrap();
        let expected = if action == "pause" { crate::transfer_control::Action::Pause } else { crate::transfer_control::Action::Cancel };
        wait_for(|| crate::transfer_control::disk_action(&id) == Some(expected)).await;
        drop(held);
        let result = tokio::time::timeout(Duration::from_secs(2), job).await.unwrap().unwrap();
        if committed {
            result.unwrap();
            assert!(load(&path(&folder.join("generated.bin"), &fixture_source()).unwrap()).unwrap().unwrap().committed);
        } else {
            assert!(result.unwrap_err().is::<crate::transfer_control::Cancelled>());
            assert!(!folder.join("generated.bin").exists());
            assert_eq!(std::fs::read(folder.join("generated.bin.part")).unwrap(), b"abcdefgh");
        }
        std::fs::write(&controls, br#"{"actions":{},"drain":false}"#).unwrap();
        wait_for(|| crate::transfer_control::disk_action(&id).is_none()).await;
    }
}

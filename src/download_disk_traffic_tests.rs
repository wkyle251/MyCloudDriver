use super::*;

#[tokio::test]
async fn a_notified_writer_forwards_the_wakeup_when_checkpoint_priority_changes() {
    use futures_util::task::{waker, ArcWake};
    use std::{future::Future, sync::atomic::AtomicUsize, task::Context};
    struct WakeCount(AtomicUsize);
    impl ArcWake for WakeCount {
        fn wake_by_ref(this: &Arc<Self>) { this.0.fetch_add(1, Ordering::Relaxed); }
    }
    let gate = Arc::new(Traffic::new());
    let active = gate.clone().write(false, "generated-active-output").await;
    let payload_count = Arc::new(WakeCount(AtomicUsize::new(0)));
    let payload_wake = waker(payload_count.clone());
    let mut payload = Box::pin(gate.clone().write(false, "generated-payload"));
    assert!(payload.as_mut().poll(&mut Context::from_waker(&payload_wake)).is_pending());
    let checkpoint_count = Arc::new(WakeCount(AtomicUsize::new(0)));
    let checkpoint_wake = waker(checkpoint_count.clone());
    let mut checkpoint = Box::pin(gate.clone().checkpoint("generated-checkpoint"));
    assert!(checkpoint.as_mut().poll(&mut Context::from_waker(&checkpoint_wake)).is_pending());
    drop(active);
    assert_eq!(payload_count.0.load(Ordering::Relaxed), 1);
    // The checkpoint deadline can expire after the payload was notified but
    // before the runtime polls it. No disk operation remains to wake anyone.
    for queued in gate.state.lock().unwrap().checkpoints.values_mut() {
        *queued = Instant::now() - CHECKPOINT_MAX_WAIT;
    }
    assert!(payload.as_mut().poll(&mut Context::from_waker(&payload_wake)).is_pending());
    assert!(checkpoint_count.0.load(Ordering::Relaxed) > 0,
        "A displaced coordinator must wake its successor instead of parking every eligible writer");
    let std::task::Poll::Ready(checkpoint_step) = checkpoint.as_mut().poll(&mut Context::from_waker(&checkpoint_wake)) else {
        panic!("The newly prioritized checkpoint must enter the idle disk");
    };
    drop(checkpoint_step);
    assert!(payload.as_mut().poll(&mut Context::from_waker(&payload_wake)).is_ready());
}

#[tokio::test]
async fn waiting_writers_do_not_poll_behind_an_active_disk_operation() {
    use futures_util::task::{waker, ArcWake};
    use std::{future::Future, sync::atomic::AtomicUsize, task::Context};
    struct WakeCount(AtomicUsize);
    impl ArcWake for WakeCount {
        fn wake_by_ref(this: &Arc<Self>) { this.0.fetch_add(1, Ordering::Relaxed); }
    }
    let gate = Arc::new(Traffic::new());
    let active = gate.clone().write(false, "generated-active-output").await;
    let mut waiting = Vec::new();
    let mut wakes = Vec::new();
    for index in 0..1_248 {
        let count = Arc::new(WakeCount(AtomicUsize::new(0)));
        let wake = waker(count.clone());
        let queued_gate = gate.clone();
        let id = format!("generated-parked-output-{index}");
        let mut future = Box::pin(async move { queued_gate.write(false, &id).await });
        assert!(future.as_mut().poll(&mut Context::from_waker(&wake)).is_pending());
        waiting.push(future); wakes.push(count);
    }
    for wake in &wakes { wake.0.store(0, Ordering::Relaxed); }
    tokio::time::sleep(IDLE_HANDOFF * 3).await;
    let polls: usize = wakes.iter().map(|wake| wake.0.load(Ordering::Relaxed)).sum();
    println!("GENERATED_WRITER_WAKEUPS {{\"waiters\":1248,\"idle_timer_wakeups\":{polls}}}");
    assert_eq!(polls, 0, "An active I/O completion will wake its successor; parked writers must not all rescan the shared queue every 50 ms");
    drop(active);
    assert_eq!(wakes.iter().map(|wake| wake.0.load(Ordering::Relaxed)).sum::<usize>(), 1);
    drop(waiting.remove(0));
    assert_eq!(wakes[1].0.load(Ordering::Relaxed), 1, "Cancelling the notified head wakes its successor");
    drop(waiting);
    assert!(gate.state.lock().unwrap().write_queue.is_empty());
}

#[tokio::test]
async fn only_one_idle_coordinator_polls_with_a_large_ineligible_queue() {
    use futures_util::task::{waker, ArcWake};
    use std::{future::Future, sync::atomic::AtomicUsize, task::Context};
    struct WakeCount(AtomicUsize);
    impl ArcWake for WakeCount {
        fn wake_by_ref(this: &Arc<Self>) { this.0.fetch_add(1, Ordering::Relaxed); }
    }
    let gate = Arc::new(Traffic::new());
    let read = gate.register(1 << 30);
    let selected = gate.buffer(Arc::from("generated-selected-tail"), 1 << 20);
    {
        let mut state = gate.state.lock().unwrap();
        state.jobs.get_mut(&read.id).unwrap().ready = true; state.runnable_jobs = 1;
        state.select_writes(); state.start(Instant::now());
    }
    let mut payloads = Vec::new(); let mut waiting = Vec::new(); let mut wakes = Vec::new();
    for index in 0..1_248 {
        let id = format!("generated-next-cohort-{index}");
        payloads.push(gate.buffer(Arc::from(id.as_str()), 1));
        let queued_gate = gate.clone();
        let mut future = Box::pin(async move { queued_gate.write(false, &id).await });
        let count = Arc::new(WakeCount(AtomicUsize::new(0))); let wake = waker(count.clone());
        assert!(future.as_mut().poll(&mut Context::from_waker(&wake)).is_pending());
        waiting.push(future); wakes.push(count);
    }
    for wake in &wakes { wake.0.store(0, Ordering::Relaxed); }
    tokio::time::sleep(IDLE_HANDOFF * 3).await;
    assert_eq!(wakes.iter().map(|wake| wake.0.load(Ordering::Relaxed)).sum::<usize>(), 1,
        "Only the coordinator watches the clock when no queued writer belongs to the selected batch");
    drop(waiting); drop(payloads); drop(selected); drop(read);
    assert!(gate.state.lock().unwrap().write_queue.is_empty());
}

#[test]
fn shutdown_controls_wake_parked_writers_and_select_the_remaining_ram_tail() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "download_verification::traffic::tests::shutdown_control_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test]
#[ignore = "isolated generated control document and frozen RAM cohorts"]
async fn shutdown_control_child() {
    use futures_util::task::{waker, ArcWake};
    use std::{future::Future, sync::atomic::AtomicUsize, task::Context};
    struct WakeCount(AtomicUsize);
    impl ArcWake for WakeCount {
        fn wake_by_ref(this: &Arc<Self>) { this.0.fetch_add(1, Ordering::Relaxed); }
    }
    let directory = tempfile::tempdir().unwrap(); let control = directory.path().join("generated-controls.json");
    std::fs::write(&control, br#"{"actions":{},"receive_only_pause":true}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    let gate = Arc::new(Traffic::new());
    let selected = gate.buffer(Arc::from("generated-current-cohort"), 1 << 20);
    let active = gate.clone().write(false, "generated-current-cohort").await;
    let later = gate.buffer(Arc::from("generated-later-cohort"), 1 << 20);
    let mut waiting = Box::pin(gate.clone().write(false, "generated-later-cohort"));
    let count = Arc::new(WakeCount(AtomicUsize::new(0))); let wake = waker(count.clone());
    assert!(waiting.as_mut().poll(&mut Context::from_waker(&wake)).is_pending());
    count.0.store(0, Ordering::Relaxed);
    std::fs::write(&control, br#"{"actions":{},"receive_only_pause":true,"drain":true}"#).unwrap();
    tokio::time::sleep(Duration::from_millis(110)).await;
    assert!(crate::transfer_control::draining());
    assert!(count.0.load(Ordering::Relaxed) > 0, "A control change must wake parked writers even while earlier I/O is active");
    assert!(waiting.as_mut().poll(&mut Context::from_waker(&wake)).is_pending(), "Shutdown cannot overlap an active disk operation");
    drop(active);
    let step = tokio::time::timeout(Duration::from_secs(1), waiting).await.expect("Shutdown must admit the finite later RAM tail");
    assert_eq!(gate.state.lock().unwrap().selected_writes(), 2 << 20);
    drop(step); drop(later); drop(selected);
}

#[test]
fn the_pressure_threshold_stays_unchanged_without_a_local_waiting_writer() {
    let now = Instant::now(); let mut state = busy(now, 40 << 30);
    state.write_queue.clear();
    state.select(Phase::Read, now);
    for seconds in [10, 60, 900] {
        state.last_received = now + Duration::from_secs(seconds);
        state.tick(now + Duration::from_secs(seconds), 800, 1_000);
        assert_eq!(state.phase, Phase::Read, "Exactly 80% must not interrupt unfinished verification, even after ten seconds");
    }
    state.tick(now + Duration::from_secs(901), 801, 1_000);
    assert_eq!(state.phase, Phase::Write, "The first byte over 80% requests a safe write handover");
    assert_eq!(state.last_read_handover_reason, 5);
    assert_eq!(state.last_read_remaining_bytes, 40 << 30);
}

#[test]
fn a_small_continuous_write_tail_has_a_longer_but_finite_wait() {
    let now = Instant::now();
    let mut state = busy(now, 4 << 30); state.select(Phase::Read, now);
    let before = now + SMALL_WRITE_MAX_WAIT - Duration::from_millis(1);
    state.last_received = before; state.tick(before, 1 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "Small writes allow a longer sequential read run");
    let mut snapshot = Snapshot::default(); snapshot.include(&mut state, before);
    assert_eq!(snapshot.turn_target_ms, 30_000);
    state.last_received = now + SMALL_WRITE_MAX_WAIT;
    state.tick(now + SMALL_WRITE_MAX_WAIT, 1 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "Continuous slow receiving must not strand a sub-64 MiB tail indefinitely");
    assert_eq!(state.last_read_handover_reason, 7);
}

#[test]
fn continuous_receiving_cannot_strand_a_write_batch_below_the_ram_threshold() {
    let now = Instant::now();
    let mut state = busy(now, 600 << 30);
    state.select(Phase::Read, now);
    let before = now + READ_WRITE_MAX_WAIT - Duration::from_millis(1);
    state.last_received = before;
    state.tick(before, 512 << 20, 32 << 30);
    assert_eq!(state.phase, Phase::Read, "Useful reads retain their sequential ten-second batch");
    let mut snapshot = Snapshot::default(); snapshot.include(&mut state, before);
    assert_eq!(snapshot.turn_target_ms, 10_000);
    state.last_received = now + READ_WRITE_MAX_WAIT;
    state.tick(now + READ_WRITE_MAX_WAIT, 512 << 20, 32 << 30);
    assert_eq!(state.phase, Phase::Write, "A 512 MiB write batch must not wait for 25.6 GiB of RAM to fill");
    assert_eq!((state.last_read_handover_reason, state.read_turn_latency_handoffs), (7, 1));
    assert_eq!((state.remaining, state.last_read_remaining_bytes), (600 << 30, 600 << 30));
    assert!(!state.jobs[&0].selected, "Paused reads retain their remaining bytes for the next turn");
}

#[test]
fn bounded_read_turns_need_local_writable_work_and_preserve_prefetch_prerequisites() {
    let now = Instant::now();
    let mut state = busy(now, 4 << 30);
    state.select(Phase::Read, now);
    state.last_received = now + READ_WRITE_MAX_WAIT;
    state.tick(now + READ_WRITE_MAX_WAIT, READ_WRITE_BATCH_MIN_BYTES - 1, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "Tiny tails should not force a seek-heavy read/write alternation");
    state.tick(now + READ_WRITE_MAX_WAIT, 0, writable_limit(8 << 30, 7 << 30));
    assert_eq!(state.phase, Phase::Read, "Unverified receive-ahead RAM must keep its prerequisite reads running");
    state.write_queue.clear();
    state.tick(now + READ_WRITE_MAX_WAIT, 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "Another drive's buffered writes must not trigger this drive's latency handoff");
    state.write_queue.push_back(1); state.checkpoints.insert(1, now);
    state.tick(now + READ_WRITE_MAX_WAIT, 0, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "A waiting durable checkpoint gets a turn even without payload bytes");
    assert_eq!(state.last_read_handover_reason, 7);
}

#[tokio::test]
async fn write_latency_handover_finishes_active_io_and_resumes_the_same_read() {
    let gate = Arc::new(Traffic::new());
    let read = gate.register(8 << 20);
    let active = read.chunk(1 << 20, "generated-latency-read").await.unwrap();
    let payload = gate.buffer(Arc::from("generated-latency-write"), 128 << 20);
    let mut writer = Box::pin(gate.clone().write(false, "generated-latency-write"));
    assert!(futures_util::poll!(&mut writer).is_pending());
    {
        let mut state = gate.state.lock().unwrap();
        let now = Instant::now();
        state.since = Some(now - READ_WRITE_MAX_WAIT); state.last_received = now;
        state.tick(now, 128 << 20, 8 << 30);
        assert_eq!(state.phase, Phase::Write);
        assert_eq!(state.readers, 1);
        assert_eq!(state.writers, 0, "A deadline cannot overlap in-flight disk operations");
    }
    assert!(futures_util::poll!(&mut writer).is_pending());
    drop(active);
    let writing = tokio::time::timeout(Duration::from_secs(1), writer).await.unwrap();
    let mut continuation = Box::pin(read.chunk(7 << 20, "generated-latency-read"));
    assert!(futures_util::poll!(&mut continuation).is_pending());
    drop(payload); drop(writing);
    drop(tokio::time::timeout(Duration::from_secs(1), continuation).await.unwrap().unwrap());
    assert_eq!(gate.state.lock().unwrap().jobs[&read.id].remaining, 0,
        "The original read continues from its existing progress after the selected writes drain");
}

#[test]
fn read_threshold_uses_the_effective_limit_and_can_yield_before_ten_seconds() {
    let now = Instant::now(); let mut state = busy(now, 4 << 30);
    state.select(Phase::Read, now);
    state.tick(now + Duration::from_millis(1), 801, 1_000);
    assert_eq!(state.phase, Phase::Write, "There is no minimum read timer after the RAM threshold is exceeded");
    let mut reduced = busy(now, 4 << 30); reduced.select(Phase::Read, now);
    reduced.tick(now, 450, 1_000); assert_eq!(reduced.phase, Phase::Read);
    reduced.tick(now + Duration::from_millis(1), 450, 500);
    assert_eq!(reduced.phase, Phase::Write, "Memory pressure lowers the threshold with the effective RAM limit");
}

#[test]
fn idle_receiving_drains_a_small_ram_tail_without_losing_unfinished_reads() {
    let now = Instant::now(); let mut state = busy(now, 600 << 30);
    state.write_queue.extend(1..324);
    state.select(Phase::Read, now);
    state.tick(now + RECEIVE_IDLE_HANDOFF - Duration::from_millis(1), 2_362_390_400, 8 << 30);
    assert_eq!(state.phase, Phase::Read);
    state.tick(now + RECEIVE_IDLE_HANDOFF, 2_362_390_400, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "The observed 2.2 GiB tail cannot wait twenty minutes for an unreachable 80% threshold");
    assert_eq!((state.last_read_handover_reason, state.read_turn_idle_handoffs), (6, 1));
    assert_eq!((state.remaining, state.last_read_remaining_bytes), (600 << 30, 600 << 30));
    assert!(!state.jobs[&0].selected, "Unfinished checks return to pending, with their progress preserved");
}

#[test]
fn idle_handover_is_per_drive_and_allows_checkpoint_only_recovery() {
    let now = Instant::now(); let mut state = busy(now, 4 << 30);
    state.write_queue.clear(); state.select(Phase::Read, now);
    state.tick(now + Duration::from_secs(900), 0, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "No idle timeout without a writer waiting on this drive");
    state.write_queue.push_back(1); state.checkpoints.insert(1, now);
    state.tick(now + Duration::from_secs(901), 0, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "A recovery checkpoint can unblock new receiving even with no RAM payload");
    assert_eq!(state.last_read_handover_reason, 6);
    let gate = Arc::new(Traffic::new()); let _payload = gate.buffer(Arc::from("generated-other-disk"), 1);
    assert!(gate.state.lock().unwrap().last_received >= now);
    assert_eq!(state.last_received, now, "Another drive's arrivals cannot indefinitely postpone this writer");
}

#[tokio::test]
async fn prefix_replay_uses_the_exclusive_drain_lane_and_is_reported_as_reading() {
    let gate = Arc::new(Traffic::new());
    let read = gate.register(1024);
    let step = read.chunk(512, "generated-verifier").await.unwrap();
    let payload = gate.buffer(Arc::from("generated-replay"), 1024);
    let mut replay = Box::pin(gate.clone().write(false, "generated-replay"));
    assert!(futures_util::poll!(&mut replay).is_pending());
    {
        let mut state = gate.state.lock().unwrap();
        state.tick(Instant::now(), 9, 10);
        assert_eq!(state.phase, Phase::Write);
        assert_eq!(state.writers, 0, "The current physical read must finish before RAM drain enters");
    }
    assert!(futures_util::poll!(&mut replay).is_pending());
    drop(step);
    let replay = tokio::time::timeout(Duration::from_secs(1), replay).await.unwrap().reading(1024);
    let mut snapshot = Snapshot::default(); snapshot.include(&mut gate.state.lock().unwrap(), Instant::now());
    assert_eq!((snapshot.active_read_tasks, snapshot.active_read_bytes, snapshot.active_write_tasks), (1, 1024, 0));
    let mut writer = Box::pin(gate.clone().write(false, "generated-payload"));
    assert!(futures_util::poll!(&mut writer).is_pending(), "Prefix reads cannot race a payload write");
    drop(replay); drop(payload); drop(read);
    drop(tokio::time::timeout(Duration::from_secs(1), writer).await.unwrap());
    let state = gate.state.lock().unwrap();
    assert_eq!((state.writers, state.replay_readers, state.replay_read_bytes), (0, 0, 0));
}

#[test]
fn selected_writes_on_other_disks_are_excluded_from_pending_ram_and_release_on_drop() {
    let counter = Arc::new(AtomicU64::new(0));
    let gate = Arc::new(Traffic { state: Mutex::new(State::new(Instant::now())), changed: Notify::new() });
    gate.state.lock().unwrap().selected_write_counter = counter.clone();
    let first = gate.buffer(Arc::from("generated-first-disk-payload"), 400);
    gate.state.lock().unwrap().select_writes();
    assert_eq!(counter.load(Ordering::Relaxed), 400);
    let later = gate.buffer(Arc::from("generated-first-disk-payload"), 100);
    assert_eq!(counter.load(Ordering::Relaxed), 400, "New receiving stays pending, even on the selected output");
    let used = 1_200u64;
    let mut reader = busy(Instant::now(), 4 << 30); let now = Instant::now(); reader.select(Phase::Read, now);
    reader.tick(now, used.saturating_sub(counter.load(Ordering::Relaxed)) as usize, 1_000);
    assert_eq!(reader.phase, Phase::Read, "RAM already assigned to another disk's writer is not pending writes");
    drop(first); assert_eq!(counter.load(Ordering::Relaxed), 0);
    gate.state.lock().unwrap().select_writes(); assert_eq!(counter.load(Ordering::Relaxed), 100);
    drop(later); assert_eq!(counter.load(Ordering::Relaxed), 0);
    let tail = gate.buffer(Arc::from("generated-abandoned-disk-payload"), 123);
    gate.state.lock().unwrap().select_writes(); assert_eq!(counter.load(Ordering::Relaxed), 123);
    drop(tail);drop(gate); assert_eq!(counter.load(Ordering::Relaxed), 0, "Cancellation cannot leave a stale global writing charge");
    assert_eq!(write_threshold(usize::MAX), (usize::MAX as u128 * 80 / 100) as usize);
}

#[test]
fn buffered_payloads_precede_checkpoints_but_an_old_shared_commit_is_bounded() {
    let now = Instant::now(); let mut state = State::new(now);
    state.write_queue.extend([0, 1]);
    state.write_owners.insert(0, Arc::from("generated-checkpoint"));
    state.write_owners.insert(1, Arc::from("generated-payload"));
    state.checkpoints.insert(0, now);
    assert_eq!(state.next_write(now), Some(1), "Payload output must not queue behind fresh progress saves");
    assert_eq!(state.next_write(now + CHECKPOINT_MAX_WAIT), Some(0), "Group commits must still get a bounded chance to finish");
}

#[test]
fn a_full_ram_queue_requests_writes_without_a_minimum_read_delay() {
    let now = Instant::now(); let mut state = busy(now, 4 << 30);
    state.select(Phase::Read, now); state.tick(now, 8 << 30, 8 << 30);
    assert_eq!(state.phase, Phase::Write);
    assert_eq!(state.last_read_handover_reason, 5);
    assert_eq!(state.last_read_remaining_bytes, 4 << 30);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn queued_writers_make_progress_after_a_waiter_is_cancelled_without_overlapping_io() {
    use std::sync::atomic::AtomicUsize;
    let gate = Arc::new(Traffic::new());
    let held = gate.clone().write(false, "generated-held-writer").await;
    let cancelled_gate = gate.clone();
    let cancelled = tokio::spawn(async move { cancelled_gate.write(false, "generated-cancelled-waiter").await });
    tokio::task::yield_now().await;
    let active = Arc::new(AtomicUsize::new(0));
    let mut jobs = tokio::task::JoinSet::new();
    for index in 0..200 {
        let gate = gate.clone(); let active = active.clone();
        jobs.spawn(async move {
            for _ in 0..8 {
                let writer = gate.clone().write(false, &format!("generated-writer-{index}")).await;
                assert_eq!(active.fetch_add(1, Ordering::SeqCst), 0);
                tokio::task::yield_now().await;
                assert_eq!(active.fetch_sub(1, Ordering::SeqCst), 1);
                drop(writer);
            }
        });
    }
    tokio::time::timeout(Duration::from_secs(2), async {
        while gate.state.lock().unwrap().write_queue.len() < 201 { tokio::task::yield_now().await; }
    }).await.unwrap();
    cancelled.abort(); let _ = cancelled.await;
    drop(held);
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(result) = jobs.join_next().await { result.unwrap(); }
    }).await.expect("A cancelled head must not strand the other buffered writers");
    let state = gate.state.lock().unwrap();
    assert!(state.write_queue.is_empty() && state.write_wakes.is_empty() && state.writers == 0);
}

#[test]
fn write_turn_drains_its_frozen_batch_without_a_deadline_then_serves_reads() {
    let gate = Arc::new(Traffic::new());
    let read = gate.register(4 << 30);
    let a = gate.buffer(Arc::from("generated-writing-a"), 256 << 20);
    let b = gate.buffer(Arc::from("generated-writing-b"), 128 << 20);
    let now = Instant::now();
    {
        let mut state = gate.state.lock().unwrap();
        state.jobs.get_mut(&read.id).unwrap().ready = true; state.runnable_jobs = 1;
        state.select(Phase::Read, now); state.start(now);
        state.tick(now + Duration::from_secs(10), 384 << 20, 400 << 20);
        state.start(now + Duration::from_secs(10));
    }
    let snapshot = |at| { let mut result = Snapshot::default(); result.include(&mut gate.state.lock().unwrap(), at); result };
    let selected = snapshot(now + Duration::from_secs(10));
    assert_eq!((selected.writing_bytes, selected.writing_tasks, selected.active_write_tasks), (384 << 20, 2, 0),
        "The writing pool includes all selected RAM, including gaps between actual disk operations");
    let later_a = gate.buffer(Arc::from("generated-writing-a"), 32 << 20);
    let c = gate.buffer(Arc::from("generated-writing-c"), 64 << 20);
    assert_eq!(snapshot(now + Duration::from_secs(10)).writing_bytes, 384 << 20, "New receiving remains pending for the next write turn");
    drop(a);
    assert_eq!(snapshot(now + Duration::from_secs(10)).writing_bytes, 128 << 20, "Only selected consumed bytes leave the writing pool");
    {
        let mut state = gate.state.lock().unwrap();
        state.tick(now + Duration::from_secs(120), 224 << 20, 8 << 30);
        assert_eq!(state.phase, Phase::Write, "Neither a deadline nor an old read backlog may interrupt selected writes");
        assert_eq!(state.selected_writes(), 128 << 20, "New arrivals cannot extend the current batch");
    }
    assert_eq!(snapshot(now + Duration::from_secs(120)).turn_target_ms, 0, "Zero means the write turn has no deadline");
    drop(b);
    {
        let mut state = gate.state.lock().unwrap();
        state.tick(now + Duration::from_secs(121), 96 << 20, 8 << 30);
        assert_eq!(state.phase, Phase::Read, "Finishing the selected batch yields to reads even with new RAM waiting");
        assert_eq!(state.selected_writes(), 0);
        state.start(now + Duration::from_secs(121));
    }
    assert_eq!(snapshot(now + Duration::from_secs(121)).turn_target_ms, 0);
    gate.state.lock().unwrap().tick(now + Duration::from_secs(131), 96 << 20, 100 << 20);
    assert_eq!(snapshot(now + Duration::from_secs(131)).writing_bytes, 96 << 20, "The next write turn selects only new arrivals");
    drop((later_a, c));
    assert!(gate.state.lock().unwrap().write_pools.is_empty(), "No per-file RAM accounting remains after drain/cancel");
}

#[test]
fn sequential_write_runs_yield_fairly_inside_an_unlimited_batch() {
    let gate = Arc::new(Traffic::new());
    let read = gate.register(4 << 30);
    let _a = gate.buffer(Arc::from("generated-sequential-writer-a"), 16 << 20);
    let _b = gate.buffer(Arc::from("generated-sequential-writer-b"), 16 << 20);
    let now = Instant::now();
    let mut state = gate.state.lock().unwrap();
    state.jobs.get_mut(&read.id).unwrap().ready = true; state.runnable_jobs = 1;
    state.select_writes(); state.start(now); state.last_io = now;
    state.write_queue.extend([0, 1]);
    state.write_owners.insert(0, Arc::from("generated-sequential-writer-b"));
    state.write_owners.insert(1, Arc::from("generated-sequential-writer-a"));
    state.preferred_writer = Some(Arc::from("generated-sequential-writer-a")); state.preferred_bytes = 1 << 20;
    assert_eq!(state.next_write(now), Some(1), "An already buffered sequential output avoids a seek per small chunk");
    state.preferred_bytes = WRITE_LOCALITY_BYTES;
    assert_eq!(state.next_write(now), Some(0), "A bounded sequential run must yield to the FIFO head");
    state.preferred_writer = Some(Arc::from("generated-sequential-writer-a")); state.preferred_bytes = 1 << 20;
    state.write_queue.pop_back();
    assert_eq!(state.next_write(now), None);
    assert_eq!(state.next_write(now + WRITE_LOCALITY_GAP), Some(0), "A slow producer cannot hold other buffered writers");
    state.tick(now + Duration::from_secs(10), 32 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "The selected batch still has bytes to write after ten seconds");
    drop(state); drop(read);
}

fn busy(now: Instant, bytes: u64) -> State {
    let mut state = State::new(now);
    state.jobs.insert(0, Job { remaining: bytes, queued: now, started: false, ready: true, selected: false, active: 0, owner: None });
    state.order.push_back(0); state.remaining = bytes; state.runnable_jobs = 1;
    state.write_queue.push_back(0); state.start(now); state
}

#[test]
fn read_elapsed_starts_after_writes_drain_but_never_imposes_a_deadline() {
    let now = Instant::now(); let mut state = busy(now, 4 << 30);
    state.writers = 1; state.write_queue.clear();
    state.tick(now + Duration::from_secs(19), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "In-flight writes finish before read selection");
    state.writers = 0; state.tick(now + Duration::from_secs(20), 512 << 20, 8 << 30);
    assert_eq!(state.since, Some(now + Duration::from_secs(20)));
    state.tick(now + Duration::from_secs(900), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "Elapsed time cannot interrupt the selected cohort");
    state.tick(now + Duration::from_secs(901), 7 << 30, 8 << 30);
    assert_eq!(state.phase, Phase::Write); assert!(state.since.is_none());
}

#[test]
fn idle_sides_yield_but_registered_unready_checks_do_not_waste_disk_turns() {
    let now = Instant::now(); let mut state = busy(now, 4 << 30);
    state.runnable_jobs = 0;
    state.tick(now + Duration::from_secs(100), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "Metadata preparation is not runnable disk I/O");
    state.runnable_jobs = 1; state.write_queue.clear(); state.since = None;
    state.tick(now + Duration::from_secs(101), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "An idle writer must not hold the disk");
    state.start(now + Duration::from_secs(101));
    state.runnable_jobs = 0; state.jobs.get_mut(&0).unwrap().remaining = 0; state.remaining = 0; state.write_queue.push_back(1);
    state.tick(now + Duration::from_secs(102), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "An empty reader yields immediately");
}

#[test]
fn preparation_gaps_keep_selected_reads_when_no_local_writer_can_use_the_disk() {
    let now = Instant::now();let mut state = busy(now, 4 << 30);
    state.write_queue.clear();
    state.select(Phase::Read, now);state.last_io = now;
    state.runnable_jobs = 0;state.jobs.get_mut(&0).unwrap().ready = false;
    for gap in [IDLE_HANDOFF, Duration::from_secs(10), Duration::from_secs(120)] {
        state.last_received = now + gap;
        state.tick(now + gap, 512 << 20, 8 << 30);
        assert_eq!(state.phase, Phase::Read, "Preparation retains unfinished reads when no local writer can drain them");
    }
    state.tick(now + Duration::from_secs(121), 7 << 30, 8 << 30);
    assert_eq!(state.phase, Phase::Write); assert!(!state.jobs[&0].selected);
    assert_eq!(state.remaining, 4 << 30);
    assert_eq!((state.read_turn_timeouts, state.read_turn_write_handoffs, state.last_read_handover_reason,
        state.last_read_turn_ms, state.last_read_remaining_bytes), (0, 1, 5, 121_000, 4 << 30));
    assert_eq!((state.last_read_pending_write_bytes, state.last_read_buffer_limit_bytes), (7 << 30, 8 << 30));
}

#[tokio::test]
async fn completed_checkpoints_unblock_selected_deferred_reads_without_a_long_idle_turn() {
    let gate = Arc::new(Traffic::new());
    let completed = gate.register(1024);
    let deferred: Vec<_> = (0..16).map(|_| gate.register(8 << 20)).collect();
    drop(completed.chunk(1024, "generated-completed-check").await.unwrap());
    drop(completed);
    {
        let state = gate.state.lock().unwrap();
        assert_eq!(state.phase, Phase::Read);
        assert!(deferred.iter().all(|read| state.jobs[&read.id].selected));
        assert_eq!((state.readers, state.waiting_readers, state.runnable_jobs), (0, 0, 0));
    }
    let checkpoint = tokio::time::timeout(
        Duration::from_secs(1),
        gate.clone().checkpoint("generated-completed-check"),
    ).await.expect("Completed checks must release admission without waiting five seconds behind unready read tickets");
    {
        let state = gate.state.lock().unwrap();
        assert_eq!(state.phase, Phase::Write);
        assert_eq!(state.writers, 1);
        assert_eq!(state.remaining, 16 * (8 << 20));
        assert_eq!(state.last_read_handover_reason, 7);
    }
    let mut ready = Box::pin(deferred[0].chunk(8 << 20, "generated-next-check"));
    assert!(futures_util::poll!(&mut ready).is_pending(),
        "A newly admitted check cannot overlap the durable checkpoint");
    drop(checkpoint);
    drop(tokio::time::timeout(Duration::from_secs(1), ready).await.unwrap().unwrap());
    assert_eq!(gate.state.lock().unwrap().jobs[&deferred[0].id].remaining, 0,
        "The parked read must retain its work and resume after the checkpoint");
}

#[test]
fn checkpoint_idle_handoff_preserves_readers_hash_gaps_and_ordinary_preparation() {
    let now = Instant::now();
    for blocker in ["physical-read", "waiting-read", "hash-gap", "active-write", "short-gap", "payload-only"] {
        let mut state = busy(now, 4 << 30);
        state.select(Phase::Read, now);
        state.runnable_jobs = 0;
        state.jobs.get_mut(&0).unwrap().ready = false;
        if blocker != "payload-only" { state.checkpoints.insert(0, now); }
        let elapsed = if blocker == "short-gap" { IDLE_HANDOFF - Duration::from_millis(1) } else { IDLE_HANDOFF * 2 };
        match blocker {
            "physical-read" => state.readers = 1,
            "waiting-read" => state.waiting_readers = 1,
            "hash-gap" => {
                state.runnable_jobs = 1;
                state.jobs.get_mut(&0).unwrap().ready = true;
            }
            "active-write" => state.writers = 1,
            _ => {}
        }
        state.last_received = now + elapsed;
        state.tick(now + elapsed, 0, 8 << 30);
        assert_eq!(state.phase, Phase::Read,
            "A checkpoint idle handoff must preserve {blocker}");
    }
}

#[test]
fn an_emptied_cohort_selects_new_pending_reads_without_a_write_turn_below_threshold() {
    let now = Instant::now(); let mut state = busy(now, 1);
    state.write_queue.clear();
    state.select(Phase::Read, now); state.jobs.get_mut(&0).unwrap().remaining = 0;
    state.jobs.insert(1, Job { remaining: 1024, queued: now, started: false, ready: true,
        selected: false, active: 0, owner: None });
    state.remaining = 1024;
    state.last_received = now + Duration::from_secs(120);
    state.tick(now + Duration::from_secs(120), 800, 1_000);
    assert_eq!(state.phase, Phase::Read); assert!(state.jobs[&1].selected);
    assert_eq!(state.last_read_handover_sequence, 0, "No spurious write handover on a finished cohort with more checks waiting");
    state.jobs.get_mut(&1).unwrap().remaining = 0;state.remaining = 0;
    state.tick(now + Duration::from_secs(121), 1, 1_000);
    assert_eq!(state.phase, Phase::Write, "The final RAM tail must drain after all verification finishes");
    assert_eq!(state.last_read_handover_reason, 2);
}

#[test]
fn handover_diagnostics_choose_the_latest_disk_and_explain_threshold_or_control() {
    let now = Instant::now();
    let mut pressure = busy(now, 4 << 30);pressure.select(Phase::Read, now);
    pressure.tick(now + Duration::from_secs(1), 7 << 30, 8 << 30);
    assert_eq!((pressure.read_turn_write_handoffs, pressure.last_read_handover_reason, pressure.last_read_turn_ms), (1, 5, 1_000));
    let mut control = busy(now, 2 << 30);control.select(Phase::Read, now);
    control.force_write(now + Duration::from_millis(500));
    assert_eq!((control.read_turn_control_handoffs, control.last_read_handover_reason, control.last_read_turn_ms), (1, 4, 500));
    let mut summary = Snapshot::default();
    summary.include(&mut control, now + Duration::from_secs(1));
    summary.include(&mut pressure, now + Duration::from_secs(1));
    assert_eq!((summary.last_read_handover_reason, summary.last_read_turn_ms, summary.last_read_remaining_bytes), (4, 500, 2 << 30),
        "The latest handover is stable regardless of physical-drive iteration order");
}

#[tokio::test]
async fn a_writer_cannot_cut_short_an_unfinished_cohort_between_prepared_readers() {
    let gate = Arc::new(Traffic::new());
    let first = gate.register(1024);
    let preparing = gate.register(8 << 20);
    drop(first.chunk(1024, "generated-first-prepared-check").await.unwrap());drop(first);
    let writer_gate = gate.clone();
    let writer = tokio::spawn(async move { writer_gate.write(false, "generated-waiting-payload").await });
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(!writer.is_finished(), "An unfinished selected reader retains its turn during a preparation gap longer than 50 ms");
    drop(preparing.chunk(8 << 20, "generated-later-prepared-check").await.unwrap());drop(preparing);
    drop(tokio::time::timeout(Duration::from_secs(1), writer).await.unwrap().unwrap());
    let state = gate.state.lock().unwrap();
    assert_eq!(state.last_read_handover_reason, 2, "Finishing all verification drains even a small RAM tail");
    assert_eq!(state.last_read_remaining_bytes, 0);
}

#[test]
fn chunk_gaps_keep_read_progress_and_do_not_prematurely_end_write_turns() {
    let now = Instant::now(); let mut state = busy(now, 4 << 30);
    state.select(Phase::Read, now); state.start(now);
    state.tick(now + Duration::from_millis(1), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "A reader retains its turn between bounded chunks");
    state.select(Phase::Write, now); state.start(now); state.write_queue.clear();
    state.tick(now + Duration::from_millis(1), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "RAM has work; do not confuse a chunk gap with an empty writer");
    state.tick(now + IDLE_HANDOFF, 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "Unready writers must not leave the disk idle for a full turn");
}

#[test]
fn pending_write_threshold_yields_reads_but_backlog_age_cannot_interrupt_a_write_batch() {
    let now = Instant::now(); let mut state = busy(now, 4 << 30);
    state.select(Phase::Read, now); state.start(now);
    state.tick(now + Duration::from_secs(1), 7 << 30, 8 << 30);
    assert_eq!(state.phase, Phase::Write); state.start(now + Duration::from_secs(1));
    state.tick(now + Duration::from_secs(20), 5 << 30, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "High-water draining continues until receiver headroom is restored");
    state.tick(now + Duration::from_secs(21), 4 << 30, 8 << 30);
    assert_eq!(state.phase, Phase::Write, "Restoring RAM headroom cannot cut short outstanding writes");
    state.write_queue.clear(); state.tick(now + Duration::from_secs(22), 32 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "After writing finishes, the queued reader receives a turn");
    let mut tiny = busy(now, 1); tiny.since = Some(now + BACKLOG_AGE);
    tiny.tick(now + BACKLOG_AGE + Duration::from_secs(120), 32 << 20, 8 << 30);
    assert_eq!(tiny.phase, Phase::Write, "Read age does not interrupt outstanding writes");
    tiny.write_queue.clear(); tiny.tick(now + BACKLOG_AGE + Duration::from_secs(121), 32 << 20, 8 << 30);
    assert_eq!(tiny.phase, Phase::Read);
}

#[tokio::test]
async fn read_and_write_never_overlap_and_cancelled_fifo_waiters_release() {
    let traffic = Arc::new(Traffic::new()); let read = traffic.register(1024);
    let step = read.chunk(256, "generated-traffic-reader").await.unwrap();
    let waiting_traffic = traffic.clone();
    let waiting = tokio::spawn(async move { waiting_traffic.write(false, "generated-traffic-writer").await });
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(!waiting.is_finished()); waiting.abort(); let _ = waiting.await;
    assert!(traffic.state.lock().unwrap().write_queue.is_empty());
    let forced_traffic = traffic.clone();
    let forced = tokio::spawn(async move { forced_traffic.write(true, "generated-traffic-writer").await });
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(!forced.is_finished(), "A checkpoint must finish the in-flight read first");
    drop(step);
    let writing = tokio::time::timeout(Duration::from_secs(1), forced).await.unwrap().unwrap();
    assert!(read.try_chunk(256).is_none());
    let sibling_traffic = traffic.clone();
    let sibling = tokio::spawn(async move { sibling_traffic.write(false, "generated-sibling-writer").await });
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(!sibling.is_finished(), "An HDD has one bounded writer, including checkpoints");
    drop(writing);
    drop(tokio::time::timeout(Duration::from_secs(1), sibling).await.unwrap().unwrap());
    drop(read);
    let state = traffic.state.lock().unwrap();
    assert!(state.jobs.is_empty() && state.order.is_empty());
    assert_eq!(state.remaining, 0); assert_eq!(state.runnable_jobs, 0);
    assert_eq!(state.waiting_readers, 0); assert_eq!(state.writers, 0);
}

#[tokio::test]
async fn completed_io_wakes_fifo_writers_without_per_chunk_polling_delays() {
    let traffic = Arc::new(Traffic::new());
    let held = traffic.clone().write(false, "generated-held-writer").await;
    let mut tasks = Vec::new();
    let order = Arc::new(Mutex::new(Vec::new()));
    for number in 0..128 {
        let (waiting_traffic, output) = (traffic.clone(), order.clone());
        tasks.push(tokio::spawn(async move {
            let _step = waiting_traffic.write(false, "generated-fifo-writer").await;
            output.lock().unwrap().push(number);
        }));
        while traffic.state.lock().unwrap().write_queue.len() != number + 1 { tokio::task::yield_now().await; }
    }
    drop(held);
    tokio::time::timeout(Duration::from_secs(2), async { for task in tasks { task.await.unwrap(); } }).await.unwrap();
    assert_eq!(*order.lock().unwrap(), (0..128).collect::<Vec<_>>());
    assert!(traffic.state.lock().unwrap().write_queue.is_empty());
}

#[test]
fn cancelled_jobs_do_not_leave_an_unbounded_order_index() {
    let traffic = Arc::new(Traffic::new()); let oldest = traffic.register(1);
    for _ in 0..10_000 { drop(traffic.register(1024)); }
    assert!(traffic.state.lock().unwrap().order.len() <= 67);
    assert_eq!(traffic.state.lock().unwrap().remaining, 1);
    drop(oldest); assert!(traffic.state.lock().unwrap().order.is_empty());
}

#[tokio::test]
async fn prepared_readers_retain_the_read_turn_across_semaphore_handover() {
    let key = Key::Drive(0xee00_0000_0000_0250);
    let gate = for_key(key);
    let writing = gate.clone().write(false, "generated-read-handover-writer").await;
    let mut first = tokio::spawn(async move {
        super::super::acquire_key_read(key, "generated-read-handover-first", Some(1024)).await.unwrap()
    });
    while gate.state.lock().unwrap().jobs.is_empty() { tokio::task::yield_now().await; }
    let mut second = tokio::spawn(async move {
        super::super::acquire_key_read(key, "generated-read-handover-second", Some(1024)).await.unwrap()
    });
    while gate.state.lock().unwrap().jobs.len() < 2 { tokio::task::yield_now().await; }
    drop(writing);
    let (first, second) = tokio::time::timeout(Duration::from_secs(1), async {
        tokio::select! {
            guard = &mut first => (guard.unwrap(), second),
            guard = &mut second => (guard.unwrap(), first),
        }
    }).await.unwrap();
    let read = first.chunk(1024, "generated-read-handover-first").await.unwrap();
    drop(read);
    let phase = {
        let mut state = gate.state.lock().unwrap();
        state.write_queue.push_back(0);
        state.tick(Instant::now(), 512 << 20, 8 << 30);
        let phase = state.phase;
        state.write_queue.clear();
        phase
    };
    assert_eq!(phase, Phase::Read, "A reader waiting for the previous read's semaphore is ready I/O, not an empty pool");
    drop(first);
    let second = tokio::time::timeout(Duration::from_secs(1), second).await.unwrap().unwrap();
    drop(second.chunk(1024, "generated-read-handover-second").await.unwrap());
    drop(second);
    assert!(gate.state.lock().unwrap().jobs.is_empty());
}

#[test]
fn read_turn_freezes_the_waiting_pool_and_returns_unfinished_work_at_the_ram_threshold() {
    let now = Instant::now(); let mut state = busy(now, 40 << 30);
    state.write_queue.clear();
    state.tick(now + Duration::from_secs(10), 512 << 20, 8 << 30);
    assert!(state.jobs[&0].selected, "All existing pending work enters the reading pool");
    state.start(now + Duration::from_secs(10));
    state.jobs.insert(1, Job { remaining: 2 << 30, queued: now + Duration::from_secs(10), started: false, ready: true, selected: false, active: 0, owner: None });
    state.runnable_jobs += 1;
    state.tick(now + Duration::from_secs(10) + Duration::from_secs(9), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read);
    assert!(!state.jobs[&1].selected, "New arrivals wait outside the current reading pool");
    state.jobs.get_mut(&0).unwrap().ready = false;
    state.runnable_jobs = 1;
    state.tick(now + Duration::from_secs(10) + Duration::from_secs(9), 512 << 20, 8 << 30);
    assert_eq!(state.phase, Phase::Read, "Preparing selected work does not prematurely empty or reset the turn");
    state.tick(now + Duration::from_secs(120), 7 << 30, 8 << 30);
    assert_eq!(state.phase, Phase::Write);
    assert!(state.jobs.values().all(|job| !job.selected), "Unfinished read work returns to pending without losing its progress");
    let mut writing = Snapshot::default(); writing.include(&mut state, now + Duration::from_secs(10) + Duration::from_secs(10));
    assert_eq!(writing.turn_target_ms, 0, "Neither phase imposes a time deadline");
}

#[test]
fn reading_snapshot_shows_the_whole_selected_pool_between_disk_calls() {
    let now = Instant::now(); let mut state = busy(now, 40 << 30);
    state.jobs.insert(1, Job { remaining: 24 << 30, queued: now, started: false, ready: false, selected: false, active: 0, owner: None });
    state.remaining += 24 << 30;
    state.select(Phase::Read, now); state.start(now);
    let mut reading = Snapshot::default(); reading.include(&mut state, now);
    assert_eq!(reading.reading_bytes, 64 << 30);
    assert_eq!(reading.reading_tasks, 2);
    assert_eq!(reading.pending_read_bytes, 0);
    assert_eq!(reading.active_read_tasks, 0, "Pool membership survives the gap between actual I/O calls");
    state.jobs.insert(2, Job { remaining: 2 << 30, queued: now, started: false, ready: true, selected: false, active: 0, owner: None });
    state.remaining += 2 << 30;
    state.jobs.get_mut(&0).unwrap().remaining -= 1 << 30;
    state.remaining -= 1 << 30;
    let mut advanced = Snapshot::default(); advanced.include(&mut state, now);
    assert_eq!(advanced.reading_bytes, 63 << 30);
    assert_eq!(advanced.pending_read_bytes, 2 << 30, "Arrivals stay in the next pending pool");
    state.tick(now + Duration::from_secs(120), 7 << 30, 8 << 30);
    let mut writing = Snapshot::default(); writing.include(&mut state, now + Duration::from_secs(10));
    assert_eq!(writing.reading_bytes, 0);
    assert_eq!(writing.pending_read_bytes, 65 << 30, "Only the bytes actually read leave the combined pools");
}

#[test]
fn selected_checks_remain_waiting_until_their_actual_disk_io_starts() {
    let now = Instant::now();
    let mut state = busy(now, 40 << 30);
    state.jobs.insert(1, Job { remaining: 24 << 30, queued: now - Duration::from_secs(90),
        started: false, ready: false, selected: false, active: 0, owner: None });
    state.remaining += 24 << 30;
    state.select(Phase::Read, now); state.start(now);
    state.jobs.get_mut(&0).unwrap().active = 1;
    let mut reading = Snapshot::default(); reading.include(&mut state, now);
    assert_eq!(reading.reading_tasks, 2, "The legacy selected-cohort counter stays compatible");
    assert_eq!(reading.active_read_tasks, 1);
    assert_eq!(reading.active_read_bytes, 40 << 30);
    assert_eq!(reading.waiting_read_tasks, 1);
    assert_eq!(reading.waiting_read_bytes, 24 << 30);
    assert_eq!(reading.oldest_waiting_read_ms, 90_000, "Selection must not hide a deferred check's age");
    assert_eq!(reading.pending_read_tasks, 0);
    state.jobs.get_mut(&0).unwrap().active = 0;
    let mut between = Snapshot::default(); between.include(&mut state, now);
    assert_eq!(between.active_read_tasks, 0);
    assert_eq!(between.waiting_read_tasks, 2);
    assert_eq!(between.waiting_read_bytes, 64 << 30);
}

#[tokio::test]
async fn later_piece_checks_of_a_selected_file_stay_in_its_read_turn() {
    let gate = Arc::new(Traffic::new());
    let first = gate.register_for(1024, "generated-selected-original");
    drop(first.chunk(1024, "generated-selected-original").await.unwrap());
    drop(first);
    let phase = {
        let mut state = gate.state.lock().unwrap(); state.write_queue.push_back(0);
        state.tick(Instant::now(), 512 << 20, 8 << 30);
        let phase = state.phase; state.write_queue.clear(); phase
    };
    assert_eq!(phase, Phase::Read, "A short gap between a selected file's piece checks does not empty its pool");
    let continuation = gate.register_for(2048, "generated-selected-original");
    let arrival = gate.register_for(4096, "generated-next-original");
    let (selected, pending) = {
        let state = gate.state.lock().unwrap();
        (state.jobs[&continuation.id].selected, state.jobs[&arrival.id].selected)
    };
    assert!(selected, "A later piece/final check of the selected file must not wait for a new turn");
    assert!(!pending, "A new original still waits for the next reading pool");
    continuation.set_expected(1024);
    drop(continuation.chunk(1024, "generated-selected-original").await.unwrap());
    assert_eq!(gate.state.lock().unwrap().jobs[&continuation.id].remaining, 0);
    drop(continuation); drop(arrival);
}


#[test]
fn awaiting_checks_cannot_block_their_reads_but_writable_ram_drains_before_capacity() {
    let gate = Arc::new(Traffic::new());
    let read = gate.register(20 << 30);
    let payload = gate.buffer(Arc::from("generated-ready-prefetch"), 1 << 30);
    let now = Instant::now();
    let mut state = gate.state.lock().unwrap();
    state.jobs.get_mut(&read.id).unwrap().ready = true; state.runnable_jobs = 1;
    state.select(Phase::Read, now); state.start(now);
    state.tick(now, 0, writable_limit(8 << 30, 8 << 30));
    assert_eq!(state.phase, Phase::Read, "RAM awaiting checks needs its prerequisite read turn even at capacity");
    state.tick(now, 1 << 30, writable_limit(8 << 30, 7 << 30));
    assert_eq!(state.phase, Phase::Write, "A ready tail must drain while the rest of RAM is awaiting verification");
    assert_eq!(state.selected_writes(), 1 << 30);
    drop(state); drop(payload);
}

#[test]
fn activated_prefetch_releases_only_its_own_selected_payload() {
    let gate = Arc::new(Traffic::new());
    let mut prefetch = gate.buffer(Arc::from("generated-activated-prefetch"), 4 << 20);
    gate.state.lock().unwrap().select_writes();
    let later = gate.buffer(Arc::from("generated-activated-prefetch"), 2 << 20);
    prefetch.release(1 << 20);
    { let state = gate.state.lock().unwrap();
      assert_eq!(state.selected_writes(), 3 << 20);
      assert_eq!(state.write_pools.values().map(|p| p.queued).sum::<u64>(), 5 << 20); }
    prefetch.release(3 << 20);
    { let state = gate.state.lock().unwrap();
      assert_eq!(state.selected_writes(), 0);
      assert_eq!(state.write_pools.values().map(|p| p.queued).sum::<u64>(), 2 << 20); }
    drop(prefetch); drop(later);
    assert!(gate.state.lock().unwrap().write_pools.is_empty());
}

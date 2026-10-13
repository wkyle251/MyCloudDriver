use super::*;
use std::sync::atomic::AtomicU64;

#[path = "download_range_fixture.rs"]
mod fixture;

#[test]
fn receiving_diagnostics_separate_cancelled_ram_and_connection_waits() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (4 << 20).to_string())
        .args(["--exact", "download_buffer::tests::receiving_diagnostics_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test]
#[ignore = "isolated real RAM, connection and payload diagnostic counters"]
async fn receiving_diagnostics_child() {
    use pikpak::download_waits::{enable, receive_diagnostics, payload_event, payload_response, PayloadEvent};
    enable(true);
    let early = Prefetch::new(Some(Arc::from("generated-queued-check")), prefetch_slots().acquire().unwrap());
    early.failed(pikpak::download_policy::Interrupted.into());
    assert!(check_early_failure("generated-queued-check").is_err()); drop(early);
    let started = Prefetch::new(Some(Arc::from("generated-started-check")), prefetch_slots().acquire().unwrap());
    verification_started("generated-started-check"); started.failed(pikpak::download_policy::Interrupted.into());
    assert!(check_early_failure("generated-started-check").is_ok(), "An active prefix check must not be repeatedly restarted by HTTP failures");
    drop(started);
    let local = Arc::new(Semaphore::new(1)); let held = Lease::acquire(&local, 1).await;
    let waiter = tokio::spawn(async move { Lease::acquire(&local, 1).await });
    wait_for(|| receive_diagnostics()["ram_body_limit_active"] == 1).await;
    waiter.abort(); let _ = waiter.await;
    assert_eq!(receive_diagnostics()["ram_body_limit_active"], 0);
    assert_eq!(receive_diagnostics()["ram_body_limit_count"], 1); drop(held);
    let quanta = budget().current().0 / QUANTUM;
    let held = Lease::acquire(&Arc::new(Semaphore::new(quanta)), quanta).await;
    let waiter = tokio::spawn(async { Lease::acquire(&Arc::new(Semaphore::new(1)), 1).await });
    wait_for(|| receive_diagnostics()["ram_shared_limit_active"] == 1).await;
    waiter.abort(); let _ = waiter.await; drop(held);
    assert_eq!(receive_diagnostics()["ram_shared_limit_active"], 0);
    assert_eq!(receive_diagnostics()["ram_shared_limit_count"], 1);
    let network = pikpak::download_network::Network::new(1, None); let held = network.try_acquire().unwrap().unwrap();
    let queued = network.clone(); let waiter = tokio::spawn(async move { queued.acquire().await });
    wait_for(|| receive_diagnostics()["connection_budget_active"] == 1).await;
    waiter.abort(); let _ = waiter.await; drop(held);
    assert_eq!(receive_diagnostics()["connection_budget_active"], 0);
    network.defer(Duration::from_millis(250)).unwrap();
    let queued = network.clone(); let waiter = tokio::spawn(async move { queued.acquire().await });
    wait_for(|| receive_diagnostics()["connection_cooldown_active"] == 1).await;
    assert!(pikpak::download_network::known_cooldown_remaining_ms() > 0);
    drop(waiter.await.unwrap().unwrap());
    assert_eq!(receive_diagnostics()["connection_cooldown_active"], 0);
    for status in [200, 429, 503, 403, 416, 404] { payload_response(status); }
    payload_event(PayloadEvent::Timeout); payload_event(PayloadEvent::RangeValidation);
    let values = receive_diagnostics();
    for key in ["payload_http_success", "payload_http_429", "payload_http_5xx", "payload_http_auth", "payload_http_416",
        "payload_http_other", "payload_timeout", "payload_range_validation", "connection_cooldown_events"] {
        assert_eq!(values[key], 1, "Fixed diagnostic category {key}");
    }
    assert_eq!(USED.load(Ordering::Relaxed), 0);
}

#[test]
fn receive_ahead_admission_separates_http_capacity_from_retained_contexts() {
    let slots = PrefetchSlots::new();
    let mut held: Vec<_> = (0..PREFETCH_RECEIVERS).map(|_| slots.acquire().unwrap()).collect();
    assert!(slots.acquire().is_none(), "Active HTTP receivers remain bounded");
    assert_eq!(slots.contexts.available_permits(), PREFETCH_CONTEXTS - PREFETCH_RECEIVERS,
        "A failed receiving acquisition must refund its context");
    for permit in &mut held { permit.receiver.take(); }
    for _ in PREFETCH_RECEIVERS..PREFETCH_CONTEXTS {
        let mut permit = slots.acquire().unwrap();
        permit.receiver.take();
        held.push(permit);
    }
    assert_eq!(slots.receivers.available_permits(), PREFETCH_RECEIVERS);
    assert!(slots.acquire().is_none(), "Finished receivers cannot build an unbounded unverified backlog");
    drop(held);
    assert_eq!(slots.contexts.available_permits(), PREFETCH_CONTEXTS);
    assert_eq!(slots.receivers.available_permits(), PREFETCH_RECEIVERS);
}

#[test]
fn activating_and_cancelling_receive_ahead_refund_the_correct_admission() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (4 << 20).to_string())
        .args(["--exact", "download_buffer::tests::prefetch_lifecycle_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated RAM and receive-ahead lifecycle counters"]
async fn prefetch_lifecycle_child() {
    let remote = fixture::Fixture::new(16 << 20).await;
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    for activate in [false, true] {
        let permit = prefetch_slot(2 << 20, remote.size).unwrap();
        let mut body = Response::new_prefetch(http.get(&remote.url).send().await.unwrap(), |_| {}, permit);
        wait_for(|| snapshot().used >= 2 << 20).await;
        assert_eq!(snapshot().prefetch_active_slots, 1);
        assert_eq!(snapshot().prefetch_contexts, 1);
        let queued = snapshot().prefetch_bytes;
        assert!(queued >= 2 << 20 && queued <= 4 << 20);
        if activate {
            body.activate(); body.activate();
            assert_eq!(snapshot().prefetch_active_slots, 0);
            assert_eq!(snapshot().prefetch_contexts, 0);
            assert_eq!(snapshot().prefetch_bytes, 0);
            assert!(snapshot().used >= queued, "Activation must retain accepted RAM");
            let mut received = 0;
            while let Some(chunk) = body.chunk().await.map_err(DlError::into_inner).unwrap() {
                received += chunk.len();
            }
            assert_eq!(received as u64, remote.size);
        }
        drop(body);
        wait_for(|| snapshot().reserved == 0 && snapshot().used == 0 && snapshot().prefetch_tasks == 0
            && snapshot().prefetch_active_slots == 0 && snapshot().prefetch_contexts == 0).await;
    }
}

#[test]
fn sequential_channel_capacity_is_returned_before_queued_ram_is_consumed() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (64 << 20).to_string())
        .args(["--exact", "download_buffer::tests::sequential_channel_lifetime_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated RAM and real sequential HTTP channel lifetime"]
async fn sequential_channel_lifetime_child() {
    let remote = fixture::Fixture::new(2 << 20).await;
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    for speculative in [false, true] {
        let network = pikpak::download_network::Network::new(1, None);
        let channel = network.acquire().await.unwrap();
        assert!(network.try_acquire().unwrap().is_none());
        let early = speculative.then(|| prefetch_slot(2 << 20, remote.size).unwrap());
        let response = http.get(&remote.url).send().await.unwrap();
        let mut body = Response::new_in_network(response, |_| {}, (network.register(), channel), early);
        let mut replacement = None;
        wait_for(|| {
            replacement = network.try_acquire().unwrap();
            replacement.is_some()
        }).await;
        assert_eq!(snapshot().used, remote.size as usize, "The consumer has not drained any RAM yet");
        if speculative {
            assert_eq!(snapshot().prefetch_active_slots, 0);
            assert_eq!(snapshot().prefetch_contexts, 1, "Unverified RAM keeps its separate allowance");
            body.activate();
        }
        let mut offset = 0;
        while let Some(chunk) = body.chunk().await.map_err(DlError::into_inner).unwrap() {
            for (index, byte) in chunk.iter().enumerate() {
                assert_eq!(*byte, fixture::byte(offset + index as u64, 1));
            }
            offset += chunk.len() as u64;
        }
        assert_eq!(offset, remote.size);
        drop(body); drop(replacement);
        wait_for(|| snapshot().used == 0 && snapshot().prefetch_contexts == 0).await;
    }
}

#[test]
fn automatic_budget_has_no_fixed_reserve_and_respects_optional_maximum() {
    assert_eq!(Policy::new(Some(16 * GIB), None).limit, 16 * GIB);
    assert_eq!(Policy::new(Some(16 * GIB), Some(4 * GIB)).limit, 4 * GIB);
    assert_eq!(Policy::new(Some(8 * GIB), Some(16 * GIB)).limit, 8 * GIB);
    assert_eq!(Policy::new(Some(4 * GIB), None).limit, 4 * GIB);
    assert_eq!(Policy::new(None, None).limit, 64 << 20);
    assert_eq!(Policy::new(Some(16 * GIB), Some(4 << 20)).limit, 4 << 20);
}

#[test]
fn pressure_stops_growth_then_recovers_gradually_without_dropping_payloads() {
    let now = Instant::now(); let mut state = Pressure::new(now, 8 * GIB);
    for second in 0..24 {
        state.update(now + Duration::from_secs(second), 1, 8 * GIB, state.allowed);
    }
    assert_eq!(state.allowed, 4 * GIB);
    let now = now + Duration::from_secs(24);
    state.update(now, 2, 8 * GIB, 4 * GIB);
    assert_eq!(state.allowed, 2 * GIB);
    for (seconds, used) in [(1, 3 * GIB), (2, GIB), (3, 256 << 20)] {
        state.update(now + Duration::from_secs(seconds), 2, 8 * GIB, used);
        assert_eq!(state.allowed, 2 * GIB, "A warning must not keep halving the queue as it drains");
    }
    state.update(now + Duration::from_secs(4), 4, 8 * GIB, GIB);
    assert_eq!(state.allowed, 16 << 20);
    state.update(now + Duration::from_secs(5), 1, 8 * GIB, 0);
    assert_eq!(state.allowed, 16 << 20, "Normal pressure must settle before RAM refills");
    state.update(now + Duration::from_secs(34), 1, 8 * GIB, 0);
    assert_eq!(state.allowed, (16 + 128) << 20);
    for seconds in 35..100 { state.update(now + Duration::from_secs(seconds), 1, 8 * GIB, state.allowed); }
    assert_eq!(state.allowed, 3 * GIB, "Recovery respects the ceiling learned from pressure, rather than refilling to the same failure");
}

#[test]
fn automatic_budget_starts_small_and_grows_only_with_demand() {
    let now = Instant::now(); let mut state = Pressure::new(now, 8 * GIB);
    assert_eq!(state.allowed, GIB, "Startup does not open an allowance for all physical RAM");
    for seconds in 0..120 { state.update(now + Duration::from_secs(seconds), 1, 8 * GIB, 0); }
    assert_eq!(state.allowed, GIB, "An idle buffer does not grow");
    state.update(now + Duration::from_secs(120), 1, 8 * GIB, GIB / 2);
    assert_eq!(state.allowed, GIB + (128 << 20));
    for seconds in 121..240 { state.update(now + Duration::from_secs(seconds), 1, 8 * GIB, state.allowed); }
    assert_eq!(state.allowed, 8 * GIB);
    let small = Pressure::new(now, 4 << 20);
    assert_eq!(small.allowed, 4 << 20, "Small explicit limits still apply immediately");
}

#[test]
fn partial_flushes_do_not_pin_an_entire_network_batch() {
    let mut batch = bytes::BytesMut::with_capacity(RESPONSE_BATCH);
    batch.extend_from_slice(&vec![0x5a; 16 * 1024]);
    let bytes = finish_batch(batch);
    assert!(bytes.iter().all(|byte| *byte == 0x5a));
    let compact = bytes.try_into_mut().unwrap();
    assert!(compact.capacity() <= compact.len() + QUANTUM,
        "A small timed flush must release the unused receive allocation");

    let full = bytes::BytesMut::from(vec![0x5a; RESPONSE_BATCH].as_slice());
    let original = full.as_ptr();
    let bytes = finish_batch(full);
    assert_eq!(bytes.as_ptr(), original, "Full disk batches retain their zero-copy path");
}

#[test]
fn stalled_disk_receive_ahead_is_bounded_and_cancellation_releases_ram() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().to_ascii_lowercase().ends_with("proxy") { child.env_remove(key); }
    }
    let result = child.env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (4 << 20).to_string())
        .args(["--exact", "download_buffer::tests::stalled_disk_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

async fn wait_for(mut predicate: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while !predicate() { tokio::time::sleep(Duration::from_millis(10)).await; }
    }).await.expect("generated receive-ahead fixture timed out");
}

#[test]
fn concurrent_ram_reservations_with_headroom_never_sleep_for_contention() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (8 << 20).to_string())
        .args(["--exact", "download_buffer::tests::ram_contention_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated shared RAM counters with concurrent synthetic producers"]
async fn ram_contention_child() {
    let barrier = Arc::new(tokio::sync::Barrier::new(64));
    let mut jobs = tokio::task::JoinSet::new();
    for _ in 0..64 {
        let barrier = barrier.clone();
        jobs.spawn(async move {
            let local = Arc::new(Semaphore::new(1));
            barrier.wait().await;
            for _ in 0..256 {
                let mut lease = Lease::acquire(&local, 1).await;
                lease.fill(QUANTUM);
                // At most 256 KiB is held against the isolated 8 MiB cap.
                tokio::task::yield_now().await;
                drop(lease);
            }
        });
    }
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(result) = jobs.join_next().await { result.unwrap(); }
    }).await.expect("Contended receivers stalled despite available RAM");
    assert_eq!(snapshot().wait_count, 0, "Counter races must retry immediately, not suspend a healthy receiver");
    assert_eq!(snapshot().reserved, 0);
    assert_eq!(snapshot().used, 0);
}

#[tokio::test]
async fn an_eof_event_never_advances_disk_coverage_ahead_of_ram_data() {
    let (sender, receiver) = mpsc::channel(2);
    let task = tokio::spawn(std::future::pending());
    let mut ranges = Ranges { receiver, task, written: State::new(16 << 20, "\"generated\"".into(), 0), pending: None, receiving: None, prefetch: None };
    sender.send(RangeEvent::PieceEof(0)).await.unwrap_or_else(|_| panic!("generated event channel closed"));
    assert!(matches!(ranges.next().await, Err(RangeError::Sequential)));
    assert_eq!(ranges.state().received(), 0);
    assert!(!ranges.state().piece_complete(0));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated small RAM budget; invoked by its parent test"]
async fn stalled_disk_child() {
    let before = snapshot().wait_count;
    assert_eq!(measured_ram_wait(std::future::ready(7)).await, 7);
    assert_eq!(snapshot().wait_count, before, "An immediately available RAM lease is not a suspended receiver");
    let remote = fixture::Fixture::new(16 << 20).await;
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let received = Arc::new(AtomicU64::new(0));
    let counter = received.clone();
    let mut response = Response::new(http.get(&remote.url).send().await.unwrap(), move |bytes| { counter.fetch_add(bytes, Ordering::Relaxed); });
    wait_for(|| snapshot().used >= 2 << 20).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(received.load(Ordering::Relaxed) > 0, "HTTP must continue while the writer is stalled");
    assert!(snapshot().used <= 4 << 20 && USED.load(Ordering::Relaxed) * QUANTUM <= 4 << 20);
    assert!(snapshot().waiting_receivers > 0 && snapshot().wait_count > before,
        "Full-buffer backpressure must be distinguishable from waiting for network bytes");
    let mut offset = 0;
    while let Some(chunk) = response.chunk().await.map_err(DlError::into_inner).unwrap() {
        for (index, byte) in chunk.iter().enumerate() { assert_eq!(*byte, fixture::byte(offset + index as u64, 1)); }
        offset += chunk.len() as u64;
    }
    assert_eq!(offset, remote.size);
    assert_eq!(received.load(Ordering::Relaxed), remote.size);
    drop(response);
    wait_for(|| USED.load(Ordering::Relaxed) == 0 && snapshot().waiting_receivers == 0).await;

    let network = pikpak::download_network::Network::new(2, None);
    let initial = State::new(remote.size, "\"fixture-1\"".into(), 0);
    let transfer = Transfer::new(&http, &remote.url, None, initial, network).unwrap();
    let received = Arc::new(AtomicU64::new(0));
    let counter = received.clone();
    let mut ranges = Ranges::new(transfer, move |bytes| { counter.fetch_add(bytes, Ordering::Relaxed); });
    wait_for(|| snapshot().used >= 2 << 20).await;
    assert!(received.load(Ordering::Relaxed) > 0);
    assert_eq!(ranges.state().received(), 0, "RAM must never enter written coverage");
    assert!(!ranges.state().complete());
    let mut saved = 0;
    while let Some(chunk) = ranges.next().await.unwrap() {
        for (index, byte) in chunk.bytes.iter().enumerate() { assert_eq!(*byte, fixture::byte(chunk.offset + index as u64, 1)); }
        saved += chunk.bytes.len() as u64;
        ranges.accept(&chunk);
        assert_eq!(ranges.state().received(), saved);
    }
    assert_eq!(saved, remote.size);
    assert!(ranges.state().complete(), "EOF proof is adopted only after the disk consumer catches up");
    drop(ranges);
    wait_for(|| USED.load(Ordering::Relaxed) == 0).await;

    let transfer = Transfer::new(&http, &remote.url, None, State::new(remote.size, "\"fixture-1\"".into(), 0),
        pikpak::download_network::Network::new(2, None)).unwrap();
    let mut cancelled = Ranges::new(transfer, |_| {});
    wait_for(|| snapshot().used >= 2 << 20).await;
    let first = cancelled.next().await.unwrap().unwrap();
    cancelled.accept(&first);
    let written = first.bytes.len() as u64;
    cancelled.stop();
    assert_eq!(cancelled.state().received(), written, "Only accepted disk bytes may be checkpointed after cancellation");
    drop(cancelled);
    wait_for(|| USED.load(Ordering::Relaxed) == 0 && snapshot().used == 0 && snapshot().waiting_receivers == 0).await;

    let response = Response::new(http.get(&remote.url).send().await.unwrap(), |_| {});
    wait_for(|| snapshot().used >= 2 << 20).await;
    drop(response);
    wait_for(|| USED.load(Ordering::Relaxed) == 0 && snapshot().used == 0 && snapshot().waiting_receivers == 0).await;
}

#[test]
fn fragmented_ranges_receive_ahead_uses_available_ram() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().to_ascii_lowercase().ends_with("proxy") { child.env_remove(key); }
    }
    let result = child.env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (4 << 20).to_string())
        .args(["--exact", "download_buffer::tests::fragmented_ranges_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[test]
fn live_ram_payloads_follow_write_cohorts_without_blocking_new_receiving() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().to_ascii_lowercase().ends_with("proxy") { child.env_remove(key); }
    }
    let result = child.env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (32 << 20).to_string())
        .args(["--exact", "download_buffer::tests::write_cohort_receiving_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated real loopback bodies and RAM/write-cohort counters"]
async fn write_cohort_receiving_child() {
    use tokio::io::AsyncWriteExt;
    let remote = fixture::Fixture::new(4 << 20).await;
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let traffic = || serde_json::to_value(crate::download_verification::traffic_snapshot()).unwrap();
    for ranged in [false, true] {
        let id = format!("generated-live-write-cohort-{ranged}");
        let scope = crate::download_verification::Scope::new(id.clone(), None);
        let drive = crate::download_verification::TestDrive::new(&id);
        let reading = drive.hold_read(512 << 20).await;
        let read_step = reading.chunk(1, &id).await.unwrap();
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("generated-payload.bin");
        let mut file = tokio::fs::File::create(&output).await.unwrap();
        let writer = crate::download_verification::WriteGate::new(&file, &id);
        scope.run(async {
            let mut response = if ranged { None } else { Some(Response::new(http.get(&remote.url).send().await.unwrap(), |_| {})) };
            let mut ranges = if ranged {
                Some(Ranges::new(Transfer::new(&http, &remote.url, None, State::new(remote.size, "\"fixture-1\"".into(), 0),
                    pikpak::download_network::Network::new(2, None)).unwrap(), |_| {}))
            } else { None };
            wait_for(|| snapshot().used == remote.size as usize).await;
            assert_eq!(traffic()["writing_bytes"], 0, "RAM stays pending during the read operation");
            drop(read_step); drop(reading);
            let held = writer.turn(false).await;
            assert_eq!(traffic()["writing_bytes"], remote.size, "The write turn selects the entire real RAM queue");
            let mut new_arrival = Response::new(http.get(&remote.url).send().await.unwrap(), |_| {});
            wait_for(|| snapshot().used == 2 * remote.size as usize).await;
            let selected = traffic();
            assert_eq!(selected["writing_bytes"], remote.size);
            assert_eq!(selected["pending_write_bytes"], remote.size, "New HTTP bodies keep receiving while the writer is busy");
            drop(held);
            if let Some(response) = &mut response {
                while let Some(chunk) = response.chunk().await.map_err(crate::DlError::into_inner).unwrap() {
                    let _turn = writer.turn(false).await;
                    file.write_all(&chunk).await.unwrap();
                }
            }
            if let Some(ranges) = &mut ranges {
                while let Some(chunk) = ranges.next().await.unwrap() {
                    let _turn = writer.turn(false).await;
                    file.write_all(&chunk.bytes).await.unwrap(); ranges.accept(&chunk);
                }
                assert!(ranges.state().complete());
            }
            while let Some(chunk) = new_arrival.chunk().await.map_err(crate::DlError::into_inner).unwrap() {
                let _turn = writer.turn(false).await;
                file.write_all(&chunk).await.unwrap();
            }
            file.sync_data().await.unwrap();
        }).await;
        wait_for(|| snapshot().used == 0 && snapshot().reserved == 0).await;
        let expected = [fixture::bytes(0, remote.size as usize, 1), fixture::bytes(0, remote.size as usize, 1)].concat();
        assert_eq!(std::fs::read(&output).unwrap(), expected);
        assert_eq!(traffic()["writing_bytes"], 0);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated fragmented-body RAM budget; invoked by its parent test"]
async fn fragmented_ranges_child() {
    let remote = fixture::Fixture::new(4 << 20).await;
    remote.wire_chunk_bytes.store(4 * 1024, Ordering::Release);
    remote.chunk_delay_millis.store(1, Ordering::Release);
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let transfer = Transfer::new(&http, &remote.url, None, State::new(remote.size, "\"fixture-1\"".into(), 0),
        pikpak::download_network::Network::new(1, None)).unwrap();
    let received = Arc::new(AtomicU64::new(0));
    let counter = received.clone();
    let mut ranges = Ranges::new(transfer, move |bytes| { counter.fetch_add(bytes, Ordering::Relaxed); });
    let ahead = tokio::time::timeout(Duration::from_secs(5), async {
        while received.load(Ordering::Relaxed) < 2 << 20 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await;
    assert!(ahead.is_ok(), "Receive-ahead stopped before half its available RAM: received={} queued={} reserved={} configured={}",
        received.load(Ordering::Relaxed), snapshot().used, USED.load(Ordering::Relaxed) * QUANTUM, snapshot().configured);
    println!("FRAGMENTED_RECEIVE_AHEAD received={} queued={} reserved={} configured={}",
        received.load(Ordering::Relaxed), snapshot().used, snapshot().reserved, snapshot().configured);
    assert_eq!(ranges.state().received(), 0, "Receive-ahead cannot advance disk coverage");
    let mut saved = 0;
    while let Some(chunk) = ranges.next().await.unwrap() {
        for (index, byte) in chunk.bytes.iter().enumerate() { assert_eq!(*byte, fixture::byte(chunk.offset + index as u64, 1)); }
        saved += chunk.bytes.len() as u64;
        ranges.accept(&chunk);
    }
    assert_eq!(saved, remote.size);
    assert!(ranges.state().complete());
    drop(ranges);
    wait_for(|| USED.load(Ordering::Relaxed) == 0 && snapshot().used == 0).await;
}

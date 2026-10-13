use super::*;
use std::{
    sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    time::Duration,
};

#[path = "download_range_fixture.rs"]
mod fixture;

#[test]
fn unfinished_deferred_work_can_reenter_receiving_without_bypassing_disk_fifo() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (64 << 20).to_string())
        .args(["--exact", "download_verification::admission::tests::deferred_receive_rearm_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test]
#[ignore = "isolated bounded early-receiving admission"]
async fn deferred_receive_rearm_child() {
    let key = Key::Drive(0xed00_0000_0000_00d1);
    let pool = pool(key);
    let oldest = pool.enqueue(key, 8 << 30, 8 << 30);
    let held = pool.claim(&oldest).unwrap();
    let id = "generated-deferred-unfinished";
    let held_receivers: Vec<_> = (0..8).map(|_| crate::download_buffer::prefetch_slot(2 << 20, 2 << 20).unwrap()).collect();
    let scope = Scope::new(id.into(), None);
    let deferred = scope.run(async {
        assert!(crate::download_buffer::prefetch_slot(2 << 20, 2 << 20).is_none());
        admit(key, id, 2 << 20, 4 << 20).err().unwrap().downcast::<Deferred>().unwrap()
    }).await;
    drop(scope);
    assert!(!deferred.ready());
    drop(held_receivers);
    assert!(deferred.ready(), "Free receiving capacity must wake known unfinished work despite a large disk-only head");
    let scope = Scope::new(id.into(), Some(deferred.clone()));
    assert_eq!(pool.0.lock().unwrap().receiving_preparing.len(), 1);
    let competing: Vec<_> = (0..7).map(|_| crate::download_buffer::prefetch_slot(2 << 20, 2 << 20).unwrap()).collect();
    assert!(crate::download_buffer::prefetch_slot(2 << 20, 2 << 20).is_none(),
        "The dispatched verifier must reserve its receiving capacity before metadata starts");
    assert!(!deferred.ready(), "A dispatch cannot spin while its preparation is running");
    scope.run(async {
        let permit = crate::download_buffer::prefetch_slot(2 << 20, 2 << 20).unwrap();
        let receiving = Receiving::current().unwrap();
        assert!(admit(key, id, 2 << 20, 4 << 20).is_ok());
        assert_eq!(pool.0.lock().unwrap().active.len(), 1, "RAM prerequisites do not steal the existing disk byte lease");
        drop(receiving); drop(permit);
    }).await;
    drop(scope);
    drop(competing);
    assert!(pool.0.lock().unwrap().receiving_preparing.is_empty());
    drop(deferred);
    // Eligibility is evidence from the current preparation, not a permanent
    // property of a file. A changed route or journal may no longer prefetch.
    let scope = Scope::new(id.into(), None);
    let stale = scope.run(async {
        receive_ahead_candidate();
        admit(key, id, 2 << 20, 4 << 20).err().unwrap().downcast::<Deferred>().unwrap()
    }).await;
    drop(scope);
    assert!(stale.ready());
    let scope = Scope::new(id.into(), Some(stale));
    let waiting = scope.run(async {
        admit(key, id, 2 << 20, 4 << 20).err().unwrap().downcast::<Deferred>().unwrap()
    }).await;
    drop(scope);
    *waiting.0.receive_after.lock().unwrap() = Instant::now();
    assert!(!waiting.ready(), "A failed receiving rearm must not repeat metadata with stale eligibility");
    drop(waiting);
    let scope = Scope::new(id.into(), None);
    let probed = scope.run(async {
        let permit = crate::download_buffer::prefetch_slot(2 << 20, 2 << 20).unwrap();
        drop(permit); // The request could not produce safe speculative payload.
        admit(key, id, 2 << 20, 4 << 20).err().unwrap().downcast::<Deferred>().unwrap()
    }).await;
    drop(scope);
    assert!(!probed.ready(), "A completed probe must wait for disk admission instead of rearming forever");
    drop(held);
    assert!(probed.ready(), "Disk-only work must retain its FIFO ticket");
}

#[test]
fn admission_is_byte_bounded_fifo_and_dropped_waiters_do_not_block() {
    let pool = Arc::new(Pool::default());
    let key = Key::Drive(0xed00_0000_0000_0001);
    let first = pool.enqueue(key, 768 << 20, 768 << 20);
    let lease = pool.claim(&first).unwrap();
    let older = pool.enqueue(key, 512 << 20, 512 << 20);
    let small = pool.enqueue(key, 1, 1);
    assert!(!older.pool.ready(&older));
    assert!(
        !small.pool.ready(&small),
        "Small new jobs cannot bypass an older waiting original"
    );
    drop(lease);
    assert!(older.pool.ready(&older));
    drop(older);
    assert!(
        small.pool.ready(&small),
        "A cancelled/dead ticket must not block the queue"
    );
    drop(pool.claim(&small).unwrap());
    let oversized = pool.enqueue(key, 8 << 30, 8 << 30);
    let lease = pool
        .claim(&oversized)
        .expect("One oversized file must progress by itself");
    let next = pool.enqueue(key, 1, 1);
    assert!(!next.pool.ready(&next));
    drop(lease);
    assert!(next.pool.ready(&next));
}

#[tokio::test]
async fn a_multi_piece_phase_keeps_admission_then_streaming_releases_it() {
    let key = Key::Drive(0xed00_0000_0000_0002);
    let id = "generated-multiple-piece-phase";
    let scope = Scope::new(id.into(), None);
    scope
        .run(async {
            drop(admit(key, id, 128 << 20, 8 << 30).unwrap());
            let older = pool(key).enqueue(key, 64 << 20, 64 << 20);
            assert!(!older.pool.ready(&older));
            drop(admit(key, id, 256 << 20, 8 << 30).unwrap());
            let receiving = Receiving::current().unwrap();
            assert!(
                older.pool.ready(&older),
                "HTTP receiving must release verification admission"
            );
            let lease = older.pool.claim(&older).unwrap();
            let producer = receiving.producer();
            let sibling = receiving.producer();
            drop(producer);
            assert!(
                scope.attempt.state.lock().unwrap().parked.is_none(),
                "Another HTTP producer is still active"
            );
            drop(sibling);
            assert!(
                scope.attempt.state.lock().unwrap().parked.is_some(),
                "Finished HTTP leaves RAM draining outside network admission"
            );
            assert!(
                admit(key, id, 1, 1).is_ok(),
                "A live RAM consumer cannot be deferred"
            );
            drop(receiving);
            let error = admit(key, id, 8 << 30, 8 << 30)
                .err()
                .expect("Final read must defer");
            let deferred = error.downcast_ref::<Deferred>().unwrap().clone();
            assert!(
                !deferred.ready(),
                "Final read-back needs separate byte admission"
            );
            drop(lease);
            assert!(deferred.ready());
        })
        .await;
}

#[tokio::test]
async fn metadata_preparation_is_bounded_without_borrowing_disk_bytes() {
    let key = Key::Drive(0xed00_0000_0000_0005);
    let pool = pool(key);
    let first = pool.enqueue(key, 512 << 20, 512 << 20);
    let second = pool.enqueue(key, 512 << 20, 512 << 20);
    let third = pool.enqueue(key, 1, 1);
    let first_id = "generated-prefetched-first";
    let first_scope = Scope::new(first_id.into(), Some(Deferred(first)));
    assert!(
        pool.ready(&second),
        "One dispatched verifier preparing metadata must not block all following readers"
    );
    let second_id = "generated-prefetched-second";
    let second_scope = Scope::new(second_id.into(), Some(Deferred(second)));
    assert!(
        pool.ready(&third),
        "Metadata must not reserve disk bytes before it can read"
    );
    let extra: Vec<_> = (0..MAX_TASKS - 2)
        .map(|index| {
            let ticket = if index == 0 {
                third.clone()
            } else {
                pool.enqueue(key, 1, 1)
            };
            Scope::new(
                format!("generated-preparation-cap-{index}"),
                Some(Deferred(ticket)),
            )
        })
        .collect();
    let next = pool.enqueue(key, 1, 1);
    assert!(
        !pool.ready(&next),
        "Metadata preparation has its own bounded allowance"
    );
    assert!(pool.0.lock().unwrap().active.is_empty());
    first_scope
        .run(async {
            let read = admit(key, first_id, 512 << 20, 512 << 20).unwrap();
            assert!(
                read.is_some(),
                "The reservation must retain its original read ticket"
            );
            let _receiving = Receiving::current().unwrap();
            assert!(
                pool.ready(&next),
                "Receiving releases the prepared verification reservation"
            );
        })
        .await;
    drop(first_scope);
    drop(second_scope);
    drop(extra);
    assert!(
        pool.0.lock().unwrap().active.is_empty(),
        "Cancelled preparation releases every reservation"
    );
}

#[test]
fn prepared_metadata_reserves_the_remaining_verifier_slots() {
    let key = Key::Drive(0xed00_0000_0000_00d2);
    let pool = Arc::new(Pool::default());
    let active: Vec<_> = (0..MAX_TASKS - 1).map(|_| {
        let ticket = pool.enqueue(key, 1, 1);
        pool.claim(&ticket).unwrap()
    }).collect();
    let first = pool.enqueue(key, 1, 1);
    let next = pool.enqueue(key, 1, 1);
    let prepared = pool.prepare(&first).unwrap();
    assert!(!pool.ready(&next), "Seven active readers and one metadata preparation fill all eight verifier slots");
    assert!(pool.prepare(&next).is_none(), "An occupied verifier must not trigger another file-open/setup attempt");
    drop(prepared);
    assert!(pool.ready(&next), "Cancellation returns the unused preparation allowance");
    drop(active);
}

#[tokio::test]
async fn a_finished_producer_releases_receiving_admission_before_its_ram_consumer() {
    let network = NetworkSlots::new(1);
    let slot = network.try_acquire().unwrap();
    let scope = Scope::with_network(
        "generated-receiving-slot-release".into(),
        None,
        Some(network.clone()),
        Some(slot),
    );
    scope
        .run(async {
            let body = Receiving::current().unwrap();
            let producer = body.producer();
            assert!(!network.available());
            drop(producer);
            assert!(
                network.available(),
                "Completed HTTP must release admission while its RAM payload drains"
            );
            assert_eq!(scope.attempt.state.lock().unwrap().receivers, 1);
            drop(body);
        })
        .await;
}

#[tokio::test]
async fn ready_bodies_cannot_starve_independently_bounded_verifier_metadata() {
    let key = Key::Drive(0xed00_0000_0000_0009);
    let pool = pool(key);
    let setup = NetworkSlots::new(1);
    let ready_body = setup.try_acquire().unwrap();
    let ticket = pool.enqueue(key, 128 << 20, 128 << 20);
    let id = "generated-independent-verifier-metadata";
    let scope = Scope::with_setup(
        id.into(),
        Some(Deferred(ticket)),
        NetworkSlots::new(1),
        setup.clone(),
        None,
    );
    tokio::time::timeout(
        Duration::from_secs(1),
        scope.run(async {
            prepare_metadata().await;
            assert!(
                !setup.available(),
                "Ready-body lookahead remains bounded independently"
            );
            assert!(scope.attempt.state.lock().unwrap().preparing.is_some());
            assert!(admit(key, id, 128 << 20, 128 << 20).unwrap().is_some());
        }),
    )
    .await
    .expect("Ready bodies held every permit and blocked a prepared disk check's metadata");
    drop(scope);
    drop(ready_body);
    assert!(pool.0.lock().unwrap().active.is_empty());
    assert!(pool.0.lock().unwrap().preparing.is_empty());
}

#[tokio::test]
async fn a_ready_check_cannot_reserve_bytes_while_waiting_outside_the_current_read_cohort() {
    let key = Key::Drive(0xed00_0000_0000_000a);
    let pool = pool(key);
    let older = pool.enqueue(key, 2 << 30, 2 << 30);
    let metadata = Scope::new(
        "generated-selected-cloud-wait".into(),
        Some(Deferred(older)),
    );
    // Start a read turn containing the older check, whose metadata is still
    // unavailable. This guard has no attempt and only drives the real gate.
    let starter = super::super::acquire_key_read(key, "generated-cohort-start", Some(1))
        .await
        .unwrap();
    drop(starter.chunk(1, "generated-cohort-start").await.unwrap());
    drop(starter);
    // This check arrives after cohort selection. Reserving its oversized
    // bytes excludes the older check, so it must be allowed to use the idle
    // read turn rather than waiting for that excluded check to finish.
    let ready = pool.enqueue(key, 2 << 30, 2 << 30);
    let id = "generated-later-ready-check";
    let scope = Scope::new(id.into(), Some(Deferred(ready)));
    tokio::time::timeout(
        Duration::from_secs(1),
        scope.run(async {
            let guard = super::super::acquire_key_read(key, id, Some(2 << 30))
                .await
                .unwrap();
            drop(guard.chunk(4096, id).await.unwrap());
        }),
    )
    .await
    .expect(
        "An admitted check waited for an older cohort which needed its reserved byte allowance",
    );
    drop(scope);
    drop(metadata);
    assert!(pool.0.lock().unwrap().active.is_empty());
    assert!(pool.0.lock().unwrap().preparing.is_empty());
}

#[tokio::test]
async fn enlarged_prepared_file_rechecks_byte_admission_without_losing_its_ticket() {
    let key = Key::Drive(0xed00_0000_0000_0006);
    let pool = pool(key);
    let first = pool.enqueue(key, 512 << 20, 512 << 20);
    let second = pool.enqueue(key, 512 << 20, 512 << 20);
    let id = "generated-prepared-growth";
    let scope = Scope::new(id.into(), Some(Deferred(first)));
    let sibling_id = "generated-prepared-growth-sibling";
    let second_scope = Scope::new(sibling_id.into(), Some(Deferred(second)));
    second_scope
        .run(async {
            drop(admit(key, sibling_id, 512 << 20, 512 << 20).unwrap());
        })
        .await;
    let error = scope
        .run(async { admit(key, id, 768 << 20, 768 << 20) })
        .await
        .err()
        .unwrap();
    let waiting = error.downcast_ref::<Deferred>().unwrap().clone();
    assert!(
        !waiting.ready(),
        "A changed file must not exceed the shared byte allowance"
    );
    drop(scope);
    drop(second_scope);
    assert!(waiting.ready());
    let resumed = Scope::new(id.into(), Some(waiting));
    resumed
        .run(async {
            assert!(
                admit(key, id, 768 << 20, 768 << 20).unwrap().is_some(),
                "The original read ticket remains pending"
            );
        })
        .await;
    drop(resumed);
    assert!(pool.0.lock().unwrap().active.is_empty());
}

#[tokio::test]
async fn oversized_metadata_preparation_cannot_leave_ready_readers_without_disk_admission() {
    let key = Key::Drive(0xed00_0000_0000_0008);
    let pool = pool(key);
    let slow = pool.enqueue(key, 8 << 30, 8 << 30);
    let ready = pool.enqueue(key, 128 << 20, 128 << 20);
    let slow_scope = Scope::new(
        "generated-slow-cloud-preparation".into(),
        Some(Deferred(slow)),
    );
    assert!(
        pool.ready(&ready),
        "An oversized cloud setup must not hold the disk byte pool"
    );
    let id = "generated-ready-disk-check";
    let ready_scope = Scope::new(id.into(), Some(Deferred(ready)));
    ready_scope
        .run(async {
            assert!(admit(key, id, 128 << 20, 128 << 20).unwrap().is_some());
        })
        .await;
    assert_eq!(pool.0.lock().unwrap().active.len(), 1);
    drop(ready_scope);
    drop(slow_scope);
    assert!(pool.0.lock().unwrap().active.is_empty());
    assert!(pool.0.lock().unwrap().preparing.is_empty());
}

#[test]
fn metadata_preparation_and_finished_http_bodies_leave_room_for_receivers() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_lowercase()
            .ends_with("proxy")
        {
            child.env_remove(key);
        }
    }
    let result = child
        .env(
            "MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES",
            (32 << 20).to_string(),
        )
        .args([
            "--exact",
            "download_verification::admission::tests::disk_preparation_and_ram_drain_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated control/network/RAM environment; invoked by parent"]
async fn disk_preparation_and_ram_drain_child() {
    use crate::transfer_control::{schedule, Concurrency};
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
    std::env::set_var(
        "MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS",
        directory.path().join("connections"),
    );
    let key = Key::Drive(0xed00_0000_0000_0004);
    let blocker = Scope::new("generated-preparation-owner".into(), None);
    drop(
        blocker
            .run(async {
                admit(
                    key,
                    "generated-preparation-owner",
                    MAX_BYTES + 1,
                    MAX_BYTES + 1,
                )
            })
            .await
            .unwrap(),
    );
    let attempts = Arc::new(AtomicUsize::new(0));
    let started = Arc::new(tokio::sync::Notify::new());
    let prepared = Arc::new(tokio::sync::Notify::new());
    let release_body = Arc::new(tokio::sync::Notify::new());
    let release_metadata = Arc::new(tokio::sync::Notify::new());
    let replacement = Arc::new(AtomicBool::new(false));
    let (start_observed, prepared_observed, body_release, replacement_observed) = (
        started.clone(),
        prepared.clone(),
        release_body.clone(),
        replacement.clone(),
    );
    let queue = tokio::spawn(schedule(
        vec![0, 1, 2],
        Concurrency::download(1, Arc::new(AtomicU64::new(0))),
        move |index| {
            let (attempts, started, prepared, release_body, release_metadata, replacement) = (
                attempts.clone(),
                started.clone(),
                prepared.clone(),
                release_body.clone(),
                release_metadata.clone(),
                replacement.clone(),
            );
            async move {
                match index {
                    0 => {
                        if attempts.fetch_add(1, Ordering::SeqCst) != 0 {
                            prepared.notify_one();
                            release_metadata.notified().await;
                        }
                        drop(admit(key, "generated-preparation-0", 1024, 1024)?);
                    }
                    1 => {
                        started.notify_one();
                        release_body.notified().await;
                    }
                    _ => {
                        replacement.store(true, Ordering::SeqCst);
                        release_metadata.notify_one();
                    }
                }
                Ok::<_, anyhow::Error>(())
            }
        },
        |index| format!("generated-preparation-{index}"),
        |_, result| result.unwrap(),
        |_, _, _| {},
    ));
    start_observed.notified().await;
    drop(blocker);
    tokio::time::timeout(Duration::from_secs(2), prepared_observed.notified())
        .await
        .unwrap();
    body_release.notify_one();
    tokio::time::timeout(Duration::from_secs(2), queue)
        .await
        .expect("A queued verifier waiting for metadata consumed the only network worker")
        .unwrap()
        .unwrap();
    assert!(replacement_observed.load(Ordering::SeqCst));

    // Reproduce the live failure without user data: cloud setup is blocked
    // for several files, while later files already have reusable links.
    // Healthy bodies must receive through the original one-body allowance.
    let remote = fixture::Fixture::new(128 << 10).await;
    let release_setup = Arc::new(AtomicBool::new(false));
    let received = Arc::new(AtomicU64::new(0));
    let healthy = Arc::new(AtomicUsize::new(0));
    let maximum = Arc::new(AtomicUsize::new(0));
    let (release, observed, observed_maximum) =
        (release_setup.clone(), healthy.clone(), maximum.clone());
    let queue = tokio::spawn(schedule(
        (0..16).collect(),
        Concurrency::download(1, received.clone()),
        move |index| {
            let (release, received, healthy, maximum, url) = (
                release_setup.clone(),
                received.clone(),
                healthy.clone(),
                maximum.clone(),
                remote.url.clone(),
            );
            async move {
                let id = format!("generated-cloud-setup-{index}");
                if index < 12 {
                    crate::transfer_control::metadata_interruptible(&id, async {
                        while !release.load(Ordering::SeqCst) {
                            tokio::time::sleep(Duration::from_millis(5)).await;
                        }
                    })
                    .await?;
                } else {
                    ready_to_receive(&id).await?;
                    maximum.fetch_max(
                        CURRENT.with(|attempt| attempt.network.as_ref().unwrap().active()),
                        Ordering::SeqCst,
                    );
                    let http = reqwest::Client::builder().no_proxy().build().unwrap();
                    let mut body = crate::download_buffer::Response::new(
                        http.get(url).send().await?,
                        move |n| {
                            received.fetch_add(n, Ordering::SeqCst);
                        },
                    );
                    let mut size = 0;
                    while let Some(bytes) =
                        body.chunk().await.map_err(crate::DlError::into_inner)?
                    {
                        size += bytes.len();
                    }
                    assert_eq!(size, 128 << 10);
                    healthy.fetch_add(1, Ordering::SeqCst);
                }
                Ok::<_, anyhow::Error>(())
            }
        },
        |index| format!("generated-cloud-setup-{index}"),
        |_, result| result.unwrap(),
        |_, _, _| {},
    ));
    let progress = tokio::time::timeout(Duration::from_secs(5), async {
        while observed.load(Ordering::SeqCst) != 4 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    release.store(true, Ordering::SeqCst);
    tokio::time::timeout(Duration::from_secs(2), queue)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(
        progress.is_ok(),
        "Cloud metadata waits blocked already-ready receiving"
    );
    assert_eq!(
        observed_maximum.load(Ordering::SeqCst),
        1,
        "Setup lookahead must preserve the body concurrency limit"
    );

    for ranged in [false, true] {
        let remote = fixture::Fixture::new(8 << 20).await;
        let received = Arc::new(AtomicU64::new(0));
        let release_disk = Arc::new(tokio::sync::Notify::new());
        let completed = Arc::new(AtomicUsize::new(0));
        let observed_received = received.clone();
        let release_on_timeout = release_disk.clone();
        let queue = tokio::spawn(schedule(
            vec![0, 1],
            Concurrency::download(1, received.clone()),
            move |index| {
                let (url, received, release_disk) =
                    (remote.url.clone(), received.clone(), release_disk.clone());
                async move {
                    ready_to_receive(&format!("generated-draining-ram-{index}")).await?;
                    let http = reqwest::Client::builder().no_proxy().build().unwrap();
                    let mut size = 0;
                    if ranged {
                        let transfer = pikpak::download_ranges::Transfer::new(
                            &http,
                            &url,
                            None,
                            pikpak::download_ranges::State::new(8 << 20, "\"fixture-1\"".into(), 0),
                            pikpak::download_network::Network::new(2, None),
                        )
                        .unwrap();
                        let mut ranges =
                            crate::download_buffer::Ranges::new(transfer, move |bytes| {
                                received.fetch_add(bytes, Ordering::SeqCst);
                            });
                        if index == 0 {
                            release_disk.notified().await;
                        } else {
                            release_disk.notify_one();
                        }
                        while let Some(chunk) = ranges.next().await? {
                            size += chunk.bytes.len();
                            ranges.accept(&chunk);
                        }
                        assert!(
                            ranges.state().complete(),
                            "Written coverage includes ordered EOF proof"
                        );
                    } else {
                        let mut response = crate::download_buffer::Response::new(
                            http.get(url).send().await.unwrap(),
                            move |bytes| {
                                received.fetch_add(bytes, Ordering::SeqCst);
                            },
                        );
                        if index == 0 {
                            release_disk.notified().await;
                        } else {
                            release_disk.notify_one();
                        }
                        while let Some(chunk) =
                            response.chunk().await.map_err(crate::DlError::into_inner)?
                        {
                            size += chunk.len();
                        }
                    }
                    assert_eq!(size, 8 << 20);
                    Ok::<_, anyhow::Error>(())
                }
            },
            |index| format!("generated-draining-ram-{index}"),
            move |_, result| {
                result.unwrap();
                completed.fetch_add(1, Ordering::SeqCst);
            },
            |_, _, _| {},
        ));
        tokio::time::timeout(Duration::from_secs(3), async {
            while observed_received.load(Ordering::SeqCst) < 16 << 20 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap_or_else(|_| {
            release_on_timeout.notify_one();
            panic!("An HTTP body already queued in RAM blocked replacement receiving");
        });
        tokio::time::timeout(Duration::from_secs(2), queue)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(crate::download_buffer::snapshot().used, 0);
    }
    println!("PASS queued metadata and completed HTTP producers cannot occupy receiving admission");
}

#[test]
fn more_than_sixty_four_verifiers_cannot_starve_ram_receiving() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_lowercase()
            .ends_with("proxy")
        {
            child.env_remove(key);
        }
    }
    let result = child
        .env(
            "MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES",
            (32 << 20).to_string(),
        )
        .args([
            "--exact",
            "download_verification::admission::tests::saturated_read_queue_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}

#[test]
fn saturated_receivers_cannot_consume_verification_dispatch_capacity() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "download_verification::admission::tests::receiver_saturation_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated scheduler, verification and control state; invoked by parent"]
async fn receiver_saturation_child() {
    use crate::transfer_control::{schedule, Concurrency};
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
    std::env::set_var(
        "MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS",
        directory.path().join("connections"),
    );
    let key = Key::Drive(0xed00_0000_0000_0007);
    let blocker = Scope::new("generated-saturated-reader-owner".into(), None);
    blocker
        .run(async {
            drop(admit(key, "generated-saturated-reader-owner", 2 << 30, 2 << 30).unwrap());
        })
        .await;
    let reads = Arc::new(AtomicUsize::new(0));
    let receiving = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(AtomicBool::new(false));
    let (observed_reads, observed_receiving, finish) =
        (reads.clone(), receiving.clone(), release.clone());
    let queue = tokio::spawn(schedule(
        (0..72).collect(),
        Concurrency::download(1, Arc::default()),
        move |index| {
            let (reads, receiving, release) = (reads.clone(), receiving.clone(), release.clone());
            async move {
                if index < 71 {
                    let id = format!("generated-saturated-reader-{index}");
                    crate::transfer_control::metadata_interruptible(&id, std::future::ready(()))
                        .await?;
                    let guard = super::super::acquire_key_read(key, &id, Some(1)).await?;
                    drop(guard.chunk(1, &id).await?);
                    drop(guard);
                    reads.fetch_add(1, Ordering::SeqCst);
                }
                super::ready_to_receive(&format!("generated-saturated-reader-{index}")).await?;
                let body = Receiving::current().unwrap();
                let producer = body.producer();
                receiving.fetch_add(1, Ordering::SeqCst);
                while !release.load(Ordering::SeqCst) {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                receiving.fetch_sub(1, Ordering::SeqCst);
                drop(producer);
                drop(body);
                Ok::<_, anyhow::Error>(())
            }
        },
        |index| format!("generated-saturated-reader-{index}"),
        |_, result| {
            result.unwrap();
        },
        |_, _, _| {
            panic!("Verification admission must not become a network retry");
        },
    ));
    tokio::time::timeout(Duration::from_secs(5), async {
        while observed_receiving.load(Ordering::SeqCst) == 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    drop(blocker);
    let progress = tokio::time::timeout(Duration::from_secs(3), async {
        while observed_reads.load(Ordering::SeqCst) < 71 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    let reads_before_release = observed_reads.load(Ordering::SeqCst);
    let receiving_before_release = observed_receiving.load(Ordering::SeqCst);
    finish.store(true, Ordering::SeqCst);
    tokio::time::timeout(Duration::from_secs(5), queue)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(progress.is_ok(), "Verification stopped at {reads_before_release}/71 checks while long-running receivers occupied the historical +64 allowance");
    assert_eq!(
        receiving_before_release, 1,
        "Finishing verification must not bypass the receiving target"
    );
    assert!(pool(key).0.lock().unwrap().active.is_empty());
    println!("PASS independently admitted verification continues while receiving slots are full");
}

#[test]
fn more_than_sixty_four_finished_bodies_cannot_block_receiving_with_ram_headroom() {
    let mut child = std::process::Command::new(std::env::current_exe().unwrap());
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_lowercase()
            .ends_with("proxy")
        {
            child.env_remove(key);
        }
    }
    let result = child
        .env(
            "MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES",
            (32 << 20).to_string(),
        )
        .args([
            "--exact",
            "download_verification::admission::tests::many_ram_drainers_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated control/network/RAM environment; invoked by parent"]
async fn many_ram_drainers_child() {
    use crate::transfer_control::{schedule, Concurrency};
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
    std::env::set_var(
        "MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS",
        directory.path().join("connections"),
    );
    let remote = fixture::Fixture::new(128 << 10).await;
    let received = Arc::new(AtomicU64::new(0));
    let finished = Arc::new(AtomicUsize::new(0));
    let waiting = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(tokio::sync::Notify::new());
    let (observed, completed, disk, waiting_observed) = (
        received.clone(),
        finished.clone(),
        release.clone(),
        waiting.clone(),
    );
    let queue = tokio::spawn(schedule(
        (0..97).collect(),
        Concurrency::download(1, received.clone()),
        move |index| {
            let (url, received, release, waiting) = (
                remote.url.clone(),
                received.clone(),
                release.clone(),
                waiting.clone(),
            );
            async move {
                ready_to_receive(&format!("generated-many-ram-drainers-{index}")).await?;
                let http = reqwest::Client::builder().no_proxy().build().unwrap();
                let mut response =
                    crate::download_buffer::Response::new(http.get(url).send().await?, move |n| {
                        received.fetch_add(n, Ordering::SeqCst);
                    });
                let ready = release.notified();
                tokio::pin!(ready);
                ready.as_mut().enable();
                waiting.fetch_add(1, Ordering::SeqCst);
                ready.await;
                let mut bytes = 0;
                while let Some(chunk) =
                    response.chunk().await.map_err(crate::DlError::into_inner)?
                {
                    bytes += chunk.len();
                }
                assert_eq!(bytes, 128 << 10);
                Ok::<_, anyhow::Error>(())
            }
        },
        |n| format!("generated-many-ram-drainers-{n}"),
        move |_, result| {
            result.unwrap();
            completed.fetch_add(1, Ordering::SeqCst);
        },
        |_, _, _| {},
    ));
    let receiving = tokio::time::timeout(Duration::from_secs(15), async {
        while observed.load(Ordering::SeqCst) < 97 * (128 << 10)
            || waiting_observed.load(Ordering::SeqCst) != 97
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    // Register every wait before broadcast; cancel cleanly on regression.
    if receiving.is_err() {
        queue.abort();
        let _ = queue.await;
        panic!("Finished bodies blocked replacement receiving although less than half the RAM budget was used");
    }
    assert!(crate::download_buffer::snapshot().used < 16 << 20);
    disk.notify_waiters();
    tokio::time::timeout(Duration::from_secs(5), queue)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(finished.load(Ordering::SeqCst), 97);
    assert_eq!(crate::download_buffer::snapshot().used, 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "isolated control/network/RAM environment; invoked by parent"]
async fn saturated_read_queue_child() {
    use crate::transfer_control::{schedule, Concurrency};
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
    std::env::set_var(
        "MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS",
        directory.path().join("connections"),
    );
    let key = Key::Drive(0xed00_0000_0000_0003);
    let owner = super::super::acquire_key(key, "generated-read-owner")
        .await
        .unwrap();
    let fixture = fixture::Fixture::new(16 << 20).await;
    let received = Arc::new(AtomicU64::new(0));
    let reads = Arc::new(AtomicUsize::new(0));
    let done = Arc::new(AtomicUsize::new(0));
    let retries = Arc::new(AtomicBool::new(false));
    let release_http = Arc::new(tokio::sync::Notify::new());
    let (rx, completed, observed_retries, http_release) = (
        received.clone(),
        done.clone(),
        retries.clone(),
        release_http.clone(),
    );
    let reads_observed = reads.clone();
    let queue = tokio::spawn(schedule(
        (0..97).collect(),
        Concurrency::download(1, received.clone()),
        move |index| {
            let (received, reads, url, release_http) = (
                received.clone(),
                reads.clone(),
                fixture.url.clone(),
                release_http.clone(),
            );
            async move {
                if index < 96 {
                    let id = format!("generated-read-{index}");
                    let guard = super::super::acquire_key_read(key, &id, Some(128 << 20)).await?;
                    drop(guard.chunk(128 << 20, &id).await?);
                    reads.fetch_add(1, Ordering::SeqCst);
                    // The first completed check releases the sole receiving task.
                    release_http.notify_one();
                } else {
                    ready_to_receive(&format!("generated-read-{index}")).await?;
                    let http = reqwest::Client::builder().no_proxy().build().unwrap();
                    let mut response = crate::download_buffer::Response::new(
                        http.get(url).send().await.unwrap(),
                        move |n| {
                            received.fetch_add(n, Ordering::SeqCst);
                        },
                    );
                    release_http.notified().await;
                    let mut offset = 0u64;
                    while let Some(bytes) =
                        response.chunk().await.map_err(crate::DlError::into_inner)?
                    {
                        for (index, byte) in bytes.iter().enumerate() {
                            assert_eq!(*byte, fixture::byte(offset + index as u64, 1));
                        }
                        offset += bytes.len() as u64;
                    }
                    assert_eq!(offset, 16 << 20);
                }
                Ok::<_, anyhow::Error>(())
            }
        },
        |index| format!("generated-read-{index}"),
        move |_, result| {
            result.unwrap();
            completed.fetch_add(1, Ordering::SeqCst);
        },
        move |_, _, _| {
            observed_retries.store(true, Ordering::SeqCst);
        },
    ));
    tokio::time::timeout(Duration::from_secs(10), async {
        while rx.load(Ordering::SeqCst) < 2 << 20 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("96 queued verifiers starved the only HTTP receiver");
    assert_eq!(reads_observed.load(Ordering::SeqCst), 0);
    assert!(crate::download_buffer::snapshot().used > 0);
    let read_pool = pool(key);
    assert!(read_pool.0.lock().unwrap().active.len() <= MAX_TASKS);
    drop(owner);
    tokio::time::timeout(Duration::from_secs(15), queue)
        .await
        .expect("Deferred reads did not advance while the receiver filled its network target")
        .unwrap()
        .unwrap();
    assert_eq!(done.load(Ordering::SeqCst), 97);
    assert_eq!(reads_observed.load(Ordering::SeqCst), 96);
    assert!(
        !retries.load(Ordering::SeqCst),
        "Read admission must not become a network retry"
    );
    assert!(read_pool.0.lock().unwrap().active.is_empty());
    assert_eq!(crate::download_buffer::snapshot().used, 0);
    // No receiver notification was needed before releasing the disk owner.
    drop(http_release);
    println!("PASS 96 queued verifiers: RAM receiving continues; every read advances; no retry or RAM leak");
}

//! Deferred setup regressions use temporary files and loopback providers only.
use super::*;
use crate::download_verification::{Deferred, Scope, TestDrive};
#[path = "download_range_fixture.rs"]
mod fixture;

#[test]
fn rejected_receive_ahead_does_not_repeat_probes_while_waiting_for_disk() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("RUST_MIN_STACK", (16 << 20).to_string())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (64 << 20).to_string())
        .args(["--exact", "download_preparation_tests::rejected_prefetch_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated generated source changes, range rejection and blocked verification"]
async fn rejected_prefetch_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_LOCKS", directory.path().join("locks"));
    std::env::set_var("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS", directory.path().join("connections"));
    for changed in [false, true] {
        let remote = fixture::Fixture::new(4 << 20).await;
        if changed { remote.revision.store(2, Ordering::Relaxed); }
        else { remote.mode.store(1, Ordering::Relaxed); }
        let client = Client::builder().refresh_token("generated-refresh").device_id("generated-device")
            .api_base_url(&remote.base).auth_base_url(&remote.base).build().unwrap();
        let file: FileInfo = serde_json::from_value(serde_json::json!({
            "id":"generated-source", "name":"generated.bin", "size":remote.size.to_string(), "kind":"drive#file"
        })).unwrap();
        let output = directory.path().join(format!("generated-{changed}"));
        std::fs::create_dir(&output).unwrap();
        let partial = output.join("generated.bin.part");
        let prefix = fixture::bytes(0, 2 << 20, 1);
        let data = crate::download_names::sidecar(&partial, ".ranges.data");
        std::fs::write(&data, &prefix).unwrap();
        let ranges = pikpak::download_ranges::State::new(remote.size, "\"fixture-1\"".into(), prefix.len() as u64);
        let hashes: Vec<_> = ranges.covered_ranges().map(|(_, offset, bytes)| {
            hex::encode(ring::digest::digest(&ring::digest::SHA256, &prefix[offset as usize..(offset+bytes) as usize]))
        }).collect();
        let journal = serde_json::json!({"version":1,"file_id":file.id,"ranges":ranges,"piece_sha256":hashes});
        std::fs::write(crate::download_names::sidecar(&partial, ".ranges.json"), serde_json::to_vec(&journal).unwrap()).unwrap();
        let blocker_id = format!("generated-probe-blocker-{changed}");
        let id = format!("generated-probe-waiter-{changed}");
        let drive = TestDrive::new(&blocker_id);
        let _destination = drive.sibling(&id);
        let blocker = Scope::new(blocker_id, None);
        let held = blocker.run(drive.hold_read(2 << 30)).await;
        let network = crate::download_verification::NetworkSlots::new(1);
        let setup = crate::download_verification::NetworkSlots::new(64);
        let retry = Arc::new(download_transport::RetryState::default());
        let received = Arc::new(AtomicU64::new(0));
        let reads = download_transport::completion_tests::ReadCounter::new(&id);
        let mut waiting = None;
        for _ in 0..4 {
            let scope = Scope::with_setup(id.clone(), waiting.take(), network.clone(), setup.clone(), None);
            let failure = tokio::time::timeout(Duration::from_secs(15), scope.run(download_file_as_with_retry(
                &client, &file, &output, false, false, received.clone(), &id, None, retry.clone(),
            ))).await.expect("Generated parked setup must defer promptly").unwrap_err();
            drop(scope);
            let deferred = failure.downcast::<Deferred>().unwrap();
            assert!(!deferred.ready(), "An attempted probe must not continually rearm a parked disk check");
            waiting = Some(deferred);
            assert_eq!(reads.bytes(), 0, "A parked check must not reread its saved prefix");
            assert_eq!(std::fs::read(&data).unwrap(), prefix);
        }
        let probes = remote.requests.lock().unwrap().iter().filter(|r| r.ranged && r.start == 0 && r.end == 0).count();
        assert_eq!(probes, 1, "Unchanged source setup must reuse its probe across verification deferrals");
        assert_eq!(remote.metadata_requests.load(Ordering::Relaxed), 1);
        drop(held); drop(blocker);
        let scope = Scope::with_setup(id.clone(), waiting, network, setup, None);
        tokio::time::timeout(Duration::from_secs(20), scope.run(download_file_as_with_retry(
            &client, &file, &output, false, false, received, &id, None, retry,
        ))).await.unwrap().unwrap();
        assert_eq!(std::fs::read(output.join("generated.bin")).unwrap(), fixture::bytes(0, remote.size as usize, if changed { 2 } else { 1 }));
        println!("Generated parked check: changed_source={changed}, setup_attempts=4, range_probes={probes}");
    }
}

#[test]
fn eligible_deferred_download_receives_while_verification_is_blocked() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("RUST_MIN_STACK", (16 << 20).to_string())
        .env(
            "MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES",
            (64 << 20).to_string(),
        )
        .args([
            "--exact",
            "download_preparation_tests::eligible_receiving_child",
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated receive-ahead budget and blocked verification"]
async fn eligible_receiving_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
    std::env::set_var(
        "MYCLOUDDRIVER_TRANSFER_LOCKS",
        directory.path().join("locks"),
    );
    std::env::set_var(
        "MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS",
        directory.path().join("connections"),
    );
    let remote = fixture::Fixture::new(4 << 20).await;
    let client = Client::builder()
        .refresh_token("generated-refresh")
        .device_id("generated-device")
        .api_base_url(&remote.base)
        .auth_base_url(&remote.base)
        .build()
        .unwrap();
    let file: FileInfo = serde_json::from_value(serde_json::json!({
        "id":"generated-source", "name":"generated.bin", "size":remote.size.to_string(), "kind":"drive#file"
    })).unwrap();
    let partial = directory.path().join("generated.bin.part");
    let prefix = fixture::bytes(0, 2 << 20, 1);
    std::fs::write(&partial, &prefix).unwrap();
    download_transport::seed_resume(&partial, &file.id, remote.size, "\"fixture-1\"");
    let blocker_id = "generated-eligible-reader";
    let id = "generated-eligible-receiver";
    let drive = TestDrive::new(blocker_id);
    let _destination = drive.sibling(id);
    let blocker = Scope::new(blocker_id.into(), None);
    let held = blocker.run(drive.hold_read(2 << 30)).await;
    let read = held.chunk(256, blocker_id).await.unwrap();
    let permits: Vec<_> = (0..8)
        .map(|_| crate::download_buffer::prefetch_slot(2 << 20, 2 << 20).unwrap())
        .collect();
    let network = crate::download_verification::NetworkSlots::new(1);
    let setup = crate::download_verification::NetworkSlots::new(64);
    let retry = Arc::new(download_transport::RetryState::default());
    let received = Arc::new(AtomicU64::new(0));
    let scope = Scope::with_setup(id.into(), None, network.clone(), setup.clone(), None);
    let waiting = scope
        .run(download_file_as_with_retry(
            &client,
            &file,
            directory.path(),
            false,
            false,
            received.clone(),
            id,
            None,
            retry.clone(),
        ))
        .await
        .unwrap_err()
        .downcast::<Deferred>()
        .unwrap();
    drop(scope);
    assert!(!waiting.ready());
    assert_eq!(remote.metadata_requests.load(Ordering::Relaxed), 1);
    drop(permits);
    assert!(waiting.ready());
    let scope = Scope::with_setup(id.into(), Some(waiting), network.clone(), setup, None);
    let count = received.clone();
    let output = directory.path().to_owned();
    let download = tokio::spawn(async move {
        scope
            .run(download_file_as_with_retry(
                &client, &file, &output, false, false, count, id, None, retry,
            ))
            .await
    });
    tokio::time::timeout(Duration::from_secs(10), async {
        while received.load(Ordering::Relaxed) < 2 << 20 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        while network.active() != 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("An eligible deferred download failed to receive through a blocked verification queue");
    assert!(!download.is_finished());
    assert_eq!(
        remote.metadata_requests.load(Ordering::Relaxed),
        1,
        "Receiving rearm must reuse its prepared source"
    );
    assert_eq!(
        std::fs::read(&partial).unwrap(),
        prefix,
        "Unverified RAM must not change durable coverage"
    );
    assert!(crate::download_buffer::snapshot().prefetch_bytes >= 2 << 20);
    drop(read);
    drop(held);
    drop(blocker);
    tokio::time::timeout(Duration::from_secs(15), download)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("generated.bin")).unwrap(),
        fixture::bytes(0, remote.size as usize, 1)
    );
    assert_eq!(crate::download_buffer::snapshot().used, 0);
}

#[test]
fn deferred_account_and_shared_setup_reuses_metadata() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("RUST_MIN_STACK", (16 << 20).to_string())
        .args([
            "--exact",
            "download_preparation_tests::deferred_setup_child",
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated control, admission and generated destination"]
async fn deferred_setup_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", control);
    std::env::set_var(
        "MYCLOUDDRIVER_TRANSFER_LOCKS",
        directory.path().join("locks"),
    );
    std::env::set_var(
        "MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS",
        directory.path().join("connections"),
    );
    for (shared, dynamic) in [(false, false), (true, false), (false, true), (true, true)] {
        let remote = guest_fixture::Fixture::new().await;
        remote.user_available.store(true, Ordering::SeqCst);
        remote.guest_denied.store(dynamic, Ordering::SeqCst);
        let client = Client::builder()
            .personal_access_token("account-access")
            .device_id("fixture-device")
            .api_base_url(&remote.base)
            .auth_base_url(&remote.base)
            .build()
            .unwrap()
            .with_content_mode(if dynamic {
                pikpak::ContentMode::Dynamic
            } else {
                pikpak::ContentMode::User
            });
        let share = client
            .share_client("https://mypikpak.com/s/public-share", "", "")
            .unwrap();
        let file: FileInfo = serde_json::from_value(if shared {
            remote.original.lock().unwrap().clone()
        } else {
            remote.saved.lock().unwrap().clone()
        })
        .unwrap();
        let output = directory
            .path()
            .join(format!("generated-{shared}-{dynamic}"));
        std::fs::create_dir(&output).unwrap();
        if !dynamic {
            std::fs::write(output.join(&file.name), b"OLD-DATA").unwrap();
        }
        let id = format!("generated-deferred-setup-{shared}-{dynamic}");
        let blocker_id = format!("generated-setup-reader-{shared}-{dynamic}");
        let drive = TestDrive::new(&blocker_id);
        let _destination = drive.sibling(&id);
        let blocker = Scope::new(blocker_id, None);
        let held = blocker.run(drive.hold_read(2 << 30)).await;
        let retry = Arc::new(download_transport::RetryState::default());
        let received = Arc::new(AtomicU64::new(0));
        let mut waiting: Option<Deferred> = None;
        let mut initial_requests = None;
        let metadata_count = || {
            remote
                .requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| {
                    request.starts_with(if shared {
                        "GET /drive/v1/share/file_info"
                    } else {
                        "GET /drive/v1/files/saved-id"
                    })
                })
                .count()
        };
        for attempt in 0..4 {
            let scope = Scope::new(id.clone(), waiting.take());
            let result = tokio::time::timeout(
                Duration::from_secs(20),
                scope.run(async {
                    if shared {
                        download_share_file_as_with_retry(
                            &share,
                            &file,
                            &output,
                            false,
                            false,
                            received.clone(),
                            &id,
                            retry.clone(),
                        )
                        .await
                    } else {
                        download_file_as_with_retry(
                            &client,
                            &file,
                            &output,
                            false,
                            false,
                            received.clone(),
                            &id,
                            None,
                            retry.clone(),
                        )
                        .await
                    }
                }),
            )
            .await
            .unwrap();
            waiting = Some(result.unwrap_err().downcast::<Deferred>().unwrap());
            drop(scope);
            assert_eq!(
                metadata_count(),
                if shared && dynamic { 3 } else { 1 },
                "Deferral {attempt} repeated cloud setup for shared={shared}, dynamic={dynamic}"
            );
            let requests = remote.requests.lock().unwrap().len();
            assert_eq!(
                *initial_requests.get_or_insert(requests),
                requests,
                "Deferral repeated Guest fallback or cloud setup"
            );
            if dynamic {
                assert!(!output.join(&file.name).exists());
                assert_eq!(
                    std::fs::read(output.join(format!("{}.part", file.name))).unwrap(),
                    b"abcdefgh"
                );
                assert_eq!(received.load(Ordering::Relaxed), 8);
            } else {
                assert_eq!(std::fs::read(output.join(&file.name)).unwrap(), b"OLD-DATA");
                assert_eq!(received.load(Ordering::Relaxed), 0);
            }
        }
        drop(held);
        drop(blocker);
        let scope = Scope::new(id.clone(), waiting);
        tokio::time::timeout(
            Duration::from_secs(10),
            scope.run(async {
                if shared {
                    download_share_file_as_with_retry(
                        &share,
                        &file,
                        &output,
                        false,
                        false,
                        received.clone(),
                        &id,
                        retry.clone(),
                    )
                    .await
                } else {
                    download_file_as_with_retry(
                        &client,
                        &file,
                        &output,
                        false,
                        false,
                        received.clone(),
                        &id,
                        None,
                        retry.clone(),
                    )
                    .await
                }
            }),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(metadata_count(), if shared && dynamic { 3 } else { 1 });
        assert_eq!(std::fs::read(output.join(&file.name)).unwrap(), b"abcdefgh");
    }
}

#[test]
fn dynamic_body_retries_reuse_only_the_user_route_and_recheck_permission() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .env("RUST_MIN_STACK", (16 << 20).to_string())
        .args(["--exact", "download_preparation_tests::dynamic_body_retry_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(result.status.success(), "{}{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated transfer control and generated route outages"]
async fn dynamic_body_retry_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_LOCKS", directory.path().join("locks"));
    std::env::set_var("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS", directory.path().join("connections"));
    for (shared, metadata_fallback) in [(false, false), (true, false), (false, true), (true, true)] {
        let remote = guest_fixture::Fixture::new().await;
        remote.user_available.store(true, Ordering::SeqCst);
        remote.guest_denied.store(true, Ordering::SeqCst);
        remote.user_body_failures.store(2, Ordering::SeqCst);
        if metadata_fallback {
            remote.original.lock().unwrap()["web_content_link"] = serde_json::json!("relative-original");
            remote.saved.lock().unwrap()["web_content_link"] = serde_json::json!("relative-original");
        }
        let client = Client::builder().personal_access_token("account-access").device_id("fixture-device")
            .api_base_url(&remote.base).auth_base_url(&remote.base).build().unwrap()
            .with_content_mode(pikpak::ContentMode::Dynamic);
        let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
        let file: FileInfo = serde_json::from_value(if shared { remote.original.lock().unwrap().clone() }
            else { remote.saved.lock().unwrap().clone() }).unwrap();
        let output = directory.path().join(format!("generated-route-{shared}-{metadata_fallback}"));
        std::fs::create_dir(&output).unwrap();
        let id = format!("generated-route-retry-{shared}-{metadata_fallback}");
        let retry = Arc::new(download_transport::RetryState::default());
        let received = Arc::new(AtomicU64::new(0));
        let key = download_preparation::Key::for_file(if shared { "share:public-share:account:account-user".into() }
            else { "account:account-user".into() }, &file, Some(pikpak::ContentMode::Dynamic));
        let run = || async {
            let scope = Scope::new(id.clone(), None);
            scope.run(async {
                if shared { download_share_file_as_with_retry(&share, &file, &output, false, false, received.clone(), &id, retry.clone()).await }
                else { download_file_as_with_retry(&client, &file, &output, false, false, received.clone(), &id, None, retry.clone()).await }
            }).await
        };
        let requests = || {
            let requests = remote.requests.lock().unwrap();
            let guest = requests.iter().filter(|request| request.starts_with("GET /guest-body/")
                || request.starts_with("GET /drive/v1/share/file_info") && !request.contains("authorization:")).count();
            let user = requests.iter().filter(|request| if shared {
                request.starts_with("GET /drive/v1/share/file_info") && request.contains("authorization:")
            } else { request.starts_with("GET /drive/v1/files/saved-id") }).count();
            (guest, user)
        };
        let first = run().await.unwrap_err();
        assert!(first.is::<transfer_control::Retry>(), "{first:#}");
        assert!(retry.preparation.user_handoff(&key));
        let initial = requests();
        assert!(initial.0 > 0 && initial.1 > 0);
        assert!(retry.preparation.download(&key, true).is_none());
        let second = run().await.unwrap_err();
        assert!(second.is::<transfer_control::Retry>(), "{second:#}");
        let next = requests();
        assert_eq!(next.0, initial.0, "A transient User body outage must not repeat Guest setup");
        assert_eq!(next.1, initial.1 + 1, "Every retry must fetch a fresh User URL and permission response");
        assert!(retry.preparation.user_handoff(&key));
        remote.user_body_failure_status.store(403, Ordering::SeqCst);
        remote.user_body_failures.store(1, Ordering::SeqCst);
        let denied = run().await.unwrap_err();
        assert!(denied.is::<transfer_control::Retry>(), "Signed URL denial remains eligible for a fresh permission check");
        assert!(!retry.preparation.user_handoff(&key), "A permission rejection cannot retain the User preference");
        run().await.unwrap();
        assert!(requests().0 > next.0, "After denial the original Guest-first policy must be retried");
        assert_eq!(std::fs::read(output.join(&file.name)).unwrap(), b"abcdefgh");
        assert!(!retry.preparation.user_handoff(&key), "Completion must release the route hint");
    }
}

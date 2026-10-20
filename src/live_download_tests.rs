//! End-to-end queue tests use a loopback-only PikPak/API/body fixture.
use super::*;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[test]
fn discovery_keeps_its_network_and_total_backlogs_bounded_independently() {
    let limits = DiscoveryLimits::default();
    assert!(limits.allows(2048, 0, 0), "A final-check backlog must not stop fresh folder pages");
    assert!(!limits.allows(2048, 2048, 200), "Unreceived/paused files still consume network lookahead");
    assert!(limits.allows(2048, 2048, 0), "Another selection can discover its first page");
    assert!(!limits.allows(8192, 0, 0), "Final checks cannot grow an unbounded metadata backlog");
}

#[test]
fn live_discovery_fetches_fresh_files_while_prior_downloads_await_final_checks() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .env("MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES", (64 << 20).to_string())
        .args(["--exact", "live_downloads::tests::verification_backlog_child", "--ignored", "--nocapture"])
        .output().unwrap();
    assert!(output.status.success(), "{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    println!("{}", String::from_utf8_lossy(&output.stdout));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated real queue, loopback folder pages and held physical verifier"]
async fn verification_backlog_child() {
    use std::os::unix::fs::MetadataExt;
    use crate::download_verification::TestDrive;
    let directory = tempfile::tempdir().unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_LOCKS", directory.path().join("locks"));
    std::env::set_var("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS", directory.path().join("connections"));
    let control = directory.path().join("controls.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    std::fs::write(&control, r#"{"actions":{}}"#).unwrap();
    for (legacy, restored) in [(true, true), (false, true), (true, false), (false, false)] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let fetched = Arc::new(AtomicUsize::new(0));
        let second_page = Arc::new(AtomicBool::new(false));
        let server = {
            let base = base.clone(); let fetched = fetched.clone(); let second_page = second_page.clone();
            tokio::spawn(async move {
                let mut clients = tokio::task::JoinSet::new();
                loop {
                    tokio::select! {
                        accepted = listener.accept() => {
                            let (mut socket, _) = accepted.unwrap();
                            let base = base.clone(); let fetched = fetched.clone(); let second_page = second_page.clone();
                            clients.spawn(async move {
                                let mut request = Vec::new();
                                while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                                    let mut buffer = [0; 4096]; let count = socket.read(&mut buffer).await.unwrap();
                                    if count == 0 { return; } request.extend_from_slice(&buffer[..count]);
                                }
                                let header_end = request.windows(4).position(|bytes| bytes == b"\r\n\r\n").unwrap() + 4;
                                let headers = String::from_utf8_lossy(&request[..header_end]);
                                let length = headers.lines().find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length:")
                                    .and_then(|value| value.trim().parse::<usize>().ok())).unwrap_or(0);
                                while request.len() < header_end + length {
                                    let mut buffer = [0; 4096]; let count = socket.read(&mut buffer).await.unwrap();
                                    if count == 0 { return; } request.extend_from_slice(&buffer[..count]);
                                }
                                let request = String::from_utf8(request).unwrap();
                                let target = request.split_whitespace().nth(1).unwrap();
                                let url = reqwest::Url::parse(&format!("{base}{target}")).unwrap();
                                let data = if url.path().contains("auth/token") {
                                    serde_json::json!({"access_token":"fixture","refresh_token":"fixture","expires_in":7200,"sub":"fixture"}).to_string().into_bytes()
                                } else if url.path().contains("captcha") {
                                    br#"{"captcha_token":"fixture"}"#.to_vec()
                                } else if url.path() == "/drive/v1/files" {
                                    let next = url.query_pairs().any(|(key, _)| key == "page_token");
                                    if next { second_page.store(true, Ordering::SeqCst); }
                                    let ids = if next { vec!["fresh"] } else { vec!["first", "second"] };
                                    let files: Vec<_> = ids.into_iter().map(|id| serde_json::json!({
                                        "id":id,"name":format!("{id}.bin"),"size":"8","kind":"drive#file","parent_id":"folder","hash":"fixture"
                                    })).collect();
                                    serde_json::json!({"files":files,"next_page_token":if next { "" } else { "next" }}).to_string().into_bytes()
                                } else if url.path().starts_with("/drive/v1/files/") {
                                    let id = url.path().rsplit('/').next().unwrap();
                                    serde_json::json!({"name":format!("{id}.bin"),"size":"8","hash":"fixture","web_content_link":format!("{base}/body/{id}")}).to_string().into_bytes()
                                } else if url.path().starts_with("/body/") {
                                    if url.path() == "/body/fresh" { fetched.fetch_add(8, Ordering::SeqCst); }
                                    b"abcdefgh".to_vec()
                                } else { panic!("Unexpected generated queue route: {}", url.path()); };
                                let header = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nETag: \"fixture\"\r\nConnection: close\r\n\r\n", data.len());
                                let _ = socket.write_all(header.as_bytes()).await; let _ = socket.write_all(&data).await;
                            });
                        }
                        result = clients.join_next(), if !clients.is_empty() => { result.unwrap().unwrap(); }
                    }
                }
            })
        };
        let destination = directory.path().join(format!("generated-{legacy}-{restored}"));
        std::fs::create_dir_all(destination.join("folder")).unwrap();
        let destination = destination.canonicalize().unwrap();
        let output = destination.join("folder");
        let root_id = format!("generated-{legacy}-{restored}");
        let drive = TestDrive::new(&format!("generated-held-{legacy}-{restored}"));
        let held = drive.hold().await;
        let mut overrides = Vec::new(); let mut reads = Vec::new();
        for id in ["first", "second", "fresh"] {
            let key = format!("{id}|{}", output.display());
            let control_id = format!("{root_id}:{}", hex::encode(ring::digest::digest(&ring::digest::SHA256, key.as_bytes())));
            overrides.push(drive.sibling(&control_id));
            reads.push(download_transport::completion_tests::ReadCounter::new(&control_id));
            if id == "fresh" || !restored { continue; }
            let part = output.join(format!("{id}.bin.part"));
            let data = crate::download_names::sidecar(&part, ".ranges.data");
            std::fs::write(&data, b"abcdefgh").unwrap();
            let metadata = std::fs::metadata(&data).unwrap();
            let identity = serde_json::json!({"device":metadata.dev(),"inode":metadata.ino(),"size":metadata.len(),
                "modified_ns":metadata.mtime()*1_000_000_000+metadata.mtime_nsec(),"changed_ns":metadata.ctime()*1_000_000_000+metadata.ctime_nsec()});
            let ranges = pikpak::download_ranges::State::new(8, "\"fixture\"".into(), 8);
            let digest = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh"));
            let journal = serde_json::json!({"version":1,"file_id":id,"ranges":ranges,"source_revision":"gcid:FIXTURE",
                "require_content_hash":true,"piece_sha256":[digest],"data_identity":identity});
            std::fs::write(crate::download_names::sidecar(&part, ".ranges.json"), serde_json::to_vec(&journal).unwrap()).unwrap();
        }
        let inbox = destination.join("inbox.json");
        std::fs::write(&inbox, serde_json::json!({"version":1,"content_mode":"user","requests":[{
            "id":root_id,"path":"/folder","destination":destination,"file":{"id":"folder","name":"folder","size":"0","kind":"drive#folder"}
        }]}).to_string()).unwrap();
        let client = Client::builder().refresh_token("fixture").device_id("fixture")
            .api_base_url(&base).auth_base_url(&base).build().unwrap();
        let limits = DiscoveryLimits { receiving: 2, total: if legacy { 2 } else { 8 }, per_root: 2 };
        let task = tokio::spawn(async move { run_with_limits(&client, Args { request_file: inbox }, limits).await });
        until(|| discovery_snapshot().final_verification >= 2).await;
        if legacy {
            tokio::time::sleep(Duration::from_millis(300)).await;
            assert!(!second_page.load(Ordering::SeqCst) && fetched.load(Ordering::SeqCst) == 0,
                "The old combined backlog must reproduce the idle network while the disk is held");
        } else {
            until(|| fetched.load(Ordering::SeqCst) == 8).await;
            assert!(second_page.load(Ordering::SeqCst), "Fresh discovery must proceed before either final check finishes");
        }
        assert!(reads.iter().all(|read| read.bytes() == 0), "The generated physical reader is still held");
        for id in ["first", "second", "fresh"] { assert!(!output.join(format!("{id}.bin")).exists()); }
        println!("Blocked verifier: restored={restored}, legacy_limit={legacy}, new_payload_received={} bytes", fetched.load(Ordering::SeqCst));
        drop(held);
        tokio::time::timeout(Duration::from_secs(15), task).await.unwrap().unwrap().unwrap();
        for (index, id) in ["first", "second", "fresh"].into_iter().enumerate() {
            assert_eq!(std::fs::read(output.join(format!("{id}.bin"))).unwrap(), b"abcdefgh");
            assert_eq!(reads[index].bytes(), 8, "Each finished file still passes its full disk integrity check");
        }
        assert_eq!(discovery_snapshot().outstanding, 0, "Completed queue telemetry must reset");
        server.abort(); drop(overrides);
    }
}

#[tokio::test]
async fn restored_completed_file_without_gcid_or_parent_skips_stale_path_and_original_url_lookups() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let mut gcid = pikpak::upload::GcidHasher::new(8); gcid.update(b"abcdefgh");
    fixture.saved.lock().unwrap()["hash"] = serde_json::json!(gcid.finish());
    let client = Client::builder().personal_access_token("account-access")
        .api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap();
    let directory = tempfile::tempdir().unwrap(); let output = directory.path().join("output");
    std::fs::create_dir(&output).unwrap();
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    crate::download_file(&client, &file, &output, false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
    let mut restored = file.clone(); restored.hash = None; restored.parent_id = None;
    restored.modified_time = Some("stale-queue-time".into());
    let mut restored = serde_json::to_value(restored).unwrap();
    restored["size"] = serde_json::json!("8"); // Native inboxes use PikPak's string size encoding.
    let inbox = directory.path().join("inbox.json");
    std::fs::write(&inbox, serde_json::json!({"version":1,"content_mode":"dynamic","requests":[{
        "id":"generated-restored-root","path":"/Gone/old-name.bin","destination":output,
        "relative_parent":[],"file":restored
    }]}).to_string()).unwrap();
    fixture.user_available.store(false, Ordering::SeqCst); fixture.requests.lock().unwrap().clear();
    tokio::time::timeout(Duration::from_secs(10), run(&client, Args { request_file: inbox })).await.unwrap().unwrap();
    assert!(fixture.requests.lock().unwrap().is_empty(), "A delivered old queue must not look up a stale cloud path or URL");
    assert_eq!(std::fs::read(output.join(&file.name)).unwrap(), b"abcdefgh");
}

#[test]
fn live_destinations_keep_independent_checkpoint_policies_including_late_roots() {
    use crate::download_checkpoint::CheckpointPolicy;
    let directory = tempfile::tempdir().unwrap();
    for (name, kind, expected) in [
        ("internal", Some("internal"), CheckpointPolicy::FREQUENT),
        ("external", Some("external"), CheckpointPolicy::RELAXED),
        ("network", Some("network"), CheckpointPolicy::RELAXED),
        ("legacy", None, CheckpointPolicy::current()),
    ] {
        let mut request: Request = serde_json::from_value(serde_json::json!({
            "id":name,"path":"/generated.bin","destination":directory.path().join(name),
            "destination_kind":kind
        })).unwrap();
        prepare_destination(&mut request).unwrap();
        assert_eq!(download_fs::checkpoint_policy(&request.destination.join("generated.part")), expected);
    }
    // A later internal root cannot reset the external root's policy.
    let external = directory.path().join("external").canonicalize().unwrap();
    assert_eq!(download_fs::checkpoint_policy(&external.join("generated.part")), CheckpointPolicy::RELAXED);
}

#[test]
fn persisted_retry_ancestry_is_optional_and_uses_a_string_object() {
    let legacy: Inbox = serde_json::from_value(serde_json::json!({
        "version":1,"requests":[]
    }))
    .unwrap();
    assert!(legacy.retry_origins.is_empty());
    let current: Inbox = serde_json::from_value(serde_json::json!({
        "version":1,"requests":[],"retry_origins":{"retry":"intermediate","intermediate":"original"}
    }))
    .unwrap();
    assert_eq!(current.retry_origins.get("retry").unwrap(), "intermediate");
    assert_eq!(
        current.retry_origins.get("intermediate").unwrap(),
        "original"
    );
}

#[tokio::test]
async fn invalid_output_reference_fails_only_its_request_and_keeps_healthy_downloads() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    let client = Client::builder()
        .refresh_token("synthetic-refresh")
        .device_id("synthetic-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_guest_mode(true);
    let directory = tempfile::tempdir().unwrap();
    let ancestor = directory.path().join("not-a-directory");
    std::fs::write(&ancestor, b"preserve-generated-ancestor").unwrap();
    let healthy = directory.path().join("healthy");
    std::fs::create_dir(&healthy).unwrap();
    let inbox = directory.path().join("inbox.json");
    let file = serde_json::json!({"id":"saved-id", "parent_id":"saved-folder", "name":"saved-name.bin", "kind":"drive#file", "size":"8"});
    std::fs::write(&inbox, serde_json::json!({"version":1, "content_mode":"guest", "requests":[
        {"id":"invalid-reference", "path":"/Saved/saved-name.bin", "destination":ancestor.join("child"), "file":file},
        {"id":"healthy-reference", "path":"/Saved/saved-name.bin", "destination":healthy, "destination_kind":"external", "file":file}
    ]}).to_string()).unwrap();
    tokio::time::timeout(
        Duration::from_secs(10),
        run(
            &client,
            Args {
                request_file: inbox,
            },
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        std::fs::read(ancestor).unwrap(),
        b"preserve-generated-ancestor"
    );
    assert_eq!(
        std::fs::read(healthy.join("saved-name.bin")).unwrap(),
        b"abcdefgh"
    );
    assert_eq!(download_fs::checkpoint_policy(&healthy.canonicalize().unwrap().join("saved-name.bin.part")),
        crate::download_checkpoint::CheckpointPolicy::RELAXED,
        "The real queue admission must bind the external policy before starting the body");
    fixture.assert_anonymous_content();
}

#[tokio::test]
async fn content_mode_live_queue_inbox_overrides_legacy_mode_for_new_downloads() {
    for mode in [
        pikpak::ContentMode::User,
        pikpak::ContentMode::Guest,
        pikpak::ContentMode::Dynamic,
    ] {
        let fixture = crate::guest_fixture::Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        if mode == pikpak::ContentMode::Dynamic {
            fixture.saved.lock().unwrap()["params"] = serde_json::Value::Null;
        }
        let client = Client::builder()
            .refresh_token("account-refresh")
            .device_id("account-device")
            .api_base_url(&fixture.base)
            .auth_base_url(&fixture.base)
            .build()
            .unwrap()
            .with_guest_mode(true);
        let directory = tempfile::tempdir().unwrap();
        let inbox = directory.path().join("inbox.json");
        std::fs::write(&inbox, serde_json::json!({"version":1,"guest_mode":mode != pikpak::ContentMode::Guest,
            "content_mode":mode,"requests":[{
                "id":"mode-request","path":"/Saved/saved-name.bin","destination":directory.path(),
                "file":{"id":"saved-id","parent_id":"saved-folder","name":"saved-name.bin","kind":"drive#file","size":"8"}
            }]}).to_string()).unwrap();
        tokio::time::timeout(
            Duration::from_secs(10),
            run(
                &client,
                Args {
                    request_file: inbox,
                },
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
            b"abcdefgh"
        );
        let requests = fixture.requests.lock().unwrap();
        let user = requests.iter().any(|r| r.starts_with("GET /user-body/"));
        let guest = requests.iter().any(|r| r.starts_with("GET /guest-body/"));
        assert_eq!(
            (user, guest),
            if mode != pikpak::ContentMode::User {
                (false, true)
            } else {
                (true, false)
            }
        );
        assert_eq!(requests.iter().filter(|r| r.starts_with("POST /drive/v1/share ")).count(), usize::from(mode == pikpak::ContentMode::Dynamic));
    }
}

#[tokio::test]
async fn guest_live_queue_uses_current_setting_and_resolves_legacy_cached_metadata() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    let client = Client::builder()
        .refresh_token("account-refresh")
        .device_id("account-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap();
    assert!(!client.guest_mode());
    let directory = tempfile::tempdir().unwrap();
    let inbox = directory.path().join("inbox.json");
    std::fs::write(
        &inbox,
        serde_json::json!({"version":1,"guest_mode":true,"requests":[{
            "id":"guest-request","path":"/Saved/saved-name.bin","destination":directory.path(),
            "file":{"id":"saved-id","name":"saved-name.bin","kind":"drive#file","size":"8"}
        }]})
        .to_string(),
    )
    .unwrap();
    tokio::time::timeout(
        Duration::from_secs(10),
        run(
            &client,
            Args {
                request_file: inbox,
            },
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        b"abcdefgh"
    );
    fixture.assert_anonymous_content();
}

#[test]
fn live_queue_streams_discovery_and_accepts_new_requests_without_a_batch_boundary() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "live_downloads::tests::live_queue_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // Backoff is a separate UI state, but every actual attempt must announce
    // worker admission again before inspecting metadata or retained bytes.
    let progress_events: Vec<serde_json::Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.strip_prefix(DOWNLOAD_PROGRESS_PREFIX))
        .map(|json| serde_json::from_str(json).unwrap())
        .collect();
    for (request, complete) in [
        ("folder", true),
        ("body-failure", true),
        ("fatal-discovery", false),
        ("paused-folder", false),
    ] {
        let discovery = progress_events
            .iter()
            .find(|event| event["event"] == "request_discovered" && event["request_id"] == request)
            .unwrap_or_else(|| panic!("No discovery event for generated request {request}"));
        assert_eq!(discovery["discovery_complete"], complete, "{request}");
    }
    for request in ["body-failure", "fatal-discovery"] {
        let finished = progress_events
            .iter()
            .find(|event| event["event"] == "request_finished" && event["request_id"] == request)
            .unwrap();
        assert_eq!(finished["success"], false, "{request}");
    }
    let events: Vec<serde_json::Value> = progress_events
        .into_iter()
        .filter(|event: &serde_json::Value| event["name"] == "retry.bin")
        .collect();
    let transitions: Vec<&str> = events
        .iter()
        .filter_map(|event| event["event"].as_str())
        .filter(|event| *event != "file_progress")
        .collect();
    assert_eq!(
        transitions,
        vec![
            "file_dequeued",
            "file_started",
            "file_retrying",
            "file_dequeued",
            "file_started",
            "file_completed",
        ],
        "A waiting retry did not re-enter Downloading before its next attempt"
    );
    let retry = events
        .iter()
        .find(|event| event["event"] == "file_retrying")
        .unwrap();
    assert_eq!(retry["attempt"], 1);
    assert_eq!(retry["retry_in_millis"], 1000);
    let starts: Vec<_> = events
        .iter()
        .filter(|event| event["event"] == "file_started")
        .collect();
    assert_eq!(starts[0]["downloaded_bytes"], 0);
    assert_eq!(starts[1]["downloaded_bytes"], 3);
    assert_eq!(starts[1]["transferred_bytes"], 3);
    assert!(events
        .iter()
        .all(|event| event["file_id"] == retry["file_id"]));
    let complete = events.last().unwrap();
    assert_eq!(complete["downloaded_bytes"], 8);
    assert_eq!(complete["transferred_bytes"], 8);
}

async fn until(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(12), async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("live queue did not make progress");
}

#[tokio::test]
#[ignore = "isolates transfer-control environment from other test cases"]
async fn live_queue_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("control.json");
    let inbox = directory.path().join("inbox.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    std::env::set_var(
        "MYCLOUDDRIVER_TRANSFER_LOCKS",
        directory.path().join("locks"),
    );
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "synthetic-account");
    std::env::remove_var("PIKPAK_PROXY");
    std::fs::write(
        &control,
        br#"{"actions":{"root:paused":"pause","root:paused-folder":"pause"}}"#,
    )
    .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let base = format!("http://{address}");
    let slow_started = Arc::new(AtomicBool::new(false));
    let page_waiting = Arc::new(AtomicBool::new(false));
    let released = Arc::new(AtomicBool::new(false));
    let retry_requests = Arc::new(AtomicUsize::new(0));
    let server = {
        let base = base.clone();
        let slow = slow_started.clone();
        let page = page_waiting.clone();
        let release = released.clone();
        let retries = retry_requests.clone();
        tokio::spawn(async move {
            let mut clients = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let (mut socket, _) = accepted.unwrap();
                        let base = base.clone(); let slow = slow.clone(); let page = page.clone();
                        let release = release.clone(); let retries = retries.clone();
                        clients.spawn(async move {
                            let mut request = Vec::new();
                            while !request.windows(4).any(|part| part == b"\r\n\r\n") {
                                let mut buffer = [0; 4096];
                                let count = socket.read(&mut buffer).await.unwrap();
                                if count == 0 { return; }
                                request.extend_from_slice(&buffer[..count]);
                            }
                            // Drain POST bodies before closing the fixture socket;
                            // unread bytes otherwise cause intermittent TCP resets.
                            let header_end = request.windows(4).position(|part| part == b"\r\n\r\n").unwrap() + 4;
                            let header = String::from_utf8_lossy(&request[..header_end]);
                            let length = header.lines().find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length:")
                                .and_then(|value| value.trim().parse::<usize>().ok())).unwrap_or(0);
                            while request.len() < header_end + length {
                                let mut buffer = [0; 4096];
                                let count = socket.read(&mut buffer).await.unwrap();
                                if count == 0 { return; }
                                request.extend_from_slice(&buffer[..count]);
                            }
                            let request = String::from_utf8(request).unwrap();
                            let target = request.split_whitespace().nth(1).unwrap();
                            let url = reqwest::Url::parse(&format!("{base}{target}")).unwrap();
                            let path = url.path();
                            let mut status = "200 OK";
                            let data = if path.starts_with("/v1/auth/token") {
                                serde_json::json!({"access_token":"fixture", "refresh_token":"fixture", "expires_in":7200, "sub":"fixture"}).to_string().into_bytes()
                            } else if path.contains("captcha") {
                                br#"{"captcha_token":"fixture"}"#.to_vec()
                            } else if path == "/drive/v1/files" {
                                let parent = url.query_pairs().find_map(|(key, value)| (key == "parent_id").then(|| value.into_owned())).unwrap();
                                if parent == "bad-listing" {
                                    status = "400 Bad Request";
                                    br#"{"error":"file_not_found","error_code":5,"error_description":"synthetic failed folder listing"}"#.to_vec()
                                } else if parent == "body-failure-folder" {
                                    br#"{"files":[{"id":"missing","name":"missing.bin","size":"8","kind":"drive#file"}],"next_page_token":""}"#.to_vec()
                                } else if parent == "never-listed" {
                                    panic!("A paused/cancelled folder was unexpectedly listed");
                                } else if url.query_pairs().any(|(key, _)| key == "page_token") {
                                    page.store(true, Ordering::SeqCst);
                                    while !release.load(Ordering::SeqCst) { tokio::time::sleep(Duration::from_millis(20)).await; }
                                    br#"{"files":[],"next_page_token":""}"#.to_vec()
                                } else {
                                    br#"{"files":[{"id":"early","name":"early.bin","size":"8","kind":"drive#file"}],"next_page_token":"second"}"#.to_vec()
                                }
                            } else if path.starts_with("/drive/v1/files/") {
                                let id = path.rsplit('/').next().unwrap();
                                assert!(!id.contains(':'), "namespaced transfer IDs must never enter API requests");
                                if id == "missing" {
                                    status = "400 Bad Request";
                                    br#"{"error":"file_not_found","error_code":5,"error_description":"synthetic missing file"}"#.to_vec()
                                } else {
                                    serde_json::json!({"name":format!("{id}.bin"), "size":"8", "web_content_link":format!("{base}/body/{id}")}).to_string().into_bytes()
                                }
                            } else if path.starts_with("/body/") {
                                let id = path.rsplit('/').next().unwrap();
                                if id == "slow" {
                                    slow.store(true, Ordering::SeqCst);
                                    while !release.load(Ordering::SeqCst) { tokio::time::sleep(Duration::from_millis(20)).await; }
                                }
                                if id == "retry" && retries.fetch_add(1, Ordering::SeqCst) == 0 {
                                    socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: \"fixture\"\r\nConnection: close\r\n\r\nabc").await.unwrap();
                                    return; // Deliberately lose the network mid-body.
                                }
                                if request.to_ascii_lowercase().contains("range: bytes=3-") {
                                    socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 5\r\nContent-Range: bytes 3-7/8\r\nETag: \"fixture\"\r\nConnection: close\r\n\r\ndefgh").await.unwrap();
                                    return;
                                }
                                b"abcdefgh".to_vec()
                            } else { panic!("Unexpected synthetic route: {path}"); };
                            let header = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nETag: \"fixture\"\r\nConnection: close\r\n\r\n", data.len());
                            let _ = socket.write_all(header.as_bytes()).await;
                            let _ = socket.write_all(&data).await;
                            let _ = socket.shutdown().await;
                        });
                    }
                    result = clients.join_next(), if !clients.is_empty() => { result.unwrap().unwrap(); }
                }
            }
        })
    };
    let client = Client::builder()
        .refresh_token("fixture")
        .api_base_url(&base)
        .auth_base_url(&base)
        .build()
        .unwrap();
    let root = |id: &str, file: &str, folder: bool, destination: &str| {
        serde_json::json!({
            "id":id, "path":format!("/{file}{}", if folder { "" } else { ".bin" }),
            "file":{"id":file,"name":format!("{file}{}", if folder { "" } else { ".bin" }),"size":"8","kind":if folder { "drive#folder" } else { "drive#file" }},
            "destination":directory.path().join(destination), "relative_parent":[], "proxy_url":""
        })
    };
    let mut requests = vec![
        root("slow", "slow", false, "first"),
        root("folder", "folder", true, "first"),
        root("paused", "early", false, "paused"),
        root("retry", "retry", false, "first"),
        root("missing", "missing", false, "first"),
        root("body-failure", "body-failure-folder", true, "first"),
        root("fatal-discovery", "bad-listing", true, "first"),
        root("paused-folder", "never-listed", true, "paused"),
    ];
    let save = |requests: &Vec<serde_json::Value>| {
        let temporary = directory.path().join("next.json");
        std::fs::write(
            &temporary,
            serde_json::to_vec(&serde_json::json!({"version":1,"requests":requests})).unwrap(),
        )
        .unwrap();
        std::fs::rename(temporary, &inbox).unwrap();
    };
    save(&requests);
    let helper = {
        let inbox = inbox.clone();
        tokio::spawn(async move {
            run(
                &client,
                Args {
                    request_file: inbox,
                },
            )
            .await
        })
    };
    until(|| {
        slow_started.load(Ordering::SeqCst)
            && page_waiting.load(Ordering::SeqCst)
            && directory.path().join("first/folder/early.bin").exists()
    })
    .await;
    assert!(!directory.path().join("first/slow.bin").exists());
    assert!(!directory.path().join("paused/early.bin").exists());
    // A new click for another destination starts before both the earlier body
    // and the folder's second page can finish. Same cloud ID, isolated controls.
    requests.push(root("late", "early", false, "late"));
    save(&requests);
    until(|| directory.path().join("late/early.bin").exists()).await;
    assert!(!directory.path().join("first/slow.bin").exists());
    assert!(!directory.path().join("paused/early.bin").exists());
    until(|| directory.path().join("first/retry.bin").exists()).await;
    assert_eq!(
        std::fs::read(directory.path().join("first/retry.bin")).unwrap(),
        b"abcdefgh"
    );
    assert!(retry_requests.load(Ordering::SeqCst) >= 2);
    // Cancelling the paused root releases it without downloading its content.
    std::fs::write(
        &control,
        br#"{"actions":{"root:paused":"cancel","root:paused-folder":"cancel"}}"#,
    )
    .unwrap();
    released.store(true, Ordering::SeqCst);
    tokio::time::timeout(Duration::from_secs(12), helper)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(!directory.path().join("paused/early.bin").exists());
    assert_eq!(
        std::fs::read(directory.path().join("first/slow.bin")).unwrap(),
        b"abcdefgh"
    );
    assert_eq!(
        std::fs::read(directory.path().join("late/early.bin")).unwrap(),
        b"abcdefgh"
    );
    server.abort();
}

//! End-to-end queue tests use a loopback-only PikPak/API/body fixture.
use super::*;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

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

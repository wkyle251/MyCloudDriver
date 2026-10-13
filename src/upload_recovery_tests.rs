//! Generated files and a loopback provider exercise durable upload recovery.
use super::*;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct DiscardRecoveryFixture {
    _temp: tempfile::TempDir,
    source: UploadSource,
    checkpoint: UploadCheckpoint,
    client: Client,
    remote: Arc<std::sync::Mutex<serde_json::Value>>,
    metadata_status: Arc<std::sync::atomic::AtomicU16>,
    trash_requests: Arc<AtomicUsize>,
    create_requests: Arc<AtomicUsize>,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for DiscardRecoveryFixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl DiscardRecoveryFixture {
    async fn new(lose_trash_reply: bool) -> Self {
        Self::new_mode(lose_trash_reply, false).await
    }

    async fn new_mode(lose_trash_reply: bool, captcha_outage: bool) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let local = temp.path().join("source.bin");
        std::fs::write(&local, b"abc").unwrap();
        let gcid = pikpak::upload::gcid_file(&local, 3, Arc::new(|_| {}))
            .await
            .unwrap();
        let source = UploadSource {
            upload_id: "discard-fixture".into(),
            path: local.clone(),
            name: "source.bin".into(),
            display_name: "source.bin".into(),
            size: 3,
            remote_parent_id: "destination".into(),
        };
        let mut checkpoint = UploadCheckpoint::open(
            temp.path().join("state"),
            "account".into(),
            "destination".into(),
            vec![local.clone()],
        )
        .unwrap();
        checkpoint
            .initialize(&serde_json::json!({}), [local.clone()].into_iter())
            .unwrap();
        checkpoint
            .save_file(
                &local,
                &pikpak::upload_checkpoint::FileCheckpoint {
                    gcid: Some(gcid.clone()),
                    remote_file_id: Some("old-placeholder".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        let remote = Arc::new(std::sync::Mutex::new(serde_json::json!({
            "id":"old-placeholder", "parent_id":"destination", "name":"source.bin", "kind":"drive#file",
            "size":"3", "hash":gcid, "phase":"PHASE_TYPE_PENDING", "trashed":false,
        })));
        let metadata_status = Arc::new(std::sync::atomic::AtomicU16::new(200));
        let trash_requests = Arc::new(AtomicUsize::new(0));
        let create_requests = Arc::new(AtomicUsize::new(0));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let (file, status, trashes, creates) = (
            remote.clone(),
            metadata_status.clone(),
            trash_requests.clone(),
            create_requests.clone(),
        );
        let server = tokio::spawn(async move {
            let mut failed_captcha = false;
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                let end = loop {
                    let mut chunk = [0; 4096];
                    let read = socket.read(&mut chunk).await.unwrap();
                    if read == 0 {
                        break 0;
                    }
                    request.extend_from_slice(&chunk[..read]);
                    if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                        break end + 4;
                    }
                };
                if end == 0 {
                    continue;
                }
                let header = String::from_utf8_lossy(&request[..end]).to_string();
                let length = header
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length: ")
                            .and_then(|size| size.parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                while request.len() < end + length {
                    let mut chunk = [0; 4096];
                    let read = socket.read(&mut chunk).await.unwrap();
                    assert!(read > 0);
                    request.extend_from_slice(&chunk[..read]);
                }
                let (response_status, body) = if header.starts_with("POST /v1/auth/token") {
                    (
                        200,
                        serde_json::json!({"access_token":"synthetic-access", "refresh_token":"synthetic-next",
                        "expires_in":3600, "sub":"synthetic-account"}),
                    )
                } else if header.starts_with("POST /v1/shield/captcha/init") {
                    let body: serde_json::Value =
                        serde_json::from_slice(&request[end..end + length]).unwrap();
                    if captcha_outage && !failed_captcha && body["action"] == "POST:/drive/v1/files"
                    {
                        failed_captcha = true;
                        (503, serde_json::json!({"error":"temporary captcha outage"}))
                    } else {
                        (
                            200,
                            serde_json::json!({"captcha_token":"synthetic-captcha"}),
                        )
                    }
                } else if header.starts_with("GET /drive/v1/files/old-placeholder?") {
                    let response_status = status.load(Ordering::SeqCst);
                    let body = if response_status == 200 {
                        file.lock().unwrap().clone()
                    } else {
                        serde_json::json!({"error":"file_not_found", "error_description":"synthetic metadata error"})
                    };
                    (response_status, body)
                } else if header.starts_with("GET /v1/user/me ") {
                    (200, serde_json::json!({"sub":"synthetic-account"}))
                } else if header.starts_with("POST /drive/v1/files:batchTrash ") {
                    let body: serde_json::Value =
                        serde_json::from_slice(&request[end..end + length]).unwrap();
                    assert_eq!(body["ids"], serde_json::json!(["old-placeholder"]));
                    trashes.fetch_add(1, Ordering::SeqCst);
                    file.lock().unwrap()["trashed"] = serde_json::json!(true);
                    if lose_trash_reply {
                        continue;
                    }
                    (200, serde_json::json!({}))
                } else if header.starts_with("GET /drive/v1/files?") {
                    (200, serde_json::json!({"files":[]}))
                } else if header.starts_with("POST /drive/v1/files ") {
                    creates.fetch_add(1, Ordering::SeqCst);
                    let body: serde_json::Value =
                        serde_json::from_slice(&request[end..end + length]).unwrap();
                    (
                        200,
                        if body["kind"] == "drive#folder" {
                            serde_json::json!({"id":"created-folder"})
                        } else {
                            serde_json::json!({"file":{"id":"replacement", "phase":"PHASE_TYPE_COMPLETE"}})
                        },
                    )
                } else {
                    panic!(
                        "unexpected discard fixture route {}",
                        header.lines().next().unwrap()
                    );
                };
                let body = body.to_string();
                socket.write_all(format!("HTTP/1.1 {response_status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
            }
        });
        let builder = Client::builder().api_base_url(&base).auth_base_url(&base);
        let client = if captcha_outage {
            builder.refresh_token("synthetic-refresh").credentials(
                pikpak::auth::OAuthCredentials::new("fixture-client", "fixture-secret"),
            )
        } else {
            builder.personal_access_token("synthetic-pat")
        }
        .build()
        .unwrap()
        .with_duplicate_cache_directory(temp.path().join("cache"));
        client
            .duplicate_cache()
            .await
            .unwrap()
            .mark_pending_folder("destination", "old-placeholder")
            .unwrap();
        Self {
            _temp: temp,
            source,
            checkpoint,
            client,
            remote,
            metadata_status,
            trash_requests,
            create_requests,
            server,
        }
    }

    fn arm_discard(&self) {
        let mut saved = self.checkpoint.file(&self.source.path).unwrap();
        saved.discarding_remote_file_id = saved.remote_file_id.clone();
        self.checkpoint
            .save_file(&self.source.path, &saved)
            .unwrap();
    }

    async fn resume(&self) -> Result<bool> {
        upload_one_file(
            &self.client,
            &self.source,
            false,
            1,
            Some(&self.checkpoint),
            Arc::new(AtomicU64::new(0)),
        )
        .await
    }
}

#[tokio::test]
async fn pre_dispatch_captcha_failure_releases_durable_file_and_folder_creation_intents() {
    for upload in [true, false] {
        let fixture = DiscardRecoveryFixture::new_mode(false, true).await;
        if upload {
            let mut saved = fixture.checkpoint.file(&fixture.source.path).unwrap();
            saved.remote_file_id = None;
            fixture
                .checkpoint
                .save_file(&fixture.source.path, &saved)
                .unwrap();
            let error = fixture.resume().await.unwrap_err();
            assert!(upload_file_failure_is_retryable(&error), "{error:#}");
            let saved = fixture.checkpoint.file(&fixture.source.path).unwrap();
            assert!(saved.creation_previous_ids.is_none());
            assert!(saved.remote_file_id.is_none());
        } else {
            let error = resume_upload_folder(
                &fixture.client,
                0,
                "destination",
                "Fixture Folder",
                Some(&fixture.checkpoint),
            )
            .await
            .unwrap_err();
            assert!(format!("{error:#}").contains("503"));
            assert!(fixture.checkpoint.folder(0).unwrap().is_none());
        }
        assert_eq!(
            fixture.create_requests.load(Ordering::SeqCst),
            0,
            "creation was never sent"
        );
        if upload {
            assert!(fixture.resume().await.unwrap());
            assert_eq!(
                fixture
                    .checkpoint
                    .file(&fixture.source.path)
                    .unwrap()
                    .remote_file_id
                    .as_deref(),
                Some("replacement")
            );
        } else {
            assert_eq!(
                resume_upload_folder(
                    &fixture.client,
                    0,
                    "destination",
                    "Fixture Folder",
                    Some(&fixture.checkpoint)
                )
                .await
                .unwrap(),
                "created-folder"
            );
        }
        assert_eq!(
            fixture.create_requests.load(Ordering::SeqCst),
            1,
            "safe recovery creates exactly once"
        );
    }
}

#[tokio::test]
async fn accepted_placeholder_trash_with_lost_reply_resumes_without_trashing_again() {
    let fixture = DiscardRecoveryFixture::new(true).await;
    assert!(fixture.resume().await.is_err());
    let pending = fixture.checkpoint.file(&fixture.source.path).unwrap();
    assert_eq!(pending.remote_file_id.as_deref(), Some("old-placeholder"));
    assert_eq!(
        pending.discarding_remote_file_id.as_deref(),
        Some("old-placeholder")
    );
    assert_eq!(fixture.trash_requests.load(Ordering::SeqCst), 1);
    assert_eq!(fixture.create_requests.load(Ordering::SeqCst), 0);
    assert!(fixture.resume().await.unwrap());
    let saved = fixture.checkpoint.file(&fixture.source.path).unwrap();
    assert!(saved.completed);
    assert_eq!(saved.remote_file_id.as_deref(), Some("replacement"));
    assert!(saved.discarding_remote_file_id.is_none());
    assert!(saved.creation_previous_ids.is_none());
    assert!(fixture
        .client
        .duplicate_cache()
        .await
        .unwrap()
        .pending_task_ids()
        .unwrap()
        .is_empty());
    assert_eq!(fixture.trash_requests.load(Ordering::SeqCst), 1);
    assert_eq!(fixture.create_requests.load(Ordering::SeqCst), 1);
    assert!(fixture.resume().await.unwrap());
    assert_eq!(fixture.create_requests.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn resume_reconciles_post_discard_checkpoint_loss_and_legacy_journals() {
    for (status, legacy, completed_before_trash) in [
        (200, false, false),
        (404, false, false),
        (400, false, false),
        (200, true, false),
        (404, true, false),
        (200, false, true),
    ] {
        let fixture = DiscardRecoveryFixture::new(false).await;
        if !legacy {
            fixture.arm_discard();
        }
        // Model the on-disk checkpoint left by a crash after successful Trash,
        // before recording its completion. No replacement has been created.
        {
            let mut file = fixture.remote.lock().unwrap();
            file["trashed"] = serde_json::json!(true);
            if completed_before_trash {
                file["phase"] = serde_json::json!("PHASE_TYPE_COMPLETE");
            }
        }
        fixture.metadata_status.store(status, Ordering::SeqCst);
        assert!(
            fixture.resume().await.unwrap(),
            "status={status}, legacy={legacy}"
        );
        let saved = fixture.checkpoint.file(&fixture.source.path).unwrap();
        assert!(saved.completed);
        assert_eq!(saved.remote_file_id.as_deref(), Some("replacement"));
        assert!(saved.discarding_remote_file_id.is_none());
        assert!(fixture
            .client
            .duplicate_cache()
            .await
            .unwrap()
            .pending_task_ids()
            .unwrap()
            .is_empty());
        assert_eq!(fixture.trash_requests.load(Ordering::SeqCst), 0);
        assert_eq!(fixture.create_requests.load(Ordering::SeqCst), 1);
    }
}

#[tokio::test]
async fn discard_recovery_preserves_completed_or_unverified_remote_files() {
    let complete = DiscardRecoveryFixture::new(false).await;
    complete.arm_discard();
    complete.remote.lock().unwrap()["phase"] = serde_json::json!("PHASE_TYPE_COMPLETE");
    assert!(complete.resume().await.unwrap());
    let saved = complete.checkpoint.file(&complete.source.path).unwrap();
    assert!(saved.completed);
    assert_eq!(saved.remote_file_id.as_deref(), Some("old-placeholder"));
    assert!(saved.discarding_remote_file_id.is_none());
    assert_eq!(complete.trash_requests.load(Ordering::SeqCst), 0);
    assert_eq!(complete.create_requests.load(Ordering::SeqCst), 0);

    for (trashed, size, hash, phase, status) in [
        (false, "3", "unverified", "PHASE_TYPE_COMPLETE", 200),
        (false, "4", "same", "PHASE_TYPE_PENDING", 200),
        (false, "3", "same", "", 200),
        (true, "3", "unverified", "PHASE_TYPE_PENDING", 200),
        (true, "4", "same", "PHASE_TYPE_PENDING", 200),
        (false, "3", "same", "PHASE_TYPE_PENDING", 403),
    ] {
        let fixture = DiscardRecoveryFixture::new(false).await;
        fixture.arm_discard();
        {
            let mut remote = fixture.remote.lock().unwrap();
            remote["trashed"] = serde_json::json!(trashed);
            remote["size"] = serde_json::json!(size);
            if hash != "same" {
                remote["hash"] = serde_json::json!(hash);
            }
            if phase.is_empty() {
                remote.as_object_mut().unwrap().remove("phase");
            } else {
                remote["phase"] = serde_json::json!(phase);
            }
        }
        fixture.metadata_status.store(status, Ordering::SeqCst);
        assert!(
            fixture.resume().await.is_err(),
            "trashed={trashed}, size={size}, hash={hash}, phase={phase}, status={status}"
        );
        assert_eq!(fixture.trash_requests.load(Ordering::SeqCst), 0);
        assert_eq!(fixture.create_requests.load(Ordering::SeqCst), 0);
        assert_eq!(
            fixture
                .checkpoint
                .file(&fixture.source.path)
                .unwrap()
                .remote_file_id
                .as_deref(),
            Some("old-placeholder")
        );
    }

    let mismatch = DiscardRecoveryFixture::new(false).await;
    let mut saved = mismatch.checkpoint.file(&mismatch.source.path).unwrap();
    saved.discarding_remote_file_id = Some("some-other-id".into());
    mismatch
        .checkpoint
        .save_file(&mismatch.source.path, &saved)
        .unwrap();
    assert!(mismatch.resume().await.is_err());
    assert_eq!(mismatch.trash_requests.load(Ordering::SeqCst), 0);
    assert_eq!(mismatch.create_requests.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn accepted_upload_is_reconciled_without_recreation_and_changed_sources_are_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let local = temp.path().join("source.bin");
    std::fs::write(&local, b"abc").unwrap();
    let gcid = pikpak::upload::gcid_file(&local, 3, Arc::new(|_| {}))
        .await
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let posts = Arc::new(AtomicUsize::new(0));
    let visible = Arc::new(AtomicBool::new(false));
    let (writes, listing, revision) = (posts.clone(), visible.clone(), gcid.clone());
    let server = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let end = loop {
                let mut buffer = [0; 4096];
                let read = socket.read(&mut buffer).await.unwrap();
                if read == 0 {
                    break 0;
                }
                request.extend_from_slice(&buffer[..read]);
                if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                    break end + 4;
                }
            };
            if end == 0 {
                continue;
            }
            let header = String::from_utf8_lossy(&request[..end]).to_string();
            let length = header
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length: ")
                        .and_then(|size| size.parse::<usize>().ok())
                })
                .unwrap_or(0);
            while request.len() < end + length {
                let mut buffer = [0; 4096];
                let read = socket.read(&mut buffer).await.unwrap();
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }
            let file = serde_json::json!({"id":"accepted-id","parent_id":"destination","name":"source.bin","kind":"drive#file","size":"3","hash":revision,"phase":"PHASE_TYPE_COMPLETE","trashed":false});
            let response = if header.starts_with("POST /drive/v1/files ") {
                writes.fetch_add(1, Ordering::SeqCst);
                // Accepted successfully; only its response is lost.
                continue;
            } else if header.starts_with("GET /drive/v1/files?") {
                serde_json::json!({"files":if listing.load(Ordering::SeqCst) { vec![file] } else { vec![] }})
            } else if header.starts_with("GET /drive/v1/files/accepted-id?") {
                file
            } else {
                panic!(
                    "unexpected fixture route {}",
                    header.lines().next().unwrap()
                );
            };
            let body = response.to_string();
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
        }
    });
    let client = Client::builder()
        .personal_access_token("synthetic-pat")
        .api_base_url(&endpoint)
        .auth_base_url(&endpoint)
        .build()
        .unwrap();
    let source = UploadSource {
        upload_id: "fixture".into(),
        path: local.clone(),
        name: "source.bin".into(),
        display_name: "source.bin".into(),
        size: 3,
        remote_parent_id: "destination".into(),
    };
    let state = temp.path().join("state");
    let mut checkpoint = UploadCheckpoint::open(
        state.clone(),
        "account".into(),
        "destination".into(),
        vec![local.clone()],
    )
    .unwrap();
    checkpoint
        .initialize(&serde_json::json!({}), [local.clone()].into_iter())
        .unwrap();
    let bytes = Arc::new(AtomicU64::new(0));
    let lost = upload_one_file(&client, &source, false, 1, Some(&checkpoint), bytes.clone())
        .await
        .unwrap_err();
    assert!(!upload_file_failure_is_retryable(&lost));
    assert!(checkpoint
        .file(&local)
        .unwrap()
        .creation_previous_ids
        .is_some());
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    assert!(
        upload_one_file(&client, &source, false, 1, Some(&checkpoint), bytes.clone())
            .await
            .is_err()
    );
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    visible.store(true, Ordering::SeqCst);
    assert!(
        upload_one_file(&client, &source, false, 1, Some(&checkpoint), bytes.clone())
            .await
            .unwrap()
    );
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    assert!(checkpoint.file(&local).unwrap().completed);

    checkpoint
        .save_file(
            &local,
            &pikpak::upload_checkpoint::FileCheckpoint {
                gcid: Some(gcid),
                ..Default::default()
            },
        )
        .unwrap();
    let modified = std::fs::metadata(&local).unwrap().modified().unwrap();
    std::fs::write(&local, b"xyz").unwrap();
    std::fs::File::options()
        .write(true)
        .open(&local)
        .unwrap()
        .set_times(std::fs::FileTimes::new().set_modified(modified))
        .unwrap();
    let changed = upload_one_file(&client, &source, false, 1, Some(&checkpoint), bytes.clone())
        .await
        .unwrap_err();
    assert!(format!("{changed:#}").contains("changed"));
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    drop(checkpoint);
    // Older manifests lack strong metadata: rehash instead of trusting old GCID.
    let manifest_path = state.join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    for fingerprint in manifest["fingerprints"]
        .as_object_mut()
        .unwrap()
        .values_mut()
    {
        for key in ["device", "inode", "changed_nanos"] {
            fingerprint.as_object_mut().unwrap().remove(key);
        }
    }
    std::fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    let checkpoint = UploadCheckpoint::open(
        state,
        "account".into(),
        "destination".into(),
        vec![local.clone()],
    )
    .unwrap();
    let legacy_changed = upload_one_file(&client, &source, false, 1, Some(&checkpoint), bytes)
        .await
        .unwrap_err();
    assert!(format!("{legacy_changed:#}").contains("changed"));
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    let folder_state = UploadCheckpoint::open(
        temp.path().join("folder-state"),
        "account".into(),
        "destination".into(),
        vec![local.clone()],
    )
    .unwrap();
    assert!(
        resume_upload_folder(&client, 0, "destination", "Folder", Some(&folder_state))
            .await
            .is_err()
    );
    assert!(folder_state.folder(0).unwrap().unwrap().remote_id.is_none());
    let posts_after_folder = posts.load(Ordering::SeqCst);
    let pending_folder =
        resume_upload_folder(&client, 0, "destination", "Folder", Some(&folder_state))
            .await
            .unwrap_err();
    assert!(pending_folder
        .downcast_ref::<PikPakError>()
        .is_some_and(|error| matches!(error, PikPakError::MutationUncertain(_))));
    assert_eq!(posts.load(Ordering::SeqCst), posts_after_folder);
    server.abort();
}

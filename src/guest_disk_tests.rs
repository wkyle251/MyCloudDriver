use super::*;

#[tokio::test]
async fn restored_queue_without_gcid_recognizes_a_completed_receipt_before_any_url_lookup() {
    use std::sync::atomic::Ordering;
    for pat in [false, true] {
        let fixture = guest_fixture::Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        let mut gcid = pikpak::upload::GcidHasher::new(8); gcid.update(b"abcdefgh");
        fixture.saved.lock().unwrap()["hash"] = serde_json::json!(gcid.finish());
        let builder = Client::builder().api_base_url(&fixture.base).auth_base_url(&fixture.base);
        let client = if pat { builder.personal_access_token("account-access") }
            else { builder.refresh_token("account-refresh").device_id("generated-device") }
            .build().unwrap().with_content_mode(pikpak::ContentMode::User);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
        let mut restored = file.clone(); restored.hash = None;
        restored.modified_time = Some("stale-queue-time".into());
        fixture.user_available.store(false, Ordering::SeqCst);
        fixture.requests.lock().unwrap().clear();
        let received = Arc::new(AtomicU64::new(0));
        download_file(&client.clone().with_content_mode(pikpak::ContentMode::Dynamic), &restored, directory.path(),
            false, false, received.clone()).await.unwrap();
        assert_eq!(received.load(Ordering::Relaxed), 0);
        assert!(fixture.requests.lock().unwrap().is_empty(), "A completed local receipt needs no Guest or User request");
        assert_eq!(std::fs::read(directory.path().join(&file.name)).unwrap(), b"abcdefgh");
        restored.hash = Some("EF".repeat(20));
        assert!(download_file(&client, &restored, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.is_err(),
            "A known different content revision must not adopt the old receipt");
        assert!(fixture.requests.lock().unwrap().iter().any(|request| request.starts_with("GET /drive/v1/files/")));
        restored.hash = None;
        let path = directory.path().join(&file.name); let modified = path.metadata().unwrap().modified().unwrap();
        std::fs::write(&path, b"xxxxxxxx").unwrap();
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(modified).unwrap();
        assert!(download_file(&client, &restored, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.is_err(),
            "Download recovery still rejects a changed local file even though duplicate scans trust its GCID");
        assert_eq!(std::fs::read(&path).unwrap(), b"xxxxxxxx");
    }
}

#[tokio::test]
async fn missing_guest_original_falls_back_to_fresh_user_url_for_oauth_and_pat() {
    use std::sync::atomic::Ordering;
    for pat in [false, true] {
        let fixture = guest_fixture::Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        fixture.original.lock().unwrap()["web_content_link"] = serde_json::Value::Null;
        fixture.saved.lock().unwrap()["web_content_link"] = serde_json::Value::Null;
        fixture.share_create_status.store(403, Ordering::SeqCst);
        fixture.user_url_missing_responses.store(1, Ordering::SeqCst);
        let builder = Client::builder().api_base_url(&fixture.base).auth_base_url(&fixture.base);
        let client = if pat { builder.personal_access_token("account-access") }
            else { builder.refresh_token("account-refresh").device_id("generated-device") }
            .build().unwrap().with_content_mode(pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
        assert_eq!(std::fs::read(directory.path().join("saved-name.bin")).unwrap(), b"abcdefgh");
        let requests = fixture.requests.lock().unwrap();
        assert_eq!(requests.iter().filter(|request| request.starts_with("GET /drive/v1/files/saved-id")).count(), 2);
        assert!(!requests.iter().any(|request| request.starts_with("GET /guest-body/")));
        assert!(requests.iter().any(|request| request.starts_with("GET /user-body/")));
        assert_eq!(client.content_mode(), pikpak::ContentMode::Dynamic);
    }
}

#[tokio::test]
async fn unavailable_guest_and_user_original_is_bounded_and_explains_fallback() {
    use std::sync::atomic::Ordering;
    let fixture = guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    fixture.original.lock().unwrap()["web_content_link"] = serde_json::Value::Null;
    fixture.saved.lock().unwrap()["web_content_link"] = serde_json::Value::Null;
    fixture.share_create_status.store(403, Ordering::SeqCst);
    *fixture.user_link_override.lock().unwrap() = Some(String::new());
    let client = Client::builder().personal_access_token("account-access")
        .api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap()
        .with_content_mode(pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let error = download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap_err();
    assert!(error.to_string().contains("Guest access was unavailable; User Mode"));
    assert_eq!(pikpak::download_policy::permanent_failure(&error), Some(pikpak::download_policy::ORIGINAL_URL_UNAVAILABLE));
    assert!(!pikpak::download_policy::retryable(&error));
    assert_eq!(fixture.requests.lock().unwrap().iter().filter(|request| request.starts_with("GET /drive/v1/files/saved-id")).count(), 2);
    assert!(!directory.path().join("saved-name.bin").exists());
}

#[tokio::test]
async fn expired_original_downloads_through_new_share_and_resumes_verified_prefix() {
    for status in ["EXPIRED", "DELETED", "AUDIT_FAILED"] {
        let fixture = guest_fixture::Fixture::new().await;
        *fixture.share_status.lock().unwrap() = status.into();
        let client = Client::builder().personal_access_token("account-access")
            .device_id("fixture-device").api_base_url(&fixture.base).auth_base_url(&fixture.base)
            .build().unwrap().with_content_mode(pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let partial = directory.path().join("saved-name.bin.part");
        std::fs::write(&partial, b"abc").unwrap();
        std::fs::write(directory.path().join("saved-name.bin.part.resume.json"),
            serde_json::json!({"file_id":file.id,"total":8,"etag":"\"guest-fixture\"",
                "source_revision":"gcid:ABCDEF","require_content_hash":true,
                "durable_bytes":3,"prefix_sha256":hex::encode(ring::digest::digest(&ring::digest::SHA256,b"abc"))})
                .to_string()).unwrap();
        let received = Arc::new(AtomicU64::new(0));
        download_file(&client, &file, directory.path(), false, false, received.clone()).await.unwrap();
        assert_eq!(std::fs::read(directory.path().join(&file.name)).unwrap(), b"abcdefgh");
        assert!(!partial.exists());
        assert_eq!(received.load(Ordering::Relaxed), 5);
        // The receipt also prevents another download or share after completion.
        download_file(&client, &file, directory.path(), false, false, received.clone()).await.unwrap();
        assert_eq!(received.load(Ordering::Relaxed), 5);
        let requests = fixture.requests.lock().unwrap();
        assert_eq!(requests.iter().filter(|r| r.starts_with("POST /drive/v1/share ")).count(), 1);
        let bodies: Vec<_> = requests.iter().filter(|r| r.starts_with("GET /guest-body/")).collect();
        assert_eq!(bodies.len(), 1);
        assert!(bodies[0].to_ascii_lowercase().contains("range: bytes=3-\r\n"));
        assert!(!requests.iter().any(|r| r.starts_with("GET /user-body/") || r.starts_with("GET /drive/v1/files/")));
    }
}

#[tokio::test]
async fn disk_conflicts_are_replaced_but_verified_completion_and_descendant_links_are_preserved() {
    let fixture = guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let client = Client::builder()
        .personal_access_token("account-access")
        .device_id("fixture-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap();
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let output = directory.path().join("saved-name.bin");
    for original in [b"OLD-DATA".as_slice(), b"old".as_slice()] {
        std::fs::write(&output, original).unwrap();
        download_file(
            &client,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0))
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
    }
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request.starts_with("GET /user-body/"))
            .count(),
        2,
        "only the original receipt may skip a matching completed file"
    );

    let outside = directory.path().join("outside");
    std::fs::create_dir(&outside).unwrap();
    std::fs::write(outside.join("saved-name.bin"), b"outside-original").unwrap();
    let linked = directory.path().join("linked");
    std::os::unix::fs::symlink(&outside, &linked).unwrap();
    assert!(download_file(
        &client,
        &file,
        &linked,
        false,
        false,
        Arc::new(AtomicU64::new(0))
    )
    .await
    .is_err());
    assert_eq!(
        std::fs::read(outside.join("saved-name.bin")).unwrap(),
        b"outside-original"
    );
    assert!(!outside.join("saved-name.bin.part").exists());
}

#[tokio::test]
async fn personal_access_token_disk_download_dynamic_fallback_keeps_pat_and_guest_separate() {
    let fixture = guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    fixture.guest_denied.store(true, Ordering::SeqCst);
    let client = Client::builder()
        .personal_access_token("account-access")
        .device_id("pat-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_content_mode(pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        b"abcdefgh"
    );
    let requests = fixture.requests.lock().unwrap();
    assert!(!requests
        .iter()
        .any(|r| r.starts_with("POST /v1/auth/token")));
    assert!(requests.iter().any(|r| r.starts_with("GET /guest-body/")));
    assert!(requests.iter().any(|r| r.starts_with("GET /user-body/")));
    assert!(requests
        .iter()
        .filter(|r| r.contains("authorization:"))
        .all(|r| r.contains("authorization: Bearer account-access")
            && !r.contains("x-captcha-token:")));
}

#[test]
fn personal_access_token_file_must_be_present_private_and_valid() {
    use std::os::unix::fs::PermissionsExt;
    let directory = tempfile::tempdir().unwrap();
    let token = directory.path().join("personal-token");
    assert!(load_personal_access_token("").is_err());
    assert!(load_personal_access_token(token.to_str().unwrap()).is_err());
    std::fs::write(&token, "fixture-personal-token\n").unwrap();
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        load_personal_access_token(token.to_str().unwrap()).unwrap(),
        "fixture-personal-token"
    );
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(load_personal_access_token(token.to_str().unwrap()).is_err());
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
    let link = directory.path().join("link");
    std::os::unix::fs::symlink(&token, &link).unwrap();
    assert!(load_personal_access_token(link.to_str().unwrap()).is_err());
    std::fs::write(&token, "").unwrap();
    assert!(load_personal_access_token(token.to_str().unwrap()).is_err());
}

#[tokio::test]
async fn content_mode_links_disk_fallback_uses_the_same_shared_file() {
    for missing_url in [false, true] {
        let fixture = guest_fixture::Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        fixture.guest_denied.store(true, Ordering::SeqCst);
        if missing_url {
            fixture.original.lock().unwrap()["web_content_link"] = serde_json::Value::Null;
        }
        let client = Client::builder()
            .refresh_token("account-refresh")
            .device_id("account-device")
            .api_base_url(&fixture.base)
            .auth_base_url(&fixture.base)
            .build()
            .unwrap()
            .with_content_mode(pikpak::ContentMode::Dynamic);
        let share = client
            .share_client("https://mypikpak.com/s/public-share", "", "")
            .unwrap();
        let file: FileInfo =
            serde_json::from_value(fixture.original.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_share_file(
            &share,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0)),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("original-name.bin")).unwrap(),
            b"abcdefgh"
        );
        let requests = fixture.requests.lock().unwrap();
        assert!(requests.iter().any(|r| r.starts_with("GET /user-body/")));
        assert!(requests
            .iter()
            .filter(|r| r.starts_with("GET /drive/v1/share/file_info"))
            .all(|r| r.contains("file_id=source-id")));
    }
}

#[tokio::test]
async fn content_mode_disk_downloads_fallback_per_file_for_missing_share_and_denied_body() {
    for mode in [pikpak::ContentMode::User, pikpak::ContentMode::Dynamic] {
        for missing_source in [true, false] {
            let fixture = guest_fixture::Fixture::new().await;
            fixture.user_available.store(true, Ordering::SeqCst);
            if missing_source {
                fixture.saved.lock().unwrap()["params"] = serde_json::Value::Null;
            } else {
                fixture.guest_denied.store(true, Ordering::SeqCst);
            }
            let client = Client::builder()
                .refresh_token("account-refresh")
                .device_id("account-device")
                .api_base_url(&fixture.base)
                .auth_base_url(&fixture.base)
                .build()
                .unwrap()
                .with_content_mode(mode);
            let file: FileInfo =
                serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
            let directory = tempfile::tempdir().unwrap();
            download_file(
                &client,
                &file,
                directory.path(),
                false,
                false,
                Arc::new(AtomicU64::new(0)),
            )
            .await
            .unwrap();
            assert_eq!(
                std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
                b"abcdefgh"
            );
            assert_eq!(
                client.content_mode(),
                mode,
                "fallback must not change another file's mode"
            );
            let requests = fixture.requests.lock().unwrap();
            assert_eq!(requests.iter().any(|r| r.starts_with("GET /user-body/")), mode == pikpak::ContentMode::User || !missing_source);
            assert_eq!(
                requests
                    .iter()
                    .filter(|r| r.starts_with("GET /guest-body/"))
                    .count(),
                if mode == pikpak::ContentMode::Dynamic { if missing_source { 1 } else { 2 } } else { 0 },
                "Dynamic retries one refreshed Guest URL before using User quota"
            );
        }
    }
}

#[tokio::test]
async fn guest_disk_download_refreshes_expired_url_and_resumes_saved_account_file() {
    let fixture = guest_fixture::Fixture::new().await;
    fixture.expired.store(true, Ordering::SeqCst);
    let client = Client::builder()
        .refresh_token("account-refresh")
        .device_id("account-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_guest_mode(true);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("saved-name.bin.part");
    std::fs::write(&partial, b"abc").unwrap();
    download_transport::seed_resume(&partial, &file.id, 8, "\"guest-fixture\"");
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        b"abcdefgh"
    );
    assert!(!directory.path().join("original-name.bin").exists());
    assert!(!partial.exists());
    fixture.assert_anonymous_content();
    let requests = fixture.requests.lock().unwrap();
    let bodies: Vec<_> = requests
        .iter()
        .filter(|r| r.starts_with("GET /guest-body/"))
        .collect();
    assert_eq!(bodies.len(), 2);
    assert!(bodies[1].contains("range: bytes=3-\r\n"));
    assert!(bodies[1].contains("if-range: \"guest-fixture\""));
}

fn seed_hashed_guest_prefix(directory: &StdPath, file: &FileInfo) -> (PathBuf, PathBuf) {
    let part = directory.join(format!("{}.part", file.name));
    let state = directory.join(format!("{}.part.resume.json", file.name));
    std::fs::write(&part, b"abc").unwrap();
    std::fs::write(
        &state,
        serde_json::to_vec(&serde_json::json!({
            "file_id":file.id, "total":8, "etag":"\"guest-fixture\"",
            "source_revision":"gcid:abcdef", "require_content_hash":true,
            "durable_bytes":3,
            "prefix_sha256":hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abc"))
        }))
        .unwrap(),
    )
    .unwrap();
    (part, state)
}

#[tokio::test]
async fn dynamic_disk_refreshes_expired_guest_url_before_using_unavailable_account_quota() {
    for shared in [false, true] {
        let fixture = guest_fixture::Fixture::new().await;
        fixture.expired.store(true, Ordering::SeqCst);
        let client = Client::builder()
            .personal_access_token("account-access")
            .device_id("fixture-device")
            .api_base_url(&fixture.base)
            .auth_base_url(&fixture.base)
            .build()
            .unwrap()
            .with_content_mode(pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(if shared {
            fixture.original.lock().unwrap().clone()
        } else {
            fixture.saved.lock().unwrap().clone()
        })
        .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let (part, _) = seed_hashed_guest_prefix(directory.path(), &file);
        let received = Arc::new(AtomicU64::new(0));
        if shared {
            let share = client
                .share_client("https://mypikpak.com/s/public-share", "", "")
                .unwrap();
            download_share_file(
                &share,
                &file,
                directory.path(),
                false,
                false,
                received.clone(),
            )
            .await
            .unwrap();
        } else {
            download_file(
                &client,
                &file,
                directory.path(),
                false,
                false,
                received.clone(),
            )
            .await
            .unwrap();
        }
        assert_eq!(
            std::fs::read(directory.path().join(&file.name)).unwrap(),
            b"abcdefgh"
        );
        assert!(!part.exists());
        assert_eq!(
            received.load(Ordering::Relaxed),
            5,
            "A refreshed Guest URL must reuse the verified prefix"
        );
        fixture.assert_anonymous_content();
        let requests = fixture.requests.lock().unwrap();
        let bodies: Vec<_> = requests
            .iter()
            .filter(|request| request.starts_with("GET /guest-body/"))
            .collect();
        assert_eq!(bodies.len(), 2);
        assert!(bodies
            .iter()
            .all(|request| request.contains("range: bytes=3-\r\n")));
        assert!(!requests
            .iter()
            .any(|request| request.starts_with("GET /user-body/")));
    }
}

#[tokio::test]
async fn dynamic_disk_guest_metadata_outage_retains_checkpoint_and_retry_cooldown() {
    for shared in [false, true] {
        for during_refresh in [false, true] {
            for status in [429, 503] {
                let fixture = guest_fixture::Fixture::new().await;
                fixture.expired.store(during_refresh, Ordering::SeqCst);
                fixture.guest_metadata_failures.store(1, Ordering::SeqCst);
                fixture
                    .guest_metadata_failure_status
                    .store(status, Ordering::SeqCst);
                fixture
                    .guest_metadata_failure_after_urls
                    .store(usize::from(during_refresh), Ordering::SeqCst);
                let client = Client::builder()
                    .personal_access_token("account-access")
                    .device_id("fixture-device")
                    .api_base_url(&fixture.base)
                    .auth_base_url(&fixture.base)
                    .build()
                    .unwrap()
                    .with_content_mode(pikpak::ContentMode::Dynamic);
                let file: FileInfo = serde_json::from_value(if shared {
                    fixture.original.lock().unwrap().clone()
                } else {
                    fixture.saved.lock().unwrap().clone()
                })
                .unwrap();
                let directory = tempfile::tempdir().unwrap();
                let (part, state) = seed_hashed_guest_prefix(directory.path(), &file);
                let checkpoint = std::fs::read(&state).unwrap();
                let received = Arc::new(AtomicU64::new(0));
                let share = client
                    .share_client("https://mypikpak.com/s/public-share", "", "")
                    .unwrap();
                let result = if shared {
                    download_share_file(
                        &share,
                        &file,
                        directory.path(),
                        false,
                        false,
                        received.clone(),
                    )
                    .await
                } else {
                    download_file(
                        &client,
                        &file,
                        directory.path(),
                        false,
                        false,
                        received.clone(),
                    )
                    .await
                };
                let error = result.unwrap_err();
                assert!(pikpak::download_policy::retryable(&error), "{error:#}");
                assert_eq!(
                    pikpak::download_policy::delay(&error),
                    Some(Duration::from_secs(7))
                );
                assert_eq!(std::fs::read(&part).unwrap(), b"abc");
                assert_eq!(std::fs::read(&state).unwrap(), checkpoint);
                fixture.assert_anonymous_content();
                if shared {
                    download_share_file(
                        &share,
                        &file,
                        directory.path(),
                        false,
                        false,
                        received.clone(),
                    )
                    .await
                    .unwrap();
                } else {
                    download_file(
                        &client,
                        &file,
                        directory.path(),
                        false,
                        false,
                        received.clone(),
                    )
                    .await
                    .unwrap();
                }
                assert_eq!(
                    std::fs::read(directory.path().join(&file.name)).unwrap(),
                    b"abcdefgh"
                );
                assert_eq!(received.load(Ordering::Relaxed), 5);
                fixture.assert_anonymous_content();
                assert!(!fixture
                    .requests
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|request| request.starts_with("GET /user-body/")));
            }
        }
    }
}

fn partial_fixture_client(
    fixture: &guest_fixture::PartialFixture,
    pat: bool,
    mode: pikpak::ContentMode,
) -> Client {
    let builder = Client::builder()
        .device_id("partial-fixture-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base);
    let builder = if pat {
        builder.personal_access_token("account-access")
    } else {
        builder.refresh_token("account-refresh")
    };
    builder.build().unwrap().with_content_mode(mode)
}

#[tokio::test]
async fn dynamic_invalid_guest_ranges_refresh_once_then_finish_on_user_without_looping() {
    for shared in [false, true] {
        for resumed in [false, true] {
            let fixture = guest_fixture::PartialFixture::new(
                8, 6, guest_fixture::PartialReply::CappedRange,
            ).await;
            fixture.config.lock().unwrap().guest_invalid_range = true;
            let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
            let file: FileInfo = serde_json::from_value(if shared {
                fixture.original.lock().unwrap().clone()
            } else {
                fixture.saved.lock().unwrap().clone()
            }).unwrap();
            let directory = tempfile::tempdir().unwrap();
            let partial = directory.path().join(format!("{}.part", file.name));
            if resumed {
                std::fs::write(&partial, &fixture.content[..3]).unwrap();
                std::fs::write(directory.path().join(format!("{}.part.resume.json", file.name)),
                    serde_json::to_vec(&serde_json::json!({
                        "file_id":file.id, "total":8, "etag":"\"guest-partial\"",
                        "source_revision":"gcid:ABCDEF", "require_content_hash":true,
                        "durable_bytes":3,
                        "prefix_sha256":hex::encode(ring::digest::digest(&ring::digest::SHA256, &fixture.content[..3]))
                    })).unwrap()).unwrap();
            }
            let received = Arc::new(AtomicU64::new(0));
            let download = async {
                if shared {
                    let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
                    download_share_file(&share, &file, directory.path(), false, false, received.clone()).await
                } else {
                    download_file(&client, &file, directory.path(), false, false, received.clone()).await
                }
            };
            tokio::time::timeout(Duration::from_secs(5), download).await
                .expect("Malformed Guest ranges must fall back in the same download run")
                .unwrap();
            assert_eq!(std::fs::read(directory.path().join(&file.name)).unwrap(), *fixture.content);
            assert_eq!(received.load(Ordering::Relaxed), if resumed { 5 } else { 8 });
            let requests = fixture.requests.lock().unwrap();
            assert_eq!(requests.iter().filter(|r| r.starts_with("GET /guest-body ")).count(), 2,
                "One refreshed Guest attempt is enough before using User");
            assert_eq!(requests.iter().filter(|r| r.starts_with("GET /user-body ")).count(), 1);
            if resumed {
                assert!(requests.iter().find(|r| r.starts_with("GET /user-body ")).unwrap()
                    .contains("range: bytes=3-\r\n"), "The verified prefix must survive Guest rejection");
            }
        }
    }
}

#[tokio::test]
async fn oversized_guest_original_switches_to_user_and_preserves_a_verified_resume_prefix() {
    for shared in [false, true] {
        for resumed in [false, true] {
            let fixture = guest_fixture::PartialFixture::new(8, 8, guest_fixture::PartialReply::ShortBody).await;
            fixture.config.lock().unwrap().guest_oversized_body = true;
            let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
            let file: FileInfo = serde_json::from_value(if shared {
                fixture.original.lock().unwrap().clone()
            } else { fixture.saved.lock().unwrap().clone() }).unwrap();
            let directory = tempfile::tempdir().unwrap();
            if resumed {
                std::fs::write(directory.path().join(format!("{}.part", file.name)), &fixture.content[..3]).unwrap();
                std::fs::write(directory.path().join(format!("{}.part.resume.json", file.name)),
                    serde_json::to_vec(&serde_json::json!({
                        "file_id":file.id, "total":8, "etag":"\"guest-partial\"",
                        "source_revision":"gcid:ABCDEF", "require_content_hash":true, "durable_bytes":3,
                        "prefix_sha256":hex::encode(ring::digest::digest(&ring::digest::SHA256, &fixture.content[..3]))
                    })).unwrap()).unwrap();
            }
            let received = Arc::new(AtomicU64::new(0));
            let download = async {
                if shared {
                    let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
                    download_share_file(&share, &file, directory.path(), false, false, received.clone()).await
                } else {
                    download_file(&client, &file, directory.path(), false, false, received.clone()).await
                }
            };
            tokio::time::timeout(Duration::from_secs(5), download).await
                .expect("Oversized Guest bodies must switch routes instead of looping").unwrap();
            assert_eq!(std::fs::read(directory.path().join(&file.name)).unwrap(), *fixture.content);
            assert_eq!(received.load(Ordering::Relaxed), if resumed { 5 } else { 8 });
            let requests = fixture.requests.lock().unwrap();
            assert_eq!(requests.iter().filter(|r| r.starts_with("GET /guest-body ")).count(), 1);
            assert_eq!(requests.iter().filter(|r| r.starts_with("GET /user-body ")).count(), 1);
            if resumed {
                assert!(requests.iter().find(|r| r.starts_with("GET /user-body ")).unwrap()
                    .contains("range: bytes=3-\r\n"));
            }
        }
    }
}

#[tokio::test]
async fn oversized_user_original_is_reported_as_a_bounded_failure_without_redownloading() {
    for shared in [false, true] {
        let fixture = guest_fixture::PartialFixture::new(8, 8, guest_fixture::PartialReply::ShortBody).await;
        {
            let mut config = fixture.config.lock().unwrap();
            config.guest_oversized_body = true;
            config.user_oversized_body = true;
        }
        let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(if shared {
            fixture.original.lock().unwrap().clone()
        } else { fixture.saved.lock().unwrap().clone() }).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let received = Arc::new(AtomicU64::new(0));
        for _ in 0..3 {
            let error = if shared {
                let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
                download_share_file(&share, &file, directory.path(), false, false, received.clone()).await.unwrap_err()
            } else {
                download_file(&client, &file, directory.path(), false, false, received.clone()).await.unwrap_err()
            };
            assert!(error.is::<pikpak::download_policy::OriginalSizeMismatch>());
            assert_eq!(pikpak::download_policy::permanent_failure(&error), Some(pikpak::download_policy::ORIGINAL_SIZE_MISMATCH));
            assert!(!pikpak::download_policy::retryable(&error));
        }
        assert_eq!(received.load(Ordering::Relaxed), 0, "Repeated invalid headers must not repeat body downloads");
        assert!(!directory.path().join(&file.name).exists());
        let requests = fixture.requests.lock().unwrap();
        assert_eq!(requests.iter().filter(|r| r.starts_with("GET /guest-body ")).count(), 3);
        assert_eq!(requests.iter().filter(|r| r.starts_with("GET /user-body ")).count(), 3);
    }
}

fn assert_only_user_suffix(fixture: &guest_fixture::PartialFixture, start: usize) {
    let requests = fixture.requests.lock().unwrap();
    let user_bodies: Vec<_> = requests
        .iter()
        .filter(|r| r.starts_with("GET /user-body "))
        .collect();
    assert_eq!(
        user_bodies.len(),
        1,
        "the User route should fetch only the unavailable suffix: {user_bodies:?}"
    );
    assert!(
        user_bodies[0].contains(&format!("range: bytes={start}-\r\n")),
        "{}",
        user_bodies[0]
    );
    assert!(
        !user_bodies[0].contains("if-range: \"guest-partial\""),
        "a different CDN cannot validate a Guest ETag"
    );
    for request in requests
        .iter()
        .filter(|r| r.starts_with("GET /guest-body "))
    {
        assert!(!request.to_ascii_lowercase().contains("authorization:"));
    }
}

#[tokio::test]
async fn new_download_share_keeps_guest_prefix_and_downloads_only_user_suffix() {
    let fixture = guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::CappedRange).await;
    fixture.saved.lock().unwrap()["params"] = serde_json::Value::Null;
    let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let received = Arc::new(AtomicU64::new(0));
    download_file(&client, &file, directory.path(), false, false, received.clone()).await.unwrap();
    assert_eq!(std::fs::read(directory.path().join(&file.name)).unwrap(), *fixture.content);
    assert_only_user_suffix(&fixture, 3);
    assert_eq!(received.load(Ordering::Relaxed), 8);
    let requests = fixture.requests.lock().unwrap();
    assert_eq!(requests.iter().filter(|r| r.starts_with("POST /drive/v1/share ")).count(), 1);
    assert!(requests.iter().filter(|r| r.starts_with("GET /drive/v1/share/file_info")).all(|r| r.contains("file_id=saved-id") && !r.contains("authorization:")));
}

#[tokio::test]
async fn guest_and_dynamic_publish_durable_complete_original_without_guest_body_or_user_quota() {
    use std::io::Write;
    for mode in [pikpak::ContentMode::Guest, pikpak::ContentMode::Dynamic] {
        for shared in [false, true] {
            let fixture =
                guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::CappedRange)
                    .await;
            fixture.config.lock().unwrap().user_available = false;
            let client = partial_fixture_client(&fixture, true, mode);
            let file: FileInfo = serde_json::from_value(if shared {
                fixture.original.lock().unwrap().clone()
            } else {
                fixture.saved.lock().unwrap().clone()
            })
            .unwrap();
            let directory = tempfile::tempdir().unwrap();
            let part = directory.path().join(format!("{}.part", file.name));
            let mut data = std::fs::File::create(&part).unwrap();
            data.write_all(fixture.content.as_slice()).unwrap();
            data.sync_data().unwrap();
            drop(data);
            std::fs::write(directory.path().join(format!("{}.part.resume.json", file.name)),
                serde_json::to_vec(&serde_json::json!({
                    "file_id":file.id, "total":8, "etag":"\"guest-partial\"",
                    "source_revision":"gcid:ABCDEF", "require_content_hash":true, "durable_bytes":8,
                    "prefix_sha256":hex::encode(ring::digest::digest(&ring::digest::SHA256, fixture.content.as_slice()))
                })).unwrap()).unwrap();
            let received = Arc::new(AtomicU64::new(0));
            if shared {
                let share = client
                    .share_client("https://mypikpak.com/s/public-share", "", "")
                    .unwrap();
                download_share_file(
                    &share,
                    &file,
                    directory.path(),
                    false,
                    false,
                    received.clone(),
                )
                .await
                .unwrap();
            } else {
                download_file(
                    &client,
                    &file,
                    directory.path(),
                    false,
                    false,
                    received.clone(),
                )
                .await
                .unwrap();
            }
            assert_eq!(
                std::fs::read(directory.path().join(&file.name)).unwrap(),
                fixture.content.as_slice()
            );
            assert_eq!(received.load(Ordering::Relaxed), 0);
            assert!(!part.exists());
            let requests = fixture.requests.lock().unwrap();
            assert!(!requests
                .iter()
                .any(|request| request.starts_with("GET /guest-body ")
                    || request.starts_with("GET /user-body ")
                    || request.starts_with("GET /drive/v1/files/saved-id")));
            assert!(requests
                .iter()
                .filter(|request| request.starts_with("GET /drive/v1/share/file_info"))
                .all(|request| !request.contains("authorization:")));
        }
    }
}

#[tokio::test]
async fn dynamic_disk_retains_guest_prefix_for_short_200_and_capped_206_with_pat_or_login() {
    for reply in [
        guest_fixture::PartialReply::ShortBody,
        guest_fixture::PartialReply::CappedRange,
    ] {
        for pat in [false, true] {
            let fixture = guest_fixture::PartialFixture::new(8, 3, reply).await;
            let client = partial_fixture_client(&fixture, pat, pikpak::ContentMode::Dynamic);
            let file: FileInfo =
                serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
            let directory = tempfile::tempdir().unwrap();
            download_file(
                &client,
                &file,
                directory.path(),
                false,
                false,
                Arc::new(AtomicU64::new(0)),
            )
            .await
            .unwrap();
            assert_eq!(
                std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
                fixture.content.as_slice()
            );
            assert_only_user_suffix(&fixture, 3);
            assert_eq!(client.content_mode(), pikpak::ContentMode::Dynamic);
            if pat {
                assert!(!fixture
                    .requests
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|r| r.starts_with("POST /v1/auth/token")));
            }
        }
    }
}

#[tokio::test]
async fn dynamic_public_share_retains_guest_prefix_with_same_gcid_and_different_cdn_etags() {
    for reply in [
        guest_fixture::PartialReply::ShortBody,
        guest_fixture::PartialReply::CappedRange,
    ] {
        let fixture = guest_fixture::PartialFixture::new(8, 3, reply).await;
        let client = partial_fixture_client(&fixture, false, pikpak::ContentMode::Dynamic);
        let share = client
            .share_client("https://mypikpak.com/s/public-share", "", "")
            .unwrap();
        let file: FileInfo =
            serde_json::from_value(fixture.original.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_share_file(
            &share,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0)),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("original-name.bin")).unwrap(),
            fixture.content.as_slice()
        );
        assert_only_user_suffix(&fixture, 3);
        assert!(fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /drive/v1/share/file_info"))
            .all(|r| r.contains("file_id=source-id")));
    }
}

#[tokio::test]
async fn dynamic_disk_same_gcid_resumes_without_server_etags() {
    let fixture =
        guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::ShortBody).await;
    {
        let mut cfg = fixture.config.lock().unwrap();
        cfg.guest_etag = None;
        cfg.user_etag = None;
    }
    let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        fixture.content.as_slice()
    );
    assert_only_user_suffix(&fixture, 3);
}

#[tokio::test]
async fn dynamic_disk_changed_or_missing_gcid_never_blindly_splices_guest_bytes() {
    for user_hash in [Some("FEDCBA".to_string()), None] {
        let fixture =
            guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::CappedRange)
                .await;
        {
            let mut cfg = fixture.config.lock().unwrap();
            cfg.user_hash = user_hash;
            cfg.user_byte = Some(255);
        }
        let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_file(
            &client,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0)),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
            vec![255; 8]
        );
        let requests = fixture.requests.lock().unwrap();
        let user_body = requests
            .iter()
            .find(|r| r.starts_with("GET /user-body "))
            .unwrap();
        assert!(
            !user_body.to_ascii_lowercase().contains("range:"),
            "unverified Guest bytes must not be retained: {user_body}"
        );
    }
}

#[tokio::test]
async fn dynamic_public_share_changed_gcid_never_splices_guest_prefix_into_user_content() {
    let fixture =
        guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::ShortBody).await;
    {
        let mut cfg = fixture.config.lock().unwrap();
        cfg.user_hash = Some("FEDCBA".into());
        cfg.user_byte = Some(255);
    }
    let client = partial_fixture_client(&fixture, false, pikpak::ContentMode::Dynamic);
    let share = client
        .share_client("https://mypikpak.com/s/public-share", "", "")
        .unwrap();
    let file: FileInfo = serde_json::from_value(fixture.original.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_share_file(
        &share,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("original-name.bin")).unwrap(),
        vec![255; 8]
    );
    let requests = fixture.requests.lock().unwrap();
    let user_body = requests
        .iter()
        .find(|r| r.starts_with("GET /user-body "))
        .unwrap();
    assert!(!user_body.to_ascii_lowercase().contains("range:"));
}

#[tokio::test]
async fn guest_only_disk_partial_access_never_uses_authenticated_content() {
    for reply in [
        guest_fixture::PartialReply::ShortBody,
        guest_fixture::PartialReply::CappedRange,
    ] {
        let fixture = guest_fixture::PartialFixture::new(8, 3, reply).await;
        let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Guest);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        assert!(download_file(
            &client,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0))
        )
        .await
        .is_err());
        assert!(!directory.path().join("saved-name.bin").exists());
        let requests = fixture.requests.lock().unwrap();
        assert!(!requests
            .iter()
            .any(|r| r.starts_with("GET /user-body ")
                || r.starts_with("GET /drive/v1/files/saved-id")));
    }
}

#[tokio::test]
async fn dynamic_disk_retains_interrupted_guest_prefix_when_later_range_is_denied_or_416() {
    for end_status in [403, 416] {
        let fixture =
            guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::InterruptedBody)
                .await;
        fixture.config.lock().unwrap().guest_end_status = end_status;
        let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_file(
            &client,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0)),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
            fixture.content.as_slice()
        );
        assert_only_user_suffix(&fixture, 3);
        let requests = fixture.requests.lock().unwrap();
        assert!(requests
            .iter()
            .filter(|r| r.starts_with("GET /guest-body "))
            .any(|r| r.contains("range: bytes=3-\r\n")));
    }
}

#[tokio::test]
async fn dynamic_large_disk_keeps_completed_guest_ranges_after_user_cdn_switch() {
    let total = 64 * 1024 * 1024;
    let prefix = 16 * 1024 * 1024;
    let fixture =
        guest_fixture::PartialFixture::new(total, prefix, guest_fixture::PartialReply::CappedRange)
            .await;
    let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        fixture.content.as_slice()
    );
    let requests = fixture.requests.lock().unwrap();
    let user_bodies: Vec<_> = requests
        .iter()
        .filter(|r| r.starts_with("GET /user-body "))
        .collect();
    assert!(
        user_bodies.len() >= 2,
        "the large file should use parallel ranges"
    );
    let mut user_data_ranges = 0;
    for request in user_bodies {
        let range = request
            .lines()
            .find_map(|line| line.strip_prefix("range: bytes="))
            .expect("large User continuation must use ranges");
        if range == "0-0" {
            continue;
        } // Discover the User CDN's own validator.
        let (start, _) = range.split_once('-').unwrap();
        assert!(
            start.parse::<usize>().unwrap() >= prefix,
            "already completed Guest data was requested again: {request}"
        );
        assert!(request.contains("if-range: \"user-partial\""));
        user_data_ranges += 1;
    }
    assert!(user_data_ranges > 0);
}

#[tokio::test]
async fn dynamic_disk_temporary_guest_congestion_retries_without_user_handoff() {
    for status in [429, 503] {
        let fixture =
            guest_fixture::PartialFixture::new(8, 8, guest_fixture::PartialReply::ShortBody).await;
        fixture.config.lock().unwrap().guest_next_error = Some(status);
        let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_file(
            &client,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0)),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
            fixture.content.as_slice()
        );
        let requests = fixture.requests.lock().unwrap();
        assert!(
            !requests.iter().any(|r| r.starts_with("GET /user-body ")
                || r.starts_with("GET /drive/v1/files/saved-id")),
            "temporary Guest errors should retain the Guest route"
        );
        assert_eq!(
            requests
                .iter()
                .filter(|r| r.starts_with("GET /guest-body "))
                .count(),
            2
        );
    }
}

#[tokio::test]
async fn dynamic_disk_partial_success_tries_remaining_guest_range_before_user_quota() {
    for reply in [
        guest_fixture::PartialReply::ShortBody,
        guest_fixture::PartialReply::CappedRange,
    ] {
        let fixture = guest_fixture::PartialFixture::new(8, 3, reply).await;
        fixture.config.lock().unwrap().guest_ranges_complete = true;
        let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
        let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_file(
            &client,
            &file,
            directory.path(),
            false,
            false,
            Arc::new(AtomicU64::new(0)),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
            fixture.content.as_slice()
        );
        let requests = fixture.requests.lock().unwrap();
        assert!(!requests.iter().any(|r| r.starts_with("GET /user-body ") || r.starts_with("GET /drive/v1/files/saved-id")), "a valid partial Guest response does not imply the remaining bytes require account quota");
        let guest_bodies: Vec<_> = requests
            .iter()
            .filter(|r| r.starts_with("GET /guest-body "))
            .collect();
        assert_eq!(guest_bodies.len(), 2);
        assert!(guest_bodies[1].contains("range: bytes=3-\r\n"));
    }
}

#[tokio::test]
async fn dynamic_disk_transient_unqualified_416_refreshes_guest_before_user_quota() {
    let fixture =
        guest_fixture::PartialFixture::new(8, 8, guest_fixture::PartialReply::ShortBody).await;
    fixture.config.lock().unwrap().guest_next_error = Some(416);
    let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0))
    )
    .await
    .unwrap();
    let requests = fixture.requests.lock().unwrap();
    assert!(
        !requests
            .iter()
            .any(|r| r.starts_with("GET /user-body ")
                || r.starts_with("GET /drive/v1/files/saved-id")),
        "a refreshed Guest link that works must not consume User quota"
    );
    assert_eq!(std::fs::read(directory.path().join("saved-name.bin")).unwrap(), fixture.content.as_slice());
}

#[tokio::test]
async fn dynamic_disk_and_share_missing_416_boundary_use_only_user_suffix() {
    for shared in [false, true] {
        let fixture = guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::ShortBody).await;
        fixture.config.lock().unwrap().guest_omit_unsatisfied_range = true;
        let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
        let directory = tempfile::tempdir().unwrap();
        let name = if shared {
            let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
            let file: FileInfo = serde_json::from_value(fixture.original.lock().unwrap().clone()).unwrap();
            download_share_file(&share, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
            "original-name.bin"
        } else {
            let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
            download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
            "saved-name.bin"
        };
        assert_eq!(std::fs::read(directory.path().join(name)).unwrap(), fixture.content.as_slice());
        assert_only_user_suffix(&fixture, 3);
        let requests = fixture.requests.lock().unwrap();
        let guest_suffixes = requests.iter().filter(|request| request.starts_with("GET /guest-body ") && request.contains("range: bytes=3-\r\n")).count();
        assert_eq!(guest_suffixes, 2, "Guest must refresh once before handing off its refused suffix");
    }
}

#[tokio::test]
async fn dynamic_parallel_416_without_boundary_still_retrieves_guest_prefix() {
    let total = 64 * 1024 * 1024;
    let prefix = 16 * 1024 * 1024;
    let fixture = guest_fixture::PartialFixture::new(total, prefix, guest_fixture::PartialReply::CappedRange).await;
    {
        let mut config = fixture.config.lock().unwrap();
        config.guest_omit_unsatisfied_range = true;
        config.guest_first_bounded_error = Some(416);
    }
    let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
    assert_eq!(std::fs::read(directory.path().join("saved-name.bin")).unwrap(), fixture.content.as_slice());
    let requests = fixture.requests.lock().unwrap();
    let mut user_ranges: Vec<_> = requests.iter().filter(|request| request.starts_with("GET /user-body "))
        .filter_map(|request| request.lines().find_map(|line| line.strip_prefix("range: bytes=")))
        .filter(|range| *range != "0-0") // The CDN validator probe is one byte.
        .map(|range| {
            let (start, end) = range.split_once('-').unwrap();
            (start.parse::<usize>().unwrap(), end.parse::<usize>().unwrap())
        }).collect();
    user_ranges.sort_unstable();
    assert_eq!(user_ranges, vec![(prefix, 2 * prefix - 1), (2 * prefix, 3 * prefix - 1), (3 * prefix, total - 1)],
        "User data requests must cover only the missing suffix, with no Guest-prefix replay");
}

#[tokio::test]
async fn dynamic_public_share_without_gcid_uses_guest_etag_for_servable_suffix() {
    let fixture =
        guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::CappedRange).await;
    fixture.original.lock().unwrap()["hash"] = serde_json::Value::Null;
    {
        let mut cfg = fixture.config.lock().unwrap();
        cfg.guest_ranges_complete = true;
        cfg.user_hash = None;
    }
    let client = partial_fixture_client(&fixture, false, pikpak::ContentMode::Dynamic);
    let share = client
        .share_client("https://mypikpak.com/s/public-share", "", "")
        .unwrap();
    let file: FileInfo = serde_json::from_value(fixture.original.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_share_file(
        &share,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("original-name.bin")).unwrap(),
        fixture.content.as_slice()
    );
    let requests = fixture.requests.lock().unwrap();
    assert!(
        !requests.iter().any(|r| r.starts_with("GET /user-body ")),
        "a strong Guest ETag can validate same-route continuation without consuming User quota"
    );
    let guest_bodies: Vec<_> = requests
        .iter()
        .filter(|r| r.starts_with("GET /guest-body "))
        .collect();
    assert_eq!(guest_bodies.len(), 2);
    assert!(guest_bodies[1].contains("range: bytes=3-\r\n"));
    assert!(guest_bodies[1].contains("if-range: \"guest-partial\""));
}

#[tokio::test]
async fn dynamic_large_disk_keeps_guest_prefix_when_user_cdn_has_no_etag() {
    let total = 64 * 1024 * 1024;
    let prefix = 16 * 1024 * 1024;
    let fixture =
        guest_fixture::PartialFixture::new(total, prefix, guest_fixture::PartialReply::CappedRange)
            .await;
    fixture.config.lock().unwrap().user_etag = None;
    let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        fixture.content.as_slice()
    );
    let requests = fixture.requests.lock().unwrap();
    let user_bodies: Vec<_> = requests
        .iter()
        .filter(|r| r.starts_with("GET /user-body "))
        .collect();
    assert_eq!(
        user_bodies.len(),
        2,
        "one validator probe followed by the missing suffix"
    );
    assert!(user_bodies[0].contains("range: bytes=0-0\r\n"));
    assert!(user_bodies[1].contains(&format!("range: bytes={prefix}-\r\n")));
    assert!(!user_bodies[1].contains("if-range:"));
}

#[tokio::test]
async fn dynamic_disk_parallel_denial_before_any_bytes_still_collects_guest_prefix() {
    let total = 64 * 1024 * 1024;
    let prefix = 3;
    let fixture =
        guest_fixture::PartialFixture::new(total, prefix, guest_fixture::PartialReply::CappedRange)
            .await;
    fixture.config.lock().unwrap().guest_first_bounded_error = Some(403);
    let client = partial_fixture_client(&fixture, true, pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(
        &client,
        &file,
        directory.path(),
        false,
        false,
        Arc::new(AtomicU64::new(0)),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        fixture.content.as_slice()
    );
    let requests = fixture.requests.lock().unwrap();
    assert!(
        requests
            .iter()
            .filter(|r| r.starts_with("GET /guest-body "))
            .any(|r| !r.to_ascii_lowercase().contains("range:")),
        "the denied initial parallel range should get one sequential Guest attempt"
    );
    let user_bodies: Vec<_> = requests
        .iter()
        .filter(|r| r.starts_with("GET /user-body "))
        .collect();
    let mut suffix_seen = false;
    for request in user_bodies {
        let range = request
            .lines()
            .find_map(|line| line.strip_prefix("range: bytes="))
            .expect("User continuation should use ranges");
        if range == "0-0" {
            continue;
        }
        let (start, _) = range.split_once('-').unwrap();
        let start = start.parse::<usize>().unwrap();
        assert!(
            start >= prefix,
            "the User route downloaded the available Guest prefix: {request}"
        );
        suffix_seen |= start == prefix;
    }
    assert!(suffix_seen);
}

#[tokio::test]
async fn dynamic_disk_metadata_rename_keeps_planned_destination_and_guest_prefix() {
    for shared in [false, true] {
        let fixture =
            guest_fixture::PartialFixture::new(8, 3, guest_fixture::PartialReply::ShortBody).await;
        fixture.config.lock().unwrap().user_name = Some("renamed-by-server.bin".into());
        let client = partial_fixture_client(&fixture, false, pikpak::ContentMode::Dynamic);
        let metadata = if shared {
            fixture.original.lock().unwrap().clone()
        } else {
            fixture.saved.lock().unwrap().clone()
        };
        let file: FileInfo = serde_json::from_value(metadata).unwrap();
        let directory = tempfile::tempdir().unwrap();
        if shared {
            let share = client
                .share_client("https://mypikpak.com/s/public-share", "", "")
                .unwrap();
            download_share_file(
                &share,
                &file,
                directory.path(),
                false,
                false,
                Arc::new(AtomicU64::new(0)),
            )
            .await
            .unwrap();
        } else {
            download_file(
                &client,
                &file,
                directory.path(),
                false,
                false,
                Arc::new(AtomicU64::new(0)),
            )
            .await
            .unwrap();
        }
        assert_eq!(
            std::fs::read(directory.path().join(&file.name)).unwrap(),
            fixture.content.as_slice()
        );
        assert!(!directory.path().join("renamed-by-server.bin").exists());
        assert!(!directory
            .path()
            .join(format!("{}.part", file.name))
            .exists());
        assert_only_user_suffix(&fixture, 3);
    }
}

/// The real PikPak answer for a file that is in the recycle bin.
const RECYCLED: &str = r#"{"error":"file_in_recycle_bin", "error_code":9, "error_url":"", "error_description":"File or folder is already in recycler", "details":[]}"#;

#[tokio::test]
async fn a_file_already_in_pikpaks_recycle_bin_is_skipped_because_only_a_finished_download_puts_it_there() {
    let fixture = guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    fixture.saved.lock().unwrap()["trashed"] = true.into();
    let client = Client::builder().personal_access_token("account-access")
        .device_id("fixture-device").api_base_url(&fixture.base).auth_base_url(&fixture.base)
        .build().unwrap();
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let output = directory.path().join("saved-name.bin");
    let received = Arc::new(AtomicU64::new(0));

    // Not downloaded here, but not an error either: nothing is created and nothing is fetched.
    download_file(&client, &file, directory.path(), false, false, received.clone()).await
        .expect("a file in the recycle bin is skipped, not reported as an interrupted download");
    assert!(!output.exists() && received.load(Ordering::Relaxed) == 0);
    assert!(!fixture.requests.lock().unwrap().iter().any(|request| request.starts_with("GET /user-body/") || request.starts_with("GET /guest-body/")));

    // A copy that was completed earlier is left exactly as it is.
    std::fs::write(&output, b"abcdefgh").unwrap();
    download_file(&client, &file, directory.path(), false, false, received.clone()).await.unwrap();
    assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
    assert_eq!(received.load(Ordering::Relaxed), 0);

    // Only this one answer is skipped: any other refusal is still a failure.
    fixture.saved.lock().unwrap()["trashed"] = false.into();
    fixture.user_available.store(false, Ordering::SeqCst);
    std::fs::remove_file(&output).unwrap();
    assert!(download_file(&client, &file, directory.path(), false, false, received.clone()).await.is_err(), "{RECYCLED}");
}

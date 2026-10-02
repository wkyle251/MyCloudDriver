use super::*;

#[tokio::test]
async fn personal_access_token_disk_download_dynamic_fallback_keeps_pat_and_guest_separate() {
    let fixture = guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    fixture.guest_denied.store(true, Ordering::SeqCst);
    let client = Client::builder().personal_access_token("account-access").device_id("pat-device")
        .api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap().with_content_mode(pikpak::ContentMode::Dynamic);
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
    assert_eq!(std::fs::read(directory.path().join("saved-name.bin")).unwrap(), b"abcdefgh");
    let requests = fixture.requests.lock().unwrap();
    assert!(!requests.iter().any(|r| r.starts_with("POST /v1/auth/token")));
    assert!(requests.iter().any(|r| r.starts_with("GET /guest-body/")));
    assert!(requests.iter().any(|r| r.starts_with("GET /user-body/")));
    assert!(requests.iter().filter(|r| r.contains("authorization:")).all(|r| r.contains("authorization: Bearer account-access") && !r.contains("x-captcha-token:")));
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
    assert_eq!(load_personal_access_token(token.to_str().unwrap()).unwrap(), "fixture-personal-token");
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
        if missing_url { fixture.original.lock().unwrap()["web_content_link"] = serde_json::Value::Null; }
        let client = Client::builder().refresh_token("account-refresh").device_id("account-device")
            .api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap().with_content_mode(pikpak::ContentMode::Dynamic);
        let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
        let file: FileInfo = serde_json::from_value(fixture.original.lock().unwrap().clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        download_share_file(&share, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
        assert_eq!(std::fs::read(directory.path().join("original-name.bin")).unwrap(), b"abcdefgh");
        let requests = fixture.requests.lock().unwrap();
        assert!(requests.iter().any(|r| r.starts_with("GET /user-body/")));
        assert!(requests.iter().filter(|r| r.starts_with("GET /drive/v1/share/file_info")).all(|r| r.contains("file_id=source-id")));
    }
}

#[tokio::test]
async fn content_mode_disk_downloads_fallback_per_file_for_missing_share_and_denied_body() {
    for mode in [pikpak::ContentMode::User, pikpak::ContentMode::Dynamic] {
        for missing_source in [true, false] {
            let fixture = guest_fixture::Fixture::new().await;
            fixture.user_available.store(true, Ordering::SeqCst);
            if missing_source { fixture.saved.lock().unwrap()["params"] = serde_json::Value::Null; }
            else { fixture.guest_denied.store(true, Ordering::SeqCst); }
            let client = Client::builder().refresh_token("account-refresh").device_id("account-device")
                .api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap().with_content_mode(mode);
            let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
            let directory = tempfile::tempdir().unwrap();
            download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0))).await.unwrap();
            assert_eq!(std::fs::read(directory.path().join("saved-name.bin")).unwrap(), b"abcdefgh");
            assert_eq!(client.content_mode(), mode, "fallback must not change another file's mode");
            let requests = fixture.requests.lock().unwrap();
            assert!(requests.iter().any(|r| r.starts_with("GET /user-body/")));
            assert_eq!(requests.iter().filter(|r| r.starts_with("GET /guest-body/")).count(),
                       usize::from(mode == pikpak::ContentMode::Dynamic && !missing_source));
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

//! Real filesystem and loopback downloads for remote names near/beyond the
//! component limit, including metadata written only when publication finishes.
use crate::*;

fn overlong_signed_name() -> String {
    format!(
        "{}?Expires=1711123246&Signature={}&uid=174475&from=loft",
        "GeneratedOpaqueDownloadName".repeat(9),
        "generated-signature".repeat(3)
    )
}

#[tokio::test]
async fn long_download_name_completes_from_account_and_share_and_reuses_receipt() {
    // The first resembles the reported URL-shaped name. The second fits by
    // itself and as a .part, but its publication metadata exceeds NAME_MAX.
    // Multibyte names also exceed macOS's character limit, not just byte size.
    for name in [
        overlong_signed_name(),
        format!("{}.mp4", "a".repeat(246)),
        format!("{}.mp4", "測試😀é".repeat(80)),
    ] {
        for shared in [false, true] {
            for mode in [
                pikpak::ContentMode::User,
                pikpak::ContentMode::Guest,
                pikpak::ContentMode::Dynamic,
            ] {
                let fixture = guest_fixture::Fixture::new().await;
                fixture.user_available.store(true, Ordering::SeqCst);
                fixture.saved.lock().unwrap()["name"] = serde_json::json!(name);
                fixture.original.lock().unwrap()["name"] = serde_json::json!(name);
                let client = Client::builder()
                    .refresh_token("account-refresh")
                    .device_id("filename-fixture")
                    .api_base_url(&fixture.base)
                    .auth_base_url(&fixture.base)
                    .build()
                    .unwrap()
                    .with_content_mode(mode);
                let metadata = if shared { &fixture.original } else { &fixture.saved };
                let file: FileInfo = serde_json::from_value(metadata.lock().unwrap().clone()).unwrap();
                let directory = tempfile::tempdir().unwrap();
                let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
                let output = directory.path().join(safe_component(&name).unwrap());
                for _ in 0..2 {
                    let received = Arc::new(AtomicU64::new(0));
                    let result = if shared {
                        download_share_file(&share, &file, directory.path(), false, false, received).await
                    } else {
                        download_file(&client, &file, directory.path(), false, false, received).await
                    };
                    result.unwrap_or_else(|error| panic!("shared={shared}, mode={mode:?}: {error:#}"));
                    assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
                }
                assert_eq!(file.name, name, "local naming must retain cloud identity");
                let body_requests = fixture.requests.lock().unwrap().iter().filter(|request| {
                    request.starts_with("GET /guest-body/") || request.starts_with("GET /user-body/")
                }).count();
                assert_eq!(body_requests, 1, "retry must reuse the completed receipt");
                let entries: Vec<_> = std::fs::read_dir(directory.path()).unwrap()
                    .map(|entry| entry.unwrap().file_name()).collect();
                assert_eq!(entries.len(), 2, "completion must remove all staging/sidecars: {entries:?}");
            }
        }
    }
}

#[tokio::test]
async fn long_download_name_resumes_existing_legacy_partial_at_the_original_path() {
    let fixture = guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    // 238 + .part + .resume.json = 255: old versions could save this
    // checkpoint; copy publication needs a longer pointer on external disks.
    let name = format!("{}.bin", "b".repeat(234));
    fixture.saved.lock().unwrap()["name"] = serde_json::json!(name);
    let client = Client::builder().refresh_token("account-refresh")
        .device_id("filename-resume-fixture").api_base_url(&fixture.base)
        .auth_base_url(&fixture.base).build().unwrap();
    let file: FileInfo = serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join(format!("{name}.part"));
    std::fs::write(&partial, b"abc").unwrap();
    let link = format!("{}/user-body/1", fixture.base);
    let source_key = hex::encode(ring::digest::digest(&ring::digest::SHA256, link.as_bytes()));
    let sha256 = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abc"));
    std::fs::write(directory.path().join(format!("{name}.part.resume.json")),
        serde_json::json!({"file_id":file.id,"total":8,"etag":"\"guest-fixture\"",
            "source_key":source_key,"source_revision":"gcid:ABCDEF",
            "durable_bytes":3,"prefix_sha256":sha256}).to_string()).unwrap();
    download_file(&client, &file, directory.path(), false, false, Arc::new(AtomicU64::new(0)))
        .await.unwrap();
    assert_eq!(std::fs::read(directory.path().join(&name)).unwrap(), b"abcdefgh");
    assert!(!partial.exists());
    let requests = fixture.requests.lock().unwrap();
    let body_requests: Vec<_> = requests.iter().filter(|r| r.starts_with("GET /user-body/")).collect();
    assert_eq!(body_requests.len(), 1);
    assert!(body_requests[0].to_ascii_lowercase().contains("range: bytes=3-\r\n"),
        "resume must request only the missing suffix");
}

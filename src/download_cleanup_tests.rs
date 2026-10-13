//! Generated originals and a loopback-only API; no real account or files.
use super::*;

fn client(fixture: &crate::guest_fixture::Fixture) -> Client {
    Client::builder()
        .refresh_token("account-refresh")
        .device_id("account-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_guest_mode(true)
}

fn file(fixture: &crate::guest_fixture::Fixture) -> FileInfo {
    serde_json::from_value(fixture.saved.lock().unwrap().clone()).unwrap()
}

async fn download(
    client: &Client,
    file: &FileInfo,
    directory: &StdPath,
    enabled: &AtomicBool,
) -> Result<()> {
    download_file_as(
        client,
        file,
        directory,
        false,
        true,
        Arc::new(AtomicU64::new(0)),
        "cleanup-fixture",
        Some(enabled),
    )
    .await
}

fn trash_requests(fixture: &crate::guest_fixture::Fixture) -> usize {
    fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter(|request| request.starts_with("POST /drive/v1/files:batchTrash "))
        .count()
}

#[tokio::test]
async fn cleanup_live_queue_uses_the_current_inbox_option() {
    for enabled in [false, true] {
        let fixture = crate::guest_fixture::Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        let directory = tempfile::tempdir().unwrap();
        let inbox = directory.path().join("inbox.json");
        std::fs::write(
            &inbox,
            serde_json::json!({
                "version":1, "content_mode":"dynamic", "delete_after_download":enabled,
                "requests":[{"id":"cleanup-request", "path":"/Saved/saved-name.bin",
                    "destination":directory.path(), "file":*fixture.saved.lock().unwrap()}]
            })
            .to_string(),
        )
        .unwrap();
        tokio::time::timeout(
            Duration::from_secs(10),
            live_downloads::run(
                &client(&fixture),
                live_downloads::Args::parse_from(["download-queue", "--request-file", inbox.to_str().unwrap()]),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
            b"abcdefgh"
        );
        assert_eq!(trash_requests(&fixture), usize::from(enabled));
    }
}

#[test]
fn cleanup_cancel_and_pause_never_remove_the_cloud_original() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "download_cleanup::tests::cleanup_controls_child",
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
    assert!(!String::from_utf8_lossy(&output.stdout).contains("file_source_trashed"));
}

#[tokio::test]
#[ignore = "isolates transfer-control environment from other test cases"]
async fn cleanup_controls_child() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    let client = client(&fixture);
    let file = file(&fixture);
    download(&client, &file, directory.path(), &AtomicBool::new(false))
        .await
        .unwrap();
    let control = directory.path().join("control.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    std::env::set_var(
        "MYCLOUDDRIVER_TRANSFER_LOCKS",
        directory.path().join("locks"),
    );
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "synthetic-cleanup-account");
    std::fs::write(
        &control,
        br#"{"actions":{"cleanup-fixture":"cancel","paused-cleanup":"pause"}}"#,
    )
    .unwrap();
    download(&client, &file, directory.path(), &AtomicBool::new(true))
        .await
        .unwrap();
    assert!(trash_verified(
        &client,
        &file,
        &directory.path().join(&file.name),
        "paused-cleanup",
        &AtomicBool::new(true)
    )
    .await
    .unwrap_err()
    .is::<transfer_control::Paused>());
    assert_eq!(
        std::fs::read(directory.path().join(&file.name)).unwrap(),
        b"abcdefgh"
    );
    assert_eq!(trash_requests(&fixture), 0);
}

#[tokio::test]
async fn cleanup_trashes_only_the_owned_file_after_verified_publication() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    download(
        &client(&fixture),
        &file(&fixture),
        directory.path(),
        &AtomicBool::new(true),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        b"abcdefgh"
    );
    assert!(!directory.path().join("saved-name.bin.part").exists());
    assert_eq!(trash_requests(&fixture), 1);
    let requests = fixture.requests.lock().unwrap();
    let body = requests
        .iter()
        .position(|r| r.starts_with("GET /user-body/") || r.starts_with("GET /guest-body/"))
        .unwrap();
    let trash = requests
        .iter()
        .position(|r| r.starts_with("POST /drive/v1/files:batchTrash "))
        .unwrap();
    assert!(body < trash);
    assert!(
        requests[trash].ends_with(r#"{"ids":["saved-id"]}"#),
        "Must not delete the shared source-id"
    );
}

#[tokio::test]
async fn cleanup_is_opt_in_and_also_handles_verified_existing_downloads() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    let client = client(&fixture);
    let file = file(&fixture);
    let enabled = AtomicBool::new(false);
    download(&client, &file, directory.path(), &enabled)
        .await
        .unwrap();
    assert_eq!(trash_requests(&fixture), 0);
    let bodies = fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.starts_with("GET /guest-body/") || r.starts_with("GET /user-body/"))
        .count();
    enabled.store(true, Ordering::SeqCst);
    download(&client, &file, directory.path(), &enabled)
        .await
        .unwrap();
    assert_eq!(trash_requests(&fixture), 1);
    assert_eq!(
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /guest-body/") || r.starts_with("GET /user-body/"))
            .count(),
        bodies
    );
}

#[tokio::test]
async fn cleanup_failure_preserves_the_successful_download() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    fixture.trash_status.store(403, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    download(
        &client(&fixture),
        &file(&fixture),
        directory.path(),
        &AtomicBool::new(true),
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("saved-name.bin")).unwrap(),
        b"abcdefgh"
    );
    assert_eq!(trash_requests(&fixture), 1);
    assert!(!fixture.gone.load(Ordering::SeqCst));
}

#[tokio::test]
async fn cleanup_keeps_changed_cloud_or_local_files_and_unverified_copies() {
    for change in ["cloud", "local", "unverified"] {
        let fixture = crate::guest_fixture::Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        let directory = tempfile::tempdir().unwrap();
        let client = client(&fixture);
        let file = file(&fixture);
        let output = directory.path().join(&file.name);
        if change == "unverified" {
            std::fs::write(&output, b"abcdefgh").unwrap();
        } else {
            download(&client, &file, directory.path(), &AtomicBool::new(false))
                .await
                .unwrap();
            if change == "cloud" {
                fixture.saved.lock().unwrap()["hash"] = serde_json::json!("CHANGED-REVISION");
            } else {
                // Replacement has a different inode even if size/mtime coincide.
                let replacement = directory.path().join("replacement.bin");
                std::fs::write(&replacement, b"changed!").unwrap();
                std::fs::rename(replacement, &output).unwrap();
            }
        }
        assert!(
            trash_verified(
                &client,
                &file,
                &output,
                "cleanup-fixture",
                &AtomicBool::new(true)
            )
            .await
            .is_err(),
            "{change}"
        );
        assert_eq!(trash_requests(&fixture), 0, "{change}");
        assert!(output.exists());
    }
}

#[tokio::test]
async fn cleanup_never_runs_for_failed_downloads_or_shared_link_originals() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    let client = client(&fixture);
    let file = file(&fixture);
    let invalid_destination = directory.path().join("not-a-directory");
    std::fs::write(&invalid_destination, b"preserve").unwrap();
    assert!(
        download(&client, &file, &invalid_destination, &AtomicBool::new(true))
            .await
            .is_err()
    );
    assert_eq!(trash_requests(&fixture), 0);
    let share = client
        .share_client("https://mypikpak.com/s/public-share", "", "")
        .unwrap();
    let original = serde_json::from_value(fixture.original.lock().unwrap().clone()).unwrap();
    download_share_file_as(
        &share,
        &original,
        directory.path(),
        false,
        true,
        Arc::new(AtomicU64::new(0)),
        "shared-cleanup-fixture",
    )
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(directory.path().join("original-name.bin")).unwrap(),
        b"abcdefgh"
    );
    assert_eq!(trash_requests(&fixture), 0);
}

#[tokio::test]
async fn a_source_already_in_the_recycle_bin_is_skipped_and_never_cleaned_up_again() {
    let fixture = crate::guest_fixture::Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    fixture.saved.lock().unwrap()["trashed"] = true.into();
    let directory = tempfile::tempdir().unwrap();
    // The account's own route, which is where PikPak refuses a link for an item in the recycle bin.
    let account = Client::builder()
        .personal_access_token("account-access")
        .device_id("fixture-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap();
    download(
        &account,
        &file(&fixture),
        directory.path(),
        &AtomicBool::new(true),
    )
    .await
    .expect("a file in the recycle bin is skipped, not an interrupted download");
    // Cleanup is for a download that just completed: it asks nothing more about the item and trashes nothing.
    assert_eq!(trash_requests(&fixture), 0);
    let requests = fixture.requests.lock().unwrap();
    let lines: Vec<&str> = requests
        .iter()
        .map(|request| request.lines().next().unwrap_or_default())
        .collect();
    assert!(
        !lines
            .iter()
            .any(|line| line.starts_with("GET /drive/v1/files/") && !line.contains("usage=FETCH")),
        "{lines:#?}"
    );
    assert!(!requests
        .iter()
        .any(|r| r.starts_with("GET /guest-body/") || r.starts_with("GET /user-body/")));
    assert!(!directory.path().join("saved-name.bin").exists());
    assert!(!directory.path().join("saved-name.bin.part").exists());
}

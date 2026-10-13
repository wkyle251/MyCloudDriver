use super::*;
use crate::{guest_fixture::Fixture, ContentMode};
use std::sync::atomic::Ordering;

fn client(fixture: &Fixture, directory: Option<&std::path::Path>) -> Client {
    let client = Client::builder()
        .personal_access_token("account-access")
        .device_id("account-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_content_mode(ContentMode::Dynamic);
    match directory {
        Some(path) => client.with_duplicate_cache_directory(path.to_owned()),
        None => client,
    }
}

fn missing_share(fixture: &Fixture) {
    fixture.saved.lock().unwrap()["params"] = Value::Null;
    fixture.user_available.store(true, Ordering::SeqCst);
}

async fn file(client: &Client) -> FileInfo {
    client.list_folder("saved-folder").await.unwrap().remove(0)
}

fn creations(fixture: &Fixture) -> usize {
    fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.starts_with("POST /drive/v1/share "))
        .count()
}

fn inventory_requests(fixture: &Fixture) -> usize {
    fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.starts_with("GET /drive/v1/share/list"))
        .count()
}

#[tokio::test]
async fn cached_links_bypass_an_unrelated_slow_inventory_in_same_and_other_helpers() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    let directory = tempfile::tempdir().unwrap();
    let original = client(&fixture, Some(directory.path()));
    let selected = file(&original).await;
    original.get_download_url_for_file(&selected).await.unwrap();
    let current = client(&fixture, Some(directory.path()));
    let other = client(&fixture, Some(directory.path()));
    let state = Arc::new(GuestState::default());
    let other_state = GuestState::default();
    let mut unrelated = selected.clone();
    unrelated.id = "synthetic-unrelated-source".into();
    fixture
        .share_inventory_delay_ms
        .store(3000, Ordering::SeqCst);
    let stalled = tokio::spawn({
        let current = current.clone();
        let state = state.clone();
        async move {
            state
                .download_share(&unrelated, &current, "synthetic")
                .await
        }
    });
    tokio::time::timeout(Duration::from_secs(2), async {
        while inventory_requests(&fixture) < 2 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    tokio::time::timeout(Duration::from_secs(1), async {
        let (a, b) = tokio::join!(
            state.download_share(&selected, &current, "synthetic"),
            other_state.download_share(&selected, &other, "synthetic")
        );
        assert_eq!(a.unwrap(), "https://mypikpak.com/s/download-share");
        assert_eq!(b.unwrap(), "https://mypikpak.com/s/download-share");
    })
    .await
    .expect("A saved link was blocked by another file's inventory or process lock");
    assert!(!stalled.is_finished());
    stalled.abort();
    let _ = stalled.await;
    assert_eq!(creations(&fixture), 1);
}

#[tokio::test]
async fn restored_uncertain_intents_share_one_complete_inventory_without_duplicate_posts() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    fixture
        .share_inventory_delay_ms
        .store(100, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    let current = client(&fixture, Some(directory.path()));
    let state = Arc::new(GuestState::default());
    let selected = file(&current).await;
    let cache = current.duplicate_cache().await.unwrap();
    let mut files = Vec::new();
    for number in 0..8 {
        let mut file = selected.clone();
        file.id = format!("synthetic-uncertain-{number}");
        let identity = serde_json::to_vec(&(
            &file.id,
            file.size,
            file.hash.as_ref().unwrap().to_ascii_lowercase(),
        ))
        .unwrap();
        let key = hex::encode(ring::digest::digest(&ring::digest::SHA256, &identity));
        cache.remember_download_share(&key, None).unwrap();
        files.push(file);
    }
    let mut tasks = tokio::task::JoinSet::new();
    for file in files.clone() {
        let current = current.clone();
        let state = state.clone();
        tasks.spawn(async move { state.download_share(&file, &current, "synthetic").await });
    }
    while let Some(result) = tasks.join_next().await {
        assert!(matches!(result.unwrap(), Err(Error::Guest(_))));
    }
    for file in files {
        assert!(matches!(
            state.download_share(&file, &current, "synthetic").await,
            Err(Error::Guest(_))
        ));
    }
    assert_eq!(
        inventory_requests(&fixture),
        1,
        "Old uncertain intents repeatedly rescanned the entire share inventory"
    );
    assert_eq!(
        creations(&fixture),
        0,
        "An ambiguous previous POST must never be repeated automatically"
    );
}

#[test]
fn unavailable_originals_create_verified_account_shares_and_log_recovery() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "download_share::tests::unavailable_originals_recovery_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    let logs = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        logs
    );
    for reason in [
        "expired",
        "deleted",
        "no longer available",
        "access code required",
    ] {
        assert!(
            logs.contains(&format!(
                "Share link unavailable: {reason}; creating a new share link to download."
            )),
            "{logs}"
        );
    }
    assert!(
        logs.contains("Download share ready; downloading from the share link."),
        "{logs}"
    );
    assert!(
        !logs.contains("ERROR"),
        "Recovered availability must not be logged as a failed download: {logs}"
    );
}

#[tokio::test]
#[ignore = "Isolated subscriber used by the parent recovery/log test"]
async fn unavailable_originals_recovery_child() {
    // An isolated process gives callsites one stable subscriber while the
    // parent suite runs other asynchronous clients in parallel.
    tracing_subscriber::fmt()
        .with_ansi(false)
        .without_time()
        .with_env_filter("warn,pikpak::guest=info,pikpak::download_share=info")
        .with_writer(std::io::stderr)
        .init();
    for status in ["EXPIRED", "DELETED", "AUDIT_FAILED", "PASS_CODE_EMPTY"] {
        let fixture = Fixture::new().await;
        *fixture.share_status.lock().unwrap() = status.into();
        // Account downstream remains blocked: success must use the new link.
        let client = client(&fixture, None);
        let file = file(&client).await;
        let download = client.get_download_url_for_file(&file).await.unwrap();
        let bytes = client
            .download_http_client()
            .get(download.web_content_link)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        assert_eq!(bytes.as_ref(), b"abcdefgh");
        assert_eq!(
            (
                download.name.as_str(),
                download.size,
                download.source_revision.as_deref()
            ),
            ("saved-name.bin", 8, Some("gcid:ABCDEF"))
        );
        // Refreshes reuse one owned share even while the original stays expired.
        client.get_download_url_for_file(&file).await.unwrap();
        assert_eq!(creations(&fixture), 1, "{status}");
        let requests = fixture.requests.lock().unwrap();
        assert!(!requests
            .iter()
            .any(|r| r.starts_with("GET /drive/v1/files/") || r.starts_with("GET /user-body/")));
        let recovered: Vec<_> = requests
            .iter()
            .filter(|r| {
                r.starts_with("GET /drive/v1/share/file_info")
                    && r.contains("share_id=download-share")
            })
            .collect();
        assert_eq!(recovered.len(), 2);
        assert!(recovered.iter().all(|r| r.contains("file_id=saved-id")
            && !r.to_ascii_lowercase().contains("authorization:")));
    }
}

#[tokio::test]
async fn temporary_original_outages_do_not_create_shares_or_spend_account_quota() {
    for status in [429, 503] {
        let fixture = Fixture::new().await;
        fixture.guest_metadata_failures.store(1, Ordering::SeqCst);
        fixture
            .guest_metadata_failure_status
            .store(status, Ordering::SeqCst);
        let client = client(&fixture, None);
        let file = file(&client).await;
        assert!(matches!(client.get_download_url_for_file(&file).await,
            Err(Error::RetryAfter { status: actual, delay }) if actual == status as u16 && delay == Duration::from_secs(7)));
        assert_eq!(creations(&fixture), 0);
        assert!(!fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.starts_with("GET /drive/v1/files/")));
        client.get_download_url_for_file(&file).await.unwrap();
        assert_eq!(
            creations(&fixture),
            0,
            "Retry the working original after its cooldown"
        );
    }
}

#[tokio::test]
async fn downloads_create_one_public_share_and_fetch_anonymously_across_concurrent_retries() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    let client = client(&fixture, None);
    let file = file(&client).await;
    let (first, second) = tokio::join!(
        client.get_download_url_for_file(&file),
        client.get_download_url_for_file(&file)
    );
    let first = first.unwrap();
    let second = second.unwrap();
    assert_ne!(
        first.web_content_link, second.web_content_link,
        "refresh signed URLs, reuse the public link"
    );
    assert_eq!(
        (
            first.name.as_str(),
            first.size,
            first.source_revision.as_deref()
        ),
        ("saved-name.bin", 8, Some("gcid:ABCDEF"))
    );
    let bytes = client
        .download_http_client()
        .get(first.web_content_link)
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(bytes.as_ref(), b"abcdefgh");
    assert_eq!(creations(&fixture), 1);
    let requests = fixture.requests.lock().unwrap();
    let creation = requests
        .iter()
        .find(|r| r.starts_with("POST /drive/v1/share "))
        .unwrap();
    let body: Value = serde_json::from_str(creation.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(body["file_ids"], json!([file.id]));
    assert_eq!(body["share_to"], "publiclink");
    assert_eq!(body["pass_code_option"], "NOT_REQUIRED");
    assert_eq!(body["expiration_days"], -1);
    assert!(body["title"].as_str().unwrap().chars().count() <= 200);
    assert!(creation.contains("authorization: Bearer account-access"));
    assert!(!requests
        .iter()
        .any(|r| r.starts_with("GET /drive/v1/files/") || r.starts_with("GET /user-body/")));
    for request in requests.iter().filter(|r| {
        r.starts_with("GET /drive/v1/share/file_info") || r.starts_with("GET /guest-body/")
    }) {
        assert!(
            !request.to_ascii_lowercase().contains("authorization:")
                && !request.contains("account-device")
        );
        if request.starts_with("GET /drive/") {
            assert!(
                request.contains("share_id=download-share") && request.contains("file_id=saved-id")
            );
        }
    }
}

#[tokio::test]
async fn download_share_links_survive_helper_restarts_and_stay_account_scoped() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    let directory = tempfile::tempdir().unwrap();
    let first = client(&fixture, Some(directory.path()));
    let file = file(&first).await;
    first.get_download_url_for_file(&file).await.unwrap();
    fixture.owned_shares.lock().unwrap().clear();
    let second = client(&fixture, Some(directory.path()));
    assert!(second
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/guest-body/"));
    assert_eq!(creations(&fixture), 1);
    assert_eq!(
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /drive/v1/share/list"))
            .count(),
        1
    );
    let cache = first.duplicate_cache().await.unwrap();
    let other = DuplicateCache::open(directory.path(), "another-account").unwrap();
    assert_ne!(cache.path(), other.path());
    let db = rusqlite::Connection::open(cache.path()).unwrap();
    let (key, url): (String, String) = db
        .query_row(
            "SELECT source_key,share_url FROM download_shares",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(url, "https://mypikpak.com/s/download-share");
    assert_eq!(other.download_share(&key).unwrap(), None);
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(cache.path())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}

#[tokio::test]
async fn downloads_reuse_existing_owned_public_shares_without_creating_another() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    fixture.owned_shares.lock().unwrap().push(json!({"share_id":"already-owned","share_url":"https://mypikpak.com/s/already-owned","file_ids":["saved-id"],"title":"Already shared","share_status":"OK"}));
    let client = client(&fixture, None);
    let file = file(&client).await;
    assert!(client
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/guest-body/"));
    assert_eq!(creations(&fixture), 0);
}

#[tokio::test]
async fn independent_helpers_coordinate_share_creation_through_the_account_cache() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    fixture.share_creation_delay_ms.store(150, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    let first = client(&fixture, Some(directory.path()));
    let second = client(&fixture, Some(directory.path()));
    let selected = file(&first).await;
    let (a, b) = tokio::join!(
        first.get_download_url_for_file(&selected),
        second.get_download_url_for_file(&selected)
    );
    assert!(a.unwrap().web_content_link.contains("/guest-body/"));
    assert!(b.unwrap().web_content_link.contains("/guest-body/"));
    assert_eq!(
        creations(&fixture),
        1,
        "Separate helper state created two public shares"
    );
}

#[tokio::test]
async fn uncertain_share_creation_reconciles_after_restart_without_duplicate_posts() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    fixture.share_create_status.store(503, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    let first = client(&fixture, Some(directory.path()));
    let file = file(&first).await;
    assert!(first
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/user-body/"));
    let second = client(&fixture, Some(directory.path()));
    assert!(second
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/guest-body/"));
    assert_eq!(creations(&fixture), 1);
    // If the remote mutation cannot be found, automatic retries still never POST again.
    let db = rusqlite::Connection::open(first.duplicate_cache().await.unwrap().path()).unwrap();
    db.execute("UPDATE download_shares SET share_url=NULL", [])
        .unwrap();
    fixture.owned_shares.lock().unwrap().clear();
    let third = client(&fixture, Some(directory.path()));
    for _ in 0..3 {
        assert!(third
            .get_download_url_for_file(&file)
            .await
            .unwrap()
            .web_content_link
            .contains("/user-body/"));
    }
    assert_eq!(creations(&fixture), 1);
}

#[tokio::test]
async fn share_creation_cancellation_leaves_recoverable_intent() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    fixture.share_creation_delay_ms.store(500, Ordering::SeqCst);
    let directory = tempfile::tempdir().unwrap();
    let first = client(&fixture, Some(directory.path()));
    let file = file(&first).await;
    let task = tokio::spawn({
        let file = file.clone();
        async move { first.get_download_url_for_file(&file).await }
    });
    tokio::time::timeout(Duration::from_secs(2), async {
        while fixture.owned_shares.lock().unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    task.abort();
    let _ = task.await;
    let second = client(&fixture, Some(directory.path()));
    assert!(second
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/guest-body/"));
    assert_eq!(creations(&fixture), 1);
}

#[tokio::test]
async fn share_creation_throttling_preserves_cooldown_and_can_retry_safely() {
    let fixture = Fixture::new().await;
    missing_share(&fixture);
    fixture.share_create_status.store(429, Ordering::SeqCst);
    let client = client(&fixture, None);
    let file = file(&client).await;
    assert!(
        matches!(client.get_download_url_for_file(&file).await, Err(Error::RetryAfter{status:429,delay}) if delay == Duration::from_secs(7))
    );
    assert!(!fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .any(|r| r.starts_with("GET /drive/v1/files/")));
    fixture.share_create_status.store(200, Ordering::SeqCst);
    assert!(client
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/guest-body/"));
    assert_eq!(creations(&fixture), 2);
}

#[tokio::test]
async fn downloads_fall_back_for_denied_or_unconfirmed_shares_and_never_share_unverifiable_files() {
    for scenario in [
        "denied",
        "mismatched-link",
        "no-content-id",
        "incomplete-list",
    ] {
        let fixture = Fixture::new().await;
        missing_share(&fixture);
        match scenario {
            "denied" => fixture.share_create_status.store(403, Ordering::SeqCst),
            "mismatched-link" => {
                *fixture.share_create_response.lock().unwrap() = Some(
                    json!({"share_id":"expected","share_url":"https://mypikpak.com/s/different"}),
                )
            }
            "no-content-id" => fixture.saved.lock().unwrap()["hash"] = Value::Null,
            _ => *fixture.share_next_page_token.lock().unwrap() = "repeated-page".into(),
        }
        let client = client(&fixture, None);
        let file = file(&client).await;
        assert!(
            client
                .get_download_url_for_file(&file)
                .await
                .unwrap()
                .web_content_link
                .contains("/user-body/"),
            "{scenario}"
        );
        assert_eq!(
            creations(&fixture),
            usize::from(matches!(scenario, "denied" | "mismatched-link"))
        );
        assert!(!fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.starts_with("GET /guest-body/")));
    }
}

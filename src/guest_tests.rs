use super::*;
use crate::guest_fixture::Fixture;
use serde_json::json;

fn client(fixture: &Fixture) -> Client {
    Client::builder()
        .refresh_token("account-refresh")
        .device_id("account-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_guest_mode(true)
}

#[tokio::test]
async fn guest_download_preview_and_scan_verify_original_and_refresh_urls() {
    let fixture = Fixture::new().await;
    let client = client(&fixture);
    let file = client.list_folder("saved-folder").await.unwrap().remove(0);
    let first = client.get_download_url_for_file(&file).await.unwrap();
    assert_eq!(first.name, "saved-name.bin");
    assert_eq!(first.size, 8);
    let preview = client
        .get_preview_info_in_parent(&file.id, Some("saved-folder"))
        .await
        .unwrap();
    assert_eq!(preview.name, file.name);
    assert_eq!(preview.sources.len(), 1);
    assert!(preview.sources[0].is_origin && preview.thumbnail_link.is_none());
    assert_ne!(preview.content_link, first.web_content_link);
    let (scan, revision) = client
        .similarity_download_info(&file.id, "saved-folder")
        .await
        .unwrap();
    assert_eq!(revision.as_deref(), Some("ABCDEF"));
    assert_ne!(scan.web_content_link, first.web_content_link);
    assert_eq!(
        client
            .download_http_client()
            .get(&scan.web_content_link)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        b"abcdefgh"
    );
    fixture.assert_anonymous_content();
    let requests = fixture.requests.lock().unwrap();
    assert_eq!(
        requests
            .iter()
            .filter(|r| r.starts_with("POST /v1/shield/"))
            .count(),
        2,
        "account and guest have separate verification; the guest session is reused"
    );
    assert!(requests
        .iter()
        .filter(|r| r.starts_with("GET /drive/v1/files?"))
        .all(|r| r.contains("authorization: Bearer account-access")));
}

#[tokio::test]
async fn guest_fresh_metadata_works_without_listing_cache_and_detects_removal() {
    let fixture = Fixture::new().await;
    let client = client(&fixture);
    client
        .get_preview_info_in_parent("saved-id", Some("saved-folder"))
        .await
        .unwrap();
    fixture
        .gone
        .store(true, std::sync::atomic::Ordering::SeqCst);
    assert!(matches!(
        client
            .similarity_file_revision("saved-id", "saved-folder")
            .await,
        Err(Error::Api { status: 404, .. })
    ));
    fixture.assert_anonymous_content();
}

#[tokio::test]
async fn guest_rejects_changed_or_unverifiable_originals_without_fallback() {
    for (key, value) in [
        ("hash", json!("different")),
        ("hash", json!(null)),
        ("size", json!("9")),
        ("id", json!("substituted-id")),
        ("kind", json!("drive#folder")),
    ] {
        let fixture = Fixture::new().await;
        fixture.original.lock().unwrap()[key] = value;
        let error = client(&fixture)
            .get_preview_info_in_parent("saved-id", Some("saved-folder"))
            .await
            .unwrap_err();
        assert!(matches!(error, Error::Guest(_)));
        fixture.assert_anonymous_content();
        assert!(!fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.starts_with("GET /guest-body/")));
    }
}

#[tokio::test]
async fn guest_requires_valid_original_share_mapping_and_content_id() {
    for change in 0..5 {
        let fixture = Fixture::new().await;
        {
            let mut saved = fixture.saved.lock().unwrap();
            match change {
                0 => saved["params"] = json!(null),
                1 => saved["params"]["url"] = json!("https://untrusted.invalid/s/public-share"),
                2 => saved["params"]["original_share_id"] = json!("another-share"),
                3 => saved["params"]["original_file_id"] = json!(""),
                _ => saved["hash"] = json!(""),
            }
        }
        assert!(matches!(
            client(&fixture)
                .get_preview_info_in_parent("saved-id", Some("saved-folder"))
                .await,
            Err(Error::Guest(_))
        ));
        assert!(!fixture.requests.lock().unwrap().iter().any(|r| r
            .starts_with("GET /drive/v1/share/")
            || r.starts_with("GET /drive/v1/files/")));
    }
}

#[tokio::test]
async fn guest_rejects_revoked_protected_shares_and_transcodes() {
    for status in ["DELETED", "EXPIRED", "PASS_CODE_EMPTY"] {
        let fixture = Fixture::new().await;
        *fixture.share_status.lock().unwrap() = status.into();
        assert!(client(&fixture)
            .get_preview_info_in_parent("saved-id", Some("saved-folder"))
            .await
            .is_err());
        fixture.assert_anonymous_content();
    }
    let fixture = Fixture::new().await;
    fixture.original.lock().unwrap()["web_content_link"] = json!(null);
    fixture.original.lock().unwrap()["medias"] =
        json!([{"is_origin":false,"link":{"url":"https://cdn.invalid/transcode"}}]);
    assert!(matches!(
        client(&fixture)
            .get_preview_info_in_parent("saved-id", Some("saved-folder"))
            .await,
        Err(Error::Guest(_))
    ));
    fixture.assert_anonymous_content();
}

#[tokio::test]
async fn guest_mode_off_preserves_the_authenticated_route() {
    let fixture = Fixture::new().await;
    let client = client(&fixture).with_guest_mode(false);
    assert!(matches!(
        client.get_download_url("saved-id").await,
        Err(Error::Api { status: 400, .. })
    ));
    assert!(!fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .any(|r| r.starts_with("GET /drive/v1/share/")));
}

#[tokio::test]
async fn guest_uses_allowed_original_hidden_from_playback_menu() {
    let fixture = Fixture::new().await;
    fixture.original.lock().unwrap()["web_content_link"] = json!(null);
    fixture.original.lock().unwrap()["medias"] = json!([
        {"is_origin":false,"is_visible":true,"link":{"url":"https://cdn.invalid/transcode"}},
        {"is_origin":true,"is_visible":false,"need_more_quota":false,"link":{"url":format!("{}/guest-body/1", fixture.base)}}
    ]);
    let preview = client(&fixture)
        .get_preview_info_in_parent("saved-id", Some("saved-folder"))
        .await
        .unwrap();
    assert_eq!(
        preview.content_link,
        format!("{}/guest-body/1", fixture.base)
    );
    fixture.original.lock().unwrap()["medias"][1]["need_more_quota"] = json!(true);
    assert!(client(&fixture)
        .get_preview_info_in_parent("saved-id", Some("saved-folder"))
        .await
        .is_err());
    fixture.assert_anonymous_content();
}

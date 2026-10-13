use super::*;
use crate::{guest_fixture::Fixture, Client};
use serde_json::json;
use std::sync::atomic::Ordering;

fn client(fixture: &Fixture, mode: ContentMode) -> Client {
    Client::builder()
        .refresh_token("account-refresh")
        .device_id("account-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_content_mode(mode)
}

#[test]
fn content_modes_preserve_legacy_settings_and_reject_unknown_modes() {
    assert_eq!(
        ContentMode::from_settings(None, false).unwrap(),
        ContentMode::User
    );
    assert_eq!(
        ContentMode::from_settings(None, true).unwrap(),
        ContentMode::Guest
    );
    for mode in [ContentMode::User, ContentMode::Guest, ContentMode::Dynamic] {
        let json = serde_json::to_value(mode).unwrap();
        assert_eq!(
            ContentMode::from_settings(json.as_str(), true).unwrap(),
            mode
        );
    }
    assert!(ContentMode::from_settings(Some("typo"), true).is_err());
}

#[test]
fn dynamic_guest_lookup_preserves_temporary_errors_and_provider_cooldown() {
    for status in [408, 429, 500, 503] {
        let error = crate::Error::RetryAfter {
            status,
            delay: std::time::Duration::from_secs(7),
        };
        let result = ContentMode::Dynamic.guest_result::<()>(Err(error));
        assert!(
            matches!(result, Err(crate::Error::RetryAfter { status: actual, delay })
            if actual == status && delay == std::time::Duration::from_secs(7))
        );
    }
    for status in [401, 403, 404] {
        assert!(ContentMode::Dynamic
            .guest_result::<()>(Err(crate::Error::Api {
                status,
                message: "Unavailable original".into(),
            }))
            .unwrap()
            .is_none());
    }
}

#[test]
fn content_mode_fallback_recognizes_sequential_and_parallel_access_errors() {
    for status in [401, 403, 404, 416, 429, 503] {
        let failure = || crate::download_policy::HttpFailure {
            status,
            retry_after: None,
        };
        let sequential = anyhow::Error::new(failure()).context("sequential body");
        let parallel = anyhow::Error::new(crate::download_ranges::Error::Http(failure()))
            .context("parallel body");
        let denied = matches!(status, 401 | 403 | 404);
        assert_eq!(content_access_denied(&sequential), denied);
        assert_eq!(content_access_denied(&parallel), denied);
    }
    assert!(content_access_denied(
        &anyhow::Error::new(crate::download_policy::ContentUnavailable)
            .context("confirmed prefix only")
    ));
    assert!(!content_access_denied(&anyhow::Error::new(
        crate::download_policy::Interrupted
    )));
    assert!(!content_access_denied(&anyhow::Error::new(
        crate::download_policy::PartialContent
    )));
    assert!(crate::download_policy::retryable(&anyhow::Error::new(
        crate::download_policy::PartialContent
    )));
    let context = anyhow::Error::msg("truncated body").context(crate::download_policy::Interrupted);
    assert!(crate::download_policy::retryable(&context));
    assert!(!content_access_denied(&context));
}

#[test]
fn content_mode_route_handoff_requires_matching_content_hashes() {
    assert!(matching_content_revision(
        Some("gcid:ABCDEF"),
        Some("gcid:abcdef")
    ));
    for (saved, current) in [
        (None, None),
        (Some("gcid:ABCDEF"), None),
        (Some("gcid:"), Some("gcid:")),
        (Some("gcid:ABCDEF"), Some("gcid:OTHER")),
        (Some("modified:same-date"), Some("modified:same-date")),
    ] {
        assert!(!matching_content_revision(saved, current));
    }
}

#[tokio::test]
async fn content_mode_user_download_preview_and_scan_never_try_guest() {
    let fixture = Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let client = client(&fixture, ContentMode::User);
    let file = client.list_folder("saved-folder").await.unwrap().remove(0);
    assert!(client
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/user-body/"));
    assert!(client
        .get_download_url(&file.id)
        .await
        .unwrap()
        .web_content_link
        .contains("/user-body/"));
    assert!(client
        .get_preview_info_in_parent(&file.id, Some("saved-folder"))
        .await
        .unwrap()
        .content_link
        .contains("/user-body/"));
    assert!(client
        .similarity_download_info(&file.id, "saved-folder")
        .await
        .unwrap()
        .0
        .web_content_link
        .contains("/user-body/"));
    assert_eq!(
        client
            .similarity_file_revision(&file.id, "saved-folder")
            .await
            .unwrap(),
        (8, Some("ABCDEF".into()))
    );
    assert!(!fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .any(|r| r.starts_with("GET /drive/v1/share/")));
}

#[tokio::test]
async fn content_mode_dynamic_prefers_guest_for_download_preview_and_scan() {
    let fixture = Fixture::new().await;
    fixture.user_available.store(true, Ordering::SeqCst);
    let client = client(&fixture, ContentMode::Dynamic);
    let file = client.list_folder("saved-folder").await.unwrap().remove(0);
    assert!(client
        .get_download_url_for_file(&file)
        .await
        .unwrap()
        .web_content_link
        .contains("/guest-body/"));
    assert!(client
        .get_download_url(&file.id)
        .await
        .unwrap()
        .web_content_link
        .contains("/guest-body/"));
    assert!(client
        .get_preview_info_in_parent(&file.id, Some("saved-folder"))
        .await
        .unwrap()
        .content_link
        .contains("/guest-body/"));
    assert!(client
        .similarity_download_info(&file.id, "saved-folder")
        .await
        .unwrap()
        .0
        .web_content_link
        .contains("/guest-body/"));
    assert_eq!(
        client
            .similarity_file_revision(&file.id, "saved-folder")
            .await
            .unwrap()
            .0,
        8
    );
    fixture.assert_anonymous_content();
}

#[tokio::test]
async fn content_mode_dynamic_recovers_download_shares_and_uses_account_for_previews_and_scans() {
    for unavailable in [
        "missing-source",
        "changed-original",
        "no-original-url",
        "revoked",
    ] {
        let fixture = Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        match unavailable {
            "missing-source" => fixture.saved.lock().unwrap()["params"] = json!(null),
            "changed-original" => {
                fixture.original.lock().unwrap()["hash"] = json!("substituted-content")
            }
            "no-original-url" => fixture.original.lock().unwrap()["web_content_link"] = json!(null),
            _ => *fixture.share_status.lock().unwrap() = "DELETED".into(),
        }
        let client = client(&fixture, ContentMode::Dynamic);
        let file = client.list_folder("saved-folder").await.unwrap().remove(0);
        let download = client.get_download_url_for_file(&file).await.unwrap();
        assert!(download.web_content_link.contains("/guest-body/"));
        assert_eq!(
            (download.name.as_str(), download.size),
            ("saved-name.bin", 8)
        );
        assert!(client
            .get_preview_info_in_parent(&file.id, Some("saved-folder"))
            .await
            .unwrap()
            .content_link
            .contains("/user-body/"));
        let (scan, revision) = client
            .similarity_download_info(&file.id, "saved-folder")
            .await
            .unwrap();
        assert!(scan.web_content_link.contains("/user-body/"));
        assert_eq!(revision.as_deref(), Some("ABCDEF"));
        let requests = fixture.requests.lock().unwrap();
        assert_eq!(
            requests
                .iter()
                .filter(|r| r.starts_with("GET /drive/v1/files/saved-id"))
                .count(),
            2
        );
        assert_eq!(requests.iter().filter(|r| r.starts_with("POST /drive/v1/share ")).count(), 1);
        assert!(
            !requests.iter().any(|r| r.starts_with("GET /guest-body/")),
            "rejected originals must never be downloaded"
        );
    }
}

#[tokio::test]
async fn content_mode_dynamic_fallback_preserves_account_failure_and_guest_is_strict() {
    let fixture = Fixture::new().await;
    fixture.saved.lock().unwrap()["params"] = json!(null);
    let dynamic = client(&fixture, ContentMode::Dynamic);
    let error = dynamic
        .get_preview_info_in_parent("saved-id", Some("saved-folder"))
        .await
        .unwrap_err();
    assert!(matches!(error, crate::Error::Api { status: 400, .. }));
    fixture.requests.lock().unwrap().clear();
    fixture.user_available.store(true, Ordering::SeqCst);
    let guest = client(&fixture, ContentMode::Guest);
    assert!(matches!(
        guest
            .get_preview_info_in_parent("saved-id", Some("saved-folder"))
            .await,
        Err(crate::Error::Guest(_))
    ));
    assert!(!fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .any(|r| r.starts_with("GET /drive/v1/files/")));
}

#[tokio::test]
async fn content_modes_apply_to_links_with_separate_guest_and_user_sessions() {
    for mode in [ContentMode::User, ContentMode::Guest, ContentMode::Dynamic] {
        let fixture = Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        fixture.original.lock().unwrap()["web_content_link"] = json!(null);
        let share = client(&fixture, mode)
            .share_client("https://mypikpak.com/s/public-share", "", "")
            .unwrap();
        let download = share.get_download_url("source-id").await;
        let preview = share.get_preview_info("source-id").await;
        if mode == ContentMode::Guest {
            assert!(download.is_err() && preview.is_err());
        } else {
            assert!(download.unwrap().web_content_link.contains("/user-body/"));
            assert!(preview.unwrap().content_link.contains("/user-body/"));
        }
        let requests = fixture.requests.lock().unwrap();
        let shares: Vec<_> = requests
            .iter()
            .filter(|r| r.starts_with("GET /drive/v1/share/file_info"))
            .collect();
        match mode {
            ContentMode::User => assert!(shares
                .iter()
                .all(|r| r.contains("authorization: Bearer account-access"))),
            ContentMode::Guest => assert!(shares.iter().all(|r| !r.contains("authorization:"))),
            ContentMode::Dynamic => {
                assert_eq!(shares.len(), 4);
                assert!(
                    !shares[0].contains("authorization:")
                        && shares[1].contains("authorization: Bearer account-access")
                );
                assert!(
                    !shares[2].contains("authorization:")
                        && shares[3].contains("authorization: Bearer account-access")
                );
            }
        }
    }
}

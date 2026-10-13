//! Generated loopback originals exercise Guest-to-User RAM handoff.
use super::*;
use crate::guest_fixture::{PartialFixture, PartialReply};

fn client(fixture: &PartialFixture, mode: crate::ContentMode) -> Client {
    Client::builder()
        .personal_access_token("account-access")
        .device_id("synthetic-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_content_mode(mode)
}

fn item(size: usize) -> CloudItem {
    CloudItem {
        id: "saved-id".into(),
        name: "saved-name.bin".into(),
        size: size as u64,
        path: "/Saved/saved-name.bin".into(),
        is_folder: false,
        revision: Some("ABCDEF".into()),
        ancestors: vec![CloudAncestor {
            id: "saved-folder".into(),
            name: "Saved".into(),
        }],
    }
}

fn body_requests(fixture: &PartialFixture, route: &str) -> Vec<String> {
    fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter(|request| request.starts_with(&format!("GET /{route}-body ")))
        .cloned()
        .collect()
}

async fn fetch(
    fixture: &PartialFixture,
    mode: crate::ContentMode,
    budget: u64,
) -> Result<Arc<MemoryInput>> {
    let fetches = Fetches::with_memory(4, budget);
    let result = tokio::time::timeout(
        Duration::from_secs(20),
        download(
            &client(fixture, mode),
            &item(fixture.content.len()),
            &AtomicBool::new(false),
            &fetches,
            |_, _| Ok(()),
        ),
    )
    .await
    .expect("Generated RAM handoff timed out");
    if result.is_err() {
        assert_eq!(fetches.memory.used(), 0);
    }
    result
}

#[tokio::test]
async fn dynamic_ram_keeps_guest_prefix_with_different_or_missing_etags() {
    for reply in [
        PartialReply::ShortBody,
        PartialReply::CappedRange,
        PartialReply::InterruptedBody,
    ] {
        for no_etags in [false, true] {
            let fixture = PartialFixture::new(8, 3, reply).await;
            if no_etags {
                let mut config = fixture.config.lock().unwrap();
                config.guest_etag = None;
                config.user_etag = None;
            }
            let original = fetch(&fixture, crate::ContentMode::Dynamic, 16)
                .await
                .unwrap();
            assert_eq!(original.as_ref().as_ref(), fixture.content.as_slice());
            let user = body_requests(&fixture, "user");
            assert_eq!(
                user.len(),
                1,
                "The User route must retrieve only the missing suffix"
            );
            assert!(user[0].to_ascii_lowercase().contains("range: bytes=3-\r\n"));
            assert!(!user[0]
                .to_ascii_lowercase()
                .contains("if-range: \"guest-partial\""));
            assert!(!user[0].to_ascii_lowercase().contains("authorization:"));
        }
    }
}

#[tokio::test]
async fn dynamic_ram_restarts_changed_or_unidentified_user_original_even_with_same_etag() {
    for hash in [Some("DIFFERENT"), None] {
        let fixture = PartialFixture::new(8, 3, PartialReply::ShortBody).await;
        {
            let mut config = fixture.config.lock().unwrap();
            config.user_hash = hash.map(str::to_owned);
            config.user_byte = Some(90);
            config.user_etag = config.guest_etag.clone();
        }
        let original = fetch(&fixture, crate::ContentMode::Dynamic, 16)
            .await
            .unwrap();
        assert_eq!(original.as_ref().as_ref(), &[90; 8]);
        let user = body_requests(&fixture, "user");
        assert_eq!(user.len(), 1);
        assert!(
            !user[0].to_ascii_lowercase().contains("range:"),
            "An unrelated User original reused Guest bytes"
        );
    }
}

#[tokio::test]
async fn guest_ram_cap_stops_without_account_content() {
    for reply in [
        PartialReply::ShortBody,
        PartialReply::CappedRange,
        PartialReply::InterruptedBody,
    ] {
        let fixture = PartialFixture::new(8, 3, reply).await;
        assert!(fetch(&fixture, crate::ContentMode::Guest, 16)
            .await
            .is_err());
        assert!(body_requests(&fixture, "user").is_empty());
        assert!(!fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|request| request.starts_with("GET /drive/v1/files/saved-id")));
    }
}

#[tokio::test]
async fn dynamic_ram_retries_temporary_guest_failures_without_account_handoff() {
    for status in [429, 503] {
        let fixture = PartialFixture::new(8, 8, PartialReply::ShortBody).await;
        fixture.config.lock().unwrap().guest_next_error = Some(status);
        let original = fetch(&fixture, crate::ContentMode::Dynamic, 16)
            .await
            .unwrap();
        assert_eq!(original.as_ref().as_ref(), fixture.content.as_slice());
        assert_eq!(body_requests(&fixture, "guest").len(), 2);
        assert!(body_requests(&fixture, "user").is_empty());
    }
}

#[tokio::test]
async fn dynamic_ram_tries_guest_suffix_before_using_account_quota() {
    for reply in [PartialReply::ShortBody, PartialReply::CappedRange] {
        let fixture = PartialFixture::new(8, 3, reply).await;
        fixture.config.lock().unwrap().guest_ranges_complete = true;
        let original = fetch(&fixture, crate::ContentMode::Dynamic, 16)
            .await
            .unwrap();
        assert_eq!(original.as_ref().as_ref(), fixture.content.as_slice());
        let guest = body_requests(&fixture, "guest");
        assert_eq!(guest.len(), 2);
        assert!(guest[1]
            .to_ascii_lowercase()
            .contains("range: bytes=3-\r\n"));
        assert!(
            body_requests(&fixture, "user").is_empty(),
            "A short response alone spent User download quota"
        );
    }
}

#[tokio::test]
async fn dynamic_ram_does_not_treat_unqualified_416_as_guest_cap() {
    let fixture = PartialFixture::new(8, 8, PartialReply::ShortBody).await;
    fixture.config.lock().unwrap().guest_next_error = Some(416);
    assert!(fetch(&fixture, crate::ContentMode::Dynamic, 16)
        .await
        .is_err());
    assert!(body_requests(&fixture, "user").is_empty());
}

#[tokio::test]
async fn dynamic_parallel_ram_keeps_guest_coverage_when_user_etag_changes() {
    let total = download_ranges::MIN_PARALLEL_SIZE as usize;
    let prefix = (20 << 20) + 3;
    let fixture = PartialFixture::new(total, prefix, PartialReply::CappedRange).await;
    let original = fetch(&fixture, crate::ContentMode::Dynamic, 96 << 20)
        .await
        .unwrap();
    assert_eq!(original.as_ref().as_ref(), fixture.content.as_slice());
    let user = body_requests(&fixture, "user");
    let downloads: Vec<_> = user
        .iter()
        .filter(|request| {
            !request
                .to_ascii_lowercase()
                .contains("range: bytes=0-0\r\n")
        })
        .collect();
    assert!(!downloads.is_empty());
    assert!(
        downloads
            .iter()
            .all(|request| !request.to_ascii_lowercase().contains("range: bytes=0-")),
        "The User route fetched an already accepted Guest prefix"
    );
    assert!(downloads.iter().any(|request| request
        .to_ascii_lowercase()
        .contains(&format!("range: bytes={prefix}-"))));
}

#[tokio::test]
async fn dynamic_parallel_ram_collects_guest_prefix_when_later_piece_fails_first() {
    for status in [403, 416] {
        let total = download_ranges::MIN_PARALLEL_SIZE as usize;
        let fixture = PartialFixture::new(total, 3, PartialReply::ShortBody).await;
        {
            let mut config = fixture.config.lock().unwrap();
            config.guest_end_status = status;
            config.delay_first_guest_range_ms = 200;
        }
        let mut fetches = Fetches::with_memory(4, 96 << 20);
        fetches.initial_range_connections = 2;
        let original = tokio::time::timeout(
            Duration::from_secs(20),
            download(
                &client(&fixture, crate::ContentMode::Dynamic),
                &item(total),
                &AtomicBool::new(false),
                &fetches,
                |_, _| Ok(()),
            ),
        )
        .await
        .expect("Parallel denial handoff timed out")
        .unwrap();
        assert_eq!(original.as_ref().as_ref(), fixture.content.as_slice());
        assert!(
            body_requests(&fixture, "guest")
                .iter()
                .any(|request| !request.to_ascii_lowercase().contains("range:")),
            "A later denied piece prevented collecting the available Guest prefix"
        );
        let user = body_requests(&fixture, "user");
        assert_eq!(user.len(), 1);
        assert!(user[0].to_ascii_lowercase().contains("range: bytes=3-\r\n"));
        drop(original);
        assert_eq!(fetches.memory.used(), 0);
    }
}

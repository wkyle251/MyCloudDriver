use crate::{Client, ContentMode, guest_fixture::Fixture};
use std::sync::{Arc, Mutex, atomic::Ordering};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn personal_access_token_download_preview_and_scan_obey_all_three_modes() {
    for mode in [ContentMode::User, ContentMode::Guest, ContentMode::Dynamic] {
        for missing_share in [false, true] {
            let fixture = Fixture::new().await;
            fixture.user_available.store(true, Ordering::SeqCst);
            if missing_share { fixture.saved.lock().unwrap()["params"] = serde_json::Value::Null; }
            let client = Client::builder().personal_access_token("account-access").device_id("pat-device")
                .api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap().with_content_mode(mode);
            let file = client.list_folder("saved-folder").await.unwrap().remove(0);
            let download = client.get_download_url_for_file(&file).await;
            let preview = client.get_preview_info_in_parent(&file.id, Some("saved-folder")).await;
            let scan = client.similarity_download_info(&file.id, "saved-folder").await;
            if mode == ContentMode::Guest && missing_share {
                assert!(download.is_err() && preview.is_err() && scan.is_err());
            } else {
                let route = if mode == ContentMode::User || missing_share { "/user-body/" } else { "/guest-body/" };
                assert!(download.unwrap().web_content_link.contains(route));
                assert!(preview.unwrap().content_link.contains(route));
                let url = scan.unwrap().0.web_content_link;
                assert!(url.contains(route));
                let bytes = client.download_http_client().get(url).send().await.unwrap().bytes().await.unwrap();
                assert_eq!(bytes.as_ref(), b"abcdefgh");
            }
            let requests = fixture.requests.lock().unwrap();
            assert!(!requests.iter().any(|r| r.starts_with("POST /v1/auth/token")));
            for request in requests.iter() {
                if request.contains("authorization:") {
                    assert!(request.contains("authorization: Bearer account-access"));
                    assert!(!request.contains("x-captcha-token:"));
                    assert!(!request.contains("/guest-body/") && !request.contains("/user-body/"));
                }
            }
            assert_eq!(client.tokens().current_refresh_token().await, "");
        }
    }
}

#[tokio::test]
async fn personal_access_token_share_links_keep_guest_and_account_credentials_separate() {
    for mode in [ContentMode::User, ContentMode::Guest, ContentMode::Dynamic] {
        let fixture = Fixture::new().await;
        fixture.user_available.store(true, Ordering::SeqCst);
        fixture.original.lock().unwrap()["web_content_link"] = serde_json::Value::Null;
        let client = Client::builder().personal_access_token("account-access").device_id("pat-device")
            .api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap().with_content_mode(mode);
        let share = client.share_client("https://mypikpak.com/s/public-share", "", "").unwrap();
        let result = share.get_preview_info("source-id").await;
        assert_eq!(result.is_ok(), mode != ContentMode::Guest);
        let requests = fixture.requests.lock().unwrap();
        assert!(!requests.iter().any(|r| r.starts_with("POST /v1/auth/token")));
        let authenticated: Vec<_> = requests.iter().filter(|r| r.contains("authorization:")).collect();
        assert_eq!(authenticated.len(), usize::from(mode != ContentMode::Guest));
        assert!(authenticated.iter().all(|r| r.contains("authorization: Bearer account-access") && !r.contains("x-captcha-token:")));
    }
}

async fn response_fixture(status: u16, body: &'static str) -> (String, Arc<Mutex<Vec<String>>>, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new()));
    let saved = requests.clone();
    let task = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.windows(4).any(|part| part == b"\r\n\r\n") {
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).await.unwrap();
                if count == 0 { break; }
                request.extend_from_slice(&buffer[..count]);
            }
            saved.lock().unwrap().push(String::from_utf8(request).unwrap());
            socket.write_all(format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        }
    });
    (base, requests, task)
}

#[tokio::test]
async fn personal_access_token_account_identity_comes_from_server_and_is_cached() {
    let (base, requests, task) = response_fixture(200, r#"{"sub":"pat-user","name":" Taylor ","email":"private@example.test"}"#).await;
    let client = Client::builder().personal_access_token("fixture-personal-token")
        .auth_base_url(base).build().unwrap();
    let profile = client.account_profile().await.unwrap();
    assert_eq!(profile.sub, "pat-user");
    assert_eq!(profile.name, "Taylor");
    assert_eq!(client.tokens().user_id().await.unwrap(), "pat-user");
    client.tokens().invalidate().await;
    assert_eq!(client.tokens().access_token().await.unwrap(), "fixture-personal-token");
    assert_eq!(client.tokens().current_refresh_token().await, "");
    assert!(!client.tokens().uses_shared_refresh_store());
    assert!(!format!("{:?}", client.tokens()).contains("fixture-personal-token"));
    assert!(client.tokens().confirm_user_id("other-user").await.is_err());
    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].starts_with("GET /v1/user/me "));
    assert!(!serde_json::to_string(&profile).unwrap().contains("email"));
    task.abort();
}

#[tokio::test]
async fn personal_access_token_rejection_never_refreshes_or_retries_with_oauth() {
    for status in [401, 403] {
        let (base, requests, task) = response_fixture(status, r#"{"error":"permission_denied","echo":"fixture-personal-token"}"#).await;
        let client = Client::builder().personal_access_token("fixture-personal-token")
            .auth_base_url(&base).api_base_url(&base).build().unwrap();
        let error = client.list_folder("").await.unwrap_err().to_string();
        assert!(!error.contains("fixture-personal-token"));
        assert_eq!(requests.lock().unwrap().len(), 1);
        task.abort();
    }
}

#[test]
fn personal_access_token_cannot_mix_with_refresh_credentials_or_rotation_store() {
    assert!(Client::builder().personal_access_token("pat").refresh_token("refresh").build().is_err());
    assert!(Client::builder().personal_access_token("pat").shared_refresh_token_store("unused", "unused-lock").build().is_err());
    assert!(Client::builder().personal_access_token("").build().is_err());
    assert!(Client::builder().personal_access_token("invalid\r\nheader").build().is_err());
}

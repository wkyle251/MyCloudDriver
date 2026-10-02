use super::*;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Fixture {
    base: String,
    requests: Arc<Mutex<Vec<(String, Value)>>>,
    worker: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.worker.abort();
    }
}
impl Fixture {
    async fn new(fail_mutation: bool, restored: bool) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let captured = requests.clone();
        let worker = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                let end = loop {
                    if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                        break end + 4;
                    }
                    let mut buffer = [0; 4096];
                    let n = socket.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    bytes.extend_from_slice(&buffer[..n]);
                };
                let headers = String::from_utf8_lossy(&bytes[..end]).to_string();
                let length = headers
                    .lines()
                    .find_map(|l| {
                        l.to_lowercase()
                            .strip_prefix("content-length: ")
                            .and_then(|s| s.parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                while bytes.len() < end + length {
                    let mut buffer = [0; 4096];
                    let n = socket.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&buffer[..n]);
                }
                let body = serde_json::from_slice::<Value>(&bytes[end..]).unwrap_or(Value::Null);
                captured.lock().unwrap().push((headers.clone(), body));
                let line = headers.lines().next().unwrap();
                let is_mutation = !line.starts_with("GET ");
                let (status, body) = if fail_mutation && is_mutation {
                    (503, json!({"error":"unavailable"}))
                } else if line.starts_with("POST /v1/auth/token") {
                    (
                        200,
                        json!({"access_token":"oauth-fixture", "refresh_token":"fixture-refresh", "token_type":"Bearer", "expires_in":3600, "sub":"owner"}),
                    )
                } else if line.starts_with("POST /v1/shield/captcha/init") {
                    (200, json!({"captcha_token":"captcha-fixture"}))
                } else if line.starts_with("GET /v1/user/me ") {
                    (200, json!({"sub":"owner","name":"Fixture"}))
                } else if line.starts_with("GET /drive/v1/files/item ") {
                    (
                        200,
                        json!({"id":"item","kind":"drive#file","trashed":!restored}),
                    )
                } else if line.starts_with("GET /drive/v1/files/folder ") {
                    (
                        200,
                        json!({"id":"folder","kind":"drive#folder","trashed":false}),
                    )
                } else if line.starts_with("GET /drive/v1/files?") {
                    (
                        200,
                        json!({"files":[{"id":"item","name":"Example","kind":"drive#file","size":"42","thumbnail_link":"secret-preview"}],"next_page_token":"next"}),
                    )
                } else if line.starts_with("GET /drive/v1/share/list?") {
                    (
                        200,
                        json!({"data":[{"share_id":"owned-share","title":"Example","share_url":"https://mypikpak.com/s/example","view_count":"4","restore_count":2}],"next_page_token":""}),
                    )
                } else if line.starts_with("GET /drive/v1/tasks?") {
                    (
                        200,
                        json!({"tasks":[{"id":"task","name":"Example","file_size":"32","progress":40,"params":{"url":"secret-source"}}],"next_page_token":""}),
                    )
                } else if line.starts_with("POST /drive/v1/files ") {
                    (
                        200,
                        json!({"task":{"id":"new-task","name":"Created","progress":0}}),
                    )
                } else if line.starts_with("POST /drive/v1/share ") {
                    (
                        200,
                        json!({"share_id":"new-share","share_url":"https://mypikpak.com/s/new","pass_code":"abcd"}),
                    )
                } else {
                    (200, json!({}))
                };
                let body = body.to_string();
                socket.write_all(format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
            }
        });
        Self {
            base,
            requests,
            worker,
        }
    }
    fn client(&self) -> Client {
        Client::builder()
            .personal_access_token("fixture-management-token")
            .device_id("fixture-device")
            .auth_base_url(&self.base)
            .api_base_url(&self.base)
            .build()
            .unwrap()
    }
}
fn request(action: ManagementAction) -> ManagementRequest {
    ManagementRequest {
        account_id: "owner".into(),
        action,
    }
}

#[tokio::test]
async fn management_pages_always_use_current_account_in_all_content_modes() {
    for mode in [
        crate::ContentMode::User,
        crate::ContentMode::Guest,
        crate::ContentMode::Dynamic,
    ] {
        let fixture = Fixture::new(false, false).await;
        let client = fixture.client().with_content_mode(mode);
        let trash = client
            .manage(request(ManagementAction::ListTrash {
                page_token: "page2".into(),
            }))
            .await
            .unwrap();
        assert_eq!(trash["files"][0]["size"], 42);
        assert!(!trash.to_string().contains("secret-preview"));
        let shares = client
            .manage(request(ManagementAction::ListShares {
                page_token: "".into(),
            }))
            .await
            .unwrap();
        assert_eq!(shares["shares"][0]["views"], 4);
        let tasks = client
            .manage(request(ManagementAction::ListTasks {
                page_token: "".into(),
            }))
            .await
            .unwrap();
        assert!(!tasks.to_string().contains("secret-source"));
        let requests = fixture.requests.lock().unwrap();
        assert_eq!(requests.len(), 6);
        for (headers, _) in requests.iter() {
            assert!(headers.contains("Bearer fixture-management-token"));
            assert!(!headers.contains("x-captcha-token"));
        }
        let parsed = reqwest::Url::parse(&format!(
            "{}{}",
            fixture.base,
            requests[1].0.split_whitespace().nth(1).unwrap()
        ))
        .unwrap();
        let query: std::collections::HashMap<_, _> = parsed.query_pairs().collect();
        assert_eq!(query["parent_id"], "*");
        assert_eq!(query["page_token"], "page2");
        assert_eq!(
            serde_json::from_str::<Value>(&query["filters"]).unwrap()["trashed"]["eq"],
            true
        );
    }
}

#[tokio::test]
async fn management_creates_tasks_and_shares_with_official_request_shapes() {
    let fixture = Fixture::new(false, false).await;
    let client = fixture.client();
    let task = client
        .manage(request(ManagementAction::CreateTask {
            url: "https://example.com/file".into(),
            parent_id: "folder".into(),
        }))
        .await
        .unwrap();
    assert_eq!(task["task"]["id"], "new-task");
    let share = client
        .manage(request(ManagementAction::CreateShare {
            ids: vec!["item".into()],
            title: "Example".into(),
            expiration_days: 7,
            password_protected: true,
        }))
        .await
        .unwrap();
    assert_eq!(share["share"]["title"], "Example");
    let requests = fixture.requests.lock().unwrap();
    let bodies: Vec<_> = requests
        .iter()
        .filter(|(h, _)| h.starts_with("POST "))
        .map(|(_, v)| v)
        .collect();
    assert_eq!(bodies[0]["upload_type"], "UPLOAD_TYPE_URL");
    assert_eq!(bodies[0]["parent_id"], "folder");
    assert_eq!(bodies[1]["pass_code_option"], "REQUIRED");
    assert_eq!(bodies[1]["share_to"], "encryptedlink");
    assert_eq!(bodies[1]["expiration_days"], 7);
}

#[tokio::test]
async fn management_create_is_not_repeated_after_server_failure() {
    let fixture = Fixture::new(true, false).await;
    let result = fixture
        .client()
        .manage(request(ManagementAction::CreateTask {
            url: "https://example.com/file".into(),
            parent_id: "".into(),
        }))
        .await;
    assert!(result.is_err());
    assert_eq!(
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(h, _)| h.starts_with("POST "))
            .count(),
        1
    );
}

#[tokio::test]
async fn management_rejects_cross_account_requests_before_mutation() {
    let fixture = Fixture::new(false, false).await;
    let mut input = request(ManagementAction::CreateTask {
        url: "https://example.com/file".into(),
        parent_id: "".into(),
    });
    input.account_id = "other-account".into();
    assert!(fixture.client().manage(input).await.is_err());
    assert_eq!(fixture.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn management_personal_token_cannot_delete_permanently_or_empty_trash() {
    let fixture = Fixture::new(false, false).await;
    for action in [
        ManagementAction::DeleteTrash {
            ids: vec!["item".into()],
            confirmed: true,
        },
        ManagementAction::EmptyTrash { confirmed: true },
    ] {
        assert!(fixture
            .client()
            .manage(request(action))
            .await
            .unwrap_err()
            .to_string()
            .contains("cannot permanently delete"));
    }
    assert!(fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .all(|(h, _)| h.starts_with("GET /v1/user/me ")));
}

#[tokio::test]
async fn management_oauth_permanent_delete_is_confirmed_and_preflighted() {
    let fixture = Fixture::new(false, false).await;
    let client = Client::builder()
        .refresh_token("fixture-refresh")
        .device_id("fixture-device")
        .auth_base_url(&fixture.base)
        .api_base_url(&fixture.base)
        .build()
        .unwrap();
    assert!(client
        .manage(request(ManagementAction::DeleteTrash {
            ids: vec!["item".into()],
            confirmed: false
        }))
        .await
        .is_err());
    let deleted = client
        .manage(request(ManagementAction::DeleteTrash {
            ids: vec!["item".into()],
            confirmed: true,
        }))
        .await;
    assert!(
        deleted.is_ok(),
        "{:?}: {:?}",
        deleted,
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .map(|(h, _)| h.lines().next().unwrap())
            .collect::<Vec<_>>()
    );
    client
        .manage(request(ManagementAction::EmptyTrash { confirmed: true }))
        .await
        .unwrap();
    let requests = fixture.requests.lock().unwrap();
    let deletes: Vec<_> = requests
        .iter()
        .filter(|(h, _)| h.starts_with("POST /drive/v1/files:batchDelete "))
        .collect();
    assert_eq!(deletes.len(), 1);
    assert_eq!(deletes[0].1["ids"], json!(["item"]));
    assert!(requests
        .iter()
        .any(|(h, _)| h.starts_with("GET /drive/v1/files/item ")));
    assert_eq!(
        requests
            .iter()
            .filter(|(h, _)| h.starts_with("PATCH /drive/v1/files/trash:empty "))
            .count(),
        1
    );
}

#[tokio::test]
async fn management_rechecks_trash_and_requires_confirmation_for_revocation() {
    let fixture = Fixture::new(false, true).await;
    assert!(fixture
        .client()
        .manage(request(ManagementAction::RestoreTrash {
            ids: vec!["item".into()]
        }))
        .await
        .is_err());
    assert!(fixture
        .client()
        .manage(request(ManagementAction::RemoveShares {
            ids: vec!["owned-share".into()],
            confirmed: false
        }))
        .await
        .is_err());
    assert!(fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .all(|(h, _)| h.starts_with("GET ")));
    let valid = Fixture::new(false, false).await;
    let client = valid.client();
    client
        .manage(request(ManagementAction::RestoreTrash {
            ids: vec!["item".into()],
        }))
        .await
        .unwrap();
    client
        .manage(request(ManagementAction::RemoveTask {
            id: "task".into(),
            confirmed: true,
        }))
        .await
        .unwrap();
    let requests = valid.requests.lock().unwrap();
    assert!(requests
        .iter()
        .any(|(h, _)| h.starts_with("POST /drive/v1/files:batchUntrash ")));
    assert!(
        requests
            .iter()
            .any(|(h, _)| h.starts_with("DELETE /drive/v1/tasks?")
                && h.contains("delete_files=false"))
    );
}

#[test]
fn management_credentials_only_expose_display_metadata() {
    let token = format!("e30.{}.private-signature", URL_SAFE_NO_PAD.encode(br#"{"sub":"private-identity","email":"private@example.test","scope":"files:read share account","exp":1900000000}"#));
    let metadata = credential_metadata(true, &token);
    assert_eq!(
        metadata.permissions,
        Some(vec!["files:read".into(), "share".into(), "account".into()])
    );
    assert_eq!(metadata.expires_at, Some(1900000000));
    assert!(!serde_json::to_string(&metadata)
        .unwrap()
        .contains("private"));
    assert!(!credential_metadata(true, "opaque-token").can_permanently_delete);
    assert!(credential_metadata(false, &token).expires_at.is_none());
}

#[test]
fn management_validates_input_and_fails_closed_on_unknown_lists() {
    for url in [
        "file:///private/data",
        "javascript:alert(1)",
        "https://user:pass@example.com",
        "https://example.com/a\nhttps://other.test",
        "magnet:?invalid",
    ] {
        assert!(validate_cloud_url(url).is_err(), "{url}");
    }
    assert!(validate_cloud_url("magnet:?xt=urn:btih:abcdef").is_ok());
    assert!(validate_cloud_url(" https://example.com/file ").is_ok());
    assert!(validate_ids(&["same".into(), "same".into()]).is_err());
    assert!(validate_ids(&["../file".into()]).is_err());
    assert!(page(&json!({"unknown":[]}), "data", "shares", normalize_share).is_err());
}

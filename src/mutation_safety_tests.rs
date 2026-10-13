use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

type PreparationReply = (&'static str, u16, Value);

async fn preparation_fixture(
    replies: Vec<PreparationReply>,
) -> (
    crate::Client,
    Arc<std::sync::atomic::AtomicUsize>,
    tokio::task::JoinHandle<()>,
) {
    use std::sync::atomic::{AtomicUsize, Ordering};

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let posts = Arc::new(AtomicUsize::new(0));
    let recorded = posts.clone();
    let server = tokio::spawn(async move {
        for (expected_path, status, response) in replies {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let end = loop {
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
                if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                    break end + 4;
                }
            };
            let header = String::from_utf8_lossy(&request[..end]).to_string();
            let mut route = header.lines().next().unwrap().split_whitespace();
            assert_eq!(route.next(), Some("POST"));
            let path = route.next().unwrap().split('?').next().unwrap();
            assert_eq!(path, expected_path);
            if path == "/drive/v1/files" {
                recorded.fetch_add(1, Ordering::SeqCst);
            }
            let length = header
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|size| size.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            while request.len() < end + length {
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
            }
            let body = response.to_string();
            socket.write_all(format!(
                "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len(),
            ).as_bytes()).await.unwrap();
        }
    });
    let client = crate::Client::builder()
        .refresh_token("synthetic-refresh")
        .credentials(crate::auth::OAuthCredentials::new(
            "fixture-client",
            "fixture-secret",
        ))
        .api_base_url(&base)
        .auth_base_url(&base)
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .unwrap();
    (client, posts, server)
}

fn preparation_auth_reply() -> PreparationReply {
    (
        "/v1/auth/token",
        200,
        json!({
            "access_token":"synthetic-access", "refresh_token":"synthetic-refresh-next",
            "expires_in":3600, "sub":"synthetic-account",
        }),
    )
}

fn preparation_captcha_reply() -> PreparationReply {
    (
        "/v1/shield/captcha/init",
        200,
        json!({"captcha_token":"synthetic-captcha"}),
    )
}

async fn preparation_create(client: &crate::Client, upload: bool) -> crate::Result<()> {
    if upload {
        client
            .create_upload_task(
                "destination",
                "fixture.bin",
                3,
                "0D3CED9BEC10A777AEC23CCC353A8C08A633045E",
            )
            .await?;
    } else {
        client
            .create_folder("destination", "Fixture Folder")
            .await?;
    }
    Ok(())
}

fn preparation_creation_reply(upload: bool) -> PreparationReply {
    (
        "/drive/v1/files",
        200,
        if upload {
            json!({"file":{"id":"created-upload","phase":"PHASE_TYPE_COMPLETE"}})
        } else {
            json!({"id":"created-folder"})
        },
    )
}

#[tokio::test]
async fn authentication_and_captcha_outages_before_creation_release_the_intent() {
    use std::sync::atomic::Ordering;

    for upload in [false, true] {
        for captcha_outage in [false, true] {
            let replies = if captcha_outage {
                vec![
                    preparation_auth_reply(),
                    (
                        "/v1/shield/captcha/init",
                        503,
                        json!({"error":"temporary outage"}),
                    ),
                    preparation_captcha_reply(),
                    preparation_creation_reply(upload),
                ]
            } else {
                vec![
                    ("/v1/auth/token", 503, json!({"error":"temporary outage"})),
                    preparation_auth_reply(),
                    preparation_captcha_reply(),
                    preparation_creation_reply(upload),
                ]
            };
            let (client, posts, server) = preparation_fixture(replies).await;
            let error = preparation_create(&client, upload).await.unwrap_err();
            match &error {
                crate::Error::MutationNotDispatched(source) if captcha_outage => {
                    assert!(
                        matches!(
                            source.downcast_ref::<crate::Error>(),
                            Some(crate::Error::Api { status: 503, .. })
                        ),
                        "{error}"
                    );
                }
                crate::Error::MutationNotDispatched(source) => {
                    assert!(
                        matches!(source.downcast_ref::<crate::Error>(),
                        Some(crate::Error::Auth(message)) if message.starts_with("status 503:")),
                        "{error}"
                    );
                }
                _ => panic!("preparation failure lost its dispatch classification: {error}"),
            }
            assert!(error.mutation_was_rejected());
            if captcha_outage {
                assert!(crate::download_policy::retryable(&anyhow::Error::new(
                    error
                )));
            }
            assert_eq!(
                posts.load(Ordering::SeqCst),
                0,
                "no creation was dispatched"
            );
            preparation_create(&client, upload).await.unwrap();
            assert_eq!(
                posts.load(Ordering::SeqCst),
                1,
                "recovery creates exactly once"
            );
            server.await.unwrap();
        }
    }
}

#[tokio::test]
async fn failed_preparation_after_definitive_rejection_can_retry_but_ambiguous_posts_cannot() {
    use std::sync::atomic::Ordering;

    for rejected_captcha in [false, true] {
        let mut replies = vec![preparation_auth_reply(), preparation_captcha_reply()];
        if rejected_captcha {
            replies.extend([
                ("/drive/v1/files", 403, json!({"error_code":9})),
                (
                    "/v1/shield/captcha/init",
                    503,
                    json!({"error":"temporary outage"}),
                ),
                preparation_captcha_reply(),
            ]);
        } else {
            replies.extend([
                ("/drive/v1/files", 401, json!({"error":"expired access"})),
                ("/v1/auth/token", 503, json!({"error":"temporary outage"})),
                preparation_auth_reply(),
            ]);
        }
        replies.push(preparation_creation_reply(true));
        let (client, posts, server) = preparation_fixture(replies).await;
        let error = preparation_create(&client, true).await.unwrap_err();
        assert!(
            matches!(&error, crate::Error::MutationNotDispatched(_)),
            "{error}"
        );
        assert!(error.mutation_was_rejected());
        assert_eq!(
            posts.load(Ordering::SeqCst),
            1,
            "only a definitively rejected request was sent"
        );
        preparation_create(&client, true).await.unwrap();
        assert_eq!(
            posts.load(Ordering::SeqCst),
            2,
            "one rejected and one successful request"
        );
        server.await.unwrap();
    }

    // A server error remains ambiguous even if its body mentions captcha expiry.
    // It must not trigger another creation or be relabeled as failed preparation.
    let (client, posts, server) = preparation_fixture(vec![
        preparation_auth_reply(),
        preparation_captcha_reply(),
        ("/drive/v1/files", 503, json!({"error_code":9})),
    ])
    .await;
    let error = preparation_create(&client, true).await.unwrap_err();
    assert!(
        matches!(&error, crate::Error::MutationUncertain(_)),
        "{error}"
    );
    assert!(!error.mutation_was_rejected());
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    server.await.unwrap();
}

#[tokio::test]
async fn ambiguous_creation_replies_are_never_replayed_and_shared_downloads_use_originals() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let counts = Arc::new(Mutex::new(HashMap::<String, usize>::new()));
    let recorded = counts.clone();
    let server = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let end = loop {
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).await.unwrap();
                if count == 0 {
                    break 0;
                }
                request.extend_from_slice(&buffer[..count]);
                if let Some(end) = request.windows(4).position(|b| b == b"\r\n\r\n") {
                    break end + 4;
                }
            };
            if end == 0 {
                continue;
            }
            let headers = String::from_utf8_lossy(&request[..end]);
            let route = headers.lines().next().unwrap().to_owned();
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|n| n.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            while request.len() < end + length {
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
            }
            let mut key = route
                .split_whitespace()
                .take(2)
                .collect::<Vec<_>>()
                .join(" ");
            let submitted: Value = if length > 0 {
                serde_json::from_slice(&request[end..end + length]).unwrap()
            } else {
                json!({})
            };
            if key == "POST /drive/v1/files" {
                key.push_str(&format!(
                    " {} {}",
                    submitted["kind"].as_str().unwrap(),
                    submitted["name"].as_str().unwrap()
                ));
            }
            let attempt = {
                let mut counts = recorded.lock().unwrap();
                let count = counts.entry(key.clone()).or_default();
                *count += 1;
                *count
            };
            let mut status = 200;
            let value = if key.starts_with("POST /drive/v1/files ") {
                if submitted["name"] == "Service Error Folder" {
                    status = 503;
                    json!({"error":"response unavailable"})
                } else if submitted["name"] == "Malformed Folder" {
                    json!({})
                } else {
                    // The fixture records a successful creation but loses its reply.
                    if attempt == 1 {
                        continue;
                    }
                    if submitted["kind"] == "drive#folder" {
                        json!({"id":format!("created-{attempt}")})
                    } else {
                        json!({"file":{"id":format!("upload-{attempt}"),"phase":"PHASE_TYPE_COMPLETE"}})
                    }
                }
            } else if key == "POST /drive/v1/share/restore" {
                if attempt == 1 {
                    continue;
                }
                json!({"restore_status":"RESTORE_COMPLETE","restore_task_id":format!("restore-{attempt}")})
            } else if key == "POST /decompress/v1/decompress" {
                if attempt == 1 {
                    continue;
                }
                json!({"task_id":format!("extract-{attempt}")})
            } else if route.starts_with("GET /v1/user/me ") {
                json!({"sub":"synthetic-account","name":"Fixture"})
            } else if route.starts_with("GET /drive/v1/files?") {
                json!({"files":[]})
            } else if route.starts_with("GET /drive/v1/share/file_info?") {
                json!({"share_status":"OK","file_info":{"id":"video","name":"video.mkv","kind":"drive#file","size":"1000",
                    "medias":[{"is_origin":false,"is_default":true,"link":{"url":"https://fixture.invalid/transcode.mp4"}},
                              {"is_origin":true,"link":{"url":"https://fixture.invalid/original.mkv"}}]}})
            } else {
                panic!("unexpected fixture route {key}")
            };
            let bytes = value.to_string();
            socket.write_all(format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{bytes}", bytes.len()).as_bytes()).await.unwrap();
        }
    });
    let client = crate::Client::builder()
        .personal_access_token("synthetic-pat")
        .api_base_url(&base)
        .auth_base_url(&base)
        .build()
        .unwrap();
    let folder = client
        .create_folder("", "Synthetic Folder")
        .await
        .unwrap_err();
    assert!(
        matches!(folder, crate::Error::MutationUncertain(_)),
        "{folder}"
    );
    for name in ["Service Error Folder", "Malformed Folder"] {
        let error = client.create_folder("", name).await.unwrap_err();
        assert!(
            matches!(error, crate::Error::MutationUncertain(_)),
            "{error}"
        );
    }
    let restore = client
        .restore_shared_files("synthetic-share", "", &["file-a".into()])
        .await
        .unwrap_err();
    assert!(
        matches!(restore, crate::Error::MutationUncertain(_)),
        "{restore}"
    );
    let extract = client
        .start_archive_extraction(
            "archive-a",
            "0123456789012345678901234567890123456789",
            "",
            &[json!({"index":0})],
        )
        .await
        .unwrap_err();
    assert!(
        matches!(extract, crate::Error::MutationUncertain(_)),
        "{extract}"
    );
    let upload = client
        .create_upload_task(
            "",
            "normal-upload.bin",
            3,
            "0D3CED9BEC10A777AEC23CCC353A8C08A633045E",
        )
        .await
        .unwrap_err();
    assert!(
        matches!(upload, crate::Error::MutationUncertain(_)),
        "{upload}"
    );
    let shared = client
        .share_client("https://mypikpak.com/s/synthetic-share", "", "")
        .unwrap();
    let download = shared.get_download_url("video").await.unwrap();
    assert_eq!(
        download.web_content_link,
        "https://fixture.invalid/original.mkv"
    );
    assert_eq!(download.name, "video.mkv");
    assert_eq!(download.size, 1000);
    assert!(counts
        .lock()
        .unwrap()
        .iter()
        .filter(|(key, _)| key.starts_with("POST "))
        .all(|(_, attempts)| *attempts == 1));
    server.abort();
}

//! Loopback challenge -> browser proof -> fresh helper -> accepted request.
//! Never contacts a real account or enumerates any user files.
use crate::{auth::OAuthCredentials, Client, Error};
use std::sync::{atomic::{AtomicUsize, Ordering}, Arc};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn verified_request_resumes_after_helper_restart_and_status_checks_do_not_list_files() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let inits = Arc::new(AtomicUsize::new(0));
    let file_requests = Arc::new(AtomicUsize::new(0));
    let init_count = inits.clone(); let files_count = file_requests.clone();
    let task = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let header_end = loop {
                let mut buffer = [0; 4096]; let n = socket.read(&mut buffer).await.unwrap(); assert_ne!(n, 0);
                request.extend_from_slice(&buffer[..n]);
                if let Some(end) = request.windows(4).position(|v| v == b"\r\n\r\n") { break end + 4; }
            };
            let headers = String::from_utf8_lossy(&request[..header_end]).to_lowercase();
            let length = headers.lines().find_map(|line| line.strip_prefix("content-length: "))
                .map(|v| v.parse::<usize>().unwrap()).unwrap_or(0);
            while request.len() < header_end + length {
                let mut buffer = [0; 4096]; let n = socket.read(&mut buffer).await.unwrap(); assert_ne!(n, 0);
                request.extend_from_slice(&buffer[..n]);
            }
            let body = if headers.starts_with("post /v1/auth/token") {
                serde_json::json!({"access_token":"generated-access", "refresh_token":"generated-refresh", "expires_in":3600, "sub":"generated-user"})
            } else if headers.starts_with("post /v1/shield/captcha/init") {
                init_count.fetch_add(1, Ordering::SeqCst);
                let input: serde_json::Value = serde_json::from_slice(&request[header_end..]).unwrap();
                assert_eq!(input["meta"]["timestamp"], "1790750014972");
                assert_eq!(input["meta"]["client_version"], "undefined");
                assert_eq!(input["action"], "GET:/drive/v1/files");
                assert_eq!(input["device_id"], "generated-device");
                assert!(input.get("redirect_uri").is_none(), "callback is added to the challenge URL, as in the official SDK");
                if input["captcha_token"] == "generated-proof" {
                    serde_json::json!({"captcha_token":"generated-accepted","expires_in":600})
                } else {
                    serde_json::json!({"captcha_token":"generated-pending","url":"https://user.mypikpak.com/verify?captcha_token=generated-pending", "expires_in":600})
                }
            } else {
                assert!(headers.starts_with("get /drive/v1/files?"), "only a generated folder response is allowed");
                assert!(headers.contains("x-captcha-token: generated-accepted\r\n"));
                files_count.fetch_add(1, Ordering::SeqCst);
                serde_json::json!({"files":[],"next_page_token":""})
            };
            let body = body.to_string();
            let response = format!("HTTP/1.1 200 Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            socket.write_all(response.as_bytes()).await.unwrap();
        }
    });
    let directory = tempfile::tempdir().unwrap(); let proof_path = directory.path().join("proof.json");
    let build = || Client::builder().refresh_token("generated-refresh").device_id("generated-device")
        .credentials(OAuthCredentials::new(crate::auth::DESKTOP_CLIENT_ID, "generated-application-secret"))
        .auth_base_url(&base).api_base_url(&base).verification_cache(&proof_path).build().unwrap();
    let original = build();
    let Err(Error::VerificationRequired(challenge)) = original.check_drive_access().await else { panic!("must return the actual challenge"); };
    assert_eq!(challenge.client_id, crate::auth::DESKTOP_CLIENT_ID);
    assert_eq!(challenge.device_id, "generated-device"); assert_eq!(challenge.action, "GET:/drive/v1/files");
    assert_eq!(file_requests.load(Ordering::SeqCst), 0, "status checks must never list user files");
    drop(original);
    std::fs::write(&proof_path, serde_json::to_vec(&serde_json::json!({"version":1,"tokens":[{
        "client_id":challenge.client_id,"device_id":challenge.device_id,"action":challenge.action,
        "captcha_token":"generated-proof", "expires_at":crate::request_verification::epoch_seconds() as f64 + 600.125
    }]})).unwrap()).unwrap();
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&proof_path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    let resumed = build();
    resumed.check_drive_access().await.unwrap();
    assert_eq!(inits.load(Ordering::SeqCst), 2, "status must validate the returned proof with PikPak");
    assert_eq!(file_requests.load(Ordering::SeqCst), 0);
    assert!(resumed.list_folder_page("", None, 1).await.unwrap().files.is_empty());
    assert_eq!(file_requests.load(Ordering::SeqCst), 1);
    task.abort();
}

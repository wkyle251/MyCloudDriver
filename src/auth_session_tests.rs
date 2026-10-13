//! Loopback-only session regressions; no real accounts or file requests.
use crate::Client;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Fixture {
    base: String,
    refreshes: Arc<AtomicUsize>,
    reject_access: Arc<AtomicBool>,
    task: tokio::task::JoinHandle<()>,
    directory: tempfile::TempDir,
}

impl Fixture {
    async fn new() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let refreshes = Arc::new(AtomicUsize::new(0));
        let reject_access = Arc::new(AtomicBool::new(false));
        let count = refreshes.clone();
        let reject = reject_access.clone();
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                let header_end = loop {
                    let mut buffer = [0; 4096];
                    let n = socket.read(&mut buffer).await.unwrap();
                    assert_ne!(n, 0);
                    request.extend_from_slice(&buffer[..n]);
                    if let Some(end) = request.windows(4).position(|v| v == b"\r\n\r\n") {
                        break end + 4;
                    }
                };
                let headers = String::from_utf8(request[..header_end].to_vec())
                    .unwrap()
                    .to_lowercase();
                let length = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .map(|v| v.parse::<usize>().unwrap())
                    .unwrap_or(0);
                while request.len() < header_end + length {
                    let mut buffer = [0; 4096];
                    let n = socket.read(&mut buffer).await.unwrap();
                    assert_ne!(n, 0);
                    request.extend_from_slice(&buffer[..n]);
                }
                let current = count.load(Ordering::SeqCst);
                let (status, body) = if headers.starts_with("post /v1/auth/token") {
                    let input: serde_json::Value =
                        serde_json::from_slice(&request[header_end..]).unwrap();
                    if input["refresh_token"] != format!("refresh-{current}") {
                        (400, serde_json::json!({"error":"invalid_grant"}))
                    } else {
                        count.fetch_add(1, Ordering::SeqCst);
                        reject.store(false, Ordering::SeqCst);
                        (
                            200,
                            serde_json::json!({"access_token":format!("access-{}", current + 1),
                            "refresh_token":format!("refresh-{}", current + 1), "expires_in":3600, "sub":"fixture-user"}),
                        )
                    }
                } else {
                    assert!(
                        headers.starts_with("get /v1/user/me "),
                        "fixture only permits account checks"
                    );
                    if reject.load(Ordering::SeqCst)
                        || !headers.contains(&format!("authorization: bearer access-{current}\r\n"))
                    {
                        (401, serde_json::json!({"error":"unauthenticated"}))
                    } else {
                        (
                            200,
                            serde_json::json!({"sub":"fixture-user","name":"Synthetic account"}),
                        )
                    }
                };
                let body = body.to_string();
                let response = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                let _ = socket.write_all(response.as_bytes()).await;
            }
        });
        let directory = tempfile::tempdir().unwrap();
        super::write_private_atomic(&directory.path().join("refresh-token"), "refresh-0").unwrap();
        Self {
            base,
            refreshes,
            reject_access,
            task,
            directory,
        }
    }

    fn client(&self) -> Client {
        Client::builder()
            .refresh_token("stale-launch-snapshot")
            .device_id("fixture-device")
            .credentials(super::OAuthCredentials::new(
                "fixture-client",
                "fixture-secret",
            ))
            .auth_base_url(&self.base)
            .shared_refresh_token_store(
                self.directory.path().join("refresh-token"),
                self.directory.path().join("refresh-token.lock"),
            )
            .build()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}

// Invoked in separate test processes below. A normal test run is a no-op.
#[test]
fn session_helper_process() {
    let Some(root) = std::env::var_os("MYCLOUD_SESSION_TEST_ROOT") else {
        return;
    };
    let base = std::env::var("MYCLOUD_SESSION_TEST_AUTH").unwrap();
    assert!(base.starts_with("http://127.0.0.1:"));
    let root = std::path::PathBuf::from(root);
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let client = Client::builder()
            .refresh_token("stale-launch-snapshot")
            .device_id("fixture-device")
            .credentials(super::OAuthCredentials::new(
                "fixture-client",
                "fixture-secret",
            ))
            .auth_base_url(base)
            .shared_refresh_token_store(root.join("refresh-token"), root.join("refresh-token.lock"))
            .build()
            .unwrap();
        assert_eq!(client.account_profile().await.unwrap().sub, "fixture-user");
    });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shared_session_reuses_access_in_separate_processes() {
    let fixture = Fixture::new().await;
    let mut children = Vec::new();
    for _ in 0..6 {
        let root = fixture.directory.path().to_owned();
        let base = fixture.base.clone();
        children.push(tokio::task::spawn_blocking(move || {
            std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "auth::session_tests::session_helper_process",
                    "--nocapture",
                ])
                .env("MYCLOUD_SESSION_TEST_ROOT", root)
                .env("MYCLOUD_SESSION_TEST_AUTH", base)
                .output()
                .unwrap()
        }));
    }
    for child in children {
        let output = child.await.unwrap();
        assert!(
            output.status.success(),
            "synthetic helper failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    assert_eq!(fixture.refreshes.load(Ordering::SeqCst), 1);
    fixture.client().account_profile().await.unwrap();
    assert_eq!(fixture.refreshes.load(Ordering::SeqCst), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn shared_session_reuses_access_across_helpers_and_restart() {
    let fixture = Fixture::new().await;
    fixture.client().account_profile().await.unwrap();
    let mut checks = Vec::new();
    for _ in 0..8 {
        let client = fixture.client();
        checks.push(tokio::spawn(async move { client.account_profile().await }));
    }
    for check in checks {
        assert!(
            check.await.unwrap().is_ok(),
            "a helper invalidated another helper's session"
        );
    }
    fixture.client().account_profile().await.unwrap();
    assert_eq!(
        fixture.refreshes.load(Ordering::SeqCst),
        1,
        "new helpers must reuse the unexpired access token"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shared_session_recovers_rejected_access_without_repeated_rotation() {
    let fixture = Fixture::new().await;
    let first = fixture.client();
    let second = fixture.client();
    first.account_profile().await.unwrap();
    second.account_profile().await.unwrap();
    fixture.reject_access.store(true, Ordering::SeqCst);
    first
        .account_profile()
        .await
        .expect("an expired access token must refresh before asking for sign-in");
    second
        .account_profile()
        .await
        .expect("a late rejection must reuse the already refreshed session");
    fixture.client().account_profile().await.unwrap();
    assert_eq!(fixture.refreshes.load(Ordering::SeqCst), 2);
    first
        .tokens()
        .reject_access_token("access-1")
        .await
        .unwrap();
    first.account_profile().await.unwrap();
    fixture.client().account_profile().await.unwrap();
    assert_eq!(
        fixture.refreshes.load(Ordering::SeqCst),
        2,
        "late 401 discarded a newer token"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shared_session_cache_expiry_corruption_and_credential_replacement() {
    let fixture = Fixture::new().await;
    fixture.client().account_profile().await.unwrap();
    let path = fixture.directory.path().join("refresh-token.session.json");
    let mut cache: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    cache["refresh_at"] = 0.into();
    super::write_private_atomic(&path, &cache.to_string()).unwrap();
    fixture.client().account_profile().await.unwrap();
    assert_eq!(fixture.refreshes.load(Ordering::SeqCst), 2);
    cache = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    cache["refresh_token"] = "different-session".into();
    super::write_private_atomic(&path, &cache.to_string()).unwrap();
    fixture.client().account_profile().await.unwrap();
    assert_eq!(
        fixture.refreshes.load(Ordering::SeqCst),
        3,
        "cache must match the authoritative refresh credential"
    );
    super::write_private_atomic(&path, "incomplete cache").unwrap();
    fixture.client().account_profile().await.unwrap();
    assert_eq!(
        fixture.refreshes.load(Ordering::SeqCst),
        4,
        "damaged optional cache must not lose the session"
    );
    for key in ["device_id", "client_id", "auth_endpoint"] {
        cache = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        cache[key] = "different-context".into();
        super::write_private_atomic(&path, &cache.to_string()).unwrap();
        fixture.client().account_profile().await.unwrap();
    }
    assert_eq!(
        fixture.refreshes.load(Ordering::SeqCst),
        7,
        "cache must be bound to its auth endpoint, client and device"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn only_explicit_refresh_credential_rejections_require_sign_in() {
    for (status, body, rejected) in [
        (
            400,
            r#"{"error":"invalid_grant","echo":"private-fixture-token"}"#,
            true,
        ),
        (401, r#"{"error_code":4126}"#, true),
        (400, r#"{"error":"invalid_client"}"#, false),
        (401, r#"{"error":"unauthenticated"}"#, false),
        (429, r#"{"error":"rate_limited"}"#, false),
        (503, r#"{"error":"invalid_grant"}"#, false),
        (400, "temporary gateway error", false),
    ] {
        let error = super::refresh_error(status, body);
        assert_eq!(matches!(error, crate::Error::SessionRejected(_)), rejected);
        if rejected {
            assert!(!error.to_string().contains("private-fixture-token"));
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shared_session_cache_write_failure_keeps_rotated_credential() {
    let fixture = Fixture::new().await;
    std::fs::create_dir(fixture.directory.path().join("refresh-token.session.json")).unwrap();
    fixture.client().account_profile().await.unwrap();
    fixture.client().account_profile().await.unwrap();
    assert_eq!(fixture.refreshes.load(Ordering::SeqCst), 2);
    assert_eq!(
        std::fs::read_to_string(fixture.directory.path().join("refresh-token")).unwrap(),
        "refresh-2"
    );
}

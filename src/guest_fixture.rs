//! Local-only provider fixture shared by guest URL and disk/RAM transfer tests.
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[allow(dead_code)] // The CLI fixture uses only the transfer-related controls.
pub struct Fixture {
    pub base: String,
    pub saved: Arc<Mutex<Value>>,
    pub original: Arc<Mutex<Value>>,
    pub requests: Arc<Mutex<Vec<String>>>,
    pub expired: Arc<AtomicBool>,
    pub gone: Arc<AtomicBool>,
    pub share_status: Arc<Mutex<String>>,
    pub user_available: Arc<AtomicBool>,
    pub guest_denied: Arc<AtomicBool>,
    task: tokio::task::JoinHandle<()>,
}

impl Fixture {
    pub async fn new() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let saved = Arc::new(Mutex::new(
            json!({"id":"saved-id","parent_id":"saved-folder",
            "name":"saved-name.bin","size":"8","kind":"drive#file","hash":"ABCDEF",
            "params":{"original_file_id":"source-id","original_share_id":"public-share",
                "url":"https://mypikpak.com/s/public-share"}}),
        ));
        let original = Arc::new(Mutex::new(
            json!({"id":"source-id","name":"original-name.bin",
            "size":"8","kind":"drive#file","hash":"abcdef"}),
        ));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let expired = Arc::new(AtomicBool::new(false));
        let gone = Arc::new(AtomicBool::new(false));
        let share_status = Arc::new(Mutex::new("OK".to_string()));
        let user_available = Arc::new(AtomicBool::new(false));
        let guest_denied = Arc::new(AtomicBool::new(false));
        let task = {
            let user_available = user_available.clone();
            let guest_denied = guest_denied.clone();
            let (base, saved, original, requests, expired, gone, share_status) = (
                base.clone(),
                saved.clone(),
                original.clone(),
                requests.clone(),
                expired.clone(),
                gone.clone(),
                share_status.clone(),
            );
            tokio::spawn(async move {
                let urls = Arc::new(AtomicUsize::new(0));
                let mut connections = tokio::task::JoinSet::new();
                loop {
                    tokio::select! {
                        accepted = listener.accept() => {
                            let (mut socket, _) = accepted.unwrap();
                            let user_available = user_available.clone();
                            let guest_denied = guest_denied.clone();
                            let (base, saved, original, requests, expired, gone, share_status, urls) =
                                (base.clone(), saved.clone(), original.clone(), requests.clone(), expired.clone(), gone.clone(), share_status.clone(), urls.clone());
                            connections.spawn(async move {
                                let mut request = Vec::new();
                                loop {
                                    let mut buffer = [0; 4096];
                                    let count = socket.read(&mut buffer).await.unwrap();
                                    if count == 0 { return; }
                                    request.extend_from_slice(&buffer[..count]);
                                    if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                                        let header = String::from_utf8_lossy(&request[..end]);
                                        let length = header.lines().find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length:")
                                            .and_then(|value| value.trim().parse::<usize>().ok())).unwrap_or(0);
                                        if request.len() >= end + 4 + length { break; }
                                    }
                                }
                                let request = String::from_utf8(request).unwrap();
                                let url = reqwest::Url::parse(&format!("{base}{}", request.split_whitespace().nth(1).unwrap())).unwrap();
                                requests.lock().unwrap().push(request.clone());
                                let mut status = "200 OK";
                                let mut extra = String::new();
                                let data = match url.path() {
                                    "/v1/auth/token" => json!({"access_token":"account-access","refresh_token":"account-refresh",
                                        "expires_in":7200,"sub":"account-user"}).to_string().into_bytes(),
                                    "/v1/shield/captcha/init" => br#"{"captcha_token":"captcha-fixture"}"#.to_vec(),
                                    "/drive/v1/files" => {
                                        let parent = url.query_pairs().find(|(key, _)| key == "parent_id").map(|(_, value)| value.to_string());
                                        let file = saved.lock().unwrap().clone();
                                        let files = if !gone.load(Ordering::SeqCst) && parent.as_deref() == Some("saved-folder") { vec![file] }
                                            else if parent.as_deref() == Some("") && !url.query_pairs().any(|(key, value)| key == "filters" && value.contains("\"id\"")) {
                                                vec![json!({"id":"saved-folder","name":"Saved","kind":"drive#folder","parent_id":""})]
                                            } else { vec![] };
                                        json!({"files":files}).to_string().into_bytes()
                                    },
                                    "/drive/v1/share/file_info" => {
                                        let mut file = original.lock().unwrap().clone();
                                        let version = urls.fetch_add(1, Ordering::SeqCst) + 1;
                                        let user = request.contains("authorization: Bearer account-access") && user_available.load(Ordering::SeqCst);
                                        // Null explicitly suppresses the default original URL.
                                        if file.get("web_content_link").is_none() { file["web_content_link"] = json!(format!("{base}/guest-body/{version}")); }
                                        if file["web_content_link"].is_null() { file["web_content_link"] = json!(""); }
                                        if user { file["web_content_link"] = json!(format!("{base}/user-body/{version}")); }
                                        let status = if user { "OK".into() } else { share_status.lock().unwrap().clone() };
                                        json!({"share_status":status,"file_info":file}).to_string().into_bytes()
                                    },
                                    path if path.starts_with("/drive/v1/files/") => {
                                        if user_available.load(Ordering::SeqCst) {
                                            assert!(request.contains("authorization: Bearer account-access"));
                                            assert!(path.ends_with("/saved-id"), "fallback must use the saved account ID");
                                            let mut file = saved.lock().unwrap().clone();
                                            file["web_content_link"] = json!(format!("{base}/user-body/1"));
                                            file.to_string().into_bytes()
                                        } else {
                                        status = "400 Bad Request";
                                        br#"{"error_code":3,"error":"monthly_download_size_exceeded"}"#.to_vec()
                                        }
                                    },
                                    path if path.starts_with("/guest-body/") || path.starts_with("/user-body/") => {
                                        if path.starts_with("/guest-body/") && (guest_denied.load(Ordering::SeqCst) || (expired.load(Ordering::SeqCst) && path.ends_with("/1"))) {
                                            status = "403 Forbidden"; b"expired".to_vec()
                                        } else {
                                            extra.push_str("ETag: \"guest-fixture\"\r\nAccept-Ranges: bytes\r\n");
                                            if request.to_ascii_lowercase().contains("range: bytes=3-\r\n") {
                                                status = "206 Partial Content"; extra.push_str("Content-Range: bytes 3-7/8\r\n"); b"defgh".to_vec()
                                            } else { b"abcdefgh".to_vec() }
                                        }
                                    },
                                    _ => { status = "404 Not Found"; b"unexpected request".to_vec() },
                                };
                                let header = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n", data.len());
                                socket.write_all(header.as_bytes()).await.unwrap();
                                socket.write_all(&data).await.unwrap();
                            });
                        },
                        done = connections.join_next(), if !connections.is_empty() => { done.unwrap().unwrap(); },
                    }
                }
            })
        };
        Self {
            base,
            saved,
            original,
            requests,
            expired,
            gone,
            share_status,
            user_available,
            guest_denied,
            task,
        }
    }

    pub fn assert_anonymous_content(&self) {
        let requests = self.requests.lock().unwrap();
        let shares: Vec<_> = requests
            .iter()
            .filter(|r| r.starts_with("GET /drive/v1/share/"))
            .collect();
        assert!(!shares.is_empty());
        for request in shares {
            assert!(!request.to_ascii_lowercase().contains("authorization:"));
            assert!(!request.contains("account-device"));
            assert!(
                request.contains("share_id=public-share") && request.contains("file_id=source-id")
            );
        }
        for request in requests
            .iter()
            .filter(|r| r.starts_with("GET /guest-body/"))
        {
            assert!(!request.to_ascii_lowercase().contains("authorization:"));
            assert!(request.contains("referer: https://mypikpak.com/"));
        }
        assert!(
            !requests
                .iter()
                .any(|r| r.starts_with("GET /drive/v1/files/")),
            "Guest Mode requested an authenticated content URL"
        );
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}

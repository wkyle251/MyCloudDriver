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
    pub guest_metadata_failures: Arc<AtomicUsize>,
    pub guest_metadata_failure_status: Arc<AtomicUsize>,
    pub guest_metadata_failure_after_urls: Arc<AtomicUsize>,
    pub owned_shares: Arc<Mutex<Vec<Value>>>,
    pub share_create_status: Arc<AtomicUsize>,
    pub share_create_response: Arc<Mutex<Option<Value>>>,
    pub share_creation_delay_ms: Arc<AtomicUsize>,
    pub share_inventory_delay_ms: Arc<AtomicUsize>,
    pub share_next_page_token: Arc<Mutex<String>>,
    pub trash_status: Arc<AtomicUsize>,
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
        let guest_metadata_failures = Arc::new(AtomicUsize::new(0));
        let guest_metadata_failure_status = Arc::new(AtomicUsize::new(503));
        let guest_metadata_failure_after_urls = Arc::new(AtomicUsize::new(0));
        let owned_shares = Arc::new(Mutex::new(Vec::<Value>::new()));
        let share_create_status = Arc::new(AtomicUsize::new(200));
        let share_create_response = Arc::new(Mutex::new(None::<Value>));
        let share_creation_delay_ms = Arc::new(AtomicUsize::new(0));
        let share_inventory_delay_ms = Arc::new(AtomicUsize::new(0));
        let share_next_page_token = Arc::new(Mutex::new(String::new()));
        let trash_status = Arc::new(AtomicUsize::new(200));
        let task = {
            let trash_status = trash_status.clone();
            let (owned_shares, share_create_status, share_create_response, share_creation_delay_ms, share_next_page_token) =
                (owned_shares.clone(), share_create_status.clone(), share_create_response.clone(), share_creation_delay_ms.clone(), share_next_page_token.clone());
            let share_inventory_delay_ms = share_inventory_delay_ms.clone();
            let user_available = user_available.clone();
            let guest_denied = guest_denied.clone();
            let guest_metadata_failures = guest_metadata_failures.clone();
            let guest_metadata_failure_status = guest_metadata_failure_status.clone();
            let guest_metadata_failure_after_urls = guest_metadata_failure_after_urls.clone();
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
                            let trash_status = trash_status.clone();
                            let user_available = user_available.clone();
                            let guest_denied = guest_denied.clone();
                            let guest_metadata_failures = guest_metadata_failures.clone();
                            let guest_metadata_failure_status = guest_metadata_failure_status.clone();
                            let guest_metadata_failure_after_urls = guest_metadata_failure_after_urls.clone();
                            let (owned_shares, share_create_status, share_create_response, share_creation_delay_ms, share_next_page_token) =
                                (owned_shares.clone(), share_create_status.clone(), share_create_response.clone(), share_creation_delay_ms.clone(), share_next_page_token.clone());
                            let share_inventory_delay_ms = share_inventory_delay_ms.clone();
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
                                    "/v1/user/me" => br#"{"sub":"account-user"}"#.to_vec(),
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
                                        let anonymous = !request.contains("authorization:");
                                        let inject_failure = anonymous
                                            && urls.load(Ordering::SeqCst) >= guest_metadata_failure_after_urls.load(Ordering::SeqCst)
                                            && guest_metadata_failures.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |left| left.checked_sub(1)).is_ok();
                                        if inject_failure {
                                            status = match guest_metadata_failure_status.load(Ordering::SeqCst) {
                                                429 => "429 Too Many Requests", _ => "503 Service Unavailable",
                                            };
                                            extra.push_str("Retry-After: 7\r\n");
                                            br#"{"error":"synthetic Guest metadata outage"}"#.to_vec()
                                        } else {
                                        let created = url.query_pairs().any(|(key, value)| key == "share_id" && value != "public-share");
                                        let mut file = if created { saved.lock().unwrap().clone() } else { original.lock().unwrap().clone() };
                                        let version = urls.fetch_add(1, Ordering::SeqCst) + 1;
                                        let user = request.contains("authorization: Bearer account-access") && user_available.load(Ordering::SeqCst);
                                        // Null explicitly suppresses the default original URL.
                                        if file.get("web_content_link").is_none() { file["web_content_link"] = json!(format!("{base}/guest-body/{version}")); }
                                        if file["web_content_link"].is_null() { file["web_content_link"] = json!(""); }
                                        if user { file["web_content_link"] = json!(format!("{base}/user-body/{version}")); }
                                        let status = if user || created { "OK".into() } else { share_status.lock().unwrap().clone() };
                                        json!({"share_status":status,"file_info":file}).to_string().into_bytes()
                                        }
                                    },
                                    "/drive/v1/share/list" => {
                                        assert!(request.contains("authorization: Bearer account-access"));
                                        let delay = share_inventory_delay_ms.load(Ordering::SeqCst);
                                        if delay>0 { tokio::time::sleep(std::time::Duration::from_millis(delay as u64)).await; }
                                        json!({"data":*owned_shares.lock().unwrap(),"next_page_token":*share_next_page_token.lock().unwrap()}).to_string().into_bytes()
                                    },
                                    "/drive/v1/share" => {
                                        assert!(request.starts_with("POST ") && request.contains("authorization: Bearer account-access"));
                                        let body: Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
                                        assert_eq!(body["file_ids"], json!(["saved-id"]));
                                        let response = share_create_response.lock().unwrap().clone().unwrap_or_else(|| json!({
                                            "share_id":"download-share", "share_url":"https://mypikpak.com/s/download-share",
                                            "title":body["title"], "file_ids":body["file_ids"], "share_status":"OK"
                                        }));
                                        let code = share_create_status.load(Ordering::SeqCst);
                                        if code == 200 || code >= 500 { owned_shares.lock().unwrap().push(response.clone()); }
                                        let delay = share_creation_delay_ms.load(Ordering::SeqCst);
                                        if delay > 0 { tokio::time::sleep(std::time::Duration::from_millis(delay as u64)).await; }
                                        match code {
                                            200 => response.to_string().into_bytes(),
                                            429 => { status = "429 Too Many Requests"; extra.push_str("Retry-After: 7\r\n"); br#"{"error":"share creation throttled"}"#.to_vec() },
                                            403 => { status = "403 Forbidden"; br#"{"error":"sharing denied"}"#.to_vec() },
                                            _ => { status = "503 Service Unavailable"; br#"{"error":"unknown create outcome"}"#.to_vec() },
                                        }
                                    },
                                    "/drive/v1/files:batchTrash" => {
                                        assert!(request.starts_with("POST ") && request.contains("authorization: Bearer account-access"));
                                        let body: Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
                                        assert_eq!(body["ids"], json!(["saved-id"]));
                                        if trash_status.load(Ordering::SeqCst) == 200 {
                                            gone.store(true, Ordering::SeqCst);
                                            b"{}".to_vec()
                                        } else {
                                            status = "403 Forbidden";
                                            br#"{"error":"synthetic cleanup denied"}"#.to_vec()
                                        }
                                    },
                                    path if path.starts_with("/drive/v1/files/") => {
                                        if user_available.load(Ordering::SeqCst) {
                                            assert!(request.contains("authorization: Bearer account-access"));
                                            assert!(path.ends_with("/saved-id"), "fallback must use the saved account ID");
                                            let mut file = saved.lock().unwrap().clone();
                                            // PikPak still describes a trashed file, but will not issue a download link for it.
                                            if file["trashed"] == true && url.query_pairs().any(|(key, value)| key == "usage" && value == "FETCH") {
                                                status = "400 Bad Request";
                                                br#"{"error":"file_in_recycle_bin", "error_code":9, "error_url":"", "error_description":"File or folder is already in recycler", "details":[]}"#.to_vec()
                                            } else {
                                                file["web_content_link"] = json!(format!("{base}/user-body/1"));
                                                file.to_string().into_bytes()
                                            }
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
                                if socket.write_all(header.as_bytes()).await.is_err() { return; }
                                let _ = socket.write_all(&data).await;
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
            guest_metadata_failures,
            guest_metadata_failure_status,
            guest_metadata_failure_after_urls,
            owned_shares,
            share_create_status,
            share_create_response,
            share_creation_delay_ms,
            share_inventory_delay_ms,
            share_next_page_token,
            trash_status,
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

/// A generated-content fixture for partial Guest access. It never reads a user
/// download, contacts PikPak, or authenticates with an actual account.
#[derive(Clone, Copy, Debug)]
pub enum PartialReply {
    ShortBody,
    CappedRange,
    InterruptedBody,
}

#[derive(Clone)]
pub struct PartialConfig {
    pub guest_reply: PartialReply,
    pub guest_prefix: usize,
    pub guest_ranges_complete: bool,
    pub guest_etag: Option<String>,
    pub user_etag: Option<String>,
    pub user_hash: Option<String>,
    pub user_name: Option<String>,
    pub user_byte: Option<u8>,
    pub user_available: bool,
    pub guest_next_error: Option<u16>,
    pub guest_first_bounded_error: Option<u16>,
    pub guest_end_status: u16,
    pub guest_omit_unsatisfied_range: bool,
    pub guest_invalid_range: bool,
    pub guest_oversized_body: bool,
    pub user_oversized_body: bool,
    pub delay_first_guest_range_ms: u64,
}

#[allow(dead_code)]
pub struct PartialFixture {
    pub base: String,
    pub saved: Arc<Mutex<Value>>,
    pub original: Arc<Mutex<Value>>,
    pub requests: Arc<Mutex<Vec<String>>>,
    pub config: Arc<Mutex<PartialConfig>>,
    pub content: Arc<Vec<u8>>,
    task: tokio::task::JoinHandle<()>,
}

impl PartialFixture {
    pub async fn new(total: usize, guest_prefix: usize, guest_reply: PartialReply) -> Self {
        assert!(guest_prefix > 0 && guest_prefix <= total);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let saved = Arc::new(Mutex::new(json!({
            "id":"saved-id","parent_id":"saved-folder","name":"saved-name.bin",
            "size":total.to_string(),"kind":"drive#file","hash":"ABCDEF",
            "params":{"original_file_id":"source-id","original_share_id":"public-share",
                "url":"https://mypikpak.com/s/public-share"}
        })));
        let original = Arc::new(Mutex::new(json!({
            "id":"source-id","name":"original-name.bin","size":total.to_string(),
            "kind":"drive#file","hash":"abcdef"
        })));
        let config = Arc::new(Mutex::new(PartialConfig {
            guest_reply,
            guest_prefix,
            guest_ranges_complete: false,
            guest_etag: Some("\"guest-partial\"".into()),
            user_etag: Some("\"user-partial\"".into()),
            user_hash: Some("ABCDEF".into()),
            user_name: None,
            user_byte: None,
            user_available: true,
            guest_next_error: None,
            guest_first_bounded_error: None,
            guest_end_status: 416,
            guest_omit_unsatisfied_range: false,
            guest_invalid_range: false,
            guest_oversized_body: false,
            user_oversized_body: false,
            delay_first_guest_range_ms: 0,
        }));
        let content = Arc::new(
            (0..total)
                .map(|offset| (offset % 251) as u8)
                .collect::<Vec<_>>(),
        );
        let requests = Arc::new(Mutex::new(Vec::new()));
        let task = {
            let (base, saved, original, config, content, requests) = (
                base.clone(),
                saved.clone(),
                original.clone(),
                config.clone(),
                content.clone(),
                requests.clone(),
            );
            tokio::spawn(async move {
                let mut connections = tokio::task::JoinSet::new();
                loop {
                    tokio::select! {
                        accepted = listener.accept() => {
                            let (mut socket, _) = accepted.unwrap();
                            let (base, saved, original, config, content, requests) = (
                                base.clone(), saved.clone(), original.clone(), config.clone(), content.clone(), requests.clone(),
                            );
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
                                let user = request.contains("authorization: Bearer account-access");
                                let cfg = config.lock().unwrap().clone();
                                let mut status = "200 OK";
                                let mut extra = String::new();
                                let mut declared_length = None;
                                let mut response_delay_ms = 0;
                                let data = match url.path() {
                                    "/v1/user/me" => br#"{"sub":"account-user"}"#.to_vec(),
                                    "/v1/auth/token" => json!({"access_token":"account-access","refresh_token":"account-refresh",
                                        "expires_in":7200,"sub":"account-user"}).to_string().into_bytes(),
                                    "/v1/shield/captcha/init" => br#"{"captcha_token":"captcha-fixture"}"#.to_vec(),
                                    "/drive/v1/files" => {
                                        let parent = url.query_pairs().find(|(key, _)| key == "parent_id").map(|(_, value)| value.to_string());
                                        let files = if parent.as_deref() == Some("saved-folder") { vec![saved.lock().unwrap().clone()] }
                                            else if parent.as_deref() == Some("") { vec![json!({"id":"saved-folder","name":"Saved","kind":"drive#folder","parent_id":""})] }
                                            else { vec![] };
                                        json!({"files":files}).to_string().into_bytes()
                                    },
                                    "/drive/v1/share/file_info" => {
                                        if user && !cfg.user_available {
                                            status = "400 Bad Request";
                                            br#"{"error_code":3,"error":"monthly_download_size_exceeded"}"#.to_vec()
                                        } else {
                                        let created = url.query_pairs().any(|(key, value)| key == "share_id" && value == "download-share");
                                        let mut file = if created { saved.lock().unwrap().clone() } else { original.lock().unwrap().clone() };
                                        if user {
                                            file["hash"] = json!(cfg.user_hash);
                                            if let Some(name) = &cfg.user_name { file["name"] = json!(name); }
                                        }
                                        file["web_content_link"] = json!(format!("{base}/{}-body", if user { "user" } else { "guest" }));
                                        json!({"share_status":"OK","file_info":file}).to_string().into_bytes()
                                        }
                                    },
                                    "/drive/v1/share/list" => {
                                        assert!(user);
                                        br#"{"data":[],"next_page_token":""}"#.to_vec()
                                    },
                                    "/drive/v1/share" => {
                                        assert!(user && request.starts_with("POST "));
                                        let body: Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
                                        assert_eq!(body["file_ids"], json!(["saved-id"]));
                                        json!({"share_id":"download-share","share_url":"https://mypikpak.com/s/download-share","title":body["title"]}).to_string().into_bytes()
                                    },
                                    "/drive/v1/files/saved-id" => {
                                        assert!(user);
                                        if !cfg.user_available {
                                            status = "400 Bad Request";
                                            br#"{"error_code":3,"error":"monthly_download_size_exceeded"}"#.to_vec()
                                        } else {
                                        let mut file = saved.lock().unwrap().clone();
                                        file["hash"] = json!(cfg.user_hash);
                                        if let Some(name) = &cfg.user_name { file["name"] = json!(name); }
                                        file["web_content_link"] = json!(format!("{base}/user-body"));
                                        file.to_string().into_bytes()
                                        }
                                    },
                                    "/guest-body" | "/user-body" => {
                                        let guest = url.path() == "/guest-body";
                                        let error = if guest { config.lock().unwrap().guest_next_error.take() } else { None };
                                        if let Some(code) = error {
                                            status = match code { 416 => "416 Range Not Satisfiable", 429 => "429 Too Many Requests", 503 => "503 Service Unavailable", _ => "403 Forbidden" };
                                            extra.push_str("Retry-After: 0\r\n");
                                            b"synthetic temporary failure".to_vec()
                                        } else if (guest && cfg.guest_oversized_body) || (!guest && cfg.user_oversized_body) {
                                            extra.push_str("ETag: \"oversized-fixture\"\r\n");
                                            let mut oversized = content.as_ref().clone();
                                            oversized.extend_from_slice(b"oversized");
                                            oversized
                                        } else {
                                            let etag = if guest { cfg.guest_etag.as_deref() } else { cfg.user_etag.as_deref() };
                                            if let Some(etag) = etag { extra.push_str(&format!("ETag: {etag}\r\n")); }
                                            extra.push_str("Accept-Ranges: bytes\r\n");
                                            let header_value = |name: &str| request.lines().find_map(|line| {
                                                let (key, value) = line.split_once(':')?;
                                                key.eq_ignore_ascii_case(name).then(|| value.trim().to_string())
                                            });
                                            let range = header_value("range").and_then(|value| {
                                                let (start, end) = value.strip_prefix("bytes=")?.split_once('-')?;
                                                Some((start.parse::<usize>().ok()?, if end.is_empty() { total - 1 } else { end.parse().ok()? }))
                                            }).filter(|_| header_value("if-range").is_none_or(|value| Some(value.as_str()) == etag));
                                            let (start, end) = range.unwrap_or((0, total - 1));
                                            let bounded_error = if guest && range.is_some() && end > start && end < total - 1 {
                                                config.lock().unwrap().guest_first_bounded_error.take()
                                            } else { None };
                                            if guest && range.is_some() && start == 0 && end > 0 && end < total - 1 {
                                                response_delay_ms = cfg.delay_first_guest_range_ms;
                                            }
                                            let available = if guest && (!cfg.guest_ranges_complete || range.is_none()) { cfg.guest_prefix } else { total };
                                            if bounded_error.is_some() {
                                                status = if bounded_error == Some(416) { "416 Range Not Satisfiable" } else { "403 Forbidden" };
                                                b"synthetic bounded range denial".to_vec()
                                            } else if start >= available {
                                                status = if guest && cfg.guest_end_status == 403 { "403 Forbidden" } else { "416 Range Not Satisfiable" };
                                                if !guest || !cfg.guest_omit_unsatisfied_range {
                                                    extra.push_str(&format!("Content-Range: bytes */{available}\r\n"));
                                                }
                                                Vec::new()
                                            } else {
                                                let end = end.min(total - 1);
                                                let returned_end = end.min(available - 1);
                                                let capped = guest && returned_end < end;
                                                let interrupted = capped && matches!(cfg.guest_reply, PartialReply::InterruptedBody);
                                                if range.is_some() || (guest && matches!(cfg.guest_reply, PartialReply::CappedRange)) {
                                                    status = "206 Partial Content";
                                                    let range_total = if guest && cfg.guest_invalid_range { total - 1 } else { total };
                                                    extra.push_str(&format!("Content-Range: bytes {start}-{}/{range_total}\r\n", if interrupted { end } else { returned_end }));
                                                }
                                                if interrupted { declared_length = Some(end - start + 1); }
                                    match cfg.user_byte.filter(|_| !guest) {
                                        Some(byte) => vec![byte; returned_end - start + 1],
                                        None => content[start..=returned_end].to_vec(),
                                    }
                                            }
                                        }
                                    },
                                    _ => { status = "404 Not Found"; b"unexpected request".to_vec() },
                                };
                                let header = format!("HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n", declared_length.unwrap_or(data.len()));
                                if response_delay_ms > 0 { tokio::time::sleep(std::time::Duration::from_millis(response_delay_ms)).await; }
                                if socket.write_all(header.as_bytes()).await.is_ok() {
                                    let _ = socket.write_all(&data).await;
                                }
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
            config,
            content,
            task,
        }
    }
}

impl Drop for PartialFixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}

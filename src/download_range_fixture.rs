//! Generated loopback originals only. Shared by the range, disk and RAM tests.
#![allow(dead_code)]
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub const SIZE: u64 = 64 << 20;
pub fn byte(offset: u64, revision: usize) -> u8 {
    ((offset % 251 + (offset / 65536) % 251 + revision as u64 * 17) % 251) as u8
}
pub fn bytes(start: u64, length: usize, revision: usize) -> Vec<u8> {
    (start..start + length as u64)
        .map(|offset| byte(offset, revision))
        .collect()
}
#[derive(Clone, Debug)]
pub struct Request {
    pub start: u64,
    pub end: u64,
    pub ranged: bool,
    pub if_range: Option<String>,
    pub referer: bool,
}

pub struct Fixture {
    pub url: String,
    pub base: String,
    pub size: u64,
    pub requests: Arc<Mutex<Vec<Request>>>,
    pub peak: Arc<AtomicUsize>,
    pub revision: Arc<AtomicUsize>,
    /// 0: normal, 1: ignore ranges, 2: malformed range, 3: changed body ETag,
    /// 4: service error on non-probe range.
    pub mode: Arc<AtomicUsize>,
    pub hold_first: Arc<AtomicBool>,
    pub drop_first: Arc<AtomicBool>,
    pub finished_other: Arc<AtomicUsize>,
    pub chunk_delay_millis: Arc<AtomicUsize>,
    pub hold_after_bytes: Arc<AtomicUsize>,
    server: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Fixture {
    pub async fn new(size: u64) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let peak = Arc::new(AtomicUsize::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let revision = Arc::new(AtomicUsize::new(1));
        let mode = Arc::new(AtomicUsize::new(0));
        let hold_first = Arc::new(AtomicBool::new(false));
        let drop_first = Arc::new(AtomicBool::new(false));
        let finished_other = Arc::new(AtomicUsize::new(0));
        let chunk_delay_millis = Arc::new(AtomicUsize::new(0));
        let hold_after_bytes = Arc::new(AtomicUsize::new(256 * 1024));
        let shared = (
            base.clone(),
            requests.clone(),
            peak.clone(),
            revision.clone(),
            mode.clone(),
            hold_first.clone(),
            drop_first.clone(),
            finished_other.clone(),
            chunk_delay_millis.clone(),
            hold_after_bytes.clone(),
        );
        let server = tokio::spawn(async move {
            let mut jobs = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    connection = listener.accept() => {
                        let (mut socket, _) = connection.unwrap();
                        let (base, requests, peak, revision, mode, hold_first, drop_first, finished_other, chunk_delay_millis, hold_after_bytes) = shared.clone();
                        let active = active.clone();
                        jobs.spawn(async move {
                            let mut request = Vec::new();
                            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                                let mut buffer = [0; 4096];
                                let Ok(count) = socket.read(&mut buffer).await else { return; };
                                if count == 0 { return; }
                                request.extend_from_slice(&buffer[..count]);
                            }
                            let text = String::from_utf8_lossy(&request);
                            let route = text.lines().next().unwrap();
                            let generation = revision.load(Ordering::Acquire);
                            let body = if route.starts_with("POST /v1/auth/token") {
                                Some(serde_json::json!({"access_token":"fixture","refresh_token":"fixture","expires_in":3600,"sub":"fixture"}))
                            } else if route.starts_with("POST /v1/shield/captcha/init") {
                                Some(serde_json::json!({"captcha_token":"fixture","expires_in":3600}))
                            } else if route.starts_with("GET /drive/v1/files/") {
                                Some(serde_json::json!({"name":"generated.bin","size":size.to_string(),"hash":format!("fixture-{generation}"),"web_content_link":format!("{base}/original")}))
                            } else { None };
                            if let Some(body) = body {
                                let body = body.to_string();
                                let reply = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());
                                let _ = socket.write_all(reply.as_bytes()).await; return;
                            }
                            let headers = text.to_lowercase();
                            let header = |name: &str| headers.lines().find_map(|line| line.strip_prefix(name).map(str::trim)).map(str::to_owned);
                            let range = header("range:").and_then(|value| value.strip_prefix("bytes=").map(str::to_owned))
                                .and_then(|value| value.split_once('-').map(|(start, end)| (start.parse::<u64>().unwrap(), end.parse::<u64>().unwrap_or(size - 1))));
                            let if_range = header("if-range:");
                            let requested = range.unwrap_or((0, size - 1));
                            requests.lock().unwrap().push(Request { start: requested.0, end: requested.1, ranged: range.is_some(),
                                if_range: if_range.clone(), referer: header("referer:").is_some() });
                            let mode = mode.load(Ordering::Acquire);
                            let probe = range == Some((0, 0));
                            if mode == 4 && !probe && range.is_some() {
                                let _ = socket.write_all(b"HTTP/1.1 503 Unavailable\r\nRetry-After: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                                return;
                            }
                            let etag = format!("\"fixture-{generation}\"");
                            let ranged = range.is_some() && mode != 1 && if_range.as_ref().is_none_or(|tag| *tag == etag);
                            let (start, end) = if ranged { requested } else { (0, size - 1) };
                            if start >= size || end >= size || end < start {
                                let reply = format!("HTTP/1.1 416 Range\r\nETag: {etag}\r\nContent-Range: bytes */{size}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                                let _ = socket.write_all(reply.as_bytes()).await; return;
                            }
                            let generation = if mode == 3 && ranged && !probe { generation + 1 } else { generation };
                            let etag = format!("\"fixture-{generation}\"");
                            let range_header = if ranged {
                                format!("Content-Range: bytes {}-{end}/{size}\r\n", start + u64::from(mode == 2 && !probe))
                            } else { String::new() };
                            let reply = format!("HTTP/1.1 {} OK\r\nETag: {etag}\r\n{range_header}Content-Length: {}\r\nConnection: close\r\n\r\n", if ranged {206} else {200}, end - start + 1);
                            if socket.write_all(reply.as_bytes()).await.is_err() { return; }
                            peak.fetch_max(active.fetch_add(1, Ordering::AcqRel) + 1, Ordering::AcqRel);
                            let mut position = start;
                            while position <= end {
                                if start == 0 && !probe && position >= hold_after_bytes.load(Ordering::Acquire) as u64 && (hold_first.load(Ordering::Acquire) || drop_first.load(Ordering::Acquire)) {
                                    if drop_first.load(Ordering::Acquire) && finished_other.load(Ordering::Acquire) > 0 {
                                        drop_first.store(false, Ordering::Release);
                                        tokio::time::sleep(Duration::from_millis(100)).await;
                                        break;
                                    }
                                    tokio::time::sleep(Duration::from_millis(10)).await; continue;
                                }
                                let data = bytes(position, ((end - position + 1) as usize).min(64 * 1024), generation);
                                if socket.write_all(&data).await.is_err() { break; }
                                position += data.len() as u64;
                                let delay = chunk_delay_millis.load(Ordering::Acquire);
                                if delay > 0 { tokio::time::sleep(Duration::from_millis(delay as u64)).await; }
                                tokio::task::yield_now().await;
                            }
                            if start > 0 && position > end { finished_other.fetch_add(1, Ordering::Release); }
                            active.fetch_sub(1, Ordering::AcqRel);
                        });
                    }
                    result = jobs.join_next(), if !jobs.is_empty() => { result.unwrap().unwrap(); }
                }
            }
        });
        Self {
            url: format!("{base}/original"),
            base,
            size,
            requests,
            peak,
            revision,
            mode,
            hold_first,
            drop_first,
            finished_other,
            chunk_delay_millis,
            hold_after_bytes,
            server,
        }
    }
}

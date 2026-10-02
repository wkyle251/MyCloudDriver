//! A synthetic experiment, not an alternative downloader for user files.
//! Compare ranges within one file under a per-connection or shared bandwidth
//! limit. Only 127.0.0.1 is contacted; no account, proxy or app state is used.
use anyhow::{ensure, Result};
use futures_util::StreamExt;
use std::{
    os::unix::fs::FileExt,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const SIZE: usize = 32 * 1024 * 1024;
const RATE: usize = 8 * 1024 * 1024;
const ETAG: &str = "\"generated-original-v1\"";

struct Fixture {
    address: std::net::SocketAddr,
    peak: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Fixture {
    async fn start(data: Arc<Vec<u8>>, shared_limit: bool) -> Result<Self> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let active = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let observed_peak = peak.clone();
        let shared_next = Arc::new(Mutex::new(tokio::time::Instant::now()));
        let task = tokio::spawn(async move {
            let mut clients = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let (mut socket, _) = accepted.unwrap();
                        let data = data.clone();
                        let active = active.clone();
                        let peak = observed_peak.clone();
                        let shared_next = shared_next.clone();
                        clients.spawn(async move {
                            let mut request = Vec::new();
                            while !request.ends_with(b"\r\n\r\n") {
                                let mut chunk = [0; 1024];
                                let count = socket.read(&mut chunk).await?;
                                ensure!(count > 0 && request.len() < 8192, "Invalid fixture request");
                                request.extend_from_slice(&chunk[..count]);
                            }
                            let request = String::from_utf8(request)?.to_ascii_lowercase();
                            ensure!(request.starts_with("get /generated.bin http/1.1\r\n"));
                            ensure!(request.contains(&format!("if-range: {ETAG}\r\n")));
                            let range = request.lines().find_map(|line| line.strip_prefix("range: bytes="))
                                .ok_or_else(|| anyhow::anyhow!("Expected a range"))?;
                            let (start, end) = range.split_once('-').unwrap();
                            let start: usize = start.parse()?;
                            let end: usize = end.parse()?;
                            ensure!(start <= end && end < data.len());
                            let count = active.fetch_add(1, Ordering::SeqCst) + 1;
                            peak.fetch_max(count, Ordering::SeqCst);
                            let header = format!("HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nETag: {ETAG}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n", end - start + 1, data.len());
                            socket.write_all(header.as_bytes()).await?;
                            let mut next = tokio::time::Instant::now();
                            for chunk in data[start..=end].chunks(64 * 1024) {
                                let interval = Duration::from_secs_f64(chunk.len() as f64 / RATE as f64);
                                let deadline = if shared_limit {
                                    let mut shared = shared_next.lock().unwrap();
                                    // Pace cumulative bytes, so timer overshoot
                                    // does not invent a lower single-stream cap.
                                    *shared += interval;
                                    *shared
                                } else {
                                    next += interval;
                                    next
                                };
                                tokio::time::sleep_until(deadline).await;
                                socket.write_all(chunk).await?;
                            }
                            socket.shutdown().await?;
                            active.fetch_sub(1, Ordering::SeqCst);
                            Ok::<(), anyhow::Error>(())
                        });
                    }
                    result = clients.join_next(), if !clients.is_empty() => {
                        result.unwrap().unwrap().unwrap();
                    }
                }
            }
        });
        Ok(Self {
            address,
            peak,
            task,
        })
    }
}

#[derive(Clone)]
enum Destination {
    Memory(Arc<Mutex<Vec<u8>>>),
    Disk(Arc<std::fs::File>),
}

impl Destination {
    fn write(&self, offset: usize, chunk: &[u8]) -> Result<()> {
        match self {
            Self::Memory(data) => {
                data.lock().unwrap()[offset..offset + chunk.len()].copy_from_slice(chunk)
            }
            Self::Disk(file) => file.write_all_at(chunk, offset as u64)?,
        }
        Ok(())
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<()> {
    // The changing pattern catches reordered/misplaced ranges, unlike a file
    // made from one repeated byte. These are generated bytes, not user content.
    let data = Arc::new(
        (0..SIZE)
            .map(|offset| (offset.wrapping_mul(31) ^ (offset / 8191)) as u8)
            .collect::<Vec<_>>(),
    );
    let expected_hash = ring::digest::digest(&ring::digest::SHA256, &data);
    let client = pikpak::Client::builder()
        .refresh_token("synthetic-only")
        .build()?;
    let http = client.download_http_client();
    println!("Synthetic HTTP ranges only: 32 MiB original, 8 MiB/s configured cap; no TLS or PikPak traffic.");
    for shared in [false, true] {
        for disk in [false, true] {
            for channels in [1, 2, 4, 8] {
                let directory = tempfile::tempdir()?;
                let path = directory.path().join("generated.bin");
                let target = if disk {
                    Destination::Disk(Arc::new(
                        std::fs::OpenOptions::new()
                            .create_new(true)
                            .write(true)
                            .open(&path)?,
                    ))
                } else {
                    Destination::Memory(Arc::new(Mutex::new(vec![0; SIZE])))
                };
                let fixture = Fixture::start(data.clone(), shared).await?;
                let started = Instant::now();
                let mut downloads = tokio::task::JoinSet::new();
                for channel in 0..channels {
                    let start = SIZE * channel / channels;
                    let end = SIZE * (channel + 1) / channels - 1;
                    let url = format!("http://{}/generated.bin", fixture.address);
                    let http = http.clone();
                    let target = target.clone();
                    downloads.spawn(async move {
                        let response = http
                            .get(url)
                            .header(reqwest::header::RANGE, format!("bytes={start}-{end}"))
                            .header(reqwest::header::IF_RANGE, ETAG)
                            .header(reqwest::header::ACCEPT_ENCODING, "identity")
                            .send()
                            .await?;
                        ensure!(response.status() == reqwest::StatusCode::PARTIAL_CONTENT);
                        ensure!(
                            response.headers()[reqwest::header::CONTENT_RANGE]
                                == format!("bytes {start}-{end}/{SIZE}")
                        );
                        ensure!(response.headers()[reqwest::header::ETAG] == ETAG);
                        ensure!(response.content_length() == Some((end - start + 1) as u64));
                        let mut stream = response.bytes_stream();
                        let mut offset = start;
                        while let Some(chunk) = stream.next().await {
                            let chunk = chunk?;
                            ensure!(offset + chunk.len() <= end + 1);
                            target.write(offset, &chunk)?;
                            offset += chunk.len();
                        }
                        ensure!(offset == end + 1);
                        Ok::<(), anyhow::Error>(())
                    });
                }
                while let Some(result) = downloads.join_next().await {
                    result??;
                }
                if let Destination::Disk(file) = &target {
                    file.sync_data()?;
                }
                let elapsed = started.elapsed().as_secs_f64();
                let received = match &target {
                    Destination::Memory(data) => data.lock().unwrap().clone(),
                    Destination::Disk(_) => std::fs::read(&path)?,
                };
                ensure!(
                    ring::digest::digest(&ring::digest::SHA256, &received).as_ref()
                        == expected_hash.as_ref(),
                    "The assembled original differs"
                );
                ensure!(fixture.peak.load(Ordering::SeqCst) == channels);
                println!(
                    "{}",
                    serde_json::json!({
                        "model": if shared { "shared_link_cap" } else { "per_connection_cap" },
                        "destination": if disk { "disk" } else { "memory" }, "channels": channels,
                        "seconds": elapsed, "mib_per_second": SIZE as f64 / (1 << 20) as f64 / elapsed,
                        "verified_bytes": received.len(), "peak_connections": fixture.peak.load(Ordering::SeqCst),
                    })
                );
            }
        }
    }
    Ok(())
}

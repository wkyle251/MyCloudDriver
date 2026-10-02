//! Exercise adaptive admission with real HTTP bodies and resumable disk writes.
use super::*;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use tokio::io::AsyncReadExt;

#[test]
fn disk_downloads_expand_during_live_bodies_and_preserve_resumed_contents() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "disk_download_tests::disk_throughput_child", "--ignored"])
        .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
        .output().unwrap();
    assert!(output.status.success(), "{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
}

#[tokio::test]
#[ignore = "isolated aggregate counters; launched by disk_downloads_expand_during_live_bodies_and_preserve_resumed_contents"]
async fn disk_throughput_child() {
    const FILES: usize = 10;
    const SIZE: usize = 32 * 1024 * 1024;
    const EXISTING: usize = 16 * 1024;
    let directory = tempfile::tempdir().unwrap();
    for id in 0..FILES {
        std::fs::write(
            directory.path().join(format!("{id}.part")),
            vec![id as u8; EXISTING],
        )
        .unwrap();
        download_transport::seed_resume(&directory.path().join(format!("{id}.part")),
            &format!("disk-throughput-{id}"), SIZE as u64, "\"fixture\"");
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let completed = Arc::new(AtomicUsize::new(0));
    let expanded_before_completion = Arc::new(AtomicBool::new(false));
    let server = {
        let active = active.clone();
        let peak = peak.clone();
        let completed = completed.clone();
        let expanded = expanded_before_completion.clone();
        tokio::spawn(async move {
            let mut bodies = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let (mut socket, _) = accepted.unwrap();
                        let active = active.clone();
                        let peak = peak.clone();
                        let completed = completed.clone();
                        let expanded = expanded.clone();
                        bodies.spawn(async move {
                            let mut request = Vec::new();
                            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                                let mut buffer = [0; 1024];
                                let count = socket.read(&mut buffer).await.unwrap();
                                assert!(count > 0);
                                request.extend_from_slice(&buffer[..count]);
                            }
                            let request = String::from_utf8(request).unwrap().to_ascii_lowercase();
                            let id: usize = request.split_whitespace().nth(1).unwrap().trim_start_matches('/').parse().unwrap();
                            assert!(request.contains(&format!("range: bytes={EXISTING}-\r\n")));
                            assert_eq!(request.contains("referer: https://mypikpak.com/\r\n"), id % 2 == 1);
                            let count = active.fetch_add(1, Ordering::SeqCst) + 1;
                            peak.fetch_max(count, Ordering::SeqCst);
                            if count == 8 && completed.load(Ordering::SeqCst) == 0 {
                                expanded.store(true, Ordering::SeqCst);
                            }
                            let header = format!("HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {EXISTING}-{}/{}\r\nConnection: close\r\n\r\n", SIZE - EXISTING, SIZE - 1, SIZE);
                            socket.write_all(header.as_bytes()).await.unwrap();
                            let chunk = [id as u8; 32 * 1024];
                            let mut remaining = SIZE - EXISTING;
                            while remaining > 0 {
                                let length = remaining.min(chunk.len());
                                socket.write_all(&chunk[..length]).await.unwrap();
                                remaining -= length;
                                // Each stream supplies about 0.8 MB/s, so two
                                // more exceed the 1 MB/s gain required to retain
                                // a trial. Keep bodies alive through both rolling
                                // trials; once proven, finish the fixture quickly.
                                if !expanded.load(Ordering::SeqCst) {
                                    tokio::time::sleep(Duration::from_millis(40)).await;
                                }
                            }
                            socket.shutdown().await.unwrap();
                            active.fetch_sub(1, Ordering::SeqCst);
                        });
                    }
                    result = bodies.join_next(), if !bodies.is_empty() => { result.unwrap().unwrap(); }
                }
            }
        })
    };
    let received = Arc::new(AtomicU64::new(0));
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let mut settled = 0;
    let transfer = transfer_control::schedule(
        (0..FILES).collect(),
        transfer_control::Concurrency::download(8, received.clone()),
        |id| {
            let http = http.clone();
            let received = received.clone();
            let completed = completed.clone();
            let partial = directory.path().join(format!("{id}.part"));
            async move {
                let file_id = format!("disk-throughput-{id}");
                let mut progress = DownloadProgressContext::new(false, &file_id, "fixture");
                progress.batch_received_bytes = Some(received);
                download_attempt_with_http(
                    &http,
                    &format!("http://{address}/{id}"),
                    SIZE as u64,
                    &partial,
                    false,
                    progress,
                    (id % 2 == 1).then_some("https://mypikpak.com/"),
                )
                .await
                .map_err(DlError::into_inner)?;
                completed.fetch_add(1, Ordering::SeqCst);
                Ok(())
            }
        },
        |id| format!("disk-throughput-{id}"),
        |_, result| {
            result.unwrap();
            settled += 1;
        },
        |_, _, _| panic!("healthy fixture should not retry"),
    );
    let result = tokio::time::timeout(Duration::from_secs(35), transfer).await;
    server.abort();
    result
        .expect("admission must expand before the initial bodies finish")
        .unwrap();
    assert_eq!(settled, FILES);
    assert!(expanded_before_completion.load(Ordering::SeqCst));
    assert_eq!(peak.load(Ordering::SeqCst), 8);
    assert_eq!(
        received.load(Ordering::Relaxed),
        (FILES * (SIZE - EXISTING)) as u64
    );
    for id in 0..FILES {
        assert_eq!(
            std::fs::read(directory.path().join(format!("{id}.part"))).unwrap(),
            vec![id as u8; SIZE]
        );
    }
}

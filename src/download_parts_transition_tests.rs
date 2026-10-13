//! Generated loopback fixtures for the sparse-to-serial ownership boundary.
use super::*;
use std::os::unix::fs::MetadataExt;
#[path = "download_range_fixture.rs"]
mod fixture;

const SOURCE: &str = "generated-transition-source";
const REVISION: &str = "gcid:0123456789abcdef0123456789abcdef01234567";

fn context() -> DownloadProgressContext<'static> {
    let mut context = DownloadProgressContext::new(false, "generated-transition", "generated.bin");
    context.source_file_id = SOURCE;
    context.source_revision = Some(REVISION.into());
    context.require_content_hash = true;
    context
}

fn seed(part: &Path, total: u64) {
    std::fs::write(part, b"abc").unwrap();
    ResumeState {
        file_id: SOURCE.into(),
        total,
        etag: String::new(),
        source_revision: Some(REVISION.into()),
        require_content_hash: true,
        source_key: Some("generated-previous-guest-route".into()),
        durable_bytes: Some(3),
        unverified_tail: None,
        prefix_sha256: Some(integrity::fixture_digest(part, 0, 3)),
    }
    .save(part)
    .unwrap();
}

fn snapshot(part: &Path) -> (u64, u64, u64, i64, i64, i64, i64) {
    let metadata = crate::download_fs::metadata(part).unwrap();
    (
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    )
}

#[tokio::test]
async fn serial_to_ranges_checks_prefix_once_and_keeps_the_final_disk_pass() {
    for damaged in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated-promotion.part");
        let remote = fixture::Fixture::new(64 << 20).await;
        let prefix = 25 << 20;
        let original = fixture::bytes(0, prefix, 1);
        std::fs::write(&part, &original).unwrap();
        let mut saved = ResumeState {
            file_id: SOURCE.into(), total: remote.size, etag: "\"fixture-1\"".into(),
            source_revision: Some(REVISION.into()), require_content_hash: true,
            source_key: Some(source_key(&remote.url)), durable_bytes: Some(prefix as u64),
            unverified_tail: None, prefix_sha256: Some(integrity::fixture_digest(&part, 0, prefix as u64)),
        };
        if damaged { saved.prefix_sha256 = Some("00".repeat(32)); }
        saved.save(&part).unwrap();
        let id = format!("generated-promotion-{damaged}");
        let reads = crate::download_transport::completion_tests::ReadCounter::new(&id);
        let mut progress = DownloadProgressContext::new(false, &id, "generated.bin");
        progress.source_file_id = SOURCE; progress.source_revision = Some(REVISION.into());
        progress.require_content_hash = true;
        let outcome = attempt_outcome(&reqwest::Client::builder().no_proxy().build().unwrap(),
            &remote.url, remote.size, &part, false, &progress, None).await.map_err(DlError::into_inner).unwrap();
        if damaged {
            assert!(matches!(outcome, Outcome::Sequential { staging_changed: false }));
            assert_eq!(reads.bytes(), prefix as u64);
            assert_eq!(std::fs::read(&part).unwrap(), original);
            assert!(!exists(&part));
            assert!(!state_path(&part).exists(), "Changed checkpoint proof must be withdrawn");
        } else {
            assert!(matches!(outcome, Outcome::Complete(_)));
            assert_eq!(reads.bytes(), prefix as u64 + remote.size,
                "Promotion reads the prefix once; publication still verifies every completed byte");
            let data = std::fs::read(&part).unwrap();
            assert_eq!(data.len() as u64, remote.size);
            assert!(data.iter().enumerate().all(|(offset, byte)| *byte == fixture::byte(offset as u64, 1)));
        }
    }
}

async fn request(socket: &mut tokio::net::TcpStream) -> String {
    let mut bytes = Vec::new();
    while !bytes.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
        let mut buffer = [0; 4096];
        let read = socket.read(&mut buffer).await.unwrap();
        assert!(read > 0);
        bytes.extend_from_slice(&buffer[..read]);
    }
    String::from_utf8(bytes).unwrap().to_lowercase()
}

#[tokio::test]
async fn small_serial_decline_keeps_the_existing_verified_prefix_without_disk_mutation() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    seed(&part, 8);
    let verified = recover_durable_prefix(&part, SOURCE, 8, "generated-transition")
        .await
        .map_err(DlError::into_inner)
        .unwrap()
        .unwrap();
    let before = snapshot(&part);
    let journal = std::fs::read(state_path(&part)).unwrap();
    let result = attempt_outcome(
        &reqwest::Client::builder().no_proxy().build().unwrap(),
        "http://127.0.0.1:1/generated-unreachable",
        8,
        &part,
        false,
        &context(),
        None,
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap();
    assert!(matches!(
        result,
        Outcome::Sequential {
            staging_changed: false
        }
    ));
    verified
        .validate_restored(&crate::download_fs::metadata(&part).unwrap())
        .map_err(DlError::into_inner)
        .unwrap();
    assert_eq!(snapshot(&part), before);
    assert_eq!(std::fs::read(state_path(&part)).unwrap(), journal);
    assert_eq!(std::fs::read(&part).unwrap(), b"abc");
    assert!(!exists(&part));
}

#[tokio::test]
async fn fresh_unsupported_probe_decline_keeps_the_original_prefix_proof() {
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let total = download_ranges::MIN_PARALLEL_SIZE;
    seed(&part, total);
    let verified = recover_durable_prefix(&part, SOURCE, total, "generated-transition")
        .await
        .map_err(DlError::into_inner)
        .unwrap()
        .unwrap();
    let before = snapshot(&part);
    let journal = std::fs::read(state_path(&part)).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/generated", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let observed = request(&mut socket).await;
        socket.write_all(b"HTTP/1.1 200 OK\r\nETag: \"generated-user\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
        observed
    });
    let result = attempt_outcome(
        &reqwest::Client::builder().no_proxy().build().unwrap(),
        &url,
        total,
        &part,
        false,
        &context(),
        None,
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap();
    assert!(matches!(
        result,
        Outcome::Sequential {
            staging_changed: false
        }
    ));
    assert!(server.await.unwrap().contains("range: bytes=0-0\r\n"));
    verified
        .validate_restored(&crate::download_fs::metadata(&part).unwrap())
        .map_err(DlError::into_inner)
        .unwrap();
    assert_eq!(snapshot(&part), before);
    assert_eq!(std::fs::read(state_path(&part)).unwrap(), journal);
    assert!(!exists(&part));
}

#[tokio::test]
async fn external_edit_or_replacement_after_fallback_rehash_is_rejected_before_serial_append() {
    for replacement in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        let total = download_ranges::MIN_PARALLEL_SIZE;
        seed(&part, total);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/generated", listener.local_addr().unwrap());
        let changed_part = part.clone();
        let server = tokio::spawn(async move {
            let mut observed = Vec::new();
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let text = request(&mut socket).await;
                let range = text
                    .lines()
                    .find_map(|line| line.strip_prefix("range: "))
                    .unwrap();
                observed.push(range.to_owned());
                if range == "bytes=0-0" {
                    let headers = format!("HTTP/1.1 206 OK\r\nETag: \"generated-user\"\r\nContent-Range: bytes 0-0/{total}\r\nContent-Length: 1\r\nConnection: close\r\n\r\na");
                    socket.write_all(headers.as_bytes()).await.unwrap();
                } else if range == "bytes=3-" {
                    // This request proves the newly restored checkpoint was
                    // read and used for the suffix. Mutate only after that
                    // proof, while the normal strict reopen guard still runs.
                    let journal = std::fs::read(state_path(&changed_part)).unwrap();
                    if replacement {
                        let changed = changed_part.with_file_name("generated replacement.part");
                        std::fs::write(&changed, b"xyz").unwrap();
                        std::fs::rename(&changed, &changed_part).unwrap();
                    } else {
                        std::fs::write(&changed_part, b"xyz").unwrap();
                    }
                    let headers = format!("HTTP/1.1 206 OK\r\nETag: \"generated-user\"\r\nContent-Range: bytes 3-{}/{total}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", total - 1, total - 3);
                    socket.write_all(headers.as_bytes()).await.unwrap();
                    return (observed, journal);
                } else {
                    // A bounded piece declines range support after its probe;
                    // no payload is accepted or written by that connection.
                    socket.write_all(b"HTTP/1.1 200 OK\r\nETag: \"generated-user\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
                }
            }
        });
        let context = context();
        let result = tokio::time::timeout(
            Duration::from_secs(8),
            super::super::attempt(
                &reqwest::Client::builder().no_proxy().build().unwrap(),
                &url,
                total,
                &part,
                false,
                context.clone(),
                None,
            ),
        )
        .await
        .unwrap();
        let error = result
            .err()
            .expect("An externally changed prefix was appended")
            .into_inner();
        assert!(
            format!("{error:#}").contains("Download staging file changed after verifying progress"),
            "{error:#}"
        );
        let (observed, journal) = tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(observed.first().map(String::as_str), Some("bytes=0-0"));
        assert!(observed
            .iter()
            .any(|range| range != "bytes=0-0" && !range.ends_with('-')));
        assert_eq!(observed.last().map(String::as_str), Some("bytes=3-"));
        assert_eq!(std::fs::read(&part).unwrap(), b"xyz");
        assert_eq!(std::fs::read(state_path(&part)).unwrap(), journal);
        assert_eq!(context.transferred_bytes(), 0);
        assert!(!exists(&part));
    }
}

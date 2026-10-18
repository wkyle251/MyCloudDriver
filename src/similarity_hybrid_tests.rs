//! Cross-drive tests use generated text and a loopback provider only.
use super::*;
use std::sync::atomic::AtomicUsize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct CloudFixture {
    client: Client,
    downloads: Arc<AtomicUsize>,
    server: tokio::task::JoinHandle<()>,
}
impl Drop for CloudFixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}
impl CloudFixture {
    async fn new(contents: HashMap<String, String>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let downloads = Arc::new(AtomicUsize::new(0));
        let transferred = downloads.clone();
        let contents = Arc::new(contents);
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    return;
                };
                let contents = contents.clone();
                let transferred = transferred.clone();
                tokio::spawn(async move {
                    let mut bytes = Vec::new();
                    let mut buffer = [0; 4096];
                    let route = loop {
                        let read = socket.read(&mut buffer).await.unwrap();
                        if read == 0 {
                            return;
                        }
                        bytes.extend_from_slice(&buffer[..read]);
                        let text = String::from_utf8_lossy(&bytes);
                        if let Some(end) = text.find("\r\n\r\n") {
                            let length = text[..end]
                                .lines()
                                .find_map(|line| {
                                    line.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .and_then(|value| value.trim().parse::<usize>().ok())
                                })
                                .unwrap_or(0);
                            if bytes.len() >= end + 4 + length {
                                break text
                                    .lines()
                                    .next()
                                    .unwrap()
                                    .split_whitespace()
                                    .nth(1)
                                    .unwrap()
                                    .to_owned();
                            }
                        }
                    };
                    let body = if route.contains("/auth/token") {
                        json!({"access_token":"generated-access","refresh_token":"generated-refresh","expires_in":3600,"sub":"generated-user"}).to_string()
                    } else if route.contains("/shield/captcha/init") {
                        json!({"captcha_token":"generated-captcha","expires_in":3600}).to_string()
                    } else if let Some(id) = route.strip_prefix("/content/") {
                        transferred.fetch_add(1, Ordering::AcqRel);
                        contents.get(id).unwrap().clone()
                    } else {
                        let id = route
                            .strip_prefix("/drive/v1/files/")
                            .unwrap()
                            .split('?')
                            .next()
                            .unwrap();
                        let content = contents.get(id).unwrap();
                        json!({"id":id,"name":format!("{id}.txt"),"kind":"drive#file","size":content.len().to_string(),
                            "hash":if id=="b" { "ab".repeat(20) } else { "cd".repeat(20) },"web_content_link":format!("http://{address}/content/{id}"),"trashed":false}).to_string()
                    };
                    let _ = socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await;
                });
            }
        });
        let client = Client::builder()
            .refresh_token("generated-refresh")
            .device_id("generated-device")
            .api_base_url(format!("http://{address}"))
            .auth_base_url(format!("http://{address}"))
            .build()
            .unwrap();
        Self {
            client,
            downloads,
            server,
        }
    }
}

fn cloud_item(id: &str, bytes: usize) -> CloudItem {
    CloudItem {
        id: id.into(),
        name: format!("{id}.txt"),
        path: format!("/PikPak/{id}.txt"),
        is_folder: false,
        size: bytes as u64,
        ancestors: vec![],
        revision: None,
    }
}
fn native_file(path: &Path) -> ExternalSource {
    ExternalSource {
        provider: Some("local".into()),
        id: "cross-native:local:stable-a".into(),
        name: "a.txt".into(),
        path: "/Local/a.txt".into(),
        size: std::fs::metadata(path).unwrap().len(),
        local_path: Some(path.into()),
        revision: Some("generated-provider-version".into()),
        content_kind: None,
    }
}
fn write_inventory(path: &Path, file: &ExternalSource) {
    std::fs::write(
        path,
        format!(
            "{}\n{{\"event\":\"complete\"}}\n",
            json!({"event":"file","file":file})
        ),
    )
    .unwrap();
}

#[test]
fn hybrid_request_validation_keeps_legacy_source_boundaries() {
    let root = tempfile::tempdir().unwrap();
    let mut request = tests::request(root.path());
    request.cloud_items = vec![cloud_item("generated", 10)];
    assert!(
        request.validate().is_err(),
        "Raw local roots cannot accidentally mix with cloud roots"
    );
    request.local_paths.clear();
    let stream = root.path().join("native.jsonl");
    std::fs::write(&stream, b"{\"event\":\"complete\"}\n").unwrap();
    request.external_source_stream = Some(stream);
    assert!(
        request.validate().is_ok(),
        "Across Drives uses local source with both metadata inventories"
    );
    request.source = ScanSource::Cloud;
    assert!(
        request.validate().is_ok(),
        "Cloud-source legacy hosts can use the same union"
    );
    request.local_paths.push(root.path().join("extra"));
    assert!(request.validate().is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unified_cross_drive_scan_compares_and_reuses_files_across_changed_scopes() {
    let root = tempfile::tempdir().unwrap();
    let text = "Generated garden plan includes fruit trees, flowers, a pond, planting dates and detailed maintenance instructions. ".repeat(40);
    let edited = format!("{text}\nRevision: add a summer watering schedule.");
    let fixture = CloudFixture::new(HashMap::from([
        ("b".into(), text.clone()),
        ("c".into(), edited.clone()),
    ]))
    .await;
    let original = root.path().join("native-a.txt");
    std::fs::write(&original, &text).unwrap();
    let native = native_file(&original);
    let stream = root.path().join("native.jsonl");
    write_inventory(&stream, &native);
    let mut request = tests::request(root.path());
    request.local_paths.clear();
    request.external_source_stream = Some(stream);
    request.cloud_items = vec![cloud_item("b", text.len())];
    request.resources.workers = 2;
    request.validate().unwrap();

    let stopping = Arc::new(AtomicBool::new(false));
    let stop = stopping.clone();
    let acquisitions = Arc::new(AtomicUsize::new(0));
    let acquired = acquisitions.clone();
    let temporary = request.temp_dir.clone();
    let responder = tokio::spawn(async move {
        let mut answered = HashSet::new();
        while !stop.load(Ordering::Acquire) {
            for run in std::fs::read_dir(&temporary)
                .into_iter()
                .flatten()
                .flatten()
            {
                for source in std::fs::read_dir(run.path())
                    .into_iter()
                    .flatten()
                    .flatten()
                {
                    let target = source.path();
                    if target.join("content").is_dir()
                        && !target.join("source.json").exists()
                        && answered.insert(target.clone())
                    {
                        let reply = target.join("reply.tmp");
                        std::fs::write(&reply, json!({"id":native.id,"path":original}).to_string())
                            .unwrap();
                        std::fs::rename(reply, target.join("source.json")).unwrap();
                        acquired.fetch_add(1, Ordering::AcqRel);
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    });
    for (iteration, id) in ["b", "c", "b"].into_iter().enumerate() {
        request.cloud_items = vec![cloud_item(
            id,
            if id == "b" { text.len() } else { edited.len() },
        )];
        tokio::time::timeout(
            Duration::from_secs(15),
            scan(
                request.clone(),
                Some(&fixture.client),
                Arc::new(AtomicBool::new(false)),
            ),
        )
        .await
        .expect("Both inventories must finish together")
        .unwrap();
        let report: ScanReport =
            serde_json::from_slice(&std::fs::read(&request.report_path).unwrap()).unwrap();
        assert_eq!(report.source, ScanSource::Local);
        assert_eq!(report.status, "completed", "{:?}", report.issues);
        assert_eq!(report.scanned_files, 2);
        assert_eq!(report.analysed_files, 2);
        assert_eq!(
            report.scores_retained, 1,
            "One unified matrix contains the cross-drive pair"
        );
        let cloud = report
            .files
            .iter()
            .find(|file| file.cloud_id.as_deref() == Some(id))
            .unwrap();
        assert!(
            cloud.local_path.is_none(),
            "Cloud results never reveal a staging locator"
        );
        let native = report
            .files
            .iter()
            .find(|file| file.id.starts_with("cross-native:"))
            .unwrap();
        assert!(native.local_path.is_some());
        assert_ne!(cloud.id, native.id);
        if iteration != 1 {
            assert!(report
                .groups
                .iter()
                .any(|group| group.match_kind == "byte_identical" && group.member_count == 2));
        } else {
            let grouped = group_scores(
                GroupQuery {
                    data_dir: request.data_dir.clone(),
                    run_id: report.run_id.clone().unwrap(),
                    result_revision: report.result_revision.unwrap(),
                    minimum_score: 0.85,
                    include_identical: true,
                },
                &AtomicBool::new(false),
            )
            .unwrap();
            assert!(grouped
                .groups
                .iter()
                .any(|group| !group.identical && group.file_ids.len() == 2));
        }
        assert_eq!(
            acquisitions.load(Ordering::Acquire),
            1,
            "Unchanged native A must reuse its hash/vector after B becomes C"
        );
        assert_eq!(
            fixture.downloads.load(Ordering::Acquire),
            (iteration + 1).min(2),
            "Unchanged cloud originals must reuse their per-file cache"
        );
        let db = rusqlite::Connection::open(
            request
                .data_dir
                .join("runs")
                .join(format!("{}.sqlite3", report.run_id.as_ref().unwrap())),
        )
        .unwrap();
        let summary: String = db
            .query_row("SELECT summary FROM run", [], |row| row.get(0))
            .unwrap();
        let summary: Value = serde_json::from_str(&summary).unwrap();
        assert!(summary["counts"]["cache_hits"].as_u64().unwrap() >= u64::from(iteration > 0));
        if iteration == 2 {
            assert_eq!(summary["counts"]["cache_hits"], 2);
            assert_eq!(summary["counts"]["vectors_encoded"], 0);
            assert_eq!(summary["counts"]["bytes_hashed"], 0);
        }
    }
    stopping.store(true, Ordering::Release);
    responder.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hybrid_inventory_refresh_never_certifies_a_missing_provider() {
    let root = tempfile::tempdir().unwrap();
    let fixture = CloudFixture::new(HashMap::from([(
        "cloud".into(),
        "generated content".into(),
    )]))
    .await;
    let original = root.path().join("native.txt");
    std::fs::write(&original, b"generated content").unwrap();
    let stream = root.path().join("native.jsonl");
    write_inventory(&stream, &native_file(&original));
    let mut request = tests::request(root.path());
    request.local_paths.clear();
    request.cloud_items = vec![cloud_item("cloud", 17)];
    request.external_source_stream = Some(stream.clone());
    let report = || {
        serde_json::from_value(json!({"source":"local","scope":[],"status":"completed","threshold":0.8,
        "scanned_files":0,"analysed_files":0,"skipped_files":0,"downloaded_bytes":0,"total_groups":0,"groups":[],
        "issues":[],"files":[],"scores_retained":0,"truncated":false,"coverage":"","elapsed_seconds":0.0})).unwrap()
    };
    let cancel = Arc::new(AtomicBool::new(false));
    let token = filetwin_core::api::CancellationToken::default();
    let runtime = tokio::runtime::Handle::current();
    let capture = || {
        inventory::capture(
            &request,
            root.path(),
            &cancel,
            Some(&fixture.client),
            &runtime,
            &token,
            report(),
        )
    };
    let before = capture().unwrap();
    assert_eq!(before.files.len(), 2);
    std::fs::write(
        &stream,
        b"{\"event\":\"error\",\"message\":\"Generated provider unavailable\"}\n",
    )
    .unwrap();
    assert!(
        capture().is_err(),
        "Cloud success cannot certify the missing native drive as deletions"
    );
    std::fs::write(&stream, b"{\"event\":\"complete\"}\n").unwrap();
    let after = capture().unwrap();
    assert_eq!(after.files.len(), 1);
    assert!(after.files[0].cloud.is_some());
    assert_eq!(inventory::changes(&before.files, &after.files).removed, 1);
    std::fs::write(&stream, b"").unwrap();
    let stop = cancel.clone();
    let cancelling = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(60));
        stop.store(true, Ordering::Release);
    });
    let began = Instant::now();
    assert!(capture().is_err());
    cancelling.join().unwrap();
    assert!(
        began.elapsed() < Duration::from_secs(2),
        "Cancelling a mixed scan releases an idle native inventory reader"
    );
}

#[test]
fn namespaced_photos_keeps_memory_and_preview_identity_rules() {
    let mut source = ExternalSource {
        provider: Some("photos".into()),
        id: "cross-native:photos:generated-asset".into(),
        name: "generated.jpg".into(),
        path: "/Photos/generated.jpg".into(),
        size: 0,
        local_path: None,
        revision: Some("generated-version".into()),
        content_kind: Some(ExternalContentKind::PhotosPreview),
    };
    let file = scope::InputFile::external(source.clone());
    assert!(file.is_photos_source());
    assert!(file.is_photos_preview());
    assert!(file.exact_identity().is_none());
    source.provider = None;
    source.content_kind = None;
    source.id = "asset:legacy-generated".into();
    assert!(scope::InputFile::external(source).is_photos_source());
}

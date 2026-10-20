use super::*;
use std::os::unix::fs::{symlink, MetadataExt};

#[tokio::test]
async fn cloud_downloads_continue_while_every_analysis_worker_is_busy() {
    cloud_pipeline_overlap(false).await;
}
#[tokio::test]
async fn automatic_cloud_downloads_overlap_analysis_and_keep_all_results() {
    cloud_pipeline_overlap(true).await;
}
async fn cloud_pipeline_overlap(automatic: bool) {
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::AtomicUsize;
    use tokio::io::AsyncReadExt;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let mut r = tests::request(&root);
    r.source = ScanSource::Cloud;
    r.local_paths.clear();
    r.families = vec!["image".into()];
    r.resources.workers = 2;
    r.resources.memory_bytes = 2 << 30;
    r.resources.automatic_memory = automatic;
    std::fs::create_dir_all(&r.model_dir).unwrap();
    std::fs::write(
        r.model_dir.join(filetwin_core::profile::SSCD_MODEL_FILE),
        [],
    )
    .unwrap();
    let library = root.join("fixture-library");
    std::fs::write(&library, []).unwrap();
    r.runtime.onnxruntime_path = Some(library);
    let ready = root.join("four-downloads-finished");
    let worker = root.join("fixture-worker");
    std::fs::write(&worker, format!(r#"#!/usr/bin/python3 -u
import json,sys,time,pathlib,urllib.request
gate=pathlib.Path({gate})
for line in sys.stdin:
 r=json.loads(line)
 assert 'memory_input' in r and not pathlib.Path(r['path']).is_absolute()
 with urllib.request.urlopen(r['memory_input']['url']) as response: data=response.read()
 assert data.startswith(b'\x89PNG\r\n\x1a\n')
 deadline=time.monotonic()+8
 while not gate.exists() and time.monotonic()<deadline: time.sleep(.01)
 assert gate.exists(), 'Downloads stopped while analysis occupied both workers'
 print(json.dumps({{'version':r['version'],'result':{{'Ok':{{'family':'image','format':'fixture','vector':[1.0]+[0.0]*511,'extraction':{{'input_storage':'memory'}}}}}}}}),flush=True)
"#, gate = serde_json::to_string(&ready).unwrap())).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    r.runtime.worker_path = Some(worker);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let downloads = Arc::new(AtomicUsize::new(0));
    let completed = downloads.clone();
    let server = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            let ready = ready.clone();
            let completed = completed.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buffer = [0; 4096];
                let route = loop {
                    let n = stream.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    data.extend_from_slice(&buffer[..n]);
                    let text = String::from_utf8_lossy(&data);
                    if let Some(end) = text.find("\r\n\r\n") {
                        let length = text[..end]
                            .lines()
                            .find_map(|line| {
                                line.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if data.len() >= end + 4 + length {
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
                let content = route.starts_with("/content/");
                let body = if route.starts_with("/v1/auth/token") {
                    json!({"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"sub":"fixture-user"}).to_string().into_bytes()
                } else if route.starts_with("/v1/shield/captcha/init") {
                    json!({"captcha_token":"fixture-captcha","expires_in":3600})
                        .to_string()
                        .into_bytes()
                } else if route.starts_with("/drive/v1/files/") {
                    let id = route
                        .trim_start_matches("/drive/v1/files/")
                        .split('?')
                        .next()
                        .unwrap();
                    json!({"id":id,"size":"9","web_content_link":format!("http://{address}/content/{id}")}).to_string().into_bytes()
                } else if content {
                    let id: u8 = route.trim_start_matches("/content/").parse().unwrap();
                    [b"\x89PNG\r\n\x1a\n".as_slice(), &[id]].concat()
                } else {
                    panic!("Unexpected fixture route");
                };
                let header = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                stream.write_all(header.as_bytes()).await.unwrap();
                stream.write_all(&body).await.unwrap();
                if content && completed.fetch_add(1, Ordering::AcqRel) + 1 >= 4 {
                    std::fs::write(ready, []).unwrap();
                }
            });
        }
    });
    r.cloud_items = (0..12)
        .map(|i| CloudItem {
            revision: None,
            id: i.to_string(),
            name: format!("{i}.png"),
            path: format!("/{i}.png"),
            is_folder: false,
            size: 9,
            ancestors: vec![],
        })
        .collect();
    let client = Client::builder()
        .refresh_token("fixture-refresh")
        .device_id("fixture-device")
        .api_base_url(format!("http://{address}"))
        .auth_base_url(format!("http://{address}"))
        .build()
        .unwrap();
    scan(r.clone(), Some(&client), Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    server.abort();
    let report = read_report(&r);
    assert_eq!(report.analysed_files, 12, "{:?}", report.issues);
    assert_eq!(report.failed_files, 0);
    assert_eq!(downloads.load(Ordering::Acquire), 12);
    assert_eq!(report.scores_retained, 66);
    assert!(
        std::fs::read_dir(&r.temp_dir).unwrap().next().is_none(),
        "No original or source scratch files remain"
    );
}

fn read_report(r: &ScanRequest) -> ScanReport {
    serde_json::from_slice(&std::fs::read(&r.report_path).unwrap()).unwrap()
}

#[tokio::test]
async fn unsupported_binary_coverage_and_diagnostics_are_retained_beyond_the_display_limit() {
    let dir = tempfile::tempdir().unwrap();
    let r = tests::request(dir.path());
    std::fs::create_dir_all(&r.local_paths[0]).unwrap();
    for i in 0..520 {
        std::fs::write(
            r.local_paths[0].join(format!("data-{i}.dat")),
            [0, 255, 3, 4],
        )
        .unwrap();
    }
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let report = read_report(&r);
    assert_eq!(report.unsupported_files, 520);
    assert_eq!(report.failed_files, 0);
    assert_eq!(report.issues.len(), 500);
    assert_eq!(
        report.issue_summary.iter().map(|s| s.count).sum::<u64>(),
        520
    );
    assert!(report
        .issue_summary
        .iter()
        .all(|s| s.category == "unsupported"));
    assert_eq!(report.status, "partial");
    assert_eq!(
        report.groups.len(),
        1,
        "Exact-copy matching remains available for binary inputs"
    );
    assert_eq!(report.groups[0].member_count, 520);
    let path = r
        .data_dir
        .join("runs")
        .join(format!("{}.sqlite3", report.run_id.unwrap()));
    let db =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    let stored: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM files WHERE diagnostic IS NOT NULL AND digest IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(stored, 520);
    let diagnostic: String = db
        .query_row("SELECT diagnostic FROM files LIMIT 1", [], |r| r.get(0))
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&diagnostic).unwrap()["code"],
        "unsupported_format"
    );
    assert!(
        !diagnostic.contains("data-"),
        "Diagnostics must not contain hidden engine paths"
    );
}

#[test]
fn coverage_reasons_distinguish_binary_text_media_duration_memory_and_worker_errors() {
    use filetwin_core::{Error, ErrorCode::*};
    let reason =
        |code, stage, message| encoding::error_reason(Some(&Error::new(code, stage, message)));
    assert!(reason(InvalidText, "encoding", "Input is not UTF-8").contains("UTF-8"));
    assert!(reason(
        InsufficientContent,
        "media",
        "A finite positive media duration is required"
    )
    .contains("duration"));
    assert!(reason(WorkerFailed, "worker", "Private diagnostic").contains("worker"));
    assert!(!reason(WorkerFailed, "worker", "Private diagnostic").contains("Private"));
    assert!(reason(ResourceBudgetTooSmall, "image", "Memory limit").contains("RAM"));
    let mut contention = Error::new(ResourceBudgetTooSmall, "memory", "Private diagnostic");
    contention.details = Box::new(json!({"retry_after_drain":true}));
    let message = encoding::error_reason(Some(&contention));
    assert!(message.contains("Retry this file") && !message.contains("Increase") && !message.contains("Private"));
    assert!(reason(IoError, "fetching", "Access denied").contains("fetch"));
}
fn summary(r: &ScanRequest, report: &ScanReport) -> Value {
    let path = r
        .data_dir
        .join("runs")
        .join(format!("{}.sqlite3", report.run_id.as_ref().unwrap()));
    let db =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    serde_json::from_str(
        &db.query_row("SELECT summary FROM run", [], |r| r.get::<_, String>(0))
            .unwrap(),
    )
    .unwrap()
}

#[tokio::test]
async fn cloud_analysis_starts_before_pagination_finishes_and_listing_recovers() {
    use std::sync::atomic::AtomicUsize;
    use tokio::io::AsyncReadExt;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let downloads = Arc::new(AtomicUsize::new(0));
    let attempts = Arc::new(AtomicUsize::new(0));
    let overlapped = Arc::new(AtomicBool::new(false));
    let active_downloads = Arc::new(AtomicUsize::new(0));
    let peak_downloads = Arc::new(AtomicUsize::new(0));
    let state = (
        downloads.clone(),
        attempts.clone(),
        overlapped.clone(),
        active_downloads.clone(),
        peak_downloads.clone(),
    );
    let server = tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let (downloads, attempts, overlapped, active_downloads, peak_downloads) = state.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buffer = [0u8; 4096];
                let header = loop {
                    let n = stream.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    data.extend_from_slice(&buffer[..n]);
                    let text = String::from_utf8_lossy(&data);
                    if let Some(end) = text.find("\r\n\r\n") {
                        let length = text[..end]
                            .lines()
                            .find_map(|line| {
                                line.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if data.len() >= end + 4 + length {
                            break text[..end].to_string();
                        }
                    }
                };
                let route = header.lines().next().unwrap();
                let content = "A garden with trees, flowers and a small pond. ".repeat(20);
                let mut status = 200;
                let response = if route.starts_with("POST /v1/auth/token") {
                    json!({"access_token":"test-access", "refresh_token":"test-refresh", "expires_in":3600, "sub":"test-user"}).to_string()
                } else if route.starts_with("POST /v1/shield/captcha/init") {
                    json!({"captcha_token":"test-captcha", "expires_in":3600}).to_string()
                } else if route.starts_with("GET /drive/v1/files?") {
                    if attempts.fetch_add(1, Ordering::AcqRel) == 0 {
                        status = 503;
                        json!({"error":"temporarily_unavailable"}).to_string()
                    } else if route.contains("page_token=second") {
                        let started = Instant::now();
                        while downloads.load(Ordering::Acquire) == 0
                            && started.elapsed() < Duration::from_secs(5)
                        {
                            tokio::time::sleep(Duration::from_millis(10)).await;
                        }
                        overlapped.store(downloads.load(Ordering::Acquire) > 0, Ordering::Release);
                        json!({"files":[{"id":"b", "name":"copy.txt", "kind":"drive#file", "size":content.len().to_string()}]}).to_string()
                    } else {
                        json!({"files":[{"id":"a", "name":"garden.txt", "kind":"drive#file", "size":content.len().to_string()}], "next_page_token":"second"}).to_string()
                    }
                } else if route.starts_with("GET /drive/v1/files/") {
                    json!({"id":"file", "size":content.len().to_string(), "web_content_link":format!("http://{address}/content")}).to_string()
                } else if route.starts_with("GET /content") {
                    downloads.fetch_add(1, Ordering::AcqRel);
                    let active = active_downloads.fetch_add(1, Ordering::AcqRel) + 1;
                    peak_downloads.fetch_max(active, Ordering::AcqRel);
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    active_downloads.fetch_sub(1, Ordering::AcqRel);
                    content
                } else {
                    panic!("Unexpected fixture route: {route}");
                };
                let _ = stream.write_all(format!("HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).as_bytes()).await;
            });
        }
    });
    let client = Client::builder()
        .refresh_token("test-refresh")
        .device_id("test-device")
        .api_base_url(format!("http://{address}"))
        .auth_base_url(format!("http://{address}"))
        .build()
        .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mut r = tests::request(dir.path());
    r.resources.memory_bytes = 2 << 30; // Two decoder slots plus RAM originals.
    r.source = ScanSource::Cloud;
    r.local_paths.clear();
    r.cloud_items = vec![CloudItem {
        revision: None,
        id: "".into(),
        name: "PikPak".into(),
        path: "/".into(),
        is_folder: true,
        size: 0,
        ancestors: vec![],
    }];
    scan(r.clone(), Some(&client), Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    server.abort();
    let report = read_report(&r);
    assert!(
        overlapped.load(Ordering::Acquire),
        "The first page must feed analysis before the second page returns"
    );
    assert!(
        attempts.load(Ordering::Acquire) >= 3,
        "A transient folder listing must retry"
    );
    assert_eq!(report.status, "completed");
    assert_eq!(report.analysed_files, 2);
    assert_eq!(downloads.load(Ordering::Acquire), 2);
    assert_eq!(
        peak_downloads.load(Ordering::Acquire),
        2,
        "PikPak originals must fetch concurrently inside the two processing slots"
    );
    assert_eq!(report.total_groups, 1);
}

#[tokio::test]
async fn failed_provider_discovery_surfaces_a_failed_scan_with_its_reason() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = tests::request(dir.path());
    r.local_paths.clear();
    let inventory = dir.path().join("inventory.jsonl");
    std::fs::write(
        &inventory,
        "{\"event\":\"error\",\"message\":\"Library access was removed\"}\n",
    )
    .unwrap();
    r.external_source_stream = Some(inventory);
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let report = read_report(&r);
    assert_eq!(report.status, "failed");
    assert_eq!(report.analysed_files, 0);
    assert!(report
        .issues
        .iter()
        .any(|issue| issue.reason.contains("Library access was removed")));
    let auth = cloud_listing_error(
        &crate::Error::Auth("private token must not be displayed".into()).into(),
    );
    assert!(auth.contains("Settings") && !auth.contains("private token"));
}

#[tokio::test]
async fn unavailable_external_originals_report_failure_and_continue_the_queue() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = tests::request(dir.path());
    r.local_paths.clear();
    r.external_sources = ["one", "two"]
        .into_iter()
        .map(|id| ExternalSource {
            provider: None,
            content_kind: None,
            revision: None,
            id: id.into(),
            name: format!("{id}.png"),
            path: format!("Photos/{id}.png"),
            size: 1,
            local_path: None,
        })
        .collect();
    let cancel = Arc::new(AtomicBool::new(false));
    let mut running = {
        let r = r.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move { scan(r, None, cancel).await })
    };
    let responder = async {
        let mut answered = HashSet::new();
        for id in ["one", "two"] {
            loop {
                let runs = std::fs::read_dir(&r.temp_dir)
                    .into_iter()
                    .flatten()
                    .flatten();
                let mut target = None;
                for run in runs {
                    for source in std::fs::read_dir(run.path())
                        .into_iter()
                        .flatten()
                        .flatten()
                    {
                        if !answered.contains(&source.path())
                            && source.file_name().to_string_lossy().starts_with("source-")
                            && source.path().join("content").is_dir()
                            && !source.path().join("source.json").exists()
                        {
                            target = Some(source.path());
                            break;
                        }
                    }
                }
                if let Some(target) = target {
                    answered.insert(target.clone());
                    let reply = target.join("reply.tmp");
                    std::fs::write(
                        &reply,
                        serde_json::to_vec(&json!({"id":id,"error":"Original unavailable"}))
                            .unwrap(),
                    )
                    .unwrap();
                    std::fs::rename(reply, target.join("source.json")).unwrap();
                    break;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
    };
    let replied = tokio::time::timeout(Duration::from_secs(5), responder)
        .await
        .is_ok();
    if !replied {
        cancel.store(true, Ordering::SeqCst);
    }
    let completed = tokio::time::timeout(Duration::from_secs(5), &mut running).await;
    let finished_in_time = completed.is_ok();
    if let Ok(result) = completed {
        result.unwrap().unwrap();
    } else {
        cancel.store(true, Ordering::SeqCst);
        running.await.unwrap().unwrap();
    }
    assert!(finished_in_time, "Replies must be consumed promptly");
    assert!(
        replied,
        "Every failed original must allow the next queued ID to be requested"
    );
    let report = read_report(&r);
    assert_eq!(report.status, "failed");
    assert_eq!(report.skipped_files, 2);
    assert_eq!(report.files.len(), 2);
    assert!(report.files.iter().all(|file| file.state == "failed"));
    assert_eq!(std::fs::read_dir(&r.temp_dir).unwrap().count(), 0);
}

#[tokio::test]
async fn custom_resources_keep_files_larger_than_batch_target_and_publish_actual_workers() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = tests::request(dir.path());
    r.resources = ScanResources {
        acceleration: acceleration::Mode::Cpu,
        memory_scheduling: false,
        automatic_memory: false,
        workers: 64,
        memory_bytes: 512 << 20,
        download_memory_bytes: None,
        batch_files: 1,
        batch_bytes: 1 << 20,
    };
    std::fs::create_dir_all(&r.local_paths[0]).unwrap();
    let large = "The garden has flowers and a pond.\n".repeat(40_000);
    assert!(large.len() > r.resources.batch_bytes as usize);
    std::fs::write(r.local_paths[0].join("large.txt"), &large).unwrap();
    std::fs::write(r.local_paths[0].join("copy.txt"), &large).unwrap();
    std::fs::write(
        r.local_paths[0].join("small.txt"),
        "A small garden with flowers.",
    )
    .unwrap();
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let report = read_report(&r);
    assert_eq!(report.analysed_files, 3);
    assert_eq!(report.skipped_files, 0);
    let stored = summary(&r, &report);
    assert_eq!(
        stored["workers"], 1,
        "Native admission applies the 512 MiB allowance per worker"
    );
    assert_eq!(stored["resources"]["workers"], 64);
    assert_eq!(stored["resources"]["batch_files"], 1);
    assert_eq!(stored["counts"]["cache_hits"], 1);
    assert!(r.data_dir.join("filetwin-vectors.f32.zst").exists());
    assert!(!r.data_dir.join("filetwin-vectors.json").exists());
}

#[tokio::test]
async fn batches_preserve_copy_occurrences_and_reuse_vectors_across_renames_and_edits() {
    let dir = tempfile::tempdir().unwrap();
    let r = tests::request(dir.path());
    let files = &r.local_paths[0];
    std::fs::create_dir_all(files).unwrap();
    let content = "A garden project with trees, flowers and a small pond. ".repeat(20);
    for i in 0..129 {
        std::fs::write(files.join(format!("{i:03}.txt")), &content).unwrap();
    }
    std::fs::hard_link(files.join("000.txt"), files.join("hardlink.txt")).unwrap();
    let before = std::fs::metadata(files.join("000.txt")).unwrap();
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let first = read_report(&r);
    let counters = summary(&r, &first);
    assert_eq!(first.files.len(), 130);
    assert_eq!(
        first
            .files
            .iter()
            .map(|f| &f.id)
            .collect::<HashSet<_>>()
            .len(),
        130
    );
    assert_eq!(first.groups[0].members.len(), 130);
    assert_eq!(first.scores_retained, 8385);
    assert_eq!(counters["counts"]["cache_hits"], 129);
    assert_eq!(counters["counts"]["vectors_encoded"], 1);
    let after = std::fs::metadata(files.join("000.txt")).unwrap();
    assert_eq!(
        (before.ino(), before.nlink(), before.mtime(), before.ctime()),
        (after.ino(), after.nlink(), after.mtime(), after.ctime())
    );
    std::fs::rename(files.join("001.txt"), files.join("renamed.txt")).unwrap();
    let edited = files.join("002.txt");
    let metadata = std::fs::metadata(&edited).unwrap();
    std::fs::write(&edited, content.replace("garden", "school")).unwrap(); // same byte length
    std::fs::File::options()
        .write(true)
        .open(&edited)
        .unwrap()
        .set_times(std::fs::FileTimes::new().set_modified(metadata.modified().unwrap()))
        .unwrap();
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let second = read_report(&r);
    let counters = summary(&r, &second);
    assert_ne!(first.run_id, second.run_id);
    assert_eq!(counters["counts"]["cache_hits"], 129);
    assert_eq!(counters["counts"]["vectors_encoded"], 1);
    assert!(second.files.iter().any(|f| f.name == "renamed.txt"));
    assert_eq!(
        second.groups[0].members.len(),
        129,
        "Edited bytes must not reuse an old content ID"
    );
    assert_eq!(std::fs::read_dir(&r.temp_dir).unwrap().count(), 0);
}

#[tokio::test]
async fn dotfiles_and_hidden_subtrees_are_ignored_without_scan_warnings() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = tests::request(dir.path());
    // Old callers cannot turn dotfiles back on.
    r.include_hidden = true;
    let files = r.local_paths[0].clone();
    std::fs::create_dir_all(files.join("nested/.git/objects")).unwrap();
    let text = "Garden plans with trees, flowers and a pond. ".repeat(20);
    for name in [
        "visible.txt",
        "nested/photo.edit.txt",
        ".gitignore",
        ".DS_Store",
        ".env",
        "nested/.hidden.txt",
        "nested/.git/objects/visible.txt",
    ] {
        std::fs::write(files.join(name), &text).unwrap();
    }
    // Include explicit selections as well as recursively discovered entries.
    r.local_paths.extend([
        files.join(".gitignore"),
        files.join(".DS_Store"),
        files.join("nested/.git"),
        files.join("missing/.ignored"),
    ]);
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let report = read_report(&r);
    assert_eq!(report.status, "completed");
    assert_eq!(report.scanned_files, 2);
    assert_eq!(report.analysed_files, 2);
    assert_eq!(report.skipped_files, 0);
    assert!(report.issues.is_empty());
    let names: std::collections::HashSet<_> =
        report.files.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(
        names,
        ["visible.txt", "photo.edit.txt"].into_iter().collect()
    );
    assert_eq!(report.groups[0].members.len(), 2);
    assert!(
        files.join(".DS_Store").exists(),
        "Ignoring files must not delete them"
    );

    r.local_paths = vec![files.join(".DS_Store"), files.join("nested/.git")];
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let empty = read_report(&r);
    assert_eq!(empty.status, "completed");
    assert!(empty.files.is_empty() && empty.groups.is_empty() && empty.issues.is_empty());
    assert_eq!(empty.skipped_files, 0);
}

#[tokio::test]
async fn scope_filters_do_not_encode_other_families_or_follow_symlinks() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = tests::request(dir.path());
    let files = r.local_paths[0].clone();
    std::fs::create_dir_all(files.join("nested")).unwrap();
    let text = "The garden has flowers and trees. ".repeat(12);
    std::fs::write(files.join("nested/one.txt"), &text).unwrap();
    std::fs::write(files.join(".hidden.txt"), &text).unwrap();
    std::fs::write(
        files.join("picture.bin"),
        b"\x89PNG\r\n\x1a\n invalid but excluded before decoding",
    )
    .unwrap();
    std::fs::copy(files.join("picture.bin"), files.join("picture-copy.bin")).unwrap();
    std::fs::create_dir(dir.path().join("outside")).unwrap();
    std::fs::write(dir.path().join("outside/escape.txt"), &text).unwrap();
    symlink(dir.path().join("outside"), files.join("linked-folder")).unwrap();
    symlink(files.join("nested/one.txt"), files.join("linked-file.txt")).unwrap();
    r.local_paths.push(files.join("nested"));
    r.local_paths.push(files.join("nested/one.txt"));
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let report = read_report(&r);
    assert_eq!(report.files.len(), 3);
    assert_eq!(report.analysed_files, 1);
    assert!(report
        .files
        .iter()
        .all(|f| !f.name.contains("hidden") && !f.name.contains("escape")));
    assert!(report
        .files
        .iter()
        .filter(|f| f.family == "image")
        .all(|f| f.state == "excluded"));
    assert_eq!(
        report.groups[0].members.len(),
        2,
        "Excluded family still has exact hash evidence when requested"
    );
    let image = report.files.iter().find(|f| f.family == "image").unwrap();
    let row = score_row(
        ScoreRowRequest {
            compact: false,
            data_dir: r.data_dir,
            run_id: report.run_id.unwrap(),
            result_revision: 1,
            file_id: image.id.clone(),
            row_offset: image.engine_index.unwrap(),
        },
        &AtomicBool::new(false),
    )
    .unwrap();
    assert!(row["entries"].as_array().unwrap().is_empty());
    assert_eq!(row["unavailable"]["file_unavailable"], 2);
}

#[tokio::test]
async fn sparse_oversized_files_remain_in_inventory_without_a_size_filter() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = tests::request(dir.path());
    r.exact_duplicates = false;
    std::fs::create_dir_all(&r.local_paths[0]).unwrap();
    let mut file = std::fs::File::create(r.local_paths[0].join("large.gz")).unwrap();
    file.write_all(&[0x1f, 0x8b]).unwrap();
    file.set_len(1024 * 1024 * 1024 + 1).unwrap();
    scan(r.clone(), None, Arc::new(AtomicBool::new(false)))
        .await
        .unwrap();
    let report = read_report(&r);
    assert_eq!(report.files[0].bytes, 1024 * 1024 * 1024 + 1);
    assert!(!report
        .issues
        .iter()
        .any(|i| i.reason.contains("size limit")));
}

#[test]
fn legacy_scan_rows_and_groups_are_read_without_migration_or_source_access() {
    use rusqlite::params;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.sqlite3");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("CREATE TABLE runs(id TEXT,snapshot_id TEXT);CREATE TABLE publications(run_id TEXT,revision INTEGER);CREATE TABLE snapshots(id TEXT,request TEXT);
        CREATE TABLE snapshot_files(snapshot_id TEXT,ordinal INTEGER,payload TEXT,vector_id TEXT,sources TEXT);CREATE TABLE records(owner TEXT,revision INTEGER,kind TEXT,payload TEXT);
        INSERT INTO runs VALUES('old-run','old-snapshot');INSERT INTO publications VALUES('old-run',2);INSERT INTO snapshots VALUES('old-snapshot','{\"pair_scope\":\"all\"}');").unwrap();
    for (i, id, profile) in [
        (1, "a", "text-profile"),
        (2, "b", "text-profile"),
        (3, "c", "image-profile"),
    ] {
        db.execute("INSERT INTO snapshot_files VALUES('old-snapshot',?1,?2,'vector','[\"source-1\"]')",params![i,json!({"file_id":id,"sha256":id,"bytes":40,"family":if i==3{"image"}else{"text"},"profile_id":profile}).to_string()]).unwrap();
    }
    db.execute(
        "INSERT INTO records VALUES('old-run',2,'scores',?1)",
        [json!({"file_a":"a","file_b":"b","score":0.94}).to_string()],
    )
    .unwrap();
    drop(db);
    let before = std::fs::read(&path).unwrap();
    let row = score_row(
        ScoreRowRequest {
            compact: false,
            data_dir: dir.path().into(),
            run_id: "old-run".into(),
            result_revision: 2,
            file_id: "a".into(),
            row_offset: 0,
        },
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(row["entries"][0]["score"], 0.94);
    assert_eq!(row["unavailable"]["incompatible_profile"], 1);
    let groups = group_scores(
        GroupQuery {
            data_dir: dir.path().into(),
            run_id: "old-run".into(),
            result_revision: 2,
            minimum_score: 0.9,
            include_identical: false,
        },
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(groups.groups[0].file_ids, vec!["a", "b"]);
    assert!(store::SavedMatrix::open(dir.path(), "old-run", 1).is_err());
    assert_eq!(before, std::fs::read(path).unwrap());
}

#[test]
fn changed_sources_and_parent_symlink_races_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let r = tests::request(dir.path());
    std::fs::create_dir_all(r.local_paths[0].join("nested")).unwrap();
    let file = r.local_paths[0].join("nested/a.txt");
    std::fs::write(&file, "original file content").unwrap();
    let mut report = ScanReport {
        source: r.source,
        scope: vec![],
        status: "completed".into(),
        threshold: 0.9,
        scanned_files: 0,
        analysed_files: 0,
        skipped_files: 0,
        unsupported_files: 0,
        failed_files: 0,
        issue_summary: vec![],
        downloaded_bytes: 0,
        total_groups: 0,
        groups: vec![],
        issues: vec![],
        truncated: false,
        coverage: String::new(),
        elapsed_seconds: 0.0,
        files: vec![],
        run_id: None,
        result_revision: None,
        scores_retained: 0,
    };
    let inventory = scope::inventory(
        &r,
        &StagedCloud::new(),
        &AtomicBool::new(false),
        &mut report,
    )
    .unwrap();
    std::fs::write(&file, "changed file content!").unwrap();
    assert!(!inventory[0].still_current());
    let old = r.local_paths[0].join("nested");
    std::fs::rename(&old, r.local_paths[0].join("elsewhere")).unwrap();
    symlink(r.local_paths[0].join("elsewhere"), &old).unwrap();
    assert!(scope::open_secure(&file).is_err());
}

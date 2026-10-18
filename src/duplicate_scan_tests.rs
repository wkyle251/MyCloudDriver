use super::*;
use crate::guest_fixture::Fixture;
use pikpak::duplicate_cache::DuplicateCache;
use std::sync::atomic::Ordering;

fn client(fixture: &Fixture, directory: &StdPath) -> Client {
    Client::builder()
        .refresh_token("fixture-refresh")
        .device_id("fixture-device")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
        .with_duplicate_cache_directory(directory.to_owned())
}

#[tokio::test]
async fn repeated_duplicate_scans_ignore_stale_inventory_and_fetch_current_metadata() {
    let fixture = Fixture::new().await;
    let directory = tempfile::tempdir().unwrap();
    let client = client(&fixture, directory.path());
    client.list_folder("").await.unwrap();
    client.list_folder("saved-folder").await.unwrap();
    let cache = DuplicateCache::open(directory.path(), "account-user").unwrap();
    let mut phantom = cache.folder("saved-folder").unwrap().unwrap()[0].clone();
    phantom.id = "cached-phantom".into();
    phantom.name = "Only in old inventory.bin".into();
    cache.upsert_files("saved-folder", &[phantom]).unwrap();
    let count_listings = || {
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request.starts_with("GET /drive/v1/files?"))
            .count()
    };
    let before = count_listings();

    for run in 1..=2 {
        let scan = scan_duplicates(&client, "", "/", false).await.unwrap();
        assert_eq!(
            (scan.scanned_folders, scan.scanned_files, scan.exact_groups),
            (2, 1, 0)
        );
        assert_eq!(
            count_listings(),
            before + run * 2,
            "every scan must fetch every folder"
        );
        assert_eq!(
            cache.folder("saved-folder").unwrap().unwrap().len(),
            2,
            "scanning must not write the inventory used by other operations"
        );
    }

    fixture.gone.store(true, Ordering::SeqCst);
    let removed = scan_duplicates(&client, "", "/", false).await.unwrap();
    assert_eq!(
        removed.scanned_files, 0,
        "external changes are visible without a refresh option"
    );
    assert_eq!(count_listings(), before + 6);
}

#[tokio::test]
async fn cloud_duplicate_checks_do_not_create_an_inventory_cache() {
    let fixture = Fixture::new().await;
    let directory = tempfile::tempdir().unwrap();
    let unused = directory.path().join("Unused Cache");
    let client = client(&fixture, &unused);
    for _ in 0..2 {
        let scan = scan_duplicates(&client, "", "/", false).await.unwrap();
        assert_eq!((scan.scanned_folders, scan.scanned_files), (2, 1));
        assert!(
            !unused.exists(),
            "duplicate checking must neither read nor create cache storage"
        );
    }
    let selected = scan_duplicates(&client, "saved-folder", "/Saved", false)
        .await
        .unwrap();
    assert_eq!(selected.scanned_files, 1);
    assert!(
        !unused.exists(),
        "selected-folder metadata must also bypass the cache"
    );
}

#[test]
fn duplicate_cli_keeps_duplicate_checking_and_removes_the_cache_switch() {
    assert!(matches!(
        Cli::try_parse_from(["pikpak", "duplicates"])
            .unwrap()
            .command,
        Command::Duplicates(_)
    ));
    assert!(Cli::try_parse_from(["pikpak", "duplicates", "--refresh-cache"]).is_err());
}

#[test]
fn duplicate_adaptive_listing_honors_provider_retry_after() {
    let error = PikPakError::RetryAfter { status: 429, delay: Duration::from_secs(17) };
    assert_eq!(duplicate_folder_failure_action(&error, 1, true),
        DuplicateFolderFailureAction::Retry(Duration::from_secs(17)));
}

fn tree_entry(id: &str, folder: bool) -> FileInfo {
    serde_json::from_value(serde_json::json!({
        "id": id, "name": id, "kind": if folder { "drive#folder" } else { "drive#file" },
        "size": "8", "hash": "same-content", "created_time": format!("created-{id}")
    })).unwrap()
}

#[tokio::test]
async fn duplicate_cloud_walk_lists_siblings_concurrently_and_preserves_paths() {
    use std::cell::Cell;
    use std::rc::Rc;
    let active = Rc::new(Cell::new(0usize));
    let peak = Rc::new(Cell::new(0usize));
    let (folders, failed, files) = collect_duplicate_tree("root", "/Chosen", None, false, 4, |id| {
        let (active, peak) = (active.clone(), peak.clone());
        async move {
            active.set(active.get() + 1);
            peak.set(peak.get().max(active.get()));
            for _ in 0..(40 - id.len() % 7 * 5) { tokio::task::yield_now().await; }
            active.set(active.get() - 1);
            Ok(match id.as_str() {
                "root" => (0..12).map(|index| tree_entry(&format!("folder-{index}"), true))
                    .chain([tree_entry("folder-0", true)]).collect(),
                id if id.ends_with("-nested") => vec![tree_entry(&format!("{id}-file"), false), tree_entry("root", true)],
                id => vec![tree_entry(&format!("{id}-nested"), true), tree_entry(&format!("{id}-file"), false)],
            })
        }
    }).await.unwrap();
    assert_eq!((peak.get(), active.get()), (4, 0));
    assert_eq!((folders, failed, files.len()), (25, 0, 24));
    let nested = files.iter().find(|file| file.id == "folder-5-nested-file").unwrap();
    assert_eq!(nested.path, "/Chosen/folder-5/folder-5-nested/folder-5-nested-file");
    assert_eq!(nested.folder_created_time.as_deref(), Some("created-folder-5-nested"));
    let scan = build_duplicate_scan("/Chosen".into(), folders, files);
    assert_eq!((scan.exact_groups, scan.groups[0].copies), (1, 24));
}

#[tokio::test(start_paused = true)]
async fn duplicate_cloud_retry_does_not_stall_other_folders() {
    use std::cell::Cell;
    use std::rc::Rc;
    let attempts = Rc::new(Cell::new(0));
    let sibling_finished = Rc::new(Cell::new(false));
    let (folders, failed, files) = collect_duplicate_tree("root", "/", None, false, 4, |id| {
        let (attempts, sibling_finished) = (attempts.clone(), sibling_finished.clone());
        async move {
            match id.as_str() {
                "root" => Ok(vec![tree_entry("good", true), tree_entry("retry", true)]),
                "retry" => {
                    attempts.set(attempts.get() + 1);
                    if attempts.get() == 1 {
                        return Err(PikPakError::Api { status: 503, message: "temporary outage".into() });
                    }
                    assert!(sibling_finished.get(), "other folder results must finish during backoff");
                    Ok(vec![tree_entry("retried-file", false)])
                }
                "good" => {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    sibling_finished.set(true);
                    Ok(vec![tree_entry("good-file", false), tree_entry("missing", true)])
                }
                "missing" => Err(PikPakError::Api { status: 404, message: "unavailable folder".into() }),
                _ => unreachable!(),
            }
        }
    }).await.unwrap();
    assert_eq!((folders, failed, files.len(), attempts.get()), (3, 1, 2, 2));
}

#[tokio::test]
async fn duplicate_cloud_auth_failure_drops_other_requests_and_root_failure_is_fatal() {
    use std::cell::Cell;
    use std::rc::Rc;
    struct Active(Rc<Cell<usize>>);
    impl Drop for Active {
        fn drop(&mut self) { self.0.set(self.0.get() - 1); }
    }
    let active = Rc::new(Cell::new(0usize));
    let calls = Rc::new(Cell::new(0));
    let failure = collect_duplicate_tree("root", "/", None, false, 4, |id| {
        let (active, calls) = (active.clone(), calls.clone());
        async move {
            active.set(active.get() + 1); calls.set(calls.get() + 1);
            let _active = Active(active);
            if id == "root" {
                return Ok((0..12).map(|index| tree_entry(&format!("folder-{index}"), true)).collect());
            }
            tokio::task::yield_now().await;
            if id == "folder-11" { return Err(PikPakError::Auth("session rejected".into())); }
            std::future::pending().await
        }
    }).await.unwrap_err();
    assert!(failure.to_string().contains("failed to inspect folder"));
    assert_eq!(active.get(), 0, "an aborted walk must drop every pending request");
    assert_eq!(calls.get(), 5, "no new requests should start after authentication fails");
    let root = collect_duplicate_tree("root", "/", None, false, 4, |_| async {
        Err(PikPakError::Api { status: 404, message: "missing root".into() })
    }).await;
    assert!(root.is_err(), "a failed selected root cannot be treated as a partial scan");
}

#[tokio::test]
#[ignore = "compares serial and parallel folder listing with synthetic network latency"]
async fn duplicate_cloud_listing_speed_benchmark() {
    let mut reports = Vec::new();
    let mut elapsed = Vec::new();
    for concurrency in [1, 4] {
        let started = Instant::now();
        let (folders, failed, files) = collect_duplicate_tree("root", "/", None, false, concurrency, |id| async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            Ok(if id == "root" {
                (0..24).map(|index| tree_entry(&format!("folder-{index}"), true)).collect()
            } else {
                vec![tree_entry(&format!("{id}-file"), false)]
            })
        }).await.unwrap();
        elapsed.push(started.elapsed().as_secs_f64());
        assert_eq!((folders, failed), (25, 0));
        reports.push(serde_json::to_value(build_duplicate_scan("/".into(), folders, files)).unwrap());
    }
    assert_eq!(reports[0], reports[1]);
    eprintln!("25 folders, synthetic 50ms/listing: serial {:.3}s, parallel {:.3}s ({:.2}x)",
        elapsed[0], elapsed[1], elapsed[0] / elapsed[1]);
}

#[tokio::test]
#[ignore = "compares folder worker counts with synthetic latency and no server throttling"]
async fn duplicate_cloud_worker_count_benchmark() {
    let mut expected = None;
    eprintln!("81 folders, synthetic 50ms/listing, no rate limits:");
    for workers in [4, 8, 16, 40] {
        let started = Instant::now();
        let (folders, failed, files) = collect_duplicate_tree("root", "/", None, false, workers, |id| async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            Ok(if id == "root" {
                (0..80).map(|index| tree_entry(&format!("folder-{index}"), true)).collect()
            } else { vec![tree_entry(&format!("{id}-file"), false)] })
        }).await.unwrap();
        let elapsed = started.elapsed().as_secs_f64();
        assert_eq!((folders, failed), (81, 0));
        let report = serde_json::to_value(build_duplicate_scan("/".into(), folders, files)).unwrap();
        if let Some(expected) = &expected { assert_eq!(&report, expected); }
        else { expected = Some(report); }
        eprintln!("workers={workers:2}, elapsed={elapsed:.4}s");
    }
}

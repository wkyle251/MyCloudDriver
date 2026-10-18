use super::*;
use crate::guest_fixture::Fixture;

fn client(fixture: &Fixture) -> Client {
    Client::builder().personal_access_token("account-access").api_base_url(&fixture.base).auth_base_url(&fixture.base).build().unwrap()
}

fn scope(paths: Vec<PathBuf>) -> Scope {
    Scope { cloud_folders: vec![CloudFolder { id: "".into(), path: "/".into() }], local_paths: paths }
}

#[tokio::test]
async fn duplicate_check_matches_pikpak_with_multiple_disk_folders_without_cloud_downloads() {
    let fixture = Fixture::new().await;
    let directory = tempfile::tempdir().unwrap();
    let first = directory.path().join("Disk One"); let second = directory.path().join("Disk Two");
    std::fs::create_dir_all(first.join("Nested")).unwrap(); std::fs::create_dir(&second).unwrap();
    let source = first.join("Nested/renamed.bin"); std::fs::write(&source, b"abcdefgh").unwrap();
    std::fs::write(second.join("backup.bin"), b"abcdefgh").unwrap();
    std::fs::write(second.join("different.bin"), b"xxxxxxxx").unwrap();
    std::fs::write(second.join(".hidden.bin"), b"abcdefgh").unwrap();
    std::os::unix::fs::symlink(&source, second.join("link.bin")).unwrap();
    let gcid = pikpak::upload::gcid_file(&source, 8, Arc::new(|_| {})).await.unwrap();
    fixture.saved.lock().unwrap()["hash"] = serde_json::json!(gcid);
    let mut selected = scope(vec![first.clone(), second.clone(), first.join("Nested")]);
    selected.cloud_folders.push(CloudFolder { id: "saved-folder".into(), path: "/Saved".into() });
    let scan = scan(&client(&fixture), selected, false).await.unwrap();
    assert_eq!((scan.scanned_files, scan.exact_groups, scan.possible_groups), (4, 1, 0));
    assert_eq!(scan.groups[0].files.len(), 3);
    assert_eq!(scan.reclaimable_bytes, 8, "only PikPak bytes are selected for reclamation");
    assert_eq!(scan.groups[0].files[0].source, DuplicateSource::Local);
    assert!(scan.groups[0].files.iter().filter(|file| file.source == DuplicateSource::Local).all(|file| file.local_identity.is_some()));
    assert!(scan.root_path.contains("Disk One") && scan.root_path.contains("Disk Two") && scan.root_path.contains("PikPak"));
    assert!(!fixture.requests.lock().unwrap().iter().any(|request| request.starts_with("GET /guest-body") || request.starts_with("GET /user-body") || request.starts_with("POST /drive/v1/share")));
}

#[tokio::test]
async fn duplicate_check_supports_cloud_md5_without_treating_name_and_size_as_exact() {
    use md5::{Digest, Md5};
    let fixture = Fixture::new().await;
    let directory = tempfile::tempdir().unwrap();
    let file = directory.path().join("renamed.bin"); std::fs::write(&file, b"abcdefgh").unwrap();
    fixture.saved.lock().unwrap()["hash"] = serde_json::Value::Null;
    fixture.saved.lock().unwrap()["md5_checksum"] = serde_json::json!(hex::encode(Md5::digest(b"abcdefgh")));
    let listed = client(&fixture).list_folder("saved-folder").await.unwrap();
    assert_eq!(listed[0].md5_checksum.as_deref(), Some("e8dc4081b13434b45189a720b77b6818"));
    let hashed = hash_local(&file, &LocalIdentity::of(&std::fs::metadata(&file).unwrap())).unwrap();
    assert_eq!(hashed.1, listed[0].md5_checksum.as_ref().unwrap().as_str());
    let matched = scan(&client(&fixture), scope(vec![directory.path().to_owned()]), false).await.unwrap();
    assert_eq!(matched.scanned_files, 2, "{matched:?}");
    assert_eq!((matched.exact_groups, matched.reclaimable_bytes), (1, 8));
    fixture.saved.lock().unwrap()["md5_checksum"] = serde_json::Value::Null;
    let unknown = scan(&client(&fixture), scope(vec![directory.path().to_owned()]), false).await.unwrap();
    assert!(unknown.groups.is_empty(), "unknown cloud content never matches a computed local hash by name alone");
}

fn candidate(id: &str, source: DuplicateSource, folder_created: Option<&str>) -> DuplicateCandidate {
    DuplicateCandidate { id: id.into(), name: "same.bin".into(), path: format!("/{id}/same.bin"), size: 8,
        modified_time: None, content_hash: Some("hash".into()), md5_checksum: None,
        source, folder_created_time: folder_created.map(str::to_owned), local_identity: None }
}

#[test]
fn duplicate_recommendations_keep_disk_copies_then_older_cloud_folders() {
    let old = candidate("z-old", DuplicateSource::Pikpak, Some("2020-01-01T00:00:00Z"));
    let new = candidate("a-new", DuplicateSource::Pikpak, Some("2026-01-01T00:00:00Z"));
    let scan = build_duplicate_scan("/".into(), 2, vec![new.clone(), old.clone()]);
    assert_eq!(scan.groups[0].files[0].id, old.id);
    assert_eq!(scan.groups[0].files[1].id, new.id);
    let local = candidate("disk", DuplicateSource::Local, None);
    let scan = build_duplicate_scan("/".into(), 2, vec![new, old, local]);
    assert_eq!(scan.groups[0].files[0].source, DuplicateSource::Local);
    assert_eq!(scan.reclaimable_bytes, 16);
}

#[test]
fn local_duplicate_hashing_rejects_changed_files_and_symlinks() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("copy.bin"); std::fs::write(&path, b"abcdefgh").unwrap();
    let before = LocalIdentity::of(&std::fs::metadata(&path).unwrap());
    assert!(hash_local(&path, &before).is_ok());
    std::fs::write(&path, b"changed size").unwrap();
    assert!(hash_local(&path, &before).is_err());
    let link = directory.path().join("link.bin"); std::os::unix::fs::symlink(&path, &link).unwrap();
    let now = LocalIdentity::of(&std::fs::metadata(&path).unwrap());
    assert!(hash_local(&link, &now).is_err());
}

#[test]
fn scope_files_accept_legacy_volume_metadata_without_using_it() {
    let selected: Scope = serde_json::from_str(r#"{"cloud_folders":[],"local_paths":["/Volumes/Disk"],
        "local_volumes":[{"path":"/Volumes/Disk","volume_id":"abc","mount_path":"/Volumes/Disk","compares_inode":true}]}"#).unwrap();
    assert!(selected.cloud_folders.is_empty());
    assert_eq!(selected.local_paths, vec![PathBuf::from("/Volumes/Disk")]);
}

fn disk_scope(disk: &StdPath) -> Scope {
    Scope { cloud_folders: vec![], local_paths: vec![disk.to_owned()] }
}

fn group_names(scan: &DuplicateScan) -> Vec<Vec<String>> {
    let mut groups: Vec<Vec<String>> = scan.groups.iter().map(|group| {
        let mut names: Vec<String> = group.files.iter().map(|file| file.name.clone()).collect(); names.sort(); names
    }).collect();
    groups.sort();
    groups
}

#[tokio::test]
async fn repeated_disk_scans_reuse_hashes_and_invalidate_same_size_edits() {
    let fixture = Fixture::new().await;
    let directory = tempfile::tempdir().unwrap();
    let cache_directory = directory.path().join("Unused Cache");
    let disk = directory.path().join("Disk");
    let (one, two, other) = (disk.join("A/one.bin"), disk.join("B/two.bin"), disk.join("B/other.bin"));
    std::fs::create_dir_all(one.parent().unwrap()).unwrap();
    std::fs::create_dir_all(two.parent().unwrap()).unwrap();
    std::fs::write(&one, b"abcdefgh").unwrap();
    std::fs::write(&two, b"abcdefgh").unwrap();
    std::fs::write(&other, b"xxxxxxxx").unwrap();
    let client = client(&fixture).with_duplicate_cache_directory(cache_directory.clone());
    let expected = vec![vec!["one.bin".to_string(), "two.bin".to_string()]];
    for _ in 0..2 {
        let checked = scan(&client, disk_scope(&disk), false).await.unwrap();
        assert_eq!((checked.scanned_files, group_names(&checked)), (3, expected.clone()));
        assert!(cache_directory.join("local-content-v1.sqlite3").is_file());
    }

    // Restore the old modification time: content is still read on every scan.
    let old_modified = std::fs::metadata(&other).unwrap().modified().unwrap();
    std::fs::write(&other, b"abcdefgh").unwrap();
    std::fs::OpenOptions::new().write(true).open(&other).unwrap().set_modified(old_modified).unwrap();
    let edited = scan(&client, disk_scope(&disk), false).await.unwrap();
    assert_eq!(group_names(&edited), vec![vec!["one.bin".to_string(), "other.bin".to_string(), "two.bin".to_string()]]);

    std::fs::remove_file(&two).unwrap();
    let removed = scan(&client, disk_scope(&disk), false).await.unwrap();
    assert_eq!((removed.scanned_files, group_names(&removed)),
        (2, vec![vec!["one.bin".to_string(), "other.bin".to_string()]]));
    std::fs::write(disk.join("new.bin"), b"abcdefgh").unwrap();
    let added = scan(&client, disk_scope(&disk), false).await.unwrap();
    assert_eq!(added.groups[0].files.len(), 3);
    assert!(cache_directory.join("local-content-v1.sqlite3").is_file());
}

#[tokio::test]
async fn local_duplicate_hashing_runs_four_workers_and_skips_unique_sizes() {
    use std::sync::atomic::AtomicUsize;
    let directory = tempfile::tempdir().unwrap();
    let content = vec![0x5a; 64 * 1024];
    let mut files = Vec::new();
    for index in 0..12 {
        let path = directory.path().join(format!("copy-{index}.bin"));
        std::fs::write(&path, &content).unwrap();
        files.push((path.clone(), LocalIdentity::of(&std::fs::metadata(path).unwrap())));
    }
    let unique = directory.path().join("unique.bin");
    std::fs::write(&unique, b"unique size").unwrap();
    files.push((unique.clone(), LocalIdentity::of(&std::fs::metadata(&unique).unwrap())));
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let calls = Arc::new(AtomicUsize::new(0));
    let (task_active, task_peak, task_calls) = (active.clone(), peak.clone(), calls.clone());
    let (mut parallel, mut failed) = (Vec::new(), 0);
    collect_local_candidates(files.clone(), &mut parallel, 1, &mut failed, false, 4,
        move |path, identity, md5, progress, _reader| {
            assert!(!md5, "GCID-only scans must not spend CPU calculating MD5");
            assert_ne!(path.file_name().unwrap(), "unique.bin");
            task_calls.fetch_add(1, Ordering::SeqCst);
            let active = task_active.fetch_add(1, Ordering::SeqCst) + 1;
            task_peak.fetch_max(active, Ordering::SeqCst);
            // Deliberately overlap file reads; no timing-based speed assertion.
            std::thread::sleep(Duration::from_millis(20));
            let result = hash_local_reporting(path, identity, md5, progress);
            task_active.fetch_sub(1, Ordering::SeqCst);
            result
        }).await.unwrap();
    assert_eq!((peak.load(Ordering::SeqCst), active.load(Ordering::SeqCst)), (4, 0));
    assert_eq!((calls.load(Ordering::SeqCst), failed, parallel.len()), (12, 0, 13));
    assert!(parallel.iter().all(|file| file.md5_checksum.is_none()));
    let (mut serial, mut failed) = (Vec::new(), 0);
    collect_local_candidates(files, &mut serial, 1, &mut failed, false, 1,
        |path, identity, md5, progress, _reader| hash_local_reporting(path, identity, md5, progress)).await.unwrap();
    let serial = build_duplicate_scan("/".into(), 1, serial);
    let parallel = build_duplicate_scan("/".into(), 1, parallel);
    assert_eq!(serde_json::to_value(&serial).unwrap(), serde_json::to_value(&parallel).unwrap());
    assert_eq!((parallel.exact_groups, parallel.groups[0].copies), (1, 12));
}

#[tokio::test]
async fn local_duplicate_hashing_only_computes_md5_for_cloud_fallback_sizes() {
    let directory = tempfile::tempdir().unwrap();
    let mut files = Vec::new();
    for (name, content) in [("fallback.bin", b"abcdefgh".as_slice()),
        ("one.bin", b"different length".as_slice()), ("two.bin", b"different length".as_slice())] {
        let path = directory.path().join(name);
        std::fs::write(&path, content).unwrap();
        files.push((path.clone(), LocalIdentity::of(&std::fs::metadata(path).unwrap())));
    }
    let mut cloud = candidate("cloud", DuplicateSource::Pikpak, None);
    cloud.content_hash = None;
    cloud.md5_checksum = Some("e8dc4081b13434b45189a720b77b6818".into());
    let (mut candidates, mut failed) = (vec![cloud], 0);
    collect_local_candidates(files, &mut candidates, 1, &mut failed, false, 4,
        |path, identity, md5, progress, _reader| {
            assert_eq!(md5, identity.size == 8);
            hash_local_reporting(path, identity, md5, progress)
        }).await.unwrap();
    assert_eq!(failed, 0);
    let scan = build_duplicate_scan("/".into(), 1, candidates);
    assert_eq!((scan.exact_groups, scan.possible_groups, scan.reclaimable_bytes), (2, 0, 8));
}

#[tokio::test]
async fn a_changed_local_file_is_skipped_without_losing_parallel_results() {
    let directory = tempfile::tempdir().unwrap();
    let mut files = Vec::new();
    for name in ["one.bin", "two.bin", "changed.bin"] {
        let path = directory.path().join(name);
        std::fs::write(&path, b"abcdefgh").unwrap();
        files.push((path.clone(), LocalIdentity::of(&std::fs::metadata(path).unwrap())));
    }
    let (mut candidates, mut failed) = (Vec::new(), 0);
    collect_local_candidates(files, &mut candidates, 1, &mut failed, false, 4,
        |path, identity, md5, progress, _reader| {
            hash_local_reporting(path, identity, md5, |bytes| {
                progress(bytes);
                if path.file_name().unwrap() == "changed.bin" {
                    std::fs::write(path, b"changed while hashing").unwrap();
                }
            })
        }).await.unwrap();
    let scan = build_duplicate_scan("/".into(), 1, candidates);
    assert_eq!((failed, scan.scanned_files, scan.exact_groups), (1, 2, 1));
    assert_eq!(group_names(&scan), vec![vec!["one.bin".to_string(), "two.bin".to_string()]]);
}

#[tokio::test]
#[ignore = "reads generated files to compare serial GCID+MD5 with parallel GCID"]
async fn duplicate_hashing_speed_benchmark() {
    let directory = tempfile::tempdir().unwrap();
    let content: Vec<u8> = (0..16 * 1024 * 1024).map(|index| (index * 31 + index / 255) as u8).collect();
    let mut files = Vec::new();
    for index in 0..16 {
        let path = directory.path().join(format!("copy-{index}.bin"));
        std::fs::write(&path, &content).unwrap();
        files.push((path.clone(), LocalIdentity::of(&std::fs::metadata(path).unwrap())));
    }
    let (mut serial, mut failed) = (Vec::new(), 0);
    let started = Instant::now();
    collect_local_candidates(files.clone(), &mut serial, 1, &mut failed, false, 1,
        |path, identity, _, progress, _reader| hash_local_reporting(path, identity, true, progress)).await.unwrap();
    let serial_time = started.elapsed();
    let (mut parallel, mut failed) = (Vec::new(), 0);
    let started = Instant::now();
    collect_local_candidates(files, &mut parallel, 1, &mut failed, false, 4,
        |path, identity, md5, progress, _reader| hash_local_reporting(path, identity, md5, progress)).await.unwrap();
    let parallel_time = started.elapsed();
    assert_eq!(group_names(&build_duplicate_scan("/".into(), 1, serial)),
        group_names(&build_duplicate_scan("/".into(), 1, parallel)));
    eprintln!("256 MiB generated files: serial GCID+MD5 {:.3}s, parallel GCID {:.3}s ({:.2}x)",
        serial_time.as_secs_f64(), parallel_time.as_secs_f64(), serial_time.as_secs_f64() / parallel_time.as_secs_f64());
}

#[tokio::test]
#[ignore = "compares GCID worker counts on 1280 MiB of generated cached files"]
async fn duplicate_hashing_worker_count_benchmark() {
    let directory = tempfile::tempdir().unwrap();
    let content: Vec<u8> = (0..16 * 1024 * 1024).map(|index| (index * 31 + index / 255) as u8).collect();
    let mut files = Vec::new();
    for index in 0..80 {
        let path = directory.path().join(format!("copy-{index:02}.bin"));
        std::fs::write(&path, &content).unwrap();
        files.push((path.clone(), LocalIdentity::of(&std::fs::metadata(path).unwrap())));
    }
    let workers = [1, 2, 4, 8, 16, 24, 40];
    let mut timings: Vec<Vec<f64>> = vec![Vec::new(); workers.len()];
    let mut expected = None;
    // Rotate execution order to reduce warmup and thermal bias. Every trial
    // uses exactly the same GCID-only algorithm and verifies identical results.
    for trial in 0..5 {
        for offset in 0..workers.len() {
            let index = (offset + trial * 3) % workers.len();
            let (mut candidates, mut failed) = (Vec::new(), 0);
            let started = Instant::now();
            collect_local_candidates(files.clone(), &mut candidates, 1, &mut failed, false, workers[index],
                |path, identity, md5, progress, _reader| hash_local_reporting(path, identity, md5, progress)).await.unwrap();
            timings[index].push(started.elapsed().as_secs_f64());
            assert_eq!(failed, 0);
            let report = serde_json::to_value(build_duplicate_scan("/".into(), 1, candidates)).unwrap();
            if let Some(expected) = &expected { assert_eq!(&report, expected); }
            else { expected = Some(report); }
        }
    }
    eprintln!("GCID only, 80 x 16 MiB cached files, median of five trials:");
    for (workers, mut times) in workers.into_iter().zip(timings) {
        times.sort_by(f64::total_cmp);
        eprintln!("workers={workers:2}, median={:.4}s, throughput={:.0} MiB/s, range={:.4}..{:.4}s",
            times[2], 1280.0 / times[2], times[0], times[4]);
    }
}

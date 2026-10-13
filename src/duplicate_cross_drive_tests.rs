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
async fn repeated_disk_scans_read_current_files_without_creating_a_hash_cache() {
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
        assert!(!cache_directory.exists(), "duplicate checks must not create persistent caches");
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
    assert!(!cache_directory.exists());
}

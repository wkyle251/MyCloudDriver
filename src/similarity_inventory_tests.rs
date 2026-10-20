use super::*;
use filetwin_core::api::{CancellationToken, Counts};

fn report() -> ScanReport {
    serde_json::from_value(
        json!({"source":"local","scope":[],"status":"completed","threshold":0.8,
        "scanned_files":0,"analysed_files":0,"skipped_files":0,"downloaded_bytes":0,
        "total_groups":0,"groups":[],"issues":[],"truncated":false,"coverage":"",
        "elapsed_seconds":0,"files":[],"scores_retained":0}),
    )
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fresh_inventory_detects_add_delete_rename_and_same_size_edit() {
    let root = tempfile::tempdir().unwrap();
    let request = crate::similarity::tests::request(root.path());
    let folder = &request.local_paths[0];
    std::fs::create_dir_all(folder).unwrap();
    for name in ["keep.txt", "delete.txt", "edit.txt", "rename.txt"] {
        std::fs::write(folder.join(name), b"before").unwrap();
    }
    let cancel = Arc::new(AtomicBool::new(false));
    let token = CancellationToken::default();
    let runtime = tokio::runtime::Handle::current();
    let get = || {
        capture(
            &request,
            root.path(),
            &cancel,
            None,
            &runtime,
            &token,
            report(),
        )
        .unwrap()
    };
    let initial = get();
    std::fs::remove_file(folder.join("delete.txt")).unwrap();
    std::fs::write(folder.join("added.txt"), b"new").unwrap();
    std::fs::write(folder.join("edit.txt"), b"edited").unwrap();
    std::fs::rename(folder.join("rename.txt"), folder.join("renamed.txt")).unwrap();
    let current = get();
    assert_eq!(
        changes(&initial.files, &current.files),
        Changes {
            added: 2,
            removed: 2,
            changed: 1
        }
    );
    let mut reordered = get();
    reordered.files.reverse();
    assert!(
        !changes(&current.files, &reordered.files).any(),
        "Provider enumeration order must not cause a rescan"
    );
    assert_eq!(initial.files.len(), 4);
    assert_eq!(
        current.report.failed_files, 0,
        "A deletion is not a failed scan"
    );
    for file in &current.files {
        std::fs::remove_file(folder.join(&file.display.name)).unwrap();
    }
    let empty = get();
    assert_eq!(changes(&current.files, &empty.files).removed, 4);
    assert_eq!(empty.report.scanned_files, 0);
}

#[test]
fn cloud_revision_changes_and_legacy_snapshots_are_revalidated() {
    let item = CloudItem {
        id: "generated-id".into(),
        name: "example.txt".into(),
        path: "/fixture/example.txt".into(),
        is_folder: false,
        size: 100,
        ancestors: vec![],
        revision: Some("version-one".into()),
    };
    let mut old = scope::InputFile::cloud(item.clone());
    old.capture_inventory_version();
    let mut same = scope::InputFile::cloud(item);
    same.capture_inventory_version();
    assert!(!changes(&[old.clone()], &[same.clone()]).any());
    same.cloud.as_mut().unwrap().revision = Some("version-two".into());
    same.capture_inventory_version();
    assert_eq!(changes(&[old.clone()], &[same.clone()]).changed, 1);
    old.inventory_version = None;
    assert_eq!(
        changes(&[old], &[same]).changed,
        1,
        "Old sealed comparisons lack a fresh inventory guarantee"
    );
}

#[test]
fn stale_native_listing_revision_does_not_restart_unchanged_analysis() {
    use std::os::unix::fs::MetadataExt;
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("generated.txt");
    std::fs::write(&path, b"before").unwrap();
    let metadata = std::fs::metadata(&path).unwrap();
    let revision = |device| format!("{}:{}:{}:{}:{}:{}:{}", device, metadata.ino(),
        metadata.len(), metadata.mtime(), metadata.mtime_nsec(), metadata.ctime(), metadata.ctime_nsec());
    let source = ExternalSource {
        provider: Some("local".into()), content_kind: None,
        id: "same-native-file".into(), name: "generated.txt".into(),
        path: path.to_string_lossy().into(), size: 6, local_path: Some(path.clone()),
        revision: Some(revision(metadata.dev().wrapping_add(4))),
    };
    let mut initial = scope::InputFile::external(source.clone());
    initial.capture_inventory_version();
    let mut fresh_source = source;
    fresh_source.revision = Some(revision(metadata.dev()));
    let mut current = scope::InputFile::external(fresh_source);
    current.capture_inventory_version();
    assert!(!changes(&[initial.clone()], &[current.clone()]).any(),
        "Refreshing a stale mount number must not restart analysis of the same live file");
    assert_eq!(initial.checkpoint_revision(), current.checkpoint_revision());
    assert!(current.checkpoint_revision().is_some());
    // A real same-size replacement must still invalidate the captured work,
    // even when the provider reuses its original listing revision.
    let replacement = root.path().join("replacement.txt");
    std::fs::write(&replacement, b"edited").unwrap();
    std::fs::rename(replacement, &path).unwrap();
    assert!(initial.checkpoint_revision().is_none());
    current.capture_inventory_version();
    assert_eq!(changes(&[initial], &[current]).changed, 1);
}

#[test]
fn remote_provider_revision_remains_part_of_file_change_detection() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("generated.txt");
    std::fs::write(&path, b"remote").unwrap();
    for provider in [None, Some("icloud"), Some("photos")] {
        let source = ExternalSource {
            provider: provider.map(str::to_owned), content_kind: None,
            id: "provider-file".into(), name: "generated.txt".into(),
            path: "/provider/generated.txt".into(), size: 6,
            local_path: Some(path.clone()), revision: Some("revision-one".into()),
        };
        let mut previous = scope::InputFile::external(source.clone());
        previous.capture_inventory_version();
        let mut source = source;
        source.revision = Some("revision-two".into());
        let mut current = scope::InputFile::external(source);
        current.capture_inventory_version();
        assert_eq!(changes(&[previous], &[current]).changed, 1, "{provider:?}");
    }
}

#[test]
fn edits_after_native_acquisition_cannot_relabel_old_analysis() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("generated.txt");
    std::fs::write(&path, b"before").unwrap();
    let mut file = scope::InputFile::external(ExternalSource {
        provider: None,
        content_kind: None,
        id: "native-generated".into(),
        name: "generated.txt".into(),
        path: path.to_string_lossy().into(),
        size: 6,
        local_path: Some(path.clone()),
        revision: Some("listed-version".into()),
    });
    file.capture_inventory_version();
    file.resolved(path.clone()).unwrap();
    assert!(file.checkpoint_revision().is_some());
    std::fs::write(path, b"edited").unwrap();
    assert!(
        file.checkpoint_revision().is_none(),
        "The old vector must not be saved under the edited file's metadata"
    );
}

#[test]
fn an_unavailable_local_volume_is_not_mass_deletion() {
    let root = tempfile::tempdir().unwrap();
    let request = crate::similarity::tests::request(root.path());
    std::fs::create_dir_all(&request.local_paths[0]).unwrap();
    std::fs::write(request.local_paths[0].join("generated.txt"), b"example").unwrap();
    let files = scope::inventory(
        &request,
        &StagedCloud::new(),
        &AtomicBool::new(false),
        &mut report(),
    )
    .unwrap();
    std::fs::remove_dir_all(&request.local_paths[0]).unwrap();
    assert!(
        validate_removals(&files, &[]).is_ok(),
        "Deleting a folder on an available filesystem is allowed"
    );
    // Model a mount disappearing to reveal its parent filesystem, without
    // mounting/unmounting any real disk in a regression test.
    let mut vanished = serde_json::to_value(&files[0]).unwrap();
    vanished["revision"]["dev"] = (files[0].local_device().unwrap().wrapping_add(1)).into();
    let vanished: scope::InputFile = serde_json::from_value(vanished).unwrap();
    assert!(validate_removals(&[vanished], &[]).is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pikpak_refresh_handles_paginated_changes_trash_and_listing_failures() {
    use std::sync::atomic::AtomicUsize;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let phase = Arc::new(AtomicUsize::new(0));
    let server_phase = phase.clone();
    let server = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let phase = server_phase.clone();
            tokio::spawn(async move {
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                while !bytes.windows(4).any(|v| v == b"\r\n\r\n") {
                    let n = socket.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    bytes.extend_from_slice(&buffer[..n]);
                }
                let header = String::from_utf8_lossy(&bytes);
                let route = header.lines().next().unwrap();
                let phase = phase.load(Ordering::Acquire);
                let mut status = "200 OK";
                let body = if route.contains("/auth/token") {
                    json!({"access_token":"generated-access","refresh_token":"generated-refresh","expires_in":3600,"sub":"generated"})
                } else if route.contains("/shield/captcha/init") {
                    json!({"captcha_token":"generated-captcha","expires_in":3600})
                } else if route.contains("/drive/v1/files/root?") {
                    json!({"id":"root","name":"Generated folder","size":"0","trashed":phase==2})
                } else if route.contains("/drive/v1/files/gone?") {
                    json!({"id":"gone","name":"gone.txt","size":"6","trashed":true,"web_content_link":"http://127.0.0.1/not-used"})
                } else {
                    assert!(route.contains("/drive/v1/files?"), "Inventory checks must never fetch originals");
                    if phase == 3 {
                        status = "403 Forbidden";
                        json!({"error":"permission_denied"})
                    } else if route.contains("page_token=second") {
                        let id = if phase == 0 { "removed" } else { "added" };
                        json!({"files":[{"id":id,"name":format!("{id}.txt"),"kind":"drive#file","size":"6","hash":"stable"}]})
                    } else {
                        json!({"files":[
                            {"id":"kept","name":"kept.txt","kind":"drive#file","size":"6","hash":"stable"},
                            {"id":"edited","name":"edited.txt","kind":"drive#file","size":"6","hash":if phase==0 {"old"} else {"new"}}],
                            "next_page_token":"second"})
                    }
                }.to_string();
                let _ = socket.write_all(format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await;
            });
        }
    });
    let root = tempfile::tempdir().unwrap();
    let mut request = crate::similarity::tests::request(root.path());
    request.source = ScanSource::Cloud;
    request.local_paths.clear();
    request.cloud_items = vec![CloudItem {
        id: "root".into(),
        name: "Generated folder".into(),
        path: "/Generated".into(),
        is_folder: true,
        size: 0,
        ancestors: vec![],
        revision: None,
    }];
    let client = Client::builder()
        .refresh_token("generated-refresh")
        .device_id("generated-device")
        .api_base_url(format!("http://{address}"))
        .auth_base_url(format!("http://{address}"))
        .build()
        .unwrap();
    let cancel = Arc::new(AtomicBool::new(false));
    let token = CancellationToken::default();
    let runtime = tokio::runtime::Handle::current();
    let get = || {
        capture(
            &request,
            root.path(),
            &cancel,
            Some(&client),
            &runtime,
            &token,
            report(),
        )
    };
    let old = get().unwrap();
    phase.store(1, Ordering::Release);
    let current = get().unwrap();
    assert_eq!(
        changes(&old.files, &current.files),
        Changes {
            added: 1,
            removed: 1,
            changed: 1
        }
    );
    phase.store(2, Ordering::Release);
    assert!(
        get().unwrap().files.is_empty(),
        "A selected folder moved to Trash is outside the live scope"
    );
    let error = client
        .similarity_download_info("gone", "")
        .await
        .unwrap_err();
    assert!(matches!(error, crate::Error::Api { status: 404, .. }));
    phase.store(3, Ordering::Release);
    assert!(
        get().is_err(),
        "Lost permission must not certify an empty scope"
    );
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn changed_inventory_rotates_comparison_ordinals_and_keeps_old_checkpoint() {
    let root = tempfile::tempdir().unwrap();
    let mut request = crate::similarity::tests::request(root.path());
    request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
    std::fs::create_dir_all(&request.local_paths[0]).unwrap();
    std::fs::write(request.local_paths[0].join("a.txt"), b"generated").unwrap();
    let snapshot = capture(
        &request,
        root.path(),
        &Arc::new(AtomicBool::new(false)),
        None,
        &tokio::runtime::Handle::current(),
        &CancellationToken::default(),
        report(),
    )
    .unwrap();
    let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
    checkpoint
        .seal(&snapshot.files, &Counts::default(), &report())
        .unwrap();
    let previous = checkpoint.comparison_directory().unwrap();
    std::fs::write(previous.join("generated-old-matrix"), b"old ordinal data").unwrap();
    checkpoint.invalidate_inventory().unwrap();
    assert!(checkpoint.sealed().unwrap().is_none());
    let current = checkpoint.comparison_directory().unwrap();
    assert_ne!(previous, current);
    assert!(previous.join("generated-old-matrix").exists());
    assert!(!current.join("generated-old-matrix").exists());
    checkpoint.seal(&[], &Counts::default(), &report()).unwrap();
    assert!(checkpoint.sealed().unwrap().unwrap().files.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn incomplete_provider_inventory_never_certifies_deletions() {
    let root = tempfile::tempdir().unwrap();
    let mut request = crate::similarity::tests::request(root.path());
    request.local_paths.clear();
    let path = root.path().join("inventory.jsonl");
    request.external_source_stream = Some(path.clone());
    std::fs::write(
        &path,
        b"{\"event\":\"error\",\"message\":\"Generated provider disconnected\"}\n",
    )
    .unwrap();
    let result = capture(
        &request,
        root.path(),
        &Arc::new(AtomicBool::new(false)),
        None,
        &tokio::runtime::Handle::current(),
        &CancellationToken::default(),
        report(),
    );
    assert!(result.is_err());
    std::fs::write(path, b"").unwrap();
    let cancel = Arc::new(AtomicBool::new(false));
    let stop = cancel.clone();
    let thread = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(60));
        stop.store(true, Ordering::Release);
    });
    let began = Instant::now();
    assert!(capture(
        &request,
        root.path(),
        &cancel,
        None,
        &tokio::runtime::Handle::current(),
        &CancellationToken::default(),
        report()
    )
    .is_err());
    thread.join().unwrap();
    assert!(
        began.elapsed() < Duration::from_secs(2),
        "Cancellation must release an idle inventory reader"
    );
}

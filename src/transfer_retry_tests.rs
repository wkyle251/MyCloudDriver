//! Restart recovery fixtures never access native preferences or user payloads.
use super::*;

#[test]
fn automatic_download_admission_uses_the_system_budget_instead_of_sixty_four() {
    let network = pikpak::download_network::Network::shared();
    let admission = Concurrency::download(usize::MAX, Arc::new(AtomicU64::new(0)));
    assert_eq!(admission.maximum, network.limit());
    assert!(admission.maximum > 64);
    assert_eq!(admission.throughput.as_ref().unwrap().0.limit, 4);
}

#[tokio::test]
async fn a_full_set_of_verifiers_leaves_admission_for_network_work() {
    let release = Arc::new(tokio::sync::Notify::new());
    let settled = Arc::new(AtomicU64::new(0));
    let run_release = release.clone();
    let mut order = Vec::new();
    tokio::time::timeout(Duration::from_secs(3), schedule(
        vec!["generated-disk-reader", "generated-network-body"],
        Concurrency::download(1, Arc::new(AtomicU64::new(0))),
        move |id| {
            let release = run_release.clone();
            async move {
                if id == "generated-disk-reader" {
                    let _reading = DiskReadPhase::enter(id);
                    release.notified().await;
                } else { release.notify_one(); }
                Ok(())
            }
        }, |id| id.to_string(), |id, result| { result.unwrap(); settled.fetch_add(1, Ordering::Relaxed); order.push(id); }, |_, _, _| {}
    )).await.expect("A queued verifier consumed the only network worker").unwrap();
    assert_eq!(settled.load(Ordering::Relaxed), 2);
    assert_eq!(order.first(), Some(&"generated-network-body"));
}

#[test]
fn restored_retry_lineage_ownership_is_isolated_in_a_child_process() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "transfer_control::retry_tests::restored_retry_lineage_child",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}

#[tokio::test]
#[ignore = "isolated helper owner/control environment"]
async fn restored_retry_lineage_child() {
    let directory = tempfile::tempdir().unwrap();
    let control = directory.path().join("controls.json");
    let locks = directory.path().join("locks");
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_LOCKS", locks);
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "synthetic-retry-owner");
    std::env::remove_var("MYCLOUDDRIVER_IMPORTED_TRANSFER_OWNERS");
    std::env::remove_var("MYCLOUDDRIVER_CLAIM_LEGACY_PARTS");
    let previous_root = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
    let middle_root = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB";
    let current_root = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC";
    let previous_body = format!("{previous_root}:old-generated-body");
    let current_body = format!("{current_root}:new-generated-body");
    let source = "generated-retry-source";
    let output = directory.path().join("generated.bin");
    let partial = directory.path().join("generated.bin.part");
    let previous_scope = format!("root:{previous_root}");
    set_scope(&previous_scope, vec![previous_scope.clone()]);
    set_scope(&previous_body, vec![previous_scope.clone()]);
    set_scope(&current_body, vec![format!("root:{current_root}")]);
    let lease = output_lock(&output, &previous_body).await.unwrap().unwrap();
    claim_partial_as_with_lease(&partial, source, &previous_body, &lease).unwrap();
    std::fs::write(&partial, b"abcdefgh").unwrap();
    crate::download_transport::seed_resume(&partial, source, 8, "\"generated\"");
    let checkpoint = partial.with_file_name("generated.bin.part.resume.json");
    let mut state: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&checkpoint).unwrap()).unwrap();
    state["source_revision"] = "gcid:LINEAGE".into();
    state["require_content_hash"] = true.into();
    std::fs::write(&checkpoint, serde_json::to_vec(&state).unwrap()).unwrap();
    drop(lease);
    // Restart loses process-local terminal-body retirement while the saved
    // folder remains live and its failed leaf is restored under a fresh root.
    remove_scope(&previous_body);
    clear_retired_scopes(previous_root);
    let manifest_path = lock_path(&output).unwrap().unwrap();
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    manifest["root_id"] = previous_root.to_ascii_lowercase().into();
    manifest["transfer_id"] =
        format!("{}:old-generated-body", previous_root.to_ascii_lowercase()).into();
    std::fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    let original_manifest = std::fs::read(&manifest_path).unwrap();
    let original_checkpoint = std::fs::read(&checkpoint).unwrap();
    let lineage = HashMap::from([
        (current_root.to_ascii_lowercase(), middle_root.to_owned()),
        (middle_root.to_owned(), previous_root.to_ascii_lowercase()),
    ]);
    set_retry_origins(&lineage).unwrap();
    let lease = output_lock(&output, &current_body).await.unwrap().unwrap();
    let assert_preserved = || {
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
        assert_eq!(std::fs::read(&manifest_path).unwrap(), original_manifest);
        assert_eq!(std::fs::read(&checkpoint).unwrap(), original_checkpoint);
    };
    assert!(claim_partial_as(&partial, source, &current_body)
        .unwrap_err()
        .is::<Retry>());
    assert_preserved();
    let wrong = output_lock(&directory.path().join("different.bin"), "wrong-lease")
        .await
        .unwrap()
        .unwrap();
    assert!(claim_partial_as_with_lease(&partial, source, &current_body, &wrong).is_err());
    assert_preserved();
    drop(wrong);
    for graph in [
        HashMap::new(),
        HashMap::from([(current_root.to_owned(), middle_root.to_owned())]),
        HashMap::from([
            (current_root.to_owned(), middle_root.to_owned()),
            (middle_root.to_owned(), current_root.to_owned()),
        ]),
        HashMap::from([
            (current_root.to_owned(), previous_root.to_owned()),
            (previous_root.to_owned(), current_root.to_owned()),
        ]),
        HashMap::from([(current_root.to_owned(), "unrelated-root".into())]),
    ] {
        set_retry_origins(&graph).unwrap();
        assert!(
            claim_partial_as_with_lease(&partial, source, &current_body, &lease)
                .unwrap_err()
                .is::<Retry>()
        );
        assert_preserved();
    }
    assert!(set_retry_origins(&HashMap::from([(
        current_root.into(),
        "invalid/root".into()
    )]))
    .is_err());
    assert!(set_retry_origins(&HashMap::from([
        (current_root.into(), previous_root.into()),
        (current_root.to_ascii_lowercase(), middle_root.into()),
    ]))
    .is_err());
    set_retry_origins(&lineage).unwrap();
    set_scope(&previous_body, vec![previous_scope.clone()]);
    assert!(
        claim_partial_as_with_lease(&partial, source, &current_body, &lease)
            .unwrap_err()
            .is::<Retry>()
    );
    assert_preserved();
    remove_scope(&previous_body);
    let lowercase_body = format!("{}:old-generated-body", previous_root.to_ascii_lowercase());
    set_scope(
        &lowercase_body,
        vec![format!("root:{}", previous_root.to_ascii_lowercase())],
    );
    retire_scope(&lowercase_body);
    std::fs::write(
        &control,
        serde_json::json!({"actions":{previous_scope.clone():"pause"}}).to_string(),
    )
    .unwrap();
    tokio::time::sleep(Duration::from_millis(110)).await;
    assert!(
        claim_partial_as_with_lease(&partial, source, &current_body, &lease)
            .unwrap_err()
            .is::<Retry>(),
        "Retirement bypassed a retry ancestor's Pause"
    );
    assert_preserved();
    clear_retired_scopes(&previous_root.to_ascii_lowercase());
    // Persisted old-body controls use canonical UUID spelling even if an
    // imported ownership record uses lowercase. Ancestor controls include the
    // invisible intermediate retry, not just the original and current roots.
    for key in [
        previous_body.clone(),
        format!("{}:old-generated-body", previous_root.to_ascii_lowercase()),
        previous_scope.clone(),
        format!("root:{}", previous_root.to_ascii_lowercase()),
        format!("root:{middle_root}"),
        format!("root:{current_root}"),
        current_body.clone(),
    ] {
        for action in ["pause", "cancel"] {
            std::fs::write(
                &control,
                serde_json::json!({"actions":{key.clone():action}}).to_string(),
            )
            .unwrap();
            tokio::time::sleep(Duration::from_millis(110)).await;
            assert!(
                claim_partial_as_with_lease(&partial, source, &current_body, &lease)
                    .unwrap_err()
                    .is::<Retry>(),
                "A {action} control on {key} released retry ownership"
            );
            assert_preserved();
        }
    }
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    tokio::time::sleep(Duration::from_millis(110)).await;
    assert!(
        claim_partial_as_with_lease(&partial, "foreign-source", &current_body, &lease).is_err()
    );
    assert_preserved();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "foreign-owner");
    assert!(claim_partial_as_with_lease(&partial, source, &current_body, &lease).is_err());
    assert_preserved();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "synthetic-retry-owner");
    claim_partial_as_with_lease(&partial, source, &current_body, &lease).unwrap();
    let rebound: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    assert_eq!(rebound["transfer_id"], current_body);
    assert_eq!(rebound["root_id"], current_root);
    assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
    remove_owned_partial_as(&partial, source, &previous_body)
        .await
        .unwrap();
    assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
    let mut progress = crate::DownloadProgressContext::new(false, &current_body, "generated.bin");
    progress.source_file_id = source;
    progress.source_revision = Some("gcid:LINEAGE".into());
    progress.require_content_hash = true;
    let network = progress.transferred_bytes.clone();
    let recovered = tokio::time::timeout(
        Duration::from_secs(2),
        crate::download_transport::attempt(
            &reqwest::Client::new(),
            "http://127.0.0.1:1/unreachable-generated-fixture",
            8,
            &partial,
            false,
            progress,
            None,
        ),
    )
    .await
    .unwrap();
    assert!(
        recovered.is_ok(),
        "The full valid stage tried the unreachable CDN"
    );
    assert_eq!(network.load(Ordering::Relaxed), 0);
    let download = pikpak::DownloadInfo {
        web_content_link: "unused-generated".into(),
        name: "generated.bin".into(),
        size: 8,
        source_revision: Some("gcid:LINEAGE".into()),
    };
    let receipt_source = crate::download_receipt::Source::from_download(
        "account:generated-retry".into(),
        source,
        &download,
        8,
    );
    crate::download_receipt::finish(&partial, &output, receipt_source.clone(), &current_body)
        .await
        .unwrap();
    assert!(crate::download_receipt::completed(&output, &receipt_source).unwrap());
    assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
    assert!(!partial.exists());
    // A copy can be committed just before a process dies, leaving its source
    // staging/pointer registered to the old folder. Recreate that generated
    // crash shape beside the already verified committed destination.
    use std::os::unix::fs::MetadataExt;
    std::fs::write(&partial, b"abcdefgh").unwrap();
    let original = std::fs::metadata(&partial).unwrap();
    let original_identity = serde_json::json!({
        "device":original.dev(), "inode":original.ino(), "size":original.len(),
        "modified":i128::from(original.mtime()) * 1_000_000_000 + i128::from(original.mtime_nsec()),
        "changed":i128::from(original.ctime()) * 1_000_000_000 + i128::from(original.ctime_nsec()),
    });
    let pointer_path = partial.with_file_name("generated.bin.part.publication.json");
    std::fs::write(
        &pointer_path,
        serde_json::json!({
            "version":1, "source":receipt_source, "original":original_identity,
            "sha256":hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh")),
        })
        .to_string(),
    )
    .unwrap();
    std::fs::write(&manifest_path, &original_manifest).unwrap();
    assert!(crate::download_receipt::completed(&output, &receipt_source).unwrap());
    assert!(
        partial.exists(),
        "No-lease completion bypassed the live original root"
    );
    let assert_committed_stage_preserved = || {
        assert_eq!(std::fs::read(&partial).unwrap(), b"abcdefgh");
        assert!(pointer_path.exists());
        assert_eq!(std::fs::read(&manifest_path).unwrap(), original_manifest);
        assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
    };
    std::fs::write(
        &control,
        serde_json::json!({"actions":{previous_scope.clone():"pause"}}).to_string(),
    )
    .unwrap();
    tokio::time::sleep(Duration::from_millis(110)).await;
    crate::download_receipt::cleanup_completed_staging_async_with_lease(
        &output,
        &receipt_source,
        &current_body,
        &lease,
    )
    .await
    .unwrap();
    assert_committed_stage_preserved();
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    tokio::time::sleep(Duration::from_millis(110)).await;
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "foreign-owner");
    crate::download_receipt::cleanup_completed_staging_async_with_lease(
        &output,
        &receipt_source,
        &current_body,
        &lease,
    )
    .await
    .unwrap();
    assert_committed_stage_preserved();
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_OWNER", "synthetic-retry-owner");
    set_scope(&previous_body, vec![previous_scope.clone()]);
    crate::download_receipt::cleanup_completed_staging_async_with_lease(
        &output,
        &receipt_source,
        &current_body,
        &lease,
    )
    .await
    .unwrap();
    assert_committed_stage_preserved();
    remove_scope(&previous_body);
    crate::download_receipt::cleanup_completed_staging_async_with_lease(
        &output,
        &receipt_source,
        &current_body,
        &lease,
    )
    .await
    .unwrap();
    assert!(!partial.exists());
    assert!(!pointer_path.exists());
    assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
    retry_ancestry_work_is_bounded();
}

fn retry_ancestry_work_is_bounded() {
    // Stay in the isolated helper subprocess so parallel live-queue fixtures
    // cannot observe a graph replacement from this synthetic depth test.
    let roots = (0..8_193)
        .map(|id| format!("bounded-generated-{id}"))
        .collect::<Vec<_>>();
    let graph = roots
        .windows(2)
        .map(|pair| (pair[0].clone(), pair[1].clone()))
        .collect();
    set_retry_origins(&graph).unwrap();
    assert!(retry_ancestry(&roots[0]).is_none());
    set_retry_origins(&HashMap::new()).unwrap();
    let synthetic = "CaseSensitiveGeneratedSyntheticRoot36";
    assert!(!is_uuid_root(synthetic));
    assert!(ownership_aliases(synthetic)
        .iter()
        .all(|id| id == synthetic));
}

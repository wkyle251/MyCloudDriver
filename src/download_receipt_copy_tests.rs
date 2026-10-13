//! Generated fixtures for volumes without exclusive rename or hard links.
use super::*;
use std::os::unix::fs::MetadataExt;

#[tokio::test]
async fn long_filename_copy_publication_resumes_and_cleans_its_bounded_pointer() {
    let directory = tempfile::tempdir().unwrap();
    let name = format!("{}.bin", "c".repeat(246));
    let output = directory.path().join(&name);
    let partial = directory.path().join(format!("{name}.part"));
    let source = Source {
        scope: "account:long-copy-fixture".into(),
        file_id: "long-copy-file".into(),
        revision: Some("gcid:LONGCOPYFIXTURE".into()),
        size: 8,
    };
    std::fs::write(&partial, b"abcdefgh").unwrap();
    crate::download_transport::seed_resume(&partial, &source.file_id, 8, "\"copy-fixture\"");
    finish_with_options(&partial, &output, source.clone(), "long-copy-transfer",
        FinishOptions { force_copy: true, fault: CopyFault::AfterBytes(3) })
        .await.unwrap_err();
    assert_eq!(std::fs::read(&output).unwrap(), b"abc");
    let pointer = publication_pointer_path(&partial);
    assert!(pointer.exists());
    finish(&partial, &output, source.clone(), "long-copy-transfer").await.unwrap();
    assert_eq!(std::fs::read(&output).unwrap(), b"abcdefgh");
    assert!(!partial.exists() && !pointer.exists());
    crate::download_transport::remove_state(&partial).unwrap();
    assert!(ensure_available(&output, &source).unwrap());
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 2);
}

struct Fixture {
    _temporary: tempfile::TempDir,
    partial: PathBuf,
    output: PathBuf,
    source: Source,
}

impl Fixture {
    fn new() -> Self {
        let temporary = tempfile::Builder::new()
            .prefix("pikpak-copy-fixture-")
            .tempdir()
            .unwrap();
        let partial = temporary.path().join("original.bin.part");
        let output = temporary.path().join("original.bin");
        let source = Source {
            scope: "account:copy-fixture".into(),
            file_id: "copy-file".into(),
            revision: Some("gcid:COPYFIXTURE".into()),
            size: 8,
        };
        std::fs::write(&partial, b"abcdefgh").unwrap();
        crate::download_transport::seed_resume(&partial, &source.file_id, 8, "\"copy-fixture\"");
        Self {
            _temporary: temporary,
            partial,
            output,
            source,
        }
    }

    async fn copy(&self, fault: CopyFault) -> Result<()> {
        finish_with_options(
            &self.partial,
            &self.output,
            self.source.clone(),
            "copy-fixture-transfer",
            FinishOptions {
                force_copy: true,
                fault,
            },
        )
        .await
    }

    async fn resume(&self) -> Result<()> {
        finish_with_options(
            &self.partial,
            &self.output,
            self.source.clone(),
            "copy-fixture-retry",
            FinishOptions::default(),
        )
        .await
    }

    fn receipt_bytes(&self) -> Vec<u8> {
        std::fs::read(path(&self.output, &self.source).unwrap()).unwrap()
    }

    fn with_large_payload() -> (Self, Vec<u8>) {
        let mut fixture = Self::new();
        let payload: Vec<u8> = (0..768 * 1024).map(|index| (index % 251) as u8).collect();
        fixture.source.size = payload.len() as u64;
        std::fs::write(&fixture.partial, &payload).unwrap();
        crate::download_transport::seed_resume(
            &fixture.partial,
            &fixture.source.file_id,
            fixture.source.size,
            "\"copy-fixture\"",
        );
        (fixture, payload)
    }

    fn stale_empty_copy_receipt(&self) {
        let receipt_path = path(&self.output, &self.source).unwrap();
        let mut receipt = load(&receipt_path).unwrap().unwrap();
        let copy = receipt.copy.as_mut().unwrap();
        // Model a pre-allocation ownership snapshot retained across a failed
        // copy. This is an injected fixture, not a claim about the host FS.
        copy.output.inode = 0;
        copy.output.size = 0;
        copy.durable_bytes = 0;
        copy.prefix_sha256 = hex::encode(ring::digest::digest(&ring::digest::SHA256, &[]));
        assert_ne!(
            copy.output.inode,
            std::fs::metadata(&self.output).unwrap().ino()
        );
        save(&receipt_path, &receipt).unwrap();
    }

    fn legacy_initial_exfat_receipt(&self) {
        self.stale_empty_copy_receipt();
        let receipt_path = path(&self.output, &self.source).unwrap();
        let mut receipt = load(&receipt_path).unwrap().unwrap();
        let creation = birth_timestamp(&std::fs::metadata(&self.output).unwrap()).unwrap();
        let copy = receipt.copy.as_mut().unwrap();
        // Inject the original empty-file timestamps and changed inode. The
        // filesystem detector is injected separately; fixtures remain local.
        copy.output.modified = creation;
        copy.output.changed = creation;
        save(&receipt_path, &receipt).unwrap();
    }
}

#[tokio::test]
async fn automatic_conflict_recovery_keeps_verified_staging_after_identity_changes() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    let replacement = fixture.partial.with_file_name("restored-staging.bin");
    std::fs::write(&replacement, b"abcdefgh").unwrap();
    std::fs::rename(&replacement, &fixture.partial).unwrap();
    let before = Identity::read(&std::fs::metadata(&fixture.partial).unwrap()).unwrap();
    assert!(ensure_available_path_async_replacing(
        &fixture.output, &fixture.source, "generated-auto-restore", None, None,
    ).await.unwrap().is_none());
    assert!(!fixture.output.exists());
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    assert_eq!(Identity::read(&std::fs::metadata(&fixture.partial).unwrap()).unwrap(), before);
    fixture.resume().await.unwrap();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert!(completed(&fixture.output, &fixture.source).unwrap());
}

#[tokio::test]
async fn automatic_conflict_recovery_deletes_bad_staging_and_its_checkpoints() {
    for missing in [false, true] {
        let fixture = Fixture::new();
        fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
        if missing {
            std::fs::remove_file(&fixture.partial).unwrap();
        } else {
            std::fs::write(&fixture.partial, b"BAD-DATA").unwrap();
        }
        for suffix in [".ranges.json", ".ranges.data"] {
            let mut path = fixture.partial.as_os_str().to_owned();
            path.push(suffix);
            std::fs::write(PathBuf::from(path), b"generated stale checkpoint").unwrap();
        }
        let unrelated = fixture.output.with_file_name("unrelated.bin");
        std::fs::write(&unrelated, b"KEEP").unwrap();
        assert!(ensure_available_path_async_replacing(
            &fixture.output, &fixture.source, "generated-auto-reset", None, None,
        ).await.unwrap().is_none());
        for target in [&fixture.output, &fixture.partial, &path(&fixture.output, &fixture.source).unwrap(),
            &publication_pointer_path(&fixture.partial)] {
            assert!(!target.exists(), "{} should be reset", target.display());
        }
        assert!(!crate::download_transport::has_parts(&fixture.partial));
        assert!(!fixture.partial.with_extension("part.resume.json").exists());
        assert_eq!(std::fs::read(&unrelated).unwrap(), b"KEEP");
        // A fresh attempt can publish normally rather than revisiting the conflict.
        std::fs::write(&fixture.partial, b"abcdefgh").unwrap();
        fixture.resume().await.unwrap();
        assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    }
}

#[tokio::test]
async fn automatic_conflict_recovery_preflights_metadata_without_following_links() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    std::fs::write(&fixture.partial, b"BAD-DATA").unwrap();
    let outside = fixture.output.with_file_name("outside.bin");
    std::fs::write(&outside, b"KEEP").unwrap();
    let mut sidecar = fixture.partial.as_os_str().to_owned();
    sidecar.push(".ranges.json");
    std::os::unix::fs::symlink(&outside, PathBuf::from(sidecar)).unwrap();
    let receipt = fixture.receipt_bytes();
    let error = ensure_available_path_async_replacing(
        &fixture.output, &fixture.source, "generated-auto-link", None, None,
    ).await.unwrap_err();
    assert_eq!(pikpak::download_policy::permanent_failure(&error), None);
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"BAD-DATA");
    assert_eq!(std::fs::read(&outside).unwrap(), b"KEEP");
    assert_eq!(fixture.receipt_bytes(), receipt);
}

#[tokio::test]
async fn legacy_initial_exfat_checkpoint_recovers_verified_first_copy_prefix_without_rewriting_it()
{
    let (fixture, payload) = Fixture::with_large_payload();
    fixture
        .copy(CopyFault::AfterBytes(256 * 1024))
        .await
        .unwrap_err();
    fixture.legacy_initial_exfat_receipt();
    let destination_before = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    let stage_before = Identity::read(&std::fs::metadata(&fixture.partial).unwrap()).unwrap();
    let receipt_before = fixture.receipt_bytes();
    let error = pending_copy_available_with_filesystem(
        &fixture.output,
        &fixture.source,
        "generated-legacy-copy",
        &|_| Ok(false),
    )
    .unwrap_err();
    assert!(
        format!("{error:#}").contains("Download copy destination changed; it was preserved"),
        "{error:#}"
    );
    assert_eq!(fixture.receipt_bytes(), receipt_before);
    assert!(pending_copy_available_with_filesystem(
        &fixture.output,
        &fixture.source,
        "generated-legacy-copy",
        &|_| Ok(true),
    )
    .unwrap());
    assert_eq!(
        std::fs::read(&fixture.output).unwrap(),
        payload[..256 * 1024]
    );
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), payload);
    assert_eq!(
        Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap(),
        destination_before,
        "Repair must only refresh the receipt, without writing destination payload"
    );
    assert_eq!(
        Identity::read(&std::fs::metadata(&fixture.partial).unwrap()).unwrap(),
        stage_before
    );
    let receipt = load(&path(&fixture.output, &fixture.source).unwrap())
        .unwrap()
        .unwrap();
    let copy = receipt.copy.unwrap();
    assert_eq!(copy.output, destination_before);
    assert_eq!(copy.durable_bytes, 256 * 1024);
    assert_eq!(
        copy.prefix_sha256,
        hex::encode(ring::digest::digest(
            &ring::digest::SHA256,
            &payload[..256 * 1024]
        ))
    );
    assert_eq!(
        crate::download_transport::saved_bytes(
            &fixture.partial,
            &fixture.source.file_id,
            fixture.source.size
        )
        .await,
        fixture.source.size
    );
    fixture.resume().await.unwrap();
    assert!(completed(&fixture.output, &fixture.source).unwrap());
    assert_eq!(std::fs::read(&fixture.output).unwrap(), payload);
}

#[tokio::test]
async fn legacy_initial_exfat_repair_rejects_unproven_creation_binding_or_prefix_without_changes() {
    for mutation in [
        "birth-10ms",
        "birth-30ms",
        "different-empty-times",
        "device",
        "prefix",
        "missing-pointer",
        "wrong-pointer-source",
        "too-large-prefix",
        "zero-prefix",
        "nonzero-checkpoint",
        "nonzero-recorded-size",
        "nonempty-recorded-digest",
        "changed-stage",
        "replaced-stage",
        "symlink-output",
        "non-exfat",
    ] {
        let (fixture, payload) = Fixture::with_large_payload();
        fixture
            .copy(CopyFault::AfterBytes(256 * 1024))
            .await
            .unwrap_err();
        fixture.legacy_initial_exfat_receipt();
        let receipt_path = path(&fixture.output, &fixture.source).unwrap();
        let mut receipt = load(&receipt_path).unwrap().unwrap();
        let copy = receipt.copy.as_mut().unwrap();
        match mutation {
            "birth-10ms" | "birth-30ms" => {
                copy.output.modified += if mutation == "birth-10ms" {
                    10_000_000
                } else {
                    30_000_000
                };
                copy.output.changed = copy.output.modified;
            }
            "different-empty-times" => copy.output.changed += 10_000_000,
            "device" => copy.output.device ^= 1,
            "prefix" => std::fs::write(&fixture.output, b"BAD").unwrap(),
            "missing-pointer" => remove_publication_pointer(&fixture.partial).unwrap(),
            "wrong-pointer-source" => {
                let mut pointer = load_publication_pointer(&fixture.partial).unwrap().unwrap();
                pointer.source.scope = "account:another-generated-fixture".into();
                download_fs::atomic_write(
                    &publication_pointer_path(&fixture.partial),
                    &serde_json::to_vec(&pointer).unwrap(),
                )
                .unwrap();
            }
            "too-large-prefix" => {
                std::fs::write(&fixture.output, &payload[..256 * 1024 + 1]).unwrap()
            }
            "zero-prefix" => std::fs::write(&fixture.output, []).unwrap(),
            "nonzero-checkpoint" => copy.durable_bytes = 1,
            "nonzero-recorded-size" => copy.output.size = 1,
            "nonempty-recorded-digest" => {
                copy.prefix_sha256 = hex::encode(ring::digest::digest(&ring::digest::SHA256, b"a"))
            }
            "changed-stage" => std::fs::write(&fixture.partial, vec![0; payload.len()]).unwrap(),
            "replaced-stage" => {
                let replacement = fixture.partial.with_file_name("generated-new-stage.bin");
                std::fs::write(&replacement, &payload).unwrap();
                std::fs::rename(&replacement, &fixture.partial).unwrap();
            }
            "symlink-output" => {
                let target = fixture
                    .output
                    .with_file_name("generated-symlink-prefix.bin");
                std::fs::write(&target, &payload[..256 * 1024]).unwrap();
                std::fs::remove_file(&fixture.output).unwrap();
                std::os::unix::fs::symlink(&target, &fixture.output).unwrap();
            }
            "non-exfat" => {}
            other => panic!("Unknown generated mutation {other}"),
        }
        save(&receipt_path, &receipt).unwrap();
        let destination_before = std::fs::read(&fixture.output).unwrap();
        let stage_before = std::fs::read(&fixture.partial).unwrap();
        let receipt_before = fixture.receipt_bytes();
        let pointer_before = std::fs::read(publication_pointer_path(&fixture.partial)).ok();
        let error = pending_copy_available_with_filesystem(
            &fixture.output,
            &fixture.source,
            "generated-legacy-negative",
            &|_| Ok(mutation != "non-exfat"),
        )
        .expect_err(mutation);
        if mutation == "changed-stage" || mutation == "replaced-stage" {
            assert!(error.downcast_ref::<VerifiedStagingProgress>().is_none());
        }
        assert_eq!(
            std::fs::read(&fixture.output).unwrap(),
            destination_before,
            "{mutation}"
        );
        assert_eq!(
            std::fs::read(&fixture.partial).unwrap(),
            stage_before,
            "{mutation}"
        );
        assert_eq!(fixture.receipt_bytes(), receipt_before, "{mutation}");
        assert_eq!(
            std::fs::read(publication_pointer_path(&fixture.partial)).ok(),
            pointer_before,
            "{mutation}"
        );
    }
}

#[tokio::test]
async fn full_copy_with_stale_empty_file_inode_is_verified_and_adopted_without_rewriting_output() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    std::fs::File::options()
        .append(true)
        .open(&fixture.output)
        .unwrap()
        .write_all(b"defgh")
        .unwrap();
    fixture.stale_empty_copy_receipt();
    let before = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    assert!(ensure_available(&fixture.output, &fixture.source).unwrap());
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert_eq!(
        Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap(),
        before,
        "Recognizing matching full bytes must not rewrite or replace the destination"
    );
    assert!(!fixture.partial.exists());
    assert!(completed(&fixture.output, &fixture.source).unwrap());
}

#[tokio::test]
async fn retained_writer_refreshes_stale_inode_snapshot_in_its_synced_copy_checkpoint() {
    let fixture = Fixture::new();
    let error = fixture
        .copy(CopyFault::StaleWriterInodeAfterBytes(3))
        .await
        .unwrap_err();
    assert!(
        error.to_string().contains("Generated copy interruption"),
        "{error:#}"
    );
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
    let receipt = load(&path(&fixture.output, &fixture.source).unwrap())
        .unwrap()
        .unwrap();
    let copy = receipt.copy.unwrap();
    assert_eq!(
        copy.output.inode,
        std::fs::metadata(&fixture.output).unwrap().ino()
    );
    assert_eq!(copy.durable_bytes, 3);
    assert!(!ensure_available(&fixture.output, &fixture.source).unwrap());
    fixture.resume().await.unwrap();
    assert!(completed(&fixture.output, &fixture.source).unwrap());
}

#[tokio::test]
async fn retained_writer_cannot_publish_or_modify_a_destination_replaced_during_copy() {
    let (fixture, payload) = Fixture::with_large_payload();
    fixture
        .copy(CopyFault::ReplaceDestinationDuringCopy(256 * 1024))
        .await
        .unwrap_err();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"reserved");
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), payload);
    assert!(
        !load(&path(&fixture.output, &fixture.source).unwrap())
            .unwrap()
            .unwrap()
            .committed
    );
    assert!(ensure_available(&fixture.output, &fixture.source).is_err());
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"reserved");
}

#[tokio::test]
async fn matching_full_replacement_can_be_recognized_but_its_payload_is_never_modified() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    let replacement = fixture
        .output
        .with_file_name("generated-full-replacement.bin");
    std::fs::write(&replacement, b"abcdefgh").unwrap();
    std::fs::rename(&replacement, &fixture.output).unwrap();
    fixture.stale_empty_copy_receipt();
    let before = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    assert!(ensure_available(&fixture.output, &fixture.source).unwrap());
    assert_eq!(
        Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap(),
        before
    );
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert!(completed(&fixture.output, &fixture.source).unwrap());
}

#[tokio::test]
async fn stale_copy_inode_never_allows_partial_wrong_bytes_or_changed_original_to_be_overwritten() {
    for mutation in [
        "partial",
        "wrong-output",
        "changed-original",
        "replaced-original",
        "symlink-output",
        "missing-pointer",
    ] {
        let fixture = Fixture::new();
        fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
        if mutation != "partial" {
            std::fs::write(
                &fixture.output,
                if mutation == "wrong-output" {
                    b"BAD-COPY"
                } else {
                    b"abcdefgh"
                },
            )
            .unwrap();
        }
        if mutation == "changed-original" {
            std::fs::write(&fixture.partial, b"BAD-DATA").unwrap();
        } else if mutation == "replaced-original" {
            let replacement = fixture.partial.with_file_name("generated-new-original.bin");
            std::fs::write(&replacement, b"abcdefgh").unwrap();
            std::fs::rename(&replacement, &fixture.partial).unwrap();
        } else if mutation == "symlink-output" {
            let external = fixture
                .output
                .with_file_name("generated-full-symlink-target.bin");
            std::fs::write(&external, b"abcdefgh").unwrap();
            std::fs::remove_file(&fixture.output).unwrap();
            std::os::unix::fs::symlink(&external, &fixture.output).unwrap();
        } else if mutation == "missing-pointer" {
            remove_publication_pointer(&fixture.partial).unwrap();
        }
        fixture.stale_empty_copy_receipt();
        let destination_before = std::fs::read(&fixture.output).unwrap();
        let original_before = std::fs::read(&fixture.partial).unwrap();
        let receipt_before = fixture.receipt_bytes();
        assert!(
            ensure_available(&fixture.output, &fixture.source).is_err(),
            "Accepted {mutation}"
        );
        fixture.resume().await.unwrap_err();
        assert_eq!(
            std::fs::read(&fixture.output).unwrap(),
            destination_before,
            "Rewrote {mutation}"
        );
        assert_eq!(
            std::fs::read(&fixture.partial).unwrap(),
            original_before,
            "Removed {mutation}"
        );
        assert_eq!(
            fixture.receipt_bytes(),
            receipt_before,
            "Rebound {mutation}"
        );
    }
}

#[tokio::test]
async fn rejected_copy_reports_only_independently_verified_staging_progress() {
    for changed_original in [false, true] {
        let fixture = Fixture::new();
        fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
        fixture.stale_empty_copy_receipt();
        if changed_original {
            std::fs::write(&fixture.partial, b"BAD-DATA").unwrap();
        }
        let error = ensure_available(&fixture.output, &fixture.source).unwrap_err();
        let proof = error.downcast_ref::<VerifiedStagingProgress>();
        if changed_original {
            assert!(
                proof.is_none(),
                "Raw staging length is not proof of retained bytes"
            );
        } else {
            let proof = proof.unwrap();
            assert_eq!(proof.downloaded_bytes, 8);
            assert_eq!(proof.total_bytes, 8);
            assert_eq!(
                proof.failure,
                "Download copy destination changed; it was preserved"
            );
        }
        let message = proof
            .map(|proof| proof.failure.clone())
            .unwrap_or_else(|| format!("{error:#}"));
        let events = serde_json::to_value(crate::download_failure_progress_events(
            &error,
            "generated-transfer",
            "generated.bin",
            99,
            &message,
        ))
        .unwrap();
        let events = events.as_array().unwrap();
        if changed_original {
            assert_eq!(events.len(), 1);
            assert_eq!(events[0]["downloaded_bytes"], 0);
        } else {
            assert_eq!(events.len(), 2);
            assert_eq!(events[0]["event"], "file_started");
            assert_eq!(events[1]["event"], "file_failed");
            for event in events {
                assert_eq!(event["downloaded_bytes"], 8);
                assert_eq!(event["total_bytes"], 8);
                assert_eq!(event["transferred_bytes"], 0);
            }
        }
        assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
    }
}

#[tokio::test]
async fn copy_tolerates_delayed_source_and_destination_timestamps_after_verifying_both_files() {
    for original in [false, true] {
        let (fixture, payload) = Fixture::with_large_payload();
        fixture
            .copy(CopyFault::ChangeDuringCopy {
                at: 256 * 1024,
                original,
                bytes: false,
            })
            .await
            .unwrap();
        assert_eq!(std::fs::read(&fixture.output).unwrap(), payload);
        assert!(!fixture.partial.exists());
        assert!(completed(&fixture.output, &fixture.source).unwrap());
    }
}

#[tokio::test]
async fn pending_copy_reconciles_timestamp_only_changes_without_redownloading_or_recreating_output()
{
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    let inode = std::fs::metadata(&fixture.output).unwrap().ino();
    for changed in [&fixture.partial, &fixture.output] {
        let file = std::fs::File::options().write(true).open(changed).unwrap();
        let modified =
            file.metadata().unwrap().modified().unwrap() + std::time::Duration::from_secs(5);
        file.set_times(std::fs::FileTimes::new().set_modified(modified))
            .unwrap();
    }
    assert!(!ensure_available(&fixture.output, &fixture.source).unwrap());
    fixture.resume().await.unwrap();
    assert_eq!(std::fs::metadata(&fixture.output).unwrap().ino(), inode);
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert!(completed(&fixture.output, &fixture.source).unwrap());
}

#[tokio::test]
async fn timestamp_tolerance_still_preserves_real_edits_behind_the_copy_reader() {
    for original in [false, true] {
        let (fixture, payload) = Fixture::with_large_payload();
        let error = fixture
            .copy(CopyFault::ChangeDuringCopy {
                at: 256 * 1024,
                original,
                bytes: true,
            })
            .await
            .unwrap_err();
        assert!(error.to_string().contains("bytes changed"), "{error:#}");
        let mut changed = payload.clone();
        changed[..8].copy_from_slice(b"CHANGED!");
        assert_eq!(
            std::fs::read(&fixture.partial).unwrap(),
            if original { &changed } else { &payload }.as_slice()
        );
        assert_eq!(
            std::fs::read(&fixture.output).unwrap(),
            if original { &payload } else { &changed }.as_slice()
        );
        assert!(
            !load(&path(&fixture.output, &fixture.source).unwrap())
                .unwrap()
                .unwrap()
                .committed
        );
    }
}

#[tokio::test]
async fn unsupported_native_publication_copies_verified_original_and_binds_output_inode() {
    let fixture = Fixture::new();
    let staging_inode = std::fs::metadata(&fixture.partial).unwrap().ino();
    assert!(!ensure_available(&fixture.output, &fixture.source).unwrap());
    fixture.copy(CopyFault::None).await.unwrap();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert_ne!(
        std::fs::metadata(&fixture.output).unwrap().ino(),
        staging_inode
    );
    assert!(
        !fixture.partial.exists(),
        "Committed copy retained its original staging file"
    );
    assert!(completed(&fixture.output, &fixture.source).unwrap());
    assert!(ensure_available(&fixture.output, &fixture.source).unwrap());
    let mut unrelated = fixture.source.clone();
    unrelated.scope = "account:unrelated-fixture".into();
    assert!(ensure_available(&fixture.output, &unrelated).is_err());
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
}

#[tokio::test]
async fn interrupted_owned_copy_resumes_without_treating_its_prefix_as_completed() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    let output_inode = std::fs::metadata(&fixture.output).unwrap().ino();
    assert!(!completed(&fixture.output, &fixture.source).unwrap());
    assert!(
        !ensure_available(&fixture.output, &fixture.source).unwrap(),
        "Owned publication progress was rejected as an unrelated destination"
    );
    fixture.resume().await.unwrap();
    assert_eq!(
        std::fs::metadata(&fixture.output).unwrap().ino(),
        output_inode,
        "Resume recreated the durable owned copy instead of continuing it"
    );
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert!(!fixture.partial.exists());
    assert!(completed(&fixture.output, &fixture.source).unwrap());
}

#[tokio::test]
async fn interrupted_copy_discards_only_its_uncheckpointed_tail_after_verification() {
    use std::io::Write;
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    let output_inode = std::fs::metadata(&fixture.output).unwrap().ino();
    // A process stop can leave later writes beyond the last durable copy
    // checkpoint. Those bytes are not yet part of the verified original.
    std::fs::File::options()
        .append(true)
        .open(&fixture.output)
        .unwrap()
        .write_all(b"ZZ")
        .unwrap();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcZZ");
    assert!(!ensure_available(&fixture.output, &fixture.source).unwrap());
    assert!(!completed(&fixture.output, &fixture.source).unwrap());
    fixture.resume().await.unwrap();
    assert_eq!(
        std::fs::metadata(&fixture.output).unwrap().ino(),
        output_inode
    );
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert!(!fixture.partial.exists());
    assert!(completed(&fixture.output, &fixture.source).unwrap());
}

#[tokio::test]
async fn copy_ownership_gap_preserves_the_unverified_exclusively_created_destination() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::BeforeOwnership).await.unwrap_err();
    assert!(fixture.output.exists());
    let output_before = std::fs::read(&fixture.output).unwrap();
    let receipt_before = fixture.receipt_bytes();
    assert!(!completed(&fixture.output, &fixture.source).unwrap());
    assert!(
        ensure_available(&fixture.output, &fixture.source).is_err(),
        "An unrecorded output inode was treated as resumable app-owned data"
    );
    fixture.resume().await.unwrap_err();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), output_before);
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    assert_eq!(fixture.receipt_bytes(), receipt_before);
}

#[tokio::test]
async fn late_destination_and_symlink_are_never_replaced_by_copy_publication() {
    for symlink in [false, true] {
        let fixture = Fixture::new();
        assert!(!ensure_available(&fixture.output, &fixture.source).unwrap());
        let external = fixture.output.with_file_name("generated-external.bin");
        if symlink {
            std::fs::write(&external, b"reserved").unwrap();
            std::os::unix::fs::symlink(&external, &fixture.output).unwrap();
        } else {
            std::fs::write(&fixture.output, b"reserved").unwrap();
        }
        fixture.copy(CopyFault::None).await.unwrap_err();
        assert_eq!(std::fs::read(&fixture.output).unwrap(), b"reserved");
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
        if symlink {
            assert!(std::fs::symlink_metadata(&fixture.output)
                .unwrap()
                .file_type()
                .is_symlink());
            assert_eq!(std::fs::read(&external).unwrap(), b"reserved");
        }
    }
}

#[tokio::test]
async fn changed_or_replaced_owned_copy_is_preserved_and_never_resumed() {
    for mutation in ["bytes", "replacement", "symlink"] {
        let fixture = Fixture::new();
        fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
        let receipt_before = fixture.receipt_bytes();
        let modified = std::fs::metadata(&fixture.output)
            .unwrap()
            .modified()
            .unwrap();
        match mutation {
            "bytes" => {
                std::fs::write(&fixture.output, b"xyz").unwrap();
                std::fs::File::options()
                    .write(true)
                    .open(&fixture.output)
                    .unwrap()
                    .set_times(std::fs::FileTimes::new().set_modified(modified))
                    .unwrap();
            }
            "replacement" => {
                let replacement = fixture.output.with_file_name("generated-replacement.bin");
                std::fs::write(&replacement, b"xyz").unwrap();
                std::fs::rename(&replacement, &fixture.output).unwrap();
            }
            "symlink" => {
                let external = fixture
                    .output
                    .with_file_name("generated-symlink-target.bin");
                std::fs::write(&external, b"xyz").unwrap();
                std::fs::remove_file(&fixture.output).unwrap();
                std::os::unix::fs::symlink(&external, &fixture.output).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(
            ensure_available(&fixture.output, &fixture.source).is_err(),
            "Accepted {mutation}"
        );
        fixture.resume().await.unwrap_err();
        assert_eq!(
            std::fs::read(&fixture.output).unwrap(),
            b"xyz",
            "Overwrote {mutation}"
        );
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
        assert_eq!(
            fixture.receipt_bytes(),
            receipt_before,
            "Rebound ownership after {mutation}"
        );
    }
}

#[tokio::test]
async fn completed_durable_copy_is_adopted_after_interrupted_receipt_commit() {
    let fixture = Fixture::new();
    fixture
        .copy(CopyFault::AfterCopyBeforeCommit)
        .await
        .unwrap_err();
    let output_inode = std::fs::metadata(&fixture.output).unwrap().ino();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    assert!(
        !load(&path(&fixture.output, &fixture.source).unwrap())
            .unwrap()
            .unwrap()
            .committed
    );
    assert!(completed(&fixture.output, &fixture.source).unwrap());
    assert_eq!(
        std::fs::metadata(&fixture.output).unwrap().ino(),
        output_inode
    );
    assert!(
        load(&path(&fixture.output, &fixture.source).unwrap())
            .unwrap()
            .unwrap()
            .committed
    );
    assert!(ensure_available(&fixture.output, &fixture.source).unwrap());
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    if fixture.partial.exists() {
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    }
}

#[tokio::test]
async fn modified_original_cannot_continue_a_durable_copy_or_rebind_its_receipt() {
    for replacement in [false, true] {
        let fixture = Fixture::new();
        fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
        let receipt_before = fixture.receipt_bytes();
        if replacement {
            let changed = fixture
                .partial
                .with_file_name("generated-staging-replacement.bin");
            std::fs::write(&changed, b"BAD-DATA").unwrap();
            std::fs::rename(&changed, &fixture.partial).unwrap();
        } else {
            std::fs::write(&fixture.partial, b"BAD-DATA").unwrap();
        }
        fixture.resume().await.unwrap_err();
        assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"BAD-DATA");
        assert_eq!(fixture.receipt_bytes(), receipt_before);
    }
}

#[tokio::test]
async fn a_changed_staging_file_is_retryable_and_receipt_check_keeps_every_file() {
    use pikpak::download_policy::{permanent_failure, retryable};
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    std::fs::write(&fixture.partial, b"BAD-DATA").unwrap();
    let receipt_before = fixture.receipt_bytes();
    let error = ensure_available(&fixture.output, &fixture.source).unwrap_err();
    assert!(
        format!("{error:#}").contains("staging file changed; it was preserved"),
        "{error:#}"
    );
    assert!(
        format!("{error:#}").contains("its contents differ from the recorded copy"),
        "{error:#}"
    );
    assert_eq!(permanent_failure(&error), None);
    assert!(retryable(&error));
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"BAD-DATA");
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
    assert_eq!(fixture.receipt_bytes(), receipt_before);
}

#[tokio::test]
async fn a_resized_staging_file_is_reported_as_a_size_difference() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    std::fs::write(&fixture.partial, b"SHORT").unwrap();
    let error = ensure_available(&fixture.output, &fixture.source).unwrap_err();
    let message = format!("{error:#}");
    assert!(message.contains("staging file changed; it was preserved"), "{message}");
    assert!(message.contains("size differs from the recorded copy"), "{message}");
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"SHORT");
}

#[test]
fn an_unverified_destination_is_retryable_and_receipt_check_leaves_it_untouched() {
    use pikpak::download_policy::{permanent_failure, retryable};
    let fixture = Fixture::new();
    std::fs::write(&fixture.output, b"OLD-DATA").unwrap();
    let error = ensure_available(&fixture.output, &fixture.source).unwrap_err();
    assert!(
        format!("{error:#}").starts_with("Destination already contains a different or unverified file"),
        "{error:#}"
    );
    assert_eq!(permanent_failure(&error), None);
    assert!(retryable(&error));
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"OLD-DATA");
    let message = format!("{error:#}");
    assert!(
        message.contains("no receipt for this file and cloud version; cloud revision: content hash; same size"),
        "{message}"
    );
    std::fs::write(&fixture.output, b"OLD").unwrap();
    let error = ensure_available(&fixture.output, &fixture.source).unwrap_err();
    assert!(format!("{error:#}").contains("different size"), "{error:#}");
}

#[tokio::test]
async fn cancellation_removes_only_owned_copy_publication_and_retains_staging_for_its_caller() {
    let fixture = Fixture::new();
    fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
    let receipt_path = path(&fixture.output, &fixture.source).unwrap();
    let pointer_path = publication_pointer_path(&fixture.partial);
    assert!(receipt_path.exists());
    assert!(pointer_path.exists());
    cancel_pending_publication(
        &fixture.partial,
        &fixture.source.file_id,
        "copy-cancel-fixture",
    )
    .unwrap();
    assert!(!fixture.output.exists());
    assert!(!receipt_path.exists());
    assert!(!pointer_path.exists());
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    assert_eq!(
        crate::download_transport::saved_bytes(&fixture.partial, &fixture.source.file_id, 8).await,
        8
    );
}

#[tokio::test]
async fn cancellation_preserves_changed_replaced_and_unrecorded_copy_destinations() {
    for mutation in ["bytes", "replacement", "unrecorded"] {
        let fixture = Fixture::new();
        fixture
            .copy(if mutation == "unrecorded" {
                CopyFault::BeforeOwnership
            } else {
                CopyFault::AfterBytes(3)
            })
            .await
            .unwrap_err();
        if mutation == "bytes" {
            std::fs::write(&fixture.output, b"xyz").unwrap();
        } else if mutation == "replacement" {
            let replacement = fixture
                .output
                .with_file_name("generated-cancel-replacement.bin");
            std::fs::write(&replacement, b"xyz").unwrap();
            std::fs::rename(&replacement, &fixture.output).unwrap();
        }
        let output_before = std::fs::read(&fixture.output).unwrap();
        let receipt_before = fixture.receipt_bytes();
        let pointer_before = std::fs::read(publication_pointer_path(&fixture.partial)).unwrap();
        cancel_pending_publication(
            &fixture.partial,
            &fixture.source.file_id,
            "copy-cancel-fixture",
        )
        .unwrap_err();
        assert_eq!(
            std::fs::read(&fixture.output).unwrap(),
            output_before,
            "Removed {mutation} destination"
        );
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
        assert_eq!(fixture.receipt_bytes(), receipt_before);
        assert_eq!(
            std::fs::read(publication_pointer_path(&fixture.partial)).unwrap(),
            pointer_before
        );
    }
}

#[tokio::test]
async fn cancellation_never_removes_a_committed_output_even_if_staging_cleanup_was_interrupted() {
    let fixture = Fixture::new();
    fixture
        .copy(CopyFault::AfterCopyBeforeCommit)
        .await
        .unwrap_err();
    let receipt_path = path(&fixture.output, &fixture.source).unwrap();
    let mut receipt = load(&receipt_path).unwrap().unwrap();
    // Simulate a stop after the final receipt commit and before staging unlink.
    receipt.local = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    receipt.committed = true;
    receipt.copy = None;
    save(&receipt_path, &receipt).unwrap();
    let receipt_before = fixture.receipt_bytes();
    cancel_pending_publication(
        &fixture.partial,
        &fixture.source.file_id,
        "copy-cancel-fixture",
    )
    .unwrap();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abcdefgh");
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    assert_eq!(fixture.receipt_bytes(), receipt_before);
    assert!(!publication_pointer_path(&fixture.partial).exists());
}

#[tokio::test]
async fn cancellation_refuses_wrong_source_or_modified_original_without_removing_progress() {
    for changed_original in [false, true] {
        let fixture = Fixture::new();
        fixture.copy(CopyFault::AfterBytes(3)).await.unwrap_err();
        if changed_original {
            std::fs::write(&fixture.partial, b"BAD-DATA").unwrap();
        }
        let original_before = std::fs::read(&fixture.partial).unwrap();
        let receipt_before = fixture.receipt_bytes();
        let pointer_before = std::fs::read(publication_pointer_path(&fixture.partial)).unwrap();
        let file_id = if changed_original {
            &fixture.source.file_id
        } else {
            "unrelated-cloud-file"
        };
        cancel_pending_publication(&fixture.partial, file_id, "copy-cancel-fixture").unwrap_err();
        assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), original_before);
        assert_eq!(fixture.receipt_bytes(), receipt_before);
        assert_eq!(
            std::fs::read(publication_pointer_path(&fixture.partial)).unwrap(),
            pointer_before
        );
    }
}

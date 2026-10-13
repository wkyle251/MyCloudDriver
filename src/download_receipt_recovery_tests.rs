//! Alternate publication uses generated files and private test namespaces only.
use super::*;

struct Fixture {
    _directory: tempfile::TempDir,
    output: PathBuf,
    partial: PathBuf,
    source: Source,
}

impl Fixture {
    async fn new(empty_checkpoint: bool, known_revision: bool) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("generated original.bin");
        let partial = directory.path().join("generated original.bin.part");
        let source = Source {
            scope: "account:generated-recovery".into(),
            file_id: "generated-recovery-source".into(),
            revision: known_revision.then(|| "gcid:GENERATEDRECOVERY".into()),
            size: 8,
        };
        std::fs::write(&partial, b"abcdefgh").unwrap();
        crate::download_transport::seed_resume(&partial, &source.file_id, 8, "\"generated\"");
        finish_with_options(
            &partial,
            &output,
            source.clone(),
            "generated-recovery-setup",
            FinishOptions {
                force_copy: true,
                fault: CopyFault::AfterBytes(3),
            },
        )
        .await
        .unwrap_err();
        let result = Self {
            _directory: directory,
            output,
            partial,
            source,
        };
        let mut receipt = result.receipt();
        let copy = receipt.copy.as_mut().unwrap();
        copy.output.inode ^= 1;
        if empty_checkpoint {
            copy.output.size = 0;
            copy.output.modified = -1;
            copy.output.changed = -1;
            copy.durable_bytes = 0;
            copy.prefix_sha256 = hex::encode(ring::digest::digest(&ring::digest::SHA256, &[]));
        }
        save(&result.receipt_path(), &receipt).unwrap();
        result
    }

    fn receipt_path(&self) -> PathBuf {
        path(&self.output, &self.source).unwrap()
    }
    fn receipt(&self) -> Receipt {
        load(&self.receipt_path()).unwrap().unwrap()
    }
    fn receipt_bytes(&self) -> Vec<u8> {
        std::fs::read(self.receipt_path()).unwrap()
    }
    fn pointer_bytes(&self) -> Vec<u8> {
        std::fs::read(publication_pointer_path(&self.partial)).unwrap()
    }
    fn recover(&self, transfer: &str) -> Result<PathBuf> {
        assert!(pending_copy_available_with_recovery(
            &self.output,
            &self.source,
            transfer,
            &|_| Ok(true),
            true,
        )?);
        receipt_output(&self.output, &self.receipt())
    }
    async fn interrupt_recovery(&self, fault: CopyFault) -> Result<()> {
        finish_with_options(
            &self.partial,
            &self.output,
            self.source.clone(),
            "generated-recovery-copy",
            FinishOptions {
                force_copy: false,
                fault,
            },
        )
        .await
    }
    fn assert_original(&self, before: &Identity) {
        assert_eq!(std::fs::read(&self.output).unwrap(), b"abc");
        assert_eq!(
            Identity::read(&std::fs::metadata(&self.output).unwrap()).unwrap(),
            *before
        );
    }
}

#[tokio::test]
async fn source_verified_recovery_finishes_both_empty_and_nonzero_conflicted_checkpoints() {
    for empty in [true, false] {
        let fixture = Fixture::new(empty, true).await;
        let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
        let actual = fixture.recover("generated-reserve").unwrap();
        assert_ne!(actual, fixture.output);
        assert!(actual
            .file_name()
            .unwrap()
            .to_string_lossy()
            .contains(" (Recovered "));
        assert_eq!(std::fs::metadata(&actual).unwrap().len(), 0);
        fixture.assert_original(&original);
        let planned = fixture.receipt();
        assert!(planned.recovery.as_ref().unwrap().owned);
        assert_eq!(receipt_output(&fixture.output, &planned).unwrap(), actual);
        // Reloading the durable receipt reproduces the route without any
        // in-memory publication state or a new filename allocation.
        let reloaded: Receipt = serde_json::from_slice(&fixture.receipt_bytes()).unwrap();
        assert_eq!(receipt_output(&fixture.output, &reloaded).unwrap(), actual);
        let published = finish_resolved(
            &fixture.partial,
            &fixture.output,
            fixture.source.clone(),
            "generated-finish",
        )
        .await
        .unwrap();
        assert_eq!(published, actual);
        assert_eq!(std::fs::read(&actual).unwrap(), b"abcdefgh");
        assert_eq!(
            fixture.receipt().sha256,
            hex::encode(ring::digest::digest(&ring::digest::SHA256, b"abcdefgh"))
        );
        assert!(fixture.receipt().committed);
        assert!(fixture.receipt().copy.is_none());
        assert!(!fixture.partial.exists());
        assert!(!publication_pointer_path(&fixture.partial).exists());
        assert_eq!(
            ensure_available_path_async_with_control(
                &fixture.output,
                &fixture.source,
                "generated-restarted-skip",
            )
            .await
            .unwrap(),
            Some(actual)
        );
        fixture.assert_original(&original);
    }
}

#[tokio::test]
async fn owned_recovery_resumes_durable_bytes_and_rotates_a_replaced_candidate_without_overwriting()
{
    let fixture = Fixture::new(true, true).await;
    let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    let first = fixture.recover("generated-reserve").unwrap();
    fixture
        .interrupt_recovery(CopyFault::AfterBytes(3))
        .await
        .unwrap_err();
    assert_eq!(fixture.receipt().copy.as_ref().unwrap().durable_bytes, 3);
    assert_eq!(fixture.recover("generated-restart").unwrap(), first);
    assert_eq!(std::fs::read(&first).unwrap(), b"abc");
    let replacement = fixture.output.with_file_name("generated replacement.bin");
    std::fs::write(&replacement, b"reserved").unwrap();
    std::fs::rename(&replacement, &first).unwrap();
    let second = fixture.recover("generated-new-route").unwrap();
    assert_ne!(first, second);
    assert_eq!(std::fs::read(&first).unwrap(), b"reserved");
    assert_eq!(
        finish_resolved(
            &fixture.partial,
            &fixture.output,
            fixture.source.clone(),
            "generated-finish"
        )
        .await
        .unwrap(),
        second
    );
    assert_eq!(std::fs::read(&second).unwrap(), b"abcdefgh");
    assert_eq!(std::fs::read(&first).unwrap(), b"reserved");
    fixture.assert_original(&original);
}

#[tokio::test]
async fn source_verified_nonzero_prefix_conflict_recovers_without_changing_the_conflicting_file() {
    let fixture = Fixture::new(false, true).await;
    std::fs::write(&fixture.output, b"xyz").unwrap();
    let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    let mut receipt = fixture.receipt();
    receipt.copy.as_mut().unwrap().output = original.clone();
    save(&fixture.receipt_path(), &receipt).unwrap();
    let actual = fixture.recover("generated-prefix-conflict").unwrap();
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"xyz");
    assert_eq!(
        finish_resolved(
            &fixture.partial,
            &fixture.output,
            fixture.source.clone(),
            "generated-finish"
        )
        .await
        .unwrap(),
        actual
    );
    assert_eq!(std::fs::read(&actual).unwrap(), b"abcdefgh");
    assert_eq!(std::fs::read(&fixture.output).unwrap(), b"xyz");
    assert_eq!(
        Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap(),
        original
    );
}

#[tokio::test]
async fn selected_original_can_disappear_after_route_reservation_without_losing_actual_output_path()
{
    let fixture = Fixture::new(true, true).await;
    let actual = fixture.recover("generated-reserve").unwrap();
    std::fs::remove_file(&fixture.output).unwrap();
    assert_eq!(
        finish_resolved(
            &fixture.partial,
            &fixture.output,
            fixture.source.clone(),
            "generated-finish"
        )
        .await
        .unwrap(),
        actual
    );
    assert_eq!(std::fs::read(&actual).unwrap(), b"abcdefgh");
    assert_eq!(
        ensure_available_path_async_with_control(
            &fixture.output,
            &fixture.source,
            "generated-restarted-skip"
        )
        .await
        .unwrap(),
        Some(actual)
    );
    assert!(!fixture.output.exists());
}

#[tokio::test]
async fn pending_source_verified_recovery_preserves_symlink_and_directory_conflicts() {
    for symlink in [false, true] {
        let fixture = Fixture::new(true, true).await;
        std::fs::remove_file(&fixture.output).unwrap();
        let protected = fixture
            .output
            .with_file_name("generated reserved target.bin");
        if symlink {
            std::fs::write(&protected, b"reserved").unwrap();
            std::os::unix::fs::symlink(&protected, &fixture.output).unwrap();
        } else {
            std::fs::create_dir(&fixture.output).unwrap();
            std::fs::write(
                fixture.output.join("generated reserved child.bin"),
                b"reserved",
            )
            .unwrap();
        }
        assert!(!completed_with_control(
            &fixture.output,
            &fixture.source,
            "generated-structural-conflict"
        )
        .unwrap());
        let actual = fixture.recover("generated-structural-conflict").unwrap();
        assert_eq!(
            finish_resolved(
                &fixture.partial,
                &fixture.output,
                fixture.source.clone(),
                "generated-finish"
            )
            .await
            .unwrap(),
            actual
        );
        assert_eq!(std::fs::read(&actual).unwrap(), b"abcdefgh");
        let metadata = std::fs::symlink_metadata(&fixture.output).unwrap();
        assert_eq!(metadata.file_type().is_symlink(), symlink);
        if symlink {
            assert_eq!(std::fs::read(&protected).unwrap(), b"reserved");
        } else {
            assert!(metadata.is_dir());
            assert_eq!(
                std::fs::read(fixture.output.join("generated reserved child.bin")).unwrap(),
                b"reserved"
            );
        }
    }
}

#[tokio::test]
async fn unowned_crash_intent_preserves_file_and_symlink_collisions_and_chooses_an_exclusive_name()
{
    for symlink in [false, true] {
        let fixture = Fixture::new(true, true).await;
        let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
        let candidate = fixture
            .output
            .with_file_name(recovery_name(&fixture.output).unwrap());
        let external = fixture.output.with_file_name("generated reserved.bin");
        if symlink {
            std::fs::write(&external, b"reserved").unwrap();
            std::os::unix::fs::symlink(&external, &candidate).unwrap();
        } else {
            std::fs::write(&candidate, b"reserved").unwrap();
        }
        let mut receipt = fixture.receipt();
        receipt.recovery = Some(RecoveryPublication {
            output_name: candidate.file_name().unwrap().into(),
            owned: false,
        });
        save(&fixture.receipt_path(), &receipt).unwrap();
        let actual = fixture.recover("generated-restart-intent").unwrap();
        assert_ne!(actual, candidate);
        assert_eq!(std::fs::read(&candidate).unwrap(), b"reserved");
        assert_eq!(
            std::fs::symlink_metadata(&candidate)
                .unwrap()
                .file_type()
                .is_symlink(),
            symlink
        );
        assert!(fixture.receipt().recovery.unwrap().owned);
        assert_eq!(
            finish_resolved(
                &fixture.partial,
                &fixture.output,
                fixture.source.clone(),
                "generated-finish"
            )
            .await
            .unwrap(),
            actual
        );
        assert_eq!(std::fs::read(&actual).unwrap(), b"abcdefgh");
        assert_eq!(std::fs::read(&candidate).unwrap(), b"reserved");
        fixture.assert_original(&original);
    }
}

#[tokio::test]
async fn unowned_intent_never_adopts_a_complete_matching_collision() {
    let fixture = Fixture::new(true, true).await;
    let candidate = fixture
        .output
        .with_file_name(recovery_name(&fixture.output).unwrap());
    std::fs::write(&candidate, b"abcdefgh").unwrap();
    let mut receipt = fixture.receipt();
    receipt.recovery = Some(RecoveryPublication {
        output_name: candidate.file_name().unwrap().into(),
        owned: false,
    });
    save(&fixture.receipt_path(), &receipt).unwrap();
    assert!(!completed_with_control(
        &fixture.output,
        &fixture.source,
        "generated-unowned-complete"
    )
    .unwrap());
    let actual = fixture.recover("generated-unowned-complete").unwrap();
    assert_ne!(candidate, actual);
    assert_eq!(std::fs::read(&candidate).unwrap(), b"abcdefgh");
    assert_eq!(std::fs::metadata(&actual).unwrap().len(), 0);
}

#[tokio::test]
async fn invalid_recovery_routes_never_mutate_original_staging_or_journal() {
    for name in [
        "../escape (Recovered bad).bin",
        "/tmp/escape (Recovered bad).bin",
        ".",
        "plain.bin",
        "",
    ] {
        let fixture = Fixture::new(true, true).await;
        let mut receipt = fixture.receipt();
        receipt.recovery = Some(RecoveryPublication {
            output_name: name.into(),
            owned: false,
        });
        save(&fixture.receipt_path(), &receipt).unwrap();
        let journal = fixture.receipt_bytes();
        let pointer = fixture.pointer_bytes();
        assert!(
            fixture.recover("generated-invalid-route").is_err(),
            "accepted {name}"
        );
        assert_eq!(fixture.receipt_bytes(), journal);
        assert_eq!(fixture.pointer_bytes(), pointer);
        assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    }
}

#[tokio::test]
async fn recovery_requires_matching_source_revision_pointer_and_stable_complete_staging() {
    for mutation in [
        "receipt-source",
        "receipt-version",
        "receipt-size",
        "copy-staging-route",
        "pointer-source",
        "pointer-version",
        "pointer-hash",
        "pointer-inode",
        "pointer-size",
        "stage-bytes",
        "stage-resize",
        "stage-replacement",
        "unknown-revision",
        "not-exfat",
    ] {
        let fixture = Fixture::new(true, mutation != "unknown-revision").await;
        match mutation {
            "receipt-source" => {
                let mut receipt = fixture.receipt();
                receipt.source.scope = "account:foreign-generated".into();
                // Deliberately bypass save's source-change rejection to model
                // damaged disk metadata, rather than app-owned journal writes.
                std::fs::write(
                    fixture.receipt_path(),
                    serde_json::to_vec(&receipt).unwrap(),
                )
                .unwrap();
            }
            "receipt-version" | "receipt-size" | "copy-staging-route" => {
                let mut receipt = fixture.receipt();
                match mutation {
                    "receipt-version" => receipt.version += 1,
                    "receipt-size" => receipt.local.size += 1,
                    "copy-staging-route" => {
                        receipt.copy.as_mut().unwrap().partial_name =
                            "../generated elsewhere.part".into()
                    }
                    _ => unreachable!(),
                }
                std::fs::write(
                    fixture.receipt_path(),
                    serde_json::to_vec(&receipt).unwrap(),
                )
                .unwrap();
            }
            "pointer-source" | "pointer-version" | "pointer-hash" | "pointer-inode"
            | "pointer-size" => {
                let mut pointer = load_publication_pointer(&fixture.partial).unwrap().unwrap();
                match mutation {
                    "pointer-source" => pointer.source.scope = "account:foreign-generated".into(),
                    "pointer-version" => pointer.version += 1,
                    "pointer-hash" => pointer.sha256 = "00".repeat(32),
                    "pointer-inode" => pointer.original.inode ^= 1,
                    "pointer-size" => pointer.original.size += 1,
                    _ => unreachable!(),
                }
                std::fs::write(
                    publication_pointer_path(&fixture.partial),
                    serde_json::to_vec(&pointer).unwrap(),
                )
                .unwrap();
            }
            "stage-bytes" => std::fs::write(&fixture.partial, b"changed!").unwrap(),
            "stage-resize" => std::fs::write(&fixture.partial, b"changed").unwrap(),
            "stage-replacement" => {
                let replacement = fixture
                    .output
                    .with_file_name("generated stage replacement.bin");
                std::fs::write(&replacement, b"abcdefgh").unwrap();
                std::fs::rename(&replacement, &fixture.partial).unwrap();
            }
            "unknown-revision" | "not-exfat" => {}
            _ => unreachable!(),
        }
        let stage = std::fs::read(&fixture.partial).unwrap();
        let journal = fixture.receipt_bytes();
        let pointer = fixture.pointer_bytes();
        let result = pending_copy_available_with_recovery(
            &fixture.output,
            &fixture.source,
            "generated-refuse-recovery",
            &|_| Ok(mutation != "not-exfat"),
            true,
        );
        assert!(!matches!(result, Ok(true)), "accepted {mutation}");
        assert_eq!(std::fs::read(&fixture.output).unwrap(), b"abc");
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), stage);
        assert_eq!(fixture.receipt_bytes(), journal);
        assert_eq!(fixture.pointer_bytes(), pointer);
        assert!(fixture.receipt().recovery.is_none());
    }
}

#[tokio::test]
async fn cancel_recovered_partial_or_full_owned_copy_preserves_original_and_retains_stage_for_caller(
) {
    for fault in [CopyFault::AfterBytes(3), CopyFault::AfterCopyBeforeCommit] {
        let fixture = Fixture::new(true, true).await;
        let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
        let actual = fixture.recover("generated-reserve").unwrap();
        fixture.interrupt_recovery(fault).await.unwrap_err();
        cancel_pending_publication(
            &fixture.partial,
            &fixture.source.file_id,
            "generated-cancel",
        )
        .unwrap();
        assert!(!actual.exists());
        assert!(!fixture.receipt_path().exists());
        assert!(!publication_pointer_path(&fixture.partial).exists());
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
        fixture.assert_original(&original);
    }
}

#[tokio::test]
async fn recovered_complete_copy_reconciles_lost_commit_and_staging_cleanup_on_restart() {
    for committed in [false, true] {
        let fixture = Fixture::new(true, true).await;
        let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
        let actual = fixture.recover("generated-reserve").unwrap();
        fixture
            .interrupt_recovery(CopyFault::AfterCopyBeforeCommit)
            .await
            .unwrap_err();
        if committed {
            let mut receipt = fixture.receipt();
            receipt.local = Identity::read(&std::fs::metadata(&actual).unwrap()).unwrap();
            receipt.committed = true;
            receipt.copy = None;
            save(&fixture.receipt_path(), &receipt).unwrap();
        }
        assert_eq!(
            ensure_available_path_async_with_control(
                &fixture.output,
                &fixture.source,
                "generated-restarted-complete"
            )
            .await
            .unwrap(),
            Some(actual.clone())
        );
        assert_eq!(std::fs::read(&actual).unwrap(), b"abcdefgh");
        assert!(fixture.receipt().committed);
        assert!(fixture.receipt().copy.is_none());
        assert!(!fixture.partial.exists());
        assert!(!publication_pointer_path(&fixture.partial).exists());
        fixture.assert_original(&original);
    }
}

#[tokio::test]
async fn cancel_never_removes_a_committed_recovered_output_after_interrupted_staging_cleanup() {
    let fixture = Fixture::new(true, true).await;
    let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    let actual = fixture.recover("generated-reserve").unwrap();
    fixture
        .interrupt_recovery(CopyFault::AfterCopyBeforeCommit)
        .await
        .unwrap_err();
    let mut receipt = fixture.receipt();
    receipt.local = Identity::read(&std::fs::metadata(&actual).unwrap()).unwrap();
    receipt.committed = true;
    receipt.copy = None;
    save(&fixture.receipt_path(), &receipt).unwrap();
    let journal = fixture.receipt_bytes();
    cancel_pending_publication(
        &fixture.partial,
        &fixture.source.file_id,
        "generated-cancel",
    )
    .unwrap();
    assert_eq!(std::fs::read(&actual).unwrap(), b"abcdefgh");
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    assert_eq!(fixture.receipt_bytes(), journal);
    assert!(!publication_pointer_path(&fixture.partial).exists());
    fixture.assert_original(&original);
}

#[tokio::test]
async fn cancellation_of_unowned_intent_preserves_collision_and_rejects_changed_staging() {
    for changed in [false, true] {
        let fixture = Fixture::new(true, true).await;
        let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
        let candidate = fixture
            .output
            .with_file_name(recovery_name(&fixture.output).unwrap());
        std::fs::write(&candidate, b"reserved").unwrap();
        let mut receipt = fixture.receipt();
        receipt.recovery = Some(RecoveryPublication {
            output_name: candidate.file_name().unwrap().into(),
            owned: false,
        });
        save(&fixture.receipt_path(), &receipt).unwrap();
        if changed {
            std::fs::write(&fixture.partial, b"changed!").unwrap();
        }
        let journal = fixture.receipt_bytes();
        let pointer = fixture.pointer_bytes();
        let result = cancel_pending_publication(
            &fixture.partial,
            &fixture.source.file_id,
            "generated-cancel",
        );
        if changed {
            assert!(result.is_err());
            assert_eq!(fixture.receipt_bytes(), journal);
            assert_eq!(fixture.pointer_bytes(), pointer);
        } else {
            result.unwrap();
            assert!(!fixture.receipt_path().exists());
            assert!(!publication_pointer_path(&fixture.partial).exists());
        }
        assert_eq!(std::fs::read(&candidate).unwrap(), b"reserved");
        assert_eq!(
            std::fs::read(&fixture.partial).unwrap(),
            if changed {
                &b"changed!"[..]
            } else {
                &b"abcdefgh"[..]
            }
        );
        fixture.assert_original(&original);
    }
}

#[tokio::test]
async fn cancellation_rejects_changed_or_replaced_owned_recovery_copy_and_keeps_all_proofs() {
    for replacement in [false, true] {
        let fixture = Fixture::new(true, true).await;
        let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
        let actual = fixture.recover("generated-reserve").unwrap();
        fixture
            .interrupt_recovery(CopyFault::AfterBytes(3))
            .await
            .unwrap_err();
        if replacement {
            let changed = fixture
                .output
                .with_file_name("generated changed recovery.bin");
            std::fs::write(&changed, b"xyz").unwrap();
            std::fs::rename(&changed, &actual).unwrap();
        } else {
            std::fs::write(&actual, b"xyz").unwrap();
        }
        let journal = fixture.receipt_bytes();
        let pointer = fixture.pointer_bytes();
        assert!(cancel_pending_publication(
            &fixture.partial,
            &fixture.source.file_id,
            "generated-cancel"
        )
        .is_err());
        assert_eq!(std::fs::read(&actual).unwrap(), b"xyz");
        assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
        assert_eq!(fixture.receipt_bytes(), journal);
        assert_eq!(fixture.pointer_bytes(), pointer);
        fixture.assert_original(&original);
    }
}

#[test]
fn recovered_publication_controls_are_isolated_in_child_process() {
    let result = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "download_receipt::recovery_tests::recovered_publication_controls_child",
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
#[ignore = "isolated publication controls environment"]
async fn recovered_publication_controls_child() {
    let controls_directory = tempfile::tempdir().unwrap();
    let controls = controls_directory.path().join("controls.json");
    std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &controls);
    std::env::set_var(
        "MYCLOUDDRIVER_TRANSFER_LOCKS",
        controls_directory.path().join("locks"),
    );
    std::env::remove_var("MYCLOUDDRIVER_TRANSFER_OWNER");
    std::fs::write(&controls, br#"{"actions":{}}"#).unwrap();
    let fixture = Fixture::new(true, true).await;
    let original = Identity::read(&std::fs::metadata(&fixture.output).unwrap()).unwrap();
    let set_action = |action: Option<&str>| {
        let actions = action
            .map(|value| serde_json::json!({"controlled-publication": value}))
            .unwrap_or_else(|| serde_json::json!({}));
        std::fs::write(
            &controls,
            serde_json::json!({"actions": actions}).to_string(),
        )
        .unwrap();
    };
    let journal = fixture.receipt_bytes();
    set_action(Some("pause"));
    tokio::time::sleep(std::time::Duration::from_millis(110)).await;
    assert!(fixture
        .recover("controlled-publication")
        .unwrap_err()
        .is::<crate::transfer_control::Paused>());
    assert_eq!(fixture.receipt_bytes(), journal);
    fixture.assert_original(&original);
    set_action(None);
    tokio::time::sleep(std::time::Duration::from_millis(110)).await;
    let actual = fixture.recover("controlled-publication").unwrap();
    fixture
        .interrupt_recovery(CopyFault::AfterBytes(3))
        .await
        .unwrap_err();
    let journal = fixture.receipt_bytes();
    set_action(Some("pause"));
    tokio::time::sleep(std::time::Duration::from_millis(110)).await;
    assert!(finish_resolved(
        &fixture.partial,
        &fixture.output,
        fixture.source.clone(),
        "controlled-publication"
    )
    .await
    .unwrap_err()
    .is::<crate::transfer_control::Paused>());
    assert_eq!(fixture.receipt_bytes(), journal);
    assert_eq!(std::fs::read(&actual).unwrap(), b"abc");
    set_action(Some("cancel"));
    tokio::time::sleep(std::time::Duration::from_millis(110)).await;
    assert!(finish_resolved(
        &fixture.partial,
        &fixture.output,
        fixture.source.clone(),
        "controlled-publication"
    )
    .await
    .unwrap_err()
    .is::<crate::transfer_control::Cancelled>());
    cancel_pending_publication(
        &fixture.partial,
        &fixture.source.file_id,
        "controlled-publication",
    )
    .unwrap();
    assert!(!actual.exists());
    assert_eq!(std::fs::read(&fixture.partial).unwrap(), b"abcdefgh");
    fixture.assert_original(&original);
}

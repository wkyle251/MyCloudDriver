//! Generated files only. Check publication and recovery ordering at failures,
//! rather than claiming that an in-process test simulates a real power cut.
use super::*;

fn writes(root: &Path, count: usize) -> Vec<CheckpointWrite> {
    (0..count)
        .map(|index| {
            let data_path = root.join(format!("generated-{index}.data"));
            let journal_path = root.join(format!("generated-{index}.journal"));
            let mut data = std::fs::OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .open(&data_path)
                .unwrap();
            data.write_all(&vec![index as u8; 4096]).unwrap();
            std::fs::write(&journal_path, b"old-durable-boundary").unwrap();
            CheckpointWrite {
                metadata: data.metadata().unwrap(),
                data,
                data_path,
                journal_path,
                journal: b"new-durable-boundary".to_vec(),
            }
        })
        .collect()
}

#[test]
fn many_journals_share_two_cache_barriers_with_data_before_publication() {
    let root = tempfile::tempdir().unwrap();
    let writes = writes(root.path(), 64);
    let mut phases = Vec::new();
    let mut barriers = 0;
    checkpoint_batch_using(&writes, |phase, file| {
        phases.push(phase);
        if phase == CheckpointSync::Barrier {
            barriers += 1;
            for write in &writes {
                assert_eq!(
                    std::fs::read(&write.journal_path).unwrap(),
                    if barriers == 1 {
                        b"old-durable-boundary".as_slice()
                    } else {
                        b"new-durable-boundary".as_slice()
                    }
                );
            }
            file.sync_all()
        } else {
            fs::fsync(file).map_err(Into::into)
        }
    })
    .unwrap();
    assert_eq!(
        barriers, 2,
        "Do not flush the whole drive once per file or journal"
    );
    assert_eq!(
        phases
            .iter()
            .filter(|phase| **phase == CheckpointSync::Directory)
            .count(),
        1
    );
    assert!(phases[..64]
        .iter()
        .all(|phase| *phase == CheckpointSync::Data));
    assert_eq!(
        std::fs::read_dir(root.path()).unwrap().count(),
        128,
        "Temporary journals must be cleaned up"
    );
}

#[test]
fn a_failed_data_barrier_does_not_advance_any_checkpoint() {
    let root = tempfile::tempdir().unwrap();
    let writes = writes(root.path(), 8);
    let result = checkpoint_batch_using(&writes, |phase, _| {
        if phase == CheckpointSync::Barrier {
            Err(std::io::Error::other("generated data barrier failure"))
        } else {
            Ok(())
        }
    });
    assert!(result.is_err());
    for write in &writes {
        assert_eq!(
            std::fs::read(&write.journal_path).unwrap(),
            b"old-durable-boundary"
        );
    }
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 16);
}

#[test]
fn a_failed_commit_barrier_is_never_acknowledged_as_durable() {
    let root = tempfile::tempdir().unwrap();
    let writes = writes(root.path(), 4);
    let mut barriers = 0;
    let result = checkpoint_batch_using(&writes, |phase, _| {
        if phase == CheckpointSync::Barrier {
            barriers += 1;
            if barriers == 2 {
                return Err(std::io::Error::other("generated commit barrier failure"));
            }
        }
        Ok(())
    });
    assert!(result.is_err());
    // Some/all journal renames may survive an interrupted commit; each still
    // refers only to the data protected by the successful first barrier.
    for write in &writes {
        assert_eq!(std::fs::read(&write.data_path).unwrap().len(), 4096);
    }
}

#[test]
fn changed_payload_or_replaced_destination_cannot_acquire_a_new_journal() {
    for replace_root in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let selected = root.path().join("generated-selected");
        std::fs::create_dir(&selected).unwrap();
        selected_directory(&selected).unwrap();
        let writes = writes(&selected, 2);
        let moved = root.path().join("generated-moved");
        let result = checkpoint_batch_using(&writes, |phase, _| {
            if phase == CheckpointSync::Barrier {
                if replace_root {
                    std::fs::rename(&selected, &moved)?;
                    std::fs::create_dir(&selected)?;
                } else {
                    std::fs::OpenOptions::new()
                        .append(true)
                        .open(&writes[0].data_path)?
                        .write_all(b"changed")?;
                }
            }
            Ok(())
        });
        assert!(result.is_err());
        let old_root = if replace_root { &moved } else { &selected };
        assert_eq!(
            std::fs::read(old_root.join("generated-0.journal")).unwrap(),
            b"old-durable-boundary"
        );
    }
}

#[test]
fn a_symlink_journal_cannot_modify_an_unrelated_file() {
    let root = tempfile::tempdir().unwrap();
    let writes = writes(root.path(), 2);
    let unrelated = root.path().join("generated-unrelated");
    std::fs::write(&unrelated, b"keep").unwrap();
    std::fs::remove_file(&writes[1].journal_path).unwrap();
    std::os::unix::fs::symlink(&unrelated, &writes[1].journal_path).unwrap();
    assert!(checkpoint_batch(&writes).is_err());
    assert_eq!(std::fs::read(&unrelated).unwrap(), b"keep");
    assert_eq!(
        std::fs::read(&writes[0].journal_path).unwrap(),
        b"old-durable-boundary"
    );
}

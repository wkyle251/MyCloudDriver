//! A finished download restored from a backup, onto another disk or a reformatted one. The copy has a new
//! inode and new times, and its hidden receipt folder may not have been restored. Its bytes decide whether it
//! is the download. Generated files and newly created disk images only.
use super::*;
use pikpak::upload::{gcid_file, GcidHasher};
use std::sync::Arc;

const BYTES: &[u8] = b"restored-finished-download";

async fn gcid(path: &Path) -> String {
    let size = std::fs::metadata(path).unwrap().len();
    gcid_file(path, size, Arc::new(|_| {})).await.unwrap()
}

fn gcid_source(file_id: &str, revision: Option<String>, size: u64) -> Source {
    Source {
        scope: "account:restore".into(),
        file_id: file_id.into(),
        revision,
        size,
    }
}

/// Download `BYTES` to `directory/name` through the real publication route, leaving a committed receipt.
async fn finished(directory: &Path, name: &str, source: &Source) -> PathBuf {
    std::fs::create_dir_all(directory).unwrap();
    let output = directory.join(name);
    let partial = directory.join(format!("{name}.part"));
    std::fs::write(&partial, BYTES).unwrap();
    finish(&partial, &output, source.clone(), "restore-fixture")
        .await
        .unwrap();
    output
}

/// Copy the finished file, and optionally its hidden receipts, like a backup and restore: a new inode and new times.
fn restore(from: &Path, to: &Path, name: &str, with_receipts: bool) -> PathBuf {
    std::fs::create_dir_all(to).unwrap();
    std::fs::copy(from.join(name), to.join(name)).unwrap();
    if with_receipts {
        let receipts = to.join(".myclouddriver-downloads");
        std::fs::create_dir_all(&receipts).unwrap();
        for entry in std::fs::read_dir(from.join(".myclouddriver-downloads")).unwrap() {
            let entry = entry.unwrap();
            std::fs::copy(entry.path(), receipts.join(entry.file_name())).unwrap();
        }
    }
    to.join(name)
}

#[tokio::test]
async fn restored_copy_with_its_receipt_is_adopted_after_byte_verification() {
    let root = tempfile::tempdir().unwrap();
    let source = gcid_source("restore-a", Some("gcid:SYNTHETIC".into()), BYTES.len() as u64);
    let original = finished(&root.path().join("before"), "movie.mp4", &source).await;
    let restored = restore(&root.path().join("before"), &root.path().join("after"), "movie.mp4", true);
    change_times(&restored);
    let before = Identity::read(&std::fs::metadata(&original).unwrap()).unwrap();
    let after = Identity::read(&std::fs::metadata(&restored).unwrap()).unwrap();
    assert_ne!(before.inode, after.inode, "A copy is a new file");
    assert!(
        ensure_available(&restored, &source).unwrap(),
        "A restored copy whose bytes match its receipt must be recognized"
    );
    let receipt = load(&path(&restored, &source).unwrap()).unwrap().unwrap();
    assert!(receipt.committed && receipt.local == after, "The receipt follows the file");
    assert_eq!(std::fs::read(&restored).unwrap(), BYTES);
    assert!(ensure_available(&restored, &source).unwrap(), "Then it is the cheap path");
}

#[tokio::test]
async fn restored_copy_with_edited_bytes_is_preserved_and_refused() {
    let root = tempfile::tempdir().unwrap();
    let source = gcid_source("restore-b", Some("gcid:SYNTHETIC".into()), BYTES.len() as u64);
    finished(&root.path().join("before"), "movie.mp4", &source).await;
    let restored = restore(&root.path().join("before"), &root.path().join("after"), "movie.mp4", true);
    let mut edited = BYTES.to_vec();
    edited[3] ^= 0xFF;
    std::fs::write(&restored, &edited).unwrap();
    let receipt_before = std::fs::read(path(&restored, &source).unwrap()).unwrap();
    assert!(ensure_available(&restored, &source).is_err(), "Different bytes are not the download");
    assert_eq!(std::fs::read(&restored).unwrap(), edited);
    assert_eq!(std::fs::read(path(&restored, &source).unwrap()).unwrap(), receipt_before);
}

#[tokio::test]
async fn restored_file_without_its_receipt_is_adopted_by_its_content_hash() {
    let root = tempfile::tempdir().unwrap();
    let plain = root.path().join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    std::fs::write(plain.join("movie.mp4"), BYTES).unwrap();
    let revision = format!("gcid:{}", gcid(&plain.join("movie.mp4")).await);
    let source = gcid_source("restore-c", Some(revision), BYTES.len() as u64);
    // Only the file was backed up: the hidden receipt folder did not come back.
    let restored = restore(&plain, &root.path().join("after"), "movie.mp4", false);
    assert!(load(&path(&restored, &source).unwrap()).unwrap().is_none());
    assert!(
        ensure_available(&restored, &source).unwrap(),
        "A file whose content hash is the cloud's hash is the original"
    );
    let receipt = load(&path(&restored, &source).unwrap()).unwrap().unwrap();
    assert!(receipt.committed && receipt.copy.is_none());
    assert_eq!(receipt.local, Identity::read(&std::fs::metadata(&restored).unwrap()).unwrap());
    assert_eq!(published_output(&restored, &source).unwrap(), restored);
    assert_eq!(std::fs::read(&restored).unwrap(), BYTES);
}

#[tokio::test]
async fn restored_file_without_a_receipt_needs_proof_that_it_is_the_original() {
    let root = tempfile::tempdir().unwrap();
    let plain = root.path().join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    std::fs::write(plain.join("movie.mp4"), BYTES).unwrap();
    let real = gcid(&plain.join("movie.mp4")).await;
    let restored = restore(&plain, &root.path().join("after"), "movie.mp4", false);
    let size = BYTES.len() as u64;
    let refused = [
        ("another content hash", gcid_source("a", Some("gcid:0123456789ABCDEF0123456789ABCDEF01234567".into()), size)),
        ("a time-based revision has no content hash", gcid_source("b", Some("modified:2026-01-01".into()), size)),
        ("an unknown revision", gcid_source("c", None, size)),
        ("a different size", gcid_source("d", Some(format!("gcid:{real}")), size + 1)),
        ("an unknown size", gcid_source("e", Some(format!("gcid:{real}")), 0)),
    ];
    for (reason, source) in refused {
        assert!(ensure_available(&restored, &source).is_err(), "Accepted despite {reason}");
        assert_eq!(std::fs::read(&restored).unwrap(), BYTES, "The file must stay as it was ({reason})");
        assert!(load(&path(&restored, &source).unwrap()).unwrap().is_none(), "No receipt for {reason}");
    }
}

/// A copy made by a tool that does not keep modification times: another time, the same bytes.
fn change_times(restored: &Path) {
    let modified = std::fs::metadata(restored).unwrap().modified().unwrap();
    std::fs::File::options()
        .write(true)
        .open(restored)
        .unwrap()
        .set_times(std::fs::FileTimes::new().set_modified(modified + std::time::Duration::from_secs(5)))
        .unwrap();
}

/// Gives `restored` the modification time of `original`, as Finder, `cp -p` and rsync do when they copy.
fn keep_times(original: &Path, restored: &Path) {
    let modified = std::fs::metadata(original).unwrap().modified().unwrap();
    std::fs::File::options()
        .write(true)
        .open(restored)
        .unwrap()
        .set_times(std::fs::FileTimes::new().set_modified(modified))
        .unwrap();
}

#[tokio::test]
async fn receipted_copy_that_kept_its_times_is_vouched_for_without_reading_or_writing_it() {
    let root = tempfile::tempdir().unwrap();
    let source = gcid_source("restore-d", Some("gcid:SYNTHETIC".into()), BYTES.len() as u64);
    let original = finished(&root.path().join("before"), "movie.mp4", &source).await;
    let restored = restore(&root.path().join("before"), &root.path().join("after"), "movie.mp4", true);
    let receipt_path = path(&restored, &source).unwrap();
    let receipt_before = std::fs::read(&receipt_path).unwrap();
    // Same size and time but other bytes. Accepting it proves the check never read the data: that is the price
    // of skipping a finished library at the speed of a stat, and any normal edit changes the time and is caught.
    let mut changed = BYTES.to_vec();
    changed[0] ^= 0xFF;
    std::fs::write(&restored, &changed).unwrap();
    keep_times(&original, &restored);
    assert!(
        completed_from_metadata(&restored, &source, "restore-metadata").unwrap(),
        "Same size and time are vouched for by the receipt"
    );
    assert!(ensure_available(&restored, &source).unwrap(), "The full route takes the same shortcut");
    assert_eq!(
        completed_without_reading(&restored, &source, "restore-metadata").await.unwrap(),
        Some(restored.clone())
    );
    assert_eq!(
        std::fs::read(&receipt_path).unwrap(),
        receipt_before,
        "Nothing is written to the destination disk to skip a finished file"
    );
    assert_eq!(std::fs::read(&restored).unwrap(), changed, "The file itself is never touched");
}

#[tokio::test]
async fn metadata_never_vouches_for_another_time_size_or_a_missing_receipt() {
    let root = tempfile::tempdir().unwrap();
    let source = gcid_source("restore-e", Some("gcid:SYNTHETIC".into()), BYTES.len() as u64);
    let original = finished(&root.path().join("before"), "movie.mp4", &source).await;

    // A copy that did not keep its time: the bytes must decide, so metadata alone does not vouch for it.
    let copied = restore(&root.path().join("before"), &root.path().join("copied"), "movie.mp4", true);
    change_times(&copied);
    assert!(!completed_from_metadata(&copied, &source, "").unwrap());
    assert!(completed_without_reading(&copied, &source, "").await.unwrap().is_none());

    // Its time and receipt are right but another size: never the same file.
    let longer = restore(&root.path().join("before"), &root.path().join("longer"), "movie.mp4", true);
    keep_times(&original, &longer);
    let mut bytes = std::fs::read(&longer).unwrap();
    bytes.push(0);
    std::fs::write(&longer, &bytes).unwrap();
    keep_times(&original, &longer);
    assert!(!completed_from_metadata(&longer, &source, "").unwrap());

    // The right size and time but no receipt: only a content hash could vouch for it.
    let bare = restore(&root.path().join("before"), &root.path().join("bare"), "movie.mp4", false);
    keep_times(&original, &bare);
    assert!(!completed_from_metadata(&bare, &source, "").unwrap());

    // A receipt for another source never vouches for this file.
    let other = gcid_source("another-file", Some("gcid:SYNTHETIC".into()), BYTES.len() as u64);
    let same = restore(&root.path().join("before"), &root.path().join("same"), "movie.mp4", true);
    keep_times(&original, &same);
    assert!(!completed_from_metadata(&same, &other, "").unwrap());
    assert!(completed_from_metadata(&same, &source, "").unwrap());
}

#[tokio::test]
async fn gcid_hasher_agrees_with_gcid_file_across_block_sizes() {
    let root = tempfile::tempdir().unwrap();
    // Around one block, several, and past the first block-size doubling at 128 MiB.
    for size in [1usize, 262_143, 262_144, 262_145, 3 * 262_144 + 7, 130 << 20] {
        let file = root.path().join(format!("size-{size}"));
        let data: Vec<u8> = (0..size).map(|index| (index * 31 + index / 7) as u8).collect();
        std::fs::write(&file, &data).unwrap();
        let mut hasher = GcidHasher::new(size as u64);
        for piece in data.chunks(100_003) {
            hasher.update(piece);
        }
        assert_eq!(hasher.finish(), gcid(&file).await, "size {size}");
    }
}

/// The reported case: a finished download on an ExFAT disk, backed up, the disk reformatted as APFS, restored.
#[cfg(target_os = "macos")]
#[tokio::test]
async fn finished_download_survives_exfat_backup_and_apfs_restore() {
    use super::disk_fixture::TestDisk;
    for with_receipts in [true, false] {
        let root = tempfile::tempdir().unwrap();
        let exfat = TestDisk::new(root.path(), "exfat", "ExFAT", 64);
        let folder = exfat.mount.join("Videos");
        std::fs::create_dir_all(&folder).unwrap();
        let reference = root.path().join("reference.bin");
        std::fs::write(&reference, BYTES).unwrap();
        let revision = format!("gcid:{}", gcid(&reference).await);
        let source = gcid_source("exfat-restore", Some(revision), BYTES.len() as u64);
        finished(&folder, "movie.mp4", &source).await;
        let backup = root.path().join("Backup");
        restore(&folder, &backup, "movie.mp4", true);
        if !with_receipts {
            std::fs::remove_dir_all(backup.join(".myclouddriver-downloads")).unwrap();
        }
        drop(exfat);
        let apfs = TestDisk::new(root.path(), "apfs", "APFS", 64);
        let restored_folder = apfs.mount.join("Videos");
        let restored = restore(&backup, &restored_folder, "movie.mp4", with_receipts);
        assert!(
            ensure_available(&restored, &source).unwrap(),
            "A finished download restored onto APFS must be recognized (receipts restored: {with_receipts})"
        );
        assert_eq!(published_output(&restored, &source).unwrap(), restored);
        assert_eq!(std::fs::read(&restored).unwrap(), BYTES);
    }
}

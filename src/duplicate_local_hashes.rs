//! Completed download receipt GCIDs are trusted first, assuming unmodified
//! downloads. Files without one use the private local hash cache. Names are
//! hashed; every computed-cache hit checks the open file,
//! path, inode, size, modification time AND change time. On local APFS/HFS,
//! temporary mount device numbers may change; other filesystems also require
//! the device to match. Uncertain identities and cache errors take the full read.
use super::*;
use std::{collections::VecDeque, fs::File, os::unix::{ffi::OsStrExt, fs::PermissionsExt}, sync::OnceLock};
use rusqlite::{Connection, OptionalExtension};

pub(super) struct HashCache {
    db: Option<Mutex<Connection>>,
    receipts: Mutex<VecDeque<(PathBuf, Arc<OnceLock<crate::download_receipt::DuplicateGcidReceiptIndex>>)>>,
}

impl HashCache {
    pub fn open(directory: Option<&StdPath>) -> Self {
        let open = |directory: &StdPath| -> Result<Connection> {
            std::fs::create_dir_all(directory)?;
            anyhow::ensure!(!std::fs::symlink_metadata(directory)?.file_type().is_symlink(), "Cache directory is a symlink");
            std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
            let path = directory.join("local-content-v1.sqlite3");
            let file = OpenOptions::new().read(true).write(true).create(true).mode(0o600)
                .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32).open(&path)?;
            anyhow::ensure!(file.metadata()?.is_file(), "Cache is not a regular file");
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            let db = Connection::open(path)?;
            db.busy_timeout(Duration::from_millis(50))?;
            db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
                CREATE TABLE IF NOT EXISTS hashes (path TEXT PRIMARY KEY, identity TEXT NOT NULL, hashes TEXT NOT NULL) WITHOUT ROWID;")?;
            Ok(db)
        };
        Self { db: directory.and_then(|path| open(path).ok()).map(Mutex::new), receipts: Mutex::new(VecDeque::new()) }
    }

    fn key(path: &StdPath) -> String {
        hex::encode(ring::digest::digest(&ring::digest::SHA256, path.as_os_str().as_bytes()))
    }

    fn get(&self, path: &StdPath, identity: &LocalIdentity, md5: bool, local_filesystem: bool) -> Option<LocalHashes> {
        let db = self.db.as_ref()?.lock().ok()?;
        let (saved, hashes): (String, String) = db.query_row(
            "SELECT identity,hashes FROM hashes WHERE path=?1", [Self::key(path)],
            |row| Ok((row.get(0)?, row.get(1)?))).optional().ok()??;
        let mut saved: LocalIdentity = serde_json::from_str(&saved).ok()?;
        let hashes: LocalHashes = serde_json::from_str(&hashes).ok()?;
        // APFS/HFS preserve inode and full mtime/ctime across remounts. Their
        // st_dev value does not persist. Never relax the other identity fields
        // or apply this exception to a remote mount's metadata representation.
        if local_filesystem { saved.device = identity.device; }
        (saved == *identity && valid_digest(&hashes.gcid, 40)
            && (!md5 || hashes.md5.as_deref().is_some_and(|value| valid_digest(value, 32)))).then_some(hashes)
    }

    fn put(&self, path: &StdPath, identity: &LocalIdentity, hashes: &LocalHashes) {
        if let Some(db) = self.db.as_ref().and_then(|db| db.lock().ok()) {
            if let (Ok(identity), Ok(hashes)) = (serde_json::to_string(identity), serde_json::to_string(hashes)) {
                let _ = db.execute("INSERT INTO hashes VALUES (?1,?2,?3)
                    ON CONFLICT(path) DO UPDATE SET identity=excluded.identity,hashes=excluded.hashes",
                    rusqlite::params![Self::key(path), identity, hashes]);
            }
        }
    }

    fn receipt(&self, path: &StdPath, file: &File) -> Option<LocalHashes> {
        let metadata = file.metadata().ok()?;
        if crate::download_buffer::memory_pressure() >= 2 {
            self.receipts.lock().ok()?.clear();
            // Stream the small receipt records instead of retaining an index.
            // Pressure must not turn an available GCID into a full content read.
            return crate::download_receipt::duplicate_gcid_from_receipts(path, &metadata)
                .map(|gcid| LocalHashes { gcid, md5: None });
        }
        let parent = path.parent()?;
        let mut indexes = self.receipts.lock().ok()?;
        let index = if let Some(position) = indexes.iter().position(|(folder, _)| folder == parent) {
            indexes.remove(position)?
        } else {
            (parent.to_owned(), Arc::new(OnceLock::new()))
        };
        let receipts = index.1.clone();
        indexes.push_back(index);
        // These are small JSON metadata indexes, not buffered file contents.
        // Bound their lifetime independently of the persistent content cache.
        while indexes.len() > 8 { indexes.pop_front(); }
        drop(indexes);
        // Read an index once per folder, without holding the global LRU lock
        // during filesystem I/O. Other folders can proceed independently.
        let receipts = receipts.get_or_init(|| crate::download_receipt::duplicate_gcid_receipts(parent));
        receipts.gcid_for(path, &metadata)
            .map(|gcid| LocalHashes { gcid, md5: None })
    }

    pub fn hash(&self, path: &StdPath, before: &mut LocalIdentity, md5: bool,
        progress: &mut dyn FnMut(u64), reader: &read_gate::Reader) -> Result<LocalHashes> {
        reader.wait()?;
        let file = OpenOptions::new().read(true).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32).open(path)?;
        let metadata = file.metadata()?;
        let current = LocalIdentity::of(&metadata);
        anyhow::ensure!(metadata.is_file() && current.device == before.device
            && current.inode == before.inode && current.size == before.size, "file changed before hashing");
        // Opening an SMB file can refresh attributes that discovery received
        // from the client's metadata cache. Adopt fresh timestamps for this
        // same object and size, then validate them for the entire hash/cache hit.
        *before = current;
        // The receipt is authoritative for duplicate checks even if the file's
        // old metadata, cache entry or MD5 requirement would otherwise cause a
        // read. Do not store this assumed digest as a freshly verified hash.
        if let Some(saved) = self.receipt(path, &file) {
            let after = std::fs::symlink_metadata(path)?;
            anyhow::ensure!(after.is_file() && !after.file_type().is_symlink()
                && LocalIdentity::of(&after) == *before && LocalIdentity::of(&file.metadata()?) == *before,
                "file changed while checking download receipt");
            progress(0);
            return Ok(saved);
        }
        // A coarse or missing change timestamp cannot prove that a same-size
        // edit with a restored modification time did not happen.
        let filesystem = filesystem(&file);
        let local_filesystem = filesystem.as_deref().is_some_and(|name| matches!(name, "apfs" | "hfs"));
        let supported = !cfg!(target_os = "macos")
            || filesystem.as_deref().is_some_and(|name| matches!(name, "apfs" | "hfs" | "smbfs"));
        let reusable = supported && before.changed_seconds > 0 && before.changed_nanoseconds > 0;
        if reusable {
            if let Some(saved) = self.get(path, before, md5, local_filesystem) {
                let after = std::fs::symlink_metadata(path)?;
                anyhow::ensure!(after.is_file() && !after.file_type().is_symlink()
                    && LocalIdentity::of(&after) == *before && LocalIdentity::of(&file.metadata()?) == *before,
                    "file changed while checking cached hash");
                progress(0); // Only real reads count as byte throughput.
                return Ok(saved);
            }
        }
        drop(file);
        let hashes = hash_local_controlled(path, before, md5, progress, || reader.wait())?;
        if reusable { self.put(path, before, &hashes); }
        Ok(hashes)
    }
}

fn valid_digest(value: &str, length: usize) -> bool {
    value.len() == length && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn filesystem(file: &File) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let fs = rustix::fs::fstatfs(file).ok()?;
        let name: Vec<_> = fs.f_fstypename.iter().copied().take_while(|byte| *byte != 0).map(|byte| byte as u8).collect();
        Some(String::from_utf8(name).ok()?)
    }
    #[cfg(not(target_os = "macos"))]
    { let _ = file; None }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt(path: &StdPath, gcid: &str, committed: bool) {
        use unicode_normalization::UnicodeNormalization;
        let metadata = std::fs::metadata(path).unwrap();
        let source: crate::download_receipt::Source = serde_json::from_value(serde_json::json!({
            "scope": "generated-account", "file_id": "generated-file", "revision": format!("gcid:{gcid}"), "size": 8,
        })).unwrap();
        let name = path.file_name().unwrap().to_string_lossy().nfd().collect::<String>().to_lowercase().nfd().collect::<String>();
        let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
        digest.update(name.as_bytes()); digest.update(&serde_json::to_vec(&source).unwrap());
        let directory = path.parent().unwrap().join(".myclouddriver-downloads");
        std::fs::create_dir_all(&directory).unwrap();
        // Every saved identity field intentionally differs from this mount.
        let value = serde_json::json!({ "version": 1, "source": source,
            "local": { "device": metadata.dev() ^ 1, "inode": metadata.ino() ^ 1, "size": metadata.len() + 1,
                "modified": 1, "changed": 1 }, "sha256": "00".repeat(32), "committed": committed });
        std::fs::write(directory.join(format!("{}.json", hex::encode(digest.finish()))), serde_json::to_vec(&value).unwrap()).unwrap();
    }

    fn hash(cache: &HashCache, path: &StdPath, md5: bool) -> (LocalHashes, u64) {
        let gate = Arc::new(read_gate::ReadGate::default()); gate.limit(1);
        let reader = gate.register();
        let mut identity = LocalIdentity::of(&std::fs::metadata(path).unwrap());
        let mut read = 0;
        let hashes = cache.hash(path, &mut identity, md5, &mut |bytes| read = bytes, &reader).unwrap();
        (hashes, read)
    }

    #[test]
    fn unchanged_files_reuse_verified_gcid_and_md5_is_added_only_when_needed() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("generated.bin"); std::fs::write(&path, b"abcdefgh").unwrap();
        let cache = HashCache::open(Some(&root.path().join("cache")));
        let (first, read) = hash(&cache, &path, false); assert_eq!(read, 8);
        let (second, read) = hash(&cache, &path, false); assert_eq!(read, 0);
        assert_eq!(first.gcid, second.gcid);
        let (with_md5, read) = hash(&cache, &path, true); assert_eq!(read, 8);
        assert!(with_md5.md5.is_some()); assert_eq!(with_md5.gcid, first.gcid);
        let (again, read) = hash(&cache, &path, true); assert_eq!(read, 0);
        assert_eq!(again.md5, with_md5.md5);
        drop(cache);
        let reopened = HashCache::open(Some(&root.path().join("cache")));
        assert_eq!(hash(&reopened, &path, true).1, 0, "cache survives app restart");
    }

    #[test]
    fn same_size_edits_with_restored_mtime_and_replaced_files_are_rehashed() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("generated.bin"); std::fs::write(&path, b"abcdefgh").unwrap();
        let cache = HashCache::open(Some(&root.path().join("cache")));
        let (first, _) = hash(&cache, &path, false);
        let mut discovery = LocalIdentity::of(&std::fs::metadata(&path).unwrap());
        let modified = std::fs::metadata(&path).unwrap().modified().unwrap();
        std::fs::write(&path, b"xxxxxxxx").unwrap();
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(modified).unwrap();
        let gate = Arc::new(read_gate::ReadGate::default()); gate.limit(1);
        let mut read = 0;
        let edited = cache.hash(&path, &mut discovery, false, &mut |bytes| read = bytes, &gate.register()).unwrap();
        assert_eq!(read, 8); assert_ne!(edited.gcid, first.gcid);
        assert_eq!(discovery, LocalIdentity::of(&std::fs::metadata(&path).unwrap()));
        let replacement = root.path().join("replacement.bin"); std::fs::write(&replacement, b"abcdefgh").unwrap();
        std::fs::rename(replacement, &path).unwrap();
        assert_eq!(hash(&cache, &path, false).1, 8);
        std::fs::remove_file(&path).unwrap(); std::os::unix::fs::symlink(root.path().join("cache"), &path).unwrap();
        let gate = Arc::new(read_gate::ReadGate::default()); gate.limit(1);
        assert!(cache.hash(&path, &mut LocalIdentity::of(&std::fs::metadata(&path).unwrap()), false, &mut |_| {}, &gate.register()).is_err());
    }

    #[test]
    fn corrupt_cache_is_optional_and_never_breaks_a_scan() {
        let root = tempfile::tempdir().unwrap(); let directory = root.path().join("cache");
        std::fs::create_dir(&directory).unwrap();
        std::fs::write(directory.join("local-content-v1.sqlite3"), b"not a database").unwrap();
        let path = root.path().join("generated.bin"); std::fs::write(&path, b"abcdefgh").unwrap();
        let cache = HashCache::open(Some(&directory));
        assert_eq!(hash(&cache, &path, false).1, 8);
    }

    #[test]
    fn local_cache_accepts_remount_only_with_exact_inode_size_and_timestamps() {
        let root = tempfile::tempdir().unwrap(); let path = root.path().join("generated.bin");
        std::fs::write(&path, b"abcdefgh").unwrap();
        let cache = HashCache::open(Some(&root.path().join("cache")));
        let (hashes, _) = hash(&cache, &path, false);
        let identity = LocalIdentity::of(&std::fs::metadata(&path).unwrap());
        let mut saved = identity.clone(); saved.device ^= 1;
        cache.put(&path, &saved, &hashes);
        assert!(cache.get(&path, &identity, false, false).is_none(), "remote mounts keep the device check");
        assert!(cache.get(&path, &identity, false, true).is_some());
        for field in 0..4 {
            let mut changed = saved.clone();
            match field {
                0 => changed.inode ^= 1,
                1 => changed.size += 1,
                2 => changed.modified_nanoseconds ^= 1,
                _ => changed.changed_nanoseconds ^= 1,
            }
            cache.put(&path, &changed, &hashes);
            assert!(cache.get(&path, &identity, false, true).is_none(), "changed field {field}");
        }
    }

    #[test]
    fn receipt_gcid_overrides_changed_metadata_cache_and_md5_without_reading_contents() {
        let root = tempfile::tempdir().unwrap(); let path = root.path().join("generated.bin");
        std::fs::write(&path, b"abcdefgh").unwrap();
        let cache = HashCache::open(Some(&root.path().join("cache")));
        let (original, read) = hash(&cache, &path, false); assert_eq!(read, 8);
        std::fs::write(&path, b"xxxxxxxx").unwrap();
        let (edited, read) = hash(&cache, &path, true); assert_eq!(read, 8);
        assert_ne!(edited.gcid, original.gcid);
        receipt(&path, &original.gcid, true);
        // Reopen so a previously cached empty folder index is not used.
        let cache = HashCache::open(Some(&root.path().join("cache")));
        let (trusted, read) = hash(&cache, &path, true);
        assert_eq!(read, 0); assert_eq!(trusted.gcid, original.gcid); assert!(trusted.md5.is_none());
        let identity = LocalIdentity::of(&std::fs::metadata(&path).unwrap());
        assert_eq!(cache.get(&path, &identity, false, true).unwrap().gcid, edited.gcid,
            "assumed receipt GCIDs must not overwrite verified cache entries");
        std::fs::write(&path, b"changed size").unwrap();
        let (trusted, read) = hash(&cache, &path, false);
        assert_eq!(read, 0); assert_eq!(trusted.gcid, original.gcid);
    }

    #[test]
    fn invalid_or_unfinished_receipts_fall_back_to_hashing() {
        let root = tempfile::tempdir().unwrap(); let path = root.path().join("generated.bin");
        std::fs::write(&path, b"abcdefgh").unwrap();
        receipt(&path, "invalid", true);
        assert_eq!(hash(&HashCache::open(None), &path, false).1, 8);
        std::fs::remove_dir_all(root.path().join(".myclouddriver-downloads")).unwrap();
        receipt(&path, &"AB".repeat(20), false);
        assert_eq!(hash(&HashCache::open(None), &path, false).1, 8);
    }
}

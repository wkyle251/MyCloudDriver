//! Account/drive-local source revisions, checked before fetching any original.
//! Each completed vector is journalled immediately, independently of scan lifetime.
use super::*;
use filetwin_core::{
    api::{FilePath, FileRecord, FileState},
    profile::{self, Backend},
};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    sync::{Mutex, OnceLock},
};

const FILENAME: &str = "filetwin-sources.sqlite3";
const MAX_RECORD_BYTES: u64 = 4 << 20;
/// Saved work nobody has used for this long is forgotten: re-analysing a file is only a cache miss.
const MAXIMUM_AGE: i64 = 90 * 24 * 60 * 60;
/// Reuse refreshes an entry's last-used time at most this often, so a scan of unchanged files writes almost nothing.
const TOUCH_AFTER: i64 = 24 * 60 * 60;
const PRUNE_EVERY: i64 = 24 * 60 * 60;
/// Total size of the saved vectors; the least recently used are dropped beyond it.
const MAXIMUM_VECTOR_BYTES: i64 = 4 << 30;

/// What one pruning pass removed.
#[derive(Debug, Default, PartialEq, Eq)]
struct Pruned {
    sources: usize,
    outcomes: usize,
    vectors: usize,
}

pub(super) struct SourceCache {
    db: Mutex<Connection>,
}

impl SourceCache {
    pub fn open(directory: &Path) -> Result<Self> {
        private_dir(directory)?;
        let path = directory.join(FILENAME);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&path)?;
        if !file.metadata()?.is_file() {
            bail!("The source cache must be a regular file.");
        }
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        let db = Connection::open(&path)?;
        db.busy_timeout(Duration::from_secs(2))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS vectors(digest TEXT, profile TEXT, payload BLOB NOT NULL,
                seen_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(digest,profile)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS sources(identity TEXT, revision TEXT, profile TEXT, digest TEXT NOT NULL,
                seen_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(identity,revision,profile)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS outcomes(identity TEXT, revision TEXT, reader TEXT, payload BLOB NOT NULL,
                seen_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(identity,revision,reader)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS imports(id TEXT PRIMARY KEY, stamp TEXT) WITHOUT ROWID;")?;
        db.execute_batch("CREATE TABLE IF NOT EXISTS content_aliases(gcid TEXT,size INTEGER,profile TEXT,digest TEXT NOT NULL,
            seen_at INTEGER NOT NULL,PRIMARY KEY(gcid,size,profile)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS content_aliases_digest ON content_aliases(digest,profile);
            CREATE INDEX IF NOT EXISTS sources_digest ON sources(digest,profile);")?;
        Self::date_existing_entries(&db)?;
        let cache = Self { db: Mutex::new(db) };
        cache.import_content_aliases()?;
        // Older versions saved the necessary identity in checkpoints, but the
        // aggregate vector file kept only content hashes. Import derived data
        // without reading originals or changing any existing scan.
        let _ = cache.import_checkpoints(directory);
        cache.prune_if_due();
        Ok(cache)
    }

    fn now(&self) -> i64 {
        Self::unix_now()
    }

    fn unix_now() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| i64::try_from(elapsed.as_secs()).unwrap_or(i64::MAX))
            .unwrap_or(0)
    }

    /// A cache from before entries had a last-used time gets one: today. Nothing it holds is old enough to prune yet.
    fn date_existing_entries(db: &Connection) -> Result<()> {
        let now = Self::unix_now();
        for table in ["vectors", "sources", "outcomes"] {
            let dated = db
                .prepare(&format!("PRAGMA table_info({table})"))?
                .query_map([], |row| row.get::<_, String>(1))?
                .filter_map(|name| name.ok())
                .any(|name| name == "seen_at");
            if !dated {
                db.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN seen_at INTEGER NOT NULL DEFAULT 0"))?;
                db.execute(&format!("UPDATE {table} SET seen_at=?1"), [now])?;
            }
        }
        Ok(())
    }

    fn last_pruned(&self) -> Option<i64> {
        self.db
            .lock()
            .unwrap()
            .query_row("SELECT value FROM meta WHERE key='last_pruned'", [], |row| row.get(0))
            .optional()
            .ok()
            .flatten()
    }

    /// Housekeeping at most once a day, when a scan opens the cache. It can only ever cost a later re-analysis.
    fn prune_if_due(&self) {
        let now = self.now();
        if self.last_pruned().is_some_and(|last| now - last < PRUNE_EVERY) {
            return;
        }
        self.prune_at(now);
    }

    fn prune_at(&self, now: i64) -> Pruned {
        self.prune_with_limit(now, MAXIMUM_VECTOR_BYTES)
    }

    /// Forgets saved work that has not been used for `MAXIMUM_AGE`, then the least recently used vectors until
    /// they fit in `limit` bytes, then any saved source whose vector is gone. A failure leaves the cache as it was.
    fn prune_with_limit(&self, now: i64, limit: i64) -> Pruned {
        let mut db = self.db.lock().unwrap();
        let run = |db: &mut Connection| -> Result<Pruned> {
            let tx = db.transaction()?;
            let cutoff = now - MAXIMUM_AGE;
            let mut pruned = Pruned {
                sources: tx.execute("DELETE FROM sources WHERE seen_at < ?1", [cutoff])?,
                outcomes: tx.execute("DELETE FROM outcomes WHERE seen_at < ?1", [cutoff])?,
                vectors: 0,
            };
            tx.execute("DELETE FROM content_aliases WHERE seen_at < ?1", [cutoff])?;
            // Content that no saved file points at stays until it is old, so a renamed or moved copy still reuses it.
            pruned.vectors += tx.execute(
                "DELETE FROM vectors WHERE seen_at < ?1 AND NOT EXISTS (
                    SELECT 1 FROM sources s WHERE s.digest = vectors.digest AND s.profile = vectors.profile)
                    AND NOT EXISTS (SELECT 1 FROM content_aliases a WHERE a.digest=vectors.digest AND a.profile=vectors.profile)",
                [cutoff],
            )?;
            let total: i64 = tx.query_row("SELECT coalesce(sum(length(payload)),0) FROM vectors", [], |row| row.get(0))?;
            let mut excess = total - limit;
            while excess > 0 {
                let oldest: Vec<(String, String, i64)> = tx
                    .prepare("SELECT digest, profile, length(payload) FROM vectors ORDER BY seen_at ASC LIMIT 512")?
                    .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
                    .collect::<std::result::Result<_, _>>()?;
                if oldest.is_empty() {
                    break;
                }
                for (digest, profile, bytes) in oldest {
                    if excess <= 0 {
                        break;
                    }
                    pruned.vectors += tx.execute("DELETE FROM vectors WHERE digest=?1 AND profile=?2", params![digest, profile])?;
                    excess -= bytes;
                }
            }
            pruned.sources += tx.execute(
                "DELETE FROM sources WHERE NOT EXISTS (
                    SELECT 1 FROM vectors v WHERE v.digest = sources.digest AND v.profile = sources.profile)",
                [],
            )?;
            tx.execute("DELETE FROM content_aliases WHERE NOT EXISTS (
                SELECT 1 FROM vectors v WHERE v.digest=content_aliases.digest AND v.profile=content_aliases.profile)", [])?;
            tx.execute("INSERT OR REPLACE INTO meta VALUES('last_pruned', ?1)", [now])?;
            tx.commit()?;
            Ok(pruned)
        };
        run(&mut db).unwrap_or_default()
    }

    pub fn reused(
        &self,
        file: &scope::InputFile,
        backend: Backend,
        families: &[String],
    ) -> Result<Option<FileRecord>> {
        let Some(revision) = file.checkpoint_revision() else {
            return Ok(None);
        };
        let identity = identity(file);
        let profiles = profile::experimental_profiles_for(backend);
        let now = self.now();
        let db = self.db.lock().unwrap();
        let mut query = db.prepare_cached(
            "SELECT v.digest,v.payload,s.seen_at,v.seen_at FROM sources s JOIN vectors v
            ON s.digest=v.digest AND s.profile=v.profile
            WHERE s.identity=?1 AND s.revision=?2 AND s.profile=?3 AND length(v.payload)<=4194304",
        )?;
        for p in profiles.iter().filter(|p| families.contains(&p.family)) {
            let saved: Option<(String, Vec<u8>, i64, i64)> = query
                .query_row(params![identity, revision, p.profile_id], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })
                .optional()?;
            let Some((digest, payload, seen_at, vector_seen)) = saved else {
                continue;
            };
            // Treat damaged/obsolete entries as cache misses, never as failures
            // or evidence that an original was successfully analysed.
            let Ok(mut record) = unpack(&payload) else {
                continue;
            };
            if record.profile_id.as_deref() != Some(&p.profile_id)
                || record.file_id.as_deref() != Some(&digest)
                || (!file.is_photos_preview()
                    && file.display.bytes > 0
                    && record.bytes != Some(file.display.bytes))
            {
                continue;
            }
            record.path = FilePath::Utf8(file.display.id.clone());
            record.reused = true;
            if let Some((gcid, size)) = cloud_content(file) {
                Self::remember_content_alias(&db, &gcid, size, &record, now)?;
            }
            if now - seen_at >= TOUCH_AFTER {
                db.execute("UPDATE sources SET seen_at=?4 WHERE identity=?1 AND revision=?2 AND profile=?3", params![identity, revision, p.profile_id, now])?;
            }
            if now - vector_seen >= TOUCH_AFTER {
                db.execute("UPDATE vectors SET seen_at=?3 WHERE digest=?1 AND profile=?2", params![digest,p.profile_id,now])?;
            }
            return Ok(Some(record));
        }
        // Different PikPak IDs may represent the same original. Only a real
        // GCID, exact byte size and the immutable analysis profile can prove
        // that reuse; timestamps and arbitrary provider revisions cannot.
        if let Some((gcid, size)) = cloud_content(file) {
            for p in profiles.iter().filter(|p| families.contains(&p.family)) {
                let saved: Option<(String, Vec<u8>, i64, i64)> = db.query_row(
                    "SELECT v.digest,v.payload,a.seen_at,v.seen_at FROM content_aliases a JOIN vectors v
                     ON a.digest=v.digest AND a.profile=v.profile WHERE a.gcid=?1 AND a.size=?2
                     AND a.profile=?3 AND length(v.payload)<=4194304",
                    params![gcid, size as i64, p.profile_id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)),
                ).optional()?;
                let Some((digest, payload, seen, vector_seen)) = saved else { continue; };
                let Ok(mut record) = unpack(&payload) else { continue; };
                if record.file_id.as_deref()!=Some(&digest) || record.profile_id.as_deref()!=Some(&p.profile_id)
                    || !alias_content_matches(&record,&gcid,size) { continue; }
                if seen <= now - TOUCH_AFTER {
                    db.execute("UPDATE content_aliases SET seen_at=?4 WHERE gcid=?1 AND size=?2 AND profile=?3", params![gcid,size as i64,p.profile_id,now])?;
                }
                if vector_seen <= now-TOUCH_AFTER {
                    db.execute("UPDATE vectors SET seen_at=?3 WHERE digest=?1 AND profile=?2 AND seen_at<=?4", params![digest,p.profile_id,now,now-TOUCH_AFTER])?;
                }
                record.path=FilePath::Utf8(file.display.id.clone()); record.reused=true;
                return Ok(Some(record));
            }
        }
        // Unknown binary/archive content has no vector, but its complete hash
        // and classification are final work too. Keep exact-copy evidence and
        // avoid downloading an unchanged original just to reject it again.
        for reader in [password::CACHE_KEY.to_owned(), reader_key(file)] {
            let saved: Option<(Vec<u8>, i64)> = db.query_row(
                "SELECT payload,seen_at FROM outcomes WHERE identity=?1 AND revision=?2 AND reader=?3 AND length(payload)<=4194304",
                params![identity, revision, reader], |row| Ok((row.get(0)?, row.get(1)?)),
            ).optional()?;
            let Some((payload, seen_at)) = saved else {
                continue;
            };
            if let Ok(mut record) = decompress(&payload)
                .and_then(|bytes| Ok(serde_json::from_slice::<FileRecord>(&bytes)?))
            {
                let valid = if reader == password::CACHE_KEY {
                    password::confirmed(&record)
                } else {
                    reusable_binary(&record)
                };
                if valid && (file.display.bytes == 0 || record.bytes == Some(file.display.bytes)) {
                    if reader == password::CACHE_KEY {
                        record = password::canonical(&record);
                    }
                    record.path = FilePath::Utf8(file.display.id.clone());
                    record.reused = true;
                    if now - seen_at >= TOUCH_AFTER {
                        db.execute("UPDATE outcomes SET seen_at=?4 WHERE identity=?1 AND revision=?2 AND reader=?3", params![identity, revision, reader, now])?;
                    }
                    return Ok(Some(record));
                }
            }
        }
        Ok(None)
    }

    pub fn completed(&self, file: &scope::InputFile, record: &FileRecord) -> Result<()> {
        let Some(revision) = file.checkpoint_revision() else {
            return Ok(());
        };
        if password::confirmed(record) {
            return self.remember_outcome(
                file,
                &revision,
                password::CACHE_KEY,
                password::canonical(record),
            );
        }
        if reusable_binary(record) {
            let mut saved = record.clone();
            saved.extraction = None;
            saved.error = Some(filetwin_core::Error::new(filetwin_core::ErrorCode::UnsupportedFormat,
                "encoding", "Binary or unsupported content has no similarity reader; exact-content hash retained"));
            return self.remember_outcome(file, &revision, &reader_key(file), saved);
        }
        self.remember(file, &revision, record)?;
        if let Some((gcid, size)) = cloud_content(file) {
            Self::remember_content_alias(&self.db.lock().unwrap(), &gcid, size, record, self.now())?;
        }
        Ok(())
    }

    fn remember_content_alias(db: &Connection, gcid: &str, size: u64, record: &FileRecord, now: i64) -> Result<()> {
        if size == 0 || size > i64::MAX as u64 || !alias_content_matches(record,gcid,size) || vector_cache::validate_record(record).is_err() {
            return Ok(());
        }
        let previous: Option<(String, i64)> = db.query_row(
            "SELECT v.digest,a.seen_at FROM content_aliases a JOIN vectors v
             ON a.digest=v.digest AND a.profile=v.profile WHERE a.gcid=?1 AND a.size=?2
             AND a.profile=?3 AND length(v.payload)<=4194304",
            params![gcid,size as i64,record.profile_id], |r| Ok((r.get(0)?,r.get(1)?)),
        ).optional()?;
        if let Some((digest,seen))=previous {
            // The caller just validated or persisted this very vector under
            // the cache lock. Its existing alias needs no second blob read or
            // decompression on a primary source-cache hit.
            let valid = if record.file_id.as_ref()==Some(&digest) {
                true
            } else {
                let payload:Vec<u8>=db.query_row("SELECT payload FROM vectors WHERE digest=?1 AND profile=?2",
                    params![digest,record.profile_id],|row|row.get(0))?;
                unpack(&payload).is_ok_and(|old| old.file_id.as_ref()==Some(&digest)
                    && old.profile_id==record.profile_id && alias_content_matches(&old,gcid,size))
            };
            if valid {
                if seen <= now-TOUCH_AFTER {
                    db.execute("UPDATE content_aliases SET seen_at=?4 WHERE gcid=?1 AND size=?2 AND profile=?3",params![gcid,size as i64,record.profile_id,now])?;
                }
                return Ok(());
            }
        }
        // Replace only a missing or invalid alias. The first valid mapping is
        // stable across full SHA-256 and range-backed GCID representations.
        db.execute("INSERT INTO content_aliases VALUES(?1,?2,?3,?4,?5)
            ON CONFLICT(gcid,size,profile) DO UPDATE SET digest=excluded.digest,seen_at=excluded.seen_at",
            params![gcid,size as i64,record.profile_id,record.file_id,now])?;
        Ok(())
    }

    fn import_content_aliases(&self) -> Result<()> {
        let mut db=self.db.lock().unwrap();
        if db.query_row("SELECT value FROM meta WHERE key='content_aliases_v1'",[],|r|r.get::<_,i64>(0)).optional()?.is_some() { return Ok(()); }
        let tx=db.transaction()?;
        {
            let mut query=tx.prepare("SELECT s.revision,s.profile,s.digest,v.payload,s.seen_at FROM sources s JOIN vectors v
                ON s.digest=v.digest AND s.profile=v.profile WHERE s.identity LIKE 'pikpak:%' AND length(v.payload)<=4194304")?;
            let mut rows=query.query([])?;
            while let Some(row)=rows.next()? {
                let revision:String=row.get(0)?;
                let Some((gcid,size))=cloud_revision_content(&revision) else {continue;};
                let profile:String=row.get(1)?; let digest:String=row.get(2)?; let payload:Vec<u8>=row.get(3)?;
                let Ok(record)=unpack(&payload) else {continue;};
                if record.profile_id.as_ref()==Some(&profile) && record.file_id.as_ref()==Some(&digest) {
                    Self::remember_content_alias(&tx,&gcid,size,&record,row.get(4)?)?;
                }
            }
        }
        tx.execute("INSERT OR REPLACE INTO meta VALUES('content_aliases_v1',1)",[])?;
        tx.commit()?;
        Ok(())
    }

    fn remember_outcome(
        &self,
        file: &scope::InputFile,
        revision: &str,
        reader: &str,
        mut saved: FileRecord,
    ) -> Result<()> {
        saved.path = FilePath::Utf8("cached".into());
        saved.reused = false;
        let data = serde_json::to_vec(&saved)?;
        let now = self.now();
        let identity = identity(file);
        let db = self.db.lock().unwrap();
        let previous: Option<(Vec<u8>, i64)> = db.query_row(
            "SELECT payload,seen_at FROM outcomes WHERE identity=?1 AND revision=?2 AND reader=?3 AND length(payload)<=4194304",
            params![identity, revision, reader], |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?;
        if previous.as_ref().is_some_and(|(payload, _)| decompress(payload).is_ok_and(|old| old == data)) {
            if previous.unwrap().1 <= now - TOUCH_AFTER {
                db.execute("UPDATE outcomes SET seen_at=?4 WHERE identity=?1 AND revision=?2 AND reader=?3", params![identity, revision, reader, now])?;
            }
            return Ok(());
        }
        let mut encoder = zstd::stream::Encoder::new(Vec::new(), 6)?;
        encoder.include_checksum(true)?;
        encoder.write_all(&data)?;
        let payload = encoder.finish()?;
        db.execute(
            "INSERT OR REPLACE INTO outcomes(identity,revision,reader,payload,seen_at) VALUES(?1,?2,?3,?4,?5)",
            params![identity, revision, reader, payload, now],
        )?;
        Ok(())
    }

    fn remember(&self, file: &scope::InputFile, revision: &str, record: &FileRecord) -> Result<()> {
        if vector_cache::validate_record(record).is_err() {
            return Ok(());
        }
        let mut db = self.db.lock().unwrap();
        let now = self.now();
        let identity = identity(file);
        let previous: Option<(Vec<u8>, i64)> = db.query_row(
            "SELECT payload,seen_at FROM vectors WHERE digest=?1 AND profile=?2 AND length(payload)<=4194304",
            params![record.file_id, record.profile_id], |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?;
        // Reused work is already durable. Verify its stored payload before
        // avoiding compression, so a fresh analysis can still repair damage.
        if let Some((_, seen_at)) = previous.as_ref().filter(|(payload, _)| {
            unpack(payload).is_ok_and(|old| old.file_id == record.file_id
                && old.profile_id == record.profile_id
                && old.vector_sha256 == record.vector_sha256 && old.bytes == record.bytes)
        }) {
            let source: Option<(String, i64)> = db.query_row(
                "SELECT digest,seen_at FROM sources WHERE identity=?1 AND revision=?2 AND profile=?3",
                params![identity, revision, record.profile_id], |row| Ok((row.get(0)?, row.get(1)?)),
            ).optional()?;
            if *seen_at > now - TOUCH_AFTER && source.as_ref().is_some_and(|(digest, used)|
                Some(digest) == record.file_id.as_ref() && *used > now - TOUCH_AFTER) {
                return Ok(());
            }
            let tx = db.transaction()?;
            tx.execute("UPDATE vectors SET seen_at=?3 WHERE digest=?1 AND profile=?2 AND seen_at<=?4",
                params![record.file_id, record.profile_id, now, now - TOUCH_AFTER])?;
            tx.execute("INSERT INTO sources(identity,revision,profile,digest,seen_at) VALUES(?1,?2,?3,?4,?5)
                ON CONFLICT(identity,revision,profile) DO UPDATE SET digest=excluded.digest,seen_at=excluded.seen_at
                WHERE sources.digest<>excluded.digest OR sources.seen_at<=?6",
                params![identity, revision, record.profile_id, record.file_id, now, now - TOUCH_AFTER])?;
            tx.commit()?;
            return Ok(());
        }
        let mut record = record.clone();
        // No paths, credentials, original content or signed links in this index.
        record.path = FilePath::Utf8("cached".into());
        record.reused = false;
        let payload = zstd::stream::encode_all(
            vector_cache::encode_payload(vec![record.clone()])?.as_slice(),
            6,
        )?;
        let tx = db.transaction()?;
        tx.execute(
            "INSERT OR REPLACE INTO vectors(digest,profile,payload,seen_at) VALUES(?1,?2,?3,?4)",
            params![record.file_id, record.profile_id, payload, now],
        )?;
        tx.execute(
            "INSERT OR REPLACE INTO sources(identity,revision,profile,digest,seen_at) VALUES(?1,?2,?3,?4,?5)",
            params![identity, revision, record.profile_id, record.file_id, now],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn import_checkpoints(&self, directory: &Path) -> Result<()> {
        let root = directory.join("checkpoints");
        if !root.exists() {
            return Ok(());
        }
        for entry in std::fs::read_dir(root)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let id = entry.file_name().to_string_lossy().into_owned();
            if !checkpoint::valid_id(&id) {
                continue;
            }
            // One invalid or concurrently changing old scan cannot prevent
            // reuse of other checkpoints or starting a fresh scan.
            let _ = self.import_checkpoint(&entry.path(), &id);
        }
        Ok(())
    }

    fn import_checkpoint(&self, directory: &Path, id: &str) -> Result<()> {
        let path = directory.join("checkpoint.sqlite3");
        // Revisit checkpoints previously imported for vectors only, including
        // completed scans that have not changed since password skipping arrived.
        let mut stamp = format!("all-records-v2;{};", password::CACHE_KEY);
        for path in [&path, &directory.join("checkpoint.sqlite3-wal")] {
            if let Ok(m) = std::fs::symlink_metadata(path) {
                if !m.is_file() || m.file_type().is_symlink() {
                    bail!("Invalid checkpoint file");
                }
                stamp.push_str(&format!(
                    "{}:{}:{}:{};",
                    m.ino(),
                    m.len(),
                    m.mtime(),
                    m.mtime_nsec()
                ));
            }
        }
        let previous: Option<String> = self
            .db
            .lock()
            .unwrap()
            .query_row("SELECT stamp FROM imports WHERE id=?1", [id], |r| r.get(0))
            .optional()?;
        if previous.as_ref() == Some(&stamp) {
            return Ok(());
        }
        let db = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        db.busy_timeout(Duration::from_millis(100))?;
        // A logical generation is unaffected by opening or checkpointing the
        // WAL. Filesystem stamps remain the compatibility fallback for legacy
        // journals which have not yet been opened by this version.
        let has_metadata: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata')", [], |row| row.get(0),
        )?;
        let generation: Option<i64> = if has_metadata {
            db.query_row("SELECT value FROM metadata WHERE key='source_cache_generation'", [], |row| row.get(0)).optional()?
        } else { None };
        if let Some(generation) = generation {
            let metadata = std::fs::symlink_metadata(directory.join("checkpoint.sqlite3"))?;
            stamp = format!("all-records-v4;{};{}:{};generation:{generation};", password::CACHE_KEY, metadata.dev(), metadata.ino());
            if previous.as_ref() == Some(&stamp) { return Ok(()); }
        }
        let mut rows = db.prepare("SELECT revision,payload FROM files WHERE revision IS NOT NULL AND length(payload)<=4194304")?;
        let mut rows = rows.query([])?;
        while let Some(row) = rows.next()? {
            let revision: String = row.get(0)?;
            let bytes: Vec<u8> = row.get(1)?;
            let Ok(data) = decompress(&bytes) else {
                continue;
            };
            let Ok(saved) = serde_json::from_slice::<scope::InputFile>(&data) else {
                continue;
            };
            if let Some(record) = &saved.record {
                // Use the revision recorded at analysis time, never stat a
                // current local file and attach its new revision to old data.
                if password::confirmed(record) {
                    self.remember_outcome(
                        &saved,
                        &revision,
                        password::CACHE_KEY,
                        password::canonical(record),
                    )?;
                } else {
                    self.remember(&saved, &revision, record)?;
                    if let Some((gcid,size))=cloud_content(&saved) {
                        Self::remember_content_alias(&self.db.lock().unwrap(),&gcid,size,record,self.now())?;
                    }
                }
            }
        }
        self.db.lock().unwrap().execute(
            "INSERT OR REPLACE INTO imports VALUES(?1,?2)",
            params![id, stamp],
        )?;
        Ok(())
    }
}

fn reusable_binary(record: &FileRecord) -> bool {
    record.state == FileState::Unsupported
        && record.bytes.is_some()
        && record.family.is_none()
        && record.profile_id.is_none()
        && record.vector.is_none()
        && record.vector_sha256.is_none()
        && record.error.as_ref().is_some_and(|error| {
            error.code == filetwin_core::ErrorCode::UnsupportedFormat && error.stage == "encoding"
        })
        && record
            .file_id
            .as_deref()
            .and_then(|id| id.strip_prefix("sha256:"))
            .is_some_and(|hash| {
                hash.len() == 64
                    && hash
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            })
}

fn reader_key(file: &scope::InputFile) -> String {
    // A newer format recognizer or a changed extension hint must get another
    // chance to analyse the content. Old unversioned checkpoint exclusions are
    // deliberately not imported as decisions made by the current recognizer.
    static READER: OnceLock<String> = OnceLock::new();
    let reader = READER.get_or_init(|| {
        hex::encode(ring::digest::digest(
            &ring::digest::SHA256,
            include_bytes!("../vendor/FileTwin/crates/filetwin-core/src/scan.rs"),
        ))
    });
    format!(
        "binary-v1:{reader}:{}",
        encoding::safe_extension(&file.display.name).to_ascii_lowercase()
    )
}

fn identity(file: &scope::InputFile) -> String {
    let namespace = if file.cloud.is_some() {
        "pikpak"
    } else if file.external.is_some() {
        "provider"
    } else {
        "local"
    };
    format!("{namespace}:{}", file.display.id)
}

fn cloud_content(file: &scope::InputFile) -> Option<(String,u64)> {
    let cloud=file.cloud.as_ref()?;
    let gcid=cloud.revision.as_deref()?.trim();
    (cloud.size>0 && cloud.size<=i64::MAX as u64 && gcid.len()==40 && gcid.bytes().all(|b|b.is_ascii_hexdigit()))
        .then(||(gcid.to_ascii_lowercase(),cloud.size))
}
fn cloud_revision_content(revision: &str) -> Option<(String,u64)> {
    let mut parts=revision.rsplitn(3,':');
    let gcid=parts.next()?;
    let size=parts.next()?.parse::<u64>().ok()?;
    let id=parts.next()?.strip_prefix("cloud:")?;
    (!id.is_empty() && size>0 && size<=i64::MAX as u64 && gcid.len()==40 && gcid.bytes().all(|b|b.is_ascii_hexdigit()))
        .then(||(gcid.to_ascii_lowercase(),size))
}
fn alias_content_matches(record:&FileRecord,gcid:&str,size:u64)->bool {
    record.bytes==Some(size) && record.file_id.as_deref().is_some_and(|id| {
        id.strip_prefix("gcid:").is_none_or(|value|value==format!("{gcid}:{size}"))
    })
}

fn decompress(bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() as u64 > MAX_RECORD_BYTES {
        bail!("Cached record too large");
    }
    let mut decoder = zstd::stream::read::Decoder::new(bytes)?;
    decoder.window_log_max(22)?;
    let mut data = Vec::new();
    decoder.take(MAX_RECORD_BYTES + 1).read_to_end(&mut data)?;
    if data.len() as u64 > MAX_RECORD_BYTES {
        bail!("Cached record too large");
    }
    Ok(data)
}

fn unpack(bytes: &[u8]) -> Result<FileRecord> {
    let mut records = vector_cache::decode_payload(&decompress(bytes)?)?;
    if records.len() != 1 {
        bail!("Invalid source vector");
    }
    Ok(records.remove(0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use filetwin_core::api::FileState;

    fn file() -> scope::InputFile {
        scope::InputFile::cloud(CloudItem {
            id: "remote-file".into(),
            name: "one.txt".into(),
            path: "/one.txt".into(),
            is_folder: false,
            size: 123,
            ancestors: vec![],
            revision: Some("content-revision-1".into()),
        })
    }
    fn record(backend: Backend, family: &str) -> FileRecord {
        let profile = profile::experimental_profiles_for(backend)
            .into_iter()
            .find(|p| p.family == family)
            .unwrap();
        let mut vector = vec![0.0f32; profile.dimensions];
        vector[0] = 1.0;
        let bytes: Vec<_> = vector.iter().flat_map(|v| v.to_le_bytes()).collect();
        FileRecord {
            path: FilePath::Utf8("000.txt".into()),
            file_id: Some(format!("sha256:{:064x}", 1)),
            bytes: Some(123),
            state: FileState::Ready,
            family: Some(family.into()),
            profile_id: Some(profile.profile_id),
            vector: Some(vector),
            vector_sha256: Some(hex::encode(ring::digest::digest(
                &ring::digest::SHA256,
                &bytes,
            ))),
            reused: false,
            error: None,
            extraction: None,
        }
    }
    fn reuse(cache: &SourceCache, file: &scope::InputFile) -> Option<FileRecord> {
        cache
            .reused(file, Backend::Cpu, &["text".into(), "image".into()])
            .unwrap()
    }

    #[test]
    fn photos_preview_cache_is_separate_and_does_not_compare_jpeg_size_to_original_size() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let original = scope::InputFile::external(ExternalSource {
            provider: None,
            id: "asset:photo".into(),
            name: "photo.jpg".into(),
            path: "Photos/photo.jpg".into(),
            size: 123,
            local_path: None,
            revision: Some("edited-1".into()),
            content_kind: None,
        });
        cache
            .completed(&original, &record(Backend::Cpu, "image"))
            .unwrap();
        assert!(reuse(&cache, &original).is_some());
        let mut preview = original.clone();
        preview.external.as_mut().unwrap().content_kind = Some(ExternalContentKind::PhotosPreview);
        assert_ne!(
            original.checkpoint_revision(),
            preview.checkpoint_revision()
        );
        assert!(
            reuse(&cache, &preview).is_none(),
            "Original vectors must not satisfy a preview scan"
        );
        let mut jpeg = record(Backend::Cpu, "image");
        jpeg.bytes = Some(45);
        jpeg.file_id = Some(format!("sha256:{:064x}", 2));
        cache.completed(&preview, &jpeg).unwrap();
        assert_eq!(reuse(&cache, &preview).unwrap().bytes, Some(45));
        assert_eq!(reuse(&cache, &original).unwrap().bytes, Some(123));
        preview.external.as_mut().unwrap().revision = Some("edited-2".into());
        assert!(
            reuse(&cache, &preview).is_none(),
            "Edited assets need new previews"
        );
        let json = serde_json::to_value(original.external.as_ref().unwrap()).unwrap();
        assert!(
            json.get("content_kind").is_none(),
            "Legacy inventories retain their fingerprint shape"
        );
    }

    #[test]
    fn checkpoint_import_reuses_records_after_the_former_100000_row_limit() {
        let root = tempfile::tempdir().unwrap();
        let id = "12345678-1234-1234-1234-123456789abc";
        let directory = root.path().join("checkpoints").join(id);
        private_dir(&directory).unwrap();
        let mut db = Connection::open(directory.join("checkpoint.sqlite3")).unwrap();
        db.execute_batch("CREATE TABLE files(id TEXT PRIMARY KEY,revision TEXT,payload BLOB)")
            .unwrap();
        let mut last = file();
        let empty =
            zstd::stream::encode_all(serde_json::to_vec(&last).unwrap().as_slice(), 1).unwrap();
        let tx = db.transaction().unwrap();
        {
            let mut insert = tx.prepare("INSERT INTO files VALUES(?1,?2,?3)").unwrap();
            for i in 0..100_000 {
                insert
                    .execute(params![format!("file-{i}"), "unused-revision", empty])
                    .unwrap();
            }
            last.record = Some(password::record(last.display.bytes));
            let payload =
                zstd::stream::encode_all(serde_json::to_vec(&last).unwrap().as_slice(), 1).unwrap();
            insert
                .execute(params![
                    last.display.id,
                    last.checkpoint_revision(),
                    payload
                ])
                .unwrap();
        }
        tx.commit().unwrap();
        drop(db);
        let cache = SourceCache::open(root.path()).unwrap();
        assert!(password::confirmed(
            &reuse(&cache, &last).expect("The 100,001st cached result must be imported")
        ));
        cache.db.lock().unwrap().execute_batch("DELETE FROM outcomes; UPDATE imports SET stamp=replace(stamp,'all-records-v2;','');").unwrap();
        drop(cache);
        let cache = SourceCache::open(root.path()).unwrap();
        assert!(
            reuse(&cache, &last).is_some(),
            "Old import stamps must not hide records past the previous limit"
        );
    }
    #[test]
    fn password_exclusions_reuse_without_hashes_but_changed_files_are_rechecked() {
        let root = tempfile::tempdir().unwrap();
        let file = file();
        let cache = SourceCache::open(root.path()).unwrap();
        cache
            .completed(&file, &password::record(file.display.bytes))
            .unwrap();
        drop(cache);
        let cache = SourceCache::open(root.path()).unwrap();
        let cached = cache
            .reused(&file, Backend::Coreml, &["video".into()])
            .unwrap()
            .unwrap();
        assert_eq!(cached.state, FileState::Unsupported);
        assert!(cached.reused && cached.file_id.is_none() && cached.vector.is_none());
        assert!(encoding::error_reason(cached.error.as_ref()).contains("Password-protected"));
        let mut changed = file.clone();
        changed.cloud.as_mut().unwrap().revision = Some("decrypted-version".into());
        assert!(reuse(&cache, &changed).is_none());
        changed.cloud.as_mut().unwrap().revision = None;
        assert!(reuse(&cache, &changed).is_none());
        changed = file.clone();
        changed.display.bytes += 1;
        assert!(reuse(&cache, &changed).is_none());
        assert!(reuse(
            &SourceCache::open(&root.path().join("another-account")).unwrap(),
            &file
        )
        .is_none());
        cache
            .db
            .lock()
            .unwrap()
            .execute("UPDATE outcomes SET payload=x'0000'", [])
            .unwrap();
        assert!(reuse(&cache, &file).is_none());
    }

    #[test]
    fn old_password_failures_are_imported_even_if_vector_import_already_ran() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let file = file();
        let mut record = password::record(file.display.bytes);
        record.state = FileState::Failed;
        record.file_id = Some(format!("sha256:{:064x}", 1));
        record.error = Some(filetwin_core::Error::new(
            filetwin_core::ErrorCode::DecodeFailed,
            "document",
            "unsupported Zip archive: Password required to decrypt file",
        ));
        checkpoint.completed(&file, &record).unwrap();
        drop(checkpoint);
        let cache = SourceCache::open(&request.data_dir).unwrap();
        // Model an old app which had marked this unchanged checkpoint imported
        // but had intentionally discarded every non-vector result.
        cache
            .db
            .lock()
            .unwrap()
            .execute_batch(
                "DELETE FROM outcomes; UPDATE imports SET stamp=replace(stamp,'password-v1;','');",
            )
            .unwrap();
        drop(cache);
        let cache = SourceCache::open(&request.data_dir).unwrap();
        let saved = reuse(&cache, &file).unwrap();
        assert_eq!(saved.state, FileState::Unsupported);
        assert_eq!(
            saved.file_id, record.file_id,
            "Retain an existing complete hash"
        );
        std::fs::remove_dir_all(request.data_dir.join("checkpoints")).unwrap();
        drop(cache);
        assert!(reuse(&SourceCache::open(&request.data_dir).unwrap(), &file).is_some());
    }

    #[test]
    fn completed_binary_hashes_are_reused_but_changed_readers_and_failures_are_not() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let mut file = file();
        file.display.name = "archive.7z".into();
        let mut binary = record(Backend::Cpu, "text");
        binary.state = FileState::Unsupported;
        binary.family = None;
        binary.profile_id = None;
        binary.vector = None;
        binary.vector_sha256 = None;
        binary.error = Some(filetwin_core::Error::new(
            filetwin_core::ErrorCode::UnsupportedFormat,
            "encoding",
            "Binary or unsupported content has no similarity reader; exact-content hash retained",
        ));
        cache.completed(&file, &binary).unwrap();
        let saved = reuse(&cache, &file).unwrap();
        assert_eq!(saved.state, FileState::Unsupported);
        assert_eq!(saved.file_id, binary.file_id);
        assert!(saved.vector.is_none());
        assert!(cache
            .reused(&file, Backend::Coreml, &["video".into()])
            .unwrap()
            .is_some());
        let mut changed = file.clone();
        changed.display.name = "renamed.mp4".into();
        assert!(
            reuse(&cache, &changed).is_none(),
            "A new decoder hint must be reconsidered"
        );
        changed = file.clone();
        changed.cloud.as_mut().unwrap().revision = Some("changed".into());
        assert!(reuse(&cache, &changed).is_none());
        let mut failed = binary.clone();
        failed.state = FileState::Failed;
        cache.completed(&changed, &failed).unwrap();
        assert!(
            reuse(&cache, &changed).is_none(),
            "Failures must remain retryable"
        );
        cache
            .db
            .lock()
            .unwrap()
            .execute("UPDATE outcomes SET reader='old-reader'", [])
            .unwrap();
        assert!(reuse(&cache, &file).is_none());
        cache.completed(&file, &binary).unwrap();
        cache
            .db
            .lock()
            .unwrap()
            .execute("UPDATE outcomes SET payload=x'0000'", [])
            .unwrap();
        assert!(reuse(&cache, &file).is_none());
    }

    #[tokio::test]
    async fn cache_write_failure_does_not_publish_a_successful_scan() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.resources.acceleration = acceleration::Mode::Cpu;
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        std::fs::create_dir_all(&request.local_paths[0]).unwrap();
        std::fs::write(
            request.local_paths[0].join("archive.7z"),
            b"7z\xbc\xaf\x27\x1c\0archive",
        )
        .unwrap();
        let cache = SourceCache::open(&request.data_dir).unwrap();
        cache.db.lock().unwrap().execute_batch(
            "CREATE TRIGGER refuse_cache BEFORE INSERT ON outcomes BEGIN SELECT RAISE(ABORT,'fixture storage failure'); END;"
        ).unwrap();
        drop(cache);
        assert!(
            scan(request.clone(), None, Arc::new(AtomicBool::new(false)))
                .await
                .is_err()
        );
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        assert!(
            checkpoint.sealed().unwrap().is_none(),
            "A failed durable write cannot seal the scan as complete"
        );
        assert!(!request.report_path.exists());
    }

    #[tokio::test]
    async fn completed_results_are_durable_before_cancel_and_resume_without_original_gets() {
        use std::sync::atomic::AtomicUsize;
        use tokio::io::AsyncReadExt;
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.source = ScanSource::Cloud;
        request.local_paths.clear();
        request.families = vec!["text".into()];
        request.resources.acceleration = acceleration::Mode::Cpu;
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let text = "A garden with flowers, trees and a pond. "
            .repeat(20)
            .into_bytes();
        let binary = b"7z\xbc\xaf\x27\x1c\0unsupported archive content".to_vec();
        let inputs = Arc::new(vec![
            ("text-a", "a.txt", text.clone()),
            ("text-b", "b.txt", text),
            ("binary-a", "a.7z", binary.clone()),
            ("binary-b", "b.7z", binary),
            (
                "pending",
                "pending.txt",
                "A different file was still downloading. "
                    .repeat(20)
                    .into_bytes(),
            ),
        ]);
        request.cloud_items = inputs
            .iter()
            .map(|(id, name, body)| CloudItem {
                id: (*id).into(),
                name: (*name).into(),
                path: format!("/{name}"),
                is_folder: false,
                size: body.len() as u64,
                ancestors: vec![],
                revision: None,
            })
            .collect();
        let requests = Arc::new(
            (0..inputs.len())
                .map(|_| AtomicUsize::new(0))
                .collect::<Vec<_>>(),
        );
        let finish_pending = Arc::new(AtomicBool::new(false));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = {
            let inputs = inputs.clone();
            let requests = requests.clone();
            let finish = finish_pending.clone();
            tokio::spawn(async move {
                loop {
                    let Ok((mut socket, _)) = listener.accept().await else {
                        return;
                    };
                    let inputs = inputs.clone();
                    let requests = requests.clone();
                    let finish = finish.clone();
                    tokio::spawn(async move {
                        let mut data = Vec::new();
                        let mut buffer = [0; 4096];
                        let route = loop {
                            let n = socket.read(&mut buffer).await.unwrap();
                            if n == 0 {
                                return;
                            }
                            data.extend_from_slice(&buffer[..n]);
                            let text = String::from_utf8_lossy(&data);
                            if let Some(end) = text.find("\r\n\r\n") {
                                let length = text[..end]
                                    .lines()
                                    .find_map(|line| {
                                        line.to_ascii_lowercase()
                                            .strip_prefix("content-length:")
                                            .and_then(|v| v.trim().parse::<usize>().ok())
                                    })
                                    .unwrap_or(0);
                                if data.len() >= end + 4 + length {
                                    break text.split_whitespace().nth(1).unwrap().to_owned();
                                }
                            }
                        };
                        let original = route.starts_with("/content/");
                        let mut pending = false;
                        let body = if route.starts_with("/v1/auth/token") {
                            json!({"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"sub":"fixture-user"}).to_string().into_bytes()
                        } else if route.starts_with("/v1/shield/captcha/init") {
                            json!({"captcha_token":"fixture-captcha","expires_in":3600})
                                .to_string()
                                .into_bytes()
                        } else {
                            let id = route
                                .trim_start_matches(if original {
                                    "/content/"
                                } else {
                                    "/drive/v1/files/"
                                })
                                .split('?')
                                .next()
                                .unwrap();
                            let (index, (_, name, body)) = inputs
                                .iter()
                                .enumerate()
                                .find(|(_, (key, _, _))| *key == id)
                                .unwrap();
                            if original {
                                requests[index].fetch_add(1, Ordering::SeqCst);
                                pending = id == "pending";
                                body.clone()
                            } else {
                                json!({"id":id,"name":name,"size":body.len().to_string(),"hash":format!("revision-{id}"),"web_content_link":format!("http://{address}/content/{id}")}).to_string().into_bytes()
                            }
                        };
                        let header = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        if socket.write_all(header.as_bytes()).await.is_err() {
                            return;
                        }
                        if pending {
                            while !finish.load(Ordering::Acquire) {
                                tokio::time::sleep(Duration::from_millis(10)).await;
                            }
                        }
                        let _ = socket.write_all(&body).await;
                    });
                }
            })
        };
        let client = Client::builder()
            .refresh_token("fixture-refresh")
            .device_id("fixture-device")
            .api_base_url(format!("http://{address}"))
            .auth_base_url(format!("http://{address}"))
            .build()
            .unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let running = {
            let request = request.clone();
            let client = client.clone();
            let cancel = cancel.clone();
            tokio::spawn(async move { scan(request, Some(&client), cancel).await })
        };
        let saved = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let count = Connection::open_with_flags(
                    request.data_dir.join(FILENAME),
                    OpenFlags::SQLITE_OPEN_READ_ONLY,
                )
                .and_then(|db| {
                    db.query_row(
                        "SELECT (SELECT count(*) FROM sources)+(SELECT count(*) FROM outcomes)",
                        [],
                        |r| r.get::<_, i64>(0),
                    )
                })
                .unwrap_or(0);
                if count == 4 && requests[4].load(Ordering::Acquire) == 1 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        cancel.store(true, Ordering::Release);
        let stopped = tokio::time::timeout(Duration::from_secs(10), running).await;
        finish_pending.store(true, Ordering::Release);
        saved.expect("Completed files must be committed before the scan ends");
        stopped.unwrap().unwrap().unwrap();

        // Resume the interrupted checkpoint. Only its unfinished file is fetched.
        scan(
            request.clone(),
            Some(&client),
            Arc::new(AtomicBool::new(false)),
        )
        .await
        .unwrap();
        for count in &requests[..4] {
            assert_eq!(count.load(Ordering::Acquire), 1);
        }
        assert_eq!(requests[4].load(Ordering::Acquire), 2);

        // Clear this synthetic scan and remove its aggregate vector snapshot.
        // A new scan must rely on the per-file cache committed above.
        std::fs::remove_dir_all(request.data_dir.join("checkpoints")).unwrap();
        let _ = std::fs::remove_file(request.data_dir.join("filetwin-vectors.f32.zst"));
        request.checkpoint_id = None;
        scan(
            request.clone(),
            Some(&client),
            Arc::new(AtomicBool::new(false)),
        )
        .await
        .unwrap();
        server.abort();
        for count in &requests[..4] {
            assert_eq!(count.load(Ordering::Acquire), 1);
        }
        assert_eq!(requests[4].load(Ordering::Acquire), 2);
        let report: ScanReport =
            serde_json::from_slice(&std::fs::read(&request.report_path).unwrap()).unwrap();
        assert_eq!(report.analysed_files, 3);
        assert_eq!(report.unsupported_files, 2);
        assert_eq!(report.failed_files, 0);
        assert_eq!(report.downloaded_bytes, 0);
        assert!(
            report.groups.iter().any(|group| group
                .members
                .iter()
                .filter(|file| file.name.ends_with(".7z"))
                .count()
                == 2),
            "Cached hashes must still produce exact-duplicate archive matches"
        );
    }

    #[test]
    fn completed_vector_reuses_before_source_resolution_and_survives_scan_clear() {
        let root = tempfile::tempdir().unwrap();
        let file = file();
        let record = record(Backend::Cpu, "text");
        let cache = SourceCache::open(root.path()).unwrap();
        cache.completed(&file, &record).unwrap();
        drop(cache);
        let cache = SourceCache::open(root.path()).unwrap();
        let reused = reuse(&cache, &file).unwrap();
        assert!(reused.reused);
        assert_eq!(reused.vector, record.vector);
        let mut renamed = file.clone();
        renamed.display.name = "renamed.txt".into();
        renamed.display.path = "/Elsewhere/renamed.txt".into();
        assert!(reuse(&cache, &renamed).is_some());
        let other = SourceCache::open(&root.path().join("another-account")).unwrap();
        assert!(reuse(&other, &file).is_none());
        assert!(
            !root.path().join("checkpoints").exists(),
            "Source cache is independent of scan checkpoints"
        );
        assert_eq!(
            std::fs::metadata(root.path().join(FILENAME))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn changed_missing_revision_profile_and_invalid_vectors_are_cache_misses() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let file = file();
        cache
            .completed(&file, &record(Backend::Cpu, "image"))
            .unwrap();
        assert!(reuse(&cache, &file).is_some());
        assert!(cache
            .reused(&file, Backend::Coreml, &["image".into()])
            .unwrap()
            .is_none());
        assert!(cache
            .reused(&file, Backend::Cpu, &["text".into()])
            .unwrap()
            .is_none());
        for revision in [None, Some("".into()), Some("changed".into())] {
            let mut changed = file.clone();
            changed.cloud.as_mut().unwrap().revision = revision;
            assert!(reuse(&cache, &changed).is_none());
        }
        let mut changed = file.clone();
        changed.cloud.as_mut().unwrap().size += 1;
        assert!(reuse(&cache, &changed).is_none());
        let mut invalid = record(Backend::Cpu, "text");
        invalid.state = FileState::Failed;
        cache.completed(&file, &invalid).unwrap();
        assert!(cache
            .reused(&file, Backend::Cpu, &["text".into()])
            .unwrap()
            .is_none());
        cache
            .db
            .lock()
            .unwrap()
            .execute("UPDATE vectors SET payload=x'0000'", [])
            .unwrap();
        assert!(reuse(&cache, &file).is_none());
    }

    #[test]
    fn older_checkpoint_is_imported_without_attaching_old_vectors_to_a_new_revision() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let file = file();
        let record = record(Backend::Cpu, "text");
        checkpoint.completed(&file, &record).unwrap();
        drop(checkpoint);
        let cache = SourceCache::open(&request.data_dir).unwrap();
        assert!(reuse(&cache, &file).is_some());
        let mut changed = file.clone();
        changed.cloud.as_mut().unwrap().revision = Some("edited".into());
        assert!(reuse(&cache, &changed).is_none());
        std::fs::remove_dir_all(request.data_dir.join("checkpoints")).unwrap();
        drop(cache);
        assert!(reuse(&SourceCache::open(&request.data_dir).unwrap(), &file).is_some());
    }

    #[test]
    fn provider_revisions_skip_exports_and_multiple_windows_share_completed_work() {
        let root = tempfile::tempdir().unwrap();
        let first = SourceCache::open(root.path()).unwrap();
        let second = SourceCache::open(root.path()).unwrap();
        let mut file = scope::InputFile::external(ExternalSource {
            provider: None,
            content_kind: None,
            id: "asset:photos-test".into(),
            name: "photo.png".into(),
            path: "Photos/Test/photo.png".into(),
            size: 123,
            local_path: None,
            revision: Some("modified:2026-09-11".into()),
        });
        first
            .completed(&file, &record(Backend::Cpu, "image"))
            .unwrap();
        assert!(reuse(&second, &file).is_some());
        file.external.as_mut().unwrap().revision = Some("modified:2026-09-12".into());
        assert!(reuse(&second, &file).is_none());
    }

    #[tokio::test]
    async fn cached_photos_vector_finishes_without_requesting_an_original() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.local_paths.clear();
        request.families = vec!["image".into()];
        let item = ExternalSource {
            provider: None,
            content_kind: None,
            id: "asset:cached-image".into(),
            name: "photo.png".into(),
            path: "Photos/photo.png".into(),
            size: 123,
            local_path: None,
            revision: Some("modified-1".into()),
        };
        let cache = SourceCache::open(&request.data_dir).unwrap();
        cache
            .completed(
                &scope::InputFile::external(item.clone()),
                &record(Backend::Cpu, "image"),
            )
            .unwrap();
        drop(cache);
        request.external_sources = vec![item];
        // There is deliberately no provider responder. Any resolve_source/FIFO
        // request would hang, so enforce a timeout and stop the helper on error.
        let cancel = Arc::new(AtomicBool::new(false));
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            scan(request.clone(), None, cancel.clone()),
        )
        .await;
        if result.is_err() {
            cancel.store(true, Ordering::Release);
        }
        result.unwrap().unwrap();
        let report: ScanReport =
            serde_json::from_slice(&std::fs::read(&request.report_path).unwrap()).unwrap();
        assert_eq!(report.analysed_files, 1);
        assert_eq!(report.failed_files, 0);
        assert_eq!(report.downloaded_bytes, 0);
        assert_eq!(std::fs::read_dir(request.temp_dir).unwrap().count(), 0);
    }

    fn rows(cache: &SourceCache, table: &str) -> i64 {
        cache.db.lock().unwrap().query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get(0)).unwrap()
    }
    fn with_revision(file: &scope::InputFile, revision: &str) -> scope::InputFile {
        let mut changed = file.clone();
        changed.cloud.as_mut().unwrap().revision = Some(revision.into());
        changed
    }
    /// A different file: another identity as well as another cloud id.
    fn another_file(id: &str) -> scope::InputFile {
        let mut item = file();
        item.display.id = id.into();
        item.cloud.as_mut().unwrap().id = id.into();
        item
    }
    fn record_with_hash(number: u64) -> FileRecord {
        let mut saved = record(Backend::Cpu, "text");
        saved.file_id = Some(format!("sha256:{number:064x}"));
        saved
    }
    const DAY: i64 = 24 * 60 * 60;
    /// Pretend a file's saved work was last used at `at`.
    fn touch(cache: &SourceCache, file: &scope::InputFile, at: i64) {
        let db = cache.db.lock().unwrap();
        let name = identity(file);
        db.execute("UPDATE sources SET seen_at=?2 WHERE identity=?1", params![name, at]).unwrap();
        db.execute("UPDATE vectors SET seen_at=?2 WHERE (digest,profile) IN (SELECT digest,profile FROM sources WHERE identity=?1)", params![name, at]).unwrap();
        db.execute("UPDATE outcomes SET seen_at=?2 WHERE identity=?1", params![name, at]).unwrap();
    }

    #[test]
    fn an_edited_files_old_revision_ages_out_while_its_current_one_stays() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let first = file();
        cache.completed(&first, &record_with_hash(1)).unwrap();
        let second = with_revision(&first, "content-revision-2");
        cache.completed(&second, &record_with_hash(2)).unwrap();
        assert_eq!(rows(&cache, "sources"), 2, "both revisions are kept while they are young");
        assert!(reuse(&cache, &first).is_some() && reuse(&cache, &second).is_some());
        let later = cache.now() + 100 * DAY;
        cache.db.lock().unwrap().execute("UPDATE sources SET seen_at=?1 WHERE revision=?2", params![later - DAY, second.checkpoint_revision().unwrap()]).unwrap();
        let pruned = cache.prune_at(later);
        assert_eq!((pruned.sources, pruned.vectors), (1, 1), "{pruned:?}");
        assert!(reuse(&cache, &first).is_none() && reuse(&cache, &second).is_some());
    }

    #[test]
    fn old_binary_outcomes_age_out_and_current_ones_stay() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let mut archive = file();
        archive.display.name = "archive.7z".into();
        let mut binary = record(Backend::Cpu, "text");
        binary.state = FileState::Unsupported;
        binary.family = None; binary.profile_id = None; binary.vector = None; binary.vector_sha256 = None;
        binary.error = Some(filetwin_core::Error::new(filetwin_core::ErrorCode::UnsupportedFormat, "encoding",
            "Binary or unsupported content has no similarity reader; exact-content hash retained"));
        cache.completed(&archive, &binary).unwrap();
        let newer = with_revision(&archive, "content-revision-2");
        cache.completed(&newer, &binary).unwrap();
        assert_eq!(rows(&cache, "outcomes"), 2);
        let later = cache.now() + 100 * DAY;
        cache.db.lock().unwrap().execute("UPDATE outcomes SET seen_at=?1 WHERE revision=?2", params![later - DAY, newer.checkpoint_revision().unwrap()]).unwrap();
        assert_eq!(cache.prune_at(later).outcomes, 1);
        assert!(reuse(&cache, &archive).is_none() && reuse(&cache, &newer).is_some());
    }

    #[test]
    fn reusing_saved_work_refreshes_its_last_used_time_at_most_once_a_day() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let item = file();
        cache.completed(&item, &record_with_hash(1)).unwrap();
        let seen = |cache: &SourceCache| -> i64 { cache.db.lock().unwrap().query_row("SELECT seen_at FROM sources", [], |row| row.get(0)).unwrap() };
        let saved = seen(&cache);
        assert!(reuse(&cache, &item).is_some());
        assert_eq!(seen(&cache), saved, "a reuse within the day writes nothing");
        cache.db.lock().unwrap().execute("UPDATE sources SET seen_at=?1", [saved - 2 * DAY]).unwrap();
        assert!(reuse(&cache, &item).is_some());
        assert!(seen(&cache) >= saved, "a reuse after a day refreshes it, so used work is never pruned");
    }

    #[test]
    fn completed_reuse_and_content_aliases_do_not_rewrite_vectors() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let item = file();
        let original = record(Backend::Cpu, "text");
        cache.completed(&item, &original).unwrap();
        let before = cache.db.lock().unwrap().total_changes();
        let reused = reuse(&cache, &item).unwrap();
        cache.completed(&item, &reused).unwrap();
        assert_eq!(cache.db.lock().unwrap().total_changes(), before);
        cache.db.lock().unwrap().execute_batch("CREATE TRIGGER no_vector_rewrite BEFORE INSERT ON vectors BEGIN SELECT RAISE(ABORT,'unexpected vector rewrite'); END;").unwrap();
        let mut alias = item.clone();
        alias.display.id = "different-occurrence".into();
        cache.completed(&alias, &original).unwrap();
        assert!(reuse(&cache, &alias).is_some());
        assert_eq!(rows(&cache, "vectors"), 1);
        assert_eq!(rows(&cache, "sources"), 2);
    }

    #[test]
    fn completed_analysis_repairs_corrupt_saved_vectors() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let item = file();
        let original = record(Backend::Cpu, "text");
        cache.completed(&item, &original).unwrap();
        cache.db.lock().unwrap().execute("UPDATE vectors SET payload=x'0000'", []).unwrap();
        assert!(reuse(&cache, &item).is_none());
        cache.completed(&item, &original).unwrap();
        assert_eq!(reuse(&cache, &item).unwrap().vector, original.vector);
        let mut wrong = original.clone();
        wrong.file_id = Some(format!("sha256:{:064x}", 2));
        let payload = zstd::stream::encode_all(vector_cache::encode_payload(vec![wrong]).unwrap().as_slice(), 6).unwrap();
        cache.db.lock().unwrap().execute("UPDATE vectors SET payload=?1", [payload]).unwrap();
        assert!(reuse(&cache, &item).is_none());
        cache.completed(&item, &original).unwrap();
        assert_eq!(reuse(&cache, &item).unwrap().file_id, original.file_id);
    }

    #[test]
    fn trusted_gcid_reuses_vectors_across_cloud_ids_without_cache_writes() {
        let root=tempfile::tempdir().unwrap();
        let cache=SourceCache::open(root.path()).unwrap();
        let mut first=file(); first.cloud.as_mut().unwrap().revision=Some("AB".repeat(20));
        let original=record(Backend::Cpu,"image"); cache.completed(&first,&original).unwrap();
        let mut copy=first.clone(); copy.cloud.as_mut().unwrap().id="another-cloud-id".into(); copy.display.id="different-occurrence".into();
        let before=cache.db.lock().unwrap().total_changes();
        let reused=cache.reused(&copy,Backend::Cpu,&["image".into()]).unwrap().unwrap();
        assert!(reused.reused); assert_eq!(reused.file_id,original.file_id); assert_eq!(reused.vector,original.vector);
        assert_eq!(cache.db.lock().unwrap().total_changes(),before);
        assert!(cache.reused(&copy,Backend::Coreml,&["image".into()]).unwrap().is_none());
        for revision in [Some("CD".repeat(20)),Some("2026-10-14T00:00:00Z".into()),None] {
            copy.cloud.as_mut().unwrap().revision=revision;
            assert!(cache.reused(&copy,Backend::Cpu,&["image".into()]).unwrap().is_none());
        }
        copy.cloud.as_mut().unwrap().revision=first.cloud.as_ref().unwrap().revision.clone();
        copy.cloud.as_mut().unwrap().size+=1; copy.display.bytes+=1;
        assert!(cache.reused(&copy,Backend::Cpu,&["image".into()]).unwrap().is_none());
    }

    #[test]
    fn old_source_rows_migrate_gcid_aliases_and_pruning_drops_dangling_aliases() {
        let root=tempfile::tempdir().unwrap();
        let cache=SourceCache::open(root.path()).unwrap();
        let mut first=file(); first.cloud.as_mut().unwrap().revision=Some("AB".repeat(20));
        cache.completed(&first,&record(Backend::Cpu,"text")).unwrap();
        cache.db.lock().unwrap().execute_batch("DELETE FROM content_aliases; DELETE FROM meta WHERE key='content_aliases_v1';").unwrap();
        drop(cache);
        let cache=SourceCache::open(root.path()).unwrap();
        let mut copy=first.clone(); copy.cloud.as_mut().unwrap().id="copy".into(); copy.display.id="copy-occurrence".into();
        assert!(reuse(&cache,&copy).is_some()); assert_eq!(rows(&cache,"content_aliases"),1);
        cache.prune_with_limit(cache.now(),0);
        assert_eq!(rows(&cache,"content_aliases"),0); assert!(reuse(&cache,&copy).is_none());
    }

    #[test]
    fn timestamp_revisions_do_not_create_gcid_aliases() {
        let root=tempfile::tempdir().unwrap();
        let cache=SourceCache::open(root.path()).unwrap();
        let mut source=file(); source.cloud.as_mut().unwrap().revision=Some("2026-10-14T00:00:00Z".into());
        cache.completed(&source,&record(Backend::Cpu,"text")).unwrap();
        assert_eq!(rows(&cache,"content_aliases"),0);
    }

    #[test]
    fn gcid_alias_migration_preserves_age_and_reuse_refreshes_vector_age() {
        let root=tempfile::tempdir().unwrap(); let cache=SourceCache::open(root.path()).unwrap();
        let mut first=file(); first.cloud.as_mut().unwrap().revision=Some("AB".repeat(20));
        cache.completed(&first,&record(Backend::Cpu,"text")).unwrap();
        let old=cache.now()-2*24*60*60;
        cache.db.lock().unwrap().execute("UPDATE vectors SET seen_at=?1",[old]).unwrap();
        let mut copy=first.clone(); copy.cloud.as_mut().unwrap().id="copy".into(); copy.display.id="copy-occurrence".into();
        assert!(reuse(&cache,&copy).is_some());
        let refreshed:i64=cache.db.lock().unwrap().query_row("SELECT seen_at FROM vectors",[],|r|r.get(0)).unwrap();
        assert!(refreshed>old);
        let expired=cache.now()-100*24*60*60;
        {let db=cache.db.lock().unwrap(); db.execute("UPDATE sources SET seen_at=?1",[expired]).unwrap(); db.execute("UPDATE vectors SET seen_at=?1",[expired]).unwrap();
         db.execute_batch("DELETE FROM content_aliases; DELETE FROM meta WHERE key='content_aliases_v1';").unwrap();}
        cache.import_content_aliases().unwrap();
        let migrated:i64=cache.db.lock().unwrap().query_row("SELECT seen_at FROM content_aliases",[],|r|r.get(0)).unwrap();
        assert_eq!(migrated,expired);
        cache.prune_at(cache.now()); assert_eq!(rows(&cache,"content_aliases"),0); assert_eq!(rows(&cache,"vectors"),0);
    }

    #[test]
    fn checkpoint_import_generation_survives_wal_changes() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let item = file();
        checkpoint.completed(&item, &record(Backend::Cpu, "text")).unwrap();
        let cache = SourceCache::open(&request.data_dir).unwrap();
        let before = cache.db.lock().unwrap().total_changes();
        cache.import_checkpoints(&request.data_dir).unwrap();
        assert_eq!(cache.db.lock().unwrap().total_changes(), before);
        drop(checkpoint);
        cache.import_checkpoints(&request.data_dir).unwrap();
        assert_eq!(cache.db.lock().unwrap().total_changes(), before);
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let mut changed = item.clone();
        changed.cloud.as_mut().unwrap().revision = Some("next-revision".into());
        checkpoint.completed(&changed, &record(Backend::Cpu, "text")).unwrap();
        cache.import_checkpoints(&request.data_dir).unwrap();
        assert!(reuse(&cache, &changed).is_some());
    }

    #[test]
    fn entries_unused_for_months_are_pruned_and_used_ones_are_kept() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let (old, recent) = (another_file("old-file"), another_file("recent-file"));
        cache.completed(&old, &record_with_hash(1)).unwrap();
        cache.completed(&recent, &record_with_hash(2)).unwrap();
        let start = cache.now();
        // Three months later only the file that was used again in the meantime is still wanted.
        let later = start + 100 * DAY;
        touch(&cache, &recent, later - DAY);
        let pruned = cache.prune_at(later);
        assert_eq!((pruned.sources, pruned.vectors), (1, 1), "{pruned:?}");
        assert!(reuse(&cache, &old).is_none() && reuse(&cache, &recent).is_some());
        assert_eq!((rows(&cache, "sources"), rows(&cache, "vectors")), (1, 1));
        let nothing = cache.prune_at(later);
        assert_eq!((nothing.sources, nothing.outcomes, nothing.vectors), (0, 0, 0), "pruning is idempotent");
    }

    #[test]
    fn content_of_deleted_files_survives_until_it_is_old_so_moves_and_renames_still_reuse_it() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        cache.completed(&file(), &record_with_hash(1)).unwrap();
        let soon = cache.now() + 10 * DAY;
        let pruned = cache.prune_at(soon);
        assert_eq!((pruned.sources, pruned.vectors), (0, 0), "recent entries are never pruned");
    }

    #[test]
    fn the_vector_cache_has_a_size_limit_and_evicts_the_oldest_first() {
        let root = tempfile::tempdir().unwrap();
        let cache = SourceCache::open(root.path()).unwrap();
        let mut files = Vec::new();
        for number in 0..6u64 {
            let item = another_file(&format!("file-{number}"));
            cache.completed(&item, &record_with_hash(number + 10)).unwrap();
            touch(&cache, &item, cache.now() - (6 - number as i64) * 60);
            files.push(item);
        }
        let total: i64 = cache.db.lock().unwrap().query_row("SELECT sum(length(payload)) FROM vectors", [], |row| row.get(0)).unwrap();
        let limit = total / 2;
        let pruned = cache.prune_with_limit(cache.now(), limit);
        assert!(pruned.vectors >= 3, "{pruned:?}");
        let kept: i64 = cache.db.lock().unwrap().query_row("SELECT coalesce(sum(length(payload)),0) FROM vectors", [], |row| row.get(0)).unwrap();
        assert!(kept <= limit, "{kept} > {limit}");
        assert!(reuse(&cache, &files[0]).is_none(), "the oldest went first");
        assert!(reuse(&cache, &files[5]).is_some(), "the newest stayed");
        assert_eq!(rows(&cache, "sources"), rows(&cache, "vectors"), "no saved source points at an evicted vector");
    }

    #[test]
    fn a_cache_from_before_pruning_is_upgraded_without_losing_anything() {
        let root = tempfile::tempdir().unwrap();
        {
            let db = Connection::open(root.path().join(FILENAME)).unwrap();
            db.execute_batch("CREATE TABLE vectors(digest TEXT, profile TEXT, payload BLOB NOT NULL, PRIMARY KEY(digest,profile)) WITHOUT ROWID;
                CREATE TABLE sources(identity TEXT, revision TEXT, profile TEXT, digest TEXT NOT NULL, PRIMARY KEY(identity,revision,profile)) WITHOUT ROWID;
                CREATE TABLE outcomes(identity TEXT, revision TEXT, reader TEXT, payload BLOB NOT NULL, PRIMARY KEY(identity,revision,reader)) WITHOUT ROWID;
                CREATE TABLE imports(id TEXT PRIMARY KEY, stamp TEXT) WITHOUT ROWID;
                INSERT INTO sources VALUES('pikpak:old-file','rev','profile','digest');
                INSERT INTO vectors VALUES('digest','profile',x'00');").unwrap();
        }
        let cache = SourceCache::open(root.path()).unwrap();
        assert_eq!((rows(&cache, "sources"), rows(&cache, "vectors")), (1, 1), "upgrading keeps the old rows");
        let upgraded = cache.prune_at(cache.now() + DAY);
        assert_eq!((upgraded.sources, upgraded.vectors), (0, 0), "old rows are dated at the upgrade, not at 1970");
        let ancient = cache.prune_at(cache.now() + 100 * DAY);
        assert_eq!((ancient.sources, ancient.vectors), (1, 1));
        cache.completed(&file(), &record_with_hash(1)).unwrap();
        assert!(reuse(&cache, &file()).is_some(), "the upgraded cache accepts new work");
    }

    #[test]
    fn opening_prunes_at_most_once_a_day() {
        let root = tempfile::tempdir().unwrap();
        let first = SourceCache::open(root.path()).unwrap();
        first.completed(&file(), &record_with_hash(1)).unwrap();
        let before = first.last_pruned().unwrap();
        drop(first);
        let again = SourceCache::open(root.path()).unwrap();
        assert_eq!(again.last_pruned().unwrap(), before, "a second open the same day does not prune again");
    }
}

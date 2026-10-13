//! Account-local metadata inventory used by duplicate scans and link saves.
//!
//! Folder snapshots become readable only after every remote page has arrived.
//! A generation counter prevents a network request started before an app file
//! change from overwriting that change. Cached files never contain signed URLs.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};

use crate::{FileInfo, FileKind};

const FILE_COLUMNS: &str = "id,name,size,kind,parent_id,mime_type,created_time,modified_time,file_extension,file_category,gcid,md5";

/// Persistent metadata for one PikPak account. Safe to share between threads.
pub struct DuplicateCache {
    path: PathBuf,
    db: Mutex<Connection>,
}

impl std::fmt::Debug for DuplicateCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DuplicateCache")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl DuplicateCache {
    /// Open an inventory under a private directory, separated by account ID.
    pub fn open(directory: &Path, account_id: &str) -> Result<Self> {
        if account_id.trim().is_empty() {
            bail!("Cannot open a duplicate cache without an account ID");
        }
        private_directory(directory)?;
        let digest = ring::digest::digest(&ring::digest::SHA256, account_id.as_bytes());
        let path = directory.join(format!(
            "duplicate-{}.sqlite3",
            hex::encode(digest.as_ref())
        ));
        private_file(&path)?;
        let mut db = Connection::open(&path).context("Open duplicate metadata cache")?;
        db.busy_timeout(Duration::from_secs(15))?;
        // DELETE journaling keeps the cache in one persistent file. Its journal
        // inherits the database permissions and avoids sensitive WAL sidecars.
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL;")?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
             ) WITHOUT ROWID;
             INSERT OR IGNORE INTO metadata VALUES ('generation',0);
             CREATE TABLE IF NOT EXISTS files (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                size TEXT NOT NULL,
                kind INTEGER NOT NULL CHECK(kind IN (0,1)),
                parent_id TEXT NOT NULL,
                mime_type TEXT,
                created_time TEXT,
                modified_time TEXT,
                file_extension TEXT,
                file_category TEXT,
                gcid TEXT,
                md5 TEXT,
                trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0,1)),
                trash_root TEXT
             );
             CREATE INDEX IF NOT EXISTS files_parent ON files(parent_id,trashed);
             CREATE INDEX IF NOT EXISTS files_gcid ON files(gcid,size) WHERE kind=0 AND trashed=0 AND gcid IS NOT NULL;
             CREATE INDEX IF NOT EXISTS files_md5 ON files(md5,size) WHERE kind=0 AND trashed=0 AND gcid IS NULL AND md5 IS NOT NULL;
             CREATE TABLE IF NOT EXISTS folders (
                parent_id TEXT PRIMARY KEY,
                complete INTEGER NOT NULL CHECK(complete IN (0,1))
             ) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS pending_task_folders (
                task_id TEXT NOT NULL,
                parent_id TEXT NOT NULL,
                PRIMARY KEY(task_id,parent_id)
             ) WITHOUT ROWID;
             CREATE INDEX IF NOT EXISTS pending_parent ON pending_task_folders(parent_id);",
        )?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS download_shares (
                source_key TEXT PRIMARY KEY,
                share_url TEXT
             ) WITHOUT ROWID;",
        )?;
        tx.commit()?;
        Ok(Self {
            path,
            db: Mutex::new(db),
        })
    }

    /// The account-specific database path, also suitable as a lock-file stem.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Public share links only, never signed CDN URLs. A NULL URL records an
    /// attempted creation whose outcome must be reconciled before another POST.
    pub(crate) fn download_share(&self, source_key: &str) -> Result<Option<Option<String>>> {
        Ok(self.connection()?.query_row(
            "SELECT share_url FROM download_shares WHERE source_key=?1",
            [source_key],
            |row| row.get(0),
        ).optional()?)
    }

    pub(crate) fn remember_download_share(&self, source_key: &str, url: Option<&str>) -> Result<()> {
        self.connection()?.execute(
            "INSERT INTO download_shares(source_key,share_url) VALUES (?1,?2)
             ON CONFLICT(source_key) DO UPDATE SET share_url=excluded.share_url",
            params![source_key, url],
        )?;
        Ok(())
    }

    pub(crate) fn forget_download_share(&self, source_key: &str) -> Result<()> {
        self.connection()?.execute("DELETE FROM download_shares WHERE source_key=?1", [source_key])?;
        Ok(())
    }

    /// Capture before a remote metadata request; guarded writes reject old data.
    pub fn generation(&self) -> Result<u64> {
        let db = self.connection()?;
        generation(&db)
    }

    /// Read one known live entry without requiring its folder to be complete.
    pub fn file(&self, id: &str) -> Result<Option<FileInfo>> {
        let db = self.connection()?;
        Ok(db
            .query_row(
                &format!("SELECT {FILE_COLUMNS} FROM files WHERE id=?1 AND trashed=0"),
                [id],
                file_from_row,
            )
            .optional()?)
    }

    /// Whether an entry is known, including retained Trash metadata for undo.
    pub fn contains_file(&self, id: &str) -> Result<bool> {
        let db = self.connection()?;
        Ok(db.query_row(
            "SELECT EXISTS(SELECT 1 FROM files WHERE id=?1)",
            [id],
            |r| r.get(0),
        )?)
    }

    /// Read a complete direct-child snapshot, including an empty folder.
    /// Pending background tasks make their folder and descendants unavailable.
    pub fn folder(&self, parent_id: &str) -> Result<Option<Vec<FileInfo>>> {
        let mut db = self.connection()?;
        let tx = db.transaction()?;
        let complete: bool = tx
            .query_row(
                "SELECT complete FROM folders WHERE parent_id=?1",
                [parent_id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(false);
        let trashed: bool = tx
            .query_row("SELECT trashed FROM files WHERE id=?1", [parent_id], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or(false);
        if !complete || trashed || has_pending_ancestor(&tx, parent_id)? {
            return Ok(None);
        }
        let files = query_files(
            &tx,
            &format!(
                "SELECT {FILE_COLUMNS} FROM files WHERE parent_id=?1 AND trashed=0 ORDER BY id"
            ),
            [parent_id],
        )?;
        tx.commit()?;
        Ok(Some(files))
    }

    /// Replace a complete listing after an application-confirmed change.
    pub fn replace_folder(&self, parent_id: &str, files: &[FileInfo]) -> Result<()> {
        self.store_folder(parent_id, files, true, None)?;
        Ok(())
    }

    /// Store a full remote listing only if no app mutation occurred meanwhile.
    /// Returns false when stale data was discarded.
    pub fn replace_folder_if_generation(
        &self,
        parent_id: &str,
        files: &[FileInfo],
        expected_generation: u64,
    ) -> Result<bool> {
        self.store_folder(parent_id, files, true, Some(expected_generation))
    }

    /// Store known children without claiming that the folder was fully listed.
    pub fn upsert_files(&self, parent_id: &str, files: &[FileInfo]) -> Result<()> {
        self.store_folder(parent_id, files, false, None)?;
        Ok(())
    }

    /// Store a partial remote page if its generation is still current.
    pub fn upsert_files_if_generation(
        &self,
        parent_id: &str,
        files: &[FileInfo],
        expected_generation: u64,
    ) -> Result<bool> {
        self.store_folder(parent_id, files, false, Some(expected_generation))
    }

    fn store_folder(
        &self,
        parent_id: &str,
        files: &[FileInfo],
        complete: bool,
        expected_generation: Option<u64>,
    ) -> Result<bool> {
        let mut seen = HashSet::with_capacity(files.len());
        for file in files {
            if file.id.is_empty() || file.id == parent_id || !seen.insert(file.id.as_str()) {
                bail!("Duplicate cache listing contains an invalid or repeated file ID");
            }
        }
        let mut db = self.connection()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(expected) = expected_generation {
            if generation(&tx)? != expected {
                return Ok(false);
            }
        }
        // A folder deleted while a request was in flight must not be revived by
        // a descendant snapshot, even when opened from a second process.
        let parent_trashed: bool = tx
            .query_row("SELECT trashed FROM files WHERE id=?1", [parent_id], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or(false);
        if parent_trashed {
            return Ok(false);
        }
        if complete {
            let old_ids: Vec<String> = {
                let mut query =
                    tx.prepare("SELECT id FROM files WHERE parent_id=?1 AND trashed=0")?;
                let ids = query
                    .query_map([parent_id], |r| r.get(0))?
                    .collect::<rusqlite::Result<_>>()?;
                ids
            };
            for id in old_ids.into_iter().filter(|id| !seen.contains(id.as_str())) {
                trash_subtree(&tx, &id)?;
                invalidate_subtree(&tx, &id)?;
            }
        }
        upsert(&tx, parent_id, files)?;
        if complete {
            tx.execute("INSERT INTO folders(parent_id,complete) VALUES(?1,?2) ON CONFLICT(parent_id) DO UPDATE SET complete=excluded.complete",
                params![parent_id, !has_pending_ancestor(&tx, parent_id)?])?;
        }
        if expected_generation.is_none() {
            bump_generation(&tx)?;
        }
        tx.commit()?;
        Ok(true)
    }

    /// Require the next duplicate scan to fetch this folder again.
    pub fn invalidate_folder(&self, parent_id: &str) -> Result<()> {
        self.mutate(|tx| invalidate_folder(tx, parent_id))
    }

    /// Require fresh listings for this folder and its cached descendants.
    pub fn invalidate_subtree(&self, parent_id: &str) -> Result<()> {
        self.mutate(|tx| invalidate_subtree(tx, parent_id))
    }

    /// Hide trashed files and descendants while retaining metadata for undo.
    pub fn remove(&self, ids: &[String]) -> Result<()> {
        self.mutate(|tx| {
            for id in ids {
                trash_subtree(tx, id)?;
            }
            Ok(())
        })
    }

    /// Restore metadata hidden by corresponding Trash operations.
    /// Children that were already individually trashed stay in Trash.
    pub fn untrash(&self, ids: &[String]) -> Result<()> {
        self.mutate(|tx| {
            let mut needs_refresh = false;
            for id in ids {
                let trash_root: Option<Option<String>> = tx.query_row(
                    "SELECT trash_root FROM files WHERE id=?1", [id], |r| r.get(0),
                ).optional()?;
                needs_refresh |= trash_root.is_none()
                    || trash_root.as_ref().and_then(|root| root.as_deref()).is_some_and(|root| root != id);
                tx.execute(
                    "WITH RECURSIVE subtree(id) AS (SELECT ?1 UNION SELECT files.id FROM files JOIN subtree ON files.parent_id=subtree.id)
                     UPDATE files SET trashed=0,trash_root=NULL
                     WHERE id IN (SELECT id FROM subtree) AND (id=?1 OR trash_root=?1 OR trash_root=?2)",
                    params![id,trash_root.flatten()],
                )?;
            }
            // An item restored without known metadata could belong to any
            // cached folder. A targeted remote metadata upsert avoids this.
            if needs_refresh { tx.execute("UPDATE folders SET complete=0", [])?; }
            Ok(())
        })
    }

    /// Update moved top-level entries; descendant parent relationships persist.
    pub fn move_files(&self, ids: &[String], parent_id: &str) -> Result<()> {
        if ids.iter().any(|id| id == parent_id) {
            bail!("Cannot move a cached folder into itself");
        }
        self.mutate(|tx| {
            let mut unknown = false;
            for id in ids {
                unknown |= tx.execute(
                    "UPDATE files SET parent_id=?1 WHERE id=?2",
                    params![parent_id, id],
                )? == 0;
            }
            // Moving an uncached item introduces unknown destination children.
            if unknown {
                invalidate_folder(tx, parent_id)?;
            }
            Ok(())
        })
    }

    /// Keep the visible filename and duplicate-scan paths current.
    pub fn rename_file(&self, id: &str, name: &str) -> Result<()> {
        self.mutate(|tx| {
            tx.execute("UPDATE files SET name=?1 WHERE id=?2", params![name, id])?;
            Ok(())
        })
    }

    /// Find content matches using the duplicate scanner's GCID-first priority.
    /// No fallback to names or size alone is allowed for automatic link saves.
    pub fn find_exact(&self, file: &FileInfo) -> Result<Vec<FileInfo>> {
        if file.kind.is_folder() {
            return Ok(Vec::new());
        }
        let (predicate, digest) = if let Some(digest) = normalized_digest(file.hash.as_deref()) {
            ("gcid=?1", digest)
        } else if let Some(digest) = normalized_digest(file.md5_checksum.as_deref()) {
            ("gcid IS NULL AND md5=?1", digest)
        } else {
            return Ok(Vec::new());
        };
        let db = self.connection()?;
        query_files(&db, &format!("SELECT {FILE_COLUMNS} FROM files WHERE kind=0 AND trashed=0 AND {predicate} AND size=?2 ORDER BY id"),
            params![digest,file.size.to_string()])
    }

    /// Pending task identifiers, for startup or task-poll reconciliation.
    pub fn pending_task_ids(&self) -> Result<Vec<String>> {
        let db = self.connection()?;
        let mut query = db
            .prepare_cached("SELECT DISTINCT task_id FROM pending_task_folders ORDER BY task_id")?;
        let tasks = query
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(tasks)
    }

    /// Background link/upload/extraction tasks keep their destination subtree
    /// incomplete until completion is observed by the task polling API.
    pub fn mark_pending_folder(&self, parent_id: &str, task_id: &str) -> Result<()> {
        if task_id.is_empty() {
            bail!("Missing pending duplicate-cache task ID");
        }
        self.mutate(|tx| {
            tx.execute(
                "INSERT OR IGNORE INTO pending_task_folders(task_id,parent_id) VALUES(?1,?2)",
                params![task_id, parent_id],
            )?;
            invalidate_subtree(tx, parent_id)
        })
    }

    /// Finish task tracking and require one fresh post-completion snapshot.
    pub fn complete_pending_task(&self, task_id: &str) -> Result<()> {
        let mut db = self.connection()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let parents: Vec<String> = {
            let mut query =
                tx.prepare("SELECT parent_id FROM pending_task_folders WHERE task_id=?1")?;
            let parents = query
                .query_map([task_id], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            parents
        };
        let changed = tx.execute(
            "DELETE FROM pending_task_folders WHERE task_id=?1",
            [task_id],
        )?;
        for parent in parents {
            invalidate_subtree(&tx, &parent)?;
        }
        if changed != 0 {
            bump_generation(&tx)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// End unobservable task blockers during an explicit scoped refresh.
    /// Only matching namespaces on this scope's ancestors or descendants are
    /// removed; their snapshots remain invalid until refreshed from PikPak.
    pub fn clear_pending_tasks_in_scope(&self, root_id: &str, prefix: &str) -> Result<()> {
        if prefix.is_empty() {
            bail!("Missing pending-task namespace for duplicate-cache refresh");
        }
        let mut db = self.connection()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let parents: Vec<String> = {
            let mut query = tx.prepare(
                "WITH RECURSIVE
                   descendants(id) AS (SELECT ?1 UNION SELECT files.id FROM files JOIN descendants ON files.parent_id=descendants.id),
                   ancestors(id) AS (SELECT ?1 UNION SELECT '' UNION SELECT files.parent_id FROM files JOIN ancestors ON files.id=ancestors.id)
                 SELECT DISTINCT parent_id FROM pending_task_folders
                 WHERE substr(task_id,1,length(?2))=?2
                   AND (?1='' OR parent_id IN (SELECT id FROM descendants UNION SELECT id FROM ancestors))",
            )?;
            let parents = query
                .query_map(params![root_id, prefix], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            parents
        };
        let mut changed = 0;
        for parent in parents {
            changed += tx.execute(
                "DELETE FROM pending_task_folders WHERE parent_id=?1 AND substr(task_id,1,length(?2))=?2",
                params![parent,prefix],
            )?;
            invalidate_subtree(&tx, &parent)?;
        }
        if changed != 0 {
            bump_generation(&tx)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Remove permanently emptied Trash metadata without invalidating live data.
    pub fn purge_trash(&self) -> Result<()> {
        self.mutate(|tx| {
            tx.execute(
                "DELETE FROM folders WHERE parent_id IN (SELECT id FROM files WHERE trashed=1)",
                [],
            )?;
            tx.execute("DELETE FROM files WHERE trashed=1", [])?;
            Ok(())
        })
    }

    /// Discard all inventory metadata, preserving the mutation generation.
    pub fn clear(&self) -> Result<()> {
        self.mutate(|tx| {
            tx.execute_batch(
                "DELETE FROM files; DELETE FROM folders; DELETE FROM pending_task_folders;",
            )?;
            Ok(())
        })
    }

    fn connection(&self) -> Result<MutexGuard<'_, Connection>> {
        self.db
            .lock()
            .map_err(|_| anyhow::anyhow!("Duplicate metadata cache lock was poisoned"))
    }

    fn mutate(&self, action: impl FnOnce(&Transaction<'_>) -> Result<()>) -> Result<()> {
        let mut db = self.connection()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        action(&tx)?;
        bump_generation(&tx)?;
        tx.commit()?;
        Ok(())
    }
}

fn generation(db: &Connection) -> Result<u64> {
    let value: i64 = db.query_row(
        "SELECT value FROM metadata WHERE key='generation'",
        [],
        |r| r.get(0),
    )?;
    u64::try_from(value).context("Invalid duplicate-cache generation")
}

fn bump_generation(tx: &Transaction<'_>) -> Result<()> {
    tx.execute(
        "UPDATE metadata SET value=value+1 WHERE key='generation'",
        [],
    )?;
    Ok(())
}

fn invalidate_folder(tx: &Transaction<'_>, parent_id: &str) -> Result<()> {
    tx.execute("INSERT INTO folders(parent_id,complete) VALUES(?1,0) ON CONFLICT(parent_id) DO UPDATE SET complete=0", [parent_id])?;
    Ok(())
}

fn invalidate_subtree(tx: &Transaction<'_>, parent_id: &str) -> Result<()> {
    invalidate_folder(tx, parent_id)?;
    if parent_id.is_empty() {
        // The account root also contains subfolder inventories whose ancestry
        // has not yet been fetched into this cache.
        tx.execute("UPDATE folders SET complete=0", [])?;
        return Ok(());
    }
    tx.execute(
        "WITH RECURSIVE subtree(id) AS (SELECT ?1 UNION SELECT files.id FROM files JOIN subtree ON files.parent_id=subtree.id)
         UPDATE folders SET complete=0 WHERE parent_id IN (SELECT id FROM subtree)", [parent_id])?;
    Ok(())
}

fn trash_subtree(tx: &Transaction<'_>, id: &str) -> Result<()> {
    tx.execute(
        "WITH RECURSIVE subtree(id) AS (SELECT ?1 UNION SELECT files.id FROM files JOIN subtree ON files.parent_id=subtree.id)
         UPDATE files SET trashed=1,trash_root=?1 WHERE trashed=0 AND id IN (SELECT id FROM subtree)", [id])?;
    Ok(())
}

fn has_pending_ancestor(db: &Connection, parent_id: &str) -> Result<bool> {
    Ok(db.query_row(
        "WITH RECURSIVE ancestors(id) AS (SELECT ?1 UNION SELECT '' UNION SELECT files.parent_id FROM files JOIN ancestors ON files.id=ancestors.id)
         SELECT EXISTS(SELECT 1 FROM pending_task_folders JOIN ancestors ON pending_task_folders.parent_id=ancestors.id)",
        [parent_id], |r| r.get(0))?)
}

fn upsert(tx: &Transaction<'_>, parent_id: &str, files: &[FileInfo]) -> Result<()> {
    let mut statement = tx.prepare_cached(
        "INSERT INTO files(id,name,size,kind,parent_id,mime_type,created_time,modified_time,file_extension,file_category,gcid,md5)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
         ON CONFLICT(id) DO UPDATE SET
            name=excluded.name,size=excluded.size,kind=excluded.kind,parent_id=excluded.parent_id,
            mime_type=COALESCE(excluded.mime_type,files.mime_type),created_time=COALESCE(excluded.created_time,files.created_time),
            modified_time=COALESCE(excluded.modified_time,files.modified_time),file_extension=COALESCE(excluded.file_extension,files.file_extension),
            file_category=COALESCE(excluded.file_category,files.file_category),
            gcid=COALESCE(excluded.gcid,CASE WHEN files.size=excluded.size THEN files.gcid END),
            md5=COALESCE(excluded.md5,CASE WHEN files.size=excluded.size THEN files.md5 END),trashed=0,trash_root=NULL")?;
    for file in files {
        statement.execute(params![
            file.id,
            file.name,
            file.size.to_string(),
            i64::from(file.kind.is_folder()),
            parent_id,
            file.mime_type,
            file.created_time,
            file.modified_time,
            file.file_extension,
            file.file_category,
            normalized_digest(file.hash.as_deref()),
            normalized_digest(file.md5_checksum.as_deref())
        ])?;
    }
    Ok(())
}

fn normalized_digest(value: Option<&str>) -> Option<String> {
    let digest = value?.trim();
    (!digest.is_empty()).then(|| digest.to_ascii_lowercase())
}

fn query_files(db: &Connection, sql: &str, params: impl rusqlite::Params) -> Result<Vec<FileInfo>> {
    let mut query = db.prepare_cached(sql)?;
    let files = query
        .query_map(params, file_from_row)?
        .collect::<rusqlite::Result<_>>()?;
    Ok(files)
}

fn file_from_row(row: &Row<'_>) -> rusqlite::Result<FileInfo> {
    let size: String = row.get(2)?;
    let size = size.parse().map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(error))
    })?;
    Ok(FileInfo {
        id: row.get(0)?,
        name: row.get(1)?,
        size,
        kind: if row.get::<_, i64>(3)? == 1 {
            FileKind::Folder
        } else {
            FileKind::File
        },
        parent_id: Some(row.get(4)?),
        mime_type: row.get(5)?,
        created_time: row.get(6)?,
        modified_time: row.get(7)?,
        file_extension: row.get(8)?,
        file_category: row.get(9)?,
        hash: row.get(10)?,
        md5_checksum: row.get(11)?,
        icon_link: None,
        thumbnail_link: None,
    })
}

fn private_directory(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path).context("Create duplicate-cache directory")?;
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        bail!("Duplicate-cache directory must not be a symlink");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn private_file(path: &Path) -> Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    let file = options
        .open(path)
        .context("Create private duplicate-cache database")?;
    if !file.metadata()?.is_file() {
        bail!("Duplicate-cache database must be a regular file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(id: &str, hash: Option<&str>, size: u64) -> FileInfo {
        FileInfo {
            id: id.into(),
            name: format!("{id}.bin"),
            size,
            kind: FileKind::File,
            parent_id: None,
            mime_type: None,
            created_time: None,
            modified_time: None,
            file_extension: None,
            icon_link: Some("https://private/icon?token=secret".into()),
            thumbnail_link: Some("https://private/thumb?token=secret".into()),
            file_category: None,
            hash: hash.map(str::to_owned),
            md5_checksum: None,
        }
    }

    fn folder(id: &str) -> FileInfo {
        let mut file = file(id, None, 0);
        file.kind = FileKind::Folder;
        file
    }

    #[test]
    fn partial_and_empty_complete_snapshots_survive_reopen_without_signed_urls() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account-a").unwrap();
        assert!(cache.folder("").unwrap().is_none());
        cache
            .upsert_files("", &[file("a", Some("AA"), u64::MAX)])
            .unwrap();
        assert!(cache.folder("").unwrap().is_none());
        cache
            .replace_folder("", &[file("a", Some("AA"), u64::MAX), folder("empty")])
            .unwrap();
        cache.replace_folder("empty", &[]).unwrap();
        drop(cache);
        let cache = DuplicateCache::open(dir.path(), "account-a").unwrap();
        let files = cache.folder("").unwrap().unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].size, u64::MAX);
        assert_eq!(files[0].hash.as_deref(), Some("aa"));
        assert!(files[0].thumbnail_link.is_none());
        assert!(files[0].icon_link.is_none());
        assert!(cache.folder("empty").unwrap().unwrap().is_empty());
        let bytes = std::fs::read(cache.path()).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("token=secret"));
    }

    #[test]
    fn mutations_preserve_hierarchy_and_trash_undo() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account").unwrap();
        cache
            .replace_folder("", &[folder("one"), folder("two")])
            .unwrap();
        cache
            .replace_folder("one", &[folder("nested"), file("a", Some("hash-a"), 10)])
            .unwrap();
        cache
            .replace_folder(
                "nested",
                &[file("b", Some("hash-b"), 20), file("c", Some("hash-c"), 30)],
            )
            .unwrap();
        cache.replace_folder("two", &[]).unwrap();
        cache.rename_file("a", "renamed.bin").unwrap();
        assert_eq!(cache.folder("one").unwrap().unwrap()[0].name, "renamed.bin");
        cache.move_files(&["nested".into()], "two").unwrap();
        assert_eq!(cache.folder("one").unwrap().unwrap().len(), 1);
        assert_eq!(cache.folder("two").unwrap().unwrap()[0].id, "nested");
        cache.remove(&["c".into()]).unwrap();
        cache.remove(&["two".into()]).unwrap();
        assert!(cache.folder("two").unwrap().is_none());
        assert!(cache
            .find_exact(&file("incoming", Some("hash-b"), 20))
            .unwrap()
            .is_empty());
        cache.untrash(&["two".into()]).unwrap();
        assert_eq!(cache.folder("nested").unwrap().unwrap().len(), 1);
        assert_eq!(
            cache
                .find_exact(&file("incoming", Some("hash-b"), 20))
                .unwrap()[0]
                .id,
            "b"
        );
        assert!(cache
            .find_exact(&file("incoming", Some("hash-c"), 30))
            .unwrap()
            .is_empty());
        cache.untrash(&["c".into()]).unwrap();
        assert_eq!(cache.folder("nested").unwrap().unwrap().len(), 2);
        cache.invalidate_subtree("two").unwrap();
        assert!(cache.folder("two").unwrap().is_none());
        assert!(cache.folder("nested").unwrap().is_none());
        assert!(cache.folder("one").unwrap().is_some());
    }

    #[test]
    fn exact_matches_use_size_normalized_hash_and_gcid_priority() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account").unwrap();
        let mut gcid = file("gcid", Some(" ABC "), 10);
        gcid.md5_checksum = Some("DEF".into());
        let mut md5 = file("md5", Some("  "), 10);
        md5.md5_checksum = Some(" DEF ".into());
        cache
            .replace_folder("", &[gcid, md5, file("different-size", Some("abc"), 11)])
            .unwrap();
        assert_eq!(
            cache.find_exact(&file("new", Some("AbC"), 10)).unwrap()[0].id,
            "gcid"
        );
        let mut incoming = file("new", None, 10);
        incoming.md5_checksum = Some("def".into());
        let matches = cache.find_exact(&incoming).unwrap();
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].id, "md5");
        assert!(cache
            .find_exact(&file("gcid", None, 10))
            .unwrap()
            .is_empty());
        assert!(cache.find_exact(&folder("new")).unwrap().is_empty());
    }

    #[test]
    fn folder_refresh_removes_absent_subtrees_and_preserves_omitted_hashes() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account").unwrap();
        cache
            .replace_folder("", &[folder("gone"), file("kept", Some("hash-k"), 3)])
            .unwrap();
        cache
            .replace_folder("gone", &[file("lost", Some("hash-l"), 4)])
            .unwrap();
        cache.replace_folder("", &[file("kept", None, 3)]).unwrap();
        assert!(cache
            .find_exact(&file("new", Some("hash-l"), 4))
            .unwrap()
            .is_empty());
        assert_eq!(
            cache
                .find_exact(&file("new", Some("hash-k"), 3))
                .unwrap()
                .len(),
            1
        );
        cache.upsert_files("", &[file("kept", None, 5)]).unwrap();
        assert!(cache
            .find_exact(&file("new", Some("hash-k"), 5))
            .unwrap()
            .is_empty());
    }

    #[test]
    fn account_isolation_and_stale_listing_generation() {
        let dir = tempfile::tempdir().unwrap();
        let first = DuplicateCache::open(dir.path(), "one").unwrap();
        let second = DuplicateCache::open(dir.path(), "two").unwrap();
        assert_ne!(first.path(), second.path());
        first
            .replace_folder("", &[file("a", Some("hash"), 10)])
            .unwrap();
        assert!(second.folder("").unwrap().is_none());
        assert!(second
            .find_exact(&file("new", Some("hash"), 10))
            .unwrap()
            .is_empty());
        let generation = first.generation().unwrap();
        let other_handle = DuplicateCache::open(dir.path(), "one").unwrap();
        other_handle.remove(&["a".into()]).unwrap();
        assert!(!first
            .replace_folder_if_generation("", &[file("a", Some("hash"), 10)], generation)
            .unwrap());
        assert!(!first
            .upsert_files_if_generation("", &[file("a", Some("hash"), 10)], generation)
            .unwrap());
        assert!(first.folder("").unwrap().unwrap().is_empty());
        let generation = first.generation().unwrap();
        assert!(first
            .replace_folder_if_generation("", &[], generation)
            .unwrap());
        assert_eq!(first.generation().unwrap(), generation);
    }

    #[test]
    fn pending_tasks_bypass_descendants_until_post_completion_listing() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account").unwrap();
        cache.replace_folder("", &[folder("parent")]).unwrap();
        cache.replace_folder("parent", &[folder("nested")]).unwrap();
        cache.replace_folder("nested", &[]).unwrap();
        cache.mark_pending_folder("parent", "task").unwrap();
        assert!(cache.folder("").unwrap().is_some());
        assert!(cache.folder("parent").unwrap().is_none());
        assert!(cache.folder("nested").unwrap().is_none());
        let generation = cache.generation().unwrap();
        cache
            .replace_folder_if_generation("nested", &[], generation)
            .unwrap();
        assert!(cache.folder("nested").unwrap().is_none());
        cache.complete_pending_task("task").unwrap();
        assert!(!cache
            .replace_folder_if_generation("nested", &[], generation)
            .unwrap());
        assert!(cache.folder("nested").unwrap().is_none());
        cache.replace_folder("nested", &[]).unwrap();
        assert!(cache.folder("nested").unwrap().is_some());
        let generation = cache.generation().unwrap();
        cache.complete_pending_task("unknown").unwrap();
        assert_eq!(cache.generation().unwrap(), generation);
    }

    #[test]
    fn unknown_restores_refresh_inventory_and_empty_trash_preserves_live_files() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account").unwrap();
        cache
            .replace_folder(
                "",
                &[file("live", Some("live-hash"), 10), folder("deleted")],
            )
            .unwrap();
        cache
            .replace_folder("deleted", &[file("child", Some("child-hash"), 20)])
            .unwrap();
        cache.remove(&["deleted".into()]).unwrap();
        cache.untrash(&["child".into()]).unwrap();
        assert_eq!(
            cache
                .find_exact(&file("new", Some("child-hash"), 20))
                .unwrap()
                .len(),
            1
        );
        assert!(cache.folder("").unwrap().is_none());
        cache
            .replace_folder("", &[file("live", Some("live-hash"), 10)])
            .unwrap();
        cache.purge_trash().unwrap();
        assert_eq!(cache.folder("").unwrap().unwrap().len(), 1);
        assert_eq!(
            cache
                .find_exact(&file("new", Some("live-hash"), 10))
                .unwrap()
                .len(),
            1
        );
        cache.untrash(&["uncached-restore".into()]).unwrap();
        assert!(cache.folder("").unwrap().is_none());
    }

    #[test]
    fn explicit_refresh_clears_only_scoped_share_restore_blockers() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account").unwrap();
        cache
            .replace_folder("", &[folder("a"), folder("b")])
            .unwrap();
        cache.replace_folder("a", &[folder("a-child")]).unwrap();
        cache.replace_folder("a-child", &[]).unwrap();
        cache.replace_folder("b", &[folder("b-child")]).unwrap();
        cache.replace_folder("b-child", &[]).unwrap();
        cache
            .mark_pending_folder("a", "share-restore:a-task")
            .unwrap();
        cache
            .mark_pending_folder("b-child", "share-restore:b-task")
            .unwrap();
        cache.mark_pending_folder("a-child", "upload-task").unwrap();
        cache.mark_pending_folder("b", "offline-task").unwrap();
        let old_generation = cache.generation().unwrap();

        // A selected subfolder can clear its ancestor's shared-restore marker.
        cache
            .clear_pending_tasks_in_scope("a-child", "share-restore:")
            .unwrap();
        assert_eq!(
            cache.pending_task_ids().unwrap(),
            ["offline-task", "share-restore:b-task", "upload-task"]
        );
        assert_eq!(cache.generation().unwrap(), old_generation + 1);
        assert!(cache.folder("a").unwrap().is_none());
        cache.replace_folder("a", &[folder("a-child")]).unwrap();
        assert!(cache.folder("a").unwrap().is_some());
        cache.replace_folder("a-child", &[]).unwrap();
        assert!(cache.folder("a-child").unwrap().is_none());
        cache
            .mark_pending_folder("a-child", "share-restore:a-descendant-task")
            .unwrap();
        cache
            .clear_pending_tasks_in_scope("a", "share-restore:")
            .unwrap();
        assert_eq!(
            cache.pending_task_ids().unwrap(),
            ["offline-task", "share-restore:b-task", "upload-task"]
        );

        // Account-root refresh covers other shared destinations, but active
        // upload and offline work remain blockers until observed completion.
        cache
            .clear_pending_tasks_in_scope("", "share-restore:")
            .unwrap();
        assert_eq!(
            cache.pending_task_ids().unwrap(),
            ["offline-task", "upload-task"]
        );
        assert!(cache.folder("b-child").unwrap().is_none());
        cache.replace_folder("b-child", &[]).unwrap();
        assert!(cache.folder("b-child").unwrap().is_none());
        let generation = cache.generation().unwrap();
        cache
            .clear_pending_tasks_in_scope("", "share-restore:")
            .unwrap();
        assert_eq!(cache.generation().unwrap(), generation);

        // Account-root markers also apply to scopes whose parent metadata has
        // not yet been fetched. A scoped manual refresh can clear that ancestor.
        cache
            .mark_pending_folder("", "share-restore:unknown-destination")
            .unwrap();
        cache.replace_folder("uncached-root", &[]).unwrap();
        assert!(cache.folder("uncached-root").unwrap().is_none());
        cache
            .clear_pending_tasks_in_scope("uncached-root", "share-restore:")
            .unwrap();
        assert_eq!(
            cache.pending_task_ids().unwrap(),
            ["offline-task", "upload-task"]
        );
        assert!(cache.folder("uncached-root").unwrap().is_none());
        cache.replace_folder("uncached-root", &[]).unwrap();
        assert!(cache.folder("uncached-root").unwrap().is_some());
    }

    #[test]
    fn concurrent_handles_preserve_each_others_changes() {
        let dir = tempfile::tempdir().unwrap();
        let cache = DuplicateCache::open(dir.path(), "account").unwrap();
        let workers = (0..4)
            .map(|worker| {
                let directory = dir.path().to_path_buf();
                std::thread::spawn(move || {
                    let cache = DuplicateCache::open(&directory, "account").unwrap();
                    for index in 0..20 {
                        cache
                            .upsert_files(
                                "",
                                &[file(&format!("{worker}-{index}"), Some("same"), 1)],
                            )
                            .unwrap();
                    }
                })
            })
            .collect::<Vec<_>>();
        for worker in workers {
            worker.join().unwrap();
        }
        assert_eq!(
            cache
                .find_exact(&file("incoming", Some("same"), 1))
                .unwrap()
                .len(),
            80
        );
        assert_eq!(cache.generation().unwrap(), 80);
    }

    #[cfg(unix)]
    #[test]
    fn database_and_directory_are_private_and_symlinks_rejected() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().join("cache");
        let cache = DuplicateCache::open(&directory, "account").unwrap();
        assert_eq!(
            std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(cache.path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let path = cache.path().to_owned();
        drop(cache);
        std::fs::remove_file(&path).unwrap();
        symlink(temp.path().join("target"), &path).unwrap();
        assert!(DuplicateCache::open(&directory, "account").is_err());
        let alias = temp.path().join("alias");
        symlink(&directory, &alias).unwrap();
        assert!(DuplicateCache::open(&alias, "account").is_err());
    }
}

//! Durable derived-data checkpoints. Original bytes and credentials never enter this store.
use super::*;
use filetwin_core::api::{Counts, FileRecord, FileState};
use rusqlite::{params, Connection, OptionalExtension};
use std::{
    fs::{File, OpenOptions},
    io::Read,
    os::unix::fs::OpenOptionsExt,
    sync::{atomic::AtomicU64, Mutex},
};

pub(super) fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

pub(super) struct Checkpoint {
    db: Mutex<Connection>,
    _lock: File,
    pub directory: PathBuf,
    newly_analysed: AtomicU64,
    reused_files: AtomicU64,
}
impl Drop for Checkpoint {
    fn drop(&mut self) {
        // A concurrently forked native worker may briefly inherit the file
        // description before exec closes it. Release ownership explicitly so
        // closing a scan never leaves a phantom owner during that interval.
        let _ = rustix::fs::flock(&self._lock, rustix::fs::FlockOperation::Unlock);
    }
}
#[derive(Serialize, Deserialize)]
pub(super) struct Sealed {
    pub files: Vec<scope::InputFile>,
    pub counts: Counts,
    pub report: ScanReport,
}
#[derive(Serialize, Deserialize)]
struct SealedSummary {
    counts: Counts,
    report: ScanReport,
    file_count: u64,
}
fn packed(value: &impl Serialize) -> Result<Vec<u8>> {
    Ok(zstd::stream::encode_all(
        serde_json::to_vec(value)?.as_slice(),
        6,
    )?)
}
fn unpacked<T: serde::de::DeserializeOwned>(bytes: &[u8], maximum: u64) -> Result<T> {
    let mut data = Vec::new();
    zstd::stream::read::Decoder::new(bytes)?
        .take(maximum + 1)
        .read_to_end(&mut data)?;
    if data.len() as u64 > maximum {
        bail!("The scan checkpoint is too large.");
    }
    Ok(serde_json::from_slice(&data)?)
}
fn origin(record: &FileRecord) -> (u32, u32, bool) {
    let finished = matches!(record.state, FileState::Ready | FileState::Unsupported);
    (
        u32::from(record.state == FileState::Ready && record.vector.is_some() && !record.reused),
        u32::from(finished && record.reused),
        finished,
    )
}
impl Checkpoint {
    pub fn open(request: &ScanRequest) -> Result<Option<Arc<Self>>> {
        let Some(id) = &request.checkpoint_id else {
            return Ok(None);
        };
        if !valid_id(id) {
            bail!("Invalid scan checkpoint identifier.");
        }
        let directory = request.data_dir.join("checkpoints").join(id);
        private_dir(&directory)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(directory.join("owner.lock"))?;
        rustix::fs::flock(&lock, rustix::fs::FlockOperation::NonBlockingLockExclusive)
            .context("This scan is already running in another window.")?;
        let path = directory.join("checkpoint.sqlite3");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&path)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        let mut db = Connection::open(path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value BLOB);
            CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY, revision TEXT, payload BLOB);
            CREATE TABLE IF NOT EXISTS sealed_files(ordinal INTEGER PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS origins(id TEXT PRIMARY KEY, revision TEXT, newly INTEGER NOT NULL,
                reused INTEGER NOT NULL, finished INTEGER NOT NULL);")?;
        db.execute("INSERT OR IGNORE INTO metadata VALUES('source_cache_generation',0)", [])?;
        // Runtime paths and credentials are deliberately excluded. Account and
        // drive isolation comes from the host's private data directory.
        let identity =
            serde_json::to_vec(&json!({"source":request.source,"paths":request.local_paths,
            "roots":request.cloud_items.iter().map(|f| &f.id).collect::<Vec<_>>(),
            "families":request.families,"exact":request.exact_duplicates}))?;
        let previous: Option<Vec<u8>> = db
            .query_row("SELECT value FROM metadata WHERE key='scope'", [], |r| {
                r.get(0)
            })
            .optional()?;
        if previous.as_ref().is_some_and(|v| v != &identity) {
            bail!("This checkpoint belongs to a different scan scope.");
        }
        db.execute(
            "INSERT OR IGNORE INTO metadata VALUES('scope',?1)",
            [identity],
        )?;
        // Checkpoints created before acceleration contain CPU vectors. Never
        // silently combine those with a newly selected visual backend.
        let has_work: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM files) OR EXISTS(SELECT 1 FROM metadata WHERE key IN ('sealed','sealed_v2'))",[],|r|r.get(0))?;
        if has_work {
            db.execute(
                "INSERT OR IGNORE INTO metadata VALUES('backend',?1)",
                [serde_json::to_vec(&filetwin_core::profile::Backend::Cpu)?],
            )?;
        }
        // Preserve whether this session originally analysed or reused a file.
        // Replaying its checkpoint must not turn all new work into cache hits.
        let tx = db.transaction()?;
        let missing = {
            let mut query = tx.prepare(
                "SELECT files.id,files.revision,files.payload FROM files
                LEFT JOIN origins USING(id) WHERE origins.id IS NULL",
            )?;
            let rows = query
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Vec<u8>>(2)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };
        for (id, revision, payload) in missing {
            let values = unpacked::<scope::InputFile>(&payload, 4 << 20)
                .ok()
                .and_then(|file| file.record.map(|record| origin(&record)))
                .unwrap_or_default();
            tx.execute(
                "INSERT INTO origins VALUES(?1,?2,?3,?4,?5)",
                params![id, revision, values.0, values.1, values.2],
            )?;
        }
        tx.commit()?;
        let (newly, reused): (i64, i64) = db.query_row(
            "SELECT coalesce(sum(newly),0),coalesce(sum(reused),0) FROM origins",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok(Some(Arc::new(Self {
            db: Mutex::new(db),
            _lock: lock,
            directory,
            newly_analysed: AtomicU64::new(newly.try_into()?),
            reused_files: AtomicU64::new(reused.try_into()?),
        })))
    }
    pub fn backend(&self) -> Result<Option<filetwin_core::profile::Backend>> {
        let value: Option<Vec<u8>> = self
            .db
            .lock()
            .unwrap()
            .query_row("SELECT value FROM metadata WHERE key='backend'", [], |r| {
                r.get(0)
            })
            .optional()?;
        value
            .map(|v| serde_json::from_slice(&v).map_err(Into::into))
            .transpose()
    }
    pub fn pin_backend(&self, backend: filetwin_core::profile::Backend) -> Result<()> {
        if self.backend()?.is_some_and(|saved| saved != backend) {
            bail!("Resume requires this scan's original encoding backend.");
        }
        self.db.lock().unwrap().execute(
            "INSERT OR IGNORE INTO metadata VALUES('backend',?1)",
            [serde_json::to_vec(&backend)?],
        )?;
        Ok(())
    }
    pub fn reused(&self, file: &scope::InputFile) -> Result<Option<FileRecord>> {
        let Some(revision) = file.checkpoint_revision() else {
            return Ok(None);
        };
        let bytes: Option<Vec<u8>> = self
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT payload FROM files WHERE id=?1 AND revision=?2",
                params![file.display.id, revision],
                |r| r.get(0),
            )
            .optional()?;
        let Some(bytes) = bytes else {
            return Ok(None);
        };
        let saved: scope::InputFile = unpacked(&bytes, 4 << 20)?;
        let backend = self
            .backend()?
            .unwrap_or(filetwin_core::profile::Backend::Cpu);
        Ok(saved
            .record
            .filter(|record| {
                record.state == FileState::Ready
                    && record
                        .profile_id
                        .as_ref()
                        .is_none_or(|id| filetwin_core::profile::find(id).is_ok())
                    && (!matches!(record.family.as_deref(), Some("image" | "video"))
                        || record.profile_id.as_ref().is_some_and(|id| {
                            filetwin_core::profile::inference_backend(id).ok() == Some(backend)
                        }))
            })
            .map(|mut record| {
                record.reused = true;
                record
            }))
    }
    pub fn completed(&self, file: &scope::InputFile, record: &FileRecord) -> Result<()> {
        let mut saved = file.clone();
        saved.record = Some(record.clone());
        let revision = file.checkpoint_revision();
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let previous: Option<(Option<String>, u32, u32, bool)> = tx
            .query_row(
                "SELECT revision,newly,reused,finished FROM origins WHERE id=?1",
                [&file.display.id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let values = match &previous {
            Some((old, newly, reused, true))
                if record.reused && revision.is_some() && old == &revision =>
            {
                (*newly, *reused, true)
            }
            _ => origin(record),
        };
        tx.execute(
            "INSERT OR REPLACE INTO files VALUES(?1,?2,?3)",
            params![file.display.id, revision, packed(&saved)?],
        )?;
        tx.execute(
            "INSERT OR REPLACE INTO origins VALUES(?1,?2,?3,?4,?5)",
            params![file.display.id, revision, values.0, values.1, values.2],
        )?;
        tx.execute("UPDATE metadata SET value=CAST(value AS INTEGER)+1 WHERE key='source_cache_generation'", [])?;
        tx.commit()?;
        let old = previous
            .map(|(_, newly, reused, _)| (newly, reused))
            .unwrap_or_default();
        self.newly_analysed.store(
            self.newly_analysed.load(Ordering::Relaxed) - u64::from(old.0) + u64::from(values.0),
            Ordering::Release,
        );
        self.reused_files.store(
            self.reused_files.load(Ordering::Relaxed) - u64::from(old.1) + u64::from(values.1),
            Ordering::Release,
        );
        Ok(())
    }
    pub fn statistics(&self) -> Value {
        json!({"newly_analysed":self.newly_analysed.load(Ordering::Acquire),"reused":self.reused_files.load(Ordering::Acquire)})
    }
    /// Ordinals and vectors may change after reconciliation. A fresh matrix
    /// prevents old pairs from being assigned to a different set of files.
    pub fn invalidate_inventory(&self) -> Result<()> {
        let mut random = [0; 16];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut random)
            .map_err(|_| anyhow::anyhow!("Could not create a comparison checkpoint"))?;
        let hex = hex::encode(random);
        let generation = format!(
            "{}-{}-{}-{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..]
        );
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        tx.execute(
            "INSERT OR REPLACE INTO metadata VALUES('comparison_directory',?1)",
            [generation],
        )?;
        tx.execute(
            "DELETE FROM metadata WHERE key IN ('sealed','sealed_v2')",
            [],
        )?;
        tx.execute("DELETE FROM sealed_files", [])?;
        tx.commit()?;
        Ok(())
    }
    pub fn seal(
        &self,
        files: &[scope::InputFile],
        counts: &Counts,
        report: &ScanReport,
    ) -> Result<()> {
        // One row per file avoids a giant JSON buffer and the old 256 MiB
        // aggregate decode ceiling. Individual records remain bounded.
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        tx.execute_batch("CREATE TEMP TABLE IF NOT EXISTS current_files(id TEXT PRIMARY KEY); DELETE FROM current_files;")?;
        {
            let mut insert = tx.prepare("INSERT INTO current_files VALUES(?1)")?;
            for file in files {
                insert.execute([&file.display.id])?;
            }
        }
        tx.execute(
            "DELETE FROM origins WHERE id NOT IN (SELECT id FROM current_files)",
            [],
        )?;
        tx.execute(
            "DELETE FROM files WHERE id NOT IN (SELECT id FROM current_files)",
            [],
        )?;
        tx.execute("DELETE FROM sealed_files", [])?;
        {
            let mut insert = tx.prepare("INSERT INTO sealed_files VALUES(?1,?2)")?;
            for (i, file) in files.iter().enumerate() {
                insert.execute(params![i as i64, packed(file)?])?;
            }
        }
        let summary = SealedSummary {
            counts: counts.clone(),
            report: report.clone(),
            file_count: files.len() as u64,
        };
        tx.execute(
            "INSERT OR REPLACE INTO metadata VALUES('sealed_v2',?1)",
            [packed(&summary)?],
        )?;
        tx.execute("DELETE FROM metadata WHERE key='sealed'", [])?;
        let (newly, reused): (i64, i64) = tx.query_row(
            "SELECT coalesce(sum(newly),0),coalesce(sum(reused),0) FROM origins",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        tx.commit()?;
        self.newly_analysed
            .store(newly.try_into()?, Ordering::Release);
        self.reused_files
            .store(reused.try_into()?, Ordering::Release);
        Ok(())
    }
    pub fn sealed(&self) -> Result<Option<Sealed>> {
        let mut db = self.db.lock().unwrap();
        let summary: Option<Vec<u8>> = db
            .query_row(
                "SELECT value FROM metadata WHERE key='sealed_v2'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(summary) = summary {
            let summary: SealedSummary = unpacked(&summary, 64 << 20)?;
            let mut query =
                db.prepare("SELECT ordinal,payload FROM sealed_files ORDER BY ordinal")?;
            let mut rows = query.query([])?;
            let mut files = Vec::new();
            while let Some(row) = rows.next()? {
                if row.get::<_, i64>(0)? != files.len() as i64 {
                    bail!("The saved scan inventory is incomplete.");
                }
                files.push(unpacked::<scope::InputFile>(
                    &row.get::<_, Vec<u8>>(1)?,
                    4 << 20,
                )?);
            }
            if files.len() as u64 != summary.file_count {
                bail!("The saved scan inventory is incomplete.");
            }
            return Ok(Some(Sealed {
                files,
                counts: summary.counts,
                report: summary.report,
            }));
        }
        let bytes: Option<Vec<u8>> = db
            .query_row("SELECT value FROM metadata WHERE key='sealed'", [], |r| {
                r.get(0)
            })
            .optional()?;
        let Some(bytes) = bytes else {
            return Ok(None);
        };
        let saved: Sealed = unpacked(&bytes, 256 << 20)?;
        if saved.report.scanned_files >= 100_000
            || saved.files.len() >= 100_000
            || saved.report.issues.iter().any(|issue| {
                issue.reason.contains("100,000-file limit")
                    || issue.reason.contains("listing limit")
            })
        {
            // A formerly capped inventory must be rediscovered. Preserve its
            // file journal and old comparison snapshot, but give the expanded
            // inventory a separate matrix so ordinal-based scores cannot mix.
            let mut random = [0; 16];
            ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut random)
                .map_err(|_| anyhow::anyhow!("Could not create a comparison checkpoint"))?;
            let hex = hex::encode(random);
            let generation = format!(
                "{}-{}-{}-{}-{}",
                &hex[..8],
                &hex[8..12],
                &hex[12..16],
                &hex[16..20],
                &hex[20..]
            );
            let tx = db.transaction()?;
            tx.execute(
                "INSERT OR REPLACE INTO metadata VALUES('comparison_directory',?1)",
                [generation],
            )?;
            tx.execute("DELETE FROM metadata WHERE key='sealed'", [])?;
            tx.commit()?;
            return Ok(None);
        }
        Ok(Some(saved))
    }
    pub fn comparison_directory(&self) -> Result<PathBuf> {
        let generation: Option<String> = self
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT value FROM metadata WHERE key='comparison_directory'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        match generation {
            Some(generation) if valid_id(&generation) => {
                let path = self.directory.join(generation);
                private_dir(&path)?;
                Ok(path)
            }
            Some(_) => bail!("Invalid comparison checkpoint identifier."),
            None => Ok(self.directory.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn report() -> ScanReport {
        serde_json::from_value(json!({"source":"cloud","scope":[],"status":"running","threshold":0.9,
            "scanned_files":0,"analysed_files":0,"skipped_files":0,"downloaded_bytes":0,"total_groups":0,"groups":[],
            "issues":[],"files":[],"scores_retained":0,"truncated":false,"coverage":"","elapsed_seconds":0.0})).unwrap()
    }
    #[test]
    fn large_sealed_inventory_reopens_past_file_and_aggregate_json_limits() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = Checkpoint::open(&request).unwrap().unwrap();
        let files: Vec<_> = (0..100_137)
            .map(|i| {
                scope::InputFile::cloud(CloudItem {
                    id: format!("file-{i}"),
                    name: format!("{i}.txt"),
                    path: format!("/{}/{i}.txt", "folder".repeat(250)),
                    is_folder: false,
                    size: 1,
                    ancestors: vec![],
                    revision: Some("revision".into()),
                })
            })
            .collect();
        assert!(serde_json::to_vec(&files[0]).unwrap().len() * files.len() > 256 << 20);
        let record = FileRecord {
            path: filetwin_core::api::FilePath::Utf8("fixture.txt".into()),
            file_id: None,
            bytes: Some(1),
            state: FileState::Ready,
            family: Some("text".into()),
            profile_id: None,
            vector: Some(vec![1.0]),
            vector_sha256: None,
            reused: false,
            error: None,
            extraction: None,
        };
        checkpoint
            .completed(files.last().unwrap(), &record)
            .unwrap();
        let mut summary = report();
        summary.scanned_files = files.len() as u64;
        checkpoint
            .seal(&files, &Counts::default(), &summary)
            .unwrap();
        let first = files[0].display.id.clone();
        let last = files.last().unwrap().clone();
        drop(files);
        drop(checkpoint);
        let checkpoint = Checkpoint::open(&request).unwrap().unwrap();
        let saved = checkpoint.sealed().unwrap().unwrap();
        assert_eq!(saved.files.len(), 100_137);
        assert_eq!(saved.files[0].display.id, first);
        assert_eq!(saved.files.last().unwrap().display.id, last.display.id);
        assert!(
            checkpoint.reused(&last).unwrap().unwrap().reused,
            "Completed work beyond the old cap must reuse without an original"
        );
        checkpoint
            .db
            .lock()
            .unwrap()
            .execute("DELETE FROM sealed_files WHERE ordinal=100000", [])
            .unwrap();
        assert!(
            checkpoint.sealed().is_err(),
            "Missing inventory rows must not appear as complete recovery"
        );
    }
    #[test]
    fn legacy_capped_inventory_is_rediscovered_with_separate_comparisons() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = Checkpoint::open(&request).unwrap().unwrap();
        let mut summary = report();
        summary.scanned_files = 100_000;
        let legacy = Sealed {
            files: vec![],
            counts: Counts::default(),
            report: summary,
        };
        checkpoint
            .db
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO metadata VALUES('sealed',?1)",
                [packed(&legacy).unwrap()],
            )
            .unwrap();
        let original = checkpoint.comparison_directory().unwrap();
        std::fs::write(
            original.join("matrix.sqlite3"),
            b"old comparison checkpoint",
        )
        .unwrap();
        assert!(checkpoint.sealed().unwrap().is_none());
        let next = checkpoint.comparison_directory().unwrap();
        assert_ne!(next, original);
        assert!(next.is_dir());
        assert_eq!(
            std::fs::read(original.join("matrix.sqlite3")).unwrap(),
            b"old comparison checkpoint"
        );
        drop(checkpoint);
        let checkpoint = Checkpoint::open(&request).unwrap().unwrap();
        assert!(checkpoint.sealed().unwrap().is_none());
        assert_eq!(checkpoint.comparison_directory().unwrap(), next);
        checkpoint.seal(&[], &Counts::default(), &report()).unwrap();
        assert!(checkpoint.sealed().unwrap().is_some());
    }
    #[test]
    fn completed_records_survive_reopen_and_changed_files_are_reanalysed() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let path = root.path().canonicalize().unwrap().join("original.txt");
        std::fs::write(&path, "first").unwrap();
        let file = scope::InputFile::external(ExternalSource {
            provider: None,
            content_kind: None,
            id: "local:test".into(),
            name: "original.txt".into(),
            path: path.display().to_string(),
            size: 5,
            local_path: Some(path.clone()),
            revision: None,
        });
        let record = FileRecord {
            path: filetwin_core::api::FilePath::Utf8("0.txt".into()),
            file_id: Some("digest".into()),
            bytes: Some(5),
            state: FileState::Ready,
            family: Some("text".into()),
            profile_id: None,
            vector: Some(vec![0.1, -0.2, 0.3]),
            vector_sha256: None,
            reused: false,
            error: None,
            extraction: None,
        };
        let checkpoint = Checkpoint::open(&request).unwrap().unwrap();
        checkpoint.completed(&file, &record).unwrap();
        assert_eq!(
            checkpoint.statistics(),
            json!({"newly_analysed":1,"reused":0})
        );
        let database = checkpoint.directory.join("checkpoint.sqlite3");
        drop(checkpoint);
        // An older checkpoint has the records but no origin journal yet.
        Connection::open(&database)
            .unwrap()
            .execute("DROP TABLE origins", [])
            .unwrap();
        let checkpoint = Checkpoint::open(&request).unwrap().unwrap();
        let reused = checkpoint.reused(&file).unwrap().unwrap();
        assert!(reused.reused);
        assert_eq!(reused.vector, record.vector);
        checkpoint.completed(&file, &reused).unwrap();
        assert_eq!(
            checkpoint.statistics(),
            json!({"newly_analysed":1,"reused":0}),
            "Checkpoint replay must not relabel this session's new analysis as reused"
        );
        drop(checkpoint);
        let checkpoint = Checkpoint::open(&request).unwrap().unwrap();
        assert_eq!(
            checkpoint.statistics(),
            json!({"newly_analysed":1,"reused":0}),
            "Origin survives multiple helper launches"
        );
        let mut alias = file.clone();
        alias.external.as_mut().unwrap().local_path = Some(PathBuf::from(
            path.to_string_lossy()
                .strip_prefix("/private")
                .unwrap_or(&path.to_string_lossy()),
        ));
        assert!(
            checkpoint.reused(&alias).unwrap().is_some(),
            "macOS /var and /private/var aliases use the same revision"
        );
        std::fs::write(&path, "changed original").unwrap();
        assert!(checkpoint.reused(&file).unwrap().is_none());
        let mut failed = record;
        failed.state = FileState::Failed;
        checkpoint.completed(&file, &failed).unwrap();
        assert!(
            checkpoint.reused(&file).unwrap().is_none(),
            "An interrupted/failed file must be tried again"
        );
    }
    #[test]
    fn checkpoint_is_private_exclusive_and_scope_bound() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let first = Checkpoint::open(&request).unwrap().unwrap();
        assert!(Checkpoint::open(&request).is_err());
        assert_eq!(
            std::fs::metadata(first.directory.join("checkpoint.sqlite3"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        drop(first);
        assert!(Checkpoint::open(&request).is_ok());
        request.families = vec!["audio".into()];
        assert!(Checkpoint::open(&request).is_err());
        assert!(!valid_id("../../private"));
    }
}

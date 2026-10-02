//! Immutable, app-owned comparison snapshots. FileTwin 0.2 returns vectors;
//! it no longer owns a catalog. Old 0.1 catalogs remain readable and untouched.
use super::*;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};

pub(super) struct AxisFile {
    pub id: String,
    pub digest: Option<String>,
    pub family: Option<String>,
    pub profile: Option<String>,
    pub available: bool,
    pub is_file: bool,
    pub sources: Vec<String>,
}

pub(super) struct SavedMatrix {
    db: Connection,
    run: String,
    revision: u64,
    legacy: bool,
    within_source: bool,
    pub files: Vec<AxisFile>,
}

impl SavedMatrix {
    pub fn open(directory: &Path, run: &str, revision: u64) -> Result<Self> {
        if !directory.is_absolute() || revision == 0 || revision > i64::MAX as u64 {
            bail!("Choose a saved scan revision.");
        }
        let legacy = !run.starts_with("mcd2-");
        let path = if legacy {
            directory.join("index.sqlite3")
        } else {
            if run.len() != 37 || !run[5..].bytes().all(|b| b.is_ascii_hexdigit()) {
                bail!("Invalid saved scan identifier.");
            }
            directory.join("runs").join(format!("{run}.sqlite3"))
        };
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let mut files = Vec::new();
        let mut within_source = false;
        if legacy {
            let snapshot: Option<String> = db.query_row(
                "SELECT r.snapshot_id FROM runs r JOIN publications p ON p.run_id=r.id WHERE r.id=?1 AND p.revision=?2",
                params![run, revision as i64], |r| r.get(0)).optional()?;
            let snapshot = snapshot.context("This saved scan revision is unavailable.")?;
            let request: String = db.query_row(
                "SELECT request FROM snapshots WHERE id=?1",
                [&snapshot],
                |r| r.get(0),
            )?;
            within_source =
                serde_json::from_str::<Value>(&request)?["pair_scope"] == "within_each_source";
            let mut query = db.prepare("SELECT payload,vector_id,sources FROM snapshot_files WHERE snapshot_id=?1 ORDER BY ordinal")?;
            let rows = query.query_map([snapshot], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?;
            for row in rows {
                let (payload, vector, sources) = row?;
                let value: Value = serde_json::from_str(&payload)?;
                files.push(AxisFile {
                    id: value["file_id"]
                        .as_str()
                        .context("Missing saved file identifier")?
                        .into(),
                    digest: value["sha256"].as_str().map(str::to_owned),
                    family: value["family"].as_str().map(str::to_owned),
                    profile: value["profile_id"].as_str().map(str::to_owned),
                    available: vector.is_some(),
                    is_file: !value["bytes"].is_null(),
                    sources: serde_json::from_str(&sources)?,
                });
            }
        } else {
            let valid: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM run WHERE id=?1 AND revision=?2)",
                params![run, revision as i64],
                |r| r.get(0),
            )?;
            if !valid {
                bail!("This saved scan revision is unavailable.");
            }
            let mut query = db
                .prepare("SELECT id,digest,family,profile,available FROM files ORDER BY ordinal")?;
            let rows = query.query_map([], |r| {
                Ok(AxisFile {
                    id: r.get(0)?,
                    digest: r.get(1)?,
                    family: r.get(2)?,
                    profile: r.get(3)?,
                    available: r.get(4)?,
                    is_file: true,
                    sources: vec![],
                })
            })?;
            for row in rows {
                files.push(row?);
            }
        }
        Ok(Self {
            db,
            run: run.into(),
            revision,
            legacy,
            within_source,
            files,
        })
    }

    pub fn visit_scores(
        &self,
        minimum: f64,
        cancel: &AtomicBool,
        mut visit: impl FnMut(&str, &str, f64) -> Result<()>,
    ) -> Result<()> {
        if self.legacy {
            let mut query = self.db.prepare(
                "SELECT payload FROM records WHERE owner=?1 AND revision=?2 AND kind='scores'",
            )?;
            let mut rows = query.query(params![self.run, self.revision as i64])?;
            while let Some(row) = rows.next()? {
                check_cancel(cancel)?;
                let pair: Value = serde_json::from_str(&row.get::<_, String>(0)?)?;
                let score = pair["score"].as_f64().context("Missing saved score")?;
                if score >= minimum {
                    visit(
                        pair["file_a"].as_str().context("Missing comparison file")?,
                        pair["file_b"].as_str().context("Missing comparison file")?,
                        score,
                    )?;
                }
            }
        } else {
            let mut query = self
                .db
                .prepare("SELECT a,b,score FROM scores WHERE score>=?1")?;
            let mut rows = query.query([minimum])?;
            while let Some(row) = rows.next()? {
                check_cancel(cancel)?;
                let a = row.get::<_, u32>(0)? as usize;
                let b = row.get::<_, u32>(1)? as usize;
                let left = self.files.get(a).context("Invalid saved matrix axis")?;
                let right = self.files.get(b).context("Invalid saved matrix axis")?;
                visit(&left.id, &right.id, row.get(2)?)?;
            }
        }
        Ok(())
    }

    pub fn row(&self, request: &ScoreRowRequest, cancel: &AtomicBool) -> Result<Value> {
        let file = self
            .files
            .get(request.row_offset as usize)
            .filter(|f| f.id == request.file_id)
            .context(
                "This file no longer belongs to the selected scan revision. Run a new scan.",
            )?;
        let mut scores = HashMap::new();
        if self.legacy {
            self.visit_scores(-1.0, cancel, |a, b, score| {
                if a == file.id {
                    scores.insert(b.to_owned(), score);
                } else if b == file.id {
                    scores.insert(a.to_owned(), score);
                }
                Ok(())
            })?;
        } else {
            let mut query = self.db.prepare("SELECT b,score FROM scores WHERE a=?1 UNION ALL SELECT a,score FROM scores WHERE b=?1")?;
            let mut rows = query.query([i64::try_from(request.row_offset)?])?;
            while let Some(row) = rows.next()? {
                check_cancel(cancel)?;
                let other = self
                    .files
                    .get(row.get::<_, u32>(0)? as usize)
                    .context("Invalid saved matrix axis")?;
                scores.insert(other.id.clone(), row.get::<_, f64>(1)?);
            }
        }
        let mut entries = Vec::new();
        let mut unavailable = std::collections::BTreeMap::<&str, u64>::new();
        for other in &self.files {
            check_cancel(cancel)?;
            if other.id == file.id {
                continue;
            }
            if let Some(score) = scores.get(&other.id) {
                if !score.is_finite() || !(-1.0..=1.0).contains(score) {
                    bail!("A saved similarity score is invalid.");
                }
                entries.push(json!({"file_id":other.id,"score":score}));
            } else {
                let reason = if !file.available || !other.available {
                    "file_unavailable"
                } else if file.profile != other.profile || file.family != other.family {
                    "incompatible_profile"
                } else if self.within_source
                    && !file.sources.iter().any(|s| other.sources.contains(s))
                {
                    "outside_scope"
                } else {
                    "not_computed"
                };
                *unavailable.entry(reason).or_default() += 1;
            }
        }
        Ok(json!({"file_id":file.id,"entries":entries,"unavailable":unavailable,"omitted":0}))
    }
}

/// Construct privately and publish with one atomic rename only after all rows
/// and the retained comparisons are durable. Readers never see a half-written run.
pub(super) struct MatrixWriter {
    db: Connection,
    temporary: Option<tempfile::NamedTempFile>,
    working: Option<PathBuf>,
    destination: PathBuf,
    pub id: String,
}
impl MatrixWriter {
    pub fn new(directory: &Path) -> Result<Self> {
        let runs = directory.join("runs");
        private_dir(&runs)?;
        let mut random = [0u8; 16];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut random)
            .map_err(|_| anyhow::anyhow!("Could not create a scan identifier"))?;
        let id = format!("mcd2-{}", hex::encode(random));
        let temporary = tempfile::NamedTempFile::new_in(&runs)?;
        let db = Connection::open(temporary.path())?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
            CREATE TABLE run(id TEXT PRIMARY KEY,revision INTEGER,summary TEXT);
            CREATE TABLE files(ordinal INTEGER PRIMARY KEY,id TEXT UNIQUE,digest TEXT,family TEXT,profile TEXT,available INTEGER,payload TEXT,extraction TEXT,diagnostic TEXT);
            CREATE TABLE scores(a INTEGER,b INTEGER,score REAL,PRIMARY KEY(a,b)) WITHOUT ROWID;
            BEGIN IMMEDIATE;")?;
        Ok(Self {
            destination: runs.join(format!("{id}.sqlite3")),
            db,
            temporary: Some(temporary),
            working: None,
            id,
        })
    }
    pub fn resume(directory: &Path, checkpoint: &Path) -> Result<Self> {
        use std::os::unix::fs::OpenOptionsExt;
        let id = checkpoint.file_name().and_then(|s| s.to_str()).filter(|id| super::checkpoint::valid_id(id))
            .context("Invalid comparison checkpoint")?;
        let id = format!("mcd2-{}",id.replace('-',""));
        let runs=directory.join("runs"); private_dir(&runs)?;
        let path=checkpoint.join("matrix.sqlite3");
        std::fs::OpenOptions::new().read(true).write(true).create(true).mode(0o600).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32).open(&path)?;
        let db=Connection::open(&path)?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS run(id TEXT PRIMARY KEY,revision INTEGER,summary TEXT);
            CREATE TABLE IF NOT EXISTS files(ordinal INTEGER PRIMARY KEY,id TEXT UNIQUE,digest TEXT,family TEXT,profile TEXT,available INTEGER,payload TEXT,extraction TEXT,diagnostic TEXT);
            CREATE TABLE IF NOT EXISTS scores(a INTEGER,b INTEGER,score REAL,PRIMARY KEY(a,b)) WITHOUT ROWID;
            BEGIN IMMEDIATE;")?;
        Ok(Self {db,temporary:None,working:Some(path),destination:runs.join(format!("{id}.sqlite3")),id})
    }
    pub fn saved_scores(&self) -> Result<u64> { Ok(self.db.query_row("SELECT COUNT(*) FROM scores",[],|r| r.get::<_,i64>(0))? as u64) }
    pub fn checkpoint(&self) -> Result<()> {
        if self.working.is_some() { self.db.execute_batch("COMMIT; BEGIN IMMEDIATE;")?; }
        Ok(())
    }
    pub fn file(
        &self,
        ordinal: usize,
        file: &MatchedFile,
        record: Option<&filetwin_core::api::FileRecord>,
    ) -> Result<()> {
        self.db
            .prepare_cached("INSERT OR REPLACE INTO files VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)")?
            .execute(params![
                ordinal as i64,
                file.id,
                record.and_then(|r| r.file_id.as_deref()),
                file.family,
                record.and_then(|r| r.profile_id.as_deref()),
                record.is_some_and(|r| r.vector.is_some()),
                serde_json::to_string(file)?,
                record
                    .and_then(|r| r.extraction.as_ref())
                    .map(serde_json::to_string)
                    .transpose()?,
                record.and_then(|r| r.error.as_ref()).map(|e| serde_json::to_string(&json!({
                    "code":e.code, "stage":e.stage, "reason":encoding::error_reason(Some(e)),
                    "fetch":if e.stage == "fetching" { json!({"kind":e.details["fetch_kind"],
                        "http_status":e.details["http_status"],"attempts":e.details["attempts"],"operation":e.details["operation"]}) } else { Value::Null }
                }))).transpose()?
            ])?;
        Ok(())
    }
    pub fn score(&self, a: usize, b: usize, score: f64) -> Result<()> {
        self.db
            .prepare_cached("INSERT INTO scores VALUES(?1,?2,?3)")?
            .execute(params![a as i64, b as i64, score])?;
        Ok(())
    }
    pub fn publish(self, summary: &Value) -> Result<()> {
        self.db.execute(
            "INSERT OR REPLACE INTO run VALUES(?1,1,?2)",
            params![self.id, serde_json::to_string(summary)?],
        )?;
        self.db
            .execute_batch("CREATE INDEX IF NOT EXISTS scores_b ON scores(b); COMMIT;")?;
        self.db.close().map_err(|(_, e)| e)?;
        let temporary = if let Some(path) = &self.working {
            // The immutable snapshot and checkpoint have separate lifetimes.
            if self.destination.exists() { return Ok(()); }
            let temp=tempfile::NamedTempFile::new_in(self.destination.parent().unwrap())?;
            std::fs::copy(path,temp.path())?; temp
        } else { self.temporary.unwrap() };
        temporary.as_file().sync_all()?;
        temporary.persist_noclobber(self.destination)?;
        Ok(())
    }
}

#[cfg(test)]
mod checkpoint_tests {
    use super::*;
    #[test]
    fn large_saved_inventory_can_be_reviewed_and_grouped() {
        let root=tempfile::tempdir().unwrap();
        let writer=MatrixWriter::new(root.path()).unwrap();
        for i in 0..101_137 {
            writer.file(i,&MatchedFile { id:format!("file-{i}"),name:format!("{i}.bin"),path:format!("/{i}.bin"),
                bytes:1,family:"other".into(),local_path:None,cloud_id:None,ancestors:vec![],
                engine_index:Some(i as u64),state:"ready".into() },None).unwrap();
        }
        let id=writer.id.clone(); writer.publish(&json!({"status":"completed"})).unwrap();
        let saved=SavedMatrix::open(root.path(),&id,1).unwrap();
        assert_eq!(saved.files.len(),101_137); assert_eq!(saved.files.last().unwrap().id,"file-101136");
        let groups=grouping::group_scores(GroupQuery {data_dir:root.path().into(),run_id:id,result_revision:1,
            minimum_score:0.9,include_identical:true},&AtomicBool::new(false)).unwrap();
        assert!(groups.groups.is_empty());
    }
    #[test]
    fn comparison_resumes_committed_scores_and_discards_an_interrupted_transaction() {
        let root=tempfile::tempdir().unwrap();
        let checkpoint=root.path().join("12345678-1234-1234-1234-123456789abc"); private_dir(&checkpoint).unwrap();
        let writer=MatrixWriter::resume(root.path(),&checkpoint).unwrap();
        writer.score(0,1,0.9).unwrap(); writer.checkpoint().unwrap();
        writer.score(0,2,0.7).unwrap(); drop(writer);
        let writer=MatrixWriter::resume(root.path(),&checkpoint).unwrap();
        assert_eq!(writer.saved_scores().unwrap(),1);
        writer.score(0,2,0.7).unwrap(); writer.score(1,2,0.8).unwrap(); writer.checkpoint().unwrap();
        let id=writer.id.clone(); writer.publish(&json!({"status":"completed"})).unwrap();
        let db=Connection::open(root.path().join("runs").join(format!("{id}.sqlite3"))).unwrap();
        assert_eq!(db.query_row("SELECT COUNT(*) FROM scores",[],|r|r.get::<_,i64>(0)).unwrap(),3);
        assert_eq!(db.query_row("SELECT score FROM scores WHERE a=0 AND b=1",[],|r|r.get::<_,f64>(0)).unwrap(),0.9);
    }
}

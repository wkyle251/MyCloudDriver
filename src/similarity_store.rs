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
    axes: Option<Vec<Vec<usize>>>,
    expected_scores: Option<u64>,
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
        let axes = if !legacy && compact(&db)? {
            Some(read_axes(&db, files.len())?)
        } else {
            None
        };
        let expected_scores = if axes.is_some() {
            Some(compact_progress(&db)?)
        } else {
            None
        };
        Ok(Self {
            db,
            run: run.into(),
            revision,
            legacy,
            within_source,
            axes,
            expected_scores,
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
        } else if let Some(axes) = &self.axes {
            let mut query = self
                .db
                .prepare("SELECT profile,a,b0,n,data FROM score_chunks ORDER BY profile,a,b0")?;
            let mut rows = query.query([])?;
            let mut cursor = comparison::Cursor::new(axes.iter().map(Vec::len).collect());
            while let Some(row) = rows.next()? {
                check_cancel(cancel)?;
                let (profile, a, b0, n, data) = chunk_row(row)?;
                validate_chunk(&mut cursor, profile, a, b0, n, &data)?;
                let axis = &axes[profile];
                let left = &self.files[axis[a]];
                for (offset, bytes) in data.chunks_exact(8).enumerate() {
                    let score = decode_score(bytes)?;
                    if score >= minimum {
                        visit(&left.id, &self.files[axis[b0 + offset]].id, score)?;
                    }
                }
            }
            if Some(cursor.completed) != self.expected_scores {
                bail!("The saved comparison snapshot is incomplete.");
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
        } else if let Some(axes) = &self.axes {
            if let Some((profile, position)) =
                axes.iter().enumerate().find_map(|(profile, axis)| {
                    axis.iter()
                        .position(|&ordinal| ordinal == request.row_offset as usize)
                        .map(|position| (profile, position))
                })
            {
                let axis = &axes[profile];
                let mut query = self.db.prepare(
                    "SELECT b0,n,data FROM score_chunks WHERE profile=?1 AND a=?2 ORDER BY b0",
                )?;
                let mut rows = query.query(params![profile as i64, position as i64])?;
                let mut expected = position + 1;
                while let Some(row) = rows.next()? {
                    check_cancel(cancel)?;
                    let b0 = index(row, 0)?;
                    let n = index(row, 1)?;
                    let data = row.get::<_, Vec<u8>>(2)?;
                    if b0 != expected
                        || n == 0
                        || n > comparison::MAX_CHUNK
                        || b0.checked_add(n).is_none_or(|end| end > axis.len())
                        || data.len() != 8 * n
                    {
                        bail!("Invalid saved comparison chunk.");
                    }
                    expected += n;
                    for (offset, bytes) in data.chunks_exact(8).enumerate() {
                        scores.insert(
                            self.files[axis[b0 + offset]].id.clone(),
                            decode_score(bytes)?,
                        );
                    }
                }
                let mut query = self.db.prepare("SELECT b0,n,substr(data,(?3-b0)*8+1,8),length(data) FROM score_chunks WHERE profile=?1 AND a=?2 AND b0<=?3 ORDER BY b0 DESC LIMIT 1")?;
                for earlier in 0..position {
                    check_cancel(cancel)?;
                    let found = query
                        .query_row(
                            params![profile as i64, earlier as i64, position as i64],
                            |r| {
                                Ok((
                                    index(r, 0)?,
                                    index(r, 1)?,
                                    r.get::<_, Vec<u8>>(2)?,
                                    index(r, 3)?,
                                ))
                            },
                        )
                        .optional()?;
                    if let Some((b0, n, bytes, length)) = found {
                        if length != 8 * n
                            || n == 0
                            || n > comparison::MAX_CHUNK
                            || b0 <= earlier
                            || b0.checked_add(n).is_none_or(|end| end > axis.len())
                        {
                            bail!("Invalid saved comparison chunk.");
                        }
                        if position < b0 + n {
                            scores.insert(
                                self.files[axis[earlier]].id.clone(),
                                decode_score(&bytes)?,
                            );
                        }
                    }
                }
            }
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
    guard_pairs: bool,
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
            guard_pairs: false,
        })
    }
    pub fn resume(directory: &Path, checkpoint: &Path) -> Result<Self> {
        use std::os::unix::fs::OpenOptionsExt;
        let id = checkpoint
            .file_name()
            .and_then(|s| s.to_str())
            .filter(|id| super::checkpoint::valid_id(id))
            .context("Invalid comparison checkpoint")?;
        let id = format!("mcd2-{}", id.replace('-', ""));
        let runs = directory.join("runs");
        private_dir(&runs)?;
        let path = checkpoint.join("matrix.sqlite3");
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&path)?;
        let db = Connection::open(&path)?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS run(id TEXT PRIMARY KEY,revision INTEGER,summary TEXT);
            CREATE TABLE IF NOT EXISTS files(ordinal INTEGER PRIMARY KEY,id TEXT UNIQUE,digest TEXT,family TEXT,profile TEXT,available INTEGER,payload TEXT,extraction TEXT,diagnostic TEXT);
            CREATE TABLE IF NOT EXISTS scores(a INTEGER,b INTEGER,score REAL,PRIMARY KEY(a,b)) WITHOUT ROWID;
            BEGIN IMMEDIATE;")?;
        if compact(&db)? {
            db.execute_batch("DROP TABLE IF EXISTS scores;")?;
        }
        let guard_pairs = if compact(&db)? {
            db.query_row("SELECT EXISTS(SELECT 1 FROM score_chunks)", [], |r| {
                r.get::<_, bool>(0)
            })?
        } else {
            db.query_row("SELECT EXISTS(SELECT 1 FROM scores)", [], |r| {
                r.get::<_, bool>(0)
            })?
        };
        Ok(Self {
            db,
            temporary: None,
            working: Some(path),
            destination: runs.join(format!("{id}.sqlite3")),
            id,
            guard_pairs,
        })
    }
    /// Install the immutable axis contract or validate it before resuming. Old
    /// row checkpoints are imported in canonical order inside this transaction.
    pub fn prepare(&self, profiles: &[comparison::Profile<'_>]) -> Result<()> {
        self.prepare_inner(profiles, None, None)
    }
    pub fn prepare_controlled(
        &self,
        profiles: &[comparison::Profile<'_>],
        cancel: &AtomicBool,
        token: Option<&filetwin_core::api::CancellationToken>,
    ) -> Result<()> {
        self.prepare_inner(profiles, Some(cancel), token)
    }
    fn prepare_inner(
        &self,
        profiles: &[comparison::Profile<'_>],
        cancel: Option<&AtomicBool>,
        token: Option<&filetwin_core::api::CancellationToken>,
    ) -> Result<()> {
        let wait = || -> Result<()> {
            if let Some(cancel) = cancel {
                check_cancel(cancel)?;
                if let Some(token) = token.filter(|token| token.is_paused()) {
                    control::wait_blocking(token, cancel)?;
                }
            }
            Ok(())
        };
        if compact(&self.db)? {
            let axes = read_axes(
                &self.db,
                self.db
                    .query_row("SELECT COUNT(*) FROM files", [], |r| index(r, 0))?,
            )?;
            if axes.len() != profiles.len() {
                bail!("Saved comparison axes changed. Start a new scan.");
            }
            let mut query = self
                .db
                .prepare("SELECT name FROM comparison_profiles WHERE id=?1")?;
            let mut fingerprint = self.db.prepare(
                "SELECT fingerprint FROM comparison_axes WHERE profile=?1 AND position=?2",
            )?;
            for (p, profile) in profiles.iter().enumerate() {
                if query.query_row([p as i64], |r| r.get::<_, String>(0))? != profile.name
                    || axes[p].len() != profile.axes.len()
                {
                    bail!("Saved comparison axes changed. Start a new scan.");
                }
                for (position, axis) in profile.axes.iter().enumerate() {
                    wait()?;
                    if axes[p][position] != axis.ordinal
                        || fingerprint.query_row(params![p as i64, position as i64], |r| {
                            r.get::<_, String>(0)
                        })? != axis.fingerprint
                    {
                        bail!("Saved comparison vectors changed. Start a new scan.");
                    }
                }
            }
            return Ok(());
        }
        self.db.execute_batch("CREATE TABLE score_format(version INTEGER NOT NULL); INSERT INTO score_format VALUES(1);
            CREATE TABLE comparison_profiles(id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE,n INTEGER NOT NULL);
            CREATE TABLE comparison_axes(profile INTEGER,position INTEGER,ordinal INTEGER UNIQUE,fingerprint TEXT NOT NULL,PRIMARY KEY(profile,position)) WITHOUT ROWID;
            CREATE TABLE score_chunks(profile INTEGER,a INTEGER,b0 INTEGER,n INTEGER,data BLOB NOT NULL,PRIMARY KEY(profile,a,b0)) WITHOUT ROWID;
            CREATE TABLE comparison_progress(singleton INTEGER PRIMARY KEY CHECK(singleton=1),profile INTEGER NOT NULL,a INTEGER NOT NULL,b INTEGER NOT NULL,completed INTEGER NOT NULL);")?;
        {
            let mut profile_insert = self
                .db
                .prepare("INSERT INTO comparison_profiles VALUES(?1,?2,?3)")?;
            let mut axis_insert = self
                .db
                .prepare("INSERT INTO comparison_axes VALUES(?1,?2,?3,?4)")?;
            for (p, profile) in profiles.iter().enumerate() {
                profile_insert.execute(params![
                    p as i64,
                    profile.name,
                    profile.axes.len() as i64
                ])?;
                for (position, axis) in profile.axes.iter().enumerate() {
                    wait()?;
                    axis_insert.execute(params![
                        p as i64,
                        position as i64,
                        axis.ordinal as i64,
                        axis.fingerprint
                    ])?;
                }
            }
        }
        let initial = comparison::Cursor::new(profiles.iter().map(|p| p.axes.len()).collect());
        self.db.execute(
            "INSERT INTO comparison_progress VALUES(1,?1,?2,?3,0)",
            params![initial.profile as i64, initial.a as i64, initial.b as i64],
        )?;
        let old = self
            .db
            .query_row("SELECT COUNT(*) FROM scores", [], |r| r.get::<_, i64>(0))?;
        let mut cursor = comparison::Cursor::new(profiles.iter().map(|p| p.axes.len()).collect());
        let mut query = self.db.prepare("SELECT aa.profile,aa.position,bb.position,s.score FROM scores s JOIN comparison_axes aa ON aa.ordinal=s.a JOIN comparison_axes bb ON bb.ordinal=s.b AND aa.profile=bb.profile ORDER BY aa.profile,aa.position,bb.position")?;
        let mut rows = query.query([])?;
        let mut scores = Vec::new();
        let mut start = (cursor.profile, cursor.a, cursor.b);
        while let Some(row) = rows.next()? {
            wait()?;
            let position = (index(row, 0)?, index(row, 1)?, index(row, 2)?);
            if position != (cursor.profile, cursor.a, cursor.b) {
                bail!("The old comparison checkpoint is not a contiguous matching inventory. Start a new scan.");
            }
            let score = row.get::<_, f64>(3)?;
            if !score.is_finite() || !(-1.0..=1.0).contains(&score) {
                bail!("A saved similarity score is invalid.");
            }
            let current = comparison::score(
                &profiles[position.0].axes[position.1],
                &profiles[position.0].axes[position.2],
            )?;
            if score != current {
                bail!("Saved comparison vectors changed. Start a new scan.");
            }
            scores.push(score);
            let end_row = cursor.remaining_row() == 1;
            cursor.advance(1)?;
            if scores.len() == comparison::MAX_CHUNK || end_row {
                self.chunk(start.0, start.1, start.2, &scores)?;
                scores.clear();
                start = (cursor.profile, cursor.a, cursor.b);
            }
        }
        if !scores.is_empty() {
            self.chunk(start.0, start.1, start.2, &scores)?;
        }
        if cursor.completed != u64::try_from(old)? {
            bail!("The old comparison checkpoint contains incompatible pairs. Start a new scan.");
        }
        drop(rows);
        drop(query);
        self.db.execute_batch("DROP TABLE scores;")?;
        Ok(())
    }
    pub fn saved_scores(&self) -> Result<u64> {
        if compact(&self.db)? {
            return compact_progress(&self.db);
        }
        Ok(self
            .db
            .query_row("SELECT COUNT(*) FROM scores", [], |r| r.get::<_, i64>(0))?
            as u64)
    }
    pub fn chunk(&self, profile: usize, a: usize, b0: usize, scores: &[f64]) -> Result<()> {
        if scores.is_empty()
            || scores.len() > comparison::MAX_CHUNK
            || scores
                .iter()
                .any(|score| !score.is_finite() || !(-1.0..=1.0).contains(score))
        {
            bail!("Invalid comparison chunk.");
        }
        let (saved_profile, saved_a, saved_b, completed) = self.db.query_row(
            "SELECT profile,a,b,completed FROM comparison_progress WHERE singleton=1",
            [],
            |r| {
                Ok((
                    index(r, 0)?,
                    index(r, 1)?,
                    index(r, 2)?,
                    r.get::<_, i64>(3)?,
                ))
            },
        )?;
        if (profile, a, b0) != (saved_profile, saved_a, saved_b) {
            bail!("Comparison chunks must form a contiguous prefix.");
        }
        let n = self.db.query_row(
            "SELECT n FROM comparison_profiles WHERE id=?1",
            [profile as i64],
            |r| index(r, 0),
        )?;
        let end = b0
            .checked_add(scores.len())
            .context("Invalid comparison chunk")?;
        if a >= b0 || end > n {
            bail!("Invalid comparison chunk.");
        }
        let next = if end < n {
            (profile, a, end)
        } else if a + 2 < n {
            (profile, a + 1, a + 2)
        } else {
            let next = self
                .db
                .query_row(
                    "SELECT id FROM comparison_profiles WHERE id>?1 AND n>=2 ORDER BY id LIMIT 1",
                    [profile as i64],
                    |r| index(r, 0),
                )
                .optional()?;
            (
                next.unwrap_or(self.db.query_row(
                    "SELECT COUNT(*) FROM comparison_profiles",
                    [],
                    |r| index(r, 0),
                )?),
                0,
                1,
            )
        };
        let completed = completed
            .checked_add(i64::try_from(scores.len())?)
            .context("Too many saved comparisons")?;
        let mut data = Vec::with_capacity(scores.len() * 8);
        for score in scores {
            data.extend_from_slice(&score.to_le_bytes());
        }
        self.db
            .prepare_cached("INSERT INTO score_chunks VALUES(?1,?2,?3,?4,?5)")?
            .execute(params![
                profile as i64,
                a as i64,
                b0 as i64,
                scores.len() as i64,
                data
            ])?;
        self.db.prepare_cached("UPDATE comparison_progress SET profile=?1,a=?2,b=?3,completed=?4 WHERE singleton=1")?.execute(params![next.0 as i64,next.1 as i64,next.2 as i64,completed])?;
        Ok(())
    }
    pub fn checkpoint(&self) -> Result<()> {
        if self.working.is_some() {
            self.db.execute_batch("COMMIT; BEGIN IMMEDIATE;")?;
        }
        Ok(())
    }
    pub fn file(
        &self,
        ordinal: usize,
        file: &MatchedFile,
        record: Option<&filetwin_core::api::FileRecord>,
    ) -> Result<()> {
        self.file_with_digest(
            ordinal,
            file,
            record,
            record.and_then(|r| r.file_id.as_deref()),
        )
    }
    pub fn file_with_digest(
        &self,
        ordinal: usize,
        file: &MatchedFile,
        record: Option<&filetwin_core::api::FileRecord>,
        exact_digest: Option<&str>,
    ) -> Result<()> {
        if self.guard_pairs {
            let old = self
                .db
                .query_row(
                    "SELECT id,digest,family,profile,available FROM files WHERE ordinal=?1",
                    [ordinal as i64],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, Option<String>>(1)?,
                            r.get::<_, Option<String>>(2)?,
                            r.get::<_, Option<String>>(3)?,
                            r.get::<_, bool>(4)?,
                        ))
                    },
                )
                .optional()?;
            let valid = old
                .as_ref()
                .is_some_and(|(id, digest, family, profile, available)| {
                    id == &file.id
                        && family.as_deref() == Some(file.family.as_str())
                        && profile.as_deref() == record.and_then(|r| r.profile_id.as_deref())
                        && *available == record.is_some_and(|r| r.vector.is_some())
                        && (digest.as_deref() == exact_digest
                            || digest.as_deref() == record.and_then(|r| r.file_id.as_deref()))
                });
            if !valid {
                bail!("Saved comparison axes changed. Start a new scan.");
            }
        }
        self.db
            .prepare_cached("INSERT OR REPLACE INTO files VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)")?
            .execute(params![
                ordinal as i64,
                file.id,
                exact_digest,
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
        if !compact(&self.db)? {
            self.db
                .execute_batch("CREATE INDEX IF NOT EXISTS scores_b ON scores(b);")?;
        }
        self.db.execute_batch("COMMIT;")?;
        self.db.close().map_err(|(_, e)| e)?;
        let temporary = if let Some(path) = &self.working {
            // The immutable snapshot and checkpoint have separate lifetimes.
            if self.destination.exists() {
                return Ok(());
            }
            let temp = tempfile::NamedTempFile::new_in(self.destination.parent().unwrap())?;
            std::fs::copy(path, temp.path())?;
            temp
        } else {
            self.temporary.unwrap()
        };
        temporary.as_file().sync_all()?;
        temporary.persist_noclobber(self.destination)?;
        Ok(())
    }
}

fn index(row: &rusqlite::Row<'_>, column: usize) -> rusqlite::Result<usize> {
    let value = row.get::<_, i64>(column)?;
    usize::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(column, value))
}
fn compact(db: &Connection) -> Result<bool> {
    let exists: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='score_format')",
        [],
        |r| r.get(0),
    )?;
    if !exists {
        return Ok(false);
    }
    let versions = db
        .prepare("SELECT version FROM score_format")?
        .query_map([], |r| r.get::<_, i64>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if versions != [1] {
        bail!("This saved comparison format is unavailable in this build.");
    }
    Ok(true)
}
fn compact_progress(db: &Connection) -> Result<u64> {
    let lengths = profile_lengths(db)?;
    let (profile, a, b, completed) = db.query_row(
        "SELECT profile,a,b,completed FROM comparison_progress WHERE singleton=1",
        [],
        |r| {
            Ok((
                index(r, 0)?,
                index(r, 1)?,
                index(r, 2)?,
                r.get::<_, i64>(3)?,
            ))
        },
    )?;
    let completed = u64::try_from(completed)?;
    let mut cursor = comparison::Cursor::new(lengths);
    cursor.skip(completed)?;
    if (cursor.profile, cursor.a, cursor.b) != (profile, a, b) {
        bail!("Invalid saved comparison progress.");
    }
    Ok(completed)
}
fn profile_lengths(db: &Connection) -> Result<Vec<usize>> {
    let mut lengths = Vec::new();
    let mut query = db.prepare("SELECT id,n FROM comparison_profiles ORDER BY id")?;
    let mut rows = query.query([])?;
    while let Some(row) = rows.next()? {
        if index(row, 0)? != lengths.len() {
            bail!("Invalid saved comparison profiles.");
        }
        lengths.push(index(row, 1)?);
    }
    Ok(lengths)
}
fn read_axes(db: &Connection, files: usize) -> Result<Vec<Vec<usize>>> {
    let lengths = profile_lengths(db)?;
    if lengths
        .iter()
        .try_fold(0usize, |sum, &n| sum.checked_add(n))
        .is_none_or(|n| n > files)
    {
        bail!("Invalid saved comparison profiles.");
    }
    let mut axes = vec![Vec::new(); lengths.len()];
    let mut seen = HashSet::new();
    let mut query = db.prepare(
        "SELECT profile,position,ordinal FROM comparison_axes ORDER BY profile,position",
    )?;
    let mut rows = query.query([])?;
    while let Some(row) = rows.next()? {
        let profile = index(row, 0)?;
        let position = index(row, 1)?;
        let ordinal = index(row, 2)?;
        let axis = axes
            .get_mut(profile)
            .context("Invalid saved comparison profile")?;
        if position != axis.len() || ordinal >= files || !seen.insert(ordinal) {
            bail!("Invalid saved comparison axis.");
        }
        axis.push(ordinal);
    }
    if axes.iter().zip(&lengths).any(|(axis, &n)| axis.len() != n) {
        bail!("Invalid saved comparison axis.");
    }
    Ok(axes)
}
fn chunk_row(row: &rusqlite::Row<'_>) -> Result<(usize, usize, usize, usize, Vec<u8>)> {
    Ok((
        index(row, 0)?,
        index(row, 1)?,
        index(row, 2)?,
        index(row, 3)?,
        row.get(4)?,
    ))
}
fn validate_chunk(
    cursor: &mut comparison::Cursor,
    profile: usize,
    a: usize,
    b0: usize,
    n: usize,
    data: &[u8],
) -> Result<()> {
    if (profile, a, b0) != (cursor.profile, cursor.a, cursor.b)
        || n == 0
        || n > comparison::MAX_CHUNK
        || data.len() != n * 8
    {
        bail!("Invalid saved comparison chunk.");
    }
    for bytes in data.chunks_exact(8) {
        decode_score(bytes)?;
    }
    cursor.advance(n)
}
fn decode_score(bytes: &[u8]) -> Result<f64> {
    let score = f64::from_le_bytes(
        bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("Invalid saved score bytes"))?,
    );
    if !score.is_finite() || !(-1.0..=1.0).contains(&score) {
        bail!("A saved similarity score is invalid.");
    }
    Ok(score)
}

#[cfg(test)]
mod checkpoint_tests {
    use super::*;
    #[test]
    fn large_saved_inventory_can_be_reviewed_and_grouped() {
        let root = tempfile::tempdir().unwrap();
        let writer = MatrixWriter::new(root.path()).unwrap();
        for i in 0..101_137 {
            writer
                .file(
                    i,
                    &MatchedFile {
                        id: format!("file-{i}"),
                        name: format!("{i}.bin"),
                        path: format!("/{i}.bin"),
                        bytes: 1,
                        family: "other".into(),
                        local_path: None,
                        cloud_id: None,
                        ancestors: vec![],
                        engine_index: Some(i as u64),
                        state: "ready".into(),
                    },
                    None,
                )
                .unwrap();
        }
        let id = writer.id.clone();
        writer.publish(&json!({"status":"completed"})).unwrap();
        let saved = SavedMatrix::open(root.path(), &id, 1).unwrap();
        assert_eq!(saved.files.len(), 101_137);
        assert_eq!(saved.files.last().unwrap().id, "file-101136");
        let groups = grouping::group_scores(
            GroupQuery {
                data_dir: root.path().into(),
                run_id: id,
                result_revision: 1,
                minimum_score: 0.9,
                include_identical: true,
            },
            &AtomicBool::new(false),
        )
        .unwrap();
        assert!(groups.groups.is_empty());
    }
    #[test]
    fn comparison_resumes_committed_scores_and_discards_an_interrupted_transaction() {
        let root = tempfile::tempdir().unwrap();
        let checkpoint = root.path().join("12345678-1234-1234-1234-123456789abc");
        private_dir(&checkpoint).unwrap();
        let writer = MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        writer.score(0, 1, 0.9).unwrap();
        writer.checkpoint().unwrap();
        writer.score(0, 2, 0.7).unwrap();
        drop(writer);
        let writer = MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), 1);
        writer.score(0, 2, 0.7).unwrap();
        writer.score(1, 2, 0.8).unwrap();
        writer.checkpoint().unwrap();
        let id = writer.id.clone();
        writer.publish(&json!({"status":"completed"})).unwrap();
        let db = Connection::open(root.path().join("runs").join(format!("{id}.sqlite3"))).unwrap();
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM scores", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            3
        );
        assert_eq!(
            db.query_row("SELECT score FROM scores WHERE a=0 AND b=1", [], |r| r
                .get::<_, f64>(0))
                .unwrap(),
            0.9
        );
    }
}

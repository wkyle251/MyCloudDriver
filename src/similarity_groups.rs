//! Read-only grouping of a saved score matrix. No source, model or worker is
//! opened. Each non-self matrix cell is stored once in the app's saved snapshot.
use super::*;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GroupQuery {
    pub data_dir: PathBuf,
    pub run_id: String,
    pub result_revision: u64,
    pub minimum_score: f64,
    pub include_identical: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SavedGroup {
    pub id: String,
    pub file_ids: Vec<String>,
    pub minimum_score: Option<f64>,
    pub identical: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SavedGroups {
    pub run_id: String,
    pub result_revision: u64,
    pub minimum_score: f64,
    pub groups: Vec<SavedGroup>,
}

pub fn group_scores(request: GroupQuery, cancel: &AtomicBool) -> Result<SavedGroups> {
    if !request.data_dir.is_absolute()
        || !request.minimum_score.is_finite()
        || !(0.05..=1.0).contains(&request.minimum_score)
        || request.result_revision == 0
    {
        bail!("Choose a saved scan and a similarity from 5% to 100%.");
    }
    let matrix =
        store::SavedMatrix::open(&request.data_dir, &request.run_id, request.result_revision)?;
    let identity = matrix.grouping_identity()?;
    if let Some(identity) = identity {
        if let Some(saved) = cached_groups(&request, identity) {
            check_cancel(cancel)?;
            if matrix.grouping_identity()? == Some(identity) {
                return Ok(saved);
            }
        }
    }
    let mut files = BTreeMap::<String, Option<String>>::new();
    for file in &matrix.files {
        check_cancel(cancel)?;
        if !file.is_file {
            continue;
        }
        files.insert(
            file.id.clone(),
            file.digest.clone().filter(|_| request.include_identical),
        );
    }
    let (ids, hashes): (Vec<_>, Vec<_>) = files.into_iter().unzip();
    let ordinals: HashMap<_, _> = ids
        .iter()
        .enumerate()
        .map(|(i, id)| (id.as_str(), i))
        .collect();
    // Qualifying edges and cluster links can both be quadratic. Keep their
    // ordering and accumulation on private disposable disk, rather than
    // imposing a hidden matching-pair ceiling or retaining them all in RAM.
    let mut spool = GroupSpool::new()?;
    matrix.visit_scores(request.minimum_score, cancel, |a, b, score| {
        if !score.is_finite() || !(-1.0..=1.0).contains(&score) {
            bail!("A saved similarity score is invalid.");
        }
        let (Some(&a), Some(&b)) = (ordinals.get(a), ordinals.get(b)) else {
            return Ok(());
        };
        if a != b && !(hashes[a].is_some() && hashes[a] == hashes[b]) {
            // These files are already one verified identical-content cluster;
            // partitioning would discard every such edge after lookup anyway.
            spool.edge(a.min(b), a.max(b), score)?;
        }
        Ok(())
    })?;
    let groups = spool.partition(&ids, &hashes, cancel)?;
    let result = SavedGroups {
        run_id: request.run_id.clone(),
        result_revision: request.result_revision,
        minimum_score: request.minimum_score,
        groups,
    };
    check_cancel(cancel)?;
    if let Some(identity) =
        identity.filter(|id| matrix.grouping_identity().ok().flatten().as_ref() == Some(id))
    {
        let _ = cache_groups(&request, identity, &result);
    }
    Ok(result)
}

#[derive(Serialize, Deserialize)]
struct CachedGroups {
    version: u32,
    identity: [u8; 32],
    include_identical: bool,
    result: SavedGroups,
}
#[derive(Serialize)]
struct CachedGroupsRef<'a> {
    version: u32,
    identity: [u8; 32],
    include_identical: bool,
    result: &'a SavedGroups,
}
fn cache_path(request: &GroupQuery) -> PathBuf {
    request.data_dir.join("runs").join(format!(
        "{}.groups-{:016x}-{}.zst",
        request.run_id,
        request.minimum_score.to_bits(),
        u8::from(request.include_identical)
    ))
}
fn cached_groups(request: &GroupQuery, identity: [u8; 32]) -> Option<SavedGroups> {
    use std::{io::Read, os::unix::fs::OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags((rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32)
        .open(cache_path(request))
        .ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut bytes = Vec::new();
    zstd::stream::read::Decoder::new(file)
        .ok()?
        .take((512 << 20) + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > 512 << 20 {
        return None;
    }
    let cached: CachedGroups = serde_json::from_slice(&bytes).ok()?;
    (cached.version == 1
        && cached.identity == identity
        && cached.include_identical == request.include_identical
        && cached.result.run_id == request.run_id
        && cached.result.result_revision == request.result_revision
        && cached.result.minimum_score == request.minimum_score)
        .then_some(cached.result)
}
fn cache_groups(request: &GroupQuery, identity: [u8; 32], result: &SavedGroups) -> Result<()> {
    let target = cache_path(request);
    let parent = target.parent().context("Missing saved groups directory")?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    {
        let mut encoder = zstd::stream::Encoder::new(file.as_file_mut(), 1)?;
        encoder.include_checksum(true)?;
        // Serialize by reference so large member lists are never cloned.
        serde_json::to_writer(
            &mut encoder,
            &CachedGroupsRef {
                version: 1,
                identity,
                include_identical: request.include_identical,
                result,
            },
        )?;
        encoder.finish()?;
    }
    file.as_file().sync_all()?;
    file.persist(&target)?;
    // Keep at most eight threshold results per run. These are disposable
    // derived files; neither originals nor the saved matrix are removed.
    let prefix = format!("{}.groups-", request.run_id);
    let mut entries = std::fs::read_dir(parent)?
        .filter_map(|e| e.ok())
        .filter_map(|entry| {
            let name = entry.file_name();
            let name = name.to_str()?;
            if !name.starts_with(&prefix) || !name.ends_with(".zst") {
                return None;
            }
            let metadata = entry.metadata().ok()?;
            (metadata.is_file() && entry.path() != target)
                .then(|| (metadata.modified().ok(), entry.path()))
        })
        .collect::<Vec<_>>();
    entries.sort_by_key(|(time, _)| *time);
    let remove = entries.len().saturating_sub(7);
    for (_, path) in entries.into_iter().take(remove) {
        let _ = std::fs::remove_file(path);
    }
    Ok(())
}

/// This temporary database contains only numeric ordinals and measurements.
/// Its page cache shrinks on OS pressure; all scratch files disappear on drop.
fn index(row: &rusqlite::Row<'_>, column: usize) -> rusqlite::Result<usize> {
    let value = row.get::<_, i64>(column)?;
    usize::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(column, value))
}
struct GroupSpool {
    db: rusqlite::Connection,
    _file: tempfile::NamedTempFile,
    last_pressure: std::cell::Cell<Instant>,
    cache_kib: std::cell::Cell<u32>,
}
impl GroupSpool {
    fn new() -> Result<Self> {
        let file = tempfile::NamedTempFile::new()?;
        let db = rusqlite::Connection::open(file.path())?;
        db.execute_batch(
            "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
            PRAGMA temp_store=FILE; PRAGMA mmap_size=0; PRAGMA cache_size=-16384;
            CREATE TABLE edges(a INTEGER,b INTEGER,score REAL,PRIMARY KEY(a,b)) WITHOUT ROWID;
            CREATE TABLE links(a INTEGER,b INTEGER,n INTEGER,PRIMARY KEY(a,b)) WITHOUT ROWID;
            CREATE INDEX links_b ON links(b);
            CREATE TABLE neighbours(other INTEGER PRIMARY KEY,n INTEGER);
            CREATE TABLE pending(sequence INTEGER PRIMARY KEY,a INTEGER,b INTEGER,UNIQUE(a,b));
            BEGIN;",
        )?;
        Ok(Self {
            db,
            _file: file,
            last_pressure: std::cell::Cell::new(Instant::now()),
            cache_kib: std::cell::Cell::new(16384),
        })
    }
    fn pressure(&self) -> Result<()> {
        if self.last_pressure.get().elapsed() < Duration::from_millis(250) {
            return Ok(());
        }
        self.last_pressure.set(Instant::now());
        let pressure = filetwin_core::memory_control::system_memory().pressure;
        let kib = if pressure >= 4 {
            1024
        } else if pressure >= 2 {
            4096
        } else {
            16384
        };
        if kib != self.cache_kib.get() {
            self.db.pragma_update(None, "cache_size", -(kib as i64))?;
            self.cache_kib.set(kib);
        }
        Ok(())
    }
    fn edge(&mut self, a: usize, b: usize, score: f64) -> Result<()> {
        self.pressure()?;
        self.db
            .prepare_cached("INSERT INTO edges VALUES(?1,?2,?3)")?
            .execute(rusqlite::params![a as i64, b as i64, score])?;
        Ok(())
    }
    fn link(&self, a: usize, b: usize) -> Result<usize> {
        use rusqlite::OptionalExtension;
        Ok(self
            .db
            .prepare_cached("SELECT n FROM links WHERE a=?1 AND b=?2")?
            .query_row(rusqlite::params![a.min(b) as i64, a.max(b) as i64], |r| {
                index(r, 0)
            })
            .optional()?
            .unwrap_or(0))
    }
    fn add(&self, a: usize, b: usize, n: usize) -> Result<usize> {
        let n = self
            .link(a, b)?
            .checked_add(n)
            .context("Too many cluster comparisons")?;
        self.db
            .prepare_cached(
                "INSERT INTO links VALUES(?1,?2,?3) ON CONFLICT(a,b) DO UPDATE SET n=excluded.n",
            )?
            .execute(rusqlite::params![
                a.min(b) as i64,
                a.max(b) as i64,
                i64::try_from(n)?
            ])?;
        Ok(n)
    }
    fn enqueue(&self, a: usize, b: usize) -> Result<()> {
        self.db
            .prepare_cached("INSERT OR IGNORE INTO pending(a,b) VALUES(?1,?2)")?
            .execute(rusqlite::params![a.min(b) as i64, a.max(b) as i64])?;
        Ok(())
    }
    fn dequeue(&self) -> Result<Option<(usize, usize)>> {
        use rusqlite::OptionalExtension;
        let next = self
            .db
            .prepare_cached("SELECT sequence,a,b FROM pending ORDER BY sequence LIMIT 1")?
            .query_row([], |r| {
                Ok((r.get::<_, i64>(0)?, index(r, 1)?, index(r, 2)?))
            })
            .optional()?;
        if let Some((sequence, a, b)) = next {
            self.db
                .prepare_cached("DELETE FROM pending WHERE sequence=?1")?
                .execute([sequence])?;
            Ok(Some((a, b)))
        } else {
            Ok(None)
        }
    }
    /// Process strongest to weakest and merge only once ALL cross-pairs are
    /// present. The score order/ties match the original complete-link history.
    fn partition(
        &mut self,
        ids: &[String],
        hashes: &[Option<String>],
        cancel: &AtomicBool,
    ) -> Result<Vec<SavedGroup>> {
        use rusqlite::params;
        check_cancel(cancel)?;
        let stop = AtomicBool::new(false);
        let interrupt = self.db.get_interrupt_handle();
        let indexed = std::thread::scope(|scope| {
            scope.spawn(|| {
                while !stop.load(Ordering::Acquire) {
                    if cancel.load(Ordering::Acquire) {
                        interrupt.interrupt();
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
            });
            let result = self
                .db
                .execute_batch("CREATE INDEX edge_order ON edges(score DESC,a,b);");
            stop.store(true, Ordering::Release);
            result
        });
        check_cancel(cancel)?;
        indexed?;
        let mut parents: Vec<_> = (0..ids.len()).collect();
        let mut members = vec![Vec::new(); ids.len()];
        let mut minimums = vec![1.0f64; ids.len()];
        let mut identical = HashMap::<&str, usize>::new();
        for file in 0..ids.len() {
            check_cancel(cancel)?;
            let root = if let Some(hash) = hashes[file].as_deref() {
                *identical.entry(hash).or_insert(file)
            } else {
                file
            };
            parents[file] = root;
            members[root].push(file);
        }
        fn root(parents: &mut [usize], mut file: usize) -> usize {
            while parents[file] != file {
                parents[file] = parents[parents[file]];
                file = parents[file];
            }
            file
        }
        fn expected(members: &[Vec<usize>], a: usize, b: usize) -> Result<usize> {
            members[a]
                .len()
                .checked_mul(members[b].len())
                .context("Too many cluster comparisons")
        }
        // The ordered edges table stays immutable while this connection
        // updates separate cluster tables; no second reader can block spills.
        let mut query = self
            .db
            .prepare("SELECT a,b,score FROM edges INDEXED BY edge_order ORDER BY score DESC,a,b")?;
        let mut rows = query.query([])?;
        while let Some(row) = rows.next()? {
            check_cancel(cancel)?;
            self.pressure()?;
            let left = index(row, 0)?;
            let right = index(row, 1)?;
            let score = row.get::<_, f64>(2)?;
            if left >= ids.len()
                || right >= ids.len()
                || left == right
                || !score.is_finite()
                || !(-1.0..=1.0).contains(&score)
            {
                bail!("Invalid saved similarity edge.");
            }
            let a = root(&mut parents, left);
            let b = root(&mut parents, right);
            if a == b {
                continue;
            }
            let count = self.add(a, b, 1)?;
            let needed = expected(&members, a, b)?;
            if count > needed {
                bail!("Duplicate pairs in the saved similarity matrix.");
            }
            if count < needed {
                continue;
            }
            self.enqueue(a, b)?;
            while let Some((a, b)) = self.dequeue()? {
                check_cancel(cancel)?;
                let mut a = root(&mut parents, a);
                let mut b = root(&mut parents, b);
                if a == b || self.link(a, b)? != expected(&members, a, b)? {
                    continue;
                }
                if members[a].len() < members[b].len()
                    || (members[a].len() == members[b].len() && a > b)
                {
                    std::mem::swap(&mut a, &mut b);
                }
                parents[b] = a;
                let moved = std::mem::take(&mut members[b]);
                members[a].extend(moved);
                minimums[a] = minimums[a].min(minimums[b]).min(score);
                self.db
                    .prepare_cached("DELETE FROM links WHERE a=?1 AND b=?2")?
                    .execute(params![a.min(b) as i64, a.max(b) as i64])?;
                self.db.execute("DELETE FROM neighbours", [])?;
                self.db.prepare_cached("INSERT INTO neighbours SELECT CASE WHEN a=?1 THEN b ELSE a END,n FROM links WHERE a=?1 OR b=?1")?.execute([b as i64])?;
                self.db
                    .prepare_cached("DELETE FROM links WHERE a=?1 OR b=?1")?
                    .execute([b as i64])?;
                let mut neighbours = self
                    .db
                    .prepare("SELECT other,n FROM neighbours ORDER BY other")?;
                let mut neighbours = neighbours.query([])?;
                while let Some(row) = neighbours.next()? {
                    check_cancel(cancel)?;
                    let other = index(row, 0)?;
                    let n = index(row, 1)?;
                    let count = self.add(a, other, n)?;
                    if count == expected(&members, a, other)? {
                        self.enqueue(a, other)?;
                    }
                }
            }
        }
        let mut output: Vec<_> = members
            .into_iter()
            .zip(minimums)
            .filter(|(members, _)| members.len() > 1)
            .map(|(mut members, minimum)| {
                members.sort_unstable();
                let first = members[0];
                let identical =
                    hashes[first].is_some() && members.iter().all(|&i| hashes[i] == hashes[first]);
                SavedGroup {
                    id: ids[first].clone(),
                    file_ids: members.into_iter().map(|i| ids[i].clone()).collect(),
                    minimum_score: (!identical).then_some(minimum),
                    identical,
                }
            })
            .collect();
        output.sort_by(|a, b| {
            b.file_ids
                .len()
                .cmp(&a.file_ids.len())
                .then_with(|| {
                    b.minimum_score
                        .unwrap_or(1.0)
                        .total_cmp(&a.minimum_score.unwrap_or(1.0))
                })
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(output)
    }
}

#[cfg(test)]
fn partition(
    ids: &[String],
    hashes: &[Option<String>],
    earlier: Vec<Vec<(usize, f64)>>,
    cancel: &AtomicBool,
) -> Result<Vec<SavedGroup>> {
    let mut spool = GroupSpool::new()?;
    for (b, edges) in earlier.into_iter().enumerate() {
        for (a, score) in edges {
            spool.edge(a, b, score)?;
        }
    }
    spool.partition(ids, hashes, cancel)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "large generated disk-backed grouping regression; run explicitly"]
    fn more_than_four_million_qualifying_edges_group_completely() {
        let count = 2830usize;
        let ids = (0..count)
            .map(|i| format!("fixture-{i:05}"))
            .collect::<Vec<_>>();
        let mut spool = GroupSpool::new().unwrap();
        for b in 0..count {
            for a in 0..b {
                spool.edge(a, b, 0.95).unwrap();
            }
        }
        assert!(count * (count - 1) / 2 > 4_000_000);
        let groups = spool
            .partition(&ids, &vec![None; count], &AtomicBool::new(false))
            .unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].file_ids, ids);
        assert_eq!(groups[0].minimum_score, Some(0.95));
    }
    #[test]
    fn disk_grouping_cancellation_drops_private_spool() {
        let mut spool = GroupSpool::new().unwrap();
        let path = spool._file.path().to_path_buf();
        spool.edge(0, 1, 0.9).unwrap();
        assert!(spool
            .partition(
                &["fixture-a".into(), "fixture-b".into()],
                &[None, None],
                &AtomicBool::new(true)
            )
            .is_err());
        drop(spool);
        assert!(!path.exists());
    }
    #[test]
    fn disk_grouping_matches_reference_with_ties_missing_pairs_and_exact_clusters() {
        for seed in 1..=12 {
            let ids = (0..32)
                .map(|i| format!("fixture-{i:04}"))
                .collect::<Vec<_>>();
            let mut hashes = vec![None; 32];
            hashes[2] = Some("same".into());
            hashes[8] = Some("same".into());
            let mut random = seed as u64;
            let mut edges = Vec::new();
            for b in 0..32 {
                for a in 0..b {
                    random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
                    if random % 9 != 0 {
                        edges.push((a, b, (5 + random % 96) as f64 / 100.0));
                    }
                }
            }
            for threshold in [1.0, 0.95, 0.5, 0.05] {
                let mut earlier = vec![vec![]; 32];
                for &(a, b, score) in &edges {
                    if score >= threshold {
                        earlier[b].push((a, score));
                    }
                }
                let expected =
                    reference_partition(&ids, &hashes, earlier.clone(), &AtomicBool::new(false))
                        .unwrap();
                let actual = partition(&ids, &hashes, earlier, &AtomicBool::new(false)).unwrap();
                assert_eq!(
                    serde_json::to_value(actual).unwrap(),
                    serde_json::to_value(expected).unwrap()
                );
            }
        }
    }
    #[test]
    fn ordinary_grouping_fixture_reports_disk_overhead() {
        let count = 200;
        let ids = (0..count)
            .map(|i| format!("fixture-{i:04}"))
            .collect::<Vec<_>>();
        let hashes = vec![None; count];
        let mut earlier = vec![vec![]; count];
        for b in 0..count {
            for a in 0..b {
                earlier[b].push((a, 0.95));
            }
        }
        let started = Instant::now();
        let expected =
            reference_partition(&ids, &hashes, earlier.clone(), &AtomicBool::new(false)).unwrap();
        let reference = started.elapsed();
        let started = Instant::now();
        let actual = partition(&ids, &hashes, earlier, &AtomicBool::new(false)).unwrap();
        let disk = started.elapsed();
        assert_eq!(
            serde_json::to_value(actual).unwrap(),
            serde_json::to_value(expected).unwrap()
        );
        eprintln!(
            "generated_grouping_pairs=19900 reference_ms={} disk_ms={}",
            reference.as_secs_f64() * 1000.0,
            disk.as_secs_f64() * 1000.0
        );
    }
    #[test]
    fn groups_require_every_pair_and_preserve_exact_evidence() {
        let ids = ["a", "b", "c", "d", "e", "f"].map(str::to_owned);
        let hashes = vec![
            None,
            None,
            None,
            Some("same".into()),
            Some("same".into()),
            None,
        ];
        let groups = partition(
            &ids,
            &hashes,
            vec![
                vec![],
                vec![(0, 0.96345)],
                vec![(1, 0.96)],
                vec![],
                vec![],
                vec![],
            ],
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(groups.len(), 2);
        assert!(groups
            .iter()
            .any(|g| g.identical && g.file_ids == ["d", "e"]));
        assert!(groups
            .iter()
            .any(|g| g.minimum_score == Some(0.96345) && g.file_ids == ["a", "b"]));
        assert!(!groups.iter().any(|g| g.file_ids.contains(&"c".into())));
    }
    #[test]
    fn grouping_cancels_without_partial_output() {
        assert!(partition(&["a".into()], &[None], vec![vec![]], &AtomicBool::new(true)).is_err());
    }

    #[test]
    fn lowering_threshold_only_merges_and_every_pair_still_qualifies() {
        // Reproducible mixed matrices, including missing measurements, ties
        // and a verified identical pair. Each cutoff is queried independently.
        for seed in 1..=24 {
            let ids: Vec<_> = (0..14).map(|i| format!("file-{i:02}")).collect();
            let mut hashes = vec![None; ids.len()];
            hashes[2] = Some("same".into());
            hashes[8] = Some("same".into());
            let mut random = seed as u64;
            let mut scores = BTreeMap::new();
            for b in 0..ids.len() {
                for a in 0..b {
                    random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
                    if random % 9 != 0 {
                        scores.insert((a, b), (5 + random % 96) as f64 / 100.0);
                    }
                }
            }
            let mut previous: Vec<SavedGroup> = vec![];
            for threshold in [1.0, 0.95, 0.9, 0.87, 0.75, 0.5, 0.05] {
                let mut earlier = vec![vec![]; ids.len()];
                for (&(a, b), &score) in &scores {
                    if score >= threshold {
                        earlier[b].push((a, score));
                    }
                }
                let groups = partition(&ids, &hashes, earlier, &AtomicBool::new(false)).unwrap();
                for old in &previous {
                    assert!(
                        groups
                            .iter()
                            .any(|new| old.file_ids.iter().all(|f| new.file_ids.contains(f))),
                        "Lower thresholds must preserve the earlier groups"
                    );
                }
                for group in &groups {
                    let files: Vec<_> = group
                        .file_ids
                        .iter()
                        .map(|id| ids.iter().position(|f| f == id).unwrap())
                        .collect();
                    for (index, &b) in files.iter().enumerate() {
                        for &a in &files[..index] {
                            assert!(
                                hashes[a].is_some() && hashes[a] == hashes[b]
                                    || scores
                                        .get(&(a.min(b), a.max(b)))
                                        .is_some_and(|s| *s >= threshold)
                            );
                        }
                    }
                }
                previous = groups;
            }
        }
    }
}

#[cfg(test)]
fn reference_partition(
    ids: &[String],
    hashes: &[Option<String>],
    earlier: Vec<Vec<(usize, f64)>>,
    cancel: &AtomicBool,
) -> Result<Vec<SavedGroup>> {
    let mut parents: Vec<_> = (0..ids.len()).collect();
    let mut members = vec![Vec::new(); ids.len()];
    let mut minimums = vec![1.0f64; ids.len()];
    let mut identical = HashMap::<&str, usize>::new();
    for file in 0..ids.len() {
        check_cancel(cancel)?;
        let root = if let Some(hash) = hashes[file].as_deref() {
            *identical.entry(hash).or_insert(file)
        } else {
            file
        };
        parents[file] = root;
        members[root].push(file);
    }
    let mut edges: Vec<_> = earlier
        .into_iter()
        .enumerate()
        .flat_map(|(b, edges)| edges.into_iter().map(move |(a, score)| (a, b, score)))
        .collect();
    edges.sort_unstable_by(|a, b| {
        b.2.total_cmp(&a.2)
            .then_with(|| a.0.cmp(&b.0))
            .then_with(|| a.1.cmp(&b.1))
    });
    // Counts replace a dense matrix: a cluster pair becomes admissible exactly
    // when count == |A| * |B|. Merging combines counts for common neighbours.
    let mut links = vec![HashMap::<usize, usize>::new(); ids.len()];
    fn root(parents: &mut [usize], mut file: usize) -> usize {
        while parents[file] != file {
            parents[file] = parents[parents[file]];
            file = parents[file];
        }
        file
    }
    for (left, right, score) in edges {
        check_cancel(cancel)?;
        let a = root(&mut parents, left);
        let b = root(&mut parents, right);
        if a == b {
            continue;
        }
        let count = links[a].get(&b).copied().unwrap_or(0) + 1;
        let expected = members[a].len() * members[b].len();
        if count > expected {
            bail!("Duplicate pairs in the saved similarity matrix.");
        }
        links[a].insert(b, count);
        links[b].insert(a, count);
        if count < expected {
            continue;
        }
        let mut pending = VecDeque::from([(a, b)]);
        while let Some((a, b)) = pending.pop_front() {
            check_cancel(cancel)?;
            let mut a = root(&mut parents, a);
            let mut b = root(&mut parents, b);
            if a == b
                || links[a].get(&b).copied().unwrap_or(0) != members[a].len() * members[b].len()
            {
                continue;
            }
            // Move the smaller membership list to keep repeated merges bounded.
            if members[a].len() < members[b].len()
                || (members[a].len() == members[b].len() && a > b)
            {
                std::mem::swap(&mut a, &mut b);
            }
            parents[b] = a;
            let moved = std::mem::take(&mut members[b]);
            members[a].extend(moved);
            minimums[a] = minimums[a].min(minimums[b]).min(score);
            links[a].remove(&b);
            links[b].remove(&a);
            let mut neighbours: Vec<_> = std::mem::take(&mut links[b]).into_iter().collect();
            neighbours.sort_unstable_by_key(|&(other, _)| other);
            for (other, count) in neighbours {
                links[other].remove(&b);
                let count = links[a].get(&other).copied().unwrap_or(0) + count;
                links[a].insert(other, count);
                links[other].insert(a, count);
                if count == members[a].len() * members[other].len() {
                    pending.push_back((a, other));
                }
            }
        }
    }
    let groups = members.into_iter().zip(minimums);
    let mut output: Vec<_> = groups
        .into_iter()
        .filter(|(members, _)| members.len() > 1)
        .map(|(mut members, minimum)| {
            members.sort_unstable();
            let first = members[0];
            let identical =
                hashes[first].is_some() && members.iter().all(|&i| hashes[i] == hashes[first]);
            SavedGroup {
                id: ids[first].clone(),
                file_ids: members.into_iter().map(|i| ids[i].clone()).collect(),
                minimum_score: (!identical).then_some(minimum),
                identical,
            }
        })
        .collect();
    output.sort_by(|a, b| {
        b.file_ids
            .len()
            .cmp(&a.file_ids.len())
            .then_with(|| {
                b.minimum_score
                    .unwrap_or(1.0)
                    .total_cmp(&a.minimum_score.unwrap_or(1.0))
            })
            .then_with(|| a.id.cmp(&b.id))
    });
    Ok(output)
}

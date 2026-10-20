//! Exact, bounded parallel comparison. Only the coordinator touches SQLite;
//! completed chunks are retained in canonical order for durable resume.
use super::*;
use filetwin_core::api::{CancellationToken, FileRecord};
use std::collections::BTreeMap;
use std::sync::{mpsc, Mutex};

pub(super) const MAX_CHUNK: usize = 4096;
pub(super) struct Axis<'a> {
    pub ordinal: usize,
    pub vector: &'a [f32],
    pub fingerprint: String,
    norm: f64,
    equivalent: usize,
}
pub(super) struct Profile<'a> {
    pub name: &'a str,
    pub axes: Vec<Axis<'a>>,
}

pub(super) fn profiles<'a>(
    records: &BTreeMap<&'a str, Vec<(usize, &'a FileRecord)>>,
) -> Result<Vec<Profile<'a>>> {
    records
        .iter()
        .map(|(&name, records)| {
            let mut dimensions = None;
            let mut axes = records
                .iter()
                .map(|&(ordinal, record)| {
                    let vector = record.vector.as_deref().context("Missing content vector")?;
                    if dimensions
                        .replace(vector.len())
                        .is_some_and(|n| n != vector.len())
                    {
                        bail!("Inconsistent vector dimensions in the same FileTwin profile.");
                    }
                    let mut sum = 0.0f64;
                    let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
                    for &value in vector {
                        let value64 = f64::from(value);
                        sum += value64 * value64;
                        hash.update(&value.to_bits().to_le_bytes());
                    }
                    let norm = sum.sqrt();
                    if !norm.is_finite() || norm <= 0.0 {
                        bail!("FileTwin returned an invalid content vector.");
                    }
                    Ok(Axis {
                        ordinal,
                        vector,
                        fingerprint: hex::encode(hash.finish()),
                        norm,
                        equivalent: 0,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            deduplicate(&mut axes);
            Ok(Profile { name, axes })
        })
        .collect()
}

fn deduplicate(axes: &mut [Axis<'_>]) {
    let mut representatives = BTreeMap::<String, Vec<usize>>::new();
    for i in 0..axes.len() {
        let key = if axes[i].vector.iter().any(|v| v.to_bits() == 0x8000_0000) {
            // Resume identity preserves every stored bit; numeric vector
            // equality deliberately treats -0.0 and +0.0 as equivalent.
            let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
            for value in axes[i].vector {
                hash.update(&(if *value == 0.0 { 0 } else { value.to_bits() }).to_le_bytes());
            }
            hex::encode(hash.finish())
        } else {
            axes[i].fingerprint.clone()
        };
        let candidates = representatives.entry(key).or_default();
        let equivalent = candidates
            .iter()
            .copied()
            .find(|&other| axes[other].vector == axes[i].vector)
            .unwrap_or(i);
        axes[i].equivalent = equivalent;
        if equivalent == i {
            candidates.push(i);
        }
    }
}

pub(super) fn total(profiles: &[Profile<'_>]) -> Result<u64> {
    profiles.iter().try_fold(0u64, |total, p| {
        let n = u64::try_from(p.axes.len())?;
        let pairs = n
            .checked_mul(n.saturating_sub(1))
            .context("Too many compatible comparisons")?
            / 2;
        total
            .checked_add(pairs)
            .context("Too many compatible comparisons")
    })
}

/// Position in the canonical profile/upper-triangular traversal. This also
/// validates migrated checkpoints instead of trusting a row count alone.
#[derive(Clone, Debug)]
pub(super) struct Cursor {
    lengths: Vec<usize>,
    pub profile: usize,
    pub a: usize,
    pub b: usize,
    pub completed: u64,
}
impl Cursor {
    pub fn new(lengths: Vec<usize>) -> Self {
        let mut cursor = Self {
            lengths,
            profile: 0,
            a: 0,
            b: 1,
            completed: 0,
        };
        cursor.normalize();
        cursor
    }
    fn normalize(&mut self) {
        while let Some(&length) = self.lengths.get(self.profile) {
            if self.a + 1 >= length {
                self.profile += 1;
                self.a = 0;
                self.b = 1;
            } else if self.b >= length {
                self.a += 1;
                self.b = self.a + 1;
            } else {
                break;
            }
        }
    }
    pub fn remaining_row(&self) -> usize {
        self.lengths.get(self.profile).map_or(0, |&n| n - self.b)
    }
    pub fn advance(&mut self, count: usize) -> Result<()> {
        if count == 0 || count > self.remaining_row() {
            bail!("Invalid saved comparison chunk.");
        }
        self.b += count;
        self.completed = self
            .completed
            .checked_add(count as u64)
            .context("Too many compatible comparisons")?;
        self.normalize();
        Ok(())
    }
    pub fn skip(&mut self, mut count: u64) -> Result<()> {
        while count > 0 {
            let n = self
                .remaining_row()
                .min(count.min(usize::MAX as u64) as usize);
            if n == 0 {
                bail!("Saved comparisons exceed the current inventory.");
            }
            self.advance(n)?;
            count -= n as u64;
        }
        Ok(())
    }
}

pub(super) fn score(left: &Axis<'_>, right: &Axis<'_>) -> Result<f64> {
    let score = if left.equivalent == right.equivalent || left.vector == right.vector {
        1.0
    } else {
        // Identical multiplication/accumulation order and denominator to
        // profile::cosine. Never use reciprocal norms or fused operations.
        let mut dot = 0.0f64;
        for (&a, &b) in left.vector.iter().zip(right.vector) {
            dot += f64::from(a) * f64::from(b);
        }
        (dot / (left.norm * right.norm)).clamp(-1.0, 1.0)
    };
    if !score.is_finite() {
        bail!("FileTwin returned an invalid content vector.");
    }
    Ok(score)
}

#[derive(Clone, Debug)]
struct Job {
    start: u64,
    profile: usize,
    a: usize,
    b: usize,
    count: usize,
}
fn calculate(job: &Job, profiles: &[Profile<'_>], cancel: &AtomicBool) -> Result<Option<Vec<f64>>> {
    let profile = &profiles[job.profile];
    let left = &profile.axes[job.a];
    let mut scores = Vec::with_capacity(job.count);
    for right in &profile.axes[job.b..job.b + job.count] {
        if cancel.load(Ordering::Acquire) {
            return Ok(None);
        }
        let score = score(left, right)?;
        scores.push(score);
    }
    Ok(Some(scores))
}

pub(super) fn run(
    profiles: &[Profile<'_>],
    writer: &store::MatrixWriter,
    saved: u64,
    workers: usize,
    cancel: &AtomicBool,
    token: Option<&CancellationToken>,
    mut progress: impl FnMut(u64) -> Result<()>,
) -> Result<u64> {
    let maximum = total(profiles)?;
    if saved > maximum {
        bail!("Saved comparisons exceed the current inventory.");
    }
    if saved == maximum || cancel.load(Ordering::Acquire) {
        return Ok(saved);
    }
    let workers = workers
        .min(std::thread::available_parallelism().map_or(1, |n| n.get()))
        .max(1);
    let window = workers.saturating_mul(2);
    std::thread::scope(|scope| {
        let (jobs_tx, jobs_rx) = mpsc::sync_channel::<Job>(window);
        let jobs_rx = Arc::new(Mutex::new(jobs_rx));
        let (results_tx, results_rx) = mpsc::sync_channel(window);
        for _ in 0..workers {
            let jobs_rx = jobs_rx.clone();
            let results_tx = results_tx.clone();
            scope.spawn(move || loop {
                let received = { jobs_rx.lock().unwrap().recv() };
                let Ok(job) = received else {
                    break;
                };
                let scores = calculate(&job, profiles, cancel);
                if results_tx.send((job, scores)).is_err() {
                    break;
                }
            });
        }
        drop(results_tx);
        let result = (|| -> Result<u64> {
            let mut cursor = Cursor::new(profiles.iter().map(|p| p.axes.len()).collect());
            cursor.skip(saved)?;
            let mut committed = saved;
            let mut outstanding = 0usize;
            let mut ready = BTreeMap::new();
            let mut last = Instant::now();
            let mut first_checkpoint = true;
            let mut stopping = false;
            loop {
                if cancel.load(Ordering::Acquire) {
                    stopping = true;
                }
                let paused = token.is_some_and(|token| token.is_paused());
                while !stopping
                    && !paused
                    && outstanding + ready.len() < window
                    && cursor.completed < maximum
                {
                    // Bound both retained output and the work between cooperative
                    // cancellation checks for high-dimensional descriptors.
                    let dimensions = profiles[cursor.profile].axes[cursor.a].vector.len().max(1);
                    let count = cursor
                        .remaining_row()
                        .min((1_048_576 / dimensions).clamp(1, MAX_CHUNK));
                    let job = Job {
                        start: cursor.completed,
                        profile: cursor.profile,
                        a: cursor.a,
                        b: cursor.b,
                        count,
                    };
                    jobs_tx.send(job)?;
                    cursor.advance(count)?;
                    outstanding += 1;
                }
                if outstanding == 0 {
                    if stopping || committed == maximum {
                        break;
                    }
                    if paused {
                        writer.checkpoint()?;
                        progress(committed)?;
                        if control::wait_blocking(token.unwrap(), cancel).is_err() {
                            break;
                        }
                        continue;
                    }
                }
                match results_rx.recv_timeout(Duration::from_millis(20)) {
                    Ok((job, scores)) => {
                        outstanding -= 1;
                        match scores? {
                            Some(scores) => {
                                ready.insert(job.start, (job, scores));
                            }
                            None => {
                                stopping = true;
                            }
                        }
                        while let Some((job, scores)) = ready.remove(&committed) {
                            writer.chunk(job.profile, job.a, job.b, &scores)?;
                            committed += scores.len() as u64;
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        if outstanding > 0 {
                            bail!("Similarity comparison workers stopped unexpectedly.");
                        }
                    }
                }
                if (first_checkpoint && committed > saved && committed < maximum)
                    || last.elapsed() >= Duration::from_millis(250)
                {
                    writer.checkpoint()?;
                    progress(committed)?;
                    first_checkpoint = false;
                    last = Instant::now();
                }
            }
            writer.checkpoint()?;
            Ok(committed)
        })();
        // Closing both channels before scoped joining also handles failures in
        // the writer/progress sink without blocked senders or borrowed vectors.
        drop(jobs_tx);
        drop(results_rx);
        result
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn query_fixture(count: usize) -> (tempfile::TempDir, String) {
        let root = tempfile::tempdir().unwrap();
        let vectors = vec![vec![1.0f32]; count];
        let profiles = fixture_profiles(&vectors);
        let writer = store::MatrixWriter::new(root.path()).unwrap();
        populate(&writer, count); writer.prepare(&profiles).unwrap();
        for a in 0..count - 1 { writer.chunk(0, a, a + 1, &vec![0.9456068339072593; count - a - 1]).unwrap(); }
        let run = writer.id.clone(); writer.publish(&json!({"status":"completed"})).unwrap();
        (root, run)
    }
    #[test]
    fn saved_bounds_preserve_thresholds_and_rebuild_corrupt_or_stale_metadata() {
        let (root, run) = query_fixture(8);
        let source = root.path().join("runs").join(format!("{run}.sqlite3"));
        let index_path = group_index::path(&source);
        let read = |cutoff| {
            let matrix = store::SavedMatrix::open(root.path(), &run, 1).unwrap();
            let mut values = Vec::new();
            matrix.visit_scores(cutoff, &AtomicBool::new(false), |a,b,s| { values.push((a.to_owned(),b.to_owned(),s)); Ok(()) }).unwrap();
            values
        };
        assert_eq!(read(0.9).len(), 28);
        let original = std::fs::read(&index_path).unwrap();
        assert_eq!(read(0.94).len(), 28);
        assert!(read(0.97).is_empty());
        assert_eq!(std::fs::read(&index_path).unwrap(), original);
        std::fs::write(&index_path, b"damaged derived index").unwrap();
        assert_eq!(read(0.94).len(), 28);
        assert_eq!(std::fs::read(&index_path).unwrap(), original);
        let db = rusqlite::Connection::open(&source).unwrap();
        let mut bytes: Vec<u8> = db.query_row("SELECT data FROM score_chunks WHERE a=0", [], |r| r.get(0)).unwrap();
        bytes[..8].copy_from_slice(&f64::NAN.to_le_bytes());
        db.execute("UPDATE score_chunks SET data=?1 WHERE a=0", [bytes]).unwrap(); drop(db);
        let matrix = store::SavedMatrix::open(root.path(), &run, 1).unwrap();
        assert!(matrix.visit_scores(1.0, &AtomicBool::new(false), |_,_,_| Ok(())).is_err(),
            "A changed source must invalidate its bounds, including invalid scores below the cutoff");
    }
    #[test]
    fn confirmed_trash_and_undo_persist_rows_and_groups_without_changing_scores() {
        let (root, run) = query_fixture(4);
        let groups = || grouping::group_scores(grouping::GroupQuery { data_dir:root.path().into(),run_id:run.clone(),
            result_revision:1,minimum_score:0.94,include_identical:true }, &AtomicBool::new(false)).unwrap();
        let original_groups = groups();
        assert_eq!(original_groups.groups[0].file_ids.len(),4);
        assert_eq!(original_groups.groups[0].minimum_score,Some(0.9456068339072593));
        let original_bytes = serde_json::to_vec(&original_groups).unwrap();
        let cache_file = std::fs::read_dir(root.path().join("runs")).unwrap().filter_map(|e|e.ok())
            .find(|e|e.file_name().to_string_lossy().contains(".groups-")).unwrap().path();
        use std::os::unix::fs::MetadataExt;
        let cache_inode = std::fs::metadata(&cache_file).unwrap().ino();
        assert_eq!(serde_json::to_vec(&groups()).unwrap(),original_bytes,
            "Cached group responses must preserve every score bit as well as membership");
        assert_eq!(std::fs::metadata(&cache_file).unwrap().ino(),cache_inode);
        std::fs::write(&cache_file,b"damaged cached group response").unwrap();
        assert_eq!(groups().groups[0].file_ids.len(),4);
        let source = root.path().join("runs").join(format!("{run}.sqlite3"));
        let metadata_before = group_index::identity(&source, &run, 1, 6).unwrap();
        for trashed in [true,false] {
            exclusions::update_result_files(exclusions::ResultFilesUpdate { data_dir:root.path().into(),run_id:run.clone(),
                result_revision:1,file_ids:vec![file(1).id],trashed }, &AtomicBool::new(false)).unwrap();
            let matrix=store::SavedMatrix::open(root.path(),&run,1).unwrap();
            let row=matrix.row(&ScoreRowRequest { compact:true,data_dir:root.path().into(),run_id:run.clone(),
                result_revision:1,file_id:file(0).id,row_offset:0 }, &AtomicBool::new(false)).unwrap();
            assert_eq!(row["entries"].as_array().unwrap().len(),if trashed {2} else {3});
            assert_eq!(row["entries"].as_array().unwrap().iter().any(|r| r["ordinal"]==1),!trashed);
            assert_eq!(groups().groups[0].file_ids.len(),if trashed {3} else {4});
            assert_eq!(group_index::identity(&source,&run,1,6).unwrap(),metadata_before);
        }
        assert!(exclusions::update_result_files(exclusions::ResultFilesUpdate { data_dir:root.path().into(),run_id:run.clone(),
            result_revision:1,file_ids:vec!["another-scan-file".into()],trashed:true }, &AtomicBool::new(false)).is_err());
        assert!(exclusions::load(&source,&run,1).unwrap().ordinals.is_empty());
    }
    fn fixture_profiles<'a>(vectors: &'a [Vec<f32>]) -> Vec<Profile<'a>> {
        let mut profiles = vec![Profile {
            name: "fixture",
            axes: vectors
                .iter()
                .enumerate()
                .map(|(ordinal, vector)| {
                    let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
                    for value in vector {
                        hash.update(&value.to_bits().to_le_bytes());
                    }
                    Axis {
                        ordinal,
                        vector,
                        fingerprint: hex::encode(hash.finish()),
                        equivalent: ordinal,
                        norm: vector
                            .iter()
                            .map(|&v| f64::from(v) * f64::from(v))
                            .sum::<f64>()
                            .sqrt(),
                    }
                })
                .collect(),
        }];
        deduplicate(&mut profiles[0].axes);
        profiles
    }
    fn file(ordinal: usize) -> MatchedFile {
        MatchedFile {
            id: format!("fixture-{ordinal:06}"),
            name: format!("fixture-{ordinal}"),
            path: format!("/fixture-{ordinal}"),
            bytes: 1,
            family: "text".into(),
            local_path: None,
            cloud_id: None,
            ancestors: vec![],
            engine_index: Some(ordinal as u64),
            state: "ready".into(),
        }
    }
    fn populate(writer: &store::MatrixWriter, count: usize) {
        for ordinal in 0..count {
            writer.file(ordinal, &file(ordinal), None).unwrap();
        }
    }
    #[test]
    fn all_pairs_above_old_limit_have_complete_first_and_last_rows() {
        let root = tempfile::tempdir().unwrap();
        let vectors = vec![vec![1.0f32]; 3001];
        let profiles = fixture_profiles(&vectors);
        let writer = store::MatrixWriter::new(root.path()).unwrap();
        populate(&writer, vectors.len());
        writer.prepare(&profiles).unwrap();
        let compared = run(
            &profiles,
            &writer,
            0,
            8,
            &AtomicBool::new(false),
            None,
            |_| Ok(()),
        )
        .unwrap();
        assert_eq!(compared, 4_501_500);
        assert_eq!(writer.saved_scores().unwrap(), compared);
        let id = writer.id.clone();
        writer.publish(&json!({"complete":true})).unwrap();
        let matrix = store::SavedMatrix::open(root.path(), &id, 1).unwrap();
        for ordinal in [0, 1500, 3000] {
            let row = matrix
                .row(
                    &ScoreRowRequest {
                        compact: false,
                        data_dir: root.path().into(),
                        run_id: id.clone(),
                        result_revision: 1,
                        file_id: file(ordinal).id,
                        row_offset: ordinal as u64,
                    },
                    &AtomicBool::new(false),
                )
                .unwrap();
            assert_eq!(row["entries"].as_array().unwrap().len(), 3000);
            assert!(row["unavailable"].as_object().unwrap().is_empty());
        }
        let bytes = std::fs::metadata(root.path().join("runs").join(format!("{id}.sqlite3")))
            .unwrap()
            .len();
        assert!(
            bytes < compared * 10,
            "compact snapshot grew beyond ten bytes per pair"
        );
    }
    #[test]
    fn old_checkpoint_migrates_then_resumes_exactly_and_rejects_changed_axes() {
        let root = tempfile::tempdir().unwrap();
        let checkpoint = root.path().join("12345678-1234-1234-1234-123456789abc");
        private_dir(&checkpoint).unwrap();
        let vectors = vec![
            vec![1.0, 0.25],
            vec![0.5, 1.0],
            vec![-0.25, 1.0],
            vec![1.0, -0.5],
        ];
        let profiles = fixture_profiles(&vectors);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, 4);
        writer
            .score(
                0,
                1,
                score(&profiles[0].axes[0], &profiles[0].axes[1]).unwrap(),
            )
            .unwrap();
        writer
            .score(
                0,
                2,
                score(&profiles[0].axes[0], &profiles[0].axes[2]).unwrap(),
            )
            .unwrap();
        writer.checkpoint().unwrap();
        drop(writer);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, 4);
        writer.prepare(&profiles).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), 2);
        writer.checkpoint().unwrap();
        writer.chunk(0, 0, 3, &[0.123]).unwrap();
        drop(writer); // Uncommitted chunk disappears.
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, 4);
        writer.prepare(&profiles).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), 2);
        assert_eq!(
            run(
                &profiles,
                &writer,
                2,
                4,
                &AtomicBool::new(false),
                None,
                |_| Ok(())
            )
            .unwrap(),
            6
        );
        writer.checkpoint().unwrap();
        drop(writer);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        let mut changed = file(0);
        changed.id = "different-fixture".into();
        assert!(writer.file(0, &changed, None).is_err());
        let mut changed_vectors = vectors.clone();
        changed_vectors[0][0] = 0.7;
        assert!(writer.prepare(&fixture_profiles(&changed_vectors)).is_err());
        writer.prepare(&profiles).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), 6);
    }
    #[test]
    fn interrupted_upgrade_keeps_the_old_checkpoint_unchanged() {
        let root = tempfile::tempdir().unwrap();
        let checkpoint = root.path().join("12345678-1234-1234-1234-123456789abc");
        private_dir(&checkpoint).unwrap();
        let vectors = vec![vec![1.0]; 3];
        let profiles = fixture_profiles(&vectors);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, 3);
        writer.score(0, 1, 1.0).unwrap();
        writer.checkpoint().unwrap();
        drop(writer);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, 3);
        assert!(writer
            .prepare_controlled(&profiles, &AtomicBool::new(true), None)
            .is_err());
        drop(writer);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), 1);
        writer.prepare(&profiles).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), 1);
    }
    #[test]
    fn migration_rejects_nonprefix_or_changed_score_in_old_checkpoint() {
        for bad_score in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let checkpoint = root.path().join("12345678-1234-1234-1234-123456789abc");
            private_dir(&checkpoint).unwrap();
            let vectors = vec![vec![1.0]; 3];
            let profiles = fixture_profiles(&vectors);
            let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
            populate(&writer, 3);
            writer
                .score(
                    0,
                    if bad_score { 1 } else { 2 },
                    if bad_score { 0.5 } else { 1.0 },
                )
                .unwrap();
            writer.checkpoint().unwrap();
            drop(writer);
            let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
            populate(&writer, 3);
            assert!(writer.prepare(&profiles).is_err());
            drop(writer);
            let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
            assert_eq!(writer.saved_scores().unwrap(), 1);
        }
    }
    #[test]
    fn single_and_parallel_snapshots_have_identical_scores() {
        let vectors = (0..65)
            .map(|i| vec![1.0, (i as f32 + 0.5) / 65.0, ((i * 17) % 31) as f32])
            .collect::<Vec<_>>();
        let profiles = fixture_profiles(&vectors);
        let mut collected = Vec::new();
        for workers in [1, 8] {
            let root = tempfile::tempdir().unwrap();
            let writer = store::MatrixWriter::new(root.path()).unwrap();
            populate(&writer, 65);
            writer.prepare(&profiles).unwrap();
            run(
                &profiles,
                &writer,
                0,
                workers,
                &AtomicBool::new(false),
                None,
                |_| Ok(()),
            )
            .unwrap();
            let id = writer.id.clone();
            writer.publish(&json!({})).unwrap();
            let matrix = store::SavedMatrix::open(root.path(), &id, 1).unwrap();
            let mut scores = Vec::new();
            matrix
                .visit_scores(-1.0, &AtomicBool::new(false), |a, b, s| {
                    scores.push((a.to_owned(), b.to_owned(), s.to_bits()));
                    Ok(())
                })
                .unwrap();
            collected.push(scores);
        }
        assert_eq!(collected[0], collected[1]);
    }
    #[test]
    fn cancellation_keeps_a_resumable_prefix_and_pause_wakes_on_cancel() {
        let root = tempfile::tempdir().unwrap();
        let checkpoint = root.path().join("12345678-1234-1234-1234-123456789abc");
        private_dir(&checkpoint).unwrap();
        let vectors = vec![vec![1.0]; 3001];
        let profiles = fixture_profiles(&vectors);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, vectors.len());
        writer.prepare(&profiles).unwrap();
        let cancel = AtomicBool::new(false);
        let completed = std::thread::scope(|scope| {
            scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(5));
                cancel.store(true, Ordering::Release);
            });
            run(&profiles, &writer, 0, 8, &cancel, None, |_| Ok(())).unwrap()
        });
        assert!(completed < total(&profiles).unwrap());
        assert_eq!(writer.saved_scores().unwrap(), completed);
        drop(writer);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, vectors.len());
        writer.prepare(&profiles).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), completed);
        cancel.store(false, Ordering::Release);
        let token = CancellationToken::default();
        token.set_paused(true);
        let paused = std::thread::scope(|scope| {
            scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(20));
                cancel.store(true, Ordering::Release);
            });
            run(
                &profiles,
                &writer,
                completed,
                8,
                &cancel,
                Some(&token),
                |_| Ok(()),
            )
            .unwrap()
        });
        assert_eq!(paused, completed);
        cancel.store(false, Ordering::Release);
        token.set_paused(false);
        assert_eq!(
            run(
                &profiles,
                &writer,
                completed,
                8,
                &cancel,
                Some(&token),
                |_| Ok(())
            )
            .unwrap(),
            4_501_500
        );
    }
    #[test]
    fn numeric_zero_equivalence_preserves_one_without_weakening_resume_identity() {
        let vectors = vec![vec![1.0, 0.0], vec![1.0, -0.0]];
        let profiles = fixture_profiles(&vectors);
        assert_ne!(
            profiles[0].axes[0].fingerprint,
            profiles[0].axes[1].fingerprint
        );
        assert_eq!(
            profiles[0].axes[0].equivalent,
            profiles[0].axes[1].equivalent
        );
        assert_eq!(
            score(&profiles[0].axes[0], &profiles[0].axes[1])
                .unwrap()
                .to_bits(),
            1.0f64.to_bits()
        );
    }
    #[test]
    fn progress_sink_failure_joins_workers_and_keeps_committed_prefix() {
        let root = tempfile::tempdir().unwrap();
        let checkpoint = root.path().join("12345678-1234-1234-1234-123456789abc");
        private_dir(&checkpoint).unwrap();
        let vectors = vec![vec![1.0]; 3001];
        let profiles = fixture_profiles(&vectors);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        populate(&writer, vectors.len());
        writer.prepare(&profiles).unwrap();
        let result = run(
            &profiles,
            &writer,
            0,
            8,
            &AtomicBool::new(false),
            None,
            |_| bail!("generated progress failure"),
        );
        assert!(result.is_err());
        let completed = writer.saved_scores().unwrap();
        assert!(completed > 0 && completed < 4_501_500);
        drop(writer);
        let writer = store::MatrixWriter::resume(root.path(), &checkpoint).unwrap();
        writer.prepare(&profiles).unwrap();
        assert_eq!(writer.saved_scores().unwrap(), completed);
        assert_eq!(
            run(
                &profiles,
                &writer,
                completed,
                8,
                &AtomicBool::new(false),
                None,
                |_| Ok(())
            )
            .unwrap(),
            4_501_500
        );
    }
    #[test]
    fn precomputed_norm_scores_are_bit_identical_to_reference() {
        let mut state = 71u64;
        let mut vectors = Vec::new();
        for _ in 0..32 {
            let vector = (0..193)
                .map(|_| {
                    state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                    ((state >> 32) as i32) as f32 / 2_147_483_648.0
                })
                .collect::<Vec<_>>();
            vectors.push(vector);
        }
        let profiles = vec![Profile {
            name: "fixture",
            axes: vectors
                .iter()
                .enumerate()
                .map(|(ordinal, vector)| Axis {
                    ordinal,
                    vector,
                    fingerprint: ordinal.to_string(),
                    equivalent: ordinal,
                    norm: vector
                        .iter()
                        .map(|&v| f64::from(v) * f64::from(v))
                        .sum::<f64>()
                        .sqrt(),
                })
                .collect(),
        }];
        for a in 0..31 {
            let job = Job {
                start: 0,
                profile: 0,
                a,
                b: a + 1,
                count: 31 - a,
            };
            for (offset, score) in calculate(&job, &profiles, &AtomicBool::new(false))
                .unwrap()
                .unwrap()
                .iter()
                .enumerate()
            {
                assert_eq!(
                    score.to_bits(),
                    filetwin_core::profile::cosine(&vectors[a], &vectors[a + 1 + offset]).to_bits()
                );
            }
        }
    }
    #[test]
    fn cursor_handles_profiles_and_partial_rows_without_missing_pairs() {
        let mut c = Cursor::new(vec![0, 1, 4, 2]);
        c.skip(4).unwrap();
        assert_eq!((c.profile, c.a, c.b, c.completed), (2, 1, 3, 4));
        c.advance(1).unwrap();
        c.advance(1).unwrap();
        c.advance(1).unwrap();
        assert_eq!(c.completed, 7);
        assert_eq!(c.remaining_row(), 0);
    }
}

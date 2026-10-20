//! Disposable bounds for immutable comparison chunks. A threshold change can
//! skip blocks that cannot contain a match, without opening any original file.
use super::*;
use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

const MAGIC: &[u8; 8] = b"MCDGIDX1";
const HEADER: usize = 48;
const RECORD: usize = 40;
const DIGEST: usize = 32;

pub(super) fn path(source: &Path) -> PathBuf {
    source.with_extension("group-index")
}

pub(super) fn identity(source: &Path, run: &str, revision: u64, scores: u64) -> Result<[u8; 32]> {
    let m = std::fs::metadata(source)?;
    let bytes = serde_json::to_vec(&json!([
        run,
        revision,
        scores,
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec()
    ]))?;
    Ok(ring::digest::digest(&ring::digest::SHA256, &bytes)
        .as_ref()
        .try_into()
        .unwrap())
}

#[derive(Clone, Copy, Debug)]
pub(super) struct Bounds {
    pub profile: usize,
    pub a: usize,
    pub b: usize,
    pub n: usize,
    pub maximum: f64,
}
impl Bounds {
    fn encode(self) -> [u8; RECORD] {
        let mut bytes = [0u8; RECORD];
        for (i, value) in [
            self.profile as u64,
            self.a as u64,
            self.b as u64,
            self.n as u64,
            self.maximum.to_bits(),
        ]
        .into_iter()
        .enumerate()
        {
            bytes[i * 8..i * 8 + 8].copy_from_slice(&value.to_le_bytes());
        }
        bytes
    }
    fn decode(bytes: &[u8]) -> Result<Self> {
        let value = |i: usize| u64::from_le_bytes(bytes[i * 8..i * 8 + 8].try_into().unwrap());
        Ok(Self {
            profile: value(0).try_into()?,
            a: value(1).try_into()?,
            b: value(2).try_into()?,
            n: value(3).try_into()?,
            maximum: f64::from_bits(value(4)),
        })
    }
}

pub(super) struct Index {
    file: File,
    records: u64,
}
impl Index {
    /// Corrupt, stale or missing caches fall back to the source matrix. Verify
    /// the complete checksum and canonical coverage BEFORE yielding any edge.
    pub fn open(
        path: &Path,
        identity: &[u8; 32],
        scores: u64,
        lengths: Vec<usize>,
        cancel: &AtomicBool,
    ) -> Result<Option<Self>> {
        let read = || -> Result<Self> {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(
                    (rustix::fs::OFlags::NOFOLLOW
                        | rustix::fs::OFlags::NONBLOCK
                        | rustix::fs::OFlags::CLOEXEC)
                        .bits() as i32,
                )
                .open(path)?;
            if !file.metadata()?.is_file() {
                bail!("Invalid comparison index");
            }
            let len = file.metadata()?.len();
            if len < (HEADER + DIGEST) as u64
                || (len - (HEADER + DIGEST) as u64) % RECORD as u64 != 0
            {
                bail!("Invalid comparison index size");
            }
            // Both validation and use stream through a fixed-size buffer. The
            // metadata index never grows the helper's working memory with N².
            let mut reader = BufReader::with_capacity(128 * 1024, file.try_clone()?);
            let mut header = [0; HEADER];
            reader.read_exact(&mut header)?;
            if &header[..8] != MAGIC
                || &header[8..40] != identity
                || u64::from_le_bytes(header[40..48].try_into().unwrap()) != scores
            {
                bail!("Stale comparison index");
            }
            let records = (len - (HEADER + DIGEST) as u64) / RECORD as u64;
            let mut checksum = ring::digest::Context::new(&ring::digest::SHA256);
            let mut cursor = comparison::Cursor::new(lengths);
            for _ in 0..records {
                check_cancel(cancel)?;
                let mut bytes = [0; RECORD];
                reader.read_exact(&mut bytes)?;
                checksum.update(&bytes);
                let bound = Bounds::decode(&bytes)?;
                if (bound.profile, bound.a, bound.b) != (cursor.profile, cursor.a, cursor.b)
                    || bound.n == 0
                    || bound.n > comparison::MAX_CHUNK
                    || !bound.maximum.is_finite()
                    || !(-1.0..=1.0).contains(&bound.maximum)
                {
                    bail!("Invalid comparison index coverage");
                }
                cursor.advance(bound.n)?;
            }
            if cursor.completed != scores {
                bail!("Incomplete comparison index");
            }
            let mut digest = [0; DIGEST];
            reader.read_exact(&mut digest)?;
            if checksum.finish().as_ref() != digest {
                bail!("Invalid comparison index checksum");
            }
            Ok(Self { file, records })
        };
        let result = read();
        check_cancel(cancel)?;
        Ok(result.ok())
    }
    pub fn bounds(&mut self) -> Result<impl Iterator<Item = Result<Bounds>> + '_> {
        self.file.seek(SeekFrom::Start(HEADER as u64))?;
        let mut reader = BufReader::with_capacity(128 * 1024, &mut self.file);
        let mut remaining = self.records;
        Ok(std::iter::from_fn(move || {
            if remaining == 0 {
                return None;
            }
            remaining -= 1;
            Some((|| {
                let mut bytes = [0; RECORD];
                reader.read_exact(&mut bytes)?;
                Bounds::decode(&bytes)
            })())
        }))
    }
}

pub(super) struct Builder {
    file: tempfile::NamedTempFile,
    writer: BufWriter<File>,
    digest: ring::digest::Context,
    destination: PathBuf,
}
impl Builder {
    pub fn new(destination: PathBuf, identity: &[u8; 32], scores: u64) -> Result<Self> {
        let parent = destination
            .parent()
            .context("Missing comparison index directory")?;
        private_dir(parent)?;
        let file = tempfile::NamedTempFile::new_in(parent)?;
        let mut writer = BufWriter::with_capacity(128 * 1024, file.as_file().try_clone()?);
        writer.write_all(MAGIC)?;
        writer.write_all(identity)?;
        writer.write_all(&scores.to_le_bytes())?;
        Ok(Self {
            file,
            writer,
            digest: ring::digest::Context::new(&ring::digest::SHA256),
            destination,
        })
    }
    pub fn push(&mut self, bound: Bounds) -> Result<()> {
        let bytes = bound.encode();
        self.writer.write_all(&bytes)?;
        self.digest.update(&bytes);
        Ok(())
    }
    pub fn finish(mut self) -> Result<()> {
        self.writer.write_all(self.digest.finish().as_ref())?;
        self.writer.flush()?;
        self.file.as_file().sync_all()?;
        self.file.persist(self.destination)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn build(path: &Path, identity: &[u8; 32]) {
        let mut builder = Builder::new(path.to_owned(), identity, 6).unwrap();
        for (a, b, n, maximum) in [(0, 1, 3, 0.9), (1, 2, 2, 0.94), (2, 3, 1, 1.0)] {
            builder
                .push(Bounds {
                    profile: 0,
                    a,
                    b,
                    n,
                    maximum,
                })
                .unwrap();
        }
        builder.finish().unwrap();
    }
    #[test]
    fn validates_bounds_inclusive_thresholds_identity_and_corruption() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("index");
        let id = [17; 32];
        build(&path, &id);
        let mut index = Index::open(&path, &id, 6, vec![4], &AtomicBool::new(false))
            .unwrap()
            .unwrap();
        assert_eq!(
            index
                .bounds()
                .unwrap()
                .filter(|b| b.as_ref().unwrap().maximum >= 0.94)
                .count(),
            2
        );
        assert!(
            Index::open(&path, &[18; 32], 6, vec![4], &AtomicBool::new(false))
                .unwrap()
                .is_none()
        );
        drop(index);
        let mut bytes = std::fs::read(&path).unwrap();
        bytes[HEADER + 32] ^= 1;
        std::fs::write(&path, bytes).unwrap();
        assert!(Index::open(&path, &id, 6, vec![4], &AtomicBool::new(false))
            .unwrap()
            .is_none());
    }
    #[test]
    fn partial_cancelled_and_wrong_coverage_indexes_are_not_usable() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("index");
        let id = [7; 32];
        {
            let mut b = Builder::new(path.clone(), &id, 6).unwrap();
            b.push(Bounds {
                profile: 0,
                a: 0,
                b: 1,
                n: 3,
                maximum: 0.9,
            })
            .unwrap();
        }
        assert!(!path.exists());
        build(&path, &id);
        assert!(Index::open(&path, &id, 6, vec![4], &AtomicBool::new(true)).is_err());
        assert!(Index::open(&path, &id, 6, vec![5], &AtomicBool::new(false))
            .unwrap()
            .is_none());
    }
}

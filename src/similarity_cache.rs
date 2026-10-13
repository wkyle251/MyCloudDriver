//! Private, lossless cache for FileTwin vectors. JSON remains the temporary
//! interoperability format; persistent data stores exact little-endian f32
//! bits in byte planes before Zstandard compression.
use super::*;
use filetwin_core::api::{
    Counts, FilePath, FileRecord, FileState, Summary, VectorFile, SCHEMA_VERSION,
    VECTOR_FILE_FORMAT,
};
use rustix::fs::{flock, openat, FlockOperation, Mode, OFlags, CWD};
use std::{collections::BTreeMap, fs::File, io::Read};

const MAGIC: &[u8; 8] = b"MCDVEC01";
const FILENAME: &str = "filetwin-vectors.f32.zst";
const LEGACY_FILENAME: &str = "filetwin-vectors.json";
const MAX_VECTOR_BYTES: usize = 128 * 1024 * 1024;
const MAX_METADATA_BYTES: usize = 64 * 1024 * 1024;
const MAX_PAYLOAD_BYTES: usize = MAX_VECTOR_BYTES + MAX_METADATA_BYTES + 8;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Metadata {
    records: Vec<FileRecord>,
    dimensions: Vec<usize>,
}

pub(super) struct VectorCache {
    records: BTreeMap<(String, String), FileRecord>,
    bytes: usize,
    directory: PathBuf,
}

impl VectorCache {
    pub(super) fn load(directory: &Path) -> Self {
        let mut cache = Self {
            records: Default::default(),
            bytes: 0,
            directory: directory.into(),
        };
        // A cache is disposable. An interrupted or corrupt cache must never
        // prevent a scan; a valid legacy file is a useful migration fallback.
        let records = read_compressed(&directory.join(FILENAME)).or_else(|_| {
            filetwin_core::read_vectors(&directory.join(LEGACY_FILENAME))
                .map(|bundle| bundle.files)
                .map_err(anyhow::Error::from)
        });
        if let Ok(records) = records {
            for record in records {
                cache.add(&record);
            }
        }
        cache
    }

    pub(super) fn add(&mut self, record: &FileRecord) {
        if validate_record(record).is_err() {
            return;
        }
        let (Some(id), Some(profile), Some(vector)) =
            (&record.file_id, &record.profile_id, &record.vector)
        else {
            return;
        };
        let key = (id.clone(), profile.clone());
        let bytes = vector.len() * 4;
        if self.records.contains_key(&key) || self.bytes + bytes > MAX_VECTOR_BYTES {
            return;
        }
        let mut record = record.clone();
        record.reused = false;
        // These are labels, never paths used to reopen a source file.
        record.path = FilePath::Utf8(format!(
            "{}-{}",
            id.trim_start_matches("sha256:"),
            profile.trim_start_matches("sha256:")
        ));
        self.bytes += bytes;
        self.records.insert(key, record);
    }

    /// A temporary FileTwin-compatible JSON snapshot, automatically removed
    /// with the scan's private temporary directory.
    pub(super) fn write(&self, path: &Path) -> Result<()> {
        filetwin_core::write_vectors(path, &self.bundle())?;
        Ok(())
    }

    pub(super) fn save(&self) -> Result<()> {
        private_dir(&self.directory)?;
        let lock = private_file(&self.directory.join("filetwin-vectors.lock"), true)?;
        lock.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        // App windows/helper processes can finish together. Merge under the
        // account-local lock, so the last finisher cannot erase new vectors
        // written by another scan after this scan took its initial snapshot.
        flock(&lock, FlockOperation::LockExclusive)?;
        let mut merged = Self::load(&self.directory);
        for record in self.records.values() {
            merged.add(record);
        }
        let payload = encode_payload(merged.records.values().cloned().collect())?;
        let mut temporary = tempfile::NamedTempFile::new_in(&self.directory)?;
        temporary
            .as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))?;
        temporary.write_all(MAGIC)?;
        temporary.write_all(&(payload.len() as u64).to_le_bytes())?;
        temporary.write_all(ring::digest::digest(&ring::digest::SHA256, &payload).as_ref())?;
        {
            let mut encoder = zstd::stream::Encoder::new(&mut temporary, 9)?;
            encoder.include_checksum(true)?;
            encoder.write_all(&payload)?;
            encoder.finish()?;
        }
        temporary.as_file().sync_all()?;
        let target = self.directory.join(FILENAME);
        if let Ok(meta) = std::fs::symlink_metadata(&target) {
            if !meta.is_file() || meta.file_type().is_symlink() {
                bail!("The vector cache is not a regular private file.");
            }
        }
        temporary.persist(&target)?;
        File::open(&self.directory)?.sync_all()?;
        // Delete only a recognised legacy cache and only after the compressed
        // replacement is durably published. No source files are touched.
        let legacy = self.directory.join(LEGACY_FILENAME);
        if std::fs::symlink_metadata(&legacy)
            .is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
            && filetwin_core::read_vectors(&legacy).is_ok()
        {
            std::fs::remove_file(legacy)?;
            File::open(&self.directory)?.sync_all()?;
        }
        Ok(())
    }

    fn bundle(&self) -> VectorFile {
        let n = self.records.len() as u64;
        VectorFile {
            format: VECTOR_FILE_FORMAT.into(),
            schema_version: SCHEMA_VERSION,
            directory: FilePath::from_path(&self.directory),
            complete: true,
            files: self.records.values().cloned().collect(),
            summary: Summary {
                counts: Counts {
                    files_discovered: n,
                    files_processed: n,
                    files_total: Some(n),
                    files_ready: n,
                    vectors_encoded: n,
                    ..Counts::default()
                },
                elapsed_seconds: 0.0,
                backend: filetwin_core::profile::Backend::Cpu,
                workers: 1,
                cancelled: false,
            },
        }
    }
}

fn private_file(path: &Path, create: bool) -> Result<File> {
    let flags = OFlags::CLOEXEC
        | OFlags::NOFOLLOW
        | OFlags::NONBLOCK
        | if create {
            OFlags::RDWR | OFlags::CREATE
        } else {
            OFlags::RDONLY
        };
    let file = File::from(openat(CWD, path, flags, Mode::from_raw_mode(0o600))?);
    if !file.metadata()?.is_file() {
        bail!("The vector cache must be a regular file.");
    }
    Ok(file)
}

pub(super) fn validate_record(record: &FileRecord) -> Result<()> {
    let valid_sha = |id: &str| {
        id.strip_prefix("sha256:").is_some_and(|s| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
    };
    if record.state != FileState::Ready
        || record.bytes.is_none()
        || record.error.is_some()
        || !record.file_id.as_deref().is_some_and(valid_sha)
    {
        bail!("Invalid cached file metadata.");
    }
    let profile = filetwin_core::profile::find(
        record
            .profile_id
            .as_deref()
            .context("Missing vector profile")?,
    )?;
    let vector = record.vector.as_ref().context("Missing cached vector")?;
    if vector.len() != profile.dimensions || record.family.as_deref() != Some(&profile.family) {
        bail!("Cached vector profile does not match its data.");
    }
    let norm: f64 = vector.iter().map(|v| f64::from(*v).powi(2)).sum();
    if !norm.is_finite() || (norm - 1.0).abs() > 1e-5 {
        bail!("Invalid cached vector normalization.");
    }
    let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
    for value in vector {
        hash.update(&value.to_le_bytes());
    }
    if record.vector_sha256.as_deref() != Some(hex::encode(hash.finish().as_ref()).as_str()) {
        bail!("Cached vector checksum does not match.");
    }
    Ok(())
}

pub(super) fn encode_payload(mut records: Vec<FileRecord>) -> Result<Vec<u8>> {
    let dimensions: Vec<_> = records
        .iter()
        .map(|r| r.vector.as_ref().map_or(0, Vec::len))
        .collect();
    let count = dimensions
        .iter()
        .try_fold(0usize, |sum, n| sum.checked_add(*n))
        .context("Vector size overflow")?;
    if count > MAX_VECTOR_BYTES / 4 {
        bail!("The vector cache exceeds its memory allowance.");
    }
    // Each plane contains one byte from every f32. Similar exponents/sign bits
    // then compress together without rounding, quantisation or score changes.
    let mut shuffled = vec![0u8; count * 4];
    let mut offset = 0;
    for record in &mut records {
        for value in record.vector.take().context("Missing cached vector")? {
            for (plane, byte) in value.to_le_bytes().iter().enumerate() {
                shuffled[plane * count + offset] = *byte;
            }
            offset += 1;
        }
    }
    let metadata = serde_json::to_vec(&Metadata {
        records,
        dimensions,
    })?;
    if metadata.len() > MAX_METADATA_BYTES {
        bail!("The vector cache metadata is too large.");
    }
    let mut payload = Vec::with_capacity(8 + metadata.len() + shuffled.len());
    payload.extend_from_slice(&(metadata.len() as u64).to_le_bytes());
    payload.extend_from_slice(&metadata);
    payload.extend_from_slice(&shuffled);
    Ok(payload)
}

pub(super) fn decode_payload(payload: &[u8]) -> Result<Vec<FileRecord>> {
    if payload.len() < 8 || payload.len() > MAX_PAYLOAD_BYTES {
        bail!("Invalid cache payload size.");
    }
    let meta_len = u64::from_le_bytes(payload[..8].try_into()?) as usize;
    if meta_len > MAX_METADATA_BYTES || meta_len > payload.len() - 8 {
        bail!("Invalid cache metadata size.");
    }
    let mut metadata: Metadata = serde_json::from_slice(&payload[8..8 + meta_len])?;
    if metadata.records.len() != metadata.dimensions.len() {
        bail!("Invalid cache record count.");
    }
    let count = metadata
        .dimensions
        .iter()
        .try_fold(0usize, |sum, n| sum.checked_add(*n))
        .context("Vector size overflow")?;
    let shuffled = &payload[8 + meta_len..];
    if count > MAX_VECTOR_BYTES / 4 || shuffled.len() != count * 4 {
        bail!("Invalid vector data size.");
    }
    let mut offset = 0;
    for (record, dimensions) in metadata.records.iter_mut().zip(metadata.dimensions) {
        if record.vector.is_some() {
            bail!("Unexpected vector in cache metadata.");
        }
        let vector = (offset..offset + dimensions)
            .map(|i| {
                f32::from_le_bytes([
                    shuffled[i],
                    shuffled[count + i],
                    shuffled[2 * count + i],
                    shuffled[3 * count + i],
                ])
            })
            .collect();
        offset += dimensions;
        record.vector = Some(vector);
        validate_record(record)?;
    }
    Ok(metadata.records)
}

fn read_compressed(path: &Path) -> Result<Vec<FileRecord>> {
    let mut file = private_file(path, false)?;
    if file.metadata()?.len() > (MAX_PAYLOAD_BYTES + 1024 * 1024) as u64 {
        bail!("Compressed cache is too large.");
    }
    let mut header = [0u8; 48];
    file.read_exact(&mut header)?;
    if &header[..8] != MAGIC {
        bail!("Unsupported compressed vector cache format.");
    }
    let length = u64::from_le_bytes(header[8..16].try_into()?);
    if length > MAX_PAYLOAD_BYTES as u64 {
        bail!("Decompressed cache is too large.");
    }
    let mut decoder = zstd::stream::Decoder::new(file)?;
    decoder.window_log_max(26)?;
    let mut payload = Vec::new();
    decoder.take(length + 1).read_to_end(&mut payload)?;
    if payload.len() as u64 != length
        || ring::digest::digest(&ring::digest::SHA256, &payload).as_ref() != &header[16..48]
    {
        bail!("Compressed vector cache integrity check failed.");
    }
    decode_payload(&payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(seed: usize) -> FileRecord {
        let profile = filetwin_core::profile::text_profile();
        let mut vector = vec![0.0; profile.dimensions];
        // Normalised vectors can still contain signed zero and subnormals;
        // those bits must survive storage, migration and reuse unchanged.
        vector[0] = -0.0;
        vector[1] = 1.0;
        vector[2] = f32::from_bits(1);
        vector[3] = -f32::from_bits(3);
        let bytes: Vec<_> = vector.iter().flat_map(|v| v.to_le_bytes()).collect();
        FileRecord {
            path: FilePath::Utf8(format!("file-{seed}.txt")),
            file_id: Some(format!("sha256:{seed:064x}")),
            bytes: Some(123),
            state: FileState::Ready,
            family: Some("text".into()),
            profile_id: Some(profile.profile_id),
            vector: Some(vector),
            vector_sha256: Some(hex::encode(ring::digest::digest(
                &ring::digest::SHA256,
                &bytes,
            ))),
            reused: false,
            error: None,
            extraction: Some(json!({"coverage":"complete_source_text","characters":123})),
        }
    }

    fn bits(record: &FileRecord) -> Vec<u32> {
        record
            .vector
            .as_ref()
            .unwrap()
            .iter()
            .map(|v| v.to_bits())
            .collect()
    }

    #[test]
    fn compressed_cache_migrates_legacy_and_preserves_exact_f32_bits() {
        let dir = tempfile::tempdir().unwrap();
        let original = record(1);
        let mut cache = VectorCache::load(dir.path());
        cache.add(&original);
        let legacy = dir.path().join(LEGACY_FILENAME);
        cache.write(&legacy).unwrap();
        let legacy_bytes = std::fs::metadata(&legacy).unwrap().len();
        let migrated = VectorCache::load(dir.path());
        assert_eq!(migrated.records.len(), 1);
        migrated.save().unwrap();
        assert!(
            !legacy.exists(),
            "Migration removes plaintext only after successful publication"
        );
        let compressed = dir.path().join(FILENAME);
        assert!(std::fs::metadata(&compressed).unwrap().len() < legacy_bytes);
        assert_eq!(
            std::fs::metadata(&compressed).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let reloaded = VectorCache::load(dir.path());
        let loaded = reloaded.records.values().next().unwrap();
        assert_eq!(bits(loaded), bits(&original));
        assert_eq!(loaded.extraction, original.extraction);
        // FileTwin still accepts the temporary JSON interchange snapshot.
        let snapshot = dir.path().join("reuse.json");
        reloaded.write(&snapshot).unwrap();
        assert_eq!(
            bits(&filetwin_core::read_vectors(&snapshot).unwrap().files[0]),
            bits(&original)
        );
    }

    #[test]
    fn corruption_and_oversized_frames_are_discarded_with_legacy_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let mut cache = VectorCache::load(dir.path());
        cache.add(&record(1));
        cache.save().unwrap();
        let compressed = dir.path().join(FILENAME);
        let mut bytes = std::fs::read(&compressed).unwrap();
        bytes[16] ^= 1; // Corrupt the complete payload checksum.
        std::fs::write(&compressed, &bytes).unwrap();
        assert!(read_compressed(&compressed).is_err());
        assert!(VectorCache::load(dir.path()).records.is_empty());
        cache.write(&dir.path().join(LEGACY_FILENAME)).unwrap();
        assert_eq!(VectorCache::load(dir.path()).records.len(), 1);
        bytes[8..16].copy_from_slice(&(MAX_PAYLOAD_BYTES as u64 + 1).to_le_bytes());
        std::fs::write(&compressed, bytes).unwrap();
        assert!(read_compressed(&compressed)
            .unwrap_err()
            .to_string()
            .contains("too large"));
        // A subsequent valid scan repairs a corrupt cache atomically.
        cache.save().unwrap();
        assert_eq!(read_compressed(&compressed).unwrap().len(), 1);
        let mut truncated = std::fs::read(&compressed).unwrap();
        truncated.truncate(truncated.len() - 5);
        std::fs::write(&compressed, truncated).unwrap();
        assert!(read_compressed(&compressed).is_err());
    }

    #[test]
    fn concurrent_scan_snapshots_merge_instead_of_overwriting_each_other() {
        let dir = tempfile::tempdir().unwrap();
        let mut initial = VectorCache::load(dir.path());
        initial.add(&record(1));
        initial.save().unwrap();
        let mut a = VectorCache::load(dir.path());
        let mut b = VectorCache::load(dir.path());
        a.add(&record(2));
        b.add(&record(3));
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let other = barrier.clone();
        let thread = std::thread::spawn(move || {
            other.wait();
            a.save().unwrap();
        });
        barrier.wait();
        b.save().unwrap();
        thread.join().unwrap();
        assert_eq!(VectorCache::load(dir.path()).records.len(), 3);
    }

    #[test]
    fn cache_refuses_symlinks_and_bad_vectors() {
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let original = dir.path().join("original.txt");
        std::fs::write(&original, "untouched").unwrap();
        symlink(&original, dir.path().join(FILENAME)).unwrap();
        let mut cache = VectorCache::load(dir.path());
        let mut invalid = record(1);
        invalid.vector.as_mut().unwrap()[1] = 0.5;
        cache.add(&invalid);
        assert!(cache.records.is_empty());
        cache.add(&record(2));
        assert!(cache.save().is_err());
        assert_eq!(std::fs::read_to_string(original).unwrap(), "untouched");
    }
}

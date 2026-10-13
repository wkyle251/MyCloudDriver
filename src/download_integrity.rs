//! Checkpoints certify the bytes on disk, not just the remote range validator.
//! Hashes advance with accepted chunks; restoring a checkpoint reads its saved
//! regions once. No periodic checkpoint rescans the downloaded file.
use super::{fatal, transfer_control, DlError};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

const READ_CHUNK_BYTES: usize = 1 << 20;

/// One sequential disk stream, with at most one buffer being hashed and one
/// being filled. Hashing runs away from the HTTP executor. No file data is
/// retained after verification, and a disk turn is held only for actual I/O.
struct ReadHasher {
    result: Prefix, region_hash: Prefix, region_index: usize,
    offset: u64, total: u64, expected: std::sync::Arc<[(u64, u64, String)]>, retain_replay_tail: bool,
    partitions: Vec<u64>, pieces: Vec<Prefix>, piece_index: usize,
}
impl ReadHasher {
    fn update(&mut self, buffer: &[u8]) -> Result<(), DlError> {
        let mut used = 0;
        while used < buffer.len() && !self.partitions.is_empty() {
            while self.pieces[self.piece_index].bytes == self.partitions[self.piece_index] {
                self.piece_index += 1;
            }
            let piece = &mut self.pieces[self.piece_index];
            let take = (self.partitions[self.piece_index] - piece.bytes).min((buffer.len() - used) as u64) as usize;
            piece.update(&buffer[used..used + take]);
            used += take;
        }
        if !self.expected.is_empty() {
            let mut used = 0;
            while used < buffer.len() {
                let (region_offset, region_length, digest) = &self.expected[self.region_index];
                let take = (*region_offset + *region_length - (self.offset + self.result.bytes + used as u64))
                    .min((buffer.len() - used) as u64) as usize;
                self.region_hash.update(&buffer[used..used + take]); used += take;
                if self.region_hash.bytes == *region_length {
                    if self.region_hash.digest() != *digest {
                        return Err(DlError::Fatal(anyhow::anyhow!("Saved download bytes changed before finalization")));
                    }
                    self.region_index += 1; self.region_hash = Prefix::new();
                }
            }
        }
        if self.retain_replay_tail && self.result.bytes + buffer.len() as u64 == self.total {
            self.result.update_for_replay(buffer);
        } else { self.result.update(buffer); }
        Ok(())
    }
}

async fn read_chunk(
    file: &mut tokio::fs::File, verification: &Option<crate::download_verification::Guard>,
    buffer: &mut [u8], id: &str, diagnostic: &mut crate::download_telemetry::Operation,
) -> Result<(), DlError> {
    let mut wait = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::ReadTurnWait, id);
    let turn = match verification {
        Some(guard) => guard.chunk(buffer.len() as u64, id).await.map_err(DlError::Fatal)?,
        None => {
            transfer_control::disk_interruptible(id, std::future::ready(())).await.map_err(DlError::Fatal)?;
            None
        }
    };
    wait.complete(); drop(wait);
    let mut io = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::ReadIo, id);
    // Finish the bounded read before releasing its turn, even if Quit/Cancel
    // arrives meanwhile. Dropping a tokio::fs read future does not cancel its
    // blocking I/O; releasing the gate early could overlap it with a writer.
    // Once a prefix starts reading, finish and cache that proof even if an
    // empty speculative request fails. Retrying earlier would reread it.
    crate::download_buffer::verification_started(id);
    file.read_exact(buffer).await.map_err(|error| fatal(error, "Cannot verify saved download progress"))?;
    io.add_bytes(buffer.len() as u64);io.complete();drop(io);drop(turn);
    diagnostic.add_bytes(buffer.len() as u64);
    #[cfg(test)]
    super::completion_tests::record_read(id, buffer.len() as u64);
    Ok(())
}

#[derive(Clone)]
pub(super) struct Prefix {
    context: ring::digest::Context,
    pub bytes: u64,
    restored_identity: Option<Identity>,
    /// A complete piece that was not read back: its digest from the journal, written after the data was synced.
    frozen: Option<String>,
    /// Only a restored piece awaiting EOF needs this one-byte rollback state.
    replay_tail: Option<Box<ring::digest::Context>>,
}

/// What a staging file looked like when a checkpoint synced it. A journal that carries this lets a resume trust the
/// checkpoint's saved piece digests while the file is exactly as it was left, and read everything back otherwise.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct SavedIdentity {
    device: u64,
    inode: u64,
    size: u64,
    modified_ns: i64,
    changed_ns: i64,
}
impl SavedIdentity {
    pub fn of(metadata: &std::fs::Metadata) -> Option<Self> {
        use std::os::unix::fs::MetadataExt;
        let nanoseconds = |seconds: i64, fraction: i64| seconds.checked_mul(1_000_000_000)?.checked_add(fraction);
        Some(Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            size: metadata.len(),
            modified_ns: nanoseconds(metadata.mtime(), metadata.mtime_nsec())?,
            changed_ns: nanoseconds(metadata.ctime(), metadata.ctime_nsec())?,
        })
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
struct Identity {
    device: u64,
    inode: u64,
    size: u64,
    modified: i128,
    changed: i128,
}
fn identity(metadata: &std::fs::Metadata) -> Identity {
    use std::os::unix::fs::MetadataExt;
    Identity {
        device: metadata.dev(),
        inode: metadata.ino(),
        size: metadata.len(),
        modified: i128::from(metadata.mtime()) * 1_000_000_000 + i128::from(metadata.mtime_nsec()),
        changed: i128::from(metadata.ctime()) * 1_000_000_000 + i128::from(metadata.ctime_nsec()),
    }
}
impl Prefix {
    pub fn new() -> Self {
        Self {
            context: ring::digest::Context::new(&ring::digest::SHA256),
            bytes: 0,
            restored_identity: None,
            frozen: None,
            replay_tail: None,
        }
    }
    /// A complete piece taken on trust from the journal. It stays bound to the file it was checked against, and can
    /// never take more bytes.
    pub fn frozen(bytes: u64, digest: String, metadata: &std::fs::Metadata) -> Self {
        Self {
            context: ring::digest::Context::new(&ring::digest::SHA256),
            bytes,
            restored_identity: Some(identity(metadata)),
            frozen: Some(digest),
            replay_tail: None,
        }
    }
    pub fn update(&mut self, bytes: &[u8]) {
        assert!(self.frozen.is_none() || bytes.is_empty(), "a verified piece cannot take more bytes");
        if !bytes.is_empty() {
            self.replay_tail = None;
        }
        self.context.update(bytes);
        self.bytes += bytes.len() as u64;
    }
    /// Keep the state before a piece's last byte. A retry can replay its EOF
    /// without reading the piece again. Called once per completed piece, not
    /// for each network chunk.
    pub fn update_for_replay(&mut self, bytes: &[u8]) {
        if let Some((tail, body)) = bytes.split_last() {
            self.update(body);
            let before_tail = Box::new(self.context.clone());
            self.update(std::slice::from_ref(tail));
            self.replay_tail = Some(before_tail);
        }
    }
    pub fn digest(&self) -> String {
        match &self.frozen {
            Some(digest) => digest.clone(),
            None => hex::encode(self.context.clone().finish()),
        }
    }
    pub fn rewind_for_replay(&mut self, bytes: u64) -> bool {
        if self.bytes.checked_sub(1) != Some(bytes) {
            return false;
        }
        let Some(context) = self.replay_tail.take() else { return false };
        self.context = *context;
        self.bytes = bytes;
        true
    }
    pub fn validate_restored(&self, metadata: &std::fs::Metadata) -> Result<(), DlError> {
        if self
            .restored_identity
            .is_some_and(|saved| saved != identity(metadata))
        {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Download staging file changed after verifying progress"
            )));
        }
        Ok(())
    }
    pub fn adopt_verified_metadata(&mut self, metadata: &std::fs::Metadata) {
        self.restored_identity = Some(identity(metadata));
    }
    /// Our staging rename changes ctime. Rebind only that field, after the
    /// controlled move, while preserving the exact file and verified bytes.
    pub fn adopt_renamed_metadata(&mut self, metadata: &std::fs::Metadata) -> Result<(), DlError> {
        let current = identity(metadata);
        if self.restored_identity.is_some_and(|saved| {
            saved.device != current.device
                || saved.inode != current.inode
                || saved.size != current.size
                || saved.modified != current.modified
        }) {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Download staging file changed while retaining its verified prefix"
            )));
        }
        self.restored_identity = Some(current);
        Ok(())
    }
    pub async fn read(
        path: &Path,
        offset: u64,
        bytes: u64,
        control_id: &str,
    ) -> Result<Self, DlError> {
        Self::read_inner(path, offset, bytes, &[], false, &[], control_id).await.map(|result| result.0)
    }
    pub async fn read_for_replay(
        path: &Path,
        offset: u64,
        bytes: u64,
        control_id: &str,
    ) -> Result<Self, DlError> {
        Self::read_inner(path, offset, bytes, &[], true, &[], control_id).await.map(|result| result.0)
    }
    /// Recover a sequential checkpoint and its future range-piece contexts in
    /// the same physical pass. The caller still compares the whole-prefix digest.
    pub async fn read_partitioned(path: &Path, bytes: u64, partitions: &[u64], control_id: &str)
        -> Result<(Self, Vec<Self>), DlError> {
        if partitions.iter().try_fold(0u64, |sum, size| sum.checked_add(*size)) != Some(bytes) {
            return Err(DlError::Fatal(anyhow::anyhow!("Invalid checkpoint partition coverage")));
        }
        Self::read_inner(path, 0, bytes, &[], false, partitions, control_id).await
    }
    pub async fn read_verified(
        path: &Path,
        bytes: u64,
        expected: &[(u64, u64, String)],
        control_id: &str,
    ) -> Result<Self, DlError> {
        let mut covered = 0;
        for (offset, length, _) in expected {
            if *offset != covered || *length == 0 {
                return Err(DlError::Fatal(anyhow::anyhow!(
                    "Invalid checkpoint checksum coverage"
                )));
            }
            covered = covered.checked_add(*length).ok_or_else(|| {
                DlError::Fatal(anyhow::anyhow!("Invalid checkpoint checksum coverage"))
            })?;
        }
        if covered != bytes {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Incomplete checkpoint checksum coverage"
            )));
        }
        Self::read_inner(path, 0, bytes, expected, false, &[], control_id).await.map(|result| result.0)
    }
    async fn read_inner(
        path: &Path,
        offset: u64,
        bytes: u64,
        expected: &[(u64, u64, String)],
        retain_replay_tail: bool,
        partitions: &[u64],
        control_id: &str,
    ) -> Result<(Self, Vec<Self>), DlError> {
        let mut diagnostic = crate::download_telemetry::Operation::new(
            if expected.is_empty() { crate::download_telemetry::Kind::ResumeRead }
            else { crate::download_telemetry::Kind::FinalRead }, control_id);
        let mut file = crate::download_fs::open_async(path, rustix::fs::OFlags::RDONLY)
            .await
            .map_err(|error| fatal(error, "Cannot verify saved download progress"))?;
        let mut gate_wait = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::ReadGateWait, control_id);
        let verification = crate::download_verification::acquire_async(&file, control_id, bytes)
            .await
            .map_err(|error| {
                if error.is::<crate::download_verification::Deferred>() { diagnostic.deferred(); gate_wait.deferred(); }
                DlError::Fatal(error)
            })?;
        gate_wait.complete();drop(gate_wait);
        let before = file
            .metadata()
            .await
            .map_err(|error| fatal(error, "Cannot inspect saved download progress"))?;
        crate::download_fs::validate_open_file(path, &before)
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        if offset
            .checked_add(bytes)
            .is_none_or(|end| end > before.len())
        {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Saved download progress was truncated"
            )));
        }
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|error| fatal(error, "Cannot seek saved download progress"))?;
        let mut hasher = ReadHasher { result: Self::new(), region_hash: Self::new(), region_index: 0,
            offset, total: bytes, expected: expected.to_vec().into(), retain_replay_tail,
            partitions: partitions.to_vec(), pieces: partitions.iter().map(|_| Self::new()).collect(), piece_index: 0 };
        if bytes > 0 {
            let capacity = bytes.min(READ_CHUNK_BYTES as u64) as usize;
            let mut buffer = vec![0; capacity];let mut spare = vec![0; capacity];
            let mut count = capacity;let mut received = count as u64;
            read_chunk(&mut file, &verification, &mut buffer[..count], control_id, &mut diagnostic).await?;
            loop {
                let id = control_id.to_owned();
                let hash = tokio::task::spawn_blocking(move || {
                    let mut timing = crate::download_telemetry::Operation::new(crate::download_telemetry::Kind::ReadHash, &id);
                    hasher.update(&buffer[..count])?;
                    timing.add_bytes(count as u64);timing.complete();
                    Ok::<_, DlError>((hasher, buffer))
                });
                let next = (bytes - received).min(capacity as u64) as usize;
                // Await both sides even on checksum failure so an outstanding
                // file read finishes before its reader permit can be released.
                let (hashed, read) = if next > 0 {
                    let (hashed, read) = tokio::join!(hash,
                        read_chunk(&mut file, &verification, &mut spare[..next], control_id, &mut diagnostic));
                    (hashed, read)
                } else { (hash.await, Ok(())) };
                let (state, previous) = hashed.map_err(|error| fatal(error, "Cannot hash saved download progress"))??;
                read?;hasher = state;
                if next == 0 { break; }
                buffer = spare;spare = previous;count = next;received += next as u64;
            }
        }
        let mut result = hasher.result;
        let after = file
            .metadata()
            .await
            .map_err(|error| fatal(error, "Cannot inspect verified download progress"))?;
        crate::download_fs::validate_open_file(path, &after)
            .map_err(|error| fatal(error, "Download staging file changed"))?;
        if identity(&before) != identity(&after) {
            return Err(DlError::Fatal(anyhow::anyhow!(
                "Download staging file changed while verifying progress"
            )));
        }
        result.restored_identity = Some(identity(&after));
        for piece in &mut hasher.pieces { piece.adopt_verified_metadata(&after); }
        diagnostic.complete();
        Ok((result, hasher.pieces))
    }
}

#[cfg(test)]
pub(super) fn fixture_digest(path: &Path, offset: u64, bytes: u64) -> String {
    use std::io::{Read, Seek};
    let mut file = crate::download_fs::open(path, rustix::fs::OFlags::RDONLY).unwrap();
    file.seek(std::io::SeekFrom::Start(offset)).unwrap();
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut remaining = bytes;
    let mut buffer = [0; 256 * 1024];
    while remaining > 0 {
        let count = remaining.min(buffer.len() as u64) as usize;
        file.read_exact(&mut buffer[..count]).unwrap();
        context.update(&buffer[..count]);
        remaining -= count as u64;
    }
    hex::encode(context.finish())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn pipelined_checks_preserve_cross_buffer_piece_proofs_offsets_and_eof_replay() {
        let directory = tempfile::tempdir().unwrap();let path = directory.path().join("generated.part");
        let data: Vec<u8> = (0..3 * READ_CHUNK_BYTES + 23).map(|index| (index % 251) as u8).collect();
        std::fs::write(&path, &data).unwrap();
        let digest = |bytes: &[u8]| hex::encode(ring::digest::digest(&ring::digest::SHA256, bytes));
        let boundaries = [0, 37, READ_CHUNK_BYTES - 7, READ_CHUNK_BYTES + 9, 2 * READ_CHUNK_BYTES + 5, data.len()];
        let proof: Vec<_> = boundaries.windows(2).map(|range|
            (range[0] as u64, (range[1] - range[0]) as u64, digest(&data[range[0]..range[1]]))).collect();
        let verified = Prefix::read_verified(&path, data.len() as u64, &proof, "generated-pipeline-proof").await.map_err(DlError::into_inner).unwrap();
        assert_eq!(verified.digest(), digest(&data));
        let mut offset = Prefix::read_for_replay(&path, 13, (data.len() - 17) as u64, "generated-pipeline-offset").await.map_err(DlError::into_inner).unwrap();
        assert_eq!(offset.digest(), digest(&data[13..data.len() - 4]));
        assert!(offset.rewind_for_replay((data.len() - 18) as u64));
        assert_eq!(offset.digest(), digest(&data[13..data.len() - 5]));
        for length in [0, 1, READ_CHUNK_BYTES, READ_CHUNK_BYTES + 1] {
            let hash = Prefix::read(&path, 0, length as u64, "generated-pipeline-boundary").await.map_err(DlError::into_inner).unwrap();
            assert_eq!(hash.digest(), digest(&data[..length]));
        }
        let mut wrong = proof.clone();wrong[1].2 = "00".repeat(32);
        assert!(Prefix::read_verified(&path, data.len() as u64, &wrong, "generated-pipeline-bad-proof").await.is_err());
        std::fs::write(&path, &data[..READ_CHUNK_BYTES + 3]).unwrap();
        assert!(Prefix::read_verified(&path, data.len() as u64, &proof, "generated-pipeline-truncated").await.is_err());
    }

    #[tokio::test]
    #[ignore = "generated cached-file timing comparison; run explicitly on a quiet machine"]
    async fn synthetic_read_hash_pipeline_benchmark() {
        use std::{io::Write, time::Instant};
        let directory = tempfile::tempdir().unwrap();let path = directory.path().join("generated.part");
        let chunk: Vec<u8> = (0..READ_CHUNK_BYTES).map(|index| (index % 251) as u8).collect();
        let mut file = std::fs::File::create(&path).unwrap();
        for _ in 0..128 { file.write_all(&chunk).unwrap(); }file.sync_all().unwrap();drop(file);
        let size = 128u64 << 20;let mut legacy = Vec::new();let mut pipeline = Vec::new();
        for round in 0..8 {
            // Reverse the order every round so warming/cache/order cannot
            // systematically favor either reader. Both hash every byte.
            let mut digests = Vec::new();
            for old in [round % 2 == 0, round % 2 != 0] {
                let start = Instant::now();
                let hash = if old {
                    let mut file = crate::download_fs::open_async(&path, rustix::fs::OFlags::RDONLY).await.unwrap();
                    let mut buffer = vec![0; 256 << 10];let mut result = Prefix::new();
                    while result.bytes < size {
                        transfer_control::disk_interruptible("generated-legacy-read", file.read_exact(&mut buffer)).await.unwrap().unwrap();
                        result.update(&buffer);
                    }
                    result
                } else { Prefix::read(&path, 0, size, "generated-pipeline-read").await.map_err(DlError::into_inner).unwrap() };
                let elapsed = start.elapsed().as_secs_f64();digests.push(hash.digest());
                if old { legacy.push(elapsed); } else { pipeline.push(elapsed); }
            }
            assert_eq!(digests[0], digests[1]);
        }
        legacy.sort_by(f64::total_cmp);pipeline.sort_by(f64::total_cmp);
        println!("GENERATED_PIPELINE_BENCH {{\"bytes_per_pass\":{size},\"rounds\":8,\"legacy_median_s\":{},\"pipeline_median_s\":{},\"legacy_MiB_s\":{},\"pipeline_MiB_s\":{},\"scope\":\"cached generated file; does not measure HDD speed\"}}",
            legacy[4], pipeline[4], 128. / legacy[4], 128. / pipeline[4]);
    }
    #[tokio::test]
    #[ignore = "generated-file performance comparison; run explicitly on a quiet machine"]
    async fn synthetic_eof_replay_benchmark() {
        use std::time::Instant;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("generated.part");
        let size = 16u64 << 20;
        std::fs::write(&path, vec![0x5a; size as usize]).unwrap();
        let baseline_reads = super::super::completion_tests::ReadCounter::new("generated-replay-baseline");
        let optimized_reads = super::super::completion_tests::ReadCounter::new("generated-replay-optimized");
        let mut baseline_times = Vec::new();
        let mut optimized_times = Vec::new();
        for _ in 0..7 {
            let started = Instant::now();
            let full = Prefix::read(&path, 0, size, "generated-replay-baseline").await.map_err(DlError::into_inner).unwrap();
            let replay = Prefix::read(&path, 0, size - 1, "generated-replay-baseline").await.map_err(DlError::into_inner).unwrap();
            baseline_times.push(started.elapsed().as_secs_f64());
            let started = Instant::now();
            let mut optimized = Prefix::read_for_replay(&path, 0, size, "generated-replay-optimized").await.map_err(DlError::into_inner).unwrap();
            assert_eq!(full.digest(), optimized.digest());
            assert!(optimized.rewind_for_replay(size - 1));
            assert_eq!(replay.digest(), optimized.digest());
            optimized_times.push(started.elapsed().as_secs_f64());
        }
        assert_eq!(baseline_reads.bytes(), 7 * (2 * size - 1));
        assert_eq!(optimized_reads.bytes(), 7 * size);
        baseline_times.sort_by(f64::total_cmp);
        optimized_times.sort_by(f64::total_cmp);
        println!("SYNTHETIC EOF replay: old_bytes_per_resume={} new_bytes_per_resume={} old_median_seconds={:.6} new_median_seconds={:.6}",
            2 * size - 1, size, baseline_times[3], optimized_times[3]);
    }
    #[tokio::test]
    async fn eof_replay_reuses_the_prefix_state_across_hash_and_read_boundaries() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("generated.part");
        let bytes: Vec<u8> = (0..262_152).map(|index| (index % 251) as u8).collect();
        std::fs::write(&path, &bytes).unwrap();
        for length in [1u64, 63, 64, 65, 262_144, 262_145] {
            let mut hash = Prefix::read_for_replay(&path, 7, length, "generated-replay").await.map_err(DlError::into_inner).unwrap();
            let digest = |data: &[u8]| hex::encode(ring::digest::digest(&ring::digest::SHA256, data));
            assert_eq!(hash.digest(), digest(&bytes[7..7 + length as usize]));
            assert!(!hash.rewind_for_replay(length), "unrelated coverage changes must not consume the saved state");
            hash.update(&[]);
            assert!(hash.rewind_for_replay(length - 1));
            assert_eq!(hash.digest(), digest(&bytes[7..6 + length as usize]));
            assert!(!hash.rewind_for_replay(length.saturating_sub(2)), "the rollback is usable only once");
            hash.update(&bytes[6 + length as usize..7 + length as usize]);
            assert_eq!(hash.digest(), digest(&bytes[7..7 + length as usize]));
            hash.validate_restored(&std::fs::metadata(&path).unwrap()).map_err(DlError::into_inner).unwrap();
        }
        let mut hash = Prefix::read_for_replay(&path, 0, 64, "generated-replay-change").await.map_err(DlError::into_inner).unwrap();
        std::fs::write(&path, b"changed").unwrap();
        assert!(hash.rewind_for_replay(63));
        assert!(hash.validate_restored(&std::fs::metadata(&path).unwrap()).is_err(), "saved hash state must not accept changed staging data");
        let mut frozen = Prefix::frozen(7, "aa".repeat(32), &std::fs::metadata(&path).unwrap());
        assert!(!frozen.rewind_for_replay(6), "a saved digest is not a resumable hashing state");
    }
    #[tokio::test]
    async fn controlled_rename_rebinds_ctime_without_accepting_replacement_or_edits() {
        for mutation in ["rename", "replace", "edit"] {
            let directory = tempfile::tempdir().unwrap();
            let source = directory.path().join("generated.part");
            let moved = directory.path().join("generated.ranges.data");
            std::fs::write(&source, b"abcdefgh").unwrap();
            let mut hash = Prefix::read(&source, 0, 8, "synthetic-rename")
                .await
                .map_err(DlError::into_inner)
                .unwrap();
            crate::download_fs::rename(&source, &moved).unwrap();
            if mutation == "replace" {
                let replacement = directory.path().join("replacement");
                std::fs::write(&replacement, b"BAD-DATA").unwrap();
                std::fs::rename(replacement, &moved).unwrap();
            } else if mutation == "edit" {
                std::fs::write(&moved, b"BAD-DATA").unwrap();
            }
            let metadata = crate::download_fs::metadata(&moved).unwrap();
            assert_eq!(
                hash.adopt_renamed_metadata(&metadata).is_ok(),
                mutation == "rename"
            );
            if mutation == "rename" {
                hash.validate_restored(&metadata)
                    .map_err(DlError::into_inner)
                    .unwrap();
            }
        }
    }
    #[test]
    fn saved_region_verification_honors_pause_and_cancel_in_isolated_process() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "download_transport::integrity::tests::control_child",
                "--ignored",
                "--nocapture",
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    #[tokio::test]
    #[ignore = "isolated controls; launched by saved_region_verification_honors_pause_and_cancel_in_isolated_process"]
    async fn control_child() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("generated.part");
        let control = directory.path().join("controls.json");
        std::fs::write(&path, b"abcdefgh").unwrap();
        std::env::set_var("MYCLOUDDRIVER_TRANSFER_CONTROL", &control);
        std::fs::write(&control, br#"{"actions":{"synthetic-file":"pause"}}"#).unwrap();
        let paused = Prefix::read(&path, 0, 8, "synthetic-file")
            .await
            .err()
            .unwrap()
            .into_inner();
        assert!(paused.is::<transfer_control::Paused>());
        std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(110)).await;
        let restored = Prefix::read(&path, 0, 8, "synthetic-file")
            .await
            .map_err(DlError::into_inner)
            .unwrap();
        assert_eq!(restored.digest(), fixture_digest(&path, 0, 8));
        std::fs::write(&control, br#"{"actions":{"synthetic-file":"cancel"}}"#).unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(110)).await;
        let cancelled = Prefix::read(&path, 0, 8, "synthetic-file")
            .await
            .err()
            .unwrap()
            .into_inner();
        assert!(cancelled.is::<transfer_control::Cancelled>());
        assert_eq!(std::fs::read(&path).unwrap(), b"abcdefgh");
    }
}

//! Confirmed password exclusions. Names alone never establish encryption.
use filetwin_core::{
    api::{FilePath, FileRecord, FileState},
    Error, ErrorCode,
};
#[path = "similarity_password_rar.rs"]
pub(super) mod rar;

pub(super) const CACHE_KEY: &str = "password-v1";
// Maximum comment + legacy end record + ZIP64 locator. The separate ZIP64
// record may still need a small range read when the comment fills this tail.
pub(super) const ZIP_TAIL: u64 = 65_535 + 22 + 20;
pub(super) const ZIP_DIRECTORY_LIMIT: u64 = 256 << 10;

#[derive(Debug, Clone, thiserror::Error)]
#[error("Password-protected file skipped")]
pub(super) struct Protected {
    pub bytes: u64,
    pub revision: Option<String>,
}

pub(super) fn error() -> Error {
    Error::new(
        ErrorCode::UnsupportedFormat,
        "password",
        "Password-protected file skipped; a password is required to analyse its contents",
    )
}

pub(super) fn record(bytes: u64) -> FileRecord {
    FileRecord {
        path: FilePath::Utf8("protected".into()),
        file_id: None,
        bytes: Some(bytes),
        state: FileState::Unsupported,
        family: None,
        profile_id: None,
        vector: None,
        vector_sha256: None,
        reused: false,
        error: Some(error()),
        extraction: None,
    }
}

pub(super) fn confirmed(record: &FileRecord) -> bool {
    matches!(record.state, FileState::Failed | FileState::Unsupported)
        && record.bytes.is_some()
        && record.profile_id.is_none()
        && record.vector.is_none()
        && record.vector_sha256.is_none()
        && record.file_id.as_deref().is_none_or(|id| {
            id.strip_prefix("sha256:").is_some_and(|hash| {
                hash.len() == 64
                    && hash
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
        })
        && record.error.as_ref().is_some_and(|e| {
            (e.code == ErrorCode::UnsupportedFormat && e.stage == "password")
                || (e.code == ErrorCode::DecodeFailed
                    && e.stage == "document"
                    && e.message == "unsupported Zip archive: Password required to decrypt file")
        })
}

pub(super) fn canonical(record: &FileRecord) -> FileRecord {
    let mut saved = record.clone();
    saved.state = FileState::Unsupported;
    saved.error = Some(error());
    saved.extraction = None;
    saved
}

pub(super) fn zip_candidate(name: &str) -> bool {
    std::path::Path::new(name)
        .extension()
        .and_then(|v| v.to_str())
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "zip" | "docx" | "xlsx" | "pptx" | "odt" | "ods" | "odp" | "epub" | "jar"
            )
        })
}

pub(super) fn archive_candidate(name: &str) -> bool {
    zip_candidate(name)
        || std::path::Path::new(name)
            .extension()
            .and_then(|v| v.to_str())
            .is_some_and(|extension| {
                let lower = extension.to_ascii_lowercase();
                lower == "rar"
                    || (lower.len() == 3
                        && lower.starts_with('r')
                        && lower.as_bytes()[1..].iter().all(u8::is_ascii_digit))
            })
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap())
}
fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn u64_at(bytes: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ZipDirectory {
    Entries { start: u64, length: u64 },
    // The fixed ZIP64 record can sit outside the tail (e.g. a long comment).
    Zip64 { start: u64, end: u64 },
}

pub(super) fn zip_prefix_encrypted(bytes: &[u8]) -> bool {
    bytes.len() >= 30 && bytes.starts_with(b"PK\x03\x04") && u16_at(bytes, 6) & 1 != 0
}

pub(super) fn zip_directory(tail: &[u8], size: u64) -> Option<ZipDirectory> {
    if tail.len() < 22 || tail.len() as u64 != size.min(ZIP_TAIL) {
        return None;
    }
    for offset in (0..=tail.len() - 22).rev() {
        let end = &tail[offset..];
        if !end.starts_with(b"PK\x05\x06") || 22 + u16_at(end, 20) as usize != end.len() {
            continue;
        }
        let entries = u16_at(end, 10);
        let length = u32_at(end, 12) as u64;
        let start = u32_at(end, 16) as u64;
        let end_offset = size - tail.len() as u64 + offset as u64;
        // PKWARE APPNOTE 4.3.14–16: ZIP64 offsets/counts live in a separate
        // record immediately before its locator, not in the legacy fields.
        if offset >= 20 && tail[offset - 20..offset - 16] == *b"PK\x06\x07" {
            let locator = &tail[offset - 20..offset];
            let start = u64_at(locator, 8);
            let end = end_offset - 20;
            if u32_at(locator, 4) != 0 || u32_at(locator, 16) != 1 || start.checked_add(56)? > end {
                return None;
            }
            return Some(ZipDirectory::Zip64 { start, end });
        }
        // Unknown and multi-volume layouts must never become cached password
        // exclusions by guess. A sentinel without its ZIP64 locator is invalid.
        if end[4..8] != [0; 4]
            || entries == 0
            || entries == u16::MAX
            || entries != u16_at(end, 8)
            || length == 0
            || length == u32::MAX as u64
            || start == u32::MAX as u64
            || start.checked_add(length)? > end_offset
        {
            return None;
        }
        return Some(ZipDirectory::Entries { start, length });
    }
    None
}

pub(super) fn zip64_directory(header: &[u8], start: u64, end: u64) -> Option<(u64, u64)> {
    if header.len() < 56 || !header.starts_with(b"PK\x06\x06") {
        return None;
    }
    let record_length = u64_at(header, 4);
    let entries = u64_at(header, 32);
    let length = u64_at(header, 40);
    let directory_start = u64_at(header, 48);
    if record_length < 44
        || start.checked_add(12)?.checked_add(record_length)? != end
        || u32_at(header, 16) != 0
        || u32_at(header, 20) != 0
        || entries == 0
        || u64_at(header, 24) != entries
        || length == 0
        || directory_start.checked_add(length)? > start
    {
        return None;
    }
    Some((directory_start, length))
}

pub(super) fn zip_directory_encrypted(bytes: &[u8]) -> bool {
    let mut offset = 0;
    while bytes.len().saturating_sub(offset) >= 46 {
        let entry = &bytes[offset..];
        if !entry.starts_with(b"PK\x01\x02") {
            return false;
        }
        let length = 46
            + u16_at(entry, 28) as usize
            + u16_at(entry, 30) as usize
            + u16_at(entry, 32) as usize;
        if length > entry.len() {
            return false;
        }
        if u16_at(entry, 8) & 1 != 0 {
            return true;
        }
        offset += length;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_status_requires_explicit_evidence() {
        let mut file = record(4096);
        assert!(confirmed(&file));
        file.state = FileState::Failed;
        file.error = Some(Error::new(
            ErrorCode::DecodeFailed,
            "document",
            "unsupported Zip archive: Password required to decrypt file",
        ));
        assert!(confirmed(&file));
        assert_eq!(canonical(&file).state, FileState::Unsupported);
        for message in [
            "Invalid ZIP",
            "password.txt was not found",
            "Decode timed out",
        ] {
            file.error = Some(Error::new(ErrorCode::DecodeFailed, "document", message));
            assert!(!confirmed(&file));
        }
        assert!(!zip_candidate("password-video.mp4"));
        assert!(zip_candidate("archive.ZIP"));
        for name in [
            "archive.rar",
            "archive.RAR",
            "set.part002.rar",
            "set.r00",
            "set.R99",
        ] {
            assert!(archive_candidate(name));
        }
        assert!(!archive_candidate("rar-password.txt"));
    }

    #[test]
    fn zip_flags_require_valid_record_boundaries() {
        let mut header = vec![0; 30];
        header[..4].copy_from_slice(b"PK\x03\x04");
        header[6] = 1;
        assert!(zip_prefix_encrypted(&header));
        assert!(!zip_prefix_encrypted(&header[..29]));
        header[6] = 0;
        assert!(!zip_prefix_encrypted(&header));
        let mut directory = vec![0; 92];
        directory[..4].copy_from_slice(b"PK\x01\x02");
        directory[46..50].copy_from_slice(b"PK\x01\x02");
        directory[54] = 1;
        assert!(zip_directory_encrypted(&directory));
        assert!(!zip_directory_encrypted(&directory[..91]));
        directory[28] = 1;
        assert!(!zip_directory_encrypted(&directory));
    }

    #[test]
    fn zip_directory_location_checks_lengths_comments_and_zip64() {
        let mut tail = vec![0; 68];
        tail[46..50].copy_from_slice(b"PK\x05\x06");
        tail[54] = 1;
        tail[56] = 1;
        tail[58] = 46;
        assert_eq!(
            zip_directory(&tail, 68),
            Some(ZipDirectory::Entries {
                start: 0,
                length: 46
            })
        );
        assert_eq!(zip_directory(&tail, 69), None);
        tail[66] = 1;
        assert_eq!(zip_directory(&tail, 68), None);
        tail.push(0);
        assert_eq!(
            zip_directory(&tail, 69),
            Some(ZipDirectory::Entries {
                start: 0,
                length: 46
            })
        );
        tail[56..58].copy_from_slice(&u16::MAX.to_le_bytes());
        assert_eq!(zip_directory(&tail, 69), None);
    }

    #[test]
    fn zip64_uses_full_width_offsets_and_rejects_invalid_records() {
        let size = (5u64 << 30) + ZIP_TAIL;
        let mut tail = vec![0; ZIP_TAIL as usize];
        let eocd = tail.len() - 22;
        tail[eocd..eocd + 4].copy_from_slice(b"PK\x05\x06");
        tail[eocd + 8..eocd + 12].fill(0xff);
        tail[eocd + 12..eocd + 20].fill(0xff);
        let locator = eocd - 20;
        tail[locator..locator + 4].copy_from_slice(b"PK\x06\x07");
        let start = size - 98;
        tail[locator + 8..locator + 16].copy_from_slice(&start.to_le_bytes());
        tail[locator + 16] = 1;
        assert_eq!(
            zip_directory(&tail, size),
            Some(ZipDirectory::Zip64 {
                start,
                end: size - 42
            })
        );
        let mut header = vec![0; 56];
        header[..4].copy_from_slice(b"PK\x06\x06");
        header[4] = 44;
        header[24] = 2;
        header[32] = 2;
        header[40] = 92;
        header[48..56].copy_from_slice(&(start - 92).to_le_bytes());
        assert_eq!(
            zip64_directory(&header, start, size - 42),
            Some((start - 92, 92))
        );
        assert_eq!(zip64_directory(&header[..55], start, size - 42), None);
        header[16] = 1;
        assert_eq!(zip64_directory(&header, start, size - 42), None);
        header[16] = 0;
        header[24] = 1;
        assert_eq!(zip64_directory(&header, start, size - 42), None);
        header[24] = 2;
        header[4..12].fill(0xff);
        assert_eq!(zip64_directory(&header, start, size - 42), None);
        tail[locator + 16] = 2;
        assert_eq!(zip_directory(&tail, size), None);
    }
}

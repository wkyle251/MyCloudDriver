//! Stable local names for provider metadata, partials and their sidecars.
//! Keep representable names unchanged so existing partials/receipts still work.
use anyhow::{bail, Result};
use std::path::{Path, PathBuf};
use unicode_normalization::UnicodeNormalization;

const COMPONENT_LIMIT: usize = 255;
const PART_SUFFIX: &str = ".part";

fn name_units(name: &str) -> usize {
    #[cfg(target_os = "macos")]
    {
        // APFS, HFS+ and ExFAT count Unicode units rather than UTF-8 bytes.
        // Decomposed UTF-16 also accommodates HFS+'s on-disk normalization.
        name.nfd().map(char::len_utf16).sum()
    }
    #[cfg(not(target_os = "macos"))]
    {
        name.len()
    }
}

fn name_digest(name: &str) -> String {
    let normalized: String = name.nfd().collect();
    hex::encode(ring::digest::digest(&ring::digest::SHA256, normalized.as_bytes()))
}

fn prefix_within(name: &str, limit: usize) -> &str {
    let mut units = 0;
    for (index, character) in name.char_indices() {
        units += name_units(&character.to_string());
        if units > limit {
            return &name[..index];
        }
    }
    name
}

pub(super) fn component(name: &str) -> Result<String> {
    let Some(base) = Path::new(name).file_name().and_then(|name| name.to_str()) else {
        bail!("refusing unsafe remote name: {name:?}");
    };
    if base.contains('\0') {
        bail!("refusing unsafe remote name: {name:?}");
    }
    let limit = COMPONENT_LIMIT - PART_SUFFIX.len();
    if name_units(base) <= limit {
        return Ok(base.to_owned());
    }
    // A bounded extension keeps the file usable in Finder. URL query strings
    // and extremely long extensions remain part of the hashed original name.
    let extension = Path::new(base)
        .extension()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty() && name_units(name) <= 32)
        .map(|name| format!(".{name}"))
        .unwrap_or_default();
    let stem = &base[..base.len() - extension.len()];
    let suffix = format!("~{}{}", &name_digest(base)[..16], extension);
    Ok(format!("{}{}", prefix_within(stem, limit - name_units(&suffix)), suffix))
}

/// Existing sidecar paths stay compatible. When a suffix would exceed the
/// component limit, use a short hidden sibling derived from the full basename.
/// Hash only that basename so backup/restore and moved folders retain resumes.
pub(super) fn sidecar(partial: &Path, suffix: &str) -> PathBuf {
    let mut original = partial.as_os_str().to_owned();
    original.push(suffix);
    let original = PathBuf::from(original);
    if original.file_name().and_then(|name| name.to_str())
        .is_none_or(|name| name_units(name) <= COMPONENT_LIMIT)
    {
        return original;
    }
    let name = partial.file_name().unwrap().to_string_lossy();
    partial.with_file_name(format!(".myclouddriver-{}{suffix}", name_digest(&name)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_names_preserve_extensions_and_distinguish_the_complete_original() {
        for stem in ["a".repeat(400), "測試😀é".repeat(100)] {
            let first = component(&format!("{stem}-first.mp4")).unwrap();
            let second = component(&format!("{stem}-second.mp4")).unwrap();
            assert!(name_units(&first) <= COMPONENT_LIMIT - PART_SUFFIX.len());
            assert!(first.ends_with(".mp4"));
            assert_ne!(first, second);
            assert_eq!(first, component(&format!("{stem}-first.mp4")).unwrap());
            assert_eq!(first, component(&first).unwrap());
        }
    }

    #[test]
    fn ordinary_names_and_whitespace_stay_unchanged() {
        for name in ["video.mp4", "相片😀.jpg", " leading and trailing.txt "] {
            assert_eq!(component(name).unwrap(), name);
        }
        let boundary = "a".repeat(COMPONENT_LIMIT - PART_SUFFIX.len());
        assert_eq!(component(&boundary).unwrap(), boundary);
        assert!(component("bad\0name").is_err());
    }

    #[test]
    fn every_sidecar_fits_and_legacy_sidecars_keep_their_original_path() {
        let directory = tempfile::tempdir().unwrap();
        for name in ["file.bin".to_owned(), "a".repeat(250), "😀é".repeat(300)] {
            let name = component(&name).unwrap();
            let partial = directory.path().join(format!("{name}.part"));
            std::fs::write(&partial, b"partial").unwrap();
            for suffix in [".resume.json", ".ranges.json", ".ranges.data", ".publication.json"] {
                let path = sidecar(&partial, suffix);
                assert!(name_units(path.file_name().unwrap().to_str().unwrap()) <= COMPONENT_LIMIT);
                assert_eq!(path.parent(), partial.parent());
                assert_eq!(path, sidecar(&partial, suffix));
                std::fs::write(&path, b"metadata").unwrap();
            }
        }
        assert_eq!(sidecar(Path::new("/folder/file.bin.part"), ".resume.json"),
            Path::new("/folder/file.bin.part.resume.json"));
        let boundary = format!("{}.part", "b".repeat(238));
        assert_eq!(sidecar(Path::new(&boundary), ".resume.json"),
            Path::new(&format!("{boundary}.resume.json")));
        let long = format!("{}.part", "a".repeat(250));
        assert_ne!(sidecar(Path::new(&long), ".resume.json"),
            sidecar(Path::new(&format!("{}.part", "b".repeat(250))), ".resume.json"));
    }
}

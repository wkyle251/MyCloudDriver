//! Inventory selected roots without reading file contents. Remote originals
//! are resolved only when FileTwin requests an available worker's next input.
use super::*;
use rustix::fs::{openat, Dir, Mode, OFlags, CWD};
use std::{
    fs::{File, Metadata},
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::Component,
};
#[cfg(test)]
use std::{
    io::{Read, Seek, SeekFrom},
    os::unix::fs::OpenOptionsExt,
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Revision {
    dev: u64,
    ino: u64,
    len: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl Revision {
    fn of(m: &Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            len: m.len(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct InputFile {
    pub path: PathBuf,
    pub display: MatchedFile,
    pub record: Option<filetwin_core::api::FileRecord>,
    pub cloud: Option<CloudItem>,
    pub external: Option<ExternalSource>,
    revision: Option<Revision>,
    #[serde(default)]
    pub inventory_version: Option<String>,
}

impl InputFile {
    pub fn is_photos_preview(&self) -> bool {
        self.external
            .as_ref()
            .is_some_and(|item| item.content_kind == Some(ExternalContentKind::PhotosPreview))
    }
    pub fn local_device(&self) -> Option<u64> {
        if self.cloud.is_none() && self.external.is_none() {
            self.revision.as_ref().map(|r| r.dev)
        } else {
            None
        }
    }
    /// Capture discovery metadata before acquisition can wait or update it.
    /// Re-reading it during comparison would hide edits made during analysis.
    pub fn capture_inventory_version(&mut self) {
        self.inventory_version = Some(self.metadata_inventory_version());
    }
    fn metadata_inventory_version(&self) -> String {
        let external_metadata = self
            .external
            .as_ref()
            .and_then(|item| item.local_path.as_ref())
            .and_then(|path| resolve_root(path).ok())
            .and_then(|path| std::fs::symlink_metadata(path).ok())
            .map(|m| Revision::of(&m));
        let mut value = json!({"id":self.display.id,"name":self.display.name,"path":self.display.path,
            "size":self.external.as_ref().map_or(self.display.bytes, |item| item.size),
            "local":if self.external.is_none() { self.revision.as_ref() } else { None },"external_metadata":external_metadata,
            "cloud_revision":self.cloud.as_ref().and_then(|item| item.revision.as_ref()),
            "provider_revision":self.external.as_ref().and_then(|item| item.revision.as_ref())});
        if self.is_photos_preview() {
            value["content_kind"] = "photos_preview_1024_v1".into();
        }
        hex::encode(ring::digest::digest(
            &ring::digest::SHA256,
            value.to_string().as_bytes(),
        ))
    }
    pub fn checkpoint_revision(&self) -> Option<String> {
        if let Some(cloud) = &self.cloud {
            return cloud
                .revision
                .as_ref()
                .filter(|r| !r.trim().is_empty())
                .map(|r| format!("cloud:{}:{}:{r}", cloud.id, cloud.size));
        }
        if let Some(external) = &self.external {
            if self.is_photos_preview() {
                return external
                    .revision
                    .as_ref()
                    .filter(|r| !r.trim().is_empty())
                    .map(|r| format!("photos-preview-1024-v1:{}:{r}", external.id));
            }
            if let Some(path) = &external.local_path {
                if self
                    .inventory_version
                    .as_ref()
                    .is_some_and(|version| version != &self.metadata_inventory_version())
                {
                    return None;
                }
                // Provider URLs may use /var while the reader uses
                // /private/var. Apply the same selected-parent resolution as
                // resolved(), retaining NOFOLLOW for the original itself.
                // Metadata only: opening an iCloud original can cause the OS
                // to hydrate it before the cache has even been checked.
                return resolve_root(path)
                    .ok()
                    .and_then(|p| std::fs::symlink_metadata(p).ok())
                    .filter(|m| m.is_file())
                    .and_then(|m| serde_json::to_string(&Revision::of(&m)).ok());
            }
            return external
                .revision
                .as_ref()
                .filter(|r| !r.trim().is_empty())
                .map(|r| format!("provider:{}:{}:{r}", external.id, external.size));
        }
        self.revision
            .as_ref()
            .filter(|r| {
                std::fs::symlink_metadata(&self.path)
                    .is_ok_and(|m| m.is_file() && Revision::of(&m) == **r)
            })
            .and_then(|r| serde_json::to_string(r).ok())
    }
    pub(super) fn cloud(item: CloudItem) -> Self {
        let id = format!(
            "file-{}",
            hex::encode(ring::digest::digest(
                &ring::digest::SHA256,
                item.id.as_bytes()
            ))
        );
        Self {
            path: PathBuf::new(),
            revision: None,
            inventory_version: None,
            record: None,
            external: None,
            display: MatchedFile {
                id,
                name: item.name.clone(),
                path: item.path.clone(),
                bytes: item.size,
                family: "other".into(),
                local_path: None,
                cloud_id: Some(item.id.clone()),
                ancestors: item.ancestors.clone(),
                engine_index: None,
                state: "pending".into(),
            },
            cloud: Some(item),
        }
    }
    pub(super) fn external(item: ExternalSource) -> Self {
        Self {
            path: PathBuf::new(),
            revision: None,
            inventory_version: None,
            record: None,
            cloud: None,
            display: MatchedFile {
                id: item.id.clone(),
                name: item.name.clone(),
                path: item.path.clone(),
                bytes: item.size,
                family: "other".into(),
                local_path: item.local_path.as_ref().map(|p| p.to_string_lossy().into()),
                cloud_id: None,
                ancestors: vec![],
                engine_index: None,
                state: "pending".into(),
            },
            external: Some(item),
        }
    }
}

/// Canonicalize only the explicitly selected root's parent (e.g. /var on
/// macOS). Descendants must never gain permission to escape through a symlink.
fn resolve_root(path: &Path) -> Result<PathBuf> {
    if path == Path::new("/") {
        return Ok(path.into());
    }
    let parent = path.parent().context("Missing source parent")?;
    Ok(parent
        .canonicalize()?
        .join(path.file_name().context("Missing source name")?))
}

pub(super) fn open_secure(path: &Path) -> Result<File> {
    let flags = OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK;
    let mut fd = openat(CWD, "/", flags | OFlags::DIRECTORY, Mode::empty())?;
    let components: Vec<_> = path.components().collect();
    if !path.is_absolute() {
        bail!("A source path must be absolute.");
    }
    for (i, c) in components.iter().enumerate() {
        match c {
            Component::RootDir => {}
            Component::Normal(name) => {
                fd = openat(
                    &fd,
                    *name,
                    flags
                        | if i + 1 < components.len() {
                            OFlags::DIRECTORY
                        } else {
                            OFlags::empty()
                        },
                    Mode::empty(),
                )?;
            }
            _ => bail!("Invalid source path component."),
        }
    }
    Ok(fd.into())
}

#[cfg(test)]
pub(super) fn inventory(
    request: &ScanRequest,
    staged: &StagedCloud,
    cancel: &AtomicBool,
    report: &mut ScanReport,
) -> Result<Vec<InputFile>> {
    let mut files = Vec::new();
    discover(request, staged, cancel, report, &mut |mut file| {
        file.capture_inventory_version();
        files.push(file);
        Ok(())
    })?;
    files.sort_by(|a, b| a.display.id.cmp(&b.display.id));
    for (i, file) in files.iter_mut().enumerate() {
        file.display.engine_index = Some(i as u64);
    }
    Ok(files)
}

pub(super) fn discover(
    request: &ScanRequest,
    staged: &StagedCloud,
    cancel: &AtomicBool,
    report: &mut ScanReport,
    next: &mut dyn FnMut(InputFile) -> Result<()>,
) -> Result<()> {
    if request.source == ScanSource::Cloud || !request.external_sources.is_empty() {
        let mut files = Vec::new();
        for (path, item) in &staged.files {
            check_cancel(cancel)?;
            files.push(InputFile {
                path: path.clone(),
                revision: None,
                inventory_version: None,
                record: None,
                cloud: Some(item.clone()),
                external: None,
                display: MatchedFile {
                    id: format!(
                        "file-{}",
                        hex::encode(ring::digest::digest(
                            &ring::digest::SHA256,
                            item.id.as_bytes()
                        ))
                    ),
                    name: item.name.clone(),
                    path: item.path.clone(),
                    bytes: item.size,
                    family: "other".into(),
                    local_path: None,
                    cloud_id: Some(item.id.clone()),
                    ancestors: item.ancestors.clone(),
                    engine_index: None,
                    state: "pending".into(),
                },
            });
        }
        for item in &request.external_sources {
            check_cancel(cancel)?;
            if item.name.starts_with('.') {
                continue;
            }
            files.push(InputFile {
                path: PathBuf::new(),
                revision: None,
                inventory_version: None,
                record: None,
                cloud: None,
                external: Some(item.clone()),
                display: MatchedFile {
                    id: item.id.clone(),
                    name: item.name.clone(),
                    path: item.path.clone(),
                    bytes: item.size,
                    family: "other".into(),
                    local_path: item.local_path.as_ref().map(|p| p.to_string_lossy().into()),
                    cloud_id: None,
                    ancestors: vec![],
                    engine_index: None,
                    state: "pending".into(),
                },
            });
        }
        files.sort_by(|a, b| a.display.id.cmp(&b.display.id));
        for (i, file) in files.iter_mut().enumerate() {
            file.display.engine_index = Some(i as u64);
        }
        if request.source == ScanSource::Local {
            report.scanned_files = files.len() as u64;
        }
        for file in files {
            next(file)?;
        }
        return Ok(());
    }
    let mut pending = VecDeque::new();
    if request.source == ScanSource::Cloud {
        let mut paths: Vec<_> = staged.files.keys().cloned().collect();
        paths.sort();
        pending.extend(paths);
    } else {
        for root in &request.local_paths {
            if root
                .file_name()
                .is_some_and(|name| name.as_bytes().starts_with(b"."))
            {
                continue;
            }
            match resolve_root(root) {
                Ok(path) => pending.push_back(path),
                Err(_) => issue(
                    report,
                    &root.to_string_lossy(),
                    "Could not access this scan root.",
                ),
            }
        }
    }
    let excluded: Vec<_> = [
        &request.data_dir,
        &request.temp_dir,
        &request.model_dir,
        &request.report_path,
    ]
    .into_iter()
    .filter_map(|p| resolve_root(p).ok())
    .collect();
    let mut seen = HashSet::new();
    let mut discovered = 0u64;
    'inventory: while let Some(path) = pending.pop_front() {
        if cancel.load(Ordering::Acquire) {
            break;
        }
        if !seen.insert(path.clone()) {
            continue;
        }
        if request.source == ScanSource::Local && excluded.iter().any(|p| path.starts_with(p)) {
            continue;
        }
        // Dotfiles and dot-directories are outside the scan scope, not failed
        // inputs. Test before opening them or walking a hidden directory.
        if path
            .file_name()
            .is_some_and(|n| n.as_bytes().starts_with(b"."))
        {
            continue;
        }
        let opened = open_secure(&path).and_then(|f| Ok((f.metadata()?, f)));
        let (meta, file) = match opened {
            Ok(value) => value,
            Err(error) if is_missing(&error) => continue,
            Err(_) => {
                classified_issue(
                    report,
                    &display_path(&path, staged, request.source),
                    "Could not read this item. Symlinks are not followed.",
                    if std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
                        "unsupported"
                    } else {
                        "failed"
                    },
                );
                continue;
            }
        };
        if meta.is_dir() {
            let directory = match Dir::read_from(&file) {
                Ok(directory) => directory,
                Err(_) => {
                    issue(
                        report,
                        &display_path(&path, staged, request.source),
                        "Could not list this folder.",
                    );
                    continue;
                }
            };
            for entry in directory {
                if cancel.load(Ordering::Acquire) {
                    break 'inventory;
                }
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(_) => {
                        issue(
                            report,
                            &display_path(&path, staged, request.source),
                            "This folder could not be fully listed.",
                        );
                        break;
                    }
                };
                let name = entry.file_name().to_bytes();
                if name.starts_with(b".") {
                    continue;
                }
                pending.push_back(path.join(std::ffi::OsStr::from_bytes(name)));
            }
        } else if meta.is_file() {
            let cloud = staged.files.get(&path);
            let identity = cloud
                .map(|f| f.id.as_bytes())
                .unwrap_or_else(|| path.as_os_str().as_bytes());
            let id = format!(
                "file-{}",
                hex::encode(ring::digest::digest(&ring::digest::SHA256, identity))
            );
            let display = MatchedFile {
                id,
                name: cloud.map(|f| f.name.clone()).unwrap_or_else(|| {
                    path.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into()
                }),
                path: display_path(&path, staged, request.source),
                bytes: meta.len(),
                family: "other".into(),
                local_path: if request.source == ScanSource::Local {
                    path.to_str().map(str::to_owned)
                } else {
                    None
                },
                cloud_id: cloud.map(|f| f.id.clone()),
                ancestors: cloud.map(|f| f.ancestors.clone()).unwrap_or_default(),
                engine_index: None,
                state: "pending".into(),
            };
            discovered += 1;
            next(InputFile {
                path,
                display,
                revision: Some(Revision::of(&meta)),
                inventory_version: None,
                record: None,
                cloud: None,
                external: None,
            })?;
        } else {
            classified_issue(
                report,
                &display_path(&path, staged, request.source),
                "This item is not a regular file.",
                "unsupported",
            );
        }
    }
    if request.source == ScanSource::Local {
        report.scanned_files = discovered as u64;
    }
    Ok(())
}

pub(super) fn is_missing(error: &anyhow::Error) -> bool {
    error.chain().any(|error| {
        error
            .downcast_ref::<std::io::Error>()
            .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound)
            || error
                .downcast_ref::<rustix::io::Errno>()
                .is_some_and(|error| *error == rustix::io::Errno::NOENT)
    })
}

fn display_path(path: &Path, staged: &StagedCloud, source: ScanSource) -> String {
    staged
        .files
        .get(path)
        .map(|f| f.path.clone())
        .unwrap_or_else(|| {
            if source == ScanSource::Local {
                path.to_string_lossy().into()
            } else {
                "Cloud file".into()
            }
        })
}

pub(super) fn issue(report: &mut ScanReport, path: &str, reason: &str) {
    classified_issue(report, path, reason, "failed");
}

pub(super) fn classified_issue(report: &mut ScanReport, path: &str, reason: &str, category: &str) {
    report.skipped_files += 1;
    if category == "unsupported" {
        report.unsupported_files += 1;
    } else {
        report.failed_files += 1;
    }
    if let Some(summary) = report
        .issue_summary
        .iter_mut()
        .find(|s| s.reason == reason && s.category == category)
    {
        summary.count += 1;
    } else {
        report.issue_summary.push(IssueSummary {
            category: category.into(),
            reason: reason.into(),
            count: 1,
        });
    }
    if report.issues.len() < MAX_ISSUES {
        report.issues.push(ScanIssue {
            path: path.into(),
            reason: reason.into(),
        });
    }
}

impl InputFile {
    /// Record the revision at the moment a provider makes this original
    /// available. The core verifies the opened source throughout analysis.
    pub fn resolved(&mut self, path: PathBuf) -> Result<()> {
        let path = resolve_root(&path)?;
        let meta = open_secure(&path)?.metadata()?;
        if !meta.is_file() {
            bail!("The provider did not return a regular file.");
        }
        self.path = path;
        self.display.bytes = meta.len();
        self.revision = Some(Revision::of(&meta));
        Ok(())
    }
    #[cfg(test)]
    fn open_current(&self) -> Result<File> {
        let file = open_secure(&self.path)?;
        if !file.metadata()?.is_file() || Some(Revision::of(&file.metadata()?)) != self.revision {
            bail!("This file changed during the scan. Scan it again when changes have finished.");
        }
        Ok(file)
    }
    #[cfg(test)]
    pub fn still_current(&self) -> bool {
        self.open_current().is_ok()
    }
    #[cfg(test)]
    pub fn family(&self) -> Result<String> {
        let mut file = self.open_current()?;
        let mut prefix = [0u8; 4096];
        let count = file.read(&mut prefix)?;
        Ok(format_filter::detect_format(&prefix[..count], &self.path)
            .0
            .into())
    }

    /// Legacy copy helper retained for source-change regression tests. The
    /// production pipeline passes the original directly to the encoder.
    #[cfg(test)]
    pub fn prepare(
        &self,
        destination: &Path,
        cancel: &AtomicBool,
        mut progress: impl FnMut(u64) -> Result<()>,
    ) -> Result<()> {
        check_cancel(cancel)?;
        let mut file = self.open_current()?;
        #[cfg(target_os = "macos")]
        {
            if rustix::fs::fclonefileat(
                &file,
                CWD,
                destination,
                rustix::fs::CloneFlags::NOFOLLOW | rustix::fs::CloneFlags::NOOWNERCOPY,
            )
            .is_ok()
            {
                std::fs::set_permissions(destination, std::fs::Permissions::from_mode(0o600))?;
                if !self.still_current() {
                    bail!("This file changed while preparing it for analysis.");
                }
                return Ok(());
            }
        }
        let mut output = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(destination)?;
        let mut buf = vec![0u8; 1024 * 1024];
        let mut bytes = 0;
        let mut last = Instant::now();
        loop {
            check_cancel(cancel)?;
            let count = file.read(&mut buf)?;
            if count == 0 {
                break;
            }
            output.write_all(&buf[..count])?;
            bytes += count as u64;
            if last.elapsed() > Duration::from_millis(250) {
                progress(bytes)?;
                last = Instant::now();
            }
        }
        output.flush()?;
        if bytes
            != self
                .revision
                .as_ref()
                .context("Missing source revision")?
                .len
            || Some(Revision::of(&file.metadata()?)) != self.revision
            || !self.still_current()
        {
            bail!("This file changed while preparing it for analysis.");
        }
        Ok(())
    }

    #[cfg(test)]
    pub fn hash_only(
        &mut self,
        cancel: &AtomicBool,
        mut progress: impl FnMut(u64) -> Result<()>,
    ) -> Result<()> {
        let mut file = self.open_current()?;
        file.seek(SeekFrom::Start(0))?;
        let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
        let mut buf = vec![0u8; 1024 * 1024];
        let mut bytes = 0;
        let mut last = Instant::now();
        loop {
            check_cancel(cancel)?;
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hash.update(&buf[..n]);
            bytes += n as u64;
            if last.elapsed() > Duration::from_millis(250) {
                progress(bytes)?;
                last = Instant::now();
            }
        }
        if bytes
            != self
                .revision
                .as_ref()
                .context("Missing source revision")?
                .len
            || Some(Revision::of(&file.metadata()?)) != self.revision
            || !self.still_current()
        {
            bail!("This file changed while checking identical content.");
        }
        self.record = Some(filetwin_core::api::FileRecord {
            path: filetwin_core::api::FilePath::Utf8(self.display.id.clone()),
            file_id: Some(format!("sha256:{}", hex::encode(hash.finish()))),
            bytes: Some(bytes),
            state: filetwin_core::api::FileState::Skipped,
            family: Some(self.display.family.clone()),
            profile_id: None,
            vector: None,
            vector_sha256: None,
            reused: false,
            error: Some(filetwin_core::Error::new(
                filetwin_core::ErrorCode::UnsupportedFormat,
                "scope",
                "Content type excluded; only identical content was checked.",
            )),
            extraction: None,
        });
        Ok(())
    }
}

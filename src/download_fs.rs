//! Directory-relative download I/O. No operation follows a descendant symlink,
//! including if an ancestor is exchanged after it was inspected.
use rustix::fs::{self, AtFlags, Mode, OFlags, CWD};
use std::{
    fs::File,
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
};

struct Destination {
    path: PathBuf,
    anchor: File,
    device: u64,
    inode: u64,
    checkpoint_policy: Mutex<Option<crate::download_checkpoint::CheckpointPolicy>>,
}

fn destinations() -> &'static Mutex<Vec<Arc<Destination>>> {
    static DESTINATIONS: OnceLock<Mutex<Vec<Arc<Destination>>>> = OnceLock::new();
    DESTINATIONS.get_or_init(Default::default)
}

fn unavailable() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::NotConnected,
        pikpak::download_policy::DestinationUnavailable,
    )
}

fn identity(metadata: &std::fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

fn absolute(path: &Path) -> std::io::Result<PathBuf> {
    let path = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::RootDir => normalized.push("/"),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(name) => normalized.push(name),
            _ => return Err(std::io::Error::other("Invalid download path")),
        }
    }
    // macOS exposes these system-owned aliases. Resolve only the alias, never
    // arbitrary descendants of the user's selected directory.
    for prefix in ["/var", "/tmp"] {
        if let Ok(rest) = normalized.strip_prefix(prefix) {
            return Ok(Path::new(prefix).canonicalize()?.join(rest));
        }
    }
    Ok(normalized)
}

fn external_root(path: &Path, volumes: &Path) -> Option<PathBuf> {
    let rest = path.strip_prefix(volumes).ok()?;
    let name = rest.components().find_map(|component| match component {
        Component::Normal(name) => Some(name),
        _ => None,
    })?;
    Some(volumes.join(name))
}

fn mounted_root(path: &Path, volumes: &Path) -> std::io::Result<Option<(PathBuf, (u64, u64))>> {
    let Some(root) = external_root(path, volumes) else {
        return Ok(None);
    };
    let parent = std::fs::metadata(volumes).map_err(|_| unavailable())?;
    let metadata = std::fs::symlink_metadata(&root).map_err(|_| unavailable())?;
    // An ordinary directory left in /Volumes is the internal disk, not the
    // selected mounted disk. Never create or accept it as a substitute.
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || identity(&metadata).0 == identity(&parent).0
    {
        return Err(unavailable());
    }
    Ok(Some((root, identity(&metadata))))
}

fn guards(path: &Path) -> Vec<Arc<Destination>> {
    destinations()
        .lock()
        .unwrap()
        .iter()
        .filter(|guard| path.starts_with(&guard.path))
        .cloned()
        .collect()
}

fn walk(path: &Path, create: bool, guards: &[Arc<Destination>]) -> std::io::Result<File> {
    let mounted = mounted_root(path, Path::new("/Volumes"))?;
    let mut current = File::from(fs::openat(
        CWD,
        "/",
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )?);
    let mut traversed = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir | Component::CurDir => continue,
            Component::Normal(name) => {
                traversed.push(name);
                let selected = guards.iter().find(|guard| guard.path == traversed);
                let protected_ancestor = guards
                    .iter()
                    .any(|guard| guard.path.starts_with(&traversed));
                let volume = mounted.as_ref().filter(|(root, _)| root == &traversed);
                // The volume boundary and explicitly selected directory must
                // still exist. Only descendants may be created by a retry.
                if create && !protected_ancestor && volume.is_none() {
                    match fs::mkdirat(&current, name, Mode::RUSR | Mode::WUSR | Mode::XUSR) {
                        Ok(()) => {}
                        Err(error) if error == rustix::io::Errno::EXIST => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                let next = fs::openat(
                    &current,
                    name,
                    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                    Mode::empty(),
                )
                .map_err(|error| {
                    if protected_ancestor || volume.is_some() {
                        unavailable()
                    } else {
                        error.into()
                    }
                })?;
                current = File::from(next);
                if let Some(guard) = selected {
                    let anchored = identity(&guard.anchor.metadata().map_err(|_| unavailable())?);
                    if anchored != (guard.device, guard.inode)
                        || identity(&current.metadata().map_err(|_| unavailable())?) != anchored
                    {
                        return Err(unavailable());
                    }
                }
                if let Some((_, expected)) = volume {
                    if identity(&current.metadata().map_err(|_| unavailable())?) != *expected {
                        return Err(unavailable());
                    }
                }
            }
            Component::ParentDir => {
                current = File::from(fs::openat(
                    &current,
                    "..",
                    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                    Mode::empty(),
                )?);
            }
            _ => return Err(std::io::Error::other("Invalid download directory")),
        }
    }
    Ok(current)
}

pub fn directory(path: &Path, create: bool) -> std::io::Result<File> {
    let path = absolute(path)?;
    let guards = guards(&path);
    walk(&path, create, &guards)
}

/// Check the selected root, independently of whether this particular file or
/// generated child exists. Open file descriptors remain bound to the original
/// filesystem; every later metadata commit must pass this path check too.
pub fn validate(path: &Path) -> std::io::Result<()> {
    let path = absolute(path)?;
    for guard in guards(&path) {
        walk(&guard.path, false, std::slice::from_ref(&guard))?;
    }
    mounted_root(&path, Path::new("/Volumes"))?;
    Ok(())
}

/// A retained descriptor may still be writable after its directory has been
/// renamed. Check both the selected root and the current staging entry before
/// advancing a durable checkpoint for that descriptor.
pub fn validate_open_file(path: &Path, opened: &std::fs::Metadata) -> std::io::Result<()> {
    validate(path)?;
    let current = metadata(path)?;
    if identity(opened) != identity(&current) {
        return Err(unavailable());
    }
    Ok(())
}

fn parent(path: &Path) -> std::io::Result<(File, &std::ffi::OsStr)> {
    let name = path
        .file_name()
        .ok_or_else(|| std::io::Error::other("Invalid download filename"))?;
    Ok((
        directory(path.parent().unwrap_or(Path::new(".")), false)?,
        name,
    ))
}

pub fn create_dir_all(path: &Path) -> std::io::Result<()> {
    directory(path, true).map(drop)
}

/// Resolve the directory explicitly chosen by the user once. All generated
/// relative folders and subsequent I/O use no-follow traversal.
pub fn selected_directory(path: &Path) -> std::io::Result<PathBuf> {
    selected_directory_with_checkpoint_policy(path, None)
}

/// The live queue can write to different volumes and admit new roots while
/// running. Bind each checkpoint policy to its validated destination anchor.
pub fn selected_directory_with_checkpoint_policy(
    path: &Path,
    policy: Option<crate::download_checkpoint::CheckpointPolicy>,
) -> std::io::Result<PathBuf> {
    let path = absolute(path)?;
    // Previously selected roots cannot be recreated. An existing explicit
    // alias may resolve elsewhere before we inspect the final volume boundary.
    for guard in guards(&path) {
        walk(&guard.path, false, std::slice::from_ref(&guard))?;
    }
    // Resolve an existing explicit selection (including its chosen aliases),
    // then create missing descendants through the no-follow implementation.
    let mut ancestor = path.as_path();
    let mut missing = Vec::new();
    let mut resolved = loop {
        match ancestor.canonicalize() {
            Ok(resolved) => break resolved,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                missing.push(
                    ancestor
                        .file_name()
                        .ok_or_else(|| unavailable())?
                        .to_owned(),
                );
                ancestor = ancestor.parent().ok_or_else(|| unavailable())?;
            }
            Err(error) => return Err(error),
        }
    };
    for name in missing.into_iter().rev() {
        resolved.push(name);
    }
    let anchor = directory(&resolved, true)?;
    let (device, inode) = identity(&anchor.metadata()?);
    let mut selected = destinations().lock().unwrap();
    if let Some(previous) = selected.iter().find(|guard| guard.path == resolved) {
        if (previous.device, previous.inode) != (device, inode) {
            return Err(unavailable());
        }
        if let Some(policy) = policy {
            *previous.checkpoint_policy.lock().unwrap() = Some(policy);
        }
    } else {
        selected.push(Arc::new(Destination {
            path: resolved.clone(),
            anchor,
            device,
            inode,
            checkpoint_policy: Mutex::new(policy),
        }));
    }
    Ok(resolved)
}

pub fn checkpoint_policy(path: &Path) -> crate::download_checkpoint::CheckpointPolicy {
    guards(path)
        .into_iter()
        .filter_map(|guard| {
            let policy = *guard.checkpoint_policy.lock().unwrap();
            policy.map(|policy| (guard.path.components().count(), policy))
        })
        .max_by_key(|(depth, _)| *depth)
        .map(|(_, policy)| policy)
        .unwrap_or_else(crate::download_checkpoint::CheckpointPolicy::current)
}

pub fn metadata(path: &Path) -> std::io::Result<std::fs::Metadata> {
    let file = open(path, OFlags::RDONLY | OFlags::NONBLOCK)?;
    file.metadata()
}

#[derive(Debug)]
pub struct NonRegularFile;
impl std::fmt::Display for NonRegularFile {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Download data is not a regular file")
    }
}
impl std::error::Error for NonRegularFile {}

pub fn open(path: &Path, flags: OFlags) -> std::io::Result<File> {
    let (parent, name) = parent(path)?;
    let file = File::from(fs::openat(
        &parent,
        name,
        flags | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR,
    )?);
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other(NonRegularFile));
    }
    Ok(file)
}

pub fn read(path: &Path) -> std::io::Result<Vec<u8>> {
    let file = open(path, OFlags::RDONLY | OFlags::NONBLOCK)?;
    if file.metadata()?.len() > 2 * 1024 * 1024 {
        return Err(std::io::Error::other("Download metadata is too large"));
    }
    let mut bytes = Vec::new();
    file.take(2 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 2 * 1024 * 1024 {
        return Err(std::io::Error::other("Download metadata is too large"));
    }
    Ok(bytes)
}

pub fn remove_file(path: &Path) -> std::io::Result<()> {
    let (parent, name) = parent(path)?;
    fs::unlinkat(&parent, name, AtFlags::empty()).map_err(Into::into)
}

pub fn rename(source: &Path, destination: &Path) -> std::io::Result<()> {
    let (source_parent, source_name) = parent(source)?;
    let (destination_parent, destination_name) = parent(destination)?;
    validate(source)?;
    validate(destination)?;
    fs::renameat(
        &source_parent,
        source_name,
        &destination_parent,
        destination_name,
    )
    .map_err(Into::into)
}

pub fn unsupported_operation(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::Unsupported
        || error.raw_os_error().is_some_and(|code| {
            code == rustix::io::Errno::NOTSUP.raw_os_error()
                || code == rustix::io::Errno::OPNOTSUPP.raw_os_error()
                || code == rustix::io::Errno::NOSYS.raw_os_error()
        })
}

fn directory_sync_result(result: std::io::Result<()>) -> std::io::Result<()> {
    match result {
        // Some user-volume drivers cannot fsync a directory. Data files and
        // metadata staging files are still synced before their publication.
        Err(error)
            if unsupported_operation(&error)
                || error.raw_os_error() == Some(rustix::io::Errno::INVAL.raw_os_error()) =>
        {
            Ok(())
        }
        result => result,
    }
}

pub fn sync_parent(path: &Path) -> std::io::Result<()> {
    let (parent, _) = parent(path)?;
    directory_sync_result(parent.sync_all())
}

/// Publish without replacing any destination. Prefer an exclusive move, then
/// a hard link on drivers which lack exclusive rename. Volumes such as ExFAT
/// reject both; the caller can retain staging and use its owned-copy journal.
pub fn publish_no_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    publish_no_replace_using(
        source,
        destination,
        |source_parent, source_name, destination_parent, destination_name| {
            fs::renameat_with(
                source_parent,
                source_name,
                destination_parent,
                destination_name,
                fs::RenameFlags::NOREPLACE,
            )
            .map_err(Into::into)
        },
        |source_parent, source_name, destination_parent, destination_name| {
            fs::linkat(
                source_parent,
                source_name,
                destination_parent,
                destination_name,
                AtFlags::empty(),
            )
            .map_err(Into::into)
        },
        File::sync_all,
    )
}

fn publish_no_replace_using(
    source: &Path,
    destination: &Path,
    exclusive_rename: impl FnOnce(
        &File,
        &std::ffi::OsStr,
        &File,
        &std::ffi::OsStr,
    ) -> std::io::Result<()>,
    hard_link: impl FnOnce(&File, &std::ffi::OsStr, &File, &std::ffi::OsStr) -> std::io::Result<()>,
    sync_directory: impl FnOnce(&File) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let (source_parent, source_name) = parent(source)?;
    let (destination_parent, destination_name) = parent(destination)?;
    let source_file = File::from(fs::openat(
        &source_parent,
        source_name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )?);
    let source_metadata = source_file.metadata()?;
    if !source_metadata.is_file() {
        return Err(std::io::Error::other(
            "Completed download is not a regular file",
        ));
    }
    validate_open_file(source, &source_metadata)?;
    validate(destination)?;
    match exclusive_rename(
        &source_parent,
        source_name,
        &destination_parent,
        destination_name,
    ) {
        Ok(()) => {}
        Err(error) if unsupported_operation(&error) => {
            hard_link(
                &source_parent,
                source_name,
                &destination_parent,
                destination_name,
            )?;
            let published = File::from(fs::openat(
                &destination_parent,
                destination_name,
                OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            )?);
            if identity(&published.metadata()?) != identity(&source_metadata) {
                return Err(unavailable());
            }
            validate_open_file(source, &source_metadata)?;
            fs::unlinkat(&source_parent, source_name, AtFlags::empty())?;
        }
        Err(error) => return Err(error),
    }
    directory_sync_result(sync_directory(&destination_parent))?;
    Ok(())
}

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// A checkpoint carries only data already handed to the OS. The coordinator
/// retains the descriptor until the entire data-before-journal commit finishes.
pub(crate) struct CheckpointWrite {
    pub data: File,
    pub data_path: PathBuf,
    pub metadata: std::fs::Metadata,
    pub journal_path: PathBuf,
    pub journal: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CheckpointSync { Data, Journal, Directory, Barrier }

struct StagedCheckpoint {
    parent: File, name: std::ffi::OsString, temporary: String, file: File,
}
impl Drop for StagedCheckpoint {
    fn drop(&mut self) { let _ = fs::unlinkat(&self.parent, &self.temporary, AtFlags::empty()); }
}

fn checkpoint_metadata(metadata: &std::fs::Metadata) -> (u64, u64, u64, i64, i64, i64, i64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino(), metadata.len(), metadata.mtime(), metadata.mtime_nsec(), metadata.ctime(), metadata.ctime_nsec())
}
fn validate_checkpoint(write: &CheckpointWrite) -> std::io::Result<()> {
    let current = write.data.metadata()?;
    validate_open_file(&write.data_path, &current)?;
    if checkpoint_metadata(&current) != checkpoint_metadata(&write.metadata) {
        return Err(std::io::Error::other("Download changed while saving its checkpoint"));
    }
    Ok(())
}
fn stage_checkpoint(write: &CheckpointWrite) -> std::io::Result<StagedCheckpoint> {
    let (parent, name) = parent(&write.journal_path)?;
    match fs::statat(&parent, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(stat) if fs::FileType::from_raw_mode(stat.st_mode) != fs::FileType::RegularFile =>
            return Err(std::io::Error::other("Download metadata is not a regular file")),
        Ok(_) => {},
        Err(error) if error == rustix::io::Errno::NOENT => {},
        Err(error) => return Err(error.into()),
    }
    let name = name.to_owned();
    for _ in 0..1024 {
        let temporary = format!(".myclouddriver-{}-{}.tmp", std::process::id(), TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed));
        let file = match fs::openat(&parent, &temporary, OFlags::CREATE | OFlags::EXCL | OFlags::WRONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::RUSR | Mode::WUSR) {
            Ok(file) => File::from(file),
            Err(error) if error == rustix::io::Errno::EXIST => continue,
            Err(error) => return Err(error.into()),
        };
        let mut staged = StagedCheckpoint { parent, name, temporary, file };
        staged.file.write_all(&write.journal)?;
        return Ok(staged);
    }
    Err(std::io::Error::other("Cannot allocate download metadata staging file"))
}

/// POSIX fsync drains each vnode to the device. The two shared full cache
/// barriers retain macOS's stronger durability: payloads before publication,
/// then directory entries before acknowledging any caller. Never mix volumes.
pub(crate) fn checkpoint_batch(writes: &[CheckpointWrite]) -> std::io::Result<()> {
    checkpoint_batch_using(writes, |phase, file| {
        if phase == CheckpointSync::Barrier { file.sync_all() }
        else { fs::fsync(file).map_err(Into::into) }
    })
}
#[cfg(test)]
#[path = "download_checkpoint_batch_fs_tests.rs"]
mod checkpoint_batch_tests;
fn checkpoint_batch_using(writes: &[CheckpointWrite], mut sync: impl FnMut(CheckpointSync, &File) -> std::io::Result<()>) -> std::io::Result<()> {
    use std::collections::HashSet;
    let Some(first) = writes.first() else { return Ok(()); };
    let device = identity(&first.metadata).0;
    let mut staged = Vec::with_capacity(writes.len());
    for write in writes {
        if identity(&write.metadata).0 != device { return Err(std::io::Error::other("Checkpoint batch crosses devices")); }
        validate_checkpoint(write)?;
        let item = stage_checkpoint(write)?;
        if identity(&item.parent.metadata()?).0 != device { return Err(std::io::Error::other("Checkpoint journal is on another device")); }
        staged.push(item);
    }
    for write in writes { sync(CheckpointSync::Data, &write.data)?; }
    for item in &staged { sync(CheckpointSync::Journal, &item.file)?; }
    sync(CheckpointSync::Barrier, &first.data)?;
    // A changed destination or data file cannot acquire a newer journal,
    // even if it changed while a disk-cache flush was in progress.
    for write in writes { validate_checkpoint(write)?; validate(&write.journal_path)?; }
    for item in &staged { fs::renameat(&item.parent, &item.temporary, &item.parent, &item.name)?; }
    let mut parents = HashSet::new();
    for item in &staged {
        if parents.insert(identity(&item.parent.metadata()?)) {
            directory_sync_result(sync(CheckpointSync::Directory, &item.parent))?;
        }
    }
    sync(CheckpointSync::Barrier, &first.data)?;
    Ok(())
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let (parent, name) = parent(path)?;
    // Reject arbitrary sidecars before replacing app-created metadata.
    match fs::statat(&parent, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(stat) if fs::FileType::from_raw_mode(stat.st_mode) != fs::FileType::RegularFile => {
            return Err(std::io::Error::other(
                "Download metadata is not a regular file",
            ))
        }
        Ok(_) => {}
        Err(error) if error == rustix::io::Errno::NOENT => {}
        Err(error) => return Err(error.into()),
    }
    let (temporary, mut file) = (0..1024)
        .find_map(|_| {
            let temporary = format!(
                ".myclouddriver-{}-{}.tmp",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            );
            match fs::openat(
                &parent,
                &temporary,
                OFlags::CREATE | OFlags::EXCL | OFlags::WRONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::RUSR | Mode::WUSR,
            ) {
                Ok(file) => Some(Ok((temporary, File::from(file)))),
                Err(error) if error == rustix::io::Errno::EXIST => None,
                Err(error) => Some(Err(std::io::Error::from(error))),
            }
        })
        .unwrap_or_else(|| {
            Err(std::io::Error::other(
                "Cannot allocate a download metadata staging file",
            ))
        })?;
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        validate(path)?;
        fs::renameat(&parent, &temporary, &parent, name)?;
        directory_sync_result(parent.sync_all())?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::unlinkat(&parent, &temporary, AtFlags::empty());
    }
    result
}

pub async fn open_async(path: &Path, flags: OFlags) -> std::io::Result<tokio::fs::File> {
    let _stage = pikpak::download_waits::Stage::enter(pikpak::download_waits::Kind::FsOpen);
    let path = path.to_owned();
    let file = tokio::task::spawn_blocking(move || open(&path, flags))
        .await
        .map_err(std::io::Error::other)??;
    Ok(tokio::fs::File::from_std(file))
}

pub async fn metadata_async(path: &Path) -> std::io::Result<std::fs::Metadata> {
    let _stage = pikpak::download_waits::Stage::enter(pikpak::download_waits::Kind::FsMetadata);
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || metadata(&path))
        .await
        .map_err(std::io::Error::other)?
}

pub async fn rename_async(source: &Path, destination: &Path) -> std::io::Result<()> {
    let source = source.to_owned();
    let destination = destination.to_owned();
    tokio::task::spawn_blocking(move || rename(&source, &destination))
        .await
        .map_err(std::io::Error::other)?
}

#[cfg(test)]
mod tests {
    #[test]
    fn checkpoint_policies_follow_validated_roots_aliases_and_component_boundaries() {
        use crate::download_checkpoint::CheckpointPolicy;
        let directory = tempfile::tempdir().unwrap();
        let slow = selected_directory_with_checkpoint_policy(
            &directory.path().join("slow"), Some(CheckpointPolicy::RELAXED)).unwrap();
        let alias = directory.path().join("alias");
        std::os::unix::fs::symlink(&slow, &alias).unwrap();
        assert_eq!(selected_directory(&alias).unwrap(), slow);
        assert_eq!(checkpoint_policy(&slow.join("file.part")), CheckpointPolicy::RELAXED,
            "A legacy selection must not erase a known destination policy");
        let fast = selected_directory_with_checkpoint_policy(
            &slow.join("nested"), Some(CheckpointPolicy::FREQUENT)).unwrap();
        assert_eq!(checkpoint_policy(&fast.join("file.part")), CheckpointPolicy::FREQUENT);
        assert_eq!(checkpoint_policy(&slow.join("other/file.part")), CheckpointPolicy::RELAXED);
        assert_eq!(checkpoint_policy(&directory.path().join("slow-neighbour/file.part")), CheckpointPolicy::current(),
            "A path prefix is not a destination ancestor");
    }

    use super::*;

    fn assert_unavailable(error: std::io::Error) {
        assert!(pikpak::download_policy::destination_unavailable(
            &error.into()
        ));
    }

    #[test]
    fn missing_selected_root_and_ancestors_are_never_recreated() {
        let temp = tempfile::tempdir().unwrap();
        let ancestor = temp.path().join("ancestor");
        let root = selected_directory(&ancestor.join("selected")).unwrap();
        atomic_write(&root.join("original.part"), b"prefix").unwrap();
        atomic_write(&root.join("original.part.resume.json"), b"checkpoint").unwrap();
        let preserved = temp.path().join("preserved");
        std::fs::rename(&ancestor, &preserved).unwrap();

        assert_unavailable(create_dir_all(&root.join("new/child")).unwrap_err());
        assert_unavailable(selected_directory(&root).unwrap_err());
        assert!(!ancestor.exists());
        assert_eq!(
            std::fs::read(preserved.join("selected/original.part")).unwrap(),
            b"prefix"
        );
        assert_eq!(
            std::fs::read(preserved.join("selected/original.part.resume.json")).unwrap(),
            b"checkpoint"
        );
    }

    #[test]
    fn replacement_selected_root_cannot_receive_data_or_checkpoint() {
        let temp = tempfile::tempdir().unwrap();
        let root = selected_directory(&temp.path().join("selected")).unwrap();
        atomic_write(&root.join("original.part"), b"prefix").unwrap();
        atomic_write(&root.join("original.part.resume.json"), b"checkpoint").unwrap();
        let held = open(&root.join("original.part"), OFlags::RDWR).unwrap();
        let preserved = temp.path().join("preserved");
        std::fs::rename(&root, &preserved).unwrap();
        std::fs::create_dir(&root).unwrap();

        assert_unavailable(create_dir_all(&root.join("child")).unwrap_err());
        assert_unavailable(
            atomic_write(&root.join("original.part.resume.json"), b"new").unwrap_err(),
        );
        assert_unavailable(
            validate_open_file(&root.join("original.part"), &held.metadata().unwrap()).unwrap_err(),
        );
        assert_unavailable(selected_directory(&root).unwrap_err());
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 0);
        assert_eq!(
            std::fs::read(preserved.join("original.part")).unwrap(),
            b"prefix"
        );
        assert_eq!(
            std::fs::read(preserved.join("original.part.resume.json")).unwrap(),
            b"checkpoint"
        );
    }

    #[test]
    fn staging_descriptor_must_still_identify_the_current_file() {
        let temp = tempfile::tempdir().unwrap();
        let root = selected_directory(&temp.path().join("selected")).unwrap();
        let part = root.join("original.part");
        atomic_write(&part, b"prefix").unwrap();
        let held = open(&part, OFlags::RDWR).unwrap();
        let preserved = root.join("preserved.part");
        std::fs::rename(&part, &preserved).unwrap();
        std::fs::write(&part, b"replacement").unwrap();
        assert_unavailable(validate_open_file(&part, &held.metadata().unwrap()).unwrap_err());
        assert_eq!(std::fs::read(&part).unwrap(), b"replacement");
        assert_eq!(std::fs::read(&preserved).unwrap(), b"prefix");
    }

    #[test]
    fn missing_or_stale_volume_boundary_is_not_a_download_destination() {
        let temp = tempfile::tempdir().unwrap();
        let volumes = temp.path().join("Volumes");
        std::fs::create_dir(&volumes).unwrap();
        let path = volumes.join("absent/selected");
        assert_unavailable(mounted_root(&path, &volumes).unwrap_err());
        assert!(!volumes.join("absent").exists());
        std::fs::create_dir(volumes.join("stale")).unwrap();
        assert_unavailable(mounted_root(&volumes.join("stale/selected"), &volumes).unwrap_err());
        assert!(!volumes.join("stale/selected").exists());
        assert_eq!(external_root(&path, &volumes), Some(volumes.join("absent")));
        assert_eq!(external_root(temp.path(), &volumes), None);
    }

    #[test]
    fn descendants_never_follow_symlinks_and_publish_never_clobbers() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("root");
        let outside = temp.path().join("outside");
        create_dir_all(&root).unwrap();
        create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("linked")).unwrap();
        assert!(create_dir_all(&root.join("linked/child")).is_err());
        assert!(open(
            &root.join("linked/body.part"),
            OFlags::CREATE | OFlags::WRONLY
        )
        .is_err());
        assert!(!outside.join("body.part").exists());
        std::fs::write(root.join("body.part"), b"new").unwrap();
        std::fs::write(root.join("body"), b"old").unwrap();
        assert_eq!(
            publish_no_replace(&root.join("body.part"), &root.join("body"))
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::AlreadyExists
        );
        assert_eq!(std::fs::read(root.join("body")).unwrap(), b"old");
        assert!(root.join("body.part").exists());
    }

    #[test]
    fn unsupported_move_uses_no_clobber_link_and_optional_directory_sync() {
        let temp = tempfile::tempdir().unwrap();
        let partial = temp.path().join("body.part");
        let output = temp.path().join("body");
        std::fs::write(&partial, b"new").unwrap();
        let staged_identity = identity(&std::fs::metadata(&partial).unwrap());
        let unsupported = || std::io::Error::from(rustix::io::Errno::NOTSUP);
        let link =
            |from: &File, from_name: &std::ffi::OsStr, to: &File, to_name: &std::ffi::OsStr| {
                fs::linkat(from, from_name, to, to_name, AtFlags::empty()).map_err(Into::into)
            };
        publish_no_replace_using(
            &partial,
            &output,
            |_, _, _, _| Err(unsupported()),
            link,
            |_| Err(unsupported()),
        )
        .unwrap();
        assert!(!partial.exists());
        assert_eq!(std::fs::read(&output).unwrap(), b"new");
        assert_eq!(
            identity(&std::fs::metadata(&output).unwrap()),
            staged_identity
        );

        // A late destination is never replaced, even on the fallback path.
        std::fs::write(&partial, b"another").unwrap();
        let error = publish_no_replace_using(
            &partial,
            &output,
            |_, _, _, _| Err(unsupported()),
            link,
            File::sync_all,
        )
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read(&output).unwrap(), b"new");
        assert_eq!(std::fs::read(&partial).unwrap(), b"another");

        // Permission failures are real failures, rather than a capability hint.
        let error = publish_no_replace_using(
            &partial,
            &output,
            |_, _, _, _| Err(std::io::Error::from(rustix::io::Errno::ACCESS)),
            |_, _, _, _| panic!("Permission failure must not try another operation"),
            File::sync_all,
        )
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn unavailable_publication_capabilities_keep_staging_and_real_sync_errors_visible() {
        let temp = tempfile::tempdir().unwrap();
        let partial = temp.path().join("body.part");
        let output = temp.path().join("body");
        std::fs::write(&partial, b"complete").unwrap();
        let error = publish_no_replace_using(
            &partial,
            &output,
            |_, _, _, _| Err(std::io::Error::from(rustix::io::Errno::NOTSUP)),
            |_, _, _, _| Err(std::io::Error::from(rustix::io::Errno::NOTSUP)),
            File::sync_all,
        )
        .unwrap_err();
        assert!(unsupported_operation(&error));
        assert_eq!(std::fs::read(&partial).unwrap(), b"complete");
        assert!(!output.exists());

        // A failed sync after the move is not a failed move. The pending
        // receipt must be able to reconcile this already-published file.
        let error = publish_no_replace_using(
            &partial,
            &output,
            |from, from_name, to, to_name| {
                fs::renameat_with(from, from_name, to, to_name, fs::RenameFlags::NOREPLACE)
                    .map_err(Into::into)
            },
            |_, _, _, _| panic!("Successful rename must not try a link"),
            |_| Err(std::io::Error::from(rustix::io::Errno::IO)),
        )
        .unwrap_err();
        assert_eq!(
            error.raw_os_error(),
            Some(rustix::io::Errno::IO.raw_os_error())
        );
        assert!(!partial.exists());
        assert_eq!(std::fs::read(&output).unwrap(), b"complete");
    }
}

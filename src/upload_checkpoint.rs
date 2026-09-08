//! Durable upload batches. Only plans, local fingerprints, GCIDs and cloud
//! item IDs are saved — never access/refresh tokens or temporary OSS secrets.
//! A per-file journal avoids rewriting thousands of rows on each completion.
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

use anyhow::{bail, Context, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Fingerprint {
    size: u64,
    modified_nanos: u128,
}

impl Fingerprint {
    pub fn read(path: &Path) -> Result<Self> {
        let metadata = std::fs::symlink_metadata(path).context("read original upload source")?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            bail!("upload source is no longer a regular local file");
        }
        Ok(Self { size: metadata.len(), modified_nanos: metadata.modified()?.duration_since(UNIX_EPOCH)?.as_nanos() })
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct Manifest {
    version: u32,
    account_id: String,
    destination_id: String,
    inputs: Vec<PathBuf>,
    plan: Value,
    fingerprints: HashMap<PathBuf, Fingerprint>,
}

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct FileCheckpoint {
    pub gcid: Option<String>,
    pub remote_file_id: Option<String>,
    pub completed: bool,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct FolderCheckpoint {
    pub parent_id: String,
    pub name: String,
    pub previous_ids: Vec<String>,
    pub remote_id: Option<String>,
}

pub struct UploadCheckpoint {
    directory: PathBuf,
    _lock: File,
    manifest: Option<Manifest>,
    account_id: String,
    destination_id: String,
    inputs: Vec<PathBuf>,
}

impl UploadCheckpoint {
    pub fn open(directory: PathBuf, account_id: String, destination_id: String, mut inputs: Vec<PathBuf>) -> Result<Self> {
        private_directory(&directory)?;
        private_directory(&directory.join("files"))?;
        private_directory(&directory.join("folders"))?;
        let lock_path = directory.join("run.lock");
        validate_regular_if_present(&lock_path)?;
        let lock = private_options().create(true).read(true).write(true).open(lock_path)?;
        lock.try_lock().context("this upload batch is already running in another process")?;
        inputs.sort();
        let manifest: Option<Manifest> = read_optional(&directory.join("manifest.json"))?;
        if let Some(saved) = &manifest {
            if saved.version != 1 || saved.account_id != account_id || saved.destination_id != destination_id || saved.inputs != inputs {
                bail!("saved upload belongs to a different account, destination, source selection, or unsupported version");
            }
        }
        Ok(Self { directory, _lock: lock, manifest, account_id, destination_id, inputs })
    }

    pub fn plan<T: DeserializeOwned>(&self) -> Result<Option<T>> {
        self.manifest.as_ref().map(|manifest| serde_json::from_value(manifest.plan.clone()).context("invalid saved upload plan")).transpose()
    }

    pub fn initialize<T: Serialize>(&mut self, plan: &T, paths: impl Iterator<Item = PathBuf>) -> Result<()> {
        if self.manifest.is_some() { return Ok(()); }
        let fingerprints = paths.map(|path| Ok((path.clone(), Fingerprint::read(&path)?))).collect::<Result<_>>()?;
        let manifest = Manifest { version: 1, account_id: self.account_id.clone(), destination_id: self.destination_id.clone(),
            inputs: self.inputs.clone(), plan: serde_json::to_value(plan)?, fingerprints };
        write_atomic(&self.directory.join("manifest.json"), &manifest)?;
        self.manifest = Some(manifest);
        Ok(())
    }

    pub fn validate_source(&self, path: &Path) -> Result<()> {
        let expected = self.manifest.as_ref().and_then(|m| m.fingerprints.get(path))
            .context("source is missing from the saved upload plan")?;
        if &Fingerprint::read(path)? != expected {
            bail!("local file changed since this upload was started; choose it as a new upload instead");
        }
        Ok(())
    }

    fn file_path(&self, source: &Path) -> PathBuf {
        let key = hex::encode(ring::digest::digest(&ring::digest::SHA256, source.as_os_str().as_encoded_bytes()).as_ref());
        self.directory.join("files").join(format!("{key}.json"))
    }

    pub fn file(&self, source: &Path) -> Result<FileCheckpoint> {
        Ok(read_optional(&self.file_path(source))?.unwrap_or_default())
    }

    pub fn save_file(&self, source: &Path, state: &FileCheckpoint) -> Result<()> {
        write_atomic(&self.file_path(source), state)
    }

    pub fn folder(&self, index: usize) -> Result<Option<FolderCheckpoint>> {
        read_optional(&self.directory.join("folders").join(format!("{index}.json")))
    }

    pub fn save_folder(&self, index: usize, state: &FolderCheckpoint) -> Result<()> {
        write_atomic(&self.directory.join("folders").join(format!("{index}.json")), state)
    }
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)] {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn private_directory(path: &Path) -> Result<()> {
    if path.exists() {
        let metadata = std::fs::symlink_metadata(path)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() { bail!("invalid upload checkpoint directory"); }
    } else {
        std::fs::create_dir_all(path)?;
    }
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn validate_regular_if_present(path: &Path) -> Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => bail!("invalid upload checkpoint file"),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn read_optional<T: DeserializeOwned>(path: &Path) -> Result<Option<T>> {
    validate_regular_if_present(path)?;
    if !path.exists() { return Ok(None); }
    if std::fs::metadata(path)?.len() > 64 * 1024 * 1024 { bail!("upload checkpoint exceeds its size limit"); }
    Ok(Some(serde_json::from_slice(&std::fs::read(path)?).context("could not read saved upload checkpoint; it was not overwritten")?))
}

fn write_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    validate_regular_if_present(path)?;
    let temporary = path.with_extension(format!("tmp-{}-{}", std::process::id(), SEQUENCE.fetch_add(1, Ordering::Relaxed)));
    let result = (|| {
        let mut file = private_options().create_new(true).write(true).open(&temporary)?;
        serde_json::to_writer(&mut file, value)?;
        file.flush()?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() { let _ = std::fs::remove_file(&temporary); }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persists_plan_files_and_folders_and_binds_account() {
        let directory = std::env::temp_dir().join(format!("pikpak-checkpoint-{}", std::process::id()));
        let source = directory.join("source.txt");
        private_directory(&directory).unwrap();
        std::fs::write(&source, b"test data").unwrap();
        let run = directory.join("run");
        let mut first = UploadCheckpoint::open(run.clone(), "account-a".into(), "destination".into(), vec![source.clone()]).unwrap();
        first.initialize(&serde_json::json!({"files": ["source.txt"]}), [source.clone()].into_iter()).unwrap();
        first.save_file(&source, &FileCheckpoint { gcid: Some("ABC".into()), remote_file_id: Some("uploaded-id".into()), completed: true }).unwrap();
        first.save_folder(0, &FolderCheckpoint { parent_id: "destination".into(), name: "Folder".into(), previous_ids: vec![], remote_id: Some("folder-id".into()) }).unwrap();
        assert!(UploadCheckpoint::open(run.clone(), "account-a".into(), "destination".into(), vec![source.clone()]).is_err());
        drop(first);
        assert!(UploadCheckpoint::open(run.clone(), "account-b".into(), "destination".into(), vec![source.clone()]).is_err());
        let restored = UploadCheckpoint::open(run, "account-a".into(), "destination".into(), vec![source.clone()]).unwrap();
        assert_eq!(restored.plan::<Value>().unwrap().unwrap()["files"][0], "source.txt");
        assert!(restored.file(&source).unwrap().completed);
        assert_eq!(restored.folder(0).unwrap().unwrap().remote_id.as_deref(), Some("folder-id"));
        restored.validate_source(&source).unwrap();
        std::fs::write(&source, b"changed source").unwrap();
        assert!(restored.validate_source(&source).is_err());
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(restored.file_path(&source)).unwrap().permissions().mode() & 0o777, 0o600);
        }
        drop(restored);
        std::fs::remove_dir_all(directory).unwrap();
    }
}

//! Confirmed Trash/Undo acknowledgements mask immutable saved comparisons.
//! Ordinals stay stable; no original file or multi-gigabyte matrix is rewritten.
use super::*;
use std::collections::BTreeSet;
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;

#[derive(Serialize, Deserialize)]
pub(super) struct Exclusions {
    pub version: u32,
    pub run_id: String,
    pub result_revision: u64,
    pub ordinals: BTreeSet<usize>,
}

pub(super) fn load(matrix: &Path, run: &str, revision: u64) -> Result<Exclusions> {
    let path = matrix.with_extension("excluded.json");
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags((rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Exclusions {
                version: 1,
                run_id: run.into(),
                result_revision: revision,
                ordinals: BTreeSet::new(),
            })
        }
        Err(error) => return Err(error.into()),
    };
    if !file.metadata()?.is_file() || file.metadata()?.len() > 64 << 20 {
        bail!("Invalid saved Trash state.");
    }
    let mut bytes = Vec::new();
    file.take((64 << 20) + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 64 << 20 {
        bail!("Invalid saved Trash state.");
    }
    let saved: Exclusions = serde_json::from_slice(&bytes)?;
    if saved.version != 1 || saved.run_id != run || saved.result_revision != revision {
        bail!("The saved Trash state belongs to another comparison revision.");
    }
    Ok(saved)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResultFilesUpdate {
    pub data_dir: PathBuf,
    pub run_id: String,
    pub result_revision: u64,
    pub file_ids: Vec<String>,
    pub trashed: bool,
}

pub fn update_result_files(request: ResultFilesUpdate, cancel: &AtomicBool) -> Result<Value> {
    check_cancel(cancel)?;
    let matrix =
        store::SavedMatrix::open(&request.data_dir, &request.run_id, request.result_revision)?;
    if !request.run_id.starts_with("mcd2-") {
        bail!("This older scan cannot save Trash state.");
    }
    let source = request
        .data_dir
        .join("runs")
        .join(format!("{}.sqlite3", request.run_id));
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(source.with_extension("excluded.lock"))?;
    if !lock.metadata()?.is_file() {
        bail!("Invalid comparison state lock.");
    }
    rustix::fs::flock(&lock, rustix::fs::FlockOperation::LockExclusive)?;
    let mut saved = load(&source, &request.run_id, request.result_revision)?;
    let before = saved.ordinals.clone();
    let positions: HashMap<_, _> = matrix
        .files
        .iter()
        .enumerate()
        .map(|(i, f)| (f.id.as_str(), i))
        .collect();
    let ordinals = request
        .file_ids
        .iter()
        .map(|id| {
            positions
                .get(id.as_str())
                .copied()
                .context("A file no longer belongs to this saved comparison.")
        })
        .collect::<Result<Vec<_>>>()?;
    for ordinal in ordinals {
        check_cancel(cancel)?;
        if request.trashed {
            saved.ordinals.insert(ordinal);
        } else {
            saved.ordinals.remove(&ordinal);
        }
    }
    if saved.ordinals != before || !source.with_extension("excluded.json").exists() {
        let mut temporary = tempfile::NamedTempFile::new_in(source.parent().unwrap())?;
        serde_json::to_writer(temporary.as_file_mut(), &saved)?;
        temporary.as_file().sync_all()?;
        temporary.persist(source.with_extension("excluded.json"))?;
    }
    let forgotten = if request.trashed {
        source_cache::forget_files(&request.data_dir, &request.file_ids)?
    } else {
        0
    };
    Ok(json!({"excluded":saved.ordinals.len(),"forgotten_sources":forgotten}))
}

//! Torrent buffer uploads from RAM or a user-selected storage folder.
//! Re-downloaded files are checked by content, never by their old modification time.
use std::{path::{Component, Path, PathBuf}, sync::Arc, time::Duration};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use crate::{Client, FileInfo, upload_checkpoint::{private_directory, private_options, read_optional, write_atomic}};

#[derive(Clone, Debug, Deserialize)]
pub struct Source { pub index: u32, pub path: String, pub size: u64 }
#[derive(Clone, Debug, Deserialize)]
pub struct Request {
    pub version: u32,
    pub account_id: String,
    pub job_id: String,
    pub parent_id: String,
    pub root_name: String,
    pub ram_root: PathBuf, // Protocol v1 name; also used for an owned disk buffer.
    pub checkpoint_dir: PathBuf,
    pub files: Vec<Source>,
    #[serde(default)] pub reconcile_only: bool,
    /// Only metadata-confirmed padding entries may be sent in this mode.
    /// It never opens the torrent buffer or creates cloud files.
    #[serde(default)] pub cleanup_padding: bool,
    pub parent_pid: Option<u32>,
}
#[derive(Serialize, Deserialize, PartialEq, Eq)]
struct Binding { version: u32, account_id: String, job_id: String, parent_id: String, root_name: String }
#[derive(Default, Serialize, Deserialize)]
struct Receipt {
    path: String, size: u64, gcid: String, parent_id: String,
    remote_id: Option<String>, completed: bool,
    // Written BEFORE creating a cloud item. A lost response is reconciled by
    // comparing the new IDs with this snapshot, never by blindly uploading again.
    previous_ids: Option<Vec<String>>,
    #[serde(default)] padding_trashed: bool,
    #[serde(default)] padding_trash_requested_at: Option<u64>,
}
#[derive(Serialize, Deserialize)]
struct Folder { parent_id: String, name: String, remote_id: Option<String>, previous_ids: Vec<String> }
type Emit = Arc<dyn Fn(Value) + Send + Sync>;

fn components(path: &str) -> Result<Vec<&str>> {
    if path.is_empty() || path.len() > 16_384 || path.contains('\0') || path.contains('\\') { bail!("invalid torrent file path"); }
    let values: Vec<_> = path.split('/').collect();
    if values.iter().any(|part| part.is_empty() || *part == "." || *part == "..") ||
       Path::new(path).components().any(|part| !matches!(part, Component::Normal(_))) { bail!("torrent path escapes its buffer"); }
    Ok(values)
}
fn source_path(root: &Path, source: &Source) -> Result<PathBuf> {
    let mut path = root.to_owned();
    let meta = std::fs::symlink_metadata(&path)?;
    if !meta.is_dir() || meta.file_type().is_symlink() { bail!("torrent source directory changed"); }
    let parts = components(&source.path)?;
    for (index, part) in parts.iter().enumerate() {
        path.push(part);
        let meta = std::fs::symlink_metadata(&path).context("torrent buffer data is unavailable; restore its storage or resume the download")?;
        if meta.file_type().is_symlink() || if index + 1 == parts.len() { !meta.is_file() || meta.len() != source.size } else { !meta.is_dir() } {
            bail!("torrent source changed or has an unexpected size");
        }
    }
    Ok(path)
}
fn receipt_path(request: &Request, index: u32) -> PathBuf { request.checkpoint_dir.join("files").join(format!("{index}.json")) }
fn receipt(request: &Request, source: &Source) -> Result<Receipt> {
    let saved: Receipt = read_optional(&receipt_path(request, source.index))?.unwrap_or_else(|| Receipt { path: source.path.clone(), size: source.size, ..Default::default() });
    if saved.path != source.path || saved.size != source.size { bail!("saved torrent file identity changed"); }
    Ok(saved)
}
fn commit(request: &Request, source: &Source, saved: &mut Receipt, emit: &Emit) -> Result<()> {
    saved.completed = true;
    write_atomic(&receipt_path(request, source.index), saved)?;
    emit(json!({"event":"committed", "index":source.index, "size":source.size, "file_id":saved.remote_id, "parent_id":saved.parent_id}));
    Ok(())
}

pub async fn run(client: &Client, request: Request, emit: Emit) -> Result<()> {
    // Independent of the paused transfer future: an orphan helper must exit,
    // release checkpoint locks and stop uploading when its app disappears.
    let parent = request.parent_pid;
    let work = run_inner(client, request, emit);
    tokio::select! {
        result = work => result,
        _ = async move {
            loop {
                if let Some(parent) = parent {
                    if rustix::process::getppid().map_or(0, |pid| pid.as_raw_nonzero().get() as u32) != parent { return; }
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        } => bail!("torrent app closed; resume from saved upload receipts"),
    }
}

async fn run_inner(client: &Client, request: Request, emit: Emit) -> Result<()> {
    if request.version != 1 || request.account_id.is_empty() || request.job_id.is_empty() || request.files.len() > 200_000 || components(&request.root_name)?.len() != 1 {
        bail!("invalid torrent upload request");
    }
    let mut indexes = std::collections::HashSet::new();
    for source in &request.files {
        components(&source.path)?;
        if source.index == 0 || !indexes.insert(source.index) { bail!("invalid or duplicate torrent file index"); }
    }
    // Server-verified identity, before ANY cloud mutation, including recovery.
    if client.account_profile().await?.sub != request.account_id { bail!("Select the original PikPak account before resuming this torrent."); }
    private_directory(&request.checkpoint_dir)?;
    private_directory(&request.checkpoint_dir.join("files"))?;
    private_directory(&request.checkpoint_dir.join("folders"))?;
    let lock_path = request.checkpoint_dir.join("run.lock");
    if std::fs::symlink_metadata(&lock_path).is_ok_and(|m| !m.is_file() || m.file_type().is_symlink()) { bail!("invalid relay lock"); }
    let lock = private_options().create(true).read(true).write(true).open(lock_path)?;
    lock.try_lock().context("This torrent is already uploading in another process. Try Resume again shortly.")?;
    let binding = Binding { version: 1, account_id: request.account_id.clone(), job_id: request.job_id.clone(), parent_id: request.parent_id.clone(), root_name: request.root_name.clone() };
    let path = request.checkpoint_dir.join("identity.json");
    if let Some(saved) = read_optional::<Binding>(&path)? {
        if saved != binding { bail!("saved torrent upload belongs to another account or destination"); }
    } else if request.cleanup_padding {
        if request.files.iter().any(|source| receipt_path(&request, source.index).exists()) {
            bail!("Padding cleanup needs the original upload identity record. Existing cloud files were kept.");
        }
        emit(json!({"event":"padding_cleaned", "checked":request.files.iter().map(|s| s.index).collect::<Vec<_>>(), "removed":[]}));
        emit(json!({"event":"finished"}));
        return Ok(());
    } else { write_atomic(&path, &binding)?; }
    if request.cleanup_padding {
        padding::cleanup(client, &request, &emit).await?;
        emit(json!({"event":"finished"}));
        return Ok(());
    }
    let mut folder_cache = std::collections::HashMap::new();
    for source in &request.files {
        let mut saved = receipt(&request, source)?;
        if saved.completed { commit(&request, source, &mut saved, &emit)?; continue; }
        if reconcile(client, &request, source, &mut saved, &emit).await? { continue; }
        if request.reconcile_only { continue; }
        let local = source_path(&request.ram_root, source)?;
        let index = source.index;
        emit(json!({"event":"hashing", "index":index, "size":source.size}));
        let progress = emit.clone();
        let gcid = crate::upload::gcid_file(&local, source.size, Arc::new(move |bytes| progress(json!({"event":"hash_progress", "index":index, "bytes":bytes})))).await?;
        if !saved.gcid.is_empty() && !saved.gcid.eq_ignore_ascii_case(&gcid) { bail!("re-downloaded torrent data differs from its saved content identity"); }
        saved.gcid = gcid;
        if saved.parent_id.is_empty() {
            let mut parent = cached_folder(client, &request, "", &request.parent_id, &request.root_name, &mut folder_cache).await?;
            let parts = components(&source.path)?;
            let mut key = String::new();
            for part in &parts[..parts.len()-1] {
                key.push('/'); key.push_str(part);
                parent = cached_folder(client, &request, &key, &parent, part, &mut folder_cache).await?;
            }
            saved.parent_id = parent;
            write_atomic(&receipt_path(&request, index), &saved)?;
        }
        // This ID is owned by this receipt. A failed/abandoned upload can be
        // replaced after checking it did not finish. Never delete completed files.
        if let Some(id) = &saved.remote_id {
            if client.completed_upload_matches(id, &saved.gcid, source.size).await? {
                commit(&request, source, &mut saved, &emit)?; continue;
            }
            client.trash_files(&[id.clone()]).await?;
            saved.remote_id = None; saved.previous_ids = None;
            write_atomic(&receipt_path(&request, index), &saved)?;
        }
        let name = components(&source.path)?.last().unwrap().to_string();
        saved.previous_ids = Some(named(client, &saved.parent_id, &name).await?.into_iter().map(|f| f.id).collect());
        write_atomic(&receipt_path(&request, index), &saved)?;
        let task = match client.create_upload_task_once(&saved.parent_id, &name, source.size, &saved.gcid).await {
            Ok(task) => task,
            Err(error) => {
                // A definite rejection did not create an upload. Timeouts and
                // server errors keep the intent for response-loss reconciliation.
                if matches!(&error, crate::Error::Api {status, ..} if (400..500).contains(status) && *status != 408) {
                    saved.previous_ids = None; write_atomic(&receipt_path(&request, index), &saved)?;
                }
                return Err(error.into());
            }
        };
        saved.remote_id = Some(task.file_id.context("PikPak returned no upload file ID; Resume to reconcile its response")?);
        write_atomic(&receipt_path(&request, index), &saved)?;
        if !task.completed {
            source_path(&request.ram_root, source)?;
            emit(json!({"event":"uploading", "index":index, "size":source.size}));
            let progress = emit.clone();
            crate::upload::upload_to_oss(client.upload_http_client(), &task.oss.context("missing upload transport")?, &local, source.size, 4,
                Arc::new(move |bytes| progress(json!({"event":"upload_progress", "index":index, "bytes":bytes})))).await?;
            // OSS completion is acknowledged before the durable receipt. If the
            // app exits here, reconciliation verifies the cloud file's GCID.
        }
        commit(&request, source, &mut saved, &emit)?;
    }
    emit(json!({"event":"finished"}));
    Ok(())
}

async fn named(client: &Client, parent: &str, name: &str) -> Result<Vec<FileInfo>> {
    Ok(client.list_upload_candidates(parent).await?.into_iter().filter(|file| file.name == name).collect())
}
async fn reconcile(client: &Client, request: &Request, source: &Source, saved: &mut Receipt, emit: &Emit) -> Result<bool> {
    if saved.remote_id.is_none() {
        if let Some(previous) = &saved.previous_ids {
            let name = components(&source.path)?.last().unwrap().to_string();
            let named_alike = named(client, &saved.parent_id, &name).await?;
            let appeared: Vec<_> = named_alike.iter().filter(|file| !previous.contains(&file.id)).collect();
            let matches: Vec<_> = appeared.iter().copied()
                .filter(|file| file.kind.is_file() && file.size == source.size && file.hash.as_deref().filter(|hash| !hash.trim().is_empty()).is_none_or(|hash| hash.eq_ignore_ascii_case(&saved.gcid))).collect();
            if matches.len() != 1 {
                if appeared.is_empty() {
                    // Nothing came into existence after the intent was recorded,
                    // so that create produced no file and re-creating cannot
                    // duplicate one. Releasing the intent is what lets Resume
                    // make progress instead of repeating this check forever.
                    saved.previous_ids = None;
                    write_atomic(&receipt_path(request, source.index), saved)?;
                    return Ok(false);
                }
                // Counts only: "nothing was ever created" and "several matched"
                // need opposite responses, and the old wording told them apart
                // for nobody. Never name the file; the operator knows the index.
                let folders = appeared.iter().filter(|file| !file.kind.is_file()).count();
                let wrong_size = appeared.iter().filter(|file| file.kind.is_file() && file.size != source.size).count();
                let wrong_hash = appeared.len() - folders - wrong_size - matches.len();
                bail!("PikPak's upload response for file #{} was lost and recovery found {} candidates instead of 1 \
                       ({} named alike in the destination: {} from before the upload, {} folders, {} sized differently, \
                       {} reporting other content). No duplicate was created.",
                      source.index, matches.len(), named_alike.len(),
                      named_alike.len() - appeared.len(), folders, wrong_size, wrong_hash);
            }
            saved.remote_id = Some(matches[0].id.clone());
            write_atomic(&receipt_path(request, source.index), saved)?;
        }
    }
    if let Some(id) = &saved.remote_id {
        if client.completed_upload_matches(id, &saved.gcid, source.size).await? {
            commit(request, source, saved, emit)?; return Ok(true);
        }
    }
    Ok(false)
}

async fn folder(client: &Client, request: &Request, key: &str, parent: &str, name: &str) -> Result<String> {
    let hash = hex::encode(ring::digest::digest(&ring::digest::SHA256, key.as_bytes()));
    let path = request.checkpoint_dir.join("folders").join(format!("{hash}.json"));
    if let Some(mut saved) = read_optional::<Folder>(&path)? {
        if saved.parent_id != parent || saved.name != name { bail!("saved torrent destination changed"); }
        if let Some(id) = saved.remote_id {
            if !client.list_folder(parent).await?.iter().any(|file| file.id == id && file.kind.is_folder()) { bail!("torrent destination moved or is no longer a folder"); }
            return Ok(id);
        }
        let matches: Vec<_> = named(client, parent, name).await?.into_iter().filter(|file| file.kind.is_folder() && !saved.previous_ids.contains(&file.id)).collect();
        if matches.len() != 1 { bail!("PikPak's folder creation response was lost. Resume after its file list updates; no second folder was created."); }
        saved.remote_id = Some(matches[0].id.clone()); write_atomic(&path, &saved)?;
        return Ok(matches[0].id.clone());
    }
    let previous_ids = named(client, parent, name).await?.into_iter().map(|file| file.id).collect();
    let mut saved = Folder { parent_id: parent.into(), name: name.into(), remote_id: None, previous_ids };
    write_atomic(&path, &saved)?;
    let result = client.create_folder_once(parent, name).await;
    if matches!(&result, Err(crate::Error::Api {status, ..}) if (400..500).contains(status) && *status != 408) { std::fs::remove_file(&path)?; }
    let file = result?;
    saved.remote_id = Some(file.clone()); write_atomic(&path, &saved)?;
    Ok(file)
}

async fn cached_folder(client: &Client, request: &Request, key: &str, parent: &str, name: &str, cache: &mut std::collections::HashMap<String,String>) -> Result<String> {
    if let Some(id) = cache.get(key) { return Ok(id.clone()); }
    let id = folder(client, request, key, parent, name).await?;
    cache.insert(key.into(), id.clone());
    Ok(id)
}

#[cfg(test)]
#[path = "torrent_relay_tests.rs"]
mod tests;

#[path = "torrent_padding.rs"]
mod padding;

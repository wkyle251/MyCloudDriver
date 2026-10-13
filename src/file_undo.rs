//! Guarded reversals of confirmed native-app file changes. Never permanently deletes.
use crate::Client;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ChangeKind {
    Trash,
    Move,
    Rename,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChange {
    pub id: String,
    pub file_id: String,
    pub kind: ChangeKind,
    pub before: String,
    pub after: String,
    pub parent_id: Option<String>,
    pub name: Option<String>,
    #[serde(default)]
    pub requires_empty_folder: bool,
}

#[derive(Debug, Deserialize)]
pub struct UndoRequest {
    pub changes: Vec<FileChange>,
}
#[derive(Debug, Serialize)]
pub struct UndoResult {
    pub completed: Vec<String>,
    pub error: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CloudFileState {
    pub id: String,
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub trashed: bool,
}

trait Backend {
    async fn read(&self, id: &str) -> Result<CloudFileState>;
    async fn has_children(&self, id: &str) -> Result<bool>;
    async fn change(&self, change: &FileChange) -> Result<()>;
}
impl Backend for Client {
    async fn read(&self, id: &str) -> Result<CloudFileState> {
        Ok(self.file_undo_state(id).await?)
    }
    async fn has_children(&self, id: &str) -> Result<bool> {
        Ok(self.folder_has_live_children(id).await?)
    }
    async fn change(&self, change: &FileChange) -> Result<()> {
        let ids = vec![change.file_id.clone()];
        match change.kind {
            ChangeKind::Trash if change.after == "true" => self.trash_files(&ids).await?,
            ChangeKind::Trash => self.untrash_files(&ids).await?,
            ChangeKind::Move => self.move_files(&ids, &change.after).await?,
            ChangeKind::Rename => self.rename_file(&change.file_id, &change.after).await?,
        }
        Ok(())
    }
}

impl FileChange {
    fn validate(&self) -> Result<()> {
        if self.id.trim().is_empty() || self.file_id.trim().is_empty() {
            bail!("Missing undo item identity");
        }
        match self.kind {
            ChangeKind::Trash
                if !["true", "false"].contains(&self.before.as_str())
                    || !["true", "false"].contains(&self.after.as_str()) =>
            {
                bail!("Invalid Trash state")
            }
            ChangeKind::Rename if self.before.trim().is_empty() || self.after.trim().is_empty() => {
                bail!("Missing rename value")
            }
            ChangeKind::Move if self.after == self.file_id => {
                bail!("A folder cannot be moved into itself")
            }
            _ => Ok(()),
        }
    }
    fn value(&self, state: &CloudFileState) -> String {
        match self.kind {
            ChangeKind::Trash => state.trashed.to_string(),
            ChangeKind::Move => state.parent_id.clone().unwrap_or_default(),
            ChangeKind::Rename => state.name.clone(),
        }
    }
    fn validate_context(&self, state: &CloudFileState) -> Result<()> {
        if state.id != self.file_id {
            bail!("PikPak returned a different file");
        }
        if self.kind != ChangeKind::Rename
            && self.name.as_ref().is_some_and(|name| name != &state.name)
        {
            bail!("This item was renamed outside the undo history. Refresh the folder before retrying.");
        }
        if self.kind != ChangeKind::Move
            && self
                .parent_id
                .as_ref()
                .is_some_and(|parent| parent != state.parent_id.as_deref().unwrap_or(""))
        {
            bail!("This item changed folders outside the undo history. Refresh the folder before retrying.");
        }
        if self.kind != ChangeKind::Trash && state.trashed {
            bail!("This item is now in Trash");
        }
        Ok(())
    }
}

async fn apply_one(backend: &impl Backend, change: &FileChange) -> Result<()> {
    let state = backend.read(&change.file_id).await?;
    change.validate_context(&state)?;
    // A retry after a lost response must not apply the inverse twice.
    if change.value(&state) == change.after {
        return Ok(());
    }
    if change.value(&state) != change.before {
        bail!("The item changed outside the undo history. Refresh the folder before retrying.");
    }
    if change.kind == ChangeKind::Trash
        && change.after == "true"
        && change.requires_empty_folder
        && state.kind == "drive#folder"
        && backend.has_children(&change.file_id).await?
    {
        bail!("The uploaded or new folder contains other items. They were kept; undo those changes first.");
    }
    let destination = match change.kind {
        ChangeKind::Move => Some(change.after.as_str()),
        ChangeKind::Trash if change.after == "false" => change.parent_id.as_deref(),
        _ => None,
    };
    if let Some(parent) = destination.filter(|id| !id.is_empty()) {
        let parent = backend
            .read(parent)
            .await
            .context("The original destination is unavailable")?;
        if parent.trashed || parent.kind != "drive#folder" {
            bail!("The destination folder is unavailable. Restore it before retrying.");
        }
    }
    backend.change(change).await?;
    // batchMove can be accepted before the new parent is visible in reads.
    for attempt in 0..12 {
        let updated = backend.read(&change.file_id).await?;
        change.validate_context(&updated)?;
        if change.value(&updated) == change.after {
            return Ok(());
        }
        if attempt < 11 {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
    }
    bail!("PikPak has not confirmed the change yet. Retry Undo after refreshing.")
}

async fn execute(backend: &impl Backend, request: UndoRequest) -> UndoResult {
    let mut completed = vec![];
    let mut seen = HashSet::new();
    for change in &request.changes {
        if let Err(error) = change.validate() {
            return UndoResult {
                completed,
                error: Some(error.to_string()),
            };
        }
        if !seen.insert(change.id.clone()) {
            return UndoResult {
                completed,
                error: Some("Duplicate undo change identity".into()),
            };
        }
    }
    for change in request.changes {
        match apply_one(backend, &change).await {
            Ok(()) => completed.push(change.id),
            Err(error) => {
                return UndoResult {
                    completed,
                    error: Some(format!("{error:#}")),
                }
            }
        }
    }
    UndoResult {
        completed,
        error: None,
    }
}

pub async fn undo_files(client: &Client, request: UndoRequest) -> UndoResult {
    execute(client, request).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    struct Fake {
        files: RefCell<HashMap<String, CloudFileState>>,
        calls: RefCell<Vec<String>>,
        fail: Option<String>,
    }
    fn file(id: &str, parent: &str, folder: bool) -> CloudFileState {
        CloudFileState {
            id: id.into(),
            name: id.into(),
            kind: if folder { "drive#folder" } else { "drive#file" }.into(),
            parent_id: Some(parent.into()),
            trashed: false,
        }
    }
    fn fake(files: Vec<CloudFileState>) -> Fake {
        Fake {
            files: RefCell::new(files.into_iter().map(|f| (f.id.clone(), f)).collect()),
            calls: RefCell::new(vec![]),
            fail: None,
        }
    }
    fn change(id: &str, kind: ChangeKind, before: &str, after: &str) -> FileChange {
        FileChange {
            id: format!("change-{id}"),
            file_id: id.into(),
            kind,
            before: before.into(),
            after: after.into(),
            parent_id: None,
            name: None,
            requires_empty_folder: false,
        }
    }
    impl Backend for Fake {
        async fn read(&self, id: &str) -> Result<CloudFileState> {
            self.files
                .borrow()
                .get(id)
                .cloned()
                .context("File no longer exists")
        }
        async fn has_children(&self, id: &str) -> Result<bool> {
            Ok(self
                .files
                .borrow()
                .values()
                .any(|f| f.parent_id.as_deref() == Some(id) && !f.trashed))
        }
        async fn change(&self, c: &FileChange) -> Result<()> {
            self.calls.borrow_mut().push(c.file_id.clone());
            if self.fail.as_ref() == Some(&c.file_id) {
                bail!("Synthetic server failure");
            }
            let mut files = self.files.borrow_mut();
            let state = files.get_mut(&c.file_id).unwrap();
            match c.kind {
                ChangeKind::Trash => state.trashed = c.after == "true",
                ChangeKind::Move => state.parent_id = Some(c.after.clone()),
                ChangeKind::Rename => state.name = c.after.clone(),
            }
            Ok(())
        }
    }

    #[tokio::test]
    async fn restores_trash_moves_to_root_and_renames_without_recreating_ids() {
        let mut trashed = file("report", "", false);
        trashed.trashed = true;
        let backend = fake(vec![
            trashed,
            file("projects", "", true),
            file("notes", "projects", false),
        ]);
        let changes = vec![
            change("report", ChangeKind::Trash, "true", "false"),
            change("notes", ChangeKind::Move, "projects", ""),
            change("report", ChangeKind::Rename, "report", "renamed"),
        ];
        // Distinct changes on one cloud ID carry distinct operation identities.
        let mut changes = changes;
        changes[2].id = "rename-report".into();
        let result = execute(&backend, UndoRequest { changes }).await;
        assert!(result.error.is_none());
        assert_eq!(result.completed.len(), 3);
        let files = backend.files.borrow();
        assert!(!files["report"].trashed);
        assert_eq!(files["report"].name, "renamed");
        assert_eq!(files["notes"].parent_id.as_deref(), Some(""));
        assert_eq!(files.len(), 3);
    }

    #[tokio::test]
    async fn undo_upload_removes_only_its_own_files_and_keeps_nonempty_folders() {
        let backend = fake(vec![
            file("upload-folder", "", true),
            file("own", "upload-folder", false),
            file("unrelated", "upload-folder", false),
        ]);
        let mut folder = change("upload-folder", ChangeKind::Trash, "false", "true");
        folder.requires_empty_folder = true;
        let result = execute(
            &backend,
            UndoRequest {
                changes: vec![
                    change("own", ChangeKind::Trash, "false", "true"),
                    folder.clone(),
                ],
            },
        )
        .await;
        assert_eq!(result.completed, ["change-own"]);
        assert!(result.error.unwrap().contains("other items"));
        assert!(!backend.files.borrow()["unrelated"].trashed);
        assert!(!backend.files.borrow()["upload-folder"].trashed);
        backend
            .files
            .borrow_mut()
            .get_mut("unrelated")
            .unwrap()
            .parent_id = Some("".into());
        let result = execute(
            &backend,
            UndoRequest {
                changes: vec![folder],
            },
        )
        .await;
        assert!(result.error.is_none());
        assert!(backend.files.borrow()["upload-folder"].trashed);
    }

    #[tokio::test]
    async fn partial_failure_is_reported_and_retry_does_not_repeat_confirmed_changes() {
        let mut backend = fake(vec![file("a", "", false), file("b", "", false)]);
        backend.fail = Some("b".into());
        let changes = vec![
            change("a", ChangeKind::Trash, "false", "true"),
            change("b", ChangeKind::Trash, "false", "true"),
        ];
        let result = execute(
            &backend,
            UndoRequest {
                changes: changes.clone(),
            },
        )
        .await;
        assert_eq!(result.completed, ["change-a"]);
        assert!(result.error.is_some());
        backend.fail = None;
        let result = execute(&backend, UndoRequest { changes }).await;
        assert_eq!(result.completed.len(), 2);
        assert!(result.error.is_none());
        assert_eq!(*backend.calls.borrow(), ["a", "b", "b"]);
    }

    #[tokio::test]
    async fn external_changes_missing_parent_and_invalid_requests_do_not_mutate() {
        let backend = fake(vec![file("a", "other", false)]);
        let mut stale = change("a", ChangeKind::Trash, "false", "true");
        stale.parent_id = Some("original".into());
        assert!(execute(
            &backend,
            UndoRequest {
                changes: vec![stale]
            }
        )
        .await
        .error
        .is_some());
        assert!(execute(
            &backend,
            UndoRequest {
                changes: vec![change("a", ChangeKind::Move, "other", "missing")]
            }
        )
        .await
        .error
        .is_some());
        let c = change("a", ChangeKind::Trash, "false", "true");
        assert!(execute(
            &backend,
            UndoRequest {
                changes: vec![c.clone(), c]
            }
        )
        .await
        .error
        .is_some());
        assert!(backend.calls.borrow().is_empty());
    }

    #[tokio::test]
    async fn authenticated_restore_contract_and_unfinished_children_are_checked() {
        use std::sync::{
            atomic::{AtomicBool, AtomicUsize, Ordering},
            Arc,
        };
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let trashed = Arc::new(AtomicBool::new(true));
        let mutations = Arc::new(AtomicUsize::new(0));
        let server_state = trashed.clone();
        let server_mutations = mutations.clone();
        let server = tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut data = Vec::new();
                let mut buf = [0; 4096];
                let (header, body) = loop {
                    let count = stream.read(&mut buf).await.unwrap();
                    assert!(count > 0);
                    data.extend_from_slice(&buf[..count]);
                    let request = String::from_utf8_lossy(&data);
                    if let Some(end) = request.find("\r\n\r\n") {
                        let header = &request[..end];
                        let length = header
                            .lines()
                            .find_map(|line| {
                                line.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|n| n.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if data.len() >= end + 4 + length {
                            break (
                                header.to_string(),
                                request[end + 4..end + 4 + length].to_string(),
                            );
                        }
                    }
                };
                let route = header.lines().next().unwrap();
                let response = if route.starts_with("POST /v1/auth/token") {
                    serde_json::json!({"access_token":"fixture-access","refresh_token":"fixture-next","expires_in":3600,"sub":"fixture-user"})
                } else if route.starts_with("POST /v1/shield/captcha/init") {
                    serde_json::json!({"captcha_token":"fixture-captcha","expires_in":3600})
                } else {
                    assert!(header.to_lowercase().contains("authorization: bearer fixture-access"), "unexpected drive request: {route}");
                    assert!(header.to_lowercase().contains("x-device-id: fixture-device"));
                    if route.starts_with("GET /drive/v1/files/file ") {
                        serde_json::json!({"id":"file","name":"report","parent_id":"","kind":"drive#file","trashed":server_state.load(Ordering::SeqCst)})
                    } else if route.starts_with("POST /drive/v1/files:batchUntrash ") {
                        assert_eq!(serde_json::from_str::<serde_json::Value>(&body).unwrap(), serde_json::json!({"ids":["file"]}));
                        server_state.store(false, Ordering::SeqCst); server_mutations.fetch_add(1, Ordering::SeqCst);
                        serde_json::json!({})
                    } else if route.starts_with("GET /drive/v1/files?") {
                        assert!(!route.contains("phase"), "unfinished upload children must be included");
                        serde_json::json!({"files":[{"id":"unfinished","name":"uploading","kind":"drive#file","phase":"PHASE_TYPE_PENDING"}]})
                    } else { panic!("Unexpected request: {route}"); }
                }.to_string();
                stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", response.len(), response).as_bytes()).await.unwrap();
            }
        });
        let client = Client::builder()
            .refresh_token("fixture-refresh")
            .device_id("fixture-device")
            .api_base_url(format!("http://{address}"))
            .auth_base_url(format!("http://{address}"))
            .build()
            .unwrap();
        let result = undo_files(
            &client,
            UndoRequest {
                changes: vec![change("file", ChangeKind::Trash, "true", "false")],
            },
        )
        .await;
        assert!(result.error.is_none(), "{:?}", result.error);
        assert_eq!(result.completed.len(), 1);
        assert_eq!(mutations.load(Ordering::SeqCst), 1);
        assert!(!trashed.load(Ordering::SeqCst));
        assert!(client.folder_has_live_children("folder").await.unwrap());
        server.abort();
    }
}

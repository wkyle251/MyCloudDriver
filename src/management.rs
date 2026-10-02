//! Account-owned management operations. Content download mode never changes
//! who owns a cloud task, a share, or Trash. Only whitelisted metadata crosses
//! the native helper boundary; bearer tokens and signed media URLs stay private.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use futures_util::{stream, StreamExt, TryStreamExt};
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

use crate::{Client, Error, Result};

#[derive(Deserialize)]
pub struct ManagementRequest {
    pub account_id: String,
    #[serde(flatten)]
    pub action: ManagementAction,
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum ManagementAction {
    AccountDetails,
    ListTasks {
        #[serde(default)]
        page_token: String,
    },
    CreateTask {
        url: String,
        #[serde(default)]
        parent_id: String,
    },
    RetryTask {
        id: String,
    },
    RemoveTask {
        id: String,
        confirmed: bool,
    },
    ListShares {
        #[serde(default)]
        page_token: String,
    },
    CreateShare {
        ids: Vec<String>,
        title: String,
        expiration_days: i64,
        password_protected: bool,
    },
    UpdateShare {
        id: String,
        expiration_days: i64,
    },
    RemoveShares {
        ids: Vec<String>,
        confirmed: bool,
    },
    ListTrash {
        #[serde(default)]
        page_token: String,
    },
    RestoreTrash {
        ids: Vec<String>,
    },
    DeleteTrash {
        ids: Vec<String>,
        confirmed: bool,
    },
    EmptyTrash {
        confirmed: bool,
    },
    PickFiles {
        #[serde(default)]
        parent_id: String,
        #[serde(default)]
        page_token: String,
    },
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct CredentialMetadata {
    pub kind: String,
    pub expires_at: Option<u64>,
    pub permissions: Option<Vec<String>>,
    pub can_permanently_delete: bool,
}

impl Client {
    pub async fn manage(&self, request: ManagementRequest) -> Result<Value> {
        if request.account_id.trim().is_empty() {
            return Err(Error::InvalidPath("a verified account is required"));
        }
        // Verify before every operation, including mutations submitted by a
        // sheet retained across a multi-window account change.
        let profile = self.account_profile().await?;
        if profile.sub != request.account_id {
            return Err(Error::Auth(
                "The account changed. Close this dialog and try again.".into(),
            ));
        }
        let mut result = match request.action {
            ManagementAction::AccountDetails => {
                let metadata = credential_metadata(
                    self.tokens().is_personal_access_token(),
                    &self.tokens().access_token().await?,
                );
                json!({"profile": profile, "credential": metadata})
            }
            ManagementAction::ListTasks { page_token } => {
                let value = self
                    .management_request(
                        Method::GET,
                        "/tasks",
                        &page_query(
                            page_token,
                            vec![
                                ("type", "offline".into()),
                                ("with", "reference_resource".into()),
                            ],
                        ),
                        None,
                    )
                    .await?;
                page(&value, "tasks", "tasks", normalize_task)?
            }
            ManagementAction::CreateTask { url, parent_id } => {
                let url = validate_cloud_url(&url)?;
                self.validate_management_destination(&parent_id).await?;
                let body = json!({"kind":"drive#file", "upload_type":"UPLOAD_TYPE_URL",
                    "parent_id":parent_id, "url":{"url":url}, "params":{"create_from":"MyCloudDriver"}});
                let value = self
                    .management_request(Method::POST, "/files", &[], Some(body))
                    .await?;
                let task = value.get("task").unwrap_or(&value);
                if text(task, "id").is_empty() {
                    return Err(unrecognized(
                        "task creation result; refresh Cloud Downloads before submitting again",
                    ));
                }
                json!({"task":normalize_task(task)?})
            }
            ManagementAction::RetryTask { id } => {
                validate_id(&id)?;
                self.management_request(
                    Method::POST,
                    "/task",
                    &[],
                    Some(json!({"id":id,"create_type":"RETRY","type":"offline"})),
                )
                .await?;
                json!({"ok":true})
            }
            ManagementAction::RemoveTask { id, confirmed } => {
                confirm(confirmed)?;
                validate_id(&id)?;
                // Removing a task never deletes its saved file.
                self.management_request(
                    Method::DELETE,
                    "/tasks",
                    &[("task_ids", id), ("delete_files", "false".into())],
                    None,
                )
                .await?;
                json!({"ok":true})
            }
            ManagementAction::ListShares { page_token } => {
                let value = self
                    .management_request(
                        Method::GET,
                        "/share/list",
                        &page_query(page_token, vec![]),
                        None,
                    )
                    .await?;
                page(&value, "data", "shares", normalize_share)?
            }
            ManagementAction::CreateShare {
                ids,
                title,
                expiration_days,
                password_protected,
            } => {
                validate_ids(&ids)?;
                validate_expiration(expiration_days)?;
                if title.trim().is_empty() || title.chars().count() > 200 {
                    return Err(Error::InvalidPath(
                        "share title must contain 1–200 characters",
                    ));
                }
                let body = json!({"file_ids":ids, "title":title.trim(), "expiration_days":expiration_days,
                    "restore_limit":-1, "share_to":if password_protected {"encryptedlink"} else {"publiclink"},
                    "pass_code_option":if password_protected {"REQUIRED"} else {"NOT_REQUIRED"}});
                let value = self
                    .management_request(Method::POST, "/share", &[], Some(body))
                    .await?;
                let mut share = normalize_share(&value)?;
                if text(&share, "title").is_empty() {
                    share["title"] = json!(title.trim());
                }
                json!({"share":share})
            }
            ManagementAction::UpdateShare {
                id,
                expiration_days,
            } => {
                validate_id(&id)?;
                validate_expiration(expiration_days)?;
                self.management_request(
                    Method::PATCH,
                    "/share",
                    &[],
                    Some(json!({"share_id":id,"expiration_days":expiration_days})),
                )
                .await?;
                json!({"ok":true})
            }
            ManagementAction::RemoveShares { ids, confirmed } => {
                confirm(confirmed)?;
                validate_ids(&ids)?;
                self.management_request(
                    Method::POST,
                    "/share:batchDelete",
                    &[],
                    Some(json!({"ids":ids})),
                )
                .await?;
                json!({"ok":true})
            }
            ManagementAction::ListTrash { page_token } => {
                let query = page_query(
                    page_token,
                    vec![
                        ("parent_id", "*".into()),
                        ("with_audit", "true".into()),
                        (
                            "filters",
                            json!({"trashed":{"eq":true},"phase":{"eq":"PHASE_TYPE_COMPLETE"}})
                                .to_string(),
                        ),
                    ],
                );
                let value = self
                    .management_request(Method::GET, "/files", &query, None)
                    .await?;
                page(&value, "files", "files", normalize_file)?
            }
            ManagementAction::RestoreTrash { ids } => {
                self.validate_trashed_ids(&ids).await?;
                self.management_request(
                    Method::POST,
                    "/files:batchUntrash",
                    &[],
                    Some(json!({"ids":ids})),
                )
                .await?;
                json!({"ok":true})
            }
            ManagementAction::DeleteTrash { ids, confirmed } => {
                self.require_permanent_delete(confirmed)?;
                self.validate_trashed_ids(&ids).await?;
                self.management_request(
                    Method::POST,
                    "/files:batchDelete",
                    &[],
                    Some(json!({"ids":ids})),
                )
                .await?;
                json!({"ok":true})
            }
            ManagementAction::EmptyTrash { confirmed } => {
                self.require_permanent_delete(confirmed)?;
                self.management_request(Method::PATCH, "/files/trash:empty", &[], None)
                    .await?;
                json!({"ok":true})
            }
            ManagementAction::PickFiles {
                parent_id,
                page_token,
            } => {
                if !parent_id.is_empty() {
                    validate_id(&parent_id)?;
                }
                let query = page_query(
                    page_token,
                    vec![
                        ("parent_id", parent_id),
                        (
                            "filters",
                            json!({"trashed":{"eq":false},"phase":{"eq":"PHASE_TYPE_COMPLETE"}})
                                .to_string(),
                        ),
                    ],
                );
                let value = self
                    .management_request(Method::GET, "/files", &query, None)
                    .await?;
                page(&value, "files", "files", normalize_file)?
            }
        };
        result["account_id"] = json!(profile.sub);
        Ok(result)
    }

    async fn management_request(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
        body: Option<Value>,
    ) -> Result<Value> {
        let url = format!("{}/drive/v1{path}", self.api_base.trim_end_matches('/'));
        let action = format!("{method}:/drive/v1{path}");
        let read = method == Method::GET;
        let response = self
            .drive_request_with_retry(method, &url, &action, query, body.as_ref(), read)
            .await
            .map_err(management_error)?;
        if response.trim().is_empty() {
            return Ok(json!({}));
        }
        let value: Value = serde_json::from_str(&response)?;
        if value
            .get("error")
            .and_then(Value::as_str)
            .is_some_and(|s| !s.is_empty())
        {
            return Err(Error::Api {
                status: 200,
                message:
                    "PikPak did not complete this operation. Refresh the workspace before retrying."
                        .into(),
            });
        }
        Ok(value)
    }

    async fn validate_management_destination(&self, id: &str) -> Result<()> {
        if id.is_empty() {
            return Ok(());
        }
        validate_id(id)?;
        let file = self.file_metadata(id).await?;
        if file["kind"] != "drive#folder" || file["trashed"] != false {
            return Err(Error::InvalidPath(
                "choose an existing folder outside Trash",
            ));
        }
        Ok(())
    }

    async fn validate_trashed_ids(&self, ids: &[String]) -> Result<()> {
        validate_ids(ids)?;
        // Complete all preflight checks before changing any file. A stale
        // selection can never permanently delete an item that was restored.
        let states: Vec<_> = stream::iter(ids.iter())
            .map(|id| async move { Ok::<_, Error>((id, self.file_metadata(id).await?)) })
            .buffered(8)
            .try_collect()
            .await?;
        for (id, file) in states {
            if text(&file, "id") != *id || file["trashed"] != true {
                return Err(Error::InvalidPath(
                    "the selection changed; refresh Trash and select the items again",
                ));
            }
        }
        Ok(())
    }

    fn require_permanent_delete(&self, confirmed: bool) -> Result<()> {
        confirm(confirmed)?;
        if self.tokens().is_personal_access_token() {
            return Err(Error::Auth("PikPak Personal Access Tokens cannot permanently delete files. Use PikPak Sign-in in Settings > Accounts, then return to Trash.".into()));
        }
        Ok(())
    }
}

// Claim metadata is a display hint only, after /user/me has authenticated this
// credential. It never authorizes a mutation or substitutes for server checks.
pub fn credential_metadata(personal: bool, token: &str) -> CredentialMetadata {
    let mut result = CredentialMetadata {
        kind: if personal {
            "personal-access-token"
        } else {
            "desktop-oauth"
        }
        .into(),
        expires_at: None,
        permissions: None,
        can_permanently_delete: !personal,
    };
    if personal {
        if let Some(claims) = token
            .split('.')
            .nth(1)
            .filter(|s| s.len() < 32_768)
            .and_then(|s| URL_SAFE_NO_PAD.decode(s.trim_end_matches('=')).ok())
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        {
            result.expires_at = claims["exp"].as_u64();
            result.permissions = claims["scope"].as_str().map(|scope| {
                scope
                    .split_whitespace()
                    .filter(|s| {
                        s.len() <= 80
                            && s.chars()
                                .all(|c| c.is_ascii_alphanumeric() || ":_-".contains(c))
                    })
                    .take(64)
                    .map(str::to_owned)
                    .collect()
            });
        }
    }
    result
}

fn management_error(error: Error) -> Error {
    if matches!(&error, Error::Api { status: 403, .. }) {
        return Error::Auth("PikPak denied this action. Check this connection’s permissions in Settings > Accounts.".into());
    }
    error
}

fn confirm(confirmed: bool) -> Result<()> {
    if !confirmed {
        return Err(Error::InvalidPath("confirm this action before continuing"));
    }
    Ok(())
}
fn validate_id(id: &str) -> Result<()> {
    if id.is_empty()
        || id.len() > 256
        || !id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.:".contains(&c))
    {
        return Err(Error::InvalidPath("invalid item identifier"));
    }
    Ok(())
}
fn validate_ids(ids: &[String]) -> Result<()> {
    if ids.is_empty() || ids.len() > 100 || ids.iter().collect::<HashSet<_>>().len() != ids.len() {
        return Err(Error::InvalidPath(
            "select between 1 and 100 distinct items",
        ));
    }
    for id in ids {
        validate_id(id)?;
    }
    Ok(())
}
fn validate_expiration(days: i64) -> Result<()> {
    if ![-1, 1, 7, 30].contains(&days) {
        return Err(Error::InvalidPath("choose a supported share expiration"));
    }
    Ok(())
}
pub fn validate_cloud_url(raw: &str) -> Result<String> {
    let raw = raw.trim();
    if raw.len() > 16_384 || raw.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err(Error::InvalidPath(
            "enter one valid HTTP, HTTPS or magnet link",
        ));
    }
    let url =
        reqwest::Url::parse(raw).map_err(|_| Error::InvalidPath("enter a valid download link"))?;
    match url.scheme() {
        "http" | "https"
            if url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none() => {}
        "magnet"
            if url
                .query_pairs()
                .any(|(k, v)| k == "xt" && v.starts_with("urn:btih:")) => {}
        _ => {
            return Err(Error::InvalidPath(
                "use an HTTP, HTTPS or BitTorrent magnet link",
            ))
        }
    }
    Ok(raw.into())
}
fn page_query(
    token: String,
    mut query: Vec<(&'static str, String)>,
) -> Vec<(&'static str, String)> {
    query.push(("limit", "100".into()));
    if !token.is_empty() {
        query.push(("page_token", token));
    }
    query
}
fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().to_owned()
}
fn number(value: &Value, key: &str) -> u64 {
    value[key]
        .as_u64()
        .or_else(|| value[key].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or_default()
}
fn unrecognized(what: &str) -> Error {
    Error::Api {
        status: 200,
        message: format!("PikPak returned an unrecognized {what}."),
    }
}
fn page(
    value: &Value,
    wire_key: &str,
    key: &str,
    normalize: fn(&Value) -> Result<Value>,
) -> Result<Value> {
    let items = value[wire_key]
        .as_array()
        .ok_or_else(|| unrecognized("list response"))?;
    let normalized = items.iter().map(normalize).collect::<Result<Vec<_>>>()?;
    Ok(json!({key:normalized, "next_page_token":text(value, "next_page_token")}))
}
fn normalize_task(v: &Value) -> Result<Value> {
    let id = text(v, "id");
    if id.is_empty() {
        return Err(unrecognized("cloud task"));
    }
    Ok(
        json!({"id":id, "name":text(v,"name"), "file_name":text(v,"file_name"), "file_id":text(v,"file_id"),
        "phase":text(v,"phase"), "progress":number(v,"progress").min(100), "size":number(v,"file_size"),
        "message":text(v,"message"), "created_time":text(v,"created_time")}),
    )
}
fn normalize_share(v: &Value) -> Result<Value> {
    let id = text(v, "share_id");
    if id.is_empty() {
        return Err(unrecognized(
            "share response; refresh My Shares before submitting again",
        ));
    }
    Ok(
        json!({"id":id,"title":text(v,"title"),"url":text(v,"share_url"),"pass_code":text(v,"pass_code"),
        "status":text(v,"share_status"),"expires_at":text(v,"expiration_at"),"created_time":text(v,"create_time"),
        "views":number(v,"view_count"),"saves":number(v,"restore_count"),"size":number(v,"file_size")}),
    )
}
fn normalize_file(v: &Value) -> Result<Value> {
    let id = text(v, "id");
    if id.is_empty() || !["drive#file", "drive#folder"].contains(&text(v, "kind").as_str()) {
        return Err(unrecognized("file response"));
    }
    Ok(
        json!({"id":id,"name":text(v,"name"),"is_folder":v["kind"] == "drive#folder","size":number(v,"size"),
        "parent_id":text(v,"parent_id"),"modified_time":text(v,"modified_time"),"trashed_time":text(v,"trashed_time")}),
    )
}

#[cfg(test)]
mod tests;

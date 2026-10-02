//! Read-only, paginated account indexing for the native quick-open palette.
//! Pages are streamed immediately; neither a large folder nor a failed branch
//! prevents already-discovered names from becoming searchable.

use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::time::Duration;

use serde::Serialize;
use tokio::task::JoinSet;

use crate::{Client, Error, FileInfo, FileKind, FilePage};

#[derive(Clone, Debug, Serialize)]
pub struct SearchAncestor {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug)]
pub struct SearchPageRequest {
    pub parent_id: String,
    pub page_token: Option<String>,
    pub ancestors: Vec<SearchAncestor>,
}

/// Deliberately exclude signed URLs, hashes, and credentials from the index.
#[derive(Debug, Serialize)]
pub struct SearchItem {
    pub id: String,
    pub name: String,
    pub kind: FileKind,
    pub size: u64,
    pub mime_type: Option<String>,
    pub modified_time: Option<String>,
}

impl From<FileInfo> for SearchItem {
    fn from(file: FileInfo) -> Self {
        Self {
            id: file.id,
            name: file.name,
            kind: file.kind,
            size: file.size,
            mime_type: file.mime_type,
            modified_time: file.modified_time,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct SearchProgress {
    pub indexed_items: usize,
    pub scanned_folders: usize,
    pub discovered_folders: usize,
    pub failed_folders: usize,
}

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SearchEvent {
    Page {
        parent_id: String,
        ancestors: Vec<SearchAncestor>,
        items: Vec<SearchItem>,
        next_page_token: Option<String>,
        progress: SearchProgress,
    },
    Failure {
        code: String,
        message: String,
        ancestors: Vec<SearchAncestor>,
        progress: SearchProgress,
    },
    Finished {
        progress: SearchProgress,
    },
}

pub async fn index_account(
    client: Client,
    workers: usize,
    emit: impl FnMut(SearchEvent) -> std::io::Result<()>,
) -> std::io::Result<()> {
    scan(
        move |request| {
            let client = client.clone();
            async move {
                // HTTP-level backoff is already implemented by Client. Bound
                // a page's total lifetime as well, including those retries.
                tokio::time::timeout(
                    Duration::from_secs(90),
                    client.list_folder_page(&request.parent_id, request.page_token.as_deref(), 500),
                )
                .await
                .unwrap_or(Err(Error::IncompleteListing(
                    "search page timed out after 90 seconds",
                )))
            }
        },
        workers,
        emit,
    )
    .await
}

async fn scan<F, Fut>(
    fetch: F,
    workers: usize,
    mut emit: impl FnMut(SearchEvent) -> std::io::Result<()>,
) -> std::io::Result<()>
where
    F: Fn(SearchPageRequest) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = crate::Result<FilePage>> + Send + 'static,
{
    let mut pending = VecDeque::from([SearchPageRequest {
        parent_id: String::new(),
        page_token: None,
        ancestors: Vec::new(),
    }]);
    let mut running = JoinSet::new();
    let mut seen_items = HashSet::from([String::new()]);
    let mut seen_pages: HashMap<String, HashSet<String>> = HashMap::new();
    let mut progress = SearchProgress {
        discovered_folders: 1,
        ..Default::default()
    };

    while !pending.is_empty() || !running.is_empty() {
        while running.len() < workers.clamp(1, 8) {
            let Some(request) = pending.pop_front() else {
                break;
            };
            let fetch = fetch.clone();
            running.spawn(async move {
                let result = fetch(request.clone()).await;
                (request, result)
            });
        }
        let Some(outcome) = running.join_next().await else {
            break;
        };
        let (request, result) = match outcome {
            Ok(value) => value,
            Err(_) => {
                progress.failed_folders += 1;
                emit(SearchEvent::Failure {
                    code: "SEARCH_WORKER_FAILED".into(),
                    message: "An indexing worker stopped unexpectedly. Scan again to retry.".into(),
                    ancestors: Vec::new(),
                    progress: progress.clone(),
                })?;
                continue;
            }
        };
        let page = match result {
            Ok(page) => page,
            Err(error) => {
                let fatal = matches!(
                    error,
                    Error::Auth(_) | Error::SessionRejected(_) | Error::TokenExpired | Error::NotConfigured(_)
                ) || matches!(error, Error::Api { status: 401, .. });
                let (code, message) = search_error(error);
                progress.failed_folders += 1;
                emit(SearchEvent::Failure {
                    code,
                    message,
                    ancestors: request.ancestors,
                    progress: progress.clone(),
                })?;
                if fatal {
                    running.abort_all();
                    break;
                }
                continue;
            }
        };

        let next = page.next_page_token.filter(|token| !token.is_empty());
        let repeated = next.as_ref().is_some_and(|token| {
            !seen_pages
                .entry(request.parent_id.clone())
                .or_default()
                .insert(token.clone())
        });
        let mut items = Vec::new();
        for file in page.files {
            // Overlapping pages and malformed cycles must never create an
            // endless scan or duplicate search results.
            if !seen_items.insert(file.id.clone()) {
                continue;
            }
            if file.kind.is_folder() {
                let mut ancestors = request.ancestors.clone();
                ancestors.push(SearchAncestor {
                    id: file.id.clone(),
                    name: file.name.clone(),
                });
                pending.push_back(SearchPageRequest {
                    parent_id: file.id.clone(),
                    page_token: None,
                    ancestors,
                });
                progress.discovered_folders += 1;
            }
            items.push(file.into());
            progress.indexed_items += 1;
        }
        if next.is_none() {
            progress.scanned_folders += 1;
        }
        emit(SearchEvent::Page {
            parent_id: request.parent_id.clone(),
            ancestors: request.ancestors.clone(),
            items,
            next_page_token: next.clone(),
            progress: progress.clone(),
        })?;
        if repeated {
            progress.failed_folders += 1;
            emit(SearchEvent::Failure {
                code: "SEARCH_REPEATED_PAGE".into(),
                message: "PikPak repeated a page token. This folder's results may be incomplete; scan again to retry.".into(),
                ancestors: request.ancestors,
                progress: progress.clone(),
            })?;
        } else if next.is_some() {
            // Queue the next page, not the whole folder, so siblings get fair
            // access to the small fixed pool of API connections.
            pending.push_back(SearchPageRequest {
                page_token: next,
                ..request
            });
        }
    }
    emit(SearchEvent::Finished { progress })
}

fn search_error(error: Error) -> (String, String) {
    match error {
        // Auth failures can embed token responses; never expose those in a
        // searchable metadata stream or in selectable diagnostic text.
        Error::Auth(_) | Error::SessionRejected(_) | Error::TokenExpired | Error::NotConfigured(_) => (
            "SEARCH_SESSION_UNAVAILABLE".into(),
            "The app's PikPak session could not be refreshed. Sign in again and retry the scan."
                .into(),
        ),
        Error::Api { status, message } => {
            let message = if let Ok(value) = serde_json::from_str::<serde_json::Value>(&message) {
                value
                    .get("error_description")
                    .or_else(|| value.get("message"))
                    .or_else(|| value.get("error"))
                    .and_then(|value| value.as_str())
                    .unwrap_or("PikPak rejected this folder request.")
                    .to_owned()
            } else {
                message
            };
            (
                format!("HTTP_{status}"),
                message.chars().take(1000).collect(),
            )
        }
        Error::Http(error) => (
            "SEARCH_NETWORK_ERROR".into(),
            error.without_url().to_string(),
        ),
        error => ("SEARCH_FOLDER_FAILED".into(), error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn item(id: &str, name: &str, folder: bool) -> FileInfo {
        serde_json::from_value(serde_json::json!({
            "id": id, "name": name,
            "kind": if folder { "drive#folder" } else { "drive#file" },
        }))
        .unwrap()
    }

    #[tokio::test]
    async fn streams_every_page_nested_names_and_deduplicates_cycles() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let saved = calls.clone();
        let mut events = Vec::new();
        scan(
            move |request| {
                saved
                    .lock()
                    .unwrap()
                    .push((request.parent_id.clone(), request.page_token.clone()));
                async move {
                    let (files, next) =
                        match (request.parent_id.as_str(), request.page_token.as_deref()) {
                            ("", None) => (vec![item("a", "Folder A", true)], Some("next".into())),
                            ("", Some("next")) => (
                                vec![item("a", "Folder A", true), item("b", "報告.zip", false)],
                                None,
                            ),
                            ("a", None) => (
                                vec![item("a", "cycle", true), item("c", "Nested", true)],
                                None,
                            ),
                            ("c", None) => (vec![item("d", "résumé.txt", false)], None),
                            _ => panic!("unexpected request"),
                        };
                    Ok(FilePage {
                        files,
                        next_page_token: next,
                    })
                }
            },
            4,
            |event| {
                events.push(event);
                Ok(())
            },
        )
        .await
        .unwrap();
        assert_eq!(calls.lock().unwrap().len(), 4);
        let serialized: Vec<_> = events
            .iter()
            .map(|e| serde_json::to_value(e).unwrap())
            .collect();
        let nested = serialized.iter().find(|e| e["parent_id"] == "c").unwrap();
        assert_eq!(nested["ancestors"][0]["id"], "a");
        assert_eq!(nested["ancestors"][1]["id"], "c");
        assert_eq!(nested["items"][0]["name"], "résumé.txt");
        let last = serialized.last().unwrap();
        assert_eq!(last["event"], "finished");
        assert_eq!(last["progress"]["indexed_items"], 4);
        assert_eq!(last["progress"]["scanned_folders"], 3);
    }

    #[tokio::test]
    async fn failures_and_repeated_pages_do_not_stop_other_branches() {
        let mut events = Vec::new();
        scan(
            |request| async move {
                match request.parent_id.as_str() {
                    "" => Ok(FilePage {
                        files: vec![item("a", "A", true), item("b", "B", true)],
                        next_page_token: None,
                    }),
                    "a" => Err(Error::Api {
                        status: 403,
                        message: "access denied".into(),
                    }),
                    "b" => Ok(FilePage {
                        files: vec![item("c", "Found.txt", false)],
                        next_page_token: Some("repeat".into()),
                    }),
                    _ => panic!(),
                }
            },
            2,
            |event| {
                events.push(event);
                Ok(())
            },
        )
        .await
        .unwrap();
        assert!(events.iter().any(|event| matches!(event, SearchEvent::Page { items, .. } if items.iter().any(|item| item.name == "Found.txt"))));
        assert!(
            matches!(events.last(), Some(SearchEvent::Finished { progress }) if progress.failed_folders == 2 && progress.indexed_items == 3)
        );
    }

    #[tokio::test]
    async fn independent_folders_are_in_flight_together_and_emit_before_finish() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let active = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let count = active.clone();
        let maximum = peak.clone();
        let mut events = Vec::new();
        scan(
            move |request| {
                let count = count.clone();
                let maximum = maximum.clone();
                async move {
                    if request.parent_id.is_empty() {
                        return Ok(FilePage {
                            files: (0..8)
                                .map(|i| item(&format!("{i}"), "Folder", true))
                                .collect(),
                            next_page_token: None,
                        });
                    }
                    let n = count.fetch_add(1, Ordering::SeqCst) + 1;
                    maximum.fetch_max(n, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(5)).await;
                    count.fetch_sub(1, Ordering::SeqCst);
                    Ok(FilePage {
                        files: Vec::new(),
                        next_page_token: None,
                    })
                }
            },
            3,
            |event| {
                events.push(event);
                Ok(())
            },
        )
        .await
        .unwrap();
        assert_eq!(peak.load(Ordering::SeqCst), 3);
        assert!(
            matches!(&events[0], SearchEvent::Page { items, progress, .. } if items.len() == 8 && progress.scanned_folders == 1)
        );
    }

    #[test]
    fn index_does_not_serialize_signed_resources_or_auth_responses() {
        let (code, message) = search_error(Error::SessionRejected("synthetic private detail"));
        assert_eq!(code, "SEARCH_SESSION_UNAVAILABLE");
        assert!(!message.contains("private detail"));
        let mut file = item("test", "Document.txt", false);
        file.thumbnail_link = Some("https://cdn.invalid/?token=secret".into());
        let json = serde_json::to_string(&SearchItem::from(file)).unwrap();
        assert!(!json.contains("token"));
        assert!(!search_error(Error::Auth("secret".into()))
            .1
            .contains("secret"));
    }
}

//! Keep-smallest uses a guarded batch: verify every retained original before
//! changing anything, then acknowledge only successfully completed batches.
use anyhow::{bail, Context, Result};
use pikpak::Client;
use serde::Deserialize;
use std::collections::HashSet;

#[derive(Debug, Deserialize)]
pub struct Keeper {
    pub id: String,
    pub size: u64,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum Selection {
    IDs(Vec<String>),
    Guarded { ids: Vec<String>, keep: Vec<Keeper> },
}

pub struct Request {
    pub ids: Vec<String>,
    keep: Vec<Keeper>,
}
impl Request {
    pub fn new(mut ids: Vec<String>, selection: Option<Selection>) -> Result<Self> {
        let keep = match selection {
            Some(Selection::IDs(mut more)) => {
                ids.append(&mut more);
                vec![]
            }
            Some(Selection::Guarded {
                ids: mut more,
                keep,
            }) => {
                if keep.is_empty() {
                    bail!("A keep-smallest request needs at least one retained file");
                }
                ids.append(&mut more);
                keep
            }
            None => vec![],
        };
        let mut seen = HashSet::new();
        let ids: Vec<_> = ids
            .into_iter()
            .map(|id| id.trim().to_string())
            .filter(|id| !id.is_empty() && seen.insert(id.clone()))
            .collect();
        if ids.is_empty() {
            bail!("at least one non-empty file id is required");
        }
        if keep.iter().any(|file| {
            file.id.trim().is_empty() || file.id.trim() != file.id || seen.contains(&file.id)
        }) {
            bail!("A retained file cannot also be selected for Trash");
        }
        Ok(Self { ids, keep })
    }
}

trait Backend {
    async fn metadata(&self, id: &str) -> Result<serde_json::Value>;
    async fn trash(&self, ids: &[String]) -> Result<()>;
}
impl Backend for Client {
    async fn metadata(&self, id: &str) -> Result<serde_json::Value> {
        Ok(self.file_metadata(id).await?)
    }
    async fn trash(&self, ids: &[String]) -> Result<()> {
        Ok(self.trash_files(ids).await?)
    }
}

pub struct Outcome {
    pub confirmed: Vec<String>,
    pub error: Option<anyhow::Error>,
}

fn verify_keeper(keeper: &Keeper, value: &serde_json::Value) -> Result<()> {
    let size = value["size"]
        .as_u64()
        .or_else(|| value["size"].as_str()?.parse().ok());
    if value["id"].as_str() != Some(keeper.id.as_str())
        || value["kind"] != "drive#file"
        || value["trashed"].as_bool() != Some(false)
        || size != Some(keeper.size)
    {
        bail!("A file to keep is unavailable or has changed size. No files were moved to Trash. Scan this group again.");
    }
    Ok(())
}

async fn apply(backend: &impl Backend, request: Request) -> Result<Outcome> {
    for keeper in &request.keep {
        let value = backend
            .metadata(&keeper.id)
            .await
            .context("Could not verify a file to keep. No files were moved to Trash")?;
        verify_keeper(keeper, &value)?;
    }
    let mut confirmed = Vec::new();
    for batch in request.ids.chunks(100) {
        if let Err(error) = backend.trash(batch).await {
            return Ok(Outcome {
                confirmed,
                error: Some(error.context("move item batch to PikPak Trash failed")),
            });
        }
        confirmed.extend_from_slice(batch);
    }
    Ok(Outcome {
        confirmed,
        error: None,
    })
}
pub async fn execute(client: &Client, request: Request) -> Result<Outcome> {
    apply(client, request).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    struct Fake {
        reads: Mutex<Vec<String>>,
        batches: Mutex<Vec<Vec<String>>>,
        missing: bool,
        fail_batch: Option<usize>,
    }
    impl Backend for Fake {
        async fn metadata(&self, id: &str) -> Result<serde_json::Value> {
            assert!(
                self.batches.lock().unwrap().is_empty(),
                "All keepers must be verified before any Trash call"
            );
            self.reads.lock().unwrap().push(id.to_string());
            if self.missing && id == "keep2" {
                bail!("not found");
            }
            Ok(serde_json::json!({"id": id, "kind": "drive#file", "trashed": false, "size": "42"}))
        }
        async fn trash(&self, ids: &[String]) -> Result<()> {
            assert!(!ids.iter().any(|id| id.starts_with("keep")));
            let mut batches = self.batches.lock().unwrap();
            if self.fail_batch == Some(batches.len()) {
                bail!("offline");
            }
            batches.push(ids.to_vec());
            Ok(())
        }
    }
    fn fake(missing: bool, fail_batch: Option<usize>) -> Fake {
        Fake {
            reads: Mutex::new(vec![]),
            batches: Mutex::new(vec![]),
            missing,
            fail_batch,
        }
    }
    fn request(count: usize) -> Request {
        Request::new(
            vec![],
            Some(Selection::Guarded {
                ids: (0..count).map(|i| format!("remove{i}")).collect(),
                keep: vec![
                    Keeper {
                        id: "keep1".into(),
                        size: 42,
                    },
                    Keeper {
                        id: "keep2".into(),
                        size: 42,
                    },
                ],
            }),
        )
        .unwrap()
    }
    #[tokio::test]
    async fn missing_keeper_prevents_all_deletes() {
        let backend = fake(true, None);
        assert!(apply(&backend, request(3)).await.is_err());
        assert!(backend.batches.lock().unwrap().is_empty());
    }
    #[tokio::test]
    async fn batch_acknowledgements_preserve_partial_failure() {
        let backend = fake(false, Some(1));
        let result = apply(&backend, request(205)).await.unwrap();
        assert_eq!(result.confirmed.len(), 100);
        assert!(result.error.is_some());
        assert_eq!(backend.reads.lock().unwrap().len(), 2);
        let success = apply(&fake(false, None), request(205)).await.unwrap();
        assert_eq!(success.confirmed.len(), 205);
        assert!(success.error.is_none());
    }
    #[test]
    fn guarded_selection_rejects_keeper_as_target_and_checks_current_metadata() {
        let selection =
            serde_json::from_str(r#"{"ids":[" keep "],"keep":[{"id":"keep","size":0}]}"#).unwrap();
        assert!(Request::new(vec![], Some(selection)).is_err());
        let keeper = Keeper {
            id: "keep".into(),
            size: 0,
        };
        let good = serde_json::json!({"id":"keep","kind":"drive#file","size":0,"trashed":false});
        assert!(verify_keeper(&keeper, &good).is_ok());
        for (field, value) in [
            ("size", serde_json::json!(1)),
            ("trashed", serde_json::json!(true)),
            ("kind", serde_json::json!("drive#folder")),
            ("id", serde_json::json!("different")),
        ] {
            let mut bad = good.clone();
            bad[field] = value;
            assert!(verify_keeper(&keeper, &bad).is_err());
        }
    }
    #[test]
    fn legacy_ids_file_still_accepts_large_deduplicated_batches() {
        let selection = serde_json::from_str(r#"["a", " b ", "a", ""]"#).unwrap();
        let request = Request::new(vec!["b".into()], Some(selection)).unwrap();
        assert_eq!(request.ids, vec!["b", "a"]);
    }
}

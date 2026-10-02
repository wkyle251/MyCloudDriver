//! Remove only legacy padding uploads owned by this torrent's durable receipts.
//! All comparisons use metadata; no local or remote payload is opened or hashed.
use super::*;
use std::collections::{BTreeMap, HashMap};
use std::time::{SystemTime, UNIX_EPOCH};

fn matches(source: &Source, saved: &Receipt, file: &FileInfo) -> bool {
    file.kind.is_file() && file.parent_id.as_deref() == Some(saved.parent_id.as_str())
        && source.path.rsplit('/').next() == Some(file.name.as_str())
        && file.size == source.size && !saved.gcid.is_empty()
        && file.hash.as_deref().is_some_and(|hash| hash.eq_ignore_ascii_case(&saved.gcid))
}

fn acknowledge(request: &Request, source: &Source, saved: &mut Receipt) -> Result<()> {
    saved.padding_trashed = true;
    write_atomic(&receipt_path(request, source.index), saved)?;
    Ok(())
}

fn already_removed(error: &crate::Error) -> bool {
    match error {
        crate::Error::Api { status:404, .. } => true,
        crate::Error::Api { status:400, message } => {
            // PikPak's item endpoint reports Trash membership as this typed
            // error rather than returning file metadata with trashed=true.
            // Other 400 errors must keep the receipt pending.
            serde_json::from_str::<Value>(message).is_ok_and(|value|
                value["error"] == "file_in_recycle_bin" && value["error_code"] == 9)
        }
        _ => false,
    }
}

pub(super) async fn cleanup(client: &Client, request: &Request, emit: &Emit) -> Result<()> {
    let mut groups: BTreeMap<String, Vec<(&Source, Receipt)>> = BTreeMap::new();
    let mut checked = Vec::new();
    let mut removed = Vec::new();
    for source in &request.files {
        let saved = receipt(request, source)?;
        if saved.padding_trashed {
            checked.push(source.index); removed.push(source.index);
        } else if saved.remote_id.is_none() && saved.previous_ids.is_none() {
            checked.push(source.index);
        } else {
            if saved.parent_id.is_empty() || saved.gcid.is_empty() {
                bail!("A padding upload receipt is incomplete. Its cloud file was kept.");
            }
            groups.entry(saved.parent_id.clone()).or_default().push((source, saved));
        }
    }
    emit(json!({"event":"padding_cleaned", "checked":checked, "removed":removed}));
    let mut held = 0;
    let mut pending = 0;
    for (parent, entries) in groups {
        // Fully paginate before making changes. Names alone never authorize
        // deletion: an existing ID or an unambiguous lost-response receipt is required.
        let listing = client.list_upload_candidates(&parent).await?;
        let by_id: HashMap<_, _> = listing.iter().map(|file| (file.id.as_str(), file)).collect();
        let mut ready = Vec::new();
        let mut acknowledged = Vec::new();
        for (source, mut saved) in entries {
            if saved.remote_id.is_none() {
                let previous = saved.previous_ids.as_deref().unwrap_or_default();
                let candidates: Vec<_> = listing.iter().filter(|file| !previous.contains(&file.id) && matches(source, &saved, file)).collect();
                if candidates.len() != 1 { held += 1; continue; }
                saved.remote_id = Some(candidates[0].id.clone());
                write_atomic(&receipt_path(request, source.index), &saved)?;
            }
            let id = saved.remote_id.as_ref().unwrap();
            if let Some(file) = by_id.get(id.as_str()) {
                if matches(source, &saved, file) { ready.push((source, saved)); continue; }
                // Some listings omit the hash. Fetch only this item's metadata.
                if file.hash.as_deref().is_some_and(|hash| !hash.is_empty()) { held += 1; continue; }
            }
            match client.file_metadata(id).await {
                Ok(value) => {
                    let file: FileInfo = serde_json::from_value(value.clone())?;
                    if file.id != *id || !matches(source, &saved, &file) { held += 1; continue; }
                    match value["trashed"].as_bool() {
                        Some(true) => { acknowledge(request, source, &mut saved)?; acknowledged.push(source.index); }
                        Some(false) => ready.push((source, saved)),
                        None => { held += 1; }
                    }
                }
                Err(error) if already_removed(&error) => { acknowledge(request, source, &mut saved)?; acknowledged.push(source.index); }
                Err(error) => return Err(error.into()),
            }
        }
        emit(json!({"event":"padding_cleaned", "checked":acknowledged, "removed":acknowledged}));
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        for batch in ready.chunks_mut(100) {
            let mut ids = Vec::new();
            for (source, saved) in batch {
                // PikPak processes batch Trash asynchronously. Record the
                // intent before sending it, then give an accepted/lost reply
                // time to settle without continually adding duplicate tasks.
                if saved.padding_trash_requested_at.is_some_and(|at| at <= now && now - at < 300) { continue; }
                saved.padding_trash_requested_at = Some(now);
                write_atomic(&receipt_path(request, source.index), saved)?;
                ids.push(saved.remote_id.clone().unwrap());
            }
            if !ids.is_empty() { client.trash_files(&ids).await?; }
        }
        if !ready.is_empty() {
            // A successful HTTP response only accepts the operation. Keep
            // visible items pending across retries and app restarts until a
            // fresh, fully-paginated listing confirms their removal.
            let visible: std::collections::HashSet<_> = client.list_upload_candidates(&parent).await?.into_iter().map(|file| file.id).collect();
            let mut confirmed = Vec::new();
            for (source, mut saved) in ready {
                if visible.contains(saved.remote_id.as_ref().unwrap()) { pending += 1; }
                else { acknowledge(request, source, &mut saved)?; confirmed.push(source.index); }
            }
            emit(json!({"event":"padding_cleaned", "checked":confirmed, "removed":confirmed}));
        }
    }
    if held > 0 { bail!("{held} padding upload(s) could not be matched safely. They were kept; cleanup will check again automatically."); }
    if pending > 0 { bail!("Waiting for PikPak to finish moving {pending} padding file(s) to Trash. Cleanup will check again automatically."); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_confirmed_trash_or_missing_responses_count_as_removed() {
        for (status, message, expected) in [
            (404, "file not found", true),
            (400, r#"{"error":"file_in_recycle_bin","error_code":9}"#, true),
            (400, r#"{"error":"invalid_argument","error_code":9}"#, false),
            (400, r#"{"error":"file_in_recycle_bin","error_code":99}"#, false),
            (400, "unrecognized reply", false),
            (403, r#"{"error":"file_in_recycle_bin","error_code":9}"#, false),
        ] {
            assert_eq!(already_removed(&crate::Error::Api { status, message:message.into() }), expected);
        }
    }
}

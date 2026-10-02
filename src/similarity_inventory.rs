//! Reconcile a running scan with fresh metadata. A complete listing, rather
//! than a failed request or missing page, establishes which files were removed.
use super::*;

pub(super) struct Snapshot {
    pub files: Vec<scope::InputFile>,
    pub report: ScanReport,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Changes {
    pub added: usize,
    pub removed: usize,
    pub changed: usize,
}
impl Changes {
    pub fn any(&self) -> bool {
        self.added + self.removed + self.changed > 0
    }
    pub fn announce(&self, total: usize) -> Result<()> {
        emit(&json!({"event":"inventory_changed", "added":self.added,
            "removed":self.removed,"changed":self.changed,"total":total}))
    }
}

pub(super) fn changes(previous: &[scope::InputFile], current: &[scope::InputFile]) -> Changes {
    let mut previous: HashMap<_, _> = previous
        .iter()
        .map(|file| (file.display.id.as_str(), file.inventory_version.as_ref()))
        .collect();
    let mut result = Changes::default();
    for file in current {
        match previous.remove(file.display.id.as_str()) {
            None => result.added += 1,
            Some(version) if version.is_none() || version != file.inventory_version.as_ref() => {
                result.changed += 1
            }
            _ => {}
        }
    }
    result.removed = previous.len();
    result
}

/// A vanished mount can expose an empty directory on its parent filesystem.
/// This also protects local paths selected outside the native drive browser.
pub(super) fn validate_removals(
    previous: &[scope::InputFile],
    current: &[scope::InputFile],
) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let present: HashSet<_> = current.iter().map(|file| &file.display.id).collect();
    let mut devices = HashMap::new();
    for file in previous
        .iter()
        .filter(|file| !present.contains(&file.display.id))
    {
        let Some(expected) = file.local_device() else {
            continue;
        };
        let parent = file.path.parent().context("Missing original directory")?;
        let actual = if let Some(device) = devices.get(parent) {
            *device
        } else {
            let mut ancestor = parent;
            let device = loop {
                match std::fs::symlink_metadata(ancestor) {
                    Ok(metadata) => break metadata.dev(),
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                        ) =>
                    {
                        ancestor = ancestor
                            .parent()
                            .context("The original disk is unavailable")?;
                    }
                    Err(error) => return Err(error.into()),
                }
            };
            devices.insert(parent.to_owned(), device);
            device
        };
        if actual != expected {
            bail!("The original disk is unavailable. Reconnect it, then resume; missing files have not been treated as deletions.");
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn capture(
    request: &ScanRequest,
    temporary: &Path,
    cancel: &Arc<AtomicBool>,
    client: Option<&Client>,
    runtime: &tokio::runtime::Handle,
    token: &filetwin_core::api::CancellationToken,
    report: ScanReport,
) -> Result<Snapshot> {
    control::wait_blocking(token, cancel)?;
    emit(&json!({"event":"inventory_check"}))?;
    let mut request = request.clone();
    // Keep the empty, privately created response file alive until its reader
    // finishes. The host validates the owned request directory before writing.
    let stream = if request.refresh_inventory {
        request
            .external_source_stream
            .as_ref()
            .map(|path| {
                tempfile::Builder::new()
                    .prefix("inventory-")
                    .suffix(".jsonl")
                    .tempfile_in(
                        path.parent()
                            .context("Missing provider inventory directory")?,
                    )
                    .map_err(anyhow::Error::from)
            })
            .transpose()?
    } else {
        None
    };
    if let Some(stream) = &stream {
        request.external_source_stream = Some(stream.path().to_owned());
        emit(&json!({"event":"refresh_inventory","inventory_file":stream.path()}))?;
    }
    let discovery = discovery::start_controlled(
        request,
        client.cloned(),
        temporary.to_owned(),
        runtime.clone(),
        cancel.clone(),
        report,
        token.clone(),
    )?;
    let mut files = Vec::new();
    loop {
        control::wait_blocking(token, cancel)?;
        check_cancel(cancel)?;
        match discovery.poll()? {
            Some(discovery::Event::File(file)) => files.push(file),
            Some(discovery::Event::Finished(report)) => {
                if report.failed_files > 0 {
                    bail!("Could not verify the current scan scope. Check drive access, then resume; completed analysis is saved.");
                }
                return Ok(Snapshot { files, report });
            }
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    }
}

#[cfg(test)]
#[path = "similarity_inventory_tests.rs"]
mod tests;

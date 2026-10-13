//! Optional cloud cleanup runs only after the download's durable publication succeeded.
use crate::*;

#[cfg(test)]
#[path = "download_cleanup_tests.rs"]
mod tests;

/// Cleanup failure must never turn a verified download into a failed transfer.
pub async fn after_complete(
    client: &Client,
    file: &FileInfo,
    output: &StdPath,
    transfer_id: &str,
    progress_json: bool,
    enabled: &AtomicBool,
) -> Result<()> {
    if !enabled.load(Ordering::SeqCst) {
        return Ok(());
    }
    match trash_verified(client, file, output, transfer_id, enabled).await {
        Ok(true) => emit_download_progress(
            progress_json,
            DownloadProgressEvent::FileSourceTrashed {
                file_id: transfer_id,
                name: &file.name,
                source_file_id: &file.id,
            },
        ),
        Ok(false) => {}
        Err(error) if error.is::<download_verification::Deferred>() => return Err(error),
        Err(error)
            if error.is::<transfer_control::Cancelled>()
                || error.is::<transfer_control::Paused>() => {}
        Err(error) => {
            let message =
                format!("Download complete; could not confirm removal from PikPak: {error:#}");
            eprintln!("{}: {message}", file.name);
            emit_download_progress(
                progress_json,
                DownloadProgressEvent::FileSourceCleanupFailed {
                    file_id: transfer_id,
                    name: &file.name,
                    error: &message,
                },
            );
        }
    }
    Ok(())
}

async fn trash_verified(
    client: &Client,
    file: &FileInfo,
    output: &StdPath,
    transfer_id: &str,
    enabled: &AtomicBool,
) -> Result<bool> {
    anyhow::ensure!(file.kind.is_file(), "Only downloaded files can be removed");
    // Refresh the same opaque account ID, never resolve by name or use a public
    // share's original ID. A changed cloud revision must retain its cloud copy.
    let metadata =
        transfer_control::interruptible(transfer_id, client.file_metadata(&file.id)).await??;
    let current: FileInfo = serde_json::from_value(metadata.clone())?;
    anyhow::ensure!(
        current.id == file.id && current.kind.is_file(),
        "The cloud source changed"
    );
    let account = transfer_control::interruptible(transfer_id, client.tokens().user_id()).await??;
    let download = pikpak::DownloadInfo {
        web_content_link: String::new(),
        name: current.name,
        size: current.size,
        source_revision: pikpak::client::download_revision(
            current.hash.as_deref(),
            current.modified_time.as_deref(),
        ),
    };
    let source = download_receipt::Source::from_download(
        format!("account:{account}"),
        &file.id,
        &download,
        current.size,
    );
    anyhow::ensure!(
        download_receipt::completed_without_reading(output, &source, transfer_id)
            .await?
            .is_some(),
        "The local copy no longer matches the completed cloud original"
    );
    // The user can turn cleanup off, pause or cancel while metadata is loading.
    if !enabled.load(Ordering::SeqCst) || transfer_control::action(transfer_id).is_some() {
        return Ok(false);
    }
    if metadata.get("trashed").and_then(serde_json::Value::as_bool) != Some(true) {
        client.trash_files(std::slice::from_ref(&file.id)).await?;
    }
    Ok(true)
}

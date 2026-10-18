//! Independent folders share a bounded request pool. One folder's page tokens
//! stay sequential, and only this coordinator mutates scan identity/coverage.
use super::*;
use filetwin_core::api::CancellationToken;
use futures_util::stream::FuturesUnordered;

const MAX_REQUESTS: usize = 8;

#[derive(Clone)]
struct Job {
    item: CloudItem,
    validate_root: bool,
    token: Option<String>,
    tokens: HashSet<String>,
}

enum Response {
    Revision((u64, Option<String>)),
    Page(crate::types::FilePage),
}

#[derive(Default)]
struct Progress {
    folders: u64,
    completed: u64,
    pages: u64,
    last: Option<Instant>,
}
impl Progress {
    fn emit(&mut self, found: u64, active: usize, complete: bool) -> Result<()> {
        let now = Instant::now();
        if complete
            || self
                .last
                .is_none_or(|last| now.duration_since(last) >= Duration::from_millis(250))
        {
            emit(
                &json!({"event":"discovery_listing", "folders_discovered":self.folders,
                "folders_completed":self.completed, "folders_pending":self.folders.saturating_sub(self.completed),
                "pages_completed":self.pages, "found":found, "active_requests":active, "complete":complete}),
            )?;
            self.last = Some(now);
        }
        Ok(())
    }
}

async fn wait(control: &CancellationToken, cancel: &AtomicBool) -> Result<()> {
    loop {
        check_cancel(cancel)?;
        if control.is_cancelled() {
            bail!("Scan cancelled.");
        }
        if !control.is_paused() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn cancel_read<T>(
    control: &CancellationToken,
    cancel: &AtomicBool,
    future: impl Future<Output = Result<T>>,
) -> Result<T> {
    tokio::pin!(future);
    loop {
        check_cancel(cancel)?;
        if control.is_cancelled() {
            bail!("Scan cancelled.");
        }
        tokio::select! {
            result = &mut future => return result,
            _ = tokio::time::sleep(Duration::from_millis(20)) => {}
        }
    }
}

async fn read<T, F, Fut>(
    network: &crate::download_network::Network,
    control: &CancellationToken,
    cancel: &AtomicBool,
    retry_forever: bool,
    mut read: F,
) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T>>,
{
    let mut attempt = 0u32;
    loop {
        wait(control, cancel).await?;
        let permit = cancel_read(control, cancel, async {
            network.acquire().await.map_err(Into::into)
        })
        .await?;
        // A pause can arrive while a shared endpoint slot is unavailable.
        // Release the acquired slot before waiting; do not start a new request.
        if control.is_paused() {
            drop(permit);
            continue;
        }
        let result = cancel_read(control, cancel, read()).await;
        drop(permit);
        let transient = match result
            .as_ref()
            .err()
            .and_then(|e| e.downcast_ref::<crate::Error>())
        {
            Some(crate::Error::Http(_)) => true,
            Some(crate::Error::Api { status, .. } | crate::Error::RetryAfter { status, .. }) => {
                crate::download_policy::transient_status(*status)
            }
            _ => false,
        };
        if !transient {
            if result.is_ok() {
                let _ = emit(&json!({"event":"network_wait", "waiting":false}));
            }
            return result;
        }
        let delay = Duration::from_millis((300u64 * (1 << attempt.min(7))).min(30_000)).max(
            result
                .as_ref()
                .err()
                .and_then(crate::download_policy::delay)
                .unwrap_or_default(),
        );
        // Publish provider rejection immediately, including when this was the
        // final bounded attempt. Other helpers share the serving-origin gate.
        if matches!(
            result
                .as_ref()
                .err()
                .and_then(|e| e.downcast_ref::<crate::Error>()),
            Some(
                crate::Error::Api {
                    status: 429 | 500..=599,
                    ..
                } | crate::Error::RetryAfter {
                    status: 429 | 500..=599,
                    ..
                }
            )
        ) {
            network.defer_metadata(delay)?;
        }
        if !retry_forever && attempt == 2 {
            return result;
        }
        let _ =
            emit(&json!({"event":"network_wait", "waiting":true, "retry_seconds":delay.as_secs()}));
        cancel_read(control, cancel, async {
            tokio::time::sleep(delay).await;
            Ok(())
        })
        .await?;
        attempt = attempt.saturating_add(1);
    }
}

async fn run_job<'a>(
    job: Job,
    client: &'a Client,
    network: &'a crate::download_network::Network,
    control: &'a CancellationToken,
    cancel: &'a AtomicBool,
    retry_forever: bool,
) -> (Job, Result<Response>) {
    let result = if job.validate_root {
        read(network, control, cancel, retry_forever, || async {
            client
                .similarity_scan_file_revision(
                    &job.item.id,
                    job.item
                        .ancestors
                        .last()
                        .map(|parent| parent.id.as_str())
                        .unwrap_or(""),
                )
                .await
                .map(Response::Revision)
                .map_err(Into::into)
        })
        .await
    } else {
        read(network, control, cancel, retry_forever, || async {
            client
                .list_similarity_folder_page(&job.item.id, job.token.as_deref(), 500)
                .await
                .map(Response::Page)
                .map_err(Into::into)
        })
        .await
    };
    (job, result)
}

/// Drain a bounded metadata batch before publishing files. A host's callback
/// may block on discovery backpressure or pause; it must never retain another
/// page request's shared socket allowance while doing so.
async fn batch(
    jobs: Vec<Job>,
    client: &Client,
    network: &crate::download_network::Network,
    control: &CancellationToken,
    cancel: &AtomicBool,
    retry_forever: bool,
) -> Result<Vec<(Job, Result<Response>)>> {
    let mut pending: VecDeque<_> = jobs.into();
    let mut running = FuturesUnordered::new();
    let mut in_flight = HashMap::new();
    let mut completed = Vec::new();
    loop {
        if control.is_paused() {
            // Dropping HTTP futures releases their permits immediately. Keep
            // each unprocessed page's token chain for a fresh request on Resume.
            running.clear();
            pending.extend(in_flight.drain().map(|(_, job)| job));
        }
        wait(control, cancel).await?;
        while let Some(job) = pending.pop_front() {
            in_flight.insert(job.item.id.clone(), job.clone());
            running.push(run_job(
                job,
                client,
                network,
                control,
                cancel,
                retry_forever,
            ));
        }
        if running.is_empty() {
            return Ok(completed);
        }
        let next = loop {
            check_cancel(cancel)?;
            if control.is_cancelled() {
                bail!("Scan cancelled.");
            }
            if control.is_paused() {
                break None;
            }
            tokio::select! {
                value = running.next() => break Some(value.context("Cloud discovery stopped unexpectedly")?),
                _ = tokio::time::sleep(Duration::from_millis(20)) => {},
            }
        };
        if let Some((job, result)) = next {
            in_flight.remove(&job.item.id);
            completed.push((job, result));
        }
    }
}

pub(super) async fn discover(
    request: &ScanRequest,
    client: &Client,
    cancel: &AtomicBool,
    control: &CancellationToken,
    staged: &mut StagedCloud,
    next: &mut dyn FnMut(CloudItem) -> Result<()>,
) -> Result<()> {
    let network = crate::download_network::Network::for_url(&client.api_base);
    let mut progress = Progress::default();
    let mut pending = VecDeque::new();
    let mut seen = HashSet::new();
    // Reserve all directly selected IDs first. An overlapping ancestor must
    // never replace a selected file's fresh revision or selected scope route.
    for item in &request.cloud_items {
        if !seen.insert(item.id.clone()) || item.name.starts_with('.') {
            continue;
        }
        progress.folders += u64::from(item.is_folder);
        pending.push_back(Job {
            item: item.clone(),
            validate_root: !item.id.is_empty(),
            token: None,
            tokens: HashSet::new(),
        });
    }
    progress.emit(staged.discovered, 0, false)?;
    loop {
        wait(control, cancel).await?;
        let mut jobs = Vec::new();
        while jobs.len() < MAX_REQUESTS {
            let Some(job) = pending.pop_front() else {
                break;
            };
            // The account root has no ID to validate; other direct roots and
            // files use a fresh detail lookup before they enter the inventory.
            if !job.validate_root && !job.item.is_folder {
                staged.discovered += 1;
                next(job.item)?;
            } else {
                jobs.push(job);
            }
        }
        if jobs.is_empty() {
            if pending.is_empty() {
                break;
            }
            continue;
        }
        progress.emit(staged.discovered, jobs.len(), false)?;
        let completed = batch(
            jobs,
            client,
            &network,
            control,
            cancel,
            request.checkpoint_id.is_some(),
        )
        .await?;
        for (mut job, result) in completed {
            wait(control, cancel).await?;
            match result {
                Ok(Response::Revision((size, revision))) => {
                    job.validate_root = false;
                    job.item.size = size;
                    job.item.revision = revision;
                    pending.push_front(job);
                }
                Ok(Response::Page(page)) => {
                    progress.pages += 1;
                    for file in page.files {
                        wait(control, cancel).await?;
                        if file.name.starts_with('.') || !seen.insert(file.id.clone()) {
                            continue;
                        }
                        let mut ancestors = job.item.ancestors.clone();
                        if !job.item.id.is_empty() {
                            ancestors.push(CloudAncestor {
                                id: job.item.id.clone(),
                                name: job.item.name.clone(),
                            });
                        }
                        let child = CloudItem {
                            revision: file.hash.clone().filter(|s| !s.trim().is_empty()).or_else(
                                || file.modified_time.clone().filter(|s| !s.trim().is_empty()),
                            ),
                            id: file.id,
                            name: file.name.clone(),
                            path: format!("{}/{}", job.item.path.trim_end_matches('/'), file.name),
                            is_folder: file.kind.is_folder(),
                            size: file.size,
                            ancestors,
                        };
                        if child.is_folder {
                            progress.folders += 1;
                            pending.push_back(Job {
                                item: child,
                                validate_root: false,
                                token: None,
                                tokens: HashSet::new(),
                            });
                        } else {
                            staged.discovered += 1;
                            next(child)?;
                        }
                    }
                    job.token = page.next_page_token;
                    match &job.token {
                        None => progress.completed += 1,
                        Some(token) if !job.tokens.insert(token.clone()) => {
                            staged.skip(
                                &job.item.path,
                                "PikPak repeated a page token. This folder is incomplete.",
                            );
                            progress.completed += 1;
                        }
                        _ => pending.push_back(job),
                    }
                }
                Err(error) if cloud_item_missing(&error) => {
                    progress.completed += u64::from(job.item.is_folder)
                }
                Err(error) => {
                    check_cancel(cancel)?;
                    if job.validate_root || request.checkpoint_id.is_some() {
                        return Err(error.context(
                            "The drive could not finish finding files. Reconnect it, then resume.",
                        ));
                    }
                    staged.skip(&job.item.path, &cloud_listing_error(&error));
                    progress.completed += u64::from(job.item.is_folder);
                }
            }
            progress.emit(staged.discovered, 0, false)?;
        }
    }
    progress.emit(staged.discovered, 0, true)
}

#[cfg(test)]
#[path = "similarity_cloud_listing_tests.rs"]
mod tests;

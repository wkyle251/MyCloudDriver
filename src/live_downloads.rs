//! One download pool for the lifetime of the native queue. The private inbox
//! may grow while bodies are running; folder pages feed it incrementally.
use crate::*;
use std::collections::VecDeque;
use std::time::Instant;
use tokio::sync::mpsc;

#[cfg(test)]
#[path = "live_download_tests.rs"]
mod tests;

#[derive(Debug, Parser)]
pub struct Args {
    #[arg(long)]
    request_file: PathBuf,
}

#[derive(Deserialize)]
struct Inbox {
    version: u32,
    requests: Vec<Request>,
    #[serde(default)]
    guest_mode: Option<bool>,
    #[serde(default)]
    content_mode: Option<pikpak::ContentMode>,
    #[serde(default)]
    retry_origins: HashMap<String, String>,
    #[serde(default)]
    delete_after_download: bool,
}

#[derive(Clone, Deserialize)]
struct Request {
    id: String,
    path: String,
    file: Option<FileInfo>,
    destination: PathBuf,
    #[serde(default)]
    destination_kind: Option<String>,
    #[serde(default)]
    relative_parent: Vec<String>,
    #[serde(default)]
    proxy_url: String,
    access: Option<ShareAccessInput>,
}

fn prepare_destination(request: &mut Request) -> Result<()> {
    let policy = request.destination_kind.as_deref().map(|kind| {
        crate::download_checkpoint::CheckpointPolicy::for_destination(Some(kind))
    });
    request.destination =
        download_fs::selected_directory_with_checkpoint_policy(&request.destination, policy)?;
    Ok(())
}

#[derive(Clone)]
enum Source {
    Account(Client),
    Shared(ShareClient),
}

struct Root {
    request: Request,
    source: Source,
    steps: usize,
    bodies: usize,
    discovered: bool,
    discovery_failed: bool,
    error: Option<String>,
    destination_unavailable: bool,
    seen: HashSet<String>,
}

struct RootScope {
    key: String,
    root: String,
}
impl RootScope {
    fn new(request: &Request) -> Result<Self> {
        let root = &request.id;
        let key = format!("root:{root}");
        let name = request
            .file
            .as_ref()
            .map(|file| file.name.as_str())
            .unwrap_or_else(|| {
                request
                    .path
                    .trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .unwrap_or("")
            });
        let target = download_root_destination(
            &request.destination,
            &request.path,
            0,
            Some(&request.relative_parent),
        )
        .and_then(|output| {
            Ok(if name.is_empty() {
                output
            } else {
                output.join(safe_component(name)?)
            })
        });
        // Invalid cloud names keep their per-request failure handling below.
        if let Ok(target) = target {
            transfer_control::set_output_reference(
                root,
                &target,
                request
                    .file
                    .as_ref()
                    .is_none_or(|file| file.kind.is_folder()),
            )?;
        }
        transfer_control::set_scope(&key, vec![key.clone()]);
        Ok(Self {
            key,
            root: root.clone(),
        })
    }
}
impl Drop for RootScope {
    fn drop(&mut self) {
        transfer_control::remove_scope(&self.key);
        transfer_control::remove_output_reference(&self.root);
        transfer_control::clear_retired_scopes(&self.root);
    }
}

#[derive(Clone)]
struct Body {
    root: String,
    id: String,
    source: Source,
    task: DownloadTask,
}

#[derive(Clone)]
struct Step {
    root: String,
    source: Source,
    path: String,
    output: PathBuf,
    folder: Option<String>,
    token: Option<String>,
    attempt: u32,
    ready: Instant,
}

impl Step {
    fn control_id(&self) -> String {
        format!("path:{}:{}", self.root, self.path)
    }
}

fn emit(value: serde_json::Value) {
    let mut output = std::io::stdout().lock();
    let _ = writeln!(output, "{DOWNLOAD_PROGRESS_PREFIX}{value}");
    let _ = output.flush();
}

fn scope(root: &str, path: &str) -> Vec<String> {
    vec![format!("root:{root}"), format!("path:{root}:{path}")]
}

fn fail(root: &mut Root, error: &anyhow::Error) {
    root.error.get_or_insert_with(|| format!("{error:#}"));
    if pikpak::download_policy::destination_unavailable(error) {
        root.destination_unavailable = true;
        emit(
            serde_json::json!({"event":"request_retrying", "request_id":root.request.id,
            "attempt":0, "retry_in_millis":1000, "destination_unavailable":true,
            "error":format!("{error:#}")}),
        );
    }
}

fn fail_discovery(root: &mut Root, error: &anyhow::Error) {
    root.discovery_failed = true;
    fail(root, error);
}

/// Bounds folder discovery ahead of the body pool. Each selection can still
/// discover its first page when a different selection is paused or backlogged.
const DISCOVERY_AHEAD: usize = 2048;
const DISCOVERY_CONNECTIONS: usize = 4;

fn accept_file(
    root: &mut Root,
    file: FileInfo,
    path: String,
    output: PathBuf,
    pending: &mut VecDeque<Step>,
    bodies: &mpsc::UnboundedSender<Body>,
) -> Result<()> {
    safe_component(&file.name)?;
    let key = if file.kind.is_folder() {
        format!("folder:{}", file.id)
    } else {
        format!("{}|{}", file.id, output.display())
    };
    if !root.seen.insert(key.clone()) {
        return Ok(());
    }
    if file.kind.is_folder() {
        let output = output.join(safe_component(&file.name)?);
        // Preserve empty folders too. File writes perform their own check.
        download_fs::create_dir_all(&output)?;
        root.steps += 1;
        let step = Step {
            root: root.request.id.clone(),
            source: root.source.clone(),
            path,
            output,
            folder: Some(file.id),
            token: None,
            attempt: 0,
            ready: Instant::now(),
        };
        transfer_control::set_scope(
            &step.control_id(),
            vec![format!("root:{}", root.request.id)],
        );
        pending.push_back(step);
    } else {
        let digest =
            hex::encode(ring::digest::digest(&ring::digest::SHA256, key.as_bytes()).as_ref());
        let id = format!("{}:{digest}", root.request.id);
        transfer_control::set_scope(&id, scope(&root.request.id, &path));
        emit(serde_json::json!({"event":"queue_append", "files":[{
            "file_id":id, "request_id":root.request.id, "source_file_id":file.id,
            "name":file.name, "total_bytes":file.size, "remote_path":path,
            "output_directory":output
        }]}));
        root.bodies += 1;
        bodies
            .send(Body {
                root: root.request.id.clone(),
                id,
                source: root.source.clone(),
                task: DownloadTask {
                    file,
                    output_directory: output,
                    remote_path: path,
                    retry_state: Arc::default(),
                },
            })
            .map_err(|_| anyhow::anyhow!("Download scheduler stopped"))?;
    }
    Ok(())
}

async fn discover(step: &Step) -> Result<(Vec<FileInfo>, Option<String>)> {
    let id = step.control_id();
    let result = transfer_control::interruptible(&id, async {
        match (&step.source, &step.folder) {
            (Source::Account(client), None) => {
                Ok((vec![client.resolve_path_info(&step.path).await?], None))
            }
            (Source::Account(client), Some(folder)) => {
                let page = client
                    .list_folder_page(folder, step.token.as_deref(), 200)
                    .await?;
                Ok((page.files, page.next_page_token))
            }
            (Source::Shared(client), Some(folder)) => {
                let page = client
                    .list_folder_page(folder, step.token.as_deref(), 200)
                    .await?;
                Ok((page.files, page.next_page_token))
            }
            (Source::Shared(_), None) => bail!("Shared download metadata is missing"),
        }
    })
    .await?;
    result
}

pub async fn run(account: &Client, args: Args) -> Result<()> {
    let (body_sender, body_receiver) = mpsc::unbounded_channel::<Body>();
    let (done_sender, mut done_receiver) = mpsc::unbounded_channel();
    let received = Arc::new(AtomicU64::new(0));
    let counter = received.clone();
    let delete_after_download = Arc::new(AtomicBool::new(false));
    let cleanup_enabled = delete_after_download.clone();
    let mut pool = tokio::spawn(async move {
        transfer_control::schedule_stream(body_receiver, transfer_control::Concurrency::download(usize::MAX, received),
            move |body: Body| {
                let received = counter.clone();
                let cleanup_enabled = cleanup_enabled.clone();
                async move {
                    let task = &body.task;
                    let mut preparation = task.retry_state.preparation.attempt();
                    let result = async {
                        emit_download_progress(true, DownloadProgressEvent::FileDequeued {
                            file_id: &body.id, name: &task.file.name, total_bytes: task.file.size,
                        });
                        download_fs::create_dir_all(&task.output_directory)
                            .map_err(|error| download_destination_error(error.into(), true, &body.id, &task.file.name))?;
                        match &body.source {
                            Source::Account(client) => {
                                // Old persisted queue entries have only ID/name/size.
                                // Resolve their folder without using the quota-gated
                                // file endpoint, and never substitute a same-named ID.
                                // An already delivered file must not depend on
                                // its old cloud path still resolving to this ID.
                                let completed_history = if client.content_mode().tries_guest() && task.file.parent_id.is_none()
                                    && task.file.hash.as_deref().is_none_or(|value| value.trim().is_empty()) {
                                    let account = transfer_control::metadata_interruptible(&body.id, client.tokens().user_id()).await??;
                                    let output = task.output_directory.join(safe_component(&task.file.name)?);
                                    download_receipt::completed_source_from_history(&output, &format!("account:{account}"),
                                        &task.file.id, task.file.size).await?.is_some()
                                } else { false };
                                let resolved;
                                let file = if client.content_mode().tries_guest() && task.file.parent_id.is_none() && !completed_history {
                                    let key = crate::download_preparation::Key::new(format!("path:{}", task.remote_path), &task.file.id, Some(client.content_mode()));
                                    let result = if let Some(file) = task.retry_state.preparation.resolved(&key) {
                                        Ok(file)
                                    } else {
                                        let result = transfer_control::metadata_interruptible(&body.id, client.resolve_path_info(&task.remote_path)).await?;
                                        if let Ok(file) = &result {
                                            if file.id == task.file.id { task.retry_state.preparation.remember_resolved(&key, file); }
                                        }
                                        result
                                    };
                                    match result {
                                        Ok(file) => {
                                            resolved = file;
                                            if resolved.id != task.file.id { return Err(pikpak::download_policy::SourceReplaced.into()); }
                                            &resolved
                                        },
                                        Err(_) if client.content_mode() == pikpak::ContentMode::Dynamic => &task.file,
                                        Err(error) => return Err(error.into()),
                                    }
                                } else { &task.file };
                                download_file_as_with_retry(client, file, &task.output_directory, false, true, received, &body.id, Some(&cleanup_enabled), task.retry_state.clone()).await
                            },
                            Source::Shared(client) => download_share_file_as_with_retry(client, &task.file, &task.output_directory, false, true, received, &body.id, task.retry_state.clone()).await,
                        }
                    }.await;
                    if result.as_ref().is_err_and(|error| error.is::<crate::download_verification::Deferred>()) {
                        preparation.defer();
                    }
                    result
                }
            }, |body| body.id.clone(),
            move |body, result| {
                if let Err(error) = &result {
                    emit_download_progress(true, DownloadProgressEvent::FileFailed {
                        file_id: &body.id, name: &body.task.file.name, downloaded_bytes: 0,
                        transferred_bytes: 0, total_bytes: body.task.file.size, error: &format!("{error:#}"),
                        permanent: pikpak::download_policy::permanent_failure(error),
                    });
                }
                transfer_control::retire_scope(&body.id);
                transfer_control::forget_network_counter(&body.id);
                let _ = done_sender.send((body.root, result));
            }, |body, attempt, delay| emit_download_progress(true, DownloadProgressEvent::FileRetrying {
                file_id: &body.id, name: &body.task.file.name, attempt, retry_in_millis: delay.as_millis() as u64,
                destination_unavailable: None, error: None,
            })).await
    });
    // Abort on every early error as well as app termination; no orphan pool.
    let result = coordinate(
        account,
        &args.request_file,
        &body_sender,
        &mut done_receiver,
        &mut pool,
        &delete_after_download,
    )
    .await;
    drop(body_sender);
    if result.is_err() {
        pool.abort();
    } else {
        pool.await??;
    }
    result
}

async fn coordinate(
    account: &Client,
    inbox_path: &StdPath,
    bodies: &mpsc::UnboundedSender<Body>,
    completed: &mut mpsc::UnboundedReceiver<(String, Result<()>)>,
    pool: &mut tokio::task::JoinHandle<Result<()>>,
    delete_after_download: &AtomicBool,
) -> Result<()> {
    let mut roots = HashMap::<String, Root>::new();
    let mut root_scopes = HashMap::<String, RootScope>::new();
    let mut consumed = HashSet::new();
    let mut pending = VecDeque::<Step>::new();
    let mut discovering = tokio::task::JoinSet::new();
    let mut proxies = HashMap::new();
    proxies.insert(
        std::env::var("PIKPAK_PROXY").unwrap_or_default(),
        account.clone(),
    );
    let mut last_poll = Instant::now() - Duration::from_secs(1);
    let mut idle_since = None;
    loop {
        // The body pool joins its RAM writers before run() returns. Discovery
        // descriptions remain in the GUI's durable selection, never completed.
        if transfer_control::draining() { return Ok(()); }
        if last_poll.elapsed() >= Duration::from_millis(150) {
            let inbox: Inbox = read_json_request_bounded(inbox_path, 32 * 1024 * 1024)?;
            if inbox.version != 1 {
                bail!("Unsupported live download queue version");
            }
            delete_after_download.store(inbox.delete_after_download, Ordering::SeqCst);
            transfer_control::set_retry_origins(&inbox.retry_origins)?;
            // Register every surviving selection before a body can claim a
            // previous checkpoint. Restored folder discovery may be paused or
            // appear later than an overlapping child in the same inbox.
            for request in &inbox.requests {
                if consumed.contains(&request.id) {
                    continue;
                }
                if request.id.is_empty()
                    || request.id.len() > 64
                    || !request
                        .id
                        .bytes()
                        .all(|v| v.is_ascii_alphanumeric() || v == b'-')
                {
                    bail!("Invalid download request identity");
                }
                if !root_scopes.contains_key(&request.id) {
                    match RootScope::new(request) {
                        Ok(scope) => {
                            root_scopes.insert(request.id.clone(), scope);
                        }
                        Err(error) => {
                            consumed.insert(request.id.clone());
                            emit(
                                serde_json::json!({"event":"request_started", "request_id":request.id}),
                            );
                            let destination_unavailable =
                                pikpak::download_policy::destination_unavailable(&error);
                            if destination_unavailable {
                                emit(
                                    serde_json::json!({"event":"request_retrying", "request_id":request.id,
                                    "attempt":0, "retry_in_millis":1000, "destination_unavailable":true,
                                    "error":format!("{error:#}")}),
                                );
                            }
                            emit(
                                serde_json::json!({"event":"request_finished", "request_id":request.id,
                                "success":false, "error":format!("{error:#}"), "destination_unavailable":destination_unavailable}),
                            );
                        }
                    }
                }
            }
            for mut request in inbox.requests {
                request.proxy_url = request.proxy_url.trim().to_owned();
                if !consumed.insert(request.id.clone()) {
                    continue;
                }
                let id = request.id.clone();
                emit(serde_json::json!({"event":"request_started", "request_id":id}));
                let source = (|| -> Result<Source> {
                    if !proxies.contains_key(&request.proxy_url) {
                        proxies.insert(
                            request.proxy_url.clone(),
                            build_client_with_proxy(Some(&request.proxy_url))?.0,
                        );
                    }
                    let client = proxies[&request.proxy_url].clone().with_content_mode(
                        inbox.content_mode.unwrap_or_else(|| {
                            inbox
                                .guest_mode
                                .map(|guest| {
                                    if guest {
                                        pikpak::ContentMode::Guest
                                    } else {
                                        pikpak::ContentMode::User
                                    }
                                })
                                .unwrap_or(account.content_mode())
                        }),
                    );
                    Ok(match &request.access {
                        Some(access) => Source::Shared(build_share_client(access, &client)?),
                        None => Source::Account(client),
                    })
                })();
                let source = match source {
                    Ok(source) => source,
                    Err(error) => {
                        emit(
                            serde_json::json!({"event":"request_finished", "request_id":id, "success":false, "error":format!("{error:#}")}),
                        );
                        root_scopes.remove(&id);
                        continue;
                    }
                };
                let mut root = Root {
                    request,
                    source,
                    steps: 0,
                    bodies: 0,
                    discovered: false,
                    discovery_failed: false,
                    error: None,
                    destination_unavailable: false,
                    seen: HashSet::new(),
                };
                let result = (|| -> Result<()> {
                    prepare_destination(&mut root.request)?;
                    let output = download_root_destination(
                        &root.request.destination,
                        &root.request.path,
                        0,
                        Some(&root.request.relative_parent),
                    )?;
                    download_fs::create_dir_all(&output)?;
                    if let Some(file) = root.request.file.clone().filter(|file| !file.id.is_empty())
                    {
                        let path = root.request.path.clone();
                        accept_file(&mut root, file, path, output, &mut pending, bodies)?;
                    } else {
                        root.steps = 1;
                        let step = Step {
                            root: id.clone(),
                            source: root.source.clone(),
                            path: root.request.path.clone(),
                            output,
                            folder: None,
                            token: None,
                            attempt: 0,
                            ready: Instant::now(),
                        };
                        transfer_control::set_scope(&step.control_id(), vec![format!("root:{id}")]);
                        pending.push_back(step);
                    }
                    Ok(())
                })();
                if let Err(error) = result {
                    fail_discovery(&mut root, &error);
                }
                roots.insert(id, root);
            }
            last_poll = Instant::now();
        }

        let mut finished = Vec::new();
        for (id, root) in &mut roots {
            if root.steps == 0 && !root.discovered {
                root.discovered = true;
                emit(
                    serde_json::json!({"event":"request_discovered", "request_id":id,
                    "discovery_complete":!root.discovery_failed}),
                );
            }
            if root.steps == 0 && root.bodies == 0 {
                emit(
                    serde_json::json!({"event":"request_finished", "request_id":id, "success":root.error.is_none(), "error":root.error,
                    "destination_unavailable":root.destination_unavailable}),
                );
                finished.push(id.clone());
            }
        }
        for id in finished {
            roots.remove(&id);
            root_scopes.remove(&id);
        }
        if roots.is_empty() {
            // Re-read once after the idle grace period. A selection that races
            // this exit stays durable in Swift until request_finished, and is
            // handed to a fresh helper without losing or replaying other roots.
            let idle = idle_since.get_or_insert_with(Instant::now);
            if idle.elapsed() >= Duration::from_millis(350)
                && last_poll.elapsed() < Duration::from_millis(50)
            {
                return Ok(());
            }
        } else {
            idle_since = None;
        }

        let outstanding: usize = roots.values().map(|root| root.bodies).sum();
        while discovering.len() < DISCOVERY_CONNECTIONS {
            let next = pending.iter().position(|step| {
                match transfer_control::action(&step.control_id()) {
                    Some(transfer_control::Action::Cancel) => true,
                    Some(transfer_control::Action::Pause) => false,
                    None => {
                        step.ready <= Instant::now()
                            && (outstanding < DISCOVERY_AHEAD
                                || roots.get(&step.root).is_some_and(|root| root.bodies < 200))
                    }
                }
            });
            let Some(index) = next else {
                break;
            };
            let step = pending.remove(index).unwrap();
            discovering.spawn(async move {
                let result = discover(&step).await;
                (step, result)
            });
        }
        tokio::select! {
            result = &mut *pool => { result??; bail!("Download scheduler stopped before the queue closed"); }
            done = completed.recv() => {
                let Some((id, result)) = done else { bail!("Download completion channel closed"); };
                if let Some(root) = roots.get_mut(&id) {
                    root.bodies -= 1;
                    if let Err(error) = result { fail(root, &error); }
                }
            }
            joined = discovering.join_next(), if !discovering.is_empty() => {
                let (mut step, result) = joined.unwrap()?;
                let root = roots.get_mut(&step.root).context("Missing discovery request")?;
                match result {
                    Err(error) if error.is::<transfer_control::Paused>() => pending.push_back(step),
                    Err(error) if pikpak::download_policy::retryable(&error) => {
                        step.attempt = step.attempt.saturating_add(1);
                        let delay = Duration::from_secs((1u64 << step.attempt.saturating_sub(1).min(6)).min(60))
                            .max(pikpak::download_policy::delay(&error).unwrap_or_default());
                        step.ready = Instant::now() + delay;
                        emit(serde_json::json!({"event":"request_retrying", "request_id":step.root, "attempt":step.attempt, "retry_in_millis":delay.as_millis() as u64}));
                        pending.push_back(step);
                    }
                    result => {
                        root.steps -= 1;
                        transfer_control::remove_scope(&step.control_id());
                        match result {
                            Ok((files, next)) => {
                                for file in files {
                                    let path = if step.folder.is_none() { step.path.clone() } else { format!("{}/{}", step.path.trim_end_matches('/'), file.name) };
                                    if let Err(error) = accept_file(root, file, path, step.output.clone(), &mut pending, bodies) { fail_discovery(root, &error); }
                                }
                                if let Some(token) = next.filter(|token| !token.is_empty()) {
                                    if root.seen.insert(format!("page|{}|{token}", step.control_id())) {
                                        step.token = Some(token); step.attempt = 0; step.ready = Instant::now();
                                        transfer_control::set_scope(&step.control_id(), vec![format!("root:{}", step.root)]);
                                        pending.push_back(step); root.steps += 1;
                                    } else { fail_discovery(root, &anyhow::anyhow!("Folder listing repeated its pagination token")); }
                                }
                            }
                            Err(error) if error.is::<transfer_control::Cancelled>() => { root.discovery_failed = true; },
                            Err(error) => fail_discovery(root, &error),
                        }
                    }
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(50)) => {},
        }
    }
}

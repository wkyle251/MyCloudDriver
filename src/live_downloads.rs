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
}

#[derive(Clone, Deserialize)]
struct Request {
    id: String,
    path: String,
    file: Option<FileInfo>,
    destination: PathBuf,
    #[serde(default)]
    relative_parent: Vec<String>,
    #[serde(default)]
    proxy_url: String,
    access: Option<ShareAccessInput>,
}

#[derive(Clone)]
enum Source { Account(Client), Shared(ShareClient) }

struct Root {
    request: Request,
    source: Source,
    steps: usize,
    bodies: usize,
    discovered: bool,
    error: Option<String>,
    seen: HashSet<String>,
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
    fn control_id(&self) -> String { format!("path:{}:{}", self.root, self.path) }
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
}

/// Bounds folder discovery ahead of the body pool. Each selection can still
/// discover its first page when a different selection is paused or backlogged.
const DISCOVERY_AHEAD: usize = 2048;
const DISCOVERY_CONNECTIONS: usize = 4;

fn accept_file(root: &mut Root, file: FileInfo, path: String, output: PathBuf,
               pending: &mut VecDeque<Step>, bodies: &mpsc::UnboundedSender<Body>) -> Result<()> {
    safe_component(&file.name)?;
    let key = if file.kind.is_folder() { format!("folder:{}", file.id) }
        else { format!("{}|{}", file.id, output.display()) };
    if !root.seen.insert(key.clone()) { return Ok(()); }
    if file.kind.is_folder() {
        let output = output.join(safe_component(&file.name)?);
        // Preserve empty folders too. File writes perform their own check.
        std::fs::create_dir_all(&output)?;
        root.steps += 1;
        let step = Step { root: root.request.id.clone(), source: root.source.clone(), path,
            output, folder: Some(file.id), token: None, attempt: 0, ready: Instant::now() };
        transfer_control::set_scope(&step.control_id(), vec![format!("root:{}", root.request.id)]);
        pending.push_back(step);
    } else {
        let digest = hex::encode(ring::digest::digest(&ring::digest::SHA256, key.as_bytes()).as_ref());
        let id = format!("{}:{digest}", root.request.id);
        transfer_control::set_scope(&id, scope(&root.request.id, &path));
        emit(serde_json::json!({"event":"queue_append", "files":[{
            "file_id":id, "request_id":root.request.id, "source_file_id":file.id,
            "name":file.name, "total_bytes":file.size, "remote_path":path,
            "output_directory":output
        }]}));
        root.bodies += 1;
        bodies.send(Body { root: root.request.id.clone(), id, source: root.source.clone(),
            task: DownloadTask { file, output_directory: output, remote_path: path } })
            .map_err(|_| anyhow::anyhow!("Download scheduler stopped"))?;
    }
    Ok(())
}

async fn discover(step: &Step) -> Result<(Vec<FileInfo>, Option<String>)> {
    let id = step.control_id();
    let result = transfer_control::interruptible(&id, async {
        match (&step.source, &step.folder) {
            (Source::Account(client), None) => Ok((vec![client.resolve_path_info(&step.path).await?], None)),
            (Source::Account(client), Some(folder)) => {
                let page = client.list_folder_page(folder, step.token.as_deref(), 200).await?;
                Ok((page.files, page.next_page_token))
            }
            (Source::Shared(client), Some(folder)) => {
                let page = client.list_folder_page(folder, step.token.as_deref(), 200).await?;
                Ok((page.files, page.next_page_token))
            }
            (Source::Shared(_), None) => bail!("Shared download metadata is missing"),
        }
    }).await?;
    result
}

pub async fn run(account: &Client, args: Args) -> Result<()> {
    let (body_sender, body_receiver) = mpsc::unbounded_channel::<Body>();
    let (done_sender, mut done_receiver) = mpsc::unbounded_channel();
    let received = Arc::new(AtomicU64::new(0));
    let counter = received.clone();
    let mut pool = tokio::spawn(async move {
        transfer_control::schedule_stream(body_receiver, transfer_control::Concurrency::download(64, received),
            move |body: Body| {
                let received = counter.clone();
                async move {
                    let task = &body.task;
                    emit_download_progress(true, DownloadProgressEvent::FileDequeued {
                        file_id: &body.id, name: &task.file.name, total_bytes: task.file.size,
                    });
                    tokio::fs::create_dir_all(&task.output_directory).await?;
                    match &body.source {
                        Source::Account(client) => {
                            // Old persisted queue entries have only ID/name/size.
                            // Resolve their folder without using the quota-gated
                            // file endpoint, and never substitute a same-named ID.
                            let resolved;
                            let file = if client.content_mode().tries_guest() && task.file.parent_id.is_none() {
                                let result = transfer_control::interruptible(&body.id, client.resolve_path_info(&task.remote_path)).await?;
                                match result {
                                    Ok(file) => {
                                        resolved = file;
                                        if resolved.id != task.file.id { bail!("This path now identifies a different file. Refresh the folder and try again."); }
                                        &resolved
                                    },
                                    Err(_) if client.content_mode() == pikpak::ContentMode::Dynamic => &task.file,
                                    Err(error) => return Err(error.into()),
                                }
                            } else { &task.file };
                            download_file_as(client, file, &task.output_directory, false, true, received, &body.id).await
                        },
                        Source::Shared(client) => download_share_file_as(client, &task.file, &task.output_directory, false, true, received, &body.id).await,
                    }
                }
            }, |body| body.id.clone(),
            move |body, result| {
                if let Err(error) = &result {
                    emit_download_progress(true, DownloadProgressEvent::FileFailed {
                        file_id: &body.id, name: &body.task.file.name, downloaded_bytes: 0,
                        transferred_bytes: 0, total_bytes: body.task.file.size, error: &format!("{error:#}"),
                    });
                }
                transfer_control::remove_scope(&body.id);
                transfer_control::forget_network_counter(&body.id);
                let _ = done_sender.send((body.root, result));
            }, |body, attempt, delay| emit_download_progress(true, DownloadProgressEvent::FileRetrying {
                file_id: &body.id, name: &body.task.file.name, attempt, retry_in_millis: delay.as_millis() as u64,
            })).await
    });
    // Abort on every early error as well as app termination; no orphan pool.
    let result = coordinate(account, &args.request_file, &body_sender, &mut done_receiver, &mut pool).await;
    drop(body_sender);
    if result.is_err() { pool.abort(); } else { pool.await??; }
    result
}

async fn coordinate(account: &Client, inbox_path: &StdPath, bodies: &mpsc::UnboundedSender<Body>,
                    completed: &mut mpsc::UnboundedReceiver<(String, Result<()>)>,
                    pool: &mut tokio::task::JoinHandle<Result<()>>) -> Result<()> {
    let mut roots = HashMap::<String, Root>::new();
    let mut consumed = HashSet::new();
    let mut pending = VecDeque::<Step>::new();
    let mut discovering = tokio::task::JoinSet::new();
    let mut proxies = HashMap::new();
    proxies.insert(std::env::var("PIKPAK_PROXY").unwrap_or_default(), account.clone());
    let mut last_poll = Instant::now() - Duration::from_secs(1);
    let mut idle_since = None;
    loop {
        if last_poll.elapsed() >= Duration::from_millis(150) {
            let inbox: Inbox = read_json_request_bounded(inbox_path, 32 * 1024 * 1024)?;
            if inbox.version != 1 { bail!("Unsupported live download queue version"); }
            for mut request in inbox.requests {
                request.proxy_url = request.proxy_url.trim().to_owned();
                if !consumed.insert(request.id.clone()) { continue; }
                // IDs are app-generated UUIDs; control delimiters stay private.
                if request.id.is_empty() || request.id.len() > 64 || !request.id.bytes().all(|v| v.is_ascii_alphanumeric() || v == b'-') {
                    bail!("Invalid download request identity");
                }
                let id = request.id.clone();
                emit(serde_json::json!({"event":"request_started", "request_id":id}));
                let source = (|| -> Result<Source> {
                    if !proxies.contains_key(&request.proxy_url) {
                        proxies.insert(request.proxy_url.clone(), build_client_with_proxy(Some(&request.proxy_url))?.0);
                    }
                    let client = proxies[&request.proxy_url].clone()
                        .with_content_mode(inbox.content_mode.unwrap_or_else(|| inbox.guest_mode
                            .map(|guest| if guest { pikpak::ContentMode::Guest } else { pikpak::ContentMode::User })
                            .unwrap_or(account.content_mode())));
                    Ok(match &request.access { Some(access) => Source::Shared(build_share_client(access, &client)?), None => Source::Account(client) })
                })();
                let source = match source {
                    Ok(source) => source,
                    Err(error) => { emit(serde_json::json!({"event":"request_finished", "request_id":id, "success":false, "error":format!("{error:#}")})); continue; }
                };
                let mut root = Root { request, source, steps: 0, bodies: 0, discovered: false, error: None, seen: HashSet::new() };
                let result = (|| -> Result<()> {
                    let output = download_root_destination(&root.request.destination, &root.request.path, 0, Some(&root.request.relative_parent))?;
                    if let Some(file) = root.request.file.clone().filter(|file| !file.id.is_empty()) {
                        let path = root.request.path.clone();
                        accept_file(&mut root, file, path, output, &mut pending, bodies)?;
                    } else {
                        root.steps = 1;
                        let step = Step { root: id.clone(), source: root.source.clone(), path: root.request.path.clone(), output,
                            folder: None, token: None, attempt: 0, ready: Instant::now() };
                        transfer_control::set_scope(&step.control_id(), vec![format!("root:{id}")]);
                        pending.push_back(step);
                    }
                    Ok(())
                })();
                if let Err(error) = result { fail(&mut root, &error); }
                roots.insert(id, root);
            }
            last_poll = Instant::now();
        }

        let mut finished = Vec::new();
        for (id, root) in &mut roots {
            if root.steps == 0 && !root.discovered {
                root.discovered = true;
                emit(serde_json::json!({"event":"request_discovered", "request_id":id}));
            }
            if root.steps == 0 && root.bodies == 0 {
                emit(serde_json::json!({"event":"request_finished", "request_id":id, "success":root.error.is_none(), "error":root.error}));
                finished.push(id.clone());
            }
        }
        for id in finished { roots.remove(&id); }
        if roots.is_empty() {
            // Re-read once after the idle grace period. A selection that races
            // this exit stays durable in Swift until request_finished, and is
            // handed to a fresh helper without losing or replaying other roots.
            let idle = idle_since.get_or_insert_with(Instant::now);
            if idle.elapsed() >= Duration::from_millis(350) && last_poll.elapsed() < Duration::from_millis(50) { return Ok(()); }
        } else { idle_since = None; }

        let outstanding: usize = roots.values().map(|root| root.bodies).sum();
        while discovering.len() < DISCOVERY_CONNECTIONS {
            let next = pending.iter().position(|step| {
                match transfer_control::action(&step.control_id()) {
                    Some(transfer_control::Action::Cancel) => true,
                    Some(transfer_control::Action::Pause) => false,
                    None => step.ready <= Instant::now() && (outstanding < DISCOVERY_AHEAD
                        || roots.get(&step.root).is_some_and(|root| root.bodies < 200)),
                }
            });
            let Some(index) = next else { break; };
            let step = pending.remove(index).unwrap();
            discovering.spawn(async move { let result = discover(&step).await; (step, result) });
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
                                    if let Err(error) = accept_file(root, file, path, step.output.clone(), &mut pending, bodies) { fail(root, &error); }
                                }
                                if let Some(token) = next.filter(|token| !token.is_empty()) {
                                    if root.seen.insert(format!("page|{}|{token}", step.control_id())) {
                                        step.token = Some(token); step.attempt = 0; step.ready = Instant::now();
                                        transfer_control::set_scope(&step.control_id(), vec![format!("root:{}", step.root)]);
                                        pending.push_back(step); root.steps += 1;
                                    } else { fail(root, &anyhow::anyhow!("Folder listing repeated its pagination token")); }
                                }
                            }
                            Err(error) if error.is::<transfer_control::Cancelled>() => {},
                            Err(error) => fail(root, &error),
                        }
                    }
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(50)) => {},
        }
    }
}

use super::*;
use std::sync::{atomic::AtomicUsize, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Request {
    path: String,
    parent: String,
    token: String,
}

struct Server {
    address: std::net::SocketAddr,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Server {
    fn client(&self) -> Client {
        Client::builder()
            .personal_access_token("generated-pat")
            .device_id("generated-device")
            .api_base_url(format!("http://{}", self.address))
            .build()
            .unwrap()
    }
}

async fn server<F, Fut>(handler: F) -> Server
where
    F: Fn(Request) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = (u16, Option<u64>, Value)> + Send + 'static,
{
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let handler = Arc::new(handler);
    let task = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let handler = handler.clone();
            tokio::spawn(async move {
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                while !bytes.windows(4).any(|v| v == b"\r\n\r\n") {
                    let n = socket.read(&mut buffer).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    bytes.extend_from_slice(&buffer[..n]);
                }
                let text = String::from_utf8_lossy(&bytes);
                let route = text
                    .lines()
                    .next()
                    .unwrap()
                    .split_whitespace()
                    .nth(1)
                    .unwrap();
                let url = url::Url::parse(&format!("http://generated{route}")).unwrap();
                let query: HashMap<_, _> = url
                    .query_pairs()
                    .map(|(k, v)| (k.into_owned(), v.into_owned()))
                    .collect();
                let request = Request {
                    path: url.path().to_owned(),
                    parent: query.get("parent_id").cloned().unwrap_or_default(),
                    token: query.get("page_token").cloned().unwrap_or_default(),
                };
                let (status, retry_after, value) = handler(request).await;
                let body = value.to_string();
                let retry = retry_after
                    .map(|seconds| format!("Retry-After: {seconds}\r\n"))
                    .unwrap_or_default();
                let response = format!("HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n{retry}\r\n{body}", body.len());
                let _ = socket.write_all(response.as_bytes()).await;
            });
        }
    });
    Server { address, task }
}

fn selected(id: &str, folder: bool, path: &str) -> CloudItem {
    CloudItem {
        id: id.into(),
        name: "Generated".into(),
        path: path.into(),
        is_folder: folder,
        size: 0,
        revision: None,
        ancestors: vec![],
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn independent_folders_overlap_but_each_page_chain_stays_sequential_and_scoped() {
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let pages = Arc::new(Mutex::new(HashMap::<String, Vec<String>>::new()));
    let per_folder = Arc::new(Mutex::new(HashSet::<String>::new()));
    let state = (active.clone(), peak.clone(), pages.clone(), per_folder);
    let fixture = server(move |request| {
        let (active, peak, pages, per_folder) = state.clone();
        async move {
            if request.path != "/drive/v1/files" {
                assert!(request.path.ends_with("/selected") || request.path.ends_with("/folder-0"));
                tokio::time::sleep(Duration::from_millis(80)).await;
                return (200,None,json!({"id":"generated", "size":"7", "hash":"fresh", "trashed":false}));
            }
            assert!(per_folder.lock().unwrap().insert(request.parent.clone()), "A folder's page requests overlapped");
            pages.lock().unwrap().entry(request.parent.clone()).or_default().push(request.token.clone());
            let count = active.fetch_add(1,Ordering::AcqRel) + 1;
            peak.fetch_max(count,Ordering::AcqRel);
            tokio::time::sleep(Duration::from_millis(40)).await;
            active.fetch_sub(1,Ordering::AcqRel);
            per_folder.lock().unwrap().remove(&request.parent);
            let page = if request.parent.is_empty() {
                let mut files:Vec<_> = (0..12).map(|i| json!({"id":format!("folder-{i}"), "name":format!("Generated-{i}"), "kind":"drive#folder", "size":"0"})).collect();
                files.extend([
                    json!({"id":"", "name":"Cycle", "kind":"drive#folder", "size":"0"}),
                    json!({"id":"hidden", "name":".hidden", "kind":"drive#folder", "size":"0"}),
                    json!({"id":"selected", "name":"Stale", "kind":"drive#file", "size":"1", "hash":"stale"}),
                    json!({"id":"root-file", "name":"Generated.txt", "kind":"drive#file", "size":"7", "hash":"fresh"}),
                ]);
                json!({"files":files})
            } else {
                assert!(request.parent.starts_with("folder-"), "Hidden and cycle folders must not be listed");
                let token = if request.token.is_empty() { "first" } else { "second" };
                json!({"files":[{"id":format!("{}-{token}",request.parent), "name":"Generated.txt", "kind":"drive#file", "size":"7", "hash":"fresh"}],
                    "next_page_token":if request.token.is_empty() { Some("next") } else { None }})
            };
            (200,None,page)
        }
    }).await;
    let root = tempfile::tempdir().unwrap();
    let mut request = super::super::tests::request(root.path());
    request.cloud_items = vec![
        selected("", true, "/"),
        selected("selected", false, "/Selected.txt"),
        selected("folder-0", true, "/SelectedFolder"),
    ];
    let client = fixture.client();
    let mut staged = StagedCloud::new();
    let mut found = Vec::new();
    discover(
        &request,
        &client,
        &AtomicBool::new(false),
        &CancellationToken::default(),
        &mut staged,
        &mut |file| {
            found.push(file);
            Ok(())
        },
    )
    .await
    .unwrap();
    assert!(peak.load(Ordering::Acquire) > 1);
    assert!(peak.load(Ordering::Acquire) <= MAX_REQUESTS);
    assert_eq!(
        (staged.discovered, staged.skipped, found.len()),
        (26, 0, 26)
    );
    let selected = found.iter().find(|f| f.id == "selected").unwrap();
    assert_eq!(
        (
            selected.size,
            selected.revision.as_deref(),
            selected.path.as_str()
        ),
        (7, Some("fresh"), "/Selected.txt")
    );
    assert!(found
        .iter()
        .filter(|f| f.id.starts_with("folder-0-"))
        .all(|f| f.path == "/SelectedFolder/Generated.txt"
            && f.ancestors.len() == 1
            && f.ancestors[0].id == "folder-0"));
    let pages = pages.lock().unwrap();
    assert_eq!(pages.len(), 13);
    for i in 0..12 {
        assert_eq!(
            pages[&format!("folder-{i}")],
            vec!["".to_owned(), "next".to_owned()]
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn empty_folder_trees_honour_pause_and_cancel_without_a_file_callback() {
    let calls = Arc::new(AtomicUsize::new(0));
    let server_calls = calls.clone();
    let fixture = server(move |request| {
        let calls = server_calls.clone();
        async move {
            assert_eq!(request.path,"/drive/v1/files");
            calls.fetch_add(1,Ordering::AcqRel);
            tokio::time::sleep(Duration::from_millis(40)).await;
            let files:Vec<_> = if request.parent.is_empty() {
                (0..64).map(|i|json!({"id":format!("empty-{i}"),"name":"Generated", "kind":"drive#folder", "size":"0"})).collect()
            } else { vec![] };
            (200,None,json!({"files":files}))
        }
    }).await;
    let root = tempfile::tempdir().unwrap();
    let mut request = super::super::tests::request(root.path());
    request.cloud_items = vec![selected("", true, "/")];
    let control = CancellationToken::default();
    control.set_paused(true);
    let cancel = Arc::new(AtomicBool::new(false));
    let controller = {
        let control = control.clone();
        let cancel = cancel.clone();
        let calls = calls.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(80)).await;
            assert_eq!(
                calls.load(Ordering::Acquire),
                0,
                "A paused scan started a metadata request"
            );
            control.set_paused(false);
            let deadline = Instant::now() + Duration::from_secs(5);
            while calls.load(Ordering::Acquire) < 3 && Instant::now() < deadline {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            assert!(calls.load(Ordering::Acquire) >= 3);
            control.set_paused(true);
            tokio::time::sleep(Duration::from_millis(100)).await;
            let paused = calls.load(Ordering::Acquire);
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert_eq!(
                calls.load(Ordering::Acquire),
                paused,
                "Empty folders continued listing while paused"
            );
            assert!(paused < 65);
            cancel.store(true, Ordering::Release);
        })
    };
    let result = tokio::time::timeout(
        Duration::from_secs(6),
        discover(
            &request,
            &fixture.client(),
            &cancel,
            &control,
            &mut StagedCloud::new(),
            &mut |_| panic!("An empty tree yielded a file"),
        ),
    )
    .await
    .unwrap();
    assert!(result.is_err());
    controller.await.unwrap();
}

#[tokio::test]
async fn scan_retry_after_is_immediate_and_shared_origin_gate_delays_other_requests() {
    let calls = Arc::new(AtomicUsize::new(0));
    let server_calls = calls.clone();
    let fixture = server(move |_| {
        let calls = server_calls.clone();
        async move {
            calls.fetch_add(1, Ordering::AcqRel);
            (429, Some(2), json!({"error":"fixture_backoff"}))
        }
    })
    .await;
    let error = fixture
        .client()
        .list_similarity_folder_page("", None, 500)
        .await
        .unwrap_err();
    assert!(
        matches!(error,crate::Error::RetryAfter { status:429, delay } if delay==Duration::from_secs(2))
    );
    assert_eq!(
        calls.load(Ordering::Acquire),
        1,
        "The scan coordinator must see the first provider rejection"
    );

    let first = crate::download_network::Network::for_url(&format!("http://{}", fixture.address));
    let second = crate::download_network::Network::for_url(&format!(
        "http://{}/different?generated=1",
        fixture.address
    ));
    assert!(Arc::ptr_eq(&first, &second));
    let control = CancellationToken::default();
    let cancel = AtomicBool::new(false);
    let attempts = AtomicUsize::new(0);
    let start = Instant::now();
    let first_read = read(&first, &control, &cancel, false, || async {
        if attempts.fetch_add(1, Ordering::AcqRel) == 0 {
            Err(crate::Error::RetryAfter {
                status: 429,
                delay: Duration::from_millis(500),
            }
            .into())
        } else {
            Ok(7)
        }
    });
    let second_read = async {
        tokio::time::sleep(Duration::from_millis(80)).await;
        read(&second, &control, &cancel, false, || async {
            Ok(Instant::now())
        })
        .await
        .unwrap()
    };
    let (result, second_start) = tokio::join!(first_read, second_read);
    assert_eq!(result.unwrap(), 7);
    assert_eq!(attempts.load(Ordering::Acquire), 2);
    assert!(
        second_start.duration_since(start) >= Duration::from_millis(450),
        "Another request bypassed the origin cooldown"
    );
}

#[tokio::test]
async fn waiting_for_a_shared_slot_is_cancellable_and_a_paused_slot_is_released() {
    let network = crate::download_network::Network::new(1, None);
    let held = network.acquire().await.unwrap();
    let control = CancellationToken::default();
    let cancel = AtomicBool::new(false);
    let controller = {
        let control = control.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(40)).await;
            control.cancel();
        })
    };
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        read(&network, &control, &cancel, false, || async {
            panic!("Cancelled gate wait started a request");
            #[allow(unreachable_code)]
            Ok(())
        }),
    )
    .await
    .unwrap();
    assert!(result.is_err());
    controller.await.unwrap();
    drop(held);
    let control = CancellationToken::default();
    control.set_paused(true);
    let calls = AtomicUsize::new(0);
    let unpause = {
        let control = control.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(80)).await;
            control.set_paused(false);
        })
    };
    assert_eq!(
        read(&network, &control, &cancel, false, || async {
            calls.fetch_add(1, Ordering::AcqRel);
            Ok(9)
        })
        .await
        .unwrap(),
        9
    );
    assert_eq!(calls.load(Ordering::Acquire), 1);
    unpause.await.unwrap();
    assert!(
        network.try_acquire().unwrap().is_some(),
        "The request leaked its shared slot"
    );
}

#[tokio::test]
async fn repeated_tokens_and_denied_folders_remain_incomplete() {
    let fixture = server(|request| async move {
        if request.parent == "denied" {
            return (403, None, json!({"error":"fixture_denied"}));
        }
        if request.parent == "loop" {
            return (200, None, json!({"files":[],"next_page_token":"same"}));
        }
        assert!(request.parent.is_empty());
        (
            200,
            None,
            json!({"files":[
            {"id":"denied","name":"GeneratedDenied","kind":"drive#folder","size":"0"},
            {"id":"loop","name":"GeneratedLoop","kind":"drive#folder","size":"0"}]}),
        )
    })
    .await;
    let root = tempfile::tempdir().unwrap();
    let mut request = super::super::tests::request(root.path());
    request.cloud_items = vec![selected("", true, "/")];
    let mut staged = StagedCloud::new();
    discover(
        &request,
        &fixture.client(),
        &AtomicBool::new(false),
        &CancellationToken::default(),
        &mut staged,
        &mut |_| Ok(()),
    )
    .await
    .unwrap();
    assert_eq!((staged.discovered, staged.skipped), (0, 2));
    assert!(staged
        .issues
        .iter()
        .any(|i| i.reason.contains("page token")));
    assert!(staged.issues.iter().any(|i| i.reason.contains("denied")));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pausing_inflight_pages_releases_shared_slots_and_resumes_the_same_token_chains() {
    let calls = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(AtomicBool::new(false));
    let pages = Arc::new(Mutex::new(HashMap::<String, Vec<String>>::new()));
    let fixture = {
        let calls = calls.clone();
        let release = release.clone();
        let pages = pages.clone();
        server(move |request| {
            let calls = calls.clone();
            let release = release.clone();
            let pages = pages.clone();
            async move {
                if request.parent.is_empty() {
                    return (200,None,json!({"files":[
                        {"id":"one","name":"GeneratedOne","kind":"drive#folder","size":"0"},
                        {"id":"two","name":"GeneratedTwo","kind":"drive#folder","size":"0"}]}));
                }
                calls.fetch_add(1, Ordering::AcqRel);
                pages.lock().unwrap().entry(request.parent.clone()).or_default().push(request.token.clone());
                while !release.load(Ordering::Acquire) { tokio::time::sleep(Duration::from_millis(5)).await; }
                let first = request.token.is_empty();
                (200,None,json!({"files":[{"id":format!("{}-{}",request.parent,if first {"first"} else {"last"}),
                    "name":"Generated.txt","kind":"drive#file","size":"7","hash":"fresh"}],
                    "next_page_token":if first {Some("next")} else {None}}))
            }
        }).await
    };
    let client = fixture.client();
    let network = crate::download_network::Network::for_url(&client.api_base);
    let control = CancellationToken::default();
    let cancel = AtomicBool::new(false);
    let controller = {
        let control = control.clone();
        let network = network.clone();
        let calls = calls.clone();
        let release = release.clone();
        tokio::spawn(async move {
            let start = Instant::now();
            while calls.load(Ordering::Acquire) < 2 {
                assert!(start.elapsed() < Duration::from_secs(2));
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            assert_eq!(network.active(), 2);
            control.set_paused(true);
            let start = Instant::now();
            while network.active() > 0 {
                assert!(
                    start.elapsed() < Duration::from_secs(1),
                    "Paused page futures retained shared slots"
                );
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            let content = network
                .try_acquire()
                .unwrap()
                .expect("A paused scan withheld content capacity");
            drop(content);
            release.store(true, Ordering::Release);
            tokio::time::sleep(Duration::from_millis(30)).await;
            control.set_paused(false);
        })
    };
    let root = tempfile::tempdir().unwrap();
    let mut request = super::super::tests::request(root.path());
    request.cloud_items = vec![selected("", true, "/")];
    let mut staged = StagedCloud::new();
    let mut found = Vec::new();
    discover(
        &request,
        &client,
        &cancel,
        &control,
        &mut staged,
        &mut |file| {
            assert_eq!(
                network.active(),
                0,
                "A publishing callback retained another page's slot"
            );
            found.push(file.id);
            Ok(())
        },
    )
    .await
    .unwrap();
    controller.await.unwrap();
    assert_eq!((staged.discovered, staged.skipped), (4, 0));
    assert_eq!(found.iter().collect::<HashSet<_>>().len(), 4);
    let pages = pages.lock().unwrap();
    for folder in ["one", "two"] {
        assert_eq!(
            pages[folder],
            vec!["".to_owned(), "".to_owned(), "next".to_owned()]
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_callback_blocked_on_discovery_backpressure_holds_no_metadata_slots() {
    let fixture=server(|request|async move{
        if request.parent.is_empty() {
            (200,None,json!({"files":[
                {"id":"one","name":"GeneratedOne","kind":"drive#folder","size":"0"},
                {"id":"two","name":"GeneratedTwo","kind":"drive#folder","size":"0"}]}))
        } else {
            tokio::time::sleep(Duration::from_millis(30)).await;
            (200,None,json!({"files":[{"id":format!("{}-file",request.parent),"name":"Generated.txt","kind":"drive#file","size":"7","hash":"fresh"}]}))
        }
    }).await;
    let client = fixture.client();
    let network = crate::download_network::Network::for_url(&client.api_base);
    let control = CancellationToken::default();
    let cancel = Arc::new(AtomicBool::new(false));
    let entered = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = std::sync::mpsc::sync_channel(0);
    let consumer = {
        let network = network.clone();
        let control = control.clone();
        let cancel = cancel.clone();
        let entered = entered.clone();
        std::thread::spawn(move || {
            let start = Instant::now();
            while !entered.load(Ordering::Acquire) {
                assert!(start.elapsed() < Duration::from_secs(2));
                std::thread::sleep(Duration::from_millis(2));
            }
            control.set_paused(true);
            assert_eq!(
                network.active(),
                0,
                "Backpressure retained metadata permits"
            );
            std::thread::sleep(Duration::from_millis(60));
            assert!(
                network.try_acquire().unwrap().is_some(),
                "Paused callback prevented another content request"
            );
            receiver.recv().unwrap();
            cancel.store(true, Ordering::Release);
        })
    };
    let root = tempfile::tempdir().unwrap();
    let mut request = super::super::tests::request(root.path());
    request.cloud_items = vec![selected("", true, "/")];
    let result = discover(
        &request,
        &client,
        &cancel,
        &control,
        &mut StagedCloud::new(),
        &mut |file| {
            entered.store(true, Ordering::Release);
            sender
                .send(file.id)
                .map_err(|_| anyhow::anyhow!("Generated callback stopped"))
        },
    )
    .await;
    assert!(result.is_err());
    consumer.join().unwrap();
    assert_eq!(network.active(), 0);
}

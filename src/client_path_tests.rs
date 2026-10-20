//! Generated path metadata and loopback HTTP only. Recorded requests prove
//! path lookup stops without silently consuming the rest of a large folder.
use super::*;
use std::{
    collections::{HashMap, VecDeque},
    path::Path,
    sync::{Arc, Mutex},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Page {
    parent: &'static str,
    token: Option<&'static str>,
    body: Value,
    before_response: Option<Box<dyn FnOnce() + Send>>,
}
impl Page {
    fn new(parent: &'static str, token: Option<&'static str>, files: Vec<Value>, next: Option<&str>) -> Self {
        Self { parent, token, body: serde_json::json!({"files":files,"next_page_token":next}), before_response: None }
    }
}

#[derive(Default)]
struct Observed {
    requests: Vec<(String, Option<String>)>,
    errors: Vec<String>,
}
struct Fixture {
    client: Client,
    worker: tokio::task::JoinHandle<()>,
    observed: Arc<Mutex<Observed>>,
    expected: usize,
}
impl Fixture {
    async fn new(pages: Vec<Page>, cache: Option<&Path>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = format!("http://{}", listener.local_addr().unwrap());
        let expected = pages.len();
        let observed = Arc::new(Mutex::new(Observed::default()));
        let records = observed.clone();
        let worker = tokio::spawn(async move {
            let mut pages = VecDeque::from(pages);
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                while !bytes.windows(4).any(|window| window == b"\r\n\r\n") {
                    let count = tokio::time::timeout(Duration::from_secs(5), socket.read(&mut buffer))
                        .await.unwrap().unwrap();
                    assert!(count > 0 && bytes.len() < 65536);
                    bytes.extend_from_slice(&buffer[..count]);
                }
                let request = String::from_utf8(bytes).unwrap();
                let first = request.lines().next().unwrap();
                let target = first.split_whitespace().nth(1).unwrap();
                let url = reqwest::Url::parse(&format!("http://generated{target}")).unwrap();
                let (status, body) = if url.path() == "/v1/user/me" {
                    (200, serde_json::json!({"sub":"generated-path-account"}))
                } else {
                    let query: HashMap<String, String> = url.query_pairs().into_owned().collect();
                    let parent = query.get("parent_id").cloned().unwrap_or_default();
                    let token = query.get("page_token").cloned();
                    {
                        let mut record = records.lock().unwrap();
                        record.requests.push((parent.clone(), token.clone()));
                        let correct_params = first.starts_with("GET /drive/v1/files?")
                            && query.get("limit").map(String::as_str) == Some("500")
                            && query.get("thumbnail_size").map(String::as_str) == Some("SIZE_MEDIUM")
                            && query.get("with_audit").map(String::as_str) == Some("false")
                            && query.get("filters").and_then(|filters| serde_json::from_str::<Value>(filters).ok())
                                == Some(serde_json::json!({"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}));
                        if !correct_params { record.errors.push("Path lookup changed the ordinary listing parameters".into()); }
                    }
                    match pages.pop_front() {
                        Some(page) => {
                            if (parent.as_str(), token.as_deref()) != (page.parent, page.token) {
                                records.lock().unwrap().errors.push(format!(
                                    "Expected generated parent/token {:?}, received {:?}",
                                    (page.parent, page.token), (parent, token)));
                            }
                            if let Some(action) = page.before_response { action(); }
                            (200, page.body)
                        }
                        None => {
                            records.lock().unwrap().errors.push("Unexpected extra listing request".into());
                            (400, serde_json::json!({"error":"generated-unexpected-request"}))
                        }
                    }
                };
                let body = body.to_string();
                let response = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                socket.write_all(response.as_bytes()).await.unwrap();
            }
        });
        let mut client = Client::builder().personal_access_token("generated-path-pat")
            .auth_base_url(&address).api_base_url(&address).timeout(Duration::from_secs(5)).build().unwrap();
        if let Some(directory) = cache { client = client.with_duplicate_cache_directory(directory.to_owned()); }
        Self { client, worker, observed, expected }
    }
    fn count(&self) -> usize { self.observed.lock().unwrap().requests.len() }
    fn assert_done(&self) {
        let observed = self.observed.lock().unwrap();
        assert!(observed.errors.is_empty(), "{:?}", observed.errors);
        assert_eq!(observed.requests.len(), self.expected, "Every expected page, and no later page, must be requested");
    }
}
impl Drop for Fixture {
    fn drop(&mut self) { self.worker.abort(); }
}

fn entry(id: &str, name: &str, parent: &str, folder: bool) -> Value {
    serde_json::json!({"id":id,"name":name,"parent_id":parent,"size":"8",
        "kind":if folder {"drive#folder"} else {"drive#file"},
        "hash":"0123456789012345678901234567890123456789",
        "phase":"PHASE_TYPE_COMPLETE","trashed":false})
}
fn cached(value: Value) -> FileInfo { serde_json::from_value(value).unwrap() }

#[tokio::test]
async fn first_page_matches_stop_both_path_apis_without_requesting_the_next_page() {
    let fixture = Fixture::new(vec![
        Page::new("", None, vec![entry("folder-first", "target", "", true)], Some("unneeded-folder-page")),
        Page::new("", None, vec![
            entry("file-first", "target.bin", "", false), entry("file-neighbor", "neighbor.bin", "", false),
        ], Some("unneeded-file-page")),
    ], None).await;
    assert_eq!(fixture.client.resolve_path("/target").await.unwrap(), "folder-first");
    assert_eq!(fixture.count(), 1, "The next page must not be requested after a folder match");
    let guest = fixture.client.clone().with_content_mode(crate::ContentMode::Guest);
    assert_eq!(guest.resolve_path_info("/target.bin").await.unwrap().id, "file-first");
    assert_eq!(fixture.count(), 2, "The next page must not be requested after a file match");
    assert!(guest.guest.cached("file-first", Some("")).is_some());
    assert!(guest.guest.cached("file-neighbor", Some("")).is_some(),
        "Early stopping must still remember every returned item for Guest downloads");
    fixture.assert_done();
}

#[tokio::test]
async fn later_page_matches_stop_in_server_order_and_keep_folder_only_intermediate_segments() {
    let fixture = Fixture::new(vec![
        Page::new("", None, vec![entry("same-name-file", "branch", "", false)], Some("folder-page")),
        Page::new("", Some("folder-page"), vec![
            entry("folder-first", "branch", "", true), entry("folder-second", "branch", "", true),
        ], Some("unneeded-root-tail")),
        Page::new("folder-first", None, vec![entry("other-file", "other", "folder-first", false)], Some("leaf-page")),
        Page::new("folder-first", Some("leaf-page"), vec![
            entry("leaf-first", "leaf", "folder-first", false),
            entry("leaf-folder", "leaf", "folder-first", true),
        ], Some("unneeded-leaf-tail")),
        Page::new("", None, vec![entry("same-name-file", "branch", "", false)], Some("folder-page")),
        Page::new("", Some("folder-page"), vec![
            entry("folder-first", "branch", "", true), entry("folder-second", "branch", "", true),
        ], Some("unneeded-folder-tail")),
    ], None).await;
    assert_eq!(fixture.client.resolve_path_info("//branch///leaf/").await.unwrap().id, "leaf-first");
    assert_eq!(fixture.count(), 4);
    assert_eq!(fixture.client.resolve_path("/branch").await.unwrap(), "folder-first",
        "Even the final segment of resolve_path must be a folder");
    fixture.assert_done();
}

#[tokio::test]
async fn the_final_info_segment_accepts_the_first_file_or_folder_with_that_name() {
    let fixture = Fixture::new(vec![
        Page::new("", None, vec![
            entry("first-file", "same", "", false), entry("later-folder", "same", "", true),
        ], Some("unneeded-one")),
        Page::new("", None, vec![
            entry("first-folder", "same", "", true), entry("later-file", "same", "", false),
        ], Some("unneeded-two")),
    ], None).await;
    assert_eq!(fixture.client.resolve_path_info("/same").await.unwrap().id, "first-file");
    assert_eq!(fixture.client.resolve_path_info("/same").await.unwrap().id, "first-folder");
    fixture.assert_done();
}

#[tokio::test]
async fn absent_segments_exhaust_pages_and_preserve_root_and_error_semantics() {
    let fixture = Fixture::new(vec![
        Page::new("", None, vec![entry("branch-id", "branch", "", true)], Some("unused-root-tail")),
        Page::new("branch-id", None, vec![], Some("last")),
        Page::new("branch-id", Some("last"), vec![entry("other", "other", "branch-id", false)], None),
    ], None).await;
    assert_eq!(fixture.client.resolve_path("///").await.unwrap(), "");
    assert!(matches!(fixture.client.resolve_path_info("/").await, Err(Error::InvalidPath(_))));
    assert_eq!(fixture.count(), 0);
    let error = fixture.client.resolve_path_info("/branch/missing").await.unwrap_err();
    assert!(matches!(error, Error::NotFound { path, segment }
        if path == "/branch/missing" && segment == "missing"));
    fixture.assert_done();
}

#[tokio::test]
async fn repeated_or_cyclic_page_tokens_fail_even_if_the_invalid_page_contains_a_match() {
    for cycle in [false, true] {
        let mut pages = vec![Page::new("", None, vec![], Some("a"))];
        if cycle { pages.push(Page::new("", Some("a"), vec![], Some("b"))); }
        pages.push(Page::new("", Some(if cycle { "b" } else { "a" }),
            vec![entry("invalid-match", "target", "", true)], Some("a")));
        let fixture = Fixture::new(pages, None).await;
        assert!(fixture.client.resolve_path("/target").await.is_err(),
            "Observed invalid pagination must not be accepted merely because a name matched");
        fixture.assert_done();
    }
}

#[tokio::test]
async fn stopped_listings_are_partial_cache_hints_and_only_exhausted_pages_replace_inventory() {
    let directory = tempfile::tempdir().unwrap();
    let cache = DuplicateCache::open(directory.path(), "generated-path-account").unwrap();
    cache.replace_folder("", &[cached(entry("obsolete", "obsolete", "", false))]).unwrap();
    assert!(cache.folder("").unwrap().is_some());
    let fixture = Fixture::new(vec![
        Page::new("", None, vec![entry("target-folder", "target", "", true)], Some("unused")),
        Page::new("", None, vec![entry("retained-one", "one", "", false)], Some("last")),
        Page::new("", Some("last"), vec![entry("retained-two", "two", "", false)], None),
    ], Some(directory.path())).await;
    assert_eq!(fixture.client.resolve_path("/target").await.unwrap(), "target-folder");
    assert!(cache.folder("").unwrap().is_none(), "An early stop cannot leave an old complete snapshot valid");
    assert!(cache.file("target-folder").unwrap().is_some(), "Observed partial metadata remains a useful hint");
    assert!(matches!(fixture.client.resolve_path_info("/missing").await, Err(Error::NotFound { .. })));
    let mut ids: Vec<_> = cache.folder("").unwrap().unwrap().into_iter().map(|file| file.id).collect();
    ids.sort();
    assert_eq!(ids, ["retained-one", "retained-two"]);
    assert!(cache.file("obsolete").unwrap().is_none());
    assert!(cache.file("target-folder").unwrap().is_none());
    fixture.assert_done();
}

#[tokio::test]
async fn mutations_between_pages_prevent_stale_partial_or_complete_cache_writes() {
    for partial in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let cache = Arc::new(DuplicateCache::open(directory.path(), "generated-path-account").unwrap());
        cache.replace_folder("", &[
            cached(entry("removed", "removed-old", "", false)),
            cached(entry("renamed", "renamed-old", "", false)),
        ]).unwrap();
        let mut last = Page::new("", Some("last"), vec![
            entry("removed", "removed-old", "", false),
            entry("renamed", "renamed-old", "", false),
            entry("target", "target", "", true),
        ], partial.then_some("unneeded-tail"));
        let changed = cache.clone();
        last.before_response = Some(Box::new(move || {
            changed.remove(&["removed".into()]).unwrap();
            changed.rename_file("renamed", "renamed-current").unwrap();
        }));
        let fixture = Fixture::new(vec![
            Page::new("", None, vec![entry("first-page-only", "first", "", false)], Some("last")),
            last,
        ], Some(directory.path())).await;
        assert_eq!(fixture.client.resolve_path("/target").await.unwrap(), "target");
        assert!(cache.file("removed").unwrap().is_none(), "A stale later page must not undo Trash");
        assert_eq!(cache.file("renamed").unwrap().unwrap().name, "renamed-current");
        assert!(cache.file("target").unwrap().is_none(), "The whole segment must retain its initial cache generation");
        assert!(cache.folder("").unwrap().is_none(), "A stale response cannot establish complete inventory");
        fixture.assert_done();
    }
}

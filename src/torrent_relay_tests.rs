use super::*;
use std::sync::{Mutex, atomic::{AtomicBool, Ordering}};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Fixture {
    client: Client,
    files: Arc<Mutex<Vec<Value>>>,
    mutations: Arc<Mutex<Vec<String>>>,
    lost: Arc<AtomicBool>,
    vanish: Arc<AtomicBool>,
    instant: Arc<AtomicBool>,
    defer_trash: Arc<AtomicBool>,
    payloads: Arc<Mutex<Vec<Vec<u8>>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture { fn drop(&mut self) { self.task.abort(); } }
impl Fixture {
    async fn new() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let files = Arc::new(Mutex::new(Vec::<Value>::new()));
        let mutations = Arc::new(Mutex::new(Vec::new()));
        let lost = Arc::new(AtomicBool::new(false));
        let vanish = Arc::new(AtomicBool::new(false));
        let vanishes = vanish.clone();
        let instant = Arc::new(AtomicBool::new(true));
        let defer_trash = Arc::new(AtomicBool::new(false));
        let deferred = defer_trash.clone();
        let payloads = Arc::new(Mutex::new(Vec::new()));
        let (items, writes, lose_reply, instant_copy, received, endpoint) = (files.clone(), mutations.clone(), lost.clone(), instant.clone(), payloads.clone(), base.clone());
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let (items, writes, lose_reply, instant, received, endpoint) = (items.clone(), writes.clone(), lose_reply.clone(), instant_copy.clone(), received.clone(), endpoint.clone());
                let deferred = deferred.clone();
                let vanishes = vanishes.clone();
                tokio::spawn(async move {
                    let mut request = Vec::new();
                    let end;
                    loop {
                        if let Some(index) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") { end = index + 4; break; }
                        let mut buffer = [0u8; 4096]; let size = socket.read(&mut buffer).await.unwrap();
                        if size == 0 { return; } request.extend_from_slice(&buffer[..size]);
                    }
                    let header = String::from_utf8_lossy(&request[..end]).to_string();
                    let mut first = header.lines().next().unwrap().split_whitespace();
                    let method = first.next().unwrap(); let target = first.next().unwrap();
                    let url = url::Url::parse(&format!("http://fixture{target}")).unwrap();
                    let length = header.lines().find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length: ").and_then(|value| value.parse::<usize>().ok())).unwrap_or(0);
                    while request.len() < end + length { let mut buffer = [0;4096]; let size = socket.read(&mut buffer).await.unwrap(); if size == 0 { return; } request.extend_from_slice(&buffer[..size]); }
                    let body: Value = serde_json::from_slice(&request[end..end+length]).unwrap_or(Value::Null);
                    if url.path().starts_with("/object/") {
                        assert!(!header.contains("fixture-relay-token"));
                        assert!(header.to_ascii_lowercase().contains("authorization: oss fixture-key:"));
                    } else { assert!(header.to_ascii_lowercase().contains("authorization: bearer fixture-relay-token")); }
                    let mut status = 200;
                    let response = {
                        let mut items = items.lock().unwrap();
                        if method == "PUT" && url.path().starts_with("/object/") {
                            received.lock().unwrap().push(request[end..end+length].to_vec());
                            let id = url.path().rsplit('/').next().unwrap();
                            let item = items.iter_mut().find(|item| item["id"] == id).unwrap();
                            item["phase"] = "PHASE_TYPE_COMPLETE".into();
                            item["hash"] = item["declared_hash"].clone();
                            json!({})
                        } else if url.path() == "/v1/user/me" { json!({"sub":"account-a", "name":"RAM test"}) }
                        else if method == "GET" && url.path() == "/drive/v1/files" {
                            let parent = url.query_pairs().find(|(name,_)| name == "parent_id").unwrap().1.to_string();
                            let filters = url.query_pairs().find(|(name,_)| name == "filters").unwrap().1.to_string();
                            let values: Vec<_> = items.iter().filter(|item| item["parent_id"] == parent && item["trashed"] != true && (!filters.contains("PHASE_TYPE_COMPLETE") || item["phase"] == "PHASE_TYPE_COMPLETE")).cloned().collect();
                            json!({"files":values})
                        } else if method == "GET" && url.path().starts_with("/drive/v1/files/") {
                            let id = url.path().rsplit('/').next().unwrap();
                            match items.iter().find(|item| item["id"] == id) {
                                Some(file) if file["trashed"] == true => {
                                    status=400; json!({"error":"file_in_recycle_bin","error_code":9})
                                }
                                Some(file) => file.clone(),
                                None => { status=404; json!({"error":"file_not_found"}) }
                            }
                        } else if method == "POST" && url.path() == "/drive/v1/files:batchTrash" {
                            writes.lock().unwrap().push("trash".into());
                            if !deferred.load(Ordering::SeqCst) {
                                for item in items.iter_mut() { if body["ids"].as_array().unwrap().contains(&item["id"]) { item["trashed"] = true.into(); } }
                            }
                            json!({})
                        } else if method == "POST" && url.path() == "/drive/v1/files" {
                            // The request never landed: no file, no record of it.
                            if body["kind"] == "drive#file" && vanishes.swap(false, Ordering::SeqCst) { return; }
                            writes.lock().unwrap().push(body["name"].as_str().unwrap().into());
                            let id = format!("remote-{}", items.len());
                            let complete = body["kind"] == "drive#folder" || instant.load(Ordering::SeqCst);
                            let file = json!({"id":id,"parent_id":body["parent_id"],"kind":body["kind"],"name":body["name"],"size":body["size"].as_u64().unwrap_or(0).to_string(),
                                "hash":if complete {body["hash"].clone()} else {json!("")},"declared_hash":body["hash"],"trashed":false,"phase":if complete {"PHASE_TYPE_COMPLETE"} else {"PHASE_TYPE_RUNNING"}});
                            items.push(file.clone());
                            if body["kind"] == "drive#file" && lose_reply.swap(false, Ordering::SeqCst) { return; }
                            if complete { json!({"file":file}) } else {
                                json!({"file":file,"resumable":{"params":{"access_key_id":"fixture-key","access_key_secret":"fixture-secret","security_token":"fixture-oss-token","bucket":"127","endpoint":endpoint,"key":format!("object/{id}")}}})
                            }
                        } else { panic!("unexpected fixture route {method} {}", url.path()) }
                    };
                    let bytes = serde_json::to_vec(&response).unwrap();
                    let header = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", bytes.len());
                    let _ = socket.write_all(header.as_bytes()).await; let _ = socket.write_all(&bytes).await;
                });
            }
        });
        let client = Client::builder().personal_access_token("fixture-relay-token").api_base_url(&base).auth_base_url(base).build().unwrap();
        Self { client, files, mutations, lost, vanish, instant, defer_trash, payloads, task }
    }
}
fn request(root: &Path) -> Request {
    let ram = root.join("ram"); std::fs::create_dir_all(ram.join("Example/sub")).unwrap();
    std::fs::write(ram.join("Example/sub/one.txt"), b"synthetic RAM contents").unwrap();
    Request { version:1, account_id:"account-a".into(), job_id:"unique-torrent-id".into(), parent_id:"destination".into(), root_name:"Torrent-unique".into(), ram_root:ram,
        checkpoint_dir:root.join("receipts"), files:vec![Source { index:1,path:"Example/sub/one.txt".into(),size:22 }],reconcile_only:false,cleanup_padding:false,parent_pid:None }
}
fn output() -> (Emit, Arc<Mutex<Vec<Value>>>) {
    let values = Arc::new(Mutex::new(Vec::new())); let sink=values.clone();
    (Arc::new(move |event| sink.lock().unwrap().push(event)), values)
}

async fn padding_request(fixture: &Fixture, root: &Path, count: u32) -> Request {
    let mut request = request(root);
    run(&fixture.client, request.clone(), output().0).await.unwrap();
    let real = receipt(&request, &request.files[0]).unwrap();
    request.files = (2..count + 2).map(|index| Source { index, path: format!("Example/sub/padding-{index}"), size: 4096 }).collect();
    for source in &request.files {
        let id = format!("padding-{}", source.index);
        let name = source.path.rsplit('/').next().unwrap();
        let saved = Receipt { path: source.path.clone(), size: source.size, gcid: format!("padding-hash-{}", source.index),
            parent_id: real.parent_id.clone(), remote_id: Some(id.clone()), completed: true, ..Default::default() };
        write_atomic(&receipt_path(&request, source.index), &saved).unwrap();
        fixture.files.lock().unwrap().push(json!({"id":id,"parent_id":saved.parent_id,"kind":"drive#file",
            "name":name,"size":source.size.to_string(),"hash":saved.gcid,"trashed":false,"phase":"PHASE_TYPE_COMPLETE"}));
    }
    // A cleanup must work with no payload directory at all.
    std::fs::remove_dir_all(&request.ram_root).unwrap();
    request.cleanup_padding = true; request.reconcile_only = true;
    fixture.mutations.lock().unwrap().clear();
    request
}

#[tokio::test]
async fn padding_cleanup_batches_only_owned_ids_and_replays_without_payload_or_retrash() {
    let fixture = Fixture::new().await; let root = tempfile::tempdir().unwrap();
    let request = padding_request(&fixture, root.path(), 205).await;
    let real_before = std::fs::read(receipt_path(&request, 1)).unwrap();
    let (emit, events) = output();
    run(&fixture.client, request.clone(), emit.clone()).await.unwrap();
    assert_eq!(fixture.mutations.lock().unwrap().len(), 3);
    let files = fixture.files.lock().unwrap();
    assert_eq!(files.iter().filter(|f| f["trashed"] == true).count(), 205);
    assert_eq!(files.iter().filter(|f| f["kind"] == "drive#file" && f["trashed"] == false).count(), 1);
    drop(files);
    assert_eq!(std::fs::read(receipt_path(&request, 1)).unwrap(), real_before);
    assert!(request.files.iter().all(|s| receipt(&request, s).unwrap().padding_trashed));
    assert_eq!(events.lock().unwrap().iter().filter_map(|e| e["removed"].as_array()).map(Vec::len).sum::<usize>(), 205);
    // A user may restore a successfully cleaned file. A saved cleanup receipt
    // must not trash that restored item again after restarting the app.
    fixture.files.lock().unwrap().last_mut().unwrap()["trashed"] = false.into();
    run(&fixture.client, request, emit).await.unwrap();
    assert_eq!(fixture.mutations.lock().unwrap().len(), 3);
    assert_eq!(fixture.files.lock().unwrap().last().unwrap()["trashed"], false);
}

#[tokio::test]
async fn padding_cleanup_reconciles_lost_trash_reply_and_missing_ids() {
    let fixture = Fixture::new().await; let root = tempfile::tempdir().unwrap();
    let request = padding_request(&fixture, root.path(), 2).await;
    // Server accepted Trash, then the app exited before writing acknowledgements.
    fixture.files.lock().unwrap().iter_mut().find(|f| f["id"] == "padding-2").unwrap()["trashed"] = true.into();
    fixture.files.lock().unwrap().retain(|f| f["id"] != "padding-3");
    run(&fixture.client, request.clone(), output().0).await.unwrap();
    assert!(fixture.mutations.lock().unwrap().is_empty());
    assert!(request.files.iter().all(|s| receipt(&request, s).unwrap().padding_trashed));
}

#[tokio::test]
async fn padding_cleanup_waits_for_async_trash_and_retries_stalled_intents() {
    let fixture = Fixture::new().await; let root = tempfile::tempdir().unwrap();
    let request = padding_request(&fixture, root.path(), 2).await;
    fixture.defer_trash.store(true, Ordering::SeqCst);
    assert!(run(&fixture.client, request.clone(), output().0).await.unwrap_err().to_string().contains("Waiting for PikPak"));
    assert!(request.files.iter().all(|s| !receipt(&request, s).unwrap().padding_trashed));
    assert_eq!(fixture.mutations.lock().unwrap().len(), 1);
    // Relaunch during provider processing: poll the original IDs without
    // resending the same asynchronous mutation or claiming success early.
    assert!(run(&fixture.client, request.clone(), output().0).await.is_err());
    assert_eq!(fixture.mutations.lock().unwrap().len(), 1);
    // A provider task that stalled is retried after the bounded grace period.
    for source in &request.files {
        let mut saved = receipt(&request, source).unwrap(); saved.padding_trash_requested_at = Some(1);
        write_atomic(&receipt_path(&request, source.index), &saved).unwrap();
    }
    fixture.defer_trash.store(false, Ordering::SeqCst);
    run(&fixture.client, request.clone(), output().0).await.unwrap();
    assert_eq!(fixture.mutations.lock().unwrap().len(), 2);
    assert!(request.files.iter().all(|s| receipt(&request, s).unwrap().padding_trashed));
}

#[tokio::test]
async fn padding_cleanup_keeps_changed_foreign_and_ambiguous_files() {
    let fixture = Fixture::new().await; let root = tempfile::tempdir().unwrap();
    let request = padding_request(&fixture, root.path(), 6).await;
    for (offset, (key, value)) in [("size",json!("1")), ("hash",json!("different")),
        ("name",json!("renamed")), ("parent_id",json!("moved")), ("kind",json!("drive#folder"))].into_iter().enumerate() {
        fixture.files.lock().unwrap().iter_mut().find(|f| f["id"] == format!("padding-{}", offset + 2)).unwrap()[key] = value;
    }
    assert!(run(&fixture.client, request.clone(), output().0).await.is_err());
    assert_eq!(fixture.files.lock().unwrap().iter().filter(|f| f["trashed"] == true).count(), 1);
    assert!(receipt(&request, request.files.last().unwrap()).unwrap().padding_trashed);
    let before = fixture.mutations.lock().unwrap().len();
    let mut wrong = request.clone(); wrong.account_id = "wrong-account".into();
    assert!(run(&fixture.client, wrong, output().0).await.is_err());
    let mut wrong = request.clone(); wrong.job_id = "wrong-torrent".into();
    assert!(run(&fixture.client, wrong, output().0).await.is_err());
    assert_eq!(fixture.mutations.lock().unwrap().len(), before);

    let fixture = Fixture::new().await; let root = tempfile::tempdir().unwrap();
    let request = padding_request(&fixture, root.path(), 1).await;
    let source = &request.files[0]; let mut saved = receipt(&request, source).unwrap();
    saved.remote_id = None; saved.previous_ids = Some(vec![]);
    write_atomic(&receipt_path(&request, source.index), &saved).unwrap();
    let mut duplicate = fixture.files.lock().unwrap().last().unwrap().clone(); duplicate["id"] = "unowned-duplicate".into();
    fixture.files.lock().unwrap().push(duplicate);
    assert!(run(&fixture.client, request.clone(), output().0).await.is_err());
    assert!(fixture.mutations.lock().unwrap().is_empty());
    // If the pre-upload snapshot proves the other ID predated this upload,
    // the unique newly-created item can be reconciled and cleaned safely.
    saved.previous_ids = Some(vec!["unowned-duplicate".into()]);
    write_atomic(&receipt_path(&request, source.index), &saved).unwrap();
    run(&fixture.client, request, output().0).await.unwrap();
    assert_eq!(fixture.files.lock().unwrap().last().unwrap()["trashed"], false);
}

#[tokio::test]
async fn finished_receipts_survive_ram_loss_and_bind_account_destination() {
    let fixture = Fixture::new().await; let temp = tempfile::tempdir().unwrap(); let request=request(temp.path());
    let (emit,events)=output();
    run(&fixture.client,request.clone(),emit.clone()).await.unwrap();
    assert!(events.lock().unwrap().iter().any(|event| event["event"] == "committed"));
    let mutations = fixture.mutations.lock().unwrap().clone();
    assert_eq!(mutations, ["Torrent-unique","Example","sub","one.txt"]);
    std::fs::remove_dir_all(&request.ram_root).unwrap();
    run(&fixture.client, request.clone(), emit.clone()).await.unwrap();
    assert_eq!(*fixture.mutations.lock().unwrap(),mutations, "completed file must not need RAM or upload again");
    let mut wrong=request.clone();wrong.account_id="account-b".into();
    assert!(run(&fixture.client,wrong,emit.clone()).await.unwrap_err().to_string().contains("original PikPak account"));
    let mut wrong=request.clone();wrong.parent_id="other-folder".into();
    assert!(run(&fixture.client,wrong,emit).await.is_err());
    assert_eq!(*fixture.mutations.lock().unwrap(),mutations);
    let journal=std::fs::read_to_string(receipt_path(&request,1)).unwrap();
    assert!(!journal.contains("token") && !journal.contains("access_key") && !journal.contains("synthetic RAM contents"));
}

#[tokio::test]
async fn lost_upload_response_is_adopted_without_a_second_file() {
    let fixture=Fixture::new().await;let temp=tempfile::tempdir().unwrap();let mut request=request(temp.path());
    fixture.lost.store(true,Ordering::SeqCst);let (emit,events)=output();
    assert!(run(&fixture.client,request.clone(),emit.clone()).await.is_err());
    let count=fixture.mutations.lock().unwrap().len();
    std::fs::remove_dir_all(&request.ram_root).unwrap();request.reconcile_only=true;
    run(&fixture.client,request,emit).await.unwrap();
    assert_eq!(fixture.mutations.lock().unwrap().len(),count);
    assert_eq!(fixture.files.lock().unwrap().iter().filter(|file| file["kind"] == "drive#file").count(),1);
    assert!(events.lock().unwrap().iter().any(|event|event["event"]=="committed"));
}

#[tokio::test]
async fn lost_response_for_an_incomplete_upload_is_adopted_without_a_second_file() {
    // PikPak lists a still-transferring placeholder with no content identity.
    // Recovery must still recognise it as the file whose reply was lost.
    let fixture=Fixture::new().await;fixture.instant.store(false,Ordering::SeqCst);
    let temp=tempfile::tempdir().unwrap();let request=request(temp.path());
    fixture.lost.store(true,Ordering::SeqCst);let (emit,events)=output();
    assert!(run(&fixture.client,request.clone(),emit.clone()).await.is_err());
    run(&fixture.client,request.clone(),emit).await.unwrap();
    assert!(events.lock().unwrap().iter().any(|event|event["event"]=="committed"));
    let files=fixture.files.lock().unwrap();
    assert_eq!(files.iter().filter(|file| file["kind"] == "drive#file" && file["trashed"] != true).count(),1,
        "the unfinished placeholder must be replaced, leaving exactly one live file");
}

#[tokio::test]
async fn an_upload_task_that_never_reached_pikpak_is_created_on_the_next_resume() {
    // Nothing appeared after the intent was recorded, so the create produced
    // nothing and there is no duplicate to risk by trying once more.
    let fixture=Fixture::new().await;fixture.instant.store(false,Ordering::SeqCst);
    let temp=tempfile::tempdir().unwrap();let request=request(temp.path());
    fixture.vanish.store(true,Ordering::SeqCst);let (emit,events)=output();
    assert!(run(&fixture.client,request.clone(),emit.clone()).await.is_err());
    assert_eq!(fixture.files.lock().unwrap().iter().filter(|file| file["kind"] == "drive#file").count(),0,
        "the destination must hold nothing for this file");
    run(&fixture.client,request.clone(),emit).await.unwrap();
    assert!(events.lock().unwrap().iter().any(|event|event["event"]=="committed"));
    assert_eq!(fixture.files.lock().unwrap().iter().filter(|file| file["kind"] == "drive#file" && file["trashed"] != true).count(),1,
        "resuming must upload it exactly once");
}

#[tokio::test]
async fn ambiguous_recovery_reports_why_no_single_candidate_was_found() {
    // Something did appear, so the create is not provably dead. Stopping is
    // right, but the operator still needs to know which way it was ambiguous.
    let fixture=Fixture::new().await;fixture.instant.store(false,Ordering::SeqCst);
    let temp=tempfile::tempdir().unwrap();let request=request(temp.path());
    fixture.lost.store(true,Ordering::SeqCst);let (emit,_)=output();
    assert!(run(&fixture.client,request.clone(),emit.clone()).await.is_err());

    // A placeholder of the wrong size must not be adopted as this file.
    fixture.files.lock().unwrap().iter_mut()
        .find(|file| file["name"] == "one.txt").unwrap()["size"]="999".into();
    let mismatched=run(&fixture.client,request.clone(),emit.clone()).await.unwrap_err().to_string();
    assert!(mismatched.contains("0 candidates"),"{mismatched}");
    assert!(mismatched.contains("1 named alike"),"{mismatched}");
    assert!(mismatched.contains("1 sized differently"),"{mismatched}");

    // Two indistinguishable placeholders: adopting either could be wrong.
    {
        let mut files=fixture.files.lock().unwrap();
        let mut original=files.iter_mut().find(|file| file["name"] == "one.txt").unwrap().clone();
        original["size"]="22".into();
        let mut twin=original.clone(); twin["id"]="twin".into();
        files.retain(|file| file["name"] != "one.txt");
        files.push(original); files.push(twin);
    }
    let ambiguous=run(&fixture.client,request,emit).await.unwrap_err().to_string();
    assert!(ambiguous.contains("2 candidates"),"{ambiguous}");
}

#[tokio::test]
async fn incomplete_recovery_includes_unfinished_files_and_never_reuses_changed_ram() {
    let fixture=Fixture::new().await;let temp=tempfile::tempdir().unwrap();let mut request=request(temp.path());
    let (emit,_)=output();run(&fixture.client,request.clone(),emit.clone()).await.unwrap();
    let mut saved=receipt(&request,&request.files[0]).unwrap();saved.completed=false;saved.remote_id=None;
    write_atomic(&receipt_path(&request,1),&saved).unwrap();
    fixture.files.lock().unwrap().last_mut().unwrap()["phase"]="PHASE_TYPE_RUNNING".into();
    request.reconcile_only=true;
    run(&fixture.client,request.clone(),emit.clone()).await.unwrap();
    assert!(receipt(&request,&request.files[0]).unwrap().remote_id.is_some(),"recovery listing must include incomplete placeholders");
    std::fs::write(request.ram_root.join(&request.files[0].path), b"DIFFERENT RAM CONTENTS").unwrap();
    request.reconcile_only=false;let writes=fixture.mutations.lock().unwrap().len();
    let error=run(&fixture.client,request.clone(),emit.clone()).await.unwrap_err().to_string();
    assert!(error.contains("differs from its saved content"),"{error}");
    assert_eq!(fixture.mutations.lock().unwrap().len(),writes,"changed content must not trash or create anything");
    std::fs::write(request.ram_root.join(&request.files[0].path), b"synthetic RAM contents").unwrap();
    run(&fixture.client,request.clone(),emit).await.unwrap();
    assert!(receipt(&request,&request.files[0]).unwrap().completed);
    assert_eq!(fixture.files.lock().unwrap().iter().filter(|f| f["kind"] == "drive#file" && f["trashed"] != true).count(),1);
}

#[tokio::test]
async fn failed_account_or_unsafe_source_causes_no_cloud_mutation() {
    let fixture=Fixture::new().await;let temp=tempfile::tempdir().unwrap();let request=request(temp.path());let (emit,_)=output();
    for name in ["../outside","/absolute","Example/../bad","Example//empty","Example\\escape"] {
        let mut wrong=request.clone();wrong.files[0].path=name.into();assert!(run(&fixture.client,wrong,emit.clone()).await.is_err());
    }
    #[cfg(unix)] {
        let path=request.ram_root.join(&request.files[0].path);std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/etc/hosts",path).unwrap();
        assert!(run(&fixture.client,request,emit).await.is_err());
    }
    assert!(fixture.mutations.lock().unwrap().is_empty());
}

#[tokio::test]
async fn actual_oss_upload_sends_source_bytes_and_does_not_persist_temporary_credentials() {
    let fixture=Fixture::new().await;fixture.instant.store(false,Ordering::SeqCst);
    let temp=tempfile::tempdir().unwrap();let request=request(temp.path());let (emit,events)=output();
    run(&fixture.client,request.clone(),emit.clone()).await.unwrap();
    assert_eq!(*fixture.payloads.lock().unwrap(),vec![b"synthetic RAM contents".to_vec()]);
    assert!(events.lock().unwrap().iter().any(|event| event["event"] == "upload_progress" && event["bytes"] == 22));
    let mut saved=receipt(&request,&request.files[0]).unwrap();saved.completed=false;
    write_atomic(&receipt_path(&request,1),&saved).unwrap();
    std::fs::remove_dir_all(&request.ram_root).unwrap();
    run(&fixture.client,request.clone(),emit).await.unwrap();
    assert_eq!(fixture.payloads.lock().unwrap().len(),1,"response lost after OSS complete must not resend the file");
    let journal=std::fs::read_to_string(receipt_path(&request,1)).unwrap();
    assert!(!journal.contains("fixture-key") && !journal.contains("fixture-secret") && !journal.contains("fixture-oss-token"));
}

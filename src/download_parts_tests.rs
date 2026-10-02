use super::*;
use std::sync::atomic::Ordering;
#[path = "download_range_fixture.rs"]
mod fixture;

fn progress() -> DownloadProgressContext<'static> {
    DownloadProgressContext::new(false, "range-fixture", "generated.bin")
}
fn assert_file(part: &Path, revision: usize) {
    use std::io::Read;
    let mut file = std::fs::File::open(part).unwrap();
    let mut offset = 0;
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer).unwrap();
        if count == 0 {
            break;
        }
        assert!(buffer[..count]
            .iter()
            .enumerate()
            .all(|(index, value)| *value == fixture::byte(offset + index as u64, revision)));
        offset += count as u64;
    }
    assert_eq!(offset, fixture::SIZE);
}

#[tokio::test]
async fn new_process_resumes_a_full_length_sparse_file_without_trusting_holes() {
    use std::io::{Seek, Write};
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let mut state =
        serde_json::to_value(State::new(fixture.size, "\"fixture-1\"".into(), 0)).unwrap();
    for piece in state["pieces"].as_array_mut().unwrap().iter_mut().skip(1) {
        piece["received"] = (16u64 << 20).into();
        piece["complete"] = true.into();
    }
    let state: State = serde_json::from_value(state).unwrap();
    let mut data = std::fs::File::create(data_path(&part)).unwrap();
    data.set_len(fixture.size).unwrap();
    data.seek(SeekFrom::Start(16 << 20)).unwrap();
    for offset in (16 << 20..fixture.size).step_by(65536) {
        data.write_all(&fixture::bytes(offset, 65536, 1)).unwrap();
    }
    data.sync_all().unwrap();
    drop(data);
    save(&part, "range-fixture", &state).unwrap();
    assert_eq!(
        saved_bytes(&part, "range-fixture", fixture.size),
        Some(48 << 20)
    );
    assert_eq!(
        std::fs::metadata(data_path(&part)).unwrap().len(),
        fixture.size
    );
    let path = part.clone();
    let url = fixture.url.clone();
    let child = tokio::task::spawn_blocking(move || {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "download_transport::parts::tests::resume_in_child",
            ])
            .env("MYCLOUD_RANGE_RESTART_PART", path)
            .env("MYCLOUD_RANGE_RESTART_URL", url)
            .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
            .output()
            .unwrap()
    })
    .await
    .unwrap();
    assert!(
        child.status.success(),
        "{}",
        String::from_utf8_lossy(&child.stderr)
    );
    assert_file(&part, 1);
    assert!(!exists(&part));
    let requests = fixture.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        2,
        "Restart downloaded previously completed ranges"
    );
    assert!(requests
        .iter()
        .any(|request| request.start == 0 && request.end == (16 << 20) - 1));
}

#[tokio::test]
async fn resume_in_child() {
    let Some(part) = std::env::var_os("MYCLOUD_RANGE_RESTART_PART") else {
        return;
    };
    let url = std::env::var("MYCLOUD_RANGE_RESTART_URL").unwrap();
    super::super::attempt(
        &reqwest::Client::new(),
        &url,
        fixture::SIZE,
        Path::new(&part),
        false,
        progress(),
        None,
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap();
}

#[test]
fn pause_resume_changed_original_and_cancel_are_isolated_in_children() {
    for mode in ["resume", "changed", "cancel"] {
        let directory = tempfile::tempdir().unwrap();
        let control = directory.path().join("control.json");
        std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "download_transport::parts::tests::pause_in_child",
            ])
            .env("MYCLOUD_RANGE_PAUSE_MODE", mode)
            .env("MYCLOUDDRIVER_TRANSFER_CONTROL", &control)
            .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
            .output()
            .unwrap();
        assert!(
            child.status.success(),
            "{mode}: {}\n{}",
            String::from_utf8_lossy(&child.stdout),
            String::from_utf8_lossy(&child.stderr)
        );
    }
}

#[tokio::test]
async fn pause_in_child() {
    let Ok(mode) = std::env::var("MYCLOUD_RANGE_PAUSE_MODE") else {
        return;
    };
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    fixture.hold_first.store(true, Ordering::Release);
    // Establish real flowing evidence before stalling the first piece. The
    // controller must not infer spare bandwidth from an already stopped body.
    fixture.chunk_delay_millis.store(50, Ordering::Release);
    fixture.hold_after_bytes.store(12 << 20, Ordering::Release);
    let directory = tempfile::tempdir().unwrap();
    let part = directory.path().join("generated.part");
    let control = PathBuf::from(std::env::var_os("MYCLOUDDRIVER_TRANSFER_CONTROL").unwrap());
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let progress = progress();
    let action = if mode == "cancel" { "cancel" } else { "pause" };
    let pause = async {
        tokio::time::timeout(Duration::from_secs(25), async {
            while progress.transferred_bytes() < 20 << 20 {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("Parallel range never started beside the stalled first piece");
        std::fs::write(
            &control,
            serde_json::to_vec(&serde_json::json!({"actions":{"range-fixture":action}})).unwrap(),
        )
        .unwrap();
    };
    let download = super::super::attempt(
        &http,
        &fixture.url,
        fixture.size,
        &part,
        false,
        progress.clone(),
        Some("https://mypikpak.com/"),
    );
    let (result, _) = tokio::join!(download, pause);
    let failure = result.err().unwrap().into_inner();
    assert!(fixture.peak.load(Ordering::Acquire) >= 2);
    if mode == "cancel" {
        assert!(failure.is::<transfer_control::Cancelled>());
        assert!(!exists(&part));
        assert!(!part.exists());
        return;
    }
    assert!(failure.is::<transfer_control::Paused>());
    let retained = load(&part, "range-fixture", fixture.size)
        .unwrap()
        .unwrap()
        .ranges;
    assert!(retained.received() > 16 << 20 && retained.received() < fixture.size);
    assert!(retained.prefix() < retained.received());
    assert!(
        !part.exists(),
        "Sparse data became a legacy contiguous prefix"
    );
    fixture.hold_first.store(false, Ordering::Release);
    fixture.chunk_delay_millis.store(0, Ordering::Release);
    if mode == "changed" {
        fixture.revision.store(2, Ordering::Release);
    }
    std::fs::write(&control, br#"{"actions":{}}"#).unwrap();
    tokio::time::sleep(Duration::from_millis(120)).await;
    let before = progress.transferred_bytes();
    super::super::attempt(
        &http,
        &fixture.url,
        fixture.size,
        &part,
        false,
        progress.clone(),
        Some("https://mypikpak.com/"),
    )
    .await
    .map_err(DlError::into_inner)
    .unwrap();
    assert_file(&part, if mode == "changed" { 2 } else { 1 });
    assert!(!exists(&part));
    if mode == "resume" {
        assert!(progress.transferred_bytes() - before <= fixture.size - retained.received() + 4);
    }
    assert!(fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .all(|request| request.referer));
}

#[tokio::test]
async fn ignored_or_malformed_ranges_fall_back_to_validated_sequential_download() {
    for mode in [1, 2, 3] {
        let fixture = fixture::Fixture::new(fixture::SIZE).await;
        fixture.mode.store(mode, Ordering::Release);
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join("generated.part");
        super::super::attempt(
            &reqwest::Client::new(),
            &fixture.url,
            fixture.size,
            &part,
            false,
            progress(),
            None,
        )
        .await
        .map_err(DlError::into_inner)
        .unwrap();
        assert_file(&part, 1);
        assert!(!exists(&part));
        assert!(fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|request| !request.ranged));
    }
}

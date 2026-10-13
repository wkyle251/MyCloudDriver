use super::*;
#[path = "download_range_fixture.rs"]
mod fixture;

fn client(fixture: &fixture::Fixture) -> Client {
    Client::builder()
        .refresh_token("fixture")
        .device_id("fixture")
        .api_base_url(&fixture.base)
        .auth_base_url(&fixture.base)
        .build()
        .unwrap()
}
fn item() -> CloudItem {
    CloudItem {
        revision: None,
        id: "file".into(),
        name: "generated.bin".into(),
        path: "/generated.bin".into(),
        is_folder: false,
        size: fixture::SIZE,
        ancestors: vec![],
    }
}
fn assert_input(input: &MemoryInput, revision: usize) {
    let data: &[u8] = input.as_ref();
    assert_eq!(data.len() as u64, fixture::SIZE);
    assert!(data
        .iter()
        .enumerate()
        .all(|(offset, value)| *value == fixture::byte(offset as u64, revision)));
}

#[tokio::test]
async fn unsupported_or_changed_ranges_restart_in_a_fresh_ram_buffer() {
    for mode in [1, 2, 3] {
        let fixture = fixture::Fixture::new(fixture::SIZE).await;
        fixture.mode.store(mode, Ordering::Release);
        let fetches = Fetches::with_memory(8, 96 << 20);
        let cancel = AtomicBool::new(false);
        let input = download(&client(&fixture), &item(), &cancel, &fetches, |_, _| Ok(()))
            .await
            .unwrap();
        assert_input(&input, 1);
        assert!(fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|request| !request.ranged));
        drop(input);
        assert_eq!(fetches.memory.used(), 0);
    }
}

#[tokio::test]
async fn cancelling_paused_parallel_ram_releases_the_mapping() {
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    fixture.hold_first.store(true, Ordering::Release);
    let fetches = Fetches::with_memory(8, 96 << 20);
    let cancel = AtomicBool::new(false);
    let stop = async {
        tokio::time::timeout(Duration::from_secs(5), async {
            while fetches.received_bytes.load(Ordering::Acquire) == 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        fetches.control.set_paused(true);
        tokio::time::sleep(Duration::from_millis(100)).await;
        cancel.store(true, Ordering::Release);
    };
    let client = client(&fixture);
    let item = item();
    let (result, _) = tokio::join!(
        download(&client, &item, &cancel, &fetches, |_, _| Ok(())),
        stop
    );
    assert!(result.is_err());
    assert_eq!(fetches.memory.used(), 0);
    assert_eq!(fetches.active.load(Ordering::Acquire), 0);
}

#[tokio::test]
async fn parallel_ram_pause_retains_pieces_and_releases_connections() {
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    fixture.hold_first.store(true, Ordering::Release);
    let mut fetches = Fetches::with_memory(8, 96 << 20);
    // Fault recovery needs concurrent pieces independent of speed-controller trials.
    fetches.initial_range_connections = 2;
    let cancel = AtomicBool::new(false);
    let client = client(&fixture);
    let item = item();
    let pause = async {
        tokio::time::timeout(Duration::from_secs(15), async {
            // Fast loopback pieces can all finish within the UI's 250 ms
            // publication interval, then wait on the held first piece. Wait
            // for actual received bytes rather than stale presentation state.
            while fetches.received_bytes.load(Ordering::Acquire) < 20 << 20 {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        fetches.control.set_paused(true);
        tokio::time::sleep(Duration::from_millis(100)).await;
        let held = fetches.memory.used();
        assert_eq!(
            Network::for_url(&fixture.url).active(),
            0,
            "Paused ranges kept the shared sockets"
        );
        let progress = fetches.download_progress()["items"][0]["received"]
            .as_u64()
            .unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(fetches.memory.used(), held);
        assert_eq!(
            fetches.download_progress()["items"][0]["received"]
                .as_u64()
                .unwrap(),
            progress
        );
        fixture.hold_first.store(false, Ordering::Release);
        fetches.control.set_paused(false);
    };
    let (result, _) = tokio::join!(
        download(&client, &item, &cancel, &fetches, |_, _| Ok(())),
        pause
    );
    let input = result.unwrap();
    assert_input(&input, 1);
    assert!(fixture.peak.load(Ordering::Acquire) >= 2);
    assert!(
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|request| request.start > 0 && request.start < 16 << 20),
        "Resume did not continue the retained first piece"
    );
    assert_eq!(
        fixture
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request.start == 0 && request.end > 0)
            .count(),
        1
    );
    drop(input);
    assert_eq!(fetches.memory.used(), 0);
}

#[tokio::test]
async fn ram_retries_a_dropped_piece_without_refetching_completed_ranges() {
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    fixture.drop_first.store(true, Ordering::Release);
    let mut fetches = Fetches::with_memory(8, 96 << 20);
    // Fault recovery needs concurrent pieces independent of speed-controller trials.
    fetches.initial_range_connections = 2;
    let cancel = AtomicBool::new(false);
    let mut received = 0;
    let input = tokio::time::timeout(
        Duration::from_secs(20),
        download(&client(&fixture), &item(), &cancel, &fetches, |bytes, _| {
            received = bytes;
            Ok(())
        }),
    )
    .await
    .unwrap()
    .unwrap();
    assert_input(&input, 1);
    assert!(received <= fixture.size + 4);
    assert!(fixture
        .requests
        .lock()
        .unwrap()
        .iter()
        .any(|request| request.start > 0 && request.start < 16 << 20));
    drop(input);
    assert_eq!(fetches.memory.used(), 0);
}

#[test]
fn memory_wait_releases_sockets_in_an_isolated_process() {
    let child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "similarity::fetch::range_tests::memory_wait_child",
        ])
        .env("MYCLOUD_RANGE_MEMORY_CHILD", "1")
        .env_remove("MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS")
        .output()
        .unwrap();
    assert!(
        child.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&child.stdout),
        String::from_utf8_lossy(&child.stderr)
    );
    assert!(String::from_utf8_lossy(&child.stdout).contains("1 passed"));
}

#[tokio::test]
async fn memory_wait_child() {
    if std::env::var_os("MYCLOUD_RANGE_MEMORY_CHILD").is_none() {
        return;
    }
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    let fetches = Fetches::with_memory(8, 96 << 20);
    let cancel = AtomicBool::new(false);
    let held = fetches.memory.stream(64 << 20, &cancel).await.unwrap();
    held.grow(60 << 20, &cancel).await.unwrap();
    let network = Network::for_url(&fixture.url);
    let mut permits = Vec::new();
    for _ in 0..63 {
        permits.push(network.acquire().await.unwrap());
    }
    let release = async {
        tokio::time::timeout(Duration::from_secs(15), async {
            while fetches.memory.waiting.load(Ordering::Acquire) == 0
                || fetches.received_bytes.load(Ordering::Acquire) == 0
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let last = network.try_acquire().unwrap();
        assert!(
            last.is_some(),
            "A RAM waiter retained the last shared network connection"
        );
        drop(last);
        drop(permits);
        drop(held);
    };
    let client = client(&fixture);
    let item = item();
    let (result, _) = tokio::join!(
        download(&client, &item, &cancel, &fetches, |_, _| Ok(())),
        release
    );
    let input = result.unwrap();
    assert_input(&input, 1);
    drop(input);
    assert_eq!(fetches.memory.used(), 0);
}

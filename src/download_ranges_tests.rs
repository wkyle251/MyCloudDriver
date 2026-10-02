use super::*;
use std::sync::atomic::Ordering;
#[path = "download_range_fixture.rs"]
mod fixture;

#[tokio::test]
async fn rolling_measurements_add_real_channels_and_stop_preserves_verified_coverage() {
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    fixture.chunk_delay_millis.store(50, Ordering::Release);
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let network = Network::new(4, None);
    let state = State::new(fixture.size, "\"fixture-1\"".into(), 0);
    let mut transfer = Transfer::new(&http, &fixture.url, None, state, network.clone())
        .unwrap()
        .with_absolute_gain();
    let mut data = vec![0; fixture.size as usize];
    tokio::time::timeout(Duration::from_secs(15), async {
        while fixture.peak.load(Ordering::Acquire) < 2 {
            let chunk = transfer.next().await.unwrap().expect("Fixture finished without a trial");
            data[chunk.offset as usize..chunk.offset as usize + chunk.bytes.len()].copy_from_slice(&chunk.bytes);
            transfer.accept(&chunk);
        }
    }).await.expect("Stable live traffic never expanded beyond one channel");
    transfer.stop();
    let retained = transfer.state().received();
    assert!(retained > 0 && retained < fixture.size);
    let state = transfer.state().clone(); drop(transfer);
    fixture.chunk_delay_millis.store(0, Ordering::Release);
    let mut transfer = Transfer::new(&http, &fixture.url, None, state, network)
        .unwrap()
        .with_absolute_gain();
    let mut resumed = 0;
    while let Some(chunk) = transfer.next().await.unwrap() {
        resumed += chunk.bytes.len() as u64;
        data[chunk.offset as usize..chunk.offset as usize + chunk.bytes.len()].copy_from_slice(&chunk.bytes);
        transfer.accept(&chunk);
    }
    assert_eq!(retained + resumed, fixture.size);
    assert!(data.iter().enumerate().all(|(offset, byte)| *byte == fixture::byte(offset as u64, 1)));
}

#[tokio::test]
async fn malformed_ranges_changed_etags_and_service_errors_do_not_commit_data() {
    for mode in [2, 3, 4] {
        let fixture = fixture::Fixture::new(4 << 20).await;
        fixture.mode.store(mode, Ordering::Release);
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let network = Network::new(4, None);
        let etag = probe(&http, &fixture.url, fixture.size, None, &network)
            .await
            .unwrap()
            .unwrap();
        let mut transfer = Transfer::new(
            &http,
            &fixture.url,
            None,
            State::new(fixture.size, etag, 0),
            network.clone(),
        )
        .unwrap();
        let error = transfer
            .next()
            .await
            .err()
            .expect("Invalid original was accepted");
        assert_eq!(transfer.state().received(), 0);
        if mode == 4 {
            assert!(
                matches!(error, Error::Http(HttpFailure { status: 503, retry_after: Some(delay) }) if delay == Duration::from_secs(1))
            );
            assert!(network.try_acquire().unwrap().is_none());
        } else {
            assert!(matches!(error, Error::Sequential));
        }
        transfer.stop();
    }
    let fixture = fixture::Fixture::new(4 << 20).await;
    fixture.mode.store(1, Ordering::Release);
    assert!(probe(
        &reqwest::Client::new(),
        &fixture.url,
        fixture.size,
        None,
        &Network::new(4, None)
    )
    .await
    .unwrap()
    .is_none());
}

#[tokio::test]
async fn completed_ranges_survive_a_different_connection_dropping() {
    let fixture = fixture::Fixture::new(fixture::SIZE).await;
    fixture.drop_first.store(true, Ordering::Release);
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let network = Network::new(2, None);
    let state = State::new(fixture.size, "\"fixture-1\"".into(), 0);
    let mut transfer = Transfer::new(&http, &fixture.url, None, state, network.clone()).unwrap();
    // Force simultaneous pieces here to isolate recovery from controller timing.
    transfer.connections = Connections::with_initial(2, 2, Instant::now());
    let mut data = vec![0; fixture.size as usize];
    let error = loop {
        match transfer.next().await {
            Ok(Some(chunk)) => {
                data[chunk.offset as usize..chunk.offset as usize + chunk.bytes.len()]
                    .copy_from_slice(&chunk.bytes);
                transfer.accept(&chunk);
            }
            Ok(None) => panic!("Fixture should disconnect its first range"),
            Err(error) => break error,
        }
    };
    let error = anyhow::Error::new(error);
    assert!(crate::download_policy::retryable(&error), "{error:#}");
    transfer.stop();
    let retained = transfer.state().received();
    assert!(retained >= PIECE_SIZE && retained < fixture.size);
    let serialized = serde_json::to_vec(transfer.state()).unwrap();
    drop(transfer);
    let restored: State = serde_json::from_slice(&serialized).unwrap();
    let mut transfer = Transfer::new(&http, &fixture.url, None, restored, network).unwrap();
    let mut received_again = 0;
    while let Some(chunk) = transfer.next().await.unwrap() {
        data[chunk.offset as usize..chunk.offset as usize + chunk.bytes.len()]
            .copy_from_slice(&chunk.bytes);
        received_again += chunk.bytes.len() as u64;
        transfer.accept(&chunk);
    }
    assert!(transfer.state().complete());
    assert!(
        received_again <= fixture.size - retained + 4,
        "Completed pieces were fetched again"
    );
    assert!(data
        .iter()
        .enumerate()
        .all(|(offset, value)| *value == fixture::byte(offset as u64, 1)));
}

#[test]
fn corrupt_coverage_and_weak_validators_are_rejected() {
    let state = State::new(fixture::SIZE, "\"fixture\"".into(), 0);
    for replacement in [
        serde_json::json!(0),
        serde_json::json!(1),
        serde_json::json!(u64::MAX),
    ] {
        let mut encoded = serde_json::to_value(&state).unwrap();
        encoded["piece_size"] = replacement;
        assert!(!serde_json::from_value::<State>(encoded).unwrap().valid());
    }
    for etag in ["W/\"weak\"", "\"invalid\r\nheader\"", ""] {
        let mut state = state.clone();
        state.etag = etag.into();
        assert!(!state.valid());
    }
    let mut state = state.clone();
    state.pieces[0].received = PIECE_SIZE + 1;
    assert!(!state.valid());
}

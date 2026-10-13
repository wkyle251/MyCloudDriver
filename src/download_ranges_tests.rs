use super::*;
use std::sync::atomic::Ordering;
#[path = "download_range_fixture.rs"]
mod fixture;

#[tokio::test]
async fn early_full_response_fallback_fills_sparse_holes_without_replacing_saved_bytes() {
    for mode in [1, 5] {
        let remote = fixture::Fixture::new(fixture::SIZE).await;
        remote.mode.store(mode, Ordering::Release);
        let mut state = State::new(remote.size, "\"fixture-1\"".into(), 3 << 20);
        state.pieces[1].received = PIECE_SIZE; state.pieces[1].complete = true;
        state.pieces[2].received = 7 << 20;
        let covered = state.received();
        let mut data = vec![0; remote.size as usize];
        for (_, offset, bytes) in state.covered_ranges() {
            data[offset as usize..(offset + bytes) as usize].copy_from_slice(&fixture::bytes(offset, bytes as usize, 1));
        }
        let mut transfer = Transfer::new(&reqwest::Client::builder().no_proxy().build().unwrap(), &remote.url,
            None, state, Network::new(1, None)).unwrap().with_streaming_fallback();
        let (mut received, mut skipped) = (0, 0);
        while let Some(event) = transfer.next_event().await.unwrap() {
            match event {
                Event::Data(chunk) => {
                    received += chunk.bytes.len() as u64;
                    data[chunk.offset as usize..chunk.offset as usize + chunk.bytes.len()].copy_from_slice(&chunk.bytes);
                    transfer.accept(&chunk);
                },
                Event::Skipped(bytes) => skipped += bytes,
                Event::PieceEof(_) => {},
            }
        }
        assert!(transfer.state().complete()); assert_eq!(received, remote.size - covered);
        assert!(skipped >= PIECE_SIZE + (7 << 20));
        assert!(data.iter().enumerate().all(|(offset, byte)| *byte == fixture::byte(offset as u64, 1)));
    }
}

#[tokio::test]
async fn early_stream_fallback_rejects_changed_validators_and_malformed_ranges() {
    for mode in [2, 3] {
        let remote = fixture::Fixture::new(4 << 20).await; remote.mode.store(mode, Ordering::Release);
        let state = State::new(remote.size, "\"fixture-1\"".into(), 1 << 20);
        let mut transfer = Transfer::new(&reqwest::Client::builder().no_proxy().build().unwrap(), &remote.url,
            None, state.clone(), Network::new(1, None)).unwrap().with_streaming_fallback();
        assert!(matches!(transfer.next_event().await, Err(Error::Sequential)));
        assert_eq!(transfer.state(), &state, "Rejected replay cannot certify any bytes");
    }
}

#[tokio::test]
async fn slow_fallback_headers_survive_repeated_receive_control_ticks() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/generated", listener.local_addr().unwrap());
    let total = 1 << 20;
    let server = tokio::spawn(async move {
        for index in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let mut bytes = [0; 1024]; let count = socket.read(&mut bytes).await.unwrap();
                assert!(count > 0); request.extend_from_slice(&bytes[..count]);
            }
            if index == 0 {
                socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
            } else {
                assert!(String::from_utf8(request).unwrap().to_lowercase().contains("range: bytes=0-\r\n"));
                tokio::time::sleep(Duration::from_millis(350)).await;
                socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nETag: \"generated\"\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
                socket.write_all(&vec![19; total as usize]).await.unwrap();
            }
        }
    });
    let mut transfer = Transfer::new(&reqwest::Client::builder().no_proxy().build().unwrap(), &url, None,
        State::new(total, "\"generated\"".into(), 0), Network::new(1, None)).unwrap().with_streaming_fallback();
    let mut timeouts = 0;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match tokio::time::timeout(Duration::from_millis(50), transfer.next_event()).await {
                Err(_) => timeouts += 1,
                Ok(Ok(Some(Event::Data(chunk)))) => { assert!(chunk.bytes.iter().all(|byte| *byte == 19)); transfer.accept(&chunk); },
                Ok(Ok(Some(_))) => {},
                Ok(Ok(None)) => break,
                Ok(Err(error)) => panic!("Generated delayed fallback failed: {error}"),
            }
        }
    }).await.expect("Control ticks restarted a slow fallback request");
    server.await.unwrap(); assert!(timeouts >= 4); assert!(transfer.state().complete());
}

#[tokio::test]
async fn piece_replacements_at_the_sample_interval_do_not_hold_ranges_at_one_channel() {
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let network = Network::new(8, None);
    let mut transfer = Transfer::new(&http, "http://127.0.0.1:9/generated", None,
        State::new(1024 * PIECE_SIZE, "\"generated\"".into(), 0), network.clone())
        .unwrap().with_absolute_gain();
    let start = Instant::now();
    let mut next_piece = 0;
    // Every half second the old request reaches EOF and a queued piece is
    // immediately ready. Keep real permits/admission but leave the generated
    // request futures unpolled: logical time isolates the scheduler from TCP.
    for tick in 0..=40 {
        transfer.jobs.clear();
        for active in &mut transfer.active { *active = false; }
        if tick > 0 {
            transfer.state.pieces[next_piece].received = PIECE_SIZE;
            transfer.state.pieces[next_piece].complete = true;
            next_piece += 1;
            network.record(transfer.connections.limit as u64 * PIECE_SIZE);
        }
        transfer.schedule_at(start + Duration::from_millis(tick * 500)).unwrap();
        if transfer.connections.limit > 1 { return; }
    }
    panic!("Continuous queued piece replacements never expanded beyond one channel");
}

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
            let chunk = transfer
                .next()
                .await
                .unwrap()
                .expect("Fixture finished without a trial");
            data[chunk.offset as usize..chunk.offset as usize + chunk.bytes.len()]
                .copy_from_slice(&chunk.bytes);
            transfer.accept(&chunk);
        }
    })
    .await
    .expect("Stable live traffic never expanded beyond one channel");
    transfer.stop();
    let retained = transfer.state().received();
    assert!(retained > 0 && retained < fixture.size);
    let state = transfer.state().clone();
    drop(transfer);
    fixture.chunk_delay_millis.store(0, Ordering::Release);
    let mut transfer = Transfer::new(&http, &fixture.url, None, state, network)
        .unwrap()
        .with_absolute_gain();
    let mut resumed = 0;
    while let Some(chunk) = transfer.next().await.unwrap() {
        resumed += chunk.bytes.len() as u64;
        data[chunk.offset as usize..chunk.offset as usize + chunk.bytes.len()]
            .copy_from_slice(&chunk.bytes);
        transfer.accept(&chunk);
    }
    assert_eq!(retained + resumed, fixture.size);
    assert!(data
        .iter()
        .enumerate()
        .all(|(offset, byte)| *byte == fixture::byte(offset as u64, 1)));
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

#[test]
fn a_forgotten_piece_is_fetched_again_and_nothing_else_changes() {
    let mut state = State::new(40 << 20, "\"fixture\"".into(), 40 << 20);
    assert!(state.complete() && state.valid());
    state.forget_piece(1);
    assert!(state.valid() && !state.complete());
    assert_eq!(state.received(), 24 << 20);
    assert_eq!(state.prefix(), 16 << 20, "the contiguous prefix ends where the forgotten piece starts");
    assert!(state.piece_complete(0) && !state.piece_complete(1) && state.piece_complete(2));
    state.forget_piece(99);
    assert_eq!(state.received(), 24 << 20, "a piece that does not exist is ignored");
}

#[test]
fn a_piece_eof_cannot_certify_queued_or_missing_disk_bytes() {
    let mut state = State::new(2 * PIECE_SIZE, "\"fixture\"".into(), 0);
    assert!(state.accept_piece_eof(0).is_err());
    assert!(state.accept_piece_eof(99).is_err());
    let chunk = Chunk { index: 0, offset: 0, bytes: Bytes::from(vec![7; PIECE_SIZE as usize]) };
    state.accept_written(&chunk).unwrap();
    assert!(!state.piece_complete(0) && state.needs_eof_replay(0));
    state.accept_piece_eof(0).unwrap();
    assert!(state.piece_complete(0) && !state.needs_eof_replay(0));
    assert_eq!(state.received(), PIECE_SIZE);
    assert!(!state.complete());
    let mut restarted = state.clone();
    restarted.restart();
    assert_eq!(restarted, state, "An observed, written piece EOF must survive a restart without a replay");
}

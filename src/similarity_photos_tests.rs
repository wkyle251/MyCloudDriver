use super::*;

#[tokio::test]
async fn unknown_photos_start_together_without_claiming_the_entire_pool() {
    let budget = memory::Budget::new(12 << 30);
    let cancel = AtomicBool::new(false);
    let capacity = photos_initial_capacity(budget.limit()).unwrap();
    assert_eq!(capacity, 1536 << 20);
    let mut originals = Vec::new();
    for _ in 0..NATIVE_PREPARERS {
        originals.push(tokio::time::timeout(Duration::from_secs(1), budget.stream(capacity, &cancel))
            .await.expect("Free RAM must admit all eight Photos receive windows").unwrap());
    }
    assert_eq!(budget.used(), NATIVE_PREPARERS as u64 * memory::RECEIVE_WINDOW);
    assert!(budget.minimum_limit() < budget.limit());
    drop(originals);
    assert_eq!(budget.used(), 0);
    assert_eq!(budget.waiting.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn larger_photos_release_partial_claims_before_retrying() {
    let budget = memory::Budget::new(64 << 20);
    let cancel = AtomicBool::new(false);
    let initial = photos_initial_capacity(budget.limit()).unwrap();
    let first = budget.stream(initial, &cancel).await.unwrap();
    let peer = budget.stream(initial, &cancel).await.unwrap();
    first.grow(initial, &cancel).await.unwrap();
    peer.grow(initial, &cancel).await.unwrap();
    let larger = photos_retry_capacity(initial, initial + 1, budget.limit()).unwrap();
    drop(first);
    assert_eq!(budget.used(), initial);
    let retry = tokio::time::timeout(Duration::from_secs(1), budget.stream(larger, &cancel))
        .await.unwrap().unwrap();
    retry.grow(larger, &cancel).await.unwrap();
    assert_eq!(budget.used(), initial + larger);
    assert!(retry.grow(larger + 1, &cancel).await.unwrap_err().is::<memory::Limit>());
    drop((retry, peer));
    assert_eq!(budget.used(), 0);
    assert_eq!(budget.minimum_limit(), 0);
}

#[test]
fn photos_capacity_escalation_is_bounded_aligned_and_rejects_invalid_replies() {
    for limit in [1, 7, 8, 16_383, 16_384, 65_535, 64 << 20, 12 << 30, u64::MAX] {
        let page = if limit >= 16_384 { 16_384 } else { 1 };
        let maximum = limit / page * page;
        let mut capacity = photos_initial_capacity(limit).unwrap();
        assert!(capacity > 0 && capacity <= maximum);
        assert_eq!(capacity % page, 0);
        let mut attempts = 1;
        while capacity < maximum {
            let next = photos_retry_capacity(capacity, capacity + 1, limit).unwrap();
            assert!(next > capacity && next <= maximum);
            assert_eq!(next % page, 0);
            capacity = next; attempts += 1;
        }
        assert!(attempts <= 5, "Geometric retries must reach the full pool promptly");
        if maximum < u64::MAX {
            assert!(photos_retry_capacity(capacity, maximum + 1, limit).unwrap_err().is::<memory::Limit>());
        }
    }
    assert!(photos_initial_capacity(0).unwrap_err().is::<memory::Limit>());
    assert!(photos_retry_capacity(8 << 20, 8 << 20, 64 << 20).is_err());
    assert!(photos_retry_capacity(8 << 20, 0, 64 << 20).is_err());
    // A PhotoKit callback can reveal a much larger minimum than double.
    assert_eq!(photos_retry_capacity(8 << 20, (25 << 20) + 1, 64 << 20).unwrap(), (25 << 20) + 16_384);
    // Paused resource edits apply to future attempts, including a smaller pool.
    assert_eq!(photos_retry_capacity(8 << 20, 9 << 20, 12 << 20).unwrap(), 12 << 20);
}

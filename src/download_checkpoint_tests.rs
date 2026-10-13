use super::*;

#[test]
fn queued_payloads_may_pass_a_soft_checkpoint_but_never_the_byte_or_time_bound() {
    let now = Instant::now();
    let mut external = CheckpointSchedule::new(CheckpointPolicy::RELAXED, now);
    external.received(1 << 20, now);
    assert!(!external.must_save(now + Duration::from_secs(20)));
    assert!(external.must_save(now + Duration::from_secs(60)));
    external.saved(now + Duration::from_secs(60));
    external.received(512 << 20, now + Duration::from_secs(61));
    assert!(external.must_save(now + Duration::from_secs(61)));
    let internal = CheckpointSchedule::new(CheckpointPolicy::FREQUENT, now);
    assert!(internal.must_save(now + Duration::from_secs(1)));
}

#[test]
fn internal_and_unknown_destinations_keep_the_one_second_checkpoint() {
    for kind in [None, Some(""), Some("internal"), Some("something-else"), Some("EXTERNAL ")] {
        assert_eq!(CheckpointPolicy::for_destination(kind), CheckpointPolicy::FREQUENT, "{kind:?}");
    }
    assert_eq!(CheckpointPolicy::FREQUENT.interval, Duration::from_secs(1));
    assert_eq!(CheckpointPolicy::FREQUENT.unsaved_bytes, u64::MAX, "an internal disk is never asked to save sooner for bytes alone");
}

#[test]
fn external_disks_and_network_shares_save_progress_far_less_often() {
    for kind in ["external", "network"] {
        let policy = CheckpointPolicy::for_destination(Some(kind));
        assert_eq!(policy, CheckpointPolicy::RELAXED, "{kind}");
    }
    assert!(CheckpointPolicy::RELAXED.interval >= Duration::from_secs(15) && CheckpointPolicy::RELAXED.interval <= Duration::from_secs(30));
    assert_eq!(CheckpointPolicy::RELAXED.unsaved_bytes, 512 << 20);
}

#[test]
fn a_schedule_is_due_after_the_interval_or_enough_unsaved_bytes_whichever_comes_first() {
    let start = Instant::now();
    let mut schedule = CheckpointSchedule::new(CheckpointPolicy::RELAXED, start);
    assert_eq!(schedule.due_at(), start + Duration::from_secs(20));
    schedule.received(100 << 20, start + Duration::from_secs(1));
    schedule.received(100 << 20, start + Duration::from_secs(2));
    assert_eq!(schedule.due_at(), start + Duration::from_secs(20), "a modest amount of new data waits for the interval");
    schedule.received(400 << 20, start + Duration::from_secs(3));
    assert_eq!(schedule.due_at(), start + Duration::from_secs(3), "600 MiB unsaved is due at once");
    let saved_at = start + Duration::from_secs(4);
    schedule.saved(saved_at);
    assert_eq!(schedule.due_at(), saved_at + Duration::from_secs(20), "a save restarts the interval");
    schedule.received(100 << 20, saved_at + Duration::from_secs(1));
    assert_eq!(schedule.due_at(), saved_at + Duration::from_secs(20), "and the unsaved count");
}

#[test]
fn the_frequent_schedule_behaves_as_before() {
    let start = Instant::now();
    let mut schedule = CheckpointSchedule::new(CheckpointPolicy::FREQUENT, start);
    assert_eq!(schedule.due_at(), start + Duration::from_secs(1));
    schedule.received(u64::MAX / 2, start);
    schedule.received(u64::MAX / 2, start);
    assert_eq!(schedule.due_at(), start + Duration::from_secs(1), "bytes never advance an internal disk's schedule");
    schedule.saved(start + Duration::from_millis(1_500));
    assert_eq!(schedule.due_at(), start + Duration::from_millis(2_500));
}

#[test]
fn an_overdue_schedule_never_moves_later() {
    let start = Instant::now();
    let mut schedule = CheckpointSchedule::new(CheckpointPolicy::RELAXED, start);
    schedule.received(600 << 20, start + Duration::from_secs(5));
    schedule.received(1, start + Duration::from_secs(9));
    assert_eq!(schedule.due_at(), start + Duration::from_secs(5), "more data after it became due does not push the save back");
}

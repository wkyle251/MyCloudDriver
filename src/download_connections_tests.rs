use super::*;

const MIB: u64 = 1 << 20;

// Feed complete stable windows through real trial admission and settlement.
// Rates and half-second byte increments are exact, including the 1 MB/s edge.
fn measured_trial(initial: usize, baseline: u64, trial_rate: u64, absolute: bool) -> Connections {
    let start = Instant::now();
    let mut pool = Connections::with_initial(64, initial, start);
    if absolute {
        pool = pool.with_absolute_gain();
    }
    let mut bytes = 0;
    for tick in 0..80 {
        let probing = pool.probe.is_some();
        pool.active = pool.limit;
        if tick > 0 {
            let rate = if probing { trial_rate } else { baseline };
            bytes += rate / 2;
        }
        pool.observe(start + Duration::from_millis(tick * 500), bytes, || true);
        if probing && pool.probe.is_none() {
            return pool;
        }
    }
    panic!("The generated stable trial did not finish");
}

#[test]
fn absolute_gain_has_the_same_inclusive_cutoff_at_low_and_high_speeds() {
    for initial in [1, 4] {
        for baseline in [500_000, 5_000_000, 100_000_000, 5_000_000_000] {
            for gain in [999_998, 1_000_000, 1_000_002] {
                let pool = measured_trial(initial, baseline, baseline + gain, true);
                let accepted = gain >= 1_000_000;
                assert_eq!(
                    pool.proven_gain, accepted,
                    "initial={initial}, baseline={baseline}, gain={gain}"
                );
                assert_eq!(pool.limit > initial, accepted);
                assert_eq!(pool.plateau.is_some(), !accepted);
            }
        }
    }
}

#[test]
fn absolute_gain_rejects_small_gains_unchanged_rates_and_slowdowns() {
    for (baseline, trial_rate) in [
        (500_000, 800_000), // A 60% gain is still below 1 MB/s.
        (100_000_000, 100_500_000),
        (100_000_000, 100_000_000),
        (100_000_000, 95_000_000),
    ] {
        let pool = measured_trial(4, baseline, trial_rate, true);
        assert_eq!(pool.limit, 4);
        assert!(!pool.proven_gain);
        assert!(pool.plateau.is_some());
    }
}

#[test]
fn trial_outcomes_require_a_completed_measurement_and_are_consumed_once() {
    let mut accepted = measured_trial(1, 2_000_000, 4_000_000, true);
    assert_eq!(accepted.take_trial_outcome(), Some(TrialOutcome::Accepted(2)));
    assert_eq!(accepted.take_trial_outcome(), None);
    let mut rejected = measured_trial(1, 2_000_000, 2_000_000, true);
    assert_eq!(rejected.take_trial_outcome(), Some(TrialOutcome::Rejected));
    assert_eq!(rejected.take_trial_outcome(), None);
    let now = Instant::now();
    let mut cold = Connections::with_initial(8, 1, now).with_absolute_gain();
    cold.active = 1;
    cold.observe(now, 0, || true);
    cold.idle(now);
    assert_eq!(cold.take_trial_outcome(), None, "A cold start or cancelled probe is not measured gain");
}

#[test]
fn absolute_gain_keeps_growing_when_each_trial_adds_less_than_ten_percent() {
    let start = Instant::now();
    let mut pool = Connections::new(64, start).with_absolute_gain();
    let mut bytes = 0;
    for tick in 0..120 {
        pool.active = pool.limit;
        bytes += (1_000_000_000 + pool.active as u64 * 500_000) / 2;
        pool.observe(start + Duration::from_millis(tick * 500), bytes, || true);
    }
    assert_eq!(pool.limit, 64);
    assert!(pool.proven_gain);
    assert!(pool.probe.is_none());
}

#[test]
fn default_policy_keeps_relative_gain_for_other_transfer_scopes() {
    let pool = measured_trial(4, 100_000_000, 101_000_000, false);
    assert_eq!(pool.limit, 4);
    assert!(!pool.proven_gain);
    let pool = measured_trial(4, 1_000_000, 1_200_000, false);
    assert!(pool.limit > 4);
    assert!(pool.proven_gain);
}

#[test]
fn rolling_speed_updates_every_half_second_and_forgets_old_bytes() {
    let start = Instant::now();
    let mut rolling = Rolling::default();
    let mut bytes = 0;
    for tick in 0..=30 {
        if tick > 0 {
            bytes += if tick <= 10 { MIB / 2 } else { MIB };
        }
        rolling.push(start + Duration::from_millis(tick * 500), bytes);
        if tick == 10 {
            assert_eq!(
                rolling.rate(start + Duration::from_secs(5)).unwrap().mean,
                MIB as f64
            );
        }
        if tick == 11 {
            assert!(
                (rolling
                    .rate(start + Duration::from_millis(5500))
                    .unwrap()
                    .mean
                    / MIB as f64
                    - 1.1)
                    .abs()
                    < 0.001
            );
        }
        if tick >= 20 {
            assert_eq!(
                rolling
                    .rate(start + Duration::from_millis(tick * 500))
                    .unwrap()
                    .mean,
                (2 * MIB) as f64
            );
        }
        assert!(rolling.samples.len() <= 11);
    }
}

#[test]
fn rolling_window_interpolates_irregular_polls_without_counting_old_partials() {
    let start = Instant::now();
    let mut rolling = Rolling::default();
    let base = u64::MAX - 1_000_000;
    for tick in 0..=20 {
        rolling.push(start + Duration::from_millis(tick * 570), base + tick * 570);
    }
    let rate = rolling
        .rate(start + Duration::from_millis(20 * 570))
        .unwrap();
    assert!((rate.mean - 1000.0).abs() < 0.001);
    assert!(rate.stable);
    assert!(rolling.samples.len() <= 11);
}

#[test]
fn bandwidth_change_retries_from_fresh_evidence_without_a_thirty_second_gate() {
    let mut network = Network::new(64);
    network.run(100, Some(4 * MIB), true);
    // End an in-flight plateau probe, then raise the aggregate ceiling.
    while network.pool.probe.is_some() {
        network.run(1, Some(4 * MIB), true);
    }
    let before = network.now;
    // Existing streams become faster too, as on a recovering shared link.
    let mut expanded = false;
    for _ in 0..240 {
        network.pool.active = network.pool.limit;
        network.bytes += network.pool.active as u64 * MIB / 5;
        network.pool.observe(network.now, network.bytes, || true);
        if network.pool.limit > 4 {
            expanded = true;
            break;
        }
        network.now += Duration::from_millis(100);
    }
    assert!(expanded && network.now.duration_since(before) < Duration::from_secs(12));
}

#[test]
fn repeated_plateaus_require_more_evidence_but_keep_measuring() {
    let mut network = Network::new(64);
    network.run(180, Some(4 * MIB), true);
    assert!(network.pool.plateau.as_ref().unwrap().failures >= 3);
    assert_eq!(
        network
            .pool
            .probe
            .as_ref()
            .map_or(network.pool.limit, |p| p.previous_limit),
        4
    );
    assert!(network.pool.samples.samples.len() <= 11);
    assert!(network.pool.samples.samples.back().unwrap().at >= network.now - SAMPLE_INTERVAL);
}

#[test]
fn a_burst_cannot_establish_a_stable_expansion_baseline() {
    let mut network = Network::new(64);
    for tick in 0..150 {
        network.pool.active = network.pool.limit;
        if tick % 50 == 0 {
            network.bytes += 20 * MIB;
        }
        network.pool.observe(network.now, network.bytes, || true);
        network.now += Duration::from_millis(100);
    }
    assert_eq!(network.pool.limit, 4);
    assert!(network.pool.probe.is_none());
}

#[test]
fn partial_occupancy_counter_resets_and_idle_demand_need_new_samples() {
    let mut network = Network::new(64);
    network.run(4, None, true);
    network.pool.active = 1;
    network
        .pool
        .observe(network.now, network.bytes + MIB, || true);
    network.run(4, None, true);
    assert_eq!(network.pool.limit, 4);
    network.bytes = 0;
    network.pool.observe(network.now, 0, || true);
    network.run(6, None, true);
    assert_eq!(network.pool.limit, 4);
    network.run(3, None, true);
    assert!(network.pool.limit > 4);
    network.pool.idle(network.now);
    assert_eq!(network.pool.limit, 4);
}

#[test]
fn fair_share_is_a_real_trial_ceiling_and_can_grow_after_other_files_finish() {
    let mut network = Network::new(64);
    network.pool.limit_for_resources(4, network.now);
    network.run(60, None, true);
    assert_eq!(network.pool.limit, 4);
    network.pool.limit_for_resources(16, network.now);
    network.run(60, None, true);
    assert_eq!(network.pool.limit, 16);
}

#[test]
fn file_and_range_controllers_never_run_simultaneous_trials() {
    let coordinator = Coordinator::new(None);
    let now = Instant::now();
    let mut files = Connections::new(16, now)
        .with_absolute_gain()
        .with_coordinator(coordinator.clone());
    let mut ranges = Connections::with_initial(16, 1, now)
        .with_absolute_gain()
        .with_coordinator(coordinator);
    let mut bytes = 0;
    let (mut file_trials, mut range_trials) = (0, 0);
    for tick in 0..2000 {
        let now = now + Duration::from_millis(tick * 100);
        bytes += files.limit as u64 * ranges.limit as u64 * MIB / 10;
        files.active = files.limit;
        ranges.active = ranges.limit;
        let old = files.limit;
        files.observe(now, bytes, || true);
        file_trials += usize::from(files.limit > old);
        let old = ranges.limit;
        ranges.observe(now, bytes, || true);
        range_trials += usize::from(ranges.limit > old);
        assert!(!(files.probe.is_some() && ranges.probe.is_some()));
    }
    assert!(
        file_trials > 1 && range_trials > 1,
        "One controller starved"
    );
    assert_eq!((files.limit, ranges.limit), (16, 16));
}

#[test]
fn idle_queues_and_resource_changes_cannot_shorten_server_cooldowns() {
    let mut network = Network::new(64);
    network.pool.back_off(network.now + Duration::from_secs(30));
    for _ in 0..40 {
        network.pool.idle(network.now);
        network.now += Duration::from_millis(500);
    }
    network.pool.limit_for_resources(1, network.now);
    network.pool.limit_for_resources(64, network.now);
    network.run(12, None, true);
    assert_eq!(network.pool.limit, 1);
    network.run(10, None, true);
    assert!(network.pool.limit > 1);
}

#[test]
fn one_file_can_grow_beyond_eight_and_stops_at_the_measured_plateau() {
    let mut network = Network::new(64);
    network.pool = Connections::with_initial(64, 1, network.now).with_absolute_gain();
    network.run(60, None, true);
    assert_eq!(network.pool.limit, 64);
    let mut network = Network::new(64);
    network.pool = Connections::with_initial(64, 1, network.now).with_absolute_gain();
    network.run(90, Some(2 * MIB), true);
    // A periodic probe can be in flight at this point. Let its measurement
    // finish before checking the capacity retained on an unchanged link.
    network.run(8, Some(2 * MIB), true);
    assert_eq!(
        network
            .pool
            .probe
            .as_ref()
            .map_or(network.pool.limit, |p| p.previous_limit),
        2
    );
}

struct Network {
    pool: Connections,
    now: Instant,
    bytes: u64,
}

impl Network {
    fn new(ceiling: usize) -> Self {
        let now = Instant::now();
        Self {
            pool: Connections::new(ceiling, now).with_absolute_gain(),
            now,
            bytes: 0,
        }
    }

    fn run(&mut self, seconds: u64, bandwidth: Option<u64>, has_room: bool) {
        for _ in 0..seconds * 10 {
            // Continuous queued demand, with completed trials drained.
            self.pool.active = self.pool.limit;
            let rate = (self.pool.active as u64 * MIB).min(bandwidth.unwrap_or(u64::MAX));
            self.bytes += rate / 10;
            self.pool.observe(self.now, self.bytes, || has_room);
            self.now += Duration::from_millis(100);
        }
    }
}

#[test]
fn independent_connections_scale_when_aggregate_throughput_improves() {
    let mut network = Network::new(32);
    network.run(90, None, true);
    assert_eq!(network.pool.limit, 32);
    assert!(network.pool.probe.is_none());
}

#[test]
fn unlimited_download_admission_grows_past_sixty_four_and_still_obeys_bandwidth() {
    let mut fast = Network::new(usize::MAX);
    fast.run(90, None, true);
    assert!(fast.pool.limit > 64, "The former file cap still limits admission");
    let mut limited = Network::new(usize::MAX);
    limited.run(90, Some(4 * MIB), true);
    assert_eq!(limited.pool.probe.as_ref().map_or(limited.pool.limit, |p| p.previous_limit), 4);
}

#[test]
fn proven_spare_bandwidth_scales_quickly_without_exceeding_the_ceiling() {
    let mut network = Network::new(64);
    network.run(6, None, true);
    assert_eq!(
        network.pool.limit, 6,
        "First trial remains small on unknown links"
    );
    network.run(45, None, true);
    assert_eq!(
        network.pool.limit, 64,
        "Do not take over a minute to use a fast connection"
    );
    assert!(network.pool.probe.is_none());
}

#[test]
fn unchanged_bandwidth_rejects_a_probe_and_can_recover_when_network_improves() {
    let mut network = Network::new(32);
    network.run(16, Some(4 * MIB), true);
    assert_eq!(network.pool.limit, 4);
    assert!(network.pool.probe.is_none());
    network.run(100, None, true);
    assert_eq!(network.pool.limit, 32);
}

#[test]
fn stalled_streams_and_ram_pressure_do_not_expand_the_pool() {
    let mut network = Network::new(32);
    network.run(90, Some(0), true);
    assert_eq!(network.pool.limit, 4);
    network.run(90, None, false);
    assert_eq!(network.pool.limit, 4);

    let mut network = Network::new(32);
    network.run(6, None, true);
    assert_eq!(network.pool.limit, 6);
    network.run(6, None, false);
    assert_eq!(network.pool.limit, 4);
}

#[test]
fn pause_discards_a_probe_without_revoking_existing_permits() {
    let mut network = Network::new(32);
    network.run(6, None, true);
    assert_eq!(network.pool.limit, 6);
    assert_eq!(network.pool.active, 6);
    network.now += Duration::from_secs(60);
    network.pool.observe(network.now, network.bytes, || true);
    assert_eq!(network.pool.limit, 4);
    assert_eq!(
        network.pool.active, 6,
        "Only permit owners release active slots"
    );
    network.run(90, None, true);
    assert_eq!(network.pool.limit, 32);
}

#[test]
fn provider_backoff_resets_probes_and_honors_the_cooldown() {
    let mut network = Network::new(32);
    network.run(6, None, true);
    let until = network.now + Duration::from_secs(30);
    network.pool.back_off(until);
    assert_eq!(network.pool.limit, 3);
    assert_eq!(network.pool.active, 6);
    network.run(31, None, true);
    assert_eq!(network.pool.limit, 3);
    network.run(90, None, true);
    assert!((24..=32).contains(&network.pool.limit));
}

#[test]
fn small_configured_ceiling_is_respected() {
    for ceiling in 1..=4 {
        let mut network = Network::new(ceiling);
        network.run(90, None, true);
        assert_eq!(network.pool.limit, ceiling);
    }
}

#[test]
fn rejected_trials_drain_before_another_measurement() {
    let mut network = Network::new(32);
    network.run(13, Some(4 * MIB), true);
    assert_eq!(network.pool.limit, 4);
    network.pool.active = 6;
    for _ in 0..900 {
        network.bytes += MIB;
        network.pool.observe(network.now, network.bytes, || true);
        network.now += Duration::from_millis(100);
    }
    assert_eq!(network.pool.limit, 4);
    assert!(network.pool.probe.is_none());
}

struct Run {
    first_finished: f64,
    finished: usize,
    peak: usize,
    bytes: u64,
}

// Shared 4 MiB/s link, queued 16 MiB originals, equal sharing between TCP
// streams. Logical time avoids assertions about this test machine's speed.
fn simulate(adaptive: bool) -> Run {
    let start = Instant::now();
    let mut pool = Connections::new(64, start).with_absolute_gain();
    let mut old_limit = 8usize;
    let mut next_growth = 1.0;
    let mut old_successes = 0;
    let mut active = Vec::<f64>::new();
    let mut result = Run {
        first_finished: f64::INFINITY,
        finished: 0,
        peak: 0,
        bytes: 0,
    };
    for tick in 0..2400 {
        let seconds = tick as f64 / 10.0;
        let limit = if adaptive { pool.limit } else { old_limit };
        while active.len() < limit {
            active.push(16.0 * MIB as f64);
        }
        pool.active = active.len();
        if adaptive {
            pool.observe(
                start + Duration::from_millis(tick * 100),
                result.bytes,
                || true,
            );
        } else if seconds >= next_growth && active.len() >= old_limit {
            old_limit = (old_limit + (old_limit / 4).max(2)).min(64);
            next_growth = seconds + 1.0;
        }
        result.peak = result.peak.max(active.len());
        let received = 4 * MIB / 10;
        result.bytes += received;
        let per_file = received as f64 / active.len() as f64;
        for remaining in &mut active {
            *remaining -= per_file;
        }
        let before = active.len();
        active.retain(|remaining| *remaining > 0.0);
        let finished = before - active.len();
        if finished > 0 {
            result.first_finished = result.first_finished.min(seconds + 0.1);
            result.finished += finished;
            old_successes += finished;
            if old_successes >= old_limit {
                old_limit = (old_limit + 2).min(64);
                old_successes = 0;
            }
        }
    }
    result
}

#[test]
fn shared_bandwidth_finishes_files_sooner_without_losing_aggregate_throughput() {
    let old = simulate(false);
    let new = simulate(true);
    assert_eq!(old.peak, 64);
    assert_eq!(new.peak, 6);
    assert_eq!(new.bytes, old.bytes);
    assert!(new.first_finished < old.first_finished / 2.0);
    assert!(new.finished > old.finished);
    eprintln!("Shared 4 MiB/s simulation: first file {:.1}s -> {:.1}s; finished in 240s {} -> {}; peak connections {} -> {}; equal total bytes",
            old.first_finished, new.first_finished, old.finished, new.finished, old.peak, new.peak);
}

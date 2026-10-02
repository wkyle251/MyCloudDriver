use super::*;

// A concurrently spawned fixture process can briefly inherit another thread's
// file locks until exec closes CLOEXEC descriptors. Production polling already
// treats WouldBlock as a temporary lack of evidence.
fn available<T>(mut operation: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        if let Some(value) = operation() {
            return value;
        }
        assert!(
            Instant::now() < deadline,
            "Trial coordination remained unavailable"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn file_and_channel_trials_exclude_each_other_and_invalidate_old_baselines() {
    for shared in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let first = Coordinator::new(shared.then(|| directory.path().to_path_buf()));
        let second = if shared {
            Coordinator::new(Some(directory.path().to_path_buf()))
        } else {
            first.clone()
        };
        let files = first.register();
        let channels = second.register();
        let now = Instant::now();
        let baseline = available(|| files.snapshot(now));
        assert_eq!(channels.snapshot(now), Some(baseline));
        let file_trial = available(|| files.acquire(now, baseline));
        assert_eq!(channels.snapshot(now), None);
        assert!(channels.acquire(now, baseline).is_none());
        assert_eq!(available(|| file_trial.valid(now)), true);
        drop(file_trial);
        let fresh = available(|| channels.snapshot(now));
        assert_ne!(fresh, baseline);
        assert!(channels.acquire(now, baseline).is_none());
        let channel_trial = available(|| channels.acquire(now, fresh));
        assert_eq!(files.snapshot(now), None);
        drop(channel_trial);
        available(|| files.snapshot(now));
    }
}

#[test]
fn expired_ownership_cannot_block_other_helpers_or_accept_a_stale_result() {
    let directory = tempfile::tempdir().unwrap();
    let first = Coordinator::new(Some(directory.path().to_path_buf()));
    let second = Coordinator::new(Some(directory.path().to_path_buf()));
    let files = first.register();
    let channels = second.register();
    let now = Instant::now();
    let generation = available(|| files.snapshot(now));
    let abandoned = available(|| files.acquire(now, generation));
    let later = now + LEASE_TIME + Duration::from_secs(1);
    let fresh = available(|| channels.snapshot(later));
    let successor = available(|| channels.acquire(later, fresh));
    assert_eq!(available(|| abandoned.valid(later)), false);
    drop(abandoned);
    assert_eq!(available(|| successor.valid(later)), true);
}

#[test]
fn forced_backoff_invalidates_another_trial_and_private_files_reject_symlinks() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let directory = tempfile::tempdir().unwrap();
    let coordinator = Coordinator::new(Some(directory.path().join("private")));
    let files = coordinator.register();
    let channels = coordinator.register();
    let now = Instant::now();
    let generation = available(|| files.snapshot(now));
    let trial = available(|| files.acquire(now, generation));
    channels.invalidate(now);
    assert_eq!(available(|| trial.valid(now)), false);
    drop(trial);
    assert_eq!(
        std::fs::metadata(directory.path().join("private"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(directory.path().join("private/concurrency-trial"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    std::fs::remove_file(directory.path().join("private/concurrency-trial")).unwrap();
    let target = directory.path().join("unrelated");
    std::fs::write(&target, b"preserved").unwrap();
    symlink(&target, directory.path().join("private/concurrency-trial")).unwrap();
    assert!(files.snapshot(now).is_none());
    assert_eq!(std::fs::read(target).unwrap(), b"preserved");
}

#[test]
fn a_separate_process_cannot_overlap_an_active_trial() {
    let directory = tempfile::tempdir().unwrap();
    let coordinator = Coordinator::new(Some(directory.path().to_path_buf()));
    let participant = coordinator.register();
    let now = Instant::now();
    let generation = available(|| participant.snapshot(now));
    let _lease = available(|| participant.acquire(now, generation));
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "download_trials::tests::trial_child",
            "--ignored",
        ])
        .env("MYCLOUD_TRIAL_FIXTURE_DIRECTORY", directory.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
}

#[test]
#[ignore = "isolated process; launched by a_separate_process_cannot_overlap_an_active_trial"]
fn trial_child() {
    let coordinator = Coordinator::new(Some(
        std::env::var_os("MYCLOUD_TRIAL_FIXTURE_DIRECTORY")
            .unwrap()
            .into(),
    ));
    assert!(coordinator.register().snapshot(Instant::now()).is_none());
}

#[test]
fn contended_release_is_retried_and_an_incomplete_lease_is_repaired() {
    let directory = tempfile::tempdir().unwrap();
    let coordinator = Coordinator::new(Some(directory.path().to_path_buf()));
    let participant = coordinator.register();
    let now = Instant::now();
    let generation = available(|| participant.snapshot(now));
    let lease = available(|| participant.acquire(now, generation));
    let path = directory.path().join("concurrency-trial");
    let held = available(|| {
        crate::download_network::Network::locked_file(
            &path,
            rustix::fs::FlockOperation::NonBlockingLockExclusive,
        )
        .ok()
    });
    drop(lease);
    assert!(participant.snapshot(now).is_none());
    drop(held);
    let after = available(|| participant.snapshot(now));
    assert!(after > generation);
    std::fs::write(&path, [1, 2, 3]).unwrap();
    assert_ne!(available(|| participant.snapshot(now)), after);
    assert_eq!(std::fs::metadata(path).unwrap().len(), 24);
}

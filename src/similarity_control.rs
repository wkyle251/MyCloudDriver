//! Per-helper cooperative pause. The helper, sockets, FIFOs and original RAM
//! leases stay alive. Finish stops acquisition separately, drains active
//! analysis and publishes a resumable report. Delete and shutdown cancel.
use super::*;
use filetwin_core::api::{CancellationToken, LiveResources};
use std::os::unix::fs::MetadataExt;

pub(super) struct Control {
    pub token: CancellationToken,
    pub acquisition_cancel: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    watcher: Option<std::thread::JoinHandle<()>>,
}
impl Drop for Control {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(watcher) = self.watcher.take() {
            let _ = watcher.join();
        }
    }
}
impl Control {
    pub fn new(
        request: &ScanRequest,
        cancel: Arc<AtomicBool>,
        memory: Option<Arc<memory::Budget>>,
    ) -> Self {
        let token = CancellationToken::default();
        let stop = Arc::new(AtomicBool::new(false));
        let acquisition_cancel = if request.checkpoint_id.is_some() {
            Arc::new(AtomicBool::new(false))
        } else {
            cancel.clone()
        };
        let watcher = request.checkpoint_id.as_ref().map(|id| {
            let automatic_memory = request.resources.automatic_memory;
            // macOS GUI URLs often use /var while secure openat traversal
            // correctly rejects that symlink. Resolve the owned directory,
            // then continue rejecting symlinks for individual control files.
            let path = request.data_dir.join("checkpoints").join(id);
            let directory = path.canonicalize().unwrap_or(path);
            let token = token.clone(); let stop = stop.clone();
            let acquisition_cancel = acquisition_cancel.clone();
            std::thread::spawn(move || {
                let mut paused = false;
                let mut pause_revision = None;
                let mut resources_data = Vec::new();
                while !stop.load(Ordering::Acquire) {
                    if cancel.load(Ordering::Acquire) {
                        acquisition_cancel.store(true, Ordering::Release);
                        token.cancel(); return;
                    }
                    if directory.join("finish").is_file() {
                        token.request_finish();
                        acquisition_cancel.store(true, Ordering::Release);
                    }
                    // The GUI atomically publishes settings before removing
                    // pause. They change admission, never the vector profile.
                    if let Some(file) = (!automatic_memory).then(|| scope::open_secure(&directory.join("live-resources.json")).ok()).flatten() {
                        if file.metadata().is_ok_and(|m| m.len() <= 16 * 1024) {
                            use std::io::Read;
                            let mut bytes = Vec::new();
                            if file.take(16 * 1024).read_to_end(&mut bytes).is_ok() && bytes != resources_data {
                                resources_data = bytes.clone();
                                let result = (|| -> Result<()> {
                                    let settings: ScanResources = serde_json::from_slice(&bytes)?;
                                    settings.validate()?;
                                    if let Some(memory) = &memory { memory.resize(settings.download_budget())?; }
                                    token.update_resources(LiveResources {
                                        workers: resources::prepare(settings.effective_workers()),
                                        memory_bytes: settings.analysis_budget(), staging_bytes: settings.download_budget(),
                                        total_memory_bytes: None, acquisition_paused: false, external_memory_bytes: None,
                                    });
                                    Ok(())
                                })();
                                if result.is_err() {
                                    let _ = std::fs::write(directory.join("pause"), []);
                                    let _ = emit(&json!({"event":"resources_rejected", "message":"The retained downloads need more RAM to finish. Resume with the previous Download RAM amount before reducing it."}));
                                }
                            }
                        }
                    }
                    // Atomic pause writes replace the marker. A quick
                    // Resume→Pause can happen inside one watcher interval;
                    // acknowledge the new request even if no unpaused edge
                    // was observed, or the GUI would wait forever for Pause.
                    let revision = if token.is_finishing() { None } else {
                        std::fs::symlink_metadata(directory.join("pause")).ok()
                            .filter(|m| m.is_file()).map(|m| (m.ino(), m.mtime(), m.mtime_nsec()))
                    };
                    let requested = revision.is_some();
                    if paused != requested || (requested && pause_revision != revision) {
                        token.set_paused(requested); paused = requested;
                        let _ = emit(&json!({"event":"pause_state", "paused":paused, "retained_in_ram":true}));
                    }
                    pause_revision = revision;
                    std::thread::sleep(Duration::from_millis(20));
                }
            })
        });
        Self {
            token,
            acquisition_cancel,
            stop,
            watcher,
        }
    }
}

pub(super) async fn wait(token: &CancellationToken, cancel: &AtomicBool) -> Result<Duration> {
    let start = Instant::now();
    let paused = token.is_paused();
    while token.is_paused() {
        check_cancel(cancel)?;
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    check_cancel(cancel)?;
    Ok(if paused {
        start.elapsed()
    } else {
        Duration::ZERO
    })
}

pub(super) fn wait_blocking(token: &CancellationToken, cancel: &AtomicBool) -> Result<Duration> {
    let start = Instant::now();
    let paused = token.is_paused();
    while token.is_paused() {
        check_cancel(cancel)?;
        if token.is_cancelled() {
            bail!("Scan cancelled.");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    check_cancel(cancel)?;
    Ok(if paused {
        start.elapsed()
    } else {
        Duration::ZERO
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gui_path_alias_keeps_pause_and_resource_updates_connected() {
        let root = tempfile::tempdir().unwrap();
        let actual = root.path().join("actual");
        std::fs::create_dir(&actual).unwrap();
        let alias = root.path().join("alias");
        std::os::unix::fs::symlink(&actual, &alias).unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        request.data_dir = alias;
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let memory = memory::Budget::new(512 << 20);
        let control = Control::new(&request, cancel, Some(memory.clone()));
        std::fs::write(checkpoint.directory.join("pause"), []).unwrap();
        let until = Instant::now() + Duration::from_secs(2);
        while !control.token.is_paused() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(control.token.is_paused());
        let limits = ScanResources {
            memory_bytes: 1 << 30,
            download_memory_bytes: Some(256 << 20),
            ..Default::default()
        };
        std::fs::write(
            checkpoint.directory.join("live-resources.json"),
            serde_json::to_vec(&limits).unwrap(),
        )
        .unwrap();
        while memory.limit() != 256 << 20 && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            memory.limit(),
            256 << 20,
            "Secure control reads rejected the GUI's directory alias"
        );
        std::fs::remove_file(checkpoint.directory.join("pause")).unwrap();
        while control.token.is_paused() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!control.token.is_paused());
    }
    #[test]
    fn finish_marker_unpauses_and_stops_acquisition_without_cancelling_analysis() {
        let root = tempfile::tempdir().unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        std::fs::write(checkpoint.directory.join("pause"), []).unwrap();
        let control = Control::new(&request, Arc::new(AtomicBool::new(false)), None);
        let until = Instant::now() + Duration::from_secs(2);
        while !control.token.is_paused() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(control.token.is_paused());
        std::fs::write(checkpoint.directory.join("finish"), []).unwrap();
        while !control.token.is_finishing() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(control.token.is_finishing());
        assert!(!control.token.is_paused() && !control.token.is_cancelled());
        assert!(control.acquisition_cancel.load(Ordering::Acquire));
    }
}

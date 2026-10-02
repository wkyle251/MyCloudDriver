//! Per-helper cooperative pause. The helper, sockets, FIFOs and original RAM
//! leases stay alive; only Clear/shutdown uses the cancellation flag.
use super::*;
use filetwin_core::api::{CancellationToken, LiveResources};

pub(super) struct Control {
    pub token: CancellationToken,
    stop: Arc<AtomicBool>,
    watcher: Option<std::thread::JoinHandle<()>>,
}
impl Drop for Control {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(watcher) = self.watcher.take() { let _ = watcher.join(); }
    }
}
impl Control {
    pub fn new(request: &ScanRequest, cancel: Arc<AtomicBool>, memory: Option<Arc<memory::Budget>>) -> Self {
        let token = CancellationToken::default();
        let stop = Arc::new(AtomicBool::new(false));
        let watcher = request.checkpoint_id.as_ref().map(|id| {
            // macOS GUI URLs often use /var while secure openat traversal
            // correctly rejects that symlink. Resolve the owned directory,
            // then continue rejecting symlinks for individual control files.
            let path = request.data_dir.join("checkpoints").join(id);
            let directory = path.canonicalize().unwrap_or(path);
            let token = token.clone(); let stop = stop.clone();
            std::thread::spawn(move || {
                let mut paused = false;
                let mut resources_data = Vec::new();
                while !stop.load(Ordering::Acquire) {
                    if cancel.load(Ordering::Acquire) { token.cancel(); return; }
                    // The GUI atomically publishes settings before removing
                    // pause. They change admission, never the vector profile.
                    if let Ok(file) = scope::open_secure(&directory.join("live-resources.json")) {
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
                    let requested = directory.join("pause").is_file();
                    if paused != requested {
                        token.set_paused(requested); paused = requested;
                        let _ = emit(&json!({"event":"pause_state", "paused":paused, "retained_in_ram":true}));
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            })
        });
        Self { token, stop, watcher }
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
    Ok(if paused { start.elapsed() } else { Duration::ZERO })
}

pub(super) fn wait_blocking(token: &CancellationToken, cancel: &AtomicBool) -> Result<Duration> {
    let start = Instant::now();
    let paused = token.is_paused();
    while token.is_paused() {
        check_cancel(cancel)?;
        if token.is_cancelled() { bail!("Scan cancelled."); }
        std::thread::sleep(Duration::from_millis(20));
    }
    check_cancel(cancel)?;
    Ok(if paused { start.elapsed() } else { Duration::ZERO })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gui_path_alias_keeps_pause_and_resource_updates_connected() {
        let root = tempfile::tempdir().unwrap();
        let actual = root.path().join("actual"); std::fs::create_dir(&actual).unwrap();
        let alias = root.path().join("alias"); std::os::unix::fs::symlink(&actual, &alias).unwrap();
        let mut request = super::super::tests::request(root.path());
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        request.data_dir = alias;
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let memory = memory::Budget::new(512 << 20);
        let control = Control::new(&request, cancel, Some(memory.clone()));
        std::fs::write(checkpoint.directory.join("pause"), []).unwrap();
        let until = Instant::now() + Duration::from_secs(2);
        while !control.token.is_paused() && Instant::now() < until { std::thread::sleep(Duration::from_millis(5)); }
        assert!(control.token.is_paused());
        let limits = ScanResources { memory_bytes: 1 << 30, download_memory_bytes: Some(256 << 20), ..Default::default() };
        std::fs::write(checkpoint.directory.join("live-resources.json"), serde_json::to_vec(&limits).unwrap()).unwrap();
        while memory.limit() != 256 << 20 && Instant::now() < until { std::thread::sleep(Duration::from_millis(5)); }
        assert_eq!(memory.limit(),256 << 20,"Secure control reads rejected the GUI's directory alias");
        std::fs::remove_file(checkpoint.directory.join("pause")).unwrap();
        while control.token.is_paused() && Instant::now() < until { std::thread::sleep(Duration::from_millis(5)); }
        assert!(!control.token.is_paused());
    }
}

//! Select one visual backend before acquisition. Checkpoints pin that choice.
use super::*;
use filetwin_core::{
    api::{CancellationToken, EncodeRequest, EncodeSource, EncoderConfig, FileState},
    profile::Backend,
    Encoder,
};

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Automatic,
    #[default]
    Cpu,
}

pub(super) fn select(
    request: &ScanRequest,
    config: &mut EncoderConfig,
    checkpoint: Option<&checkpoint::Checkpoint>,
    cancel: &AtomicBool,
) -> Result<()> {
    let pinned = checkpoint.map(|c| c.backend()).transpose()?.flatten();
    let automatic = request.resources.acceleration == Mode::Automatic;
    let backend = if let Some(backend) = pinned {
        backend
    } else if automatic
        && cfg!(all(target_os = "macos", target_arch = "aarch64"))
        && request
            .families
            .iter()
            .any(|f| matches!(f.as_str(), "image" | "video"))
    {
        emit(
            &json!({"event":"acceleration","backend":"checking","message":"Checking CoreML acceleration…"}),
        )?;
        if probe(config, cancel)? {
            Backend::Coreml
        } else {
            Backend::Cpu
        }
    } else {
        Backend::Cpu
    };
    config.backend = backend;
    if let Some(checkpoint) = checkpoint {
        checkpoint.pin_backend(backend)?;
    }
    announce(
        backend,
        config.accelerator_capacity(),
        automatic && backend == Backend::Cpu && pinned.is_none(),
    )
}

pub(super) fn announce(backend: Backend, workers: usize, fallback: bool) -> Result<()> {
    emit(
        &json!({"event":"acceleration","backend":backend.as_str(),"accelerator_limit":workers,
        "message":if backend == Backend::Coreml { "CoreML acceleration · CPU with GPU / Neural Engine support" }
            else if fallback { "CPU processing · CoreML unavailable or not needed for this scan" } else { "CPU processing" }}),
    )
}

fn probe(config: &EncoderConfig, cancel: &AtomicBool) -> Result<bool> {
    let mut probe = config.clone();
    probe.backend = Backend::Coreml;
    probe.workers = 1;
    probe.memory_bytes = probe.memory_bytes.min(2 << 30);
    let token = CancellationToken::default();
    let started = Instant::now();
    // Synthetic PPM stays in RAM. No user original is downloaded for this check.
    let mut image = b"P6\n2 2\n255\n".to_vec();
    image.extend_from_slice(&[32, 64, 128, 128, 64, 32, 255, 128, 64, 64, 128, 255]);
    let mut source = Some(EncodeSource::from_memory(
        "acceleration-check.ppm",
        Arc::new(filetwin_core::memory_input::MemoryInput::new(image)),
    ));
    let result = Encoder::new(probe)?.encode_sources(
        &EncodeRequest::new(&config.temp_dir),
        &token,
        || Ok(source.take()),
        |_| {
            if cancel.load(Ordering::Acquire) || started.elapsed() >= Duration::from_secs(45) {
                token.cancel();
            }
        },
    );
    check_cancel(cancel)?;
    Ok(result
        .is_ok_and(|r| !r.summary.cancelled && r.files.iter().any(|f| f.state == FileState::Ready)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unavailable_acceleration_falls_back_and_resume_keeps_the_original_backend() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let mut request = super::super::tests::request(&root);
        request.resources.acceleration = Mode::Automatic;
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        let mut config = EncoderConfig::new(root.join("missing-models"), &root);
        select(
            &request,
            &mut config,
            Some(&checkpoint),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(config.backend, Backend::Cpu);
        assert_eq!(checkpoint.backend().unwrap(), Some(Backend::Cpu));
        assert!(checkpoint.pin_backend(Backend::Coreml).is_err());
        drop(checkpoint);
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        config.backend = Backend::Coreml;
        select(
            &request,
            &mut config,
            Some(&checkpoint),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(config.backend, Backend::Cpu);
    }
    #[test]
    fn coreml_checkpoints_stay_coreml_even_when_new_scan_preference_is_cpu() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let mut request = super::super::tests::request(&root);
        request.checkpoint_id = Some("12345678-1234-1234-1234-123456789abc".into());
        let checkpoint = checkpoint::Checkpoint::open(&request).unwrap().unwrap();
        checkpoint.pin_backend(Backend::Coreml).unwrap();
        let mut config = EncoderConfig::new(root.join("models"), &root);
        select(
            &request,
            &mut config,
            Some(&checkpoint),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(config.backend, Backend::Coreml);
        assert_ne!(
            filetwin_core::profile::experimental_profiles_for(Backend::Cpu)[1].profile_id,
            filetwin_core::profile::experimental_profiles_for(Backend::Coreml)[1].profile_id
        );
    }
}

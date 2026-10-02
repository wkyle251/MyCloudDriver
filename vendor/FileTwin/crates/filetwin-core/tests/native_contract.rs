//! Host/worker contracts with deterministic disposable workers; no model downloads.
use filetwin_core::{
    Encoder, ErrorCode,
    api::*,
    profile,
    worker_protocol::{Encoded, Response, VERSION},
    write_vectors,
};
use serde_json::json;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    input: PathBuf,
    config: EncoderConfig,
}
impl Fixture {
    fn new(body: impl FnOnce(&Path) -> String) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let input = root.join("input");
        fs::create_dir(&input).unwrap();
        let mut config = EncoderConfig::new(root.join("models"), root.join("staging"));
        fs::create_dir(&config.temp_dir).unwrap();
        fs::create_dir(&config.model_dir).unwrap();
        fs::write(config.model_dir.join(profile::SSCD_MODEL_FILE), []).unwrap();
        let worker = root.join("worker");
        fs::write(&worker, format!("#!/bin/sh\n{}\n", body(&root))).unwrap();
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o700)).unwrap();
        let library = root.join("library");
        fs::write(&library, []).unwrap();
        config.runtime = RuntimeConfig {
            worker_path: Some(worker.clone()),
            ffmpeg_path: Some(worker.clone()),
            ffprobe_path: Some(worker),
            onnxruntime_path: Some(library.clone()),
            pdfium_path: Some(library),
            ..RuntimeConfig::default()
        };
        response(&root.join("response.json"), "image", 512);
        Self {
            _temp: temp,
            root,
            input,
            config,
        }
    }
    fn images(&self, n: u8) {
        for i in 0..n {
            let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
            bytes.push(i);
            fs::write(self.input.join(format!("{i}.png")), bytes).unwrap();
        }
    }
    fn run(&self) -> VectorFile {
        Encoder::new(self.config.clone())
            .unwrap()
            .encode(
                &EncodeRequest::new(&self.input),
                &CancellationToken::default(),
                |_| {},
            )
            .unwrap()
    }
    fn clean(&self) {
        assert_eq!(fs::read_dir(&self.config.temp_dir).unwrap().count(), 0);
    }
}
fn response(path: &Path, family: &str, dimensions: usize) {
    let mut vector = vec![0.0; dimensions];
    vector[0] = 1.0;
    fs::write(
        path,
        serde_json::to_vec(&Response {
            version: VERSION,
            result: Ok(Encoded {
                family: family.into(),
                format: "fixture".into(),
                vector,
                extraction: json!({"fixture":true}),
            }),
        })
        .unwrap(),
    )
    .unwrap();
}
fn serve(root: &Path) -> String {
    format!(
        "while IFS= read -r request; do /bin/cat '{}'; printf '\\n'; done",
        root.join("response.json").display()
    )
}

fn streamed(f: &Fixture, sources: Vec<EncodeSource>, progress: impl FnMut(&Progress)) -> VectorFile {
    let mut sources = sources.into_iter();
    Encoder::new(f.config.clone()).unwrap().encode_sources(&EncodeRequest::new(&f.input), &CancellationToken::default(),
        || Ok(sources.next()), progress).unwrap()
}

#[test]
fn deferred_fetches_overlap_and_share_the_full_lifecycle_slot_limit() {
    use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
    let mut f = Fixture::new(|root| format!("while IFS= read -r request; do /bin/sleep 0.08; /bin/cat '{}'; printf '\\n'; done", root.join("response.json").display()));
    f.config.workers = 4;
    f.config.memory_bytes = 4 << 30;
    f.images(8);
    let fetching = Arc::new(AtomicUsize::new(0)); let peak = Arc::new(AtomicUsize::new(0));
    let sources = (0..8).map(|i| {
        let path = f.input.join(format!("{i}.png")); let fetching = fetching.clone(); let peak = peak.clone();
        EncodeSource::deferred(format!("{i}.png"), move |cancel| {
            let count = fetching.fetch_add(1, Ordering::SeqCst) + 1;
            peak.fetch_max(count, Ordering::SeqCst);
            for _ in 0..20 { assert!(!cancel.is_cancelled()); std::thread::sleep(Duration::from_millis(4)); }
            fetching.fetch_sub(1, Ordering::SeqCst);
            Ok(EncodeSource::new(format!("{i}.png"), path))
        })
    }).collect();
    let mut phases = WorkCounts::default();
    let result = streamed(&f, sources, |p| {
        if let Some(work) = &p.work {
            assert!(work.fetching + work.reading + work.encoding + work.waiting_memory <= 4);
            phases.fetching = phases.fetching.max(work.fetching);
            phases.encoding = phases.encoding.max(work.encoding);
        }
    });
    assert_eq!(peak.load(Ordering::SeqCst), 4, "Original acquisition must not be serial");
    assert!(phases.fetching >= 2 && phases.encoding >= 2);
    assert_eq!(result.summary.counts.files_ready, 8);
    f.clean();
}

#[test]
fn duplicate_waiters_do_not_hold_slots_or_block_unrelated_native_files() {
    let mut f = Fixture::new(|root| {
        let script = root.join("worker.py");
        fs::write(&script, format!(r#"import json,sys,time,pathlib
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line); name=pathlib.Path(r['path']).read_bytes()[-1]
 with (root/'events').open('a') as f: f.write('start:'+str(name)+'\n')
 time.sleep(0.5 if name==0 else 0.05)
 with (root/'events').open('a') as f: f.write('finish:'+str(name)+'\n')
 print((root/'response.json').read_text(),flush=True)
"#, root = root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'", script.display())
    });
    f.config.workers = 2;
    f.images(2);
    let copy = f.input.join("copy.png"); fs::copy(f.input.join("0.png"), &copy).unwrap();
    let result = streamed(&f, vec![EncodeSource::new("first.png", f.input.join("0.png")),
        EncodeSource::new("copy.png", copy), EncodeSource::new("unrelated.png", f.input.join("1.png"))], |_| {});
    let events = fs::read_to_string(f.root.join("events")).unwrap();
    assert!(events.find("start:1").unwrap() < events.find("finish:0").unwrap(), "{events}");
    assert_eq!(events.matches("start:0").count(), 1, "Identical content is encoded only once");
    assert_eq!(result.summary.counts.files_ready, 3);
    assert_eq!(result.summary.counts.cache_hits, 1);
    f.clean();
}

#[test]
fn a_large_decoder_can_borrow_unused_memory_without_exceeding_the_shared_budget() {
    let mut f = Fixture::new(|root| {
        let script = root.join("worker.py");
        fs::write(&script, format!(r#"import json,sys,pathlib
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line)
 with (root/'allowances').open('a') as f: f.write(str(r['memory_bytes'])+'\n')
 if r['memory_bytes'] < 1500000000:
  print(json.dumps({{'version':r['version'],'result':{{'Err':{{'code':'resource_budget_too_small','stage':'image','message':'Decoded image exceeds memory allowance','details':{{'required_memory_bytes':1500000000}}}}}}}}),flush=True)
 else: print((root/'response.json').read_text(),flush=True)
"#, root = root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'", script.display())
    });
    f.config.workers = 4; f.config.memory_bytes = 2 << 30; f.images(1);
    let result = streamed(&f, vec![EncodeSource::new("large.png", f.input.join("0.png"))], |p| {
        if let Some(work) = &p.work { assert!(work.memory_in_use <= work.memory_limit); }
    });
    assert_eq!(result.summary.counts.files_ready, 1);
    assert_eq!(result.summary.counts.files_failed, 0);
    let allowances: Vec<u64> = fs::read_to_string(f.root.join("allowances")).unwrap().lines().map(|s| s.parse().unwrap()).collect();
    assert_eq!(allowances, vec![512 << 20, 1_500_000_000]);
    f.clean();
}

#[test]
fn cancellation_interrupts_deferred_acquisition_and_releases_all_leases() {
    use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
    let mut f = Fixture::new(serve); f.config.workers = 4; f.config.memory_bytes = 4 << 30;
    let active = Arc::new(AtomicUsize::new(0));
    struct Guard(Arc<AtomicUsize>);
    impl Drop for Guard { fn drop(&mut self) { self.0.fetch_sub(1, Ordering::SeqCst); } }
    let mut sources = (0..20).map(|i| {
        let active = active.clone();
        EncodeSource::deferred(format!("{i}.png"), move |cancel| {
            active.fetch_add(1, Ordering::SeqCst); let _guard = Guard(active);
            while !cancel.is_cancelled() { std::thread::sleep(Duration::from_millis(5)); }
            Err(filetwin_core::Error::new(ErrorCode::Cancelled, "fetching", "cancelled"))
        })
    });
    let cancel = CancellationToken::default(); let started = Instant::now();
    let result = Encoder::new(f.config.clone()).unwrap().encode_sources(&EncodeRequest::new(&f.input), &cancel, || Ok(sources.next()), |p| {
        if p.work.as_ref().is_some_and(|w| w.fetching >= 4) { cancel.cancel(); }
    }).unwrap();
    assert!(result.summary.cancelled && result.summary.counts.files_discovered <= 4);
    assert_eq!(active.load(Ordering::SeqCst), 0);
    assert!(started.elapsed() < Duration::from_secs(3));
    f.clean();
}

#[test]
fn a_large_ready_file_waiting_for_memory_does_not_block_a_smaller_ready_file() {
    for memory_scheduling in [false, true] {
    let mut f = Fixture::new(|root| {
        let script = root.join("worker.py");
        fs::write(&script, format!(r#"import json,sys,pathlib,time
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line); name=pathlib.Path(r['path']).read_bytes()[8]
 if name==1 and r['memory_bytes'] < 2*1024**3:
  (root/'large-waiting').touch()
  print(json.dumps({{'version':r['version'],'result':{{'Err':{{'code':'resource_budget_too_small','stage':'image','message':'Fixture needs memory','details':{{'required_memory_bytes':2*1024**3}}}}}}}}),flush=True)
  continue
 if name==0:
  deadline=time.monotonic()+5
  while not (root/'small-started').exists() and time.monotonic()<deadline: time.sleep(.01)
  assert (root/'small-started').exists(), 'Large queue head blocked a smaller ready file'
 if name==2: (root/'small-started').touch()
 print((root/'response.json').read_text(),flush=True)
"#, root = root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'", script.display())
    });
    f.config.workers = 4; f.config.memory_bytes = 2 << 30; f.images(3);
    f.config.memory_scheduling = memory_scheduling;
    let waiting = f.root.join("large-waiting"); let path = f.input.join("2.png");
    let result = streamed(&f, vec![EncodeSource::new("busy.png", f.input.join("0.png")),
        EncodeSource::new("large.png", f.input.join("1.png")),
        EncodeSource::deferred("small.png", move |cancel| {
            let started = Instant::now();
            while !waiting.exists() { assert!(!cancel.is_cancelled()); assert!(started.elapsed() < Duration::from_secs(5)); std::thread::sleep(Duration::from_millis(5)); }
            // Give the scheduler time to queue the larger-file retry first.
            std::thread::sleep(Duration::from_millis(50));
            Ok(EncodeSource::new("small.png", path))
        })], |p| {
            if let Some(work) = &p.work { assert!(work.memory_in_use <= work.memory_limit); }
        });
    assert_eq!(result.summary.counts.files_ready, 3);
    assert_eq!(result.summary.counts.files_failed, 0);
    f.clean();
    }
}

#[test]
fn streamed_binary_data_keeps_hashes_without_being_reported_as_a_worker_failure() {
    let f = Fixture::new(serve);
    let path = f.input.join("encrypted.dat"); fs::write(&path, [0, 255, 0, 3, 4]).unwrap();
    let result = streamed(&f, vec![EncodeSource::new("data", path)], |_| {});
    assert_eq!(result.summary.counts.files_skipped, 1);
    assert_eq!(result.summary.counts.files_failed, 0);
    assert_eq!(result.files[0].state, FileState::Unsupported);
    assert!(result.files[0].file_id.is_some() && result.files[0].vector.is_none());
    f.clean();
}

#[test]
fn streamed_sources_fetch_only_for_free_slots_and_reuse_workers() {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    struct Lease {
        _directory: tempfile::TempDir,
        active: Arc<AtomicUsize>,
    }
    impl Drop for Lease {
        fn drop(&mut self) {
            self.active.fetch_sub(1, Ordering::SeqCst);
        }
    }
    let mut f = Fixture::new(|root| {
        fs::create_dir(root.join("starts")).unwrap();
        format!(
            "while IFS= read -r request; do /usr/bin/touch '{root}/starts/'$$; /bin/sleep 0.05; /bin/cat '{root}/response.json'; printf '\\n'; done",
            root = root.display()
        )
    });
    f.config.workers = 2;
    let originals = f.root.join("originals");
    fs::create_dir(&originals).unwrap();
    let active = Arc::new(AtomicUsize::new(0));
    let mut next = 0;
    let result = Encoder::new(f.config.clone())
        .unwrap()
        .encode_sources(
            &EncodeRequest::new(&f.input),
            &CancellationToken::default(),
            || {
                assert!(
                    active.load(Ordering::SeqCst) < 2,
                    "No original may be fetched ahead of a free slot"
                );
                if next == 7 {
                    return Ok(None);
                }
                let directory = tempfile::tempdir_in(&originals).unwrap();
                let path = directory.path().join("original.png");
                let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
                bytes.push(next);
                fs::write(&path, bytes).unwrap();
                active.fetch_add(1, Ordering::SeqCst);
                let source = EncodeSource::new(format!("{next}.png"), path).retaining(Lease {
                    _directory: directory,
                    active: active.clone(),
                });
                next += 1;
                Ok(Some(source))
            },
            |_| {},
        )
        .unwrap();
    assert_eq!(result.summary.counts.files_ready, 7);
    assert_eq!(result.summary.counts.vectors_encoded, 7);
    assert_eq!(
        fs::read_dir(f.root.join("starts")).unwrap().count(),
        2,
        "Workers stay loaded throughout the stream"
    );
    assert_eq!(active.load(Ordering::SeqCst), 0);
    assert_eq!(fs::read_dir(originals).unwrap().count(), 0);
    f.clean();
}

#[test]
fn discovery_can_wait_for_analysis_without_ending_the_stream() {
    use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
    let f = Fixture::new(serve);
    f.images(2);
    let first_ready = Arc::new(AtomicBool::new(false));
    let observed = first_ready.clone();
    let started = Instant::now();
    let mut supplied = 0;
    let mut waits = 0;
    let result = Encoder::new(f.config.clone()).unwrap().encode_stream(
        &EncodeRequest::new(&f.input), &CancellationToken::default(), || {
            assert!(started.elapsed() < Duration::from_secs(5), "Analysis must finish while discovery is waiting");
            if supplied == 1 && !first_ready.load(Ordering::Acquire) {
                waits += 1;
                return Ok(EncodeSourcePoll::Pending);
            }
            if supplied == 2 { return Ok(EncodeSourcePoll::Complete); }
            let i = supplied; supplied += 1;
            Ok(EncodeSourcePoll::Ready(EncodeSource::new(format!("{i}.png"), f.input.join(format!("{i}.png")))))
        }, |progress| {
            if progress.counts.files_ready == 1 {
                assert!(progress.counts.files_total.is_none(), "Discovery has not finished");
                observed.store(true, Ordering::Release);
            }
        }).unwrap();
    assert!(waits > 0);
    assert!(first_ready.load(Ordering::Acquire));
    assert_eq!(result.summary.counts.files_ready, 2);
    assert_eq!(result.summary.counts.files_total, Some(2));
    f.clean();
}

#[test]
fn pending_discovery_is_cancellable() {
    let f = Fixture::new(serve);
    let token = CancellationToken::default();
    let mut polls = 0;
    let result = Encoder::new(f.config.clone()).unwrap().encode_stream(
        &EncodeRequest::new(&f.input), &token, || {
            polls += 1;
            if polls == 3 { token.cancel(); }
            Ok(EncodeSourcePoll::Pending)
        }, |_| {}).unwrap();
    assert_eq!(polls, 3);
    assert!(result.summary.cancelled);
    f.clean();
}

#[test]
fn streamed_cancellation_stops_pulling_and_releases_originals() {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    let mut f = Fixture::new(|_| "/bin/sleep 120".into());
    f.config.workers = 2;
    let originals = f.root.join("originals");
    fs::create_dir(&originals).unwrap();
    let fetched = Arc::new(AtomicUsize::new(0));
    let token = CancellationToken::default();
    let worker = {
        let (config, input, originals, fetched, token) = (
            f.config.clone(),
            f.input.clone(),
            originals.clone(),
            fetched.clone(),
            token.clone(),
        );
        std::thread::spawn(move || {
            Encoder::new(config)
                .unwrap()
                .encode_sources(
                    &EncodeRequest::new(input),
                    &token,
                    || {
                        let i = fetched.fetch_add(1, Ordering::SeqCst);
                        let lease = tempfile::tempdir_in(&originals).unwrap();
                        let path = lease.path().join("original.png");
                        let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
                        bytes.push(i as u8);
                        fs::write(&path, bytes).unwrap();
                        Ok(Some(
                            EncodeSource::new(format!("{i}.png"), path).retaining(lease),
                        ))
                    },
                    |_| {},
                )
                .unwrap()
        })
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while fetched.load(Ordering::SeqCst) < 2 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    token.cancel();
    let result = worker.join().unwrap();
    assert!(result.summary.cancelled);
    assert_eq!(
        fetched.load(Ordering::SeqCst),
        2,
        "Cancelled scans must not fetch queued originals"
    );
    assert_eq!(fs::read_dir(originals).unwrap().count(), 0);
    f.clean();
}

#[test]
fn native_cache_and_scratch_files_are_disposable_between_calls() {
    let f = Fixture::new(|root| {
        format!(
            r#"
while IFS= read -r request; do
    case "$TMPDIR" in '{root}/staging/'*) ;; *) exit 31 ;; esac
    case "$XDG_CACHE_HOME" in "$TMPDIR/"*) ;; *) exit 32 ;; esac
    case "$CUDA_CACHE_PATH" in "$TMPDIR/"*) ;; *) exit 33 ;; esac
    [ "$TMP" = "$TMPDIR" ] && [ "$TEMP" = "$TMPDIR" ] || exit 34
    printf 'scratch' > "$TMPDIR/decoder-tmp"
    printf 'cache' > "$XDG_CACHE_HOME/library-cache"
    printf 'compiled' > "$CUDA_CACHE_PATH/kernel-cache"
    /bin/cat '{root}/response.json'
    printf '\n'
done
"#,
            root = root.display()
        )
    });
    f.images(3);
    for _ in 0..3 {
        let result = f.run();
        assert_eq!(result.summary.counts.files_ready, 3);
        assert_eq!(result.summary.counts.vectors_encoded, 3);
        f.clean();
    }
}
fn wait_for(path: &Path) {
    let start = Instant::now();
    while !path.exists() {
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "worker did not start"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn native_workers_run_concurrently_reuse_processes_and_deduplicate_content() {
    let f = Fixture::new(|root| {
        fs::create_dir(root.join("starts")).unwrap();
        format!(
            r#"
while IFS= read -r request; do
    /usr/bin/touch '{root}/starts/'$$
    attempts=0
    while [ "$(/bin/ls '{root}/starts' | /usr/bin/wc -l)" -lt 2 ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 500 ] || exit 19
        /bin/sleep 0.01
    done
    /bin/cat '{root}/response.json'
    printf '\n'
done
"#,
            root = root.display()
        )
    });
    f.images(6);
    fs::hard_link(f.input.join("0.png"), f.input.join("alias.png")).unwrap();
    let result = f.run();
    assert_eq!(
        (
            result.summary.counts.files_ready,
            result.summary.counts.vectors_encoded,
            result.summary.counts.cache_hits
        ),
        (7, 6, 1),
        "{:?}",
        result.summary
    );
    assert_eq!(fs::read_dir(f.root.join("starts")).unwrap().count(), 2);
    assert!(
        result
            .files
            .iter()
            .all(|f| f.vector.as_ref().unwrap().len() == 512)
    );
    f.clean();
}

#[test]
fn a_crashed_worker_is_replaced_for_the_next_file() {
    let mut f = Fixture::new(|root| {
        format!(
            r#"
while IFS= read -r request; do
    if [ ! -e '{root}/crashed' ]; then /usr/bin/touch '{root}/crashed'; exit 17; fi
    /bin/cat '{root}/response.json'
    printf '\n'
done
"#,
            root = root.display()
        )
    });
    f.config.workers = 1;
    f.images(3);
    let result = f.run();
    assert_eq!(
        (
            result.summary.counts.files_ready,
            result.summary.counts.files_failed
        ),
        (2, 1)
    );
    assert_eq!(
        result.files[0].error.as_ref().unwrap().code,
        ErrorCode::WorkerFailed
    );
    assert!(result.files[0].file_id.is_some());
    f.clean();
}

#[test]
fn malformed_oversized_and_incompatible_worker_results_do_not_stop_text() {
    for kind in [
        "malformed",
        "oversized",
        "version",
        "dimensions",
        "family",
        "zero_vector",
    ] {
        let f = Fixture::new(|root| match kind {
            "malformed" => "printf 'not JSON\\n'".into(),
            "oversized" => "/usr/bin/head -c 1048577 /dev/zero".into(),
            _ => serve(root),
        });
        if matches!(kind, "dimensions" | "family") {
            response(
                &f.root.join("response.json"),
                if kind == "family" { "audio" } else { "image" },
                4096,
            );
        }
        if matches!(kind, "version" | "zero_vector") {
            let path = f.root.join("response.json");
            let mut value: serde_json::Value =
                serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            if kind == "version" {
                value["version"] = json!(VERSION - 1);
            } else {
                value["result"]["Ok"]["vector"] = json!(vec![0.0; 512]);
            }
            fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
        }
        f.images(1);
        fs::write(f.input.join("text.txt"), "still encodes complete text").unwrap();
        let result = f.run();
        assert_eq!(
            (
                result.summary.counts.files_ready,
                result.summary.counts.files_failed
            ),
            (1, 1),
            "{kind}"
        );
        assert!(
            result.files[0].file_id.is_some() && result.files[0].vector.is_none(),
            "{kind}"
        );
        assert_eq!(
            result.files[0].error.as_ref().unwrap().code,
            ErrorCode::WorkerFailed,
            "{kind}"
        );
        f.clean();
    }
}

#[test]
fn a_source_changed_during_native_encoding_loses_id_and_vector() {
    let f = Fixture::new(|root| {
        format!(
            r#"
while IFS= read -r request; do
    /usr/bin/touch '{root}/started'
    while [ ! -e '{root}/release' ]; do /bin/sleep 0.01; done
    /bin/cat '{root}/response.json'
    printf '\n'
done
"#,
            root = root.display()
        )
    });
    f.images(1);
    let input = f.input.clone();
    let config = f.config.clone();
    let thread = std::thread::spawn(move || {
        Encoder::new(config)
            .unwrap()
            .encode(
                &EncodeRequest::new(input),
                &CancellationToken::default(),
                |_| {},
            )
            .unwrap()
    });
    wait_for(&f.root.join("started"));
    fs::write(f.input.join("0.png"), b"\x89PNG\r\n\x1a\nchanged").unwrap();
    fs::write(f.root.join("release"), []).unwrap();
    let result = thread.join().unwrap();
    assert_eq!(result.summary.counts.files_failed, 1);
    assert!(result.files[0].file_id.is_none() && result.files[0].vector.is_none());
    assert_eq!(
        result.files[0].error.as_ref().unwrap().code,
        ErrorCode::SourceChanged
    );
    f.clean();
}

#[test]
fn cache_reuses_native_vectors_without_runtime_and_separates_backends() {
    let f = Fixture::new(serve);
    f.images(2);
    let original = f.run();
    let saved = f.root.join("vectors.json");
    write_vectors(&saved, &original).unwrap();
    let mut config = f.config.clone();
    config.runtime = RuntimeConfig::default();
    let mut request = EncodeRequest::new(&f.input);
    request.vectors_file = Some(saved);
    let cached = Encoder::new(config.clone())
        .unwrap()
        .encode(&request, &CancellationToken::default(), |_| {})
        .unwrap();
    assert_eq!(
        (
            cached.summary.counts.cache_hits,
            cached.summary.counts.vectors_encoded
        ),
        (2, 0)
    );
    assert_eq!(cached.summary.counts.bytes_hashed, 18);
    config.backend = profile::Backend::Coreml;
    let different = Encoder::new(config)
        .unwrap()
        .encode(&request, &CancellationToken::default(), |_| {})
        .unwrap();
    assert_eq!(
        (
            different.summary.counts.cache_hits,
            different.summary.counts.files_failed
        ),
        (0, 2)
    );
    assert!(
        different
            .files
            .iter()
            .all(|f| f.error.as_ref().unwrap().code == ErrorCode::RuntimeUnavailable)
    );
}

#[test]
fn staging_allowance_is_shared_and_oversized_files_still_get_an_id() {
    let mut f = Fixture::new(serve);
    f.images(3);
    f.config.staging_bytes = 2 * filetwin_core::worker_protocol::MAX_RESPONSE as u64 + 9;
    let good = f.run();
    assert_eq!(good.summary.counts.files_ready, 3);
    f.config.staging_bytes = 1;
    let limited = f.run();
    assert_eq!(limited.summary.counts.files_failed, 3);
    assert_eq!(limited.summary.counts.bytes_hashed, 27);
    assert!(limited.files.iter().all(|f| f.file_id.is_some()
        && f.vector.is_none()
        && f.error.as_ref().unwrap().code == ErrorCode::ResourceBudgetTooSmall));
    f.clean();
}

#[test]
fn cancellation_kills_worker_descendants_and_cleans_staging() {
    let f = Fixture::new(|root| {
        format!(
            "/bin/sleep 120 &\nprintf '%s' \"$!\" > '{}/decoder.pid'\nwait",
            root.display()
        )
    });
    f.images(1);
    let token = CancellationToken::default();
    let other = token.clone();
    let input = f.input.clone();
    let config = f.config.clone();
    let thread = std::thread::spawn(move || {
        Encoder::new(config)
            .unwrap()
            .encode(&EncodeRequest::new(input), &other, |_| {})
            .unwrap()
    });
    wait_for(&f.root.join("decoder.pid"));
    let pid: i32 = fs::read_to_string(f.root.join("decoder.pid"))
        .unwrap()
        .parse()
        .unwrap();
    token.cancel();
    let result = thread.join().unwrap();
    assert_eq!(result.exit_code(), 130);
    assert_eq!(result.summary.counts.files_processed, 0);
    assert!(!result.complete);
    f.clean();
    for _ in 0..100 {
        // SAFETY: signal zero only checks whether this disposable process exists.
        if unsafe { libc::kill(pid, 0) } != 0 {
            return;
        }
        #[cfg(target_os = "linux")]
        if fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|s| s.contains(") Z ")) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("Decoder still running after cancellation");
}

#[test]
fn memory_sources_and_local_memory_staging_never_send_an_original_path() {
    use std::sync::Arc;
    use filetwin_core::memory_input::MemoryInput;
    let mut f = Fixture::new(|root| {
        let script = root.join("memory-worker.py");
        fs::write(&script, format!(r#"import json,sys,pathlib,urllib.request
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line)
 assert r['memory_input']['url'].startswith('http://127.0.0.1:')
 assert not pathlib.Path(r['path']).exists(), 'A disk-backed original reached the worker'
 request=urllib.request.Request(r['memory_input']['url'],headers={{'Range':'bytes=0-7'}})
 assert urllib.request.urlopen(request).read()==bytes([137,80,78,71,13,10,26,10])
 print((root/'response.json').read_text(),flush=True)
"#, root=root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'",script.display())
    });
    f.config.memory_staging = true;
    f.images(1);
    let original = Arc::new(MemoryInput::new(b"\x89PNG\r\n\x1a\nunique".to_vec()));
    let weak = Arc::downgrade(&original);
    let result = streamed(&f,vec![EncodeSource::from_memory("remote.png",original.clone()),
        EncodeSource::from_memory("duplicate.png",original),
        EncodeSource::new("local.png",f.input.join("0.png"))], |_| {});
    assert_eq!(result.summary.counts.files_ready,3);
    assert_eq!(result.summary.counts.cache_hits,1);
    assert!(weak.upgrade().is_none(),"Completed original retained in RAM");
    f.clean();
}

#[test]
fn cancellation_releases_a_memory_original_after_the_native_worker_stops() {
    use std::sync::Arc;
    use filetwin_core::memory_input::MemoryInput;
    let f = Fixture::new(|_| "read request; sleep 30".into());
    let original = Arc::new(MemoryInput::new(b"\x89PNG\r\n\x1a\nunique".to_vec()));
    let weak = Arc::downgrade(&original);
    let mut sources = vec![EncodeSource::from_memory("remote.png",original)].into_iter();
    let cancel = CancellationToken::default();
    let started = Instant::now();
    let result = Encoder::new(f.config.clone()).unwrap().encode_sources(&EncodeRequest::new(&f.input), &cancel,
        || Ok(sources.next()), |p| { if p.work.as_ref().is_some_and(|w| w.encoding>0) {cancel.cancel();} }).unwrap();
    assert!(result.summary.cancelled); assert!(started.elapsed()<Duration::from_secs(3));
    assert!(weak.upgrade().is_none(),"Cancelled original retained in RAM");
    f.clean();
}

#[test]
fn native_ram_reader_copies_are_reserved_inside_the_analysis_budget() {
    for memory_scheduling in [false, true] {
    use filetwin_core::memory_input::MemoryInput;
    use std::sync::Arc;
    let mut f = Fixture::new(|root| format!("while IFS= read -r request; do /bin/sleep 0.25; /bin/cat '{}'; printf '\\n'; done", root.join("response.json").display()));
    f.config.workers = 2; f.config.memory_bytes = 1 << 30;
    f.config.memory_scheduling = memory_scheduling;
    let sources = (0..2).map(|i| {
        let mut data = vec![0;2 << 20]; data[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n"); data[8] = i;
        EncodeSource::from_memory(format!("{i}.png"), Arc::new(MemoryInput::new(data)))
    }).collect();
    let mut peak_memory = 0; let mut peak_active = 0;
    let result = streamed(&f,sources,|p| if let Some(work) = &p.work {
        assert!(work.memory_in_use <= work.memory_limit);
        peak_memory = peak_memory.max(work.memory_in_use); peak_active = peak_active.max(work.encoding);
    });
    assert_eq!(result.summary.counts.files_ready,2);
    assert_eq!(peak_active,1,"Two 512 MiB decoders plus their reader copies do not fit in 1 GiB");
    if !memory_scheduling { assert_eq!(peak_memory,(512 << 20) + (2 << 20)); }
    f.clean();
    }
}

/// Logical GB reservations avoid allocating GB of fixture data.
struct DownloadReservation {
    budget: std::sync::Arc<std::sync::Mutex<(u64, u64)>>,
    bytes: u64,
    active: std::sync::atomic::AtomicBool,
}
impl DownloadReservation {
    fn new(budget: &std::sync::Arc<std::sync::Mutex<(u64, u64)>>, bytes: u64) -> Self {
        let value = Self { budget: budget.clone(), bytes, active: false.into() };
        assert!(filetwin_core::memory_input::OriginalReservation::try_reacquire(&value)); value
    }
}
impl filetwin_core::memory_input::OriginalReservation for DownloadReservation {
    fn bytes(&self) -> u64 { self.bytes }
    fn release(&self) {
        let mut state = self.budget.lock().unwrap();
        if self.active.swap(false, std::sync::atomic::Ordering::SeqCst) { state.0 -= self.bytes; }
    }
    fn try_reacquire(&self) -> bool {
        let mut state = self.budget.lock().unwrap();
        if self.active.load(std::sync::atomic::Ordering::SeqCst) { return true; }
        if self.bytes > state.1 - state.0 { return false; }
        state.0 += self.bytes; self.active.store(true, std::sync::atomic::Ordering::SeqCst); true
    }
}
impl Drop for DownloadReservation {
    fn drop(&mut self) { filetwin_core::memory_input::OriginalReservation::release(self); }
}

#[test]
fn analysis_handoff_refills_all_40_gb_of_download_ram_within_the_combined_64_gb() {
    use filetwin_core::memory_input::MemoryInput;
    use std::sync::{Arc, Mutex};
    let mut f = Fixture::new(|root| format!("while IFS= read -r request; do /bin/sleep 0.3; /bin/cat '{}'; printf '\\n'; done", root.join("response.json").display()));
    f.config.memory_scheduling = true; f.config.memory_staging = true;
    f.config.memory_bytes = 24 << 30; f.config.staging_bytes = 40 << 30;
    let download = Arc::new(Mutex::new((0, 40 << 30)));
    let mut weak = Vec::new();
    let sources = (0..5).map(|i| {
        let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec(); bytes.push(i);
        let memory = Arc::new(MemoryInput::new(bytes).with_reservation(DownloadReservation::new(&download, 8 << 30)));
        weak.push(Arc::downgrade(&memory));
        EncodeSource::from_memory(format!("{i}.png"), memory)
    }).collect();
    assert_eq!(download.lock().unwrap().0, 40 << 30);
    let mut refilled = Vec::new(); let mut peak = 0;
    let result = streamed(&f, sources, |p| if let Some(work) = &p.work {
        let used = download.lock().unwrap().0;
        if work.encoding >= 2 && refilled.is_empty() {
            assert_eq!(used, 24 << 30, "Two originals must have left Download RAM");
            refilled.push(DownloadReservation::new(&download, 16 << 30));
            assert!(work.memory_in_use >= 17 << 30, "Analysis must own original buffers and decoder/copy allowances");
        }
        let used = download.lock().unwrap().0;
        assert!(used <= 40 << 30 && work.memory_in_use <= 24 << 30);
        peak = peak.max(used + work.memory_in_use);
        assert!(peak <= 64 << 30);
    });
    assert_eq!(result.summary.counts.files_ready, 5, "{:?}", result.files);
    assert!(!refilled.is_empty() && peak >= 57 << 30, "Download RAM could not refill during analysis");
    assert!(weak.iter().all(|m| m.upgrade().is_none()));
    drop(refilled); assert_eq!(download.lock().unwrap().0, 0); f.clean();
}

#[test]
fn handed_off_originals_survive_decoder_retries_with_a_full_download_queue() {
    use filetwin_core::memory_input::MemoryInput;
    use std::sync::{Arc, Mutex};
    for required in [1u64 << 30, (2u64 << 30) - (256 << 20) - 9] {
        let mut f = Fixture::new(|root| {
            let script = root.join("retry.py");
            fs::write(&script, format!(r#"import json,sys,pathlib,time
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line)
 time.sleep(0.3)
 if r['memory_bytes'] < {required}:
  print(json.dumps(dict(version=r['version'],result=dict(Err=dict(code='resource_budget_too_small',stage='image',message='More RAM',details=dict(required_memory_bytes={required}))))),flush=True)
 else: print((root/'response.json').read_text(),flush=True)
"#, root=root.to_str().unwrap())).unwrap();
            format!("exec /usr/bin/python3 -u '{}'", script.display())
        });
        f.config.memory_scheduling = true; f.config.memory_staging = true;
        f.config.memory_bytes = 2 << 30; f.config.staging_bytes = 512 << 20;
        let download = Arc::new(Mutex::new((0, 512 << 20)));
        let sources = (0..2).map(|i| {
            let mut data = b"\x89PNG\r\n\x1a\n".to_vec(); data.push(i);
            let memory = MemoryInput::new(data).with_reservation(DownloadReservation::new(&download, 256 << 20));
            EncodeSource::from_memory(format!("{i}.png"), Arc::new(memory))
        }).collect();
        let mut refilled = Vec::new();
        let started = Instant::now();
        let result = streamed(&f, sources, |p| if let Some(work) = &p.work {
            assert!(started.elapsed() < Duration::from_secs(10), "Retry deadlocked the RAM pools");
            if work.encoding == 2 && refilled.is_empty() {
                assert_eq!(download.lock().unwrap().0, 0);
                refilled.push(DownloadReservation::new(&download, 512 << 20));
            }
            assert!(work.memory_in_use <= 2 << 30);
            assert!(download.lock().unwrap().0 <= 512 << 20);
        });
        assert!(!refilled.is_empty());
        if required == 1 << 30 {
            assert_eq!(result.summary.counts.files_ready, 2, "{:?}", result.files);
        } else {
            assert_eq!(result.summary.counts.files_ready, 1);
            assert_eq!(result.summary.counts.files_failed, 1);
            assert!(result.files.iter().any(|r| r.error.as_ref().is_some_and(|e| e.code == ErrorCode::ResourceBudgetTooSmall)));
        }
        drop(refilled); assert_eq!(download.lock().unwrap().0, 0); f.clean();
    }
}

#[test]
fn cancellation_releases_handed_off_originals_after_stopping_workers() {
    use filetwin_core::memory_input::MemoryInput;
    use std::sync::{Arc, Mutex};
    let mut f = Fixture::new(|_| "/bin/sleep 60".into());
    f.config.memory_scheduling = true; f.config.memory_bytes = 2 << 30;
    let download = Arc::new(Mutex::new((0, 1 << 30)));
    let memory = Arc::new(MemoryInput::new(b"\x89PNG\r\n\x1a\n!".to_vec())
        .with_reservation(DownloadReservation::new(&download, 1 << 30)));
    let weak = Arc::downgrade(&memory);
    let mut sources = vec![EncodeSource::from_memory("one.png", memory)].into_iter();
    let token = CancellationToken::default(); let mut handed_off = false;
    let result = Encoder::new(f.config.clone()).unwrap().encode_sources(&EncodeRequest::new(&f.input), &token,
        || Ok(sources.next()), |p| if let Some(work) = &p.work { if work.encoding > 0 {
            assert_eq!(download.lock().unwrap().0, 0);
            assert!(work.memory_in_use >= (1 << 30) + (512 << 20));
            handed_off = true; token.cancel();
        }}).unwrap();
    assert!(handed_off && result.summary.cancelled && weak.upgrade().is_none());
    assert_eq!(download.lock().unwrap().0, 0); f.clean();
}

#[test]
fn coreml_jobs_follow_ram_admission_while_legacy_limits_and_cpu_progress_remain() {
    for memory_scheduling in [false, true] {
    let mut f = Fixture::new(|root| {
        let script=root.join("accelerator-worker.py");
        fs::write(&script,format!(r#"import json,sys,os,time,pathlib
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line); visual=r['format']!='pdf'; family='image' if visual else 'text'
 with (root/'events').open('a') as f: f.write('start:'+family+':'+str(os.getpid())+'\n')
 time.sleep(.3 if visual else .01)
 vector=[1.]+[0.]*(511 if visual else 4095)
 with (root/'events').open('a') as f: f.write('finish:'+family+':'+str(os.getpid())+'\n')
 print(json.dumps({{'version':r['version'],'result':{{'Ok':{{'family':family,'format':'fixture','vector':vector,'extraction':{{}}}}}}}}),flush=True)
"#,root=root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'",script.display())
    });
    f.config.backend=profile::Backend::Coreml; f.config.workers=8;
    f.config.memory_scheduling=memory_scheduling;
    f.config.accelerator_workers=1; f.config.memory_bytes=4<<30;
    f.images(4); let document=f.input.join("document.pdf"); fs::write(&document,b"%PDF-1.7 fixture").unwrap();
    let sources=vec![EncodeSource::new("0.png",f.input.join("0.png")),
        EncodeSource::new("1.png",f.input.join("1.png")),EncodeSource::new("document.pdf",document),
        EncodeSource::new("2.png",f.input.join("2.png")),EncodeSource::new("3.png",f.input.join("3.png"))];
    let capacity=f.config.accelerator_capacity();
    assert_eq!(capacity,if memory_scheduling { 8 } else { 1 });
    let mut peak=0; let mut accelerator_wait=false;
    let result=streamed(&f,sources,|p| if let Some(work)=&p.work {
        if p.stage == Stage::Encoding { assert_eq!(work.accelerator_limit,capacity); }
        assert!(work.accelerator_active<=capacity);
        peak=peak.max(work.accelerator_active);
        accelerator_wait |= work.waiting_accelerator > 0;
        assert_eq!(work.waiting_memory,0,"These small files fit the RAM pool; occupied slots must not be labelled as memory waits");
        assert!(work.memory_in_use<=work.memory_limit);
    });
    assert_eq!(result.summary.counts.files_ready,5,"{:?}",result.files);
    let events=fs::read_to_string(f.root.join("events")).unwrap();
    assert!(events.find("start:text:").unwrap()<events.find("finish:image:").unwrap(),"{events}");
    let pids:std::collections::HashSet<_>=events.lines().filter_map(|l|l.strip_prefix("start:image:")).collect();
    if memory_scheduling {
        assert!(peak>2,"Ready images must not remain restricted to two CoreML jobs: peak={peak}");
    } else {
        assert_eq!(pids.len(),1,"Legacy visual models must reuse their dedicated slot");
        assert!(accelerator_wait,"A queued legacy CoreML job must report its occupied accelerator slot");
    }
    assert!(pids.len()<=capacity,"Visual models must stay in the same RAM-bounded slot set");
    f.clean();
    }
}

#[test]
fn accelerated_capacity_tracks_ram_and_host_resources_in_memory_mode() {
    let mut config=EncoderConfig::new("models","temp");
    config.backend=profile::Backend::Coreml; config.workers=416;
    config.memory_scheduling=true; config.memory_bytes=52 << 30;
    assert_eq!(config.accelerator_capacity(),104);
    config.accelerator_workers=0;
    assert_eq!(config.accelerator_capacity(),104,"Legacy accelerator preference is ignored");
    config.memory_bytes=2 << 30; assert_eq!(config.accelerator_capacity(),4);
    config.workers=3; assert_eq!(config.accelerator_capacity(),3,"Host OS resource ceiling still applies");
    config.memory_scheduling=false; config.accelerator_workers=2;
    assert_eq!(config.accelerator_capacity(),2,"Legacy host behavior is unchanged");
}

#[test]
fn memory_admission_uses_reader_cost_instead_of_equal_worker_shares() {
    let mut f = Fixture::new(|root| {
        let script=root.join("memory-worker.py");
        fs::write(&script,format!(r#"import json,sys,time,pathlib
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line); visual=r['format']!='pdf'; family='image' if visual else 'text'
 with (root/'allowances').open('a') as f: f.write(f"{{family}}:{{r['memory_bytes']}}\n")
 time.sleep(.4)
 print(json.dumps({{'version':r['version'],'result':{{'Ok':{{'family':family,'format':'fixture','vector':[1.]+[0.]*(511 if visual else 4095),'extraction':{{}}}}}}}}),flush=True)
"#,root=root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'",script.display())
    });
    f.config.memory_scheduling=true; f.config.workers=64; f.config.memory_bytes=1 << 30;
    f.images(2);
    let mut sources=Vec::new();
    for i in 0..5 {
        let path=f.input.join(format!("{i}.pdf")); fs::write(&path,format!("%PDF-1.7 {i}")).unwrap();
        sources.push(EncodeSource::new(format!("{i}.pdf"),path));
    }
    sources.push(EncodeSource::new("0.png",f.input.join("0.png")));
    sources.push(EncodeSource::new("1.png",f.input.join("1.png")));
    let mut peak=0; let mut reserved=0;
    let result=streamed(&f,sources,|p| if let Some(work)=&p.work {
        assert!(work.memory_scheduling); assert!(work.memory_in_use<=work.memory_limit);
        peak=peak.max(work.encoding); reserved=work.memory_in_use;
    });
    assert_eq!(result.summary.counts.files_ready,7,"{:?}",result.files);
    assert!(peak>=4,"Small document readers should overlap within the same 1 GiB, peak={peak}");
    assert_eq!(reserved,0);
    let allowances=fs::read_to_string(f.root.join("allowances")).unwrap();
    assert!(allowances.lines().any(|line| line==format!("text:{}",128 << 20)));
    assert!(allowances.lines().any(|line| line==format!("image:{}",512 << 20)));
    f.clean();
}

#[test]
fn memory_retry_does_not_deadlock_with_original_ram_waiters() {
    let mut f=Fixture::new(|root| {
        let script=root.join("grow.py");
        fs::write(&script,format!(r#"import json,sys,pathlib
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line)
 if r['memory_bytes'] < 1024**3:
  print(json.dumps({{'version':r['version'],'result':{{'Err':{{'code':'resource_budget_too_small','stage':'image','message':'More RAM','details':{{'required_memory_bytes':1024**3}}}}}}}}),flush=True)
 else: print((root/'response.json').read_text(),flush=True)
"#,root=root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'",script.display())
    });
    f.config.memory_scheduling=true; f.config.workers=64; f.config.memory_bytes=1 << 30;
    f.config.staging_bytes=2 * filetwin_core::worker_protocol::MAX_RESPONSE as u64 + 9;
    f.images(8);
    let started=Instant::now();
    let sources=(0..8).map(|i|EncodeSource::new(format!("{i}.png"),f.input.join(format!("{i}.png")))).collect();
    let result=streamed(&f,sources,|p| {
        assert!(started.elapsed()<Duration::from_secs(10),"Analysis reservation blocked originals from draining");
        if let Some(work)=&p.work { assert!(work.memory_in_use<=work.memory_limit); }
    });
    assert_eq!(result.summary.counts.files_ready,8,"{:?}",result.files); f.clean();
}

#[test]
fn live_ram_edits_apply_while_a_decoder_is_busy_and_keep_its_original() {
    use filetwin_core::memory_input::MemoryInput;
    use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
    for backend in [profile::Backend::Cpu, profile::Backend::Coreml] {
    for initial_gb in [1, 4] {
        let mut f = Fixture::new(|root| {
            let script = root.join("live-resources.py");
            fs::write(&script, format!(r#"import json,sys,time,pathlib,os
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line); name=pathlib.Path(r['path']).stem
 with (root/'events').open('a') as log: log.write('start:'+name+':'+str(os.getpid())+'\n')
 while name=='0' and not (root/'release-first').exists(): time.sleep(.01)
 family='text' if r['format']=='pdf' else 'image'
 print(json.dumps({{'version':r['version'],'result':{{'Ok':{{'family':family,'format':'fixture','vector':[1.]+[0.]*(4095 if family=='text' else 511),'extraction':{{}}}}}}}}),flush=True)
"#, root=root.to_str().unwrap())).unwrap();
            format!("exec /usr/bin/python3 -u '{}'", script.display())
        });
        f.config.backend = backend;
        f.config.memory_scheduling = true; f.config.memory_staging = true;
        f.config.workers = 32; f.config.memory_bytes = initial_gb << 30;
        let mut originals = Vec::new();
        let mut sources = (0..4).map(|i| {
            // A CoreML scan's CPU document occupies a high slot, which must
            // survive a capacity reduction until its reply has been received.
            let pdf = i == 0 && backend == profile::Backend::Coreml;
            let mut bytes = if pdf { b"%PDF-1.7 fixture".to_vec() } else { b"\x89PNG\r\n\x1a\n".to_vec() };
            bytes.push(i);
            let original = Arc::new(MemoryInput::new(bytes));
            originals.push(Arc::downgrade(&original));
            EncodeSource::from_memory(format!("{i}.{}", if pdf { "pdf" } else { "png" }), original)
        }).collect::<Vec<_>>().into_iter();
        let feed = Arc::new(AtomicBool::new(false));
        let mut first = true; let mut requested = false; let mut applied = false;
        let mut completed_while_first_busy = false;
        let token = CancellationToken::default(); let started = Instant::now();
        let mut last_limit = 0;
        let result = Encoder::new(f.config.clone()).unwrap().encode_stream(
            &EncodeRequest::new(&f.input), &token,
            || {
                if !first && !feed.load(Ordering::Acquire) { return Ok(EncodeSourcePoll::Pending); }
                first = false;
                Ok(sources.next().map_or(EncodeSourcePoll::Complete, EncodeSourcePoll::Ready))
            },
            |p| {
                if started.elapsed() > Duration::from_secs(15) { token.cancel(); }
                if let Some(work) = &p.work {
                    last_limit = work.memory_limit;
                    if !requested && work.encoding > 0 {
                        requested = true;
                        token.set_paused(true);
                        token.update_resources(LiveResources { workers:16, memory_bytes:2 << 30, staging_bytes:512 << 20 });
                    } else if requested && !applied && work.memory_limit == 2 << 30 {
                        assert!(token.is_paused(), "Resources must apply even before Resume");
                        assert!(work.encoding > 0, "The active decoder must survive the edit");
                        assert!(originals[0].upgrade().is_some(), "The active original was lost");
                        assert_eq!(work.worker_limit,16);
                        applied = true; feed.store(true, Ordering::Release); token.set_paused(false);
                    }
                    if applied { assert_eq!(work.memory_limit,2 << 30,"Progress reverted to the startup allowance"); }
                    assert!(work.memory_in_use <= work.memory_limit);
                    if applied && p.counts.files_processed >= 3 && !completed_while_first_busy {
                        assert!(originals[0].upgrade().is_some());
                        completed_while_first_busy = true;
                        fs::write(f.root.join("release-first"), []).unwrap();
                    }
                }
            }).unwrap();
        assert!(requested && applied && completed_while_first_busy, "Live edits blocked behind an active decoder: {backend:?}, {initial_gb} GB");
        assert_eq!(result.summary.counts.files_ready,4,"{:?}",result.files);
        assert_eq!(last_limit,2 << 30);
        assert_eq!(result.summary.workers,16);
        assert!(originals.iter().all(|weak| weak.upgrade().is_none()));
        let events = fs::read_to_string(f.root.join("events")).unwrap();
        for i in 0..4 { assert_eq!(events.lines().filter(|line|line.starts_with(&format!("start:{i}:"))).count(),1,"An original was restarted: {events}"); }
        f.clean();
    }
    }
}

#[test]
fn live_ram_reduction_below_active_usage_drains_before_admitting_more() {
    use filetwin_core::memory_input::MemoryInput;
    use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
    let mut f = Fixture::new(|root| {
        let script = root.join("drain-resources.py");
        fs::write(&script, format!(r#"import json,sys,time,pathlib
root=pathlib.Path({root:?})
for line in sys.stdin:
 r=json.loads(line); name=pathlib.Path(r['path']).stem
 with (root/'events').open('a') as log: log.write('start:'+name+'\n')
 while name in ('0','1') and not (root/('release-'+name)).exists(): time.sleep(.01)
 print((root/'response.json').read_text(),flush=True)
"#,root=root.to_str().unwrap())).unwrap();
        format!("exec /usr/bin/python3 -u '{}'",script.display())
    });
    f.config.memory_scheduling = true; f.config.memory_staging = true;
    f.config.workers = 16; f.config.memory_bytes = 2 << 30;
    let mut sources = (0..3).map(|i| {
        let mut data = b"\x89PNG\r\n\x1a\n".to_vec(); data.push(i);
        EncodeSource::from_memory(format!("{i}.png"), Arc::new(MemoryInput::new(data)))
    }).collect::<Vec<_>>().into_iter();
    let feed = AtomicBool::new(false); let mut count = 0;
    let token = CancellationToken::default(); let started = Instant::now();
    let mut requested = false; let mut draining = false; let mut checked_wait = false;
    let result = Encoder::new(f.config.clone()).unwrap().encode_stream(
        &EncodeRequest::new(&f.input), &token,
        || {
            if count >= 2 && !feed.load(Ordering::Acquire) { return Ok(EncodeSourcePoll::Pending); }
            count += 1;
            Ok(sources.next().map_or(EncodeSourcePoll::Complete,EncodeSourcePoll::Ready))
        },
        |p| {
            if started.elapsed() > Duration::from_secs(15) { token.cancel(); }
            let Some(work) = &p.work else { return };
            if !requested && work.encoding == 2 {
                requested = true; token.set_paused(true);
                token.update_resources(LiveResources {workers:16,memory_bytes:600 << 20,staging_bytes:512 << 20});
            } else if requested && !draining && work.memory_limit == 600 << 20 {
                assert_eq!(work.encoding,2); assert!(work.memory_in_use > work.memory_limit);
                draining = true; fs::write(f.root.join("release-0"),[]).unwrap();
                feed.store(true,Ordering::Release); token.set_paused(false);
            } else if draining && !checked_wait && p.counts.files_processed == 1 && work.ready > 0 {
                assert_eq!(work.encoding,1); assert!(work.memory_in_use <= work.memory_limit);
                assert!(!fs::read_to_string(f.root.join("events")).unwrap().contains("start:2"));
                checked_wait = true; fs::write(f.root.join("release-1"),[]).unwrap();
            }
        }).unwrap();
    assert!(draining && checked_wait, "RAM shrink did not preserve active work and gate new admission");
    assert_eq!(result.summary.counts.files_ready,3,"{:?}",result.files);
    f.clean();
}

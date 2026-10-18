//! Provider range sources are distinct from whole-original hashes and buffers.
use filetwin_core::{
    api::*,
    memory_input::{MemoryServer, Reader, SeekableInput},
    profile, Encoder,
};
use std::{
    io::{Read, Seek, SeekFrom, Write},
    os::unix::fs::PermissionsExt,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
};

struct Generated {
    id: String,
    len: u64,
    read: AtomicU64,
    poisoned: AtomicBool,
    fail_offset: u64,
}
impl Generated {
    fn new(len: u64) -> Arc<Self> {
        Arc::new(Self {
            id: format!("gcid:{}:{len}", "a".repeat(40)),
            len,
            read: AtomicU64::new(0),
            poisoned: AtomicBool::new(false),
            fail_offset: u64::MAX,
        })
    }
}
impl SeekableInput for Generated {
    fn len(&self) -> u64 {
        self.len
    }
    fn content_id(&self) -> &str {
        &self.id
    }
    fn current(&self) -> bool {
        !self.poisoned.load(Ordering::Acquire)
    }
    fn read_at(&self, offset: u64, bytes: &mut [u8], stop: &AtomicBool) -> std::io::Result<usize> {
        if stop.load(Ordering::Acquire) {
            return Err(std::io::ErrorKind::Interrupted.into());
        }
        if offset >= self.fail_offset {
            self.poisoned.store(true, Ordering::Release);
            return Err(std::io::ErrorKind::InvalidData.into());
        }
        let n = bytes.len().min(
            self.len
                .saturating_sub(offset)
                .try_into()
                .unwrap_or(usize::MAX),
        );
        for (i, b) in bytes[..n].iter_mut().enumerate() {
            let at = offset + i as u64;
            *b = if at < 12 {
                b"\0\0\0\x18ftypisom"[at as usize]
            } else {
                (at % 251) as u8
            };
        }
        self.read.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
}
#[test]
fn distant_seek_does_not_read_the_gap_and_content_ids_are_truthful() {
    let original = Generated::new(8 << 30);
    let mut reader = Reader::seekable(original.clone());
    reader.seek(SeekFrom::End(-8)).unwrap();
    let mut tail = [0; 8];
    reader.read_exact(&mut tail).unwrap();
    assert_eq!(original.read.load(Ordering::Relaxed), 8);
    assert!(reader.seek(SeekFrom::Start(0)).is_ok());
    assert!(reader.seek(SeekFrom::Current(-1)).is_err());
    assert!(filetwin_core::valid_content_id(
        &original.id,
        Some(original.len)
    ));
    assert!(!filetwin_core::valid_content_id(
        &original.id,
        Some(original.len - 1)
    ));
    assert!(!filetwin_core::valid_content_id(
        &format!("gcid:{}:08", "a".repeat(40)),
        Some(8)
    ));
    assert!(!filetwin_core::valid_content_id(
        &format!("gcid:{}:invalid", "a".repeat(40)),
        None
    ));
    assert!(!filetwin_core::valid_content_id(
        &format!("gcid:{}:8", "A".repeat(40)),
        Some(8)
    ));
}
#[test]
fn loopback_range_reads_fetch_only_the_requested_bytes() {
    let original = Generated::new(8 << 30);
    let server = MemoryServer::new_seekable(original.clone()).unwrap();
    let (address, path) = server.location.address().unwrap();
    let mut socket = std::net::TcpStream::connect(address).unwrap();
    write!(socket, "GET /{path} HTTP/1.1\r\nRange: bytes=-16\r\n\r\n").unwrap();
    let mut reply = Vec::new();
    socket.read_to_end(&mut reply).unwrap();
    assert!(reply.starts_with(b"HTTP/1.1 206"));
    assert_eq!(original.read.load(Ordering::Relaxed), 16);
    drop(server);
}
#[test]
fn seekable_media_encodes_without_reading_or_hashing_the_complete_original() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let models = root.join("models");
    let staging = root.join("staging");
    std::fs::create_dir(&models).unwrap();
    std::fs::create_dir(&staging).unwrap();
    std::fs::write(models.join(profile::SSCD_MODEL_FILE), []).unwrap();
    let worker = root.join("worker");
    std::fs::write(&worker,r##"#!/usr/bin/python3
import sys,json,urllib.request
for line in sys.stdin:
 r=json.loads(line)
 assert r['path']=='original.mp4'
 assert r['memory_input']['bytes']==8589934592
 assert not any('http' in str(v) for k,v in r.items() if k!='memory_input')
 for span in ['bytes=0-15','bytes=-16']:
  q=urllib.request.Request(r['memory_input']['url'],headers={'Range':span})
  with urllib.request.urlopen(q) as response:
   assert response.status==206 and len(response.read())==16
 print(json.dumps({'version':r['version'],'result':{'Ok':{'family':'video','format':'mp4','vector':[1.0]+[0.0]*511,'extraction':{'generated':True}}}}),flush=True)
"##).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    let library = root.join("library");
    std::fs::write(&library, []).unwrap();
    let mut config = EncoderConfig::new(&models, &staging);
    config.memory_scheduling = true;
    config.memory_staging = true;
    config.workers = 2;
    config.memory_bytes = 2 << 30;
    config.staging_bytes = 256 << 20;
    config.runtime = RuntimeConfig {
        worker_path: Some(worker.clone()),
        ffmpeg_path: Some(worker.clone()),
        ffprobe_path: Some(worker),
        onnxruntime_path: Some(library.clone()),
        pdfium_path: Some(library),
        ..RuntimeConfig::default()
    };
    let original = Generated::new(8 << 30);
    let source = EncodeSource::from_seekable("original.mp4", original.clone())
        .with_families(vec!["video".into()]);
    let mut source = Some(source);
    let result = Encoder::new(config)
        .unwrap()
        .encode_sources(
            &EncodeRequest::new(&root),
            &CancellationToken::default(),
            || Ok(source.take()),
            |_| {},
        )
        .unwrap();
    assert_eq!(result.files.len(), 1);
    assert_eq!(
        result.files[0].state,
        FileState::Ready,
        "{:?}",
        result.files[0].error
    );
    assert_eq!(
        result.files[0].file_id.as_deref(),
        Some(original.id.as_str())
    );
    assert_eq!(result.summary.counts.bytes_hashed, 0);
    assert!(original.read.load(Ordering::Relaxed) < 8192);
    let vectors = root.join("vectors.json");
    filetwin_core::write_vectors(&vectors, &result).unwrap();
    assert_eq!(
        filetwin_core::read_vectors(&vectors).unwrap().files[0].file_id,
        result.files[0].file_id
    );
}

#[test]
fn a_worker_cannot_publish_a_partial_vector_after_a_failed_distant_range() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let models = root.join("models");
    let staging = root.join("staging");
    std::fs::create_dir(&models).unwrap();
    std::fs::create_dir(&staging).unwrap();
    std::fs::write(models.join(profile::SSCD_MODEL_FILE), []).unwrap();
    let worker = root.join("worker");
    std::fs::write(&worker,r##"#!/usr/bin/python3
import sys,json,urllib.request
for line in sys.stdin:
 r=json.loads(line)
 try:
  q=urllib.request.Request(r['memory_input']['url'],headers={'Range':'bytes=4096-4111'})
  urllib.request.urlopen(q).read()
 except Exception:
  pass
 print(json.dumps({'version':r['version'],'result':{'Ok':{'family':'video','format':'mp4','vector':[1.0]+[0.0]*511,'extraction':{'partial_success':True}}}}),flush=True)
"##).unwrap();
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
    let library = root.join("library");
    std::fs::write(&library, []).unwrap();
    let mut config = EncoderConfig::new(&models, &staging);
    config.memory_scheduling = true;
    config.memory_staging = true;
    config.workers = 1;
    config.memory_bytes = 2 << 30;
    config.staging_bytes = 256 << 20;
    config.runtime = RuntimeConfig {
        worker_path: Some(worker.clone()),
        ffmpeg_path: Some(worker.clone()),
        ffprobe_path: Some(worker),
        onnxruntime_path: Some(library.clone()),
        pdfium_path: Some(library),
        ..RuntimeConfig::default()
    };
    let original = Arc::new(Generated {
        id: format!("gcid:{}:8589934592", "a".repeat(40)),
        len: 8 << 30,
        read: AtomicU64::new(0),
        poisoned: AtomicBool::new(false),
        fail_offset: 4096,
    });
    let mut source = Some(
        EncodeSource::from_seekable("original.mp4", original.clone())
            .with_families(vec!["video".into()]),
    );
    let result = Encoder::new(config)
        .unwrap()
        .encode_sources(
            &EncodeRequest::new(&root),
            &CancellationToken::default(),
            || Ok(source.take()),
            |_| {},
        )
        .unwrap();
    assert_eq!(result.files[0].state, FileState::Failed);
    assert_eq!(
        result.files[0].error.as_ref().unwrap().code,
        filetwin_core::ErrorCode::SourceChanged
    );
    assert!(result.files[0].vector.is_none() && result.files[0].file_id.is_none());
}

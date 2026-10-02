//! Read-only, seekable transport for originals held in RAM. Nothing in this
//! module creates a file. A short-lived loopback endpoint lets FFmpeg seek
//! without its disk-backed cache protocol or a second staged original.
use std::{
    io::{Read, Write}, net::{TcpListener, TcpStream},
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, thread::JoinHandle, time::Duration,
};
use serde::{Deserialize, Serialize};

/// Create a private IPC entry, never a regular file containing original data.
pub fn create_pipe(path: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let name = std::ffi::CString::new(path.as_os_str().as_bytes())?;
    // SAFETY: CString owns the terminated pathname for the duration of mkfifo.
    if unsafe { libc::mkfifo(name.as_ptr(), 0o600) } != 0 { return Err(std::io::Error::last_os_error()); }
    Ok(())
}

/// A completed original can move between host download/staging RAM and analysis
/// RAM without copying its bytes. Each transition reserves the destination first.
pub trait OriginalReservation: Send + Sync {
    fn bytes(&self) -> u64;
    fn release(&self);
    fn try_reacquire(&self) -> bool;
}
struct InputReservation {
    original: Box<dyn OriginalReservation>,
    analysis: Option<Box<dyn std::any::Any + Send + Sync>>,
}
pub struct MemoryInput {
    data: Box<dyn AsRef<[u8]> + Send + Sync>,
    _guard: Option<Box<dyn std::any::Any + Send + Sync>>,
    reservation: Mutex<Option<InputReservation>>,
}
impl std::fmt::Debug for MemoryInput {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.debug_struct("MemoryInput").field("bytes",&self.as_ref().len()).finish() }
}
impl MemoryInput {
    pub fn new(data: Vec<u8>) -> Self { Self::from_buffer(data) }
    /// Retain a host-owned anonymous RAM buffer without copying a complete
    /// original into a second Vec. No mutation is exposed after handoff.
    pub fn from_buffer(data: impl AsRef<[u8]> + Send + Sync + 'static) -> Self {
        Self { data: Box::new(data), _guard: None, reservation: Mutex::new(None) }
    }
    pub fn retaining(mut self, guard: impl std::any::Any + Send + Sync) -> Self {
        self._guard = Some(Box::new(guard)); self
    }
    pub fn with_reservation(mut self, original: impl OriginalReservation + 'static) -> Self {
        assert!(original.bytes() >= self.as_ref().len() as u64, "Original RAM must cover the buffer");
        self.reservation = Mutex::new(Some(InputReservation { original: Box::new(original), analysis: None })); self
    }
    pub(crate) fn original_bytes(&self) -> u64 {
        self.reservation.lock().unwrap().as_ref().map_or(0, |r| r.original.bytes())
    }
    pub(crate) fn analysis_bytes(&self) -> u64 {
        self.reservation.lock().unwrap().as_ref().filter(|r| r.analysis.is_some()).map_or(0, |r| r.original.bytes())
    }
    pub(crate) fn move_to_analysis(&self, guard: impl std::any::Any + Send + Sync) {
        let mut state = self.reservation.lock().unwrap();
        let reservation = state.as_mut().expect("Original reservation");
        assert!(reservation.analysis.is_none());
        reservation.analysis = Some(Box::new(guard));
        reservation.original.release();
    }
    pub(crate) fn return_to_download(&self) -> bool {
        let mut state = self.reservation.lock().unwrap();
        let Some(reservation) = state.as_mut() else { return true; };
        if reservation.analysis.is_none() { return true; }
        if !reservation.original.try_reacquire() { return false; }
        reservation.analysis.take();
        true
    }
}
impl AsRef<[u8]> for MemoryInput { fn as_ref(&self) -> &[u8] { self.data.as_ref().as_ref() } }

pub struct SharedInput(pub Arc<MemoryInput>);
impl AsRef<[u8]> for SharedInput { fn as_ref(&self) -> &[u8] { self.0.as_ref().as_ref() } }
pub enum Reader { File(std::fs::File), Memory(std::io::Cursor<SharedInput>) }
impl Reader {
    pub fn memory(input: Arc<MemoryInput>) -> Self { Self::Memory(std::io::Cursor::new(SharedInput(input))) }
    pub fn data(&self) -> Option<Arc<MemoryInput>> { match self { Self::Memory(c)=>Some(c.get_ref().0.clone()), _=>None } }
}
impl Read for Reader {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> { match self { Self::File(f)=>f.read(bytes), Self::Memory(c)=>c.read(bytes) } }
}
impl std::io::Seek for Reader {
    fn seek(&mut self, from: std::io::SeekFrom) -> std::io::Result<u64> { match self { Self::File(f)=>f.seek(from), Self::Memory(c)=>c.seek(from) } }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemoryLocation { pub url: String, pub bytes: u64 }

pub struct MemoryServer {
    pub location: MemoryLocation,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

// A decoder can keep its current HTTP response alive until the replacement
// range request succeeds. Serve those reads independently, with a per-original
// limit so stalled clients cannot create an unbounded number of threads.
const MAX_MEMORY_READERS: usize = 8;

impl MemoryServer {
    pub fn new(input: Arc<MemoryInput>) -> std::io::Result<Self> {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let address = listener.local_addr()?;
        let mut random = [0u8; 32];
        // SAFETY: random is a writable 32-byte buffer; getentropy accepts up to
        // 256 bytes. This does not open /dev/urandom or a content file.
        if unsafe { libc::getentropy(random.as_mut_ptr().cast(), random.len()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let path = format!("/{}", random.iter().map(|b| format!("{b:02x}")).collect::<String>());
        let location = MemoryLocation { url: format!("http://{address}{path}"), bytes: input.as_ref().as_ref().len() as u64 };
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = std::thread::Builder::new().name("filetwin-memory".into()).spawn(move || {
            let mut readers: Vec<JoinHandle<()>> = Vec::new();
            while !stopping.load(Ordering::Acquire) {
                for i in (0..readers.len()).rev() {
                    if readers[i].is_finished() { let _ = readers.swap_remove(i).join(); }
                }
                match listener.accept() {
                    Ok((mut socket, _)) => {
                        if readers.len() == MAX_MEMORY_READERS {
                            let _ = socket.set_write_timeout(Some(Duration::from_millis(200)));
                            let _ = socket.write_all(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                            continue;
                        }
                        let input = input.clone();
                        let path = path.clone();
                        let stopping = stopping.clone();
                        if let Ok(reader) = std::thread::Builder::new()
                            .name("filetwin-memory-read".into()).stack_size(256 * 1024)
                            .spawn(move || { let _ = serve(&mut socket, &path, input.as_ref().as_ref(), &stopping); })
                        { readers.push(reader); }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(5)),
                    Err(_) => break,
                }
            }
            stopping.store(true, Ordering::Release);
            // Join every reader before releasing the original and its RAM
            // reservation, including on cancellation or listener failure.
            for reader in readers { let _ = reader.join(); }
        })?;
        Ok(Self { location, stop, thread: Some(thread) })
    }
}
impl Drop for MemoryServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() { let _ = thread.join(); }
    }
}

fn header(socket: &mut TcpStream, stop: Option<&AtomicBool>) -> std::io::Result<String> {
    let mut bytes = Vec::new();
    let mut byte = [0u8];
    let started = std::time::Instant::now();
    while bytes.len() < 8192 {
        if stop.is_some_and(|s| s.load(Ordering::Acquire)) { return Err(std::io::ErrorKind::Interrupted.into()); }
        if started.elapsed() >= Duration::from_secs(30) { return Err(std::io::ErrorKind::TimedOut.into()); }
        match socket.read_exact(&mut byte) {
            Ok(()) => bytes.push(byte[0]),
            Err(e) if matches!(e.kind(),std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted) => continue,
            Err(e) => return Err(e),
        }
        if bytes.ends_with(b"\r\n\r\n") {
            return String::from_utf8(bytes).map_err(|_| std::io::ErrorKind::InvalidData.into());
        }
    }
    Err(std::io::ErrorKind::InvalidData.into())
}
fn range(value: &str, len: usize) -> Option<(usize, usize)> {
    let (start, end) = value.strip_prefix("bytes=")?.split_once('-')?;
    if len == 0 { return None; }
    if start.is_empty() {
        let tail = end.parse::<usize>().ok()?;
        return (tail > 0).then(|| (len.saturating_sub(tail), len));
    }
    let start = start.parse::<usize>().ok()?;
    let end = if end.is_empty() { len } else { end.parse::<usize>().ok()?.saturating_add(1).min(len) };
    (start < end && start < len).then_some((start, end))
}
fn serve(socket: &mut TcpStream, path: &str, bytes: &[u8], stop: &AtomicBool) -> std::io::Result<()> {
    socket.set_read_timeout(Some(Duration::from_millis(200)))?;
    socket.set_write_timeout(Some(Duration::from_millis(200)))?;
    let header = header(socket, Some(stop))?;
    let mut lines = header.lines();
    let mut request = lines.next().unwrap_or("").split_whitespace();
    let method = request.next().unwrap_or("");
    if !matches!(method, "GET" | "HEAD") || request.next() != Some(path) {
        return socket.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
    let wanted = lines.filter_map(|l| l.split_once(':')).find(|(k,_)| k.eq_ignore_ascii_case("range")).map(|(_,v)|v.trim());
    let (start, end) = match wanted {
        Some(value) => match range(value, bytes.len()) {
            Some(range) => range,
            None => return write!(socket,"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", bytes.len()),
        },
        None => (0, bytes.len()),
    };
    write!(socket, "HTTP/1.1 {}\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nConnection: close\r\n", if wanted.is_some() {"206 Partial Content"} else {"200 OK"}, end-start)?;
    if wanted.is_some() { write!(socket,"Content-Range: bytes {}-{}/{}\r\n", start,end-1,bytes.len())?; }
    socket.write_all(b"\r\n")?;
    if method != "HEAD" {
        for chunk in bytes[start..end].chunks(64*1024) {
            let mut written = 0;
            let started = std::time::Instant::now();
            while written < chunk.len() {
                if stop.load(Ordering::Acquire) { return Ok(()); }
                match socket.write(&chunk[written..]) {
                    Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
                    Ok(n) => written += n,
                    Err(e) if matches!(e.kind(),std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted)
                        && started.elapsed() < Duration::from_secs(30) => {},
                    Err(e) => return Err(e),
                }
            }
        }
    }
    Ok(())
}

impl MemoryLocation {
    /// Deliberately accepts only the transport's numeric loopback address and
    /// unguessable path. No DNS, proxy, redirect, cookies or response caching.
    pub fn address(&self) -> std::io::Result<(std::net::SocketAddr, &str)> {
        let (authority, path) = self.url.strip_prefix("http://127.0.0.1:")
            .and_then(|s| s.split_once('/')).ok_or(std::io::ErrorKind::InvalidInput)?;
        let port: u16 = authority.parse().map_err(|_|std::io::ErrorKind::InvalidInput)?;
        if port == 0 || path.len() != 64 || !path.bytes().all(|c| c.is_ascii_hexdigit()) { return Err(std::io::ErrorKind::InvalidInput.into()); }
        Ok((std::net::SocketAddr::from(([127,0,0,1],port)),path))
    }
    pub fn read(&self) -> std::io::Result<Vec<u8>> {
        let (address,path) = self.address()?;
        let mut socket = TcpStream::connect_timeout(&address, Duration::from_secs(5))?;
        socket.set_read_timeout(Some(Duration::from_secs(30)))?;
        socket.set_write_timeout(Some(Duration::from_secs(5)))?;
        write!(socket,"GET /{path} HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n")?;
        let head = header(&mut socket, None)?;
        if !head.starts_with("HTTP/1.1 200 ") { return Err(std::io::ErrorKind::InvalidData.into()); }
        let length = head.lines().filter_map(|l|l.split_once(':')).find(|(k,_)|k.eq_ignore_ascii_case("content-length")).and_then(|(_,v)|v.trim().parse::<u64>().ok());
        if length != Some(self.bytes) { return Err(std::io::ErrorKind::InvalidData.into()); }
        let length = usize::try_from(self.bytes).map_err(|_|std::io::ErrorKind::OutOfMemory)?;
        let mut bytes = Vec::new();
        bytes.try_reserve_exact(length).map_err(|_|std::io::ErrorKind::OutOfMemory)?;
        bytes.resize(length, 0);
        socket.read_exact(&mut bytes)?;
        if socket.read(&mut [0u8;1])? != 0 { return Err(std::io::ErrorKind::InvalidData.into()); }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handoff_keeps_the_same_buffer_and_analysis_lease_until_the_last_reader_drops() {
        struct Lease { live: Arc<AtomicBool> }
        impl Drop for Lease { fn drop(&mut self) { self.live.store(false, Ordering::SeqCst); } }
        impl OriginalReservation for Lease {
            fn bytes(&self) -> u64 { 4 }
            fn release(&self) { self.live.store(false, Ordering::SeqCst); }
            fn try_reacquire(&self) -> bool { self.live.store(true, Ordering::SeqCst); true }
        }
        let download = Arc::new(AtomicBool::new(true));
        let analysis = Arc::new(AtomicBool::new(true));
        let input = Arc::new(MemoryInput::new(b"data".to_vec()).with_reservation(Lease { live: download.clone() }));
        let pointer = input.as_ref().as_ref().as_ptr();
        let reader = Reader::memory(input.clone());
        input.move_to_analysis(Lease { live: analysis.clone() });
        assert!(!download.load(Ordering::SeqCst) && analysis.load(Ordering::SeqCst));
        assert_eq!(input.analysis_bytes(), 4);
        assert_eq!(input.as_ref().as_ref().as_ptr(), pointer);
        assert!(input.return_to_download());
        assert!(download.load(Ordering::SeqCst) && !analysis.load(Ordering::SeqCst));
        analysis.store(true, Ordering::SeqCst);
        input.move_to_analysis(Lease { live: analysis.clone() });
        drop(input);
        assert!(analysis.load(Ordering::SeqCst), "An outstanding reader still owns the buffer");
        drop(reader);
        assert!(!download.load(Ordering::SeqCst) && !analysis.load(Ordering::SeqCst));
    }

    fn request(location: &MemoryLocation, range: &str) -> TcpStream {
        let (addr, path) = location.address().unwrap();
        let mut socket = TcpStream::connect(addr).unwrap();
        socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        write!(socket, "GET /{path} HTTP/1.1\r\nRange: {range}\r\n\r\n").unwrap();
        socket
    }

    #[test]
    fn seek_requests_do_not_wait_for_an_unfinished_response() {
        let mut bytes = vec![42; 16 * 1024 * 1024];
        let tail = bytes.len() - 4;
        bytes[tail..].copy_from_slice(b"tail");
        let input = Arc::new(MemoryInput::new(bytes));
        let weak = Arc::downgrade(&input);
        let server = MemoryServer::new(input).unwrap();
        // FFmpeg can keep the current response open until a replacement seek
        // succeeds. Leave enough unread bytes to fill the first socket.
        let mut original = request(&server.location, "bytes=0-");
        assert!(header(&mut original, None).unwrap().starts_with("HTTP/1.1 206"));
        for wanted in ["bytes=-4".to_owned(), format!("bytes={tail}-") ] {
            let mut seek = request(&server.location, &wanted);
            let mut response = Vec::new();
            seek.read_to_end(&mut response).expect("A seek was blocked by an earlier response");
            assert!(response.starts_with(b"HTTP/1.1 206"));
            assert!(response.ends_with(b"\r\n\r\ntail"));
        }
        // The overlapping seek must not truncate the earlier response.
        let mut remaining = Vec::new();
        original.read_to_end(&mut remaining).unwrap();
        assert_eq!(remaining.len(), tail + 4);
        assert!(remaining[..tail].iter().all(|b| *b == 42));
        assert_eq!(&remaining[tail..], b"tail");
        drop(server);
        assert!(weak.upgrade().is_none(), "A reader retained the original");
    }

    #[test]
    fn stalled_headers_do_not_block_reads_and_all_readers_stop_on_drop() {
        let input = Arc::new(MemoryInput::new(vec![42; 16 * 1024 * 1024]));
        let weak = Arc::downgrade(&input);
        let server = MemoryServer::new(input).unwrap();
        let (addr, _) = server.location.address().unwrap();
        let mut body = request(&server.location, "bytes=0-");
        header(&mut body, None).unwrap();
        let mut incomplete = TcpStream::connect(addr).unwrap();
        incomplete.write_all(b"GET ").unwrap();
        let mut seek = request(&server.location, "bytes=0-3");
        let mut reply = Vec::new();
        seek.read_to_end(&mut reply).expect("A stalled request header blocked a seek");
        assert!(reply.ends_with(b"\r\n\r\n****"));
        let started = std::time::Instant::now();
        drop(server);
        assert!(started.elapsed() < Duration::from_secs(2), "Cancellation waited for a stalled reader");
        assert!(weak.upgrade().is_none(), "Cancellation retained the original");
        assert!(TcpStream::connect(addr).is_err());
    }

    #[test]
    fn excess_readers_fail_promptly_and_capacity_recovers() {
        let input = Arc::new(MemoryInput::new(vec![42; 16 * 1024 * 1024]));
        let weak = Arc::downgrade(&input);
        let server = MemoryServer::new(input).unwrap();
        let mut held = Vec::new();
        for _ in 0..MAX_MEMORY_READERS {
            let mut socket = request(&server.location, "bytes=0-");
            assert!(header(&mut socket, None).unwrap().starts_with("HTTP/1.1 206"));
            held.push(socket);
        }
        let mut excess = request(&server.location, "bytes=0-3");
        assert!(header(&mut excess, None).unwrap().starts_with("HTTP/1.1 503"));
        drop(held.pop());
        let started = std::time::Instant::now();
        loop {
            let mut socket = request(&server.location, "bytes=0-3");
            let response = header(&mut socket, None).unwrap();
            if response.starts_with("HTTP/1.1 206") {
                let mut bytes = Vec::new();
                socket.read_to_end(&mut bytes).unwrap();
                assert_eq!(bytes, b"****");
                break;
            }
            assert!(response.starts_with("HTTP/1.1 503"));
            assert!(started.elapsed() < Duration::from_secs(2), "A disconnected reader kept its slot");
            std::thread::sleep(Duration::from_millis(5));
        }
        let started = std::time::Instant::now();
        drop(server);
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(weak.upgrade().is_none());
    }

    #[test]
    fn host_owned_buffers_are_not_copied_and_live_until_the_last_reader() {
        struct Owned { bytes: Vec<u8>, dropped: Arc<AtomicBool> }
        impl AsRef<[u8]> for Owned { fn as_ref(&self) -> &[u8] { &self.bytes } }
        impl Drop for Owned { fn drop(&mut self) { self.dropped.store(true, Ordering::Release); } }
        struct Guard(Arc<AtomicBool>);
        impl Drop for Guard { fn drop(&mut self) { self.0.store(true, Ordering::Release); } }
        let dropped = Arc::new(AtomicBool::new(false)); let released = Arc::new(AtomicBool::new(false));
        let owned = Owned { bytes: b"0123456789".to_vec(), dropped:dropped.clone() };
        let pointer = owned.as_ref().as_ptr();
        let input = Arc::new(MemoryInput::from_buffer(owned).retaining(Guard(released.clone())));
        assert_eq!(input.as_ref().as_ref().as_ptr(),pointer);
        let mut reader = Reader::memory(input.clone()); drop(input);
        assert!(!dropped.load(Ordering::Acquire) && !released.load(Ordering::Acquire));
        std::io::Seek::seek(&mut reader,std::io::SeekFrom::Start(7)).unwrap();
        let mut bytes = Vec::new(); reader.read_to_end(&mut bytes).unwrap(); assert_eq!(bytes,b"789");
        drop(reader);
        assert!(dropped.load(Ordering::Acquire) && released.load(Ordering::Acquire));
    }
    #[test]
    fn memory_transport_reads_ranges_and_releases_original() {
        let input = Arc::new(MemoryInput::new(b"0123456789".to_vec()));
        let weak = Arc::downgrade(&input);
        let server = MemoryServer::new(input).unwrap();
        assert_eq!(server.location.read().unwrap(),b"0123456789");
        let (addr,path) = server.location.address().unwrap();
        let mut s = TcpStream::connect(addr).unwrap();
        write!(s,"GET /{path} HTTP/1.1\r\nRange: bytes=3-5\r\n\r\n").unwrap();
        let mut out = String::new(); s.read_to_string(&mut out).unwrap();
        assert!(out.starts_with("HTTP/1.1 206")); assert!(out.ends_with("\r\n345"));
        assert_eq!(range("bytes=-3",10),Some((7,10)));
        assert_eq!(range("bytes=10-",10),None);
        drop(server); assert!(weak.upgrade().is_none());
        assert!(TcpStream::connect(addr).is_err());
    }
    #[test]
    fn memory_transport_rejects_remote_or_non_token_urls() {
        for url in ["https://127.0.0.1:3/abc","http://localhost:3/abc","http://192.0.2.1:3/abc","http://127.0.0.1:3/../file"] {
            assert!(MemoryLocation {url:url.into(),bytes:0}.address().is_err());
        }
    }
    #[test]
    fn a_scheduled_out_reader_can_resume_and_stalled_headers_cancel_promptly() {
        let server = MemoryServer::new(Arc::new(MemoryInput::new(b"original".to_vec()))).unwrap();
        let (addr,path) = server.location.address().unwrap();
        let mut socket = TcpStream::connect(addr).unwrap();
        std::thread::sleep(Duration::from_millis(350));
        write!(socket,"GET /{path} HTTP/1.1\r\n\r\n").unwrap();
        let mut reply=String::new(); socket.read_to_string(&mut reply).unwrap();
        assert!(reply.ends_with("\r\noriginal"));
        let mut stalled = TcpStream::connect(addr).unwrap();
        stalled.write_all(b"G").unwrap();
        std::thread::sleep(Duration::from_millis(50));
        let started = std::time::Instant::now();
        drop(server);
        assert!(started.elapsed()<Duration::from_secs(1));
    }
}

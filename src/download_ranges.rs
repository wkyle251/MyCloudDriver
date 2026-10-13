//! Validated parallel byte ranges. Coverage advances only after the caller has
//! accepted a chunk; disk and RAM callers retain the same state across retries.
use crate::{
    download_connections::Connections,
    download_network::{Network, Permit},
    download_policy::{self, HttpFailure, Interrupted},
};
use bytes::Bytes;
use futures_util::{future::BoxFuture, stream::FuturesUnordered, StreamExt};
use reqwest::{header, Response, StatusCode};
use serde::{Deserialize, Serialize};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

pub const MIN_PARALLEL_SIZE: u64 = 64 * 1024 * 1024;
const PIECE_SIZE: u64 = 16 * 1024 * 1024;
const MAX_PIECES: usize = 8192;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("The original requires sequential range validation")]
    Sequential,
    #[error(transparent)]
    Http(#[from] HttpFailure),
    #[error("Original connection interrupted")]
    Network(#[source] reqwest::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Incomplete(#[from] Interrupted),
    #[error("The current range source cannot supply the remaining bytes")]
    Unavailable(#[source] crate::download_policy::ContentUnavailable),
}

impl From<reqwest::Error> for Error {
    fn from(error: reqwest::Error) -> Self {
        Self::Network(error.without_url())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Piece {
    received: u64,
    complete: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    total: u64,
    piece_size: u64,
    etag: String,
    pieces: Vec<Piece>,
}

impl State {
    pub fn new(total: u64, etag: String, prefix: u64) -> Self {
        let piece_size =
            PIECE_SIZE.max(total.div_ceil(MAX_PIECES as u64).div_ceil(PIECE_SIZE) * PIECE_SIZE);
        let pieces = (0..total.div_ceil(piece_size))
            .map(|index| {
                let start = index * piece_size;
                let size = piece_size.min(total - start);
                let received = prefix.saturating_sub(start).min(size);
                Piece {
                    received,
                    complete: received == size,
                }
            })
            .collect();
        Self {
            total,
            piece_size,
            etag,
            pieces,
        }
    }

    pub fn valid(&self) -> bool {
        self.total > 0
            && self.total <= i64::MAX as u64
            && self.piece_size >= crate::download_network::RECEIVE_WINDOW
            && self.piece_size % crate::download_network::RECEIVE_WINDOW == 0
            && self.etag.starts_with('"')
            && self.etag.ends_with('"')
            && header::HeaderValue::from_str(&self.etag).is_ok()
            && self.pieces.len() <= MAX_PIECES
            && self.total.div_ceil(self.piece_size) == self.pieces.len() as u64
            && self.pieces.iter().enumerate().all(|(index, piece)| {
                piece.received <= self.size(index)
                    && (!piece.complete || piece.received == self.size(index))
            })
    }

    pub fn total(&self) -> u64 {
        self.total
    }
    /// Forgets everything received of one piece, so it is fetched again. The other pieces are untouched.
    pub fn forget_piece(&mut self, index: usize) {
        if let Some(piece) = self.pieces.get_mut(index) {
            piece.received = 0;
            piece.complete = false;
        }
    }
    /// Each piece owns one contiguous prefix. Disk checkpoints hash precisely
    /// these regions, including unfinished prefixes and excluding sparse holes.
    pub fn covered_ranges(&self) -> impl Iterator<Item = (usize, u64, u64)> + '_ {
        self.pieces
            .iter()
            .enumerate()
            .map(|(index, piece)| (index, index as u64 * self.piece_size, piece.received))
    }
    pub fn etag(&self) -> &str {
        &self.etag
    }
    /// Preserve coverage when a caller has independently verified that both
    /// CDN routes represent the same original (GCID and total byte count).
    pub fn rebind_etag(&mut self, etag: &str) -> bool {
        if !etag.starts_with('"')
            || !etag.ends_with('"')
            || header::HeaderValue::from_str(etag).is_err()
        {
            return false;
        }
        self.etag = etag.to_owned();
        true
    }
    pub fn received(&self) -> u64 {
        self.pieces.iter().map(|piece| piece.received).sum()
    }
    /// The disk consumer tracks coverage independently from receive-ahead.
    /// Completion flags advance separately, after the corresponding EOF event.
    pub fn accept_written(&mut self, chunk: &Chunk) -> Result<(), Error> {
        let Some(piece) = self.pieces.get(chunk.index) else { return Err(Error::Sequential); };
        if piece.complete || chunk.offset != chunk.index as u64 * self.piece_size + piece.received
            || chunk.bytes.len() as u64 > self.size(chunk.index) - piece.received {
            return Err(Error::Sequential);
        }
        self.pieces[chunk.index].received += chunk.bytes.len() as u64;
        Ok(())
    }
    pub fn same_received_coverage(&self, other: &Self) -> bool {
        self.total == other.total && self.piece_size == other.piece_size && self.etag == other.etag
            && self.pieces.len() == other.pieces.len()
            && self.pieces.iter().zip(&other.pieces).all(|(a, b)| a.received == b.received)
    }
    /// An observed HTTP EOF proves one piece only after its preceding data
    /// events have been accepted by the consumer. It never adds byte coverage.
    pub fn accept_piece_eof(&mut self, index: usize) -> Result<(), Error> {
        if index >= self.pieces.len() || self.pieces[index].received != self.size(index) {
            return Err(Error::Sequential);
        }
        self.pieces[index].complete = true;
        Ok(())
    }
    pub fn complete(&self) -> bool {
        self.pieces.iter().all(|piece| piece.complete)
    }
    pub fn piece_complete(&self, index: usize) -> bool {
        self.pieces.get(index).is_some_and(|piece| piece.complete)
    }
    pub fn needs_eof_replay(&self, index: usize) -> bool {
        self.pieces.get(index).is_some_and(|piece| {
            !piece.complete && piece.received == self.size(index)
        })
    }
    pub fn extent(&self) -> u64 {
        self.pieces
            .iter()
            .enumerate()
            .filter(|(_, piece)| piece.received > 0)
            .map(|(index, piece)| index as u64 * self.piece_size + piece.received)
            .max()
            .unwrap_or(0)
    }
    pub fn prefix(&self) -> u64 {
        let mut prefix = 0;
        for (index, piece) in self.pieces.iter().enumerate() {
            prefix += piece.received;
            if piece.received != self.size(index) {
                break;
            }
        }
        prefix
    }
    fn size(&self, index: usize) -> u64 {
        self.piece_size
            .min(self.total - index as u64 * self.piece_size)
    }
    fn restart(&mut self) {
        for index in 0..self.pieces.len() {
            // Re-read the last byte if EOF was not observed before interruption.
            if self.needs_eof_replay(index) {
                self.pieces[index].received -= 1;
            }
        }
    }
}

#[cfg(test)]
#[path = "download_ranges_tests.rs"]
mod tests;

fn range(headers: &header::HeaderMap) -> Option<(u64, u64, u64)> {
    let value = headers.get(header::CONTENT_RANGE)?.to_str().ok()?;
    let (span, total) = value.strip_prefix("bytes ")?.split_once('/')?;
    let (start, end) = span.split_once('-')?;
    let (start, end, total) = (
        start.parse().ok()?,
        end.parse::<u64>().ok()?,
        total.parse().ok()?,
    );
    (start <= end && end < total).then_some((start, end, total))
}

fn status(response: &Response, network: &Network) -> Result<(), Error> {
    if response.status().is_success() {
        return Ok(());
    }
    let failure = HttpFailure {
        status: response.status().as_u16(),
        retry_after: download_policy::retry_after(response.headers()),
    };
    if matches!(failure.status, 429 | 500..=599) {
        network.defer(failure.retry_after.unwrap_or(Duration::from_secs(1)))?;
    }
    Err(failure.into())
}

fn identity(response: &Response) -> bool {
    response
        .headers()
        .get(header::CONTENT_ENCODING)
        .is_none_or(|value| value == "identity")
}

/// An ignored range or weak/missing validator uses the existing sequential path.
/// The probe owns a shared connection slot and never consumes a full 200 body.
pub async fn probe(
    http: &reqwest::Client,
    link: &str,
    total: u64,
    referer: Option<&str>,
    network: &Arc<Network>,
) -> Result<Option<String>, Error> {
    let _stage = crate::download_waits::Stage::enter(crate::download_waits::Kind::RangeProbe);
    let _participant = network.register();
    let _permit = network.acquire().await?;
    let mut request = http
        .get(link)
        .header(header::RANGE, "bytes=0-0")
        .header(header::ACCEPT_ENCODING, "identity");
    if let Some(referer) = referer {
        request = request.header(header::REFERER, referer);
    }
    let mut response = request.send().await.map_err(|error| {
        crate::download_waits::payload_event(if error.is_timeout() { crate::download_waits::PayloadEvent::Timeout }
            else { crate::download_waits::PayloadEvent::Connection });
        error
    })?;
    crate::download_waits::payload_response(response.status().as_u16());
    if response.status() == StatusCode::RANGE_NOT_SATISFIABLE
        && response
            .headers()
            .get(header::CONTENT_RANGE)
            .is_some_and(|value| value == "bytes */0")
    {
        return Err(Error::Unavailable(
            crate::download_policy::ContentUnavailable,
        ));
    }
    status(&response, network)?;
    let etag = response
        .headers()
        .get(header::ETAG)
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.starts_with('"') && value.ends_with('"'))
        .map(str::to_owned);
    if response.status() != StatusCode::PARTIAL_CONTENT
        || range(response.headers()) != Some((0, 0, total))
        || !identity(&response)
        || etag.is_none()
    {
        return Ok(None);
    }
    let mut received = 0;
    while let Some(chunk) = response.chunk().await? {
        received += chunk.len();
        if received > 1 {
            return Ok(None);
        }
    }
    if received != 1 {
        return Err(Interrupted.into());
    }
    Ok(etag)
}

struct Read {
    response: Response,
    permit: Permit,
    chunk: Option<Bytes>,
}
type Job = BoxFuture<'static, (usize, Result<Read, Error>)>;

fn read(index: usize, mut response: Response, permit: Permit) -> Job {
    Box::pin(async move {
        let result = response
            .chunk()
            .await
            .map(|chunk| Read {
                response,
                permit,
                chunk,
            })
            .map_err(Error::from);
        (index, result)
    })
}

pub struct Chunk {
    pub index: usize,
    pub offset: u64,
    pub bytes: Bytes,
}

/// Ordered body data and validated per-piece EOF. Streaming disk consumers
/// can retain completed-piece proof without waiting for unrelated requests.
pub enum Event {
    Data(Chunk),
    PieceEof(usize),
    /// Already-covered bytes in a validated open-ended fallback response.
    Skipped(u64),
}

struct SequentialRead {
    response: Response,
    _permit: Permit,
    position: u64,
    chunk: Option<Bytes>,
    eof: bool,
}

pub struct Transfer {
    state: State,
    http: reqwest::Client,
    link: String,
    referer: Option<String>,
    network: Arc<Network>,
    connections: Connections,
    jobs: FuturesUnordered<Job>,
    active: Vec<bool>,
    pending: Option<(usize, Read, usize)>,
    streaming_fallback: bool,
    sequential: Option<SequentialRead>,
    sequential_start: Option<BoxFuture<'static, Result<SequentialRead, Error>>>,
    sequential_pending: Option<(usize, usize)>,
    _participant: crate::download_network::Participant,
}

impl Transfer {
    pub fn new(
        http: &reqwest::Client,
        link: &str,
        referer: Option<&str>,
        mut state: State,
        network: Arc<Network>,
    ) -> Result<Self, Error> {
        if !state.valid() {
            return Err(Error::Sequential);
        }
        state.restart();
        let ceiling = network.limit().min(state.pieces.len());
        let participant = network.register();
        let connections = Connections::with_initial(ceiling, 1, Instant::now())
            .with_coordinator(network.trials());
        Ok(Self {
            active: vec![false; state.pieces.len()],
            state,
            http: http.clone(),
            link: link.into(),
            referer: referer.map(str::to_owned),
            network,
            connections,
            jobs: FuturesUnordered::new(),
            pending: None,
            streaming_fallback: false,
            sequential: None,
            sequential_start: None,
            sequential_pending: None,
            _participant: participant,
        })
    }
    pub fn state(&self) -> &State {
        &self.state
    }
    /// Apply the normal-download gain threshold before starting range requests.
    pub fn with_absolute_gain(mut self) -> Self {
        self.connections = self.connections.with_absolute_gain();
        self
    }
    /// An early receiver can change request strategy without waiting for its
    /// disk consumer. Only the same validated entity may fill existing holes.
    pub fn with_streaming_fallback(mut self) -> Self {
        self.streaming_fallback = true;
        self
    }
    #[cfg(test)]
    pub(crate) fn set_test_initial_channels(&mut self, initial: usize) {
        if initial > 1 {
            self.connections = Connections::with_initial(
                self.network.limit().min(self.state.pieces.len()),
                initial,
                Instant::now(),
            )
            .with_coordinator(self.network.trials());
        }
    }
    pub fn stop(&mut self) {
        self.connections.idle(Instant::now());
        self.jobs.clear();
        self.pending = None;
        self.sequential = None;
        self.sequential_start = None;
        self.sequential_pending = None;
        self.active.fill(false);
    }
    /// The caller reserves this headroom before polling HTTP bodies. It covers
    /// all outstanding per-connection receive windows, including paused reads.
    pub fn buffer_headroom(&self) -> u64 {
        self.network.limit().min(self.state.pieces.len()) as u64
            * crate::download_network::RECEIVE_WINDOW
    }

    fn schedule(&mut self) -> Result<(), Error> {
        self.schedule_at(Instant::now())
    }

    fn schedule_at(&mut self, now: Instant) -> Result<(), Error> {
        self.connections.active = self.active.iter().filter(|active| **active).count();
        self.connections
            .limit_for_resources(self.network.fair_share(), now);
        let admission = self.connections.limit.min(self.network.fair_share());
        for index in 0..self.state.pieces.len() {
            if self.connections.active >= admission {
                break;
            }
            if self.active[index] || self.state.pieces[index].complete {
                continue;
            }
            let Some(permit) = self.network.try_acquire()? else {
                break;
            };
            let start = index as u64 * self.state.piece_size + self.state.pieces[index].received;
            let end = index as u64 * self.state.piece_size + self.state.size(index) - 1;
            let mut request = self
                .http
                .get(&self.link)
                .header(header::ACCEPT_ENCODING, "identity")
                .header(header::RANGE, format!("bytes={start}-{end}"))
                .header(header::IF_RANGE, &self.state.etag);
            if let Some(referer) = &self.referer {
                request = request.header(header::REFERER, referer);
            }
            let total = self.state.total;
            let etag = self.state.etag.clone();
            let network = self.network.clone();
            self.jobs.push(Box::pin(async move {
                let result = async {
                    let response = request.send().await?;
                    crate::download_waits::payload_response(response.status().as_u16());
                    if response.status() == StatusCode::RANGE_NOT_SATISFIABLE {
                        let cap = response
                            .headers()
                            .get(header::CONTENT_RANGE)
                            .and_then(|value| value.to_str().ok())
                            .and_then(|value| value.strip_prefix("bytes */"))
                            .and_then(|value| value.parse::<u64>().ok());
                        if let Some(cap) = cap.filter(|cap| *cap < total) {
                            if start >= cap {
                                return Err(Error::Unavailable(
                                    crate::download_policy::ContentUnavailable,
                                ));
                            }
                            if end >= cap {
                                return Err(Error::Sequential);
                            }
                        }
                    }
                    status(&response, &network)?;
                    if response.status() != StatusCode::PARTIAL_CONTENT
                        || range(response.headers()) != Some((start, end, total))
                        || response
                            .headers()
                            .get(header::ETAG)
                            .and_then(|value| value.to_str().ok())
                            != Some(etag.as_str())
                        || response
                            .content_length()
                            .is_some_and(|length| length != end - start + 1)
                        || !identity(&response)
                    {
                        return Err(Error::Sequential);
                    }
                    read(index, response, permit).await.1
                }
                .await;
                (index, result)
            }));
            self.active[index] = true;
            self.connections.active += 1;
        }
        // An EOF followed by an immediately ready piece is continuous demand.
        // Sample after refill so short pieces cannot repeatedly invalidate the
        // controller's five-second window with a transient empty socket slot.
        self.connections
            .observe(now, self.network.received(), || true);
        Ok(())
    }

    /// No writes happen here. Cancelling this future leaves coverage unchanged.
    pub async fn next(&mut self) -> Result<Option<Chunk>, Error> {
        loop {
            match self.next_event().await? {
                Some(Event::Data(chunk)) => return Ok(Some(chunk)),
                Some(Event::PieceEof(_)) => {},
                Some(Event::Skipped(_)) => {},
                None => return Ok(None),
            }
        }
    }

    /// EOF is delivered even when another piece stalls and produces no data.
    /// Each data event must be accepted before polling the next event.
    pub async fn next_event(&mut self) -> Result<Option<Event>, Error> {
        assert!(
            self.pending.is_none() && self.sequential_pending.is_none(),
            "Accept the previous range chunk first"
        );
        loop {
            if let Some(start) = &mut self.sequential_start {
                // Retain the request future across the producer's control
                // ticks. A slow header must not restart every 100 ms.
                self.sequential = Some(start.await?);
                self.sequential_start = None;
            }
            if self.sequential.is_some() { return self.next_sequential().await; }
            self.schedule()?;
            if self.state.complete() {
                return Ok(None);
            }
            tokio::select! {
                completed = self.jobs.next(), if !self.jobs.is_empty() => {
                    let (index, received) = completed.unwrap();
                    let mut received = match received {
                        Err(Error::Sequential) if self.streaming_fallback => {
                            self.start_sequential();
                            continue;
                        }
                        result => result?,
                    };
                    if let Some(bytes) = received.chunk.take() {
                        if bytes.len() as u64 > self.state.size(index) - self.state.pieces[index].received {
                            return Err(Error::Sequential);
                        }
                        let offset = index as u64 * self.state.piece_size + self.state.pieces[index].received;
                        self.pending = Some((index, received, bytes.len()));
                        return Ok(Some(Event::Data(Chunk { index, offset, bytes })));
                    }
                    self.active[index] = false;
                    if self.state.pieces[index].received != self.state.size(index) { return Err(Interrupted.into()); }
                    self.state.pieces[index].complete = true;
                    return Ok(Some(Event::PieceEof(index)));
                }
                _ = tokio::time::sleep(Duration::from_millis(25)) => {}
            }
        }
    }

    pub fn accept(&mut self, chunk: &Chunk) {
        if let Some((index, bytes)) = self.sequential_pending.take() {
            assert_eq!((index, bytes), (chunk.index, chunk.bytes.len()));
            self.state.accept_written(chunk).expect("validated sequential range coverage");
            self.network.record(bytes as u64);
            return;
        }
        let (index, read_result, bytes) = self.pending.take().expect("Pending range chunk");
        assert_eq!((index, bytes), (chunk.index, chunk.bytes.len()));
        self.state.pieces[index].received += bytes as u64;
        self.network.record(bytes as u64);
        self.jobs
            .push(read(index, read_result.response, read_result.permit));
    }

    fn start_sequential(&mut self) {
        self.stop();
        crate::download_waits::payload_event(crate::download_waits::PayloadEvent::StreamingFallback);
        let start = self.state.pieces.iter().enumerate().find(|(index, piece)| piece.received < self.state.size(*index))
            .map(|(index, piece)| index as u64 * self.state.piece_size + piece.received)
            .unwrap_or(self.state.total - 1);
        let mut request = self.http.get(&self.link)
            .header(header::ACCEPT_ENCODING, "identity")
            .header(header::RANGE, format!("bytes={start}-"))
            .header(header::IF_RANGE, &self.state.etag);
        if let Some(referer) = &self.referer { request = request.header(header::REFERER, referer); }
        let network = self.network.clone();
        let total = self.state.total;
        let etag = self.state.etag.clone();
        self.sequential_start = Some(Box::pin(async move {
            let permit = network.acquire().await?;
            let response = crate::download_waits::track(crate::download_waits::Kind::ContentHeaders, request.send()).await?;
            crate::download_waits::payload_response(response.status().as_u16());
            status(&response, &network)?;
            let position = match response.status() {
                StatusCode::PARTIAL_CONTENT if range(response.headers()) == Some((start, total - 1, total)) => start,
                StatusCode::OK if response.content_length() == Some(total) => 0,
                _ => return Err(Error::Sequential),
            };
            if response.headers().get(header::ETAG).and_then(|value| value.to_str().ok()) != Some(etag.as_str())
                || !identity(&response) || response.content_length().is_some_and(|length| length != total - position) {
                return Err(Error::Sequential);
            }
            Ok(SequentialRead { response, _permit: permit, position, chunk: None, eof: false })
        }));
    }

    async fn next_sequential(&mut self) -> Result<Option<Event>, Error> {
        loop {
            let stream = self.sequential.as_mut().unwrap();
            if let Some(bytes) = stream.chunk.take() {
                if stream.position >= self.state.total { return Err(Error::Sequential); }
                let index = (stream.position / self.state.piece_size) as usize;
                let base = index as u64 * self.state.piece_size;
                let covered = base + self.state.pieces[index].received;
                let mut take = bytes.len().min((base + self.state.size(index) - stream.position) as usize);
                let offset = stream.position;
                let skipped = offset < covered;
                if skipped { take = take.min((covered - offset) as usize); }
                else if offset != covered { return Err(Error::Sequential); }
                if take < bytes.len() { stream.chunk = Some(bytes.slice(take..)); }
                stream.position += take as u64;
                if skipped {
                    self.network.record(take as u64);
                    return Ok(Some(Event::Skipped(take as u64)));
                }
                self.sequential_pending = Some((index, take));
                return Ok(Some(Event::Data(Chunk { index, offset, bytes: bytes.slice(..take) })));
            }
            if stream.eof {
                // A piece is complete only after the whole validated response
                // reaches EOF. Interrupted full pieces retain their replay rule.
                if let Some(index) = self.state.pieces.iter().position(|piece| !piece.complete) {
                    self.state.accept_piece_eof(index)?;
                    return Ok(Some(Event::PieceEof(index)));
                }
                return Ok(None);
            }
            match stream.response.chunk().await? {
                Some(bytes) if !bytes.is_empty() => stream.chunk = Some(bytes),
                Some(_) => {},
                None if stream.position == self.state.total => stream.eof = true,
                None => return Err(Interrupted.into()),
            }
        }
    }
}

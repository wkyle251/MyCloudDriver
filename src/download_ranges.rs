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
}

impl From<reqwest::Error> for Error {
    fn from(error: reqwest::Error) -> Self {
        Self::Network(error.without_url())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Piece {
    received: u64,
    complete: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
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
    pub fn etag(&self) -> &str {
        &self.etag
    }
    pub fn received(&self) -> u64 {
        self.pieces.iter().map(|piece| piece.received).sum()
    }
    pub fn complete(&self) -> bool {
        self.pieces.iter().all(|piece| piece.complete)
    }
    pub fn piece_complete(&self, index: usize) -> bool {
        self.pieces.get(index).is_some_and(|piece| piece.complete)
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
            if !self.pieces[index].complete && self.pieces[index].received == self.size(index) {
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
    let _participant = network.register();
    let _permit = network.acquire().await?;
    let mut request = http
        .get(link)
        .header(header::RANGE, "bytes=0-0")
        .header(header::ACCEPT_ENCODING, "identity");
    if let Some(referer) = referer {
        request = request.header(header::REFERER, referer);
    }
    let mut response = request.send().await?;
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
    #[cfg(test)]
    pub(crate) fn set_test_initial_channels(&mut self, initial: usize) {
        if initial > 1 {
            self.connections = Connections::with_initial(self.network.limit().min(self.state.pieces.len()), initial, Instant::now())
                .with_coordinator(self.network.trials());
        }
    }
    pub fn stop(&mut self) {
        self.connections.idle(Instant::now());
        self.jobs.clear();
        self.pending = None;
        self.active.fill(false);
    }
    /// The caller reserves this headroom before polling HTTP bodies. It covers
    /// all outstanding per-connection receive windows, including paused reads.
    pub fn buffer_headroom(&self) -> u64 {
        self.network.limit().min(self.state.pieces.len()) as u64
            * crate::download_network::RECEIVE_WINDOW
    }

    fn schedule(&mut self) -> Result<(), Error> {
        self.connections.active = self.active.iter().filter(|active| **active).count();
        self.connections
            .limit_for_resources(self.network.fair_share(), Instant::now());
        self.connections
            .observe(Instant::now(), self.network.received(), || true);
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
        Ok(())
    }

    /// No writes happen here. Cancelling this future leaves coverage unchanged.
    pub async fn next(&mut self) -> Result<Option<Chunk>, Error> {
        assert!(
            self.pending.is_none(),
            "Accept the previous range chunk first"
        );
        loop {
            self.schedule()?;
            if self.state.complete() {
                return Ok(None);
            }
            tokio::select! {
                completed = self.jobs.next(), if !self.jobs.is_empty() => {
                    let (index, received) = completed.unwrap();
                    let mut received = received?;
                    if let Some(bytes) = received.chunk.take() {
                        if bytes.len() as u64 > self.state.size(index) - self.state.pieces[index].received {
                            return Err(Error::Sequential);
                        }
                        let offset = index as u64 * self.state.piece_size + self.state.pieces[index].received;
                        self.pending = Some((index, received, bytes.len()));
                        return Ok(Some(Chunk { index, offset, bytes }));
                    }
                    self.active[index] = false;
                    if self.state.pieces[index].received != self.state.size(index) { return Err(Interrupted.into()); }
                    self.state.pieces[index].complete = true;
                }
                _ = tokio::time::sleep(Duration::from_millis(25)) => {}
            }
        }
    }

    pub fn accept(&mut self, chunk: &Chunk) {
        let (index, read_result, bytes) = self.pending.take().expect("Pending range chunk");
        assert_eq!((index, bytes), (chunk.index, chunk.bytes.len()));
        self.state.pieces[index].received += bytes as u64;
        self.network.record(bytes as u64);
        self.jobs
            .push(read(index, read_result.response, read_result.permit));
    }
}

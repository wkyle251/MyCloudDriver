//! Small archive range probes; inconclusive layouts fall back to normal acquisition.
use super::*;

struct Slice {
    bytes: Vec<u8>,
    etag: Option<reqwest::header::HeaderValue>,
}

async fn read_range(
    client: &Client, url: &reqwest::Url, size: u64, start: u64, length: u64,
    etag: Option<&reqwest::header::HeaderValue>, fetches: &Fetches,
    transferred: &mut u64, progress: &mut impl FnMut(u64, u64) -> Result<()>,
) -> Result<Slice> {
    let end = start + length - 1;
    let network = Network::for_url(url.as_str());
    let _participant = network.register();
    let _channel = network.acquire().await?;
    let mut request = client.download_http_client().get(url.clone())
        .header(reqwest::header::ACCEPT_ENCODING, "identity")
        .header(reqwest::header::RANGE, format!("bytes={start}-{end}"));
    if let Some(etag) = etag { request = request.header(reqwest::header::IF_RANGE, etag); }
    let response = request.send().await?;
    if matches!(response.status().as_u16(), 401 | 403 | 404 | 408 | 429 | 500..=599) {
        if matches!(response.status().as_u16(), 429 | 500..=599) {
            network.defer(retry_after(response.headers()).unwrap_or(Duration::from_secs(1)))?;
        }
        return Err(Failure::http(response.status().as_u16(), "download", retry_after(response.headers())).into());
    }
    let validator = response.headers().get(reqwest::header::ETAG).filter(|tag|
        tag.to_str().is_ok_and(|s| s.starts_with('"') && s.ends_with('"'))).cloned();
    if etag.is_some_and(|expected| validator.as_ref() != Some(expected)) {
        bail!("Archive probe revision changed");
    }
    if response.headers().get(reqwest::header::CONTENT_ENCODING)
        .is_some_and(|value| value != "identity") { bail!("Encoded archive probe response"); }
    if response.status() == reqwest::StatusCode::PARTIAL_CONTENT {
        let range = response.headers().get(reqwest::header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok()).and_then(content_range);
        if range != Some((start, end, size))
            || response.content_length().is_some_and(|n| n != length) { bail!("Invalid archive probe range"); }
    } else if response.status() != reqwest::StatusCode::OK || start != 0
        || response.content_length().is_some_and(|n| n != size) {
        bail!("Archive probe range unavailable");
    }
    let mut bytes = Vec::with_capacity(length as usize);
    let mut stream = response.bytes_stream();
    while bytes.len() < length as usize {
        let Some(chunk) = stream.next().await else { bail!("Incomplete archive probe"); };
        let chunk = chunk?;
        *transferred += chunk.len() as u64;
        fetches.received_bytes.fetch_add(chunk.len() as u64, Ordering::Relaxed);
        network.record(chunk.len() as u64);
        progress(*transferred, size)?;
        let keep = chunk.len().min(length as usize - bytes.len());
        bytes.extend_from_slice(&chunk[..keep]);
    }
    // Drop the response even when the server ignored Range. Never drain a
    // complete original merely to perform a small encryption check.
    Ok(Slice { bytes, etag: validator })
}

pub(super) async fn check(
    client: &Client, url: &reqwest::Url, size: u64, fetches: &Fetches,
    transferred: &mut u64, progress: &mut impl FnMut(u64, u64) -> Result<()>,
) -> Result<bool> {
    if size < 8 { return Ok(false); }
    let prefix = read_range(client, url, size, 0, size.min(30), None, fetches, transferred, progress).await?;
    if let Some(format) = password::rar::format(&prefix.bytes) {
        return check_rar(format, prefix, client, url, size, fetches, transferred, progress).await;
    }
    if password::zip_prefix_encrypted(&prefix.bytes) { return Ok(true); }
    if !prefix.bytes.starts_with(b"PK\x03\x04") { return Ok(false); }
    let tail_size = size.min(password::ZIP_TAIL);
    let tail_start = size - tail_size;
    let tail = read_range(client, url, size, tail_start, tail_size, prefix.etag.as_ref(), fetches, transferred, progress).await?;
    let Some(location) = password::zip_directory(&tail.bytes, size) else { return Ok(false); };
    let (start, length) = match location {
        password::ZipDirectory::Entries { start, length } => (start, length),
        password::ZipDirectory::Zip64 { start, end } => {
            let record;
            let header = if start >= tail_start {
                &tail.bytes[(start - tail_start) as usize..][..56]
            } else {
                record = read_range(client, url, size, start, 56, prefix.etag.as_ref(), fetches, transferred, progress).await?;
                &record.bytes
            };
            let Some(directory) = password::zip64_directory(header, start, end) else { return Ok(false); };
            directory
        }
    };
    if start >= tail_start {
        let offset = (start - tail_start) as usize;
        return Ok(password::zip_directory_encrypted(&tail.bytes[offset..offset + length as usize]));
    }
    let directory = read_range(client, url, size, start, length.min(password::ZIP_DIRECTORY_LIMIT),
        prefix.etag.as_ref(), fetches, transferred, progress).await?;
    Ok(password::zip_directory_encrypted(&directory.bytes))
}

async fn check_rar(
    format: password::rar::Format, prefix: Slice,
    client: &Client, url: &reqwest::Url, size: u64, fetches: &Fetches,
    transferred: &mut u64, progress: &mut impl FnMut(u64, u64) -> Result<()>,
) -> Result<bool> {
    let etag = prefix.etag.clone();
    let mut window = prefix;
    let mut start = 0u64;
    let mut read = window.bytes.len() as u64;
    let mut offset = format.signature_bytes();
    for index in 0..password::rar::MAX_BLOCKS {
        if size.saturating_sub(offset) < 7 { return Ok(false); }
        if offset < start || offset + 7 > start + window.bytes.len() as u64 {
            let length = (size - offset).min(4_096);
            if read + length > password::rar::MAX_PROBE_BYTES { return Ok(false); }
            window = read_range(client, url, size, offset, length, etag.as_ref(), fetches, transferred, progress).await?;
            read += length; start = offset;
        }
        let Some(length) = format.header_bytes(&window.bytes[(offset - start) as usize..]) else { return Ok(false); };
        if length as u64 > size - offset { return Ok(false); }
        if offset + length as u64 > start + window.bytes.len() as u64 {
            if read + length as u64 > password::rar::MAX_PROBE_BYTES { return Ok(false); }
            window = read_range(client, url, size, offset, length as u64, etag.as_ref(), fetches, transferred, progress).await?;
            read += length as u64; start = offset;
        }
        let local = (offset - start) as usize;
        let Some(block) = format.block(&window.bytes[local..local + length], index == 0) else { return Ok(false); };
        let Some(next) = offset.checked_add(length as u64).and_then(|n| n.checked_add(block.data_bytes)).filter(|n| *n <= size) else { return Ok(false); };
        if block.encrypted { return Ok(true); }
        if block.end { return Ok(false); }
        offset = next; // Seek over compressed data; never download it to find the next header.
    }
    Ok(false)
}

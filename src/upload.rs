//! PikPak upload helpers: GCID hashing plus authenticated Alibaba OSS writes.
//!
//! PikPak's Drive API returns short-lived OSS credentials after an upload task
//! is created. These helpers deliberately keep those credentials in memory and
//! use header authentication, so secrets never appear in URLs or logs.

use std::io::SeekFrom;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine as _;
use bytes::Bytes;
use futures_util::{stream, StreamExt};
use reqwest::{Method, StatusCode};
use ring::{digest, hmac};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::client::OssUploadParams;

const SMALL_UPLOAD_LIMIT: u64 = 10 * 1024 * 1024;
const MIN_MULTIPART_SIZE: u64 = 1024 * 1024;
const MAX_MULTIPART_PARTS: u64 = 1_000;
const STREAM_CHUNK_SIZE: usize = 256 * 1024;
const MAX_OSS_ATTEMPTS: u32 = 3;
const OSS_USER_AGENT: &str =
    "aliyun-sdk-android/2.9.13(Linux/Android 14/M2004j7ac;UKQ1.231108.001)";

/// A thread-safe callback receiving the logical bytes uploaded for one file.
pub type UploadProgress = Arc<dyn Fn(u64) + Send + Sync>;

/// Calculate PikPak's GCID for a local file while reporting bytes hashed.
///
/// GCID hashes each adaptive-size block with SHA-1, concatenates the binary
/// block digests, then SHA-1 hashes that sequence. This is not a password or
/// security primitive; it is PikPak's content identifier and enables instant
/// uploads when the service already stores the same bytes.
pub async fn gcid_file(path: &Path, file_size: u64, progress: UploadProgress) -> Result<String> {
    let mut file = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("open local file {}", path.display()))?;
    let block_size = gcid_block_size(file_size);
    let mut outer = digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY);
    let mut inner = digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY);
    let mut block_bytes = 0usize;
    let mut total_read = 0u64;
    let mut last_progress = Instant::now();
    let mut buffer = vec![0u8; STREAM_CHUNK_SIZE.min(block_size)];

    loop {
        let read = file
            .read(&mut buffer)
            .await
            .with_context(|| format!("read local file {}", path.display()))?;
        if read == 0 {
            break;
        }

        let mut consumed = 0usize;
        while consumed < read {
            let available = block_size - block_bytes;
            let take = available.min(read - consumed);
            inner.update(&buffer[consumed..consumed + take]);
            block_bytes += take;
            consumed += take;
            if block_bytes == block_size {
                outer.update(inner.finish().as_ref());
                inner = digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY);
                block_bytes = 0;
            }
        }

        total_read = total_read.saturating_add(read as u64);
        if total_read >= file_size || last_progress.elapsed() >= Duration::from_millis(200) {
            progress(total_read.min(file_size));
            last_progress = Instant::now();
        }
    }

    if total_read != file_size {
        bail!("local file changed while hashing (expected {file_size} bytes, read {total_read})");
    }
    if block_bytes > 0 {
        outer.update(inner.finish().as_ref());
    }
    Ok(hex::encode_upper(outer.finish().as_ref()))
}

/// PikPak's GCID for callers that read the bytes themselves, such as one pass that also computes another
/// checksum. It is the algorithm of [`gcid_file`], which a test keeps it in agreement with.
pub struct GcidHasher {
    block_size: usize,
    outer: digest::Context,
    inner: digest::Context,
    block_bytes: usize,
}

impl GcidHasher {
    pub fn new(file_size: u64) -> Self {
        Self {
            block_size: gcid_block_size(file_size),
            outer: digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY),
            inner: digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY),
            block_bytes: 0,
        }
    }

    pub fn update(&mut self, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            let take = (self.block_size - self.block_bytes).min(bytes.len());
            self.inner.update(&bytes[..take]);
            self.block_bytes += take;
            bytes = &bytes[take..];
            if self.block_bytes == self.block_size {
                let block = std::mem::replace(
                    &mut self.inner,
                    digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY),
                );
                self.outer.update(block.finish().as_ref());
                self.block_bytes = 0;
            }
        }
    }

    pub fn finish(mut self) -> String {
        if self.block_bytes > 0 {
            self.outer.update(self.inner.finish().as_ref());
        }
        hex::encode_upper(self.outer.finish().as_ref())
    }
}

/// Upload a file with the temporary OSS credentials returned by PikPak.
pub async fn upload_to_oss(
    http: &reqwest::Client,
    params: &OssUploadParams,
    path: &Path,
    file_size: u64,
    multipart_concurrency: usize,
    progress: UploadProgress,
) -> Result<()> {
    upload_to_oss_with_network(
        http,
        params,
        path,
        file_size,
        multipart_concurrency,
        progress,
        Arc::new(AtomicU64::new(0)),
    )
    .await
}

/// Count bytes pulled by HTTP bodies, including retries, independently of
/// logical progress, saved checkpoints, and instant uploads.
pub async fn upload_to_oss_with_network(
    http: &reqwest::Client,
    params: &OssUploadParams,
    path: &Path,
    file_size: u64,
    multipart_concurrency: usize,
    progress: UploadProgress,
    network_bytes: Arc<AtomicU64>,
) -> Result<()> {
    validate_oss_params(params)?;
    if file_size <= SMALL_UPLOAD_LIMIT {
        put_object(http, params, path, file_size, progress, network_bytes).await
    } else {
        multipart_upload(
            http,
            params,
            path,
            file_size,
            multipart_concurrency.clamp(1, 8),
            progress,
            network_bytes,
        )
        .await
    }
}

fn gcid_block_size(file_size: u64) -> usize {
    let mut block_size = 0x40_000u64;
    while file_size > block_size * 0x200 && block_size < 0x20_0000 {
        block_size <<= 1;
    }
    block_size as usize
}

fn validate_oss_params(params: &OssUploadParams) -> Result<()> {
    if params.access_key_id.trim().is_empty()
        || params.access_key_secret.trim().is_empty()
        || params.bucket.trim().is_empty()
        || params.endpoint.trim().is_empty()
        || params.key.is_empty()
        || params.security_token.trim().is_empty()
    {
        bail!("PikPak returned incomplete temporary upload credentials");
    }
    Ok(())
}

async fn put_object(
    http: &reqwest::Client,
    params: &OssUploadParams,
    path: &Path,
    file_size: u64,
    progress: UploadProgress,
    network_bytes: Arc<AtomicU64>,
) -> Result<()> {
    let url = oss_object_url(params, &[])?;
    let canonical_resource = canonical_resource(params, &[]);
    let monotonic_progress =
        MonotonicProgress::new(progress, file_size).with_network(network_bytes);

    for attempt in 1..=MAX_OSS_ATTEMPTS {
        let body = file_body(path, 0, file_size, 0, monotonic_progress.clone()).await?;
        let response = signed_request(
            http,
            params,
            Method::PUT,
            url.clone(),
            &canonical_resource,
            "application/octet-stream",
        )
        .header(reqwest::header::CONTENT_LENGTH, file_size)
        .body(body)
        .send()
        .await;

        match response {
            Ok(response) if response.status().is_success() => {
                monotonic_progress.emit(file_size);
                return Ok(());
            }
            Ok(response) => {
                let retryable = oss_status_is_retryable(response.status());
                let error = oss_response_error(response, "upload object").await;
                if !retryable || attempt == MAX_OSS_ATTEMPTS {
                    return Err(error);
                }
            }
            Err(error) => {
                if !request_error_is_retryable(&error) || attempt == MAX_OSS_ATTEMPTS {
                    return Err(error).context("send file to PikPak upload storage");
                }
            }
        }
        tokio::time::sleep(upload_retry_delay(attempt)).await;
    }
    unreachable!("bounded OSS upload loop always returns")
}

/// Cancelling a per-file future also discards its OSS multipart session.
/// Credentials stay in this in-memory guard and are never written to disk.
struct MultipartAbortGuard {
    http: reqwest::Client,
    params: OssUploadParams,
    upload_id: String,
    armed: bool,
}
impl Drop for MultipartAbortGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let http = self.http.clone();
            let params = self.params.clone();
            let upload_id = self.upload_id.clone();
            runtime.spawn(async move {
                let _ = abort_multipart(&http, &params, &upload_id).await;
            });
        }
    }
}

async fn multipart_upload(
    http: &reqwest::Client,
    params: &OssUploadParams,
    path: &Path,
    file_size: u64,
    concurrency: usize,
    progress: UploadProgress,
    network_bytes: Arc<AtomicU64>,
) -> Result<()> {
    let upload_id = initiate_multipart(http, params).await?;
    let mut abort_guard = MultipartAbortGuard {
        http: http.clone(),
        params: params.clone(),
        upload_id: upload_id.clone(),
        armed: true,
    };
    let part_size = multipart_part_size(file_size);
    let part_count = file_size.div_ceil(part_size);
    let mut multipart_progress = MultipartProgress::new(progress, part_count as usize, file_size);
    multipart_progress.network_bytes = Some(network_bytes);
    let mut completed_parts = Vec::with_capacity(part_count as usize);
    let upload_id_for_parts = upload_id.as_str();

    // Parts can complete out of order. `buffer_unordered` keeps only a small,
    // fixed number of file handles and request bodies alive, rather than
    // spawning one task for every part of a very large file.
    let mut uploads = stream::iter(0..part_count)
        .map(|part_index| {
            let part_number = part_index + 1;
            let offset = part_index.saturating_mul(part_size);
            let length = part_size.min(file_size.saturating_sub(offset));
            let part_progress = multipart_progress.part_tracker(part_index as usize, length);
            async move {
                upload_part(
                    http,
                    params,
                    path,
                    upload_id_for_parts,
                    part_number,
                    offset,
                    length,
                    part_progress,
                )
                .await
                .map(|etag| (part_number, etag))
            }
        })
        .buffer_unordered(concurrency);

    let mut first_error = None;
    while let Some(result) = uploads.next().await {
        match result {
            Ok(part) => completed_parts.push(part),
            Err(error) => {
                first_error = Some(error);
                break;
            }
        }
    }
    // Dropping the buffered stream cancels any in-flight part bodies before
    // the remote multipart session is aborted.
    drop(uploads);
    if let Some(error) = first_error {
        let _ = abort_multipart(http, params, &upload_id).await;
        return Err(error);
    }

    completed_parts.sort_unstable_by_key(|(part_number, _)| *part_number);
    if let Err(error) = complete_multipart(http, params, &upload_id, &completed_parts).await {
        let _ = abort_multipart(http, params, &upload_id).await;
        return Err(error);
    }
    abort_guard.armed = false;
    multipart_progress.finish();
    Ok(())
}

async fn initiate_multipart(http: &reqwest::Client, params: &OssUploadParams) -> Result<String> {
    let subresources = [("uploads", None)];
    let url = oss_object_url(params, &subresources)?;
    let canonical = canonical_resource(params, &subresources);
    let response = signed_request(http, params, Method::POST, url, &canonical, "")
        .header(reqwest::header::CONTENT_LENGTH, 0)
        .send()
        .await
        .context("start multipart upload")?;
    if !response.status().is_success() {
        return Err(oss_response_error(response, "start multipart upload").await);
    }
    let body = response
        .text()
        .await
        .context("read multipart upload response")?;
    xml_element(&body, "UploadId").ok_or_else(|| {
        anyhow!("PikPak upload storage did not return a multipart upload identifier")
    })
}

#[allow(clippy::too_many_arguments)]
async fn upload_part(
    http: &reqwest::Client,
    params: &OssUploadParams,
    path: &Path,
    upload_id: &str,
    part_number: u64,
    offset: u64,
    length: u64,
    progress: MonotonicProgress,
) -> Result<String> {
    let part_number_string = part_number.to_string();
    let subresources = [
        ("partNumber", Some(part_number_string.as_str())),
        ("uploadId", Some(upload_id)),
    ];
    let url = oss_object_url(params, &subresources)?;
    let canonical = canonical_resource(params, &subresources);

    for attempt in 1..=MAX_OSS_ATTEMPTS {
        let body = file_body(path, offset, length, 0, progress.clone()).await?;
        let response = signed_request(
            http,
            params,
            Method::PUT,
            url.clone(),
            &canonical,
            "application/octet-stream",
        )
        .header(reqwest::header::CONTENT_LENGTH, length)
        .body(body)
        .send()
        .await;

        match response {
            Ok(response) if response.status().is_success() => {
                let etag = response
                    .headers()
                    .get(reqwest::header::ETAG)
                    .and_then(|value| value.to_str().ok())
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string)
                    .ok_or_else(|| anyhow!("upload storage omitted the part ETag"))?;
                progress.emit(length);
                return Ok(etag);
            }
            Ok(response) => {
                let retryable = oss_status_is_retryable(response.status());
                let error = oss_response_error(response, "upload file part").await;
                if !retryable || attempt == MAX_OSS_ATTEMPTS {
                    return Err(error);
                }
            }
            Err(error) => {
                if !request_error_is_retryable(&error) || attempt == MAX_OSS_ATTEMPTS {
                    return Err(error).context("send multipart data to PikPak upload storage");
                }
            }
        }
        tokio::time::sleep(upload_retry_delay(attempt)).await;
    }
    unreachable!("bounded OSS part loop always returns")
}

async fn complete_multipart(
    http: &reqwest::Client,
    params: &OssUploadParams,
    upload_id: &str,
    parts: &[(u64, String)],
) -> Result<()> {
    let body = complete_multipart_xml(parts);
    let subresources = [("uploadId", Some(upload_id))];
    let url = oss_object_url(params, &subresources)?;
    let canonical = canonical_resource(params, &subresources);
    let response = signed_request(
        http,
        params,
        Method::POST,
        url,
        &canonical,
        "application/xml",
    )
    .header(reqwest::header::CONTENT_LENGTH, body.len())
    .body(body)
    .send()
    .await
    .context("complete multipart upload")?;
    if !response.status().is_success() {
        return Err(oss_response_error(response, "complete multipart upload").await);
    }
    Ok(())
}

async fn abort_multipart(
    http: &reqwest::Client,
    params: &OssUploadParams,
    upload_id: &str,
) -> Result<()> {
    let subresources = [("uploadId", Some(upload_id))];
    let url = oss_object_url(params, &subresources)?;
    let canonical = canonical_resource(params, &subresources);
    let response = signed_request(http, params, Method::DELETE, url, &canonical, "")
        .send()
        .await
        .context("abort multipart upload")?;
    if !response.status().is_success() && response.status() != StatusCode::NOT_FOUND {
        return Err(oss_response_error(response, "abort multipart upload").await);
    }
    Ok(())
}

async fn file_body(
    path: &Path,
    offset: u64,
    length: u64,
    progress_base: u64,
    progress: MonotonicProgress,
) -> Result<reqwest::Body> {
    let mut file = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("open local file {}", path.display()))?;
    file.seek(SeekFrom::Start(offset))
        .await
        .with_context(|| format!("seek local file {}", path.display()))?;

    struct State {
        file: tokio::fs::File,
        remaining: u64,
        sent: u64,
        base: u64,
        progress: MonotonicProgress,
    }

    let body_stream = stream::try_unfold(
        State {
            file,
            remaining: length,
            sent: 0,
            base: progress_base,
            progress,
        },
        |mut state| async move {
            if state.remaining == 0 {
                return Ok::<_, std::io::Error>(None);
            }
            let requested = STREAM_CHUNK_SIZE.min(state.remaining as usize);
            let mut buffer = vec![0u8; requested];
            let read = state.file.read(&mut buffer).await?;
            if read == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "local file changed while uploading",
                ));
            }
            buffer.truncate(read);
            state.remaining = state.remaining.saturating_sub(read as u64);
            state.sent = state.sent.saturating_add(read as u64);
            if let Some(counter) = &state.progress.network_bytes {
                counter.fetch_add(read as u64, Ordering::Relaxed);
            }
            state.progress.emit(state.base.saturating_add(state.sent));
            Ok(Some((Bytes::from(buffer), state)))
        },
    );
    Ok(reqwest::Body::wrap_stream(body_stream))
}

fn signed_request(
    http: &reqwest::Client,
    params: &OssUploadParams,
    method: Method,
    url: url::Url,
    canonical_resource: &str,
    content_type: &str,
) -> reqwest::RequestBuilder {
    let date = http_date(SystemTime::now());
    let canonical_oss_headers = format!("x-oss-security-token:{}\n", params.security_token.trim());
    let string_to_sign = format!(
        "{}\n\n{}\n{}\n{}{}",
        method.as_str(),
        content_type,
        date,
        canonical_oss_headers,
        canonical_resource
    );
    let key = hmac::Key::new(
        hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY,
        params.access_key_secret.as_bytes(),
    );
    let signature = BASE64_STANDARD.encode(hmac::sign(&key, string_to_sign.as_bytes()).as_ref());
    let authorization = format!("OSS {}:{signature}", params.access_key_id);

    let mut request = http
        .request(method, url)
        .header(reqwest::header::DATE, date)
        .header("x-oss-security-token", params.security_token.trim())
        .header(reqwest::header::AUTHORIZATION, authorization)
        .header(reqwest::header::USER_AGENT, OSS_USER_AGENT);
    if !content_type.is_empty() {
        request = request.header(reqwest::header::CONTENT_TYPE, content_type);
    }
    request
}

fn oss_object_url(
    params: &OssUploadParams,
    subresources: &[(&str, Option<&str>)],
) -> Result<url::Url> {
    let raw_endpoint = params.endpoint.trim().trim_end_matches('/');
    let normalized = if raw_endpoint.contains("://") {
        raw_endpoint.to_string()
    } else {
        format!("https://{raw_endpoint}")
    };
    let mut url = url::Url::parse(&normalized).context("parse PikPak upload endpoint")?;
    if url.scheme() != "https" && url.scheme() != "http" {
        bail!("PikPak returned an unsupported upload endpoint scheme");
    }
    let host = url
        .host_str()
        .ok_or_else(|| anyhow!("PikPak returned an upload endpoint without a host"))?;
    let bucket_prefix = format!("{}.", params.bucket);
    if !host.starts_with(&bucket_prefix) {
        let bucket_host = format!("{}.{host}", params.bucket);
        url.set_host(Some(&bucket_host))
            .context("apply PikPak upload bucket")?;
    }
    url.set_path(&params.key);
    url.set_query(None);
    if !subresources.is_empty() {
        let mut pairs = url.query_pairs_mut();
        for (key, value) in subresources {
            match value {
                Some(value) => {
                    pairs.append_pair(key, value);
                }
                None => {
                    pairs.append_key_only(key);
                }
            }
        }
    }
    Ok(url)
}

fn canonical_resource(params: &OssUploadParams, subresources: &[(&str, Option<&str>)]) -> String {
    let mut canonical = format!("/{}/{}", params.bucket, params.key);
    if !subresources.is_empty() {
        canonical.push('?');
        for (index, (key, value)) in subresources.iter().enumerate() {
            if index > 0 {
                canonical.push('&');
            }
            canonical.push_str(key);
            if let Some(value) = value {
                canonical.push('=');
                canonical.push_str(value);
            }
        }
    }
    canonical
}

fn multipart_part_size(file_size: u64) -> u64 {
    let desired_parts = if file_size > 9 * 1024 * 1024 * 1024 {
        MAX_MULTIPART_PARTS
    } else {
        ((file_size.saturating_sub(1)) / (1024 * 1024 * 1024) + 1) * 100
    };
    file_size
        .div_ceil(desired_parts.max(1))
        .max(MIN_MULTIPART_SIZE)
}

fn complete_multipart_xml(parts: &[(u64, String)]) -> String {
    let mut xml = String::from("<CompleteMultipartUpload>");
    for (number, etag) in parts {
        xml.push_str("<Part><PartNumber>");
        xml.push_str(&number.to_string());
        xml.push_str("</PartNumber><ETag>");
        xml.push_str(&xml_escape(etag));
        xml.push_str("</ETag></Part>");
    }
    xml.push_str("</CompleteMultipartUpload>");
    xml
}

fn xml_element(xml: &str, name: &str) -> Option<String> {
    let start_marker = format!("<{name}>");
    let end_marker = format!("</{name}>");
    let start = xml.find(&start_marker)? + start_marker.len();
    let end = xml[start..].find(&end_marker)? + start;
    let value = xml_unescape(xml[start..end].trim());
    (!value.is_empty()).then_some(value)
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn xml_unescape(value: &str) -> String {
    value
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

async fn oss_response_error(response: reqwest::Response, action: &str) -> anyhow::Error {
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    let detail = body.split_whitespace().collect::<Vec<_>>().join(" ");
    let detail = detail.chars().take(320).collect::<String>();
    if detail.is_empty() {
        anyhow!("{action} failed with HTTP {}", status.as_u16())
    } else {
        anyhow!("{action} failed with HTTP {}: {detail}", status.as_u16())
    }
}

fn oss_status_is_retryable(status: StatusCode) -> bool {
    status == StatusCode::REQUEST_TIMEOUT
        || status == StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error()
}

fn request_error_is_retryable(error: &reqwest::Error) -> bool {
    error.is_timeout() || error.is_connect() || error.is_request() || error.is_body()
}

fn upload_retry_delay(attempt: u32) -> Duration {
    Duration::from_millis(500u64.saturating_mul(1u64 << attempt.saturating_sub(1).min(4)))
}

/// Aggregates independently advancing multipart streams into one logical file
/// position. Reporting an offset from whichever part happens to run furthest
/// would make progress jump ahead and then stall; summing per-part high-water
/// marks keeps the UI monotonic and truthful when parts finish out of order.
#[derive(Clone)]
struct MultipartProgress {
    callback: UploadProgress,
    network_bytes: Option<Arc<AtomicU64>>,
    state: Arc<Mutex<MultipartProgressState>>,
}

struct MultipartProgressState {
    part_bytes: Vec<u64>,
    last_emitted: u64,
    last_emit: Instant,
    total: u64,
}

impl MultipartProgress {
    fn new(callback: UploadProgress, part_count: usize, total: u64) -> Self {
        Self {
            callback,
            network_bytes: None,
            state: Arc::new(Mutex::new(MultipartProgressState {
                part_bytes: vec![0; part_count],
                last_emitted: 0,
                last_emit: Instant::now(),
                total,
            })),
        }
    }

    fn part_tracker(&self, part_index: usize, part_size: u64) -> MonotonicProgress {
        let aggregate = self.clone();
        let mut tracker = MonotonicProgress::new(
            Arc::new(move |part_bytes| aggregate.emit_part(part_index, part_bytes)),
            part_size,
        );
        tracker.network_bytes = self.network_bytes.clone();
        tracker
    }

    fn emit_part(&self, part_index: usize, part_bytes: u64) {
        let emission = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            let Some(previous) = state.part_bytes.get(part_index).copied() else {
                return;
            };
            if part_bytes <= previous {
                return;
            }
            state.part_bytes[part_index] = part_bytes;
            let aggregate = state
                .part_bytes
                .iter()
                .fold(0u64, |total, value| total.saturating_add(*value))
                .min(state.total);
            let should_emit =
                aggregate >= state.total || state.last_emit.elapsed() >= Duration::from_millis(200);
            if !should_emit || aggregate <= state.last_emitted {
                None
            } else {
                state.last_emitted = aggregate;
                state.last_emit = Instant::now();
                Some(aggregate)
            }
        };
        if let Some(value) = emission {
            (self.callback)(value);
        }
    }

    fn finish(&self) {
        let total = self.state.lock().map(|state| state.total).unwrap_or(0);
        (self.callback)(total);
    }
}

#[derive(Clone)]
struct MonotonicProgress {
    callback: UploadProgress,
    network_bytes: Option<Arc<AtomicU64>>,
    state: Arc<Mutex<MonotonicProgressState>>,
}

struct MonotonicProgressState {
    highest: u64,
    last_emitted: u64,
    last_emit: Instant,
    total: u64,
}

impl MonotonicProgress {
    fn new(callback: UploadProgress, total: u64) -> Self {
        Self {
            callback,
            network_bytes: None,
            state: Arc::new(Mutex::new(MonotonicProgressState {
                highest: 0,
                last_emitted: 0,
                last_emit: Instant::now(),
                total,
            })),
        }
    }

    fn with_network(mut self, counter: Arc<AtomicU64>) -> Self {
        self.network_bytes = Some(counter);
        self
    }

    fn emit(&self, value: u64) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if value <= state.highest {
            return;
        }
        state.highest = value;
        let should_emit =
            value >= state.total || state.last_emit.elapsed() >= Duration::from_millis(200);
        if !should_emit || value <= state.last_emitted {
            return;
        }
        state.last_emitted = value;
        state.last_emit = Instant::now();
        drop(state);
        (self.callback)(value);
    }
}

/// Format an IMF-fixdate without adding a heavy date/time dependency.
fn http_date(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    let weekdays = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let weekday = weekdays[days.rem_euclid(7) as usize];
    format!(
        "{weekday}, {day:02} {} {year:04} {hour:02}:{minute:02}:{second:02} GMT",
        months[(month - 1) as usize]
    )
}

/// Howard Hinnant's public-domain civil-calendar conversion, with day zero at
/// 1970-01-01. It is valid for every timestamp SystemTime can practically
/// produce in this application.
fn civil_from_days(days_since_unix_epoch: i64) -> (i64, i64, i64) {
    let z = days_since_unix_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    fn params() -> OssUploadParams {
        OssUploadParams {
            access_key_id: "id".into(),
            access_key_secret: "secret".into(),
            bucket: "bucket".into(),
            endpoint: "https://oss.example.test".into(),
            key: "folder/a b.txt".into(),
            security_token: "token".into(),
        }
    }

    #[test]
    fn oss_url_uses_bucket_host_and_encodes_object_key() {
        let url = oss_object_url(
            &params(),
            &[("partNumber", Some("1")), ("uploadId", Some("a+b"))],
        )
        .unwrap();
        assert_eq!(url.host_str(), Some("bucket.oss.example.test"));
        assert_eq!(url.path(), "/folder/a%20b.txt");
        assert_eq!(url.query(), Some("partNumber=1&uploadId=a%2Bb"));
    }

    #[test]
    fn canonical_resource_keeps_oss_subresource_order() {
        assert_eq!(
            canonical_resource(
                &params(),
                &[("partNumber", Some("2")), ("uploadId", Some("upload"))]
            ),
            "/bucket/folder/a b.txt?partNumber=2&uploadId=upload"
        );
    }

    #[test]
    fn multipart_parts_stay_within_pikpak_limits() {
        assert_eq!(multipart_part_size(11 * 1024 * 1024), 1024 * 1024);
        let huge = 20 * 1024 * 1024 * 1024u64;
        assert!(huge.div_ceil(multipart_part_size(huge)) <= MAX_MULTIPART_PARTS);
    }

    #[test]
    fn gcid_block_size_matches_threshold_boundaries() {
        let base = 0x40_000u64;
        assert_eq!(gcid_block_size(base * 0x200), base as usize);
        assert_eq!(gcid_block_size(base * 0x200 + 1), (base * 2) as usize);
        assert_eq!(gcid_block_size(20 * 1024 * 1024 * 1024), 0x20_0000);
    }

    #[test]
    fn multipart_progress_sums_parts_that_finish_out_of_order() {
        let observed = Arc::new(Mutex::new(Vec::new()));
        let callback_values = observed.clone();
        let aggregate = MultipartProgress::new(
            Arc::new(move |value| callback_values.lock().unwrap().push(value)),
            3,
            100,
        );
        let first = aggregate.part_tracker(0, 30);
        let second = aggregate.part_tracker(1, 30);
        let third = aggregate.part_tracker(2, 40);

        third.emit(40);
        first.emit(30);
        second.emit(30);
        aggregate.finish();

        let state = aggregate.state.lock().unwrap();
        assert_eq!(state.part_bytes, vec![30, 30, 40]);
        drop(state);
        let values = observed.lock().unwrap();
        assert_eq!(values.last(), Some(&100));
        assert!(values.windows(2).all(|window| window[0] <= window[1]));
    }

    #[test]
    fn fixed_http_date_matches_unix_epoch() {
        assert_eq!(http_date(UNIX_EPOCH), "Thu, 01 Jan 1970 00:00:00 GMT");
    }

    #[tokio::test]
    async fn network_counter_measures_retried_bodies_and_multipart_independently_of_progress() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let data = vec![0x5a; 512 * 1024];
        let size = data.len() as u64;
        let server = std::thread::spawn(move || {
            let mut received = 0u64;
            for attempt in 0..4 {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut headers = Vec::new();
                while !headers.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    socket.read_exact(&mut byte).unwrap();
                    headers.push(byte[0]);
                }
                let headers = String::from_utf8(headers).unwrap().to_ascii_lowercase();
                let length: u64 = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .unwrap()
                    .parse()
                    .unwrap();
                let mut body = Vec::new();
                (&mut socket).take(length).read_to_end(&mut body).unwrap();
                assert_eq!(body.len() as u64, length);
                assert!(body.iter().all(|byte| *byte == 0x5a));
                received += length;
                let status = if attempt == 0 {
                    "503 Service Unavailable"
                } else {
                    "200 OK"
                };
                write!(
                    socket,
                    "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
                .unwrap();
            }
            received
        });
        let directory =
            std::env::temp_dir().join(format!("pikpak-upload-network-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("fixture.bin");
        std::fs::write(&path, data).unwrap();
        let network = Arc::new(AtomicU64::new(0));
        let logical = Arc::new(AtomicU64::new(0));
        let callback = logical.clone();
        let progress = MonotonicProgress::new(
            Arc::new(move |bytes| {
                callback.store(bytes, Ordering::Relaxed);
            }),
            size,
        )
        .with_network(network.clone());
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        for _ in 0..2 {
            let body = file_body(&path, 0, size, 0, progress.clone())
                .await
                .unwrap();
            client
                .put(format!("http://{address}/fixture"))
                .header(reqwest::header::CONTENT_LENGTH, size)
                .body(body)
                .send()
                .await
                .unwrap();
        }
        assert_eq!(logical.load(Ordering::Relaxed), size);
        assert_eq!(
            network.load(Ordering::Relaxed),
            size * 2,
            "Retransmitted bytes must be measured even when logical progress cannot advance"
        );
        let mut multipart = MultipartProgress::new(Arc::new(|_| {}), 2, size);
        multipart.network_bytes = Some(network.clone());
        for index in 0..2 {
            let body = file_body(
                &path,
                index * size / 2,
                size / 2,
                0,
                multipart.part_tracker(index as usize, size / 2),
            )
            .await
            .unwrap();
            client
                .put(format!("http://{address}/part"))
                .header(reqwest::header::CONTENT_LENGTH, size / 2)
                .body(body)
                .send()
                .await
                .unwrap();
        }
        assert_eq!(server.join().unwrap(), size * 3);
        assert_eq!(network.load(Ordering::Relaxed), size * 3);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn gcid_matches_known_small_file_vector() {
        let directory =
            std::env::temp_dir().join(format!("pikpak-gcid-test-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("abc.txt");
        std::fs::write(&path, b"abc").unwrap();
        let digest = gcid_file(&path, 3, Arc::new(|_| {})).await.unwrap();
        assert_eq!(digest, "0D3CED9BEC10A777AEC23CCC353A8C08A633045E");
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_dir(directory);
    }
}

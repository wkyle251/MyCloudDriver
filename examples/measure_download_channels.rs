//! Read-only channel comparison for an explicitly selected account original.
//! Input is a private JSON plan; URLs, tokens and file contents are never logged.
use anyhow::{anyhow, ensure, Result};
use futures_util::StreamExt;
use pikpak::{auth::OAuthCredentials, Client};
use reqwest::{header, StatusCode};
use serde::Deserialize;
use std::{
    path::PathBuf,
    process::ExitCode,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

#[derive(Deserialize)]
struct Plan {
    account_directory: PathBuf,
    target: Target,
    #[serde(default = "default_channels")]
    channels: Vec<usize>,
    #[serde(default = "default_sample_bytes")]
    sample_bytes: u64,
}

fn default_channels() -> Vec<usize> {
    vec![1, 2, 4, 8, 8, 4, 2, 1]
}

fn default_sample_bytes() -> u64 {
    128 * 1024 * 1024
}

#[derive(Deserialize)]
struct Target {
    id: String,
    name: String,
    size: u64,
}

fn safe_http(error: reqwest::Error) -> anyhow::Error {
    if let Some(status) = error.status() {
        anyhow!("HTTP status {}", status.as_u16())
    } else if error.is_timeout() {
        anyhow!("Network timeout")
    } else if error.is_connect() {
        anyhow!("Connection failed")
    } else {
        anyhow!("HTTP transfer failed")
    }
}

fn range(response: &reqwest::Response) -> Option<(u64, u64, u64)> {
    let value = response
        .headers()
        .get(header::CONTENT_RANGE)?
        .to_str()
        .ok()?;
    let (span, size) = value.strip_prefix("bytes ")?.split_once('/')?;
    let (start, end) = span.split_once('-')?;
    Some((start.parse().ok()?, end.parse().ok()?, size.parse().ok()?))
}

async fn original(client: &Client, target: &Target) -> Result<pikpak::DownloadInfo> {
    let info = tokio::time::timeout(Duration::from_secs(60), client.get_download_url(&target.id))
        .await
        .map_err(|_| anyhow!("Original metadata setup exceeded sixty seconds"))?
        .map_err(|_| anyhow!("Could not resolve the selected original"))?;
    ensure!(
        info.name == target.name && info.size == target.size,
        "Selected original metadata changed; comparison stopped"
    );
    ensure!(
        reqwest::Url::parse(&info.web_content_link).is_ok_and(|url| url.scheme() == "https"),
        "The original does not have an HTTPS URL"
    );
    Ok(info)
}

async fn run() -> Result<()> {
    let path = std::env::args_os()
        .nth(1)
        .ok_or_else(|| anyhow!("Supply a private benchmark plan"))?;
    let plan: Plan = serde_json::from_slice(
        &std::fs::read(path).map_err(|_| anyhow!("Cannot read benchmark plan"))?,
    )
    .map_err(|_| anyhow!("Invalid benchmark plan"))?;
    // This is a bounded diagnostic, separate from production admission. Keep
    // invalid plans from allocating unbounded tasks or payload buffers.
    ensure!(
        !plan.channels.is_empty()
            && plan.channels.len() <= 16
            && plan.channels.iter().all(|count| (1..=128).contains(count)),
        "Supply 1 to 16 trials with 1 to 128 channels each"
    );
    ensure!(
        (8 * 1024 * 1024..=1024 * 1024 * 1024).contains(&plan.sample_bytes),
        "Sample size must be between 8 MiB and 1 GiB"
    );
    let sample = plan.target.size.min(plan.sample_bytes);
    ensure!(
        sample >= 8 * 1024 * 1024
            && sample / *plan.channels.iter().max().unwrap() as u64 >= 1024 * 1024,
        "The selected sample is too small for this comparison"
    );
    let token_path = plan.account_directory.join("refresh-token");
    let token =
        std::fs::read_to_string(&token_path).map_err(|_| anyhow!("Saved session unavailable"))?;
    let device = std::fs::read_to_string(plan.account_directory.join("device-id"))
        .map_err(|_| anyhow!("Saved device unavailable"))?;
    let secret = std::env::var("PIKPAK_DESKTOP_CLIENT_SECRET")
        .map_err(|_| anyhow!("Desktop build credentials unavailable"))?;
    let client = Client::builder()
        .refresh_token(token.trim())
        .device_id(device.trim())
        .credentials(OAuthCredentials::new(
            pikpak::auth::DESKTOP_CLIENT_ID,
            secret,
        ))
        .shared_refresh_token_store(
            &token_path,
            plan.account_directory.join("refresh-token.lock"),
        )
        .build()
        .map_err(|_| anyhow!("Could not construct the direct client"))?;
    let info = original(&client, &plan.target).await?;
    let http = client.download_http_client();
    let probe = http
        .get(&info.web_content_link)
        .timeout(Duration::from_secs(30))
        .header(header::RANGE, "bytes=0-0")
        .header(header::ACCEPT_ENCODING, "identity")
        .send()
        .await
        .map_err(safe_http)?;
    println!(
        "{}",
        serde_json::json!({"event":"probe", "status":probe.status().as_u16(),
        "valid_range":range(&probe)==Some((0,0,plan.target.size)), "direct":true,
        "http_version":format!("{:?}",probe.version()),
        "strong_etag":probe.headers().get(header::ETAG).and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.starts_with('"') && v.ends_with('"'))})
    );
    ensure!(
        probe.status() == StatusCode::PARTIAL_CONTENT
            && range(&probe) == Some((0, 0, plan.target.size)),
        "The selected original did not return the requested range"
    );
    let etag = probe
        .headers()
        .get(header::ETAG)
        .cloned()
        .filter(|value| {
            value
                .to_str()
                .is_ok_and(|value| value.starts_with('"') && value.ends_with('"'))
        })
        .ok_or_else(|| anyhow!("A strong validator is required for this comparison"))?;
    let mut probe = probe;
    let mut probe_bytes = 0usize;
    while let Some(chunk) = probe.chunk().await.map_err(safe_http)? {
        probe_bytes = probe_bytes.saturating_add(chunk.len());
        ensure!(probe_bytes <= 1, "Probe exceeded its one-byte boundary");
    }
    ensure!(probe_bytes == 1, "Invalid probe body");
    println!(
        "{}",
        serde_json::json!({"event":"comparison_started","channels":plan.channels,
            "sample_bytes":sample,"total_measured_bytes":sample*plan.channels.len() as u64})
    );
    let mut reference_hash = None;
    for (index, channels) in plan.channels.iter().copied().enumerate() {
        // Refresh the signed original URL for every trial. Metadata requests are
        // outside the body timer; all trials use the same file and byte span.
        let info = original(&client, &plan.target).await?;
        let received = Arc::new(AtomicU64::new(0));
        let started = Instant::now();
        let mut tasks = tokio::task::JoinSet::new();
        println!(
            "{}",
            serde_json::json!({"event":"trial_started","trial":index+1,
            "channels":channels,"sample_bytes":sample})
        );
        for channel in 0..channels {
            let start = sample * channel as u64 / channels as u64;
            let end = sample * (channel + 1) as u64 / channels as u64 - 1;
            let target_size = plan.target.size;
            let http = http.clone();
            let link = info.web_content_link.clone();
            let etag = etag.clone();
            let received = received.clone();
            tasks.spawn(async move {
                let response = http
                    .get(link)
                    .header(header::RANGE, format!("bytes={start}-{end}"))
                    .header(header::IF_RANGE, etag.clone())
                    .header(header::ACCEPT_ENCODING, "identity")
                    .send()
                    .await
                    .map_err(safe_http)?;
                let headers_seconds = started.elapsed().as_secs_f64();
                ensure!(
                    response.status() == StatusCode::PARTIAL_CONTENT,
                    "Range request returned HTTP {}; comparison stopped",
                    response.status().as_u16()
                );
                ensure!(
                    range(&response) == Some((start, end, target_size)),
                    "Incorrect byte range"
                );
                ensure!(
                    response.headers().get(header::ETAG) == Some(&etag),
                    "Original validator changed"
                );
                ensure!(
                    response
                        .content_length()
                        .is_none_or(|size| size == end - start + 1),
                    "Incorrect range length"
                );
                ensure!(
                    response
                        .headers()
                        .get(header::CONTENT_ENCODING)
                        .is_none_or(|value| value == "identity"),
                    "Unexpected content encoding"
                );
                let mut data = Vec::with_capacity((end - start + 1) as usize);
                let mut body = response.bytes_stream();
                while let Some(chunk) = body.next().await {
                    let chunk = chunk.map_err(safe_http)?;
                    ensure!(
                        data.len() as u64 + chunk.len() as u64 <= end - start + 1,
                        "Range body exceeded its boundary"
                    );
                    received.fetch_add(chunk.len() as u64, Ordering::Relaxed);
                    data.extend_from_slice(&chunk);
                }
                ensure!(
                    data.len() as u64 == end - start + 1,
                    "Incomplete range body"
                );
                Ok::<_, anyhow::Error>((channel, data, headers_seconds))
            });
        }
        let mut pieces = Vec::new();
        let mut heartbeat = tokio::time::interval(Duration::from_secs(10));
        heartbeat.tick().await;
        while !tasks.is_empty() {
            tokio::select! {
                completed=tasks.join_next()=>pieces.push(completed.unwrap()
                    .map_err(|_|anyhow!("Range task stopped"))??),
                _=heartbeat.tick()=>println!("{}",serde_json::json!({"event":"trial_progress",
                    "trial":index+1,"channels":channels,"received_bytes":received.load(Ordering::Relaxed),
                    "elapsed_seconds":started.elapsed().as_secs_f64()})),
                _=tokio::time::sleep_until((started+Duration::from_secs(180)).into())=>{
                    return Err(anyhow!("Trial exceeded the three-minute comparison limit"));
                }
            }
        }
        let seconds = started.elapsed().as_secs_f64();
        pieces.sort_by_key(|piece| piece.0);
        let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
        for (_, piece, _) in &pieces {
            hash.update(piece);
        }
        let hash = hash.finish();
        if let Some(reference) = &reference_hash {
            ensure!(
                hash.as_ref() == reference,
                "Sample integrity differs between trials"
            );
        } else {
            reference_hash = Some(hash.as_ref().to_vec());
        }
        let headers = pieces.iter().map(|piece| piece.2).fold(0.0, f64::max);
        println!(
            "{}",
            serde_json::json!({"event":"trial_finished","trial":index+1,
            "channels":channels,"sample_bytes":sample,"seconds":seconds,
            "mib_per_second":sample as f64/(1<<20) as f64/seconds,
            "slowest_headers_seconds":headers,"integrity_matches":true,"direct":true})
        );
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    println!(
        "{}",
        serde_json::json!({"event":"finished","trials":plan.channels.len(),"sample_bytes":sample,
        "total_measured_bytes":sample*plan.channels.len() as u64,"integrity_matches":true})
    );
    Ok(())
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            // run() converts network/auth errors to fixed categories first.
            eprintln!("Comparison stopped: {error}");
            ExitCode::FAILURE
        }
    }
}

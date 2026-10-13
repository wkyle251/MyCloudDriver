//! Retry information shared by metadata requests and original downloads.
use std::time::{Duration, SystemTime};

pub fn retry_after(headers: &reqwest::header::HeaderMap) -> Option<Duration> {
    let value = headers
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim();
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds.min(86_400)));
    }
    httpdate::parse_http_date(value).ok().map(|date| {
        date.duration_since(SystemTime::now())
            .unwrap_or_default()
            .min(Duration::from_secs(86_400))
    })
}

pub fn transient_status(status: u16) -> bool {
    matches!(status, 408 | 429 | 500..=599)
}

/// A broken/expired link affects one file. Reduce the whole transfer pool only
/// for service congestion or a process-wide shortage of file descriptors.
pub fn reduce_concurrency(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        let status = if let Some(failure) = cause.downcast_ref::<HttpFailure>() {
            Some(failure.status)
        } else if let Some(
            crate::Error::Api { status, .. } | crate::Error::RetryAfter { status, .. },
        ) = cause.downcast_ref::<crate::Error>()
        {
            Some(*status)
        } else {
            None
        };
        status.is_some_and(|status| matches!(status, 429 | 500..=599))
            || cause
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| matches!(error.raw_os_error(), Some(23 | 24)))
    })
}

#[derive(Debug, thiserror::Error)]
#[error("Temporary download interruption")]
pub struct Interrupted;

/// A clean, validated response supplied only a prefix, or explicitly refused
/// the remaining range. This is distinct from a broken network connection.
#[derive(Debug, thiserror::Error)]
#[error("The current download source cannot supply the remaining bytes")]
pub struct ContentUnavailable;

/// A validated response advanced a resumable prefix. The next request should
/// try the remaining range on the same route before spending account quota.
#[derive(Debug, thiserror::Error)]
#[error("The download response supplied a resumable prefix")]
pub struct PartialContent;

#[derive(Debug, thiserror::Error)]
#[error("The download service returned an invalid byte range")]
pub struct InvalidByteRange;

#[derive(Debug, thiserror::Error)]
#[error("The original exceeded its declared size ({received} bytes supplied; {expected} expected); download was not finalized")]
pub struct OriginalSizeMismatch {
    pub expected: u64,
    pub received: u64,
}

#[derive(Debug, thiserror::Error)]
#[error(
    "Download destination is unavailable or was replaced; reconnect the original disk and resume"
)]
pub struct DestinationUnavailable;

/// Device failures can recover after reconnecting a disk. Missing individual
/// files and ordinary access denial retain their existing failure policy.
pub fn destination_io_interrupted(error: &std::io::Error) -> bool {
    error.raw_os_error().is_some_and(|code| {
        let errno = rustix::io::Errno::from_raw_os_error(code);
        matches!(
            errno,
            rustix::io::Errno::IO
                | rustix::io::Errno::NXIO
                | rustix::io::Errno::NODEV
                | rustix::io::Errno::STALE
        )
    }) || error
        .get_ref()
        .is_some_and(|cause| cause.is::<DestinationUnavailable>())
}

pub fn destination_unavailable(error: &anyhow::Error) -> bool {
    error.is::<DestinationUnavailable>()
        || error.chain().any(|cause| {
            cause.is::<DestinationUnavailable>()
                || cause
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(destination_io_interrupted)
        })
}

#[derive(Debug, thiserror::Error)]
#[error("Download service returned HTTP {status}")]
pub struct HttpFailure {
    pub status: u16,
    pub retry_after: Option<Duration>,
}

pub fn retryable(error: &anyhow::Error) -> bool {
    // Typed anyhow context is downcastable without appearing as a separate
    // Error::source entry, including transport's Interrupted retry marker.
    if error.is::<Interrupted>()
        || error.is::<PartialContent>()
        || error.is::<DestinationUnavailable>()
        || error.is::<LocalFileConflict>()
    {
        return true;
    }
    error.chain().any(|cause| {
        if cause.is::<Interrupted>()
            || cause.is::<PartialContent>()
            || cause.is::<DestinationUnavailable>()
            || cause.is::<LocalFileConflict>()
        {
            return true;
        }
        if let Some(crate::download_ranges::Error::Network(error)) =
            cause.downcast_ref::<crate::download_ranges::Error>()
        {
            // Reqwest can classify a truncated Content-Length body as a decode
            // error. Here it is a body transport failure, not metadata parsing.
            return !error.is_builder();
        }
        if let Some(failure) = cause.downcast_ref::<HttpFailure>() {
            // Signed content links expire independently of the account session.
            return transient_status(failure.status) || matches!(failure.status, 401 | 403);
        }
        if let Some(error) = cause.downcast_ref::<crate::Error>() {
            return match error {
                crate::Error::Api { status, .. } | crate::Error::RetryAfter { status, .. } => {
                    transient_status(*status)
                }
                _ => false,
            };
        }
        if let Some(error) = cause.downcast_ref::<reqwest::Error>() {
            return !error.is_builder()
                && (error.is_timeout()
                    || error.is_connect()
                    || error.is_request()
                    || error.is_body());
        }
        if let Some(error) = cause.downcast_ref::<std::io::Error>() {
            return destination_io_interrupted(error)
                || matches!(error.raw_os_error(), Some(23 | 24))
                || matches!(
                    error.kind(),
                    std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::ConnectionAborted
                        | std::io::ErrorKind::NotConnected
                );
        }
        false
    })
}

/// This path now holds a different file than the one queued, so retrying can never fetch the queued one.
#[derive(Debug, thiserror::Error)]
#[error("This path now identifies a different file. Refresh the folder and try again.")]
pub struct SourceReplaced;

/// A destination or staging file no longer matches this download. The runner
/// removes conflicting regular files under its output lease and retries;
/// failed cleanup remains eligible for automatic retry.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct LocalFileConflict(pub String);

pub const FILE_MISSING: &str = "No longer found on PikPak; it was deleted or moved";
pub const CONTENT_GONE: &str = "PikPak reports this file's content is no longer available";
pub const PATH_REPLACED: &str = "The path now holds a different file; refresh the folder and download it again";
pub const ORIGINAL_SIZE_MISMATCH: &str = "PikPak repeatedly returned content larger than this original's declared size; refresh the file and retry";

fn http_content_gone(status: u16) -> bool {
    matches!(status, 404 | 410)
}

/// The account's file lookup says the file does not exist, in either of the two shapes PikPak uses.
fn api_file_missing(status: u16, message: &str) -> bool {
    status == 404
        || (status == 400
            && serde_json::from_str::<serde_json::Value>(message)
                .ok()
                .is_some_and(|body| body.get("error").and_then(|error| error.as_str()) == Some("file_not_found")))
}

/// Why this exact file can no longer be fetched from the account, or `None` when the failure may still clear
/// (throttling, outages, expired links, disks, permissions, sessions and anything unrecognised).
/// A single report is not proof: callers wait for the same reason to repeat before they stop retrying.
pub fn permanent_failure(error: &anyhow::Error) -> Option<&'static str> {
    error.chain().find_map(|cause| {
        if cause.is::<SourceReplaced>() {
            return Some(PATH_REPLACED);
        }
        if cause.is::<OriginalSizeMismatch>() {
            return Some(ORIGINAL_SIZE_MISMATCH);
        }
        if let Some(failure) = cause.downcast_ref::<HttpFailure>() {
            return http_content_gone(failure.status).then_some(CONTENT_GONE);
        }
        if let Some(crate::download_ranges::Error::Http(failure)) =
            cause.downcast_ref::<crate::download_ranges::Error>()
        {
            return http_content_gone(failure.status).then_some(CONTENT_GONE);
        }
        match cause.downcast_ref::<crate::Error>()? {
            crate::Error::NotFound { .. } => Some(FILE_MISSING),
            crate::Error::Api { status, message } if api_file_missing(*status, message) => Some(FILE_MISSING),
            _ => None,
        }
    })
}

pub fn delay(error: &anyhow::Error) -> Option<Duration> {
    error
        .chain()
        .filter_map(|cause| {
            if let Some(failure) = cause.downcast_ref::<HttpFailure>() {
                return failure.retry_after;
            }
            if let Some(crate::Error::RetryAfter { delay, .. }) =
                cause.downcast_ref::<crate::Error>()
            {
                return Some(*delay);
            }
            None
        })
        .max()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn destination_interruption_is_typed_and_does_not_retry_missing_files() {
        let guarded = anyhow::Error::new(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            DestinationUnavailable,
        ))
        .context("opening the destination");
        assert!(destination_unavailable(&guarded));
        assert!(retryable(&guarded));
        for errno in [
            rustix::io::Errno::IO,
            rustix::io::Errno::NXIO,
            rustix::io::Errno::NODEV,
            rustix::io::Errno::STALE,
        ] {
            let error = anyhow::Error::new(std::io::Error::from_raw_os_error(errno.raw_os_error()));
            assert!(destination_unavailable(&error));
            assert!(retryable(&error));
            assert!(!reduce_concurrency(&error));
        }
        for kind in [
            std::io::ErrorKind::PermissionDenied,
            std::io::ErrorKind::NotFound,
        ] {
            let error = anyhow::Error::new(std::io::Error::from(kind));
            assert!(!destination_unavailable(&error));
            assert!(!retryable(&error));
        }
        // An ordinary disconnected network socket remains a network retry.
        assert!(!destination_unavailable(
            &std::io::Error::from(std::io::ErrorKind::NotConnected).into()
        ));
    }
    #[test]
    fn only_a_file_that_cannot_come_back_is_permanent() {
        let missing = |error: anyhow::Error| permanent_failure(&error.context("failed to download A.bin"));
        assert_eq!(
            missing(crate::Error::NotFound { path: "/A.bin".into(), segment: "A.bin".into() }.into()),
            Some(FILE_MISSING)
        );
        assert_eq!(
            missing(crate::Error::Api { status: 404, message: "gone".into() }.into()),
            Some(FILE_MISSING)
        );
        assert_eq!(
            missing(crate::Error::Api { status: 400, message: r#"{"error":"file_not_found","error_code":9}"#.into() }.into()),
            Some(FILE_MISSING)
        );
        assert_eq!(missing(SourceReplaced.into()), Some(PATH_REPLACED));
        for status in [404, 410] {
            assert_eq!(missing(HttpFailure { status, retry_after: None }.into()), Some(CONTENT_GONE));
            assert_eq!(
                missing(crate::download_ranges::Error::Http(HttpFailure { status, retry_after: None }).into()),
                Some(CONTENT_GONE)
            );
        }
        // Throttling, outages, expired links, sessions, disks and unrecognised failures all keep retrying.
        for status in [401, 403, 408, 429, 500, 502, 503, 504] {
            assert_eq!(missing(HttpFailure { status, retry_after: None }.into()), None, "HTTP {status}");
            assert_eq!(
                missing(crate::download_ranges::Error::Http(HttpFailure { status, retry_after: None }).into()),
                None,
                "ranged HTTP {status}"
            );
            assert_eq!(missing(crate::Error::Api { status, message: "temporary".into() }.into()), None, "API {status}");
        }
        assert_eq!(
            missing(crate::Error::Api { status: 400, message: r#"{"error":"invalid_argument"}"#.into() }.into()),
            None
        );
        assert_eq!(missing(crate::Error::TokenExpired.into()), None);
        assert_eq!(missing(crate::Error::SessionRejected("revoked").into()), None);
        for kind in [
            std::io::ErrorKind::StorageFull,
            std::io::ErrorKind::PermissionDenied,
            std::io::ErrorKind::NotFound,
            std::io::ErrorKind::TimedOut,
        ] {
            assert_eq!(missing(std::io::Error::from(kind).into()), None, "{kind:?}");
        }
        assert_eq!(missing(Interrupted.into()), None);
        assert_eq!(missing(anyhow::anyhow!("The download source changed while refreshing its URL; resume")), None);
    }

    #[test]
    fn oversized_original_reports_a_stable_reason_even_when_byte_counts_change() {
        for received in [9, 10, 1024] {
            let error = anyhow::Error::new(OriginalSizeMismatch { expected: 8, received })
                .context("failed to download generated.bin");
            assert_eq!(permanent_failure(&error), Some(ORIGINAL_SIZE_MISMATCH));
            assert!(!retryable(&error));
            assert!(!reduce_concurrency(&error));
        }
    }
    #[test]
    fn individual_failures_do_not_throttle_healthy_files() {
        for status in [401, 403, 408] {
            let error = anyhow::Error::new(HttpFailure {
                status,
                retry_after: None,
            })
            .context("retry this file");
            assert!(retryable(&error));
            assert!(!reduce_concurrency(&error));
        }
        for kind in [
            std::io::ErrorKind::ConnectionReset,
            std::io::ErrorKind::TimedOut,
        ] {
            let error = anyhow::Error::new(std::io::Error::from(kind));
            assert!(retryable(&error));
            assert!(!reduce_concurrency(&error));
        }
        for status in [429, 500, 503] {
            let error = anyhow::Error::new(HttpFailure {
                status,
                retry_after: Some(Duration::from_secs(12)),
            })
            .context("retry this file");
            assert!(reduce_concurrency(&error));
            assert_eq!(delay(&error), Some(Duration::from_secs(12)));
        }
        assert!(reduce_concurrency(&anyhow::Error::new(
            crate::Error::RetryAfter {
                status: 429,
                delay: Duration::from_secs(12),
            }
        )));
        assert!(reduce_concurrency(&anyhow::Error::new(
            std::io::Error::from_raw_os_error(24)
        )));
    }
    #[test]
    fn permanent_failures_stop_and_provider_delays_survive_context() {
        for status in [400, 401, 403, 404] {
            assert!(!retryable(&anyhow::Error::new(crate::Error::Api {
                status,
                message: "unavailable".into()
            })));
        }
        for error in [
            std::io::ErrorKind::PermissionDenied,
            std::io::ErrorKind::StorageFull,
            std::io::ErrorKind::NotFound,
        ] {
            assert!(!retryable(&std::io::Error::from(error).into()));
        }
        let error = anyhow::Error::new(HttpFailure {
            status: 503,
            retry_after: Some(Duration::from_secs(120)),
        })
        .context("file");
        assert!(retryable(&error));
        assert_eq!(delay(&error), Some(Duration::from_secs(120)));
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(reqwest::header::RETRY_AFTER, "120".parse().unwrap());
        assert_eq!(retry_after(&headers), Some(Duration::from_secs(120)));
        headers.insert(
            reqwest::header::RETRY_AFTER,
            httpdate::fmt_http_date(SystemTime::now() + Duration::from_secs(120))
                .parse()
                .unwrap(),
        );
        assert!(retry_after(&headers).unwrap() >= Duration::from_secs(118));
    }
}

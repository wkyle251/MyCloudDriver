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
        } else if let Some(crate::Error::Api { status, .. } | crate::Error::RetryAfter { status, .. }) = cause.downcast_ref::<crate::Error>() {
            Some(*status)
        } else { None };
        status.is_some_and(|status| matches!(status, 429 | 500..=599))
            || cause.downcast_ref::<std::io::Error>().is_some_and(|error| matches!(error.raw_os_error(), Some(23 | 24)))
    })
}

#[derive(Debug, thiserror::Error)]
#[error("Temporary download interruption")]
pub struct Interrupted;

#[derive(Debug, thiserror::Error)]
#[error("Download service returned HTTP {status}")]
pub struct HttpFailure {
    pub status: u16,
    pub retry_after: Option<Duration>,
}

pub fn retryable(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        if cause.is::<Interrupted>() {
            return true;
        }
        if let Some(crate::download_ranges::Error::Network(error)) = cause.downcast_ref::<crate::download_ranges::Error>() {
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
            return matches!(error.raw_os_error(), Some(23 | 24))
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
    fn individual_failures_do_not_throttle_healthy_files() {
        for status in [401, 403, 408] {
            let error = anyhow::Error::new(HttpFailure { status, retry_after: None }).context("retry this file");
            assert!(retryable(&error));
            assert!(!reduce_concurrency(&error));
        }
        for kind in [std::io::ErrorKind::ConnectionReset, std::io::ErrorKind::TimedOut] {
            let error = anyhow::Error::new(std::io::Error::from(kind));
            assert!(retryable(&error)); assert!(!reduce_concurrency(&error));
        }
        for status in [429, 500, 503] {
            let error = anyhow::Error::new(HttpFailure { status, retry_after: Some(Duration::from_secs(12)) }).context("retry this file");
            assert!(reduce_concurrency(&error)); assert_eq!(delay(&error), Some(Duration::from_secs(12)));
        }
        assert!(reduce_concurrency(&anyhow::Error::new(crate::Error::RetryAfter {
            status: 429, delay: Duration::from_secs(12),
        })));
        assert!(reduce_concurrency(&anyhow::Error::new(std::io::Error::from_raw_os_error(24))));
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

//! Content authorization is fixed for a transfer/scan, with per-file fallback
//! in Dynamic mode. Account metadata and mutations retain their own session.
use serde::{Deserialize, Serialize};

#[cfg(test)]
#[path = "content_mode_tests.rs"]
mod tests;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ContentMode {
    #[default]
    User,
    Guest,
    Dynamic,
}

impl ContentMode {
    pub fn tries_guest(self) -> bool {
        self != Self::User
    }

    /// A failed guest lookup only permits account fallback when explicitly
    /// selected. Never carry an unverified guest URL into the account route.
    pub(crate) fn guest_result<T>(self, result: crate::Result<T>) -> crate::Result<Option<T>> {
        match result {
            Ok(value) => Ok(Some(value)),
            Err(error) if self == Self::Dynamic && !guest_lookup_transient(&error) => Ok(None),
            Err(error) => Err(error),
        }
    }

    pub fn from_settings(mode: Option<&str>, legacy_guest: bool) -> crate::Result<Self> {
        match mode {
            Some("user") => Ok(Self::User),
            Some("guest") => Ok(Self::Guest),
            Some("dynamic") => Ok(Self::Dynamic),
            None => Ok(if legacy_guest {
                Self::Guest
            } else {
                Self::User
            }),
            Some(_) => Err(crate::Error::InvalidPath(
                "unknown content mode; choose user, guest or dynamic",
            )),
        }
    }
}

/// Temporary Guest metadata failures do not establish that account quota is
/// necessary. Preserve their error and cooldown for the normal retry queue.
pub(crate) fn guest_lookup_transient(error: &crate::Error) -> bool {
    match error {
        crate::Error::Http(error) => !error.is_builder(),
        crate::Error::Api { status, .. } | crate::Error::RetryAfter { status, .. } => {
            crate::download_policy::transient_status(*status)
        }
        _ => false,
    }
}

/// A rejected signed URL can be valid syntactically while the guest CDN no
/// longer permits access. Transport interruption and throttling keep their
/// existing retry policy; access failures, confirmed partial availability and
/// oversized originals request an account route.
pub fn content_access_denied(error: &anyhow::Error) -> bool {
    if error.is::<crate::download_policy::ContentUnavailable>()
        || error.is::<crate::download_policy::OriginalSizeMismatch>()
    {
        return true;
    }
    error.chain().any(|cause| {
        if cause.is::<crate::download_policy::ContentUnavailable>()
            || cause.is::<crate::download_policy::OriginalSizeMismatch>()
        {
            return true;
        }
        let failure = cause
            .downcast_ref::<crate::download_policy::HttpFailure>()
            .or_else(
                || match cause.downcast_ref::<crate::download_ranges::Error>() {
                    Some(crate::download_ranges::Error::Http(failure)) => Some(failure),
                    _ => None,
                },
            );
        failure.is_some_and(|failure| matches!(failure.status, 401 | 403 | 404))
    })
}

/// Only the original's content hash can authorize combining bytes from two
/// CDN routes with different HTTP validators. Modification dates cannot.
pub fn matching_content_revision(saved: Option<&str>, current: Option<&str>) -> bool {
    match (
        saved.and_then(|value| value.strip_prefix("gcid:")),
        current.and_then(|value| value.strip_prefix("gcid:")),
    ) {
        (Some(saved), Some(current)) => {
            !saved.trim().is_empty() && saved.trim().eq_ignore_ascii_case(current.trim())
        }
        _ => false,
    }
}

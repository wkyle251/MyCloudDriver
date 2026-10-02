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
    pub fn tries_guest(self) -> bool { self != Self::User }

    /// A failed guest lookup only permits account fallback when explicitly
    /// selected. Never carry an unverified guest URL into the account route.
    pub(crate) fn guest_result<T>(self, result: crate::Result<T>) -> crate::Result<Option<T>> {
        match result {
            Ok(value) => Ok(Some(value)),
            Err(_) if self == Self::Dynamic => Ok(None),
            Err(error) => Err(error),
        }
    }

    pub fn from_settings(mode: Option<&str>, legacy_guest: bool) -> crate::Result<Self> {
        match mode {
            Some("user") => Ok(Self::User),
            Some("guest") => Ok(Self::Guest),
            Some("dynamic") => Ok(Self::Dynamic),
            None => Ok(if legacy_guest { Self::Guest } else { Self::User }),
            Some(_) => Err(crate::Error::InvalidPath("unknown content mode; choose user, guest or dynamic")),
        }
    }
}

/// A rejected signed URL can be valid syntactically while the guest CDN no
/// longer permits access. Transport interruption and throttling keep their
/// existing retry policy; only access failures request an account route.
pub fn content_access_denied(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        let failure = cause.downcast_ref::<crate::download_policy::HttpFailure>()
            .or_else(|| match cause.downcast_ref::<crate::download_ranges::Error>() {
                Some(crate::download_ranges::Error::Http(failure)) => Some(failure),
                _ => None,
            });
        failure.is_some_and(|failure| matches!(failure.status, 401 | 403 | 404))
    })
}

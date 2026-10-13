//! Error type for the pikpak-api crate.

use thiserror::Error;

/// All errors that can be returned by a [`crate::Client`] operation.
#[derive(Error, Debug)]
pub enum Error {
    /// Preparation failed before a non-idempotent mutation could be accepted.
    /// Keep the underlying authentication/transport error for retry policy.
    #[error("Cloud operation was not sent: {0}")]
    MutationNotDispatched(#[source] Box<dyn std::error::Error + Send + Sync>),
    /// The service may have accepted a non-idempotent mutation. Do not submit
    /// it again until its durable intent has been reconciled.
    #[error("Cloud operation outcome is unknown: {0}. Refresh and reconcile it before submitting again.")]
    MutationUncertain(&'static str),
    /// Guest access never falls back to the account's download allowance.
    #[error("Guest Mode: {0}")]
    Guest(&'static str),
    /// Preserve the provider's cooldown when an outer operation retries.
    #[error("API error {status}: the provider requested a retry after {delay:?}")]
    RetryAfter {
        status: u16,
        delay: std::time::Duration,
    },
    /// Underlying HTTP transport failure (DNS, TLS, socket, etc.).
    #[error("HTTP request failed: {0}")]
    Http(#[from] reqwest::Error),

    /// The PikPak API returned a non-success HTTP status.
    #[error("API error {status}: {message}")]
    Api {
        /// HTTP status code.
        status: u16,
        /// Server-provided error message, or raw body if no message field.
        message: String,
    },

    /// Authentication or token refresh failed.
    #[error("authentication failed: {0}")]
    Auth(String),

    /// An operation/device challenge, not a rejected saved account session.
    #[error("PikPak requires additional verification for this request")]
    VerificationRequired(crate::VerificationChallenge),

    /// A credential was explicitly revoked/rejected, distinct from an
    /// expired access token, service outage, or OAuth client configuration.
    #[error("PikPak session rejected: {0}")]
    SessionRejected(&'static str),

    /// Response body did not match the expected JSON shape.
    #[error("failed to parse response: {0}")]
    Parse(#[from] serde_json::Error),

    /// Pagination did not reach a trustworthy end, so the collected folder
    /// entries may be incomplete and must not be used for destructive work.
    #[error("incomplete folder listing: {0}")]
    IncompleteListing(&'static str),

    /// Required configuration (refresh token, etc.) was not supplied.
    #[error("not configured: missing {0}")]
    NotConfigured(&'static str),

    /// A path segment could not be resolved.
    #[error("path not found: {path} (failed at segment `{segment}`)")]
    NotFound {
        /// The full path that was being resolved.
        path: String,
        /// The segment that could not be found.
        segment: String,
    },

    /// The user access token has expired and automatic refresh is not
    /// possible (no refresh token, or refresh also rejected).
    #[error("access token expired and could not be refreshed")]
    TokenExpired,

    /// A supplied path was empty or otherwise malformed.
    #[error("invalid path: {0}")]
    InvalidPath(&'static str),

    /// Content metadata supplied no absolute HTTP(S) original URL. This is
    /// independent of the account session and must never reach HTTP builders.
    #[error("PikPak did not provide a usable original download URL. Refresh the file and try again.")]
    InvalidDownloadUrl,

    /// A URL did not identify a PikPak public share.
    #[error("invalid PikPak share link: {0}")]
    InvalidShareLink(String),

    /// A public share is unavailable, protected by a passcode, or otherwise
    /// rejected independently of the signed-in account session.
    #[error("PikPak shared link unavailable: {0}")]
    Share(String),

    /// Url construction error.
    #[error("url error: {0}")]
    Url(#[from] url::ParseError),
}

/// Result alias with [`Error`] as the error type.
pub type Result<T, E = Error> = std::result::Result<T, E>;

impl Error {
    /// PikPak's typed answer for an item that is in its recycle bin (HTTP 400, `error_code` 9). Item metadata can
    /// still be read for such a file, but no download link is issued, so it is not a failure of the transfer.
    /// Any other 400 is something else and does not match.
    pub fn is_file_in_recycle_bin(&self) -> bool {
        match self {
            Self::Api { status: 400, message } => serde_json::from_str::<serde_json::Value>(message)
                .is_ok_and(|value| value["error"] == "file_in_recycle_bin" && value["error_code"] == 9),
            _ => false,
        }
    }

    /// A definitive rejection or failure before contacting the mutation
    /// endpoint can release a recorded intent. Transport/body/5xx ambiguity
    /// cannot.
    pub fn mutation_was_rejected(&self) -> bool {
        match self {
            Self::MutationNotDispatched(_) => true,
            Self::Api { status, .. } => (400..500).contains(status) && *status != 408,
            Self::RetryAfter { status, .. } => *status == 429,
            Self::Http(error) => error.is_connect(),
            Self::Auth(_)
            | Self::VerificationRequired(_)
            | Self::SessionRejected(_)
            | Self::TokenExpired
            | Self::NotConfigured(_)
            | Self::InvalidPath(_) => true,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Error;

    fn api(status: u16, message: &str) -> Error {
        Error::Api { status, message: message.to_owned() }
    }

    #[test]
    fn only_the_typed_recycle_bin_answer_is_recognised() {
        let real = r#"{"error":"file_in_recycle_bin", "error_code":9, "error_url":"", "error_description":"File or folder is already in recycler", "details":[]}"#;
        assert!(api(400, real).is_file_in_recycle_bin());
        // A different code, status, error name or a body that is not JSON is some other failure.
        assert!(!api(400, r#"{"error":"file_in_recycle_bin","error_code":99}"#).is_file_in_recycle_bin());
        assert!(!api(404, real).is_file_in_recycle_bin());
        assert!(!api(400, r#"{"error":"file_not_found","error_code":5}"#).is_file_in_recycle_bin());
        assert!(!api(400, "file_in_recycle_bin").is_file_in_recycle_bin());
        assert!(!Error::TokenExpired.is_file_in_recycle_bin());
    }
}

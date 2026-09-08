//! Error type for the pikpak-api crate.

use thiserror::Error;

/// All errors that can be returned by a [`crate::Client`] operation.
#[derive(Error, Debug)]
pub enum Error {
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

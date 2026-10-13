//! Rust crate for PikPak cloud storage.

#![forbid(unsafe_code)]

pub mod auth;
pub mod captcha;
pub mod client;
pub mod content_mode;
pub mod download_connections;
pub mod download_network;
pub mod download_policy;
pub mod download_ranges;
mod download_share;
pub mod download_trials;
#[doc(hidden)]
pub mod download_waits;
pub mod duplicate_cache;
pub mod error;
pub mod file_undo;
mod guest;
#[cfg(test)]
mod guest_fixture;
pub mod management;
pub mod request_verification;
#[cfg(test)]
mod request_verification_tests;
#[cfg(test)]
mod personal_access_tests;
pub mod search;
pub mod share;
pub mod share_save_duplicates;
pub mod similarity;
pub mod torrent_relay;
pub mod transfer_quota;
pub mod types;
pub mod upload;
pub mod upload_checkpoint;

pub use client::{
    Client, ClientBuilder, DownloadInfo, OssUploadParams, PreviewInfo, PreviewSource,
    ShareRestoreResult, UploadTask,
};
pub use content_mode::ContentMode;
pub use error::{Error, Result};
pub use request_verification::VerificationChallenge;
pub use share::{ParsedShareLink, ShareBrowsePage, ShareClient};
pub use transfer_quota::{QuotaDetails, TransferQuota};
pub use types::{FileInfo, FileKind, FilePage, Quota};

#[cfg(test)]
mod mutation_safety_tests;

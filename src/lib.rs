//! Rust crate for PikPak cloud storage.

#![forbid(unsafe_code)]

pub mod auth;
pub mod captcha;
pub mod client;
pub mod content_mode;
pub mod download_connections;
pub mod download_trials;
pub mod download_policy;
pub mod download_ranges;
pub mod download_network;
pub mod error;
mod guest;
#[cfg(test)]
mod guest_fixture;
#[cfg(test)]
mod personal_access_tests;
pub mod file_undo;
pub mod management;
pub mod search;
pub mod share;
pub mod similarity;
pub mod types;
pub mod transfer_quota;
pub mod upload;
pub mod upload_checkpoint;
pub mod torrent_relay;

pub use client::{
    Client, ClientBuilder, DownloadInfo, OssUploadParams, PreviewInfo, PreviewSource,
    ShareRestoreResult, UploadTask,
};
pub use error::{Error, Result};
pub use content_mode::ContentMode;
pub use share::{ParsedShareLink, ShareBrowsePage, ShareClient};
pub use types::{FileInfo, FileKind, FilePage, Quota};
pub use transfer_quota::{QuotaDetails, TransferQuota};

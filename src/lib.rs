//! Rust crate for PikPak cloud storage.

#![forbid(unsafe_code)]

pub mod auth;
pub mod captcha;
pub mod client;
pub mod error;
pub mod file_undo;
pub mod search;
pub mod share;
pub mod types;
pub mod upload;
pub mod upload_checkpoint;

pub use client::{
    Client, ClientBuilder, DownloadInfo, OssUploadParams, PreviewInfo, PreviewSource,
    ShareRestoreResult, UploadTask,
};
pub use error::{Error, Result};
pub use share::{ParsedShareLink, ShareBrowsePage, ShareClient};
pub use types::{FileInfo, FileKind, FilePage, Quota};

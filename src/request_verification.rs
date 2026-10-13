//! An interactive shield challenge is separate from an OAuth sign-in failure.
//! The UI returns short-lived, action/device-bound proof through a private file.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct VerificationChallenge {
    pub url: String,
    pub client_id: String,
    pub device_id: String,
    pub action: String,
    pub expires_at: u64,
}

impl VerificationChallenge {
    pub(crate) fn new(url: &str, client_id: &str, device_id: &str, action: &str) -> crate::Result<Self> {
        let parsed = url::Url::parse(url)?;
        let host = parsed.host_str().unwrap_or_default();
        if parsed.scheme() != "https" || !parsed.username().is_empty() || parsed.password().is_some()
            || parsed.port_or_known_default() != Some(443)
            || !(host == "mypikpak.com" || host.ends_with(".mypikpak.com"))
            || url.len() > 32_768
        {
            return Err(crate::Error::Auth("PikPak returned an unsupported verification address".into()));
        }
        Ok(Self { url: url.into(), client_id: client_id.into(), device_id: device_id.into(),
            action: action.into(), expires_at: epoch_seconds() + 15 * 60 })
    }
}

#[derive(Deserialize)]
struct VerifiedToken {
    client_id: String,
    device_id: String,
    action: String,
    captcha_token: String,
    expires_at: f64,
}

#[derive(Deserialize)]
struct VerifiedTokens {
    version: u32,
    tokens: Vec<VerifiedToken>,
}

pub(crate) fn epoch_seconds() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

/// Never use proof from another action/device/client, or a token the API already
/// rejected. Each helper reads this after an interactive challenge completes.
pub(crate) fn verified_token(path: Option<&Path>, client: &str, device: &str, action: &str,
    rejected: Option<&str>) -> Option<String> {
    let path = path?;
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 262_144 { return None; }
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 { return None; }
    }
    let bytes = std::fs::read(path).ok()?;
    let stored: VerifiedTokens = serde_json::from_slice(&bytes).ok()?;
    if stored.version != 1 || stored.tokens.len() > 64 { return None; }
    let now = epoch_seconds();
    stored.tokens.into_iter().rev().find(|token| token.client_id == client && token.device_id == device
        && token.action == action && token.expires_at > (now + 5) as f64 && token.expires_at <= (now + 1800) as f64
        && !token.captcha_token.is_empty() && token.captcha_token.len() <= 16_384
        && !token.captcha_token.chars().any(char::is_whitespace)
        && rejected != Some(token.captcha_token.as_str())).map(|token| token.captcha_token)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn proof_is_private_current_and_bound_to_the_request() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("proof.json");
        let write = |expires: u64| {
            std::fs::write(&path, serde_json::to_vec(&serde_json::json!({"version":1,"tokens":[{
                "client_id":"generated-client", "device_id":"generated-device", "action":"GET:/drive/v1/files",
                "captcha_token":"generated-proof", "expires_at":expires
            }]})).unwrap()).unwrap();
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            }
        };
        let read = |client, device, action, rejected| verified_token(Some(&path), client, device, action, rejected);
        write(epoch_seconds() + 600);
        assert_eq!(read("generated-client", "generated-device", "GET:/drive/v1/files", None).as_deref(), Some("generated-proof"));
        assert!(read("other", "generated-device", "GET:/drive/v1/files", None).is_none());
        assert!(read("generated-client", "other", "GET:/drive/v1/files", None).is_none());
        assert!(read("generated-client", "generated-device", "POST:/drive/v1/files", None).is_none());
        assert!(read("generated-client", "generated-device", "GET:/drive/v1/files", Some("generated-proof")).is_none());
        write(epoch_seconds() - 1);
        assert!(read("generated-client", "generated-device", "GET:/drive/v1/files", None).is_none());
        write(epoch_seconds() + 3600);
        assert!(read("generated-client", "generated-device", "GET:/drive/v1/files", None).is_none());
        #[cfg(unix)] {
            use std::os::unix::fs::{symlink, PermissionsExt};
            write(epoch_seconds() + 600);
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(read("generated-client", "generated-device", "GET:/drive/v1/files", None).is_none());
            let link = dir.path().join("link.json"); symlink(&path, &link).unwrap();
            assert!(verified_token(Some(&link), "generated-client", "generated-device", "GET:/drive/v1/files", None).is_none());
        }
    }

    #[test]
    fn challenge_only_opens_the_provider_and_does_not_leak_in_error_display() {
        for url in ["http://user.mypikpak.com/verify", "https://mypikpak.com.evil.test/", "https://user:pass@mypikpak.com/", "https://mypikpak.com:8443/"] {
            assert!(VerificationChallenge::new(url, "client", "device", "action").is_err());
        }
        let challenge = VerificationChallenge::new("https://user.mypikpak.com/verify?captcha_token=generated-secret", "client", "device", "action").unwrap();
        let message = crate::Error::VerificationRequired(challenge).to_string();
        assert!(message.contains("verification")); assert!(!message.contains("generated-secret"));
    }
}

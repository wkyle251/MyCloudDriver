//! Monthly traffic counters returned by PikPak's account endpoint.

use serde::Serialize;
use serde_json::Value;

use crate::types::Quota;

#[derive(Debug, Clone, Copy, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferQuota {
    pub cloud_download: Option<Quota>,
    pub downstream: Option<Quota>,
    pub upload: Option<Quota>,
    pub daily_downstream: Option<Quota>,
    pub connected_apps: Option<ConnectedAppsQuota>,
}

/// Connected Apps have their own server counters. They are shared by all
/// connected apps, not an extra allowance or a per-token quota.
#[derive(Debug, Clone, Copy, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectedAppsQuota {
    pub cloud_download: Option<Quota>,
    pub downstream: Option<Quota>,
    pub upload: Option<Quota>,
    pub daily_downstream: Option<Quota>,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct QuotaDetails {
    #[serde(flatten)]
    pub storage: Quota,
    pub transfer: TransferQuota,
}

impl TransferQuota {
    pub(crate) fn from_quantity(body: &Value) -> Self {
        // `base` is the basic monthly allowance; `transfer` is the aggregate
        // additional allowance. `apps_summary` is a subset of this usage and
        // must not be added again. Package history in `data` is not a counter.
        let combined = |key: &str| {
            let base = read_quota(&body["base"][key])?;
            let extra = read_quota(&body["transfer"][key])?;
            Some(Quota {
                total: base.total.checked_add(extra.total)?,
                used: base.used.checked_add(extra.used)?,
            })
        };
        Self {
            cloud_download: combined("offline"),
            downstream: combined("download"),
            upload: combined("upload"),
            daily_downstream: read_daily_quota(&body["base"]["download_daily"]),
            connected_apps: body
                .get("apps_summary")
                .filter(|value| value.is_object())
                .map(|apps| ConnectedAppsQuota {
                    cloud_download: read_quota(&apps["offline"]),
                    downstream: read_quota(&apps["download"]),
                    upload: read_quota(&apps["upload"]),
                    daily_downstream: read_daily_quota(&apps["download_daily"]),
                }),
        }
    }
}

fn read_daily_quota(value: &Value) -> Option<Quota> {
    // PikPak returns zero allowance for premium accounts with no daily cap.
    read_quota(value).filter(|quota| quota.total > 0)
}

fn read_quota(value: &Value) -> Option<Quota> {
    fn bytes(value: &Value) -> Option<u64> {
        match value {
            Value::String(number) => number.parse().ok(),
            Value::Number(number) => number.as_u64(),
            _ => None,
        }
    }
    // Missing/invalid counters stay unknown. Never present them as zero use.
    Some(Quota {
        total: bytes(&value["total_assets"])?,
        used: bytes(&value["assets"])?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn monthly_counters_preserve_overages_and_include_additional_quota_once() {
        let quotas = TransferQuota::from_quantity(&json!({
            "base": {
                "offline": {"total_assets": "43980465111040", "assets": "152718301266"},
                "download": {"total_assets": 4398046511104_u64, "assets": "4442026976215"},
                "upload": {"total_assets": "1099511627776", "assets": 0}
            },
            "transfer": {
                "offline": {"total_assets": 0, "assets": 0},
                "download": {"total_assets": 0, "assets": 0},
                "upload": {"total_assets": 100, "assets": 12, "size": 500}
            },
            "apps_summary": {"download": {"total_assets": 1099511627776_u64, "assets": 1000}},
            "data": [{"assets": "50000"}], "has_more": true
        }));
        assert_eq!(quotas.cloud_download.unwrap().total, 43980465111040);
        let downstream = quotas.downstream.unwrap();
        assert!(downstream.used > downstream.total);
        assert_eq!(downstream.free(), 0);
        assert_eq!(quotas.upload.unwrap().used, 12);
        assert_eq!(quotas.upload.unwrap().total, 1099511627876);
        assert_eq!(
            serde_json::to_value(quotas).unwrap()["cloudDownload"]["total"],
            43980465111040_u64
        );
    }

    #[test]
    fn missing_and_invalid_counters_are_unknown_independently() {
        for unknown in [
            Value::Null,
            json!({}),
            json!({"cloud_download": {"limit": "5", "usage": "1"}}),
        ] {
            let quotas = TransferQuota::from_quantity(&unknown);
            assert!(
                quotas.cloud_download.is_none()
                    && quotas.downstream.is_none()
                    && quotas.upload.is_none()
            );
        }
        for invalid in [
            json!(null),
            json!(-1),
            json!(1.5),
            json!(""),
            json!("18446744073709551616"),
        ] {
            let quotas = TransferQuota::from_quantity(&json!({
                "base": {
                    "download": {"total_assets": invalid, "assets": "0"},
                    "upload": {"total_assets": "100", "assets": "12"}
                },
                "transfer": {"upload": {"total_assets": 0, "assets": 0}}
            }));
            assert!(quotas.downstream.is_none());
            assert_eq!(quotas.upload.unwrap().used, 12);
        }
        assert!(TransferQuota::from_quantity(&json!({
            "base": {"download": {"total_assets": "100"}},
            "transfer": {"download": {"total_assets": 0, "assets": 0}}
        }))
        .downstream
        .is_none());
        assert!(TransferQuota::from_quantity(&json!({
            "base": {"download": {"total_assets": u64::MAX, "assets": 0}},
            "transfer": {"download": {"total_assets": 1, "assets": 0}}
        }))
        .downstream
        .is_none());
    }

    #[tokio::test]
    async fn transfer_quota_endpoint_refreshes_auth_and_keeps_server_totals() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for index in 0..4 {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let mut request = String::new();
                let mut buffer = [0_u8; 4096];
                while !request.contains("\r\n\r\n") {
                    let count = socket.read(&mut buffer).unwrap();
                    assert!(count > 0);
                    request.push_str(&String::from_utf8_lossy(&buffer[..count]));
                }
                let (status, body) = if index % 2 == 0 {
                    assert!(request.starts_with("POST /v1/auth/token?client_id="));
                    (
                        "200 OK",
                        r#"{"access_token":"fixture-access","refresh_token":"fixture-next","expires_in":3600,"sub":"quota-user"}"#,
                    )
                } else {
                    assert!(request.starts_with("GET /vip/v1/quantity/list?type=transfer "));
                    assert!(request
                        .to_lowercase()
                        .contains("authorization: bearer fixture-access"));
                    assert!(request
                        .to_lowercase()
                        .contains("x-device-id: fixture-device"));
                    if index == 1 {
                        ("401 Unauthorized", "{}")
                    } else {
                        (
                            "200 OK",
                            r#"{"base":{"download":{"total_assets":4000,"assets":4040}},"transfer":{"download":{"total_assets":1000,"assets":20}},"apps_summary":{"download":{"total_assets":1250,"assets":50}}}"#,
                        )
                    }
                };
                write!(socket, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
        });
        let client = crate::Client::builder()
            .refresh_token("fixture-refresh")
            .device_id("fixture-device")
            .auth_base_url(format!("http://{address}"))
            .api_base_url(format!("http://{address}"))
            .build()
            .unwrap();
        let result = client.transfer_quota().await.unwrap();
        assert_eq!(result.downstream.unwrap().total, 5000);
        assert_eq!(result.downstream.unwrap().used, 4060);
        let apps = result.connected_apps.unwrap().downstream.unwrap();
        assert_eq!(apps.total, 1250);
        assert_eq!(apps.used, 50);
        assert!(result.cloud_download.is_none() && result.upload.is_none());
        server.join().unwrap();
    }

    #[test]
    fn connected_apps_are_separate_server_counters_with_optional_daily_caps() {
        let quotas = TransferQuota::from_quantity(&json!({
            "base": {"download": {"total_assets": 4000, "assets": 4100},
                     "download_daily": {"total_assets": "20", "assets": "21"}},
            "transfer": {"download": {"total_assets": 200, "assets": 0}},
            "apps_summary": {
                "offline": {"total_assets": "10000", "assets": 0},
                "download": {"total_assets": 1033, "assets": "1080"},
                "upload": {"total_assets": -1, "assets": 0},
                "download_daily": {"total_assets": 5, "assets": 6}
            }
        }));
        let apps = quotas.connected_apps.unwrap();
        assert_eq!(apps.cloud_download.unwrap().used, 0);
        assert_eq!(
            apps.downstream.unwrap().total,
            1033,
            "Never estimate by multiplying account allowance"
        );
        assert_eq!(apps.downstream.unwrap().used, 1080);
        assert_eq!(apps.downstream.unwrap().free(), 0);
        assert!(apps.upload.is_none());
        assert_eq!(quotas.downstream.unwrap().total, 4200);
        assert_eq!(quotas.downstream.unwrap().used, 4100);
        assert_eq!(quotas.daily_downstream.unwrap().used, 21);
        assert_eq!(apps.daily_downstream.unwrap().total, 5);
        let missing = TransferQuota::from_quantity(&json!({"apps_summary": {}}));
        assert!(missing.connected_apps.unwrap().downstream.is_none());
        let premium = TransferQuota::from_quantity(&json!({
            "base": {"download_daily": {"total_assets": 0, "assets": 0}}
        }));
        assert!(premium.connected_apps.is_none() && premium.daily_downstream.is_none());
        let json = serde_json::to_value(quotas).unwrap();
        assert_eq!(json["connectedApps"]["downstream"]["total"], 1033);
        assert_eq!(json["dailyDownstream"]["total"], 20);
    }

    #[tokio::test]
    async fn quantity_read_recovers_from_server_failure_without_changing_pat() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for attempt in 0..3 {
                let (mut socket, _) = listener.accept().unwrap();
                socket.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
                let mut request = String::new();
                let mut buffer = [0_u8; 4096];
                while !request.contains("\r\n\r\n") {
                    let count = socket.read(&mut buffer).unwrap();
                    assert!(count > 0);
                    request.push_str(&String::from_utf8_lossy(&buffer[..count]));
                }
                assert!(request.starts_with("GET /vip/v1/quantity/list?type=transfer "));
                assert!(request.to_lowercase().contains("authorization: bearer fixture-pat"));
                if attempt == 0 { continue; } // A dropped response must be retried.
                let (status, body) = if attempt == 1 { ("503 Service Unavailable", "{}") } else {
                    ("200 OK", r#"{"base":{},"transfer":{},"apps_summary":{"download":{"total_assets":1000,"assets":4}}}"#)
                };
                write!(socket, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
        });
        let client = crate::Client::builder().personal_access_token("fixture-pat")
            .api_base_url(format!("http://{address}")).build().unwrap();
        let quotas = client.transfer_quota().await.unwrap();
        assert_eq!(quotas.connected_apps.unwrap().downstream.unwrap().used, 4);
        server.join().unwrap();
    }
}

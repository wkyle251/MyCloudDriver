# PikPak transfer quotas

The PikPak sidebar shows all three transfer counters below Storage for the
selected login method. **Monthly quota** opens a comparison of full account
and Connected Apps usage, limits and remaining bytes. Refresh
runs every 60 seconds while the view is visible, independently of downloads,
previews and Browser requests. Multiple windows of one workspace share a
monitor. A manual Refresh bypasses the interval, but never duplicates an active
request.

These are counters reported by PikPak for each scope, including activity from
other applications. They are not a measurement of MyCloudDriver alone, and
PikPak may update them with a delay. A failed refresh retains the previous
values with an error and their original timestamp. Missing or invalid counters
are shown as unavailable. Usage above a limit is retained; remaining allowance
stops at zero. Account changes clear the snapshot and discard late replies.

## What each allowance covers

| Counter | Transfer |
| --- | --- |
| Cloud Download Traffic | Internet → PikPak cloud, through cloud-download tasks |
| Downstream Traffic | PikPak → device: downloads, streaming, previews and originals read by similarity scans |
| Upload Traffic | Device → PikPak cloud |

Downloading an existing cloud file to a Mac always uses downstream traffic.
There is no quota selector for the same download. Parallel ranges change how
bytes are transferred, not the quota category. Repeated downloads and retries
can transfer additional data; reuse of already cached analysis avoids fetching
those originals again.

PikPak defines these categories and calendar-month resets in its
[official FAQ](https://mypikpak.com/en-US/faq#35). That FAQ also describes a
separate Connected Apps cap. The sidebar follows the selected login method:
Normal login shows the full account counters; Token login shows Connected Apps
counters. Quota details and Account Settings compare both scopes side by side.

## API and validation

`pikpak quota --json --with-transfer` adds `transfer` and `account_id` to the
existing storage output. The native monitor verifies the account identity and
uses a separate bounded helper with the existing desktop session/token lock.
Neither tokens nor signed file URLs are exposed by this response.

The client reads `/vip/v1/quantity/list?type=transfer`, the endpoint used by
PikPak's [official web client](https://mypikpak.com/drive/8005.1115f99c.js)
when checked on September 15, 2026. `base` and `transfer` contain the basic and
additional monthly allowances. `offline`, `download`, and `upload` map to the
three rows; `total_assets` is the limit and `assets` is consumed allowance.
The client combines the basic and additional aggregates, without adding
`apps_summary` or paginated package-history records again. The separate
`transfer.connectedApps` object reads the actual `apps_summary` counters; it
never estimates limits by multiplying the account allowance. Positive
`download_daily` limits are shown separately for accounts with daily caps.
Unknown Connected Apps counters stay unavailable, even when account counters
are known. Amounts use the
same binary byte formatting as the existing PikPak storage display.

The storage `/drive/v1/about` endpoint does not consistently provide monthly
traffic counters with the desktop session, so it is used only for storage.
The separate transfer endpoint was verified against the signed-in account
without downloading any file content. Tests cover authentication retry,
numeric/string counters, additional quota, overages, missing fields, overflow,
account isolation, stale data, cancellation and native helper cleanup.

## Login switch (16 September 2026)

The account card at the top of the left sidebar switches saved users and the
Normal login / Token login connection. Connecting one method preserves the
other. Reconnecting replaces only the same method for the same verified user.
Account selection is independent in each workspace; refreshing a credential
updates only workspaces that selected that exact connection.

The selector shows downstream allowance for both scopes; the sidebar shows
all three counters for the active method. Live quotas are cleared on a
connection change, including switches between methods for the same account.
Late responses from the previous connection cannot overwrite the new snapshot.

Read-only checks of the active PAT returned account limits of 40 / 4 / 1 TiB
and Connected Apps limits of 10 / 1 / 0.25 TiB. The UI uses PikPak's binary
formatting with TB/GB labels. Shared Connected Apps usage was zero at that check.
No download, upload, share creation or deletion was performed.

[Official Connected Apps quota FAQ](https://mypikpak.com/en-US/connect-apps-faq)
confirms the combined 25% cap, calendar-month reset, proportional extra quota,
and the additional daily cap on free accounts.

Quota reads reuse the storage connection and retry connection failures or server
errors twice, with short backoff. Authentication is refreshed at most once for
normal login; token login never falls back to normal login. Network recovery
does not change the configured proxy or download mode.

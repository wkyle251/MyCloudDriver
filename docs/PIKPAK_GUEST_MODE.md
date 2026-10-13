# PikPak download modes

PikPak **Transfers → Download** always uses **Dynamic Mode**, including downloads
queued from Browser, Bookmarks and Links. Downloads try Guest access first, keep
verified bytes already retrieved, and use your selected account connection for
remaining ranges when Guest cannot continue.
Account downloads with a missing, expired, deleted or otherwise unavailable
original share reuse an existing account-owned public link or create a public
link for the saved account copy. Activity Log reports the reason and recovery,
for example: “Share link unavailable: expired; creating a new share link to
download.” The new link must match the saved file ID, size and content hash
before downloading; temporary outages and throttling keep normal retries.
New links appear in My Shares without a passcode or expiration; you can revoke
them there. Previews and scans do not create shares.

Choose **Preview & Scan Mode** in the PikPak workspace sidebar to control
previews, Quick Look, Open and similarity-scan originals. The chooser explains
all three options and the sidebar always displays the selected choice. Apple
Photos, iCloud Drive and local files continue to use their own providers.

| Mode | Content access |
| --- | --- |
| **User Mode** | Always resolve content using the signed-in account. |
| **Guest Mode** | Only use guest public-share URLs; unavailable guest access returns an error. |
| **Dynamic Mode** | Try guest access for each file, then use the signed-in account when guest access is unavailable. |

Dynamic can fall back for missing/revoked/protected public shares, missing
original URLs, and originals that fail identity verification. Account fallback
always uses the saved account file ID, never a mismatched public original.
Downloads to disk and scan RAM also fall back if a guest body returns HTTP
401/403/404, a repeated partial response cannot advance the download, or a range
response confirms that the remaining bytes are unavailable. After a valid short
response, the next request first tries the remaining Guest range. When both routes report the
same original content hash and size, downloaded Guest bytes are retained and
User access requests the missing ranges. Different CDN ETags do not force a
restart when that content identity matches. Missing or changed hashes require
fresh validation or a restart before combining bytes. This decision belongs to
that file; it does not switch other files to User Mode. Connection interruptions
and throttling retain normal retries. Disk downloads refresh an expired Guest
URL once after HTTP 401/403 before requesting User access. Temporary Guest
metadata failures, including network timeouts and HTTP 429/5xx, stay on Guest
retry. Native previews continue to resolve a
single URL; this partial-download handoff applies to disk and scan RAM transfers.

User access uses the account's downstream quota. If the account route also
fails, the error is returned. Guest mode remains subject to PikPak's public-share
access rules and limits. Creating a link does not bypass those limits.
The live quota display continues to show the account's monthly counters.

## Persistence and when changes take effect

The preview and scan preference persists across launches and is shared by workspace windows.
On upgrade, the old Guest Mode toggle maps to Guest when enabled and User when
disabled. New installations default to User for previews and scans. Downloads
always use Dynamic, regardless of this preference.
Resetting the workspace layout does not reset the mode.

New and resumed GUI downloads use Dynamic Mode. Newly opened previews and
newly started or restarted scan helpers use the selected preview and scan mode.
Retained scan helpers keep their captured mode through pause/resume; restart
the scan to change its mode. Preview players, cached URLs, pending Open/Quick Look
work and similarity previews are cleared when the preference changes.

## Engine behavior

- `PIKPAK_CONTENT_MODE=user|guest|dynamic` selects the policy. Unknown values
  fail explicitly. If absent, the old `PIKPAK_GUEST_MODE=1` still selects Guest.
  The GUI sets Dynamic for download helpers and the selected preference for
  preview and scan helpers, removing the old variable from both environments.
- The live queue sends `content_mode` in its private inbox so requests added to
  an existing GUI download helper use Dynamic. Older `guest_mode` inboxes and
  inboxes without either value remain supported. New values take precedence.
- Account folder listings supply original-share mapping and content identity.
  Guest and Dynamic use parent-folder metadata to avoid quota-gated file-detail
  lookups before trying a public original. Fresh scan revalidation bypasses the
  short metadata cache. Guest successes do not request an account download URL.
- Guest requests use a separate anonymous device/captcha session without account
  bearer credentials. The fallback uses the selected account connection.
  Both honor the explicit app proxy.
- Original ID, nonempty content ID and size must match before accepting a guest
  original. Saved filenames and account IDs remain download/checkpoint identities.
- Signed URLs are refreshed on retry and never persisted. Existing range checks,
  partial-file ownership, cancellation, adaptive connections and RAM budgets remain
  active. Partial journals retain the content revision so a later route or
  restart can verify which original supplied the retained bytes.
- Created public share links and creation intents are stored in the private,
  account-specific metadata cache. Concurrent helpers and retries reuse the
  link. An interrupted or uncertain creation is reconciled against My Shares
  before use and is never blindly submitted again. Temporary sharing failures
  preserve provider cooldowns; unavailable sharing permits normal Dynamic User
  fallback. The anonymous route still verifies the content ID and size.
- Confirmed download shares bypass inventory and creation locks. Creation is
  coordinated per source identity across helpers. A complete My Shares scan
  reconciles all intents restored before that scan, rather than repeating the
  full catalog for each intent. A new uncertain POST requires a newer scan and
  is never posted again automatically.
- Cloud setup has a separate bounded allowance of 64 files. Receiving slots
  start at the content-request boundary; neither metadata waits nor finished
  bodies draining RAM consume them. Verification preparation is also bounded
  separately from actual disk byte admission. Its eight-task allowance also
  obtains metadata independently of ready-body lookahead, so those waits cannot
  reserve or strand an idle disk. The shared RAM cap and adaptive body/range limits
  continue to bound download resources.
- A metadata-ready check that obtains disk byte admission joins the current
  read cohort. It cannot reserve that allowance while waiting for an older
  cohort whose unfinished check needs the same allowance. Disk reads still
  wait for an active write turn, and pending RAM above 80% still requests the
  normal safe handover to writing.

## Verification

Loopback HTTP tests cover all three modes for account downloads, Links, previews
and scan URL resolution. Disk and RAM tests read synthetic bytes through real
transfers, including Dynamic fallback, guest URL expiry and resumed partials.
Partial-access fixtures verify Guest prefixes followed by only User suffixes,
different CDN validators, changed content hashes, strict Guest mode, and normal
retry handling for interrupted or throttled responses.
Tests verify strict Guest behavior, User bypassing guest, Dynamic preferring guest,
missing mappings, rejected identities, missing URLs, account quota failure and
separate authorization. Live-inbox tests check mode precedence and old queues.
Native tests cover migration, persistence, Dynamic download helper environments
and live inboxes, selected preview and scan environments, preview invalidation,
and captured running-scan settings.

`GuestModeUITestApp.swift` presents the production sidebar and chooser with
synthetic data and isolated preferences. Check all three selections, the active
checkmark, descriptions, keyboard interaction and persistence after relaunch.
Transfers → Download displays its fixed Dynamic policy independently of that
selection.

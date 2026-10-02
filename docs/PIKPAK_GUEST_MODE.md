# PikPak download modes

Choose **Download Mode** in the PikPak workspace sidebar. The chooser explains
all three options and the sidebar always displays the active choice. It applies
to downloads, previews, Quick Look, Open, and similarity-scan originals in PikPak.
Apple Photos, iCloud Drive and local files continue to use their own providers.

| Mode | Content access |
| --- | --- |
| **User Mode** | Always resolve content using the signed-in account. |
| **Guest Mode** | Only use guest public-share URLs; unavailable guest access returns an error. |
| **Dynamic Mode** | Try guest access for each file, then use the signed-in account if guest resolution fails. |

Dynamic can fall back for missing/revoked/protected public shares, missing
original URLs, and originals that fail identity verification. Account fallback
always uses the saved account file ID, never a mismatched public original.
Downloads to disk and scan RAM also fall back if a guest body returns HTTP
401/403/404. This decision belongs to that file; it does not switch other files
to User Mode. Connection interruptions and throttling retain normal retries.

User access uses the account's downstream quota. If the account route also
fails, the error is returned. Guest mode remains subject to PikPak's public-share
access rules and limits. The app does not create public shares automatically.
The live quota display continues to show the account's monthly counters.

## Persistence and when changes take effect

The preference persists across launches and is shared by workspace windows.
On upgrade, the old Guest Mode toggle maps to Guest when enabled and User when
disabled. New installations default to User. Dynamic is an explicit choice.
Resetting the workspace layout does not reset the mode.

New/retried download requests, newly opened previews, and newly started or
restarted scan helpers use the selected mode. Running download selections and
retained scan helpers keep their captured mode through pause/resume. Restart
that work to change modes. Preview players, cached URLs, pending Open/Quick Look
work and similarity previews are cleared when the preference changes.

## Engine behavior

- `PIKPAK_CONTENT_MODE=user|guest|dynamic` selects the policy. Unknown values
  fail explicitly. If absent, the old `PIKPAK_GUEST_MODE=1` still selects Guest.
  The GUI sets the new value and removes the old variable from helper environments.
- The live queue sends `content_mode` in its private inbox so requests added to
  an existing helper use the current preference. Older `guest_mode` inboxes and
  inboxes without either value remain supported. New values take precedence.
- Account folder listings supply original-share mapping and content identity.
  Guest and Dynamic use parent-folder metadata to avoid quota-gated file-detail
  lookups before trying a public original. Fresh scan revalidation bypasses the
  short metadata cache. Guest successes do not request an account download URL.
- Guest requests use a separate anonymous device/captcha session without account
  bearer credentials. The fallback uses the independent desktop account session.
  Both honor the explicit app proxy.
- Original ID, nonempty content ID and size must match before accepting a guest
  original. Saved filenames and account IDs remain download/checkpoint identities.
- Signed URLs are refreshed on retry and never persisted. Existing range checks,
  partial-file ownership, cancellation, adaptive connections and RAM budgets remain
  active. RAM partials are released before switching from a denied guest body.

## Verification

Loopback HTTP tests cover all three modes for account downloads, Links, previews
and scan URL resolution. Disk and RAM tests read synthetic bytes through real
transfers, including Dynamic fallback, guest URL expiry and resumed partials.
Tests verify strict Guest behavior, User bypassing guest, Dynamic preferring guest,
missing mappings, rejected identities, missing URLs, account quota failure and
separate authorization. Live-inbox tests check mode precedence and old queues.
Native tests cover migration, persistence, every helper environment, preview
invalidation, live inbox encoding and captured running-helper settings.

`GuestModeUITestApp.swift` presents the production sidebar and chooser with
synthetic data and isolated preferences. Check all three selections, the active
checkmark, descriptions, keyboard interaction and persistence after relaunch.

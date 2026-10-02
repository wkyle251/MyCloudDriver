# Automatic recovery audit

Audited the application's operation families on 2026-09-26, including the Swift task owners, Rust request/transfer helpers, and native torrent engine. Recovery belongs to the task owner: a bounded request retry inside a helper must either return to an owner that retries or report a condition requiring user input.

`AutomaticRecovery` uses 5, 15, 30, 60, 120, then 300 seconds repeatedly. There is no attempt ceiling. Existing transfer engines retain their shorter backoff and provider cooldowns. Successful progress resets the appropriate delay. Retrying does not change configured concurrency or bypass storage, source-integrity, account, or destination checks.

| Operation | Recovery owner and behavior |
| --- | --- |
| PikPak downloads | Rust retries transient per-file requests and refreshes signed URLs. Swift retains unfinished requests and restarts interrupted helpers, including exits without a final error event and failures while launching. Full disks remain eligible for retry. Provider cooldowns are preserved. |
| PikPak uploads | Swift retries saved batches, including launch failures and unavailable source disks. Rust upload checkpoints reconcile completed cloud files before continuing. Source identity/size checks remain mandatory. |
| Saved transfer state | Failed writes retry using the current queue snapshot. Unreadable/corrupt saved queues are retained rather than overwritten with an empty queue. Whole-batch pauses, per-file pauses, and upload cancellations are saved. |
| Torrents and torrent-to-PikPak relay | Confirmed engine exits, interrupted metadata requests, engine errors, and unavailable buffers schedule recovery. Relay recovery reconciles cloud receipts and fences off the previous uploader first. A lost status reply leaves an unconfirmed live writer monitored. Resume continues to validate cached pieces and the original disk/buffer. |
| Torrent queue persistence | Failed writes retry while the app is open. Explicit Pause/Stop is saved separately from interruption; interrupted work can resume after relaunch. Legacy paused queues without intent stay held unless migration can establish that they were running. |
| Saved shared-link roots | Failed roots keep retrying at the capped delay. An unavailable account waits without generating repeated login prompts. |
| Cloud extraction and folder merge | Existing remaining-work/receipt reconciliation retries without the former six-attempt ceiling. Password requests still wait for a password. Cancel and removal clear scheduled retries. |
| Folder listings and file search | Foreground listings, expanded folders, and interrupted name-search helpers retry. Account/context changes, collapse, navigation, close, and explicit cancellation supersede old requests. Native-drive listings retry temporary provider/filesystem failures. |
| Folder measurements and duplicate discovery | Interrupted read-only helpers retry. Native duplicate discovery retries temporary filesystem interruptions; unsupported or corrupt inputs remain individual reported issues. |
| Empty-folder and `.DS_Store` cleanup | Interrupted scans repeat discovery in the originally requested scope. The scanner rechecks current files/folders; it does not replay an unconfirmed deletion blindly. Cancel ends recovery. |
| Similarity scans | Checkpointed interruptions keep auto-resuming beyond the former six-attempt limit. Drive/network interruptions remain retryable. Inventory entries are acknowledged only after their write succeeds, preventing a failed append from silently skipping an item. |
| Images, thumbnails, previews, and Open downloads | Temporary reads/materialization retry until the owning task is cancelled. Streaming cache requests no longer stop after three failures. Selecting another item or closing the preview cancels its work. Invalid data, missing decoders, and external application-launch errors remain actionable errors. |
| Native-drive transfers | Transfer retries cover network interruptions, provider cancellations that the user did not request, unavailable disks, disk space/quota, and access errors. Waiting jobs release their worker slot. Completed-item tracking avoids repeating successful items in the same run. |
| Account/traffic information | Foreground quota requests and temporary management reads retry. The traffic panel already polls every minute and retains the last snapshot on failure. Rejected credentials require sign-in; they are never silently substituted with another account. |

## Conditions requiring intervention

Automatic retry cannot supply a password, grant macOS access, replace corrupt input, install a missing decoder/helper, resolve a destination collision, or make a provider accept a permanently rejected link. These checks stay visible and are never bypassed. Storage-related waits continue automatically when the original resource becomes usable.

Cloud create/share/move/delete actions without a durable receipt or reconciliation contract are not blindly replayed after an ambiguous reply. Native-drive operation closures are not a durable relaunch journal: an application exit still requires reviewing/restarting those operations. Durable relaunch recovery covers PikPak transfers, torrents, and checkpointed similarity scans. Extending native relaunch recovery requires persisted operation descriptors and receipts, especially for Photos imports.

## Verification

Run `zsh scripts/test-automatic-recovery.sh` after building the app resources. It compiles one fixture executable and runs recovery, torrent, native transfer fairness, download, shared-link, transfer-control/persistence, preview, thumbnail, folder-expansion, and similarity suites. Test payloads are generated in temporary directories. It does not inspect the user's downloaded payloads.

Regressions cover an outage exceeding the backoff schedule, unexpected helper/provider exits, disk errors, retry cancellation, account isolation, explicit pauses across relaunch, receipt preservation, and safe torrent destination checks.

# PikPak management workspaces

Added in MyCloudDriver 2.2.41 (216).

## Cloud Downloads

Open **PikPak → Cloud Downloads → New Task**. Enter one HTTP, HTTPS or magnet
link and choose a destination folder. PikPak downloads the source into its cloud;
the task continues when MyCloudDriver closes. This uses cloud-download traffic.
Transfers to the Mac still use downstream traffic.

The workspace shows task status and progress, refreshes the newest page every
eight seconds while tasks are active, and supports retrying failed tasks.
Removing a task asks for confirmation and keeps any saved file. Load More shows
older tasks; automatic refresh pauses once more than one page is loaded.

### A source contains too many files

`task_sub_task_num_limit` is a definite rejection from PikPak. The new-task
dialog keeps the link and destination, explains the file-count limit, and offers
**Download to Mac**, **Edit Link**, **Copy Link** and **PikPak Help**. Creating the same rejected torrent
again is disabled, including links that change only its name or trackers. A
different source can be submitted immediately. Account changes clear the failure.

PikPak currently documents [7,000 files per torrent task](https://mypikpak.com/en-US/help-center/save_files/torrent_magnet/maximum_number)
and [no individual file selection before creation](https://mypikpak.com/en-US/help-center/save_files/torrent_magnet/selected_download)
(verified 17 September 2026). Use an independently available source containing
fewer files, or choose **Download to Mac** to select and download files locally
inside MyCloudDriver, then upload them if needed. The handoff preserves the
magnet and waits for **Load File List**; it does not start a download on its own.
See [Local torrents](LOCAL_TORRENTS.md). MyCloudDriver cannot split an existing
magnet into smaller cloud tasks.
The published limit is guidance; the server error determines rejection.

The helper's HTTP status and named service code are decoded separately. HTTP 416
or numeric `error_code: 8` alone does not trigger this explanation. Other definite
rejections show PikPak's readable reason. Transport failures, timeouts and 5xx
responses retain the uncertain-outcome warning and offer **Review Cloud
Downloads** before resubmitting. No failed mutation is automatically replayed.
Failed list entries carrying the same service code show recovery guidance in
place of a futile Retry button.

## My Shares

Use **My Shares → Create Link**, the Browser's link toolbar button, or **Create
Shared Link…** in a file/folder context menu. Choose up to 100 files/folders, a
title, an expiry (1, 7, 30 days or never), and optionally a generated passcode.
Creating a link requires an explicit submission. Copy includes the passcode when
needed. My Shares shows views/saves, lets you change expiry, and asks for
confirmation before revoking a link. Revocation keeps the original files.

**Links** continues to browse links received from others. **My Shares** manages
links owned by the current account.

## Trash

Trash lists deleted items across the account, with paged loading and selection
of up to 100 items per action. **Restore** checks that selected IDs are still in
Trash, then restores their original cloud IDs. **Delete Permanently** checks the
selection again; **Empty Trash** removes all current Trash contents. Both require
explicit confirmation and a PikPak sign-in connection.

PikPak Personal Access Tokens cannot grant permanent deletion. With a PAT,
permanent-delete/empty controls are disabled, Restore stays available, and a
nearby Account Settings link explains how to change the connection. The engine
also enforces this restriction; it never falls back to an old OAuth credential.

## Account details

**Settings → Accounts** shows account ID, current connection/status, token
expiry, reported permissions, account-wide storage and transfer counters, and
links to PikPak Account & Security. The existing replace-token, sign-in, switch
account and log-out controls remain available. Token claims are used only as
display metadata after the account service authenticates the credential. PikPak
still enforces permission checks on every action. Opaque tokens show unavailable
metadata; OAuth sessions show automatic renewal.

## Request and account isolation

- Management uses the selected account in User, Guest and Dynamic modes. Those
  modes control content fetching and never change management ownership.
- `pikpak manage --request-file <private JSON>` validates the expected account
  against `/v1/user/me` before each action. Native request/output/error files are
  temporary, owner-only, and removed when the helper finishes.
- Account/credential changes cancel old page readers and discard stale results.
  Same-window account changes wait for a management mutation to finish.
- Task/share creation has no automatic retry after a transport failure or 5xx.
  An uncertain result tells the user to refresh before submitting again.
- The helper emits whitelisted metadata; bearer tokens and signed content URLs
  are excluded. Repeated page tokens and mismatched account replies fail closed.

## API evidence (16 September 2026)

Primary sources:

- [Official CLI](https://mypikpak.com/en-US/cli), version 0.5.0: task add/list,
  share create/list/remove help and synthetic-credential request inspection.
- Installed official PikPak desktop renderer: cloud task retry/removal,
  `/share` POST/PATCH, `/share/list`, `/share:batchDelete`, Trash filters,
  `/files:batchUntrash`, `/files:batchDelete`, `/files/trash:empty`.
- [Official PAT permissions](https://mypikpak.com/en-US/help-center/connected_apps/personal_access_tokens/create_personal_access_token):
  permanent deletion is unavailable to personal tokens.
- [Connected Apps FAQ](https://mypikpak.com/en-US/connect-apps-faq): Connected Apps
  share 25% of monthly transfer allowances; usage also counts toward the account.

Read-only live requests with the user's already-saved token returned HTTP 200
for profile, tasks, owned shares and Trash. Its reported scopes included read,
write, manage, cloud_download, share and account. No live tasks or shares were
created, and no account files or Trash contents were changed during verification.
Mutations, including OAuth permanent deletion, use local HTTP/native fixtures.

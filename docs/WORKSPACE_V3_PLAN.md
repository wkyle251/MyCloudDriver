# MyCloudDriver workspace, transfers and similarity update

## Design

The app keeps one visual language across PikPak, iCloud Drive, Apple Photos and
Local Disk: the same blue accents, browser chrome, file tree, preview and status
footer. Opening any drive from All Drives always enters its Browser.

### Workspaces

File → New Window (Command-N) opens an independent window at All Drives in the
same app process. There is no window/session count limit and no Split mode.
Existing windows keep their position and size; new windows cascade nearby.
Each owns navigation, selection, preview, account selection and task state.
Settings remain shared. Commands act on the focused workspace. Closing one
window leaves the others intact. Different PikPak accounts use captured
credentials and isolated transfer persistence. Storage slots expand beyond the
legacy primary/secondary pair; closed slots can be reused with a fresh browser
and their unfinished transfer queue preserved.

Local Disk is a fourth drive card. It opens the user's home folder, supports
choosing another folder/volume, and uses the same native file provider operations
as iCloud, without iCloud download requirements. OS access restrictions remain
visible as actionable errors. Drive cards wrap into a readable grid in smaller
windows.

Settings → General adds Preview placement: Right (default) / Bottom. Both use
the existing media controls and full-width preview canvas; media height remains
adjustable. Reset Layout restores Right.

### Status and transfers

The footer is the entry point for background work. A Transfers action opens the
transfer manager; the sidebar no longer consumes a navigation item for it.
Every queued or active transfer exposes Pause/Resume and Cancel. Pausing retains
partial data. Cancelling stops its writer before removing its own partial file.
Completed files and unrelated files are never removed by cancellation.

Failures retry automatically with a bounded exponential delay until success,
pause or cancellation. Retrying shows the reason and next attempt. Transfers,
scans and navigation remain independent; cancelling one file does not stop
unrelated workers. Persistence records interruption and pause state.

### Similarity

A single source chooser offers PikPak, iCloud Drive, Apple Photos and Local Disk.
Scopes and results remain separate for each source. All supported content types
are analysed automatically; the content type buttons are removed. Dotfiles and
hidden folders remain excluded. Show in Folder on a result opens its original
drive's Browser and selects that file.

Scan Resources offers Automatic and Custom. Automatic derives conservative
defaults from available CPU and physical memory; GPU information is shown
honestly without claiming acceleration for the CPU encoding backend. Custom
provides integer workers, memory allowance, batch file count and batch input
bytes, with validation and restore defaults. Batch size is not a per-file size
limit. The chosen values are passed to the engine rather than being UI-only.

Closing the similarity window or dismissing its status activity clears its
session, selection, scope and results; active work is cancelled and late events
cannot repopulate the dismissed session. Reopening starts with a comfortable
default window size. Saved vectors and comparison files are independent of
ephemeral UI session state.

### Cache format

Store exact float32 bits as byte-shuffled binary alongside compact metadata,
compressed with Zstandard. A measured sample of the existing 5.43 MB JSON cache
compressed to approximately 1.02 MB, versus 1.42 MB for JSON plus Zstandard.
The container is versioned, integrity checked and bounded when decompressed.
Private atomic writes and merge locking protect concurrent sessions. Legacy
JSON remains readable and is migrated only after a successful compressed write.
Corrupt cache data causes re-encoding, never loss of scan results.

## Implementation sequence

1. Implement and test lossless cache migration and configurable engine limits.
2. Implement transfer control and retry state machines, partial-file cleanup,
   and the Status transfer manager.
3. Add Local Disk through the shared native provider and Browser entry routing.
4. Integrate the four-drive similarity chooser, resource controls, result reveal
   actions and explicit session reset lifecycle.
5. Add preview placement and independent workspace windows through File → New
   Window, without a count limit or automatic tiling.
6. Build, run focused regression tests and inspect the rendered UI with synthetic
   files/accounts. Verify commands target only the focused workspace, saved
   credentials never cross accounts, and simultaneous tasks remain independent.
7. Build and sign the app. Install only when doing so will not interrupt the
   user's active transfers or scans.

## Verification

- Exact float bit roundtrip, old-cache migration, corruption and concurrent merge.
- Resource validation and automatic defaults on small/large hardware profiles.
- Retry, pause, resume and cancel in active and queued download/upload states;
  cancellation removes only its partial data after the writer stops.
- Local provider browse/expand/rename/copy/move/trash/undo and scan scope.
- All-drive similarity routing and close/dismiss reset, including running scans.
- Two workspaces with shared/different accounts, independent state and commands.
- Preview placement, narrow windows, light/dark appearance and build/signature.

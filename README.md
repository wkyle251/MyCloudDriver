# MyCloudDriver

MyCloudDriver is the source repository for the **My PikPak for Mac** app.
It builds on [youming-ai/pikpak-downloader](https://github.com/youming-ai/pikpak-downloader)
and retains the original MIT license and attribution.

A lightweight native macOS transfer app for PikPak files and folders. It avoids
PikPak Desktop's large transfer-list renderer by keeping only a small, fixed
number of workers alive and by rendering large transfer collections with
native virtualized lists.

> This is an unofficial client built on PikPak's private API. PikPak can change
> that API without notice.

## What it does

- Three workspaces in a Finder-style left sidebar: **Browser**, **Transfers**,
  and **Links**, accessible with Control-Command-1 through
  Control-Command-3 or the native **Go** menu. Labels remain visible in the sidebar.
  The sidebar uses the app's blue accent in both light and dark appearance,
  including its auto-hide overlay. Enabled navigation and action buttons show
  a pointing hand. **Account** displays the username fetched from PikPak's
  account service; missing profile metadata does not prevent browsing.
  Browser and Links reuse cached sort order, row lists and item lookups when
  returning to an unchanged folder. Inactive shared links keep their prepared
  outlines, and loading feedback updates independently of the file view.
  Large switches highlight the requested tab immediately and
  show an **Opening Browser… / Opening Links…** overlay until the destination
  is presented. Small switches stay immediate. Another tab click supersedes
  the pending switch; file actions wait for the displayed workspace to be ready.
- Right-click a file in Browser or Links, in either List or Thumbnails, and
  choose **Open** for its default Mac app, or **Open With** for an installed app
  (including **Other…**). The complete original downloads independently of the
  preview pane. Opening another folder does not cancel it; the footer has a
  cancel control. Copies retain their filenames in the app's private
  `Opened Files` support directory and stay available after quitting. Reopening
  the same cloud revision during the session reuses that copy. Edits stay on
  this Mac and are not uploaded to PikPak automatically.
- **Settings…** opens a separate native window from the sidebar or the app menu
  (**Command-Comma**). The sidebar is visible by default. Optional auto-hide
  reserves an 8-point strip outside the file rows: hover there for 250 ms to
  reveal the sidebar, and move away to hide it. Pressed buttons and file drags
  suppress reveal; it overlays rather than reflows the workspace. **View → Show
  Sidebar** (Option-Command-S) also keeps it visible.
  **Account** in the sidebar opens **Settings → Accounts**, without adding a
  section to the browser. The matching grouped pane shows the current username,
  checked login status, **Sign In**, **Log Out**, **Add Account**, and **Switch**
  controls. Login status is checked with PikPak when needed and can be refreshed
  manually. Offline errors keep saved sign-ins; expired sessions prompt sign-in.
  Every saved account has its own desktop session, device identity and refresh
  lock. New logins and switches are verified before the previous account is
  replaced; cancellation leaves it intact. Signing in to the same PikPak account
  updates its saved entry. Logout removes that account's local credentials and
  keeps other saved accounts available. Active work must finish or stop before
  switching. Unfinished transfers are restored for their account without starting
  automatically; browser, previews and pending actions clear on account changes.
  **General → About** shows the running app's version and build number as
  selectable text, read directly from its bundle metadata.
  General settings include one persistent **32-worker** default for both upload
  and download (range 1–64), the default download folder, and preview visibility.
  **Workers per direction** accepts a typed whole number or the stepper arrows;
  the field rejects letters, decimal separators, and signs, and bounds committed
  values to 1–64.
  Worker changes apply to the next queued or resumed batch; an active transfer
  keeps its allocation. The Transfers worker pickers have been removed.
  **Resources** measures CPU deltas and resident memory every two seconds for
  this app and its own task processes. Rows show the task, its folder/file and
  available progress (including duplicate scans, cleanup, transfers, search
  indexing and cloud extraction), sorted by CPU usage. Each task includes its
  descendant helpers without double-counting; hover a row for full details and
  PIDs. Previews and other work inside the app share the app row. Sampling runs
  off the UI thread only while the panel is visible; stopped helpers disappear.
  CPU counters use the Mac's Mach timebase so Apple silicon reports correct
  percentages. CPU at 100% means one core, and memory may count shared pages in multiple
  processes. Remote/cloud resource use cannot be measured on this Mac.
- Browser's top action bar is replaced by a single bottom **path + selection +
  status** footer. Paths include a selected file's
  ancestors; folders remain clickable and support drop destinations. Native
  **View** provides **as List** (Command-1), **as Thumbnails** (Command-2), item
  size controls (Command-Plus/Minus/0), and **Hide/Show Preview** (Shift-Command-P).
  These commands affect the active Browser or Links workspace, with an
  independent display-mode preference for each. **Refresh** (Command-R) is in
  the main app menu. Upload, new folder, download queue, and Trash actions are
  in the **File** menu and appropriate item context menus. Links keeps its
  link input bar; the separate Shared Link action toolbar has been removed.
  Navigation, view controls and refresh remain in the native menus, while
  file rows and context menus provide save/download actions.
  Hovering the Links row icons immediately shows their purpose beside the
  button: remove the link from this app (keeping cloud files), save to My
  PikPak, or add the file/folder to the download queue.
  File lists use SwiftUI hover tracking for button cursors and collect drop
  target geometry only during a drag, avoiding continuous native cursor-view
  layout and target-coordinate updates while scrolling.
- **Command-F** opens a quick-search palette for the current visible files and
  expanded folders, including all expanded roots in Links. It searches locally
  without crawling collapsed or not-yet-loaded branches. In thumbnail mode it
  searches the displayed folder's loaded items. **Command-Shift-F** searches
  from the signed-in PikPak account root, including unopened folders and every
  page. The palette labels its scope and keeps the two indexes separate.
  Four read-only page requests scan all descendants and pagination; root matches
  appear incrementally, with full parent paths, Unicode/case-insensitive and
  abbreviated-name matching. Use Up/Down and Return, or click a result, to reveal
  and focus its row with its parents expanded. Other expanded branches remain
  open; native metadata and pagination are preserved. Nested results switch to
  list view when needed to display the ancestry. Escape/outside click closes the palette and stops only
  its scan. Stop Scan keeps the partial results; Scan Again refreshes them.
  The in-memory index is reused during the app session and cleared on sign-out
  or account replacement. Root search excludes Trash and unsaved shared links;
  current-item search includes the visible shared files, scoped to their link.
  Large match sets have a Show More control; partial failures remain visible
  with selectable, redacted diagnostic details. Indexing and matching run off
  the main thread and do not lock browsing or transfers.
- Download selections queued by separate clicks are combined into the next
  compatible concurrent batch instead of each consuming a separate serial
  run. Destination, share authorization, worker count, and proxy must match;
  overlapping local output trees stay in separate runs to avoid write races.
  Cached browser IDs avoid re-resolving each selected path, and each selection's
  local relative destination is captured before batching. Other batches keep
  their queue order. Items added during an active batch
  start automatically with the next batch; the active batch is not interrupted.
  An idle queue still requires Start Download. Uploads and Finder-to-Browser
  drops can run alongside downloads, using their own process and the same
  safely locked private app session. Each drop captures its destination before
  Finder supplies its file/folder URLs, then opens Transfers → Uploads.

- Uses a compact, native macOS interface with workspace navigation, storage,
  Settings, and account actions in the left sidebar. A single fixed-height
  footer combines the path, selection count, status and Activity Log control.
  Click the status to read or copy the complete message; long details wrap in
  a popover without shrinking the file list. Narrow windows use a compact
  status indicator, with an explicit red **Error** label for failures. Error
  details include a sanitized source, HTTP/API/system code, and service message
  as selectable text with **Copy Error**. File-opening progress and Cancel
  remain in the same footer. Account controls live in Settings. The same sidebar
  shows PikPak storage used, total capacity, remaining space, and a compact
  color-coded usage bar; use its Refresh button to update it.
- Browses PikPak folders in bounded pages of 200 entries, with back navigation
  and server-provided thumbnails for visible rows. Row selection keeps the
  current viewport stable, while entering a different folder starts at the top.
  Returning with Back or a parent breadcrumb restores the folder row that was
  opened, including any additional pages that had already been loaded.
  The Finder-style breadcrumb displays the complete clickable ancestry whenever
  it fits. At compact widths it becomes **… > parent > current**, always keeping
  the immediate parent visible; the ellipsis opens an indented menu of every
  ancestor, and those menu destinations use the same position restoration.
  Clicking unused canvas space clears every checked/active item and its preview
  in both the account Browser and the combined Links outline, matching Finder.
  A selected top-level Link row is separate from its active cached/API session,
  so clearing its blue highlight never disconnects or collapses that link.
  Opening a deeply nested row from the expandable outline reconstructs every
  cached parent in that path instead of skipping directly from the root to the
  leaf folder.
  Account outline rows use stable cloud-item identities rather than their
  changing flattened indexes. Their disclosure chevrons rotate from the same
  published expansion snapshot that inserts child rows, preventing an expanded
  folder from retaining a recycled sideways arrow.
- Previews images, audio, video, and plain-text files in the native app using short-lived PikPak
  links fetched only when requested. Video/audio previews provide AVPlayer the
  correct media type and browser identity, allow slow links time to start, and
  automatically fall back across available PikPak streams and the direct file
  when a source fails or stalls. For AVI files, a bounded header probe detects
  legacy codecs without downloading the video. If PikPak has no compatible
  transcode, the preview pane offers an owner-only temporary stream to IINA
  (when installed), keeping the signed URL out of command arguments and logs.
  The IINA streaming action is also available for any audio/video preview that
  AVPlayer cannot decode. Plain-text and common source/data files use a bounded
  native text viewer whose contents remain selectable, copyable, and searchable;
  files larger than 2 MB show their first 2 MB without loading the whole file
  into memory. A separate **Quick Look** action is available for every file type and downloads an
  owner-only temporary copy. The native macOS Quick Look panel opens immediately
  with a loading indicator, then displays the fetched file. Copies are removed
  automatically; it never writes the fallback into Downloads.
  Account and shared-link streams both carry PikPak's expected media origin and
  referrer headers. Native preview and Quick Look use the same persisted app
  proxy as transfers. Progressive AVPlayer streams are delivered by a
  proxy-aware byte-range loader, and Quick Look uses a dedicated ephemeral
  download session. Both retain normal macOS TLS negotiation and certificate
  validation; the app never accepts an untrusted certificate to hide `-1200`.
  Progressive previews now pass through an owner-only sparse temporary cache.
  The preview pane reports exact unique bytes retained against the stream's
  content length instead of treating AVPlayer's changing loaded-time ranges as
  cumulative progress. Separate seek ranges are merged without double-counting,
  backward seeks reuse cached bytes, and the current file's cache survives
  pause, seek, player rebuild, and deselection; it is removed when another file
  is previewed or the app quits. HLS fallbacks report only the combined timeline
  ranges AVPlayer currently makes available. The pane also reports playback,
  live byte-delta transfer rate, and the active playback source. Historical
  AVPlayer bitrate estimates are never presented as current traffic; the rate
  changes to **No network activity** shortly after bytes stop arriving. Pausing stops the
  playhead without suspending transfer: a low-priority sequential prefetcher
  continues filling the sparse cache independently of AVPlayer's immediate
  playback requests, and the buffer/byte indicators keep updating while paused.
  AVPlayer's automatic stall waiting remains enabled, so a temporary empty
  playback buffer enters a waiting state and resumes instead of silently
  converting the user's Play request into Pause. Playback intent also survives
  automatic source fallback while explicit Pause and system interruptions are
  still respected. It is resizable
  and can expand to use the complete browser workspace. The media canvas has a
  visible border whose right edge, bottom edge, or corner can be dragged for
  freeform resizing; the chosen dimensions persist between launches. The
  canvas stays horizontally centered in the preview pane, and its height has
  no app-imposed upper limit. The
  folder and preview panes keep usable minimum widths of 360 and 300 points.
  If the main window becomes narrower than both panes, the browser workspace
  scrolls horizontally instead of crushing either pane. The main app window
  itself still has no app-imposed minimum width or height. Hide Preview from
  View or Settings to give the file list the full workspace. Sidebar workspace
  names and storage stay available independently of the file pane width.
  Preview-link and AVPlayer failures appear in a dedicated section below the
  player, leaving the file thumbnail unobstructed. The section uses the same
  selectable, copyable diagnostic card, including the PikPak HTTP/API message or
  AVFoundation/CoreMedia code that is actually available; refresh tokens and
  signed stream URLs are redacted.
  Image previews keep one decoded bitmap visible while their full-image link
  resolves and downloads. The thumbnail is replaced only when the original is
  decoded, without a second placeholder/fade or a change in canvas padding.
  Reloading or a failed full-image request retains the last good image; a late
  thumbnail cannot overwrite a finished original, and changing files cancels
  the previous requests. Image decoding runs off the UI thread with a bounded
  pixel size and the same secure proxy policy as native media previews.
- Displays cloud files in switchable Finder-style List and Thumbnails views.
  List uses an expandable outline with disclosure arrows, nested indentation,
  and Name, Size, Kind, and Date Modified columns. Drag any header divider to
  resize that column; use the header's Columns menu or its context menu to hide
  Size, Kind, or Date Modified, and reset the layout in one click. Widths and
  visibility persist across launches. Column and media-preview resizers use a
  stable screen-space drag and save only on pointer-up, preventing moving-edge
  feedback, preference-write jitter, and mixed lazy-row layouts. An over-wide
  table scrolls with its
  header still aligned to every row. Folder children load lazily
  and stay cached while the branch is open. Right-click a folder and click
  **Expand Folder** to open it and its immediate subfolders (1 level).
  Hover over that menu item to choose **1–10 Levels** or **All Levels** in a
  native submenu, without a popup. **2 Levels** also opens the subfolders'
  subfolders. Menu icons use fixed-size templates independent of row text size
  and hover animations. Already-open branches and selection stay
  unchanged. Expansion uses cached listings, fetches every remaining page with
  at most four simultaneous read-only requests, and provides a **Cancel** bar.
  Cancelling keeps folders already opened; navigating to another workspace
  stops pending expansion so late results cannot affect a different link.
  The thumbnail context-menu action switches to List to show the hierarchy.
  Thumbnails uses a lazy icon grid for
  the current folder, with signed PikPak artwork when available and native
  file/folder fallbacks. When a folder contains more than the API's 200-item
  page, a fixed thumbnail footer shows the loaded count and a prominent
  **Load Next 200** control; it cannot be pushed offscreen by toolbar actions.
  Command-Plus and Command-Minus resize rows, text,
  tiles, and artwork in either view; Command-0 restores the default size. The
  selected view and item size persist between launches. Disclosure controls use
  a large hover-highlighted target, and clicks made while a preview or another
  branch request is finishing are queued instead of lost. Hovering any
  shortened file or folder name reveals its complete name in a native macOS
  tooltip; the same behavior is available in transfer stacks and duplicate
  results. In List view, clicking Name, Size, Kind, or Date Modified sorts every
  sibling level without breaking the folder outline; clicking the active column
  reverses the order. Folders remain grouped above files, and the selected sort
  persists between launches.
  Every row has a checkbox for additive multi-selection. Checking a folder
  selects its complete subtree, including children that have not been loaded.
  In Links, checkboxes and Command-click keep selections across expanded share
  URLs; Shift-click selects a range in the visible order. Right-click a selected
  file or folder and choose **Save N Items to My PikPak** to save the selection.
  Right-click an unselected item to save just that item. List and Thumbnails use
  the same selection, and the footer shows its total. Saves and downloads keep
  each link's authorization separate; saved/queued items and selected descendants
  already covered by a selected folder are not submitted twice.
  Selected files and folders can be dragged onto any visible folder in List or
  Thumbnails view to move them server-side, or onto a breadcrumb to move them
  back toward the drive root. Finder files/folders can be dropped onto the same
  folder rows, thumbnails, breadcrumbs, or the blank area (current folder) to
  copy-upload and switch to Transfers. Originals remain on the Mac. One shared
  drop receiver resolves both the operation and its single blue destination
  outline from the same viewport coordinates, including after scrolling,
  resizing columns, and zooming thumbnails. A destination banner shows the
  operation and cloud path (plus the item count for in-app moves); invalid targets show the reason instead
  of accidentally accepting into the root. Hovering a list folder for 0.8 seconds
  expands it so nested destinations can be reached without ending the drag.
  Dropping over a file means its actual parent folder, not the view's root.
  The drag image shows the selected-item count, and every row
  and tile remains draggable while uploads, duplicate scans, previews, or other
  requests are active. If the foreground engine is busy, the move is queued and
  starts automatically when it is safe. Downloads and read-only scans continue
  independently; uploads and conflicting folder changes finish before a queued
  move starts. Multi-selection moves as one batch, while
  drops onto the same parent, the selected folder itself, or one of its descendants are
  blocked before PikPak is contacted. Drag payloads are private to this app and
  contain only a random one-use token; cloud IDs, paths, and session credentials
  never enter the system pasteboard. Shared-link browsing remains read-only.
  Local file providers are gathered as one batch: an unreadable item fails the
  drop with a copyable error instead of silently uploading a partial selection.
  Selecting both a local folder and its child uploads that child only once.
  The accepted destination and account are captured before asynchronous Finder
  URL loading, so later navigation or account changes cannot misdirect a drop.
  Finder providers are requested only at release, while macOS grants access.
  Delayed destination layout keeps the native drop offer alive; release still
  requires a resolved, valid target. The footer immediately shows preparation
  with the file count, then Transfers opens when the upload starts. Missing
  providers or an unresolved destination report an error instead of failing silently.
  Two or more selected sibling folders can also be merged. Its sheet receives
  the complete folder snapshot atomically, provides both a populated **Keep as**
  menu and directly clickable destination rows, and never opens with an empty
  stale picker while the underlying selection is valid.
  Any account file or folder can be renamed from its right-click menu. The
  native dialog pre-fills the complete current name, accepts Return, cancels
  with Escape, keeps the item selected, and immediately updates and re-sorts
  every loaded outline occurrence after PikPak confirms the change.
  Dropping an account-browser selection into Finder lazily downloads it to that
  local destination using a native file representation; multiple selected roots
  arrive together inside one **PikPak Selection** folder. Conversely, local
  Finder files and complete folder trees can be dropped directly onto a visible
  PikPak folder (or the open folder workspace) to upload there and switch to
  Transfers automatically.
  Up/Down moves across every visible row, Left/Right collapses or expands
  folders, Return opens a selected folder, and double-click still opens folders
  or previews files.
- Extracts ZIP, RAR and 7z archives directly in PikPak. Right-click a supported
  account file and choose **Extract in PikPak**, or **Extract N Selected
  Archives** for a selection. The app reads and extracts every entry in the
  background, beside the original archive. The Browser stays open.
  Locked archives present a focused **Archive password** sheet. **Extract**
  submits the password and continues automatically; **Later** leaves that
  archive waiting in the footer without reserving a worker. Multiple password
  requests are presented one at a time, and an incorrect password can be retried.
  Passwords use private temporary requests and are cleared on completion/failure;
  they are never saved in history or logged.
  The footer's **Extractions** control opens a tall, single-column list with
  each archive's state, server-reported percentage, queued/waiting work, errors,
  retry controls and finished results. Before PikPak provides a percentage the
  indicator is indeterminate. **Show in Browser** opens the containing folder;
  **Clear Finished** removes history without deleting files.
  **Settings → General → Archives → Extractions at once** is the single,
  persistent integer limit (1–8, default 4). Running jobs retain their slots
  when the limit is lowered. PikPak controls server scheduling and quota.
  Extraction has its own background process and progress observation. It does
  not disable unrelated browsing, uploads, downloads, scans or file actions, or
  redraw a large file list on each progress update. Moving/renaming/deleting the
  active source archive or its ancestors waits until extraction finishes.
  Completion refreshes the destination while preserving expanded folders.
  There is no separate Extractions task page or password-recovery feature.
- Shows a selected file's size immediately. Folder sizes can be calculated on
  demand from either view, recursively, with a circular in-row loading state,
  reusable per-folder results, file/subfolder counts, and a Cancel control. A
  single parent scan also calculates and caches every descendant folder, so
  already visible children—and children opened later—show their sizes without
  another scan. Size recursion runs in a utility-priority background process,
  so users can change folders, expand the outline, switch between Browser and
  Links, select files, and load previews throughout the calculation. Completed
  results are saved in an owner-only, account-scoped
  local cache containing opaque IDs, parent relationships, direct item sizes,
  and aggregate counts, then restored
  on future launches without scanning the cloud again. Right-click any measured
  folder and choose **Recalculate Folder Size** to replace a stale result;
  this explicitly forces a full fresh scan. Confirmed Trash operations subtract
  known file/subtree sizes from their ancestors, moves update both parent chains,
  and new empty folders update counts without rescanning. Renames preserve sizes.
  Uploads, shared saves, extractions, and partially completed merges refresh only
  changed branches in the background, reusing unchanged cached subtrees. Upload
  updates and cache writes are coalesced. Complete Browser listings also reconcile
  direct changes; partial pages and stale in-flight responses cannot overwrite
  newer totals. The existing aggregate-only cache migrates without discarding
  saved sizes. Unknown sizes trigger a scoped refresh, never a guessed zero.
  External edits not yet seen in Browser may still require a manual rescan.
  File, folder, transfer, duplicate, and quota sizes use one
  consistent binary scale, avoiding misleading comparisons caused by mixing
  decimal file units with binary quota units. Folder scans count only completed,
  non-trashed PikPak objects—the same objects shown in Browser.
- The **File** menu provides **Check for Duplicates**, **Remove Empty Folders**,
  **Remove .DS_Store Files**, and **Merge Selected Folders**. Browser, Transfers,
  and Links are the three workspaces. The footer status popover shows operation
  progress, Cancel, completion summaries, errors, and Retry Remaining for folder
  merges. Results survive navigation and ordinary “Loaded items” updates.
  Choose **Review Results…** in status or **File → Review Duplicate Results…**
  to review duplicate groups in a large sheet. **File → Show Status** (⇧⌘I)
  opens progress from any workspace. Duplicate checking (⇧⌘D) has live file and
  folder counts; unknown recursive totals use an indeterminate progress bar.
  Server content identifiers produce exact-match groups; matching names and
  sizes are reported separately as possible matches when hashes are absent.
  Temporary PikPak request failures are retried without discarding earlier
  progress; an unavailable descendant folder is recorded and the scan continues
  with clearly marked partial results instead of failing the complete scan.
  Redundant exact copies are preselected while one copy per group is protected,
  and all selected files can be moved to PikPak Trash after one confirmation.
  Duplicate discovery runs in the background, so folder navigation, selection,
  and previews remain available while a scan is checking a large tree.
- Moves one or many selected files and complete folder trees to PikPak Trash
  only after a native destructive-action confirmation. Trashed items remain
  recoverable from an official PikPak client until Trash is emptied. Every
  app-owned confirmation accepts Return for its primary action and Escape for
  Cancel; the sign-in form keeps Return inside PikPak's page and Escape closes
  the sign-in sheet.
- Merges two or more selected sibling folders from their Browser context menu.
  A confirmation lets the user choose which folder name survives; children are
  moved server-side, and each source folder goes to recoverable PikPak Trash
  only after repeated fresh listings confirm that it is empty. PikPak's batch
  moves can settle asynchronously, so merge verification polls with bounded
  backoff and retries only unresolved children instead of failing immediately.
  A dedicated cancellable utility process reports live source, item, and
  verification progress in the footer status while Browser and Links remain responsive.
  Interrupted merges retain already moved children, keep every nonempty source,
  and can retry only the unfinished sources.
- Recursively finds and removes empty descendant folders after a complete,
  read-only safety scan. Every folder found empty is fully listed again immediately
  before its individual Trash request; a new file, remaining subfolder,
  incomplete listing, or unreadable branch blocks deletion. Empty folders are
  processed deepest-first, the chosen scan root is preserved, and removals go
  only to recoverable PikPak Trash. Empty-folder and `.DS_Store` maintenance run
  in a cancellable background process, so Browser and Links navigation, folder
  expansion, selection, and previews remain responsive throughout a large scan.
- Creates folders in the current account-browser location. Finder files and
  complete local folder trees can be dropped anywhere over the current Browser
  workspace to start the high-throughput uploader in that exact open cloud
  folder; the UI then switches to Transfers > Uploads automatically. A separate
  recursive cleanup finds only exact, regular `.DS_Store` files, rechecks their
  parent listings, and moves those files—never their folders—to PikPak Trash.
- Downloads one or many checked files/folder trees through a reviewable queue.
  Browser and Links download actions remain available while previews, scans,
  uploads, or another download are active. Download first adds each selected
  file or recursive folder root to Transfers, where it can be removed—or the
  waiting queue cleared—before **Start Download** is pressed. After that manual
  start, remaining batches continue in order. **Save to My PikPak** uses an
  independent per-link helper, so browsing, previewing, and disconnecting an
  unrelated link remain available throughout the server-side save.
- Adds multiple official `https://mypikpak.com/s/...` public share URLs to a dedicated
  **Links** tab. Each URL is a top-level expandable Link row in one Finder-style
  outline; its files and folders render directly underneath it. Link rows share
  the resizable Name, Size, Kind, and Date Modified columns, display their added
  date, calculate the complete shared-root size on demand, and place a compact,
  local-only **Disconnect** (×) button on the left beside the link icon in both
  list and thumbnail views. File/folder rows have two fixed-size buttons:
  **Save to My PikPak** (cloud arrow, or a disabled green check when saved)
  and **Download**. Full names remain in hover tooltips and accessibility labels;
  the action column no longer needs a long text label. Disconnect has its own red hover state;
  while it is hovered, the surrounding row hover highlight is suppressed so
  the pending action is visually unambiguous. Optional access codes are
  stored only in the app's owner-only local state file and passed to the bundled
  engine through owner-only temporary JSON files rather than process arguments.
  The Links workspace reuses the
  Finder-style outline expansion, back-position restoration, keyboard navigation, multi-selection,
  preview, recursive folder-size calculation, and the normal download progress
  stacks. Multiple link roots stay expanded at the same time, each rendering
  its own independently cached Finder workspace. Initial opens and retries also
  run in per-link helpers, so several slow links can contact PikPak concurrently;
  their row spinners remain independent and never place a blocking overlay over
  the outline or prevent switching back to Browser. The complete link list, active
  link, root and nested disclosure states, loaded pages, locations, selection,
  access state, load/error state, and saved-item markers survive a normal app
  relaunch. Links can be switched, retried, or removed locally without affecting
  cloud data.
  Shared folder-size cache keys include the local link UUID, because PikPak can
  return the same root folder ID for several URLs; consequently only the folder
  actually being measured shows a scanner or receives the resulting size.
  Additional folder-size requests remain available and enter an explicitly
  labelled per-folder queue, rather than disabling or changing every other link.
  It displays an inline opening result and can restore selected files
  or complete folder trees server-side into **Pack From Shared**. Share
  browsing and restore requests use the same coordinated, app-owned desktop
  session as Browser; they never read or refresh Safari's separate Web token.
  Upload, duplicate cleanup, empty-folder cleanup, and Trash remain absent.
- Shows live aggregate bytes, percentage, speed, ETA, and file counts. Logical
  completion bytes stay separate from bytes actually received this run, so
  resumed parts, already-present files, and HTTP retries do not inflate speed
  or corrupt the remaining-time estimate. Final progress is rebuilt from the
  engine's complete ordered event stream before the run is marked finished.
  Separate virtualized Downloading, Queue, and Completed stacks track every file in the
  current run without eagerly rendering thousands of rows. Queue metadata is
  sent to the UI in bounded batches. Downloads also own a utility-priority
  background process and coalesce progress events, leaving the independent
  Browser/Links request lane available throughout remote scanning and transfer.
  For large uploads, aggregate totals still
  cover the complete job while each stack renders only the next or latest 160
  rows, and chatty engine events are coalesced into short UI batches so the
  Browser and transfer controls remain responsive. The hash-heavy uploader runs
  at utility QoS so AppKit retains scheduling priority. Upload results separate successful files
  from failures: a dedicated red Failed stack appears below Completed and keeps
  each affected path, transferred-byte count, sanitized engine/API error code,
  selectable message, and Copy Error action visible for retry decisions.
  Transient uploads automatically retry the entire file up to three times after
  lower-level storage-request retries; exhausted failures retain their original
  local source and cloud parent for a one-click manual retry. Downloads use five
  bounded resume attempts and keep their own Failed stack. Each failed download
  retains its remote source and exact nested local destination, so its row can
  retry only that file while the other failures remain visible; **Retry All
  Failed** remains available for the complete set. Existing partials resume and
  already complete local files are skipped.
- Keeps all long-running work off the foreground browser channel: downloads,
  uploads, duplicate scans, empty-folder scans, `.DS_Store` scans, folder-size
  calculations, and cloud-extraction polling can continue while Browser and
  Links navigation, outline expansion, selection, and previews remain usable.
  Transfer and scan progress is delivered to SwiftUI in bounded batches, and
  CPU/network-heavy helpers run at utility priority so they do not starve the
  app's controls.
- Offers one **Workers per direction** setting, default 32, with persistent
  choices from 1–64 in Settings. Both directions use it, while the engine never
  starts more workers than there are files. Values above
  32 remain available for many-small-file workloads but may increase PikPak/CDN
  throttling and local disk pressure.
- Resumes `.part` files using HTTP Range requests.
- Saves unfinished download selections and upload batches privately per verified
  PikPak account. Queue edits and starts are written atomically, and a normal
  Quit flushes current state before stopping helpers. After reopening, downloads
  return to the removable queue with **Resume Downloads**; **Saved Uploads** has
  individual **Resume** and **Remove** controls. Nothing transfers automatically
  merely because the app was reopened. Upload and download workers remain
  independent, so resuming one does not block browsing or the other direction.
  Upload checkpoints retain the original scan, source fingerprints, GCIDs,
  created cloud-folder IDs, and completed files. They do not retain desktop
  tokens or temporary object-storage secrets. An interrupted upload file may
  restart from zero; already completed files are skipped, and cloud folders are
  reused. Missing/changed local sources or an ambiguous remote folder produce
  an error instead of silently uploading into a different location. Keep the
  original sources and download partials in place until the batch is complete.
- Retries transient network and server failures with bounded backoff.
- Preserves the remote folder structure.
- Skips an existing final file when its size matches PikPak.
- Uploads one or many local files or complete folder trees into a selectable
  PikPak destination, preserving nested and empty directories. Transfers has a
  **Choose…** destination workflow that opens the account Browser, accepts the
  current or selected folder, then returns directly to Uploads.
  Uploads use the shared Settings worker count (32 by default, adjustable
  from 1–64). The engine never starts more workers than there are
  files. Independent files are hashed and uploaded concurrently, while large individual files use up to four
  concurrent multipart streams within a shared concurrency envelope. The engine
  discovers a large tree once, de-duplicates overlapping Finder selections,
  skips symbolic links safely, and keeps only the configured number of active
  file tasks.
  The Transfers workspace shows local checking speed, live completed bytes,
  byte-weighted percentage, stable network-upload speed, remaining bytes/ETA,
  a compact two-line completed/instant/failed file summary,
  and separate Uploading, Queue, and Completed stacks. Instant and
  already-present bytes advance completion
  without inflating transfer speed. Uploads run independently from the cloud
  browser, and can be paused and continued without discarding the in-memory
  queue. Small files use a direct object upload; larger files use retryable
  multipart upload.
  PikPak's GCID content identifier is calculated locally, so content already in
  the service can complete as an instant upload without retransmitting bytes.
  Cancelling keeps files that already completed. A background Browser/quota
  refresh no longer blocks choosing a fresh source and starting the next upload.
- Stores the refresh token in an owner-only local file under Application
  Support. Builds older than 1.7.0 are migrated once and their legacy Keychain
  item is removed.
- Detects rejected or expired sessions and opens a temporary, app-specific
  PikPak sign-in window. After a successful sign-in, the official page grants
  a desktop-client authorization code. The app exchanges that code for its own
  desktop refresh token, discards the temporary Web session, saves the desktop
  token locally, and reloads the cloud browser.
- The GUI has no browser-token import path. It never reads Safari storage and
  never saves or refreshes the temporary Web token. Safari keeps its Web-client
  token chain while My PikPak for Mac rotates a separate desktop-client chain.
- Gives every engine process the same persistent device identity. Rotating
  refresh tokens are coordinated through an advisory lock and atomically
  published to the owner-only session file before another process authenticates.
  The token is never placed in process arguments, environment values, or logs.

## Build the app

Requirements: macOS 13 or newer, Swift 5/6, Rust/Cargo, and Python 3.9+ for build configuration.

OAuth client secrets are intentionally excluded from the repository. Before
building, copy `pikpak-client-credentials.example.json` to
`.local/pikpak-client-credentials.json`, fill in the two client secrets locally,
and restrict that file to its owner (`chmod 600`). Alternatively, set
`PIKPAK_WEB_CLIENT_SECRET` and `PIKPAK_DESKTOP_CLIENT_SECRET` in the build environment.
The build embeds these application credentials in ignored build artifacts.
For direct Cargo commands, use `python3 scripts/with-client-credentials.py cargo test --locked`
or supply the environment variables yourself.

Your refresh tokens, device identity, account records, saved shared links,
downloads, diagnostic logs, app bundles, and local tool settings must remain
outside Git. `.gitignore` covers local configuration and copies of runtime data;
the macOS app normally stores account data in your user Application Support
directory. `.env.example` and the JSON template contain placeholders only.

```bash
./scripts/build-app-icon.sh  # only needed after changing AppIcon.png
./scripts/build-app.sh
```

Keep previous installed versions as ZIP archives, not loose `.app` bundles.
macOS indexes loose backups under the same app identity and can launch an older
interface. After replacing the app in `~/Applications`, quit any backup copy
and run `python3 scripts/archive-app-backups.py`. It verifies every archived file,
retires only app bundles inside `dist/installed-backup-*` and `dist/update-backup-*`,
and registers the installed app as the launcher target. Rollback archives remain
in their original backup directories.

The app is created at:

```text
dist/My PikPak for Mac.app
```

The bundle is ad-hoc signed for local use. It contains both the SwiftUI app and
the release Rust engine; no Python, Node, or separate runtime is required.

## First use

1. Select **Sign In to PikPak**. Enter your credentials on PikPak's official
   page inside the temporary login window.
2. After PikPak signs in, the page authorizes PikPak's desktop client. The app
   saves only the resulting desktop refresh token and its stable device identity under
   `~/Library/Application Support/My PikPak for Mac/Accounts/<account>/` with owner-only
   permissions, closes the login window, and loads your files.
   The previous single-account session is migrated automatically.
3. Use **Cloud Browser** like Finder: switch between the expandable List and
   current-folder Thumbnails views from the toolbar. Command-Plus and
   Command-Minus change the item size in either view, and Command-0 resets it.
   Use each item checkbox to build a multi-selection without holding a modifier;
   a checked folder includes everything below it. Arrow keys navigate the
   visible items, Shift-Arrow selects a contiguous range, Command-click toggles
   items, and Command-Delete moves the selection to PikPak Trash after
   confirmation. Choose **Load Preview** for images, audio, video, or selectable
   plain text. Choose **Quick Look** on any file to open a private temporary copy
   with the appropriate macOS viewer. Select a
   folder and choose **Calculate** to total its contents without downloading it.
4. Choose **File → Check for Duplicates** to scan the current folder tree. Open
   the footer status and choose **Review Results…** to review the
   preselected exact copies, optionally select possible
   matches, then use **Move All Selected to Trash**. The app always keeps at
   least one copy in each group and asks for confirmation before deletion. You
   can keep navigating in **Browser** or **Links** during the scan; downloading, folder measurement,
   and Trash actions wait until the scan completes.
5. Check one or more files/folders and choose **File → Add Selected Items to Download Queue**
   (or the item's download/context-menu action). The app adds every
   selected tree to the queue and switches to **Transfers**. Review or remove
   waiting roots there, then press **Start Download**. Download sources are
   always chosen in **Browser** or **Links**; Transfers contains destination,
   progress, and queue controls. Worker limits now live in Settings.
6. To upload, either open the destination folder in **Browser** and choose
   **File → Upload Files or Folders…** or drop files from Finder, or open
   **Transfers → Uploads**, use **Destination → Choose…**,
   select a cloud folder (or use the folder currently open), and confirm it.
   Then select one or more local
   files, folders, or both. Both directions default to 32 workers; change this
   in Settings if needed. Very high values can increase disk pressure or
   service throttling. The app switches
   to **Transfers → Uploads** and displays folder creation, preparation, and
   network progress for every file. You can return to **Browser** while it runs;
   **Pause Upload** temporarily suspends the active queue and **Continue Upload**
   resumes it from the same in-memory transfer state.
   If you quit the app or cancel the run, reopen **Transfers → Uploads → Saved
   Uploads** and choose **Resume**. Completed files stay completed; an unfinished
   file may restart. **Remove** forgets only the saved batch, without deleting
   its local sources or cloud files. New uploads can be chosen independently of
   saved, stopped batches.
   If this network requires a local proxy, enter it in **Advanced → Proxy**
   (for example `http://127.0.0.1:10808`). The value is saved immediately and
   is shared by API requests, transfers, inline media, and Quick Look temporary
   downloads; the app never disables TLS certificate checks.
7. To browse a shared URL, open
   **Links**, paste an official PikPak `/s/` URL, optionally enter its access
   code, and choose **Open**. An inline message confirms success or explains
   the error. Browse and select it like the main Browser tab; previews and
   downloads work normally. Choose **Save to My PikPak** to restore the selected
   files or folders into **Pack From Shared** without downloading them first.
   Once every selected action root has been saved, that control becomes the
   disabled confirmation **Saved to My PikPak**.
   Destructive controls remain hidden.

The login browser uses a nonpersistent WebKit data store isolated from Safari.
It acts only as an authorization broker while the visible page is on
`mypikpak.com` (or one of its subdomains); its cookies and Web token are cleared
after the desktop authorization finishes. Upgrading from the older Web-token
design requires one app sign-in. Version-2, copied, Keychain, and otherwise
untrusted GUI tokens are discarded rather than imported into the independent
desktop refresh-token chain.

Automatic download concurrency is the recommended default. Quitting stops
network work but retains transfer state. After reopening and verifying the same
account, choose **Resume Downloads** for the restored queue. Existing `.part`
files resume by byte range and completed local files are skipped. You can also
return stopped/failed selections to the queue without quitting first. This
applies to transfers started in version 1.76.0 or later; older versions did not
save their queues across restarts.

## CLI

The bundled Rust engine remains usable directly:

```bash
export PIKPAK_REFRESH_TOKEN='your-token'
cargo run -- quota
cargo run -- ls --path '/My Pack' -l -h
cargo run -- browse --parent-id '' --limit 200
cargo run -- share-browse --request-file '/private/path/share-request.json'
cargo run -- preview --id 'a-file-id-from-browse'
cargo run -- share-preview --request-file '/private/path/share-preview.json'
cargo run -- measure --id 'a-folder-id-from-browse'
cargo run -- duplicates --parent-id 'a-folder-id' --root-path '/My Pack/folder'
cargo run -- trash --id 'a-file-or-folder-id' --yes
cargo run -- empty-folders --parent-id 'a-folder-id' --root-path '/My Pack/folder' --yes
cargo run -- download --path '/My Pack/one.mp4' --path '/My Pack/two.mp4' --output ./downloads --jobs 2
cargo run -- share-download --request-file '/private/path/share-download.json' --output ./downloads --jobs 2
cargo run -- upload --parent-id 'a-folder-id' --input './large-folder' --jobs 4
```

`browse`, `preview`, `measure`, `duplicates`, and `trash` emit JSON for native
integrations. `trash` deliberately requires `--yes`. Preview and thumbnail URLs
are signed and short-lived; do not save or log them.

The GUI uses its own PikPak desktop OAuth session. Its temporary WebKit login
profile is nonpersistent and discarded after authorization, so Safari's Web
refresh-token chain remains separate.

For secure integrations, set `PIKPAK_REFRESH_TOKEN_FILE` to a private file and
`PIKPAK_ROTATED_TOKEN_FILE` to a path where the engine should atomically write
any rotated token. Multi-process frontends should also set
`PIKPAK_REFRESH_TOKEN_LOCK_FILE` to a shared lock path and `PIKPAK_DEVICE_ID` to
a stable, persisted device identity. In that mode each refresh reloads and
updates the shared token file while holding the lock.

## Safety notes

- Delete controls only move items to PikPak Trash; this app does not permanently
  empty Trash. Every Trash action requires confirmation in the native UI.
- Finder-style drag and drop uses PikPak's server-side batch-move request; it
  never downloads and re-uploads the moved content. The app has no offline-task
  commands. Uploads use temporary OSS
  credentials returned for one PikPak file task; those credentials remain only
  in engine memory and are never saved or printed.
- The browser loads at most 200 metadata entries per request and uses a native
  virtualized list. Additional entries load only after **Load More** is chosen.
- Inline preview covers images, audio, and video. Other types remain
  downloadable. The app tries alternate PikPak streams when macOS AVPlayer
  rejects a link or codec. AVI files using legacy FMP4/Xvid-family codecs use
  the IINA compatibility-preview action when no server transcode is available.
- Downloaded files are written as `name.part` and renamed only after completion.
- A filename received from the service is reduced to one safe path component.
- Treat a PikPak refresh token like a signed-in browser session. Do not paste it
  into chat, source files, screenshots, or shell history. The local session
  file is plaintext and protected by its owner-only directory and `0600` mode;
  processes already running as your macOS user can still read it.

## Verification

Shared-link input fields use a single adaptive layout instead of swapping
copies at narrow widths. URL/passcode editor identity, selection, and focus
remain intact on resize; full-field clicks focus the editor, with a visible
focus outline. Long text does not influence the wrapping breakpoint.
The geometry checks run without any account or network access:

```bash
swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
  macos/SharedLinkInputBar.swift scripts/SharedLinkInputTests.swift \
  -o /private/tmp/pikpak-link-input-tests
/private/tmp/pikpak-link-input-tests
```

`scripts/SharedLinkInputUITestApp.swift` mounts the same production fields in
an isolated UI fixture. Command-1/2/3 switch between narrow/compact/wide layouts
while typing; submitted text stays in the fixture and never reaches PikPak.

Concurrent cloud extraction tests use a local fixture helper (no account/network
access) to check overlapping inspections/extractions, independent passwords and
file selections, cancelling one inspection, and a failure alongside a success.

```zsh
swiftc -swift-version 5 -parse-as-library scripts/CloudExtractionFixtureEngine.swift -o /private/tmp/pikpak-extraction-fixture
extraction_test_sources=(macos/*.swift)
extraction_test_sources=("${(@)extraction_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D ARCHIVE_TASK_TESTS -swift-version 5 -parse-as-library "${extraction_test_sources[@]}" scripts/CloudExtractionTests.swift -o /private/tmp/pikpak-extraction-tests
/private/tmp/pikpak-extraction-tests /private/tmp/pikpak-extraction-fixture
```

The same suite covers automatic single-file extraction, independent password
prompts, wrong-password retries, Later/resume, stale submissions, worker bounds,
other file actions remaining available and progress observation isolation.
`scripts/CloudExtractionUITestApp.swift` runs the real ContentView with a bundled
`extraction-fixture` helper. Compile with `ARCHIVE_TASK_TESTS` and
`WORKSPACE_SWITCH_PROFILING`. Its `ExtractionInspectionScenario` bundle key
selects `activity`, `password`, `retry`, `footer` or `tasks`;
`ExtractionInspectionWidth` and `ExtractionInspectionDark` choose layout/appearance.
The activity scenario uses labeled synthetic progress; password scenarios run
actual inspection responses through the offline helper.

Offline transfer persistence tests exercise the real queue/snapshot types,
separate writer/reader processes, a 2,000-file queue, account isolation, private
permissions, corrupt-file protection, and model shutdown/reopen callbacks.
They use an isolated temporary directory and never load account credentials.

```zsh
transfer_test_sources=(macos/*.swift)
transfer_test_sources=("${(@)transfer_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D TRANSFER_PERSISTENCE_TESTS -swift-version 5 -parse-as-library "${transfer_test_sources[@]}" scripts/TransferPersistenceTests.swift -o /private/tmp/pikpak-transfer-persistence-tests
/private/tmp/pikpak-transfer-persistence-tests
```

Incremental folder-size tests use synthetic trees only (no account/API access).
They cover exact deltas, subtree reuse, private cache migration/relaunch, overlap
selection, concurrent mutation races, partial pagination, and large batches:

```zsh
folder_test_sources=(macos/*.swift)
folder_test_sources=("${(@)folder_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D FOLDER_SIZE_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${folder_test_sources[@]}" scripts/FolderSizeCacheTests.swift -o /private/tmp/pikpak-folder-size-tests
/private/tmp/pikpak-folder-size-tests
cargo test --locked --bin pikpak folder_measurement
```

Offline search, queue-batching, and Finder-drop regression tests:

```bash
swiftc -swift-version 5 -parse-as-library scripts/FileSearchFixtureEngine.swift -o /private/tmp/pikpak-search-fixture
swiftc -swift-version 5 -parse-as-library macos/FileSearch.swift macos/TransferScheduling.swift scripts/FileSearchTests.swift -o /private/tmp/pikpak-search-tests
/private/tmp/pikpak-search-tests /private/tmp/pikpak-search-fixture

# Full Browser/Links reveal and scope integration, with synthetic data only (zsh):
file_search_test_sources=(macos/*.swift)
file_search_test_sources=("${(@)file_search_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D FILE_SEARCH_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${file_search_test_sources[@]}" scripts/FileSearchTests.swift -o /private/tmp/pikpak-search-model-tests
/private/tmp/pikpak-search-model-tests /private/tmp/pikpak-search-fixture
```

Finder workspace, settings, account switching, footer/navigation, and resource monitor tests:

```zsh
finder_test_sources=(macos/*.swift)
finder_test_sources=("${(@)finder_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D FINDER_WORKSPACE_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${finder_test_sources[@]}" scripts/FinderWorkspaceTests.swift -o /private/tmp/pikpak-finder-tests
/private/tmp/pikpak-finder-tests
```

Account storage and the bounded account-status helper use only temporary files
and synthetic sessions. They cover migration, separate token rotation paths,
cancelled login, identity checks, logout, expiration and connection errors:

```zsh
account_test_sources=(macos/LegacyKeychainStore.swift macos/LocalCredentialStore.swift macos/CredentialParser.swift macos/PikPakAccounts.swift)
swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${account_test_sources[@]}" scripts/PikPakAccountStoreTests.swift -o /private/tmp/pikpak-account-store-tests
/private/tmp/pikpak-account-store-tests
swiftc -swift-version 5 -parse-as-library scripts/PikPakAccountVerifierFixture.swift -o /private/tmp/pikpak-account-verifier-fixture
swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${account_test_sources[@]}" macos/PikPakAccountVerifier.swift scripts/PikPakAccountVerifierTests.swift -o /private/tmp/pikpak-account-verifier-tests
/private/tmp/pikpak-account-verifier-tests /private/tmp/pikpak-account-verifier-fixture
```

File opening and account display tests use synthetic metadata/downloads and an
injected application launcher; no cloud account is accessed:

```zsh
open_test_sources=(macos/*.swift)
open_test_sources=("${(@)open_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D FINDER_WORKSPACE_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${open_test_sources[@]}" scripts/FinderFileOpeningTests.swift -o /private/tmp/pikpak-file-opening-tests
/private/tmp/pikpak-file-opening-tests
cargo test --locked --lib --bin pikpak -- --test-threads=1
```

Coverage includes profile fallback, original-file selection, private copies,
default/chosen app handoff, repeated opens, account/link isolation, cancellation,
HTTP errors, incomplete downloads, and navigation during an open request. Rust
tests use local HTTP fixtures; run them serially because download tests share
process-wide transfer counters.

`scripts/FinderWorkspaceUITestApp.swift` uses the real ContentView, native menu
commands, and Settings with synthetic folders and two independently expanded
links. Compile with `FINDER_WORKSPACE_TESTS` and bundle with
`scripts/FinderWorkspaceUITest-Info.plist`; no engine or credentials are bundled.
`scripts/FooterUITestApp.swift` checks the combined footer in the real workspace.
Also define `FINDER_FOOTER_TESTS` and `WORKSPACE_SWITCH_PROFILING`. Its bundle
keys `FooterInspectionScenario` (`ready`, `busy`, `error`),
`FooterInspectionWidth`, `FooterInspectionDark`, `FooterInspectionDetails`
and `FooterInspectionSection` select stable, offline visual scenarios.
Add `FINDER_RESOURCE_TESTS` to open Settings directly to Resources for visual QA.
Add `FINDER_ACCOUNTS_TESTS` instead for two synthetic accounts and the Accounts
pane, with verification handled by an in-memory fixture.
For a harmless sample scan, compile `scripts/TaskResourceFixtureEngine.swift`
as `Contents/Resources/resource-fixture` in the test bundle. It runs bounded
synthetic CPU work in a child and grandchild and never accesses PikPak or files.
The sampler reads only the app's process tree using macOS libproc, never command
arguments or unrelated apps. Tests cover CPU delta/idle/stale samples, task
attribution and totals across descendant helpers, live scan descriptions and
progress, cancellation, persistent defaults, edge-hover drag suppression,
queued worker limits, selected-file ancestry, and link-scoped saved state.

`scripts/BrowserScrollingUITestApp.swift` is an offline scrolling benchmark using
the actual Browser/Links rows. Compile with `-O`, `FINDER_WORKSPACE_TESTS` and
`BROWSER_SCROLL_PROFILING`, using the same source list and test bundle metadata.
Command-Shift-B scrolls 5,000 synthetic rows for 15 seconds and records timer
callbacks, pauses over 50 ms, worst delay, CPU and rendering counters in the
temporary directory as `<bundle identifier>-scroll.txt`. The Benchmark menu
provides larger/smaller datasets and cursor/drop isolation variants. Set the
test bundle's `ScrollFixtureSource` to `links` for 102 expanded synthetic links.
Run without concurrent compilation, profiling or accessibility queries. These
are diagnostic timer measurements, not display refresh-rate measurements.

Workspace switching, cache invalidation and loading-state tests (synthetic data):

```zsh
workspace_test_sources=(macos/*.swift)
workspace_test_sources=("${(@)workspace_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -O -D FINDER_WORKSPACE_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${workspace_test_sources[@]}" scripts/WorkspaceSwitchingTests.swift -o /private/tmp/pikpak-workspace-switch-tests
/private/tmp/pikpak-workspace-switch-tests
```

`scripts/WorkspaceSwitchingUITestApp.swift` exercises the real ContentView with
50,000 account files, 50,000 shared files and 102 expanded links. Compile with
`-O`, `FINDER_WORKSPACE_TESTS` and `WORKSPACE_SWITCH_PROFILING`, then bundle it
with its own identifier and no engine. It automatically measures six switches,
including click-handler time, destination presentation and main-loop pauses,
and writes `<bundle identifier>-switch.txt` in the temporary directory. Run
without concurrent compilation, profiling or accessibility queries; the report
measures event-loop responsiveness and presentation, not display refresh rate.

Recursive folder expansion tests (synthetic cached/paged trees, no account or network):

```zsh
expansion_test_sources=(macos/*.swift)
expansion_test_sources=("${(@)expansion_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D FOLDER_EXPANSION_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${expansion_test_sources[@]}" scripts/BrowserFolderExpansionTests.swift -o /private/tmp/pikpak-expansion-tests
/private/tmp/pikpak-expansion-tests
```

`scripts/BrowserFolderExpansionUITestApp.swift` is an offline native-menu harness.
Compile it with `macos/BrowserFolderExpansion.swift` and
`macos/BrowserContextMenuStyle.swift`; right-click its synthetic folder, or use
Command-M on macOS 14.4+ to inspect the same native submenu. Command-L changes
the row font size to check that context-menu icons keep their fixed dimensions.

Image-preview transition tests (synthetic bitmaps and controlled loaders; no network):

```zsh
swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library macos/PreviewTransport.swift macos/ImagePreview.swift scripts/ImagePreviewTests.swift -o /private/tmp/pikpak-image-preview-tests
/private/tmp/pikpak-image-preview-tests
```

Replace the test entry point with `scripts/ImagePreviewUITestApp.swift` to build
an offline visual harness. Its keyboard controls hold or complete the original
image request, making thumbnail retention and failed/retried loads inspectable.

Finder upload and in-app move target/model tests (synthetic files only):

```zsh
drop_test_sources=(macos/*.swift)
drop_test_sources=("${(@)drop_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D BROWSER_DROP_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${drop_test_sources[@]}" scripts/BrowserDragDropTests.swift -o /private/tmp/pikpak-browser-drop-tests
/private/tmp/pikpak-browser-drop-tests
```

The optional `scripts/BrowserDragDropUITestApp.swift` harness uses the actual
row drag source and unified drop canvas with stubbed upload/move boundaries;
compile it with the same sources and `BROWSER_DROP_TESTS` flag. It never accesses
an account and displays the accepted destination without sending data to PikPak.
The drag regression suite also exercises the delegate across hover, delayed
layout and release without a second pointer update, plus synchronous provider
capture, immediate preparation/error feedback and destination preservation.

The optional `scripts/FileSearchUITestApp.swift` harness uses the same popup
with an offline fixture helper, so Command-F, Command-Shift-F, arrows, Return, and Escape can be
verified without reading account data or interrupting live transfers.

```bash
cargo test
./scripts/build-app.sh
codesign --verify --deep --strict 'dist/My PikPak for Mac.app'
```

## Upstream and license

The PikPak protocol library and original CLI are based on
[youming-ai/pikpak-downloader](https://github.com/youming-ai/pikpak-downloader),
used under its MIT License. Local additions include the SwiftUI app, private
local session storage, secure token exchange, bounded scheduler, and
GUI-oriented safety checks. See [LICENSE](LICENSE).

The File-menu/status regression harness verifies retained progress and results,
footer-only progress observation, cancellation, duplicate keep-one protection,
account-scoped updates while Links is visible, cleanup/merge outcomes, and
clearing activity when accounts change:

```zsh
status_test_sources=(macos/*.swift)
status_test_sources=("${(@)status_test_sources:#macos/PikPakDownloaderApp.swift}")
swiftc -D FINDER_WORKSPACE_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library "${status_test_sources[@]}" scripts/TaskActivityTests.swift -o /private/tmp/pikpak-status-tests
/private/tmp/pikpak-status-tests
```

`scripts/TaskActivityUITestApp.swift` presents the real File menu, footer and
review sheet with synthetic data and no bundled engine. Compile with
`FINDER_WORKSPACE_TESTS`. Bundle metadata `TaskActivityScenario` accepts `ready`,
`running`, `complete`, `results`, or `mixed`; `TaskActivityWidth` and
`TaskActivityDark` cover narrow and dark layouts. The fake duplicate scan stays
at a stable progress snapshot for inspection; Cancel and the normal menu and
review actions remain interactive.

File context menus use the installed applications' full-color icons in **Open With**,
with the default application first. **Other…** opens a native application picker;
choosing an app opens a local copy without changing the system default. Distinct
installed versions of an identically named application show their version.

Press **Space** on a selected file in Browser or Links to open the system Quick
Look panel immediately. It shows the filename and a loading indicator until the
cloud copy is ready; failures offer **Try Again** inside the panel. **Up/Down**
selects the previous/next file and updates the same panel, including while a
download is pending. Clicking another file also updates an open preview. Moving
onto a folder shows its name and folder icon. The browser keeps the selection
visible, and recently fetched previews reuse up to eight private local copies.
Copies are scoped to the active account/link and file version.

A second Space, **Escape**, or the panel's close button closes Quick Look and
cancels its pending download. Late metadata or bytes cannot reopen it or replace
a newer selection. If the inline preview is already fetching this file's metadata,
Quick Look joins that request; unrelated foreground work can finish before the
latest selected preview is fetched. Typing, sheets, and Settings keep their own
key handling. Quick Look is also in both list and thumbnail context menus.
Preview panels retain the original filename in their title.

`FinderFileOpeningTests.swift` covers immediate pending previews, selection and
metadata races, Up/Down navigation, boundaries, copy reuse, cancellation and
late replies, keyboard scoping/repeats, app icons and caching, in addition to the
existing original-file/private-copy/handoff checks. `FileInteractionUITestApp.swift`
provides the real menus and system Quick Look with local synthetic text; compile
with `FINDER_WORKSPACE_TESTS`. Its optional `FileInteractionLoading` bundle flag
holds metadata for 20 seconds after Space to inspect cancellation. The optional
`QuickLookNavigation` flag instead supplies three distinct synthetic files with
an eight-second fetch delay for native loading, navigation and close checks.
The fixture contains no PikPak engine and intercepts external-app handoffs.


Use **Command-Z** or **Edit → Undo** to reverse the latest confirmed file action.
**Command-Shift-Z** or **Edit → Redo** applies it again. The menu names the action:
Move to Trash, Move, Upload, Rename, or New Folder. Undo Upload puts the exact
cloud IDs created by that batch into PikPak Trash; Redo restores those copies
without uploading them again. An uploaded/new folder must be empty before Undo
can move it to Trash, so unrelated items added later remain intact. Undoing a
stopped upload also cancels that batch's remaining saved work.

The app retains up to 50 actions in memory for the current account. History begins
with actions performed in this version and clears on account changes or app exit.
Undo waits for active uploads and conflicting file mutations to finish. Text
fields keep their own native Undo/Redo. Downloads, share imports, folder merges,
cleanup tools, and extractions do not add entries to this file-action history.

Undo/Redo validates current cloud state before changing it and advances history
only for confirmed changes. If a batch partly succeeds, its remaining changes
stay on the same stack and the completed portion becomes reversible on the other
stack. A retry recognizes an already-applied change after a lost response. The
browser refreshes after Undo/Redo and keeps the completion/error message in the
footer. Requests use the app's private JSON exchange files and existing session
coordination; they do not contain local source paths or file contents.

`FinderFileUndoTests.swift` covers ordering, partial acknowledgements, history
bounds, resumed-upload grouping, model registration, saved-upload cancellation,
and account isolation. `FileUndoUITestApp.swift`, built with
`FINDER_WORKSPACE_TESTS`, exercises the native Edit menu, both keyboard shortcuts,
and independent text-field undo using synthetic items and no PikPak engine.
Rust `file_undo` tests cover state conflicts, partial server failures, idempotent
retries, nonempty upload folders, and the authenticated restore protocol against
a local HTTP fixture. The `batchUntrash` route follows the compatible client's
[restore implementation](https://github.com/Quan666/PikPakAPI/blob/main/pikpakapi/__init__.py).

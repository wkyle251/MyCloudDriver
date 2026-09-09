# MyCloudDriver

The app opens at **Your drives**, with equally sized PikPak, iCloud Drive and
Apple Photos cards. Each card identifies its connection state and opens the
workspace. A persistent header offers **All Drives** and a drive switcher.
Switching drives preserves navigation, selection and background work.

All workspaces use the existing blue sidebar, neutral content cards, list/grid
switch, search, multi-selection, contextual actions, a preview pane and a status
footer. Downloads/imports and scans remain visible in their drive's activity
view. Connection controls live in Settings and on disconnected drive screens.

| Action | PikPak | iCloud Drive | Apple Photos |
| --- | --- | --- | --- |
| Browse, search, list/grid, select multiple | Files/folders | Files/folders | Photos/videos/albums |
| Open/Open With, Space Quick Look and arrow navigation | Download original | Materialize cloud file | Fetch asset resource |
| Import/export | Upload/download | Copy into/out of drive | Import media/export originals |
| New container, rename, move | Folders/files | Folders/files | Albums and album membership |
| Delete | PikPak Trash | Finder Trash | Photos deletion confirmation/Recently Deleted |
| Undo | Existing file actions | Rename, move, copy, Trash | Album edits and membership changes |
| Duplicate and similarity review | Existing engine | Same FileTwin engine | Same engine on selected asset resources |
| Folder size, cleanup, archive extraction | Existing operations | File-system operations | Albums have no archive or `.DS_Store` semantics |

Photos does not expose arbitrary filename renaming or programmatic restoration
of deleted library assets. Those commands use album operations where applicable;
deleted media is recovered in Photos. PikPak shared links remain provider-specific.
An unavailable operation has an explanation, never a success placeholder.

iCloud Drive is connected using the macOS folder picker and a security-scoped
bookmark. Reads and writes use file coordination; files stored only in iCloud
are downloaded before analysis. Photos uses PhotoKit, requests access only when
the user connects it, and never reads the private `.photoslibrary` database.
Original resources are staged privately and exported results map back to assets.

The application is renamed to **MyCloudDriver**. Its bundle identifier and
existing private Application Support location are retained to preserve PikPak
accounts, transfer history and preferences. Native drive bookmarks and caches
remain private and excluded from Git. The old installed app is archived before
installing the renamed bundle, preventing duplicate launcher entries.

Validation uses an isolated folder provider and a synthetic Photos provider;
real library mutation is never used for tests. Live permission prompts are left
to the user. Test cancellation, stale navigation, source isolation, safe paths,
partial failure, file undo, Photos album semantics and independent scans.

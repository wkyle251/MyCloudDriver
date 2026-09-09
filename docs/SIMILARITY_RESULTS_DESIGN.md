# Similarity results workspace

The scan window uses the same blue accent, file icons, outline rows and split
panes as the drive browser. PikPak, iCloud Drive, Apple Photos and This Mac share
the result view; each retains its own scan scope and catalog.

## Flow

1. Choose the scope and content types, then start a background scan.
2. Progress shows the current stage, raw file/pair counts, elapsed time and
   bytes read. A percentage appears only when FileTwin supplies a known total.
   The footer continues to report activity if the window is closed.
3. Completed scans open a results workspace. Setup controls collapse behind
   **Scan Settings** so the file tree and matches have room to breathe.
4. The left pane contains the scanned folder/file tree, including unmatched and
   unavailable files. Search narrows this tree while preserving folder context.
5. Select a file to show its details and related files on the right. Each match
   has its own saved cosine score, file name, path, size, and preview/open actions.
   Byte-identical evidence is labelled separately; a group minimum is never
   presented as the score between two individual files.
6. Change the minimum score (5–100%) or show only identical copies without
   downloading, decoding or scanning again. The selected file stays selected.

## Data and responsiveness

The imported FileTwin revision saves all compatible pair scores. Only the file
inventory and exact-copy groups enter the initial app report. Selecting a file
queries one matrix row in bounded pages on a helper process. The app cancels
obsolete requests and caches a small number of rows; it never constructs the
full quadratic score matrix on the GUI thread. Outline rows are virtualized by
AppKit and the tree is indexed once per report.

Missing scores are not zero. Failed analysis, incompatible media types and
incomplete comparison coverage have distinct explanations. Exact-copy matches
can exist even when a file format has no similarity decoder. Reports keep the
FileTwin run and revision fixed for every score query.

Cloud and Photos originals are removed from temporary scan storage after
analysis. Preview requests fetch a fresh private copy only when requested;
selection changes cancel pending previews. Local files are read in place.

Saved scores consume quadratic disk space. Existing finite engine resource
budgets remain in force; partial runs stay reviewable and clearly show incomplete
coverage. UI and export bounds are reported, never silently treated as a complete
file inventory.

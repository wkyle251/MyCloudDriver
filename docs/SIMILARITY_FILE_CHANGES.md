# Files changing during similarity scans

Similarity scans reconcile their inventory before comparison and once more
before returning the final report. The checks list metadata; they do not
download or export every original again. This applies to PikPak, local disks,
iCloud Drive and Photos inventories supplied by the current app.

- Added files enter analysis automatically, including files found after the
  initial discovery finished.
- Changed metadata or revisions invalidate the old result. Unchanged files
  reuse their completed analysis before an original is acquired.
- Removed files disappear from the final inventory, groups and comparisons.
  Removing every file produces an empty result. Direct PikPak selections moved
  to Trash are excluded as well.
- Reordering a provider's listing does not cause a rescan.
- Native Local Disk entries use the live inode, size and timestamps captured by
  discovery. A provider listing's stale mount number does not override that
  metadata and falsely restart an unchanged inventory. Real local changes still
  invalidate reuse; remote provider revisions remain part of their identity.
- A failed listing, lost permission or disconnected disk cannot establish that
  its files were deleted. The scan retains completed analysis for recovery.
  The scan window displays the drive's access or connection reason while
  discovery retries, and clears it when the drive supplies files again.

Discovery captures each entry's identity and revision before original
acquisition can wait. The captured metadata is compared with a fresh listing;
reading the original's *current* metadata only at comparison time would hide
an intervening edit. Native files are also revalidated before cached analysis
can be saved under their revision.

When membership or revisions change, the engine analyses the fresh inventory
and checks again. It uses a new comparison generation so ordinal-based scores
cannot be assigned to different files. A resumed sealed checkpoint goes through
the same checks. Completed per-file analysis remains reusable across passes and
restarts; deleted entries are removed from the current checkpoint statistics.

Follow-up passes carry completed records forward for every unchanged file,
including unsupported-file decisions and failed-attempt diagnostics. A change
elsewhere does not retry those originals. The saved scan also reuses completed
exclusions and failed-attempt diagnostics after a helper restart. Resume retries
cancelled or changed-input attempts. Starting a new scan can retry completed
failures and reconsider exclusions using the current recognizer.
Only an added file or a genuinely changed revision requires fresh processing.

The app shows **Checking for file changes** while reconciling. Totals can
increase or decrease when a new inventory is admitted. After eight follow-up
passes that continue to change, the scan stops with saved work and an explicit
resume message, rather than running indefinitely or claiming stable results.
This limit requires manual Resume and is persisted as a paused scan, so neither
automatic fault recovery nor reopening the window can restart the pass cycle.

The final report describes the last completed inventory check. Providers and
filesystems do not offer one atomic snapshot spanning listing, downloads and
comparison, so edits after that boundary require another scan. Opening saved
results or adjusting the similarity threshold continues to query that saved
result; it does not start background discovery.

The provider refresh protocol uses a separate empty, private JSONL file for
each request. The app validates its owning request directory and rejects
symlinks and occupied files. Discovery is deduplicated within each pass, and
pause/cancellation stops both the inventory producer and reader.

## Resuming after an SSH update

With the app closed, launch it with the saved Across Drives scan ID:

```sh
open /Applications/MyCloudDriver.app --args --resume-similarity-session SCAN_UUID
```

This uses the normal Resume action for that scan in the current account and
opens its results window. Completed scans open their saved report. Ordinary
launches still leave user-paused scans paused; an unknown ID starts no work.

## Validation

Saved comparison queries also use disposable per-run chunk bounds. The bounds
are tied to the sealed matrix's file identity, checked for complete coverage
and checksum integrity, and rebuilt from saved scores if stale or damaged.
Threshold changes skip chunks whose maximum cannot qualify. Up to eight
completed threshold responses are cached with the matrix and Trash-state
identities; changing either invalidates the response. Neither path opens an
original file or starts discovery, analysis or comparison again.

Score rows can return stable numeric ordinals instead of repeating long file
identifiers. The app joins them against the saved report and uses the same
bounded 512 MiB reader as report recovery, replacing the former 32 MiB query
limit.

Confirmed Trash actions atomically record excluded ordinals beside the matrix
and retire the removed files' source-cache associations. Shared content vectors
remain while another retained file references them. Retired source revisions
cannot be reimported from an older checkpoint. Undo restores the exclusion state
even after the results window closes; the sealed scores remain intact for that
recovery. Reopening results reapplies saved exclusions and retries interrupted
source-cache cleanup.

After Trash, selection advances in the current filtered display order, skipping
removed files and groups that no longer have two members. At the end it uses
the nearest preceding file. Tree refreshes preserve a surviving viewport anchor
instead of scrolling back to the first group; match-list selection advances too.

Disk Trash listing verifies each entry independently. An invalid or foreign
volume journal is counted and preserved while other verified entries remain
visible. Put Back and Empty Trash retain their strict validation.

All fixtures use generated local data and loopback HTTP responses.

```sh
python3 scripts/with-client-credentials.py cargo test --locked --lib similarity::inventory::tests
python3 scripts/with-client-credentials.py cargo build --locked --bin pikpak
scripts/build-native-test.sh scripts/SimilarityInventoryTests.swift /tmp/mycloud-similarity-inventory
/tmp/mycloud-similarity-inventory "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources" "$PWD/target/debug/pikpak"
```

The native fixture changes files after analysis and after comparison, verifies
that unchanged originals are acquired once, resumes a sealed comparison after
deletion, and finally removes the whole file set. Rust fixtures cover same-size
edits, rename/reordering, paginated PikPak changes, Trash, incomplete provider
inventories, cancellation and comparison-generation isolation.

Validated on October 19, 2026: 216 similarity library tests passed (two ignored),
and all 11 native inventory checks passed against the packaged release engine.
The native checks include repeated changes, reuse of completed exclusions and
failures across restart, recovery from a disconnected drive, the manual pause
limit, and loading/reopening a completed report over 64 MiB.

Validated on October 20, 2026: 221 similarity library tests passed (two ignored),
plus 37 native checks locally and on the remote Mac against build 306. These
cover exact cached-score round trips, corrupt bounds, a score row above 32 MiB,
durable Trash exclusions, shared-vector retention, Undo after window closure,
foreign Trash journals, and next-item selection with viewport preservation.
The native suite can be reproduced with:

```sh
scripts/build-native-test.sh scripts/SimilarityQueryAndTrashTests.swift /tmp/mycloud-query-trash \
  -D SIMILARITY_QUERY_TEST_LIBRARY scripts/DiskTrashTests.swift scripts/SimilarityTests.swift \
  scripts/SimilarityTreeExpansionTests.swift
/tmp/mycloud-query-trash "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources"
```

Validated on September 15, 2026: 191 library tests and 84 CLI tests passed
(five CLI tests remained ignored). The inventory and existing similarity native
suites also passed against the packaged release engine. Version 2.2.26 (build
201) was built, signed, installed and relaunched with saved transfers preserved.

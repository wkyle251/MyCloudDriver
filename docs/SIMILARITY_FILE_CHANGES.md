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
- A failed listing, lost permission or disconnected disk cannot establish that
  its files were deleted. The scan retains completed analysis for recovery.

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

The app shows **Checking for file changes** while reconciling. Totals can
increase or decrease when a new inventory is admitted. After eight follow-up
passes that continue to change, the scan stops with saved work and an explicit
resume message, rather than running indefinitely or claiming stable results.

The final report describes the last completed inventory check. Providers and
filesystems do not offer one atomic snapshot spanning listing, downloads and
comparison, so edits after that boundary require another scan. Opening saved
results or adjusting the similarity threshold continues to query that saved
result; it does not start background discovery.

The provider refresh protocol uses a separate empty, private JSONL file for
each request. The app validates its owning request directory and rejects
symlinks and occupied files. Discovery is deduplicated within each pass, and
pause/cancellation stops both the inventory producer and reader.

## Validation

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

Validated on September 15, 2026: 191 library tests and 84 CLI tests passed
(five CLI tests remained ignored). The inventory and existing similarity native
suites also passed against the packaged release engine. Version 2.2.26 (build
201) was built, signed, installed and relaunched with saved transfers preserved.

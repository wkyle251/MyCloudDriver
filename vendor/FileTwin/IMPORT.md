# FileTwin source import

Updated on 2026-09-09 from the app owner's FileTwin workspace, commit
`9af294cad9e213467b60d94c2490610c71d97c28` (version 0.1.0-dev).
`UPSTREAM-SHA256.json` records the unmodified source snapshot. Only tracked
source, schemas, examples, build scripts and public documentation are included.
Credentials, indexes, scan results, model binaries and build outputs are excluded.

MyCloudDriver calls `filetwin-core` from `src/similarity.rs` and bundles the
`filetwin-worker` executable. It saves all compatible pair scores and reads
bounded matrix rows when a user selects a result file. Exact copies use the
separate SHA-256 evidence. Source files are not read again when changing the
result filter.

This update replaces the previous local progress patches with FileTwin's
published raw counters. Discovery includes analysis; its total is unknown until
inventory is complete. The app shows counts during discovery and a percentage
only for stages with a known positive total. There is no invented per-file
encoding percentage or ETA.

Native assets are provisioned explicitly at build time. Preserve
THIRD_PARTY_NOTICES.md and downloaded component notices in distributed apps.

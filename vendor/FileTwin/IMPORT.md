# FileTwin source import

Imported on 2026-09-09 from the app owner’s FileTwin workspace, version
0.1.0-dev. `UPSTREAM-SHA256.json` records the unmodified source snapshot.
Only source code, schemas, build scripts and public documentation are included;
no credentials, indexes, local scan results, model binaries or build outputs.

MyCloudDriver calls `filetwin-core` from `src/similarity.rs` and bundles the
`filetwin-worker` executable. The app adds PikPak staging, progress and a native
review window; changes to those belong outside this directory. Native assets
are provisioned explicitly at build time. Preserve THIRD_PARTY_NOTICES.md and
the downloaded component notices when distributing a built app.

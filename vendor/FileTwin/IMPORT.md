# FileTwin source import

Imported on 2026-09-09 from the app owner’s FileTwin workspace, version
0.1.0-dev. `UPSTREAM-SHA256.json` records the unmodified source snapshot.
Only source code, schemas, build scripts and public documentation are included;
no credentials, indexes, local scan results, model binaries or build outputs.

MyCloudDriver calls `filetwin-core` from `src/similarity.rs` and bundles the
`filetwin-worker` executable. The app adds PikPak staging, progress and a native
review window. Native assets
are provisioned explicitly at build time. Preserve THIRD_PARTY_NOTICES.md and
the downloaded component notices when distributing a built app.

Local changes for v1.89.0 (the original hashes above remain unchanged):

- `engine.rs`: transient, throttled progress telemetry with stage totals,
  current file and bytes read. It does not change the stored job schema.
- `scan.rs`: inventory paths into a temporary SQLite queue before analysing
  content, so the UI has a stable work total. Content still uses secure opens,
  revision checks and the existing encoders. Reads and hashes report bytes.
- `native.rs`: report source-copy bytes and the decoder stage.
- `matching.rs`: report pairs examined and match entries grouped, including
  exact-copy work, with totals from the frozen snapshot.

Matching profiles, score calculations, decoder limits and published result
formats remain those of the imported source.

# Remote download monitor

Run on this Mac:

```sh
cd /Users/wky/Work/PikPakDownloader
python3 scripts/remote-download-monitor.py
```

Or double-click **Monitor Remote Downloads.command** in Finder. Enlarge Terminal to
to **140 columns × 36 rows** for full details; a standard **80 × 24** window uses
the compact dashboard. Press **q**
or **Ctrl-C** to close the monitor. This does not pause or quit MyCloudDriver.

The default connection is `fubao@192.168.50.228`, using the Mac's standard SSH client
and host-key verification. Enter the remote account's password when SSH prompts.
The script does not save credentials. Existing SSH keys/agent configuration work
as usual. Python 3 is required on both Macs; no pip packages or administrator access
are needed. A collector runs over this one SSH channel, with no installed daemon.

## Display

- **Download:** the trailing five-second payload rate, latest sample rate, progress,
  downloaded/total bytes, discovered/completed/skipped counts, remaining bytes and
  ETA and expected completion, plus active, queued, retrying, and failed counts.
- **RAM:** used/limit/peak, receivers waiting for RAM, receiving tasks, and remote
  system CPU/load and estimated system RAM use. The RAM estimate subtracts free,
  inactive, and speculative pages; it differs from Activity Monitor's accounting.
- **Disk:** pending reads, reading, pending writes and writing; selected task counts,
  actual active I/O, oldest wait, ready reads, completed checks, current turn and
  handover wait. “Reading” and “writing” describe the selected pools; actual active
  disk operations appear separately.
- **Graphs:** download, physical disk read, and physical disk write each have a
  full-width row, stacked vertically. Each upper-left heading shows the latest
  sampled speed. The five-minute download history uses the five-second average
  (0–100 **MB/s**); disk histories use sampled rates (0–260 **MiB/s**).
  Short windows use one-line sparklines; taller windows show vertical axes.
  `^` marks a clipped peak; logged values remain exact. Disk rates include all
  applications on the physical destination disk, like the app.
- **Wait trace:** the oldest active anonymous setup stages, worker occupancy, monitor
  average, the app's overall average and chart ETA, and observed time below 10 MB/s. These are evidence for investigation,
  not an automatic claim that the cloud or disk caused a slowdown.

Samples arrive every two seconds. The five-second rate uses the same cumulative
payload counter and interpolation as the existing terminal monitor. Fresh progress
and pool snapshots need app build **268 or later**. Earlier builds still provide
speed, disk rates, and most pool/wait data through their ten-second diagnostic
windows; unavailable progress/ETA are shown explicitly. Unknown/stale values show
`--`, and missing samples are graph gaps rather than invented zero rates. After a
lost SSH connection, rerun the command to reconnect; retained logs remain usable.

## Saved history

Numeric history is saved **on this Mac**, under:

```text
~/Library/Logs/MyCloudDriver/RemoteMonitor/fubao_192.168.50.228/
```

The active file is ordinary JSON Lines, flushed on each sample. At 8 MiB it rotates
to a gzip archive; closing the monitor also compresses the active file. On restart,
an incomplete final JSON line is ignored and prior active files are archived.
Retention is **eight days**, subject to a **512 MiB total cap**, whichever removes
old history first. Files are private (`0600`), directories `0700`, and a lock prevents
two monitors from writing to the same directory. A log-storage failure is shown
without stopping remote downloads. Each record has a version and UTC epoch time.

To inspect stored history:

```sh
python3 scripts/remote-download-monitor.py --summary \
  "$HOME/Library/Logs/MyCloudDriver/RemoteMonitor/fubao_192.168.50.228/"*.jsonl.gz

python3 scripts/remote-download-monitor.py --replay /path/to/monitor-....jsonl.gz
```

Summary output includes time-weighted download speed, low-rate observations, disk
rates, RAM waiters and active setup stages at those times. Replay accepts one or
more active JSONL or compressed archives in chronological order and never connects
to the remote Mac. It neither alters nor deletes those logs. `--summary` is also
safe while the active JSONL is being written.

Other useful options:

```sh
python3 scripts/remote-download-monitor.py --plain --duration 120
python3 scripts/remote-download-monitor.py --demo               # synthetic preview, no SSH or logs
python3 scripts/remote-download-monitor.py --no-log              # display only
python3 scripts/remote-download-monitor.py --history 900         # fifteen-minute graphs
python3 scripts/remote-download-monitor.py --max-log-mib 1024 --retention-days 14
python3 scripts/remote-download-monitor.py --host user@other-mac --destination /Volumes/OtherDrive
```

Only allowlisted numeric fields are transmitted and logged. The collector reads
the app's bounded numeric snapshots and bounded tails of its structured diagnostic
logs. It never reads download files, filenames, queue contents, ordinary activity
messages, URLs, credentials, file-descriptor paths, or process arguments. Disk
counters come from IOKit; resolving the specified mount uses filesystem metadata
only. It does not run disk benchmarks or query SMART sensors. No transfer settings,
buffer limits or read/write policies are changed by the monitor.

The remote Mac also has a separate [download FullWake guard](REMOTE_FULLWAKE.md)
for closed-lid operation on AC power. It runs independently of this monitor and
restores its sleep override when downloads and saving/verification work stop.

## Verification

```sh
python3 scripts/test-remote-download-monitor.py
python3 scripts/test-monitor-download-speed.py
swiftc -swift-version 5 -parse-as-library macos/DownloadDiagnostics.swift \
  scripts/DownloadDiagnosticsTests.swift -o /tmp/download-monitor-diagnostics-tests
/tmp/download-monitor-diagnostics-tests
```

Tests use synthetic data only and cover privacy filtering, five-second rates,
counter resets, stale data, bounded readers, log rotation/compression/retention,
crash tails, permissions, single-writer locking, low-speed summaries and layouts
at several terminal sizes.

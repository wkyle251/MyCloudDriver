# Remote FullWake guard

The remote Mac at `192.168.50.228` can enter DarkWake with its laptop lid closed,
even while Amphetamine and `caffeinate` hold idle-sleep assertions. The verified
closed-lid workaround is the system-wide `pmset disablesleep` override. Ordinary
pings and repeated user-activity assertions did not maintain continuous FullWake.

`scripts/remote-fullwake-guard.py` scopes that override to active MyCloudDriver
downloads, Find Similarity and Check Duplicates on AC power. It reads bounded
numeric transfer and app-work heartbeats; it does not inspect original files,
cloud credentials, or the saved transfer queue. The app-work heartbeat contains
only its version, app PID, timestamp and active-owner count, refreshes off the
main actor, and covers native duplicate scans without a helper process.
For older apps without this heartbeat, the guard privately verifies an owned
installed-app descendant and its scan operation; it does not log raw arguments.
Pausing still retains protection while accepted RAM data, active verification,
pending reads/writes, or checkpoint batches drain. Fully idle work releases after
15 seconds; missing/stale app snapshots release within about 25 seconds of the
last valid activity. Disconnecting AC or disabling the guard releases on the next
check, normally within ten seconds. Resume reacquires protection automatically.

The guard runs independently of SSH, Screen Sharing, and the TUI. It does not
change download concurrency, disk policy, idle/display sleep timers, or Amphetamine
preferences. During protection, manual system sleep and lid sleep are suppressed;
disable the guard first if you want the Mac to sleep while this work remains active.
This addresses power state; verification and HDD scheduling can still lower speed.

## Installed on the remote Mac

- Root-owned code/configuration: `/Library/Application Support/MyCloudDriver/FullWake/`
- Launch daemon: `/Library/LaunchDaemons/com.myclouddriver.fullwake.plist`
- Service: `system/com.myclouddriver.fullwake`
- Snapshot owner: remote account `fubao` (UID 501).

The daemon starts at boot and is restarted by launchd if it exits. Before setting
the override, it durably journals the original value. Normal idle, shutdown and
service unloading restore that value. After a crash or reboot, a replacement
daemon restores the journaled value before considering current work. A sleep
override that was already enabled by someone else is left unchanged. Configuration
and the restoration journal are root-only; no password or sudoers rule is saved.

Run these commands **over SSH on the remote Mac**:

```sh
# View current power state, guard ownership, reason and update time (no sudo needed).
/usr/bin/python3 '/Library/Application Support/MyCloudDriver/FullWake/guard.py' --status

# Disable the guard and let it restore the original sleep setting.
sudo /usr/bin/python3 '/Library/Application Support/MyCloudDriver/FullWake/guard.py' --disable

# Re-enable automatic protection for active downloads/scans on AC.
sudo /usr/bin/python3 '/Library/Application Support/MyCloudDriver/FullWake/guard.py' --enable
```

After disabling, confirm `holding: false` and the original `sleep_disabled` value
in status. To unload the service after restoring sleep:

```sh
sudo launchctl bootout system/com.myclouddriver.fullwake
```

The next boot loads the service again with its saved enabled/disabled preference.
`fullwake` uses the kernel CPU + graphics capability bits, and `capabilities: 15`
was the observed FullWake value on this Mac (`9` was DarkWake). The status file's
timestamp must be fresh; it is an observation, not a guarantee that the daemon is
currently alive.

## Verification

```sh
python3 scripts/test-remote-fullwake-guard.py
```

Synthetic tests cover drained Pause, completion, stale/crashed helpers, AC removal,
explicit disable, preservation of external overrides, journal ordering, daemon
recovery, command failures, bounded snapshot reads, independent scan owners,
native-only scans, idle/stale heartbeats and verified legacy-helper fallback.
Tests use injected process/power observations and never inspect host files or
change power settings. Deployment checks additionally
verify disable/restore and re-enable, plus FullWake with Screen Sharing disconnected.

On 12 October 2026, the installed service held kernel capabilities at `15` in all
91 samples over 185 seconds with the lid closed and Screen Sharing/SSH disconnected.
A further 31 samples over 62 seconds after a service update also remained at `15`.
Disabling restored `SleepDisabled` to its original `false`; launchd recovered after
a forced process exit. Receiving averaged about 2.1 MB/s during these observations,
with the disk in its verification read phase, so FullWake alone did not clear that
separate throughput bottleneck. The final installed source checksum is recorded
with the local deployment evidence under `dist/fullwake-deploy-xg0tpuj6/`.

Apple's [pmset implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m)
stores `disablesleep` as a system-wide setting, which is why AC scoping and explicit
restoration belong to this guard rather than an AC-only pmset profile.

#!/usr/bin/env python3
"""Keep an AC-powered download Mac fully awake, with crash-safe sleep restoration."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import threading
import time

DEFAULT_CONFIG = Path('/Library/Application Support/MyCloudDriver/FullWake/config.json')
WORK_KEYS = ('ram_buffered_bytes', 'pending_write_bytes', 'pending_read_tasks',
             'reading_tasks', 'writing_tasks', 'active_read_tasks',
             'active_write_tasks', 'checkpoint_batch_pending')


def read_json(path, limit=16384, owner=None):
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            return None
        if owner is not None and info.st_uid != owner:
            return None
        data = os.read(fd, limit + 1)
        return json.loads(data) if len(data) <= limit else None
    except (OSError, ValueError, UnicodeError):
        return None
    finally:
        if fd is not None:
            os.close(fd)


def atomic_json(path, value, mode=0o600):
    temporary = path.with_name(path.name + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, 'w') as out:
        os.fchmod(out.fileno(), mode)
        json.dump(value, out, separators=(',', ':'), allow_nan=False)
        out.write('\n')
        out.flush()
        os.fsync(out.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def observation(row, wall_time):
    if not isinstance(row, dict) or type(row.get('version')) is not int or row['version'] != 1:
        return 'unavailable'
    pid, updated, values = row.get('helper_pid'), row.get('updated_at'), row.get('values')
    if type(pid) is not int or pid <= 0 or not finite(updated) or not -1 <= wall_time - updated <= 5:
        return 'unavailable'
    if not isinstance(values, dict):
        return 'unavailable'
    downloading, paused = values.get('is_downloading'), values.get('reception_paused', 0)
    if not finite(downloading) or downloading not in (0, 1) or not finite(paused) or paused not in (0, 1):
        return 'unavailable'
    # The helper stays alive with is_downloading=1 while reception is paused.
    # Retain protection only while receiving is enabled or accepted work drains.
    if (downloading == 1 and paused == 0) or any(finite(values.get(k)) and values[k] > 0 for k in WORK_KEYS):
        return 'active'
    return 'idle'


class Policy:
    def __init__(self):
        self.last_active = None

    def decide(self, enabled, ac_power, state, now):
        if not enabled or not ac_power:
            self.last_active = None
            return False, 'disabled' if not enabled else 'battery'
        if state == 'active':
            self.last_active = now
            return True, 'active'
        grace = 20 if state == 'unavailable' else 15
        if self.last_active is not None and now - self.last_active < grace:
            return True, 'settling'
        return False, state


class Store:
    def __init__(self, directory):
        self.path = directory / 'restore.json'
        self.status = directory / 'status.json'

    def pending(self):
        row = read_json(self.path, owner=0)
        if row is None:
            if self.path.exists():
                raise RuntimeError('Unreadable restoration journal')
            return None
        if (not isinstance(row, dict) or type(row.get('version')) is not int or row['version'] != 1
                or type(row.get('owned')) is not bool or type(row.get('original')) is not bool):
            raise RuntimeError('Invalid restoration journal')
        return row['original'] if row.get('owned') is True else None

    def save(self, original):
        atomic_json(self.path, {'version': 1, 'owned': True, 'original': original})

    def clear(self):
        atomic_json(self.path, {'version': 1, 'owned': False, 'original': False})


class MacPower:
    @staticmethod
    def run(argv):
        return subprocess.run(argv, check=True, capture_output=True, timeout=5,
                              env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C'}).stdout

    def read(self):
        raw = self.run(['/usr/sbin/ioreg', '-r', '-n', 'IOPMrootDomain', '-d', '1', '-a'])
        rows = plistlib.loads(raw)
        root = rows[0] if len(rows) == 1 else {}
        disabled, caps = root.get('SleepDisabled'), root.get('System Capabilities')
        if type(disabled) is not bool or type(caps) is not int:
            raise RuntimeError('Power state unavailable')
        supply = self.run(['/usr/bin/pmset', '-g', 'batt']).splitlines()[0]
        return {'sleep_disabled': disabled, 'capabilities': caps,
                'fullwake': caps & 3 == 3, 'lid_closed': root.get('AppleClamshellState') is True,
                'ac_power': b"'AC Power'" in supply}

    def set_disabled(self, value):
        self.run(['/usr/bin/pmset', '-a', 'disablesleep', str(int(value))])
        for _ in range(10):
            if self.read()['sleep_disabled'] == value:
                return
            time.sleep(.2)
        raise RuntimeError('Sleep setting did not take effect')

    def wake(self):
        # A short activity declaration promotes an existing DarkWake. The sleep
        # override, rather than repeated activity pulses, maintains FullWake.
        self.run(['/usr/bin/caffeinate', '-u', '-t', '2'])


class Guard:
    def __init__(self, power, store):
        self.power, self.store = power, store
        self.last_wake = -100

    def release(self):
        original = self.store.pending()
        if original is not None:
            self.power.set_disabled(original)
            # Keep the journal until the original value is confirmed. A killed
            # daemon is restarted by launchd and recovers this same transaction.
            self.store.clear()

    def hold(self, power_state, now):
        if not power_state['sleep_disabled']:
            if self.store.pending() is None:
                self.store.save(False)  # durable BEFORE changing global power policy
            self.power.set_disabled(True)
            self.power.wake()
            self.last_wake = now
        elif not power_state['fullwake'] and now - self.last_wake >= 10:
            self.power.wake()
            self.last_wake = now


def load_config(path):
    row = read_json(path, owner=0)
    if not isinstance(row, dict) or type(row.get('enabled')) is not bool:
        raise RuntimeError('Invalid guard configuration')
    directory, uid = row.get('monitor_directory'), row.get('owner_uid')
    if not isinstance(directory, str) or not Path(directory).is_absolute() or type(uid) is not int or uid <= 0:
        raise RuntimeError('Invalid snapshot owner')
    return row


def serve(config_path, stop):
    directory = config_path.parent
    lock = os.open(directory / 'guard.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    store, policy, power = Store(directory), Policy(), MacPower()
    guard = Guard(power, store)
    try:
        guard.release()  # restore a previous run before considering new work
        while not stop.is_set():
            try:
                config = load_config(config_path)
                row = read_json(Path(config['monitor_directory']) / 'monitor-state-v1.json', owner=config['owner_uid'])
                state = observation(row, time.time())
                current = power.read()
                wanted, reason = policy.decide(config['enabled'], current['ac_power'], state, time.monotonic())
                if wanted:
                    guard.hold(current, time.monotonic())
                else:
                    guard.release()
                current = power.read()
                atomic_json(store.status, {'version': 1, 'updated_at': time.time(),
                            'guard_pid': os.getpid(), 'enabled': config['enabled'], 'reason': reason,
                            'holding': store.pending() is not None, **current}, 0o644)
            except Exception as error:
                policy.last_active = None
                try:
                    guard.release()
                except Exception:
                    pass  # retain the restoration journal and retry next pass
                atomic_json(store.status, {'version': 1, 'updated_at': time.time(),
                            'guard_pid': os.getpid(), 'reason': 'error',
                            'error_type': type(error).__name__, 'holding': store.pending() is not None}, 0o644)
            stop.wait(5)
    finally:
        try:
            guard.release()
        finally:
            os.close(lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--status', action='store_true')
    actions.add_argument('--enable', action='store_true')
    actions.add_argument('--disable', action='store_true')
    args = parser.parse_args()
    if args.status:
        print(json.dumps(read_json(args.config.parent / 'status.json'), indent=2))
        return
    if os.geteuid() != 0:
        parser.error('Run with sudo; this controls the closed-lid system sleep policy')
    os.umask(0o077)
    if args.enable or args.disable:
        config = load_config(args.config)
        config['enabled'] = bool(args.enable)
        atomic_json(args.config, config)
        print('FullWake guard ' + ('enabled' if args.enable else 'disabled; sleep will restore on the next check'))
        return
    stop = threading.Event()
    for name in (signal.SIGTERM, signal.SIGINT):
        signal.signal(name, lambda *_: stop.set())
    serve(args.config, stop)


if __name__ == '__main__':
    main()

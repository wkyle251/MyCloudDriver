#!/usr/bin/env python3
"""Keep active MyCloudDriver work on AC fully awake, with crash-safe restoration."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import stat
import struct
import subprocess
import sys
import threading
import time

DEFAULT_CONFIG = Path('/Library/Application Support/MyCloudDriver/FullWake/config.json')
DEFAULT_APP_EXECUTABLE = '/Applications/MyCloudDriver.app/Contents/MacOS/PikPakDownloader'
SCAN_OPERATIONS = frozenset(('similarity-scan', 'duplicates'))
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
    try:
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    except OverflowError:
        return False


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


def awake_observation(row, wall_time):
    """Validate the app's filename-free, numeric activity heartbeat."""
    if not isinstance(row, dict) or type(row.get('version')) is not int or row['version'] != 1:
        return 'unavailable'
    pid, updated, count = row.get('app_pid'), row.get('updated_at'), row.get('active_work_count')
    if (type(pid) is not int or pid <= 0 or not finite(updated)
            or not -1 <= wall_time - updated <= 5
            or type(count) is not int or count < 0):
        return 'unavailable'
    return 'active' if count > 0 else 'idle'


def helper_executable(app_executable):
    return str(Path(app_executable).parent.parent / 'Resources' / 'pikpak')


def scan_operation_from_procargs(data):
    """Return only a recognized verb from a bounded Darwin KERN_PROCARGS2 row."""
    if not isinstance(data, bytes) or len(data) < 4 or len(data) > 256 * 1024:
        return None
    if struct.unpack_from('i', data)[0] < 2:
        return ''
    end = data.find(b'\0', 4)
    if end < 0:
        return None
    start = end + 1
    while start < len(data) and data[start] == 0:
        start += 1
    first_end = data.find(b'\0', start)
    next_end = data.find(b'\0', first_end + 1) if first_end >= 0 else -1
    if next_end < 0:
        return None
    candidate = data[first_end + 1:next_end]
    return next((value for value in SCAN_OPERATIONS if candidate == value.encode('ascii')), '')


def scan_process_observation(rows, owner_uid, app_executable=DEFAULT_APP_EXECUTABLE):
    """Pure fallback policy; rows contain identities and one whitelisted verb only.

    A fresh app heartbeat is preferred over this compatibility fallback because
    a paused older helper may remain alive with its originals retained in RAM.
    """
    if not isinstance(rows, list):
        return 'unavailable'
    processes, uncertain = {}, False
    for row in rows:
        if not isinstance(row, dict):
            return 'unavailable'
        pid, parent, uid = row.get('pid'), row.get('ppid'), row.get('uid')
        if (type(pid) is not int or pid <= 0 or type(parent) is not int or parent < 0
                or type(uid) is not int or uid < 0 or pid in processes):
            return 'unavailable'
        processes[pid] = row
        uncertain = uncertain or (uid == owner_uid and row.get('executable') is None)
    apps = {pid for pid, row in processes.items()
            if row['uid'] == owner_uid and row.get('executable') == app_executable}
    expected_helper = helper_executable(app_executable)
    for row in processes.values():
        if row['uid'] != owner_uid or row.get('executable') != expected_helper:
            continue
        if row.get('operation') is None:
            uncertain = True
            continue
        if row['operation'] not in SCAN_OPERATIONS:
            continue
        seen, parent = {row['pid']}, row['ppid']
        while parent > 0 and parent not in seen:
            ancestor = processes.get(parent)
            if ancestor is None:
                # Process exit/reparenting during enumeration cannot establish
                # ownership. The existing unavailable grace remains bounded.
                uncertain = True
                break
            if ancestor['uid'] != owner_uid:
                break
            if parent in apps:
                return 'active'
            seen.add(parent)
            parent = ancestor['ppid']
    return 'unavailable' if uncertain else 'idle'


def process_rows(owner_uid, app_executable=DEFAULT_APP_EXECUTABLE):
    """Read numeric process topology and exact executable identity privately.

    No process command line is passed through ps, printed, written to status,
    or retained here. Darwin's proc arguments are used only to select argv[1],
    and only for exact app-bundled helper executables owned by the target user.
    """
    if sys.platform != 'darwin':
        raise RuntimeError('Darwin process identity is unavailable')
    import ctypes
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    library.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
    library.proc_pidpath.restype = ctypes.c_int
    library.sysctl.argtypes = (ctypes.POINTER(ctypes.c_int), ctypes.c_uint,
                              ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
                              ctypes.c_void_p, ctypes.c_size_t)
    library.sysctl.restype = ctypes.c_int
    numeric = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,uid='], check=True,
                             capture_output=True, timeout=3,
                             env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C'}).stdout
    if len(numeric) > 4 * 1024 * 1024:
        raise RuntimeError('Process topology exceeds its bound')
    rows = []
    expected_helper = helper_executable(app_executable)
    for line in numeric.splitlines():
        parts = line.split()
        if len(parts) != 3 or not all(part.isdigit() for part in parts):
            raise RuntimeError('Invalid numeric process topology')
        pid, parent, uid = map(int, parts)
        row = {'pid': pid, 'ppid': parent, 'uid': uid, 'executable': ''}
        if uid == owner_uid:
            path = ctypes.create_string_buffer(4096)
            length = library.proc_pidpath(pid, path, len(path))
            row['executable'] = os.fsdecode(path.value) if length > 0 else None
            if row['executable'] == expected_helper:
                # CTL_KERN / KERN_PROCARGS2: argc, executable path, padding,
                # then argv. A bounded buffer is never decoded or logged as a
                # whole: only the known operation verb survives this function.
                name = (ctypes.c_int * 3)(1, 49, pid)
                arguments = ctypes.create_string_buffer(256 * 1024)
                size = ctypes.c_size_t(len(arguments))
                operation = None
                if library.sysctl(name, 3, arguments, ctypes.byref(size), None, 0) == 0:
                    operation = scan_operation_from_procargs(arguments.raw[:size.value])
                row['operation'] = operation
        rows.append(row)
    return rows


def work_observation(download_row, awake_row, wall_time, rows, owner_uid,
                     app_executable=DEFAULT_APP_EXECUTABLE):
    downloading = observation(download_row, wall_time)
    awake = awake_observation(awake_row, wall_time)
    # An authoritative zero means that a new app has paused/drained all its
    # scans. Do not let its retained, paused helper reactivate the override.
    if awake == 'unavailable':
        awake = scan_process_observation(rows, owner_uid, app_executable)
    states = (downloading, awake)
    return 'active' if 'active' in states else 'idle' if all(state == 'idle' for state in states) else 'unavailable'


def read_work_observation(config, wall_time):
    directory, owner = Path(config['monitor_directory']), config['owner_uid']
    download = read_json(directory / 'monitor-state-v1.json', owner=owner)
    awake = read_json(directory / 'awake-work-state-v1.json', owner=owner)
    if observation(download, wall_time) == 'active' or awake_observation(awake, wall_time) == 'active':
        return 'active'
    rows = None
    if awake_observation(awake, wall_time) == 'unavailable':
        try:
            rows = process_rows(owner, config.get('app_executable', DEFAULT_APP_EXECUTABLE))
        except Exception:
            pass  # A transient enumeration failure uses the existing grace.
    return work_observation(download, awake, wall_time, rows, owner,
                            config.get('app_executable', DEFAULT_APP_EXECUTABLE))


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
    executable = row.get('app_executable', DEFAULT_APP_EXECUTABLE)
    if (not isinstance(executable, str) or not Path(executable).is_absolute()
            or not executable.endswith('/MyCloudDriver.app/Contents/MacOS/PikPakDownloader')
            or '..' in Path(executable).parts):
        raise RuntimeError('Invalid app executable identity')
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
                state = read_work_observation(config, time.time())
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

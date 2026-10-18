#!/usr/bin/env python3
"""Synthetic power transitions only; these tests never change macOS power policy."""
import importlib.util
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('fullwake', Path(__file__).with_name('remote-fullwake-guard.py'))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def sample(**values):
    return {'version': 1, 'helper_pid': 42, 'updated_at': 1000,
            'values': {'is_downloading': 0, 'reception_paused': 0, **values}}


def awake(count=1, **changes):
    return {'version': 1, 'app_pid': 100, 'updated_at': 1000,
            'active_work_count': count, **changes}


def processes(operation='similarity-scan'):
    app = g.DEFAULT_APP_EXECUTABLE
    return [{'pid': 1, 'ppid': 0, 'uid': 0, 'executable': '/generated/init'},
            {'pid': 100, 'ppid': 1, 'uid': 501, 'executable': app},
            {'pid': 101, 'ppid': 100, 'uid': 501, 'executable': '/generated/intermediate'},
            {'pid': 102, 'ppid': 101, 'uid': 501, 'executable': g.helper_executable(app),
             'operation': operation}]


class MemoryStore:
    def __init__(self, events, original=None):
        self.events, self.original = events, original
    def pending(self):
        return self.original
    def save(self, original):
        self.events.append(('journal', original)); self.original = original
    def clear(self):
        self.events.append(('clear',)); self.original = None


class Power:
    def __init__(self, events, disabled=False, fullwake=False):
        self.events, self.disabled, self.fullwake = events, disabled, fullwake
        self.fail = None
    def set_disabled(self, value):
        self.events.append(('set', value))
        self.disabled = value
        if self.fail is value:
            raise RuntimeError('Simulated power command failure after application')
    def wake(self):
        self.events.append(('wake',)); self.fullwake = True
    def read(self):
        return {'sleep_disabled': self.disabled, 'fullwake': self.fullwake}


class FullWakeTests(unittest.TestCase):
    def test_numeric_app_work_schema_and_freshness(self):
        self.assertEqual(g.awake_observation(awake(2), 1000), 'active')
        self.assertEqual(g.awake_observation(awake(0), 1000), 'idle')
        self.assertEqual(g.awake_observation(awake(updated_at=995), 1000), 'active')
        self.assertEqual(g.awake_observation(awake(updated_at=1001), 1000), 'active')
        invalid = [None, [], {}, awake(version=True), awake(version=2),
                   awake(app_pid=True), awake(app_pid=0), awake(app_pid=-1),
                   awake(active_work_count=True), awake(active_work_count=-1),
                   awake(active_work_count=1.5), awake(active_work_count='1'),
                   awake(updated_at=994.9), awake(updated_at=1001.1),
                   awake(updated_at=float('nan')), awake(updated_at=float('inf')),
                   awake(updated_at=10 ** 1000)]
        for row in invalid:
            self.assertEqual(g.awake_observation(row, 1000), 'unavailable')

    def test_scan_processes_require_exact_executables_owner_and_app_ancestry(self):
        for operation in g.SCAN_OPERATIONS:
            self.assertEqual(g.scan_process_observation(processes(operation), 501), 'active')
        for operation in ['download', 'filetwin-worker', 'scan-duplicates',
                          'scan-cross-drive-duplicates', 'similarity-scan-other', '']:
            self.assertEqual(g.scan_process_observation(processes(operation), 501), 'idle')
        variants = []
        for index, field, value in [(1, 'uid', 502), (2, 'uid', 502), (3, 'uid', 502),
                                    (1, 'executable', '/generated/PikPakDownloader'),
                                    (3, 'executable', '/generated/pikpak'),
                                    (3, 'ppid', 1), (3, 'ppid', 102)]:
            rows = processes(); rows[index][field] = value; variants.append(rows)
        for rows in variants:
            self.assertEqual(g.scan_process_observation(rows, 501), 'idle')
        self.assertEqual(g.scan_process_observation([], 501), 'idle')
        rows = processes(); rows[1]['executable'] += '-other'
        self.assertEqual(g.scan_process_observation(rows, 501), 'idle')
        rows = processes(); rows[3]['executable'] += '-other'
        self.assertEqual(g.scan_process_observation(rows, 501), 'idle')

    def test_scan_process_uncertainty_is_bounded_by_existing_grace(self):
        unknown_path = processes(); unknown_path[3]['executable'] = None
        unknown_operation = processes(); unknown_operation[3]['operation'] = None
        missing_parent = processes(); missing_parent[3]['ppid'] = 999
        duplicate_pid = processes(); duplicate_pid.append(dict(duplicate_pid[-1]))
        malformed = processes(); malformed[1]['uid'] = True
        for rows in [None, {}, [None], unknown_path, unknown_operation,
                     missing_parent, duplicate_pid, malformed]:
            self.assertEqual(g.scan_process_observation(rows, 501), 'unavailable')
            policy = g.Policy()
            policy.decide(True, True, 'active', 100)
            self.assertTrue(policy.decide(True, True, 'unavailable', 119.9)[0])
            self.assertFalse(policy.decide(True, True, 'unavailable', 120)[0])

    def test_procargs_parser_retains_only_whitelisted_operation_not_private_arguments(self):
        def arguments(operation, argc=4):
            return (g.struct.pack('i', argc) + b'/generated/executable\0\0\0'
                    + b'/generated/argv-zero\0' + operation + b'\0'
                    + b'--request-file\0/generated-private-input\0GENERATED_SECRET=private\0')
        for operation in g.SCAN_OPERATIONS:
            self.assertEqual(g.scan_operation_from_procargs(arguments(operation.encode())), operation)
        self.assertEqual(g.scan_operation_from_procargs(arguments(b'download')), '')
        # A later filename or argument with the same spelling is not argv[1].
        self.assertEqual(g.scan_operation_from_procargs(arguments(b'--input') + b'similarity-scan\0'), '')
        self.assertEqual(g.scan_operation_from_procargs(arguments(b'similarity-scan', argc=1)), '')
        for raw in [None, b'', b'\0' * 3, g.struct.pack('i', 2) + b'not-terminated',
                    g.struct.pack('i', 2) + b'/generated\0\0argv-zero\0no-end',
                    b'\0' * (256 * 1024 + 1)]:
            self.assertIsNone(g.scan_operation_from_procargs(raw))

    def test_fresh_zero_app_count_supersedes_retained_paused_helpers_but_not_downloads(self):
        self.assertEqual(g.work_observation(sample(), awake(0), 1000, processes(), 501), 'idle')
        self.assertEqual(g.work_observation(sample(is_downloading=1), awake(0), 1000, processes(), 501), 'active')
        self.assertEqual(g.work_observation(sample(), awake(3), 1000, [], 501), 'active')
        self.assertEqual(g.work_observation(sample(), None, 1000, processes(), 501), 'active')
        self.assertEqual(g.work_observation(sample(), awake(updated_at=990), 1000, processes('duplicates'), 501), 'active')
        self.assertEqual(g.work_observation(sample(), None, 1000, [], 501), 'idle')
        self.assertEqual(g.work_observation(None, None, 1000, [], 501), 'unavailable')

    def test_reader_uses_owner_checked_numeric_snapshots_and_only_needed_compatibility_probe(self):
        config = {'monitor_directory': '/generated/monitor', 'owner_uid': 501}
        requested = []
        def read(path, owner):
            requested.append((path.name, owner))
            return sample() if path.name == 'monitor-state-v1.json' else awake(0)
        with mock.patch.object(g, 'read_json', side_effect=read), mock.patch.object(g, 'process_rows') as probe:
            self.assertEqual(g.read_work_observation(config, 1000), 'idle')
            self.assertEqual(requested, [('monitor-state-v1.json', 501), ('awake-work-state-v1.json', 501)])
            probe.assert_not_called()
        with mock.patch.object(g, 'read_json', side_effect=[sample(), None]), \
                mock.patch.object(g, 'process_rows', return_value=processes()) as probe:
            self.assertEqual(g.read_work_observation(config, 1000), 'active')
            probe.assert_called_once_with(501, g.DEFAULT_APP_EXECUTABLE)
        with mock.patch.object(g, 'read_json', side_effect=[sample(), None]), \
                mock.patch.object(g, 'process_rows', side_effect=RuntimeError('Generated unavailable identity')):
            self.assertEqual(g.read_work_observation(config, 1000), 'unavailable')
        with mock.patch.object(g, 'read_json', side_effect=[None, awake(1)]), \
                mock.patch.object(g, 'process_rows') as probe:
            self.assertEqual(g.read_work_observation(config, 1000), 'active')
            probe.assert_not_called()

    def test_native_process_reader_requests_only_numeric_topology_and_owned_helper_verb(self):
        import ctypes
        app, helper = g.DEFAULT_APP_EXECUTABLE, g.helper_executable(g.DEFAULT_APP_EXECUTABLE)
        paths = {100: app, 101: '/generated/intermediate', 102: helper}
        path_calls, argument_calls = [], []
        class NativeFunction:
            def __init__(self, action): self.action = action
            def __call__(self, *args): return self.action(*args)
        def path_for(pid, buffer, size):
            path_calls.append(pid)
            data = paths[pid].encode() + b'\0'
            ctypes.memmove(buffer, data, len(data))
            return len(data)
        def arguments_for(name, name_length, buffer, size_pointer, new_buffer, new_length):
            self.assertEqual(list(name), [1, 49, 102])
            self.assertEqual(name_length, 3)
            argument_calls.append(102)
            data = (g.struct.pack('i', 3) + helper.encode() + b'\0\0\0'
                    + helper.encode() + b'\0similarity-scan\0/generated-private-input\0')
            ctypes.memmove(buffer, data, len(data))
            ctypes.cast(size_pointer, ctypes.POINTER(ctypes.c_size_t)).contents.value = len(data)
            return 0
        native = SimpleNamespace(proc_pidpath=NativeFunction(path_for), sysctl=NativeFunction(arguments_for))
        topology = b'1 0 0\n100 1 501\n101 100 501\n102 101 501\n103 100 502\n'
        with mock.patch.object(g.sys, 'platform', 'darwin'), \
                mock.patch.object(ctypes, 'CDLL', return_value=native), \
                mock.patch.object(g.subprocess, 'run', return_value=SimpleNamespace(stdout=topology)) as command:
            rows = g.process_rows(501)
            self.assertEqual(g.scan_process_observation(rows, 501), 'active')
            self.assertEqual(command.call_args.args[0], ['/bin/ps', '-axo', 'pid=,ppid=,uid='])
        self.assertEqual(path_calls, [100, 101, 102])
        self.assertEqual(argument_calls, [102])
        self.assertEqual(rows[-1]['executable'], '')
        self.assertEqual(rows[-2]['operation'], 'similarity-scan')
        self.assertNotIn('arguments', rows[-2])

    def test_last_scan_completion_or_app_crash_restores_global_policy(self):
        for final_row, rows, settling in [(awake(0), processes(), 15), (None, [], 20)]:
            events = []; power = Power(events); store = MemoryStore(events)
            guard, policy = g.Guard(power, store), g.Policy()
            active = g.work_observation(sample(), awake(2), 1000, processes(), 501)
            self.assertTrue(policy.decide(True, True, active, 100)[0])
            guard.hold(power.read(), 100)
            still_active = g.work_observation(sample(), awake(1), 1000, processes(), 501)
            self.assertTrue(policy.decide(True, True, still_active, 101)[0])
            guard.hold(power.read(), 101)
            final = g.work_observation(None if final_row is None else sample(), final_row, 1000, rows, 501)
            self.assertFalse(policy.decide(True, True, final, 101 + settling)[0])
            guard.release()
            self.assertFalse(power.disabled)
            self.assertIsNone(store.pending())
            self.assertEqual(events, [('journal', False), ('set', True), ('wake',), ('set', False), ('clear',)])

    def test_config_accepts_exact_installed_app_identity_only(self):
        base = {'enabled': True, 'monitor_directory': '/generated/monitor', 'owner_uid': 501}
        with mock.patch.object(g, 'read_json', return_value=base):
            self.assertEqual(g.load_config(Path('/generated/config')), base)
        custom = {**base, 'app_executable': '/generated/MyCloudDriver.app/Contents/MacOS/PikPakDownloader'}
        with mock.patch.object(g, 'read_json', return_value=custom):
            self.assertEqual(g.load_config(Path('/generated/config')), custom)
        for executable in [None, False, 'PikPakDownloader', '/generated/other-app',
                           '/generated/../MyCloudDriver.app/Contents/MacOS/PikPakDownloader']:
            with mock.patch.object(g, 'read_json', return_value={**base, 'app_executable': executable}):
                with self.assertRaises(RuntimeError): g.load_config(Path('/generated/config'))

    def test_paused_download_retains_protection_until_saving_and_verification_drain(self):
        for key in g.WORK_KEYS:
            paused = sample(is_downloading=1, reception_paused=1, **{key: 1})
            self.assertEqual(g.observation(paused, 1000), 'active', key)
        self.assertEqual(g.observation(sample(is_downloading=1), 1000), 'active')
        self.assertEqual(g.observation(sample(), 1000), 'idle')
        self.assertEqual(g.observation(sample(is_downloading=1, reception_paused=1), 1000), 'idle')
        # A deferred file by itself may be explicitly paused. It must not keep
        # the laptop awake after its actual read/write work has drained.
        self.assertEqual(g.observation(sample(is_downloading=1, reception_paused=1,
                                             deferred_read_tasks=3000), 1000), 'idle')

    def test_missing_stale_future_and_malformed_snapshots_cannot_start_wake_protection(self):
        valid = sample(is_downloading=1)
        invalid = [None, [], {}, {**valid, 'updated_at': 994.9},
                   {**valid, 'updated_at': 1001.1}, {**valid, 'helper_pid': True},
                   {**valid, 'updated_at': float('nan')}, {**valid, 'values': []},
                   sample(is_downloading=True), sample(is_downloading=float('inf')),
                   sample(is_downloading=2), sample(reception_paused=True),
                   sample(reception_paused=2), sample(reception_paused=float('nan'))]
        policy = g.Policy()
        for row in invalid:
            self.assertEqual(g.observation(row, 1000), 'unavailable')
            self.assertFalse(policy.decide(True, True, 'unavailable', 0)[0])

    def test_completion_and_helper_crash_have_bounded_grace(self):
        for state, seconds in [('idle', 15), ('unavailable', 20)]:
            policy = g.Policy()
            self.assertEqual(policy.decide(True, True, 'active', 100), (True, 'active'))
            self.assertTrue(policy.decide(True, True, state, 100 + seconds - .01)[0])
            self.assertEqual(policy.decide(True, True, state, 100 + seconds), (False, state))
            self.assertFalse(policy.decide(True, True, state, 1000)[0])

    def test_adapter_removal_and_explicit_disable_release_immediately(self):
        for enabled, ac, reason in [(True, False, 'battery'), (False, True, 'disabled')]:
            policy = g.Policy(); policy.decide(True, True, 'active', 0)
            self.assertEqual(policy.decide(enabled, ac, 'active', 1), (False, reason))
            self.assertFalse(policy.decide(True, True, 'unavailable', 2)[0])
            self.assertTrue(policy.decide(True, True, 'active', 3)[0])

    def test_journal_precedes_override_and_confirmed_restore_precedes_clear(self):
        events = []; power = Power(events); store = MemoryStore(events); guard = g.Guard(power, store)
        guard.hold(power.read(), 0)
        self.assertEqual(events, [('journal', False), ('set', True), ('wake',)])
        events.clear()
        guard.hold(power.read(), 5)
        self.assertEqual(events, [])  # no repeated pmset writes or activity pulses
        guard.release()
        self.assertEqual(events, [('set', False), ('clear',)])
        self.assertFalse(power.disabled)

    def test_daemon_restart_recovers_original_value_before_reacquiring(self):
        events = []; power = Power(events, disabled=True); store = MemoryStore(events, original=False)
        replacement = g.Guard(power, store)
        replacement.release()
        self.assertEqual(events, [('set', False), ('clear',)])
        replacement.hold(power.read(), 0)
        self.assertIs(store.pending(), False)
        replacement.release()
        self.assertFalse(power.disabled)

    def test_activation_and_restoration_failures_retain_recovery_information(self):
        events = []; power = Power(events); store = MemoryStore(events); guard = g.Guard(power, store)
        power.fail = True
        with self.assertRaises(RuntimeError): guard.hold(power.read(), 0)
        self.assertIs(store.pending(), False)
        power.fail = False
        with self.assertRaises(RuntimeError): guard.release()
        self.assertIs(store.pending(), False)
        self.assertNotIn(('clear',), events)
        power.fail = None
        guard.release()
        self.assertFalse(power.disabled)
        self.assertIsNone(store.pending())

    def test_preexisting_external_sleep_override_is_never_owned_or_released(self):
        events = []; power = Power(events, disabled=True); store = MemoryStore(events); guard = g.Guard(power, store)
        guard.hold(power.read(), 0)
        guard.release()
        self.assertEqual(events, [('wake',)])
        self.assertTrue(power.disabled)
        self.assertIsNone(store.pending())

    def test_bounded_snapshot_reader_rejects_other_owners_symlinks_and_fifos(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); path = root / 'state.json'
            g.atomic_json(path, sample(is_downloading=1))
            self.assertEqual(g.read_json(path, owner=os.getuid()), sample(is_downloading=1))
            self.assertIsNone(g.read_json(path, owner=os.getuid() + 1))
            self.assertIsNone(g.read_json(path, limit=1))
            link = root / 'link'; link.symlink_to(path)
            self.assertIsNone(g.read_json(link))
            fifo = root / 'fifo'; os.mkfifo(fifo)
            self.assertIsNone(g.read_json(fifo))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            g.atomic_json(path, {'version': 1, 'fullwake': True}, 0o644)
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
            self.assertEqual(g.read_json(path), {'version': 1, 'fullwake': True})


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Synthetic power transitions only; these tests never change macOS power policy."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('fullwake', Path(__file__).with_name('remote-fullwake-guard.py'))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def sample(**values):
    return {'version': 1, 'helper_pid': 42, 'updated_at': 1000,
            'values': {'is_downloading': 0, 'reception_paused': 0, **values}}


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

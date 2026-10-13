#!/usr/bin/env python3
"""Show the app's anonymous payload rates without process or socket polling."""
import argparse
import collections
import datetime
import json
import math
import os
import pathlib
import stat
import sys
import time


class RollingRate:
    """Time-weighted trailing five seconds, interpolated like the app's rate."""

    def __init__(self):
        self.samples = collections.deque()

    def sample(self, now, total):
        self.samples.append((now, total))
        if len(self.samples) == 1:
            return None
        edge = now - 5.0
        while len(self.samples) > 2 and self.samples[1][0] <= edge:
            self.samples.popleft()
        base_time, base_bytes = self.samples[0]
        if base_time < edge:
            next_time, next_bytes = self.samples[1]
            fraction = (edge - base_time) / (next_time - base_time)
            base_time, base_bytes = edge, base_bytes + (next_bytes - base_bytes) * fraction
        elapsed = now - base_time
        if elapsed > 4.999:
            elapsed = 5.0
        return max(0.0, total - base_bytes) / elapsed if elapsed else 0.0


class LiveRates:
    """Reject stale snapshots and reset cleanly on helper restart or sleep."""

    def __init__(self):
        self.previous = None
        self.rolling = RollingRate()
        self.rates = None

    @property
    def window_ready(self):
        return bool(self.previous and self.rolling.samples and
                    self.previous[1] - self.rolling.samples[0][0] >= 4.999)

    def sample(self, row, now):
        keys = {"version", "helper_pid", "received_bytes", "sampled_uptime", "updated_at"}
        valid = isinstance(row, dict) and set(row) == keys
        valid = valid and type(row["version"]) is int and row["version"] == 1
        valid = valid and type(row["helper_pid"]) is int and row["helper_pid"] > 0
        valid = valid and type(row["received_bytes"]) is int and 0 <= row["received_bytes"] < 2 ** 64
        valid = valid and all(type(row[key]) in (int, float) and math.isfinite(row[key])
                              for key in ("sampled_uptime", "updated_at"))
        # GUI publication plus the coalesced writer can exceed three seconds
        # during restoration. Match the five-second gap limit, and label any
        # genuinely reset/partial window explicitly below.
        valid = valid and row["sampled_uptime"] >= 0 and -1 <= now - row["updated_at"] <= 5
        if not valid:
            self.__init__()
            return None
        pid, at, total = row["helper_pid"], row["sampled_uptime"], row["received_bytes"]
        old = self.previous
        if old and pid == old[0] and at == old[1] and total == old[2]:
            return self.rates  # Reading one snapshot twice never adds bytes.
        if old and (pid != old[0] or at <= old[1] or at - old[1] > 5 or total < old[2]):
            self.__init__()
            old = None
        current = (total - old[2]) / (at - old[1]) if old else 0.0
        self.rates = current, self.rolling.sample(at, total)
        self.previous = pid, at, total
        return self.rates


def read_live(path):
    # One private file capped at 512 bytes. Do not follow links or open FIFOs.
    descriptor = None
    try:
        flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 512:
            return None
        data = os.read(descriptor, 513)
        return json.loads(data) if len(data) <= 512 else None
    except (OSError, ValueError, UnicodeError):
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=0, help="stop after N updates; default: keep monitoring")
    parser.add_argument("--file", type=pathlib.Path, default=pathlib.Path.home() /
                        "Library/Logs/MyCloudDriver/Downloads/live-speed-v1.json",
                        help="app's private numeric live-speed snapshot")
    args = parser.parse_args()
    if args.samples < 0:
        parser.error("--samples must be zero or positive")
    rates = LiveRates()
    interactive = sys.stdout.isatty()
    updates = 0
    try:
        while True:
            started = time.monotonic()
            result = rates.sample(read_live(args.file), time.time())
            if result is None:
                line = "1s:    0.00 MB/s | 5s avg:    0.00 MB/s  (waiting for the app)"
            else:
                current, average = result
                line = "1s: %7.2f MB/s | 5s avg: %7.2f MB/s%s" % (
                    current / 1_000_000, (average or 0.0) / 1_000_000,
                    "  (warming up)" if not rates.window_ready else "")
            prefix = "\r" if interactive else datetime.datetime.now().strftime("%H:%M:%S ")
            print(prefix + line.ljust(78), end="" if interactive else "\n", flush=True)
            updates += 1
            if args.samples and updates >= args.samples:
                return 0
            time.sleep(max(0, 1.0 - (time.monotonic() - started)))
    except (KeyboardInterrupt, BrokenPipeError):
        return 0
    finally:
        if interactive:
            print()


if __name__ == "__main__":
    sys.exit(main())

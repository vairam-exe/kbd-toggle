#!/usr/bin/env python3
"""Tests for kbd-guard.py's external-keyboard count.

The guard must agree with kbd-toggle, so the same mock /dev/input by-path
scenarios run here: 0 with only the internal keyboard, 1 per physical
external keyboard, the usb/usbv2 duplicate link counting once, and an
unreadable directory resolving to None (which callers treat as "enable
the internal keyboard").

Exits non-zero on the first mismatch.
"""

import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "files", "kbd-guard.py")
TMP = os.environ["KBD_TMP"]

spec = importlib.util.spec_from_file_location("kbd_guard_test", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

failures = 0


def check(scenario, want, what):
    global failures
    guard.BYPATH = os.path.join(TMP, scenario, "input", "by-path")
    got = guard.count_external_keyboards()
    if got != want:
        failures += 1
        print(f"FAIL: {what}: expected {want!r}, got {got!r}", file=sys.stderr)


check("internal-only", 0, "internal keyboard only must count as 0 external")
check("one-external", 1, "one external keyboard")
check("two-external", 2, "two external keyboards")
check("usb-duplicate", 1, "usb/usbv2 duplicate link counts once")
check("no-internal-port", 1, "external only")
check("dead-link", 0, "dead by-path link is not counted")

# An unreadable directory must yield None (unknown), which the lock-screen
# code treats as "no external keyboard" and enables the internal keyboard.
guard.BYPATH = os.path.join(TMP, "does-not-exist")
got = guard.count_external_keyboards()
if got is not None:
    failures += 1
    print(f"FAIL: missing by-path dir must return None, got {got!r}", file=sys.stderr)
if guard.no_external_keyboard() is not True:
    failures += 1
    print("FAIL: unknown count must resolve to 'no external keyboard'", file=sys.stderr)

sys.exit(1 if failures else 0)

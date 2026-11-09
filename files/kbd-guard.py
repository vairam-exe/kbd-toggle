#!/usr/bin/env python3
"""Keep the internal laptop keyboard disabled while you are logged in.

Installed to ~/.local/bin/kbd-guard.py, run by kbd-guard.service.

Behaviour:
  - on session start   : disable the internal keyboard
  - on session end     : enable it again, so the login screen always has a
                         working keyboard
  - on screen lock     : if no external keyboard is present, enable it so you
                         can never be locked out of your own lock screen
  - on screen unlock   : restore the disabled state if the lock override fired

Every action goes through ~/.local/bin/kbd-toggle, so the external-keyboard
guard and the state verification apply here too.
"""

import os
import signal
import subprocess

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

TOGGLE = os.path.expanduser("~/.local/bin/kbd-toggle")
STATE_DIR = os.path.expanduser("~/.local/state/kbd-toggle")
OVERRIDE = os.path.join(STATE_DIR, "lock-override")
LOG = os.path.join(STATE_DIR, "guard.log")

INTERNAL_NAME = "AT Translated Set 2 keyboard"


def log(message):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(f"{message}\n")
    except OSError:
        pass


def toggle(action):
    """Run the toggle script. Never raises."""
    try:
        subprocess.run([TOGGLE, action], check=False, timeout=30)
    except Exception as exc:  # noqa: BLE001 - a failure here must not kill the guard
        log(f"toggle {action} failed: {exc}")


def external_keyboards():
    """Number of keyboards on the machine that are not the internal one."""
    try:
        result = subprocess.run(
            ["udevadm", "info", "--export-db"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception:  # noqa: BLE001
        # Unknown is treated as "there is one", which keeps the keyboard
        # disabled rather than surprising the user.
        return 1

    count = 0
    for block in result.stdout.split("\n\n"):
        if "ID_INPUT_KEYBOARD=1" in block and INTERNAL_NAME not in block:
            count += 1
    return count


def on_active_changed(_conn, _sender, _path, _iface, _signal, params):
    locked = params.unpack()[0]

    if locked:
        if external_keyboards() == 0:
            log("locked with no external keyboard: enabling internal")
            toggle("on")
            try:
                open(OVERRIDE, "w", encoding="utf-8").close()
            except OSError as exc:
                log(f"could not write override flag: {exc}")
    else:
        if os.path.exists(OVERRIDE):
            log("unlocked: restoring disabled state")
            toggle("off")
            try:
                os.remove(OVERRIDE)
            except OSError:
                pass


def on_name_appeared(connection, name, owner):
    """Subscribe only once gnome-shell actually owns the name.

    Subscribing to a well-known name before it has an owner can silently
    never fire, so we wait for the name to appear first.
    """
    log(f"{name} appeared (owner {owner}); subscribing to ActiveChanged")
    connection.signal_subscribe(
        name,
        "org.gnome.ScreenSaver",
        "ActiveChanged",
        "/org/gnome/ScreenSaver",
        None,
        Gio.DBusSignalFlags.NONE,
        on_active_changed,
    )


def main():
    toggle("off")

    Gio.bus_watch_name(
        Gio.BusType.SESSION,
        "org.gnome.ScreenSaver",
        Gio.BusNameWatcherFlags.NONE,
        on_name_appeared,
        None,
    )

    loop = GLib.MainLoop()

    def shutdown(*_args):
        log("session ending: enabling internal keyboard")
        toggle("on")
        loop.quit()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    loop.run()


if __name__ == "__main__":
    main()

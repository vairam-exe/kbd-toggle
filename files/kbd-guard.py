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
  - on hotplug         : if the last external keyboard disappears while the
                         internal one is off, enable it again

Every action goes through ~/.local/bin/kbd-toggle, so the external-keyboard
guard and the state verification apply here too.
"""

import os
import signal
import subprocess
import threading
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

TOGGLE = os.path.expanduser("~/.local/bin/kbd-toggle")
STATE_DIR = os.path.expanduser("~/.local/state/kbd-toggle")
OVERRIDE = os.path.join(STATE_DIR, "lock-override")
LOG = os.path.join(STATE_DIR, "guard.log")

# The external-keyboard count must match kbd-toggle's, which counts physical
# keyboards from /dev/input/by-path.
BYPATH = "/dev/input/by-path"
SERIO = "/sys/bus/serio/devices"
ATKBD = "/sys/bus/serio/drivers/atkbd"
PORT_DESCRIPTION = "i8042 KBD port"
INTERNAL_NAME = "AT Translated Set 2 keyboard"


def log(message):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {message}\n")
    except OSError:
        pass


def toggle(action):
    """Run the toggle script. Never raises."""
    try:
        subprocess.run([TOGGLE, action], check=False, timeout=30)
    except Exception as exc:  # noqa: BLE001 - a failure here must not kill the guard
        log(f"toggle {action} failed: {exc}")


def notify(body, urgency="critical"):
    try:
        subprocess.run(
            [
                "notify-send",
                "--app-name=Keyboard Toggle",
                "--icon=input-keyboard",
                f"--urgency={urgency}",
                "--expire-time=4000",
                "Internal keyboard",
                body,
            ],
            check=False,
            timeout=10,
        )
    except Exception:  # noqa: BLE001 - notifications are best-effort
        pass


def count_external_keyboards():
    """Number of physical keyboards that are not the internal one.

    Mirrors the logic in kbd-toggle: one physical keyboard is one event node
    found under /dev/input/by-path, the internal one hides behind the
    platform-i8042-serio-* prefix, and a USB keyboard gets two links (usb-
    and usbv2-) to the same event node.

    Returns None when the answer cannot be determined.
    """
    try:
        names = os.listdir(BYPATH)
    except OSError as exc:
        log(f"could not list {BYPATH}: {exc}")
        return None

    seen = set()
    for name in names:
        if not name.endswith("-event-kbd"):
            continue
        if "platform-i8042-serio-" in name:
            continue
        path = os.path.join(BYPATH, name)
        if not os.path.exists(path):
            continue
        seen.add(os.path.realpath(path))
    return len(seen)


def no_external_keyboard():
    """True when there is, or may be, no external keyboard.

    An unknown count resolves to "none": the alternative is refusing to
    re-enable the internal keyboard, which can lock the user out.
    """
    return count_external_keyboards() in (None, 0)


def find_port():
    """The i8042 KBD port. Never raises, returns None if it cannot be found.

    With several candidate ports, prefer the one whose input device names
    the internal keyboard.
    """
    try:
        entries = sorted(os.listdir(SERIO))
    except OSError:
        return None

    ports = []
    for entry in entries:
        if not entry.startswith("serio"):
            continue
        try:
            with open(os.path.join(SERIO, entry, "description"), encoding="ascii") as handle:
                if handle.read().strip() == PORT_DESCRIPTION:
                    ports.append(entry)
        except OSError:
            continue
    if not ports:
        return None
    if len(ports) > 1:
        log(f"WARNING: multiple i8042 KBD ports found: {ports}")

    for port in ports:
        input_dir = os.path.join(SERIO, port, "input")
        try:
            inputs = [n for n in os.listdir(input_dir) if n.startswith("input")]
        except OSError:
            continue
        for sub in inputs:
            try:
                with open(os.path.join(input_dir, sub, "name"), encoding="ascii") as handle:
                    if handle.read().strip() == INTERNAL_NAME:
                        return port
            except OSError:
                continue
    return ports[0]


def internal_enabled():
    """True if the internal keyboard is bound to atkbd, None if unknown."""
    port = find_port()
    if port is None:
        return None
    return os.path.exists(os.path.join(ATKBD, port))


def on_active_changed(_conn, _sender, _path, _iface, _signal, params):
    locked = params.unpack()[0]

    if locked:
        if no_external_keyboard():
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


_sub_id = None


def on_name_appeared(connection, name, owner):
    """Subscribe only once gnome-shell actually owns the name.

    Subscribing to a well-known name before it has an owner can silently
    never fire, so we wait for the name to appear first. gnome-shell restarts
    re-acquire the name, so without the guard every restart would pile up
    another subscription and multiply every lock event.
    """
    global _sub_id
    if _sub_id is not None:
        return
    log(f"{name} appeared (owner {owner}); subscribing to ActiveChanged")
    _sub_id = connection.signal_subscribe(
        name,
        "org.gnome.ScreenSaver",
        "ActiveChanged",
        "/org/gnome/ScreenSaver",
        None,
        Gio.DBusSignalFlags.NONE,
        on_active_changed,
    )


def on_name_vanished(connection, name):
    """Drop the subscription when the screensaver name goes away.

    The signal routes through the vanished owner's connection, so a stale
    subscription fires on the next name loss and duplicates the next one.
    """
    global _sub_id
    if _sub_id is None:
        return
    log(f"{name} vanished; unsubscribing from ActiveChanged")
    try:
        connection.signal_unsubscribe(_sub_id)
    except Exception as exc:  # noqa: BLE001 - never let cleanup kill the guard
        log(f"could not unsubscribe: {exc}")
    _sub_id = None


_monitor_proc = None
_last_hotplug_check = 0.0


def check_hotplug():
    """Re-enable the internal keyboard if the last external one is gone."""
    global _last_hotplug_check
    now = time.monotonic()
    if now - _last_hotplug_check < 2.0:
        return False
    _last_hotplug_check = now

    if not no_external_keyboard():
        return False
    if internal_enabled() is not False:
        return False

    log("no external keyboard left and internal disabled: enabling internal")
    toggle("on")
    notify("The last external keyboard was removed, so the internal keyboard "
           "was re-enabled.")
    return True


def watch_hotplug():
    """Watch input add/remove events; re-check after every event.

    Uses `udevadm monitor` as the event source, so there is no dependency on
    pyudev or GUdev bindings. Runs on a daemon thread; each event just posts
    the debounced check to the main loop.
    """
    global _monitor_proc
    try:
        _monitor_proc = subprocess.Popen(
            ["udevadm", "monitor", "--udev", "--subsystem-match=input"],
            stdout=subprocess.PIPE,
            text=True,
        )
    except Exception as exc:  # noqa: BLE001
        log(f"could not start udevadm monitor: {exc}")
        return

    try:
        for _line in _monitor_proc.stdout:
            GLib.idle_add(check_hotplug)
    except Exception as exc:  # noqa: BLE001
        log(f"udevadm monitor stopped: {exc}")


def main():
    toggle("off")

    Gio.bus_watch_name(
        Gio.BusType.SESSION,
        "org.gnome.ScreenSaver",
        Gio.BusNameWatcherFlags.NONE,
        on_name_appeared,
        on_name_vanished,
    )

    threading.Thread(target=watch_hotplug, name="kbd-hotplug", daemon=True).start()

    loop = GLib.MainLoop()

    def shutdown(*_args):
        log("session ending: enabling internal keyboard")
        toggle("on")
        if _monitor_proc is not None:
            try:
                _monitor_proc.terminate()
            except Exception:  # noqa: BLE001
                pass
        loop.quit()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    loop.run()


if __name__ == "__main__":
    main()

# Internal Keyboard Toggle

A **keyboard icon in the top bar**. Click it, flip the switch, and the laptop's
built-in keyboard turns on or off. It also turns itself **off automatically when
you log in**.

Built for `vairam-TUF-Gaming-FX505DT-FX505DT` — Ubuntu 26.04, GNOME 50 on Wayland.

---

## What you get

| Thing | What it does |
|---|---|
| Keyboard icon in the top bar | Click it for the "Internal keyboard" switch |
| Login service | Disables the keyboard automatically once you are logged in |
| Logout safety | Re-enables it when you log out, so the login screen always works |
| Lock-screen safety | If the screen locks and no external keyboard is plugged in, it turns the keyboard back on so you cannot lock yourself out |
| Crash safety | If the guard service is killed, systemd turns the keyboard back on when it stops |
| Hotplug safety | If you unplug the last external keyboard while the built-in one is off, the built-in one turns back on by itself |
| Dock icon (optional) | The same toggle, if you prefer clicking a dock icon |

The top-bar icon is **dimmed** when the keyboard is disabled and **bright** when
it is enabled, so you can tell the state without opening the menu.

Your Logitech K230 counts as an external keyboard, so the automatic disable is
allowed. If you unplug it, the tool **refuses** to disable the built-in keyboard
rather than leaving you with no keyboard at all. If you unplug it **while the
built-in keyboard is already off**, the login guard turns the built-in one back
on automatically.

---

## Install (one command)

```bash
sudo bash ~/kbd-toggle/install.sh
```

Type your password. You will see preflight checks (it verifies the i8042 port,
`bind_mode`, `notify-send`, `python3-gi` and GNOME Shell), then eight numbered
steps, then `Install complete.`

---

## Then log out and back in

**This step is required.** GNOME loads extensions only at startup and cannot
hot-load a new one on Wayland. Until you log out and back in, the top-bar icon
will not exist.

After logging back in:

1. A **keyboard icon** appears in the top bar, on the right.
2. It is **dimmed**, because the login service already disabled the keyboard.
3. Click it. You get a menu with an **Internal keyboard** switch.
4. Flip the switch on. The keyboard works again and the icon brightens.

---

## Everyday use

| You want to | Do this |
|---|---|
| Type on the laptop keyboard | Click the top-bar icon, turn the switch on |
| Go back to the external keyboard | Click the icon, turn the switch off |
| Check the state at a glance | Dimmed icon = disabled, bright = enabled |
| Use a terminal instead | `~/.local/bin/kbd-toggle status` |
| See what happened | `cat ~/.local/state/kbd-toggle/toggle.log` |

The switch always shows the **real** kernel state. The extension watches the
kernel driver directory directly and refreshes at least every 30 seconds, so it
stays correct even if you toggle from a terminal.

---

## Removing the dock icon

The dock icon still works and is a useful fallback. If you do not want it:

Right-click it in the dock and choose **Remove from Favorites**.

To put it back: press **Super**, type `Toggle Internal Keyboard`, right-click,
**Add to Favorites**.

---

## If something goes wrong

**The top-bar icon does not appear after logging in.**
Check the extension is enabled:

```bash
gnome-extensions list --enabled | grep kbd-toggle
```

If nothing prints, enable it and log out and back in again:

```bash
gnome-extensions enable kbd-toggle@vairam
```

**The switch flips back immediately.**
That is the safety guard: no external keyboard was detected. Plug the Logitech
receiver back in. The menu shows "Refused: no external keyboard detected".

**The internal keyboard turned itself back on.**
If you just unplugged the external keyboard, that is the hotplug guard: the
login re-enables the built-in keyboard so the machine is never left without
one. See `~/.local/state/kbd-toggle/guard.log` for the exact reason.

**The keyboard turns itself back on after a key press.**
That was a bug in earlier versions. Unbinding the driver is not enough on its
own, because the kernel re-probes the port on the next interrupt. Reinstall so
the helper also sets `bind_mode=manual`:

```bash
sudo bash ~/kbd-toggle/install.sh
```

**The keyboard is off and nothing responds.**
Use your Logitech keyboard and run:

```bash
sudo /usr/local/sbin/kbd-internal on
```

**No keyboard works at all.**
Reboot. The disabled state is never saved to disk, so a restart always brings
the keyboard back. This is the main reason the tool does not use a udev rule.

**The screen is locked and the keyboard is dead.**
The lock-screen guard should have handled this. If it did not, use the Logitech
keyboard, or reboot.

**Force it once with no external keyboard.**
Only if you are sure you can re-enable it with the mouse:

```bash
mkdir -p ~/.config/kbd-toggle && touch ~/.config/kbd-toggle/allow-no-external
```

---

## How it works

```
Top-bar icon  ──►  ~/.local/bin/kbd-toggle  ──►  sudo -n  ──►  /usr/local/sbin/kbd-internal
   (switch)              │                                          │
                         │                                          └─ writes to
                         │                                             /sys/bus/serio/devices/serio0/bind_mode
                         │                                             /sys/bus/serio/drivers/atkbd/{bind,unbind}
                         └─ checks state, verifies result

Login  ──►  kbd-guard.service  ──►  kbd-guard.py  ──►  kbd-toggle off
Logout ──►  kbd-guard.py stops ──►  kbd-toggle on
Lock   ──►  kbd-guard.py checks for an external keyboard
```

The keyboard is disabled by **unbinding the `atkbd` driver from the `i8042 KBD
port`**, and that alone is not enough. The kernel re-probes a serio port
whenever it receives an interrupt while no driver is bound: `serio_interrupt()`
calls `serio_rescan()`, so the first key press would make `atkbd` bind itself
straight back and the keyboard would come alive again. To prevent that, the
port's `bind_mode` is set to `manual` before the unbind, which makes
`serio_bus_match()` refuse every automatic bind. Enabling reverses both writes,
in the opposite order.

That state lives only in kernel memory. Nothing is written to
`/etc/udev/rules.d/`, which is what made the earlier attempt survive reboots and
lock you out.

---

## Uninstall

```bash
sudo bash ~/kbd-toggle/uninstall.sh
```

Then log out and back in to clear the top-bar icon.

## Developing

The regression tests cover the external-keyboard count (the safety guard's
core) and syntax-check all scripts:

```bash
bash ~/kbd-toggle/tests/run-tests.sh
```

---

## Files it installs

| Path | Owner | Purpose |
|---|---|---|
| `/usr/local/sbin/kbd-internal` | root | The only privileged part |
| `/etc/sudoers.d/kbd-toggle` | root | Lets you run that one helper, with `on`/`off`/`status` only, without a password |
| `/etc/logrotate.d/kbd-internal` | root | Keeps `/var/log/kbd-internal.log` bounded (weekly, 4 rotations) |
| `~/.local/bin/kbd-toggle` | you | Toggle logic, safety checks, notifications |
| `~/.local/bin/kbd-guard.py` | you | Login / logout / lock handling |
| `~/.config/systemd/user/kbd-guard.service` | you | Starts the guard at login |
| `~/.local/share/gnome-shell/extensions/kbd-toggle@vairam/` | you | The top-bar icon |
| `~/.local/share/applications/kbd-toggle.desktop` | you | The optional dock icon |
| `~/.local/state/kbd-toggle/*.log` | you | Logs |
| `/var/log/kbd-internal.log` | root | Helper log |

#!/usr/bin/env bash
# Installer for the internal keyboard toggle.
# Run with:  sudo bash ~/kbd-toggle/install.sh
set -euo pipefail

# Derive the target user instead of hardcoding a name. The normal way to run
# this is `sudo bash install.sh` from the user's own shell, so SUDO_USER is
# the account that should own the user-level files. KBD_TARGET_USER overrides
# it explicitly when needed.
if [ -n "${KBD_TARGET_USER:-}" ]; then
    TARGET_USER="$KBD_TARGET_USER"
elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-root}" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    echo "ERROR: this installer needs to know which user to install for."
    echo "       Run it as that user with sudo:   sudo bash $0"
    echo "       Or name the user explicitly:      sudo KBD_TARGET_USER=name bash $0"
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "ERROR: could not resolve a home directory for user '$TARGET_USER'."
    exit 1
fi

RUNTIME_DIR="/run/user/$TARGET_UID"
BUS_ADDR="unix:path=$RUNTIME_DIR/bus"
EXT_UUID="kbd-toggle@vairam"
EXT_DIR="$TARGET_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files"
REPO_DIR="$(dirname "$SRC")"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer needs root. Run it with:"
    echo "  sudo bash $0"
    exit 1
fi

if [ ! -d "$SRC" ]; then
    echo "ERROR: cannot find the 'files' directory next to this script."
    exit 1
fi

# Run a command as the target user inside their graphical session.
as_user() {
    runuser -u "$TARGET_USER" -- env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" \
        "$@"
}

# Fill in the user-dependent parts of a template file.
# $1: source template, $2: destination name
render() {
    sed -e "s|__HOME__|$TARGET_HOME|g" \
        -e "s|__DOC__|$REPO_DIR|g" \
        -e "s|__USER__|$TARGET_USER|g" \
        "$1" >"$TMPD/$2"
}

# Fail loudly, with a specific message, when the prerequisites are missing.
preflight() {
    local fatal=0 version major

    echo "==> Preflight checks (user: $TARGET_USER)"

    if grep -qs '^i8042 KBD port$' /sys/bus/serio/devices/serio*/description; then
        echo "    OK: i8042 keyboard port found"
    else
        echo "    FATAL: no i8042 KBD port under /sys/bus/serio/devices."
        echo "           This tool targets laptops with a PS/2-style internal"
        echo "           keyboard port; on this machine it cannot work."
        fatal=1
    fi

    if ls /sys/bus/serio/devices/serio*/bind_mode >/dev/null 2>&1; then
        echo "    OK: serio bind_mode is supported (kernel >= 6.11)"
    else
        echo "    WARNING: serio bind_mode is not supported (kernel < 6.11)."
        echo "             Disabling the keyboard still works, but any key press"
        echo "             makes the kernel re-enable it."
    fi

    if command -v notify-send >/dev/null 2>&1; then
        echo "    OK: notify-send found"
    else
        echo "    WARNING: notify-send not found (libnotify-bin)."
        echo "             Desktop notifications and the hotplug notice will be skipped."
    fi

    if command -v udevadm >/dev/null 2>&1; then
        echo "    OK: udevadm found"
    else
        echo "    WARNING: udevadm not found. The hotplug re-enable guard will not run."
    fi

    if python3 -c "import gi" >/dev/null 2>&1; then
        echo "    OK: python3 gi module found"
    else
        echo "    FATAL: the python3 gi module is missing (python3-gi)."
        echo "           The login guard needs it. Install it first:"
        echo "             sudo apt install python3-gi"
        fatal=1
    fi

    if command -v logrotate >/dev/null 2>&1; then
        echo "    OK: logrotate found"
    else
        echo "    WARNING: logrotate not found; the helper log will grow unbounded."
    fi

    version="$(gnome-shell --version 2>/dev/null | awk '{print $NF}')" || true
    major="$(printf '%s' "$version" | cut -d. -f1 | tr -cd '0-9')"
    if [ -n "$version" ] && [ "${major:-0}" -ge 48 ] 2>/dev/null; then
        echo "    OK: GNOME Shell $version"
    else
        echo "    WARNING: could not confirm GNOME Shell >= 48 (got '${version:-nothing}')."
        echo "             The extension targets Shell 48-50."
    fi

    if [ "$fatal" -ne 0 ]; then
        echo "ERROR: preflight found blocking problems. Nothing was installed."
        exit 1
    fi
}

preflight

echo "==> 1/8  Installing the root helper"
install -o root -g root -m 0755 "$SRC/kbd-internal" /usr/local/sbin/kbd-internal

echo "==> 2/8  Installing the sudoers rule"
render "$SRC/kbd-toggle.sudoers" sudoers
install -o root -g root -m 0440 "$TMPD/sudoers" /etc/sudoers.d/kbd-toggle
if ! visudo -c -f /etc/sudoers.d/kbd-toggle >/dev/null 2>&1; then
    echo "ERROR: the sudoers rule failed validation. Removing it."
    rm -f /etc/sudoers.d/kbd-toggle
    exit 1
fi

echo "==> 3/8  Installing your files"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/bin"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/share/applications"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/systemd/user"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/state/kbd-toggle"

install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "$SRC/kbd-toggle" "$TARGET_HOME/.local/bin/kbd-toggle"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "$SRC/kbd-guard.py" "$TARGET_HOME/.local/bin/kbd-guard.py"
render "$SRC/kbd-toggle.desktop" kbd-toggle.desktop
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
    "$TMPD/kbd-toggle.desktop" "$TARGET_HOME/.local/share/applications/kbd-toggle.desktop"
render "$SRC/kbd-guard.service" kbd-guard.service
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
    "$TMPD/kbd-guard.service" "$TARGET_HOME/.config/systemd/user/kbd-guard.service"

echo "==> 4/8  Installing the top-bar extension"
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
        "$SRC/extension/metadata.json" >/dev/null 2>&1; then
    echo "ERROR: extension/metadata.json is not valid JSON."
    exit 1
fi
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$EXT_DIR"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
    "$SRC/extension/metadata.json" "$EXT_DIR/metadata.json"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
    "$SRC/extension/extension.js" "$EXT_DIR/extension.js"

# The shell only scans the extensions directory at startup, so a freshly
# copied extension is unknown to `gnome-extensions enable`. Write the UUID
# into enabled-extensions directly; it loads at the next login.
if as_user gsettings get org.gnome.shell enabled-extensions >/dev/null 2>&1; then
    current="$(as_user gsettings get org.gnome.shell enabled-extensions)"
    case "$current" in
        *"'$EXT_UUID'"*)
            echo "    already enabled: $EXT_UUID"
            ;;
        *)
            body="${current#[}"
            body="${body%]}"
            if [ -z "$body" ]; then
                updated="['$EXT_UUID']"
            else
                updated="[$body, '$EXT_UUID']"
            fi
            as_user gsettings set org.gnome.shell enabled-extensions "$updated"
            echo "    enabled: $EXT_UUID"
            ;;
    esac
else
    echo "    WARNING: could not reach gsettings. Enable it manually after login:"
    echo "      gnome-extensions enable $EXT_UUID"
fi

echo "==> 5/8  Refreshing the application menu"
as_user update-desktop-database "$TARGET_HOME/.local/share/applications" \
    >/dev/null 2>&1 || true

echo "==> 6/8  Installing the log rotation rule"
install -o root -g root -m 0644 \
    "$SRC/kbd-internal.logrotate" /etc/logrotate.d/kbd-internal

echo "==> 7/8  Enabling the login service"
if as_user systemctl --user daemon-reload 2>/dev/null; then
    as_user systemctl --user enable kbd-guard.service >/dev/null
    echo "    enabled: kbd-guard.service"
else
    echo "    WARNING: could not reach your systemd session."
    echo "    After logging in, run:  systemctl --user enable kbd-guard.service"
fi

echo "==> 8/8  Checking the helper"
if /usr/local/sbin/kbd-internal status >/dev/null 2>&1; then
    echo "    helper works, keyboard is currently: $(/usr/local/sbin/kbd-internal status)"
else
    echo "    WARNING: the helper did not report a status. Check /var/log/kbd-internal.log"
fi

cat <<DONE

Install complete for user $TARGET_USER.

IMPORTANT: the top-bar icon only appears after you log out and back in.
GNOME loads extensions at startup and cannot hot-load a new one on Wayland.

After logging back in:
  - A keyboard icon sits in the top bar.
  - Click it for the "Internal keyboard" switch.
  - The keyboard will already be disabled by the login service.

To undo everything:  sudo bash $REPO_DIR/uninstall.sh

DONE

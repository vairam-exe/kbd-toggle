#!/usr/bin/env bash
# Installer for the internal keyboard toggle.
# Run with:  sudo bash ~/kbd-toggle/install.sh
set -euo pipefail

TARGET_USER="vairam"
TARGET_HOME="/home/vairam"
TARGET_UID="$(id -u "$TARGET_USER")"
RUNTIME_DIR="/run/user/$TARGET_UID"
BUS_ADDR="unix:path=$RUNTIME_DIR/bus"
EXT_UUID="kbd-toggle@vairam"
EXT_DIR="$TARGET_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files"

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

echo "==> 1/7  Installing the root helper"
install -o root -g root -m 0755 "$SRC/kbd-internal" /usr/local/sbin/kbd-internal

echo "==> 2/7  Installing the sudoers rule"
install -o root -g root -m 0440 "$SRC/kbd-toggle.sudoers" /etc/sudoers.d/kbd-toggle
if ! visudo -c -f /etc/sudoers.d/kbd-toggle >/dev/null 2>&1; then
    echo "ERROR: the sudoers rule failed validation. Removing it."
    rm -f /etc/sudoers.d/kbd-toggle
    exit 1
fi

echo "==> 3/7  Installing your files"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/bin"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/share/applications"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/systemd/user"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/state/kbd-toggle"

install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "$SRC/kbd-toggle" "$TARGET_HOME/.local/bin/kbd-toggle"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "$SRC/kbd-guard.py" "$TARGET_HOME/.local/bin/kbd-guard.py"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "$SRC/kbd-toggle.desktop" "$TARGET_HOME/.local/share/applications/kbd-toggle.desktop"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
    "$SRC/kbd-guard.service" "$TARGET_HOME/.config/systemd/user/kbd-guard.service"

echo "==> 4/7  Installing the top-bar extension"
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

echo "==> 5/7  Refreshing the application menu"
as_user update-desktop-database "$TARGET_HOME/.local/share/applications" \
    >/dev/null 2>&1 || true

echo "==> 6/7  Enabling the login service"
if as_user systemctl --user daemon-reload 2>/dev/null; then
    as_user systemctl --user enable kbd-guard.service >/dev/null
    echo "    enabled: kbd-guard.service"
else
    echo "    WARNING: could not reach your systemd session."
    echo "    After logging in, run:  systemctl --user enable kbd-guard.service"
fi

echo "==> 7/7  Checking the helper"
if /usr/local/sbin/kbd-internal status >/dev/null 2>&1; then
    echo "    helper works, keyboard is currently: $(/usr/local/sbin/kbd-internal status)"
else
    echo "    WARNING: the helper did not report a status. Check /var/log/kbd-internal.log"
fi

cat <<'DONE'

Install complete.

IMPORTANT: the top-bar icon only appears after you log out and back in.
GNOME loads extensions at startup and cannot hot-load a new one on Wayland.

After logging back in:
  - A keyboard icon sits in the top bar.
  - Click it for the "Internal keyboard" switch.
  - The keyboard will already be disabled by the login service.

To undo everything:  sudo bash ~/kbd-toggle/uninstall.sh

DONE

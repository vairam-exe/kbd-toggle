#!/usr/bin/env bash
# Remove the internal keyboard toggle and restore normal behaviour.
# Run with:  sudo bash ~/kbd-toggle/uninstall.sh
set -uo pipefail

# Derive the target user the same way install.sh does.
if [ -n "${KBD_TARGET_USER:-}" ]; then
    TARGET_USER="$KBD_TARGET_USER"
elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-root}" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    echo "ERROR: this uninstaller needs to know which user to uninstall for."
    echo "       Run it as that user with sudo:   sudo bash $0"
    echo "       Or name the user explicitly:      sudo KBD_TARGET_USER=name bash $0"
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"
RUNTIME_DIR="/run/user/$TARGET_UID"
BUS_ADDR="unix:path=$RUNTIME_DIR/bus"
EXT_UUID="kbd-toggle@vairam"
EXT_DIR="$TARGET_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"

if [ "$(id -u)" -ne 0 ]; then
    echo "This uninstaller needs root. Run it with:"
    echo "  sudo bash $0"
    exit 1
fi

as_user() {
    runuser -u "$TARGET_USER" -- env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" \
        "$@"
}

echo "==> Stopping the login service"
as_user systemctl --user disable --now kbd-guard.service >/dev/null 2>&1 || true
as_user systemctl --user daemon-reload >/dev/null 2>&1 || true

echo "==> Re-enabling the keyboard"
if [ -x /usr/local/sbin/kbd-internal ]; then
    /usr/local/sbin/kbd-internal on || true
fi

echo "==> Removing the top-bar extension"
if as_user gsettings get org.gnome.shell enabled-extensions >/dev/null 2>&1; then
    current="$(as_user gsettings get org.gnome.shell enabled-extensions)"
    case "$current" in
        *"'$EXT_UUID'"*)
            updated="$(printf '%s' "$current" | sed "s/, *'$EXT_UUID'//; s/'$EXT_UUID', *//; s/'$EXT_UUID'//")"
            as_user gsettings set org.gnome.shell enabled-extensions "$updated"
            ;;
    esac
fi
rm -rf "$EXT_DIR"

echo "==> Removing files"
rm -f /etc/sudoers.d/kbd-toggle
rm -f /usr/local/sbin/kbd-internal
rm -f "$TARGET_HOME/.local/bin/kbd-toggle"
rm -f "$TARGET_HOME/.local/bin/kbd-guard.py"
rm -f "$TARGET_HOME/.local/share/applications/kbd-toggle.desktop"
rm -f "$TARGET_HOME/.config/systemd/user/kbd-guard.service"
rm -rf "$TARGET_HOME/.local/state/kbd-toggle"
rm -rf "$TARGET_HOME/.config/kbd-toggle"
# The root-owned helper log, its rotation rule, and the runtime lock.
rm -f /var/log/kbd-internal.log
rm -f /etc/logrotate.d/kbd-internal
rm -f "$RUNTIME_DIR/kbd-toggle.lock"

as_user update-desktop-database "$TARGET_HOME/.local/share/applications" \
    >/dev/null 2>&1 || true

echo
echo "Removed. Your internal keyboard is enabled."
echo "Log out and back in to clear the top-bar icon."

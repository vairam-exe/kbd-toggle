// Top-bar indicator for the internal laptop keyboard.
//
// Adds a keyboard icon to the GNOME panel. Clicking it opens a menu with a
// switch that enables or disables the built-in keyboard. The switch reflects
// the real kernel state, polled from sysfs, so it stays correct even if the
// keyboard is toggled from a terminal or by the login guard.

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const TOGGLE = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'kbd-toggle']);
const ATKBD = '/sys/bus/serio/drivers/atkbd';
const SERIO = '/sys/bus/serio/devices';
const PORT_DESCRIPTION = 'i8042 KBD port';

function readText(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok)
            return null;
        return new TextDecoder().decode(bytes).trim();
    } catch (e) {
        return null;
    }
}

// Match on the port description rather than assuming serio0, which can change
// across kernel or hardware changes.
function findPort() {
    try {
        const enumerator = Gio.File.new_for_path(SERIO).enumerate_children(
            'standard::name', Gio.FileQueryInfoFlags.NONE, null);

        let info;
        while ((info = enumerator.next_file(null)) !== null) {
            const name = info.get_name();
            if (!name.startsWith('serio'))
                continue;
            if (readText(`${SERIO}/${name}/description`) === PORT_DESCRIPTION)
                return name;
        }
    } catch (e) {
        logError(e, 'kbd-toggle: could not scan serio devices');
    }
    return null;
}

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'Internal Keyboard', false);

        this._port = findPort();
        this._syncing = false;
        this._timer = 0;

        this._icon = new St.Icon({
            icon_name: 'input-keyboard-symbolic',
            style_class: 'system-status-icon',
        });
        this.add_child(this._icon);

        this._switchItem = this._buildToggleItem();
        this.menu.addMenuItem(this._switchItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._messageItem = new PopupMenu.PopupMenuItem('', {reactive: false});
        this._messageItem.visible = false;
        this.menu.addMenuItem(this._messageItem);

        this._sync();

        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this._sync();
            return GLib.SOURCE_CONTINUE;
        });
    }

    // Prefer a real switch. Fall back to a plain menu item if the switch class
    // is ever unavailable, so the extension still loads instead of throwing.
    _buildToggleItem() {
        if (PopupMenu.PopupSwitchMenuItem) {
            const item = new PopupMenu.PopupSwitchMenuItem('Internal keyboard', false);
            item.connect('toggled', (self, state) => {
                if (this._syncing)
                    return;
                this._apply(state);
            });
            return item;
        }

        const item = new PopupMenu.PopupMenuItem('Internal keyboard');
        item.connect('activate', () => {
            this._apply(this._isEnabled() !== true);
        });
        return item;
    }

    _isEnabled() {
        if (!this._port)
            this._port = findPort();
        if (!this._port)
            return null;
        return GLib.file_test(`${ATKBD}/${this._port}`, GLib.FileTest.EXISTS);
    }

    _setMessage(text) {
        this._messageItem.label.text = text;
        this._messageItem.visible = Boolean(text);
    }

    _sync() {
        const enabled = this._isEnabled();

        // setToggleState emits 'toggled', so guard against re-entering _apply.
        if (this._switchItem.setToggleState) {
            this._syncing = true;
            this._switchItem.setToggleState(enabled === true);
            this._syncing = false;
        } else {
            this._switchItem.label.text = enabled
                ? 'Internal keyboard: on'
                : 'Internal keyboard: off';
        }

        if (enabled === null) {
            this._switchItem.visible = false;
            this._icon.opacity = 120;
            this._setMessage('Keyboard port not found');
            return;
        }

        this._switchItem.visible = true;
        this._icon.opacity = enabled ? 255 : 120;
    }

    _apply(enable) {
        const action = enable ? 'on' : 'off';

        try {
            const launcher = new Gio.SubprocessLauncher({
                flags: Gio.SubprocessFlags.STDOUT_SILENCE |
                       Gio.SubprocessFlags.STDERR_SILENCE,
            });
            // The menu is the feedback, so suppress the desktop notification.
            launcher.setenv('KBD_TOGGLE_QUIET', '1', true);

            const proc = launcher.spawnv([TOGGLE, action]);
            proc.wait_check_async(null, (p, res) => {
                try {
                    p.wait_check_finish(res);
                    this._setMessage('');
                } catch (e) {
                    // Exit 3 means the safety guard refused: no external keyboard.
                    this._setMessage('Refused: no external keyboard detected');
                }
                this._sync();
            });
        } catch (e) {
            logError(e, 'kbd-toggle: could not run the toggle script');
            this._setMessage('Could not run the toggle script');
        }
    }

    destroy() {
        if (this._timer) {
            GLib.source_remove(this._timer);
            this._timer = 0;
        }
        super.destroy();
    }
});

export default class KbdToggleExtension extends Extension {
    enable() {
        this._indicator = new Indicator();
        Main.panel.addToStatusArea('kbd-toggle', this._indicator);
    }

    disable() {
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}

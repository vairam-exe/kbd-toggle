// Preferences for the internal keyboard toggle.
//
// One setting for now: how often the extension falls back to polling sysfs.
// The switch itself needs no configuration, so this stays deliberately small.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

export default class KbdTogglePreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        const page = new Adw.PreferencesPage({
            title: 'General',
            icon_name: 'preferences-system-symbolic',
        });

        const group = new Adw.PreferencesGroup({
            title: 'State tracking',
            description: 'The extension watches the kernel for changes. ' +
                'This poll is the fallback for when the watch does not fire.',
        });

        const row = new Adw.SpinRow({
            title: 'Poll interval',
            subtitle: 'Seconds between fallback checks of the keyboard state',
            adjustment: new Gtk.Adjustment({
                lower: 5,
                upper: 300,
                step_increment: 5,
                page_increment: 30,
            }),
        });
        settings.bind('poll-interval-seconds', row, 'value',
            Gio.SettingsBindFlags.DEFAULT);
        group.add(row);

        page.add(group);
        window.add(page);
    }
}

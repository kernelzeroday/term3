// term3 GNOME test tier only (term3/tests/gnome.sh); never installed.
//
// Runs inside the test's own headless GNOME Shell and:
//   - puts known text on the clipboard so super+v has something to paste,
//   - keeps the overview closed and the newest window focused, so injected
//     keys reach the terminal under test,
//   - appends shell events (the notification/calendar menu opening, the
//     overview, focus changes) as JSON lines to $T3TEST_EVENTS, timestamped
//     with the wall clock so the driver can match them to the keys it sent.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class Term3Test {
    enable() {
        const path = GLib.getenv('T3TEST_EVENTS');
        this._out = path
            ? Gio.File.new_for_path(path).append_to(Gio.FileCreateFlags.NONE, null)
            : null;

        St.Clipboard.get_default().set_text(
            St.ClipboardType.CLIPBOARD, GLib.getenv('T3TEST_CLIPBOARD') ?? 'PASTED-TEXT');

        const dm = Main.panel.statusArea.dateMenu;
        this._ids = [
            [dm.menu, dm.menu.connect('open-state-changed',
                (_m, open) => this._log(open ? 'menu-open' : 'menu-close'))],
            [Main.overview, Main.overview.connect('showing', () => this._log('overview-showing'))],
            [global.display, global.display.connect('notify::focus-window', () => {
                const w = global.display.focus_window;
                this._log('focus', w ? w.get_wm_class() : null);
            })],
            [global.stage, global.stage.connect('notify::key-focus', () => {
                const a = global.stage.key_focus;
                this._log('stage-key-focus', a ? a.constructor.name : null);
            })],
        ];

        this._tick = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, () => {
            if (Main.overview.visible && !Main.overview.animationInProgress)
                Main.overview.hide();
            if (!global.display.focus_window && !dm.menu.isOpen) {
                const wins = global.display.list_all_windows()
                    .filter(w => w.get_window_type() === 0 /* NORMAL */);
                if (wins.length)
                    wins[wins.length - 1].activate(global.get_current_time());
            }
            return GLib.SOURCE_CONTINUE;
        });
        this._log('enabled');
    }

    disable() {
        for (const [obj, id] of this._ids)
            obj.disconnect(id);
        GLib.source_remove(this._tick);
        this._out?.close(null);
    }

    _log(ev, arg = null) {
        if (!this._out)
            return;
        const line = JSON.stringify({t: GLib.get_real_time() / 1e6, ev, arg}) + '\n';
        this._out.write_all(new TextEncoder().encode(line), null);
        this._out.flush(null);
    }
}

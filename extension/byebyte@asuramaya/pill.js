// SPDX-License-Identifier: GPL-3.0-or-later
// pill.js — the family's vendored extension commons (UNIFY.md Wave A #2).
//
// One module, vendored byte-identical into each pill's extension dir as a
// sibling of extension.js (`import * as Pill from './pill.js'`), with a
// pill.version drift anchor beside it — same hash discipline as sutra.py.
// Never hand-edit a vendored copy; re-vendor.
//
// What lives here is the shape every pill repeats: the palette, the tiny
// predicates and formatters, the status.json read + staleness rule, the
// socket command writer, the menu-row helpers, the version footer + update
// row (the update spine's face), the file-monitor lifecycle, and the
// Quick Settings indicator boilerplate.
//
// What deliberately does NOT live here: domain judgement. ETA horizons
// (ByeByte thinks in weeks, RAMstein in seconds), hero/severity ranking,
// mission and stance chips, notification policy — each of those is a pill
// being itself. A commons that absorbs domain stops being a commons and
// starts being a framework; this file must stay the former.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';

export const PILL_JS_VERSION = '0.1.0';

// ---- palette (FAMILY.md doctrine #12) --------------------------------------
// The five concept colors every pill shares, plus the chip/dot button styles
// (coldspot/phanspeed's switcher idiom) so a new switcher never re-derives
// its own rounded-rect numbers.
export const PALETTE = {
    ACCENT: '#b9acff',
    DIM: '#9aa0a6',
    GOOD: '#4caf50',
    WARN: '#ffbb33',
    BAD: '#ff5b5b',
};
export const CHIP = 'border-radius:13px; padding:6px 10px; margin:0 2px; color:#dedde6;'
    + ' background-color:rgba(255,255,255,0.07);';
export const CHIP_ON = 'border-radius:13px; padding:6px 10px; margin:0 2px; color:#ffffff;'
    + ' font-weight:bold; background-color:#5b50a8;';
export const DOT = 'border-radius:9px; padding:2px 0; margin:0 3px; color:#9aa0a6;'
    + ' background-color:rgba(255,255,255,0.05);';
export const DOT_ON = 'border-radius:9px; padding:2px 0; margin:0 3px; color:#ffffff;'
    + ' font-weight:bold; background-color:#5b50a8;';

// NBSP: glues a label to its figure ("OOM ~2h") so a wrap can only land on a
// real separator (' · '), never mid-phrase — see wrapRow/iconRow below.
export const NB = ' ';

// ---- predicates + formatters ----------------------------------------------
export function isObj(v) {
    return v && typeof v === 'object' && !Array.isArray(v);
}

export function num(v) {
    return (typeof v === 'number' && isFinite(v)) ? v : null;
}

export function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
}

export function fmtBytes(n) {
    if (n == null)
        return '?';
    const units = ['B', 'K', 'M', 'G', 'T'];
    let i = 0;
    while (Math.abs(n) >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    return i === 0 ? `${Math.round(n)}B` : `${n.toFixed(1)}${units[i]}`;
}

// ---- status snapshot -------------------------------------------------------
// Read a daemon's status.json; `validate` narrows the accepted shape (e.g.
// o => Array.isArray(o.mounts)) on top of the it's-a-JSON-object floor.
export function readStatusFile(path, validate = null) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok)
            return null;
        const o = JSON.parse(new TextDecoder().decode(bytes));
        if (!isObj(o))
            return null;
        return (validate && !validate(o)) ? null : o;
    } catch (_e) {
        return null;
    }
}

// The family staleness rule: a snapshot older than three poll intervals plus
// slack means the daemon stopped updating — distinct from "not running"
// (readStatusFile returned null), and the pill should say which.
export function isStale(st, defaultPoll = 30) {
    return !!st && (GLib.get_real_time() / 1e6 - st.ts) >
        3 * (num(st.daemon?.poll_interval) ?? defaultPoll) + 5;
}

// ---- socket command --------------------------------------------------------
// Fire-and-forget JSON line to a daemon's control socket; the next status
// refresh reflects the result. `cancellable` should be the extension's
// enable()-scoped Gio.Cancellable so disable() aborts in-flight writes.
export function sendCmd(sockPath, obj, cancellable = null, tag = 'pill') {
    const client = new Gio.SocketClient();
    client.timeout = 2;
    const addr = new Gio.UnixSocketAddress({path: sockPath});
    const payload = new TextEncoder().encode(JSON.stringify(obj) + '\n');
    client.connect_async(addr, cancellable, (src, res) => {
        let conn;
        try {
            conn = src.connect_finish(res);
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                logError(e, `${tag} connect`);
            return;
        }
        conn.get_output_stream().write_all_async(
            payload, GLib.PRIORITY_DEFAULT, cancellable, (out, ores) => {
                try {
                    out.write_all_finish(ores);
                } catch (e) {
                    if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        logError(e, `${tag} write`);
                }
                conn.close_async(GLib.PRIORITY_DEFAULT, null, null);
            });
    });
}

// ---- menu rows -------------------------------------------------------------
export function row(markup) {
    const it = new PopupMenu.PopupMenuItem('', {reactive: false});
    it.label.clutter_text.set_markup(markup);
    return it;
}

// Content that can outgrow the popup's fixed width wraps to a second line
// instead of clipping mid-word — PopupMenuItem labels don't wrap by default,
// and an ellipsis silently eats whole figures.
export function wrapRow(markup) {
    const it = row(markup);
    it.label.clutter_text.set_line_wrap(true);
    it.label.clutter_text.set_ellipsize(Pango.EllipsizeMode.NONE);
    return it;
}

// Icon-led stat row — phanspeed/kast's shape: a reactive-false base item
// wrapping an St.BoxLayout, label wrapping like wrapRow.
export function iconRow(iconName, markup) {
    const it = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
    const box = new St.BoxLayout({x_expand: true});
    box.add_child(new St.Icon({icon_name: iconName, style_class: 'popup-menu-icon'}));
    const label = new St.Label({x_expand: true, style: 'margin-left: 8px;'});
    label.clutter_text.set_markup(markup);
    label.clutter_text.set_line_wrap(true);
    label.clutter_text.set_ellipsize(Pango.EllipsizeMode.NONE);
    box.add_child(label);
    it.add_child(box);
    return it;
}

// Name-first, data-flush-right row (coldspot's lists idiom): the name label
// expands so it pins flush left and pushes the variable-width data flush
// right, instead of the data's width raggedly shifting the name's start.
export function dataRow(name, dataText, onActivate = null) {
    const it = new PopupMenu.PopupBaseMenuItem({reactive: !!onActivate, can_focus: !!onActivate});
    it.add_child(new St.Label({text: name, x_expand: true}));
    it.add_child(new St.Label({
        text: dataText,
        style: `color:${PALETTE.DIM}; font-size:0.9em; padding-left:10px;`,
    }));
    if (onActivate)
        it.connect('activate', onActivate);
    return it;
}

// Best-effort toast; per the family notification spec a toast is a pointer
// to truth — the ledger/status entry it points at must already exist.
export function notify(title, body) {
    try {
        Main.notify(title, body);
    } catch (_e) {
        // no tray; skip
    }
}

// ---- version footer + update row (the update spine's face) -----------------
// The pill end of sutra_update: a dim version footer plus an update row that
// stays hidden until `<pill> update --check --json` reports a newer release,
// then installs via pkexec on tap (the polkit "click" consent tier). The
// daemon has no network; both commands run in the user session, exactly
// phanspeed's proven shape.
export class UpdateSurface {
    constructor(pill, {cancellable = null, onChanged = null} = {}) {
        this._pill = pill;
        this._cancellable = cancellable;
        this._onChanged = onChanged;
        this._latest = null;
        this._version = null;

        this.updateItem = new PopupMenu.PopupMenuItem('');
        this.updateItem.visible = false;
        this.updateItem.connect('activate', () => this.runUpdate());
        this.versionItem = new PopupMenu.PopupMenuItem('', {reactive: false});
        this._paint();
    }

    // ver = the running daemon's version (null while it's offline).
    setVersion(ver) {
        this._version = ver || null;
        this._paint();
    }

    _paint() {
        this.versionItem.label.clutter_text.set_markup(
            `<span foreground="${PALETTE.DIM}">${this._pill} ` +
            `${this._version ? `v${esc(this._version)}` : '(daemon offline)'}</span>`);
        const show = !!this._latest && this._latest !== this._version;
        this.updateItem.visible = show;
        if (show) {
            this.updateItem.label.clutter_text.set_markup(
                `<span foreground="${PALETTE.ACCENT}" font_weight="bold">` +
                `⬆ Update to v${esc(this._latest)}</span>`);
        }
    }

    checkNow() {
        let proc;
        try {
            proc = Gio.Subprocess.new(
                [this._pill, 'update', '--check', '--json'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (_e) {
            return;
        }
        proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
            let out;
            try {
                [, out] = p.communicate_utf8_finish(res);
            } catch (_e) {
                return;
            }
            let latest = null;
            try {
                const o = JSON.parse(String(out || '').trim().split('\n').pop());
                if (o && o.available && typeof o.latest === 'string')
                    latest = o.latest;
            } catch (_e) {
                latest = null;
            }
            this._latest = latest;
            this._paint();
            this._onChanged?.();
        });
    }

    // sh picks the packaged updater if present, else the source-install copy,
    // so one row works for both install layouts.
    runUpdate() {
        const cmd = `p=/usr/bin/${this._pill}-update; [ -x "$p" ] || ` +
            `p=/usr/local/bin/${this._pill}-update; exec "$p"`;
        try {
            const proc = Gio.Subprocess.new(
                ['pkexec', '/bin/sh', '-c', cmd],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
            proc.wait_async(this._cancellable, () => {
                this.checkNow();   // re-check; clears the notice when done
                this._onChanged?.();
            });
        } catch (e) {
            logError(e, `${this._pill} update`);
        }
        notify(this._pill, `Installing v${this._latest || ''}…`);
    }
}

// ---- status watcher (enable/disable lifecycle) ------------------------------
// Default mode is event-driven: the daemon writes status.json with an atomic
// rename, which lands here as one CREATED/CHANGES_DONE event per poll, plus
// a slow fallback tick that catches daemon death (no events, status goes
// stale) and monitor misses across /run recreation on reboot. Pass
// `pollSeconds` instead for plain interval polling (a pill whose refresh
// also drives non-file state, e.g. coldspot's notification edge detection).
export class StatusWatcher {
    constructor(path, onChange, {fallbackSeconds = 60, pollSeconds = null} = {}) {
        this._monitor = null;
        this._monitorId = null;
        if (pollSeconds == null) {
            this._file = Gio.File.new_for_path(path);
            this._monitor = this._file.monitor_file(Gio.FileMonitorFlags.NONE, null);
            this._monitorId = this._monitor.connect('changed', (_m, _f, _of, ev) => {
                if (ev === Gio.FileMonitorEvent.CHANGES_DONE_HINT ||
                    ev === Gio.FileMonitorEvent.CREATED ||
                    ev === Gio.FileMonitorEvent.RENAMED)
                    onChange();
            });
        }
        this._timeout = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, pollSeconds ?? fallbackSeconds, () => {
                onChange();
                return GLib.SOURCE_CONTINUE;
            });
    }

    destroy() {
        if (this._timeout) {
            GLib.source_remove(this._timeout);
            this._timeout = null;
        }
        if (this._monitor) {
            if (this._monitorId)
                this._monitor.disconnect(this._monitorId);
            this._monitor.cancel();
            this._monitor = null;
            this._monitorId = null;
        }
        this._file = null;
    }
}

// ---- Quick Settings indicator boilerplate -----------------------------------
const PillIndicator = GObject.registerClass(
class PillIndicator extends SystemIndicator {
});

// enable(): const ind = addQuickSettingsToggle(new MyToggle());
export function addQuickSettingsToggle(toggle) {
    const ind = new PillIndicator();
    ind.quickSettingsItems.push(toggle);
    Main.panel.statusArea.quickSettings.addExternalIndicator(ind);
    return ind;
}

// disable(): destroys the toggle(s) and the indicator; callers null their ref.
export function removeIndicator(ind) {
    ind?.quickSettingsItems.forEach(i => i.destroy());
    ind?.destroy();
}

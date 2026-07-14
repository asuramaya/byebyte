// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 asuramaya and ByeByte contributors
//
// ByeByte — storage as a deadline, not a percentage, in a GNOME Quick
// Settings pill. Reads the daemon's status snapshot; M1 is read-only
// (the purge/ballast levers arrive with M3 and will talk to the socket).

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const STATUS_PATH = '/run/byebyte/status.json';

const ICON = 'drive-harddisk-symbolic';

// concept palette (family)
const ACCENT = '#b9acff';
const DIM = '#9aa0a6';
const GOOD = '#4caf50';
const WARN = '#ffbb33';
const BAD = '#ff5b5b';

const STATE_COLOR = {ok: GOOD, warn: WARN, hot: BAD, edquot: BAD};
const STATE_MARK = {ok: '', warn: '⚠ ', hot: '‼ ', edquot: '✗ '};

function isObj(v) {
    return v && typeof v === 'object' && !Array.isArray(v);
}
function num(v) {
    return (typeof v === 'number' && isFinite(v)) ? v : null;
}
function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
}
function fmtBytes(n) {
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
function fmtBurn(bps) {
    const perDay = (bps ?? 0) * 86400;
    if (Math.abs(perDay) < 1024 * 1024)
        return 'quiet';
    return `${fmtBytes(perDay)}/day`;
}
function fmtEta(s) {
    if (s == null)
        return '—';
    if (s >= 14 * 86400)
        return `~${Math.floor(s / (7 * 86400))}w`;
    if (s >= 2 * 86400)
        return `~${Math.floor(s / 86400)}d`;
    if (s >= 2 * 3600)
        return `~${Math.floor(s / 3600)}h`;
    return `~${Math.max(1, Math.floor(s / 60))}m`;
}
// severity order for picking the tile's hero mount
const RANK = {ok: 0, warn: 1, hot: 2, edquot: 3};

function readStatus() {
    try {
        const [ok, bytes] = GLib.file_get_contents(STATUS_PATH);
        if (!ok)
            return null;
        const o = JSON.parse(new TextDecoder().decode(bytes));
        return isObj(o) && Array.isArray(o.mounts) ? o : null;
    } catch (_e) {
        return null;
    }
}

const ByeByteToggle = GObject.registerClass(
class ByeByteToggle extends QuickMenuToggle {
    _init() {
        super._init({title: 'ByeByte', iconName: ICON, toggleMode: false});
        this.menu.setHeader(ICON, 'ByeByte', 'bytes at rest');

        // alert banner — hidden until a mount is warn/hot/edquot
        this._alertSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._alertSection);

        // one row per mount, rebuilt on refresh (mounts come and go)
        this._mountSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._mountSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._versionItem = new PopupMenu.PopupMenuItem('', {reactive: false});
        this.menu.addMenuItem(this._versionItem);

        // M1 has nothing to toggle; a click is a free instant refresh
        this.connect('clicked', () => this.refresh());
    }

    refresh() {
        const st = readStatus();
        const stale = st && (GLib.get_real_time() / 1e6 - st.ts) >
            3 * (num(st.daemon?.poll_interval) ?? 30) + 5;
        if (!st || stale) {
            this.subtitle = stale ? 'status stale' : 'daemon offline';
            this.checked = false;
            this._alertSection.removeAll();
            this._mountSection.removeAll();
            const it = new PopupMenu.PopupMenuItem(
                stale ? 'byebyted stopped updating' : 'byebyted not running',
                {reactive: false});
            this._mountSection.addMenuItem(it);
            this._setVersion(null);
            return;
        }
        this._apply(st);
    }

    _apply(st) {
        const mounts = st.mounts.filter(isObj);

        // tile: the worst mount is the hero; ties go to the biggest burn
        let hero = null;
        for (const m of mounts) {
            if (!hero || (RANK[m.state] ?? 0) > (RANK[hero.state] ?? 0) ||
                ((RANK[m.state] ?? 0) === (RANK[hero.state] ?? 0) &&
                 (m.burn_bps ?? 0) > (hero.burn_bps ?? 0)))
                hero = m;
        }
        if (hero) {
            const eta = hero.eta_seconds != null ? ` · ${fmtEta(hero.eta_seconds)}` : '';
            this.subtitle = `${STATE_MARK[hero.state] ?? ''}` +
                `${fmtBytes(hero.effective_free)}${eta}`;
        } else {
            this.subtitle = 'no mounts';
        }
        // the heat: pill lights accent whenever anything is warn or worse
        this.checked = !!hero && (RANK[hero.state] ?? 0) >= 1;

        // alert banner: quota/hot mounts get their own loud line
        this._alertSection.removeAll();
        for (const m of mounts) {
            if ((RANK[m.state] ?? 0) < 1)
                continue;
            const it = new PopupMenu.PopupMenuItem('', {reactive: false});
            const why = m.state === 'edquot'
                ? 'quota exhausted'
                : (m.quota && m.effective_free < m.free
                    ? `quota: ${fmtBytes(m.quota.remaining)} left`
                    : `full ${fmtEta(m.eta_seconds)}`);
            it.label.clutter_text.set_markup(
                `<span foreground="${STATE_COLOR[m.state]}">` +
                `${STATE_MARK[m.state]}${esc(m.mountpoint)} — ${esc(why)}</span>`);
            this._alertSection.addMenuItem(it);
        }

        // per-mount rows: mountpoint, effective free, burn, deadline
        this._mountSection.removeAll();
        for (const m of mounts) {
            const it = new PopupMenu.PopupMenuItem('', {reactive: false});
            const color = STATE_COLOR[m.state] ?? DIM;
            const quota = m.quota
                ? `  <span foreground="${DIM}">[q ${fmtBytes(m.quota.remaining)}]</span>`
                : '';
            it.label.clutter_text.set_markup(
                `<span foreground="${color}" font_weight="bold">●</span> ` +
                `${esc(m.mountpoint)}  ` +
                `<span foreground="${ACCENT}">${fmtBytes(m.effective_free)}</span>` +
                `<span foreground="${DIM}"> of ${fmtBytes(m.total)} · ` +
                `${esc(fmtBurn(m.burn_bps))} · full ${fmtEta(m.eta_seconds)}</span>` +
                quota);
            this._mountSection.addMenuItem(it);
        }

        const heroSub = hero ? this.subtitle : 'bytes at rest';
        this.menu.setHeader(ICON, 'ByeByte', heroSub);
        this._setVersion(st.daemon?.version);
    }

    _setVersion(ver) {
        this._versionItem.label.clutter_text.set_markup(
            `<span foreground="${DIM}">byebyte ${ver ? `v${esc(ver)}` : '(daemon offline)'}</span>`);
    }
});

const ByeByteIndicator = GObject.registerClass(
class ByeByteIndicator extends SystemIndicator {
    _init() {
        super._init();
        this.toggle = new ByeByteToggle();
        this.quickSettingsItems.push(this.toggle);
    }
});

export default class ByeByteExtension extends Extension {
    enable() {
        this._indicator = new ByeByteIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
        this._indicator.toggle.refresh();

        // event-driven: the daemon writes status.json with an atomic rename,
        // which lands here as exactly one CREATED/CHANGES_DONE event per poll
        this._file = Gio.File.new_for_path(STATUS_PATH);
        this._monitor = this._file.monitor_file(Gio.FileMonitorFlags.NONE, null);
        this._monitorId = this._monitor.connect('changed', (_m, _f, _of, ev) => {
            if (ev === Gio.FileMonitorEvent.CHANGES_DONE_HINT ||
                ev === Gio.FileMonitorEvent.CREATED ||
                ev === Gio.FileMonitorEvent.RENAMED)
                this._indicator.toggle.refresh();
        });
        // slow fallback tick: catches daemon death (no events, status goes
        // stale) and monitor misses across /run recreation on reboot
        this._timeout = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 60, () => {
            this._indicator.toggle.refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
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
        this._indicator?.quickSettingsItems.forEach(i => i.destroy());
        this._indicator?.destroy();
        this._indicator = null;
    }
}

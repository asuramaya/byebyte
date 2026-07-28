// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 asuramaya and ByeByte contributors
//
// ByeByte — storage as a deadline, not a percentage, in a GNOME Quick
// Settings pill. Reads the daemon's status snapshot; talks to the socket
// for the purge/ballast/sweep levers.

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {QuickMenuToggle} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import * as Pill from './pill.js';

const STATUS_PATH = '/run/byebyte/status.json';
const {PALETTE} = Pill;
const {DIM, ACCENT} = PALETTE;

const ICON = 'drive-harddisk-symbolic';

const STATE_COLOR = {ok: PALETTE.GOOD, warn: PALETTE.WARN, hot: PALETTE.BAD, edquot: PALETTE.BAD};
const STATE_MARK = {ok: '', warn: '⚠ ', hot: '‼ ', edquot: '✗ '};

function fmtBurn(bps) {
    const perDay = (bps ?? 0) * 86400;
    if (Math.abs(perDay) < 1024 * 1024)
        return 'quiet';
    return `${Pill.fmtBytes(perDay)}/day`;
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

// V2.M2: when snapshots pin a big enough slice of a btrfs mount, the free-
// space number alone is misleading — the walk can't see that data, but it's
// real and only a snapshot deletion (M4 policy territory) frees it. 20% of
// the mount's total is the "dominates" bar for re-skinning the subtitle.
const BTRFS_DOMINATES_FRAC = 0.2;

function btrfsNote(m) {
    const b = m.btrfs;
    if (!Pill.isObj(b) || !b.available || !b.snapshots)
        return null;
    const pinned = Pill.num(b.pinned_bytes);
    if (pinned == null)
        return null;
    return {pinned, dominates: Pill.num(m.total) != null &&
                               pinned >= BTRFS_DOMINATES_FRAC * m.total};
}

function readStatus() {
    return Pill.readStatusFile(STATUS_PATH, o => Array.isArray(o.mounts));
}

// re-check cadence for the pill's own "update available" row — independent
// of byebyte-update.timer (which only notifies/logs, never paints the UI).
// GitHub's unauthenticated rate limit (60/h) has no trouble with this.
const UPDATE_CHECK_SECONDS = 6 * 3600;

const ByeByteToggle = GObject.registerClass(
class ByeByteToggle extends QuickMenuToggle {
    _init(cancellable) {
        super._init({title: 'ByeByte', iconName: ICON, toggleMode: false});
        this.menu.setHeader(ICON, 'ByeByte', 'bytes at rest');

        // alert banner — hidden until a mount is warn/hot/edquot
        this._alertSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._alertSection);

        // one row per mount, rebuilt on refresh (mounts come and go)
        this._mountSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._mountSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._update = new Pill.UpdateSurface('byebyte', {cancellable});
        this.menu.addMenuItem(this._update.updateItem);
        this.menu.addMenuItem(this._update.versionItem);

        // a click is a free instant refresh
        this.connect('clicked', () => this.refresh());
    }

    refresh() {
        const st = readStatus();
        const stale = Pill.isStale(st);
        if (!st || stale) {
            this.subtitle = stale ? 'status stale' : 'daemon offline';
            this.checked = false;
            this._alertSection.removeAll();
            this._mountSection.removeAll();
            const it = new PopupMenu.PopupMenuItem(
                stale ? 'byebyted stopped updating' : 'byebyted not running',
                {reactive: false});
            this._mountSection.addMenuItem(it);
            this._update.setVersion(null);
            return;
        }
        this._apply(st);
    }

    _apply(st) {
        const mounts = st.mounts.filter(Pill.isObj);

        // tile: the worst mount is the hero; ties go to the biggest burn
        let hero = null;
        for (const m of mounts) {
            if (!hero || (RANK[m.state] ?? 0) > (RANK[hero.state] ?? 0) ||
                ((RANK[m.state] ?? 0) === (RANK[hero.state] ?? 0) &&
                 (m.burn_bps ?? 0) > (hero.burn_bps ?? 0)))
                hero = m;
        }
        const heroBtrfs = hero ? btrfsNote(hero) : null;
        if (hero && heroBtrfs?.dominates) {
            // re-skin: free-space alone is misleading when snapshots pin
            // most of what's "used" — lead with the pinned number instead
            this.subtitle = `${STATE_MARK[hero.state] ?? ''}` +
                `${Pill.fmtBytes(heroBtrfs.pinned)} snapshot-pinned`;
        } else if (hero) {
            const eta = hero.eta_seconds != null ? ` · ${fmtEta(hero.eta_seconds)}` : '';
            this.subtitle = `${STATE_MARK[hero.state] ?? ''}` +
                `${Pill.fmtBytes(hero.effective_free)}${eta}`;
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
                    ? `quota: ${Pill.fmtBytes(m.quota.remaining)} left`
                    : `full ${fmtEta(m.eta_seconds)}`);
            it.label.clutter_text.set_markup(
                `<span foreground="${STATE_COLOR[m.state]}">` +
                `${STATE_MARK[m.state]}${Pill.esc(m.mountpoint)} — ${Pill.esc(why)}</span>`);
            this._alertSection.addMenuItem(it);
        }

        // per-mount rows: mountpoint, effective free, burn, deadline
        this._mountSection.removeAll();
        for (const m of mounts) {
            const it = new PopupMenu.PopupMenuItem('', {reactive: false});
            const color = STATE_COLOR[m.state] ?? DIM;
            const quota = m.quota
                ? `  <span foreground="${DIM}">[q ${Pill.fmtBytes(m.quota.remaining)}]</span>`
                : '';
            const btrfs = btrfsNote(m);
            const snap = btrfs
                ? `  <span foreground="${DIM}">[snap pin ${Pill.fmtBytes(btrfs.pinned)}]</span>`
                : '';
            it.label.clutter_text.set_markup(
                `<span foreground="${color}" font_weight="bold">●</span> ` +
                `${Pill.esc(m.mountpoint)}  ` +
                `<span foreground="${ACCENT}">${Pill.fmtBytes(m.effective_free)}</span>` +
                `<span foreground="${DIM}"> of ${Pill.fmtBytes(m.total)} · ` +
                `${Pill.esc(fmtBurn(m.burn_bps))} · full ${fmtEta(m.eta_seconds)}</span>` +
                quota + snap);
            this._mountSection.addMenuItem(it);
        }

        const heroSub = hero ? this.subtitle : 'bytes at rest';
        this.menu.setHeader(ICON, 'ByeByte', heroSub);
        this._update.setVersion(st.daemon?.version);
    }

    checkForUpdate() {
        this._update.checkNow();
    }
});

export default class ByeByteExtension extends Extension {
    enable() {
        this._cancellable = new Gio.Cancellable();
        this._toggle = new ByeByteToggle(this._cancellable);
        this._indicator = Pill.addQuickSettingsToggle(this._toggle);
        this._toggle.refresh();
        this._toggle.checkForUpdate();

        this._watcher = new Pill.StatusWatcher(
            STATUS_PATH, () => this._toggle.refresh(), {fallbackSeconds: 60});
        this._updateTimeout = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, UPDATE_CHECK_SECONDS, () => {
                this._toggle.checkForUpdate();
                return GLib.SOURCE_CONTINUE;
            });
    }

    disable() {
        this._cancellable?.cancel();
        this._cancellable = null;
        if (this._updateTimeout) {
            GLib.source_remove(this._updateTimeout);
            this._updateTimeout = null;
        }
        this._watcher?.destroy();
        this._watcher = null;
        Pill.removeIndicator(this._indicator);
        this._indicator = null;
        this._toggle = null;
    }
}

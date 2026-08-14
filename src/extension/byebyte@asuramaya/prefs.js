// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 asuramaya and byebyte contributors
//
// byebyte Settings — the "set once, forget" knobs that don't belong in the
// Quick Settings popup: reserved blocks per mount, journal cap, fstrim
// schedule, tmp size. GNOME's own extension-preferences mechanism (kast's
// own "Kast Settings…" is the reference — this.openPreferences() + this
// file, no separate app or packaging surface). The popup stays pure
// observation (msg 4427 via Alfred: "the popup shows every fact about what
// the system is doing right now ... the window shows what you've asked
// for"); this window is where you go looking to change any of it. The
// PENDING divergence for tmp-size stays in the popup, not here — see
// extension.js's own tmpPendingBadge.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

const STATUS_PATH = '/run/byebyte/status.json';

// Same preset vocabulary the popup rendered as SEGMENT chips before this
// split. journal-cap: common journald.conf SystemMaxUse= values. tmp-size:
// same order of magnitude as ramstein's own SWAP_SIZE_PRESETS (same class
// of resource, tmpfs sizing vs swap-file sizing) — own judgment call.
const RESERVE_PRESETS = [1, 5, 10, 20];
const JOURNAL_CAP_PRESETS = ['100M', '500M', '1G', '2G'];
const TMP_SIZE_PRESETS = ['2G', '4G', '8G', '16G'];

// Same PATH-independence reasoning as extension.js's own byebyteCli(): the
// preferences window is a separate GNOME-spawned process with no guarantee
// of inheriting a shell PATH that includes /usr/local/bin.
let _byebyteCliPath = null;
function byebyteCli() {
    if (_byebyteCliPath)
        return _byebyteCliPath;
    for (const p of ['/usr/bin/byebyte', '/usr/local/bin/byebyte']) {
        if (GLib.file_test(p, GLib.FileTest.IS_EXECUTABLE)) {
            _byebyteCliPath = p;
            return _byebyteCliPath;
        }
    }
    _byebyteCliPath = 'byebyte';
    return _byebyteCliPath;
}

// Fire-and-forget subprocess, same query+response shape as extension.js's
// runByebyteJson — no cancellable to thread through here, though: a prefs
// window has no long-lived actor whose disable() should cancel in-flight
// calls the way the popup's toggle does, so a plain null cancellable is
// the right shape (kast's own prefs.js runCli() makes the same call).
function runByebyteJson(args, onDone) {
    try {
        const proc = Gio.Subprocess.new(
            [byebyteCli(), ...args],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        proc.communicate_utf8_async(null, null, (p, res) => {
            let parsed = null;
            try {
                const [, stdout] = p.communicate_utf8_finish(res);
                parsed = JSON.parse(stdout);
            } catch (e) {
                logError(e, 'byebyte prefs: JSON parse failed');
            }
            onDone(parsed);
        });
    } catch (e) {
        logError(e, 'byebyte prefs: subprocess failed');
        onDone(null);
    }
}

// Read once at window-open time, not watched live — this window shows what
// you've asked for, not a live feed (that's the popup's job). Matches
// kast's own prefs.js scope exactly (its readConf()/getMode() are also
// one-shot reads on fillPreferencesWindow, no GFileMonitor).
function readStatus() {
    try {
        const [ok, bytes] = GLib.file_get_contents(STATUS_PATH);
        if (!ok)
            return null;
        const doc = JSON.parse(new TextDecoder().decode(bytes));
        return Array.isArray(doc.mounts) ? doc : null;
    } catch (_e) {
        return null;
    }
}

function fmtBytes(n) {
    if (n == null)
        return '?';
    const units = ['B', 'K', 'M', 'G', 'T'];
    let v = n, i = 0;
    while (Math.abs(v) >= 1024 && i < units.length - 1) {
        v /= 1024;
        i++;
    }
    return `${i === 0 || v >= 100 ? Math.round(v) : v.toFixed(1)}${units[i]}`;
}

export default class ByeBytePreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const page = new Adw.PreferencesPage({
            title: 'byebyte',
            icon_name: 'drive-harddisk-symbolic',
        });
        window.add(page);

        const st = readStatus();
        if (!st) {
            page.add(new Adw.PreferencesGroup({
                description: 'byebyted is not running, or has stopped updating — ' +
                    'start it and reopen Settings.',
            }));
            return;
        }

        const mounts = st.mounts.filter(m => m && typeof m === 'object');
        const pill = st.pill ?? null;
        const reserveMounts = mounts.filter(m => m.reserved_percent != null);

        // --- reserved blocks, one row per mount tune2fs -m accounting
        // actually applies to (ext2/3/4) -- absent entirely otherwise,
        // same "not applicable, not zero" principle the popup badge uses.
        if (reserveMounts.length > 0) {
            const reserved = new Adw.PreferencesGroup({
                title: 'Reserved blocks',
                description: 'Percent of each filesystem held back from ordinary ' +
                    'writes (tune2fs -m). Affects what the pill counts as "free".',
            });
            page.add(reserved);
            for (const m of reserveMounts)
                reserved.add(this._buildReserveRow(m));
        }

        // --- journal cap / fstrim schedule / tmp size ---
        const housekeeping = new Adw.PreferencesGroup({
            title: 'Disk housekeeping',
            description: "journald's log footprint, the weekly TRIM timer, and " +
                "/tmp's own tmpfs cap.",
        });
        page.add(housekeeping);
        housekeeping.add(this._buildJournalCapRow(pill?.journal_cap));
        housekeeping.add(this._buildFstrimRow(pill?.fstrim_schedule));
        housekeeping.add(this._buildTmpSizeRow(pill?.tmp_size));
    }

    _buildReserveRow(m) {
        const current = Math.round(m.reserved_percent);
        const row = new Adw.ComboRow({
            title: m.mountpoint,
            subtitle: `${current}% reserved`,
            model: Gtk.StringList.new(RESERVE_PRESETS.map(p => `${p}%`)),
        });
        const idx = RESERVE_PRESETS.indexOf(current);
        row.selected = idx >= 0 ? idx : Gtk.INVALID_LIST_POSITION;
        row.connect('notify::selected', () => {
            const pct = RESERVE_PRESETS[row.selected];
            if (pct == null || pct === current)
                return;
            row.subtitle = 'applying…';
            runByebyteJson(['reserve', m.mountpoint, String(pct), '--yes', '--json'], doc => {
                if (!doc || doc.error) {
                    row.subtitle = doc?.error || 'reserve failed — daemon unreachable';
                    return;
                }
                row.subtitle = doc.ok
                    ? `${doc.prior_percent}% → ${doc.new_percent}% reserved (confirmed)`
                    : `reserve to ${doc.new_percent}% did not take effect`;
            });
        });
        return row;
    }

    _buildJournalCapRow(journalCap) {
        const current = journalCap?.current_cap ?? null;
        const row = new Adw.ComboRow({
            title: 'Journal cap',
            subtitle: current ? `currently ${current}` : 'currently uncapped',
            model: Gtk.StringList.new(JOURNAL_CAP_PRESETS),
        });
        const idx = JOURNAL_CAP_PRESETS.indexOf(current);
        row.selected = idx >= 0 ? idx : Gtk.INVALID_LIST_POSITION;
        row.connect('notify::selected', () => {
            const size = JOURNAL_CAP_PRESETS[row.selected];
            if (size == null || size === current)
                return;
            row.subtitle = 'applying…';
            runByebyteJson(['journal-cap', size, '--yes', '--json'], doc => {
                if (!doc || doc.error) {
                    row.subtitle = doc?.error || 'journal-cap failed — daemon unreachable';
                    return;
                }
                const freed = doc.freed_bytes;
                const tail = freed ? `, freed ${fmtBytes(Math.max(freed, 0))}` : '';
                row.subtitle = `${doc.prior_cap ?? 'uncapped'} → ${doc.new_cap}${tail}`;
            });
        });
        return row;
    }

    // TOGGLE: Adw.SwitchRow, the family's own stock widget for this
    // affordance (ramstein's oomd/zram rows use PopupSwitchMenuItem in the
    // popup; this is the Adwaita preferences-window equivalent). `enabled
    // === null` means fstrim.timer doesn't exist on this system — an
    // absent unit gets plain explanatory text instead of a dead switch,
    // same treatment the popup used to give it.
    _buildFstrimRow(fstrimSchedule) {
        const enabled = fstrimSchedule?.enabled ?? null;
        if (enabled === null) {
            return new Adw.ActionRow({
                title: 'fstrim schedule',
                subtitle: 'fstrim.timer not found on this system',
            });
        }
        const row = new Adw.SwitchRow({
            title: 'fstrim schedule',
            subtitle: 'weekly TRIM via the stock fstrim.timer',
        });
        row.active = enabled;
        // Guards against the synchronous notify::active re-entry that
        // reverting row.active on failure would otherwise trigger.
        let applying = false;
        row.connect('notify::active', () => {
            if (applying)
                return;
            const state = row.active;
            runByebyteJson(['fstrim-schedule', state ? 'on' : 'off', '--yes', '--json'], doc => {
                if (!doc || doc.error) {
                    row.subtitle = doc?.error || 'fstrim-schedule failed — daemon unreachable';
                    applying = true;
                    row.active = !state;
                    applying = false;
                    return;
                }
                row.subtitle = `${doc.new_enabled ? 'enabled' : 'disabled'} (confirmed live)`;
            });
        });
        return row;
    }

    // PENDING (decision 3b31bc10): the write is instant, but /tmp is never
    // remounted by this verb, so the toast/subtitle here must never claim
    // the effective size changed — only that the new cap was set. The
    // live divergence itself is NOT duplicated here; it stays on /tmp's
    // own row in the popup (extension.js's tmpPendingBadge) since that's
    // an observation, not a setting (msg 4427 via Alfred).
    _buildTmpSizeRow(tmpSize) {
        const configured = tmpSize?.configured_cap ?? null;
        const row = new Adw.ComboRow({
            title: 'tmp size',
            subtitle: configured ? `currently ${configured}` : 'no cap set by byebyte',
            model: Gtk.StringList.new(TMP_SIZE_PRESETS),
        });
        const idx = TMP_SIZE_PRESETS.indexOf(configured);
        row.selected = idx >= 0 ? idx : Gtk.INVALID_LIST_POSITION;
        row.connect('notify::selected', () => {
            const size = TMP_SIZE_PRESETS[row.selected];
            if (size == null || size === configured)
                return;
            row.subtitle = 'applying…';
            runByebyteJson(['tmp-size', size, '--yes', '--json'], doc => {
                if (!doc || doc.error) {
                    row.subtitle = doc?.error || 'tmp-size failed — daemon unreachable';
                    return;
                }
                row.subtitle = `${doc.prior_cap ?? 'default'} → ${doc.new_cap} ` +
                    '(takes effect at next reboot or manual remount)';
            });
        });
        return row;
    }
}

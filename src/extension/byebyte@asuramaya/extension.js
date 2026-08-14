// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 asuramaya and byebyte contributors
//
// byebyte — storage as a deadline, not a percentage, in a GNOME Quick
// Settings pill. Reads the daemon's status snapshot; talks to the socket
// for the purge/ballast/sweep levers.

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

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

// reserved-blocks SEGMENT presets (Part 4) — percent values offered as chips
const RESERVE_PRESETS = [1, 5, 10, 20];

// layer-3 SEGMENT presets (msg 3502 via Alfred). journal-cap: common
// journald.conf SystemMaxUse= values. tmp-size: same order of magnitude as
// ramstein's own SWAP_SIZE_PRESETS (same class of resource, tmpfs sizing
// vs swap-file sizing) — own judgment call, not copied from any spec.
const JOURNAL_CAP_PRESETS = ['100M', '500M', '1G', '2G'];
const TMP_SIZE_PRESETS = ['2G', '4G', '8G', '16G'];

// Parses a byebyte size string (digits + optional K/M/G/T, byebyted's own
// _SIZE_RE) into bytes, 1024-based — the same convention systemd's own
// tmpfs Options=size= and journald's SystemMaxUse= both use. Needed only
// to compare tmp-size's CONFIGURED cap against its EFFECTIVE live total
// (decision 3b31bc10) — reserve's percent chips never needed this, they
// compare against a plain integer already.
function bytesFromSizeStr(s) {
    const m = typeof s === 'string' ? /^(\d+)([KMGT]?)$/.exec(s) : null;
    if (!m)
        return null;
    const mult = {'': 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4}[m[2]];
    return parseInt(m[1], 10) * mult;
}

// ---- byebyte CLI subprocess: query+response (as opposed to Pill.sendCmd's
// fire-and-forget socket write) — the established family pattern for verbs
// whose result the pill actually waits on and renders (kast's readKastJson).
// Packaging can land the CLI in /usr/bin or /usr/local/bin depending on deb
// vs from-source install, and GNOME Shell's own process doesn't necessarily
// inherit a shell PATH that includes /usr/local/bin (phanspeed's
// UpdateSurface.runUpdate hit the same problem) — check both explicitly,
// bare-string PATH lookup only as the last resort.
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

// Runs `byebyte <args>` and parses stdout as JSON — kast's readKastJson
// shape: always calls onDone exactly once, with the parsed doc or null on
// any failure (spawn, communicate, or parse).
function runByebyteJson(args, cancellable, onDone) {
    try {
        const proc = Gio.Subprocess.new(
            [byebyteCli(), ...args],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        proc.communicate_utf8_async(null, cancellable, (p, res) => {
            let parsed = null;
            try {
                const [, stdout] = p.communicate_utf8_finish(res);
                parsed = JSON.parse(stdout);
            } catch (e) {
                logError(e, 'byebyte: JSON parse failed');
            }
            onDone(parsed);
        });
    } catch (e) {
        logError(e, 'byebyte: subprocess failed');
        onDone(null);
    }
}

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

// A mount earns a standing row in the default view when it's the root
// filesystem (the one everyone thinks of first) or already in trouble.
// Everything else — /boot, /boot/efi, a waydroid image mount, an idle
// /dev/shm — folds under "N more mounts ▸": still fully reachable, just
// not making the pill read like a `mount` dump every time it opens
// (operator design review, 2026-08-14: "shrink it by 70%, more like
// phanspeed/kast"). A folded mount promotes into the default list, with
// its own Reclaim ▸, the moment it stops being healthy — the fold is a
// "nothing to see right now" claim, not a wall.
function isSignificantMount(m) {
    return m.mountpoint === '/' || (RANK[m.state] ?? 0) >= 1;
}

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
        super._init({title: 'byebyte', iconName: ICON, toggleMode: false});
        this.menu.setHeader(ICON, 'byebyte', 'bytes at rest');
        this._cancellable = cancellable;

        // alert banner — hidden until a mount is warn/hot/edquot
        this._alertSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._alertSection);

        // one row per SIGNIFICANT mount (root, or already in trouble),
        // rebuilt on refresh (mounts come and go). Everything else lives
        // in _moreMountsItem, folded by default.
        this._mountSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._mountSection);

        // "N more mounts ▸" — the fold for mounts nobody needs to see by
        // default (see isSignificantMount). Same row shape as the default
        // list, minus Reclaim (a folded mount essentially never has
        // anything worth declaring — it's system-owned, not user files;
        // `byebyte why <mount>` stays the CLI escape hatch for the rare
        // case it does). Single persistent item, hidden when nothing folds.
        this._moreMountsItem = new PopupMenu.PopupSubMenuMenuItem('more mounts ▸');
        this._moreMountsItem.visible = false;
        this.menu.addMenuItem(this._moreMountsItem);

        // Reclaim ▸ pick-lists — ONE persistent PopupSubMenuMenuItem per
        // SIGNIFICANT mountpoint, never blanket-removeAll()'d on a routine
        // refresh the way _mountSection above is. refresh() fires every
        // poll_interval (~30s) via Pill.StatusWatcher regardless of user
        // action; a user who's ticked boxes here and paused to think must
        // not have them silently destroyed by the next automatic tick.
        // _apply() diffs this map against the significant-mount list
        // instead of rebuilding it.
        this._reclaimSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._reclaimSection);
        this._reclaimItems = new Map();   // mountpoint -> {item, built, rows, footerItem, commitItem}

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        // Advanced ▸ — every "set once, forget" knob in one place: reserved
        // blocks per mount (Part 4's SEGMENT, no longer inline under each
        // mount row) plus the three layer-3 system controls (msg 3502 via
        // Alfred). None of these change on their own and none earn a
        // standing row every time the pill opens — phanspeed's own
        // "Advanced ›" is the reference shape (operator design review,
        // 2026-08-14). Rebuilt every refresh; only the place moved.
        this._advancedItem = new PopupMenu.PopupSubMenuMenuItem('Advanced ▸');
        this.menu.addMenuItem(this._advancedItem);

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
            this._moreMountsItem.visible = false;
            this._moreMountsItem.menu.removeAll();
            this._advancedItem.menu.removeAll();
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
            // most of what's "used" — lead with the pinned number instead.
            // Mountpoint prefixed (Part 5): with 2+ mounts a bare figure
            // doesn't say which one it's about.
            this.subtitle = `${STATE_MARK[hero.state] ?? ''}${hero.mountpoint} ` +
                `${Pill.fmtBytes(heroBtrfs.pinned)} snapshot-pinned`;
        } else if (hero) {
            const eta = hero.eta_seconds != null ? ` · ${fmtEta(hero.eta_seconds)}` : '';
            this.subtitle = `${STATE_MARK[hero.state] ?? ''}${hero.mountpoint} ` +
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

        // per-mount rows: root and anything in trouble show by default;
        // everything else folds under "N more mounts ▸" (isSignificantMount)
        const significant = mounts.filter(isSignificantMount);
        const folded = mounts.filter(m => !isSignificantMount(m));

        this._mountSection.removeAll();
        for (const m of significant)
            this._mountSection.addMenuItem(this._buildMountRow(m));

        this._moreMountsItem.menu.removeAll();
        if (folded.length === 0) {
            this._moreMountsItem.visible = false;
        } else {
            this._moreMountsItem.visible = true;
            this._moreMountsItem.label.text =
                `${folded.length} more mount${folded.length === 1 ? '' : 's'} ▸`;
            for (const m of folded)
                this._moreMountsItem.menu.addMenuItem(this._buildMountRow(m));
        }

        // Reclaim ▸ pick-lists: only for SIGNIFICANT mounts — a folded mount
        // promotes here the moment it stops being healthy. Diffed against
        // the live significant-mount list instead of rebuilding — see the
        // _init() note by _reclaimSection. A mount present in both keeps
        // its existing submenu (ticks and all) completely untouched; only
        // appearing/disappearing mounts change anything here.
        const reclaimMountpoints = new Set(significant.map(m => m.mountpoint));
        for (const [mp, rec] of this._reclaimItems) {
            if (!reclaimMountpoints.has(mp)) {
                rec.item.destroy();
                this._reclaimItems.delete(mp);
            }
        }
        for (const m of significant) {
            if (!this._reclaimItems.has(m.mountpoint)) {
                const rec = this._createReclaimItem(m.mountpoint);
                this._reclaimSection.addMenuItem(rec.item);
                this._reclaimItems.set(m.mountpoint, rec);
            }
        }

        this._renderAdvanced(mounts, st.pill ?? null);

        const heroSub = hero ? this.subtitle : 'bytes at rest';
        this.menu.setHeader(ICON, 'byebyte', heroSub);
        this._update.setVersion(st.daemon?.version);
    }

    // Shared row shape for both the default list and the "N more mounts ▸"
    // fold — mountpoint, effective free, burn, deadline. No reserve strip
    // inline any more (Part 4's original shape) — reserved% moved into
    // Advanced ▸ with the rest of the "set once" knobs.
    _buildMountRow(m) {
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
        return it;
    }

    // ---- Advanced ▸: every "set once, forget" knob in one place ------------
    // reserved% per mount (Part 4's SEGMENT, grouped here instead of inline
    // under each mount row) plus the three layer-3 system controls (msg
    // 3502 via Alfred). Rebuilt every refresh — none of this holds
    // in-progress user state the way Reclaim's ticked selections do, same
    // reasoning the old flat _systemSection used.
    _renderAdvanced(mounts, pill) {
        const menu = this._advancedItem.menu;
        menu.removeAll();

        // reserved-blocks SEGMENT — only for mounts the daemon could
        // actually read a reserved_percent for (ext2/3/4 + tune2fs
        // readable); absent/null means "not applicable", not "0%", same
        // principle the old inline placement used. Every such mount, not
        // just the significant ones — Advanced is the complete view.
        const reserveMounts = mounts.filter(m => m.reserved_percent != null);
        for (const m of reserveMounts)
            menu.addMenuItem(this._buildReserveStrip(m));
        if (reserveMounts.length > 0)
            menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        if (!pill) {
            menu.addMenuItem(new PopupMenu.PopupMenuItem(
                'daemon status unavailable', {reactive: false}));
            return;
        }
        menu.addMenuItem(this._buildJournalCapRow(pill.journal_cap));
        menu.addMenuItem(this._buildFstrimScheduleRow(pill.fstrim_schedule));
        for (const row of this._buildTmpSizeRows(pill.tmp_size))
            menu.addMenuItem(row);
    }

    // ---- Part 4: reserve's SEGMENT strip -----------------------------------

    _buildReserveStrip(m) {
        const mountpoint = m.mountpoint;
        // reserved_percent can be a float (5.03) from the block-count-
        // truncation math the daemon documents — round for the highlight
        // comparison, don't require exact float equality.
        const current = Math.round(m.reserved_percent);
        const box = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const layout = new St.BoxLayout({x_expand: true});
        // mountpoint-labeled now that this strip lives in Advanced ▸ rather
        // than directly under its own mount's row — "reserved" alone would
        // be ambiguous once several strips sit next to each other.
        const lab = new St.Label({
            text: `reserved (${mountpoint})`, style: `color:${DIM}; padding-right:8px;`});
        lab.y_align = 2;   // Clutter.ActorAlign.CENTER
        layout.add_child(lab);
        for (const pct of RESERVE_PRESETS) {
            const btn = new St.Button({
                label: `${pct}%`, x_expand: true, can_focus: true,
                style: pct === current ? Pill.CHIP_ON : Pill.CHIP,
            });
            btn.connect('clicked', () => this._onReserveClick(mountpoint, pct));
            layout.add_child(btn);
        }
        box.add_child(layout);
        return box;
    }

    _onReserveClick(mountpoint, pct) {
        runByebyteJson(
            ['reserve', mountpoint, String(pct), '--yes', '--json'], this._cancellable,
            doc => {
                if (!doc || doc.error) {
                    Pill.notify('byebyte', doc?.error || 'reserve failed — daemon unreachable');
                    return;
                }
                if (doc.ok) {
                    const delta = doc.avail_delta_bytes;
                    const sign = (delta ?? 0) >= 0 ? '+' : '-';
                    const deltaText = delta != null
                        ? `${sign}${Pill.fmtBytes(Math.abs(delta))}` : '?';
                    Pill.notify('byebyte', `${mountpoint}: ${doc.prior_percent}% → ` +
                        `${doc.new_percent}% reserved (${deltaText} free)`);
                } else {
                    // tune2fs ran but statvfs proved nothing moved — the
                    // daemon's own honest failure case (reserve()'s "ok"
                    // computation), not something we infer client-side.
                    Pill.notify('byebyte',
                        `${mountpoint}: reserve to ${doc.new_percent}% did not take effect`);
                }
                // no forced extra status.json refresh — the chip highlight
                // catches up on the next routine poll, which is correct:
                // the toast already reported the daemon's own verified
                // result, this is just the card's own measurement lagging
                // a little, honestly.
            });
    }

    // ---- layer-3 system controls: journal-cap/tmp-size (SEGMENT) and
    // fstrim-schedule (TOGGLE) — msg 3502 via Alfred. System-wide, not
    // per-mount, so one build per refresh rather than one per mount like
    // the reserve strip above. Reads pill.{journal_cap,fstrim_schedule,
    // tmp_size} from the digest (byebyted's build_pill_summary) rather
    // than making its own socket/subprocess call just to know what to
    // highlight — same reasoning as the reserve strip's reserved_percent.
    // Rendered inside _renderAdvanced above; the builders below stay
    // standalone functions since nothing else about them changed.

    _buildJournalCapRow(journalCap) {
        const current = journalCap?.current_cap ?? null;
        const box = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const layout = new St.BoxLayout({x_expand: true});
        const lab = new St.Label({text: 'journal cap', style: `color:${DIM}; padding-right:8px;`});
        lab.y_align = 2;   // Clutter.ActorAlign.CENTER
        layout.add_child(lab);
        for (const size of JOURNAL_CAP_PRESETS) {
            const btn = new St.Button({
                label: size, x_expand: true, can_focus: true,
                style: size === current ? Pill.CHIP_ON : Pill.CHIP,
            });
            btn.connect('clicked', () => this._onJournalCapClick(size));
            layout.add_child(btn);
        }
        box.add_child(layout);
        return box;
    }

    _onJournalCapClick(size) {
        runByebyteJson(['journal-cap', size, '--yes', '--json'], this._cancellable, doc => {
            if (!doc || doc.error) {
                Pill.notify('byebyte', doc?.error || 'journal-cap failed — daemon unreachable');
                return;
            }
            const freed = Pill.num(doc.freed_bytes);
            const tail = freed ? `, freed ${Pill.fmtBytes(Math.max(freed, 0))}` : '';
            Pill.notify('byebyte',
                `journal cap: ${doc.prior_cap ?? 'uncapped'} → ${doc.new_cap}${tail}`);
            // no forced refresh — same reasoning as reserve, the digest
            // catches up on the next routine poll
        });
    }

    // TOGGLE: PopupMenu.PopupSwitchMenuItem, GNOME's own stock widget —
    // ramstein's own shape for oomd/zram (msg 3502 cites it as the family
    // reference), no bespoke widget needed. `enabled === null` means
    // fstrim.timer doesn't exist on this system (byebyted's own
    // _systemctl_is_enabled convention) — an absent unit gets the same
    // actionable-text-instead-of-a-dead-switch treatment ramstein's zram
    // row uses for a missing systemd-zram-generator.
    _buildFstrimScheduleRow(fstrimSchedule) {
        const enabled = fstrimSchedule?.enabled ?? null;
        if (enabled === null) {
            const it = new PopupMenu.PopupMenuItem('', {reactive: false});
            it.label.clutter_text.set_markup(
                `<span foreground="${DIM}">fstrim schedule: fstrim.timer not found on this system</span>`);
            return it;
        }
        const it = new PopupMenu.PopupSwitchMenuItem('fstrim schedule (weekly TRIM)', enabled);
        it.connect('toggled', (_item, state) => this._onFstrimToggle(state));
        return it;
    }

    _onFstrimToggle(state) {
        runByebyteJson(['fstrim-schedule', state ? 'on' : 'off', '--yes', '--json'],
            this._cancellable, doc => {
                if (!doc || doc.error) {
                    Pill.notify('byebyte', doc?.error || 'fstrim-schedule failed — daemon unreachable');
                    this.refresh();   // switch reverts to the real state
                    return;
                }
                Pill.notify('byebyte',
                    `fstrim schedule ${doc.new_enabled ? 'enabled' : 'disabled'} (confirmed live)`);
            });
    }

    // PENDING (decision 3b31bc10, the fourth affordance beside SEGMENT/
    // TOGGLE/BOUNDED-WAIT): tmp-size's write is instant but /tmp is never
    // remounted by the verb, so CONFIGURED (the drop-in byebyte last wrote,
    // or the vendor unit's own size= if byebyte has never touched it) and
    // EFFECTIVE (live_total_bytes, a real statvfs("/tmp") read) can
    // genuinely diverge. The UI contract is binding: render BOTH, visibly
    // distinct, whenever they differ — never collapse to a single value
    // that would read as "done" when it isn't. When a reboot/manual
    // remount lands, configuredBytes and liveBytes converge on their own
    // and this collapses back to one line, with nothing here having to be
    // told that happened.
    _buildTmpSizeRows(tmpSize) {
        const configured = tmpSize?.configured_cap ?? null;
        const liveBytes = Pill.num(tmpSize?.live_total_bytes);
        const configuredBytes = bytesFromSizeStr(configured);
        // configuredBytes is null both when nothing's configured AND when
        // the vendor unit's own default is a percentage (e.g. "50%" — this
        // family's own tmp.mount fixture, and Ubuntu/Debian's real stock
        // default) that bytesFromSizeStr can't parse. Either way there is
        // no proof of divergence to show — a false "pending" would be
        // exactly the drift class this affordance exists to prevent, just
        // inverted (claiming a change is in flight when none was ever
        // requested). Only claim pending when both sides are comparable
        // numbers and they actually differ.
        const pending = configuredBytes != null && liveBytes != null &&
            configuredBytes !== liveBytes;

        const status = new PopupMenu.PopupMenuItem('', {reactive: false});
        const nowText = liveBytes != null ? Pill.fmtBytes(liveBytes) : '?';
        status.label.clutter_text.set_markup(pending
            ? `<span foreground="${DIM}">/tmp: </span>${Pill.esc(nowText)}` +
              `<span foreground="${DIM}"> now — </span>${Pill.esc(configured)}` +
              `<span foreground="${DIM}"> after reboot</span>`
            : `<span foreground="${DIM}">/tmp: </span>${Pill.esc(nowText)}`);

        const box = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const layout = new St.BoxLayout({x_expand: true});
        const lab = new St.Label({text: 'tmp size', style: `color:${DIM}; padding-right:8px;`});
        lab.y_align = 2;
        layout.add_child(lab);
        for (const size of TMP_SIZE_PRESETS) {
            const btn = new St.Button({
                label: size, x_expand: true, can_focus: true,
                style: size === configured ? Pill.CHIP_ON : Pill.CHIP,
            });
            btn.connect('clicked', () => this._onTmpSizeClick(size));
            layout.add_child(btn);
        }
        box.add_child(layout);
        return [status, box];
    }

    _onTmpSizeClick(size) {
        runByebyteJson(['tmp-size', size, '--yes', '--json'], this._cancellable, doc => {
            if (!doc || doc.error) {
                Pill.notify('byebyte', doc?.error || 'tmp-size failed — daemon unreachable');
                return;
            }
            // PENDING: the write succeeded, but /tmp is never remounted by
            // this verb — the toast must never claim the effective size
            // changed, only that the new cap was set (ruling 3b31bc10)
            const live = Pill.num(doc.live_total_bytes);
            const liveText = live != null ? `, still ${Pill.fmtBytes(live)} now` : '';
            Pill.notify('byebyte',
                `/tmp cap: ${doc.prior_cap ?? 'default'} → ${doc.new_cap} ` +
                `(after reboot${liveText})`);
            // no forced refresh — same reasoning as reserve/journal-cap
        });
    }

    // ---- Part 3: declare's Reclaim ▸ pick-list ------------------------------

    _createReclaimItem(mountpoint) {
        const item = new PopupMenu.PopupSubMenuMenuItem(`Reclaim on ${mountpoint} ▸`);
        const rec = {item, built: false, rows: new Map(), footerItem: null, commitItem: null};
        // lazy build on first expand only — never refetch on later opens;
        // "↻ Refresh list" inside is the only other way this repopulates.
        item.menu.connect('open-state-changed', (_menu, open) => {
            if (open && !rec.built) {
                rec.built = true;
                this._populateReclaimList(mountpoint, rec);
            }
        });
        return rec;
    }

    _addReclaimRefreshRow(mountpoint, rec, menu) {
        const refresh = new PopupMenu.PopupMenuItem('↻ Refresh list');
        refresh.connect('activate', () => this._populateReclaimList(mountpoint, rec));
        menu.addMenuItem(refresh);
    }

    _populateReclaimList(mountpoint, rec) {
        const menu = rec.item.menu;
        menu.removeAll();
        rec.rows = new Map();
        rec.footerItem = null;
        rec.commitItem = null;
        menu.addMenuItem(Pill.row(`<span foreground="${DIM}">loading…</span>`));
        this._addReclaimRefreshRow(mountpoint, rec, menu);

        runByebyteJson(['why', mountpoint, '--json'], this._cancellable, doc => {
            // The mount may have vanished (unplugged) while this was in
            // flight — this rec's item may already be destroyed, and a
            // fresh (or no) entry may sit in _reclaimItems now; touching
            // the dead actor here would throw, so bail instead.
            if (this._reclaimItems.get(mountpoint) !== rec)
                return;
            this._renderReclaimList(mountpoint, rec, doc);
        });
    }

    _renderReclaimList(mountpoint, rec, doc) {
        const menu = rec.item.menu;
        menu.removeAll();
        rec.rows = new Map();
        rec.footerItem = null;
        rec.commitItem = null;

        if (!doc || doc.error) {
            const msg = doc?.error || 'could not reach the daemon';
            menu.addMenuItem(new PopupMenu.PopupMenuItem(msg, {reactive: false}));
            this._addReclaimRefreshRow(mountpoint, rec, menu);
            return;
        }

        const rows = Array.isArray(doc.rows) ? doc.rows : [];
        if (rows.length === 0) {
            menu.addMenuItem(new PopupMenu.PopupMenuItem(
                '(nothing above the index threshold here)', {reactive: false}));
        } else {
            // already sorted biggest-first and limited by the daemon
            // (default 15) — no client-side re-limiting.
            for (const r of rows) {
                if (!r || typeof r.path !== 'string')
                    continue;
                const bytes = Pill.num(r.bytes) ?? 0;
                rec.rows.set(r.path, {bytes, selected: false});
                const it = Pill.dataRow(r.path, Pill.fmtBytes(bytes), () => {
                    const s = rec.rows.get(r.path);
                    s.selected = !s.selected;
                    it.setOrnament(s.selected ? PopupMenu.Ornament.CHECK : PopupMenu.Ornament.NONE);
                    this._updateReclaimFooter(rec);
                });
                it.setOrnament(PopupMenu.Ornament.NONE);
                menu.addMenuItem(it);
            }
        }

        rec.footerItem = new PopupMenu.PopupMenuItem('', {reactive: false});
        menu.addMenuItem(rec.footerItem);

        rec.commitItem = new PopupMenu.PopupMenuItem('');
        rec.commitItem.connect('activate', () => this._commitReclaim(mountpoint, rec));
        menu.addMenuItem(rec.commitItem);

        this._addReclaimRefreshRow(mountpoint, rec, menu);
        this._updateReclaimFooter(rec);
    }

    _updateReclaimFooter(rec) {
        if (!rec.footerItem)
            return;
        let n = 0, bytes = 0;
        for (const s of rec.rows.values()) {
            if (s.selected) {
                n++;
                bytes += s.bytes;
            }
        }
        rec.footerItem.label.clutter_text.set_markup(
            `<span foreground="${DIM}">` +
            (n === 0 ? 'Selected: none' : `Selected: ${n} · ${Pill.esc(Pill.fmtBytes(bytes))}`) +
            '</span>');
        if (!rec.commitItem)
            return;
        if (n === 0) {
            rec.commitItem.visible = false;
        } else {
            rec.commitItem.visible = true;
            rec.commitItem.reactive = true;
            rec.commitItem.label.text =
                `Reclaim selected — ${Pill.fmtBytes(bytes)} (${n} path${n === 1 ? '' : 's'})`;
        }
    }

    // Deletes every ticked path, one declare() at a time (sequential — no
    // overlapping daemon writes to reason about), then toasts the daemon's
    // own verified totals and refreshes the list against reality.
    _commitReclaim(mountpoint, rec) {
        const paths = [];
        for (const [path, s] of rec.rows) {
            if (s.selected)
                paths.push(path);
        }
        if (paths.length === 0)
            return;
        if (rec.commitItem) {
            rec.commitItem.reactive = false;
            rec.commitItem.label.text = 'declaring…';
        }

        let freedBytes = 0, skipped = 0, failed = 0;
        const runNext = i => {
            if (i >= paths.length) {
                const total = paths.length;
                const plural = total === 1 ? '' : 's';
                let summary;
                if (skipped === 0 && failed === 0) {
                    summary = `Reclaimed ${Pill.fmtBytes(freedBytes)} (${total} path${plural})`;
                } else {
                    const notes = [];
                    if (skipped)
                        notes.push(`${skipped} skipped — changed since selected`);
                    if (failed)
                        notes.push(`${failed} failed`);
                    summary = `Reclaimed ${Pill.fmtBytes(freedBytes)} of ${total} ` +
                        `path${plural} (${notes.join(', ')})`;
                }
                Pill.notify('byebyte', summary);
                // refresh against reality: whatever's left now that some
                // paths are gone (this is a harmless no-op if the mount
                // itself vanished in the meantime)
                if (this._reclaimItems.get(mountpoint) === rec)
                    this._populateReclaimList(mountpoint, rec);
                return;
            }
            runByebyteJson(['declare', paths[i], '--yes', '--json'], this._cancellable, doc => {
                if (doc && doc.ok)
                    freedBytes += Pill.num(doc.bytes) ?? 0;
                else if (doc && doc.skipped)
                    skipped++;
                else
                    failed++;
                runNext(i + 1);
            });
        };
        runNext(0);
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

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 asuramaya and byebyte contributors
//
// byebyte — storage as a deadline, not a percentage, in a GNOME Quick
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

// Parses a byebyte size string (digits + optional K/M/G/T, byebyted's own
// _SIZE_RE) into bytes, 1024-based — the same convention systemd's own
// tmpfs Options=size= and journald's SystemMaxUse= both use. Needed only
// to compare tmp-size's CONFIGURED cap against its EFFECTIVE live total
// (decision 3b31bc10) for the PENDING badge on /tmp's own row — the SEGMENT
// chips that used to live here moved to Settings (prefs.js) along with
// reserved%/journal-cap/fstrim-schedule (msg 4427 via Alfred: the popup
// stays observation, the window is where you go looking to configure).
function bytesFromSizeStr(s) {
    const m = typeof s === 'string' ? /^(\d+)([KMGT]?)$/.exec(s) : null;
    if (!m)
        return null;
    const mult = {'': 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4}[m[2]];
    return parseInt(m[1], 10) * mult;
}

// PENDING (decision 3b31bc10, the fourth affordance beside SEGMENT/TOGGLE/
// BOUNDED-WAIT): tmp-size's write is instant but /tmp is never remounted by
// the verb, so CONFIGURED and EFFECTIVE can genuinely diverge. This fact
// stays on /tmp's own mount row even though the tmp-size KNOB moved to
// Settings — "the popup shows every fact about what the system is doing
// right now, including 'you asked for something it hasn't done yet'"
// (Alfred, msg 4427). Never renders a single value that would read as
// "done" when it isn't; converges back to nothing shown, on its own, once
// a reboot/remount actually lands — no code has to be told that happened.
function tmpPendingBadge(pill) {
    const tmpSize = pill?.tmp_size;
    const configured = tmpSize?.configured_cap ?? null;
    const liveBytes = Pill.num(tmpSize?.live_total_bytes);
    const configuredBytes = bytesFromSizeStr(configured);
    // configuredBytes is null both when nothing's configured AND when the
    // vendor unit's own default is a percentage bytesFromSizeStr can't
    // parse — either way there's no proof of divergence, so no badge
    // (same reasoning the old inline chip strip used).
    const pending = configuredBytes != null && liveBytes != null &&
        configuredBytes !== liveBytes;
    if (!pending)
        return '';
    return `  <span foreground="${DIM}">[cap ${Pill.esc(configured)} @reboot]</span>`;
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
    _init(cancellable, onPrefs) {
        super._init({title: 'byebyte', iconName: ICON, toggleMode: false});
        this.menu.setHeader(ICON, 'byebyte', 'bytes at rest');
        this._cancellable = cancellable;
        this._onPrefs = onPrefs;

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
        // list, PLUS its own Reclaim ▸ per folded mount — a fold may hide a
        // mount, it must never hide the one lever that fixes it (Alfred,
        // msg 4508). Two sub-sections inside, same split as the top level:
        // _moreMountsRowsSection is cheap display rows, rebuilt every poll;
        // _moreMountsReclaimSection holds the persistent Reclaim items,
        // diffed like _reclaimSection below rather than rebuilt. Single
        // persistent outer item, hidden when nothing folds.
        this._moreMountsItem = new PopupMenu.PopupSubMenuMenuItem('more mounts ▸');
        this._moreMountsItem.visible = false;
        this._moreMountsRowsSection = new PopupMenu.PopupMenuSection();
        this._moreMountsItem.menu.addMenuItem(this._moreMountsRowsSection);
        this._moreMountsReclaimSection = new PopupMenu.PopupMenuSection();
        this._moreMountsItem.menu.addMenuItem(this._moreMountsReclaimSection);
        this.menu.addMenuItem(this._moreMountsItem);

        // Reclaim ▸ pick-lists — ONE persistent PopupSubMenuMenuItem per
        // mountpoint (significant OR folded), never blanket-removeAll()'d on
        // a routine refresh the way _mountSection above is. refresh() fires
        // every poll_interval (~30s) via Pill.StatusWatcher regardless of
        // user action; a user who's ticked boxes here and paused to think
        // must not have them silently destroyed by the next automatic tick.
        // _apply() diffs this map against the live mount list instead of
        // rebuilding it — see the reclaimMountpoints/rec.section handling
        // there for the one case (a mount crossing the significance
        // boundary mid-selection) this can't preserve, and why.
        this._reclaimSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._reclaimSection);
        this._reclaimItems = new Map();   // mountpoint -> {item, section, built, rows, footerItem, commitItem}

        // Read-only observation rows for the two knobs that moved to
        // Settings but have no OTHER row reporting their effective state
        // (Alfred's test, msg 4447: "a control may leave the popup only if
        // the popup retains an independent observation of that
        // subsystem's effective state"). reserved%/tmp-size pass without
        // this — their numbers already live on a mount's own row. journal
        // cap and fstrim schedule have no mount to piggyback on and no
        // other trace anywhere in the card, so each gets one compact line
        // here instead. Not a fold, not interactive — just the fact.
        this._systemSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._systemSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        // "byebyte Settings…" — every "set once, forget" knob (reserved%
        // per mount, journal cap, fstrim schedule, tmp size) lives in
        // GNOME's own extension-preferences window (prefs.js), not the
        // popup. Kast's own shape (msg 4419/4427 via Alfred): the popup is
        // pure observation, the window is where you go looking to
        // configure. The one exception is tmp-size's PENDING divergence,
        // which stays on /tmp's own row below — see tmpPendingBadge.
        this.menu.addAction('byebyte Settings…', () => this._onPrefs?.());

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
            this._moreMountsRowsSection.removeAll();
            this._moreMountsReclaimSection.removeAll();
            this._reclaimSection.removeAll();
            this._reclaimItems.clear();
            this._systemSection.removeAll();
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
        const pill = st.pill ?? null;
        const significant = mounts.filter(isSignificantMount);
        const folded = mounts.filter(m => !isSignificantMount(m));

        this._mountSection.removeAll();
        for (const m of significant)
            this._mountSection.addMenuItem(this._buildMountRow(m, pill));

        this._moreMountsRowsSection.removeAll();
        if (folded.length === 0) {
            this._moreMountsItem.visible = false;
        } else {
            this._moreMountsItem.visible = true;
            this._moreMountsItem.label.text =
                `${folded.length} more mount${folded.length === 1 ? '' : 's'} ▸`;
            for (const m of folded)
                this._moreMountsRowsSection.addMenuItem(this._buildMountRow(m, pill));
        }

        // Reclaim ▸ pick-lists: every mount gets one now, significant or
        // folded — a fold hides the mount, never the lever (Alfred, msg
        // 4508). Diffed against the live mount list instead of rebuilding,
        // same reasoning as before: a mount present with the same
        // significance keeps its existing submenu (ticks and all)
        // completely untouched.
        //
        // The one case this can't preserve: a mount CROSSING the
        // significance boundary between polls, with a live selection on
        // it. GNOME's PopupMenuBase has no supported way to move an
        // existing item to a different parent menu without destroying it —
        // removeAll() always calls destroy(), and there is no public
        // removeMenuItem (verified against Shell's own popupMenu.js).
        // Rather than reach into box/actor internals to fake a re-parent,
        // this rebuilds fresh in the new location and the selection resets.
        // That's an honest trade: the move itself is visible (Reclaim
        // relocates between the flat list and "more mounts ▸"), unlike the
        // original bug where the lever was silently absent altogether.
        const significantMountpoints = new Set(significant.map(m => m.mountpoint));
        const allMountpoints = new Set(mounts.map(m => m.mountpoint));
        for (const [mp, rec] of this._reclaimItems) {
            if (!allMountpoints.has(mp)) {
                rec.item.destroy();
                this._reclaimItems.delete(mp);
            }
        }
        for (const [mp, rec] of this._reclaimItems) {
            const wantSection = significantMountpoints.has(mp) ? 'sig' : 'fold';
            if (rec.section !== wantSection) {
                rec.item.destroy();
                this._reclaimItems.delete(mp);
            }
        }
        for (const m of significant) {
            if (!this._reclaimItems.has(m.mountpoint)) {
                const rec = this._createReclaimItem(m.mountpoint);
                rec.section = 'sig';
                this._reclaimSection.addMenuItem(rec.item);
                this._reclaimItems.set(m.mountpoint, rec);
            }
        }
        for (const m of folded) {
            if (!this._reclaimItems.has(m.mountpoint)) {
                const rec = this._createReclaimItem(m.mountpoint);
                rec.section = 'fold';
                this._moreMountsReclaimSection.addMenuItem(rec.item);
                this._reclaimItems.set(m.mountpoint, rec);
            }
        }

        this._renderSystemObservations(pill);

        const heroSub = hero ? this.subtitle : 'bytes at rest';
        this.menu.setHeader(ICON, 'byebyte', heroSub);
        this._update.setVersion(st.daemon?.version);
    }

    // Shared row shape for both the default list and the "N more mounts ▸"
    // fold — mountpoint, effective free, burn, deadline, plus two READ-ONLY
    // badges for facts that used to be interactive SEGMENT strips here:
    // reserved% (load-bearing for what "free" even means on this mount —
    // Alfred's corollary, msg 4427) and, on /tmp specifically, the PENDING
    // divergence between its configured cap and live size. The KNOBS to
    // change either now live in Settings (prefs.js); these badges are the
    // observation half that stays.
    _buildMountRow(m, pill) {
        const it = new PopupMenu.PopupMenuItem('', {reactive: false});
        const color = STATE_COLOR[m.state] ?? DIM;
        const quota = m.quota
            ? `  <span foreground="${DIM}">[q ${Pill.fmtBytes(m.quota.remaining)}]</span>`
            : '';
        const btrfs = btrfsNote(m);
        const snap = btrfs
            ? `  <span foreground="${DIM}">[snap pin ${Pill.fmtBytes(btrfs.pinned)}]</span>`
            : '';
        const reserved = m.reserved_percent != null
            ? `  <span foreground="${DIM}">[reserved ${Math.round(m.reserved_percent)}%]</span>`
            : '';
        const pendingCap = m.mountpoint === '/tmp' ? tmpPendingBadge(pill) : '';
        it.label.clutter_text.set_markup(
            `<span foreground="${color}" font_weight="bold">●</span> ` +
            `${Pill.esc(m.mountpoint)}  ` +
            `<span foreground="${ACCENT}">${Pill.fmtBytes(m.effective_free)}</span>` +
            `<span foreground="${DIM}"> of ${Pill.fmtBytes(m.total)} · ` +
            `${Pill.esc(fmtBurn(m.burn_bps))} · full ${fmtEta(m.eta_seconds)}</span>` +
            quota + snap + reserved + pendingCap);
        return it;
    }

    // ---- system observations: journal cap -----------------------------------
    // Alfred's rule refined (msg 4454, after I tested "does it feed a
    // number the popup shows" and he tested "can configured diverge from
    // effective"): a control may leave without a witness row ONLY IF its
    // state can't diverge from what the system is actually doing. fstrim
    // does NOT get a row here even though it failed my first, cruder test
    // -- byebyted's build_pill_summary reads fstrim_schedule.enabled via a
    // live `systemctl is-enabled` call every poll tick, never a stored
    // intent, so configured == effective by construction and there is
    // nothing for a row to witness. journal cap DOES get one: usage_bytes
    // is a real, separate filesystem read, and journal_cap()'s own
    // response says why it can diverge --vacuum-size only prunes archived
    // files, so usage can exceed the new cap until the active segment
    // rotates on its own. That's a real, if short-lived, PENDING-shaped
    // gap with a genuine witness needed.
    _renderSystemObservations(pill) {
        this._systemSection.removeAll();
        this._systemSection.addMenuItem(this._buildJournalCapObservation(pill?.journal_cap));
    }

    // The full PENDING form (Alfred, msg 4465): configured, effective, AND
    // the event that clears the gap, not just the divergence -- the same
    // shape tmp-size's own badge already names ("after reboot"), applied
    // here now that there's a real computable divergence to name it for.
    // Deliberately qualitative, not a timestamp: the daemon has no
    // rotation-ETA data (checked byebyted directly -- journal_cap()'s own
    // note documents the MECHANISM, never a "when"), and inventing a time
    // the data doesn't have is exactly the trap Till named on his own
    // oomd row. "Clears when the active segment rotates" is true
    // regardless of timing; a fabricated ETA would not be.
    _buildJournalCapObservation(journalCap) {
        const it = new PopupMenu.PopupMenuItem('', {reactive: false});
        const usage = Pill.num(journalCap?.usage_bytes);
        const cap = journalCap?.current_cap ?? null;
        const capBytes = bytesFromSizeStr(cap);
        const usageText = usage != null ? Pill.fmtBytes(usage) : '?';
        if (usage != null && capBytes != null && usage > capBytes) {
            it.label.clutter_text.set_markup(
                `<span foreground="${DIM}">journal: </span>${Pill.esc(usageText)}` +
                `<span foreground="${DIM}"> over ${Pill.esc(cap)} cap — clears when the ` +
                `active segment rotates</span>`);
            return it;
        }
        const capText = cap ? `of ${Pill.esc(cap)} cap` : 'uncapped';
        it.label.clutter_text.set_markup(
            `<span foreground="${DIM}">journal: ${usageText} ${capText}</span>`);
        return it;
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
        this._toggle = new ByeByteToggle(this._cancellable, () => this.openPreferences());
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

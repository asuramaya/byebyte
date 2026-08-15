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
const {DIM, ACCENT, WARN} = PALETTE;

const ICON = 'drive-harddisk-symbolic';

const STATE_COLOR = {ok: PALETTE.GOOD, warn: PALETTE.WARN, hot: PALETTE.BAD, edquot: PALETTE.BAD};
const STATE_MARK = {ok: '', warn: '⚠ ', hot: '‼ ', edquot: '✗ '};

// Variant A (operator ruling, "a for both ram and bye" — byebyte and
// ramstein stay siblings, decision fdf6fa0d): every "set once, forget"
// knob lives inline in the popup rather than a separate GNOME preferences
// window. Variant B (external prefs.js) is shelved, not deleted —
// preserved whole on the variant-b-shelved branch.
const RESERVE_PRESETS = [1, 5, 10, 20];
const JOURNAL_CAP_PRESETS = ['100M', '500M', '1G', '2G'];
const TMP_SIZE_PRESETS = ['2G', '4G', '8G', '16G'];

// Parses a byebyte size string (digits + optional K/M/G/T, byebyted's own
// _SIZE_RE) into bytes, 1024-based — the same convention systemd's own
// tmpfs Options=size= and journald's SystemMaxUse= both use. Used to
// compare tmp-size's CONFIGURED cap against its EFFECTIVE live total
// (decision 3b31bc10) for /tmp's own mount-row badge and journal-cap's
// Advanced ▸ caveat.
function bytesFromSizeStr(s) {
    const m = typeof s === 'string' ? /^(\d+)([KMGT]?)$/.exec(s) : null;
    if (!m)
        return null;
    const mult = {'': 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4}[m[2]];
    return parseInt(m[1], 10) * mult;
}

// configuredBytes is null both when nothing's configured AND when the
// vendor unit's own default is a percentage bytesFromSizeStr can't parse —
// either way there's no proof of divergence. Shared by /tmp's own mount-row
// badge (below) and Advanced ▸'s fold-header caveat, so the two never
// disagree about whether tmp-size is pending.
function isTmpSizePending(pill) {
    const tmpSize = pill?.tmp_size;
    const configuredBytes = bytesFromSizeStr(tmpSize?.configured_cap ?? null);
    const liveBytes = Pill.num(tmpSize?.live_total_bytes);
    return configuredBytes != null && liveBytes != null && configuredBytes !== liveBytes;
}

// journal-cap's own divergence check (--vacuum-size only prunes archived
// files, so usage can exceed a fresh cap until the active segment rotates)
// — shared by Advanced ▸'s caption row and its fold-header caveat, same
// reasoning as isTmpSizePending above.
function isJournalCapPending(journalCap) {
    const usage = Pill.num(journalCap?.usage_bytes);
    const capBytes = bytesFromSizeStr(journalCap?.current_cap ?? null);
    return usage != null && capBytes != null && usage > capBytes;
}

// PENDING (decision 3b31bc10, the fourth affordance beside SEGMENT/TOGGLE/
// BOUNDED-WAIT): tmp-size's write is instant but /tmp is never remounted by
// the verb, so CONFIGURED and EFFECTIVE can genuinely diverge. This fact
// stays on /tmp's own mount row — "the popup shows every fact about what
// the system is doing right now, including 'you asked for something it
// hasn't done yet'" (Alfred, msg 4427). Never renders a single value that
// would read as "done" when it isn't; converges back to nothing shown, on
// its own, once a reboot/remount actually lands — no code has to be told
// that happened.
function tmpPendingBadge(pill) {
    if (!isTmpSizePending(pill))
        return '';
    return `  <span foreground="${DIM}">[cap ${Pill.esc(pill.tmp_size.configured_cap)} @reboot]</span>`;
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

        // ONE PopupSubMenuMenuItem per mount, SIGNIFICANT ones flat here,
        // everything else inside "more mounts ▸" — diffed by mountpoint
        // identity against the live list every refresh, NEVER blanket-
        // rebuilt, so an open mount / ticked Reclaim selection / an open
        // reserved% strip all survive a routine 30s poll.
        //
        // Redesign 2026-08-15 (operator ruling — "roll up the repetition,
        // slaughter all is on the table"): this collapses what used to be
        // THREE separate lists that each enumerated every mount name —
        // plain observation rows, a flat "Reclaim on X ▸" list, Advanced's
        // per-mount reserved% strips — into ONE. A mount's name now
        // appears exactly once anywhere in the pill. Everything about that
        // mount (reserved% if it's ext, tmp-size if it's /tmp, Reclaim)
        // lives one click inside its own row, via _mountItems below.
        this._mountSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._mountSection);
        this._mountItems = new Map();   // mountpoint -> {item, section, mountpoint, controlsSection, reclaim}
        this._offlinePlaceholder = null;

        // "N more mounts ▸" — the fold for mounts nobody needs to see by
        // default (see isSignificantMount). Holds the same per-mount items
        // directly now — no separate rebuilt row-list, no separate diffed
        // Reclaim sub-section; a fold may hide a mount, it must never hide
        // the capabilities that live inside it (Alfred, msg 4508).
        this._moreMountsItem = new PopupMenu.PopupSubMenuMenuItem('more mounts ▸');
        this._moreMountsItem.visible = false;
        this.menu.addMenuItem(this._moreMountsItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        // Advanced ▸ — now ONLY the true system-wide singletons: journal
        // cap, fstrim schedule. reserved% and tmp-size both moved into
        // each mount's own row (they're about a specific mount, not the
        // system) — Advanced dropped from ~7 rows to 2. Defaults CLOSED,
        // and the fold's own LABEL still carries a live caveat (journal-
        // cap's the only one left that can diverge with no other witness;
        // reserved%/tmp-size both pass without one now, same as before —
        // their numbers AND their controls live on the mount's own row).
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
            for (const [, rec] of this._mountItems)
                rec.item.destroy();
            this._mountItems.clear();
            this._moreMountsItem.visible = false;
            this._advancedItem.menu.removeAll();
            this._advancedItem.label.text = 'Advanced ▸';
            if (this._offlinePlaceholder)
                this._offlinePlaceholder.destroy();
            this._offlinePlaceholder = new PopupMenu.PopupMenuItem(
                stale ? 'byebyted stopped updating' : 'byebyted not running',
                {reactive: false});
            this._mountSection.addMenuItem(this._offlinePlaceholder);
            this._update.setVersion(null);
            return;
        }
        this._apply(st);
    }

    _apply(st) {
        const mounts = st.mounts.filter(Pill.isObj);
        const pill = st.pill ?? null;

        // the daemon is confirmed live again — drop the offline placeholder
        // (a no-op if we were already online; _mountSection otherwise holds
        // only real mount items, never blanket-rebuilt below)
        if (this._offlinePlaceholder) {
            this._offlinePlaceholder.destroy();
            this._offlinePlaceholder = null;
        }

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

        // per-mount items: root and anything in trouble show by default;
        // everything else folds under "N more mounts ▸" (isSignificantMount).
        // Diffed against the live mount list by mountpoint identity —
        // a mount present with the same significance keeps its existing
        // item (open/closed state, ticked Reclaim selections, all of it)
        // completely untouched; only appearing/disappearing/crossing
        // mounts change anything here.
        //
        // The one case this can't preserve: a mount CROSSING the
        // significance boundary between polls. GNOME's PopupMenuBase has
        // no supported way to move an existing item to a different parent
        // menu without destroying it — removeAll() always calls destroy(),
        // and there is no public removeMenuItem (verified against Shell's
        // own popupMenu.js, decision from the earlier Reclaim-reach work).
        // Rather than reach into box/actor internals to fake a re-parent,
        // this rebuilds fresh in the new location and EVERYTHING about
        // that row resets — expanded state, reserved% chip focus, any
        // ticked Reclaim selection, all of it, together, since it's all
        // one object now. That's a bigger reset than the old design's
        // (which only lost Reclaim's ticks), but still an honest trade:
        // the move itself is visible, unlike the original bug where the
        // lever was silently absent altogether.
        const significant = mounts.filter(isSignificantMount);
        const folded = mounts.filter(m => !isSignificantMount(m));
        const significantMountpoints = new Set(significant.map(m => m.mountpoint));
        const allMountpoints = new Set(mounts.map(m => m.mountpoint));

        for (const [mp, rec] of this._mountItems) {
            if (!allMountpoints.has(mp)) {
                rec.item.destroy();
                this._mountItems.delete(mp);
            }
        }
        for (const [mp, rec] of this._mountItems) {
            const wantSection = significantMountpoints.has(mp) ? 'sig' : 'fold';
            if (rec.section !== wantSection) {
                rec.item.destroy();
                this._mountItems.delete(mp);
            }
        }
        for (const m of mounts) {
            let rec = this._mountItems.get(m.mountpoint);
            if (!rec) {
                rec = this._createMountItem(m.mountpoint);
                rec.section = significantMountpoints.has(m.mountpoint) ? 'sig' : 'fold';
                (rec.section === 'sig' ? this._mountSection : this._moreMountsItem.menu)
                    .addMenuItem(rec.item);
                this._mountItems.set(m.mountpoint, rec);
            }
            this._updateMountItem(rec, m, pill);
        }

        this._moreMountsItem.visible = folded.length > 0;
        if (folded.length > 0) {
            this._moreMountsItem.label.text =
                `${folded.length} more mount${folded.length === 1 ? '' : 's'} ▸`;
        }

        this._renderControls(pill);

        const heroSub = hero ? this.subtitle : 'bytes at rest';
        this.menu.setHeader(ICON, 'byebyte', heroSub);
        this._update.setVersion(st.daemon?.version);
    }

    // Builds the persistent per-mount item ONCE: the collapsed row (a
    // PopupSubMenuMenuItem's own label, updated in place every refresh —
    // see _updateMountItem) expands to reveal a controlsSection (reserved%/
    // tmp-size chips, cheap and stateless, safely rebuilt every refresh)
    // and a persistent nested "Reclaim ▸" item, lazy-loaded on its own
    // first expand exactly like the old top-level Reclaim items were —
    // same mechanism, just nested one level deeper now.
    _createMountItem(mountpoint) {
        const item = new PopupMenu.PopupSubMenuMenuItem('');
        const controlsSection = new PopupMenu.PopupMenuSection();
        item.menu.addMenuItem(controlsSection);
        const reclaimItem = new PopupMenu.PopupSubMenuMenuItem('Reclaim ▸');
        item.menu.addMenuItem(reclaimItem);

        const rec = {
            item, section: null, mountpoint, controlsSection,
            reclaim: {item: reclaimItem, built: false, rows: new Map(),
                footerItem: null, commitItem: null},
        };
        reclaimItem.menu.connect('open-state-changed', (_menu, open) => {
            if (open && !rec.reclaim.built) {
                rec.reclaim.built = true;
                this._populateReclaimList(mountpoint, rec.reclaim);
            }
        });
        return rec;
    }

    // Runs every refresh regardless of whether the item is currently
    // expanded — all cheap markup/chip-strip rebuilds, never touches the
    // nested Reclaim item (that one only ever changes via its own lazy
    // load or a user click, see _populateReclaimList).
    _updateMountItem(rec, m, pill) {
        rec.item.label.clutter_text.set_markup(this._mountRowMarkup(m, pill));

        rec.controlsSection.removeAll();
        if (m.reserved_percent != null || m.reserved_percent_unknown)
            rec.controlsSection.addMenuItem(this._buildReserveStrip(m));
        if (m.mountpoint === '/tmp') {
            for (const row of this._buildTmpSizeRows(pill?.tmp_size))
                rec.controlsSection.addMenuItem(row);
        }
    }

    // The collapsed row's own markup — mountpoint, effective free, burn,
    // deadline, plus two READ-ONLY badges: reserved% (load-bearing for
    // what "free" even means on this mount — Alfred's corollary, msg 4427)
    // and, on /tmp specifically, the PENDING divergence between its
    // configured cap and live size. The KNOBS that change either now live
    // one click inside this same row (see _updateMountItem); these badges
    // are the always-visible observation half.
    _mountRowMarkup(m, pill) {
        const color = STATE_COLOR[m.state] ?? DIM;
        const quota = m.quota
            ? `  <span foreground="${DIM}">[q ${Pill.fmtBytes(m.quota.remaining)}]</span>`
            : '';
        const btrfs = btrfsNote(m);
        const snap = btrfs
            ? `  <span foreground="${DIM}">[snap pin ${Pill.fmtBytes(btrfs.pinned)}]</span>`
            : '';
        // "not applicable" (no key at all — a non-ext mount) and "I don't
        // know" (reserved_percent_unknown — an ext mount tune2fs couldn't
        // read, e.g. missing on a trimmed image) must render differently
        // (ruling 2c45d78e) — both used to collapse to the same blank badge.
        const reserved = m.reserved_percent != null
            ? `  <span foreground="${DIM}">[reserved ${Math.round(m.reserved_percent)}%]</span>`
            : m.reserved_percent_unknown
                ? `  <span foreground="${DIM}">[reserved: unknown]</span>`
                : '';
        const pendingCap = m.mountpoint === '/tmp' ? tmpPendingBadge(pill) : '';
        return `<span foreground="${color}" font_weight="bold">●</span> ` +
            `${Pill.esc(m.mountpoint)}  ` +
            `<span foreground="${ACCENT}">${Pill.fmtBytes(m.effective_free)}</span>` +
            `<span foreground="${DIM}"> of ${Pill.fmtBytes(m.total)} · ` +
            `${Pill.esc(fmtBurn(m.burn_bps))} · full ${fmtEta(m.eta_seconds)}</span>` +
            quota + snap + reserved + pendingCap;
    }

    // ---- Advanced ▸: the true system-wide singletons only ------------------
    // journal cap, fstrim schedule. reserved%/tmp-size live on their own
    // mount's row now (_updateMountItem above) — neither belongs here
    // anymore, they're facts about ONE mount, not the system.
    _renderControls(pill) {
        this._updateAdvancedHeader(pill);
        const menu = this._advancedItem.menu;
        menu.removeAll();

        if (!pill) {
            menu.addMenuItem(new PopupMenu.PopupMenuItem(
                'daemon status unavailable', {reactive: false}));
            return;
        }
        menu.addMenuItem(this._buildJournalCapRow(pill.journal_cap));
        const journalCaveat = this._journalCapCaption(pill.journal_cap);
        if (journalCaveat)
            menu.addMenuItem(journalCaveat);
        menu.addMenuItem(this._buildFstrimScheduleRow(pill.fstrim_schedule));
    }

    // The fold's own label carries a live caveat (ramstein's rule, Alfred's
    // DM 4458, applied here): a COLLAPSED Advanced must not hide that
    // journal-cap might currently be pending — collapsing is the entire
    // point of a disclosure, so the caveat has to survive it. journal-cap
    // is the only occupant left that can diverge with no other witness;
    // reserved%/tmp-size both pass without needing one here, same as
    // before, now doubly true since their CONTROLS live on the mount row
    // too, not just their badges.
    _updateAdvancedHeader(pill) {
        this._advancedItem.label.text = isJournalCapPending(pill?.journal_cap)
            ? 'Advanced ▸  ⚠ pending'
            : 'Advanced ▸';
    }

    // A caveat line under a control row — ramstein's own _captionRow shape
    // exactly (indented under the row it explains, small text, WARN by
    // default since this is an open-but-converging condition, not a
    // resolved negative).
    _captionRow(text, color = WARN) {
        const it = Pill.wrapRow(
            `<span foreground="${color}" size="small">${Pill.esc(text)}</span>`);
        it.style = 'margin: -6px 0 2px 44px;';
        return it;
    }

    // The full PENDING form (Alfred, msg 4465): names the MECHANISM, never
    // invents a TIMING the daemon can't back — journal_cap()'s own
    // response documents why usage can exceed a fresh cap (--vacuum-size
    // only prunes archived files), never a rotation ETA. "Clears when the
    // active segment rotates" is true regardless of timing.
    _journalCapCaption(journalCap) {
        if (!isJournalCapPending(journalCap))
            return null;
        const usageText = Pill.fmtBytes(Pill.num(journalCap.usage_bytes));
        return this._captionRow(
            `${usageText} over ${journalCap.current_cap} cap — clears when the ` +
            'active segment rotates');
    }

    // ---- reserve's SEGMENT strip --------------------------------------------
    // Lives inside a single mount's own expansion now, so there is only
    // ever ONE strip visible at a time and it never needs to disambiguate
    // itself from a sibling mount's strip — distinguishingMountLabel and
    // its whole truncation-collision fix (built earlier tonight for the
    // old flat, all-strips-at-once Advanced layout) are dead with this
    // redesign; the structural fix dissolved the bug a third time. Deleted
    // outright rather than left unused.

    _buildReserveStrip(m) {
        const mountpoint = m.mountpoint;
        // reserved_percent can be a float (5.03) from the block-count-
        // truncation math the daemon documents — round for the highlight
        // comparison, don't require exact float equality. null here means
        // "couldn't read it this poll" (reserved_percent_unknown), never
        // "0%" — no preset gets highlighted as current, and the label says
        // so explicitly rather than silently picking a chip.
        const current = m.reserved_percent != null ? Math.round(m.reserved_percent) : null;
        const box = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const layout = new St.BoxLayout({x_expand: true});
        const labText = current != null ? 'reserved' : 'reserved: unknown';
        const lab = new St.Label({text: labText, style: `color:${DIM}; padding-right:8px;`});
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
                    Pill.notify('byebyte',
                        `${mountpoint}: reserve to ${doc.new_percent}% did not take effect`);
                }
            });
    }

    // ---- journal-cap / fstrim-schedule --------------------------------------

    _buildJournalCapRow(journalCap) {
        const current = journalCap?.current_cap ?? null;
        const box = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const layout = new St.BoxLayout({x_expand: true});
        const lab = new St.Label({text: 'journal cap', style: `color:${DIM}; padding-right:8px;`});
        lab.y_align = 2;
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
        });
    }

    // TOGGLE: PopupMenu.PopupSwitchMenuItem — ramstein's own oomd/zram
    // shape. `enabled === null` means fstrim.timer doesn't exist on this
    // system (byebyted's own _systemctl_is_enabled convention) — an absent
    // unit gets actionable text instead of a dead switch. No caveat/caption
    // ever needed here: enabled reads `systemctl is-enabled` live every
    // poll tick, never a stored intent, so configured == effective by
    // construction (Alfred's test, msg 4454 — verified against byebyted
    // directly, not assumed).
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

    // ---- /tmp's own tmp-size SEGMENT, rendered inside /tmp's mount row -----
    // PENDING (decision 3b31bc10): the status line here restates the same
    // fact /tmp's own mount-row badge already carries (tmpPendingBadge) —
    // deliberate duplication, not redundancy: the badge is the always-
    // visible fact even collapsed, this one sits right next to the control
    // that sets it once expanded, same "detail lives next to the control
    // that owns it" shape ramstein's captions use.
    _buildTmpSizeRows(tmpSize) {
        const configured = tmpSize?.configured_cap ?? null;
        const liveBytes = Pill.num(tmpSize?.live_total_bytes);
        const pending = isTmpSizePending({tmp_size: tmpSize});

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
            const live = Pill.num(doc.live_total_bytes);
            const liveText = live != null ? `, still ${Pill.fmtBytes(live)} now` : '';
            Pill.notify('byebyte',
                `/tmp cap: ${doc.prior_cap ?? 'default'} → ${doc.new_cap} ` +
                `(after reboot${liveText})`);
        });
    }

    // ---- Reclaim ▸ pick-list, nested inside each mount's own row -----------
    // Same lazy-load-on-first-expand mechanism as before (see
    // _createMountItem), just addressed via rec.reclaim instead of a
    // top-level map lookup — mountpoint is still threaded through for the
    // CLI calls and user-facing notify() text.

    _addReclaimRefreshRow(mountpoint, reclaim, menu) {
        const refresh = new PopupMenu.PopupMenuItem('↻ Refresh list');
        refresh.connect('activate', () => this._populateReclaimList(mountpoint, reclaim));
        menu.addMenuItem(refresh);
    }

    _populateReclaimList(mountpoint, reclaim) {
        const menu = reclaim.item.menu;
        menu.removeAll();
        reclaim.rows = new Map();
        reclaim.footerItem = null;
        reclaim.commitItem = null;
        menu.addMenuItem(Pill.row(`<span foreground="${DIM}">loading…</span>`));
        this._addReclaimRefreshRow(mountpoint, reclaim, menu);

        runByebyteJson(['why', mountpoint, '--json'], this._cancellable, doc => {
            // The mount may have vanished, or crossed the significance
            // boundary (destroy-and-rebuild), while this was in flight —
            // this reclaim record's item may already be destroyed, and a
            // fresh (or no) mount item may sit in _mountItems now; touching
            // the dead actor here would throw, so bail instead.
            if (this._mountItems.get(mountpoint)?.reclaim !== reclaim)
                return;
            this._renderReclaimList(mountpoint, reclaim, doc);
        });
    }

    _renderReclaimList(mountpoint, reclaim, doc) {
        const menu = reclaim.item.menu;
        menu.removeAll();
        reclaim.rows = new Map();
        reclaim.footerItem = null;
        reclaim.commitItem = null;

        if (!doc || doc.error) {
            const msg = doc?.error || 'could not reach the daemon';
            menu.addMenuItem(new PopupMenu.PopupMenuItem(msg, {reactive: false}));
            this._addReclaimRefreshRow(mountpoint, reclaim, menu);
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
                reclaim.rows.set(r.path, {bytes, selected: false});
                const it = Pill.dataRow(r.path, Pill.fmtBytes(bytes), () => {
                    const s = reclaim.rows.get(r.path);
                    s.selected = !s.selected;
                    it.setOrnament(s.selected ? PopupMenu.Ornament.CHECK : PopupMenu.Ornament.NONE);
                    this._updateReclaimFooter(reclaim);
                });
                it.setOrnament(PopupMenu.Ornament.NONE);
                menu.addMenuItem(it);
            }
        }

        reclaim.footerItem = new PopupMenu.PopupMenuItem('', {reactive: false});
        menu.addMenuItem(reclaim.footerItem);

        reclaim.commitItem = new PopupMenu.PopupMenuItem('');
        reclaim.commitItem.connect('activate', () => this._commitReclaim(mountpoint, reclaim));
        menu.addMenuItem(reclaim.commitItem);

        this._addReclaimRefreshRow(mountpoint, reclaim, menu);
        this._updateReclaimFooter(reclaim);
    }

    _updateReclaimFooter(reclaim) {
        if (!reclaim.footerItem)
            return;
        let n = 0, bytes = 0;
        for (const s of reclaim.rows.values()) {
            if (s.selected) {
                n++;
                bytes += s.bytes;
            }
        }
        reclaim.footerItem.label.clutter_text.set_markup(
            `<span foreground="${DIM}">` +
            (n === 0 ? 'Selected: none' : `Selected: ${n} · ${Pill.esc(Pill.fmtBytes(bytes))}`) +
            '</span>');
        if (!reclaim.commitItem)
            return;
        if (n === 0) {
            reclaim.commitItem.visible = false;
        } else {
            reclaim.commitItem.visible = true;
            reclaim.commitItem.reactive = true;
            reclaim.commitItem.label.text =
                `Reclaim selected — ${Pill.fmtBytes(bytes)} (${n} path${n === 1 ? '' : 's'})`;
        }
    }

    // Deletes every ticked path, one declare() at a time (sequential — no
    // overlapping daemon writes to reason about), then toasts the daemon's
    // own verified totals and refreshes the list against reality.
    _commitReclaim(mountpoint, reclaim) {
        const paths = [];
        for (const [path, s] of reclaim.rows) {
            if (s.selected)
                paths.push(path);
        }
        if (paths.length === 0)
            return;
        if (reclaim.commitItem) {
            reclaim.commitItem.reactive = false;
            reclaim.commitItem.label.text = 'declaring…';
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
                // itself vanished, or crossed the significance boundary,
                // in the meantime)
                if (this._mountItems.get(mountpoint)?.reclaim === reclaim)
                    this._populateReclaimList(mountpoint, reclaim);
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

# Using ByeByte

Everything the CLI, the daemon and the tile can do. If you just installed ByeByte, start
with `byebyte status`. For the short version, see the [README](../README.md); for a
terminal reference, `man byebyte` and `man byebyted`.

Every command that prints something accepts `--json`, which is how the GNOME extension
talks to the CLI, and how you'd script against it.

## Where things stand

```bash
byebyte status              # headroom, burn rate, ETA-to-full, quota per mount
```

Where `df` gives a percentage, `status` gives a deadline: free space, burn rate, and
time-until-full, including quota headroom on tmpfs, where "disk full" errors happen while
`df` still swears everything is fine.

```bash
byebyte why [path] [--limit N]     # instant du-tree from the index, age-tagged
byebyte blame [--since T]          # what grew since T (1d, 1w, or YYYY-MM-DD)
```

`why` answers "what's big"; `blame` answers "what got bigger." Both read the index rather
than walking the disk live, so they're instant, and both age-tag results (big *and* stale
stands out from big and recent). On a btrfs mount, either one adds a note when snapshots pin
space the walk can't see, or when btrfs accounting isn't available.

```bash
byebyte scan [--wait]        # kick off an on-demand index refresh
```

The index refreshes nightly on its own; `scan` is for when you don't want to wait.

## Reclaiming space

```bash
byebyte purge <category> [--yes]
```

Deletes what a compiled-in category detector positively matches, never a path you type in.
Dry-run by default; `--yes` executes. `--all` is refused on purpose, one category per act.
Categories: `hf-hub`, `pip-cache`, `uv-cache`, `thumbnails`, `project-artifacts`,
`rotated-logs`, `journald`, `snap-old`. Every deletion is appended to
`/var/lib/byebyte/ledger.jsonl`.

```bash
byebyte ghosts
```

Deleted-but-open files still holding disk blocks: the classic "`df` and `du` disagree"
mystery, grouped by the process holding them and the mount they live on. Report-only; it
never signals anything, it just tells you who to restart.

```bash
byebyte ballast [release]
```

Shows the pre-allocated emergency reserve, or releases it to free space even at 0 bytes
free. The release path itself allocates nothing, so freeing space never needs free space to
begin with.

```bash
byebyte kernels
```

Lists removable kernel packages (installed, not running, not the newest) and prints the
exact `apt autoremove` line. It never runs `apt` itself.

```bash
byebyte advise
```

One-line nudges: a mount nearing full, a fast index grower, a cold cache worth clearing, a
pile of ghosts, quota headroom running low.

## Watching writes

```bash
byebyte burn [--seconds N] [--limit N]
```

Live per-process write rates, sampled over `N` seconds (default 5, clamped 1-30). As root,
with `CAP_SYS_ADMIN` available, each writer also names the directory it's writing to. Absent
that capability, writers are named by pid only.

## Unattended reclaim

```bash
byebyte sweep [--dry]
byebyte sweep --history [--limit N]
```

The unattended reclaim policy, off by default and double-consent when it isn't. Consent #1
is the `byebyte-sweep.timer` unit, disabled unless you enable it. Consent #2 is naming a
category in `sweep_categories` in `/etc/byebyte/config.json`, itself always a subset of
`purge`'s own compiled-in categories; config can arm a category, never invent one. Missing
either consent means every call only previews and ledgers a `dry_run` entry; nothing is
deleted. Kernel removal is never armable through `sweep`, regardless of config. `--history`
replays past sweep acts and previews from the ledger, most recent first.

## Updating

```bash
byebyte update [--check] [--json]
```

`--check` reports whether a newer release exists. It's the same call the daily timer makes,
notify-only. A bare `update` is the manual-install consent tier; there is no unattended
install tier wired up from this CLI. Before installing anything, `update` verifies the
release against its published `SHA256SUMS` manifest, and its SSH signature once the trust
anchor is armed. See [RELEASE-SIGNING.md](RELEASE-SIGNING.md) for what that means.

## The Quick Settings tile

The **byebyte** tile sits in GNOME's Quick Settings once the pill is installed
(`make pill`, then `gnome-extensions enable byebyte@asuramaya`, then log out and back in,
since Wayland only loads extensions at login). Collapsed, it shows the tightest mount's headroom
and ETA, heating up as the deadline shrinks and turning red on a write failure. Expanded, it
lists per-mount headroom and the index's top growers. An update row appears once
`byebyte update --check --json` reports one available, and installs with a click
(`pkexec`-elevated).

The tile reads a status file the daemon writes as a by-product of its poll loop, so opening
it is instant rather than blocking on a live query.
[ARCHITECTURE.md](ARCHITECTURE.md) describes that seam if you're curious why.

## Configuration

`/etc/byebyte/config.json` is the seed, never the master: every key is typed and clamped on
load, unknown keys are ignored, and a tampered file can tune numbers within their documented
ranges but can never grant the daemon a new ability. It's seeded once at install
(`owner_uid` from the installing `sudo` call) and never overwritten by a reinstall. Edit it
by hand and restart `byebyted` to pick up changes.

The full key/default/clamp table is in `man byebyted`. The two worth knowing about day to
day: `purge_disabled` (category ids to switch off) and `sweep_categories` (category ids to
arm for unattended reclaim, see above).

## Troubleshooting

**`byebyte: command not found`**
`/usr/local/bin` (or `/usr/bin` for a `.deb` install) isn't on your `PATH`, or the daemon
isn't installed yet, so `man byebyte` won't render either. Check `sudo systemctl status
byebyted`.

**No byebyte tile in Quick Settings**
The extension only loads at a fresh login on Wayland. Log out and back in, then check
`gnome-extensions list --enabled | grep byebyte`.

**`byebyte status` reports stale or missing data**
Check `byebyte-healthcheck`, or `sudo systemctl status byebyted` directly. The daemon writes
`status.json` on every poll (default every 30s); a gap usually means the daemon isn't
running.

**A quota-backed mount shows full while `df` disagrees**
That's the invariant this tool exists for: effective headroom is
`min(free, quota remaining)`, and `df` can't see the quota half. `byebyte status` is the
correct number; trust it over `df` on a quota-backed mount.

**btrfs snapshots seem to be hiding space**
`byebyte why` and `byebyte blame` note when snapshots pin space the walk can't see. Install
the `btrfs-progs` package if it isn't already, so ByeByte can read the real accounting
instead of falling back to a plain walk.

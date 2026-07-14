# byebyte — build plan

The disk sibling of the family: **kast · phanspeed · coldspot · byebyte**.
coldspot governs the internet, phanspeed governs power, byebyte governs storage.

## Constitution

- Free tools, not products. GPLv3. Open source on GitHub; only home is asuramaya.com (portfolio).
- Ubuntu is free, the demons are free — the dream is to be merged up to the OS one day.
  Every decision must survive a hypothetical Debian maintainer: stdlib-only Python,
  FHS-clean, man pages, no telemetry, `.deb`-able.
- House doctrine (from coldspot's README): **a daemon that owns the truth, a verb CLI
  over it, and a GNOME pill on top.** State on disk is the seed, never the master.

## Anatomy

```
byebyte/
├── bin/
│   ├── byebyted             # root daemon — the only privileged actor
│   ├── byebyte              # verb CLI, JSON over AF_UNIX control socket
│   ├── byebyte-healthcheck  # index fresh? scan not wedged? status shape valid?
│   └── byebyte-update       # family-standard, click-to-install only, never unattended
├── extension/               # byebyte@asuramaya — GNOME 50 Quick Settings pill
├── registry/                # category definitions (the purge allowlist)
├── systemd/system/          # byebyted.service (ProtectSystem=strict etc.) + update timer
├── config/                  # default config.json — seed, never master
├── tests/                   # attack_socket.py, fixture trees, full-disk loopback rig
├── docs/ARCHITECTURE.md
├── Makefile                 # smoke / deploy / pill
├── install.sh               # sudo installs daemon; pill is its own user-level step
└── LICENSE (GPLv3) · VERSION · CHANGELOG.md · README.md
```

- IPC: newline-delimited JSON over `/run/byebyte/control.sock`; socket chowned to the
  user, mode 0660 (phanspeed model; revisit group model at packaging time).
- `status.json` at `/run/byebyte/status.json`, 0640. Pill reads it via Gio.FileMonitor
  (event-driven, no polling, never root).
- Index: sqlite (stdlib) at `/var/lib/byebyte/index.db`. Per-directory aggregation
  (~200k rows for 2.3M files), `newest_mtime` + atime percentiles per dir for
  age-weighting. Scans are snapshot rows, ring-buffered to 30.

## Verbs

| verb | what |
|---|---|
| `byebyte status` | headroom, burn rate, ETA-to-full, top growers |
| `byebyte why [path]` | instant du-tree from the index, age-shaded (big AND stale) |
| `byebyte blame [--since T]` | what grew — join of two snapshots |
| `byebyte scan` | on-demand index refresh (nightly otherwise) |
| `byebyte purge <category>` | allowlist-only, dry-run by default, ledger of freed bytes |
| `byebyte advise` | nudges: leaks, hoards, "syslog grew 8G/day" |
| `byebyte ghosts` | deleted-but-open files holding blocks; names the holding process |
| `byebyte kernels` | /boot cleanup that works even at 0 bytes free in /boot |
| `byebyte ballast` | pre-allocated emergency reserve; `release` un-wedges a full disk |
| `byebyte burn` | live per-process writes (v1: /proc/*/io deltas; v2: eBPF) |

Modes: **Watch** (observe only — default, v1) and an active auto-purge mode
(name candidate **Sweep** — "steward" is banned). Sweep is v2, opt-in, never default.

## Invariants (hardcoded in the daemon; house security doctrine)

1. Nothing is ever deleted unless a **compiled-in category detector positively
   matches** it. Config can disable categories; it can never add raw paths.
   A tampered config cannot weaken safety (phanspeed doctrine).
2. Emergency verbs (`ghosts`, `ballast release`, `purge --category logs`) must run
   at 100% full from a bare TTY — the pill is dead exactly when things are worst.
   Proven in CI with a loopback ext4 image filled to 100%.
3. Headroom is **effective** headroom: min(free, quota remaining) per mount.
   Born from the 2026-07-13 incident: EDQUOT on tmpfs /tmp (usrquota) while df said 11%.
4. Docker/containers are accounted **via their own APIs only** — generic du-walks
   get overlay storage wrong (documented podman/docker accounting bugs).

## Registry seeds (regenerable categories)

huggingface hub · uv · pip · snap old revisions · journald vacuum · rotated logs ·
docker (API) · kondo-style project artifacts (node_modules / .venv / target / build) ·
old kernels · thumbnails

## Milestones

- **M0 — truth engine.** Daemon, no scanner: statvfs + quota poll (30s), EWMA burn
  rate, ETA, EDQUOT/ENOSPC watch, status.json, control socket. `byebyte status` e2e.
  ~400 lines; already beats every point-in-time GNOME disk extension.
- **M1 — pill.** Collapsed: `825G · ~9w`, heats as ETA shrinks, red on write failure.
  Expanded: per-mount headroom, top growers. `make smoke` asserts status.json shape.
- **M2 — index.** Scanner + sqlite + snapshot ring. `why`, `blame`, pill top-growers live.
- **M3 — hands.** Registry + `purge` + `advise` + `ghosts` + `kernels` + ballast.
- **M4 — luxuries.** Sweep mode, eBPF burn, btrfs sampling (btdu-style), `.deb`, man pages.

## Stolen ideas ledger (credit where due)

agedu: age-weighting · BleachBit CleanerML + qdirstat cleanup actions: declarative
category cleaners w/ preview · kondo: regenerable-by-construction project detection ·
dua-cli: trash-not-rm, junk highlighting · npkill: "still in use" warnings ·
gdu: JSON export · duc: persistent index prior art (we daemon-ify it) ·
rmlint: reflink dedup on CoW (future) · coldspot: ledger, stances, bpf precedent ·
phanspeed: missions, failsafe invariants, healthcheck, hostile-input socket doctrine.

## Community targets (build for me AND them)

snap revision hoarding · /boot kernel catch-22 · journald/syslog growth ·
df-vs-du ghost files · docker accounting drift · disk-full-breaks-login ·
Timeshift self-fill (warn) · ML cache growth · quota EDQUOT invisibility.
GNOME's own low-disk notification has been hated for 15+ years; the pill is the answer.

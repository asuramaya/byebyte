# Changelog

## 0.6.1 — V2.M1: ghosts dedup
- byebyted ghosts(): groups by (dev, inode) instead of (pid, comm) — a deleted-but-open file shared by N pids is now ONE ghost with an N-entry `holders` list, not N separate ghosts; `total_bytes` no longer double-counts a shared file's size (also sharpens advise's ghosts_heavy rule, which reads total_bytes)
- byebyte ghosts: renders one line per ghost, listing every holding pid
- smoke: existing single-holder ghosts test updated for the new shape; new fork-based fixture proves the dedup — one shared deleted fd, two pids, one ghost, bytes counted once

## 0.6.0 — adopt the sutra backbone (behavior-preserving)
- vendored bin/sutra.py + bin/sutra.version (sutra 0.1.0, ByeByte is the pilot extraction); byebyted/byebyte now import it as a sibling instead of hand-rolling the same skeleton
- byebyted: load_config -> sutra.load_config (ballast_bytes test hatch re-applied on top, since sutra doesn't know that key); write_status -> sutra.write_status; the EWMA inline in poll_mount -> sutra.ewma_rate; the Control class deleted in favor of a dispatch closure over cfg/indexer/live_status carrying the unchanged domain commands (scan/why/blame/purge/ghosts/ballast/kernels/advise/burn), served by sutra.ControlServer + allow_uids — ping/status are sutra's job now
- byebyte: request()/fetch() now call sutra.request / sutra.read_status instead of hand-rolling the socket client and status.json fallback
- make check-sutra: verifies bin/sutra.py's sha256 against bin/sutra.version (integrity, always) and diffs against ~/code/REPOS/sutra/sutra.py when that checkout is present (freshness); wired into CI and the front of make smoke; make deb now ships bin/sutra.py alongside the bins
- no observable change: same socket contract, same status.json shape, same config semantics — make smoke + make attack stay green throughout

## 0.0.1 — M0 truth engine
- byebyted: statvfs + tmpfs-usrquota polling, EWMA burn rate, ETA-to-full, status.json, hardened control socket
- byebyte: status verb (human + --json)
- make smoke: shape + hostile-input assertions

## 0.1.0 — M1 pill
- extension/byebyte@asuramaya: Quick Settings pill — hero mount deadline on the tile, per-mount rows, quota alerts, event-driven via GFileMonitor
- make pill: user-level install target

## 0.2.0 — Wave 1 packaging
- install.sh / uninstall.sh: two-step root/pill split (coldspot doctrine) — root installs daemon+CLI+units, seeds /etc/byebyte/config.json once (owner_uid from SUDO_UID) and never overwrites it; the pill stays a separate no-root step; uninstall keeps config+state unless --purge
- bin/byebyte-healthcheck: vitals probe — status.json fresher than 3× its declared poll_interval, control.sock answers ping; exit 0/nonzero with a one-line reason
- bin/byebyte-update + byebyte-update.{service,timer}: daily release CHECK (--check/--json), notify-only — installing stays click-to-install and is an explicit stub until releases are published; the daemon stays networkless
- .github/workflows/ci.yml: smoke + bash -n + py_compile + extension syntax on every push/PR
- CODE_OF_CONDUCT.md, CONTRIBUTING.md, SECURITY.md (threat model: root daemon, peercred+0660 socket, hostile-input doctrine, no network in the daemon)
- README: Install section (two steps, deliberately); make install/uninstall wired to the scripts

## 0.3.0 — M2 index
- byebyted: Indexer — per-directory snapshots (interned paths, min-bytes threshold, 30-scan ring) in stdlib sqlite; socket cmds scan/why/blame; nightly scan hour; live index state in socket status
- byebyte: scan/why/blame verbs — why is age-tagged, blame falls back to the oldest snapshot and reports the honest span
- smoke: fixture-tree index coverage + hostile index input

## 0.4.0 — M3 the hands
- byebyted: compiled-in category registry (hf-hub, pip-cache, uv-cache, thumbnails, project-artifacts, rotated-logs, journald, snap-old) — purge can only delete what a detector positively matches; config may disable a category, never add one; every deletion ledgered to ledger.jsonl
- byebyte purge <category> [--yes]: dry-run by default, `--all` refused (one category per act)
- byebyted/byebyte ghosts: walks /proc/[pid]/fd for deleted-but-open files, groups by (pid, comm), names the mount via mountinfo — report-only, never signals
- byebyted/byebyte ballast: pre-allocated emergency reserve (fallocate'd slabs), built at startup when headroom is comfortable; release needs no free space and writes nothing before the unlink
- byebyted/byebyte kernels: enumerates /boot + dpkg, marks removable kernels (never running, never newest), prints the apt autoremove line — never runs apt
- byebyted/byebyte advise: rule engine over index + status — ETA soon, quota low, fast growers, cold caches, heavy ghosts — one line per finding + --json
- smoke: fixture-based coverage for all five verbs (marker-gating, hostile input, child-held ghost fd, tiny ballast build/release, fixture /boot, growth-driven advise rule)

## 0.5.0 — M4 completion
- byebyted/byebyte burn: samples /proc/<pid>/io twice N seconds apart (write_bytes minus cancelled_write_bytes), reports top writers by rate + mount; seconds clamped 1..30
- man/byebyte.1, man/byebyted.8: groff -man source, config keys + clamps table, security model, files, signals — installed by install.sh, removed by uninstall.sh
- make deb: minimal dpkg-deb package (bins to /usr/bin, units, man pages, config.json as a conffile); postinst/prerm/postrm share the owner_uid seed logic with install.sh via scripts/seed-owner-uid.py; never installed by smoke, only built and inspected
- hardening: systemd unit gets CapabilityBoundingSet (DAC_READ_SEARCH, DAC_OVERRIDE, CHOWN — each documented), SystemCallFilter=@system-service plus quotactl_fd, ProtectKernelTunables, ProtectClock, MemoryDenyWriteExecute, RestrictAddressFamilies=AF_UNIX; fixes ProtectHome=read-only silently blocking purge in real deployments; fixes advise's cold-cache rule triggering a full-filesystem walk via project-artifacts on every call (found by installing and running the hardened unit live)
- tests/attack_socket.py: standalone adversarial harness covering the full command surface plus oversized/garbage/nested/stall; make attack wired into CI alongside make smoke

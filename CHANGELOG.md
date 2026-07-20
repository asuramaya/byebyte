# Changelog

## 0.8.1 — fix: btrfs snapshot detection (V2.M2's first live root run)
- alfred's privileged `sudo make smoke` run exercised the btrfs loop-device fixture for the first time and found `snapshots: 0` against a fixture that definitely has one — `btrfs subvolume list -as <mount>` (bundled `-a`+`-s`, "list only snapshots") turned out unreliable live, despite matching documented flag semantics
- replaced it with `btrfs subvolume show <path>`'s `Parent UUID` field per discovered subvolume — a real (non-`-`) parent UUID means "snapshot of something", and `subvolume show`'s output has stayed far more stable across btrfs-progs versions than `list`'s flag-combination behavior
- `pinned_bytes` was a trivial consequence of the empty snapshot set (summing exclusive bytes filtered by an empty id set is always 0), not a separate quota-timing bug — the fixture's existing `quota rescan -w` was already correct
- smoke: new pure-parsing unit test for `_parse_subvol_show_parent_uuid` (no privilege needed); verified here (unprivileged: parsing unit green, live branch still cleanly skipped, no CAP_SYS_ADMIN in this sandbox) — the actual fix needs alfred's next root pass to confirm `snapshots >= 1` and `pinned_bytes` nonzero for real

## 0.8.0 — V2.M3: burn pid→path attribution
- byebyted: `PathAttribution` — a background fanotify watch (mount-wide, read-only FAN_MODIFY, root/CAP_SYS_ADMIN only, x86_64) answers WHERE a pid writes, aggregated continuously as events arrive rather than resampled per `burn` call; bounded by the new `burn_path_lru` config key (LRU-evicted). Raw ctypes syscalls (fanotify_init/fanotify_mark) — not vendored into sutra (ruling 86a80778: not a primitive); eBPF not needed, fanotify proved sufficient
- `burn`'s writers gain an optional `top_path` (the directory with the most write events for that pid); status.json gains a `burn` section (`available`, `top_paths`) refreshed every poll
- degrade: no CAP_SYS_ADMIN, non-x86_64, or the aggregator thread dying mid-run all fall back to pid-level burn exactly as before — never an error
- byebyte burn: prints the directory alongside the mount when present
- man pages: byebyted.8 documents the fanotify watch + `burn_path_lru`; byebyte.1 documents `burn`'s path-naming behavior
- smoke: status.json shape gains the `burn` section check; the burn fixture asserts `top_path` matches the writer's real directory under root, and asserts its clean absence off root (verified here — no CAP_SYS_ADMIN in this sandbox, so only the degrade path ran; the live fanotify path needs a real root confirmation, same as V2.M2's btrfs branch)

## 0.7.1 — fix: `sudo make smoke` (root-run acceptance bar)
- three of byebyted's test-only escape hatches (`BYEBYTE_TEST_HOME`, `BYEBYTE_TEST_BOOT`, the `ballast_bytes` config override) are non-root-only by design — the daemon must never let an env var or config value redirect where a privileged process touches disk. That's correct and untouched, but it meant `sudo make smoke` broke: root silently fell through to the REAL home/boot/ballast-size instead of the fixtures, failing the hf-hub purge dry-run first (found live by the operator, reproduced by alfred) and would have failed kernels/ballast right after
- smoke.sh: detects root once (`ROOT_SMOKE`); under root, disables ballast outright (`ballast_gb: 0`, since the real multi-GB build isn't appropriate for a smoke pass and risks this box's own tmpfs quota) and relaxes the hf-hub/kernels assertions to real-data-agnostic invariant checks (still meaningful — no crash, no candidate is ever the running/newest kernel — just not fixture-exact, since root correctly can't be redirected there)
- unprivileged `make smoke` behavior is unchanged (verified green); the root path was sanity-checked by forcing the new branches without real root (crash-free, correct skip messages) but the actual root-only behavior (BYEBYTE_TEST_HOME/BOOT being refused) still needs a real `sudo make smoke` run to fully confirm

## 0.7.0 — V2.M2: btrfs truth (read-only)
- byebyted: `btrfs_info()` — read-only subvolume/snapshot/qgroup accounting via the `btrfs` CLI (optional soft dependency, see packages.txt); `pinned_bytes` sums the EXCLUSIVE bytes held only by snapshots, i.e. data a plain walk of the live tree can never see. No mutation ever (no `quota enable`, no snapshot verbs — that's M4 policy territory). Absent CLI or disabled quotas degrade to a reason string, never an error.
- status.json: btrfs mounts gain a per-mount `btrfs` section (subvolumes, snapshots, pinned_bytes, quotas_enabled)
- why/blame: gain an optional `btrfs` notice when the queried path/root lives on a btrfs mount ("N snapshots pin XG the walk can't see", or an unavailable-accounting reason)
- byebyte: why/blame print the new notice line
- pill: subtitle re-skins to lead with the pinned amount when snapshot-pinned space is at least 20% of a mount's total; per-mount rows gain a `[snap pin XG]` tag
- packages.txt: new file documenting btrfs-progs (and the pre-existing snapd) as soft dependencies
- smoke: pure parsing unit test for the subvolume-list/qgroup-show parsers (always runs); a loop-device fixture (subvolume + read-only snapshot pinning deleted data) exercises the live path when root/btrfs-progs/loop are available, skips cleanly otherwise (CI-safe)

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

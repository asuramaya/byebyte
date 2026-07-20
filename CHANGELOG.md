# Changelog

## 0.9.0 — V2.M4: sweep (the unattended reclaim policy)
- byebyted: `sweep(force_dry, cfg, indexer)` — double-consent unattended reclaim per docs/V2-SPEC.md M4 and UNIFY.md's ledger/notification specs. Consent #1 is the new `byebyte-sweep.timer` (disabled by default); consent #2 is the new `sweep_categories` config key (list of REGISTRY category ids to arm — validated as a subset, config can never widen beyond the compiled-in registry, same invariant `purge_disabled` already established in the other direction)
- an unarmed category, or the whole call under `--dry`, only ever previews: reports what it would reclaim and ledgers a `dry_run` entry (only when there's something to report, to keep the ledger from filling with empty "nothing found" lines every timer tick), never touches disk. Armed categories reuse purge's own compiled-in detect/delete functions verbatim to actually reclaim, ledgering `sweep:<category>` per act
- kernels stay report-only, unconditionally, even if named in `sweep_categories` (validated away): `kernels()` carries M3's own "never runs apt" invariant, and unattended kernel removal is a materially different, higher-stakes capability that needs its own explicit authorization — not bundled silently into this milestone. Ghosts (kill-after-confirm) and ballast (expiry) aren't reclaim categories here at all yet, for the same reason — no policy classifier or expiry definition has been ruled on; flagged to alfred rather than guessed
- byebyte: new `sweep [--dry]` verb; prints per-category previews/results, fires a best-effort `notify-send` toast into the owner's desktop session (via `/run/user/<uid>/bus` + `runuser`) when an armed category actually reclaims something — never required, silently does nothing without an active login session
- status.json's `daemon` section gains `owner_uid` (needed by the CLI to target the notification at the right session)
- new `systemd/system/byebyte-sweep.service` + `.timer` (disabled by default, installed by install.sh, removed by uninstall.sh, packaged by make deb); `packages.txt` documents `libnotify-bin` as sweep's soft dependency for the toast
- smoke: full dry-run→armed→ledger cycle (hf-hub armed via the fixture config, every other category stays unarmed — both paths exercised in one pass, ordered after the M3 purge section so its own hf-hub fixture check isn't disturbed); attack extends the command surface with hostile `sweep` inputs (safe by construction — the attack fixture arms nothing)

## 0.8.4 — fix: make deb race condition (0.8.3's fix wasn't the root cause)
- 0.8.3's lintian hardening was correct but didn't fix alfred's actual bug: he forensically boxed an impossible paradox (`make deb` returns rc=1, yet its captured log shows complete success, and a mysterious level-1 sub-make "Leaving directory" line appears despite smoke.sh having exactly one make call)
- real root cause: `DEBROOT`/`DEBFILE` (the deb staging directory and the smoke-test log path) were FIXED, non-unique paths — `build/deb/byebyte_<version>_all[.deb]` and `/tmp/byebyte-deb-build.log`. This dev box runs concurrent smoke passes constantly (root and unprivileged, different agents, same checkout); two concurrent `make deb` invocations racing on the same staging directory and log file produces exactly alfred's paradox — one process's real failure, with the OTHER (successful) process's clean output clobbering the shared log by the time anyone reads it
- reproduced directly: a leftover ROOT-owned staging directory from a prior privileged run permission-denied every file in an unprivileged `rm -rf` of the same fixed path — the exact class of cross-run interference this predicts
- fix: `DEBROOT` is now per-invocation-unique (random suffix); the final `DEBFILE` name stays canonical (it's the real release artifact name) but is only ever populated via an atomic `mv` from a per-invocation temp build target, so concurrent builds can never leave it torn; smoke.sh's log path is now `mktemp`-unique instead of fixed, and its `DEBFILE` lookup is now deterministic (derived from VERSION, matching the Makefile) instead of an ambiguous "most recently modified" glob
- verified: make smoke + make attack green; 4 fully concurrent `make deb` invocations all succeeded independently with zero staging-directory leakage, including with the leftover root-owned directory still present and untouched

## 0.8.3 — fix: silent `make deb` failure under root
- alfred's root-run `sudo make smoke` failed at the deb section with no visible error — the log ended cleanly after "-- built ..." and "-- lintian not installed, skipping", yet `make deb` exited nonzero. The prime suspect: the terse `command -v lintian >/dev/null 2>&1 && lintian $(DEBFILE) || echo "..."` one-liner, whose exit status is unambiguous on paper (`(A && B) || C`) but is exactly the kind of clever compound this class of bug hides in
- rewritten as an explicit `if`/`else`/`fi`: run lintian if present (its own exit code discarded via `|| true` — warnings are just warnings, never a build failure), otherwise print the skip message. Deterministically exits 0 either way; verified here both with lintian genuinely absent (unchanged output) and with a fake lintian simulating a warning-exit (correct output, no misleading "not installed" message, exit 0)
- bonus catch made while in there: `check-sutra`'s freshness check used `$HOME` to find the canonical sutra checkout, which is `/root` under sudo — silently skipping the check (not failing it) rather than genuinely comparing. Now resolves the real invoking user's home via `SUDO_USER`/`getent passwd`, falling back to `$HOME` when not run under sudo
- make smoke + make attack green (unprivileged); still needs alfred's next root pass to confirm the actual silent-failure mechanism is gone — I could not reproduce the failure itself without root, only hypothesize and harden against his named suspect

## 0.8.2 — fix: btrfs pinned_bytes (V2.M2's second live root run)
- alfred caught this one live with a hand-built raw fixture: `btrfs qgroup show -reF --raw <mount>` — the `-F` filters to qgroups impacting the GIVEN PATH, which at the mount root means only the toplevel qgroup; every child (snapshot) subvolume's qgroup row is excluded entirely. `pinned_bytes` summed exclusive bytes over an intersection with `snap_ids` that was structurally always empty, regardless of anything else being correct
- fix: drop `-F` — `qgroup show -re --raw` returns every qgroup, toplevel and children alike, matched against snapshot subvolume ids exactly as before. Column format unchanged, so `_parse_qgroup_show` needed no changes, only the flag
- snapshot detection itself (0.8.1's Parent UUID fix) is confirmed correct on real hardware: alfred's root run reported `snapshots: 1`
- unverified in this sandbox as always (no CAP_SYS_ADMIN) — alfred's next root pass covers three proofs at once: root-smoke end-to-end, btrfs live (this fix), and fanotify live (never yet reached)

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

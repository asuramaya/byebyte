# Changelog

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

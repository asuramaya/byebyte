# ByeByte M3 — the hands (spec for werner)

Authored by alfred (coordinator, house bytebye), 2026-07-14. Doctrine:
`~/code/REPOS/FAMILY.md`. Read `PLAN.md` first; this spec turns its M3 line
into buildable scope. Nothing here is optional unless marked.

## Scope

Five verbs land: `purge` · `ghosts` · `ballast` · `kernels` · `advise`.
Version 0.4.0. The daemon stays stdlib-only. Nothing is ever committed to git.

## The invariant (build this first, everything hangs off it)

A compiled-in **category registry** in `byebyted`. Purge can ONLY delete what
a detector positively matches. Config may DISABLE categories
(`purge_disabled: [ids]`); no config key can add paths or categories — a
tampered config cannot weaken safety (phanspeed doctrine). The socket refuses
any purge naming an unknown category or carrying a raw path. Smoke must prove
the refusal.

Registry seed (id → detect → delete strategy):
- `hf-hub`: `~<owner>/.cache/huggingface/hub/models--*` dirs → rm tree
- `pip-cache`: `~/.cache/pip` → rm contents
- `uv-cache`: `~/.cache/uv` → rm contents
- `project-artifacts` (kondo-style, marker-gated): `node_modules` beside
  `package.json`; `.venv`/`venv` containing `pyvenv.cfg`; `target` beside
  `Cargo.toml` → rm tree. Marker missing → NOT a match, refuse.
- `rotated-logs`: `/var/log/*.{1,2,3...}(.gz|.xz)?` + `*.old` → rm files
- `journald`: delete nothing ourselves — shell out
  `journalctl --vacuum-size=<config, default 1G>`
- `snap-old`: disabled revisions from `snap list --all` → `snap remove
  --revision=N` (root only; skip cleanly when snap absent)
- `thumbnails`: `~<owner>/.cache/thumbnails` → rm contents
Docker is deliberately ABSENT until an API-based accounting lands (doctrine 4
of the invariants in FAMILY.md; generic walks lie about overlayfs).

Detector rules: never follow symlinks; stat st_dev must match the parent
(never cross devices); resolve with os.path.realpath and verify the result
is still inside the matched root. Owner-home paths derive from
`owner_uid`'s passwd entry, not $HOME.

## Verbs

- `purge <category> [--yes]` — socket `{"cmd":"purge","category":c,
  "dry_run":bool}`. Dry-run is the DEFAULT and lists candidates + bytes from
  the index when fresh, direct walk otherwise. `--yes` executes. Every
  deletion appends one JSONL line to `/var/lib/byebyte/ledger.jsonl`
  (ts, category, path, bytes, ok|error) — coldspot's ledger, storage dialect.
  CLI prints freed total. `purge --all` is refused (one category per act).
- `ghosts` — walk `/proc/[0-9]*/fd`, readlink targets ending in
  ` (deleted)`, fstat size, group by (pid, comm), report per-holder and
  total. Report-only in M3: name the holder, print its pid, DO NOT signal.
  Include the mount each ghost lives on (major:minor → /proc/self/mountinfo)
  so tmpfs-quota ghosts (the 2026-07-13 incident) are called out explicitly.
- `ballast` — `/var/lib/byebyte/ballast/slab.<n>`, fallocate'd to
  `ballast_gb` total (config, default 2, clamp 0–32, 0 = off), created by
  the daemon on startup when headroom is comfortable (> 4× ballast size).
  `ballast release` unlinks the slabs — deletion needs no free space, and
  the code path must allocate nothing (no status write, no ledger write
  before the unlink; ledger after, best-effort). `ballast status` shows
  slabs + bytes. Rebuild happens on next daemon startup, never automatically
  mid-flight.
- `kernels` — enumerate `/boot/vmlinuz-*` + `dpkg -l 'linux-image-*'`
  (degrade to /boot listing when dpkg is absent), mark candidates =
  installed, not running (`os.uname().release`), not the newest. M3 reports
  and prints the exact `sudo apt autoremove --purge` line — it does NOT run
  apt. Refuse to ever list the running or newest kernel as a candidate.
- `advise` — rule engine over index + status, each nudge one line +
  machine-readable via `--json`:
  1. mount ETA-to-full < 14d → say which and the burn
  2. top `blame` grower over the last two snapshots > 2G/day → name it
  3. any registry category > 5G AND newest_mtime > 90d → "cold cache"
  4. ghosts total > 1G → point at `byebyte ghosts`
  5. quota remaining < 20% of limit → the EDQUOT early-warning

## Socket & CLI

All new cmds follow the existing dispatch: typed validation, ValueError on
hostile input, `{"error": ...}` replies, peercred gate unchanged. CLI verbs
replace their PLANNED stubs; each supports `--json`.

## Smoke (extend tests/smoke.sh — all fixture-based, NEVER real paths)

- Build a fake owner-home in the fixture tree (hf hub layout with a dummy
  `models--test--x/blob`, a `node_modules`+`package.json` pair, one without
  the marker). Point the daemon at it (add a test-only config override
  `registry_home` — root-only ignored in prod? NO: derive owner-home via
  passwd normally, but allow `BYEBYTE_TEST_HOME` env override honored ONLY
  when the daemon is not uid 0. Document that gate in a comment).
- purge dry-run lists the marked `node_modules`, NOT the marker-less one.
- purge --yes deletes it, ledger line appears, bytes match.
- purge with category "raw-path" or a path string → error, daemon alive.
- ghosts: child process opens a tmpfile, unlinks it, holds the fd → ghosts
  names that pid; kill child, ghost gone.
- ballast: tiny ballast_gb equivalent via a test override (`ballast_bytes`
  config honored under the same non-root gate), release at full-disk is
  simulated by asserting the release path performs zero writes before
  unlink (inspect with strace if available, else code-review assertion).
- kernels: assert the running kernel is never in candidates.

## Verification gate

`make smoke` green, `py_compile` both bins, healthcheck still exits 0
against a live temp daemon, CHANGELOG `## 0.4.0 — M3 the hands`, VERSION +
daemon constant bumped. Reply to alfred by OSIRIS mail with the smoke tail
and the ledger line from the purge test.

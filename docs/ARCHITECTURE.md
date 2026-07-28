# How ByeByte is built

For anyone picking up the code, including a future maintainer who wasn't here when it was
written. If you want to *use* ByeByte, [USAGE.md](USAGE.md) is the document you want.

## The shape of the thing

House doctrine, shared with the rest of the family: **a daemon that owns the truth, a verb
CLI over it, and a GNOME pill on top.** State on disk is the seed, never the master.

`src/bin/byebyted` is the only privileged actor. It owns the truth about bytes at rest:
statvfs and tmpfs-usrquota polling, EWMA burn rate, ETA-to-full, a per-directory sqlite
index, and the category registry that `purge` and `sweep` act through. `src/bin/byebyte` is a
thin verb CLI that talks to it over a control socket and prints the answer. Nothing above
that socket ever needs privilege.

```
GNOME pill ──reads──▶ status.json
                              ▲
byebyte <verb> ──JSON over AF_UNIX──▶ byebyted ──writes──▶ status.json, index.db, ledger.jsonl
```

## The status.json seam

`/run/byebyte/status.json`, mode 0640, owned by the configured `owner_uid`, written
atomically (temp file + rename) by the daemon's poll loop. The pill watches it with
`Gio.FileMonitor`, which is event-driven, no polling, and never needs root. `byebyte status`
reads the same file when it's fresh enough, and falls back to a live socket query
otherwise.

The control socket, `/run/byebyte/control.sock`, is newline-delimited JSON, mode 0660, with
every connection additionally checked against `SO_PEERCRED`: only root or `owner_uid` may
issue commands. Two independent gates, so a mode-bit mistake alone can't open it up.
`BYEBYTE_RUNTIME_DIR` overrides both paths, for testing.

## Where everything lives

`src/` is the one row that groups four directories rather than naming one thing: `bin/`,
`data/` and `extension/` all live under it, so this map matters more than it used to, since
the root listing no longer shows them individually.

| Path | What it is |
|---|---|
| `src/bin/byebyted` | the daemon. Truth engine, index, registry, control server |
| `src/bin/byebyte` | the verb CLI, a thin socket client |
| `src/bin/byebyte-healthcheck` | thin wrapper over `sutra.check_health`: is status.json fresh, does the socket answer a ping |
| `src/bin/byebyte-update` | thin wrapper over `sutra_update.py`, pill name `byebyte`. `auto_enabled` is hardcoded `False`, so the timer only ever checks and never installs unattended |
| `src/bin/sutra.py` | the family's shared daemon skeleton, vendored byte-identical from `sutra`: config load/clamp, `write_status`, the EWMA helper, `ControlServer` |
| `src/bin/sutra_update.py` | the shared update spine: the three consent tiers, signature verification |
| `src/bin/sutra_xen.py` | vendored unconditionally per the family's vendor script; unused by ByeByte today, same as every other pill |
| `src/bin/*.version`, `src/bin/*.commit` | drift anchors for each vendored file: integrity hash and the canonical commit it was vendored from |
| `src/extension/byebyte@asuramaya/` | the GNOME pill: `extension.js` is the tile, `pill.js` is the family's shared extension commons (status parsing, formatting, the update-surface widget) |
| `src/data/config/config.json` | the seed config installed to `/etc/byebyte/config.json` on first install, never overwritten after |
| `src/data/systemd/system/` | `byebyted.service`; `byebyte-sweep.service` + `.timer` (disabled by default, the unattended-reclaim opt-in); `byebyte-update.service` + `.timer` (daily, `--check` only) |
| `src/data/man/man1/byebyte.1`, `src/data/man/man8/byebyted.8` | the man pages, groff source, kept in sync with USAGE.md by hand, split by section (a daemon manual belongs in section 8) |
| `packaging/release-signing/allowed_signers` | the release-verification trust anchor. See [RELEASE-SIGNING.md](RELEASE-SIGNING.md) |
| `packaging/scripts/seed-owner-uid.py` | the config-seeding logic shared between `install.sh` and the `.deb`'s `postinst`, so they can't drift apart |
| `packaging/deb/` | `.deb` maintainer scripts (`postinst`, `prerm`, `postrm`). `make deb` builds the package; it never installs it |
| `packaging/packages.txt` | the apt packages the installer needs |
| `packaging/VERSION` | the one version constant. `src/bin/byebyted` and `src/bin/byebyte-update` both read it at runtime rather than carrying their own copy; CI asserts it equals the git tag at release |
| `docs/CHANGELOG.md` | what changed, and when |
| `tests/` | `smoke.sh`, `test_signing.sh`, `attack_socket.py` |
| `install.sh`, `uninstall.sh` | the root installer and its symmetric removal |

## The two install layouts

Unlike the family's user-scope pills, ByeByte's checkout install is root-scope too: there's
a real root daemon and system-wide state, so both layouts land in the same places.

The **checkout** path (`sudo ./install.sh`) installs binaries to `$PREFIX/bin`
(`$PREFIX` defaults to `/usr/local`), the vendored spine and the release-signing anchor to
`$PREFIX/share/byebyte`, seeds `/etc/byebyte/config.json` once, and enables `byebyted` plus
the daily update-check timer. It never re-execs itself as root, an incident-driven
doctrine after a past sibling repo misattributed the human user to root by self-elevating.
So `install.sh` checks `EUID` itself and prints guidance if `sudo` was forgotten, rather than
quietly re-invoking itself.

The **`.deb`** path (`sudo dpkg -i byebyte_*.deb`) installs the same files under `/usr`
instead of `/usr/local`, and its `postinst` runs the identical config-seed and
systemd-enable logic via `packaging/scripts/seed-owner-uid.py`, the piece factored out specifically so
the two paths can't drift.

Both layouts have to ship the **full vendored set**: `sutra.py`, `sutra_update.py`,
`sutra_xen.py`, and the release-signing anchor. Skip one and an install works until the
first update, then dies on an import. `tests/smoke.sh` asserts the `.deb`'s contents directly for
exactly this reason; it's a mistake this family has made more than once.

The GNOME pill is always a separate, no-root step (`make pill`, or `.deb`'s own activation
instructions) since it only ever touches the installing user's own `$HOME` and gnome-shell
session.

## The update path

`byebyte update` runs `src/bin/byebyte-update`, a thin wrapper over `src/bin/sutra_update.py`. That
file is vendored byte-identical from `sutra`, and `make check-sutra` proves it: integrity
(the hash in the matching `.version` file) is a hard failure if it doesn't match. Freshness
is a LAG-vs-DRIFT read against canonical git, when a canonical checkout is present (normally
isn't in CI): the recorded `.commit` at or behind canonical HEAD is LAG and warns; not in
canonical's history at all is DRIFT and fails.

Verification is two independent implementations of the same check, deliberately, since
ByeByte's `install.sh` bootstrap can't depend on the Python it's about to install:

- `sutra_update.py`'s `verify_dir()`, used by `byebyte update` / `byebyte-update` once a
  checkout or `.deb` install already exists.
- `install.sh`'s own `verify_signature()`, used by the `curl -fsSL … | sudo bash` bootstrap,
  against an embedded copy of the anchor (`RELEASE_ALLOWED_SIGNERS`) since no
  `packaging/release-signing/` file exists on disk yet at that point.

Both degrade to SHA256-only-with-a-warning while the anchor is unarmed, and fail closed
forever once it's armed. The full trust chain (why SSH signatures, why a FIDO2 key, the
principal/namespace split, the arm-then-seal ceremony) is in
[RELEASE-SIGNING.md](RELEASE-SIGNING.md).

## The invariants

Hardcoded in the daemon, not configurable, house security doctrine:

1. **Nothing is ever deleted unless a compiled-in category detector positively matches
   it.** Config can disable a category (`purge_disabled`); it can never add a raw path or a
   new category. A tampered config cannot weaken safety.
2. **Emergency verbs work at 100% full.** `ghosts`, `ballast release` and a targeted `purge`
   have to run from a bare TTY when things are worst. `ballast release`'s own code path
   allocates nothing before the unlink, so freeing space never itself needs free space.
3. **Headroom is effective headroom**: `min(free, quota remaining)` per mount, read via
   `quotactl_fd(2)` on x86_64. Born from a real incident: EDQUOT on a tmpfs `/tmp` while
   `df` reported 11% used, because `df` can't see a usrquota limit tighter than the
   filesystem itself.
4. **Docker is out of scope** until it can be accounted via its own API. A generic
   directory walk gets overlay storage wrong, and this family doesn't ship detectors that
   lie. See Standard exemptions, below.

## The category registry

Eight categories, id → what matches, all in `src/bin/byebyted`: `hf-hub` (Hugging Face hub
cache), `pip-cache`, `uv-cache`, `thumbnails`, `project-artifacts` (kondo-style:
`node_modules` beside `package.json`, a `.venv` containing `pyvenv.cfg`, `target` beside
`Cargo.toml`; the marker is required, never inferred), `rotated-logs`, `journald` (shells
out to `journalctl --vacuum-size`, deletes nothing itself), `snap-old` (disabled snap
revisions, root only). Every detector resolves symlinks and refuses to cross device
boundaries or leave the matched root.

`purge <category>` acts on one category at a time (`--all` is refused) and is dry-run by
default. `sweep` reclaims unattended, gated by double consent: the `byebyte-sweep.timer`
unit enabled (opt-in #1) and the category named in `sweep_categories` (opt-in #2, itself
constrained to a subset of this same registry; config can arm a category, never invent
one). Either opt-in missing means every category only previews and ledgers a `dry_run`
entry. Kernel removal (`kernels`) stays report-only unconditionally, even under `sweep`,
since unattended removal is a materially different capability that hasn't been authorized.

Every purge, sweep act, and ballast release appends one line to
`/var/lib/byebyte/ledger.jsonl`: timestamp, category, `target`, bytes, status. Lines
written before the `target` field existed used `path` for the same thing; history is never
rewritten, and readers treat `path` as a legacy alias.

## btrfs and burn attribution

On a btrfs mount, a plain directory walk lies about space, since subvolumes and snapshots
share extents. When the `btrfs` CLI is present (a soft dependency, documented in
`packaging/packages.txt`), `byebyted` shells out to it for read-only subvolume/snapshot/qgroup
accounting; absent the CLI or with quotas disabled, `why` and `blame` degrade to the plain
walk plus a one-line notice, never an error. Nothing here ever mutates the filesystem.

`burn` samples `/proc/<pid>/io` twice, a few seconds apart, to name the pids writing
fastest. When `CAP_SYS_ADMIN` is available (root, x86_64), a background `fanotify(7)` watch
additionally names *which directory* each pid is writing to, aggregated in memory and capped
at `burn_path_lru` entries (oldest evicted first) so a hostile write pattern can't grow it
without bound. Absent the capability or on another architecture, `burn` names pids only,
exactly as before, never an error.

## Conventions worth knowing before you edit

* Every static check that matters is mechanical, wired into `make check` (which itself
  depends on `make check-sutra`, the vendored spine's integrity and freshness check). A
  convention that isn't wired into `make` is a wish, not a rule.
* The category registry is the only path to deletion. A new cleanup idea is a new detector
  with its own positive match, never a config-driven path.
* Device names, discovered devices, and anything else that comes from outside the machine
  don't apply here. ByeByte's only external input is the filesystem itself, so path
  handling (symlink resolution, device-boundary checks, realpath containment) is the
  equivalent hostile-input surface, and every detector goes through it.
* Owner-home paths are derived from `owner_uid`'s passwd entry, never `$HOME`. The daemon
  runs as root, and `$HOME` there means nothing.

## Standard exemptions

ByeByte's declared departures from the family repo standard. Anything the standard asks for
that ByeByte doesn't have is listed here. A gap that isn't in this table is a bug, not a
choice.

| Item | Why |
|------|-----|
| no Docker/container accounting | generic directory walks get overlay storage wrong; this needs API-based accounting that hasn't been built yet (invariant 4, above) |
| no eBPF burn sampling | fanotify path attribution has been sufficient so far; eBPF stays a possible future build-time addition, not a primitive vendored into `sutra` |

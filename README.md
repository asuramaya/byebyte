# byebyte

[![ci](https://github.com/asuramaya/byebyte/actions/workflows/ci.yml/badge.svg)](https://github.com/asuramaya/byebyte/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/asuramaya/byebyte?sort=semver)](https://github.com/asuramaya/byebyte/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Say bye to bytes. The storage sibling of [kast](https://github.com/asuramaya/kast)
(casting), [coldspot](https://github.com/asuramaya/coldspot) (internet) and
[phanspeed](https://github.com/asuramaya/phanspeed) (power): a root daemon that owns the
truth about your disks, a verb CLI over it, and a GNOME Quick Settings pill on top.

Where `df` tells you a percentage, byebyte tells you a *deadline*: free space, burn rate,
and time-until-full, including quota headroom on tmpfs, where "disk full" errors happen
while `df` swears everything is fine.

```
byebyte status     # headroom, burn rate, ETA-to-full per mount
```

That's the read-only half. The other half reclaims space, and only from a fixed, compiled-in
list of things it's allowed to touch, never a path you type in:

| | |
|---|---|
| `why` / `blame` | instant du-tree from a background index, and a "what grew since" diff |
| `purge <category>` | delete what a category detector positively matches: caches, old kernels, kondo-style dead project artifacts, rotated logs, and more. Dry-run by default |
| `ghosts` | deleted-but-open files still holding disk blocks, and who's holding them |
| `ballast` | a pre-allocated emergency reserve you can release even at 0 bytes free |
| `sweep` | the same reclaim, unattended. Off unless you double opt in |
| `burn` | live per-process write rates, with the writing directory named when running as root |

On a btrfs mount, `why` and `blame` read the filesystem's own subvolume and snapshot
accounting instead of a plain walk, which lies about space that snapshots pin.

## Install

Two deliberate steps: one needs root, one never does:

```sh
sudo ./install.sh                          # daemon + CLI + healthcheck + updater + units
make pill                                  # as yourself, no sudo: the GNOME pill into YOUR account
gnome-extensions enable byebyte@asuramaya  # then log out/in once (Wayland)
```

`install.sh` is root-only and says so plainly if you forget `sudo`. It never re-invokes
itself, so there's exactly one privilege hop, always, and no ambiguity about which account
it's acting on. It installs the daemon, CLI, `byebyte-healthcheck` and `byebyte-update`,
seeds `/etc/byebyte/config.json` **once** (your `owner_uid`, from the sudo call; an existing
config is never overwritten), and enables `byebyted` plus a daily update **check** timer,
which only ever notifies and never installs unattended. It does *not* touch the GNOME pill:
that only ever needed your own `$HOME` and your own gnome-shell session, never root, so
`make pill` is its own per-account step.

Or from a checkout: `sudo make install`, then `make pill`.

There's also a `.deb` on the
[latest release](https://github.com/asuramaya/byebyte/releases/latest), or the one-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/asuramaya/byebyte/main/install.sh | sudo bash
```

which fetches and verifies the published `.deb` when no local checkout is present. Either
way, the `.deb` and the checkout install land in the same places; see
[ARCHITECTURE.md](docs/ARCHITECTURE.md) if you're curious why.

## First run

Log out and back in. Wayland can't hot-reload shell extensions, so the byebyte tile appears
in Quick Settings only at your next login. Then:

```sh
byebyte status
```

The byebyte tile now sits beside Wi-Fi and Bluetooth in the system menu, heating up as the
nearest mount's ETA-to-full shrinks.

## Everyday use

```
byebyte status                  headroom, burn rate, ETA-to-full per mount
byebyte why /var/log            instant du-tree from the index, age-tagged
byebyte purge pip-cache         dry-run by default; --yes to execute
byebyte ghosts                  deleted-but-open files still holding blocks
byebyte advise                  one-line nudges: what's worth looking at
```

Every command, every category, the tile and the config keys are documented in
[docs/USAGE.md](docs/USAGE.md) and `man byebyte`.

## Updating

```sh
byebyte update            # update in place from the latest release
byebyte update --check    # just say whether one is available
```

Before it installs anything, `byebyte update` verifies the release against its published
`SHA256SUMS` manifest, and its SSH signature once the trust anchor is armed. It's the same
trust chain a fresh install uses, written up in
[docs/RELEASE-SIGNING.md](docs/RELEASE-SIGNING.md). There is no unattended-install tier: the
daily timer only ever checks and notifies.

## Uninstall

```sh
sudo ./uninstall.sh            # remove byebyte, keep config and state
sudo ./uninstall.sh --purge    # also remove /etc/byebyte and /var/lib/byebyte
```

## Security

byebyte's only privileged actor is the daemon. Its control socket is peercred-gated: only
root or the configured owner may issue commands, on top of its own restrictive file mode.
Deletion is never path-driven: `purge` and `sweep` can only act on what a compiled-in
category detector positively matches, and a tampered config can disable a category but never
add one. `install.sh` and `byebyte update` fetch over HTTPS and verify checksum and signature
before installing anything.

The full threat model, and how to report a vulnerability privately, is in
[SECURITY.md](SECURITY.md).

Free software, GPLv3, stdlib-only Python. No telemetry, no product, no website. The dream
is upstream. byebyte belongs to a family of small GNOME utilities that share a runtime
backbone, an update spine and a signed-release chain.

# byebyte

Say bye to bytes. The storage sibling of
[coldspot](https://github.com/asuramaya/coldspot) (internet) and
[phanspeed](https://github.com/asuramaya/phanspeed) (power): a daemon that
owns the truth about your disks, a verb CLI over it, and a GNOME
Quick Settings pill on top.

Where `df` tells you a percentage, byebyte tells you a *deadline*: free
space, burn rate, and time-until-full — including quota headroom on tmpfs,
where "disk full" errors happen while `df` swears everything is fine.

```
byebyte status     # headroom, burn rate, ETA-to-full per mount
```

Status: **M0** — the truth engine (statvfs + quota polling, burn/ETA,
status.json, control socket). See [PLAN.md](PLAN.md) for the road:
`why` · `blame` · `purge` · `ghosts` · `ballast` and the pill.

## Install

Two steps, deliberately — one needs root, one never does:

```sh
sudo ./install.sh                          # daemon + CLI + healthcheck + updater + units
make pill                                  # as yourself, no sudo — the GNOME pill into YOUR account
gnome-extensions enable byebyte@asuramaya  # then log out/in once (Wayland)
```

`install.sh` is root-only and says so plainly if you forget `sudo` — it never
re-invokes itself, so there's exactly one privilege hop, always, and no
ambiguity about which account it's acting on. It installs the daemon, CLI,
`byebyte-healthcheck` and `byebyte-update`, seeds `/etc/byebyte/config.json`
**once** (your `owner_uid`, from the sudo call; an existing config is never
overwritten), and enables `byebyted` plus a daily update **check** timer —
which only ever notifies, it never installs unattended. It does *not* touch
the GNOME pill: that only ever needed your own `$HOME` and your own
gnome-shell session, never root, so `make pill` is its own per-account step.

Or from a checkout: `sudo make install`, then `make pill`.

Remove with `sudo ./uninstall.sh` (keeps `/etc/byebyte` and
`/var/lib/byebyte`; add `--purge` to drop them too).

Free software, GPLv3, stdlib-only Python. No telemetry, no product,
no website — the dream is upstream.

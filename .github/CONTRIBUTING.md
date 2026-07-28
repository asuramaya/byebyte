# Contributing to byebyte

Thanks for your interest! byebyte is small and dependency-free on purpose —
keep changes simple and self-contained.

## Project layout

See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the repo map. It's
the only one in the tree on purpose, so it can't drift out of sync with a
second copy here.

## Dev setup

No build step. The daemon runs fine as an unprivileged user against a temp
runtime dir, which is exactly what the smoke test does:

```bash
make smoke                          # must print "SMOKE OK"
python3 -m py_compile src/bin/byebyted src/bin/byebyte src/bin/byebyte-healthcheck src/bin/byebyte-update
```

To poke it by hand:

```bash
RD=$(mktemp -d)
echo '{"poll_interval": 2, "owner_uid": '"$(id -u)"'}' > "$RD/config.json"
BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyted --config "$RD/config.json" &
BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte status
BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte-healthcheck
```

For the pill, after editing `src/extension/byebyte@asuramaya/extension.js`:

```bash
node --check <(cat src/extension/byebyte@asuramaya/extension.js)   # or copy to .mjs
# install with `make pill` + log out/in (Wayland) to load it, then watch:
journalctl -f -o cat /usr/bin/gnome-shell                      # extension logs
```

## Before opening a PR

- `make smoke` passes (it includes the hostile-input socket assertions).
- Any new config field is **typed, clamped, and defaulted** in `load_config`
  (`DEFAULTS` + `CLAMPS` in `src/bin/byebyted`) — config is the seed, never the
  master; a tampered config must never weaken an invariant.
- Any new socket command treats its input as **hostile by default**: bounded
  reads, JSON only, malformed or unknown input answered with `{"error": ...}`
  — the daemon runs as root and must never crash on bad bytes.
- The daemon and CLI stay **dependency-free** (Python stdlib only) and the
  daemon stays **networkless** — anything that must reach the internet
  belongs in `byebyte-update`, nowhere else.

## License

By contributing you agree your contributions are licensed under
**GPL-3.0-or-later**, matching the project.

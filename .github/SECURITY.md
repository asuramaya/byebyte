# Security Policy

byebyte runs a **root daemon** that accepts commands over a local Unix socket,
so security is taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead use GitHub's
private reporting:

1. Go to the repo's **Security** tab → **Report a vulnerability**.
2. Describe the issue, affected version, and a reproduction if possible.

You'll get a response as soon as reasonably possible.

## Threat model

The relevant attacker is an **unprivileged local process** abusing the root
daemon. The daemon has **no network attack surface at all** — `byebyted` never
opens anything but an `AF_UNIX` socket and never speaks to the internet.

Hardening in place (see `src/bin/byebyted` and `src/data/systemd/system/byebyted.service`):

- **SO_PEERCRED authorization** — only root and the configured `owner_uid`
  may issue commands, checked on every connection *on top of* the socket's
  file mode (`0660`, chowned to `owner_uid`). Two independent gates.
- **All input is hostile by default** — bounded reads (4 KiB line cap, 5 s
  socket timeout), JSON only, a fixed set of known commands (`ping`,
  `status`, `why`, `blame`, `scan`, `purge`, `ghosts`, `ballast`, `kernels`,
  `advise`, `burn`, `sweep`); anything else — garbage bytes, unknown
  commands, non-objects — is answered with `{"error": ...}` and the
  connection dies. Malformed input can never crash the daemon; `make smoke`
  and `make attack` fuzz this on every run.
- **Config is the seed, never the master** — `/etc/byebyte/config.json` is
  typed, clamped, and unknown-key-ignoring on load. A tampered config can
  tune numbers within compiled-in clamps and select mounts; it cannot grant
  the daemon new abilities or weaken an invariant.
- **status.json is the read seam** (mode `0640`, owner `owner_uid`, written
  atomically via tmp + rename) — the CLI and pill read it; nothing above the
  seam ever needs privilege.
- **Sandboxed unit** — `NoNewPrivileges`, `ProtectSystem=strict` with
  write access only to `/run/byebyte` + `/var/lib/byebyte`,
  `ProtectHome=read-only`. (`PrivateTmp` is deliberately **off**: watching
  the real `/tmp` — tmpfs quota ghosts included — is this daemon's job.)

## Update path

The daemon has no network access; `byebyte-update` is the **only networked
piece**, so it gets its own rules:

- The daily `byebyte-update.timer` runs it with **`--check` only** — it
  notifies and logs, it never installs unattended. The service unit runs it
  as an **unprivileged `DynamicUser`**, because checking needs no privilege.
- Installing a new version stays a **deliberate, interactive act**
  (click-to-install doctrine): a bare `byebyte update`, never the timer.
  Every install verifies the release's `SHA256SUMS` manifest, and its SSH
  signature once the trust anchor is armed (it is, as of the release after
  v0.11.0) — see [RELEASE-SIGNING.md](../docs/RELEASE-SIGNING.md).
- The check is bounded: 5 s timeout, 1 MiB response cap, HTTPS to
  `api.github.com` only.

Adversarial socket tests live inside `tests/smoke.sh` and assert the daemon
survives hostile input. Please keep them passing in any security-relevant PR.

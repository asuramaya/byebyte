#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and byebyte contributors
# byebyte installer — the storage demon: daemon, CLI, healthcheck, updater,
# systemd units. Root-only, and ONLY root-only: this script never re-execs
# itself under sudo (a script that quietly escalates itself is exactly what
# once misattributed the human user to "root" in a sibling repo — see
# coldspot's git log). If you're not root, it says so and stops; you always
# type sudo yourself, exactly once, so there is no ambiguity about who
# actually ran it. The GNOME pill is a SEPARATE, per-account, non-root step —
# `make pill` — since installing a file into your own home never needed root
# in the first place.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/byebyte"
UNITDIR="/etc/systemd/system"
EXT_UUID="byebyte@asuramaya"
REPO_SLUG="asuramaya/ByeByte"

# principal = WHO (byebyte's stable identity); namespace = WHAT-FOR (what
# this signature authorizes). Never conflate the two — see ~/code/REPOS/RELEASE.md.
SIGN_PRINCIPAL="byebyte"
SIGN_NAMESPACE="byebyte-release"

# Trust anchor for the curl-pipe-bash bootstrap below, EMBEDDED directly:
# `curl -fsSL .../install.sh | sudo bash` fetches ONLY this file — not the
# sibling release-signing/ directory — so the anchor has to travel embedded
# in whichever copy of this script is currently executing, not be read from
# a file that hasn't been fetched yet (that would mean trusting the very
# release being verified). Ships EMPTY until a key is provisioned (arm-
# first-from-birth, docs/RELEASE-SIGNING.md); kept in sync with
# release-signing/allowed_signers by `mudra sync-signers ByeByte` — never
# hand-edit this. Single-quoted deliberately: the value can span multiple
# lines (one per pinned key) and must never be shell-interpolated. While
# empty, verification degrades to SHA256-only with a printed warning.
RELEASE_ALLOWED_SIGNERS='byebyte namespaces="byebyte-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAvqlv848gk9uzM40ZsFZTQeXsQKpxYaK4Fi8ubNl1H7AAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTE= ra-master-1
byebyte namespaces="byebyte-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFJBKAsk6b4YR2UH/UZ1Rk24PxepTYNkF7zflo01AmlZAAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTI= ra-master-2
byebyte namespaces="byebyte-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHTVqgo3ARbpTq04YlQksobfGIbBAw21nbE6HyeCPgxBAAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTM= ra-master-3
byebyte namespaces="byebyte-release,pills-tag" sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIP15ZeSJYWryHN2WEHDlJbWk/vA+j5JFgb9RSzT1SHveAAAAFnNzaDphc3VyYW1heWEtbWFzdGVyLTQ= ra-master-4
'

# Has a real key been provisioned, or is this still the empty placeholder?
has_signing_key() {
  [[ -n "${RELEASE_ALLOWED_SIGNERS// /}" ]]
}

# True/false: does the detached signature in $2 (a file path) verify $1 (a
# file path, the exact bytes that were signed) against the pinned key(s) in
# $3 (an allowed_signers path), for principal $4 and namespace $5? Principal
# is WHO (byebyte's identity); namespace is WHAT-FOR (what this signature
# authorizes) — a signature made for a different purpose, or by a principal
# not pinned in allowed_signers, must not verify here.
verify_signature() {
  local data_file="$1" sig_file="$2" signers="$3" principal="$4" ns="$5"
  ssh-keygen -Y verify -f "${signers}" -I "${principal}" -n "${ns}" -s "${sig_file}" \
    < "${data_file}" >/dev/null 2>&1
}

# tests/test_signing.sh sources this file (with BYEBYTE_INSTALL_SOURCED=1) to
# reach has_signing_key/verify_signature directly, without running an actual
# install — everything above this point only ever DEFINES functions/vars, so
# returning here before the root check keeps sourcing side-effect-free.
if [[ "${BYEBYTE_INSTALL_SOURCED:-0}" == "1" ]]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

# ---- root, checked FIRST ------------------------------------------------
# Fail fast and plainly rather than self-elevating.
if [[ $EUID -ne 0 ]]; then
  cat >&2 <<'EOF'
byebyte needs root to install (binaries, systemd units, /etc/byebyte). Re-run
with sudo:

  sudo ./install.sh        (or: sudo make install)

The GNOME pill is a separate, no-root step afterwards — as yourself:

  make pill
  gnome-extensions enable byebyte@asuramaya
EOF
  exit 1
fi

# Reached when install.sh runs without its sibling files next to it, i.e.
# `curl -fsSL .../install.sh | sudo bash` — the human types sudo on their
# OWN command line (this script still never re-execs itself; the root check
# above already ran and passed by the time we get here). Fetches the
# published .deb + SHA256SUMS (+ signature once a key is provisioned) and
# dpkg -i's it — the .deb's own postinst does everything the rest of this
# script does for a checkout install (config seed, systemd enable+start),
# so nothing else needs to run afterward.
bootstrap_from_release() {
  command -v curl >/dev/null 2>&1 || { echo "curl is required for remote install" >&2; exit 1; }
  command -v dpkg >/dev/null 2>&1 || {
    echo "dpkg not found — this quick-install path needs a Debian/Ubuntu" >&2
    echo "system. Clone the repo and run install.sh from a checkout instead." >&2
    exit 1
  }

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  local base="https://github.com/${REPO_SLUG}/releases/latest/download"

  echo "== fetching latest byebyte release =="
  curl -fsSL "${base}/SHA256SUMS" -o "${tmp}/SHA256SUMS" \
    || { echo "could not fetch the release checksum manifest (SHA256SUMS) — refusing to install unverified." >&2; exit 1; }
  local debname
  debname="$(awk '$2 ~ /_all\.deb$/ { n = $2; sub(/^\*/, "", n); print n; exit }' "${tmp}/SHA256SUMS")"
  [[ -n "${debname}" ]] || { echo "SHA256SUMS has no .deb entry — aborting." >&2; exit 1; }
  curl -fsSL "${base}/${debname}" -o "${tmp}/${debname}" \
    || { echo "deb download failed" >&2; exit 1; }

  local want got
  want="$(awk -v n="${debname}" '$2 == n || $2 == "*"n { print $1; exit }' "${tmp}/SHA256SUMS")"
  got="$(sha256sum "${tmp}/${debname}" | cut -d' ' -f1)"
  [[ "${want}" == "${got}" ]] || { echo "CHECKSUM MISMATCH for ${debname} — aborting." >&2; exit 1; }
  echo "sha256 verified."

  if has_signing_key; then
    curl -fsSL "${base}/SHA256SUMS.sig" -o "${tmp}/SHA256SUMS.sig" \
      || { echo "signing key is pinned but the release has no SHA256SUMS.sig — refusing to install unsigned." >&2; exit 1; }
    printf '%s\n' "${RELEASE_ALLOWED_SIGNERS}" > "${tmp}/allowed_signers"
    verify_signature "${tmp}/SHA256SUMS" "${tmp}/SHA256SUMS.sig" "${tmp}/allowed_signers" \
      "${SIGN_PRINCIPAL}" "${SIGN_NAMESPACE}" \
      || { echo "SIGNATURE VERIFICATION FAILED — aborting." >&2; exit 1; }
    echo "signature verified."
  else
    echo "warning: no release-signing key provisioned yet (see docs/RELEASE-SIGNING.md) — proceeding on SHA256 alone." >&2
  fi

  dpkg -i "${tmp}/${debname}"
  echo
  echo ">>> the GNOME pill is a separate, per-account, NO-ROOT step — as yourself: <<<"
  echo "  mkdir -p ~/.local/share/gnome-shell/extensions"
  echo "  cp -r /usr/share/byebyte/extension/${EXT_UUID} ~/.local/share/gnome-shell/extensions/"
  echo "  gnome-extensions enable ${EXT_UUID}"
  echo "  (then log out and back in once — Wayland reloads extensions at login)"
}

if [[ ! -f "$SRC/bin/byebyted" ]]; then
  bootstrap_from_release
  exit 0
fi

# The only thing that needs to know about a human account is owner_uid in a
# FRESHLY seeded config (the daemon chowns status.json + control.sock to it).
# Since this script never sudos itself, $SUDO_UID is reliable: it's set by
# whichever single sudo call the human actually typed.
OWNER_UID="${SUDO_UID:-1000}"
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)"

echo "== byebyte ${VERSION} installer =="

# 1. binaries + version marker (root-owned, not group/world writable)
echo "-- binaries -> $BINDIR"
for b in byebyted byebyte byebyte-healthcheck byebyte-update; do
  install -m 0755 -o root -g root "$SRC/bin/$b" "$BINDIR/$b"
done
# sutra + sutra_update are imported modules, not entry points (0644, no
# +x) — but they're siblings byebyted/byebyte/byebyte-healthcheck/
# byebyte-update all `import`, straight from BINDIR, exactly like Python's
# own script-directory sys.path[0] rule expects. The .deb has always done
# this (Makefile's deb: target); install.sh had fallen behind since sutra's
# adoption — a source install would ModuleNotFoundError without this.
install -m 0644 -o root -g root "$SRC/bin/sutra.py" "$BINDIR/sutra.py"
install -m 0644 -o root -g root "$SRC/bin/sutra_update.py" "$BINDIR/sutra_update.py"
install -m 0644 -o root -g root "$SRC/bin/sutra_xen.py" "$BINDIR/sutra_xen.py"
install -d -m 0755 "$SHAREDIR"
install -m 0644 "$SRC/VERSION" "$SHAREDIR/VERSION"
# release-signing trust anchor (docs/RELEASE-SIGNING.md) — empty until a key
# is provisioned; byebyte-update degrades to SHA256-only until it isn't
install -m 0644 "$SRC/release-signing/allowed_signers" "$SHAREDIR/allowed_signers"

# 1b. man pages
echo "-- man pages -> $PREFIX/share/man"
install -d -m 0755 "$PREFIX/share/man/man1" "$PREFIX/share/man/man8"
install -m 0644 "$SRC/man/byebyte.1" "$PREFIX/share/man/man1/byebyte.1"
install -m 0644 "$SRC/man/byebyted.8" "$PREFIX/share/man/man8/byebyted.8"

# 2. config: seeded once, then NEVER overwritten (kept across reinstalls).
# Config is the seed, never the master — a tampered one can't weaken the
# daemon anyway (typed, clamped, unknown keys ignored), but the human's
# tuning survives every reinstall.
if [[ -f /etc/byebyte/config.json ]]; then
  echo "-- /etc/byebyte/config.json exists — keeping it untouched"
else
  echo "-- seeding /etc/byebyte/config.json (owner_uid=$OWNER_UID)"
  if [[ -z "${SUDO_UID:-}" ]]; then
    echo "   couldn't tell which account owns the socket (no \$SUDO_UID —"
    echo "   running from a root shell rather than sudo?). Defaulting"
    echo "   owner_uid to 1000; edit /etc/byebyte/config.json if that's wrong."
  fi
  install -d -m 0755 /etc/byebyte
  # shared with the .deb's postinst (scripts/seed-owner-uid.py) so the two
  # installers can't drift on what "seeding" means
  python3 "$SRC/scripts/seed-owner-uid.py" \
    "$SRC/config/config.json" /etc/byebyte/config.json "$OWNER_UID"
  chmod 0644 /etc/byebyte/config.json
fi

# 3. systemd: daemon + daily update-CHECK timer + the sweep timer (both
# opt-in). update.timer only ever runs `byebyte-update --check` — it
# notifies, it never installs unattended. sweep.timer runs `byebyte sweep`,
# which only ACTS on categories explicitly armed in config.json's
# sweep_categories — everything else stays a dry-run preview regardless of
# whether this timer is enabled (family doctrine: updates and unattended
# reclaim are both click-to-install/opt-in, never on by default).
echo "-- systemd units + enabling"
install -m 0644 "$SRC/systemd/system/byebyted.service"       "$UNITDIR/byebyted.service"
install -m 0644 "$SRC/systemd/system/byebyte-update.service" "$UNITDIR/byebyte-update.service"
install -m 0644 "$SRC/systemd/system/byebyte-update.timer"   "$UNITDIR/byebyte-update.timer"
install -m 0644 "$SRC/systemd/system/byebyte-sweep.service"  "$UNITDIR/byebyte-sweep.service"
install -m 0644 "$SRC/systemd/system/byebyte-sweep.timer"    "$UNITDIR/byebyte-sweep.timer"
systemctl daemon-reload
systemctl enable byebyted.service
# `enable --now` on an ALREADY-active unit is a no-op start — it would leave
# the old binary running in memory even though we just overwrote it on disk.
# Detect a re-install and explicitly restart so the new daemon actually runs.
if systemctl is-active --quiet byebyted.service; then
  echo "-- restarting byebyted to load the updated daemon"
  systemctl restart byebyted.service
else
  systemctl start byebyted.service
fi
# The daily update timer only ever CHECKS (notify-only, unprivileged) — but
# even a check that phones GitHub is opt-in, family-wide. Enable deliberately:
#   sudo systemctl enable --now byebyte-update.timer

# 4. verify perms
echo "-- verifying"
verify() { local got; got="$(stat -c '%a' "$1" 2>/dev/null || echo '?')"
  [[ "$got" == "$2" ]] && echo "   OK   $1 ($got)" || echo "   WARN $1 is $got, expected $2"; }
verify "$BINDIR/byebyted" 755
verify /etc/byebyte/config.json 644

cat <<EOF

== byebyte ${VERSION} installed ==
  byebyte status             headroom, burn rate, ETA-to-full per mount
  byebyte-healthcheck        vitals: fresh status.json + a daemon that answers ping
  byebyte-update --check     is a newer release out? (never installs by itself)
  man byebyte / man 8 byebyted   full verb reference, config keys, security model
  Remove:  sudo ./uninstall.sh   (keeps /etc/byebyte + /var/lib/byebyte; --purge drops them)

daily update CHECK is off by default (it's notify-only, never installs). Opt in:
  sudo systemctl enable --now byebyte-update.timer

sweep (unattended reclaim) is off by default — TWO opt-ins needed: this timer,
AND naming categories in sweep_categories (/etc/byebyte/config.json); nothing
acts until both are set, and only named categories ever act (everything else
stays a dry-run, ledgered, notified):
  sudo systemctl enable --now byebyte-sweep.timer

>>> the GNOME pill is a separate, per-account, NO-ROOT step — as yourself: <<<
  make pill
  gnome-extensions enable ${EXT_UUID}
  (then log out and back in once — Wayland reloads extensions at login)
EOF

# Release signing

Status: **armed** — `release-signing/allowed_signers` (and its
`install.sh`-embedded twin, `RELEASE_ALLOWED_SIGNERS`) carry the operator's
four canonical keys as of the arming commit that followed v0.11.0's tag. v0.11.0
itself shipped, and still verifies, as hash-only-with-a-warning: its own
artifacts were published before the anchor existed, per the family's
arm-first-from-birth sequencing (`~/code/REPOS/RELEASE.md`: "arm BEFORE tag,
so the first sealed artifacts carry the anchor from birth") — arming right
after v0.11.0 rather than inside its own tag commit means the *next* release
is the first one the trust chain actually covers from birth. From the arming
commit on, `byebyte-update`/`install.sh`'s bootstrap fail closed for anything
released after it: no `SHA256SUMS.sig`, no `ssh-keygen`, or no matching key
means no install.

## Why this exists

The SHA256 check ByeByte has always done (via its own manifest) proves a
download wasn't corrupted or truncated in transit. It proves nothing about
*authenticity*: the checksum comes from the same GitHub release it's
checking, so a compromised release asset carries its own "valid" checksum.
Closing that gap needs a signature from a key that lives outside GitHub's
control entirely.

## Mechanism: SSH signatures, FIDO2 hardware key

Chosen over GPG/minisign: SSH signature verification (`ssh-keygen -Y sign` /
`-Y verify`) is already in every OpenSSH install, needs no new dependency on
either side, and — the reason for the FIDO2 requirement — supports
**resident, touch-required hardware keys** (`ecdsa-sk` / `ed25519-sk`). The
private key material never leaves the hardware token, and every signature
needs a physical touch. A compromised CI runner or build machine cannot
forge a release; it would need the physical key in hand. This is the same
trust anchor the fleet's `rotten-apple` master-identity ceremony established
(2026-07-16) — ByeByte reuses that identity rather than minting its own
(per-project keys were the ruled-out footgun — see `~/code/REPOS/RELEASE.md`).

**The signing key must never be provisioned into CI.** That's the whole
point — CI compromise is exactly the threat this defends against. Releases
are signed by hand, from the operator's own machine, with the hardware key
attached.

## One enforcement policy, not two

phanspeed/coldspot split their policy because they run an unattended daily
*install* path (their update timer can auto-install once armed). ByeByte's
`byebyte-update.timer` only ever runs `--check` (`auto_enabled` is hardcoded
`False` in `bin/byebyte-update` — family doctrine: updates are
click-to-install) — it notifies, it never reaches `sutra_update.py`'s
verify/install code at all. So every real consumer of this anchor is
already a human-triggered action: a bare `byebyte update` (or
`byebyte-update`), and the `curl -fsSL .../install.sh | sudo bash`
bootstrap. Same shape as kast's reasoning, same conclusion: **one policy for
both** — degrade to SHA256-only with a warning while unarmed, fail closed
once a key is provisioned. (If ByeByte ever adds a real unattended-install
tier, `auto_enabled` stops being hardcoded and this doc gets a second policy
to match — not before.)

## Identity vs role — principal is WHO, namespace is WHAT-FOR

Per `~/code/REPOS/RELEASE.md`: **principal** (`-I`) is the repo's stable
identity (`byebyte`); **namespace** (`-n`) is what a given signature
authorizes (`byebyte-release`). Never pass the same string for both — that
welds identity to role and only works by accident. `allowed_signers` line
format (one line per key, exactly 4 when populated):

```
byebyte namespaces="byebyte-release,pills-tag" sk-ssh-ed25519@openssh.com <b64> ra-master-<n>
```

## One-time setup — `mudra sync-signers ByeByte`, never hand-edit

```sh
~/code/REPOS/mudra/bin/mudra sync-signers ByeByte
```

Rebuilds `release-signing/allowed_signers` **and** `install.sh`'s embedded
`RELEASE_ALLOWED_SIGNERS` twin — byte-identical, trailing newline included —
from ALL 4 canonical pubkeys in `~/.ssh/asuramaya-master/*.pub` (the
operator's own key home). Always a full rebuild, never an append. Refuses
to run unless it finds exactly 4 canonical keys. `.github/workflows/
signing-sync.yml` is CI's own internal-consistency check: it can confirm
the anchor is well-formed and the embedded copy matches it, but — since the
canonical key home never reaches a CI runner — it can't confirm either one
still matches the operator's actual keys; that comparison only ever happens
locally, via `mudra` itself.

**Sequencing rule:** `mudra sync-signers ByeByte` populates the anchor. It
was run once, after v0.11.0's tag and before any release depended on it —
arming earlier than a release's own tag is exactly the "arm before tag"
sequencing the doctrine calls for, and arming any *later* than a release
would brick `byebyte update` against that release's own already-published,
unsigned artifacts. Re-run it only to rotate keys, and only between
releases, never mid-ceremony (see [RELEASING.md](RELEASING.md)).

## Per-release signing (operator, needs the FIDO2 key attached + a touch)

```sh
# Sign the checksum manifest, not each artifact — SHA256SUMS covers every
# release artifact (the .deb and the tarball) via its checksum entries, so
# signing it transitively covers the whole release, and it's tiny (one
# line per artifact).
ssh-keygen -Y sign -f /path/to/id_asuramaya_master_N.pub -n byebyte-release \
  SHA256SUMS
# -> produces SHA256SUMS.sig

gh release upload vX.Y.Z SHA256SUMS.sig
```

## Verification (client side — already built)

```sh
sha256sum -c SHA256SUMS                                       # artifact matches the manifest
ssh-keygen -Y verify -f release-signing/allowed_signers \
  -I byebyte -n byebyte-release -s SHA256SUMS.sig \
  < SHA256SUMS                                                 # manifest carries the operator's hand
```

Exit 0 = valid signature from the pinned principal, over exactly those
checksum bytes. Anything else is a hard failure. Two independent
implementations of the same algorithm, matching the family's Update-path
convergence doctrine:

- `bin/sutra_update.py`'s `verify_dir()` — the update spine, run by `byebyte
  update` / `byebyte-update`. `armed()` checks whether the anchor
  (`anchor_candidates` in `bin/byebyte-update`: the deb path, the
  source-install path, then the repo-relative dev fallback) carries any
  real line; while unarmed, degrades to hash-only with a printed warning.
  Once armed: requires a `SHA256SUMS.sig` asset, fails closed on a missing
  signature or a verification failure.
- `install.sh`'s `verify_signature()` — the `curl -fsSL .../install.sh |
  sudo bash` bootstrap's own copy of the same check, using the embedded
  `RELEASE_ALLOWED_SIGNERS` (no sibling `release-signing/` file exists yet
  at that point — the anchor has to travel embedded in the one file that
  WAS fetched). `tests/test_signing.sh` exercises both `has_signing_key()`
  and `verify_signature()` with a real (throwaway, non-hardware) ed25519
  key roundtrip: valid signature accepted, tampered data / untrusted key /
  wrong namespace / wrong principal all rejected.

## The artifact — deb + tarball + one manifest, from birth

Per `~/code/REPOS/RELEASE.md`'s artifact ruling: every release ships **a
`.deb` + a `git archive` tarball + one `SHA256SUMS` manifest covering both**.
`make deb` builds `build/deb/byebyte_<ver>_all.deb` (never installs it — see
`tests/smoke.sh`) and its own `build/deb/SHA256SUMS`; `.github/workflows/
release.yml` appends the tarball's hash to that same manifest. The tarball
is built with `--prefix=ByeByte/` (extraction hygiene: it extracts into
exactly one named directory, never bare into the caller's CWD) and
`.gitattributes` keeps CI/dev-only paths (`.github`, `tests`, `Makefile`,
...) out of it.

The `.deb` installs the full vendored set in both layouts — `sutra.py`,
`sutra_update.py`, `sutra_xen.py` (vendored unconditionally, unused by
ByeByte today, same as every other pill), the release-signing anchor
(`/usr/share/byebyte/allowed_signers`), and the extension source
(`/usr/share/byebyte/extension/byebyte@asuramaya/`, for the curl-bootstrap
path's pill-activation instructions) — matching what a checkout install via
`install.sh` ships into `$BINDIR`/`$SHAREDIR`. Never partial in either
direction; `tests/smoke.sh` asserts the deb's contents directly.

## Release notes — the extracted CHANGELOG section, never `--generate-notes`

Family ruling (decision `1bc925cb`, UNIFY presentation axis): `gh release
create --generate-notes` produces a generic commit-list/compare-stub, not
curated prose. `release.yml` extracts the `CHANGELOG.md` section matching
the exact version being released into `NOTES.md` and ships that via
`--notes-file` — refusing the release outright if no matching section
exists, rather than silently falling back to a generic one. ByeByte is the
first pill to apply this from its very first release.

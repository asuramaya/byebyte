# Releasing ByeByte

How a version becomes a signed release. The trust chain itself is described in
[RELEASE-SIGNING.md](RELEASE-SIGNING.md); this is the running order.

Two people are involved and only one of them can finish it. A maintainer prepares and tags.
The operator signs, by hand, with a physical key. No automation can stand in for that step,
and the signing key never goes near CI.

## 1. Prepare

Bump `packaging/VERSION`. It's the one version constant: `src/bin/byebyted` and
`src/bin/byebyte-update` both read it at runtime rather than carrying their own copy, and CI
asserts it equals the tag at release.

Write the `docs/CHANGELOG.md` entry under a `## X.Y.Z` heading that starts with the bare
version number, formatted the same way every existing entry is. This is not optional
bookkeeping: the release workflow lifts that
section verbatim as the release notes, and refuses to publish when the section is missing.
Whatever you write there is what the world reads.

Run the checks:

```bash
make check           # static checks, and the vendored spine matches canonical, byte for byte
make smoke           # end to end, against a throwaway runtime dir
make attack          # full command surface, oversized/garbage/nested/stall input
```

`check-sutra` failing on freshness (LAG, not DRIFT) means the shared spine moved and ByeByte
hasn't caught up. Re-vendor before releasing rather than after:
`bash ~/code/REPOS/sutra/vendor.sh src/share/byebyte/lib src/extension/byebyte@asuramaya`.

## 2. Tag and publish

ByeByte's trust anchor is armed: `packaging/release-signing/allowed_signers` and `install.sh`'s
embedded twin both carry the operator's four canonical keys. If a key has rotated since the
last release, rebuild the anchor first:

```bash
~/code/REPOS/mudra/bin/mudra sync-signers ByeByte
```

This rebuilds both copies from `~/.ssh/asuramaya-master/*.pub`, byte-identical, and never
appends. A key retired upstream disappears here too. It's a full rebuild every time, so
only run it when you mean to, and never between a tag and its signing (see the rule below).

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

CI then builds `byebyte_X.Y.Z_all.deb`, a `git archive` tarball, and a `SHA256SUMS` manifest
covering both, and publishes them with the notes it lifted from the CHANGELOG. It signs
nothing. That's deliberate: if CI could sign, then anyone who compromised the workflow or
the account could sign whatever they pushed, and the anchor would be protecting nothing.

> **An armed anchor with no signature is a broken update path.** Once the anchor carries
> real keys, a client whose installed copy is armed will refuse a release with no `.sig`,
> and it's right to. So tagging and signing belong to one sitting, with the operator
> available shortly after. Never tag and walk away.

## 3. The operator seals it

The operator verifies the published bytes, signs the manifest offline with the FIDO2 key,
and uploads the detached signature:

```bash
gh release upload vX.Y.Z SHA256SUMS.sig --clobber
```

One signature over the manifest covers every artifact in the release, since the manifest
covers them all. In practice this runs through the family's seal desk (`mudra`), which
derives its queue from published releases and shows anything published without a `.sig` as
awaiting the seal.

## Rules that don't bend

* **A sealed release is never re-cut.** If something is wrong with it, the fix is the next
  version. Re-cutting breaks every copy that already verified it.
* **The signing key never enters CI**, in any form, for any reason.
* **Arming commits are scoped** to the anchor files alone, never `git add -A`. A stray add
  has put unrelated files into a public commit before.
* **`--notes-file`, never `--generate-notes`.** A commit dump is not release notes.

## When it goes wrong

**CI refuses with "no CHANGELOG section"** means the heading doesn't contain the version, or
doesn't start with the bare number. Add the section and re-push the tag.

**The tag assertion fails** means `packaging/VERSION` and the tag disagree. Fix it, delete
the tag, tag again.

**A client reports "armed but release is unsigned"** means the release was published and
never sealed. Nothing is broken in the artifact; it needs the operator's signature uploaded.

# byebyte — the storage demon
.PHONY: smoke attack check check-py check-shell check-js check-man check-sutra check-repo install uninstall pill deb

# static checks, broken into sub-targets so ci.yml can invoke each by name
# for readable per-step results without hand-duplicating any command list
# of its own (REPO-STANDARD.md: CI holding a stale or wrong copy of
# something the Makefile moved past is a recurring, real bug class across
# this family -- phanspeed's CI was red for five commits over exactly this,
# sutra's on every commit since 0.1.0). Every check either lives here, or
# it isn't a check anyone can trust matches what `make check` itself runs.
# Deliberately excludes smoke/attack (real daemon, real sockets) so it
# stays fast enough to run before every commit. check-repo (the family's
# structural gate) hangs off this target.
check: check-sutra check-py check-shell check-js check-man
	@echo "check: all static checks passed"

check-py:
	python3 -m py_compile src/bin/byebyted src/bin/byebyte src/bin/byebyte-healthcheck src/bin/byebyte-update \
	    src/share/byebyte/lib/sutra.py src/share/byebyte/lib/sutra_update.py src/share/byebyte/lib/sutra_xen.py

check-shell:
	bash -n install.sh uninstall.sh tests/smoke.sh tests/test_signing.sh
	shellcheck -e SC1090,SC1091 install.sh uninstall.sh tests/smoke.sh tests/test_signing.sh

check-js:
	@mjs=$$(mktemp --suffix=.mjs); \
	cp 'src/extension/byebyte@asuramaya/extension.js' "$$mjs"; \
	node --check "$$mjs"; \
	rm -f "$$mjs"
	python3 -c "import json; json.load(open('src/extension/byebyte@asuramaya/metadata.json'))"

check-man:
	groff -man -Tutf8 -ww src/data/man/man1/byebyte.1 > /dev/null
	groff -t -man -Tutf8 -ww src/data/man/man8/byebyted.8 > /dev/null

VERSION := $(shell tr -d '[:space:]' < packaging/VERSION)
# DEBROOT is per-invocation-unique (a shared dev box runs concurrent smoke
# passes — root and unprivileged, different agents — against the SAME
# checkout; a fixed staging dir raced install/rm-rf across them and
# produced impossible-looking failures: real nonzero exit, innocent-looking
# log, because the log/artifacts belonged to a DIFFERENT concurrent
# invocation). DEBFILE's name stays canonical — it's the real, user-facing
# release artifact name — but is only ever populated via an atomic rename
# from a per-invocation temp file, so two concurrent builds can never leave
# it torn.
DEBROOT := build/deb/.stage-$(shell mktemp -u XXXXXX)-byebyte_$(VERSION)_all
DEBFILE := build/deb/byebyte_$(VERSION)_all.deb
DEBTMP := $(DEBFILE).$(shell mktemp -u XXXXXX).tmp

smoke: check-sutra
	bash tests/smoke.sh
	bash tests/test_signing.sh

# drift guard for every vendored sutra file: integrity (hash matches what
# vendor.sh recorded — the copy wasn't hand-edited) is the hard gate,
# always enforced. Freshness is a LAG-vs-DRIFT read (sutra's 0.7.0 ruling,
# custodian recipe, thread 2ac0a67f — RAMstein's aec8899 is the reference
# shape): a plain HEAD-compare reddened on ordinary LAG (an honest vendor
# from an earlier canonical commit, indistinguishable on sight from actual
# DRIFT/corruption), so this asks canonical git which of the two a recorded
# .commit anchor actually is. LAG warns and exits 0; DRIFT (the recorded
# commit isn't in canonical's history at all) is a hard fail. Only runs
# when the canonical checkout is present, which it normally isn't in CI.
check-sutra:
	@real_home=$$(getent passwd "$${SUDO_USER:-$$(id -un)}" | cut -d: -f6); \
	canon="$${real_home:-$$HOME}/code/REPOS/sutra"; \
	for f in src/share/byebyte/lib/sutra.py src/share/byebyte/lib/sutra_update.py \
	         src/share/byebyte/lib/sutra_xen.py \
	         src/extension/byebyte@asuramaya/pill.js; do \
	    vf="$${f%.py}"; vf="$${vf%.js}.version"; \
	    cf="$${f%.py}"; cf="$${cf%.js}.commit"; \
	    ver=$$(cut -d' ' -f1 "$$vf" 2>/dev/null); \
	    sha=$$(awk '{print $$NF}' "$$vf" 2>/dev/null); \
	    actual=$$(sha256sum "$$f" | cut -d' ' -f1); \
	    if [ "$$sha" != "$$actual" ]; then \
	        echo "check-sutra FAIL: $$f doesn't match $$vf" \
	             "(hand-edited? re-vendor: bash ~/code/REPOS/sutra/vendor.sh src/share/byebyte/lib src/extension/byebyte@asuramaya)"; \
	        exit 1; \
	    fi; \
	    echo "check-sutra: integrity ok ($$f, $$ver, sha256 $$sha)"; \
	    if [ -d "$$canon/.git" ]; then \
	        if [ ! -f "$$cf" ]; then \
	            echo "check-sutra: freshness unknown ($$f has no .commit anchor, an older vendor)"; \
	        else \
	            recorded=$$(cat "$$cf"); \
	            head=$$(git -C "$$canon" rev-parse HEAD); \
	            if [ "$$recorded" = "$$head" ]; then \
	                echo "check-sutra: freshness ok ($$f matches canonical HEAD $$head)"; \
	            elif git -C "$$canon" merge-base --is-ancestor "$$recorded" HEAD 2>/dev/null; then \
	                echo "check-sutra: LAG ($$f vendored from $$recorded, canonical has since" \
	                     "moved to $$head) -- warn, not a failure"; \
	            else \
	                echo "check-sutra FAIL: DRIFT ($$f's vendored commit $$recorded is not in" \
	                     "canonical's history at $$canon) -- re-vendor"; \
	                exit 1; \
	            fi; \
	        fi; \
	    else \
	        echo "check-sutra: canonical sutra checkout not present, freshness skipped for $$f"; \
	    fi; \
	done

# the thorough adversarial pass (full cmd surface + oversized/garbage/nested/
# stall); smoke.sh keeps its own quick hostile-input block for a fast loop
attack:
	python3 tests/attack_socket.py

# root half of the two-step install; the pill (below) is the no-root half.
# install.sh gates on EUID itself and prints guidance if sudo was forgotten.
install:
	@if [ "$$(id -u)" -eq 0 ]; then \
		bash ./install.sh; \
	else \
		echo "make install needs root — run: sudo make install   (or: sudo ./install.sh)"; \
		echo "(the GNOME pill stays a separate no-root step: make pill)"; \
		exit 1; \
	fi

uninstall:
	@if [ "$$(id -u)" -eq 0 ]; then \
		bash ./uninstall.sh; \
	else \
		echo "make uninstall needs root — run: sudo make uninstall   (or: sudo ./uninstall.sh)"; \
		exit 1; \
	fi

# the pill only ever needs your own $$HOME and gnome-shell session — never root
pill:
	mkdir -p $(HOME)/.local/share/gnome-shell/extensions
	cp -r src/extension/byebyte@asuramaya $(HOME)/.local/share/gnome-shell/extensions/
	@echo "pill installed — now: gnome-extensions enable byebyte@asuramaya"
	@echo "then log out and back in once (Wayland reloads extensions at login)"

# Bins land straight in /usr/bin, not /usr/lib/byebyte + symlinks: every
# binary here (byebyted, byebyte, byebyte-healthcheck, byebyte-update) is
# meant to be run directly by a human or systemd — none is an internal
# helper, so a private libdir + symlink layer would only add indirection
# nothing here needs. The vendored sutra modules are different: they used
# to sit beside the bins in /usr/bin, where any two pills installed on one
# machine collided (dpkg refuses the second package outright). They move to
# /usr/share/byebyte/lib/ instead -- a private, per-pill dir each binary
# finds via a small bootstrap preamble, not co-location (BOOTSTRAP.md,
# ruling 3e44bd95). .version/.commit anchors travel with them, always --
# an anchorless install dir is exactly how a mixed-version sutra sat
# undetected on the operator's own machine before this fix. Builds only;
# never installs the result.
deb:
	rm -rf $(DEBROOT)
	install -d -m 0755 $(DEBROOT)/DEBIAN
	install -d -m 0755 $(DEBROOT)/usr/bin
	install -d -m 0755 $(DEBROOT)/usr/share/byebyte/lib
	install -d -m 0755 $(DEBROOT)/usr/share/byebyte/scripts
	install -d -m 0755 $(DEBROOT)/usr/share/byebyte/extension/byebyte@asuramaya
	install -d -m 0755 $(DEBROOT)/usr/share/man/man1
	install -d -m 0755 $(DEBROOT)/usr/share/man/man8
	install -d -m 0755 $(DEBROOT)/etc/byebyte
	install -d -m 0755 $(DEBROOT)/lib/systemd/system
	install -m 0755 src/bin/byebyted src/bin/byebyte src/bin/byebyte-healthcheck src/bin/byebyte-update $(DEBROOT)/usr/bin/
	install -m 0644 src/share/byebyte/lib/sutra.py src/share/byebyte/lib/sutra.version src/share/byebyte/lib/sutra.commit \
	    src/share/byebyte/lib/sutra_update.py src/share/byebyte/lib/sutra_update.version src/share/byebyte/lib/sutra_update.commit \
	    src/share/byebyte/lib/sutra_xen.py src/share/byebyte/lib/sutra_xen.version src/share/byebyte/lib/sutra_xen.commit \
	    $(DEBROOT)/usr/share/byebyte/lib/
	install -m 0644 packaging/VERSION $(DEBROOT)/usr/share/byebyte/VERSION
	install -m 0644 packaging/release-signing/allowed_signers $(DEBROOT)/usr/share/byebyte/allowed_signers
	install -m 0755 packaging/scripts/seed-owner-uid.py $(DEBROOT)/usr/share/byebyte/scripts/
	install -m 0644 src/extension/byebyte@asuramaya/extension.js src/extension/byebyte@asuramaya/pill.js \
	    src/extension/byebyte@asuramaya/metadata.json $(DEBROOT)/usr/share/byebyte/extension/byebyte@asuramaya/
	install -m 0644 src/data/man/man1/byebyte.1 $(DEBROOT)/usr/share/man/man1/byebyte.1
	install -m 0644 src/data/man/man8/byebyted.8 $(DEBROOT)/usr/share/man/man8/byebyted.8
	install -m 0644 src/data/config/config.json $(DEBROOT)/etc/byebyte/config.json
	install -m 0644 src/data/systemd/system/byebyted.service src/data/systemd/system/byebyte-update.service \
	    src/data/systemd/system/byebyte-update.timer src/data/systemd/system/byebyte-sweep.service \
	    src/data/systemd/system/byebyte-sweep.timer $(DEBROOT)/lib/systemd/system/
	install -m 0755 packaging/deb/postinst $(DEBROOT)/DEBIAN/postinst
	install -m 0755 packaging/deb/prerm $(DEBROOT)/DEBIAN/prerm
	install -m 0755 packaging/deb/postrm $(DEBROOT)/DEBIAN/postrm
	echo /etc/byebyte/config.json > $(DEBROOT)/DEBIAN/conffiles
	{ \
	  echo "Package: byebyte"; \
	  echo "Version: $(VERSION)"; \
	  echo "Section: admin"; \
	  echo "Priority: optional"; \
	  echo "Architecture: all"; \
	  echo "Depends: python3 (>= 3.8), systemd, openssh-client"; \
	  echo "Maintainer: asuramaya <asuramaya@users.noreply.github.com>"; \
	  echo "Homepage: https://github.com/asuramaya/byebyte"; \
	  echo "Description: storage as a deadline, not a percentage"; \
	  echo " byebyte owns the truth about disks: statvfs+quota polling, burn rate,"; \
	  echo " ETA-to-full, an index, purge/ghosts/ballast/kernels/advise, and a GNOME"; \
	  echo " Quick Settings pill."; \
	} > $(DEBROOT)/DEBIAN/control
	dpkg-deb --build --root-owner-group $(DEBROOT) $(DEBTMP)
	mv -f $(DEBTMP) $(DEBFILE)
	rm -rf $(DEBROOT)
	( cd build/deb && sha256sum "$$(basename $(DEBFILE))" > SHA256SUMS )
	@echo "-- built $(DEBFILE)"
	@if command -v lintian >/dev/null 2>&1; then \
	    lintian $(DEBFILE) || true; \
	else \
	    echo "-- lintian not installed, skipping"; \
	fi

# signing anchor rebuild is centralized in mudra now, not a per-repo target:
#   ~/code/REPOS/mudra/bin/mudra sync-signers ByeByte

# The family's structural gate (REPO-STANDARD.md §5), mechanical only: it
# cannot judge whether a document is any good, only that the shape it's
# supposed to have is actually there and nothing contradicts it. Copied from
# coldspot, the family's reference implementation of this target, with one
# addition: `build` is excluded from the root row count the same way
# coldspot excludes .claude/.mcp.json/.ruff_cache -- it's gitignored,
# generated-only, and counting it would make `make deb` (which this same
# Makefile runs) able to fail its OWN structural gate.
check-repo:
	@fail=0; \
	for f in README.md LICENSE Makefile install.sh uninstall.sh .gitignore .gitattributes \
	         docs/USAGE.md docs/ARCHITECTURE.md docs/RELEASING.md; do \
	    if [ ! -e "$$f" ]; then echo "check-repo FAIL: missing $$f"; fail=1; fi; \
	done; \
	if [ ! -e src/data/man/man1/byebyte.1 ] && ! grep -q 'man1/byebyte.1' docs/ARCHITECTURE.md 2>/dev/null; then \
	    echo "check-repo FAIL: no src/data/man/man1/byebyte.1 and no exemption for it"; fail=1; \
	fi; \
	rows=$$(git ls-files | cut -d/ -f1 | sort -u | wc -l); \
	if [ "$$rows" -gt 12 ]; then \
	    echo "check-repo FAIL: root has $$rows rows, standard caps it at 12"; fail=1; \
	else \
	    echo "check-repo: root row count ok ($$rows)"; \
	fi; \
	if ! grep -q '^## Map' README.md 2>/dev/null; then \
	    echo "check-repo FAIL: README.md has no navigation block (## Map)"; fail=1; \
	fi; \
	for h in Troubleshooting "Repo Layout"; do \
	    if grep -q "^## $$h" README.md 2>/dev/null; then \
	        echo "check-repo FAIL: README.md carries a post-install heading ('$$h') that belongs in docs/USAGE.md"; fail=1; \
	    fi; \
	done; \
	if [ ! -f packaging/VERSION ]; then \
	    echo "check-repo FAIL: no packaging/VERSION"; fail=1; \
	fi; \
	if grep -rn "VERSION[[:space:]]*=[[:space:]]*['\"][0-9]" \
	    src/bin/byebyted src/bin/byebyte src/bin/byebyte-healthcheck src/bin/byebyte-update \
	    install.sh uninstall.sh "src/extension/byebyte@asuramaya/extension.js" 2>/dev/null; then \
	    echo "check-repo FAIL: a literal version string exists outside packaging/VERSION"; fail=1; \
	fi; \
	if grep -v '^[[:space:]]*#' .github/workflows/release.yml 2>/dev/null | grep -q -- '--generate-notes'; then \
	    echo "check-repo FAIL: release.yml still uses --generate-notes, not --notes-file"; fail=1; \
	fi; \
	stray=$$(find docs -name '*.md' -not -path '*/.*' | while read -r f; do git ls-files --error-unmatch "$$f" >/dev/null 2>&1 || echo "$$f"; done); \
	if [ -n "$$stray" ]; then \
	    echo "check-repo FAIL: untracked *.md under docs/: $$stray"; fail=1; \
	fi; \
	spec=$$(find . -name '*-SPEC.md' -not -path './.git/*'); \
	if [ -n "$$spec" ]; then \
	    echo "check-repo FAIL: *-SPEC.md left in the repo (specs belong in the seat's office): $$spec"; fail=1; \
	fi; \
	if [ -f docs/ARCHITECTURE.md ] && grep -q '^## Standard exemptions' docs/ARCHITECTURE.md; then \
	    bad=$$(awk '/^## Standard exemptions/{f=1;next} f && /^\|/ && !/^\| *Item *\|/ && !/^\|---/{ n=gsub(/\|/,"|"); if (n<3) print }' docs/ARCHITECTURE.md); \
	    if [ -n "$$bad" ]; then echo "check-repo FAIL: exemptions table has a row missing a column"; fail=1; fi; \
	fi; \
	if [ "$$fail" -eq 0 ]; then echo "check-repo: all mechanical checks passed"; else exit 1; fi

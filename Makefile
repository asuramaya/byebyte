# byebyte — the storage demon
.PHONY: smoke attack install uninstall pill deb check-sutra

VERSION := $(shell tr -d '[:space:]' < VERSION)
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
	for f in bin/sutra.py bin/sutra_update.py bin/sutra_xen.py \
	         extension/byebyte@asuramaya/pill.js; do \
	    vf="$${f%.py}"; vf="$${vf%.js}.version"; \
	    cf="$${f%.py}"; cf="$${cf%.js}.commit"; \
	    ver=$$(cut -d' ' -f1 "$$vf" 2>/dev/null); \
	    sha=$$(awk '{print $$NF}' "$$vf" 2>/dev/null); \
	    actual=$$(sha256sum "$$f" | cut -d' ' -f1); \
	    if [ "$$sha" != "$$actual" ]; then \
	        echo "check-sutra FAIL: $$f doesn't match $$vf" \
	             "(hand-edited? re-vendor: bash ~/code/REPOS/sutra/vendor.sh bin extension/byebyte@asuramaya)"; \
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
	cp -r extension/byebyte@asuramaya $(HOME)/.local/share/gnome-shell/extensions/
	@echo "pill installed — now: gnome-extensions enable byebyte@asuramaya"
	@echo "then log out and back in once (Wayland reloads extensions at login)"

# Bins land straight in /usr/bin, not /usr/lib/byebyte + symlinks: every
# binary here (byebyted, byebyte, byebyte-healthcheck, byebyte-update) is
# meant to be run directly by a human or systemd — none is an internal
# helper, so a private libdir + symlink layer would only add indirection
# nothing here needs. Builds only; never installs the result.
deb:
	rm -rf $(DEBROOT)
	install -d -m 0755 $(DEBROOT)/DEBIAN
	install -d -m 0755 $(DEBROOT)/usr/bin
	install -d -m 0755 $(DEBROOT)/usr/share/byebyte/scripts
	install -d -m 0755 $(DEBROOT)/usr/share/byebyte/extension/byebyte@asuramaya
	install -d -m 0755 $(DEBROOT)/usr/share/man/man1
	install -d -m 0755 $(DEBROOT)/usr/share/man/man8
	install -d -m 0755 $(DEBROOT)/etc/byebyte
	install -d -m 0755 $(DEBROOT)/lib/systemd/system
	install -m 0755 bin/byebyted bin/byebyte bin/byebyte-healthcheck bin/byebyte-update $(DEBROOT)/usr/bin/
	install -m 0644 bin/sutra.py $(DEBROOT)/usr/bin/sutra.py
	install -m 0644 bin/sutra_update.py $(DEBROOT)/usr/bin/sutra_update.py
	install -m 0644 bin/sutra_xen.py $(DEBROOT)/usr/bin/sutra_xen.py
	install -m 0644 VERSION $(DEBROOT)/usr/share/byebyte/VERSION
	install -m 0644 release-signing/allowed_signers $(DEBROOT)/usr/share/byebyte/allowed_signers
	install -m 0755 scripts/seed-owner-uid.py $(DEBROOT)/usr/share/byebyte/scripts/
	install -m 0644 extension/byebyte@asuramaya/extension.js extension/byebyte@asuramaya/pill.js \
	    extension/byebyte@asuramaya/metadata.json $(DEBROOT)/usr/share/byebyte/extension/byebyte@asuramaya/
	install -m 0644 man/byebyte.1 $(DEBROOT)/usr/share/man/man1/byebyte.1
	install -m 0644 man/byebyted.8 $(DEBROOT)/usr/share/man/man8/byebyted.8
	install -m 0644 config/config.json $(DEBROOT)/etc/byebyte/config.json
	install -m 0644 systemd/system/byebyted.service systemd/system/byebyte-update.service \
	    systemd/system/byebyte-update.timer systemd/system/byebyte-sweep.service \
	    systemd/system/byebyte-sweep.timer $(DEBROOT)/lib/systemd/system/
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

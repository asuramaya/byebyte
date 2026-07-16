# byebyte — the storage demon
.PHONY: smoke install uninstall pill deb

VERSION := $(shell tr -d '[:space:]' < VERSION)
DEBROOT := build/deb/byebyte_$(VERSION)_all
DEBFILE := build/deb/byebyte_$(VERSION)_all.deb

smoke:
	bash tests/smoke.sh

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
	install -d -m 0755 $(DEBROOT)/usr/share/man/man1
	install -d -m 0755 $(DEBROOT)/usr/share/man/man8
	install -d -m 0755 $(DEBROOT)/etc/byebyte
	install -d -m 0755 $(DEBROOT)/lib/systemd/system
	install -m 0755 bin/byebyted bin/byebyte bin/byebyte-healthcheck bin/byebyte-update $(DEBROOT)/usr/bin/
	install -m 0644 VERSION $(DEBROOT)/usr/share/byebyte/VERSION
	install -m 0755 scripts/seed-owner-uid.py $(DEBROOT)/usr/share/byebyte/scripts/
	install -m 0644 man/byebyte.1 $(DEBROOT)/usr/share/man/man1/byebyte.1
	install -m 0644 man/byebyted.8 $(DEBROOT)/usr/share/man/man8/byebyted.8
	install -m 0644 config/config.json $(DEBROOT)/etc/byebyte/config.json
	install -m 0644 systemd/system/byebyted.service systemd/system/byebyte-update.service \
	    systemd/system/byebyte-update.timer $(DEBROOT)/lib/systemd/system/
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
	  echo "Depends: python3 (>= 3.8), systemd"; \
	  echo "Maintainer: asuramaya <asuramaya@users.noreply.github.com>"; \
	  echo "Homepage: https://github.com/asuramaya/byebyte"; \
	  echo "Description: storage as a deadline, not a percentage"; \
	  echo " byebyte owns the truth about disks: statvfs+quota polling, burn rate,"; \
	  echo " ETA-to-full, an index, purge/ghosts/ballast/kernels/advise, and a GNOME"; \
	  echo " Quick Settings pill."; \
	} > $(DEBROOT)/DEBIAN/control
	dpkg-deb --build --root-owner-group $(DEBROOT) $(DEBFILE)
	@echo "-- built $(DEBFILE)"
	@command -v lintian >/dev/null 2>&1 && lintian $(DEBFILE) || echo "-- lintian not installed, skipping"

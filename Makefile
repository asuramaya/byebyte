# byebyte — the storage demon
.PHONY: smoke install uninstall pill

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

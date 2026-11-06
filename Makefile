# Majestic Media Player — build with `make`, run with `make run`.
# Requires: nim >= 2.2, git, mpv (libmpv), mesa/libGL, libX11, libXrandr.

NIM      ?= nim
BIN      := majestic-media-player
SRC      := src/majestic.nim
NIMFLAGS ?= -d:release

.PHONY: all deps run debug clean

all: $(BIN)

# tools/build.sh fetches deps when deps.lock changed, then compiles, showing a
# progress bar per package / build phase plus an overall bar.
deps:
	./tools/fetch_deps.sh
	touch vendor/.stamp

$(BIN): VERSION deps.lock $(wildcard tools/*.sh) $(wildcard patches/*.patch) $(wildcard src/*.nim) $(wildcard src/*/*.nim) $(wildcard assets/presets/*) assets/fonts/IBMPlexSans-Regular.ttf
	@./tools/build.sh $(NIM) c $(NIMFLAGS) -o:$(BIN) $(SRC)

debug:
	@./tools/build.sh $(NIM) c -d:debug -o:$(BIN) $(SRC)

run: $(BIN)
	./$(BIN)

clean:
	rm -f $(BIN)

# Install. Default is per-user (~/.local); `sudo make install PREFIX=/usr/local`
# installs system-wide. DESTDIR is honoured for packaging. The launcher entry's
# Exec/TryExec are rewritten to the absolute binary path, so the app starts from
# the application launcher even when $(PREFIX)/bin isn't on the session's PATH.
PREFIX  ?= $(HOME)/.local
DESTDIR ?=
BINDIR  := $(PREFIX)/bin
APPDIR  := $(PREFIX)/share/applications
ICONDIR := $(PREFIX)/share/icons/hicolor
DESKTOP := majestic-media-player.desktop

.PHONY: install uninstall
install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)
	install -dm755 $(DESTDIR)$(APPDIR)
	sed -e 's|^Exec=majestic-media-player|Exec=$(BINDIR)/$(BIN)|' \
	    -e '/^Exec=/i TryExec=$(BINDIR)/$(BIN)' \
	    assets/desktop/$(DESKTOP) > $(DESTDIR)$(APPDIR)/$(DESKTOP)
	chmod 644 $(DESTDIR)$(APPDIR)/$(DESKTOP)
	install -Dm644 assets/desktop/majestic-media-player.svg $(DESTDIR)$(ICONDIR)/scalable/apps/majestic-media-player.svg
ifeq ($(DESTDIR),)
	@$(MAKE) --no-print-directory refresh-caches
	@echo "Installed $(BINDIR)/$(BIN) — find it in the application launcher as 'Majestic Media Player'."
endif

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BIN) $(DESTDIR)$(APPDIR)/$(DESKTOP) \
	      $(DESTDIR)$(ICONDIR)/scalable/apps/majestic-media-player.svg
ifeq ($(DESTDIR),)
	@$(MAKE) --no-print-directory refresh-caches
endif

# Best effort: lets the launcher, "Open With" and the icon theme notice the
# change without logging out. Missing tools are skipped silently.
.PHONY: refresh-caches
refresh-caches:
	-@command -v update-desktop-database >/dev/null && update-desktop-database -q $(APPDIR) || true
	-@command -v gtk-update-icon-cache >/dev/null && [ -f $(ICONDIR)/index.theme ] && gtk-update-icon-cache -qtf $(ICONDIR) || true
	-@[ "$$(id -u)" != 0 ] && command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

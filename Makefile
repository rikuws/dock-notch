APP := build/DockNotch.app
INSTALL_PATH ?= /Applications/DockNotch.app

.PHONY: build app run install customize update release clean

build:
	swift build

app:
	./scripts/bundle.sh release

run: app
	-pkill -x DockNotch
	open $(APP)

install: app
	-pkill -x DockNotch
	rm -rf "$(INSTALL_PATH)"
	ditto $(APP) "$(INSTALL_PATH)"
	open "$(INSTALL_PATH)"

# Start your own version with a coding agent: make customize IDEA="…" (see CUSTOMIZING.md).
customize:
	./scripts/customize.sh "$(IDEA)"

# Move your changes onto the newest release, then rebuild and reinstall.
update:
	INSTALL_PATH="$(INSTALL_PATH)" ./scripts/update.sh

# A signed, notarized release in dist/: make release VERSION=0.2.0 (see RELEASING.md).
release:
	./scripts/release.sh $(VERSION)

clean:
	rm -rf .build build dist

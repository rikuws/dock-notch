APP := build/DockNotch.app

.PHONY: build app run install clean

build:
	swift build

app:
	./scripts/bundle.sh release

run: app
	-pkill -x DockNotch
	open $(APP)

install: app
	-pkill -x DockNotch
	rm -rf /Applications/DockNotch.app
	cp -R $(APP) /Applications/
	open /Applications/DockNotch.app

clean:
	rm -rf .build build

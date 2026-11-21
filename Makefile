.PHONY: build app install run clean screenshots icon dmg

build:
	swift build

app:
	scripts/build-app.sh

install:
	scripts/build-app.sh --install

# The app in a .dmg to download (GitHub Releases): Apple silicon, not notarized.
dmg:
	scripts/build-dmg.sh

run: app
	open build/Runbar.app

clean:
	rm -rf .build build

screenshots:
	scripts/screenshots.sh

# The app icon, drawn by scripts/app-icon.swift. The .icns is committed, so a build doesn't redraw it.
icon:
	swift scripts/app-icon.swift Resources/AppIcon.icns

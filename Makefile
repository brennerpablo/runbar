.PHONY: build app install run clean screenshots

build:
	swift build

app:
	scripts/build-app.sh

install:
	scripts/build-app.sh --install

run: app
	open build/Runbar.app

clean:
	rm -rf .build build

screenshots:
	scripts/screenshots.sh

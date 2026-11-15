.PHONY: build app install run clean

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

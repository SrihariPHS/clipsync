.PHONY: build debug run test self-test icon install clean

build:
	./scripts/build-app.sh release

debug:
	./scripts/build-app.sh debug

run: build
	open build/ClipSync.app

test:
	swift test

self-test:
	swift run ClipSync --self-test

icon:
	./scripts/make-icon.sh

install: build
	-osascript -e 'quit app "ClipSync"' 2>/dev/null || true
	sleep 1
	rm -rf /Applications/ClipSync.app
	cp -R build/ClipSync.app /Applications/
	open /Applications/ClipSync.app

uninstall:
	-osascript -e 'quit app "ClipSync"' 2>/dev/null || true
	rm -rf /Applications/ClipSync.app

clean:
	rm -rf .build build

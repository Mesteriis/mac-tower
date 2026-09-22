SHELL := /bin/bash
.DEFAULT_GOAL := help
CONFIGURATION ?= debug

.PHONY: help build test check format lint app run release daemon-help

help:
	@printf '%s\n' \
	  'build        Build the menu bar app and daemon' \
	  'test         Run Swift tests' \
	  'check        Build, test, lint, and validate resources' \
	  'format       Format Swift sources' \
	  'lint         Check Swift formatting' \
	  'app          Build dist/MacTower.app (development signing)' \
	  'run          Build and open the menu bar app' \
	  'release      Build optimized binaries and app bundle' \
	  'daemon-help  Print daemon usage without elevated privileges'

build:
	swift build --configuration $(CONFIGURATION)

test:
	./src/scripts/test.sh
	bash tests/daemon_cli.sh "$$(swift build --show-bin-path)/mac-tower-daemon"
	bash tests/claude_bridge_cli.sh "$$(swift build --show-bin-path)/mac-tower-claude-bridge"

lint:
	xcrun swift-format lint --strict --recursive Package.swift src tests

format:
	xcrun swift-format format --in-place --recursive Package.swift src tests

check: build test lint
	plutil -lint src/Resources/Info.plist src/Resources/dev.mactower.daemon.plist
	bash -n src/scripts/build_app.sh src/scripts/build_and_run.sh src/scripts/test.sh tests/daemon_cli.sh tests/claude_bridge_cli.sh

app:
	./src/scripts/build_app.sh $(CONFIGURATION)

run:
	./src/scripts/build_and_run.sh

release:
	$(MAKE) build app CONFIGURATION=release

daemon-help: build
	"$$(swift build --configuration $(CONFIGURATION) --show-bin-path)/mac-tower-daemon" --help

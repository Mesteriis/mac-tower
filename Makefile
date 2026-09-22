SHELL := /bin/bash
.DEFAULT_GOAL := help
CONFIGURATION ?= debug

.PHONY: help build test test-mqtt-docker check format lint app run release daemon-help install uninstall purge-data install-dry-run

help:
	@printf '%s\n' \
	  'build        Build the menu bar app and daemon' \
	  'test         Run Swift tests' \
	  'test-mqtt-docker  Run the optional real-broker MQTT integration test' \
	  'check        Build, test, lint, and validate resources' \
	  'format       Format Swift sources' \
	  'lint         Check Swift formatting' \
	  'app          Build dist/MacTower.app (development signing)' \
	  'run          Build and open the menu bar app' \
	  'release      Build optimized binaries and app bundle' \
	  'daemon-help  Print daemon usage without elevated privileges' \
	  'install      Install the app and root service (prompts for administrator access)' \
	  'uninstall    Remove app and service, preserving account data' \
	  'purge-data   Permanently delete preserved account data after confirmation' \
	  'install-dry-run  Print privileged installation actions without changing files'

build:
	swift build --configuration $(CONFIGURATION)

test:
	./src/scripts/test.sh
	bash tests/daemon_cli.sh "$$(swift build --show-bin-path)/mac-tower-daemon"
	bash tests/claude_bridge_cli.sh "$$(swift build --show-bin-path)/mac-tower-claude-bridge"
	bash tests/installer_dry_run.sh src/scripts/install.sh src/scripts/uninstall.sh src/scripts/purge_data.sh

test-mqtt-docker:
	bash tests/mqtt_docker_integration.sh

lint:
	xcrun swift-format lint --strict --recursive Package.swift src tests

format:
	xcrun swift-format format --in-place --recursive Package.swift src tests

check: build test lint
	plutil -lint src/Resources/Info.plist src/Resources/dev.mactower.daemon.plist
	bash -n src/scripts/build_app.sh src/scripts/build_and_run.sh src/scripts/test.sh src/scripts/install.sh src/scripts/uninstall.sh src/scripts/purge_data.sh tests/daemon_cli.sh tests/claude_bridge_cli.sh tests/installer_dry_run.sh tests/mqtt_docker_integration.sh

app:
	./src/scripts/build_app.sh $(CONFIGURATION)

run:
	./src/scripts/build_and_run.sh

release:
	$(MAKE) build app CONFIGURATION=release

daemon-help: build
	"$$(swift build --configuration $(CONFIGURATION) --show-bin-path)/mac-tower-daemon" --help

install: release
	@codex_bin="$$(command -v codex)"; \
	if [[ -z "$$codex_bin" ]]; then printf 'codex is required for installation.\n' >&2; exit 1; fi; \
	bin_dir="$$(swift build --configuration release --show-bin-path)"; \
	sudo src/scripts/install.sh \
	  --app "$(CURDIR)/dist/MacTower.app" \
	  --daemon "$$bin_dir/mac-tower-daemon" \
	  --bridge "$$bin_dir/mac-tower-claude-bridge" \
	  --codex "$$codex_bin" \
	  --owner-uid "$$(id -u)"

uninstall:
	sudo src/scripts/uninstall.sh

purge-data:
	@printf 'Type DELETE-MACTOWER-DATA to permanently delete all MacTower account data: '; \
	read -r confirmation; \
	if [[ "$$confirmation" != DELETE-MACTOWER-DATA ]]; then printf 'Cancelled.\n'; exit 1; fi; \
	sudo src/scripts/purge_data.sh --confirm "$$confirmation"

install-dry-run:
	@bin_dir="$$(swift build --show-bin-path)"; \
	src/scripts/install.sh --dry-run \
	  --app "$(CURDIR)/dist/MacTower.app" \
	  --daemon "$$bin_dir/mac-tower-daemon" \
	  --bridge "$$bin_dir/mac-tower-claude-bridge" \
	  --codex "$$(command -v codex || printf /path/to/codex)" \
	  --owner-uid "$$(id -u)"

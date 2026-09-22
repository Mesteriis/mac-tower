#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s install-script uninstall-script purge-script\n' "$0" >&2
    exit 2
fi

install_script="$1"
uninstall_script="$2"
purge_script="$3"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install_output="$($install_script --dry-run \
    --app "$project_root/dist/MacTower.app" \
    --daemon "$project_root/.build/debug/mac-tower-daemon" \
    --bridge "$project_root/.build/debug/mac-tower-claude-bridge" \
    --codex /opt/homebrew/bin/codex \
    --owner-uid "$(id -u)")"

grep -q '/Applications/MacTower.app' <<<"$install_output"
grep -q '/Library/PrivilegedHelperTools/dev.mactower.daemon' <<<"$install_output"
grep -q '/Library/LaunchDaemons/dev.mactower.daemon.plist' <<<"$install_output"
grep -q 'dry-run: no files changed' <<<"$install_output"

if "$install_script" --dry-run \
    --app "$project_root/dist/MacTower.app" \
    --daemon "$project_root/.build/debug/mac-tower-daemon" \
    --bridge "$project_root/.build/debug/mac-tower-claude-bridge" \
    --codex /opt/homebrew/bin/codex \
    --owner-uid 0 >/dev/null 2>&1
then
    printf 'Installer accepted root as the GUI owner.\n' >&2
    exit 1
fi

preflight_root="$(mktemp -d "${TMPDIR:-/tmp}/mactower-install-preflight.XXXXXX")"
trap 'rm -rf "$preflight_root"' EXIT
mkdir -p "$preflight_root/MacTower.app"
cp /usr/bin/true "$preflight_root/daemon"
cp /usr/bin/true "$preflight_root/bridge"
cp /usr/bin/true "$preflight_root/codex"
preflight_output="$($install_script --preflight \
    --app "$preflight_root/MacTower.app" \
    --daemon "$preflight_root/daemon" \
    --bridge "$preflight_root/bridge" \
    --codex "$preflight_root/codex" \
    --owner-uid "$(id -u)")"
grep -q 'preflight: installation artifacts and paths are valid' <<<"$preflight_output"

uninstall_output="$($uninstall_script --dry-run)"
grep -q 'preserve /Library/Application Support/MacTower' <<<"$uninstall_output"
grep -q 'dry-run: no files changed' <<<"$uninstall_output"

purge_output="$($purge_script --dry-run)"
grep -q 'delete /Library/Application Support/MacTower' <<<"$purge_output"
grep -q 'dry-run: no files changed' <<<"$purge_output"

printf 'PASS: privileged lifecycle dry-run contracts.\n'

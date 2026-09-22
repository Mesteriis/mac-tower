#!/usr/bin/env bash
set -euo pipefail

dry_run=false
preflight_only=false
app=""
daemon=""
bridge=""
codex=""
owner_uid=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true; shift ;;
        --preflight) preflight_only=true; shift ;;
        --app) app="${2:-}"; shift 2 ;;
        --daemon) daemon="${2:-}"; shift 2 ;;
        --bridge) bridge="${2:-}"; shift 2 ;;
        --codex) codex="${2:-}"; shift 2 ;;
        --owner-uid) owner_uid="${2:-}"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -z "$app" || -z "$daemon" || -z "$bridge" || -z "$codex" || ! "$owner_uid" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Usage: %s [--dry-run|--preflight] --app PATH --daemon PATH --bridge PATH --codex PATH --owner-uid UID\n' "$0" >&2
    exit 2
fi

printf '%s\n' \
    "install $app -> /Applications/MacTower.app" \
    "install $daemon -> /Library/PrivilegedHelperTools/dev.mactower.daemon" \
    "install $bridge -> /Library/PrivilegedHelperTools/mac-tower-claude-bridge" \
    "install pinned Codex from $codex -> /Library/PrivilegedHelperTools/mac-tower-codex" \
    "install launchd plist -> /Library/LaunchDaemons/dev.mactower.daemon.plist" \
    "record cdhash trust for owner uid $owner_uid -> /Library/Preferences/dev.mactower.trust.json"

if $dry_run; then
    printf 'dry-run: no files changed\n'
    exit 0
fi

if ! $preflight_only && [[ $EUID -ne 0 ]]; then
    printf 'Installation requires administrator privileges. Use make install.\n' >&2
    exit 77
fi

for path in "$app" "$daemon" "$bridge" "$codex"; do
    if [[ ! -e "$path" ]]; then
        printf 'Missing installation artifact: %s\n' "$path" >&2
        exit 66
    fi
done

if [[ ! -d "$app" || ! -f "$daemon" || ! -x "$daemon" || ! -f "$bridge" || ! -x "$bridge" || ! -f "$codex" || ! -x "$codex" ]]; then
    printf 'Installation artifacts have invalid types or permissions.\n' >&2
    exit 66
fi
codex_resolved="$(/bin/realpath "$codex")"
if [[ ! -f "$codex_resolved" || ! -x "$codex_resolved" ]]; then
    printf 'Unable to resolve the Codex executable.\n' >&2
    exit 66
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plist_source="$project_root/src/Resources/dev.mactower.daemon.plist"
/usr/bin/plutil -lint "$plist_source" >/dev/null

if $preflight_only; then
    printf 'preflight: installation artifacts and paths are valid\n'
    exit 0
fi

codex_signature="$(/usr/bin/codesign -dv --verbose=2 "$codex_resolved" 2>&1)"
if ! /usr/bin/grep -q '^Identifier=codex$' <<<"$codex_signature" \
    || ! /usr/bin/grep -q '^TeamIdentifier=2DC432GLL2$' <<<"$codex_signature"
then
    printf 'The selected Codex executable is not signed by OpenAI.\n' >&2
    exit 65
fi

app_stage="/Applications/.MacTower.app.install.$$"
daemon_stage="/Library/PrivilegedHelperTools/.dev.mactower.daemon.install.$$"
bridge_stage="/Library/PrivilegedHelperTools/.mac-tower-claude-bridge.install.$$"
codex_stage="/Library/PrivilegedHelperTools/.mac-tower-codex.install.$$"
plist_stage="/Library/LaunchDaemons/.dev.mactower.daemon.plist.install.$$"
trust_stage="/Library/Preferences/.dev.mactower.trust.json.$$"

/bin/rm -rf "$app_stage"
/bin/rm -f "$daemon_stage" "$bridge_stage" "$codex_stage" "$plist_stage" "$trust_stage"
cleanup_stages() {
    /bin/rm -rf "$app_stage"
    /bin/rm -f "$daemon_stage" "$bridge_stage" "$codex_stage" "$plist_stage" "$trust_stage"
}
trap cleanup_stages EXIT
/usr/bin/ditto "$app" "$app_stage"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$app_stage"

/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
/usr/bin/install -d -o root -g wheel -m 700 "/Library/Application Support/MacTower"
/usr/bin/install -o root -g wheel -m 755 "$daemon" "$daemon_stage"
/usr/bin/install -o root -g wheel -m 755 "$bridge" "$bridge_stage"
/usr/bin/install -o root -g wheel -m 755 "$codex_resolved" "$codex_stage"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$daemon_stage"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$bridge_stage"
/usr/bin/install -o root -g wheel -m 644 "$plist_source" "$plist_stage"
/usr/bin/plutil -lint "$plist_stage" >/dev/null

app_hash="$(/usr/bin/codesign -dvvv "$app_stage" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
daemon_hash="$(/usr/bin/codesign -dvvv "$daemon_stage" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
if [[ -z "$app_hash" || -z "$daemon_hash" ]]; then
    printf 'Unable to determine staged code hashes.\n' >&2
    exit 70
fi
/usr/bin/printf '{"ownerUID":%s,"appCDHash":"%s","daemonCDHash":"%s"}\n' \
    "$owner_uid" "$app_hash" "$daemon_hash" >"$trust_stage"
/usr/sbin/chown root:wheel "$trust_stage"
/bin/chmod 644 "$trust_stage"

/bin/launchctl bootout system/dev.mactower.daemon >/dev/null 2>&1 || true

if [[ -e /Applications/MacTower.app ]]; then
    /bin/rm -rf /Applications/MacTower.app.previous
    /bin/mv /Applications/MacTower.app /Applications/MacTower.app.previous
fi
/bin/mv "$app_stage" /Applications/MacTower.app
/usr/sbin/chown -R root:wheel /Applications/MacTower.app
/bin/mv "$daemon_stage" /Library/PrivilegedHelperTools/dev.mactower.daemon
/bin/mv "$bridge_stage" /Library/PrivilegedHelperTools/mac-tower-claude-bridge
/bin/mv "$codex_stage" /Library/PrivilegedHelperTools/mac-tower-codex
/bin/mv "$plist_stage" /Library/LaunchDaemons/dev.mactower.daemon.plist
/bin/mv "$trust_stage" /Library/Preferences/dev.mactower.trust.json

/bin/launchctl bootstrap system /Library/LaunchDaemons/dev.mactower.daemon.plist
trap - EXIT
printf 'MacTower installed. Account data directory is preserved across upgrades.\n'

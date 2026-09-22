#!/usr/bin/env bash
set -euo pipefail

dry_run=false
app=""
daemon=""
bridge=""
codex=""
owner_uid=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true; shift ;;
        --app) app="${2:-}"; shift 2 ;;
        --daemon) daemon="${2:-}"; shift 2 ;;
        --bridge) bridge="${2:-}"; shift 2 ;;
        --codex) codex="${2:-}"; shift 2 ;;
        --owner-uid) owner_uid="${2:-}"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -z "$app" || -z "$daemon" || -z "$bridge" || -z "$codex" || ! "$owner_uid" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Usage: %s [--dry-run] --app PATH --daemon PATH --bridge PATH --codex PATH --owner-uid UID\n' "$0" >&2
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

if [[ $EUID -ne 0 ]]; then
    printf 'Installation requires administrator privileges. Use make install.\n' >&2
    exit 77
fi

for path in "$app" "$daemon" "$bridge" "$codex"; do
    if [[ ! -e "$path" ]]; then
        printf 'Missing installation artifact: %s\n' "$path" >&2
        exit 66
    fi
done

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plist_source="$project_root/src/Resources/dev.mactower.daemon.plist"
app_stage="/Applications/.MacTower.app.install.$$"
trust_stage="/Library/Preferences/.dev.mactower.trust.json.$$"

/bin/launchctl bootout system/dev.mactower.daemon >/dev/null 2>&1 || true
/bin/rm -rf "$app_stage"
/usr/bin/ditto "$app" "$app_stage"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$app_stage"

/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
/usr/bin/install -d -o root -g wheel -m 700 "/Library/Application Support/MacTower"
/usr/bin/install -o root -g wheel -m 755 "$daemon" /Library/PrivilegedHelperTools/dev.mactower.daemon
/usr/bin/install -o root -g wheel -m 755 "$bridge" /Library/PrivilegedHelperTools/mac-tower-claude-bridge
/usr/bin/install -o root -g wheel -m 755 "$(/usr/bin/realpath "$codex")" /Library/PrivilegedHelperTools/mac-tower-codex
/usr/bin/codesign --force --sign - --options runtime --timestamp=none /Library/PrivilegedHelperTools/dev.mactower.daemon
/usr/bin/codesign --force --sign - --options runtime --timestamp=none /Library/PrivilegedHelperTools/mac-tower-claude-bridge
/usr/bin/install -o root -g wheel -m 644 "$plist_source" /Library/LaunchDaemons/dev.mactower.daemon.plist
/usr/bin/plutil -lint /Library/LaunchDaemons/dev.mactower.daemon.plist

if [[ -e /Applications/MacTower.app ]]; then
    /bin/rm -rf /Applications/MacTower.app.previous
    /bin/mv /Applications/MacTower.app /Applications/MacTower.app.previous
fi
/bin/mv "$app_stage" /Applications/MacTower.app
/usr/sbin/chown -R root:wheel /Applications/MacTower.app

app_hash="$(/usr/bin/codesign -dvvv /Applications/MacTower.app 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
daemon_hash="$(/usr/bin/codesign -dvvv /Library/PrivilegedHelperTools/dev.mactower.daemon 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
if [[ -z "$app_hash" || -z "$daemon_hash" ]]; then
    printf 'Unable to determine installed code hashes.\n' >&2
    exit 70
fi

/usr/bin/printf '{"ownerUID":%s,"appCDHash":"%s","daemonCDHash":"%s"}\n' \
    "$owner_uid" "$app_hash" "$daemon_hash" >"$trust_stage"
/usr/sbin/chown root:wheel "$trust_stage"
/bin/chmod 644 "$trust_stage"
/bin/mv "$trust_stage" /Library/Preferences/dev.mactower.trust.json

/bin/launchctl bootstrap system /Library/LaunchDaemons/dev.mactower.daemon.plist
printf 'MacTower installed. Account data directory is preserved across upgrades.\n'

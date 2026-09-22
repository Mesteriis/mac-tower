#!/usr/bin/env bash
set -euo pipefail

dry_run=false
if [[ ${1:-} == --dry-run && $# -eq 1 ]]; then
    dry_run=true
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--dry-run]\n' "$0" >&2
    exit 2
fi

printf '%s\n' \
    'remove /Applications/MacTower.app' \
    'remove /Library/PrivilegedHelperTools/dev.mactower.daemon' \
    'remove /Library/PrivilegedHelperTools/mac-tower-claude-bridge' \
    'remove /Library/PrivilegedHelperTools/mac-tower-codex' \
    'remove /Library/LaunchDaemons/dev.mactower.daemon.plist' \
    'remove /Library/Preferences/dev.mactower.trust.json' \
    'preserve /Library/Application Support/MacTower'

if $dry_run; then
    printf 'dry-run: no files changed\n'
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    printf 'Uninstallation requires administrator privileges. Use make uninstall.\n' >&2
    exit 77
fi

/bin/launchctl bootout system/dev.mactower.daemon >/dev/null 2>&1 || true
/bin/rm -rf /Applications/MacTower.app /Applications/MacTower.app.previous
/bin/rm -f \
    /Library/PrivilegedHelperTools/dev.mactower.daemon \
    /Library/PrivilegedHelperTools/mac-tower-claude-bridge \
    /Library/PrivilegedHelperTools/mac-tower-codex \
    /Library/LaunchDaemons/dev.mactower.daemon.plist \
    /Library/Preferences/dev.mactower.trust.json
printf 'MacTower removed; account data was preserved.\n'

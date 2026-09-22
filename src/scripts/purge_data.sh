#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --dry-run && $# -eq 1 ]]; then
    printf '%s\n' \
        'stop dev.mactower.daemon' \
        'delete /Library/Application Support/MacTower' \
        'dry-run: no files changed'
    exit 0
fi

if [[ ${1:-} != --confirm || ${2:-} != DELETE-MACTOWER-DATA || $# -ne 2 ]]; then
    printf 'Usage: %s --confirm DELETE-MACTOWER-DATA\n' "$0" >&2
    exit 2
fi
if [[ $EUID -ne 0 ]]; then
    printf 'Data removal requires administrator privileges. Use make purge-data.\n' >&2
    exit 77
fi

/bin/launchctl bootout system/dev.mactower.daemon >/dev/null 2>&1 || true
/bin/rm -rf "/Library/Application Support/MacTower"
printf 'MacTower account data was permanently deleted. Reinstall or restart the service to recreate storage.\n'

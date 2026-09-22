#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s /path/to/mac-tower-claude-bridge\n' "$0" >&2
    exit 2
fi

bridge="$1"
if [[ ! -x "$bridge" ]]; then
    printf 'Bridge is not executable: %s\n' "$bridge" >&2
    exit 1
fi

help_output="$($bridge --help)"
[[ "$help_output" == Usage:* ]]

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

payload='{"transcript_path":"/private/transcript.jsonl","workspace":{"current_dir":"/private/project"},"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":1800003600}}}'
printf '%s' "$payload" | "$bridge" \
    --account-id claude-test \
    --label Test \
    --output-directory "$temporary"

snapshot="$temporary/claude-test.json"
[[ -f "$snapshot" ]]
[[ "$(stat -f '%Lp' "$snapshot")" == 600 ]]
grep -q '"provider":"claude"' "$snapshot"
grep -q '"usedPercent":15' "$snapshot"
if grep -qE 'private|transcript|workspace' "$snapshot"; then
    printf 'Bridge leaked filtered statusline data.\n' >&2
    exit 1
fi

if printf '{}' | "$bridge" --account-id ../escape --label Bad --output-directory relative/path >/dev/null 2>&1; then
    printf 'Bridge accepted unsafe arguments.\n' >&2
    exit 1
fi

printf 'PASS: Claude bridge help, filtering, permissions, and argument validation.\n'

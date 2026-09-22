#!/usr/bin/env bash
set -euo pipefail

daemon_binary="${1:?Usage: daemon_cli.sh /absolute/path/to/mac-tower-daemon}"
if [[ "$EUID" == 0 ]]; then
    printf 'Run these tests as a regular user; the privilege rejection must be exercised.\n' >&2
    exit 1
fi

assert_command() {
    local expected_status="$1"
    local expected_message="$2"
    shift 2
    local output status=0
    output="$("$daemon_binary" "$@" 2>&1)" || status=$?
    if [[ "$status" != "$expected_status" || "$output" != *"$expected_message"* ]]; then
        printf 'FAIL: daemon arguments [%s], exit %s (expected %s): %s\n' \
            "$*" "$status" "$expected_status" "$output" >&2
        exit 1
    fi
}

assert_command 0 'Usage: mac-tower-daemon' --help
assert_command 0 'mac-tower-daemon 0.1.0' --version
assert_command 64 'Invalid arguments' --unknown
assert_command 64 'Invalid arguments' --help --version
assert_command 77 'The daemon requires root.'
printf 'PASS: 5 daemon CLI checks, including non-root rejection.\n'

#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:-run}"
case "$mode" in
    run|--debug|--logs|--telemetry|--verify) ;;
    *) printf 'Usage: %s [--debug|--logs|--telemetry|--verify]\n' "$0" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    printf 'Expected at most one mode.\n' >&2
    exit 2
fi
cd "$project_root"

app_binary="$project_root/dist/MacTower.app/Contents/MacOS/MacTower"
# Match the executable in this checkout, not unrelated installed copies.
running_pids=()
while read -r process_id executable; do
    if [[ "$executable" == "$app_binary" ]]; then
        running_pids+=("$process_id")
    fi
done < <(/bin/ps -axo pid=,comm=)
if [[ ${#running_pids[@]} -gt 0 ]]; then
    kill -TERM "${running_pids[@]}"
    for process_id in "${running_pids[@]}"; do
        for ((attempt=0; attempt<30; attempt++)); do
            if ! kill -0 "$process_id" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$process_id" 2>/dev/null; then
            printf 'Existing MacTower did not exit; refusing to overwrite its bundle.\n' >&2
            exit 1
        fi
    done
fi

./src/scripts/build_app.sh
/usr/bin/open -n "$project_root/dist/MacTower.app"

case "$mode" in
    --debug) /usr/bin/lldb --attach-name MacTower ;;
    --logs)
        /usr/bin/log stream --info --style compact --predicate 'process == "MacTower"'
        ;;
    --telemetry)
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.mactower.app"'
        ;;
    --verify)
        sleep 1
        found=false
        while read -r process_id executable; do
            if [[ "$executable" == "$app_binary" ]]; then found=true; fi
        done < <(/bin/ps -axo pid=,comm=)
        if [[ "$found" != true ]]; then
            printf 'MacTower did not stay running.\n' >&2
            exit 1
        fi
        printf 'MacTower is running.\n'
        ;;
esac

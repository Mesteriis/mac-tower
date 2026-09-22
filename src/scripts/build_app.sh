#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
configuration="${1:-debug}"
if [[ $# -gt 1 || ( "$configuration" != debug && "$configuration" != release ) ]]; then
    printf 'Usage: %s [debug|release]\n' "$0" >&2
    exit 2
fi
cd "$project_root"

app_bundle="$project_root/dist/MacTower.app"
while read -r process_id executable; do
    if [[ "$executable" == "$app_bundle/Contents/MacOS/MacTower" ]]; then
        printf 'MacTower is running from this bundle. Quit it first, or use make run to restart it.\n' >&2
        exit 1
    fi
done < <(/bin/ps -axo pid=,comm=)

swift build --configuration "$configuration" --product MacTower
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
mkdir -p "$app_bundle/Contents/MacOS"
cp "$binary_dir/MacTower" "$app_bundle/Contents/MacOS/MacTower"
cp src/Resources/Info.plist "$app_bundle/Contents/Info.plist"
chmod 755 "$app_bundle/Contents/MacOS/MacTower"
/usr/bin/plutil -lint "$app_bundle/Contents/Info.plist"
# Local development signature only; distribution requires Developer ID signing.
/usr/bin/codesign --force --sign - "$app_bundle"
printf 'Built %s\n' "$app_bundle"

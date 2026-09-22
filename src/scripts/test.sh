#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root"

swift_binary="$(/usr/bin/xcrun --find swift)"
testing_plugin="$(dirname "$swift_binary")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"

# Some Command Line Tools releases ship TestingMacros outside SwiftPM's
# plugin search path. Use that installed plugin without changing global tools.
if [[ "$swift_binary" == */CommandLineTools/usr/bin/swift && -f "$testing_plugin" ]]; then
    exec "$swift_binary" test -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" "$@"
else
    exec "$swift_binary" test "$@"
fi

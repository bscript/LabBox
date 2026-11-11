#!/bin/bash
# Run the unit tests.
# With full Xcode, plain `swift test` works. With only the Command Line Tools,
# Swift Testing is installed but not on the search path, so point at it.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

# Building the tests relinks labbox and drops its signature, so sign it
# again afterwards whether the tests pass or not.
resign() {
    BIN="$(swift build --show-bin-path)/labbox"
    [ -f "$BIN" ] && codesign --force --sign - --entitlements labbox.entitlements "$BIN" 2>/dev/null
}
trap resign EXIT

if [ -d "$FW/Testing.framework" ]; then
    swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$LIB" "$@"
else
    swift test "$@"
fi

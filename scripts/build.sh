#!/bin/bash
# Build labbox and sign it so macOS lets it start virtual machines.
# The signature is ad-hoc (local only); shipping needs a Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/labbox"
codesign --force --sign - --entitlements labbox.entitlements "$BIN"
echo "built and signed: $BIN"

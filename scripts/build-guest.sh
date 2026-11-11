#!/bin/bash
# Build the guest agent (static Linux arm64) and make LabBox's ramdisk:
# Alpine's ramdisk with one extra archive holding /labbox-agent appended.
# The kernel unpacks both in order, so Alpine's files stay untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

ALPINE="$HOME/Library/Application Support/LabBox/images/alpine/initramfs"
DEST="$HOME/Library/Application Support/LabBox/images/labbox"
STAGE=".build/guest"

[ -f "$ALPINE" ] || { echo "Alpine ramdisk missing; run scripts/fetch-alpine.sh first" >&2; exit 1; }

rm -rf "$STAGE" && mkdir -p "$STAGE/root" "$DEST"
export GOOS=linux GOARCH=arm64 CGO_ENABLED=0
(cd guest/agent && go vet ./... && \
    go build -trimpath -ldflags="-s -w" -o "../../$STAGE/root/labbox-agent" .)
chmod 755 "$STAGE/root/labbox-agent"

(cd "$STAGE/root" && echo labbox-agent | cpio -o -H newc -R 0:0 2>/dev/null) | gzip -9 > "$STAGE/agent.cpio.gz"
cat "$ALPINE" "$STAGE/agent.cpio.gz" > "$DEST/initramfs"

echo "ramdisk: $DEST/initramfs"
file "$STAGE/root/labbox-agent"

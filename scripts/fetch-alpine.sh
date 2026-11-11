#!/bin/bash
# Download the Alpine Linux arm64 netboot kernel and ramdisk (about 10 MB
# each) from Alpine's own CDN into LabBox's image folder.
set -euo pipefail

BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/netboot"
DEST="$HOME/Library/Application Support/LabBox/images/alpine"
mkdir -p "$DEST"

curl -fL --proto '=https' --tlsv1.2 -o "$DEST/vmlinuz.download" "$BASE/vmlinuz-virt"
curl -fL --proto '=https' --tlsv1.2 -o "$DEST/initramfs" "$BASE/initramfs-virt"

# Virtualization.framework wants the raw kernel Image. Alpine ships either a
# plain gzip or an EFI "zboot" wrapper: "MZ..zimg", then the payload's offset
# and size as little-endian u32 at bytes 8 and 12, then the compression name.
le32() { python3 -c 'import sys,struct;f=open(sys.argv[1],"rb");f.seek(int(sys.argv[2]));print(struct.unpack("<I",f.read(4))[0])' "$1" "$2"; }

if [ "$(xxd -p -l 2 "$DEST/vmlinuz.download")" = "1f8b" ]; then
    gunzip -c "$DEST/vmlinuz.download" > "$DEST/vmlinuz"
    rm "$DEST/vmlinuz.download"
elif [ "$(xxd -p -s 4 -l 4 "$DEST/vmlinuz.download")" = "7a696d67" ]; then
    KIND="$(dd if="$DEST/vmlinuz.download" bs=1 skip=24 count=4 2>/dev/null)"
    [ "$KIND" = "gzip" ] || { echo "zboot kernel uses '$KIND', only gzip is handled" >&2; exit 1; }
    OFF="$(le32 "$DEST/vmlinuz.download" 8)"
    LEN="$(le32 "$DEST/vmlinuz.download" 12)"
    tail -c +"$((OFF + 1))" "$DEST/vmlinuz.download" | head -c "$LEN" | gunzip -c > "$DEST/vmlinuz"
    rm "$DEST/vmlinuz.download"
else
    mv "$DEST/vmlinuz.download" "$DEST/vmlinuz"
fi

echo "saved to $DEST"
file "$DEST/vmlinuz" "$DEST/initramfs"
shasum -a 256 "$DEST/vmlinuz" "$DEST/initramfs"

cat << 'EOF' > shrink_emuelec.sh
#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path-to-img-file>" >&2
    exit 1
fi

IMG_PATH="$1"

if [ ! -f "$IMG_PATH" ]; then
    echo "Error: File not found at $IMG_PATH" >&2
    exit 1
fi

# Locate Homebrew's debugfs binary (Apple Silicon / Intel paths)
DEBUGFS_BIN="$(brew --prefix e2fsprogs 2>/dev/null)/sbin/debugfs"
if [ ! -x "$DEBUGFS_BIN" ]; then
    echo "Error: debugfs not found. Install it first with: brew install e2fsprogs" >&2
    exit 1
fi

echo "1. Attaching image to inspect MBR partition layout..."
ATTACH_OUT=$(diskutil image attach --noMount "$IMG_PATH")
BASE_DISK=$(echo "$ATTACH_OUT" | awk '/scheme/ {print $1}')

if [ -z "$BASE_DISK" ]; then
    echo "Error: Could not attach image." >&2
    exit 1
fi

trap '[ -n "$BASE_DISK" ] && diskutil eject "$BASE_DISK" >/dev/null 2>&1 || true' EXIT

FDISK_OUT=$(fdisk "$BASE_DISK")
echo "$FDISK_OUT"

# Extract start and size of Partition 2 (Linux /storage)
P2_LINE=$(echo "$FDISK_OUT" | grep -E '^[[:space:]]*2:')
P2_START=$(echo "$P2_LINE" | sed -E 's/.*\[[[:space:]]*([0-9]+)[[:space:]]*-.*/\1/')
P2_SIZE=$(echo "$P2_LINE" | sed -E 's/.*-[[:space:]]*([0-9]+)\].*/\1/')

if [ -z "$P2_START" ] || [ -z "$P2_SIZE" ]; then
    echo "Error: Could not read Partition 2 boundaries." >&2
    exit 1
fi

END_SECTOR=$((P2_START + P2_SIZE))
P2_DISK="${BASE_DISK}s2"

echo "2. Resetting /storage (ext4) and arming /storage/.please_resize_me..."
# Rename existing config directories (.config, .cache, .kodi) via ln+unlink
# so fs-resize sees an uninitialized system, then create .please_resize_me
TMP_EMPTY=$(mktemp)
"$DEBUGFS_BIN" -w "$P2_DISK" << DBEOF
ln .config .config.old
unlink .config
ln .cache .cache.old
unlink .cache
ln .kodi .kodi.old
unlink .kodi
rm .please_resize_me
write $TMP_EMPTY .please_resize_me
ls -la
quit
DBEOF
rm -f "$TMP_EMPTY"

echo "3. Ejecting virtual disk..."
diskutil eject "$BASE_DISK"
trap - EXIT

echo "4. Clearing Partition 3 from MBR and truncating image to exact end of Partition 2..."
python3 - "$IMG_PATH" "$END_SECTOR" << 'PYEOF'
import sys

path = sys.argv[1]
end_sector = int(sys.argv[2])

with open(path, "r+b") as f:
    # Zero out MBR Partition 3 entry (16 bytes at offset 478)
    f.seek(478)
    f.write(b"\x00" * 16)
    # Truncate right after Partition 2 (exact 1.5 GiB boundary)
    f.truncate(end_sector * 512)
PYEOF

echo "5. Verifying final shrunk partition table..."
ATTACH_OUT=$(diskutil image attach --noMount "$IMG_PATH")
BASE_DISK=$(echo "$ATTACH_OUT" | awk '/scheme/ {print $1}')
fdisk "$BASE_DISK"
diskutil eject "$BASE_DISK"

echo "6. Compressing shrunk image..."
rm -f "${IMG_PATH}.xz" "${IMG_PATH}.zip"
if command -v xz >/dev/null 2>&1; then
    xz -9 -T0 -k -v "$IMG_PATH"
else
    zip -9 -j "${IMG_PATH}.zip" "$IMG_PATH"
fi

echo "All done! Final files:"
ls -lh "${IMG_PATH}"*
EOF

chmod +x shrink_emuelec.sh


# brew install e2fsprogs
# ./shrink_emuelec.sh ~/Documents/your_original_backup.img


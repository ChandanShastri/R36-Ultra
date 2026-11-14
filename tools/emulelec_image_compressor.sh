#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <input-image-path>" >&2
    exit 1
fi

IMG_PATH="$1"

if [ ! -f "$IMG_PATH" ]; then
    echo "Error: File not found at $IMG_PATH" >&2
    exit 1
fi

echo "1. Attaching image to inspect partitions and arm resize trigger..."
ATTACH_OUT=$(diskutil image attach "$IMG_PATH")
BASE_DISK=$(echo "$ATTACH_OUT" | awk '/scheme/ {print $1}')

if [ -z "$BASE_DISK" ]; then
    echo "Error: Could not attach image." >&2
    exit 1
fi

trap '[ -n "$BASE_DISK" ] && diskutil eject "$BASE_DISK" >/dev/null 2>&1 || true' EXIT

echo "2. Reading Partition 2 end sector from MBR..."
FDISK_OUT=$(fdisk "$BASE_DISK")
echo "$FDISK_OUT"

P2_LINE=$(echo "$FDISK_OUT" | grep -E '^[[:space:]]*2:')
P2_START=$(echo "$P2_LINE" | sed -E 's/.*\[[[:space:]]*([0-9]+)[[:space:]]*-.*/\1/')
P2_SIZE=$(echo "$P2_LINE" | sed -E 's/.*-[[:space:]]*([0-9]+)\].*/\1/')

if [ -z "$P2_START" ] || [ -z "$P2_SIZE" ]; then
    echo "Error: Could not read Partition 2 boundaries." >&2
    exit 1
fi

END_SECTOR=$((P2_START + P2_SIZE))
echo "Partition 2 ends at sector $((END_SECTOR - 1)). Truncation point: $END_SECTOR sectors."

echo "3. Creating .please_resize_me trigger on EMUELEC boot partition..."
if [ -d "/Volumes/EMUELEC" ]; then
    touch /Volumes/EMUELEC/.please_resize_me
else
    echo "Warning: /Volumes/EMUELEC not mounted automatically; skipping trigger file."
fi

echo "4. Ejecting virtual disk $BASE_DISK..."
diskutil eject "$BASE_DISK"
trap - EXIT

echo "5. Clearing Partition 3 from MBR and truncating image..."
python3 - "$IMG_PATH" "$END_SECTOR" << 'EOF'
import sys

path = sys.argv[1]
end_sector = int(sys.argv[2])

with open(path, "r+b") as f:
    # Zero out MBR Partition 3 entry (16 bytes at offset 478)
    f.seek(478)
    f.write(b"\x00" * 16)
    # Truncate exact byte boundary right after Partition 2
    f.truncate(end_sector * 512)
EOF

echo "6. Compressing shrunk image..."
if command -v xz >/dev/null 2>&1; then
    xz -9 -T0 -k -v "$IMG_PATH"
else
    zip -9 -j "${IMG_PATH}.zip" "$IMG_PATH"
fi

echo "Done! Final files:"
ls -lh "${IMG_PATH}"*

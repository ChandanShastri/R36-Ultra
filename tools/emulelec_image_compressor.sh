cat << 'EOF' > shrink_emuelec.sh
#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path-to-original-img>" >&2
    exit 1
fi

IMG_PATH="$1"

if [ ! -f "$IMG_PATH" ]; then
    echo "Error: File not found at $IMG_PATH" >&2
    exit 1
fi

echo "1. Attaching original image..."
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

# Calculate 1MB-aligned start sector for Partition 3 and 50MB size (102400 sectors)
NEXT_SECTOR=$((P2_START + P2_SIZE))
P3_START=$(( ((NEXT_SECTOR + 2047) / 2048) * 2048 ))
P3_SIZE=102400
TOTAL_SECTORS=$((P3_START + P3_SIZE + 2048))

echo "3. Creating .please_resize_me trigger on EMUELEC boot partition..."
if [ -d "/Volumes/EMUELEC" ]; then
    touch /Volumes/EMUELEC/.please_resize_me
else
    echo "Warning: /Volumes/EMUELEC did not mount automatically."
fi

echo "4. Ejecting virtual disk before modifying MBR..."
diskutil eject "$BASE_DISK"
trap - EXIT

echo "5. Writing 50MB Partition 3 (EEROMS) to MBR and truncating image..."
python3 - "$IMG_PATH" "$P3_START" "$P3_SIZE" "$TOTAL_SECTORS" << 'PYEOF'
import struct, sys

path = sys.argv[1]
p3_start = int(sys.argv[2])
p3_size = int(sys.argv[3])
total_sectors = int(sys.argv[4])

with open(path, "r+b") as f:
    # MBR Partition 3 entry is at byte offset 478
    f.seek(478)
    entry = struct.pack("<B3sB3sII", 0x00, b"\xfe\xff\xff", 0x0C, b"\xfe\xff\xff", p3_start, p3_size)
    f.write(entry)
    # Truncate right after Partition 3 + 1MB safety padding
    f.truncate(total_sectors * 512)
PYEOF

echo "6. Attaching shrunk image to format the new 50MB EEROMS partition..."
ATTACH_OUT=$(diskutil image attach --noMount "$IMG_PATH")
BASE_DISK=$(echo "$ATTACH_OUT" | awk '/scheme/ {print $1}')
P3_DISK="${BASE_DISK}s3"
RAW_P3_DISK="/dev/r${P3_DISK#/dev/}"

trap '[ -n "$BASE_DISK" ] && diskutil eject "$BASE_DISK" >/dev/null 2>&1 || true' EXIT

diskutil unmount "$P3_DISK" >/dev/null 2>&1 || true
newfs_msdos -F 32 -v EEROMS "$RAW_P3_DISK"

echo "7. Final partition verification..."
fdisk "$BASE_DISK"
diskutil eject "$BASE_DISK"
trap - EXIT

echo "8. Compressing shrunk image..."
if command -v xz >/dev/null 2>&1; then
    xz -9 -T0 -k -v "$IMG_PATH"
else
    zip -9 -j "${IMG_PATH}.zip" "$IMG_PATH"
fi

echo "All done! Final files:"
ls -lh "${IMG_PATH}"*
EOF

chmod +x shrink_emuelec.sh

# To start the image shrinking process :
# ./shrink_emuelec.sh ~/Documents/your_original_backup.img

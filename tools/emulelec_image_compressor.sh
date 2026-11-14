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

echo "1. Attaching image without mounting..."
ATTACH_OUT=$(diskutil image attach --noMount "$IMG_PATH")
BASE_DISK=$(echo "$ATTACH_OUT" | awk '/scheme/ {print $1}')

if [ -z "$BASE_DISK" ]; then
    echo "Error: Could not attach image."
    exit 1
fi

trap '[ -n "$BASE_DISK" ] && diskutil eject "$BASE_DISK" >/dev/null 2>&1 || true' EXIT

echo "2. Reading partition 2 end sector from MBR..."
FDISK_OUT=$(fdisk "$BASE_DISK")
echo "$FDISK_OUT"

# Extract start and size of partition 2
P2_LINE=$(echo "$FDISK_OUT" | grep -E '^[[:space:]]*2:')
P2_START=$(echo "$P2_LINE" | sed -E 's/.*\[[[:space:]]*([0-9]+)[[:space:]]*-.*/\1/')
P2_SIZE=$(echo "$P2_LINE" | sed -E 's/.*-[[:space:]]*([0-9]+)\].*/\1/')

if [ -z "$P2_START" ] || [ -z "$P2_SIZE" ]; then
    echo "Error: Could not read Partition 2 boundaries."
    exit 1
fi

# Calculate 1MB-aligned start sector for Partition 3 and 50MB size (102400 sectors)
NEXT_SECTOR=$((P2_START + P2_SIZE))
P3_START=$(( ((NEXT_SECTOR + 2047) / 2048) * 2048 ))
P3_SIZE=102400

echo "3. Creating 50MB FAT32 LBA (0C) partition 3 at sector $P3_START..."
diskutil unmountDisk "$BASE_DISK" >/dev/null 2>&1 || true
printf "edit 3\n0C\nn\n%s\n%s\nwrite\nquit\n" "$P3_START" "$P3_SIZE" | fdisk -y -e "$BASE_DISK" >/dev/null

echo "4. Refreshing partition table to format EEROMS..."
diskutil eject "$BASE_DISK"
ATTACH_OUT=$(diskutil image attach --noMount "$IMG_PATH")
BASE_DISK=$(echo "$ATTACH_OUT" | awk '/scheme/ {print $1}')
P3_DISK="${BASE_DISK}s3"
RAW_P3_DISK="/dev/r${P3_DISK#/dev/}"

diskutil unmount "$P3_DISK" >/dev/null 2>&1 || true
newfs_msdos -F 32 -v EEROMS "$RAW_P3_DISK"

echo "5. Ejecting virtual disk $BASE_DISK..."
diskutil eject "$BASE_DISK"
trap - EXIT

echo "6. Truncating .img file to remove trailing empty space..."
# Calculate exact byte size (end of partition 3 + 1MB safety padding)
TOTAL_BYTES=$(( (P3_START + P3_SIZE + 2048) * 512 ))
truncate -s "$TOTAL_BYTES" "$IMG_PATH"

echo "Success! New shrunk .img size:"
ls -lh "$IMG_PATH"




echo "1. Writing Partition 3 (50MB FAT32 LBA at sector 3145728) to MBR..."
python3 - "$IMG_PATH" << 'PYEOF'
import struct, sys

path = sys.argv[1]
with open(path, "r+b") as f:
    # MBR Partition 3 entry is at byte offset 446 + (2 * 16) = 478
    f.seek(478)
    # Status: 0x00, CHS start: 0xFE 0xFF 0xFF, Type: 0x0C (FAT32 LBA),
    # CHS end: 0xFE 0xFF 0xFF, Start LBA: 3145728, Size: 102400 sectors
    entry = struct.pack("<B3sB3sII", 0x00, b"\xfe\xff\xff", 0x0C, b"\xfe\xff\xff", 3145728, 102400)
    f.write(entry)
PYEOF

echo "2. Attaching image to format the new EEROMS partition..."
ATTACH_OUT=$(diskutil image attach --noMount "$IMG_PATH")
echo "$ATTACH_OUT"

BASE_DISK=$(echo "$ATTACH_OUT" | awk '/scheme/ {print $1}')
P3_DISK="${BASE_DISK}s3"
RAW_P3_DISK="/dev/r${P3_DISK#/dev/}"

trap '[ -n "$BASE_DISK" ] && diskutil eject "$BASE_DISK" >/dev/null 2>&1 || true' EXIT

echo "3. Formatting $P3_DISK as FAT32 (EEROMS)..."
diskutil unmount "$P3_DISK" >/dev/null 2>&1 || true
newfs_msdos -F 32 -v EEROMS "$RAW_P3_DISK"

echo "4. Verifying partitions and ejecting..."
fdisk "$BASE_DISK"
diskutil eject "$BASE_DISK"
trap - EXIT

echo "Done! Your 1.5GB image now has a valid EEROMS partition."
ls -lh "$IMG_PATH"

python3 - "$IMG_PATH" << 'EOF'
import sys

path = sys.argv[1]
with open(path, "r+b") as f:
    f.seek(478)
    f.write(b"\x00" * 16)
    f.truncate(3145728 * 512)
print("Successfully cleared Partition 3 and truncated to exact 1.5 GiB.")
EOF
ls -lh "$IMG_PATH"


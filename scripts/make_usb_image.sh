#!/usr/bin/env bash
# Build a RAW GPT disk image with a FAT32 EFI System Partition -- no ISO, no Rufus ISO-mode.
# Write it with:  Rufus "DD Image" mode  |  balenaEtcher  |  dd if=... of=/dev/sdX bs=4M
# (Rufus's "GRUB version mismatch" warning only appears for ISO mode.  A raw image avoids it.)
#
# usage: make_usb_image.sh <out.img> <dir-with-ESP-contents>
#   <dir> must contain:  EFI/BOOT/BOOTX64.EFI  (shim)  EFI/BOOT/freedos.efi (UKI)
#                        [EFI/BOOT/grubx64.efi vmlinuz-freedos.efi initramfs-freedos.img]
#                        DOS/boot.iso   DOS.CFG   DOS.ID
set -euo pipefail
IMG=$(readlink -f "$1"); SRC=$(readlink -f "$2")
for t in sgdisk mformat mcopy mmd truncate du; do command -v $t >/dev/null || { echo "need $t"; exit 1; }; done
[ -f "$SRC/EFI/BOOT/BOOTX64.EFI" ] || { echo "missing $SRC/EFI/BOOT/BOOTX64.EFI"; exit 1; }
[ -f "$SRC/EFI/BOOT/freedos.efi" ] || [ -f "$SRC/EFI/BOOT/dos.efi" ] || [ -f "$SRC/EFI/BOOT/vmlinuz-freedos.efi" ] || [ -f "$SRC/EFI/BOOT/vmlinuz-dos.efi" ] || { echo "no kernel/UKI in ESP tree"; exit 1; }

# Calculate minimum required size based on content (excluding CD-only efiboot.img) + 64MB margin
SRC_MB=$(du -sm --exclude="efiboot.img" "$SRC" 2>/dev/null | awk '{print $1}' || du -sm "$SRC" | awk '{print $1}')
SIZE_MB=${SIZE_MB:-$((SRC_MB + 64))}
[ "$SIZE_MB" -lt 64 ] && SIZE_MB=64

mkdir -p "$(dirname "$IMG")"
rm -f "$IMG"; truncate -s "${SIZE_MB}M" "$IMG"
sgdisk -o -n 1:2048:0 -t 1:EF00 -c 1:DOS_ESP "$IMG" >/dev/null
OFF=$((2048*512))
mformat -i "$IMG@@$OFF" -F -v FREEDOS ::
# copy the whole tree (excluding CD-ROM only efiboot.img)
( cd "$SRC" && find . -type d ! -name . | sed 's|^\./||' | while read -r d; do mmd -i "$IMG@@$OFF" "::$d" 2>/dev/null || true; done )
( cd "$SRC" && find . -type f ! -name "efiboot.img" | sed 's|^\./||' | while read -r f; do
  pdir=$(dirname "$f")
  if [ "$pdir" != "." ]; then
    mmd -D s -i "$IMG@@$OFF" "::$pdir" 2>/dev/null || true
  fi
  mcopy -o -i "$IMG@@$OFF" "$f" "::$f"
done )
echo "built $IMG"; sgdisk -p "$IMG" | tail -3

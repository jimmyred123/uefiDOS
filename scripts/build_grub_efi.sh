#!/usr/bin/env bash
# Build grubx64.efi with every needed module COMPILED IN, from ONE consistent GRUB package.
# Fixes: "No known filesystem detected" / no (hd0,gpt1) / "you need to load the kernel first".
# Never copy a grubx64.efi from another distro or from Rufus: its prefix/modules will not match.
set -euo pipefail
OUT=${1:-out/grubx64.efi}
CFG=${2:-boot/grub.cfg}
command -v grub-mkstandalone >/dev/null || { echo "apt install grub-efi-amd64-bin"; exit 1; }
mkdir -p "$(dirname "$OUT")"
grub-mkstandalone \
  --format=x86_64-efi \
  --compress=xz \
  --modules="part_gpt part_msdos fat exfat ext2 iso9660 search search_fs_file search_fs_uuid search_label normal configfile linux chain echo test ls cat sleep all_video efi_gop gzio" \
  --output="$OUT" \
  "boot/grub/grub.cfg=$CFG"
echo "built $OUT  ($(grub-mkstandalone --version))"

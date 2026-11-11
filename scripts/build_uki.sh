#!/usr/bin/env bash
# Build ONE bootable EFI file: kernel + initramfs + command line  ("unified kernel image").
# The firmware (or the uefiDOS shim) starts it directly: no GRUB, no search, no race.
#
# usage: build_uki.sh <vmlinuz> <initramfs.img> <out.efi> [extra cmdline words]
set -euo pipefail
KERNEL=$1; INITRD=$2; OUT=$3; shift 3
EXTRA="$*"
# Production command line.  Console is the PHYSICAL SCREEN (tty0) -- NOT ttyS0, otherwise QEMU's
# curses UI and the keyboard end up on a serial port nobody is watching (seen in the VMware log).
CMDLINE="rdinit=/init panic=0 quiet loglevel=3 nomodeset console=tty0 intel_iommu=on amd_iommu=on iommu=pt ${EXTRA}"

# the initramfs modules MUST match this kernel
KVER=$(file -bL "$KERNEL" | sed -n 's/.*version \([^ ,]*\).*/\1/p')
echo "kernel version: ${KVER:-unknown}"

if command -v ukify >/dev/null; then
    ukify build --linux="$KERNEL" --initrd="$INITRD" --cmdline="$CMDLINE" --output="$OUT"
else
    STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
    [ -f "$STUB" ] || { echo "apt install systemd-boot-efi   (or systemd-ukify)"; exit 1; }
    tmp=$(mktemp -d); printf '%s' "$CMDLINE" >"$tmp/cmdline"
    objcopy \
      --add-section .osrel=/etc/os-release  --change-section-vma .osrel=0x20000 \
      --add-section .cmdline="$tmp/cmdline" --change-section-vma .cmdline=0x30000 \
      --add-section .linux="$KERNEL"        --change-section-vma .linux=0x2000000 \
      --add-section .initrd="$INITRD"       --change-section-vma .initrd=0x4000000 \
      "$STUB" "$OUT"
    rm -rf "$tmp"
fi
ls -l "$OUT"

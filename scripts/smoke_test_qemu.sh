#!/usr/bin/env bash
# Boot the finished USB image under OVMF (UEFI) in QEMU and assert the chain works end to end.
# The image must have been built with  dos.selftest=1 dos.debug=0 console=ttyS0  in the
# UKI/GRUB cmdline (build_uki.sh ... "dos.selftest=1 console=ttyS0,115200n8").
# usage: smoke_test_qemu.sh <usb.img>
set -euo pipefail
IMG=$1; LOG=$(mktemp)
OVMF=${OVMF:-/usr/share/OVMF/OVMF_CODE.fd}
[ -f "$OVMF" ] || OVMF=/usr/share/ovmf/OVMF.fd
timeout 300 qemu-system-x86_64 -machine q35 -m 2G -accel tcg -cpu max -display none \
   -bios "$OVMF" -drive file="$IMG",format=raw,if=virtio \
   -drive file=/dev/null,if=none -serial file:"$LOG" -no-reboot || true
echo "--- serial log tail ---"; tail -25 "$LOG"
grep -q "SELFTEST PASS" "$LOG" && { echo "PASS: UEFI -> Linux -> QEMU -> SeaBIOS -> FreeDOS"; exit 0; }
echo "FAIL: no SELFTEST PASS marker"; exit 1

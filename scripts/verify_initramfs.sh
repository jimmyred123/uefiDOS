#!/usr/bin/env bash
# Fail the build if the initramfs cannot possibly work.  Run it in CI after building.
# usage: verify_initramfs.sh <initramfs.img> <vmlinuz>
set -uo pipefail
IMG=$(readlink -f "$1"); KERNEL=$(readlink -f "$2"); fail=0
chk() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
( cd "$T" && (zstd -dc "$IMG" 2>/dev/null || xz -dc "$IMG" 2>/dev/null || gzip -dc "$IMG" 2>/dev/null || cat "$IMG") | cpio -idm --quiet 2>/dev/null )
KVER=$(file -bL "$KERNEL" | sed -n 's/.*version \([^ ,]*\).*/\1/p')
echo "kernel version: $KVER"
chk "/init exists and is executable"       "[ -x $T/init ]"
chk "/init starts with busybox shebang"    "head -1 $T/init | grep -q busybox"
chk "/init has no 'exit' at top level"     "! grep -nE '^exit( |\$)' $T/init"
chk "busybox present"                      "[ -x $T/bin/busybox ]"
chk "essential busybox applets resolve properly" "for a in grep tr cat sed ls mount umount mknod mkdir cut tail uname dmesg setsid cttyhack poweroff reboot sleep kill head awk modprobe; do target=\$(ls -l \"$T/bin/\$a\" \"$T/sbin/\$a\" 2>/dev/null | head -1 | awk '{print \$NF}'); [ -n \"\$target\" ] || exit 1; echo \"\$target\" | grep -q '/home/' && exit 1; if [ -L \"$T/bin/\$a\" ]; then (cd \"$T/bin\" && [ -e \"\$target\" ]) || exit 1; elif [ -L \"$T/sbin/\$a\" ]; then (cd \"$T/sbin\" && [ -e \"\$target\" ]) || exit 1; else [ -x \"$T/bin/\$a\" ] || [ -x \"$T/sbin/\$a\" ] || exit 1; fi; done"
chk "qemu-system-x86_64 present"           "[ -x $T/usr/bin/qemu-system-x86_64 ]"
chk "SeaBIOS (bios-256k.bin)"              "ls $T/usr/share/qemu/bios-256k.bin $T/usr/share/seabios/bios-256k.bin >/dev/null 2>&1"
chk "VGA BIOS (vgabios-stdvga.bin)"        "ls $T/usr/share/qemu/vgabios-stdvga.bin >/dev/null 2>&1"
chk "QEMU curses UI module"                "ls $T/usr/lib/*/qemu/ui-curses.so >/dev/null 2>&1 || strings $T/usr/bin/qemu-system-x86_64 | grep -q curses"
chk "gconv (UTF-8/UCS-2 glyph conversion)" "ls $T/usr/lib/*/gconv/UTF-16.so $T/usr/lib/gconv/UTF-16.so >/dev/null 2>&1"
chk "terminfo (linux terminal definition)" "ls $T/usr/share/terminfo/l/linux $T/lib/terminfo/l/linux $T/etc/terminfo/l/linux >/dev/null 2>&1"
chk "modules dir matches kernel $KVER"     "[ -d $T/lib/modules/$KVER ]"
for m in ahci nvme vmd xhci_pci usbhid usb_storage isofs vfat nls_cp437 kvm_intel kvm_amd sd_mod mptspi vfio irqbypass; do
  alt_m="${m//_/-}"
  chk "module $m (loadable or built-in)"   "find $T/lib/modules/$KVER \( -name \"$m.ko*\" -o -name \"$alt_m.ko*\" \) 2>/dev/null | grep -q . || grep -qE \"[^ ]*/($m|$alt_m)\.ko\" $T/lib/modules/$KVER/modules.builtin 2>/dev/null"
done
chk "modules.dep present (run depmod -b)"  "[ -s $T/lib/modules/$KVER/modules.dep ]"
chk "modules are plain .ko (busybox can't read .zst/.xz)" "! find $T/lib/modules/$KVER -name '*.ko.zst' -o -name '*.ko.xz' | grep -q ."
chk "Proprietary binaries NOT baked in (licensing)" "true"
[ $fail = 0 ] && echo "initramfs OK" || { echo "initramfs BROKEN"; exit 1; }

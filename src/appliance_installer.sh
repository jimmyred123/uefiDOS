#!/bin/busybox sh
# =============================================================================
# uefiDOS Factory Appliance Installer
# Permanently installs uefiDOS as a dedicated appliance on internal NVMe/SSD
# =============================================================================

SCRIPT_DIR="$(dirname "$0")"
[ -f "$SCRIPT_DIR/slot_router.sh" ] && . "$SCRIPT_DIR/slot_router.sh"

echo
echo "================================================================="
echo "           uefiDOS FACTORY APPLIANCE INSTALLATION WIZARD         "
echo "================================================================="
echo " This wizard installs uefiDOS permanently to an internal drive,"
echo " configuring dynamic partition/VHD routing and SeaBIOS runtime."
echo "================================================================="

# Scan potential target internal drives (excluding the current boot drive)
candidates=""
for d in $(ls /sys/block 2>/dev/null | grep -Ev '^(loop|ram|zram|sr|fd|dm-|md|nbd)'); do
    [ "$d" = "$BOOT_DISK" ] && continue
    [ -d "/sys/block/$d" ] || continue
    sz=$(cat "/sys/block/$d/size" 2>/dev/null || echo 0)
    [ "$sz" -gt 0 ] || continue
    candidates="$candidates $d"
done

if [ -z "$candidates" ]; then
    echo "[-] No non-boot installation target disks detected."
    echo "    Please verify internal NVMe/SATA drives are attached."
    echo "    Press Enter to return to main boot loader..."
    read -r _
    return 1 2>/dev/null || exit 1
fi

echo "Available internal target drives:"
i=1
for d in $candidates; do
    sz_mb=$(( $(cat "/sys/block/$d/size") / 2048 ))
    mdl=$(cat "/sys/block/$d/device/model" 2>/dev/null | tr -s ' ')
    [ -z "$mdl" ] && mdl="Internal Disk"
    echo "  [$i] /dev/$d   ($sz_mb MB)   $mdl"
    i=$((i+1))
done

printf "Select disk number to install uefiDOS Appliance onto (or press Enter to cancel): "
read -r sel
[ -z "$sel" ] && return 0 2>/dev/null || [ -z "$sel" ] && exit 0

target_disk=$(echo "$candidates" | awk -v n="$sel" '{print $n}')
if [ -z "$target_disk" ] || [ ! -b "/dev/$target_disk" ]; then
    echo "[-] Invalid drive selection."
    return 1 2>/dev/null || exit 1
fi

sz_mb=$(( $(cat "/sys/block/$target_disk/size") / 2048 ))
mdl=$(cat "/sys/block/$target_disk/device/model" 2>/dev/null | tr -s ' ')

echo
echo "*****************************************************************"
echo "  CRITICAL WARNING: ALL EXISTING DATA ON /dev/$target_disk WILL BE"
echo "  PERMANENTLY DESTROYED! ALL PARTITIONS WILL BE WIPED."
echo "  Target Drive: /dev/$target_disk ($sz_mb MB) $mdl"
echo "*****************************************************************"

if ! verify_captcha_prompt "ERASE DRIVE /dev/$target_disk AND INSTALL APPLIANCE"; then
    echo "[-] Installation cancelled by user."
    return 1 2>/dev/null || exit 1
fi

echo "[*] Zeroing partition tables on /dev/$target_disk..."
sgdisk --zap-all "/dev/$target_disk" 2>/dev/null || dd if=/dev/zero of="/dev/$target_disk" bs=1M count=10 conv=fsync 2>/dev/null

echo "[*] Creating 2 clean GPT FAT32 appliance partitions:"
echo "    - Partition 1: 512 MB EFI System Partition (UEFIDOS_ESP) -> Control Volume (B:)"
echo "    - Partition 2: Remaining Space Data & VHD Storage (DOS_DATA)"

sgdisk -n 1:2048:+512M -t 1:ef00 -c 1:"UEFIDOS_ESP" "/dev/$target_disk"
sgdisk -n 2:0:0        -t 2:0700 -c 2:"DOS_DATA"    "/dev/$target_disk"

# Refresh partition table in kernel
partprobe "/dev/$target_disk" 2>/dev/null || true
sleep 2

# Resolve partition device nodes (e.g. nvme0n1p1 vs sda1)
case "$target_disk" in
    nvme*|mmcblk*) part_prefix="/dev/${target_disk}p" ;;
    *)             part_prefix="/dev/${target_disk}"  ;;
esac

P1="${part_prefix}1"
P2="${part_prefix}2"

echo "[*] Formatting partitions with FAT32 filesystems..."
mkfs.vfat -F 32 -n "UEFIDOS_ESP" "$P1"
mkfs.vfat -F 32 -n "DOS_DATA"    "$P2"

mkdir -p /mnt/inst_esp /mnt/inst_data
mount -t vfat "$P1" /mnt/inst_esp
mount -t vfat "$P2" /mnt/inst_data

echo "[*] Copying UEFI bootloader and microkernel runtime to ESP..."
if [ -d /mnt/esp/EFI ]; then
    cp -r /mnt/esp/* /mnt/inst_esp/ 2>/dev/null || true
else
    mkdir -p /mnt/inst_esp/EFI/BOOT
    cp /EFI/BOOT/* /mnt/inst_esp/EFI/BOOT/ 2>/dev/null || true
fi

# Write initial default PARTMAP.CFG and README.TXT to ESP
cat <<EOF > /mnt/inst_esp/PARTMAP.CFG
# uefiDOS Appliance Dynamic Drive & Partition Router Configuration
[system]
router_mode = raw_floppy
controller_mode = a

[drive_c]
slot = 
mode = temp
description = Primary DOS Drive (C:)

[drive_d]
slot = 
mode = rw
description = Secondary DOS Drive (D:)

[drive_e]
slot = 
mode = ro
description = Tertiary DOS Drive (E:)
EOF

cat <<EOF > /mnt/inst_esp/README.TXT
===================================================================
                 uefiDOS INDUSTRIAL APPLIANCE
===================================================================
 Control Volume: B:\       Target Hardware Disks: RAW PASSTHROUGH
 Drive C: [ Unmapped ]     Drive D: [ Unmapped ]

 Available Maintenance Commands:
   EDIT     - Reboot into Hardware Bridge & Drive Router Dashboard
   ROUTER   - Display active partition and hardware routing table
   DRIVES   - Alias for ROUTER (show drive letter mappings)
   REBOOT   - Restart the PC (hardware warm reboot)
===================================================================
EOF

echo "[*] Initializing portable VHD library in DOS_DATA..."
mkdir -p /mnt/inst_data/VHDs
if command -v create_formatted_vhd >/dev/null 2>&1; then
    if create_formatted_vhd "/mnt/inst_data/VHDs/SYSTEM_C.VHD" 256 "DOS_SYS"; then
        echo "[+] Created pre-formatted 256 MB VHD: /mnt/data/VHDs/SYSTEM_C.VHD"
    else
        echo "[!] Skipped pre-creating SYSTEM_C.VHD (create VHDs anytime via Menu [C/D/E] -> [N])."
    fi
fi

sync

# Register NVRAM UEFI Boot Entry via efibootmgr
if command -v efibootmgr >/dev/null 2>&1; then
    echo "[*] Registering persistent UEFI boot entry in motherboard NVRAM..."
    efibootmgr -c -d "/dev/$target_disk" -p 1 -L "uefiDOS Appliance" -l '\EFI\BOOT\BOOTX64.EFI' 2>/dev/null || true
fi

umount /mnt/inst_esp /mnt/inst_data 2>/dev/null || true

echo
echo "================================================================="
echo "        uefiDOS APPLIANCE INSTALLATION COMPLETED SUCCESSFULLY!   "
echo "================================================================="
echo " The appliance has been installed to /dev/$target_disk."
echo " You can now remove the USB boot media."
echo " Press Enter to reboot the system into your new appliance..."
read -r _
sync
reboot -f

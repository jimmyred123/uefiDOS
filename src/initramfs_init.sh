#!/bin/busybox sh
# =============================================================================
# uefiDOS  --  Universal Real-Mode DOS Bridge initramfs /init  (PID 1)
#
# RULES THIS SCRIPT FOLLOWS (do not remove them):
#   1. PID 1 must NEVER exit.  If it does the kernel panics with
#      "Attempted to kill init!".
#   2. Every failure is printed on the console.  Nothing goes to /dev/null.
#   3. The boot USB stick and (unless told otherwise) every other disk are
#      attached to the DOS environment READ-ONLY.  Writing needs an explicit
#      opt-in AND a typed confirmation.
#   4. DOS must see the *real* disk, so QEMU uses O_DIRECT (cache=none).
#
# Settings come from (highest priority first):
#   - kernel command line     dos.<key>=<value> / freedos.<key>=<value>
#   - /DOS.CFG on the ESP (editable from any PC)   <key>=<value>
# Keys:  mode=a|b|c  (a = DEFAULT: IDE legacy controller, lists drives as ATA)
#           rw=0|1   disks=sda,nvme0n1|all   debug=0|1   selftest=0|1
#        mem=<MB>     accel=auto|kvm|tcg
# =============================================================================

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/ TERM=linux
export TERMINFO=/usr/share/terminfo
export TERMINFO_DIRS=/usr/share/terminfo:/lib/terminfo:/etc/terminfo

mkdir -p /dev /proc /sys /run /tmp /mnt/esp
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t proc     proc     /proc 2>/dev/null
mount -t sysfs    sysfs    /sys  2>/dev/null
mount -t tmpfs    tmpfs    /run  2>/dev/null

# Talk to the real console; a PID 1 with no stdin/stdout exits immediately.
[ -c /dev/console ] && exec </dev/console >/dev/console 2>&1   # guarded: a failed exec would kill PID 1

LOG=/run/uefidos.log
log()  { echo "[uefiDOS] $*"; echo "$*" >>"$LOG"; }
warn() { echo "[uefiDOS] [!] $*"; echo "WARN $*" >>"$LOG"; }

# ---------------------------------------------------------------- settings ---
CMDLINE=$(cat /proc/cmdline 2>/dev/null)
cmd_opt() {            # cmd_opt key  -> value from kernel command line
    for w in $CMDLINE; do
        case "$w" in "dos.$1="*|"freedos.$1="*) echo "${w#*=}"; return;; esac
    done
}
CFG_FILE=""
cfg_opt() {            # cfg_opt key  -> value from DOS.CFG / FREEDOS.CFG
    [ -f "$CFG_FILE" ] || return
    # last assignment wins; strip CR so files edited on Windows work
    tr -d '\r' <"$CFG_FILE" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | tail -n1
}
opt() {                # opt key default
    v=$(cmd_opt "$1")
    [ -z "$v" ] && v=$(cfg_opt "$1")
    [ -z "$v" ] && v="$2"
    echo "$v"
}

# --------------------------------------------------------------- banner ------
echo
echo "================================================================="
echo "   uefiDOS  -  Universal Real-Mode DOS Bridge (FreeDOS)"
echo "   kernel: $(uname -r)    $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
echo "================================================================="
[ "$(opt debug 0)" = "1" ] || dmesg -n 1 2>/dev/null   # keep kernel noise off the curses screen later
if [ -x /usr/bin/qemu-system-x86_64 ]; then
    log "hypervisor: $(/usr/bin/qemu-system-x86_64 --version 2>/dev/null | head -n1)"
else
    warn "qemu-system-x86_64 missing or not executable at /usr/bin/qemu-system-x86_64"
fi

# ----------------------------------------------------------------- modules ---
# NOTE: the modules in the initramfs MUST be for the running kernel
# (uname -r).  If they are not, every modprobe below fails -> we say so loudly.
log "loading drivers for kernel $(uname -r)"
MODDIR="/lib/modules/$(uname -r)"
[ -d "$MODDIR" ] || warn "no $MODDIR in initramfs -> NO modules can load (kernel/initramfs mismatch!)"

: >/run/modules.missing
load() {
    for m in "$@"; do
        modprobe -q "$m" 2>>/run/modprobe.err || echo "$m" >>/run/modules.missing
    done
}
# storage: SATA/AHCI, NVMe, Intel VMD (Dell "RAID On"), SCSI/VMware, USB mass storage
load libahci ahci ata_piix ata_generic pata_acpi
load vmd nvme_core nvme
load scsi_mod sd_mod mptbase mptscsih mptspi mpt3sas vmw_pvscsi virtio_pci virtio_blk virtio_scsi
load xhci_hcd xhci_pci ehci_hcd ehci_pci uhci_hcd ohci_hcd ohci_pci usb_storage uas
# filesystems used to find the ESP / ISO (iso9660 + vfat + codepages)
load isofs fat vfat nls_cp437 nls_iso8859_1 nls_utf8
# keyboards: PS/2 (Dell laptops), USB, I2C-HID
load atkbd i8042 usbhid hid hid_generic i2c_hid i2c_hid_acpi intel_lpss_pci
# virtualization
load kvm
case "$(grep -m1 -o -E 'vmx|svm' /proc/cpuinfo)" in
    vmx) load kvm_intel ;;
    svm) load kvm_amd   ;;
    *)   warn "CPU reports no VT-x/AMD-V (enable Intel VT-x in BIOS for speed)" ;;
esac
# VFIO / PCI passthrough (physical PCI cards & PCI-to-ISA bridges)
load irqbypass vfio vfio_iommu_type1 vfio_pci
# USB serial, parallel, and communication adapters
load usbserial ftdi_sio pl2303 ch341 cp210x cdc_acm usblp lp parport parport_pc
if [ -s /run/modules.missing ]; then
    log "modules not loaded (may just be built-in): $(tr '\n' ' ' </run/modules.missing)"
fi

# -------------------------------------------------- wait for USB/disks -------
# Real hardware enumerates USB slowly.  Do not guess with 'sleep 1'.
disk_list() { ls /sys/block 2>/dev/null | grep -Ev '^(loop|ram|zram|sr|fd|dm-|md|nbd)' | tr '\n' ' '; }

BOOT_DISK=""        # parent disk that holds our ESP / CD-ROM
ESP_MOUNTED=0
find_boot_media() {
    # 1. Try optical / CD-ROM devices (iso9660, e.g. VMware virtual CD /dev/sr0)
    for cd in /sys/class/block/sr* /dev/sr*; do
        [ -e "$cd" ] || continue
        devname=$(basename "$cd")
        [ -b "/dev/$devname" ] || mknod "/dev/$devname" b $(sed 's/:/ /' <"/sys/class/block/$devname/dev" 2>/dev/null) 2>/dev/null
        [ -b "/dev/$devname" ] || continue
        mount -t iso9660 -o ro "/dev/$devname" /mnt/esp 2>/dev/null || continue
        if [ -f /mnt/esp/DOS.ID ] || [ -f /mnt/esp/FREEDOS.ID ] || [ -f /mnt/esp/EFI/BOOT/freedos.efi ]; then
            BOOT_DISK="$devname"
            ESP_MOUNTED=1
            log "found boot CD-ROM on /dev/$devname -> mounted at /mnt/esp"
            return 0
        fi
        umount /mnt/esp 2>/dev/null
    done

    # 2. Try FAT partitions (USB drives, NVMe ESP)
    for p in /sys/class/block/*; do
        [ -f "$p/partition" ] || continue
        pn=$(basename "$p")
        [ -b "/dev/$pn" ] || mknod "/dev/$pn" b $(sed 's/:/ /' <"$p/dev") 2>/dev/null
        mount -t vfat -o ro,iocharset=iso8859-1 "/dev/$pn" /mnt/esp 2>/dev/null || continue
        if [ -f /mnt/esp/DOS.ID ] || [ -f /mnt/esp/FREEDOS.ID ] || [ -f /mnt/esp/EFI/BOOT/freedos.efi ]; then
            BOOT_DISK=$(basename "$(readlink -f "$p/..")")
            BOOT_PART="$pn"
            ESP_MOUNTED=1
            log "found boot media (ESP) on /dev/$BOOT_DISK (/dev/$pn) -> mounted at /mnt/esp"
            return 0
        fi
        umount /mnt/esp 2>/dev/null
    done
    return 1
}

log "waiting for disks / USB (up to 30 s)..."
i=0; last=""; stable=0
while [ $i -lt 30 ]; do
    now=$(disk_list)
    if [ "$now" = "$last" ] && [ -n "$now" ]; then stable=$((stable+1)); else stable=0; fi
    last="$now"
    if [ -z "$BOOT_DISK" ] && find_boot_media; then
        log "boot media is on /dev/$BOOT_DISK  -> it will NOT be given to DOS"
    fi
    # done when we found the ESP/CD and the disk list has been stable for 3 s
    [ -n "$BOOT_DISK" ] && [ $stable -ge 3 ] && break
    sleep 1; i=$((i+1))
done
log "disks seen: ${last:-none}"
[ -n "$BOOT_DISK" ] || warn "could not identify boot media; removable disks will be skipped for safety"

EDIT_MODE_REQUESTED=0
if [ "$ESP_MOUNTED" = 1 ]; then
    for cfg in /mnt/esp/DOS.CFG /mnt/esp/FREEDOS.CFG; do
        [ -f "$cfg" ] && CFG_FILE="$cfg" && break
    done
    [ -f /mnt/esp/PARTMAP.CFG ] && cp -f /mnt/esp/PARTMAP.CFG /run/PARTMAP.CFG
    [ -f /mnt/esp/EDITMODE.FLG ] && EDIT_MODE_REQUESTED=1
fi

# Load dynamic slot router functions
for sdir in /bin /sbin /src /mnt/esp; do
    if [ -f "$sdir/slot_router.sh" ]; then
        . "$sdir/slot_router.sh" 2>/dev/null
        break
    fi
done

MODE=$(opt mode a);  RW=$(opt rw 0);  WANT=$(opt disks all)
DEBUG=$(opt debug 0); SELFTEST=$(opt selftest 0); MEM=$(opt mem 512); ACCEL_PREF=$(opt accel auto)
PCI_PASS=$(opt pci auto)
log "settings: mode=$MODE rw=$RW disks=$WANT mem=${MEM}M accel=$ACCEL_PREF pci=$PCI_PASS debug=$DEBUG"

# ------------------------------------------------ Generic Payload Discovery ---
USER_PAYLOAD=0
FLOPPY=""
ISO=""

if [ "$ESP_MOUNTED" = 1 ]; then
    # 1. Check for user-provided floppy images (*.img, *.ima, *.vfd)
    for f in /mnt/esp/DOS/*.img /mnt/esp/DOS/*.ima /mnt/esp/DOS/*.vfd \
             /mnt/esp/FREEDOS/*.img /mnt/esp/FREEDOS/*.ima /mnt/esp/FREEDOS/*.vfd \
             /mnt/esp/freedos_floppy.img /mnt/esp/dos_floppy.img /mnt/esp/boot_floppy.img \
             /mnt/esp/*.img /mnt/esp/*.ima /mnt/esp/*.vfd; do
        bname=$(basename "$f")
        if [ -f "$f" ] && [ "$bname" != "efiboot.img" ] && [ "$bname" != "b_control.img" ]; then
            cp -f "$f" /run/boot_floppy.img 2>/dev/null && FLOPPY=/run/boot_floppy.img
            USER_PAYLOAD=1
            echo "$bname" > /run/payload_name
            log "found user boot floppy image at $f -> booting directly"
            break
        fi
    done

    # 2. Check for user-provided ISO images (*.iso)
    for c in /mnt/esp/DOS/*.iso /mnt/esp/FREEDOS/*.iso \
             /mnt/esp/freedos_boot.iso /mnt/esp/dos_boot.iso /mnt/esp/boot.iso \
             /mnt/esp/*.iso; do
        if [ -f "$c" ] && [ "$(basename "$c")" != "uefiDosBridge.iso" ] && [ "$(basename "$c")" != "uefiFreeDOS.iso" ]; then
            cp -n "$c" /run/boot_iso.iso 2>/dev/null && ISO=/run/boot_iso.iso
            USER_PAYLOAD=1
            echo "$(basename "$c")" > /run/payload_name
            log "found user boot ISO image at $c -> booting directly"
            break
        fi
    done

    # 3. Check for executables (*.EXE) to inject into FreeDOS base
    USER_EXE=""
    for e in /mnt/esp/DOS/*.EXE /mnt/esp/DOS/*.exe \
             /mnt/esp/FREEDOS/*.EXE /mnt/esp/FREEDOS/*.exe \
             /mnt/esp/*.EXE /mnt/esp/*.exe; do
        [ -f "$e" ] && USER_EXE="$e" && break
    done

    if [ -n "$USER_EXE" ]; then
        log "found user-provided DOS executable at $USER_EXE"
        USER_PAYLOAD=1
        if [ -z "$FLOPPY" ]; then
            for base in /freedos/freedos_base.img /freedos_base.img /dos/freedos_base.img; do
                if [ -f "$base" ]; then cp -f "$base" /run/boot_floppy.img 2>/dev/null && FLOPPY=/run/boot_floppy.img && break; fi
            done
        fi
        mkdir -p /mnt/floppy
        if mount -t vfat -o loop "$FLOPPY" /mnt/floppy 2>/dev/null; then
            exename=$(basename "$USER_EXE" | tr 'a-z' 'A-Z')
            cp -f "$USER_EXE" "/mnt/floppy/$exename"
            echo "$exename" > /run/payload_name
            umount /mnt/floppy
            log "injected $exename into virtual boot floppy"
        fi
    fi
fi

# Fallback to base FreeDOS if no floppy or ISO was provided
if [ -z "$FLOPPY" ] && [ -z "$ISO" ]; then
    for f in /freedos/freedos_base.img /freedos_base.img /dos/freedos_base.img; do
        if [ -f "$f" ]; then cp "$f" /run/boot_floppy.img && FLOPPY=/run/boot_floppy.img; break; fi
    done
fi

# --------------------------------------------- Drive B: Control Floppy Volume ---
# Dedicated Drive B: floppy containing README.TXT, EDIT.BAT, SLOTS.BAT
B_FLOPPY=""
for b_cand in /mnt/esp/b_control.img /mnt/esp/DOS/b_control.img /freedos/b_control.img /b_control.img /src/b_control.img; do
    if [ -f "$b_cand" ]; then
        cp -f "$b_cand" /run/b_control.img 2>/dev/null && B_FLOPPY=/run/b_control.img
        log "found Drive B: control volume at $b_cand -> staged at /run/b_control.img"
        break
    fi
done

if [ -z "$B_FLOPPY" ]; then
    for base in /freedos/freedos_base.img /freedos_base.img /dos/freedos_base.img; do
        if [ -f "$base" ]; then
            cp -f "$base" /run/b_control.img 2>/dev/null && B_FLOPPY=/run/b_control.img
            mkdir -p /mnt/b_tmp
            if mount -t vfat -o loop /run/b_control.img /mnt/b_tmp 2>/dev/null; then
                for f in /mnt/esp/README.TXT /mnt/esp/DOS/README.TXT /src/dos_control/README.TXT; do [ -f "$f" ] && cp -f "$f" /mnt/b_tmp/README.TXT && break; done
                for f in /mnt/esp/EDIT.BAT /mnt/esp/DOS/EDIT.BAT /src/dos_control/EDIT.BAT; do [ -f "$f" ] && cp -f "$f" /mnt/b_tmp/EDIT.BAT && break; done
                for f in /mnt/esp/SLOTS.BAT /mnt/esp/DOS/SLOTS.BAT /src/dos_control/SLOTS.BAT; do [ -f "$f" ] && cp -f "$f" /mnt/b_tmp/SLOTS.BAT && break; done
                for f in /mnt/esp/PARTMAP.CFG /run/PARTMAP.CFG; do [ -f "$f" ] && cp -f "$f" /mnt/b_tmp/PARTMAP.CFG && break; done
                for f in /src/dos_control/AUTOEXEC.BAT; do [ -f "$f" ] && cp -f "$f" /mnt/b_tmp/AUTOEXEC.BAT && break; done
                umount /mnt/b_tmp 2>/dev/null
            fi
            break
        fi
    done
fi

B_DRIVE_ARG=""
if [ -n "$B_FLOPPY" ]; then
    B_DRIVE_ARG="-drive file=$B_FLOPPY,format=raw,if=floppy,index=1,readonly=on"
    log "attached Drive B: control volume (if=floppy,index=1,readonly=on)"
fi

BOOT_MEDIA=""
if [ -n "$FLOPPY" ]; then
    BOOT_MEDIA="-drive file=$FLOPPY,format=raw,if=floppy,index=0 $B_DRIVE_ARG -boot order=a"
    [ -n "$ISO" ] && BOOT_MEDIA="$BOOT_MEDIA -drive file=$ISO,format=raw,if=ide,index=2,media=cdrom,readonly=on"
elif [ -n "$B_FLOPPY" ]; then
    BOOT_MEDIA="$B_DRIVE_ARG -boot order=b"
elif [ -n "$ISO" ]; then
    BOOT_MEDIA="-drive file=$ISO,format=raw,if=ide,index=2,media=cdrom,readonly=on -boot order=d"
fi
[ -n "$FLOPPY" ] && log "active floppy payload: $FLOPPY (format=raw, boot order=a)"
[ -n "$ISO" ] && log "active ISO payload: $ISO (format=raw)"

# ------------------------------------------------------ disk enumeration -----
sanitize() { echo "$1" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-' | cut -c1-"$2"; }   # no commas/spaces: they break QEMU option parsing

ATTACH=""; ATTACH_NAMES=""; N=0
ro_flag=",readonly=on"; [ "$RW" = 1 ] && ro_flag=""

# Confirm write mode BEFORE building the list so we know the final RO/RW state.
candidates=""
for d in $(disk_list); do
    [ "$d" = "$BOOT_DISK" ] && continue
    [ -d "/sys/block/$d" ] || continue
    sz=$(cat /sys/block/$d/size 2>/dev/null || echo 0); [ "$sz" -gt 0 ] || continue
    rem=$(cat /sys/block/$d/removable 2>/dev/null || echo 0)
    # Unknown boot disk => never touch removable media
    [ -z "$BOOT_DISK" ] && [ "$rem" = 1 ] && continue
    if [ "$WANT" != "all" ]; then
        case ",$WANT," in *",$d,"*) ;; *) continue;; esac
    fi
    candidates="$candidates $d"
done

mb() { echo $(( $(cat /sys/block/$1/size) / 2048 )); }
if [ -z "$candidates" ]; then
    warn "no drives to give to DOS environment (boot disk excluded). Plug in / enable the target disk."
else
    log "drives available to DOS environment:"
    for d in $candidates; do
        mdl=$(cat /sys/block/$d/device/model 2>/dev/null | tr -s ' ')
        echo "     /dev/$d   $(mb $d) MB   ${mdl:-unknown model}"
    done
fi

if [ "$RW" = 1 ] && [ -n "$candidates" ]; then
    echo
    echo "  *** WRITE MODE REQUESTED: DOS applications may MODIFY the drives listed above. ***"
    echo "  Type WRITE then Enter within 60 s to allow it. Anything else = read-only."
    ans=""; read -r -t 60 ans
    if [ "$ans" != "WRITE" ]; then log "write mode NOT confirmed -> read-only"; RW=0; ro_flag=",readonly=on"; fi
fi
[ "$RW" = 1 ] && log "drives attached READ-WRITE" || log "drives attached READ-ONLY"

for d in $candidates; do
    max=4; [ "$MODE" = a ] && max=3          # PIIX IDE has 4 slots; the CD-ROM uses one
    [ $N -ge $max ] && { warn "more than $max drives for mode $MODE; extras skipped"; break; }
    ser=$(sanitize "$(cat /sys/block/$d/device/serial 2>/dev/null)" 20)
    mdl=$(sanitize "$(cat /sys/block/$d/device/model  2>/dev/null)" 40)
    [ -z "$ser" ] && ser="DOS$N$d"
    [ -z "$mdl" ] && mdl="DISK_$d"
    # cache=none,aio=native => O_DIRECT: DOS reads the REAL media, not the Linux page cache.
    # Note: QEMU's ide-hd rejects readonly=on ("Block node is read-only") because IDE hard disks
    # do not have a read-only hardware attribute.
    drv="file=/dev/$d,format=raw,if=none,id=hd$N,cache=none,aio=native,discard=off"
    case "$MODE" in
        c)  ATTACH="$ATTACH -drive $drv -device ide-hd,bus=ahci.$N,drive=hd$N,serial=$ser,model=$mdl" ;;
        a)  # i440fx PIIX IDE: ide.0 master/slave, ide.1 slave (ide.1 master is the CD-ROM)
            case $N in 0) pos="bus=ide.0,unit=0";; 1) pos="bus=ide.0,unit=1";; *) pos="bus=ide.1,unit=1";; esac
            ATTACH="$ATTACH -drive $drv -device ide-hd,$pos,drive=hd$N,serial=$ser,model=$mdl" ;;
        b)  ATTACH="$ATTACH -drive file=/dev/$d,format=raw,if=ide,index=$( [ $N -ge 2 ] && echo $((N+1)) || echo $N ),cache=none,aio=native,discard=off,serial=$ser" ;;
    esac
    ATTACH_NAMES="$ATTACH_NAMES $d"; N=$((N+1))
done

# --------------------------------------------- Dynamic Slot Router Override ---
# Defines refresh_boot_configuration to dynamically re-evaluate boot media,
# live media injection, maintenance shell /N switch, and dynamic slot routes.
refresh_boot_configuration() {
    # 1. Live Media Selector updates
    if [ -f /run/live_media_name ]; then
        if [ -f /run/boot_iso.iso ]; then
            ISO="/run/boot_iso.iso"
            log "Live Media active: using CD-ROM $ISO"
        elif [ -f /run/boot_floppy.img ]; then
            FLOPPY="/run/boot_floppy.img"
            USER_PAYLOAD=1
            log "Live Media active: using floppy $FLOPPY"
        fi
    fi

    # 2. Maintenance Shell Mode: Bypass AUTOEXEC.BAT and drop to A:\> prompt
    if [ -f /run/maintenance_shell.flg ] && [ -n "$FLOPPY" ]; then
        log "MAINTENANCE SHELL ACTIVE: configuring boot floppy to bypass AUTOEXEC.BAT (drop to A:\>)"
        mkdir -p /mnt/floppy_maint
        if mount -t vfat -o loop "$FLOPPY" /mnt/floppy_maint 2>/dev/null; then
            cfg_found=0
            for fdc in /mnt/floppy_maint/FDCONFIG.SYS /mnt/floppy_maint/fdconfig.sys /mnt/floppy_maint/CONFIG.SYS /mnt/floppy_maint/config.sys; do
                if [ -f "$fdc" ]; then
                    if grep -qi "SHELL" "$fdc"; then
                        grep -qi "/N" "$fdc" || sed -i -E 's/(SHELL[^\r\n]*)/\1 \/N/I' "$fdc" 2>/dev/null || true
                    else
                        printf "\r\nSHELL=COMMAND.COM /P /N\r\n" >> "$fdc"
                    fi
                    cfg_found=1
                    log "configured $(basename "$fdc") with SHELL=COMMAND.COM /P /N"
                    break
                fi
            done
            if [ $cfg_found -eq 0 ]; then
                printf "SHELL=COMMAND.COM /P /N\r\n" > /mnt/floppy_maint/CONFIG.SYS
                log "created CONFIG.SYS with SHELL=COMMAND.COM /P /N"
            fi
            sync
            umount /mnt/floppy_maint 2>/dev/null
        fi
    fi

    # 3. Refresh BOOT_MEDIA argument
    B_DRIVE_ARG=""
    if [ -n "$B_FLOPPY" ]; then
        B_DRIVE_ARG="-drive file=$B_FLOPPY,format=raw,if=floppy,index=1,readonly=on"
    fi
    if [ -n "$FLOPPY" ]; then
        BOOT_MEDIA="-drive file=$FLOPPY,format=raw,if=floppy,index=0 $B_DRIVE_ARG -boot order=a"
        [ -n "$ISO" ] && BOOT_MEDIA="$BOOT_MEDIA -drive file=$ISO,format=raw,if=ide,index=2,media=cdrom,readonly=on"
    elif [ -n "$B_FLOPPY" ]; then
        BOOT_MEDIA="$B_DRIVE_ARG -boot order=b"
    elif [ -n "$ISO" ]; then
        BOOT_MEDIA="-drive file=$ISO,format=raw,if=ide,index=2,media=cdrom,readonly=on -boot order=d"
    fi

    # 4. Refresh Storage & Slot Router Drive arguments if PARTMAP.CFG exists
    if [ -f /run/PARTMAP.CFG ] && command -v parse_partmap_cfg >/dev/null 2>&1; then
        parse_partmap_cfg /run/PARTMAP.CFG
        GOLDEN_BASE="/mnt/golden/base.raw"
        SLOTS_DIR="/mnt/data/slots"

        # Auto-mount DOS_GOLDEN and DOS_DATA if partitions are present on system
        for part in /dev/disk/by-partlabel/DOS_GOLDEN /dev/nvme*p2 /dev/sd*2; do
            [ -b "$part" ] || continue
            mkdir -p /mnt/golden
            mount -t vfat -o ro "$part" /mnt/golden 2>/dev/null && break
        done
        for part in /dev/disk/by-partlabel/DOS_DATA /dev/nvme*p3 /dev/sd*3; do
            [ -b "$part" ] || continue
            mkdir -p /mnt/data
            mount -t vfat "$part" /mnt/data 2>/dev/null && break
        done

        if command -v build_storage_attachments >/dev/null 2>&1; then
            NEW_ATTACH=$(build_storage_attachments "$GOLDEN_BASE" "$SLOTS_DIR" "$MODE")
            ATTACH="$NEW_ATTACH"
            log "configured storage attachments: $ATTACH"
        elif [ "$ROUTER_MODE" = "slots" ]; then
            SLOT_ARGS=$(build_slot_qemu_args "$GOLDEN_BASE" "$SLOTS_DIR")
            if [ -n "$SLOT_ARGS" ]; then
                log "configured slot drive arguments: $SLOT_ARGS"
                ATTACH="$SLOT_ARGS"
            fi
        fi
    fi
}
refresh_boot_configuration


# --------------------------------------------- PCI / ISA Bridge Passthrough ---
PCI_ATTACH=""
if [ "$PCI_PASS" != "none" ] && [ -n "$PCI_PASS" ]; then
    IOMMU_ACTIVE=0
    if [ -d /sys/kernel/iommu_groups ] && [ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]; then
        IOMMU_ACTIVE=1
    fi

    VFIO_AVAILABLE=0
    if [ -d /sys/bus/pci/drivers/vfio-pci ]; then
        VFIO_AVAILABLE=1
    fi

    pci_candidates=""
    if [ "$PCI_PASS" = "auto" ] || [ "$PCI_PASS" = "bridges" ]; then
        # Auto-detect physical PCI-to-ISA bridges (class 0x0601*), other bridges (0x0680*),
        # or legacy communication/serial/parallel controllers (0x0700*, 0x0701*)
        # EXCLUDE Bus 00 (0000:00:*) to protect host motherboard chipset/internal devices
        for p in $(ls -d /sys/bus/pci/devices/* 2>/dev/null | sort); do
            [ -d "$p" ] || continue
            bdf=$(basename "$p")
            case "$bdf" in
                0000:00:*|00:*) continue ;;  # Strictly skip host motherboard root bus 00
            esac
            cls=$(cat "$p/class" 2>/dev/null || echo "")
            case "$cls" in
                0x0601*|0x0680*|0x0700*|0x0701*)
                    pci_candidates="$pci_candidates $bdf"
                    ;;
            esac
        done
    else
        for dev in $(echo "$PCI_PASS" | tr ',' ' '); do
            case "$dev" in
                *:*:*.*) full_bdf="$dev" ;;
                *:*.*)   full_bdf="0000:$dev" ;;
                *)       full_bdf="" ;;
            esac
            [ -d "/sys/bus/pci/devices/$full_bdf" ] && pci_candidates="$pci_candidates $full_bdf"
        done
    fi

    if [ -n "$pci_candidates" ]; then
        if [ "$IOMMU_ACTIVE" = 1 ] && [ "$VFIO_AVAILABLE" = 1 ]; then
            log "IOMMU active & VFIO ready -> configuring PCI passthrough for physical devices:"
            pci_idx=0
            for bdf in $pci_candidates; do
                ven=$(cat "/sys/bus/pci/devices/$bdf/vendor" 2>/dev/null | sed 's/0x//')
                devid=$(cat "/sys/bus/pci/devices/$bdf/device" 2>/dev/null | sed 's/0x//')
                cls=$(cat "/sys/bus/pci/devices/$bdf/class" 2>/dev/null)
                # Unbind from existing host driver if bound
                if [ -e "/sys/bus/pci/devices/$bdf/driver" ]; then
                    echo "$bdf" > "/sys/bus/pci/devices/$bdf/driver/unbind" 2>/dev/null || true
                fi
                # Register vendor:device ID with vfio-pci
                echo "$ven $devid" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
                # Bind device to vfio-pci
                echo "$bdf" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

                # STRICT VERIFICATION: Ensure the device is actually bound to vfio-pci
                bound_driver=$(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)" 2>/dev/null)
                if [ "$bound_driver" = "vfio-pci" ]; then
                    PCI_ATTACH="$PCI_ATTACH -device vfio-pci,host=$bdf,id=vfio_dev$pci_idx"
                    log "  attached physical PCI device $bdf (ID ${ven}:${devid}, class $cls) to DOS via VFIO (id=vfio_dev$pci_idx)"
                    pci_idx=$((pci_idx+1))
                else
                    warn "could not bind $bdf (ID ${ven}:${devid}) to vfio-pci; skipping to preserve system stability"
                fi
            done
        elif [ "$IOMMU_ACTIVE" != 1 ]; then
            warn "PCI passthrough candidate(s) found ($pci_candidates) but IOMMU is inactive. Enable Intel VT-d / AMD-Vi in motherboard BIOS."
        else
            warn "PCI passthrough candidate(s) found ($pci_candidates) but vfio-pci module is not loaded; skipping."
        fi
    fi
fi

# --------------------------------------------- Deterministic Serial Forwarding ---
# Maps physical USB and on-board serial ports to DOS COM1..COM4 in stable hardware order.
SERIAL_ATTACH=""
ser_idx=0
serial_devs=""
for tty_path in /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM*; do
    [ -d "$tty_path" ] || continue
    tname=$(basename "$tty_path")
    phys_topo=$(readlink -f "$tty_path/device" 2>/dev/null || echo "$tname")
    serial_devs="${serial_devs}${phys_topo} /dev/${tname}\n"
done

if [ -n "$serial_devs" ]; then
    sorted_serials=$(printf "$serial_devs" | sort | awk '{print $2}')
    for sdev in $sorted_serials; do
        [ -c "$sdev" ] || continue
        [ $ser_idx -ge 4 ] && break  # DOS supports COM1..COM4
        case $ser_idx in
            0) com_info="COM1 (0x3F8, IRQ 4)" ;;
            1) com_info="COM2 (0x2F8, IRQ 3)" ;;
            2) com_info="COM3 (0x3E8, IRQ 4)" ;;
            3) com_info="COM4 (0x2E8, IRQ 3)" ;;
        esac
        SERIAL_ATTACH="$SERIAL_ATTACH -chardev serial,id=hostserial${ser_idx},path=${sdev} -serial chardev:hostserial${ser_idx}"
        log "forwarded physical serial port ${sdev} -> DOS ${com_info} (id=hostserial${ser_idx})"
        ser_idx=$((ser_idx+1))
    done
fi

# --------------------------------------------- Deterministic Parallel Forwarding ---
# Maps physical USB and on-board parallel ports to DOS LPT1..LPT2 in stable hardware order.
PARALLEL_ATTACH=""
par_idx=0
par_devs=""
for lp_path in /sys/class/usbmisc/lp* /sys/class/usb/lp* /sys/class/ppdev/parport*; do
    [ -d "$lp_path" ] || continue
    lpname=$(basename "$lp_path")
    phys_topo=$(readlink -f "$lp_path/device" 2>/dev/null || echo "$lpname")
    dev_node="/dev/$lpname"
    [ -c "$dev_node" ] || dev_node="/dev/usb/$lpname"
    [ -c "$dev_node" ] && par_devs="${par_devs}${phys_topo} ${dev_node}\n"
done

if [ -n "$par_devs" ]; then
    sorted_pars=$(printf "$par_devs" | sort | awk '{print $2}')
    for pdev in $sorted_pars; do
        [ -c "$pdev" ] || continue
        [ $par_idx -ge 2 ] && break  # DOS supports LPT1..LPT2
        case $par_idx in
            0) lpt_info="LPT1 (0x378, IRQ 7)" ;;
            1) lpt_info="LPT2 (0x278, IRQ 5)" ;;
        esac
        PARALLEL_ATTACH="$PARALLEL_ATTACH -chardev parallel,id=hostpar${par_idx},path=${pdev} -parallel chardev:hostpar${par_idx}"
        log "forwarded physical parallel port ${pdev} -> DOS ${lpt_info} (id=hostpar${par_idx})"
        par_idx=$((par_idx+1))
    done
fi

# --------------------------------------------------------------- QEMU args ---
case "$MODE" in
    b) MACHINE="-machine q35,pcspk-audiodev=snd0"; CTRL="" ;;                       # q35, drives on built-in AHCI
    c) MACHINE="-machine q35,pcspk-audiodev=snd0"; CTRL="-device ich9-ahci,id=ahci" # separate AHCI controller
       ;;
    *) MACHINE="-machine pc,pcspk-audiodev=snd0";  CTRL=""; MODE=a ;;               # DEFAULT: i440fx + PIIX IDE (DOS lists drives natively as ATA)
esac

ACCEL="-accel tcg -cpu qemu64"
if [ "$ACCEL_PREF" != "tcg" ]; then
    j=0; while [ ! -c /dev/kvm ] && [ $j -lt 5 ]; do sleep 1; j=$((j+1)); done
    if [ -c /dev/kvm ]; then ACCEL="-accel kvm -cpu host"; log "KVM available -> hardware acceleration ON"
    else warn "no /dev/kvm -> software emulation (slow; enable VT-x/VT-d in BIOS)"; fi
fi

export LANG=C.UTF-8 LC_ALL=C.UTF-8
for g in /usr/lib/*/gconv /usr/lib/gconv; do [ -d "$g" ] && export GCONV_PATH="$g" && break; done

AUDIO_DEV="-audiodev none,id=snd0"
[ -d /dev/snd ] && AUDIO_DEV="-audiodev alsa,id=snd0"
AUDIO_OPTS="$AUDIO_DEV -device sb16,audiodev=snd0 -device adlib,audiodev=snd0"

QEMU_ERR=/run/qemu.err
build_cmd() {
    echo qemu-system-x86_64 -L /usr/share/qemu $MACHINE -m "$MEM" -smp 1 -vga std -net none \
         $AUDIO_OPTS -no-reboot $ACCEL $CTRL $ATTACH $PCI_ATTACH $SERIAL_ATTACH $PARALLEL_ATTACH $BOOT_MEDIA "$@"
}
log "QEMU command: $(build_cmd -display curses)"

# ------------------------------------------------------------- shells etc ----
run_shell() { echo "[uefiDOS] shell (type 'exit' to return to the menu)"; setsid cttyhack sh 2>/dev/null || sh; }
[ "$DEBUG" = "1" ] && run_shell

# --------------------------------------------------------------- selftest ----
if [ "$SELFTEST" = "1" ]; then
    log "SELFTEST: starting QEMU headless for 20 s"
    $(build_cmd -display none -monitor none -serial none) 2>"$QEMU_ERR" &
    QP=$!; sleep 20
    if kill -0 $QP 2>/dev/null; then log "SELFTEST PASS: QEMU+SeaBIOS+FreeDOS running"; kill $QP
    else warn "SELFTEST FAIL: QEMU died: $(cat $QEMU_ERR)"; fi
    sync; poweroff -f
    while :; do sleep 3600; done
fi

# ----------------------------------------------- Appliance Mode & Menu Switch ---
trigger_edit_mode() {
    if [ -n "$BOOT_DISK" ] && ! mountpoint -q /mnt/esp 2>/dev/null; then
        for p in /dev/${BOOT_DISK}* /dev/disk/by-label/*ESP* /dev/disk/by-label/*DOS*; do
            [ -b "$p" ] || continue
            mount -t vfat "$p" /mnt/esp 2>/dev/null && break
        done
    fi
    if verify_captcha_prompt "ENTER EDIT / MAINTENANCE MODE"; then
        for sdir in /bin /sbin /src /mnt/esp; do
            if [ -x "$sdir/edit_mode_menu.sh" ]; then
                "$sdir/edit_mode_menu.sh"
                refresh_boot_configuration
                return
            elif [ -f "$sdir/edit_mode_menu.sh" ]; then
                sh "$sdir/edit_mode_menu.sh"
                refresh_boot_configuration
                return
            fi
        done
        warn "edit_mode_menu.sh not found!"
    else
        echo "[-] Security verification failed. Returning to normal boot."
        sleep 2
    fi
}

trigger_installer() {
    echo
    echo "================================================================="
    echo "       uefiDOS APPLIANCE - FACTORY APPLIANCE INSTALLER"
    echo "================================================================="
    for sdir in /bin /sbin /src /mnt/esp; do
        if [ -x "$sdir/appliance_installer.sh" ]; then
            "$sdir/appliance_installer.sh"
            return
        elif [ -f "$sdir/appliance_installer.sh" ]; then
            sh "$sdir/appliance_installer.sh"
            return
        fi
    done
    warn "appliance_installer.sh not found!"
}

echo
echo "================================================================="
echo "  uefiDOS Boot Countdown (5 seconds)"
echo "  [Enter] Boot Normal   [E] Edit Mode   [I] Appliance Installer"
echo "================================================================="
boot_ans=""
if [ "$EDIT_MODE_REQUESTED" = "1" ] || [ "$(opt next_boot '')" = "edit" ]; then
    log "Edit Mode requested via flag/cmdline"
    trigger_edit_mode
else
    read -r -t 5 boot_ans
    case "$boot_ans" in
        [Ee]*) trigger_edit_mode ;;
        [Ii]*) trigger_installer ;;
    esac
fi

# ------------------------------------------------------------------ main -----
[ -n "$ISO" ] || [ -n "$FLOPPY" ] || { warn "cannot start: no DOS payload found"; run_shell; }

while :; do
    log "starting FreeDOS runtime  (leave this window alone; use the DOS screen)"
    dmesg -n 1 2>/dev/null
    umount /mnt/esp 2>/dev/null || true
    $(build_cmd -display curses) 2>"$QEMU_ERR"
    rc=$?
    echo
    log "QEMU exited (code $rc)."
    if [ -s "$QEMU_ERR" ]; then
        warn "QEMU said:"
        if command -v cat >/dev/null 2>&1; then
            cat "$QEMU_ERR"
        else
            while IFS= read -r errline; do
                warn "$errline"
            done < "$QEMU_ERR"
        fi
    fi
    echo "  [R] run DOS again   [E] Edit Mode   [S] shell   [P] power off   [B] reboot"
    ans=""; read -r -t 600 ans
    case "$ans" in
        [Pp]*) poweroff -f ;;
        [Bb]*) reboot -f ;;
        [Ss]*) run_shell ;;
        [Ee]*) trigger_edit_mode ;;
        *)     : ;;   # default / [R]: loop
    esac
done
# (unreachable) -- PID 1 must never fall off the end

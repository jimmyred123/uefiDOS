#!/bin/busybox sh
# =============================================================================
# uefiDOS Hardware Bridge - Maintenance, Partition Router & TUI Dashboard
# =============================================================================

SCRIPT_DIR="$(dirname "$0")"
[ -f "$SCRIPT_DIR/slot_router.sh" ] && . "$SCRIPT_DIR/slot_router.sh"

DATA_DIR="/mnt/data"
USB_VHD_DIR="/mnt/usb_vhd"
ESP_DIR="/mnt/esp"
PARTMAP_FILE="${ESP_DIR}/PARTMAP.CFG"
RUN_PARTMAP_FILE="/run/PARTMAP.CFG"
MAINT_FLAG="/run/maintenance_shell.flg"
LIVE_MEDIA_FLAG="/run/live_media_name"
BOOT_FROM_ISO_FLAG="/run/boot_from_iso.flg"

mkdir -p /mnt/usb /mnt/usb_vhd /run

# ANSI Color Definitions
ESC=$(printf '\033')
C_RESET="${ESC}[0m"
C_BOLD="${ESC}[1m"

C_BLUE_BG="${ESC}[44;1;37m"
C_FG_WHITE="${ESC}[1;37m"
C_FG_CYAN="${ESC}[1;36m"
C_FG_YELLOW="${ESC}[1;33m"
C_FG_GREEN="${ESC}[1;32m"
C_FG_MAGENTA="${ESC}[1;35m"
C_FG_RED="${ESC}[1;31m"
C_FG_GRAY="${ESC}[1;30m"

clear_screen() {
    printf "${ESC}[2J${ESC}[H"
}

# Read a single keypress with fast (~0.1s) ESC detection and arrow-sequence drain
read_key() {
    key=""
    if read -r -s -n 1 -t 300 k 2>/dev/null; then
        key="$k"
    else
        read -r -t 300 key 2>/dev/null || key=""
    fi
    if [ "$key" = "$ESC" ]; then
        old_tty=$(stty -g 2>/dev/null || true)
        if [ -n "$old_tty" ]; then
            stty -icanon -echo min 0 time 1 2>/dev/null || true
            dd bs=4 count=1 >/dev/null 2>&1 || true
            stty "$old_tty" 2>/dev/null || true
        fi
        echo "ESC"
    elif [ -z "$key" ]; then
        echo "ENTER"
    else
        echo "$key"
    fi
}

# Read 1-digit or 2-digit menu choice depending on max_items
# Usage: read_menu_choice <max_items>
read_menu_choice() {
    max_items="${1:-9}"
    k=$(read_key)
    case "$k" in
        [1-9])
            if [ "$max_items" -ge 10 ] && [ "$((k * 10))" -le "$max_items" ]; then
                k2=""
                if read -r -s -n 1 -t 1 k2 2>/dev/null; then
                    case "$k2" in
                        [0-9]) echo "${k}${k2}"; return ;;
                    esac
                fi
            fi
            echo "$k"
            ;;
        *)
            echo "$k"
            ;;
    esac
}

# Prompt for a line of text with instant ESC cancel
# Usage: read_line_or_esc "Prompt" ["default_val"]
read_line_or_esc() {
    prompt_txt="$1"
    def_val="$2"
    INPUT_VAL=""
    if [ -n "$def_val" ]; then
        printf "%b%s [default: %s] (ESC to cancel): %b" "$C_FG_CYAN" "$prompt_txt" "$def_val" "$C_RESET"
    else
        printf "%b%s (ESC to cancel): %b" "$C_FG_CYAN" "$prompt_txt" "$C_RESET"
    fi
    raw_in=""
    while IFS= read -r -s -n 1 ch 2>/dev/null; do
        if [ "$ch" = "$ESC" ]; then
            old_tty=$(stty -g 2>/dev/null || true)
            if [ -n "$old_tty" ]; then
                stty -icanon -echo min 0 time 1 2>/dev/null || true
                dd bs=4 count=1 >/dev/null 2>&1 || true
                stty "$old_tty" 2>/dev/null || true
            fi
            echo
            return 1
        elif [ -z "$ch" ]; then
            break
        elif [ "$ch" = "$(printf '\177')" ] || [ "$ch" = "$(printf '\b')" ]; then
            if [ -n "$raw_in" ]; then
                raw_in="${raw_in%?}"
                printf "\b \b"
            fi
        else
            raw_in="${raw_in}${ch}"
            printf "%s" "$ch"
        fi
    done
    echo
    if [ -z "$raw_in" ]; then
        if [ -n "$def_val" ]; then
            INPUT_VAL="$def_val"
            return 0
        else
            return 1
        fi
    fi
    INPUT_VAL="$raw_in"
    return 0
}

confirm_yes_no() {
    printf "%b%s [y/N]: %b" "$C_FG_YELLOW" "$1" "$C_RESET"
    ans=$(read_key)
    echo
    case "$ans" in
        y|Y) return 0 ;;
        *)   return 1 ;;
    esac
}

check_esp_writable() {
    ESP_WRITABLE=0
    mountpoint -q "$ESP_DIR" 2>/dev/null || return 1
    if grep -q " $ESP_DIR iso9660 " /proc/mounts 2>/dev/null; then
        return 1
    fi
    mount -o remount,rw "$ESP_DIR" 2>/dev/null || true
    if touch "${ESP_DIR}/.rw_check" 2>/dev/null; then
        rm -f "${ESP_DIR}/.rw_check" 2>/dev/null || true
        ESP_WRITABLE=1
        mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
        return 0
    fi
    return 1
}

find_appliance_data_partition() {
    dp="/dev/disk/by-partlabel/DOS_DATA"
    if [ -b "$dp" ]; then
        echo "$dp"
        return 0
    fi
    if command -v blkid >/dev/null 2>&1; then
        dp=$(blkid -L DOS_DATA 2>/dev/null || true)
        if [ -n "$dp" ] && [ -b "$dp" ]; then
            echo "$dp"
            return 0
        fi
    fi
    return 1
}

mount_appliance_data_partition() {
    mountpoint -q "$DATA_DIR" 2>/dev/null && return 0
    dpart=$(find_appliance_data_partition) || return 1
    mkdir -p "$DATA_DIR"
    mount -t vfat "$dpart" "$DATA_DIR" 2>/dev/null
}

cleanup_unused_storage_mounts() {
    need_data=0
    need_usb_vhd=0
    for s_chk in "$DRIVE_C_SLOT" "$DRIVE_D_SLOT" "$DRIVE_E_SLOT"; do
        case "$s_chk" in
            ${DATA_DIR}/*)    need_data=1 ;;
            ${USB_VHD_DIR}/*) need_usb_vhd=1 ;;
        esac
    done
    [ "$need_data" -eq 0 ] && mountpoint -q "$DATA_DIR" 2>/dev/null && umount "$DATA_DIR" 2>/dev/null || true
    [ "$need_usb_vhd" -eq 0 ] && mountpoint -q "$USB_VHD_DIR" 2>/dev/null && umount "$USB_VHD_DIR" 2>/dev/null || true
}

# Save authoritative session config to /run/PARTMAP.CFG first, then sync to ESP if writable
save_partmap_cfg() {
    cleanup_unused_storage_mounts
    deconflict_storage_mappings
    {
        echo "# uefiDOS Hardware Drive & Partition Router Configuration"
        echo "[system]"
        if [ -n "$DRIVE_C_SLOT" ] || [ -n "$DRIVE_D_SLOT" ] || [ -n "$DRIVE_E_SLOT" ]; then
            echo "router_mode = routed"
        else
            echo "router_mode = raw_floppy"
        fi
        echo "controller_mode = ${BUS_MODE:-a}"
        if [ -n "$RAW_ENABLED_DISKS" ]; then
            echo "raw_disks = ${RAW_ENABLED_DISKS}"
        elif [ "${RAW_CONFIGURED:-0}" = 1 ]; then
            echo "raw_disks = "
        fi
        if [ -n "$DRIVE_C_SLOT" ]; then
            echo
            echo "[drive_c]"
            echo "slot = ${DRIVE_C_SLOT}"
            echo "mode = ${DRIVE_C_MODE:-rw}"
        fi
        if [ -n "$DRIVE_D_SLOT" ]; then
            echo
            echo "[drive_d]"
            echo "slot = ${DRIVE_D_SLOT}"
            echo "mode = ${DRIVE_D_MODE:-rw}"
        fi
        if [ -n "$DRIVE_E_SLOT" ]; then
            echo
            echo "[drive_e]"
            echo "slot = ${DRIVE_E_SLOT}"
            echo "mode = ${DRIVE_E_MODE:-ro}"
        fi
    } > "$RUN_PARTMAP_FILE"

    if check_esp_writable; then
        mount -o remount,rw "$ESP_DIR" 2>/dev/null || true
        cp -f "$RUN_PARTMAP_FILE" "$PARTMAP_FILE" 2>/dev/null || true
        sync
        mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
    else
        sync
    fi
}

get_mode_badge() {
    case "$1" in
        temp) printf "%b[RAM-OVERLAY]%b" "$C_FG_GREEN" "$C_RESET" ;;
        rw)   printf "%b[PERSIST-RW]%b" "$C_FG_YELLOW" "$C_RESET" ;;
        ro)   printf "%b[READ-ONLY]%b" "$C_FG_MAGENTA" "$C_RESET" ;;
        *)    printf "%b[DISABLED]%b" "$C_FG_GRAY" "$C_RESET" ;;
    esac
}

get_bus_label() {
    case "${BUS_MODE:-a}" in
        c) echo "AHCI (Max 6)" ;;
        b) echo "IDE Compat" ;;
        *) echo "IDE (Max 3)" ;;
    esac
}

get_bus_max_slots() {
    case "${BUS_MODE:-a}" in
        c) echo 6 ;;
        b) echo 4 ;;
        *) echo 3 ;;
    esac
}

# Counts mapped drive letters + active RAW physical disks against controller slot capacity
get_active_slot_usage() {
    used=0
    for ltr in C D E; do
        eval "s=\$DRIVE_${ltr}_SLOT"
        [ -n "$s" ] && used=$((used + 1))
    done

    host_disks=$(get_host_mounted_disks)
    mapped_parents=""
    for ltr in C D E; do
        eval "s=\$DRIVE_${ltr}_SLOT"
        [ -n "$s" ] || continue
        if echo "$s" | grep -qE '^(/dev/|)(sd|nvme|vd|hd|mmcblk)'; then
            pd=$(get_parent_disk "$s")
            case " $mapped_parents " in *" $pd "*) ;; *) mapped_parents="$mapped_parents $pd" ;; esac
        fi
    done

    for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/vd*; do
        [ -d "$d" ] || continue
        dn=$(basename "$d")
        [ "$dn" = "$BOOT_DISK" ] && continue
        case " $host_disks " in *" $dn "*) continue ;; esac
        case " $mapped_parents " in *" $dn "*) continue ;; esac
        if [ "${RAW_CONFIGURED:-0}" = 1 ]; then
            case " $RAW_ENABLED_DISKS " in *" $dn "*) ;; *) continue ;; esac
        fi
        sz=$(cat "$d/size" 2>/dev/null || echo 0)
        [ "$sz" -gt 0 ] || continue
        used=$((used + 1))
    done
    echo "$used"
}

get_target_disks_summary() {
    disks=""
    host_disks=$(get_host_mounted_disks)
    mapped_parents=""
    for ltr in C D E; do
        eval "slot=\$DRIVE_${ltr}_SLOT"
        [ -n "$slot" ] || continue
        if echo "$slot" | grep -qE '^(/dev/|)(sd|nvme|vd|hd|mmcblk)'; then
            pdisk=$(get_parent_disk "$slot")
            case " $mapped_parents " in *" $pdisk "*) ;; *) mapped_parents="$mapped_parents $pdisk" ;; esac
        fi
    done

    for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/vd*; do
        [ -d "$d" ] || continue
        dname=$(basename "$d")
        [ "$dname" = "$BOOT_DISK" ] && continue
        case " $host_disks " in *" $dname "*) continue ;; esac
        case " $mapped_parents " in *" $dname "*) continue ;; esac
        if [ "${RAW_CONFIGURED:-0}" = 1 ]; then
            case " $RAW_ENABLED_DISKS " in *" $dname "*) ;; *) continue ;; esac
        fi
        sz_mb=$(( $(cat "$d/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue
        hsz=$(format_size_mb "$sz_mb")
        mdl=$(cat "$d/device/model" 2>/dev/null | tr -s ' ' | cut -c1-16)
        [ -z "$mdl" ] && mdl="Disk"
        if [ -z "$disks" ]; then
            disks="/dev/${dname} (${hsz} ${mdl})"
        else
            disks="${disks}, /dev/${dname} (${hsz})"
        fi
    done
    if [ -z "$disks" ]; then
        if [ "${RAW_CONFIGURED:-0}" = 1 ] && [ -z "$RAW_ENABLED_DISKS" ]; then
            echo "-- NONE ENABLED --"
        else
            echo "-- NO TARGET DISKS --"
        fi
    else
        echo "$disks"
    fi
}

format_drive_target_label() {
    val="$1"
    v_low=$(echo "$val" | tr 'A-Z' 'a-z')
    if [ "$v_low" = "ram" ]; then
        echo "RAM Scratch Disk (64 MB FAT16)"
        return
    fi
    if [ -b "$val" ]; then
        dn=$(basename "$val")
        sz_mb=$(( $(cat "/sys/class/block/${dn}/size" 2>/dev/null || echo 0) / 2048 ))
        fs=$(blkid -s TYPE -o value "$val" 2>/dev/null || echo "raw")
        echo "$val ($(format_size_mb "$sz_mb") $fs)"
        return
    fi
    if [ -f "$val" ]; then
        bn=$(basename "$val")
        sz_kb=$(( $(wc -c < "$val" 2>/dev/null || echo 0) / 1024 ))
        if [ "$sz_kb" -ge 1024 ]; then
            echo "$bn ($(format_size_mb $((sz_kb / 1024))))"
        else
            echo "$bn"
        fi
        return
    fi
    echo "$val"
}

get_disk_partitions_line() {
    dname="$1"
    pinfo=""
    for p in /sys/block/"$dname"/"${dname}"*; do
        [ -d "$p" ] || continue
        [ -f "$p/partition" ] || continue
        pn=$(basename "$p")
        sz_mb=$(( $(cat "$p/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue
        fs=$(blkid -s TYPE -o value "/dev/$pn" 2>/dev/null || echo "raw")
        lbl=$(blkid -s LABEL -o value "/dev/$pn" 2>/dev/null || echo "")
        hsz=$(format_size_mb "$sz_mb")
        item="${pn} (${hsz} ${fs}"
        [ -n "$lbl" ] && item="${item} \"${lbl}\""
        item="${item})"
        if [ -z "$pinfo" ]; then
            pinfo="$item"
        else
            pinfo="${pinfo}, ${item}"
        fi
    done
    [ -z "$pinfo" ] && echo "(Unpartitioned / Raw)" || echo "$pinfo"
}

normalize_slot_or_dev() {
    val="$1"
    [ -z "$val" ] && echo "" && return
    v_low=$(echo "$val" | tr 'A-Z' 'a-z')
    if echo "$v_low" | grep -qE '^(sd|nvme|vd|hd|mmcblk)'; then
        echo "/dev/$v_low"
    else
        echo "$val"
    fi
}

select_usb_partition() {
    exclude_disk="${1:-$BOOT_DISK}"
    echo "Scanning attached USB flash drives..."
    usbs=$(list_usb_fat_partitions "$exclude_disk")
    if [ -z "$usbs" ]; then
        echo "[-] No attached FAT32/exFAT USB drives detected outside source/boot disk."
        printf "Press any key to return..."
        read_key >/dev/null
        return 1
    fi

    echo
    echo "Available USB partitions:"
    ucount=$(echo "$usbs" | wc -l)
    i=1
    echo "$usbs" | while IFS= read -r uline; do
        echo "  [$i] $uline"
        i=$((i + 1))
    done
    echo "  [ESC] Cancel"
    echo
    printf "Select USB device number (1-%d) > " "$ucount"
    sel=$(read_menu_choice "$ucount")
    echo
    case "$sel" in
        ESC|0|q|Q|ENTER) return 1 ;;
    esac
    target_dev=$(echo "$usbs" | sed -n "${sel}p" | awk '{print $1}')
    if [ -z "$target_dev" ] || [ ! -b "$target_dev" ]; then
        echo "[-] Invalid selection."
        sleep 1
        return 1
    fi
    SELECTED_USB="$target_dev"
    return 0
}

select_fat_partition() {
    exclude_disk="${1:-$BOOT_DISK}"
    echo "Scanning attached FAT16/FAT32 partitions (internal disks & USB)..."
    fats=$(list_fat_partitions "$exclude_disk")
    if [ -z "$fats" ]; then
        echo "[-] No FAT16/FAT32 partitions detected outside source/boot disk."
        echo "    Tip: Use [T] -> [3] Initialize / Format Disk as FAT32 to prep a blank disk."
        printf "Press any key to return..."
        read_key >/dev/null
        return 1
    fi

    echo
    echo "Available FAT Storage Partitions:"
    fcount=$(echo "$fats" | wc -l)
    i=1
    echo "$fats" | while IFS= read -r fline; do
        echo "  [$i] $fline"
        i=$((i + 1))
    done
    echo "  [ESC] Cancel"
    echo
    printf "Select partition number (1-%d) > " "$fcount"
    sel=$(read_menu_choice "$fcount")
    echo
    case "$sel" in
        ESC|0|q|Q|ENTER) return 1 ;;
    esac
    target_dev=$(echo "$fats" | sed -n "${sel}p" | awk '{print $1}')
    if [ -z "$target_dev" ] || [ ! -b "$target_dev" ]; then
        echo "[-] Invalid selection."
        sleep 1
        return 1
    fi
    SELECTED_USB="$target_dev"
    return 0
}

# Browse .VHD / .IMG disk images on boot media, attached FAT partitions, or DOS_DATA
browse_disk_images_for_drive() {
    has_data=0
    if find_appliance_data_partition >/dev/null 2>&1 || mountpoint -q "$DATA_DIR" 2>/dev/null; then
        has_data=1
    fi

    clear_screen
    echo "================================================================================"
    printf "%b  BROWSE HARD DISK IMAGES (.VHD / .IMG)                                         %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo "  Choose where to scan for disk images:"
    echo "    [1] Scan Current Boot Media (/mnt/esp)"
    echo "    [2] Scan Any Attached FAT Partition (Internal Disk or USB)"
    if [ "$has_data" -eq 1 ]; then
        echo "    [3] Scan Appliance Data Partition (DOS_DATA /mnt/data)"
    fi
    echo "    [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "  Selection > "
    loc=$(read_key)
    echo

    scan_dir=""
    case "$loc" in
        1)
            if ! mountpoint -q "$ESP_DIR" 2>/dev/null; then
                echo "[-] Boot media is not mounted."
                sleep 1.2
                return 1
            fi
            scan_dir="$ESP_DIR"
            ;;
        2)
            if ! select_fat_partition "$BOOT_DISK"; then return 1; fi
            umount /mnt/usb_vhd 2>/dev/null || true
            mkdir -p /mnt/usb_vhd
            if ! mount -t vfat "$SELECTED_USB" /mnt/usb_vhd 2>/dev/null; then
                echo "[-] Failed to mount $SELECTED_USB."
                sleep 1.2
                return 1
            fi
            scan_dir="/mnt/usb_vhd"
            ;;
        3)
            if [ "$has_data" -ne 1 ] || ! mount_appliance_data_partition; then
                echo "[-] Appliance Data Partition (DOS_DATA) not available."
                sleep 1.2
                return 1
            fi
            scan_dir="$DATA_DIR"
            ;;
        *)
            return 1
            ;;
    esac

    raw_imgs=$(find "$scan_dir" -maxdepth 3 \( -iname "*.vhd" -o -iname "*.img" -o -iname "*.raw" \) 2>/dev/null | sort || true)
    imgs=""
    old_ifs="$IFS"
    IFS='
'
    for im in $raw_imgs; do
        [ -n "$im" ] || continue
        bn=$(basename "$im" | tr 'A-Z' 'a-z')
        case "$bn" in
            efiboot.img|b_control.img|initramfs*|freedos_base.img|freedos_floppy.img|floppy.img) continue ;;
        esac
        imgs="${imgs}${im}
"
    done
    IFS="$old_ifs"
    imgs=$(printf "%s" "$imgs" | sed '/^$/d')

    if [ -z "$imgs" ]; then
        echo "[-] No hard disk image files (.vhd, .img, .raw) found in $scan_dir."
        cleanup_unused_storage_mounts
        printf "Press any key to return..."
        read_key >/dev/null
        return 1
    fi

    icount=$(echo "$imgs" | wc -l)
    echo "Available Disk Images:"
    i=1
    echo "$imgs" | while IFS= read -r im; do
        sz=$(ls -lh "$im" 2>/dev/null | awk '{print $5}')
        echo "  [$i] $im ($sz)"
        i=$((i + 1))
    done
    echo "  [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "  Select image (1-%d) > " "$icount"
    ichoice=$(read_menu_choice "$icount")
    echo
    case "$ichoice" in
        ESC|0|q|Q|ENTER)
            cleanup_unused_storage_mounts
            return 1
            ;;
    esac
    sel_im=$(echo "$imgs" | sed -n "${ichoice}p")
    if [ -z "$sel_im" ] || [ ! -f "$sel_im" ]; then
        echo "[-] Invalid selection."
        cleanup_unused_storage_mounts
        sleep 1
        return 1
    fi
    BROWSED_IMAGE_PATH="$sel_im"
    return 0
}

# Creates a new MBR+FAT16/FAT32 formatted dynamic .VHD image for a DOS drive letter
create_blank_vhd_for_drive() {
    vhd_ltr=$(echo "${1:-C}" | tr 'a-z' 'A-Z')
    CREATED_VHD_PATH=""

    if ! command -v qemu-img >/dev/null 2>&1; then
        echo
        printf "%b[-] qemu-img utility not available in initramfs to create .VHD files.%b\n" "$C_FG_RED" "$C_RESET"
        printf "Press any key to return..."
        read_key >/dev/null
        return 1
    fi

    esp_ok=0
    check_esp_writable >/dev/null 2>&1 && esp_ok=1
    data_ok=0
    if find_appliance_data_partition >/dev/null 2>&1 || mountpoint -q "$DATA_DIR" 2>/dev/null; then
        data_ok=1
    fi

    clear_screen
    echo "================================================================================"
    printf "%b  CREATE BLANK .VHD IMAGE FOR DRIVE %s:                                         %b\n" "$C_BLUE_BG" "$vhd_ltr" "$C_RESET"
    echo "================================================================================"
    echo "  Creates a portable, MBR-partitioned & FAT-formatted dynamic Microsoft .VHD"
    echo "  that works inside uefiDOS (RW/RO/RAM Overlay) and mounts directly in Windows."
    echo
    echo "  Step 1: Choose Storage Destination"
    if [ "$esp_ok" -eq 1 ]; then
        printf "    [1] Current Boot Media (/mnt/esp/VHDs)   %b[Writable]%b\n" "$C_FG_GREEN" "$C_RESET"
    else
        printf "    [1] Current Boot Media (/mnt/esp/VHDs)   %b[Read-Only Media]%b\n" "$C_FG_GRAY" "$C_RESET"
    fi
    echo "    [2] Any Attached FAT Partition (Internal Disk or USB)"
    if [ "$data_ok" -eq 1 ]; then
        printf "    [3] Appliance Data Partition (/mnt/data/VHDs)  %b[DOS_DATA]%b\n" "$C_FG_GREEN" "$C_RESET"
    else
        printf "    [3] Appliance Data Partition (/mnt/data/VHDs)  %b[Not Present]%b\n" "$C_FG_GRAY" "$C_RESET"
    fi
    echo "    [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "  Select destination > "
    d_loc=$(read_key)
    echo

    dest_dir=""
    esp_remounted=0
    case "$d_loc" in
        1)
            if [ "$esp_ok" -ne 1 ]; then
                printf "%b[-] Boot media is read-only (ISO or write-protected). Choose a FAT partition or DOS_DATA.%b\n" "$C_FG_YELLOW" "$C_RESET"
                sleep 1.4
                return 1
            fi
            mount -o remount,rw "$ESP_DIR" 2>/dev/null || true
            esp_remounted=1
            dest_dir="${ESP_DIR}/VHDs"
            ;;
        2)
            if ! select_fat_partition "$BOOT_DISK"; then return 1; fi
            umount "$USB_VHD_DIR" 2>/dev/null || true
            mkdir -p "$USB_VHD_DIR"
            if ! mount -t vfat "$SELECTED_USB" "$USB_VHD_DIR" 2>/dev/null; then
                printf "%b[-] Failed to mount %s.%b\n" "$C_FG_RED" "$SELECTED_USB" "$C_RESET"
                sleep 1.2
                return 1
            fi
            dest_dir="${USB_VHD_DIR}/VHDs"
            ;;
        3)
            if [ "$data_ok" -ne 1 ] || ! mount_appliance_data_partition; then
                printf "%b[-] DOS_DATA appliance partition is not available.%b\n" "$C_FG_YELLOW" "$C_RESET"
                sleep 1.2
                return 1
            fi
            dest_dir="${DATA_DIR}/VHDs"
            ;;
        *)
            return 1
            ;;
    esac

    echo
    echo "  Step 2: Choose Virtual Hard Disk Capacity"
    echo "    [1] 128 MB   (MBR + FAT16 - Fast, maximum DOS compatibility)"
    echo "    [2] 512 MB   (MBR + FAT16 - Standard DOS utility & workspace volume)"
    echo "    [3] 2048 MB  (MBR + FAT32 - Large data & imaging archive)"
    echo "    [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "  Select capacity [1-3 or ESC] > "
    sz_pick=$(read_key)
    echo

    vhd_mb=0
    case "$sz_pick" in
        1) vhd_mb=128 ;;
        2) vhd_mb=512 ;;
        3) vhd_mb=2048 ;;
        *)
            [ "$esp_remounted" -eq 1 ] && mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
            cleanup_unused_storage_mounts
            return 1
            ;;
    esac

    echo
    if ! read_line_or_esc "Step 3: Enter new .VHD filename" "DISK_${vhd_ltr}.VHD"; then
        [ "$esp_remounted" -eq 1 ] && mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
        cleanup_unused_storage_mounts
        return 1
    fi

    clean_name=$(basename "$INPUT_VAL" | tr -cd 'A-Za-z0-9._-')
    if [ -z "$clean_name" ]; then
        clean_name="DISK_${vhd_ltr}.VHD"
    fi
    case "$clean_name" in
        *.vhd|*.VHD) ;;
        *) clean_name="${clean_name}.VHD" ;;
    esac
    dest_vhd="${dest_dir}/${clean_name}"

    if [ -e "$dest_vhd" ]; then
        echo
        if ! confirm_yes_no "File $dest_vhd already exists. Overwrite it?"; then
            [ "$esp_remounted" -eq 1 ] && mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
            cleanup_unused_storage_mounts
            return 1
        fi
    fi

    echo
    printf "%b[*] Creating %d MB MBR+FAT dynamic .VHD at %s...%b\n" "$C_FG_CYAN" "$vhd_mb" "$dest_vhd" "$C_RESET"
    if create_formatted_vhd "$dest_vhd" "$vhd_mb" "DOS_${vhd_ltr}"; then
        sync
        [ "$esp_remounted" -eq 1 ] && mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
        CREATED_VHD_PATH="$dest_vhd"
        printf "%b[+] Created formatted VHD: %s (%d MB)%b\n" "$C_FG_GREEN" "$dest_vhd" "$vhd_mb" "$C_RESET"
        sleep 1
        return 0
    else
        [ "$esp_remounted" -eq 1 ] && mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
        cleanup_unused_storage_mounts
        printf "%b[-] Failed to create .VHD image at %s.%b\n" "$C_FG_RED" "$dest_vhd" "$C_RESET"
        printf "Press any key to return..."
        read_key >/dev/null
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Sub-Actions
# -----------------------------------------------------------------------------

# Configure or unmap a single DOS drive letter (C, D, or E)
do_configure_drive() {
    sel_ltr=$(echo "$1" | tr 'a-z' 'A-Z')
    case "$sel_ltr" in
        C|D|E) ;;
        *) return ;;
    esac

    while :; do
        eval "cur_slot=\$DRIVE_${sel_ltr}_SLOT"
        eval "cur_mode=\$DRIVE_${sel_ltr}_MODE"

        clear_screen
        echo "================================================================================"
        printf "%b  CONFIGURE DRIVE %s:  ::  Select Physical Partition, RAM Disk, or Image    %b\n" "$C_BLUE_BG" "$sel_ltr" "$C_RESET"
        echo "================================================================================"
        if [ -n "$cur_slot" ]; then
            printf "  Current: %s  %b\n" "$(format_drive_target_label "$cur_slot")" "$(get_mode_badge "$cur_mode")"
        else
            printf "  Current: %b(Unmapped / Offline)%b\n" "$C_FG_GRAY" "$C_RESET"
        fi
        if [ "$sel_ltr" != "C" ] && [ -z "$DRIVE_C_SLOT" ]; then
            printf "\n  %b[!] Note: Drive C: is unmapped. DOS assigns C: to the first active FAT disk.%b\n" "$C_FG_YELLOW" "$C_RESET"
        fi
        echo
        echo "  [0] Unmap / Detach Drive ${sel_ltr}:"
        echo "  [1] Virtual RAM Scratch Disk (64 MB Clean FAT16 Volume in RAM)"
        echo
        echo "  Detected Physical Partitions (outside boot media & host mounts):"

        host_disks=$(get_host_mounted_disks)
        plist=""
        pfslist=""
        pcount=1
        for p in /sys/class/block/*; do
            [ -f "$p/partition" ] || continue
            pn=$(basename "$p")
            parent=$(basename "$(readlink -f "$p/..")")
            [ "$parent" = "$BOOT_DISK" ] && continue
            case " $host_disks " in *" $parent "*) continue ;; esac
            sz_mb=$(( $(cat "$p/size" 2>/dev/null || echo 0) / 2048 ))
            [ "$sz_mb" -gt 0 ] || continue
            hsz=$(format_size_mb "$sz_mb")
            fs_type=$(blkid -s TYPE -o value "/dev/$pn" 2>/dev/null || echo "")
            fs_lbl=$(blkid -s LABEL -o value "/dev/$pn" 2>/dev/null || echo "")
            [ -n "$fs_lbl" ] && lbl_str="\"$fs_lbl\"" || lbl_str=""

            case "$(echo "$fs_type" | tr 'A-Z' 'a-z')" in
                vfat|fat|fat32|fat16|msdos)
                    fs_badge="${C_FG_GREEN}[${fs_type} - DOS Ready]${C_RESET}"
                    ;;
                "")
                    fs_badge="${C_FG_GRAY}[Raw / Unformatted]${C_RESET}"
                    ;;
                *)
                    fs_badge="${C_FG_YELLOW}[${fs_type} - Non-DOS]${C_RESET}"
                    ;;
            esac

            pcount=$((pcount + 1))
            printf "    [%d] /dev/%-10s (%9s)  %b %s\n" "$pcount" "$pn" "$hsz" "$fs_badge" "$lbl_str"
            plist="${plist}/dev/${pn} "
            pfslist="${pfslist}${fs_type:-raw} "
        done

        if [ "$pcount" -eq 1 ]; then
            echo "    (No physical partitions detected outside boot disk & host mounts)"
        fi
        echo
        echo "  [V] Browse Existing Disk Images (.VHD / .IMG)"
        echo "  [N] Create New Blank .VHD Image (128 MB / 512 MB / 2 GB)"
        echo "  [F] Enter Custom Device or Image Path"
        echo "  [ESC] Return to Dashboard"
        echo "--------------------------------------------------------------------------------"
        printf "  Select target (0-%d, V, N, F, or ESC) > " "$pcount"

        choice=$(read_menu_choice "$pcount")
        new_target=""
        chosen_fs=""
        case "$choice" in
            ESC|q|Q|ENTER)
                cleanup_unused_storage_mounts
                return
                ;;
            0)
                eval "DRIVE_${sel_ltr}_SLOT=''"
                eval "DRIVE_${sel_ltr}_MODE=''"
                save_partmap_cfg
                printf "\n%b[+] Drive %s: unmapped.%b\n" "$C_FG_GREEN" "$sel_ltr" "$C_RESET"
                sleep 0.9
                return
                ;;
            1)
                new_target="ram"
                ;;
            [2-9]|[1-9][0-9])
                if [ "$choice" -ge 2 ] && [ "$choice" -le "$pcount" ]; then
                    part_idx=$((choice - 1))
                    new_target=$(echo "$plist" | awk -v n="$part_idx" '{print $n}')
                    chosen_fs=$(echo "$pfslist" | awk -v n="$part_idx" '{print $n}')
                else
                    echo "[-] Invalid selection."
                    sleep 0.9
                    continue
                fi
                ;;
            v|V)
                if browse_disk_images_for_drive; then
                    new_target="$BROWSED_IMAGE_PATH"
                else
                    continue
                fi
                ;;
            n|N)
                if create_blank_vhd_for_drive "$sel_ltr"; then
                    new_target="$CREATED_VHD_PATH"
                else
                    continue
                fi
                ;;
            f|F)
                echo
                if ! read_line_or_esc "Enter partition (/dev/sda1) or image path (.vhd/.img)"; then
                    continue
                fi
                new_target=$(normalize_slot_or_dev "$INPUT_VAL")
                [ -z "$new_target" ] && continue
                ;;
            *)
                continue
                ;;
        esac

        # Warn on non-DOS filesystems before continuing
        case "$(echo "$chosen_fs" | tr 'A-Z' 'a-z')" in
            ntfs|ext2|ext3|ext4|exfat|btrfs|xfs)
                echo
                if ! confirm_yes_no "Partition $new_target uses '$chosen_fs' (not natively readable by DOS). Map anyway?"; then
                    continue
                fi
                ;;
        esac

        # Virtual RAM Scratch Disk is always an ephemeral RAM volume
        if [ "$new_target" = "ram" ]; then
            eval "DRIVE_${sel_ltr}_SLOT=\"ram\""
            eval "DRIVE_${sel_ltr}_MODE=\"temp\""
            save_partmap_cfg
            printf "\n%b[+] Drive %s: mapped to 64 MB FAT16 RAM Scratch Disk ([RAM-OVERLAY])%b\n" "$C_FG_GREEN" "$sel_ltr" "$C_RESET"
            sleep 1.1
            return
        fi

        # Step 2: Select Access Mode for Drive $sel_ltr
        clear_screen
        echo "================================================================================"
        printf "%b  SELECT ACCESS MODE FOR DRIVE %s: [ %s ]%b\n" "$C_BLUE_BG" "$sel_ltr" "$new_target" "$C_RESET"
        echo "================================================================================"
        echo "  Choose how DOS interacts with this target:"
        echo
        echo "    [1] Read/Write (Persistent)"
        echo "        Direct hardware block writes. All changes are saved permanently."
        echo
        echo "    [2] Read-Only (Write-Protected)"
        echo "        Target opened read-only; DOS cannot alter underlying sectors."
        echo
        echo "    [3] RAM Overlay (Disposable Snapshot)"
        echo "        DOS can write freely, but all writes live in RAM and vanish on reboot."
        echo
        echo "    [ESC] Cancel"
        echo "--------------------------------------------------------------------------------"
        printf "  Select mode [1, 2, 3, or ESC] > "
        mode_choice=$(read_key)
        echo
        new_mode=""
        case "$mode_choice" in
            1)
                if echo "$new_target" | grep -q '^/dev/'; then
                    if ! confirm_yes_no "Enable persistent Read/Write access directly on $new_target?"; then
                        continue
                    fi
                fi
                new_mode="rw"
                ;;
            2) new_mode="ro" ;;
            3) new_mode="temp" ;;
            ESC|q|Q)
                cleanup_unused_storage_mounts
                continue
                ;;
            *)
                cleanup_unused_storage_mounts
                continue
                ;;
        esac

        before_raw="$RAW_ENABLED_DISKS"
        eval "DRIVE_${sel_ltr}_SLOT=\"$new_target\""
        eval "DRIVE_${sel_ltr}_MODE=\"$new_mode\""
        save_partmap_cfg

        echo
        printf "%b[+] Drive %s: mapped to %s (%s)%b\n" "$C_FG_GREEN" "$sel_ltr" "$new_target" "$(get_mode_badge "$new_mode")" "$C_RESET"
        if [ "$before_raw" != "$RAW_ENABLED_DISKS" ]; then
            printf "%b[!] Parent disk excluded from RAW Passthrough (single-ownership rule).%b\n" "$C_FG_YELLOW" "$C_RESET"
        fi
        sleep 1.3
        return
    done
}

do_route_drives() {
    while :; do
        clear_screen
        echo "================================================================================"
        printf "%b  CONFIGURE DRIVE LETTERS  ::  Choose Drive C:, D:, or E:                       %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        printf "    [C] Drive C: %-40s %b\n" "${DRIVE_C_SLOT:--- UNMAPPED --}" "$(get_mode_badge "${DRIVE_C_SLOT:+$DRIVE_C_MODE}")"
        printf "    [D] Drive D: %-40s %b\n" "${DRIVE_D_SLOT:--- UNMAPPED --}" "$(get_mode_badge "${DRIVE_D_SLOT:+$DRIVE_D_MODE}")"
        printf "    [E] Drive E: %-40s %b\n" "${DRIVE_E_SLOT:--- UNMAPPED --}" "$(get_mode_badge "${DRIVE_E_SLOT:+$DRIVE_E_MODE}")"
        echo
        echo "  Enter [C, D, E] to configure or unmap, or [ESC] to return."
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        ltr=$(read_key)
        case "$ltr" in
            c|C) do_configure_drive C ;;
            d|D) do_configure_drive D ;;
            e|E) do_configure_drive E ;;
            ESC|0|q|Q|ENTER) break ;;
        esac
    done
}

do_p2v_migration() {
    clear_screen
    echo "================================================================================"
    printf "%b  DISK / PARTITION TO VHD BACKUP  ::  Save Raw Storage as Dynamic Windows VHD  %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo "  Rip a physical disk or individual partition to a standalone .VHD file on USB."
    echo

    host_disks=$(get_host_mounted_disks)
    pdisks=""
    pparents=""
    pcount=0

    echo "  Whole Physical Disks:"
    for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/vd*; do
        [ -d "$d" ] || continue
        dname=$(basename "$d")
        [ "$dname" = "$BOOT_DISK" ] && continue
        case " $host_disks " in *" $dname "*) continue ;; esac
        sz_mb=$(( $(cat "$d/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue
        hsz=$(format_size_mb "$sz_mb")
        mdl=$(cat "$d/device/model" 2>/dev/null | tr -s ' ' | cut -c1-24)
        [ -z "$mdl" ] && mdl="Physical Disk"
        pcount=$((pcount + 1))
        printf "    [%d] /dev/%-10s (%9s)  %s\n" "$pcount" "$dname" "$hsz" "$mdl"
        pdisks="${pdisks}/dev/${dname} "
        pparents="${pparents}${dname} "
    done

    echo
    echo "  Individual Physical Partitions:"
    for p in /sys/class/block/*; do
        [ -f "$p/partition" ] || continue
        pn=$(basename "$p")
        parent=$(basename "$(readlink -f "$p/..")")
        [ "$parent" = "$BOOT_DISK" ] && continue
        case " $host_disks " in *" $parent "*) continue ;; esac
        sz_mb=$(( $(cat "$p/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue
        hsz=$(format_size_mb "$sz_mb")
        fs=$(blkid -s TYPE -o value "/dev/$pn" 2>/dev/null || echo "raw")
        pcount=$((pcount + 1))
        printf "    [%d] /dev/%-10s (%9s)  [%s Partition]\n" "$pcount" "$pn" "$hsz" "$fs"
        pdisks="${pdisks}/dev/${pn} "
        pparents="${pparents}${parent} "
    done

    if [ "$pcount" -eq 0 ]; then
        echo "  [-] No eligible physical drives or partitions found outside boot/host disks."
        printf "  Press any key to return..."
        read_key >/dev/null
        return
    fi
    echo
    echo "  [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "  Select source (1-%d or ESC) > " "$pcount"
    sel=$(read_menu_choice "$pcount")
    echo
    case "$sel" in
        ESC|0|q|Q|ENTER) return ;;
    esac
    src_dev=$(echo "$pdisks" | awk -v n="$sel" '{print $n}')
    src_parent=$(echo "$pparents" | awk -v n="$sel" '{print $n}')
    if [ -z "$src_dev" ] || [ ! -b "$src_dev" ]; then
        echo "[-] Invalid selection."
        sleep 1
        return
    fi

    if ! select_fat_partition "$src_parent"; then return; fi
    umount /mnt/usb 2>/dev/null || true
    if ! mount -t vfat "$SELECTED_USB" /mnt/usb 2>/dev/null; then
        echo "[-] Failed to mount $SELECTED_USB."
        sleep 1
        return
    fi

    def_vhd="BACKUP_$(basename "$src_dev").vhd"
    if ! read_line_or_esc "Enter target VHD filename" "$def_vhd"; then
        umount /mnt/usb 2>/dev/null || true
        return
    fi
    target_vhd="/mnt/usb/${INPUT_VAL}"
    case "$target_vhd" in *.vhd|*.VHD) ;; *) target_vhd="${target_vhd}.vhd" ;; esac

    echo
    echo "================================================================================"
    echo "  CONFIRM VHD BACKUP:"
    echo "    Source Device      : $src_dev (READ-ONLY)"
    echo "    Destination File   : $target_vhd (on $SELECTED_USB)"
    echo "================================================================================"
    if confirm_yes_no "Begin VHD backup now?"; then
        echo "[*] Converting $src_dev -> $target_vhd (this may take several minutes)..."
        qemu-img convert -p -f raw -O vpc -o subformat=dynamic "$src_dev" "$target_vhd"
        rc=$?
        sync
        umount /mnt/usb 2>/dev/null || true
        if [ $rc -eq 0 ]; then
            printf "\n%b[+] VHD BACKUP COMPLETED SUCCESSFULLY!%b\n" "$C_FG_GREEN" "$C_RESET"
        else
            printf "\n%b[-] VHD Backup failed (code %d)%b\n" "$C_FG_RED" "$rc" "$C_RESET"
        fi
    else
        echo "[-] Aborted."
        umount /mnt/usb 2>/dev/null || true
    fi
    printf "Press any key to return..."
    read_key >/dev/null
}

do_physical_disk_manager() {
    while :; do
        clear_screen
        max_slots=$(get_bus_max_slots)
        used_slots=$(get_active_slot_usage)
        echo "================================================================================"
        printf "%b  PHYSICAL DISK PASSTHROUGH  ::  Whole-Disk Direct Hardware Access             %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        echo "  Control which physical drives are passed directly to DOS / diagnostics."
        echo "  Single-Ownership Rule: Drives with partitions mapped to C:, D:, or E: cannot"
        echo "  be passed through RAW, and host/boot disks are strictly blocked."
        printf "  Controller: %b%s%b | Active Drives: %b%d / %d%b\n" \
            "$C_FG_CYAN" "$(get_bus_label)" "$C_RESET" "$C_FG_YELLOW" "$used_slots" "$max_slots" "$C_RESET"
        if [ "$used_slots" -gt "$max_slots" ]; then
            printf "  %b[!] Capacity exceeded! Extra drives will be skipped unless you switch [I] to AHCI.%b\n" "$C_FG_RED" "$C_RESET"
        fi
        echo
        echo "  Physical Disks Detected:"

        host_disks=$(get_host_mounted_disks)
        pdisks=""
        pcount=0
        for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/vd*; do
            [ -d "$d" ] || continue
            dname=$(basename "$d")
            sz_mb=$(( $(cat "$d/size" 2>/dev/null || echo 0) / 2048 ))
            [ "$sz_mb" -gt 0 ] || continue
            hsz=$(format_size_mb "$sz_mb")
            mdl=$(cat "$d/device/model" 2>/dev/null | tr -s ' ' | cut -c1-22)
            [ -z "$mdl" ] && mdl="Disk"
            pcount=$((pcount + 1))

            badge=""
            is_host=0
            case " $host_disks " in
                *" $dname "*)
                    badge="${C_FG_RED}[HOST-MOUNTED - BLOCKED]${C_RESET}"
                    is_host=1
                    ;;
            esac

            mapped_letter=""
            if [ $is_host -eq 0 ]; then
                for ltr in C D E; do
                    eval "slot=\$DRIVE_${ltr}_SLOT"
                    [ -n "$slot" ] || continue
                    slot_parent=$(get_parent_disk "$slot")
                    if [ "$slot_parent" = "$dname" ]; then
                        mapped_letter="$ltr"
                        break
                    fi
                done
            fi

            if [ -n "$mapped_letter" ]; then
                badge="${C_FG_YELLOW}[DRIVE ${mapped_letter}: MAPPED - EXCLUDED]${C_RESET}"
            elif [ $is_host -eq 0 ]; then
                is_enabled=0
                if [ "${RAW_CONFIGURED:-0}" = 1 ]; then
                    case " $RAW_ENABLED_DISKS " in
                        *" $dname "*) is_enabled=1 ;;
                    esac
                else
                    is_enabled=1
                fi
                if [ $is_enabled -eq 1 ]; then
                    badge="${C_FG_GREEN}[ACTIVE RAW]${C_RESET}"
                else
                    badge="${C_FG_GRAY}[OFFLINE / DISABLED]${C_RESET}"
                fi
            fi

            printf "    [%d] /dev/%-8s (%9s)  %-22s %b\n" "$pcount" "$dname" "$hsz" "$mdl" "$badge"
            printf "        %bPartitions:%b %s\n" "$C_FG_GRAY" "$C_RESET" "$(get_disk_partitions_line "$dname")"
            pdisks="${pdisks}${dname} "
        done

        if [ "$pcount" -eq 0 ]; then
            echo "    (No physical drives detected)"
        fi
        echo
        echo "  [1-$pcount] Toggle disk   [A] Enable ALL eligible   [N] Disable ALL"
        echo "  [ESC] or [0] Return to Main Dashboard"
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        sk=$(read_menu_choice "$pcount")
        case "$sk" in
            ESC|0|q|Q|ENTER)
                break
                ;;
            a|A)
                new_all=""
                for cand in $pdisks; do
                    case " $host_disks " in *" $cand "*) continue ;; esac
                    unmap_drive_letters_for_disk "$cand"
                    new_all="$new_all $cand"
                done
                RAW_ENABLED_DISKS=$(echo "$new_all" | xargs)
                RAW_CONFIGURED=1
                save_partmap_cfg
                printf "\n%b[+] Enabled all eligible physical disks for RAW passthrough.%b\n" "$C_FG_GREEN" "$C_RESET"
                sleep 1
                ;;
            n|N)
                RAW_ENABLED_DISKS=""
                RAW_CONFIGURED=1
                save_partmap_cfg
                printf "\n%b[-] Disabled all RAW passthrough disks.%b\n" "$C_FG_GRAY" "$C_RESET"
                sleep 1
                ;;
            [1-9]|[1-9][0-9])
                if [ "$sk" -ge 1 ] && [ "$sk" -le "$pcount" ]; then
                    sel_dname=$(echo "$pdisks" | awk -v n="$sk" '{print $n}')
                    case " $host_disks " in
                        *" $sel_dname "*)
                            echo
                            printf "%b[-] /dev/%s hosts active system/boot mounts and cannot be passed through.%b\n" "$C_FG_RED" "$sel_dname" "$C_RESET"
                            sleep 1.4
                            continue
                            ;;
                    esac

                    was_enabled=0
                    if [ "${RAW_CONFIGURED:-0}" = 1 ]; then
                        case " $RAW_ENABLED_DISKS " in *" $sel_dname "*) was_enabled=1 ;; esac
                    else
                        was_enabled=1
                    fi

                    if [ $was_enabled -eq 1 ]; then
                        new_raw=""
                        if [ "${RAW_CONFIGURED:-0}" != 1 ]; then
                            for cand in $pdisks; do
                                [ "$cand" = "$sel_dname" ] && continue
                                case " $host_disks " in *" $cand "*) continue ;; esac
                                new_raw="$new_raw $cand"
                            done
                        else
                            for r in $RAW_ENABLED_DISKS; do
                                [ "$r" = "$sel_dname" ] && continue
                                new_raw="$new_raw $r"
                            done
                        fi
                        RAW_ENABLED_DISKS=$(echo "$new_raw" | xargs)
                        RAW_CONFIGURED=1
                        save_partmap_cfg
                        printf "\n%b[-] /dev/%s disabled from RAW passthrough.%b\n" "$C_FG_GRAY" "$sel_dname" "$C_RESET"
                        sleep 0.9
                    else
                        has_conflict=0
                        for ltr in C D E; do
                            eval "sl=\$DRIVE_${ltr}_SLOT"
                            [ -n "$sl" ] || continue
                            if [ "$(get_parent_disk "$sl")" = "$sel_dname" ]; then
                                has_conflict=1
                            fi
                        done
                        if [ $has_conflict -eq 1 ]; then
                            echo
                            if ! confirm_yes_no "Drive letter(s) map partitions on /dev/$sel_dname. Enabling RAW will unmap them. Proceed?"; then
                                continue
                            fi
                            unmap_drive_letters_for_disk "$sel_dname"
                        fi
                        RAW_ENABLED_DISKS=$(echo "$RAW_ENABLED_DISKS $sel_dname" | xargs)
                        RAW_CONFIGURED=1
                        save_partmap_cfg
                        printf "\n%b[+] /dev/%s enabled for RAW passthrough.%b\n" "$C_FG_GREEN" "$sel_dname" "$C_RESET"
                        sleep 0.9
                    fi
                fi
                ;;
        esac
    done
}

do_live_media_selector() {
    clear_screen
    echo "================================================================================"
    printf "%b  BOOT MEDIA SELECTOR  ::  Mount .IMG / .ISO onto Drive A: or CD-ROM (Session) %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo "  Transient Injection: Selected images are staged into RAM (/run) for this"
    echo "  session only. Your physical USB media and defaults remain untouched."
    echo
    echo "  [0] Reset Boot Media to Default Built-in Payload"
    echo "  [1] Scan Boot Media ($ESP_DIR)"
    echo "  [2] Scan Attached Secondary USB Flash Drive"
    echo "  [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "  Selection > "
    src_pick=$(read_key)
    echo

    scan_dir=""
    umount_usb=0
    case "$src_pick" in
        0)
            rm -f "$LIVE_MEDIA_FLAG" "$BOOT_FROM_ISO_FLAG"
            [ -f /run/default_boot_floppy.img ] && cp -f /run/default_boot_floppy.img /run/boot_floppy.img
            [ -f /run/default_floppy_name ] && cp -f /run/default_floppy_name /run/floppy_name
            [ -f /run/default_iso_name ] && cp -f /run/default_iso_name /run/iso_name
            printf "%b[+] Boot media restored to default.%b\n" "$C_FG_GREEN" "$C_RESET"
            sleep 1.1
            return
            ;;
        1)
            if ! mountpoint -q "$ESP_DIR" 2>/dev/null; then
                echo "[-] Boot media is not mounted."
                sleep 1.2
                return
            fi
            scan_dir="$ESP_DIR"
            ;;
        2)
            if ! select_usb_partition "$BOOT_DISK"; then return; fi
            umount /mnt/usb 2>/dev/null || true
            if ! mount -t vfat -o ro "$SELECTED_USB" /mnt/usb 2>/dev/null; then
                echo "[-] Failed to mount $SELECTED_USB."
                sleep 1.2
                return
            fi
            scan_dir="/mnt/usb"
            umount_usb=1
            ;;
        *)
            return
            ;;
    esac

    raw_images=$(find "$scan_dir" -maxdepth 3 \( -iname "*.img" -o -iname "*.ima" -o -iname "*.vfd" -o -iname "*.iso" \) 2>/dev/null | sort || true)
    images=""
    old_ifs="$IFS"
    IFS='
'
    for im in $raw_images; do
        [ -n "$im" ] || continue
        bn=$(basename "$im" | tr 'A-Z' 'a-z')
        case "$bn" in
            efiboot.img|b_control.img|initramfs*|uefidosbridge.iso|uefifreedos.iso) continue ;;
        esac
        images="${images}${im}
"
    done
    IFS="$old_ifs"
    images=$(printf "%s" "$images" | sed '/^$/d')

    if [ -z "$images" ]; then
        echo "[-] No bootable disk images (*.img, *.ima, *.vfd, *.iso) found in $scan_dir."
        [ $umount_usb -eq 1 ] && umount /mnt/usb 2>/dev/null || true
        printf "Press any key to return..."
        read_key >/dev/null
        return
    fi

    total_imgs=$(echo "$images" | wc -l)
    echo "Available Boot Images:"
    icount=0
    echo "$images" | while IFS= read -r img; do
        icount=$((icount + 1))
        isz=$(ls -lh "$img" 2>/dev/null | awk '{print $5}')
        echo "  [$icount] $(basename "$img") ($isz)"
    done
    echo "  [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "Select image number (1-%d) > " "$total_imgs"
    sel_num=$(read_menu_choice "$total_imgs")
    echo
    case "$sel_num" in
        ESC|0|q|Q|ENTER)
            [ $umount_usb -eq 1 ] && umount /mnt/usb 2>/dev/null || true
            return
            ;;
    esac

    sel_img=$(echo "$images" | sed -n "${sel_num}p")
    if [ -z "$sel_img" ] || [ ! -f "$sel_img" ]; then
        echo "[-] Invalid selection."
        [ $umount_usb -eq 1 ] && umount /mnt/usb 2>/dev/null || true
        sleep 1
        return
    fi

    bname=$(basename "$sel_img")
    echo "[*] Staging $bname into RAM..."
    case "$bname" in
        *.iso|*.ISO)
            cp -f "$sel_img" /run/boot_iso.iso
            touch "$BOOT_FROM_ISO_FLAG"
            echo "$bname" > /run/iso_name
            echo "$bname (ISO CD-ROM)" > "$LIVE_MEDIA_FLAG"
            ;;
        *)
            rm -f "$BOOT_FROM_ISO_FLAG"
            cp -f "$sel_img" /run/boot_floppy.img
            echo "$bname" > /run/floppy_name
            echo "$bname" > "$LIVE_MEDIA_FLAG"
            ;;
    esac
    sync
    [ $umount_usb -eq 1 ] && umount /mnt/usb 2>/dev/null || true

    echo
    printf "%b[+] Live media staged: [ %s ] (Session-only)%b\n" "$C_FG_GREEN" "$bname" "$C_RESET"
    sleep 1.2
}

do_format_disk_fat32() {
    clear_screen
    echo "================================================================================"
    printf "%b  INITIALIZE / FORMAT DISK AS FAT32  ::  Prep Blank or Spare Disk for DOS/VHDs %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo "  Creates a single active MBR + FAT32 partition on a non-boot physical disk."
    echo "  The formatted partition can be mapped directly to DOS (C:/D:/E:) or used to"
    echo "  store multiple .VHD virtual hard disks."
    echo

    host_disks=$(get_host_mounted_disks)
    fdisks=""
    fcount=0

    echo "  Eligible Physical Disks (boot & host-mounted disks excluded):"
    for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/vd*; do
        [ -d "$d" ] || continue
        dname=$(basename "$d")
        [ "$dname" = "$BOOT_DISK" ] && continue
        case " $host_disks " in *" $dname "*) continue ;; esac
        sz_mb=$(( $(cat "$d/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -ge 64 ] || continue
        hsz=$(format_size_mb "$sz_mb")
        mdl=$(cat "$d/device/model" 2>/dev/null | tr -s ' ' | cut -c1-24)
        [ -z "$mdl" ] && mdl="Physical Disk"
        fcount=$((fcount + 1))
        printf "    [%d] /dev/%-10s (%9s)  %s\n" "$fcount" "$dname" "$hsz" "$mdl"
        printf "        %bCurrent Partitions:%b %s\n" "$C_FG_GRAY" "$C_RESET" "$(get_disk_partitions_line "$dname")"
        fdisks="${fdisks}${dname} "
    done

    if [ "$fcount" -eq 0 ]; then
        echo "    (No eligible disks >= 64 MB detected outside boot & host-mounted disks)"
        echo
        printf "  Press any key to return..."
        read_key >/dev/null
        return
    fi

    echo
    echo "  [ESC] Cancel"
    echo "--------------------------------------------------------------------------------"
    printf "  Select disk to ERASE & format as FAT32 (1-%d or ESC) > " "$fcount"
    sel=$(read_menu_choice "$fcount")
    echo
    case "$sel" in
        ESC|0|q|Q|ENTER) return ;;
    esac

    sel_dname=$(echo "$fdisks" | awk -v n="$sel" '{print $n}')
    if [ -z "$sel_dname" ] || [ ! -b "/dev/$sel_dname" ]; then
        echo "[-] Invalid selection."
        sleep 1
        return
    fi

    sz_mb=$(( $(cat "/sys/block/$sel_dname/size" 2>/dev/null || echo 0) / 2048 ))
    hsz=$(format_size_mb "$sz_mb")
    mdl=$(cat "/sys/block/$sel_dname/device/model" 2>/dev/null | tr -s ' ')
    [ -z "$mdl" ] && mdl="Physical Disk"
    cur_parts=$(get_disk_partitions_line "$sel_dname")

    echo
    if ! read_line_or_esc "Enter FAT32 volume label (max 11 chars)" "DOS_STORAGE"; then
        return
    fi
    vol_label="$INPUT_VAL"

    echo
    echo "================================================================================"
    printf "%b  CRITICAL WARNING: ALL DATA ON /dev/%s WILL BE PERMANENTLY ERASED!%b\n" "$C_FG_RED" "$sel_dname" "$C_RESET"
    echo "    Target Disk       : /dev/$sel_dname ($hsz) $mdl"
    echo "    Current Layout    : $cur_parts"
    echo "    New Layout        : Single Active MBR + FAT32 Partition (Label: $vol_label)"
    echo "================================================================================"

    if ! verify_captcha_prompt "ERASE /dev/$sel_dname AND FORMAT AS MBR FAT32"; then
        return
    fi

    unmap_drive_letters_for_disk "$sel_dname"
    save_partmap_cfg

    echo
    printf "%b[*] Initializing /dev/%s as MBR + FAT32 (%s)...%b\n" "$C_FG_CYAN" "$sel_dname" "$vol_label" "$C_RESET"
    if format_disk_mbr_fat32 "/dev/$sel_dname" "$vol_label"; then
        echo
        printf "%b[+] SUCCESS! Created FAT32 partition: %s%b\n" "$C_FG_GREEN" "${FORMATTED_PART_DEV:-/dev/${sel_dname}1}" "$C_RESET"
        echo "    You can now map it directly in [C/D/E], or store .VHD images on it via [N]/[V]."
    else
        echo
        printf "%b[-] Failed to format /dev/%s as MBR + FAT32.%b\n" "$C_FG_RED" "$sel_dname" "$C_RESET"
    fi
    echo
    printf "Press any key to return..."
    read_key >/dev/null
}

do_advanced_tools() {
    while :; do
        clear_screen
        echo "================================================================================"
        printf "%b  DISK TOOLS & APPLIANCE INSTALLER                                              %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        echo "  [1] Disk / Partition to VHD Backup (Save raw drive or partition to .VHD)"
        echo "  [2] Factory Appliance Installer (Install uefiDOS permanently to internal drive)"
        echo "  [3] Initialize / Format Disk as FAT32 (Prep blank or spare disk for DOS & VHDs)"
        echo
        echo "  [ESC] or [0] Return to Main Dashboard"
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        ak=$(read_key)
        case "$ak" in
            1) do_p2v_migration ;;
            2)
                for sdir in /bin /sbin /src /mnt/esp; do
                    if [ -x "$sdir/appliance_installer.sh" ]; then
                        "$sdir/appliance_installer.sh"
                        break
                    elif [ -f "$sdir/appliance_installer.sh" ]; then
                        sh "$sdir/appliance_installer.sh"
                        break
                    fi
                done
                ;;
            3) do_format_disk_fat32 ;;
            ESC|0|q|Q|ENTER) break ;;
        esac
    done
}

do_toggle_maintenance_shell() {
    if [ -f "$MAINT_FLAG" ]; then
        rm -f "$MAINT_FLAG"
    else
        touch "$MAINT_FLAG"
    fi
}

do_toggle_controller_mode() {
    if [ "${BUS_MODE:-a}" = "c" ]; then
        BUS_MODE="a"
    else
        BUS_MODE="c"
    fi
    save_partmap_cfg
}

do_reset_defaults() {
    echo
    if confirm_yes_no "Reset all drive mappings, RAW selections, controller mode, and boot media?"; then
        DRIVE_C_SLOT=""; DRIVE_C_MODE="rw"
        DRIVE_D_SLOT=""; DRIVE_D_MODE="rw"
        DRIVE_E_SLOT=""; DRIVE_E_MODE="ro"
        RAW_ENABLED_DISKS=""
        RAW_CONFIGURED=0
        BUS_MODE="a"
        rm -f "$MAINT_FLAG" "$LIVE_MEDIA_FLAG" "$BOOT_FROM_ISO_FLAG"
        [ -f /run/default_boot_floppy.img ] && cp -f /run/default_boot_floppy.img /run/boot_floppy.img
        [ -f /run/default_floppy_name ] && cp -f /run/default_floppy_name /run/floppy_name
        [ -f /run/default_iso_name ] && cp -f /run/default_iso_name /run/iso_name
        save_partmap_cfg
        printf "%b[+] Restored factory default routing.%b\n" "$C_FG_GREEN" "$C_RESET"
        sleep 1.1
    fi
}

get_drive_a_label() {
    if [ -f "$BOOT_FROM_ISO_FLAG" ] && [ -f "$LIVE_MEDIA_FLAG" ]; then
        cat "$LIVE_MEDIA_FLAG"
        return
    fi
    if [ -f "$LIVE_MEDIA_FLAG" ]; then
        cat "$LIVE_MEDIA_FLAG"
        return
    fi
    if [ -f /run/floppy_name ]; then
        cat /run/floppy_name
        return
    fi
    if [ -f /run/payload_name ]; then
        cat /run/payload_name
        return
    fi
    echo "FreeDOS 1.3 Base Runtime"
}

# -----------------------------------------------------------------------------
# Main In-Place Painted Dashboard Loop
# -----------------------------------------------------------------------------
if [ -f "$RUN_PARTMAP_FILE" ]; then
    parse_partmap_cfg "$RUN_PARTMAP_FILE"
else
    parse_partmap_cfg "$PARTMAP_FILE"
fi
BUS_MODE="${BUS_MODE:-${MODE:-a}}"
check_esp_writable >/dev/null 2>&1 || true

while :; do
    clear_screen
    if [ "${ESP_WRITABLE:-0}" = "1" ]; then
        cfg_scope="Persistent USB"
    else
        cfg_scope="Session-Only RAM"
    fi
    bus_lbl=$(get_bus_label)

    # Header Banner
    echo "================================================================================"
    printf "%b  uefiDOS HARDWARE BRIDGE & ROUTER   [Config: %-16s | Bus: %-12s]%b\n" "$C_BLUE_BG" "$cfg_scope" "$bus_lbl" "$C_RESET"
    printf "%b  System: %-21s ::  Kernel: %-25s     %b\n" "$C_BLUE_BG" "$(cat /sys/class/dmi/id/product_name 2>/dev/null | cut -c1-21 || echo "x86_64")" "$(uname -r)" "$C_RESET"
    echo "================================================================================"

    # Active Drive Status
    live_media_label=$(get_drive_a_label)
    if [ -f "$BOOT_FROM_ISO_FLAG" ]; then
        boot_role="${C_FG_CYAN}[CD-ROM BOOT]${C_RESET}"
    else
        boot_role="${C_FG_CYAN}[BOOTABLE]${C_RESET}"
    fi

    echo "  ACTIVE DRIVE & HARDWARE ROUTING"
    echo "  ----------------------------------------------------------------------------"
    printf "  [A] Boot Media : %-36s %b %b\n" "[ $(echo "$live_media_label" | cut -c1-34) ]" "$(get_mode_badge temp)" "$boot_role"
    printf "      Control B: : %-36s %b %b\n" "[ b_control.img (EDIT/ROUTER/REBOOT) ]" "$(get_mode_badge ro)" "${C_FG_CYAN}[SYSTEM]${C_RESET}"

    for ltr in C D E; do
        eval "sl=\$DRIVE_${ltr}_SLOT"
        eval "md=\$DRIVE_${ltr}_MODE"
        if [ -n "$sl" ]; then
            desc=$(format_drive_target_label "$sl" | cut -c1-34)
            printf "  [%s] Drive %s:   : %-36s %b %b\n" "$ltr" "$ltr" "[ $desc ]" "$(get_mode_badge "${md:-rw}")" "${C_FG_GREEN}[ACTIVE]${C_RESET}"
        else
            printf "  [%s] Drive %s:   : %-36s %b %b\n" "$ltr" "$ltr" "[ -- UNMAPPED -- ]" "$(get_mode_badge unmapped)" "${C_FG_GRAY}[OFFLINE]${C_RESET}"
        fi
    done

    # Disks passthrough + slot counter
    target_disks=$(get_target_disks_summary)
    used_slots=$(get_active_slot_usage)
    max_slots=$(get_bus_max_slots)
    case "$target_disks" in
        "("*|"--"*)
            raw_badge="${C_FG_GRAY}[OFFLINE]${C_RESET}"
            ;;
        *)
            raw_badge="${C_FG_CYAN}[RAW PASSTHRU]${C_RESET}"
            ;;
    esac
    printf "  [W] Raw Disks  : %-36s %b (Slots: %d/%d)\n" "[ $(echo "$target_disks" | cut -c1-34) ]" "$raw_badge" "$used_slots" "$max_slots"

    if [ -f "$MAINT_FLAG" ]; then
        echo "  ----------------------------------------------------------------------------"
        printf "  %b*** CLEAN DOS PROMPT ACTIVE: AUTOEXEC.BAT BYPASSED -> DROPS TO A:\> ***%b\n" "$C_FG_YELLOW" "$C_RESET"
    fi
    if [ "$used_slots" -gt "$max_slots" ]; then
        echo "  ----------------------------------------------------------------------------"
        printf "  %b[!] Slot limit (%d/%d) exceeded! Press [I] to switch Controller to AHCI (Max 6).%b\n" "$C_FG_YELLOW" "$used_slots" "$max_slots" "$C_RESET"
    fi
    echo "  ----------------------------------------------------------------------------"

    echo "  STORAGE & BOOT CONFIGURATION"
    printf "    %b[C/D/E]%b Configure or Unmap DOS Drive (Partition, RAM Disk, or VHD)\n" "$C_FG_YELLOW" "$C_RESET"
    printf "    %b[W]%b     Physical Disk Passthrough (Toggle Whole-Disk RAW Access)\n" "$C_FG_YELLOW" "$C_RESET"
    printf "    %b[A]%b     Boot Media Selector (Mount .IMG / .ISO to Drive A: or CD-ROM)\n" "$C_FG_CYAN" "$C_RESET"
    if [ -f "$MAINT_FLAG" ]; then
        printf "    %b[M]%b     Clean DOS Prompt (Bypass AUTOEXEC.BAT): %b[ENABLED - A:\>]%b\n" "$C_FG_CYAN" "$C_RESET" "$C_FG_GREEN" "$C_RESET"
    else
        printf "    %b[M]%b     Clean DOS Prompt (Bypass AUTOEXEC.BAT): %b[DISABLED - Normal]%b\n" "$C_FG_CYAN" "$C_RESET" "$C_FG_GRAY" "$C_RESET"
    fi
    printf "    %b[I]%b     Disk Controller Mode: %b[%s]%b        %b[X]%b Reset Defaults\n" "$C_FG_CYAN" "$C_RESET" "$C_FG_YELLOW" "$bus_lbl" "$C_RESET" "$C_FG_GRAY" "$C_RESET"
    echo
    echo "  SYSTEM & UTILITIES"
    printf "    %b[B]%b     Boot DOS Runtime               %b[T]%b Disk-to-VHD Backup & Installer\n" "$C_FG_GREEN" "$C_RESET" "$C_FG_YELLOW" "$C_RESET"
    printf "    %b[R]%b     Reboot System                  %b[P]%b Power Off        %b[S]%b Shell\n" "$C_FG_YELLOW" "$C_RESET" "$C_FG_RED" "$C_RESET" "$C_FG_GRAY" "$C_RESET"
    echo "================================================================================"
    printf "  %bPress key to configure, or [B] to Boot DOS Runtime%b\n" "$C_FG_GRAY" "$C_RESET"
    echo "================================================================================"
    printf "  Selection > "

    opt=$(read_key)

    case "$opt" in
        1) do_route_drives ;;
        c|C) do_configure_drive C ;;
        d|D) do_configure_drive D ;;
        e|E) do_configure_drive E ;;
        w|W|3) do_physical_disk_manager ;;
        a|A) do_live_media_selector ;;
        m|M) do_toggle_maintenance_shell ;;
        i|I) do_toggle_controller_mode ;;
        x|X) do_reset_defaults ;;
        t|T) do_advanced_tools ;;
        b|B)
            echo
            printf "%b[*] Preparing to boot DOS Runtime...%b\n" "$C_FG_GREEN" "$C_RESET"
            rm -f "${ESP_DIR}/EDITMODE.FLG" 2>/dev/null || true
            esp_needs_rw=0
            for bltr in C D E; do
                eval "bsl=\$DRIVE_${bltr}_SLOT"
                eval "bmd=\$DRIVE_${bltr}_MODE"
                case "$bsl" in
                    ${ESP_DIR}/*)
                        [ "$(echo "$bmd" | tr 'A-Z' 'a-z')" = "rw" ] && esp_needs_rw=1
                        ;;
                esac
            done
            if [ "$esp_needs_rw" = "1" ]; then
                mount -o remount,rw "$ESP_DIR" 2>/dev/null || true
            else
                mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
            fi
            sync
            break
            ;;
        s|S)
            echo
            echo "[*] Launching hypervisor shell (type 'exit' to return to dashboard)..."
            setsid cttyhack sh 2>/dev/null || sh
            ;;
        r|R)
            echo
            if confirm_yes_no "Reboot the physical system now?"; then
                sync; reboot -f
            fi
            ;;
        p|P)
            echo
            if confirm_yes_no "Power off the physical system now?"; then
                sync; poweroff -f
            fi
            ;;
        *)
            ;;
    esac
done

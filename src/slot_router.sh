#!/bin/busybox sh
# =============================================================================
# uefiDOS Dynamic Slot & Drive Router Shell Engine
# =============================================================================

# Generates a random alphanumeric CAPTCHA excluding ambiguous characters (0, O, 1, I, L)
generate_captcha() {
    len="${1:-5}"
    if [ -c /dev/urandom ]; then
        tr -dc '23456789ABCDEFGHJKMNPQRSTUVWXYZ' < /dev/urandom 2>/dev/null | head -c "$len"
    else
        awk -v n="$len" 'BEGIN {
            chars = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
            srand();
            res = "";
            for (i=0; i<n; i++) {
                idx = int(rand() * length(chars)) + 1;
                res = res substr(chars, idx, 1);
            }
            print res;
        }'
    fi
}

# Prompts user with an ANSI graphics styled CAPTCHA challenge; returns 0 on match, 1 on failure
verify_captcha_prompt() {
    prompt_title="${1:-CONFIRMATION REQUIRED}"
    code=$(generate_captcha 5)
    ESC=$(printf '\033')
    C_RESET="${ESC}[0m"
    C_BLUE_BG="${ESC}[44;1;37m"
    C_FG_CYAN="${ESC}[1;36m"
    C_FG_YELLOW="${ESC}[1;33m"
    C_FG_GREEN="${ESC}[1;32m"
    C_FG_RED="${ESC}[1;31m"
    C_FG_GRAY="${ESC}[1;30m"

    printf "${ESC}[2J${ESC}[H"
    echo "================================================================================"
    printf "%b  uefiDOS SECURITY VERIFICATION  ::  AUTHENTICATION REQUIRED                   %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo
    printf "  %bACTION:%b %s\n" "$C_FG_CYAN" "$C_RESET" "$prompt_title"
    echo
    echo "  To prevent unintended configuration changes or hardware modifications,"
    echo "  please enter the 5-character verification code shown below:"
    echo
    echo "         +-------------------------------------------------------+"
    printf "         |              Verification Code:  %b[  %s  ]%b              |\n" "$C_FG_YELLOW" "$code" "$C_RESET"
    echo "         +-------------------------------------------------------+"
    echo
    echo "  Type the code above and press [ENTER] to confirm."
    printf "  Press %b[ESC]%b or press %b[ENTER]%b with empty input to cancel.\n" "$C_FG_YELLOW" "$C_RESET" "$C_FG_YELLOW" "$C_RESET"
    echo "================================================================================"
    printf "  Verification Code > "
    user_input=""
    while IFS= read -r -s -n 1 ch 2>/dev/null; do
        if [ "$ch" = "$ESC" ]; then
            user_input=""
            break
        elif [ -z "$ch" ]; then
            break
        elif [ "$ch" = "$(printf '\177')" ] || [ "$ch" = "$(printf '\b')" ]; then
            if [ -n "$user_input" ]; then
                user_input="${user_input%?}"
                printf "\b \b"
            fi
        else
            user_input="${user_input}${ch}"
            printf "%s" "$ch"
        fi
    done
    echo
    user_upper=$(echo "$user_input" | tr -d '\r\n ' | tr 'a-z' 'A-Z')
    code_upper=$(echo "$code" | tr -d '\r\n ' | tr 'a-z' 'A-Z')
    if [ -z "$user_input" ] || [ "$user_input" = "$ESC" ]; then
        echo
        printf "  %b[-] Verification cancelled.%b\n" "$C_FG_GRAY" "$C_RESET"
        sleep 1
        return 1
    elif [ "$user_upper" = "$code_upper" ]; then
        echo
        printf "  %b[+] Code verified. Access granted.%b\n" "$C_FG_GREEN" "$C_RESET"
        sleep 1
        return 0
    else
        echo
        printf "  %b[-] Incorrect verification code or timed out.%b\n" "$C_FG_RED" "$C_RESET"
        sleep 1.5
        return 1
    fi
}

# Converts a size in MiB to a human-readable string (MB, GB, TB)
format_size_mb() {
    m="${1:-0}"
    case "$m" in ""|*[!0-9]*) echo "0 MB"; return ;; esac
    if [ "$m" -ge 1048576 ]; then
        awk -v x="$m" 'BEGIN { printf "%.2f TB", x/1048576 }'
    elif [ "$m" -ge 10240 ]; then
        awk -v x="$m" 'BEGIN { printf "%.1f GB", x/1024 }'
    elif [ "$m" -ge 1024 ]; then
        awk -v x="$m" 'BEGIN { printf "%.2f GB", x/1024 }'
    else
        echo "${m} MB"
    fi
}

# Resolves parent disk device name (e.g. /dev/sda1 -> sda, /dev/nvme0n1p2 -> nvme0n1, sdb -> sdb)
get_parent_disk() {
    dev_name=$(basename "$1")
    [ -z "$dev_name" ] && echo "" && return
    if [ -d "/sys/class/block/$dev_name" ]; then
        parent_link=$(readlink -f "/sys/class/block/$dev_name/..")
        parent_cand=$(basename "$parent_link")
        if [ -f "/sys/class/block/$parent_cand/dev" ] && [ "$parent_cand" != "block" ]; then
            echo "$parent_cand"
            return
        fi
    fi
    case "$dev_name" in
        nvme*p[0-9]*|mmcblk*p[0-9]*) echo "${dev_name%p*}" ;;
        sd[a-z]*[0-9]*|vd[a-z]*[0-9]*|hd[a-z]*[0-9]*) echo "$dev_name" | sed 's/[0-9]*$//' ;;
        *) echo "$dev_name" ;;
    esac
}

# Returns list of physical disks hosting active Linux mounts (must never be raw-passed)
get_host_mounted_disks() {
    mounted=""
    [ -n "$BOOT_DISK" ] && mounted="$BOOT_DISK"
    for mp in / /mnt/esp /mnt/data /mnt/usb_vhd /mnt/inst_esp /mnt/inst_data; do
        if mountpoint -q "$mp" 2>/dev/null; then
            dev=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || df "$mp" 2>/dev/null | awk 'NR==2 {print $1}')
            if [ -n "$dev" ]; then
                pdisk=$(get_parent_disk "$dev")
                case " $mounted " in
                    *" $pdisk "*) ;;
                    *) mounted="$mounted $pdisk" ;;
                esac
            fi
        fi
    done
    echo "$mounted" | xargs
}

# Unmaps any drive letters (C, D, E) currently assigned to a disk or any of its partitions
unmap_drive_letters_for_disk() {
    target_disk=$(get_parent_disk "$1")
    [ -z "$target_disk" ] && return
    for ltr in C D E; do
        eval "slot=\$DRIVE_${ltr}_SLOT"
        [ -n "$slot" ] || continue
        slot_parent=$(get_parent_disk "$slot")
        if [ "$slot_parent" = "$target_disk" ]; then
            eval "DRIVE_${ltr}_SLOT=''"
            eval "DRIVE_${ltr}_MODE=''"
            echo "[!] Drive ${ltr}: unmapped (parent disk $target_disk was assigned to RAW Passthrough)"
        fi
    done
}

# Deconflicts drive letter mappings (C:, D:, E:) and RAW passthrough disks
deconflict_storage_mappings() {
    mapped_parents=""
    for ltr in C D E; do
        eval "slot=\$DRIVE_${ltr}_SLOT"
        [ -n "$slot" ] || continue
        if echo "$slot" | grep -qE '^(/dev/|)(sd|nvme|vd|hd|mmcblk)'; then
            pdisk=$(get_parent_disk "$slot")
            case " $mapped_parents " in
                *" $pdisk "*) ;;
                *) mapped_parents="$mapped_parents $pdisk" ;;
            esac
        fi
    done

    host_disks=$(get_host_mounted_disks)
    if [ "${RAW_CONFIGURED:-0}" != 1 ] && [ -n "$mapped_parents" ]; then
        cur_raw=""
        for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/vd*; do
            [ -d "$d" ] || continue
            dn=$(basename "$d")
            [ "$dn" = "$BOOT_DISK" ] && continue
            cur_raw="$cur_raw $dn"
        done
        RAW_ENABLED_DISKS="$cur_raw"
        RAW_CONFIGURED=1
    fi

    new_raw=""
    for rdisk in $RAW_ENABLED_DISKS; do
        rdisk_clean=$(get_parent_disk "$rdisk")
        case " $host_disks " in
            *" $rdisk_clean "*) continue ;; # Exclude host-mounted disks
        esac
        case " $mapped_parents " in
            *" $rdisk_clean "*) continue ;; # Exclude parent of mapped partition
        esac
        case " $new_raw " in
            *" $rdisk_clean "*) continue ;;
        esac
        new_raw="$new_raw $rdisk_clean"
    done
    RAW_ENABLED_DISKS=$(echo "$new_raw" | xargs)
}

# Normalizes controller_mode / bus_mode string to a, b, or c
normalize_bus_mode() {
    case "$(echo "$1" | tr 'A-Z' 'a-z')" in
        c|ahci) echo "c" ;;
        b)      echo "b" ;;
        a|ide)  echo "a" ;;
        *)      echo "" ;;
    esac
}

# Parses PARTMAP.CFG or DOS.CFG for drive mappings and controller settings
# Sets ROUTER_MODE, BUS_MODE, DRIVE_C_SLOT, DRIVE_C_MODE, DRIVE_D_*, DRIVE_E_*, RAW_ENABLED_DISKS
parse_partmap_cfg() {
    cfg_path="$1"
    ROUTER_MODE="raw_floppy"
    BUS_MODE=""
    DRIVE_C_SLOT=""; DRIVE_C_MODE="rw"
    DRIVE_D_SLOT=""; DRIVE_D_MODE="rw"
    DRIVE_E_SLOT=""; DRIVE_E_MODE="rw"
    RAW_ENABLED_DISKS=""
    RAW_CONFIGURED=0

    [ -f "$cfg_path" ] || return 1

    current_section=""
    while IFS= read -r line || [ -n "$line" ]; do
        clean_line=$(echo "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$clean_line" in
            \#*|";"*|"") continue ;;
            "["*"]")
                current_section=$(echo "$clean_line" | tr -d '[]' | tr 'A-Z' 'a-z')
                ;;
            *"="*)
                key=$(echo "$clean_line" | cut -d'=' -f1 | tr -d ' ' | tr 'A-Z' 'a-z')
                val=$(echo "$clean_line" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                case "$current_section" in
                    system)
                        case "$key" in
                            router_mode) ROUTER_MODE="$val" ;;
                            controller_mode|bus_mode)
                                parsed_bus=$(normalize_bus_mode "$val")
                                [ -n "$parsed_bus" ] && BUS_MODE="$parsed_bus"
                                ;;
                            raw_disks|enabled_disks)
                                RAW_ENABLED_DISKS="$val"
                                RAW_CONFIGURED=1
                                ;;
                        esac
                        ;;
                    raw_disks)
                        case "$key" in
                            enabled|enabled_disks|raw_disks)
                                RAW_ENABLED_DISKS="$val"
                                RAW_CONFIGURED=1
                                ;;
                        esac
                        ;;
                    drive_c)
                        if [ "$key" = "slot" ] || [ "$key" = "target" ]; then DRIVE_C_SLOT="$val"; fi
                        [ "$key" = "mode" ] && DRIVE_C_MODE="$val"
                        ;;
                    drive_d)
                        if [ "$key" = "slot" ] || [ "$key" = "target" ]; then DRIVE_D_SLOT="$val"; fi
                        [ "$key" = "mode" ] && DRIVE_D_MODE="$val"
                        ;;
                    drive_e)
                        if [ "$key" = "slot" ] || [ "$key" = "target" ]; then DRIVE_E_SLOT="$val"; fi
                        [ "$key" = "mode" ] && DRIVE_E_MODE="$val"
                        ;;
                    "")
                        case "$key" in
                            router_mode) ROUTER_MODE="$val" ;;
                            controller_mode|bus_mode)
                                parsed_bus=$(normalize_bus_mode "$val")
                                [ -n "$parsed_bus" ] && BUS_MODE="$parsed_bus"
                                ;;
                            raw_disks|enabled_disks)
                                RAW_ENABLED_DISKS="$val"
                                RAW_CONFIGURED=1
                                ;;
                            drive_c)
                                DRIVE_C_SLOT=$(echo "$val" | cut -d':' -f1)
                                DRIVE_C_MODE=$(echo "$val" | cut -sd':' -f2)
                                [ -z "$DRIVE_C_MODE" ] && DRIVE_C_MODE="rw"
                                ;;
                            drive_d)
                                DRIVE_D_SLOT=$(echo "$val" | cut -d':' -f1)
                                DRIVE_D_MODE=$(echo "$val" | cut -sd':' -f2)
                                [ -z "$DRIVE_D_MODE" ] && DRIVE_D_MODE="rw"
                                ;;
                            drive_e)
                                DRIVE_E_SLOT=$(echo "$val" | cut -d':' -f1)
                                DRIVE_E_MODE=$(echo "$val" | cut -sd':' -f2)
                                [ -z "$DRIVE_E_MODE" ] && DRIVE_E_MODE="rw"
                                ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done < "$cfg_path"
    deconflict_storage_mappings
    return 0
}

# Formats a non-negative integer as 32-bit little-endian octal escapes for POSIX printf
to_le32_octal() {
    awk -v n="${1:-0}" 'BEGIN {
        b0 = n % 256; n = int(n / 256);
        b1 = n % 256; n = int(n / 256);
        b2 = n % 256; n = int(n / 256);
        b3 = n % 256;
        printf "\\%03o\\%03o\\%03o\\%03o", b0, b1, b2, b3;
    }'
}

# Writes an active MBR partition entry #1 at byte 446 and 0x55AA signature at byte 510
# Usage: write_mbr_partition_entry <img_file> <part_type_octal> <lba_sectors> [start_lba]
write_mbr_partition_entry() {
    w_img="$1"
    w_ptype="$2"
    w_sectors="$3"
    w_start="${4:-2048}"
    le_start=$(to_le32_octal "$w_start")
    le_sectors=$(to_le32_octal "$w_sectors")
    printf "\200\376\377\377${w_ptype}\376\377\377${le_start}${le_sectors}" | dd of="$w_img" bs=1 seek=446 conv=notrunc 2>/dev/null
    printf '\125\252' | dd of="$w_img" bs=1 seek=510 conv=notrunc 2>/dev/null
}

# Dynamically creates a 64 MiB MBR-partitioned FAT16 RAM scratch disk in RAM
# Usage: ensure_ram_scratch_disk <drive_letter>
ensure_ram_scratch_disk() {
    ltr_low=$(echo "$1" | tr 'A-Z' 'a-z')
    ltr_up=$(echo "$1" | tr 'a-z' 'A-Z')
    ram_dir="${RAMDISK_DIR:-/run}"
    mkdir -p "$ram_dir" 2>/dev/null || ram_dir="/tmp"
    ram_img="${ram_dir}/ramdisk_${ltr_low}.img"

    if [ -f "$ram_img" ] && [ -s "$ram_img" ]; then
        echo "$ram_img"
        return 0
    fi

    dd if=/dev/zero of="$ram_img" bs=1M count=0 seek=64 2>/dev/null
    part_tmp="${ram_dir}/ramdisk_part_${ltr_low}.tmp"
    dd if=/dev/zero of="$part_tmp" bs=1M count=0 seek=63 2>/dev/null
    if command -v mkfs.vfat >/dev/null 2>&1; then
        mkfs.vfat -F 16 -n "RAMDISK_${ltr_up}" "$part_tmp" >/dev/null 2>&1 || true
    elif command -v mkfs.fat >/dev/null 2>&1; then
        mkfs.fat -F 16 -n "RAMDISK_${ltr_up}" "$part_tmp" >/dev/null 2>&1 || true
    fi
    dd if="$part_tmp" of="$ram_img" bs=512 seek=2048 conv=notrunc 2>/dev/null
    rm -f "$part_tmp"
    # Active MBR partition entry #1: type=0x0E (\016 FAT16 LBA), start LBA=2048, count=129024 (63 MiB)
    write_mbr_partition_entry "$ram_img" '\016' 129024 2048
    echo "$ram_img"
}

# Creates a portable, MBR-partitioned + FAT16/FAT32-formatted dynamic Microsoft .VHD image
# Usage: create_formatted_vhd <dest_vhd_path> <size_mb> [vol_label]
create_formatted_vhd() {
    dest_vhd="$1"
    size_mb="${2:-128}"
    raw_label="${3:-UEFIDOS}"
    case "$size_mb" in ""|*[!0-9]*) return 1 ;; esac
    [ "$size_mb" -ge 16 ] || return 1

    vol_label=$(echo "$raw_label" | tr 'a-z' 'A-Z' | tr -cd 'A-Z0-9_-' | cut -c1-11)
    [ -z "$vol_label" ] && vol_label="UEFIDOS"

    if [ "$size_mb" -le 512 ]; then
        fat_bits=16
        ptype='\016'
    else
        fat_bits=32
        ptype='\014'
    fi

    part_mb=$((size_mb - 1))
    part_sectors=$((part_mb * 2048))

    work_dir="${VHD_WORK_DIR:-/tmp}"
    mkdir -p "$work_dir" 2>/dev/null || work_dir="/tmp"
    mkdir -p "$(dirname "$dest_vhd")" 2>/dev/null || return 1
    raw_tmp="${work_dir}/vhd_build_$$.raw"
    part_tmp="${work_dir}/vhd_part_$$.tmp"
    rm -f "$raw_tmp" "$part_tmp"

    dd if=/dev/zero of="$raw_tmp" bs=1M count=0 seek="$size_mb" 2>/dev/null || return 1

    mkfs_bin=""
    if command -v mkfs.vfat >/dev/null 2>&1; then
        mkfs_bin="mkfs.vfat"
    elif command -v mkfs.fat >/dev/null 2>&1; then
        mkfs_bin="mkfs.fat"
    fi

    formatted=0
    if [ -n "$mkfs_bin" ]; then
        if "$mkfs_bin" --offset=2048 -F "$fat_bits" -n "$vol_label" "$raw_tmp" >/dev/null 2>&1; then
            formatted=1
        fi
        if [ "$formatted" -eq 0 ]; then
            dd if=/dev/zero of="$part_tmp" bs=1M count=0 seek="$part_mb" 2>/dev/null
            if "$mkfs_bin" -F "$fat_bits" -n "$vol_label" "$part_tmp" >/dev/null 2>&1; then
                # Copy initialized FAT headers (up to 32 MiB) so tmpfs RAM stays minimal for 2 GB images
                hdr_mb=32
                [ "$part_mb" -lt "$hdr_mb" ] && hdr_mb="$part_mb"
                dd if="$part_tmp" of="$raw_tmp" bs=1M count="$hdr_mb" seek=1 conv=notrunc 2>/dev/null
                formatted=1
            fi
            rm -f "$part_tmp"
        fi
    fi

    write_mbr_partition_entry "$raw_tmp" "$ptype" "$part_sectors" 2048

    rc=1
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img convert -f raw -O vpc -o subformat=dynamic "$raw_tmp" "$dest_vhd"
        rc=$?
        rm -f "$raw_tmp"
    elif [ "${VHD_RAW_FALLBACK:-0}" = "1" ]; then
        mv -f "$raw_tmp" "$dest_vhd"
        rc=$?
    else
        rm -f "$raw_tmp"
        rc=1
    fi
    return $rc
}

# Resolves a drive target specification to RESOLVED_FILE and RESOLVED_FORMAT
# Usage: resolve_target_spec <target_spec> <drive_letter>
resolve_target_spec() {
    r_slot="$1"
    r_ltr="$2"
    r_lower=$(echo "$r_slot" | tr 'A-Z' 'a-z')

    if [ "$r_lower" = "ram" ]; then
        RESOLVED_FILE=$(ensure_ram_scratch_disk "$r_ltr")
        RESOLVED_FORMAT="raw"
    elif echo "$r_lower" | grep -qE '\.vhd$'; then
        RESOLVED_FILE="$r_slot"
        RESOLVED_FORMAT="vpc"
    elif echo "$r_lower" | grep -qE '\.(img|ima|raw|vfd)$' || [ -f "$r_slot" ]; then
        RESOLVED_FILE="$r_slot"
        RESOLVED_FORMAT="raw"
    elif [ -b "$r_slot" ] || [ -b "/dev/$r_slot" ] || echo "$r_lower" | grep -qE '^(/dev/|)(sd|nvme|vd|hd|mmcblk)'; then
        if [ -b "$r_slot" ]; then
            RESOLVED_FILE="$r_slot"
        elif [ -b "/dev/$r_slot" ]; then
            RESOLVED_FILE="/dev/$r_slot"
        elif echo "$r_slot" | grep -q '^/dev/'; then
            RESOLVED_FILE="$r_slot"
        else
            RESOLVED_FILE="/dev/$r_slot"
        fi
        RESOLVED_FORMAT="raw"
    else
        RESOLVED_FILE=""
        RESOLVED_FORMAT=""
    fi
}

# Unmaps a specific drive letter (c, d, or e)
unmap_drive_mapping() {
    ltr="$1"
    case "$ltr" in
        c|C) DRIVE_C_SLOT=""; DRIVE_C_MODE="" ;;
        d|D) DRIVE_D_SLOT=""; DRIVE_D_MODE="" ;;
        e|E) DRIVE_E_SLOT=""; DRIVE_E_MODE="" ;;
    esac
}

# Builds QEMU -drive and -device arguments for mapped drives
# Usage: build_slot_qemu_args
build_slot_qemu_args() {
    args=""

    idx=0
    for ltr in C D E; do
        eval "slot=\$DRIVE_${ltr}_SLOT"
        eval "mode=\$DRIVE_${ltr}_MODE"
        [ -n "$slot" ] || continue

        slot_lower=$(echo "$slot" | tr 'A-Z' 'a-z')
        mode_lower=$(echo "$mode" | tr 'A-Z' 'a-z')
        [ "$slot_lower" = "ram" ] && mode_lower="temp"
        [ -z "$mode_lower" ] && mode_lower="rw"

        resolve_target_spec "$slot" "$ltr"
        target_file="$RESOLVED_FILE"
        file_format="$RESOLVED_FORMAT"
        [ -n "$target_file" ] || continue

        drive_id="slotdrive_$(echo "$ltr" | tr 'A-Z' 'a-z')"
        case "$mode_lower" in
            temp)
                drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},snapshot=on,cache=unsafe"
                ;;
            ro)
                # QEMU ide-hd aborts with "Block node is read-only" on readonly=on; snapshot=on opens target read-only safely.
                drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},snapshot=on"
                ;;
            *)
                drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},cache=none,aio=native"
                ;;
        esac

        case $idx in
            0) pos="bus=ide.0,unit=0" ;;  # C:
            1) pos="bus=ide.0,unit=1" ;;  # D:
            2) pos="bus=ide.1,unit=1" ;;  # E: (ide.1 unit 0 is CD-ROM)
            *) pos="bus=ide.$((idx/2)),unit=$((idx%2))" ;;
        esac

        args="$args -drive $drive_opt -device ide-hd,$pos,drive=${drive_id},serial=SLOT_${ltr}"
        idx=$((idx + 1))
    done

    echo "$args"
}

# Builds complete QEMU drive & device arguments for both mapped drives and RAW passthrough disks
# Usage: build_storage_attachments [mode]
build_storage_attachments() {
    if [ -n "$3" ]; then
        qmode="$3"
    else
        qmode="${1:-a}"
    fi
    args=""

    # 1. Attach mapped drives (C:, D:, E:)
    used_ide0_0=0; used_ide0_1=0; used_ide1_1=0
    ahci_port=0

    for ltr in C D E; do
        eval "slot=\$DRIVE_${ltr}_SLOT"
        eval "mode=\$DRIVE_${ltr}_MODE"
        [ -n "$slot" ] || continue

        slot_lower=$(echo "$slot" | tr 'A-Z' 'a-z')
        mode_lower=$(echo "$mode" | tr 'A-Z' 'a-z')
        [ "$slot_lower" = "ram" ] && mode_lower="temp"
        [ -z "$mode_lower" ] && mode_lower="rw"

        resolve_target_spec "$slot" "$ltr"
        target_file="$RESOLVED_FILE"
        file_format="$RESOLVED_FORMAT"
        [ -n "$target_file" ] || continue

        drive_id="slotdrive_$(echo "$ltr" | tr 'A-Z' 'a-z')"
        case "$mode_lower" in
            temp) drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},snapshot=on,cache=unsafe" ;;
            # QEMU ide-hd aborts with "Block node is read-only" on readonly=on; snapshot=on opens target read-only safely.
            ro)   drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},snapshot=on" ;;
            *)    drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},cache=none,aio=native" ;;
        esac

        case "$qmode" in
            c)
                [ $ahci_port -ge 6 ] && break
                args="$args -drive $drive_opt -device ide-hd,bus=ahci.${ahci_port},drive=${drive_id},serial=SLOT_${ltr}"
                ahci_port=$((ahci_port + 1))
                ;;
            b)
                idx=0; [ "$ltr" = "D" ] && idx=1; [ "$ltr" = "E" ] && idx=3
                args="$args -drive file=${target_file},format=${file_format},if=ide,index=${idx},cache=none,aio=native,discard=off,serial=SLOT_${ltr}"
                ;;
            *)  # Mode A (PIIX IDE)
                case "$ltr" in
                    C) pos="bus=ide.0,unit=0"; used_ide0_0=1 ;;
                    D) pos="bus=ide.0,unit=1"; used_ide0_1=1 ;;
                    E) pos="bus=ide.1,unit=1"; used_ide1_1=1 ;;
                esac
                args="$args -drive $drive_opt -device ide-hd,$pos,drive=${drive_id},serial=SLOT_${ltr}"
                ;;
        esac
    done

    # 2. Attach eligible RAW passthrough disks
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

    raw_idx=0
    for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/vd*; do
        [ -d "$d" ] || continue
        dname=$(basename "$d")
        [ "$dname" = "$BOOT_DISK" ] && continue
        case " $host_disks " in *" $dname "*) continue ;; esac
        case " $mapped_parents " in *" $dname "*) continue ;; esac
        sz=$(cat "$d/size" 2>/dev/null || echo 0); [ "$sz" -gt 0 ] || continue
        rem=$(cat "$d/removable" 2>/dev/null || echo 0)
        [ -z "$BOOT_DISK" ] && [ "$rem" = 1 ] && continue

        if [ "$RAW_CONFIGURED" = 1 ]; then
            case " $RAW_ENABLED_DISKS " in *" $dname "*) ;; *) continue ;; esac
        fi

        ser=$(cat "$d/device/serial" 2>/dev/null | tr ' ' '_' | tr -cd 'A-Za-z0-9._-' | cut -c1-20)
        mdl=$(cat "$d/device/model" 2>/dev/null | tr ' ' '_' | tr -cd 'A-Za-z0-9._-' | cut -c1-40)
        [ -z "$ser" ] && ser="DOS${raw_idx}${dname}"
        [ -z "$mdl" ] && mdl="DISK_${dname}"

        drv="file=/dev/$dname,format=raw,if=none,id=hd${raw_idx},cache=none,aio=native,discard=off"

        case "$qmode" in
            c)
                [ $ahci_port -ge 6 ] && break
                args="$args -drive $drv -device ide-hd,bus=ahci.${ahci_port},drive=hd${raw_idx},serial=$ser,model=$mdl"
                ahci_port=$((ahci_port + 1))
                ;;
            b)
                b_idx=$raw_idx
                [ $b_idx -ge 2 ] && b_idx=$((b_idx + 1))
                args="$args -drive file=/dev/$dname,format=raw,if=ide,index=${b_idx},cache=none,aio=native,discard=off,serial=$ser"
                ;;
            *)  # Mode A (PIIX IDE): fill remaining positions among ide.0,0, ide.0,1, ide.1,1
                pos=""
                if [ $used_ide0_0 -eq 0 ]; then
                    pos="bus=ide.0,unit=0"; used_ide0_0=1
                elif [ $used_ide0_1 -eq 0 ]; then
                    pos="bus=ide.0,unit=1"; used_ide0_1=1
                elif [ $used_ide1_1 -eq 0 ]; then
                    pos="bus=ide.1,unit=1"; used_ide1_1=1
                else
                    # All 3 IDE positions occupied
                    break
                fi
                args="$args -drive $drv -device ide-hd,$pos,drive=hd${raw_idx},serial=$ser,model=$mdl"
                ;;
        esac
        raw_idx=$((raw_idx + 1))
    done

    echo "$args"
}

# Formats a whole physical disk with a clean MBR partition table and a single active FAT32 partition
# Usage: format_disk_mbr_fat32 <disk_dev_or_name> [vol_label]
format_disk_mbr_fat32() {
    raw_dev="$1"
    raw_label="${2:-DOS_STORAGE}"
    case "$raw_dev" in
        /*|[A-Za-z]:/*) disk_dev="$raw_dev"; dname=$(basename "$raw_dev") ;;
        *)              disk_dev="/dev/$raw_dev"; dname="$raw_dev" ;;
    esac
    [ -b "$disk_dev" ] || [ -f "$disk_dev" ] || return 1

    vol_label=$(echo "$raw_label" | tr 'a-z' 'A-Z' | tr -cd 'A-Z0-9_-' | cut -c1-11)
    [ -z "$vol_label" ] && vol_label="DOS_STORAGE"

    if [ -f "/sys/block/$dname/size" ]; then
        total_sectors=$(cat "/sys/block/$dname/size" 2>/dev/null || echo 0)
    else
        # Fallback for file-backed unit tests (size in 512-byte sectors)
        total_bytes=$(wc -c < "$disk_dev" 2>/dev/null || echo 0)
        total_sectors=$(awk -v b="$total_bytes" 'BEGIN { printf "%.0f", int(b / 512) }')
    fi

    # Require at least 64 MiB (131072 sectors) for clean FAT32 formatting
    is_valid_sz=$(awk -v s="$total_sectors" 'BEGIN { print (s >= 131072) ? 1 : 0 }')
    [ "$is_valid_sz" = "1" ] || return 1

    # Single active MBR partition starting at LBA 2048, clamped to 32-bit MBR LBA limit (~2 TiB)
    part_sectors=$(awk -v s="$total_sectors" 'BEGIN {
        p = s - 2048;
        if (p > 4294965248) p = 4294965248;
        printf "%.0f", p;
    }')

    # Erase any stale GPT headers (primary + backup) and first 2 MiB
    if [ -b "$disk_dev" ] && command -v sgdisk >/dev/null 2>&1; then
        sgdisk --zap-all "$disk_dev" >/dev/null 2>&1 || true
    fi
    dd if=/dev/zero of="$disk_dev" bs=1M count=2 conv=notrunc 2>/dev/null || return 1

    # Write active MBR partition #1: type=0x0C (\014 FAT32 LBA), start=2048
    write_mbr_partition_entry "$disk_dev" '\014' "$part_sectors" 2048
    sync 2>/dev/null || true

    # If called on a regular file (e.g. unit test), stop after writing MBR unless block device
    [ -b "$disk_dev" ] || return 0

    partprobe "$disk_dev" 2>/dev/null || blockdev --rereadpt "$disk_dev" 2>/dev/null || true

    case "$dname" in
        nvme*|mmcblk*) part_name="${dname}p1" ;;
        *)             part_name="${dname}1" ;;
    esac
    part_dev="/dev/${part_name}"

    wait_i=0
    while [ ! -b "$part_dev" ] && [ $wait_i -lt 6 ]; do
        if [ -f "/sys/block/$dname/$part_name/dev" ]; then
            mknod "$part_dev" b $(sed 's/:/ /' < "/sys/block/$dname/$part_name/dev" 2>/dev/null) 2>/dev/null || true
        fi
        [ -b "$part_dev" ] && break
        sleep 1
        wait_i=$((wait_i + 1))
    done
    [ -b "$part_dev" ] || return 1

    if command -v mkfs.vfat >/dev/null 2>&1; then
        mkfs.vfat -F 32 -n "$vol_label" "$part_dev"
    elif command -v mkfs.fat >/dev/null 2>&1; then
        mkfs.fat -F 32 -n "$vol_label" "$part_dev"
    else
        return 1
    fi
    rc=$?
    sync 2>/dev/null || true
    FORMATTED_PART_DEV="$part_dev"
    return $rc
}

# Scan connected USB mass storage devices with FAT partitions (ignoring boot disk)
list_usb_fat_partitions() {
    exclude_disk="$1"
    for p in /sys/class/block/*; do
        [ -f "$p/partition" ] || continue
        pn=$(basename "$p")
        parent=$(basename "$(readlink -f "$p/..")")
        [ "$parent" = "$exclude_disk" ] && continue
        
        # Check if USB
        readlink -f "$p" | grep -q "usb" || continue

        sz_mb=$(( $(cat "$p/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue

        mdl=$(cat "/sys/class/block/$parent/device/model" 2>/dev/null | tr -s ' ')
        [ -z "$mdl" ] && mdl="USB Drive"

        echo "/dev/$pn ($(format_size_mb "$sz_mb")) [$mdl]"
    done
}

# Scan all non-boot FAT16/FAT32 partitions (both internal SATA/NVMe disks and USB drives)
list_fat_partitions() {
    exclude_disk="$1"
    for p in /sys/class/block/*; do
        [ -f "$p/partition" ] || continue
        pn=$(basename "$p")
        parent=$(basename "$(readlink -f "$p/..")")
        [ "$parent" = "$exclude_disk" ] && continue

        sz_mb=$(( $(cat "$p/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue

        fs_type=$(blkid -s TYPE -o value "/dev/$pn" 2>/dev/null || echo "")
        case "$(echo "$fs_type" | tr 'A-Z' 'a-z')" in
            vfat|fat|fat32|fat16|msdos) ;;
            *) continue ;;
        esac

        if readlink -f "$p" | grep -q "usb"; then
            bus_tag="USB"
        else
            bus_tag="DISK"
        fi

        lbl=$(blkid -s LABEL -o value "/dev/$pn" 2>/dev/null || echo "")
        mdl=$(cat "/sys/class/block/$parent/device/model" 2>/dev/null | tr -s ' ' | cut -c1-18)
        [ -z "$mdl" ] && mdl="Drive"

        if [ -n "$lbl" ]; then
            echo "/dev/$pn ($(format_size_mb "$sz_mb")) [${bus_tag} ${fs_type} \"${lbl}\" - ${mdl}]"
        else
            echo "/dev/$pn ($(format_size_mb "$sz_mb")) [${bus_tag} ${fs_type} - ${mdl}]"
        fi
    done
}

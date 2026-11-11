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
    for mp in / /mnt/esp /mnt/data /mnt/golden /mnt/inst_esp /mnt/inst_data /mnt/inst_golden; do
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
        if echo "$slot" | grep -qE '^(/dev/|)(sd|nvme|vd|hd)'; then
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

# Parses PARTMAP.CFG or DOS.CFG for slot drive mappings
# Sets ROUTER_MODE, DRIVE_C_SLOT, DRIVE_C_MODE, DRIVE_D_*, DRIVE_E_*, RAW_ENABLED_DISKS
parse_partmap_cfg() {
    cfg_path="$1"
    ROUTER_MODE="raw_floppy"
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
                        [ "$key" = "slot" ] && DRIVE_C_SLOT="$val"
                        [ "$key" = "mode" ] && DRIVE_C_MODE="$val"
                        ;;
                    drive_d)
                        [ "$key" = "slot" ] && DRIVE_D_SLOT="$val"
                        [ "$key" = "mode" ] && DRIVE_D_MODE="$val"
                        ;;
                    drive_e)
                        [ "$key" = "slot" ] && DRIVE_E_SLOT="$val"
                        [ "$key" = "mode" ] && DRIVE_E_MODE="$val"
                        ;;
                    "")
                        case "$key" in
                            router_mode) ROUTER_MODE="$val" ;;
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

# Unmaps a specific drive letter (c, d, or e)
unmap_drive_mapping() {
    ltr="$1"
    case "$ltr" in
        c|C) DRIVE_C_SLOT=""; DRIVE_C_MODE="" ;;
        d|D) DRIVE_D_SLOT=""; DRIVE_D_MODE="" ;;
        e|E) DRIVE_E_SLOT=""; DRIVE_E_MODE="" ;;
    esac
}

# Builds QEMU -drive and -device arguments for mapped slots
# Usage: build_slot_qemu_args <golden_path> <slots_dir>
build_slot_qemu_args() {
    golden_path="$1"
    slots_dir="$2"
    args=""

    idx=0
    for ltr in C D E; do
        eval "slot=\$DRIVE_${ltr}_SLOT"
        eval "mode=\$DRIVE_${ltr}_MODE"
        [ -n "$slot" ] || continue

        slot_lower=$(echo "$slot" | tr 'A-Z' 'a-z')
        mode_lower=$(echo "$mode" | tr 'A-Z' 'a-z')
        [ -z "$mode_lower" ] && mode_lower="rw"

        if [ "$slot_lower" = "golden" ] || [ "$slot_lower" = "base" ] || [ "$slot_lower" = "ram" ]; then
            target_file="$golden_path"
            file_format="raw"
        elif [ -b "$slot" ] || [ -b "/dev/$slot" ] || echo "$slot_lower" | grep -qE '^(/dev/|)(sd|nvme|vd)'; then
            if [ -b "$slot" ]; then
                target_file="$slot"
            elif [ -b "/dev/$slot" ]; then
                target_file="/dev/$slot"
            elif echo "$slot" | grep -q '^/dev/'; then
                target_file="$slot"
            else
                target_file="/dev/$slot"
            fi
            file_format="raw"
        else
            target_file="${slots_dir}/${slot_lower}.qcow2"
            file_format="qcow2"
        fi

        drive_id="slotdrive_$(echo "$ltr" | tr 'A-Z' 'a-z')"
        case "$mode_lower" in
            temp)
                drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},snapshot=on,cache=unsafe"
                ;;
            ro)
                drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},readonly=on"
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

# Builds complete QEMU drive & device arguments for both mapped slots and RAW passthrough disks
# Usage: build_storage_attachments <golden_path> <slots_dir> <mode>
build_storage_attachments() {
    golden_path="$1"
    slots_dir="$2"
    qmode="${3:-a}"
    args=""

    # 1. Attach mapped slots (C:, D:, E:)
    used_ide0_0=0; used_ide0_1=0; used_ide1_1=0
    ahci_port=0

    for ltr in C D E; do
        eval "slot=\$DRIVE_${ltr}_SLOT"
        eval "mode=\$DRIVE_${ltr}_MODE"
        [ -n "$slot" ] || continue

        slot_lower=$(echo "$slot" | tr 'A-Z' 'a-z')
        mode_lower=$(echo "$mode" | tr 'A-Z' 'a-z')
        [ -z "$mode_lower" ] && mode_lower="rw"

        if [ "$slot_lower" = "golden" ] || [ "$slot_lower" = "base" ] || [ "$slot_lower" = "ram" ]; then
            target_file="$golden_path"
            file_format="raw"
        elif [ -b "$slot" ] || [ -b "/dev/$slot" ] || echo "$slot_lower" | grep -qE '^(/dev/|)(sd|nvme|vd)'; then
            if [ -b "$slot" ]; then
                target_file="$slot"
            elif [ -b "/dev/$slot" ]; then
                target_file="/dev/$slot"
            elif echo "$slot" | grep -q '^/dev/'; then
                target_file="$slot"
            else
                target_file="/dev/$slot"
            fi
            file_format="raw"
        else
            target_file="${slots_dir}/${slot_lower}.qcow2"
            file_format="qcow2"
        fi

        drive_id="slotdrive_$(echo "$ltr" | tr 'A-Z' 'a-z')"
        case "$mode_lower" in
            temp) drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},snapshot=on,cache=unsafe" ;;
            ro)   drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},readonly=on" ;;
            *)    drive_opt="file=${target_file},format=${file_format},if=none,id=${drive_id},cache=none,aio=native" ;;
        esac

        case "$qmode" in
            c)
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
        if echo "$slot" | grep -qE '^(/dev/|)(sd|nvme|vd|hd)'; then
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

        echo "/dev/$pn ($sz_mb MB) [$mdl]"
    done
}

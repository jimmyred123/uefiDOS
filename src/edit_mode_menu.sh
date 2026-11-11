#!/bin/busybox sh
# =============================================================================
# uefiDOS Industrial Appliance - Interactive Maintenance & TUI Dashboard
# In-place ANSI painted interface with Human Factors / Ergonomic Design
# =============================================================================

# Include helper functions
SCRIPT_DIR="$(dirname "$0")"
[ -f "$SCRIPT_DIR/slot_router.sh" ] && . "$SCRIPT_DIR/slot_router.sh"

DATA_DIR="/mnt/data"
SLOTS_DIR="${DATA_DIR}/slots"
GOLDEN_PATH="/mnt/golden/base.raw"
ESP_DIR="/mnt/esp"
PARTMAP_FILE="${ESP_DIR}/PARTMAP.CFG"
MAINT_FLAG="/run/maintenance_shell.flg"
LIVE_MEDIA_FLAG="/run/live_media_name"

mkdir -p "$SLOTS_DIR" /mnt/usb /run

# ANSI Color Definitions
ESC=$(printf '\033')
C_RESET="${ESC}[0m"
C_BOLD="${ESC}[1m"
C_DIM="${ESC}[2m"
C_REV="${ESC}[7m"

C_BLUE_BG="${ESC}[44;1;37m"
C_GRAY_BG="${ESC}[47;1;30m"
C_RED_BG="${ESC}[41;1;37m"

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

# Read a single key press with ESC detection (ASCII 27)
read_key() {
    key=""
    if read -r -s -n 1 -t 300 k 2>/dev/null; then
        key="$k"
    else
        read -r -t 300 key 2>/dev/null || key=""
    fi
    if [ "$key" = "$ESC" ]; then
        # Consume any trailing escape sequence characters (like arrow keys)
        read -r -s -n 2 -t 1 _dummy 2>/dev/null || true
        echo "ESC"
    elif [ -z "$key" ]; then
        echo "ENTER"
    else
        echo "$key"
    fi
}

# Prompt for a line of text, allowing [ESC], "0", or "q" to abort
# Usage: read_line_or_esc "Prompt text" "default_val"
# Returns 0 on input, 1 on abort/ESC
# Result stored in $INPUT_VAL
read_line_or_esc() {
    prompt_txt="$1"
    def_val="$2"
    INPUT_VAL=""
    if [ -n "$def_val" ]; then
        printf "%b%s [default: %s] (or ESC/0 to abort): %b" "$C_FG_CYAN" "$prompt_txt" "$def_val" "$C_RESET"
    else
        printf "%b%s (or ESC/0 to abort): %b" "$C_FG_CYAN" "$prompt_txt" "$C_RESET"
    fi
    raw_in=""
    while IFS= read -r -s -n 1 ch 2>/dev/null; do
        if [ "$ch" = "$ESC" ]; then
            raw_in="$ESC"
            break
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
    if [ "$raw_in" = "$ESC" ] || [ "$raw_in" = "0" ] || [ "$raw_in" = "q" ] || [ "$raw_in" = "Q" ] || [ "$raw_in" = "abort" ]; then
        return 1
    fi
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

ensure_rw_esp() {
    mount -o remount,rw "$ESP_DIR" 2>/dev/null || true
}

save_partmap_cfg() {
    ensure_rw_esp
    deconflict_storage_mappings
    {
        echo "# uefiDOS Dynamic Slot & Partition Router Configuration"
        echo "[system]"
        if [ -n "$DRIVE_C_SLOT" ] || [ -n "$DRIVE_D_SLOT" ] || [ -n "$DRIVE_E_SLOT" ]; then
            echo "router_mode = slots"
        else
            echo "router_mode = raw_floppy"
        fi
        if [ -n "$RAW_ENABLED_DISKS" ]; then
            echo "raw_disks = ${RAW_ENABLED_DISKS}"
        elif [ "${RAW_CONFIGURED:-0}" = 1 ]; then
            echo "raw_disks = "
        fi
        echo
        echo "[drive_c]"
        echo "slot = ${DRIVE_C_SLOT}"
        echo "mode = ${DRIVE_C_MODE:-temp}"
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
    } > "$PARTMAP_FILE"
    cp -f "$PARTMAP_FILE" /run/PARTMAP.CFG 2>/dev/null || true
    sync
}

get_mode_badge() {
    m="$1"
    case "$m" in
        temp) printf "%b[RAM-OVERLAY]%b" "$C_FG_GREEN" "$C_RESET" ;;
        rw)   printf "%b[PERSIST-RW]%b" "$C_FG_YELLOW" "$C_RESET" ;;
        ro)   printf "%b[READ-ONLY]%b" "$C_FG_MAGENTA" "$C_RESET" ;;
        *)    printf "%b[DISABLED]%b" "$C_FG_GRAY" "$C_RESET" ;;
    esac
}

get_target_disks_summary() {
    disks=""
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
        mdl=$(cat "$d/device/model" 2>/dev/null | tr -s ' ' | cut -c1-18)
        [ -z "$mdl" ] && mdl="Disk"
        if [ -z "$disks" ]; then
            disks="/dev/${dname} (${sz_mb}MB ${mdl})"
        else
            disks="${disks}, /dev/${dname} (${sz_mb}MB)"
        fi
    done
    if [ -z "$disks" ]; then
        if [ "${RAW_CONFIGURED:-0}" = 1 ] && [ -z "$RAW_ENABLED_DISKS" ]; then
            echo "(All unmapped / None enabled)"
        else
            echo "(None detected / Boot disk excluded)"
        fi
    else
        echo "$disks"
    fi
}

list_available_slots() {
    echo "  Available Virtual Storage Slots:"
    echo "    - golden  (Immutable Factory Golden Master Base)"
    if [ -d "$SLOTS_DIR" ]; then
        found=0
        for s in "$SLOTS_DIR"/*.qcow2; do
            [ -f "$s" ] || continue
            sname=$(basename "$s" .qcow2)
            sz=$(ls -lh "$s" 2>/dev/null | awk '{print $5}')
            echo "    - $sname ($sz)"
            found=1
        done
        [ $found -eq 0 ] && echo "    (No custom slots found - golden base only)"
    fi
    echo
    echo "  Available Physical Partitions (Linux device paths):"
    p_found=0
    for p in /sys/class/block/*; do
        [ -f "$p/partition" ] || continue
        pn=$(basename "$p")
        parent=$(basename "$(readlink -f "$p/..")")
        [ "$parent" = "$BOOT_DISK" ] && continue
        sz_mb=$(( $(cat "$p/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue
        fs_type=$(blkid -s TYPE -o value "/dev/$pn" 2>/dev/null || echo "")
        [ -n "$fs_type" ] && fs_info="[$fs_type]" || fs_info=""
        echo "    - /dev/$pn (${sz_mb}MB $fs_info)"
        p_found=1
    done
    [ $p_found -eq 0 ] && echo "    (No physical partitions detected outside boot disk)"
}

normalize_slot_or_dev() {
    val="$1"
    [ -z "$val" ] && echo "" && return
    if echo "$val" | grep -qE '^(sd|nvme|vd)'; then
        echo "/dev/$val"
    else
        echo "$val"
    fi
}

select_usb_partition() {
    echo "Scanning attached USB flash drives..."
    usbs=$(list_usb_fat_partitions "$BOOT_DISK")
    if [ -z "$usbs" ]; then
        echo "[-] No attached FAT32 USB flash drives detected. Please insert one."
        printf "Press any key to return..."
        read_key >/dev/null
        return 1
    fi

    echo
    echo "Available USB partitions:"
    i=1
    echo "$usbs" | while IFS= read -r uline; do
        echo "  [$i] $uline"
        i=$((i+1))
    done
    echo

    if ! read_line_or_esc "Select USB device number (1-$(( $(echo "$usbs" | wc -l) )))"; then
        return 1
    fi
    sel="$INPUT_VAL"
    target_dev=$(echo "$usbs" | sed -n "${sel}p" | awk '{print $1}')
    if [ -z "$target_dev" ] || [ ! -b "$target_dev" ]; then
        echo "[-] Invalid selection."
        sleep 1
        return 1
    fi
    SELECTED_USB="$target_dev"
    return 0
}

# -----------------------------------------------------------------------------
# Sub-Actions
# -----------------------------------------------------------------------------

do_route_drives() {
    while :; do
        clear_screen
        echo "================================================================================"
        printf "%b  STORAGE ROUTING  ::  Configure Hardware Drive Assignments (C:, D:, E:)        %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        echo "  Select a drive letter to configure, or press [ESC] to return."
        echo
        echo "  Current Assignments:"
        if [ -n "$DRIVE_C_SLOT" ]; then
            printf "    [C] Drive C: %-30s %b\n" "$DRIVE_C_SLOT" "$(get_mode_badge "$DRIVE_C_MODE")"
        else
            printf "    [C] Drive C: %-30s %b\n" "(Unmapped)" "${C_FG_GRAY}[OFFLINE]${C_RESET}"
        fi
        if [ -n "$DRIVE_D_SLOT" ]; then
            printf "    [D] Drive D: %-30s %b\n" "$DRIVE_D_SLOT" "$(get_mode_badge "$DRIVE_D_MODE")"
        else
            printf "    [D] Drive D: %-30s %b\n" "(Unmapped)" "${C_FG_GRAY}[OFFLINE]${C_RESET}"
        fi
        if [ -n "$DRIVE_E_SLOT" ]; then
            printf "    [E] Drive E: %-30s %b\n" "$DRIVE_E_SLOT" "$(get_mode_badge "$DRIVE_E_MODE")"
        else
            printf "    [E] Drive E: %-30s %b\n" "(Unmapped)" "${C_FG_GRAY}[OFFLINE]${C_RESET}"
        fi
        echo
        echo "  Enter drive letter [C, D, E] to configure, or [ESC] to return."
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        target_ltr=$(read_key)
        case "$target_ltr" in
            c|C) sel_ltr="C" ;;
            d|D) sel_ltr="D" ;;
            e|E) sel_ltr="E" ;;
            ESC|0|q|Q) break ;;
            *) continue ;;
        esac

        # Step 1: Select Target for Drive $sel_ltr
        clear_screen
        echo "================================================================================"
        printf "%b  SELECT TARGET FOR DRIVE %s:                                                   %b\n" "$C_BLUE_BG" "$sel_ltr" "$C_RESET"
        echo "================================================================================"
        echo "  [0] Unmap / Detach Drive ${sel_ltr}:"
        echo "  [1] Virtual RAM Scratch Disk (Clean FreeDOS volume in RAM)"
        echo
        echo "  Detected Physical Partitions:"

        plist=""
        pcount=1
        for p in /sys/class/block/*; do
            [ -f "$p/partition" ] || continue
            pn=$(basename "$p")
            parent=$(basename "$(readlink -f "$p/..")")
            [ "$parent" = "$BOOT_DISK" ] && continue
            sz_mb=$(( $(cat "$p/size" 2>/dev/null || echo 0) / 2048 ))
            [ "$sz_mb" -gt 0 ] || continue
            fs_type=$(blkid -s TYPE -o value "/dev/$pn" 2>/dev/null || echo "")
            [ -n "$fs_type" ] && fs_info="[$fs_type]" || fs_info="[raw]"
            fs_label=$(blkid -s LABEL -o value "/dev/$pn" 2>/dev/null || echo "")
            [ -n "$fs_label" ] && fs_lbl="\"$fs_label\"" || fs_lbl=""
            pcount=$((pcount + 1))
            printf "    [%d] /dev/%-8s (%6d MB)  %-8s %s\n" "$pcount" "$pn" "$sz_mb" "$fs_info" "$fs_lbl"
            plist="${plist}/dev/${pn} "
        done

        if [ $pcount -eq 1 ]; then
            echo "    (No physical partitions detected outside boot disk)"
        fi
        echo
        echo "  [F] Custom File Path / USB Disk Image (.img / .vhd)"
        echo "  [ESC] Cancel"
        echo "--------------------------------------------------------------------------------"
        printf "  Select target (0-%d, F, or ESC) > " "$pcount"

        choice=$(read_key)
        new_target=""
        case "$choice" in
            ESC|q|Q)
                continue
                ;;
            0)
                eval "DRIVE_${sel_ltr}_SLOT=''"
                eval "DRIVE_${sel_ltr}_MODE=''"
                save_partmap_cfg
                printf "\n%b[+] Drive %s: unmapped.%b\n" "$C_FG_GREEN" "$sel_ltr" "$C_RESET"
                sleep 1
                continue
                ;;
            1)
                new_target="ram"
                ;;
            [2-9]*)
                idx_num=$(echo "$choice" | tr -cd '0-9')
                if [ -n "$idx_num" ] && [ "$idx_num" -ge 2 ] && [ "$idx_num" -le "$pcount" ]; then
                    part_idx=$((idx_num - 1))
                    new_target=$(echo "$plist" | awk -v n="$part_idx" '{print $n}')
                else
                    echo "Invalid selection."
                    sleep 1
                    continue
                fi
                ;;
            f|F)
                echo
                if ! read_line_or_esc "Enter partition path or disk image filename (e.g. /dev/sda1 or /mnt/usb/DATA.VHD)"; then
                    continue
                fi
                new_target=$(normalize_slot_or_dev "$INPUT_VAL")
                [ -z "$new_target" ] && continue
                ;;
            *)
                continue
                ;;
        esac

        # Step 2: Select Access Mode for Drive $sel_ltr
        clear_screen
        echo "================================================================================"
        printf "%b  SELECT ACCESS MODE FOR DRIVE %s: [ %s ]%b\n" "$C_BLUE_BG" "$sel_ltr" "$new_target" "$C_RESET"
        echo "================================================================================"
        echo "  Choose how DOS interacts with this target:"
        echo
        echo "    [1] Read/Write (Persistent)"
        echo "        Direct hardware block access. All file modifications and sector"
        echo "        writes are saved permanently to the target."
        echo
        echo "    [2] Read-Only (Hardware Lock)"
        echo "        Strict write protection. Any write attempt by DOS or utilities"
        echo "        is blocked at the hardware emulation layer."
        echo
        echo "    [3] RAM Overlay (Disposable Snapshot)"
        echo "        Disposable RAM layer. DOS can freely read and write, but all changes"
        echo "        are kept in RAM and discarded on reboot. Target remains pristine."
        echo
        echo "    [ESC] Cancel"
        echo "--------------------------------------------------------------------------------"
        printf "  Select mode [1, 2, 3, or ESC] > "
        mode_choice=$(read_key)
        new_mode="rw"
        case "$mode_choice" in
            1) new_mode="rw" ;;
            2) new_mode="ro" ;;
            3) new_mode="temp" ;;
            ESC|q|Q) continue ;;
            *) new_mode="rw" ;;
        esac

        eval "DRIVE_${sel_ltr}_SLOT=\"$new_target\""
        eval "DRIVE_${sel_ltr}_MODE=\"$new_mode\""

        save_partmap_cfg
        echo
        printf "%b[+] Drive %s: mapped to %s (%s)%b\n" "$C_FG_GREEN" "$sel_ltr" "$new_target" "$(get_mode_badge "$new_mode")" "$C_RESET"
        sleep 1.2
    done
}

do_unmap_drive() {
    clear_screen
    echo "================================================================================"
    printf "%b  DRIVE ROUTING  ::  Unmap Assigned Virtual Drive                              %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo "  Current Mappings:"
    echo "    [C] Drive C: ${DRIVE_C_SLOT:-slot1} ($(get_mode_badge "${DRIVE_C_MODE:-temp}"))"
    [ -n "$DRIVE_D_SLOT" ] && echo "    [D] Drive D: ${DRIVE_D_SLOT} ($(get_mode_badge "${DRIVE_D_MODE:-rw}"))" || echo "    [D] Drive D: (Unmapped)"
    [ -n "$DRIVE_E_SLOT" ] && echo "    [E] Drive E: ${DRIVE_E_SLOT} ($(get_mode_badge "${DRIVE_E_MODE:-ro}"))" || echo "    [E] Drive E: (Unmapped)"
    echo
    echo "  Enter drive letter to unmap [C, D, E], or press [ESC] to abort."
    printf "  Selection > "
    k=$(read_key)
    case "$k" in
        c|C)
            printf "Unmap Drive C? Confirm [y/N]: "
            read -r conf
            case "$conf" in [yY]*) DRIVE_C_SLOT=""; DRIVE_C_MODE=""; save_partmap_cfg ;; esac
            ;;
        d|D)
            DRIVE_D_SLOT=""; DRIVE_D_MODE=""
            save_partmap_cfg
            printf "\n%b[+] Drive D: unmapped successfully.%b\n" "$C_FG_GREEN" "$C_RESET"
            sleep 1
            ;;
        e|E)
            DRIVE_E_SLOT=""; DRIVE_E_MODE=""
            save_partmap_cfg
            printf "\n%b[+] Drive E: unmapped successfully.%b\n" "$C_FG_GREEN" "$C_RESET"
            sleep 1
            ;;
        *)
            echo "Aborted."
            sleep 0.5
            ;;
    esac
}

do_slot_manager() {
    while :; do
        clear_screen
        echo "================================================================================"
        printf "%b  SLOT MANAGER  ::  Create, Clone, and Reset Virtual Disk Slots               %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        list_available_slots
        echo
        echo "  Operations:"
        echo "    [1] Clone Slot"
        echo "    [2] Create New Empty Slot"
        echo "    [3] Factory Reset Slot (Revert to pristine Golden Master base)"
        echo
        echo "    [ESC] Return to Main Menu"
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        sk=$(read_key)
        case "$sk" in
            1)
                echo
                if ! read_line_or_esc "Enter source slot name (e.g. golden, slot1)"; then continue; fi
                src_slot=$(echo "$INPUT_VAL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_')
                if ! read_line_or_esc "Enter new destination slot name (e.g. slot2)"; then continue; fi
                dst_slot=$(echo "$INPUT_VAL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_')
                [ -z "$dst_slot" ] && continue

                dst_file="${SLOTS_DIR}/${dst_slot}.qcow2"
                if [ -f "$dst_file" ]; then
                    if ! verify_captcha_prompt "OVERWRITE EXISTING SLOT $dst_slot"; then
                        echo "[-] Clone aborted."
                        sleep 1
                        continue
                    fi
                fi

                echo "[*] Cloning $src_slot -> $dst_slot..."
                if [ "$src_slot" = "golden" ]; then
                    qemu-img create -f qcow2 -b "$GOLDEN_PATH" -F raw "$dst_file"
                else
                    src_file="${SLOTS_DIR}/${src_slot}.qcow2"
                    if [ ! -f "$src_file" ]; then
                        echo "[-] Source slot $src_file not found."
                        sleep 1
                        continue
                    fi
                    cp -f "$src_file" "$dst_file"
                fi
                sync
                printf "%b[+] Slot $dst_slot cloned successfully.%b\n" "$C_FG_GREEN" "$C_RESET"
                sleep 1
                ;;
            2)
                echo
                if ! read_line_or_esc "Enter new slot name (e.g. slot3)"; then continue; fi
                nslot=$(echo "$INPUT_VAL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_')
                [ -z "$nslot" ] && continue
                nfile="${SLOTS_DIR}/${nslot}.qcow2"
                echo "[*] Creating slot $nslot backed by Golden Master..."
                qemu-img create -f qcow2 -b "$GOLDEN_PATH" -F raw "$nfile"
                sync
                printf "%b[+] Slot $nslot created successfully.%b\n" "$C_FG_GREEN" "$C_RESET"
                sleep 1
                ;;
            3)
                echo
                if ! read_line_or_esc "Enter slot to factory reset (e.g. slot1)"; then continue; fi
                rslot=$(echo "$INPUT_VAL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_')
                [ -z "$rslot" ] || [ "$rslot" = "golden" ] && continue
                if ! verify_captcha_prompt "RESET SLOT $rslot TO PRISTINE FACTORY STATE"; then
                    echo "[-] Reset cancelled."
                    sleep 1
                    continue
                fi
                target_file="${SLOTS_DIR}/${rslot}.qcow2"
                rm -f "$target_file"
                qemu-img create -f qcow2 -b "$GOLDEN_PATH" -F raw "$target_file"
                sync
                printf "%b[+] Slot $rslot reset to Golden Master.%b\n" "$C_FG_GREEN" "$C_RESET"
                sleep 1
                ;;
            ESC|q|Q)
                break
                ;;
        esac
    done
}

do_vhd_management() {
    while :; do
        clear_screen
        echo "================================================================================"
        printf "%b  VHD MANAGEMENT  ::  Import & Export Microsoft Windows VHD Disks              %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        echo "  [1] Export Slot to Windows VHD on USB Stick"
        echo "  [2] Import Windows VHD from USB Stick to Slot"
        echo
        echo "  [ESC] Return to Main Menu"
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        vk=$(read_key)
        case "$vk" in
            1)
                clear_screen
                echo "--- Export Slot to Windows VHD ---"
                list_available_slots
                echo
                if ! read_line_or_esc "Enter slot to export" "slot1"; then continue; fi
                slot_name=$(echo "$INPUT_VAL" | tr 'A-Z' 'a-z')
                slot_file="${SLOTS_DIR}/${slot_name}.qcow2"
                if [ "$slot_name" = "golden" ]; then
                    slot_file="$GOLDEN_PATH"
                elif [ ! -f "$slot_file" ]; then
                    echo "[-] Slot $slot_name does not exist."
                    sleep 1
                    continue
                fi

                if ! select_usb_partition; then continue; fi
                umount /mnt/usb 2>/dev/null || true
                if ! mount -t vfat "$SELECTED_USB" /mnt/usb; then
                    echo "[-] Failed to mount $SELECTED_USB."
                    sleep 1
                    continue
                fi

                def_name="${slot_name}_export.vhd"
                if ! read_line_or_esc "Enter output VHD filename" "$def_name"; then
                    umount /mnt/usb 2>/dev/null; continue
                fi
                vhd_name="$INPUT_VAL"
                case "$vhd_name" in *.vhd|*.VHD) ;; *) vhd_name="${vhd_name}.vhd" ;; esac
                target_path="/mnt/usb/${vhd_name}"

                echo "[*] Converting $slot_name to $target_path (Windows VPC VHD)..."
                if [ "$slot_name" = "golden" ]; then
                    qemu-img convert -f raw -O vpc -o subformat=dynamic "$slot_file" "$target_path"
                else
                    qemu-img convert -f qcow2 -O vpc -o subformat=dynamic "$slot_file" "$target_path"
                fi
                rc=$?
                sync
                umount /mnt/usb 2>/dev/null || true
                if [ $rc -eq 0 ]; then
                    echo
                    printf "%b[+] EXPORT SUCCESSFUL: %s%b\n" "$C_FG_GREEN" "$vhd_name" "$C_RESET"
                    echo "    You can now mount this VHD directly in Windows File Explorer!"
                else
                    echo "[-] Export failed (code $rc)."
                fi
                printf "Press any key to continue..."
                read_key >/dev/null
                ;;
            2)
                clear_screen
                echo "--- Import Windows VHD from USB Stick ---"
                if ! select_usb_partition; then continue; fi
                umount /mnt/usb 2>/dev/null || true
                if ! mount -t vfat "$SELECTED_USB" /mnt/usb; then
                    echo "[-] Failed to mount $SELECTED_USB."
                    sleep 1
                    continue
                fi

                vhds=$(find /mnt/usb -maxdepth 2 -iname "*.vhd" 2>/dev/null)
                if [ -z "$vhds" ]; then
                    echo "[-] No .VHD files found on $SELECTED_USB."
                    umount /mnt/usb 2>/dev/null || true
                    printf "Press any key to continue..."
                    read_key >/dev/null
                    continue
                fi

                echo "Available VHD files on USB:"
                i=1
                echo "$vhds" | while IFS= read -r v; do
                    vsz=$(ls -lh "$v" | awk '{print $5}')
                    echo "  [$i] $(basename "$v") ($vsz)"
                    i=$((i+1))
                done

                if ! read_line_or_esc "Select VHD number to import"; then
                    umount /mnt/usb 2>/dev/null; continue
                fi
                selected_vhd=$(echo "$vhds" | sed -n "${INPUT_VAL}p")
                if [ -z "$selected_vhd" ] || [ ! -f "$selected_vhd" ]; then
                    echo "[-] Invalid selection."
                    umount /mnt/usb 2>/dev/null || true
                    sleep 1
                    continue
                fi

                if ! read_line_or_esc "Enter target slot name (e.g. slot2)" "slot2"; then
                    umount /mnt/usb 2>/dev/null; continue
                fi
                target_slot=$(echo "$INPUT_VAL" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_')
                [ -z "$target_slot" ] && { umount /mnt/usb 2>/dev/null; continue; }

                target_file="${SLOTS_DIR}/${target_slot}.qcow2"
                if [ -f "$target_file" ]; then
                    if ! verify_captcha_prompt "OVERWRITE EXISTING SLOT $target_slot"; then
                        echo "[-] Import cancelled."
                        umount /mnt/usb 2>/dev/null || true
                        sleep 1
                        continue
                    fi
                fi

                echo "[*] Converting $selected_vhd -> $target_file..."
                qemu-img convert -f vpc -O qcow2 "$selected_vhd" "$target_file"
                rc=$?
                sync
                umount /mnt/usb 2>/dev/null || true
                if [ $rc -eq 0 ]; then
                    printf "%b[+] Imported %s into slot %s.%b\n" "$C_FG_GREEN" "$(basename "$selected_vhd")" "$target_slot" "$C_RESET"
                else
                    echo "[-] Import failed (code $rc)."
                fi
                printf "Press any key to continue..."
                read_key >/dev/null
                ;;
            ESC|q|Q)
                break
                ;;
        esac
    done
}

do_p2v_migration() {
    clear_screen
    echo "================================================================================"
    printf "%b  P2V MIGRATION  ::  Rip Physical Disks to Standalone Windows VHD             %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo "  Virtualize an entire legacy PC directly onto a USB drive."
    echo "  The resulting .VHD file can be mounted in Windows or imported into uefiDOS."
    echo
    echo "Available physical disks:"
    pdisks=""
    pcount=0
    for d in /sys/block/sd* /sys/block/nvme*n1; do
        [ -d "$d" ] || continue
        dname=$(basename "$d")
        [ "$dname" = "$BOOT_DISK" ] && continue
        sz_mb=$(( $(cat "$d/size" 2>/dev/null || echo 0) / 2048 ))
        [ "$sz_mb" -gt 0 ] || continue
        mdl=$(cat "$d/device/model" 2>/dev/null | tr -s ' ')
        [ -z "$mdl" ] && mdl="Physical Disk"
        pcount=$((pcount + 1))
        echo "  [$pcount] /dev/${dname} (${sz_mb} MB) - $mdl"
        pdisks="${pdisks}/dev/${dname}\n"
    done

    if [ $pcount -eq 0 ]; then
        echo "[-] No eligible physical drives found (boot disk excluded)."
        printf "Press any key to return..."
        read_key >/dev/null
        return
    fi
    echo
    if ! read_line_or_esc "Select disk number to rip (1-$pcount)"; then return; fi
    src_dev=$(printf "$pdisks" | sed -n "${INPUT_VAL}p")
    if [ -z "$src_dev" ] || [ ! -b "$src_dev" ]; then
        echo "[-] Invalid selection."
        sleep 1
        return
    fi

    if ! select_usb_partition; then return; fi
    umount /mnt/usb 2>/dev/null || true
    if ! mount -t vfat "$SELECTED_USB" /mnt/usb; then
        echo "[-] Failed to mount $SELECTED_USB."
        sleep 1
        return
    fi

    def_vhd="P2V_$(basename "$src_dev").vhd"
    if ! read_line_or_esc "Enter target VHD filename" "$def_vhd"; then
        umount /mnt/usb 2>/dev/null; return
    fi
    target_vhd="/mnt/usb/${INPUT_VAL}"
    case "$target_vhd" in *.vhd|*.VHD) ;; *) target_vhd="${target_vhd}.vhd" ;; esac

    echo
    echo "================================================================================"
    echo "  CONFIRM P2V CONVERSION:"
    echo "    Source Physical Disk : $src_dev (READ-ONLY)"
    echo "    Target Virtual VHD   : $target_vhd"
    echo "================================================================================"
    printf "Begin conversion? [y/N]: "
    read -r go_p2v
    case "$go_p2v" in
        [yY]*)
            echo "[*] Converting $src_dev -> $target_vhd (this may take several minutes)..."
            qemu-img convert -p -f raw -O vpc -o subformat=dynamic "$src_dev" "$target_vhd"
            rc=$?
            sync
            umount /mnt/usb 2>/dev/null || true
            if [ $rc -eq 0 ]; then
                printf "\n%b[+] P2V MIGRATION COMPLETED SUCCESSFULLY!%b\n" "$C_FG_GREEN" "$C_RESET"
            else
                printf "\n%b[-] P2V Migration failed (code %d)%b\n" "$C_FG_RED" "$rc" "$C_RESET"
            fi
            ;;
        *)
            echo "[-] Aborted."
            umount /mnt/usb 2>/dev/null || true
            ;;
    esac
    printf "Press any key to return..."
    read_key >/dev/null
}

do_physical_disk_manager() {
    while :; do
        clear_screen
        echo "================================================================================"
        printf "%b  PHYSICAL DISK PASSTHROUGH  ::  Hardware Whole-Disk Direct Passthrough        %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        echo "  Control which physical drives are passed directly to DOS / diagnostics."
        echo "  Single-Ownership Rule: Drives mapped to letters (C:, D:, E:) cannot be RAW,"
        echo "  and host-mounted disks (Appliance OS / Boot media) are strictly protected."
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

            printf "    [%d] /dev/%-8s (%6d MB)  %-22s %b\n" "$pcount" "$dname" "$sz_mb" "$mdl" "$badge"
            pdisks="${pdisks}${dname} "
        done

        if [ $pcount -eq 0 ]; then
            echo "    (No physical drives detected outside boot media)"
        fi
        echo
        echo "  Enter disk number [1-$pcount] to toggle RAW passthrough on/off."
        echo "  [ESC] or [0] Return to Main Menu"
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        sk=$(read_key)
        case "$sk" in
            ESC|0|q|Q)
                break
                ;;
            [1-9]*)
                sel_num=$(echo "$sk" | tr -cd '0-9')
                if [ -n "$sel_num" ] && [ "$sel_num" -ge 1 ] && [ "$sel_num" -le "$pcount" ]; then
                    sel_dname=$(echo "$pdisks" | awk -v n="$sel_num" '{print $n}')
                    case " $host_disks " in
                        *" $sel_dname "*)
                            echo
                            printf "%b[-] /dev/%s hosts active system mounts and cannot be passed through.%b\n" "$C_FG_RED" "$sel_dname" "$C_RESET"
                            sleep 1.5
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
                        # Toggle OFF
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
                        sleep 1
                    else
                        # Toggle ON: unmap any conflicting drive letter
                        unmap_drive_letters_for_disk "$sel_dname"
                        RAW_ENABLED_DISKS=$(echo "$RAW_ENABLED_DISKS $sel_dname" | xargs)
                        RAW_CONFIGURED=1
                        save_partmap_cfg
                        printf "\n%b[+] /dev/%s enabled for RAW passthrough.%b\n" "$C_FG_GREEN" "$sel_dname" "$C_RESET"
                        sleep 1
                    fi
                fi
                ;;
        esac
    done
}

do_live_media_selector() {
    clear_screen
    echo "================================================================================"
    printf "%b  LIVE MEDIA SELECTOR  ::  Mount Live Tooling / Diagnostic Disk to Drive A:    %b\n" "$C_BLUE_BG" "$C_RESET"
    echo "================================================================================"
    echo "  Transient Injection Mode: The selected image is loaded into RAM (/run) for this"
    echo "  session only. Your physical USB stick and golden defaults remain untouched."
    echo
    if ! select_usb_partition; then return; fi

    umount /mnt/usb 2>/dev/null || true
    if ! mount -t vfat -o ro "$SELECTED_USB" /mnt/usb; then
        echo "[-] Failed to mount $SELECTED_USB."
        sleep 1
        return
    fi

    images=$(find /mnt/usb -maxdepth 3 \( -iname "*.img" -o -iname "*.ima" -o -iname "*.vfd" -o -iname "*.iso" -o -iname "*.vhd" \) 2>/dev/null)
    if [ -z "$images" ]; then
        echo "[-] No disk images (*.img, *.ima, *.iso, *.vhd) found on $SELECTED_USB."
        umount /mnt/usb 2>/dev/null || true
        printf "Press any key to return..."
        read_key >/dev/null
        return
    fi

    echo "Available Disk Images on USB:"
    icount=0
    echo "$images" | while IFS= read -r img; do
        icount=$((icount + 1))
        isz=$(ls -lh "$img" 2>/dev/null | awk '{print $5}')
        echo "  [$icount] $(basename "$img") ($isz)"
    done
    total_imgs=$(echo "$images" | wc -l)
    echo
    if ! read_line_or_esc "Select image number to mount to Drive A: (1-$total_imgs)"; then
        umount /mnt/usb 2>/dev/null
        return
    fi

    sel_img=$(echo "$images" | sed -n "${INPUT_VAL}p")
    if [ -z "$sel_img" ] || [ ! -f "$sel_img" ]; then
        echo "[-] Invalid selection."
        umount /mnt/usb 2>/dev/null
        sleep 1
        return
    fi

    bname=$(basename "$sel_img")
    echo "[*] Staging $bname to RAM (/run/boot_floppy.img)..."
    case "$bname" in
        *.iso|*.ISO)
            cp -f "$sel_img" /run/boot_iso.iso
            echo "$bname (ISO CD-ROM)" > "$LIVE_MEDIA_FLAG"
            ;;
        *)
            cp -f "$sel_img" /run/boot_floppy.img
            echo "$bname" > "$LIVE_MEDIA_FLAG"
            ;;
    esac
    sync
    umount /mnt/usb 2>/dev/null || true

    echo
    printf "%b[+] Live media mounted to Drive A: [ %s ] (Session-only)%b\n" "$C_FG_GREEN" "$bname" "$C_RESET"
    sleep 1.5
}

do_advanced_tools() {
    while :; do
        clear_screen
        echo "================================================================================"
        printf "%b  ADVANCED TOOLS & UTILITIES                                                    %b\n" "$C_BLUE_BG" "$C_RESET"
        echo "================================================================================"
        echo "  [1] P2V Migration (Rip Physical Disks to Standalone Windows VHD)"
        echo "  [2] VHD Management (Export / Import Microsoft VHD Images)"
        echo
        echo "  [ESC] or [0] Return to Main Menu"
        echo "--------------------------------------------------------------------------------"
        printf "  Selection > "
        ak=$(read_key)
        case "$ak" in
            1) do_p2v_migration ;;
            2) do_vhd_management ;;
            ESC|0|q|Q) break ;;
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

get_drive_a_label() {
    if [ -f "$LIVE_MEDIA_FLAG" ]; then
        cat "$LIVE_MEDIA_FLAG"
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
parse_partmap_cfg "$PARTMAP_FILE"

while :; do
    clear_screen
    # Header Banner
    echo "================================================================================"
    printf "%b  uefiDOS INDUSTRIAL APPLIANCE  ::  MAINTENANCE & ROUTER CONTROL               %b\n" "$C_BLUE_BG" "$C_RESET"
    printf "%b  System: %-21s ::  Kernel: %-25s     %b\n" "$C_BLUE_BG" "$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "x86_64")" "$(uname -r)" "$C_RESET"
    echo "================================================================================"

    # Live Media badge
    live_media_label=$(get_drive_a_label)

    # Active Drive Status
    echo "  ACTIVE DRIVE ROUTING & HARDWARE MAPPINGS"
    echo "  ----------------------------------------------------------------------------"
    printf "  Drive A: %-38s %b %b\n" "[ $live_media_label ]" "$(get_mode_badge temp)" "${C_FG_CYAN}[BOOTABLE]${C_RESET}"
    printf "  Drive B: %-38s %b %b\n" "[ CONTROL VOLUME (b_control.img) ]" "$(get_mode_badge ro)" "${C_FG_CYAN}[SYSTEM]${C_RESET}"

    # Drive C
    if [ -n "$DRIVE_C_SLOT" ]; then
        c_desc="[ ${DRIVE_C_SLOT} ]"
        printf "  Drive C: %-38s %b %b\n" "$c_desc" "$(get_mode_badge "${DRIVE_C_MODE:-temp}")" "${C_FG_GREEN}[ACTIVE]${C_RESET}"
    else
        printf "  Drive C: %-38s %b %b\n" "[ -- UNMAPPED -- ]" "$(get_mode_badge unmapped)" "${C_FG_GRAY}[OFFLINE]${C_RESET}"
    fi

    # Drive D
    if [ -n "$DRIVE_D_SLOT" ]; then
        d_desc="[ ${DRIVE_D_SLOT} ]"
        printf "  Drive D: %-38s %b %b\n" "$d_desc" "$(get_mode_badge "${DRIVE_D_MODE:-rw}")" "${C_FG_GREEN}[ACTIVE]${C_RESET}"
    else
        printf "  Drive D: %-38s %b %b\n" "[ -- UNMAPPED -- ]" "$(get_mode_badge unmapped)" "${C_FG_GRAY}[OFFLINE]${C_RESET}"
    fi

    # Drive E
    if [ -n "$DRIVE_E_SLOT" ]; then
        e_desc="[ ${DRIVE_E_SLOT} ]"
        printf "  Drive E: %-38s %b %b\n" "$e_desc" "$(get_mode_badge "${DRIVE_E_MODE:-ro}")" "${C_FG_GREEN}[ACTIVE]${C_RESET}"
    else
        printf "  Drive E: %-38s %b %b\n" "[ -- UNMAPPED -- ]" "$(get_mode_badge unmapped)" "${C_FG_GRAY}[OFFLINE]${C_RESET}"
    fi

    # Disks passthrough
    target_disks=$(get_target_disks_summary)
    case "$target_disks" in
        "("*|"")
            raw_badge="${C_FG_GRAY}[OFFLINE]${C_RESET}"
            ;;
        *)
            raw_badge="${C_FG_CYAN}[RAW PASSTHRU]${C_RESET}"
            ;;
    esac
    printf "  Disks:   %-38s %b\n" "[ $(echo "$target_disks" | cut -c1-45) ]" "$raw_badge"

    # Maintenance shell banner
    if [ -f "$MAINT_FLAG" ]; then
        echo "  ----------------------------------------------------------------------------"
        printf "  %b*** MAINTENANCE SHELL ACTIVE: AUTOEXEC BYPASSED -> CLEAN A:\> PROMPT ***%b\n" "$C_FG_YELLOW" "$C_RESET"
    fi
    echo "  ----------------------------------------------------------------------------"

    echo "  STORAGE & HARDWARE ROUTING"
    printf "    %b[1]%b Map Drive Letters (C:, D:, E: -> Physical Partitions, RAM, VHD)\n" "$C_FG_YELLOW" "$C_RESET"
    printf "    %b[2]%b Unmap a Drive (Clear C:, D:, or E:)\n" "$C_FG_YELLOW" "$C_RESET"
    printf "    %b[3]%b Physical Disk Passthrough (Toggle Whole-Disk RAW)\n" "$C_FG_YELLOW" "$C_RESET"
    echo
    echo "  LIVE MEDIA & TOOLING"
    printf "    %b[A]%b Live Media Selector (Mount USB .IMG / .ISO / .VHD to Drive A:)\n" "$C_FG_CYAN" "$C_RESET"
    if [ -f "$MAINT_FLAG" ]; then
        printf "    %b[M]%b Maintenance Shell Mode: %b[ENABLED - Drops to A:\>]%b\n" "$C_FG_CYAN" "$C_RESET" "$C_FG_GREEN" "$C_RESET"
    else
        printf "    %b[M]%b Maintenance Shell Mode: %b[DISABLED - Normal Boot]%b\n" "$C_FG_CYAN" "$C_RESET" "$C_FG_GRAY" "$C_RESET"
    fi
    echo
    echo "  SYSTEM & UTILITIES"
    printf "    %b[T]%b Advanced Tools (P2V Migration, VHD Utilities)\n" "$C_FG_YELLOW" "$C_RESET"
    printf "    %b[B]%b Boot DOS Runtime               %b[S]%b Hypervisor Shell\n" "$C_FG_GREEN" "$C_RESET" "$C_FG_YELLOW" "$C_RESET"
    printf "    %b[R]%b Reboot System                  %b[P]%b Power Off\n" "$C_FG_YELLOW" "$C_RESET" "$C_FG_RED" "$C_RESET"
    echo "================================================================================"
    printf "  %b[ESC] Abort / Return without saving changes%b\n" "$C_FG_GRAY" "$C_RESET"
    echo "================================================================================"
    printf "  Selection > "

    opt=$(read_key)

    case "$opt" in
        1) do_route_drives ;;
        2) do_unmap_drive ;;
        3) do_physical_disk_manager ;;
        [Tt]*) do_advanced_tools ;;
        [Aa]*) do_live_media_selector ;;
        [Mm]*) do_toggle_maintenance_shell ;;
        [Bb]*)
            echo
            printf "%b[*] Exiting Edit Mode -> Preparing to boot DOS Runtime...%b\n" "$C_FG_GREEN" "$C_RESET"
            rm -f "${ESP_DIR}/EDITMODE.FLG" 2>/dev/null || true
            mount -o remount,ro "$ESP_DIR" 2>/dev/null || true
            sync
            break
            ;;
        [Ss]*)
            echo
            echo "[*] Launching hypervisor shell (type 'exit' to return to menu)..."
            setsid cttyhack sh 2>/dev/null || sh
            ;;
        [Rr]*)
            sync; reboot -f
            ;;
        [Pp]*)
            sync; poweroff -f
            ;;
        ESC|q|Q)
            # Re-read configuration from disk to discard any uncommitted in-memory changes
            parse_partmap_cfg "$PARTMAP_FILE"
            ;;
        *)
            # Refresh dashboard in place
            ;;
    esac
done

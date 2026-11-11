#!/usr/bin/env python3
"""
src/slot_router.py - uefiDOS Dynamic Drive & Partition Router

Parses PARTMAP.CFG / DOS.CFG and constructs QEMU drive and device parameters
for multi-drive routing across physical partitions (/dev/sdXN, /dev/nvmeXnYpZ),
standalone virtual disk images (.VHD / .IMG), and ephemeral 64 MB RAM disks,
with per-drive access modes (rw, ro, temp).
"""

import os
import random
import string
from dataclasses import dataclass, field
from typing import Dict, List, Tuple

VALID_MODES = ("rw", "ro", "temp")
CAPTCHA_CHARS = "".join(c for c in string.ascii_uppercase + string.digits if c not in "0O1IL")


@dataclass
class SlotDriveMapping:
    drive_letter: str         # "c", "d", "e"
    slot_name: str            # "/dev/sda1", "/mnt/usb/DISK.VHD", "ram", etc.
    mode: str = "temp"        # "rw", "ro", "temp"
    description: str = ""


@dataclass
class SlotRouterConfig:
    enabled: bool = False
    mappings: Dict[str, SlotDriveMapping] = field(default_factory=dict)
    raw_disks: List[str] = field(default_factory=list)
    raw_configured: bool = False
    controller_mode: str = "a"


def format_size_mb(size_mb: int) -> str:
    """Formats a size in MiB into MB, GB, or TB."""
    if size_mb <= 0:
        return "0 MB"
    if size_mb >= 1048576:
        return f"{size_mb / 1048576:.2f} TB"
    if size_mb >= 10240:
        return f"{size_mb / 1024:.1f} GB"
    if size_mb >= 1024:
        return f"{size_mb / 1024:.2f} GB"
    return f"{size_mb} MB"


def _normalize_controller_mode(val: str) -> str:
    """Normalizes controller_mode / bus_mode config values to 'a', 'b', or 'c'."""
    v = val.strip().lower()
    if v in ("c", "ahci"):
        return "c"
    if v == "b":
        return "b"
    if v in ("a", "ide"):
        return "a"
    return ""


def get_parent_disk(dev_path: str) -> str:
    """
    Resolves the parent disk name from a partition or device path.
    e.g. /dev/sda1 -> sda, /dev/nvme0n1p2 -> nvme0n1, /dev/sdb -> sdb, sda -> sda
    """
    import re
    base = os.path.basename(dev_path).strip().lower()
    if not base:
        return ""
    m_nvme = re.match(r"^(nvme\d+n\d+|mmcblk\d+)p\d+$", base)
    if m_nvme:
        return m_nvme.group(1)
    m_sd = re.match(r"^([a-z]+)\d+$", base)
    if m_sd:
        return m_sd.group(1)
    return base


def deconflict_storage_mappings(
    mappings: Dict[str, SlotDriveMapping],
    raw_disks: List[str],
) -> Tuple[Dict[str, SlotDriveMapping], List[str]]:
    """
    Enforces the single-ownership invariant:
    If a partition or disk is mapped to a drive letter, its parent is excluded from raw_disks.
    Returns (updated_mappings, updated_raw_disks).
    """
    mapped_parents = set()
    for _, mapping in mappings.items():
        slot = mapping.slot_name.strip()
        if slot.startswith(("/dev/", "sd", "nvme", "vd", "hd", "mmcblk")):
            pdisk = get_parent_disk(slot)
            if pdisk:
                mapped_parents.add(pdisk)

    updated_raw = []
    seen = set()
    for d in raw_disks:
        pdisk = get_parent_disk(d)
        if pdisk and pdisk not in mapped_parents and pdisk not in seen:
            seen.add(pdisk)
            updated_raw.append(pdisk)
    return mappings, updated_raw


def generate_captcha(length: int = 5) -> str:
    """Generates a high-clarity 5-character randomized alphanumeric verification code."""
    return "".join(random.choice(CAPTCHA_CHARS) for _ in range(length))


def parse_slot_string(spec: str) -> Tuple[str, str]:
    """
    Parses a drive target specification string like '/dev/sda1:temp',
    '/mnt/usb/TOOLS.VHD:rw', or 'ram:temp'.
    Returns (target_spec, mode). Defaults to 'temp' if mode is omitted or invalid.
    """
    parts = spec.strip().split(":", 1)
    target = parts[0].strip()
    mode = parts[1].strip().lower() if len(parts) > 1 else "temp"
    if mode not in VALID_MODES:
        mode = "temp"
    return target, mode


def parse_partmap_cfg(cfg_path: str) -> SlotRouterConfig:
    """Parses PARTMAP.CFG or lines from DOS.CFG to construct SlotRouterConfig."""
    config = SlotRouterConfig()
    if not os.path.exists(cfg_path):
        return config

    current_section = ""
    with open(cfg_path, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith(";"):
                continue

            if line.startswith("[") and line.endswith("]"):
                current_section = line[1:-1].strip().lower()
                continue

            if "=" in line:
                key, val = [x.strip() for x in line.split("=", 1)]
                key_lower = key.lower()

                if current_section == "system":
                    if key_lower in ("enable_slots", "router_mode"):
                        config.enabled = val.lower() in ("true", "1", "yes", "routed", "custom", "slots")
                    elif key_lower in ("controller_mode", "bus_mode"):
                        norm_bus = _normalize_controller_mode(val)
                        if norm_bus:
                            config.controller_mode = norm_bus
                    elif key_lower in ("raw_disks", "enabled", "enabled_disks"):
                        config.raw_configured = True
                        disks = [d.strip() for d in val.replace(",", " ").split() if d.strip()]
                        config.raw_disks.extend(disks)

                elif current_section == "raw_disks":
                    if key_lower in ("enabled", "enabled_disks", "raw_disks"):
                        config.raw_configured = True
                        disks = [d.strip() for d in val.replace(",", " ").split() if d.strip()]
                        config.raw_disks.extend(disks)

                elif current_section.startswith("drive_"):
                    drv_letter = current_section.split("_")[1]
                    if drv_letter not in config.mappings:
                        config.mappings[drv_letter] = SlotDriveMapping(drive_letter=drv_letter, slot_name="")
                    if key_lower in ("slot", "target"):
                        config.mappings[drv_letter].slot_name = val
                    elif key_lower == "mode":
                        config.mappings[drv_letter].mode = val.lower() if val.lower() in VALID_MODES else "temp"
                    elif key_lower == "description":
                        config.mappings[drv_letter].description = val

                elif not current_section:
                    if key_lower in ("controller_mode", "bus_mode"):
                        norm_bus = _normalize_controller_mode(val)
                        if norm_bus:
                            config.controller_mode = norm_bus
                    elif key_lower.startswith("drive_"):
                        drv_letter = key_lower.split("_")[1]
                        target, mode = parse_slot_string(val)
                        if target:
                            config.enabled = True
                            config.mappings[drv_letter] = SlotDriveMapping(
                                drive_letter=drv_letter,
                                slot_name=target,
                                mode=mode,
                            )

    config.mappings = {k: v for k, v in config.mappings.items() if v.slot_name.strip()}
    config.mappings, config.raw_disks = deconflict_storage_mappings(config.mappings, config.raw_disks)
    return config


def build_qemu_slot_drive_args(config: SlotRouterConfig) -> List[str]:
    """
    Generates QEMU command line arguments (-drive and -device) for all mapped drives.
    Preserves exact drive ordering (C: first, D: second, E: third).
    """
    if not config.enabled or not config.mappings:
        return []

    args = []
    sorted_letters = sorted(config.mappings.keys())
    bus_mode = _normalize_controller_mode(config.controller_mode)

    for idx, letter in enumerate(sorted_letters):
        mapping = config.mappings[letter]
        raw_slot = mapping.slot_name.strip()
        slot_name = raw_slot.lower()
        mode = mapping.mode.lower()

        # Determine target backing file and QEMU format
        if slot_name == "ram":
            target_file = f"/run/ramdisk_{letter.lower()}.img"
            file_format = "raw"
            mode = "temp"
        elif slot_name.endswith(".vhd"):
            target_file = raw_slot
            file_format = "vpc"
        elif slot_name.endswith((".img", ".ima", ".raw", ".vfd")):
            target_file = raw_slot
            file_format = "raw"
        elif slot_name.startswith(("/dev/", "dev/", "sd", "nvme", "vd", "hd", "mmcblk")):
            if raw_slot.startswith("/dev/"):
                dev_name = raw_slot
            elif raw_slot.startswith("dev/"):
                dev_name = f"/{raw_slot}"
            else:
                dev_name = f"/dev/{raw_slot}"
            target_file = dev_name
            file_format = "raw"
        elif raw_slot.startswith("/"):
            target_file = raw_slot
            file_format = "raw"
        else:
            continue

        target_file = target_file.replace("\\", "/")
        drive_id = f"slotdrive_{letter}"

        # Construct -drive parameters based on mode
        if mode == "temp":
            # Stateless RAM overlay: target is untouched, writes go into ephemeral RAM overlay
            drive_opt = f"file={target_file},format={file_format},if=none,id={drive_id},snapshot=on,cache=unsafe"
        elif mode == "ro":
            # Read-only safe attachment: QEMU ide-hd rejects readonly=on, so snapshot=on opens backing media O_RDONLY
            drive_opt = f"file={target_file},format={file_format},if=none,id={drive_id},snapshot=on"
        else:  # "rw"
            # Persistent read-write
            drive_opt = f"file={target_file},format={file_format},if=none,id={drive_id},cache=none,aio=native"

        if bus_mode == "c":
            pos = f"bus=ahci.{idx}"
        elif idx == 0:
            pos = "bus=ide.0,unit=0"   # Primary Master (C:)
        elif idx == 1:
            pos = "bus=ide.0,unit=1"   # Primary Slave (D:)
        elif idx == 2:
            pos = "bus=ide.1,unit=1"   # Secondary Slave (E: - ide.1 unit 0 is CD-ROM)
        else:
            pos = f"bus=ide.{idx // 2},unit={idx % 2}"

        args.extend([
            "-drive", drive_opt,
            "-device", f"ide-hd,{pos},drive={drive_id},serial=SLOT_{letter.upper()}"
        ])

    return args


def build_vhd_create_command(raw_source: str, target_vhd: str) -> List[str]:
    """Generates qemu-img command to convert an MBR+FAT raw disk image into a dynamic Microsoft VHD."""
    return [
        "qemu-img", "convert",
        "-f", "raw",
        "-O", "vpc",
        "-o", "subformat=dynamic",
        raw_source,
        target_vhd,
    ]


def build_p2v_command(source_block_device: str, target_vhd: str) -> List[str]:
    """Generates qemu-img command to rip a physical raw disk or partition (/dev/sdX, /dev/nvme0n1) into a dynamic Windows VHD."""
    return [
        "qemu-img", "convert",
        "-f", "raw",
        "-O", "vpc",
        "-o", "subformat=dynamic",
        source_block_device,
        target_vhd,
    ]


def unmap_drive(config: SlotRouterConfig, drive_letter: str) -> bool:
    """Removes a drive mapping (c, d, e, etc.) from configuration."""
    letter = drive_letter.strip().lower()
    if letter in config.mappings:
        del config.mappings[letter]
        return True
    return False

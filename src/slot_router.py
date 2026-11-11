#!/usr/bin/env python3
"""
src/slot_router.py - uefiDOS Dynamic Slot & Drive Router

Parses PARTMAP.CFG / DOS.CFG and constructs QEMU drive and device parameters
for multi-drive slot configurations (e.g., C=slot1:temp, D=slot3:rw, E=golden:ro),
and provides VHD export/import utilities for Windows-based workflows.
"""

import os
import sys
import subprocess
import random
import string
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

VALID_MODES = ("rw", "ro", "temp")
CAPTCHA_CHARS = "".join(c for c in string.ascii_uppercase + string.digits if c not in "0O1IL")

@dataclass
class SlotDriveMapping:
    drive_letter: str         # "c", "d", "e", etc.
    slot_name: str            # "slot1", "slot2", "golden", etc.
    mode: str = "temp"        # "rw", "ro", "temp"
    description: str = ""

@dataclass
class SlotRouterConfig:
    enabled: bool = False
    golden_base_path: str = "/mnt/data/golden_base.raw"
    slots_dir: str = "/mnt/data/slots"
    mappings: Dict[str, SlotDriveMapping] = field(default_factory=dict)
    raw_disks: List[str] = field(default_factory=list)
    raw_configured: bool = False

def get_parent_disk(dev_path: str) -> str:
    """
    Resolves the parent disk name from a partition or device path.
    e.g. /dev/sda1 -> sda, /dev/nvme0n1p2 -> nvme0n1, /dev/sdb -> sdb, sda -> sda
    """
    import re
    base = os.path.basename(dev_path).strip().lower()
    if not base:
        return ""
    # NVMe or MMC pattern: nvme0n1p1 -> nvme0n1, mmcblk0p1 -> mmcblk0
    m_nvme = re.match(r"^(nvme\d+n\d+|mmcblk\d+)p\d+$", base)
    if m_nvme:
        return m_nvme.group(1)
    # Standard sd/vd/hd partition pattern: sda1 -> sda, vda2 -> vda, hda3 -> hda
    m_sd = re.match(r"^([a-z]+)\d+$", base)
    if m_sd:
        return m_sd.group(1)
    return base

def deconflict_storage_mappings(mappings: Dict[str, SlotDriveMapping], raw_disks: List[str]) -> Tuple[Dict[str, SlotDriveMapping], List[str]]:
    """
    Enforces the single-ownership invariant:
    If a partition or disk is mapped to a drive letter, its parent is excluded from raw_disks.
    Returns (updated_mappings, updated_raw_disks).
    """
    mapped_parents = set()
    for letter, mapping in mappings.items():
        slot = mapping.slot_name.strip()
        if slot.startswith(("/dev/", "sd", "nvme", "vd", "hd")):
            pdisk = get_parent_disk(slot)
            if pdisk:
                mapped_parents.add(pdisk)

    # Filter raw disks so no parent of a mapped partition is in raw_disks
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
    Parses a slot specification string like 'slot1:temp' or 'slot3:rw' or 'golden:ro'.
    Returns (slot_name, mode). Defaults to 'temp' if mode is omitted.
    """
    parts = spec.strip().split(":")
    slot_name = parts[0].strip()
    mode = parts[1].strip().lower() if len(parts) > 1 else "temp"
    if mode not in VALID_MODES:
        mode = "temp"
    return slot_name, mode

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
                        config.enabled = (val.lower() in ("true", "1", "yes", "slots"))
                    elif key_lower == "golden_base":
                        config.golden_base_path = val
                    elif key_lower == "slots_dir":
                        config.slots_dir = val
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
                    if key_lower == "slot":
                        config.mappings[drv_letter].slot_name = val
                    elif key_lower == "mode":
                        config.mappings[drv_letter].mode = val.lower() if val.lower() in VALID_MODES else "temp"
                    elif key_lower == "description":
                        config.mappings[drv_letter].description = val

                elif not current_section:
                    # Flat key=val in DOS.CFG, e.g. drive_c=slot1:temp
                    if key_lower.startswith("drive_"):
                        drv_letter = key_lower.split("_")[1]
                        slot_name, mode = parse_slot_string(val)
                        if slot_name:
                            config.enabled = True
                            config.mappings[drv_letter] = SlotDriveMapping(
                                drive_letter=drv_letter,
                                slot_name=slot_name,
                                mode=mode
                            )

    config.mappings = {k: v for k, v in config.mappings.items() if v.slot_name.strip()}
    config.mappings, config.raw_disks = deconflict_storage_mappings(config.mappings, config.raw_disks)
    return config

def build_qemu_slot_drive_args(config: SlotRouterConfig) -> List[str]:
    """
    Generates QEMU command line arguments (-drive and -device) for all mapped slots.
    Preserves exact drive ordering (C: first, D: second, E: third).
    """
    if not config.enabled or not config.mappings:
        return []

    args = []
    # Sort drive letters: c, d, e, etc.
    sorted_letters = sorted(config.mappings.keys())

    for idx, letter in enumerate(sorted_letters):
        mapping = config.mappings[letter]
        slot_name = mapping.slot_name.lower()
        mode = mapping.mode.lower()

        # Determine target backing file
        if slot_name in ("golden", "base", "golden_base", "ram"):
            target_file = config.golden_base_path
            file_format = "raw"
        elif slot_name.startswith("/dev/") or slot_name.startswith("dev/") or slot_name.startswith("sd") or slot_name.startswith("nvme") or slot_name.startswith("vd"):
            dev_name = slot_name if slot_name.startswith("/dev/") else f"/dev/{slot_name.lstrip('dev/')}"
            target_file = dev_name
            file_format = "raw"
        else:
            target_file = os.path.join(config.slots_dir, f"{slot_name}.qcow2")
            file_format = "qcow2"

        target_file = target_file.replace("\\", "/")

        drive_id = f"slotdrive_{letter}"

        # Construct -drive parameters based on mode
        if mode == "temp":
            # Stateless RAM overlay: base is untouched, writes go into ephemeral RAM overlay
            drive_opt = f"file={target_file},format={file_format},if=none,id={drive_id},snapshot=on,cache=unsafe"
        elif mode == "ro":
            # Strict read-only
            drive_opt = f"file={target_file},format={file_format},if=none,id={drive_id},readonly=on"
        else: # "rw"
            # Persistent read-write
            drive_opt = f"file={target_file},format={file_format},if=none,id={drive_id},cache=none,aio=native"

        # Determine IDE bus/unit positioning
        if idx == 0:
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

def build_vhd_export_command(source_qcow2: str, target_vhd: str) -> List[str]:
    """Generates qemu-img command to convert a slot to native Microsoft VHD format."""
    return [
        "qemu-img", "convert",
        "-O", "vpc",
        "-o", "subformat=dynamic",
        source_qcow2,
        target_vhd
    ]

def build_vhd_import_command(source_vhd: str, target_qcow2: str, backing_base: Optional[str] = None) -> List[str]:
    """Generates qemu-img command to convert a Windows VHD into a QCOW2 slot."""
    cmd = [
        "qemu-img", "convert",
        "-O", "qcow2"
    ]
    if backing_base:
        cmd.extend(["-B", backing_base, "-o", "backing_fmt=raw"])
    cmd.extend([source_vhd, target_qcow2])
    return cmd

def build_p2v_command(source_block_device: str, target_vhd: str) -> List[str]:
    """Generates qemu-img command to rip a physical raw disk (/dev/sdX, /dev/nvme0n1) into a Windows VHD."""
    return [
        "qemu-img", "convert",
        "-f", "raw",
        "-O", "vpc",
        "-o", "subformat=dynamic",
        source_block_device,
        target_vhd
    ]

def unmap_drive(config: SlotRouterConfig, drive_letter: str) -> bool:
    """Removes a drive mapping (c, d, e, etc.) from configuration."""
    letter = drive_letter.strip().lower()
    if letter in config.mappings:
        del config.mappings[letter]
        return True
    return False


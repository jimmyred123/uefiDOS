#!/usr/bin/env python3
"""
uefiDOS Storage Discovery & Mapping Engine

Scans available block devices (physical NVMe, SATA/IDE disks, and virtual disks),
determines controller mappings, and generates QEMU drive attachment parameters
to expose them as virtual AHCI or passed-through SATA endpoints to DOS runtimes.
"""

import os
import sys
import json
import re
from dataclasses import dataclass, field
from typing import List, Optional, Dict

@dataclass
class BlockDevice:
    device_path: str
    name: str
    size_bytes: int
    device_type: str  # "nvme", "sata", "ide", "virtio", "scsi", "unknown"
    pci_slot: Optional[str] = None
    serial: Optional[str] = None
    model: Optional[str] = None
    read_only: bool = False

@dataclass
class StorageMappingConfig:
    target_mode: str = "virtual_ahci"  # "virtual_ahci" or "vfio_passthrough"
    ahci_controller_id: str = "ahci0"
    enable_write: bool = True
    cache_mode: str = "none"
    aio_mode: str = "native"
    target_devices: List[BlockDevice] = field(default_factory=list)

def classify_device_type(device_name: str) -> str:
    """Classifies device type based on Linux kernel device naming conventions."""
    base_name = os.path.basename(device_name)
    if base_name.startswith("nvme"):
        return "nvme"
    elif base_name.startswith("sd"):
        return "sata"
    elif base_name.startswith("hd"):
        return "ide"
    elif base_name.startswith("vd"):
        return "virtio"
    elif base_name.startswith("loop"):
        return "loop"
    return "unknown"

def parse_sysfs_size(size_str: str) -> int:
    """Converts a sysfs 512-byte sector count string to total bytes."""
    try:
        sectors = int(size_str.strip())
        return sectors * 512
    except (ValueError, TypeError):
        return 0

def build_qemu_ahci_args(config: StorageMappingConfig) -> List[str]:
    """
    Builds the command-line parameters for QEMU to instantiate an ICH9 AHCI
    controller and attach target devices to its ports.
    """
    args = [
        "-device", f"ich9-ahci,id={config.ahci_controller_id}"
    ]

    port_index = 0
    for dev in config.target_devices:
        drive_id = f"disk{port_index}"
        
        # Build drive backend parameter
        drive_param_parts = [
            f"file={dev.device_path}",
            "format=raw",
            "if=none",
            f"id={drive_id}",
            f"cache={config.cache_mode}",
            f"aio={config.aio_mode}"
        ]
        if not config.enable_write or dev.read_only:
            drive_param_parts.append("readonly=on")

        args.extend(["-drive", ",".join(drive_param_parts)])

        # Attach to AHCI port
        args.extend([
            "-device",
            f"ide-hd,bus={config.ahci_controller_id}.{port_index},drive={drive_id}"
        ])
        port_index += 1

    return args

def build_qemu_iso_args(iso_path: str) -> List[str]:
    """Generates QEMU arguments for mounting bootable ISO media."""
    return [
        "-cdrom", iso_path,
        "-boot", "order=d"
    ]

def build_qemu_fda_args(fda_path: str) -> List[str]:
    """Generates QEMU arguments for booting directly from a FreeDOS floppy image."""
    return [
        "-fda", fda_path,
        "-boot", "order=a"
    ]

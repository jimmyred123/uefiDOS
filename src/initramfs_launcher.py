#!/usr/bin/env python3
"""
uefiDOS Boot Target & Storage Auto-Discovery Daemon

Runs inside the micro-Linux initramfs before starting the VMM.
Discovers all physical disks, filters out the boot USB/medium,
and allows automated or interactive selection of target disks to map to AHCI.
"""

import os
import sys
import argparse
from typing import List

# Ensure parent directory is in sys.path when invoked directly as a script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PARENT_DIR = os.path.dirname(SCRIPT_DIR)
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)
if PARENT_DIR not in sys.path:
    sys.path.insert(0, PARENT_DIR)

try:
    from src.storage_mapper import BlockDevice, StorageMappingConfig, classify_device_type, parse_sysfs_size
    from src.qemu_config import QemuRunnerConfig, generate_qemu_command
except ImportError:
    from storage_mapper import BlockDevice, StorageMappingConfig, classify_device_type, parse_sysfs_size
    from qemu_config import QemuRunnerConfig, generate_qemu_command

def scan_linux_block_devices(sys_block_path: str = "/sys/block") -> List[BlockDevice]:
    """Scans /sys/block to enumerate all available disk devices."""
    devices = []
    if not os.path.exists(sys_block_path):
        return devices

    for dev_name in os.listdir(sys_block_path):
        # Ignore partitions (like loop0p1, nvme0n1p1, sda1) and ram disks
        if dev_name.startswith("ram") or dev_name.startswith("zram"):
            continue

        dev_sys_path = os.path.join(sys_block_path, dev_name)
        dev_node = f"/dev/{dev_name}"

        # Read size
        size_file = os.path.join(dev_sys_path, "size")
        size_bytes = 0
        if os.path.exists(size_file):
            try:
                with open(size_file, "r") as f:
                    size_bytes = parse_sysfs_size(f.read())
            except Exception:
                pass

        # Read read-only flag
        ro_file = os.path.join(dev_sys_path, "ro")
        read_only = False
        if os.path.exists(ro_file):
            try:
                with open(ro_file, "r") as f:
                    read_only = (f.read().strip() == "1")
            except Exception:
                pass

        # Classify
        dev_type = classify_device_type(dev_name)

        devices.append(BlockDevice(
            device_path=dev_node,
            name=dev_name,
            size_bytes=size_bytes,
            device_type=dev_type,
            read_only=read_only
        ))

    return devices

def main():
    parser = argparse.ArgumentParser(description="uefiDOS Storage Mapper & Launcher")
    parser.add_argument("--iso", default=None, help="Path to bootable ISO")
    parser.add_argument("--floppy", default=None, help="Path to bootable FreeDOS floppy image (.img)")
    parser.add_argument("--disk", action="append", default=[], help="Specific disk(s) to attach to AHCI (e.g. /dev/nvme0n1)")
    parser.add_argument("--auto-all", action="store_true", help="Automatically attach all detected non-removable disks")
    parser.add_argument("--dry-run", action="store_true", help="Print QEMU command and exit without launching")
    parser.add_argument("--headless", action="store_true", help="Launch QEMU in headless mode")
    parser.add_argument("--enable-kvm", action="store_true", help="Enable hardware acceleration (/dev/kvm)")
    parser.add_argument("--pci", action="append", default=[], help="Specific PCI device BDF to pass through via VFIO (e.g. 01:00.0)")
    args = parser.parse_args()

    selected_devices = []

    if args.disk:
        for d in args.disk:
            selected_devices.append(BlockDevice(
                device_path=d,
                name=os.path.basename(d),
                size_bytes=0,
                device_type=classify_device_type(d)
            ))
    elif args.auto_all:
        all_devs = scan_linux_block_devices()
        # Filter out loop and read-only
        selected_devices = [d for d in all_devs if d.device_type in ("nvme", "sata", "ide", "virtio") and not d.read_only]

    floppy_path = args.floppy
    # If no floppy specified, check if embedded payload module is available
    if not floppy_path and (not args.iso or not os.path.exists(args.iso)):
        base_gz = os.path.join(os.path.dirname(__file__), "freedos_base.img.gz")
        base_img = os.path.join(os.path.dirname(__file__), "freedos_base.img")
        if os.path.exists(base_gz):
            import gzip
            extracted_floppy = "/tmp/freedos_base.img"
            with open(base_gz, "rb") as f_in, open(extracted_floppy, "wb") as f_out:
                f_out.write(gzip.decompress(f_in.read()))
            floppy_path = extracted_floppy
        elif os.path.exists(base_img):
            floppy_path = base_img

    storage_cfg = StorageMappingConfig(target_devices=selected_devices)
    qemu_cfg = QemuRunnerConfig(
        storage_config=storage_cfg,
        iso_path=args.iso,
        fda_path=floppy_path,
        pci_passthrough=args.pci,
        headless=args.headless,
        enable_kvm=args.enable_kvm
    )

    cmd = generate_qemu_command(qemu_cfg)

    if args.dry_run:
        print(" ".join(cmd))
        sys.exit(0)

    # In production initramfs, exec into QEMU
    print(f"[*] Executing VMM with {len(selected_devices)} mapped AHCI disks...")
    os.execvp(cmd[0], cmd)

if __name__ == "__main__":
    main()

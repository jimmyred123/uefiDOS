#!/usr/bin/env python3
"""
uefiDOS Bootable Hybrid ISO Generator

Generates a VMware / QEMU / Rufus / Ventoy compliant bootable UEFI ISO.

Key UEFI ISO Requirements:
1. Standard ISO9660 filesystem with joliet/rock-ridge.
2. An EFI System Partition (FAT image) embedded as an El Torito boot catalog entry
   with platform ID 0xEF (EFI).
3. The EFI partition MUST contain /EFI/BOOT/BOOTX64.EFI.
4. An optional /startup.nsh in the EFI partition root to ensure immediate execution
   under UEFI Shell environments.

Usage:
    python make_bootable_iso.py --source-dir build/iso_root --output build/uefiDOS.iso --shim-efi path/to/UefiDosShim.efi
"""

import os
import sys
import argparse
import subprocess
import shutil

def generate_efi_fat_partition(source_dir: str, efi_fat_path: str, shim_efi: str, size_mb: int = None):
    """Creates a valid FAT32 image containing essential EFI bootloaders and UKI for El Torito boot."""
    source_boot_dir = os.path.join(source_dir, "EFI", "BOOT")
    essential_efi_files = ["BOOTX64.EFI", "freedos.efi", "csmwrapx64.efi", "csmwrap.ini", "grubx64.efi"]
    
    if size_mb is None:
        total_source_bytes = 0
        if os.path.exists(source_boot_dir):
            for fname in os.listdir(source_boot_dir):
                if fname in essential_efi_files:
                    total_source_bytes += os.path.getsize(os.path.join(source_boot_dir, fname))
        if shim_efi and os.path.exists(shim_efi):
            total_source_bytes += os.path.getsize(shim_efi)
        # Add 32MB safety margin and round up to next 16MB boundary, min 64MB for strictly compliant FAT32 (>65525 clusters)
        calculated_mb = (total_source_bytes // (1024 * 1024)) + 32
        size_mb = max(64, ((calculated_mb + 15) // 16) * 16)

    total_bytes = size_mb * 1024 * 1024
    print(f"[*] Allocating {size_mb} MB FAT32 EFI boot partition: {efi_fat_path}...")
    with open(efi_fat_path, "wb") as f:
        f.truncate(total_bytes)

    # Format FAT32 using mkfs.vfat (with fallback to mformat)
    try:
        subprocess.run(["mkfs.vfat", "-F", "32", "-n", "DOS_ESP", efi_fat_path], check=True)
    except Exception:
        subprocess.run(["mformat", "-i", efi_fat_path, "-F", "-v", "DOS_ESP", "::"], check=True)

    subprocess.run(["mmd", "-i", efi_fat_path, "::/EFI"], check=True)
    subprocess.run(["mmd", "-i", efi_fat_path, "::/EFI/BOOT"], check=True)

    if os.path.exists(source_boot_dir):
        for fname in os.listdir(source_boot_dir):
            if fname in essential_efi_files:
                src_file = os.path.join(source_boot_dir, fname)
                print(f"[*] Copying into ESP boot catalog: {fname} -> ::/EFI/BOOT/{fname}")
                subprocess.run(["mcopy", "-o", "-i", efi_fat_path, src_file, f"::/EFI/BOOT/{fname}"], check=True)

    if shim_efi and os.path.exists(shim_efi):
        print(f"[*] Installing {shim_efi} -> ::/EFI/BOOT/BOOTX64.EFI inside ESP image")
        subprocess.run(["mcopy", "-o", "-i", efi_fat_path, shim_efi, "::/EFI/BOOT/BOOTX64.EFI"], check=True)

    # Create startup.nsh fallback
    startup_nsh = "startup.nsh"
    with open(startup_nsh, "w") as f:
        f.write("@echo -off\r\nfs0:\r\n\\EFI\\BOOT\\BOOTX64.EFI\r\n")
    subprocess.run(["mcopy", "-o", "-i", efi_fat_path, startup_nsh, "::/startup.nsh"], check=True)
    if os.path.exists(startup_nsh):
        os.remove(startup_nsh)

def build_hybrid_iso(source_dir: str, output_iso: str, efi_fat_rel_path: str, floppy_rel_path: str = None):
    """
    Invokes xorriso to generate a pure-UEFI compliant El Torito hybrid ISO
    specifying both:
    1. Legacy BIOS / SeaBIOS El Torito floppy boot catalog entry (1.44M floppy)
    2. EFI platform ID (0xEF) boot catalog entry for modern UEFI firmware.
    """
    cmd = [
        "xorriso",
        "-as", "mkisofs",
        "-r", "-V", "FREEDOS_UEFI",
        "-J", "-joliet-long"
    ]

    # If legacy bootable floppy image is present, set as initial El Torito entry:
    if floppy_rel_path and os.path.exists(os.path.join(source_dir, floppy_rel_path)):
        print(f"[*] Adding El Torito legacy floppy boot entry: {floppy_rel_path}")
        cmd.extend([
            "-b", floppy_rel_path,
            "-c", "boot.catalog"
        ])

    # El Torito EFI Boot entry:
    cmd.extend([
        "-eltorito-alt-boot",
        "-e", efi_fat_rel_path,
        "-no-emul-boot",
        "-isohybrid-gpt-basdat",
        "-o", output_iso,
        source_dir
    ])
    print(f"[*] Executing xorriso:\n    {' '.join(cmd)}")
    subprocess.run(cmd, check=True)
    print(f"[+] Successfully generated bootable UEFI ISO: {output_iso}")

def main():
    parser = argparse.ArgumentParser(description="Build bootable UEFI Hybrid ISO")
    parser.add_argument("--source-dir", required=True, help="Directory containing ISO contents")
    parser.add_argument("--output", default="build/uefiDOS.iso", help="Target ISO path")
    parser.add_argument("--shim-efi", default=None, help="Path to UefiDosShim.efi / BOOTX64.EFI")
    args = parser.parse_args()

    os.makedirs(args.source_dir, exist_ok=True)
    
    # 1. Ensure /EFI/BOOT/BOOTX64.EFI also exists on the ISO9660 filesystem tree itself
    iso_efi_boot = os.path.join(args.source_dir, "EFI", "BOOT")
    os.makedirs(iso_efi_boot, exist_ok=True)
    if args.shim_efi and os.path.exists(args.shim_efi):
        dest_shim = os.path.join(iso_efi_boot, "BOOTX64.EFI")
        if os.path.abspath(args.shim_efi) != os.path.abspath(dest_shim):
            shutil.copy2(args.shim_efi, dest_shim)

    # 2. Check for legacy floppy image
    floppy_rel = None
    for cand in ["freedos_floppy.img", "dos_floppy.img", "floppy.img", "boot_floppy.img"]:
        if os.path.exists(os.path.join(args.source_dir, cand)):
            floppy_rel = cand
            break

    # 3. Build embedded EFI FAT partition (efiboot.img)
    efi_fat_name = "efiboot.img"
    efi_fat_full_path = os.path.join(args.source_dir, efi_fat_name)
    generate_efi_fat_partition(args.source_dir, efi_fat_full_path, args.shim_efi)

    # 4. Build Hybrid ISO with dual legacy El Torito + UEFI boot catalog
    build_hybrid_iso(args.source_dir, args.output, efi_fat_name, floppy_rel)

if __name__ == "__main__":
    main()

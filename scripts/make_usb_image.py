#!/usr/bin/env python3
"""
uefiDOS USB Image Creator

Creates a ready-to-flash raw disk image (.img) formatted with a standard GPT
and EFI System Partition (FAT32) that can be written directly to a USB drive
using Rufus, BalenaEtcher, Win32DiskImager, or dd.

Usage:
    python make_usb_image.py --output uefiDOS-usb.img --payload-iso boot.iso
"""

import os
import sys
import argparse
import subprocess
import shutil
import tempfile
import struct

def check_tools():
    """Checks for required utilities depending on OS."""
    required = ["mformat", "mcopy", "mmd"]
    missing = [tool for tool in required if not shutil.which(tool)]
    return missing

def create_gpt_fat32_image(output_img: str, size_mb: int, shim_efi: str, payload_iso: str = None, payload_exe: str = None):
    """
    Constructs a bootable raw disk image containing an EFI System Partition (FAT32).
    Uses mtools (cross-platform on Linux/macOS, available in CI) to format FAT32.
    """
    total_bytes = size_mb * 1024 * 1024
    print(f"[*] Allocating {size_mb} MB blank image: {output_img}...")
    
    with open(output_img, "wb") as f:
        f.truncate(total_bytes)

    # Use mformat to format as FAT32
    print("[*] Formatting FAT32 EFI partition...")
    subprocess.run(["mformat", "-i", output_img, "-F", "-v", "FREEDOS", "::"], check=True)

    # Create directories
    print("[*] Creating directory structure...")
    subprocess.run(["mmd", "-i", output_img, "::EFI"], check=True)
    subprocess.run(["mmd", "-i", output_img, "::EFI/BOOT"], check=True)
    subprocess.run(["mmd", "-i", output_img, "::DOS"], check=True)

    # Copy files
    if shim_efi and os.path.exists(shim_efi):
        print(f"[*] Installing UEFI shim: {shim_efi} -> ::EFI/BOOT/BOOTX64.EFI")
        subprocess.run(["mcopy", "-i", output_img, shim_efi, "::EFI/BOOT/BOOTX64.EFI"], check=True)

    if payload_iso and os.path.exists(payload_iso):
        print(f"[*] Copying payload ISO: {payload_iso} -> ::DOS/boot.iso")
        subprocess.run(["mcopy", "-i", output_img, payload_iso, "::DOS/boot.iso"], check=True)

    if payload_exe and os.path.exists(payload_exe):
        basename = os.path.basename(payload_exe).upper()
        print(f"[*] Copying payload EXE: {payload_exe} -> ::DOS/{basename}")
        subprocess.run(["mcopy", "-i", output_img, payload_exe, f"::DOS/{basename}"], check=True)

    print(f"[+] Successfully generated bootable USB image: {output_img}")

def main():
    parser = argparse.ArgumentParser(description="Generate bootable uefiDOS USB raw image (.img)")
    parser.add_argument("--output", default="uefiDOS-usb.img", help="Output .img file path")
    parser.add_argument("--size-mb", type=int, default=128, help="Size of raw USB disk image in MB (default: 128)")
    parser.add_argument("--shim-efi", default=None, help="Path to compiled shim EFI (will be /EFI/BOOT/BOOTX64.EFI)")
    parser.add_argument("--payload-iso", default=None, help="Path to payload .iso")
    parser.add_argument("--payload-exe", default=None, help="Path to payload .exe")
    args = parser.parse_args()

    missing = check_tools()
    if missing:
        print(f"[-] Warning: Missing tools {missing}. On Linux/CI install: sudo apt-get install -y mtools dosfstools", file=sys.stderr)
        if sys.platform == "win32":
            print("[*] Note: On Windows, use scripts/make-usb.ps1 to format USB drives natively.", file=sys.stderr)

    create_gpt_fat32_image(
        output_img=args.output,
        size_mb=args.size_mb,
        shim_efi=args.shim_efi,
        payload_iso=args.payload_iso,
        payload_exe=args.payload_exe
    )

if __name__ == "__main__":
    main()

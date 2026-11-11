#!/usr/bin/env python3
"""
Generates the dedicated Drive B: Control Floppy Image (1.44MB FAT12)
containing:
- README.TXT
- EDIT.BAT
- SLOTS.BAT
- PARTMAP.CFG
"""

import os
import sys
import gzip
from inject_payload import inject_file_fat12

def create_control_floppy(output_path: str = "src/b_control.img"):
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base_gz = os.path.join(repo_root, "src", "freedos_base.img.gz")
    base_raw = os.path.join(repo_root, "src", "freedos_base.img")
    
    if os.path.exists(base_gz):
        with open(base_gz, "rb") as f:
            floppy = bytearray(gzip.decompress(f.read()))
    elif os.path.exists(base_raw):
        with open(base_raw, "rb") as f:
            floppy = bytearray(f.read())
    else:
        raise FileNotFoundError("freedos_base.img(.gz) not found in src/")

    # Set unique Volume Label for Drive B: so it is never confused with the boot floppy
    floppy[43:54] = b"UEFI_CTRL_B"
    root_off = 19 * 512
    for i in range(0, 14 * 512, 32):
        if floppy[root_off + i + 11] == 0x08:
            floppy[root_off + i : root_off + i + 11] = b"UEFI_CTRL_B"

    # Clear non-system files from root directory of control floppy
    # Keep KERNEL.SYS / COMMAND.COM if present so B: is also bootable if selected
    dos_ctrl_dir = os.path.join(repo_root, "src", "dos_control")
    reboot_com_path = os.path.join(dos_ctrl_dir, "REBOOT.COM")
    if not os.path.exists(reboot_com_path):
        with open(reboot_com_path, "wb") as f:
            f.write(bytes([
                0xB4, 0x0D, 0xCD, 0x21, 0xB0, 0xFE, 0xE6, 0x64,
                0xB9, 0xFF, 0xFF, 0xE2, 0xFE, 0xBA, 0xF9, 0x0C,
                0xB0, 0x06, 0xEE, 0xB9, 0xFF, 0xFF, 0xE2, 0xFE,
                0xB8, 0x40, 0x00, 0x8E, 0xD8, 0xC7, 0x06, 0x72,
                0x00, 0x34, 0x12, 0xEA, 0x00, 0x00, 0xFF, 0xFF
            ]))

    files_to_inject = [
        ("AUTOEXEC.BAT", os.path.join(dos_ctrl_dir, "AUTOEXEC.BAT")),
        ("README.TXT", os.path.join(dos_ctrl_dir, "README.TXT")),
        ("EDIT.BAT", os.path.join(dos_ctrl_dir, "EDIT.BAT")),
        ("ROUTER.BAT", os.path.join(dos_ctrl_dir, "ROUTER.BAT")),
        ("DRIVES.BAT", os.path.join(dos_ctrl_dir, "DRIVES.BAT")),
        ("SLOTS.BAT", os.path.join(dos_ctrl_dir, "SLOTS.BAT")),
        ("REBOOT.COM", os.path.join(dos_ctrl_dir, "REBOOT.COM")),
        ("PARTMAP.CFG", os.path.join(repo_root, "PARTMAP.CFG")),
    ]

    for dest_name, src_path in files_to_inject:
        if os.path.exists(src_path):
            with open(src_path, "rb") as f:
                content = f.read()
            inject_file_fat12(floppy, dest_name, content)
            print(f"[+] Injected {dest_name} ({len(content)} bytes) into control floppy")
        else:
            print(f"[!] Warning: {src_path} not found")

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(floppy)
    print(f"[+] Successfully created Drive B: control floppy: {output_path} ({len(floppy)} bytes)")

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "src/b_control.img"
    create_control_floppy(out)

#!/usr/bin/env python3
"""
scripts/build_clean_freedos_base.py

Downloads the official FreeDOS 1.3 distribution from ibiblio.org,
extracts the official, untouched FreeDOS 1.3 KERNEL.SYS and COMMAND.COM,
and constructs a 100% clean, vendor-neutral 1.44MB FAT12 boot floppy:
  src/freedos_base.img.gz
"""

import urllib.request
import zipfile
import io
import os
import gzip
from inject_payload import inject_file_fat12

FREEDOS_FLOPPY_ZIP_URL = "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.3/official/FD13-FloppyEdition.zip"

def extract_file_from_fat12(img: bytearray, filename_83: bytes) -> bytes:
    root_off = 19 * 512
    entry = None
    for i in range(0, 14 * 512, 32):
        if img[root_off + i : root_off + i + 11] == filename_83:
            entry = img[root_off + i : root_off + i + 32]
            break
    if not entry:
        # Search anywhere in image for subdirectory entry
        pos = img.find(filename_83)
        if pos != -1:
            entry = img[pos : pos + 32]
        else:
            raise FileNotFoundError(f"File {filename_83} not found in floppy image")

    cluster = int.from_bytes(entry[26:28], "little")
    size = int.from_bytes(entry[28:32], "little")

    fat = img[1 * 512 : 10 * 512]
    def get_fat(c):
        idx = (c * 3) // 2
        val = int.from_bytes(fat[idx:idx+2], "little")
        return (val >> 4) if (c & 1) else (val & 0xFFF)

    chunks = []
    curr = cluster
    while 1 < curr < 0xFF8:
        sec = 33 + curr - 2
        chunks.append(img[sec * 512 : (sec + 1) * 512])
        curr = get_fat(curr)

    return b"".join(chunks)[:size]

def main():
    print(f"[*] Downloading official FreeDOS 1.3 Floppy Edition from:\n    {FREEDOS_FLOPPY_ZIP_URL}")
    req = urllib.request.Request(FREEDOS_FLOPPY_ZIP_URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req) as resp:
        zip_bytes = resp.read()
    print(f"[+] Downloaded {len(zip_bytes):,} bytes.")

    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        boot_img = bytearray(z.read("144m/x86BOOT.img"))

    print(f"[+] Extracted official 144m/x86BOOT.img ({len(boot_img):,} bytes).")

    # Extract official KERNEL.SYS and COMMAND.COM
    kernel_sys = extract_file_from_fat12(boot_img, b"KERNEL  SYS")
    print(f"[+] Extracted official FreeDOS KERNEL.SYS ({len(kernel_sys):,} bytes).")

    command_com = extract_file_from_fat12(boot_img, b"COMMAND COM")
    print(f"[+] Extracted official FreeDOS COMMAND.COM ({len(command_com):,} bytes).")

    # Create a fresh 1.44MB FAT12 floppy using the official boot sector
    clean_floppy = bytearray(1474560)
    # Copy boot sector (sector 0)
    clean_floppy[0:512] = boot_img[0:512]
    # Set volume label in boot sector
    clean_floppy[43:54] = b"FREEDOS13  "

    # Initialize FAT1 and FAT2
    clean_floppy[1 * 512 : 1 * 512 + 3] = b"\xF0\xFF\xFF"
    clean_floppy[10 * 512 : 10 * 512 + 3] = b"\xF0\xFF\xFF"

    # Set root directory volume label (sector 19)
    vol_entry = bytearray(32)
    vol_entry[0:11] = b"FREEDOS13  "
    vol_entry[11] = 0x08  # Volume label attribute
    clean_floppy[19 * 512 : 19 * 512 + 32] = vol_entry

    # Inject official KERNEL.SYS first (so it occupies cluster 2 directly)
    inject_file_fat12(clean_floppy, "KERNEL.SYS", kernel_sys)
    print(f"[+] Injected KERNEL.SYS ({len(kernel_sys)} bytes) at cluster 2")

    # Inject official COMMAND.COM
    inject_file_fat12(clean_floppy, "COMMAND.COM", command_com)
    print(f"[+] Injected COMMAND.COM ({len(command_com)} bytes)")

    # Clean, vendor-neutral CONFIG.SYS
    config_sys = (
        "BUFFERS=20\r\n"
        "FILES=40\r\n"
        "DOS=HIGH,UMB\r\n"
        "LASTDRIVE=Z\r\n"
        "SHELL=COMMAND.COM /E:1024 /P\r\n"
    ).encode("ascii")
    inject_file_fat12(clean_floppy, "CONFIG.SYS", config_sys)
    print(f"[+] Injected CONFIG.SYS ({len(config_sys)} bytes)")

    # Clean, vendor-neutral AUTOEXEC.BAT
    autoexec_bat = (
        "@echo off\r\n"
        "path a:\\;b:\\;c:\\\r\n"
        "set blaster=a220 i5 d1 h5 t6\r\n"
        "cls\r\n"
        "echo ------------------------------------------------------------\r\n"
        "echo   uefiDOS Open Industrial Appliance  ::  FreeDOS 1.3\r\n"
        "echo ------------------------------------------------------------\r\n"
        "if exist b:\\readme.txt type b:\\readme.txt\r\n"
        "if exist a:\\autoexec.bat echo [Autoexec ready]\r\n"
    ).encode("ascii")
    inject_file_fat12(clean_floppy, "AUTOEXEC.BAT", autoexec_bat)
    print(f"[+] Injected AUTOEXEC.BAT ({len(autoexec_bat)} bytes)")

    # Verify absence of any commercial/vendor strings
    for banned in [b"Gibson", b"gibson", b"GRC", b"SpinRite", b"spinrite"]:
        if banned in clean_floppy:
            raise ValueError(f"CRITICAL ERROR: Banned vendor string {banned} found in clean floppy!")

    print("[+] String verification passed: ZERO commercial or proprietary strings present.")

    # Write uncompressed src/freedos_base.img and compressed src/freedos_base.img.gz
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_img = os.path.join(repo_root, "src", "freedos_base.img")
    out_gz = os.path.join(repo_root, "src", "freedos_base.img.gz")

    with open(out_img, "wb") as f:
        f.write(clean_floppy)
    print(f"[+] Written uncompressed base: {out_img} ({len(clean_floppy):,} bytes)")

    with gzip.open(out_gz, "wb", compresslevel=9) as f:
        f.write(clean_floppy)
    print(f"[+] Written compressed base: {out_gz} ({os.path.getsize(out_gz):,} bytes)")

if __name__ == "__main__":
    main()

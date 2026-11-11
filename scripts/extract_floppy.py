#!/usr/bin/env python3
"""
scripts/extract_floppy.py - Prepares bootable FreeDOS floppy & ISO media for build.

Sources checked in order:
  1. Payload executable (*.exe) in repo root (user provided)
  2. Payload ISO (*.iso) in repo root (user provided)
  3. Clean open-source FreeDOS base image: src/freedos_base.img(.gz)

If a user-provided payload binary is present, it is injected into the base FreeDOS image.
If no payload binary is present, the clean base FreeDOS image is staged.
"""
import sys
import os
import glob
import gzip

target = sys.argv[1] if len(sys.argv) > 1 else "freedos_boot.iso"
os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
exe_source = None
iso_source = None
for f in glob.glob(os.path.join(REPO_ROOT, "*.exe")) + glob.glob(os.path.join(REPO_ROOT, "*.EXE")):
    exe_source = f
    break
for f in glob.glob(os.path.join(REPO_ROOT, "*.iso")) + glob.glob(os.path.join(REPO_ROOT, "*.ISO")):
    if not os.path.basename(f).lower().startswith("uefi"):
        iso_source = f
        break

base_img = os.path.join(REPO_ROOT, "src", "freedos_base.img")
base_gz = os.path.join(REPO_ROOT, "src", "freedos_base.img.gz")

def load_base_floppy() -> bytearray:
    if os.path.exists(base_img):
        with open(base_img, "rb") as f:
            return bytearray(f.read())
    elif os.path.exists(base_gz):
        with open(base_gz, "rb") as f:
            return bytearray(gzip.decompress(f.read()))
    raise FileNotFoundError("Base FreeDOS floppy image (src/freedos_base.img) not found!")

# Helper functions for FAT12 injection
def get_fat_entry(fat, n):
    idx = (n * 3) // 2
    val = int.from_bytes(fat[idx:idx+2], "little")
    return (val >> 4) if (n & 1) else (val & 0xFFF)

def set_fat_entry(fat, n, val):
    idx = (n * 3) // 2
    orig = int.from_bytes(fat[idx:idx+2], "little")
    if n & 1:
        new_val = (orig & 0x000F) | ((val & 0xFFF) << 4)
    else:
        new_val = (orig & 0xF000) | (val & 0xFFF)
    fat[idx:idx+2] = new_val.to_bytes(2, "little")

def inject_fat12(floppy, filename, file_data):
    root_off = 19 * 512
    free_root = None
    base, ext = (filename.split(".") + [""])[:2]
    name83 = f"{base[:8]:<8}{ext[:3]:<3}".upper().encode("ascii")
    for i in range(0, 14 * 512, 32):
        if floppy[root_off + i : root_off + i + 11] == name83:
            free_root = root_off + i
            break
        if free_root is None and floppy[root_off + i] in (0x00, 0xE5):
            free_root = root_off + i
    if free_root is None:
        raise RuntimeError("Floppy root directory full")
    num_clusters = (len(file_data) + 511) // 512
    fat1 = floppy[1 * 512 : 10 * 512]
    fat2 = floppy[10 * 512 : 19 * 512]
    allocated = []
    for c in range(2, 2880):
        if get_fat_entry(fat1, c) == 0:
            allocated.append(c)
            if len(allocated) == num_clusters:
                break
    for i, c in enumerate(allocated):
        nxt = allocated[i + 1] if i + 1 < len(allocated) else 0xFFF
        set_fat_entry(fat1, c, nxt)
        set_fat_entry(fat2, c, nxt)
        chunk = file_data[i * 512 : (i + 1) * 512]
        if len(chunk) < 512:
            chunk = chunk + b"\x00" * (512 - len(chunk))
        sec = 33 + c - 2
        floppy[sec * 512 : (sec + 1) * 512] = chunk
    floppy[1 * 512 : 10 * 512] = fat1
    floppy[10 * 512 : 19 * 512] = fat2
    dir_entry = bytearray(32)
    dir_entry[0:11] = name83
    dir_entry[11] = 0x20
    dir_entry[26:28] = allocated[0].to_bytes(2, "little")
    dir_entry[28:32] = len(file_data).to_bytes(4, "little")
    floppy[free_root : free_root + 32] = dir_entry

floppy = load_base_floppy()

payload_exe_bytes = None
payload_name = "PAYLOAD.EXE"
if exe_source and os.path.exists(exe_source):
    payload_name = os.path.basename(exe_source).upper()
    print(f"[*] Found local executable payload at {exe_source}")
    with open(exe_source, "rb") as f:
        payload_exe_bytes = f.read()
elif iso_source and os.path.exists(iso_source):
    print(f"[*] Found local ISO payload at {iso_source}")
    with open(iso_source, "rb") as f:
        iso_data = f.read()
    off = 27 * 2048
    if len(iso_data) >= off + 1474560:
        f_tmp = iso_data[off : off + 1474560]
        # read first executable from root dir
        r_off = 19 * 512
        for i in range(0, 14 * 512, 32):
            if f_tmp[r_off + i + 8 : r_off + i + 11] == b"EXE":
                name83 = f_tmp[r_off + i : r_off + i + 8].decode("ascii", errors="ignore").strip()
                payload_name = f"{name83}.EXE"
                start_c = int.from_bytes(f_tmp[r_off + i + 26 : r_off + i + 28], "little")
                sz = int.from_bytes(f_tmp[r_off + i + 28 : r_off + i + 32], "little")
                fat1 = bytearray(f_tmp[1*512:10*512])
                c = start_c
                out = bytearray()
                while c >= 2 and c < 0xFF8:
                    sec = 33 + c - 2
                    out.extend(f_tmp[sec*512 : (sec+1)*512])
                    c = get_fat_entry(fat1, c)
                payload_exe_bytes = bytes(out[:sz])
                break

if payload_exe_bytes:
    print(f"[+] Injecting {payload_name} ({len(payload_exe_bytes):,} bytes) into FreeDOS base...")
    inject_fat12(floppy, payload_name, payload_exe_bytes)
else:
    print("[*] No local payload provided. Using redistributable FreeDOS base.")
    print("    Users can inject payloads post-build using scripts/inject_payload.py")

data = bytes(floppy)
with open(target, "wb") as f:
    f.write(data)

print(f"[+] Prepared {target} ({len(data)} bytes)")

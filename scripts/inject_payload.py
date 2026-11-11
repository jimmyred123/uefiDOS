#!/usr/bin/env python3
r"""
scripts/inject_payload.py - Universal Payload Injector for UEFI FreeDOS Boot Media

Injects any user-supplied DOS executable (e.g. utilities, diagnostics, games)
or raw floppy into:
  1. Standalone 1.44MB FreeDOS floppy image (freedos_base.img -> boot_floppy.img)
  2. Bootable hybrid ISO (uefiDOS.iso)
  3. USB disk image (uefiDOS-usb.img)

Usage:
  python scripts/inject_payload.py --payload /path/to/APP.EXE --iso artifacts/uefiDOS.iso
  python scripts/inject_payload.py --payload /path/to/APP.EXE --img artifacts/uefiDOS-usb.img
"""

import sys
import os
import argparse
import gzip
import shutil

def get_fat_entry(fat: bytearray, n: int) -> int:
    idx = (n * 3) // 2
    val = int.from_bytes(fat[idx:idx+2], "little")
    return (val >> 4) if (n & 1) else (val & 0xFFF)

def set_fat_entry(fat: bytearray, n: int, val: int) -> None:
    idx = (n * 3) // 2
    orig = int.from_bytes(fat[idx:idx+2], "little")
    if n & 1:
        new_val = (orig & 0x000F) | ((val & 0xFFF) << 4)
    else:
        new_val = (orig & 0xF000) | (val & 0xFFF)
    fat[idx:idx+2] = new_val.to_bytes(2, "little")

def inject_file_fat12(floppy_img: bytearray, filename: str, file_data: bytes) -> int:
    """Inject a file into a 1.44MB FAT12 floppy image."""
    root_off = 19 * 512
    free_root = None
    
    # 8.3 filename
    base, ext = (filename.split(".") + [""])[:2]
    name83 = f"{base[:8]:<8}{ext[:3]:<3}".upper().encode("ascii")
    
    # Search for existing entry or free entry
    for i in range(0, 14 * 512, 32):
        entry_name = floppy_img[root_off + i : root_off + i + 11]
        if entry_name == name83:
            free_root = root_off + i
            break
        if free_root is None and floppy_img[root_off + i] in (0x00, 0xE5):
            free_root = root_off + i
            
    if free_root is None:
        raise RuntimeError("Floppy root directory is full")
        
    num_clusters = (len(file_data) + 511) // 512
    fat1 = floppy_img[1 * 512 : 10 * 512]
    fat2 = floppy_img[10 * 512 : 19 * 512]
    
    allocated = []
    for c in range(2, 2880):
        if get_fat_entry(fat1, c) == 0:
            allocated.append(c)
            if len(allocated) == num_clusters:
                break
                
    if len(allocated) != num_clusters:
        raise RuntimeError(f"Floppy full: needed {num_clusters} free clusters, found {len(allocated)}")
        
    for i, c in enumerate(allocated):
        nxt = allocated[i + 1] if i + 1 < len(allocated) else 0xFFF
        set_fat_entry(fat1, c, nxt)
        set_fat_entry(fat2, c, nxt)
        chunk = file_data[i * 512 : (i + 1) * 512]
        if len(chunk) < 512:
            chunk = chunk + b"\x00" * (512 - len(chunk))
        sec = 33 + c - 2
        floppy_img[sec * 512 : (sec + 1) * 512] = chunk
        
    floppy_img[1 * 512 : 10 * 512] = fat1
    floppy_img[10 * 512 : 19 * 512] = fat2
    
    dir_entry = bytearray(32)
    dir_entry[0:11] = name83
    dir_entry[11] = 0x20  # Archive attribute
    dir_entry[26:28] = allocated[0].to_bytes(2, "little")
    dir_entry[28:32] = len(file_data).to_bytes(4, "little")
    floppy_img[free_root : free_root + 32] = dir_entry
    return allocated[0]

def extract_exe_from_iso(iso_path: str) -> tuple:
    """Extract first DOS executable from an El Torito bootable ISO."""
    with open(iso_path, "rb") as f:
        data = f.read()
    offset = 27 * 2048
    if len(data) >= offset + 1474560:
        floppy = bytearray(data[offset : offset + 1474560])
        root_off = 19 * 512
        for i in range(0, 14 * 512, 32):
            e = floppy[root_off + i : root_off + i + 32]
            if e[8:11] == b"EXE" and e[0] not in (0x00, 0xE5):
                name = e[:11].decode('ascii', errors='ignore').strip()
                start_c = int.from_bytes(e[26:28], "little")
                size = int.from_bytes(e[28:32], "little")
                fat1 = floppy[1 * 512 : 10 * 512]
                c = start_c
                out = bytearray()
                while c >= 2 and c < 0xFF8:
                    sec = 33 + c - 2
                    out.extend(floppy[sec * 512 : (sec + 1) * 512])
                    c = get_fat_entry(fat1, c)
                return name, bytes(out[:size])
    raise RuntimeError(f"Could not extract DOS executable from {iso_path}")

def get_base_floppy() -> bytearray:
    """Load the pristine FreeDOS base floppy image."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    img_path = os.path.join(repo_root, "src", "freedos_base.img")
    gz_path = os.path.join(repo_root, "src", "freedos_base.img.gz")
    if os.path.exists(img_path):
        with open(img_path, "rb") as f:
            return bytearray(f.read())
    elif os.path.exists(gz_path):
        with open(gz_path, "rb") as f:
            return bytearray(gzip.decompress(f.read()))
    raise FileNotFoundError("freedos_base.img(.gz) not found in src/")

def build_injected_floppy(filename: str, payload_bytes: bytes) -> bytes:
    """Creates a 1.44MB FAT12 floppy with payload injected, or uses payload directly if already a 1.44MB image."""
    if len(payload_bytes) == 1474560 and filename.upper().endswith(('.IMG', '.IMA', '.VFD')):
        return payload_bytes
    base = get_base_floppy()
    inject_file_fat12(base, filename, payload_bytes)
    return bytes(base)

def inject_into_image_file(file_path: str, filename: str, payload_bytes: bytes) -> int:
    """Inject payload file into all 1.44MB FAT12 floppy instances in an ISO or disk image."""
    injected_floppy = build_injected_floppy(filename, payload_bytes)

    with open(file_path, "r+b") as f:
        data = bytearray(f.read())

    signatures = [b"FREEDOS13  ", b"FREEDOS_SR ", b"FD13-BOOT  ", b"FREEDOS    "]
    injected_count = 0

    for sig in signatures:
        pos = 0
        while True:
            p = data.find(sig, pos)
            if p == -1:
                break
            floppy_start = p - (19 * 512)
            if floppy_start >= 0 and floppy_start % 512 == 0 and floppy_start + 1474560 <= len(data):
                candidate = data[floppy_start : floppy_start + 1474560]
                # Never overwrite Drive B: control volume floppy instances
                if b"UEFI_CTRL_B" in candidate or b"DOS_CTRL_B" in candidate:
                    pos = floppy_start + 1474560
                    continue
                if data[floppy_start : floppy_start + 3] == b"\xeb<\x90" or b"FRDOS" in data[floppy_start : floppy_start + 32] or b"FreeDOS" in data[floppy_start : floppy_start + 64]:
                    data[floppy_start : floppy_start + 1474560] = injected_floppy
                    injected_count += 1
                    pos = floppy_start + 1474560
                    continue
            pos = p + 1

    if injected_count > 0:
        with open(file_path, "wb") as f:
            f.write(data)
        print(f"[+] Successfully injected {filename} into {injected_count} floppy instance(s) in {file_path}")
    else:
        print(f"[!] Warning: No matching 1.44MB floppy signatures found in {file_path}")
    return injected_count

def inject_into_zip_file(zip_path: str, filename: str, payload_bytes: bytes) -> int:
    """Inject payload and updated floppy images into a USB extraction ZIP archive."""
    import zipfile
    injected_floppy = build_injected_floppy(filename, payload_bytes)
    temp_zip = zip_path + ".tmp"
    injected_count = 0
    signatures = [b"FREEDOS13  ", b"FREEDOS_SR ", b"FD13-BOOT  ", b"FREEDOS    "]
    with zipfile.ZipFile(zip_path, "r") as zin:
        with zipfile.ZipFile(temp_zip, "w", compression=zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                fname = item.filename
                if fname.lower().endswith((".img", ".ima", ".vfd")) and "efiboot" not in fname.lower() and "initramfs" not in fname.lower() and "b_control" not in fname.lower():
                    zout.writestr(item, injected_floppy)
                    injected_count += 1
                    print(f"[*] Replaced floppy image in zip: {fname}")
                elif fname.lower().endswith(".iso"):
                    iso_data = bytearray(zin.read(item.filename))
                    for sig in signatures:
                        pos = 0
                        while True:
                            p = iso_data.find(sig, pos)
                            if p == -1:
                                break
                            floppy_start = p - (19 * 512)
                            if floppy_start >= 0 and floppy_start % 512 == 0 and floppy_start + 1474560 <= len(iso_data):
                                if iso_data[floppy_start : floppy_start + 3] == b"\xeb<\x90" or b"FRDOS" in iso_data[floppy_start : floppy_start + 32]:
                                    iso_data[floppy_start : floppy_start + 1474560] = injected_floppy
                                    injected_count += 1
                                    pos = floppy_start + 1474560
                                    continue
                            pos = p + 1
                    zout.writestr(item, bytes(iso_data))
                    print(f"[*] Injected floppy instances into embedded ISO in zip: {fname}")
                else:
                    zout.writestr(item, zin.read(item.filename))
            zout.writestr(f"DOS/{filename}", payload_bytes)
            zout.writestr(filename, payload_bytes)
            print(f"[+] Added direct payload {filename} and DOS/{filename} to zip")
    os.replace(temp_zip, zip_path)
    print(f"[+] Successfully updated ZIP archive: {zip_path}")
    return injected_count

def get_plain_and_injected_paths(file_path: str) -> tuple:
    """Computes distinct filenames for pristine baseline and injected copies."""
    dir_name, base_name = os.path.split(file_path)
    stem, ext = os.path.splitext(base_name)
    
    if stem.endswith("-usb"):
        prefix = stem[:-4]
        plain_stem = f"{prefix}-plain-usb"
        injected_stem = f"{prefix}-injected-usb"
    elif stem.endswith("-usb-files"):
        prefix = stem[:-10]
        plain_stem = f"{prefix}-plain-usb-files"
        injected_stem = f"{prefix}-injected-usb-files"
    else:
        plain_stem = f"{stem}-plain"
        injected_stem = f"{stem}-injected"
        
    plain_path = os.path.join(dir_name, f"{plain_stem}{ext}")
    injected_path = os.path.join(dir_name, f"{injected_stem}{ext}")
    return plain_path, injected_path

def prepare_artifact_for_injection(file_path: str, duplicate: bool = True) -> tuple:
    """
    Ensures a pristine -plain copy is preserved before injection.
    If a -plain copy already exists, restores the working file from it first
    to ensure we always inject cleanly without cumulative mutations.
    Returns (plain_path, injected_path).
    """
    plain_path, injected_path = get_plain_and_injected_paths(file_path)
    if not duplicate:
        return plain_path, injected_path

    if os.path.exists(plain_path):
        if os.path.exists(file_path) and os.path.getmtime(file_path) > os.path.getmtime(plain_path) + 2:
            print(f"[*] Newer baseline detected: updating pristine copy {file_path} -> {plain_path}")
            shutil.copy2(file_path, plain_path)
        else:
            print(f"[*] Restoring clean baseline from {plain_path} -> {file_path}")
            shutil.copy2(plain_path, file_path)
    else:
        print(f"[*] Preserving pristine baseline copy: {file_path} -> {plain_path}")
        shutil.copy2(file_path, plain_path)
    return plain_path, injected_path

def finalize_injected_artifact(file_path: str, injected_path: str, duplicate: bool = True):
    """Duplicates the freshly injected artifact to its dedicated -injected name."""
    if not duplicate:
        return
    print(f"[+] Creating dedicated injected artifact: {file_path} -> {injected_path}")
    shutil.copy2(file_path, injected_path)

def main():
    parser = argparse.ArgumentParser(description="Inject payload executable into UEFI DOS boot media.")
    parser.add_argument("--payload", "-p", "--file", "-f", required=True, help="Path to executable (.EXE) or bootable ISO")
    parser.add_argument("--name", "-n", default=None, help="Destination filename on DOS floppy (e.g. APP.EXE)")
    parser.add_argument("--iso", "-i", help="Path to bootable ISO to update in-place")
    parser.add_argument("--img", "-m", help="Path to USB disk image to update in-place")
    parser.add_argument("--zip", "-z", help="Path to USB ZIP archive to update in-place")
    parser.add_argument("--output", "-o", help="Output path for injected 1.44MB floppy image")
    parser.add_argument("--all", "-a", nargs="?", const="artifacts", help="Inject into all media found in directory (default: artifacts/)")
    parser.add_argument("--no-duplicate", action="store_true", help="Do not duplicate artifacts into -plain and -injected copies")
    args = parser.parse_args()

    payload_path = args.payload
    if not os.path.exists(payload_path):
        print(f"[-] Error: File not found: {payload_path}")
        sys.exit(1)

    print(f"[*] Reading payload from: {payload_path}")
    if payload_path.lower().endswith(".iso"):
        detected_name, payload_bytes = extract_exe_from_iso(payload_path)
        dest_name = args.name or detected_name
    else:
        with open(payload_path, "rb") as f:
            payload_bytes = f.read()
        dest_name = args.name or os.path.basename(payload_path).upper()

    print(f"[+] Loaded payload: {dest_name} ({len(payload_bytes):,} bytes)")

    dup = not args.no_duplicate

    if args.all:
        target_dir = args.all
        if not os.path.exists(target_dir):
            os.makedirs(target_dir, exist_ok=True)
        # 1. Output standalone floppy
        base_name = os.path.splitext(dest_name)[0]
        floppy_out = os.path.join(target_dir, f"{base_name}_boot_floppy.img")
        injected_floppy = build_injected_floppy(dest_name, payload_bytes)
        if os.path.abspath(floppy_out) != os.path.abspath(payload_path):
            with open(floppy_out, "wb") as f:
                f.write(injected_floppy)
            print(f"[+] Wrote injected floppy image to: {floppy_out}")

        # 2. In-place ISO injection with duplication
        iso_cand = os.path.join(target_dir, "uefiDOS.iso")
        if os.path.exists(iso_cand):
            _, inj_path = prepare_artifact_for_injection(iso_cand, duplicate=dup)
            inject_into_image_file(iso_cand, dest_name, payload_bytes)
            finalize_injected_artifact(iso_cand, inj_path, duplicate=dup)

        # 3. In-place USB image injection with duplication
        img_cand = os.path.join(target_dir, "uefiDOS-usb.img")
        if os.path.exists(img_cand):
            _, inj_path = prepare_artifact_for_injection(img_cand, duplicate=dup)
            inject_into_image_file(img_cand, dest_name, payload_bytes)
            finalize_injected_artifact(img_cand, inj_path, duplicate=dup)

        # 4. In-place USB ZIP injection with duplication
        zip_cand = os.path.join(target_dir, "uefiDOS-usb-files.zip")
        if os.path.exists(zip_cand):
            _, inj_path = prepare_artifact_for_injection(zip_cand, duplicate=dup)
            inject_into_zip_file(zip_cand, dest_name, payload_bytes)
            finalize_injected_artifact(zip_cand, inj_path, duplicate=dup)
        return

    if args.output:
        injected_floppy = build_injected_floppy(dest_name, payload_bytes)
        with open(args.output, "wb") as f:
            f.write(injected_floppy)
        print(f"[+] Wrote injected floppy image to: {args.output}")

    if args.iso:
        if not os.path.exists(args.iso):
            print(f"[-] Error: ISO not found: {args.iso}")
            sys.exit(1)
        _, inj_path = prepare_artifact_for_injection(args.iso, duplicate=dup)
        inject_into_image_file(args.iso, dest_name, payload_bytes)
        finalize_injected_artifact(args.iso, inj_path, duplicate=dup)

    if args.img:
        if not os.path.exists(args.img):
            print(f"[-] Error: IMG not found: {args.img}")
            sys.exit(1)
        _, inj_path = prepare_artifact_for_injection(args.img, duplicate=dup)
        inject_into_image_file(args.img, dest_name, payload_bytes)
        finalize_injected_artifact(args.img, inj_path, duplicate=dup)

    if args.zip:
        if not os.path.exists(args.zip):
            print(f"[-] Error: ZIP not found: {args.zip}")
            sys.exit(1)
        _, inj_path = prepare_artifact_for_injection(args.zip, duplicate=dup)
        inject_into_zip_file(args.zip, dest_name, payload_bytes)
        finalize_injected_artifact(args.zip, inj_path, duplicate=dup)

    if not args.output and not args.iso and not args.img and not args.zip:
        default_out = "boot_floppy.img"
        injected_floppy = build_injected_floppy(dest_name, payload_bytes)
        with open(default_out, "wb") as f:
            f.write(injected_floppy)
        print(f"[+] Wrote injected floppy image to: {default_out}")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Unit tests for slot_router module and shell storage router engine.
"""

import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from src.slot_router import (
    SlotDriveMapping,
    SlotRouterConfig,
    build_p2v_command,
    build_qemu_slot_drive_args,
    build_vhd_create_command,
    deconflict_storage_mappings,
    format_size_mb,
    generate_captcha,
    get_parent_disk,
    parse_partmap_cfg,
    parse_slot_string,
    unmap_drive,
)


class TestSlotRouter(unittest.TestCase):

    def test_captcha_generation(self):
        code1 = generate_captcha(5)
        code2 = generate_captcha(5)
        self.assertEqual(len(code1), 5)
        self.assertEqual(len(code2), 5)
        for char in "0O1IL":
            self.assertNotIn(char, code1)
            self.assertNotIn(char, code2)

    def test_parse_slot_string(self):
        target, mode = parse_slot_string("/dev/sda1:temp")
        self.assertEqual(target, "/dev/sda1")
        self.assertEqual(mode, "temp")

        target, mode = parse_slot_string("/mnt/usb/DISK.VHD:rw")
        self.assertEqual(target, "/mnt/usb/DISK.VHD")
        self.assertEqual(mode, "rw")

        target, mode = parse_slot_string("/dev/nvme0n1p2:ro")
        self.assertEqual(target, "/dev/nvme0n1p2")
        self.assertEqual(mode, "ro")

        # Default fallback to temp when mode is omitted or invalid
        target, mode = parse_slot_string("ram")
        self.assertEqual(target, "ram")
        self.assertEqual(mode, "temp")

        target, mode = parse_slot_string("/dev/sdb1:invalid_mode")
        self.assertEqual(target, "/dev/sdb1")
        self.assertEqual(mode, "temp")

    def test_parse_partmap_cfg(self):
        content = """
[system]
router_mode = routed
controller_mode = a

[drive_c]
slot = ram
mode = temp
description = Ephemeral RAM Scratch

[drive_d]
slot = /mnt/data/VHDs/TOOLS.VHD
mode = rw
description = Persistent Tools VHD

[drive_e]
target = /dev/sda1
mode = ro
description = Read-Only Physical Reference Partition
"""
        with tempfile.NamedTemporaryFile("w", delete=False) as tf:
            tf.write(content)
            temp_path = tf.name

        try:
            cfg = parse_partmap_cfg(temp_path)
            self.assertTrue(cfg.enabled)
            self.assertEqual(cfg.controller_mode, "a")
            self.assertIn("c", cfg.mappings)
            self.assertIn("d", cfg.mappings)
            self.assertIn("e", cfg.mappings)

            self.assertEqual(cfg.mappings["c"].slot_name, "ram")
            self.assertEqual(cfg.mappings["c"].mode, "temp")

            self.assertEqual(cfg.mappings["d"].slot_name, "/mnt/data/VHDs/TOOLS.VHD")
            self.assertEqual(cfg.mappings["d"].mode, "rw")

            self.assertEqual(cfg.mappings["e"].slot_name, "/dev/sda1")
            self.assertEqual(cfg.mappings["e"].mode, "ro")
        finally:
            if os.path.exists(temp_path):
                os.remove(temp_path)

    def test_flat_dos_cfg_slot_parsing(self):
        content = """
# DOS.CFG flat format
drive_c = /dev/sda1:temp
drive_d = /mnt/data/VHDs/SYSTEM_C.VHD:rw
"""
        with tempfile.NamedTemporaryFile("w", delete=False) as tf:
            tf.write(content)
            temp_path = tf.name

        try:
            cfg = parse_partmap_cfg(temp_path)
            self.assertTrue(cfg.enabled)
            self.assertIn("c", cfg.mappings)
            self.assertIn("d", cfg.mappings)
            self.assertEqual(cfg.mappings["c"].slot_name, "/dev/sda1")
            self.assertEqual(cfg.mappings["c"].mode, "temp")
            self.assertEqual(cfg.mappings["d"].slot_name, "/mnt/data/VHDs/SYSTEM_C.VHD")
            self.assertEqual(cfg.mappings["d"].mode, "rw")
        finally:
            if os.path.exists(temp_path):
                os.remove(temp_path)

    def test_build_qemu_slot_drive_args(self):
        cfg = SlotRouterConfig(
            enabled=True,
            mappings={
                "c": SlotDriveMapping(drive_letter="c", slot_name="ram", mode="temp"),
                "d": SlotDriveMapping(drive_letter="d", slot_name="/mnt/usb/TOOLS.VHD", mode="rw"),
                "e": SlotDriveMapping(drive_letter="e", slot_name="/dev/nvme0n1p2", mode="ro"),
            },
        )
        args = build_qemu_slot_drive_args(cfg)

        # Drive C: ram temp (snapshot=on, cache=unsafe)
        self.assertIn("-drive", args)
        c_drive_str = [a for a in args if "id=slotdrive_c" in a][0]
        self.assertIn("file=/run/ramdisk_c.img", c_drive_str)
        self.assertIn("format=raw", c_drive_str)
        self.assertIn("snapshot=on", c_drive_str)
        self.assertIn("cache=unsafe", c_drive_str)
        self.assertIn("ide-hd,bus=ide.0,unit=0,drive=slotdrive_c,serial=SLOT_C", args)

        # Drive D: VHD rw (persistent, format=vpc, cache=none)
        d_drive_str = [a for a in args if "id=slotdrive_d" in a][0]
        self.assertIn("file=/mnt/usb/TOOLS.VHD", d_drive_str)
        self.assertIn("format=vpc", d_drive_str)
        self.assertIn("cache=none", d_drive_str)
        self.assertIn("ide-hd,bus=ide.0,unit=1,drive=slotdrive_d,serial=SLOT_D", args)

        # Drive E: physical partition ro (snapshot=on, never readonly=on for ide-hd)
        e_drive_str = [a for a in args if "id=slotdrive_e" in a][0]
        self.assertIn("file=/dev/nvme0n1p2", e_drive_str)
        self.assertIn("format=raw", e_drive_str)
        self.assertIn("snapshot=on", e_drive_str)
        self.assertNotIn("readonly=on", e_drive_str)
        self.assertIn("ide-hd,bus=ide.1,unit=1,drive=slotdrive_e,serial=SLOT_E", args)

    def test_raw_partition_drive_mapping(self):
        cfg = SlotRouterConfig(
            enabled=True,
            mappings={
                "c": SlotDriveMapping(drive_letter="c", slot_name="/dev/sda1", mode="temp"),
                "d": SlotDriveMapping(drive_letter="d", slot_name="nvme0n1p2", mode="rw"),
            },
        )
        args = build_qemu_slot_drive_args(cfg)

        c_drive_str = [a for a in args if "id=slotdrive_c" in a][0]
        self.assertIn("file=/dev/sda1", c_drive_str)
        self.assertIn("format=raw", c_drive_str)
        self.assertIn("snapshot=on", c_drive_str)

        d_drive_str = [a for a in args if "id=slotdrive_d" in a][0]
        self.assertIn("file=/dev/nvme0n1p2", d_drive_str)
        self.assertIn("format=raw", d_drive_str)
        self.assertIn("cache=none", d_drive_str)

    def test_vhd_creation_command(self):
        cmd = build_vhd_create_command("/tmp/vhd_build.raw", "/mnt/data/VHDs/DISK_C.VHD")
        self.assertEqual(cmd[0], "qemu-img")
        self.assertEqual(cmd[1], "convert")
        self.assertIn("raw", cmd)
        self.assertIn("vpc", cmd)
        self.assertIn("subformat=dynamic", cmd)
        self.assertIn("/tmp/vhd_build.raw", cmd)
        self.assertIn("/mnt/data/VHDs/DISK_C.VHD", cmd)

    def test_p2v_conversion_command(self):
        p2v_cmd = build_p2v_command("/dev/sda", "/mnt/usb/OLD_BOX.VHD")
        self.assertEqual(p2v_cmd[0], "qemu-img")
        self.assertEqual(p2v_cmd[1], "convert")
        self.assertIn("-f", p2v_cmd)
        self.assertIn("raw", p2v_cmd)
        self.assertIn("-O", p2v_cmd)
        self.assertIn("vpc", p2v_cmd)
        self.assertIn("/dev/sda", p2v_cmd)
        self.assertIn("/mnt/usb/OLD_BOX.VHD", p2v_cmd)

    def test_unmap_drive(self):
        cfg = SlotRouterConfig(
            enabled=True,
            mappings={
                "c": SlotDriveMapping(drive_letter="c", slot_name="/dev/sda1", mode="temp"),
                "d": SlotDriveMapping(drive_letter="d", slot_name="/mnt/usb/TOOLS.VHD", mode="rw"),
            },
        )
        self.assertIn("d", cfg.mappings)
        self.assertTrue(unmap_drive(cfg, "d"))
        self.assertNotIn("d", cfg.mappings)
        self.assertFalse(unmap_drive(cfg, "e"))

    def test_parent_disk_resolution(self):
        self.assertEqual(get_parent_disk("/dev/sda1"), "sda")
        self.assertEqual(get_parent_disk("sda2"), "sda")
        self.assertEqual(get_parent_disk("/dev/nvme0n1p3"), "nvme0n1")
        self.assertEqual(get_parent_disk("nvme1n1p1"), "nvme1n1")
        self.assertEqual(get_parent_disk("/dev/vda1"), "vda")
        self.assertEqual(get_parent_disk("sdb"), "sdb")

    def test_deconflict_storage_mappings(self):
        mappings = {
            "c": SlotDriveMapping(drive_letter="c", slot_name="/dev/sda1", mode="temp"),
            "d": SlotDriveMapping(drive_letter="d", slot_name="/mnt/usb/TOOLS.VHD", mode="ro"),
        }
        raw_disks = ["sda", "sdb", "sdc"]
        _, deconflicted = deconflict_storage_mappings(mappings, raw_disks)
        self.assertNotIn("sda", deconflicted, "sda must be excluded because /dev/sda1 is mapped to C:")
        self.assertIn("sdb", deconflicted)
        self.assertIn("sdc", deconflicted)

    def test_parse_partmap_cfg_with_raw_disks_and_empty_slots(self):
        content = """# PARTMAP.CFG
[system]
router_mode = routed
raw_disks = sdb, sdc

[drive_c]
slot = /dev/sda1
mode = temp

[drive_d]
slot = 
mode = rw

[drive_e]
slot = 
mode = ro
"""
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".cfg") as tf:
            tf.write(content)
            temp_path = tf.name
        try:
            cfg = parse_partmap_cfg(temp_path)
            self.assertTrue(cfg.enabled)
            self.assertTrue(cfg.raw_configured)
            self.assertIn("c", cfg.mappings)
            self.assertNotIn("d", cfg.mappings, "Empty slot string must not create a mapping")
            self.assertNotIn("e", cfg.mappings, "Empty slot string must not create a mapping")
            self.assertEqual(cfg.mappings["c"].slot_name, "/dev/sda1")
            self.assertEqual(cfg.raw_disks, ["sdb", "sdc"])
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)

    def test_ram_scratch_disk_mapping(self):
        cfg = SlotRouterConfig(
            enabled=True,
            mappings={
                "c": SlotDriveMapping(drive_letter="c", slot_name="ram", mode="temp")
            },
        )
        args = build_qemu_slot_drive_args(cfg)
        c_drive_str = [a for a in args if "id=slotdrive_c" in a][0]
        self.assertIn("file=/run/ramdisk_c.img", c_drive_str)
        self.assertIn("format=raw", c_drive_str)
        self.assertIn("snapshot=on", c_drive_str)
        self.assertIn("cache=unsafe", c_drive_str)

    def test_partition_rw_ro_overlay_qemu_args(self):
        cfg_temp = SlotRouterConfig(
            enabled=True,
            mappings={"c": SlotDriveMapping(drive_letter="c", slot_name="/dev/sda1", mode="temp")},
        )
        args_temp = build_qemu_slot_drive_args(cfg_temp)
        c_str_temp = [a for a in args_temp if "id=slotdrive_c" in a][0]
        self.assertIn("file=/dev/sda1", c_str_temp)
        self.assertIn("snapshot=on", c_str_temp)
        self.assertIn("cache=unsafe", c_str_temp)

        cfg_ro = SlotRouterConfig(
            enabled=True,
            mappings={"d": SlotDriveMapping(drive_letter="d", slot_name="/dev/sda2", mode="ro")},
        )
        args_ro = build_qemu_slot_drive_args(cfg_ro)
        d_str_ro = [a for a in args_ro if "id=slotdrive_d" in a][0]
        self.assertIn("file=/dev/sda2", d_str_ro)
        self.assertIn("snapshot=on", d_str_ro)
        self.assertNotIn("readonly=on", d_str_ro)

        cfg_rw = SlotRouterConfig(
            enabled=True,
            mappings={"e": SlotDriveMapping(drive_letter="e", slot_name="/dev/sdb1", mode="rw")},
        )
        args_rw = build_qemu_slot_drive_args(cfg_rw)
        e_str_rw = [a for a in args_rw if "id=slotdrive_e" in a][0]
        self.assertIn("file=/dev/sdb1", e_str_rw)
        self.assertIn("cache=none", e_str_rw)
        self.assertIn("aio=native", e_str_rw)

    def test_case_insensitive_captcha_verification(self):
        code = generate_captcha(5)
        self.assertEqual(len(code), 5)
        lower_input = code.lower()
        self.assertEqual(lower_input.strip().upper(), code.strip().upper())

    def test_direct_vhd_and_img_drive_mapping(self):
        cfg = SlotRouterConfig(
            enabled=True,
            mappings={
                "c": SlotDriveMapping(drive_letter="c", slot_name="/mnt/usb_vhd/TOOLS.VHD", mode="rw"),
                "d": SlotDriveMapping(drive_letter="d", slot_name="/mnt/esp/DOS_WORK.IMG", mode="temp"),
            },
        )
        args = build_qemu_slot_drive_args(cfg)
        c_str = [a for a in args if "id=slotdrive_c" in a][0]
        self.assertIn("file=/mnt/usb_vhd/TOOLS.VHD", c_str)
        self.assertIn("format=vpc", c_str)
        self.assertIn("cache=none", c_str)

        d_str = [a for a in args if "id=slotdrive_d" in a][0]
        self.assertIn("file=/mnt/esp/DOS_WORK.IMG", d_str)
        self.assertIn("format=raw", d_str)
        self.assertIn("snapshot=on", d_str)

    def test_controller_mode_ahci_vs_ide(self):
        content = """[system]
router_mode = routed
controller_mode = ahci

[drive_c]
slot = /dev/sda1
mode = temp

[drive_d]
slot = /mnt/usb_vhd/BACKUP.VHD
mode = ro
"""
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".cfg") as tf:
            tf.write(content)
            temp_path = tf.name
        try:
            cfg = parse_partmap_cfg(temp_path)
            self.assertEqual(cfg.controller_mode, "c")
            args = build_qemu_slot_drive_args(cfg)
            self.assertIn("ide-hd,bus=ahci.0,drive=slotdrive_c,serial=SLOT_C", args)
            self.assertIn("ide-hd,bus=ahci.1,drive=slotdrive_d,serial=SLOT_D", args)
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)

    def test_format_size_mb(self):
        self.assertEqual(format_size_mb(0), "0 MB")
        self.assertEqual(format_size_mb(512), "512 MB")
        self.assertEqual(format_size_mb(2048), "2.00 GB")
        self.assertEqual(format_size_mb(122880), "120.0 GB")
        self.assertEqual(format_size_mb(2097152), "2.00 TB")

    def test_shell_router_functional(self):
        sh_bin = shutil.which("sh")
        if not sh_bin and os.path.exists(r"C:\Program Files\Git\bin\sh.exe"):
            sh_bin = r"C:\Program Files\Git\bin\sh.exe"
        if not sh_bin:
            self.skipTest("POSIX sh binary not available")

        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        router_sh = os.path.join(repo_root, "src", "slot_router.sh").replace("\\", "/")

        cfg_content = """[system]
router_mode = routed
controller_mode = ahci
raw_disks = sdb

[drive_c]
slot = ram
mode = temp

[drive_d]
slot = /mnt/usb_vhd/DISK.VHD
mode = ro
"""
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".cfg") as tf:
            tf.write(cfg_content)
            cfg_path = tf.name.replace("\\", "/")

        work_dir = tempfile.mkdtemp(prefix="routertest_")
        work_dir_posix = work_dir.replace("\\", "/")
        try:
            script = f"""
set -e
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export RAMDISK_DIR="{work_dir_posix}"
export VHD_WORK_DIR="{work_dir_posix}"
export VHD_RAW_FALLBACK=1
. "{router_sh}"
echo "SZ_512=$(format_size_mb 512)"
echo "SZ_2G=$(format_size_mb 2048)"
echo "SZ_1T=$(format_size_mb 1572864)"
parse_partmap_cfg "{cfg_path}"
echo "BUS=$BUS_MODE"
echo "C_SLOT=$DRIVE_C_SLOT"
ARGS=$(build_storage_attachments "$BUS_MODE")
echo "ARGS=$ARGS"
QARGS=$(build_slot_qemu_args)
echo "QARGS=$QARGS"
create_formatted_vhd "{work_dir_posix}/disk128.img" 128 "DOS_C"
create_formatted_vhd "{work_dir_posix}/disk600.img" 600 "DOS_D"
dd if=/dev/zero of="{work_dir_posix}/phys128.img" bs=1M count=0 seek=128 2>/dev/null
format_disk_mbr_fat32 "{work_dir_posix}/phys128.img" "DOS_STORE"
"""
            res = subprocess.run([sh_bin, "-c", script], capture_output=True, text=True, check=True)
            out = res.stdout
            self.assertIn("SZ_512=512 MB", out)
            self.assertIn("SZ_2G=2.00 GB", out)
            self.assertIn("SZ_1T=1.50 TB", out)
            self.assertIn("BUS=c", out)
            self.assertIn("C_SLOT=ram", out)
            self.assertIn("ramdisk_c.img,format=raw,if=none,id=slotdrive_c,snapshot=on,cache=unsafe", out)
            self.assertIn("bus=ahci.0,drive=slotdrive_c,serial=SLOT_C", out)
            self.assertIn("file=/mnt/usb_vhd/DISK.VHD,format=vpc,if=none,id=slotdrive_d,snapshot=on", out)
            self.assertIn("bus=ahci.1,drive=slotdrive_d,serial=SLOT_D", out)
            self.assertNotIn("readonly=on", out, "ide-hd rejects readonly=on; must use snapshot=on")

            ram_img_file = os.path.join(work_dir, "ramdisk_c.img")
            self.assertTrue(os.path.exists(ram_img_file))
            with open(ram_img_file, "rb") as rf:
                mbr = rf.read(512)
            self.assertEqual(len(mbr), 512)
            self.assertEqual(mbr[446], 0x80)
            self.assertEqual(mbr[450], 0x0E)
            self.assertEqual(struct.unpack("<II", mbr[454:462]), (2048, 129024))
            self.assertEqual(mbr[510:512], b"\x55\xaa")

            # Verify create_formatted_vhd MBR entry for 128 MB (FAT16 LBA type 0x0E)
            d128 = os.path.join(work_dir, "disk128.img")
            self.assertEqual(os.path.getsize(d128), 128 * 1024 * 1024)
            with open(d128, "rb") as f128:
                mbr128 = f128.read(512)
            self.assertEqual(mbr128[446], 0x80)
            self.assertEqual(mbr128[450], 0x0E)
            self.assertEqual(struct.unpack("<II", mbr128[454:462]), (2048, 127 * 2048))
            self.assertEqual(mbr128[510:512], b"\x55\xaa")

            # Verify create_formatted_vhd MBR entry for 600 MB (FAT32 LBA type 0x0C)
            d600 = os.path.join(work_dir, "disk600.img")
            self.assertEqual(os.path.getsize(d600), 600 * 1024 * 1024)
            with open(d600, "rb") as f600:
                mbr600 = f600.read(512)
            self.assertEqual(mbr600[446], 0x80)
            self.assertEqual(mbr600[450], 0x0C)
            self.assertEqual(struct.unpack("<II", mbr600[454:462]), (2048, 599 * 2048))
            self.assertEqual(mbr600[510:512], b"\x55\xaa")

            # Verify format_disk_mbr_fat32 MBR entry on 128 MB disk image (FAT32 LBA type 0x0C)
            p128 = os.path.join(work_dir, "phys128.img")
            self.assertEqual(os.path.getsize(p128), 128 * 1024 * 1024)
            with open(p128, "rb") as fp128:
                mbr_p = fp128.read(512)
            self.assertEqual(mbr_p[446], 0x80)
            self.assertEqual(mbr_p[450], 0x0C)
            self.assertEqual(struct.unpack("<II", mbr_p[454:462]), (2048, 127 * 2048))
            self.assertEqual(mbr_p[510:512], b"\x55\xaa")
        finally:
            if os.path.exists(cfg_path):
                os.unlink(cfg_path)
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()

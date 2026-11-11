#!/usr/bin/env python3
"""
Unit tests for slot_router module.
"""

import unittest
import tempfile
import os
from src.slot_router import (
    generate_captcha,
    parse_slot_string,
    parse_partmap_cfg,
    build_qemu_slot_drive_args,
    build_vhd_export_command,
    build_vhd_import_command,
    build_p2v_command,
    unmap_drive,
    SlotRouterConfig,
    SlotDriveMapping
)

class TestSlotRouter(unittest.TestCase):

    def test_captcha_generation(self):
        code1 = generate_captcha(5)
        code2 = generate_captcha(5)
        self.assertEqual(len(code1), 5)
        self.assertEqual(len(code2), 5)
        # Ensure ambiguous characters are excluded
        for char in "0O1IL":
            self.assertNotIn(char, code1)
            self.assertNotIn(char, code2)

    def test_parse_slot_string(self):
        slot, mode = parse_slot_string("slot1:temp")
        self.assertEqual(slot, "slot1")
        self.assertEqual(mode, "temp")

        slot, mode = parse_slot_string("slot3:rw")
        self.assertEqual(slot, "slot3")
        self.assertEqual(mode, "rw")

        slot, mode = parse_slot_string("golden:ro")
        self.assertEqual(slot, "golden")
        self.assertEqual(mode, "ro")

        # Default fallback to temp when mode is omitted or invalid
        slot, mode = parse_slot_string("slot2")
        self.assertEqual(slot, "slot2")
        self.assertEqual(mode, "temp")

        slot, mode = parse_slot_string("slot5:invalid_mode")
        self.assertEqual(slot, "slot5")
        self.assertEqual(mode, "temp")

    def test_parse_partmap_cfg(self):
        content = """
[system]
enable_slots = true
golden_base = /data/golden.raw
slots_dir = /data/slots

[drive_c]
slot = slot1
mode = temp
description = Factory Sandbox

[drive_d]
slot = slot3
mode = rw
description = Persistent Telemetry

[drive_e]
slot = golden
mode = ro
description = Read-Only Firmware Reference
"""
        with tempfile.NamedTemporaryFile("w", delete=False) as tf:
            tf.write(content)
            temp_path = tf.name

        try:
            cfg = parse_partmap_cfg(temp_path)
            self.assertTrue(cfg.enabled)
            self.assertEqual(cfg.golden_base_path, "/data/golden.raw")
            self.assertEqual(cfg.slots_dir, "/data/slots")
            self.assertIn("c", cfg.mappings)
            self.assertIn("d", cfg.mappings)
            self.assertIn("e", cfg.mappings)

            self.assertEqual(cfg.mappings["c"].slot_name, "slot1")
            self.assertEqual(cfg.mappings["c"].mode, "temp")

            self.assertEqual(cfg.mappings["d"].slot_name, "slot3")
            self.assertEqual(cfg.mappings["d"].mode, "rw")

            self.assertEqual(cfg.mappings["e"].slot_name, "golden")
            self.assertEqual(cfg.mappings["e"].mode, "ro")
        finally:
            if os.path.exists(temp_path):
                os.remove(temp_path)

    def test_flat_dos_cfg_slot_parsing(self):
        content = """
# DOS.CFG flat format
drive_c = slot1:temp
drive_d = slot3:rw
"""
        with tempfile.NamedTemporaryFile("w", delete=False) as tf:
            tf.write(content)
            temp_path = tf.name

        try:
            cfg = parse_partmap_cfg(temp_path)
            self.assertTrue(cfg.enabled)
            self.assertIn("c", cfg.mappings)
            self.assertIn("d", cfg.mappings)
            self.assertEqual(cfg.mappings["c"].slot_name, "slot1")
            self.assertEqual(cfg.mappings["c"].mode, "temp")
            self.assertEqual(cfg.mappings["d"].slot_name, "slot3")
            self.assertEqual(cfg.mappings["d"].mode, "rw")
        finally:
            if os.path.exists(temp_path):
                os.remove(temp_path)

    def test_build_qemu_slot_drive_args(self):
        cfg = SlotRouterConfig(
            enabled=True,
            golden_base_path="/data/golden.raw",
            slots_dir="/data/slots",
            mappings={
                "c": SlotDriveMapping(drive_letter="c", slot_name="slot1", mode="temp"),
                "d": SlotDriveMapping(drive_letter="d", slot_name="slot3", mode="rw"),
                "e": SlotDriveMapping(drive_letter="e", slot_name="golden", mode="ro")
            }
        )
        args = build_qemu_slot_drive_args(cfg)

        # Drive C: temp (snapshot=on)
        self.assertIn("-drive", args)
        c_drive_str = [a for a in args if "id=slotdrive_c" in a][0]
        self.assertIn("file=/data/slots/slot1.qcow2", c_drive_str)
        self.assertIn("snapshot=on", c_drive_str)
        self.assertIn("ide-hd,bus=ide.0,unit=0,drive=slotdrive_c,serial=SLOT_C", args)

        # Drive D: rw (persistent, cache=none)
        d_drive_str = [a for a in args if "id=slotdrive_d" in a][0]
        self.assertIn("file=/data/slots/slot3.qcow2", d_drive_str)
        self.assertIn("cache=none", d_drive_str)
        self.assertIn("ide-hd,bus=ide.0,unit=1,drive=slotdrive_d,serial=SLOT_D", args)

        # Drive E: golden ro (readonly=on)
        e_drive_str = [a for a in args if "id=slotdrive_e" in a][0]
        self.assertIn("file=/data/golden.raw", e_drive_str)
        self.assertIn("readonly=on", e_drive_str)
        self.assertIn("ide-hd,bus=ide.1,unit=1,drive=slotdrive_e,serial=SLOT_E", args)

    def test_raw_partition_drive_mapping(self):
        cfg = SlotRouterConfig(
            enabled=True,
            mappings={
                "c": SlotDriveMapping(drive_letter="c", slot_name="/dev/sda1", mode="temp"),
                "d": SlotDriveMapping(drive_letter="d", slot_name="nvme0n1p2", mode="rw")
            }
        )
        args = build_qemu_slot_drive_args(cfg)
        
        # Drive C: /dev/sda1 raw temp
        c_drive_str = [a for a in args if "id=slotdrive_c" in a][0]
        self.assertIn("file=/dev/sda1", c_drive_str)
        self.assertIn("format=raw", c_drive_str)
        self.assertIn("snapshot=on", c_drive_str)

        # Drive D: /dev/nvme0n1p2 raw rw
        d_drive_str = [a for a in args if "id=slotdrive_d" in a][0]
        self.assertIn("file=/dev/nvme0n1p2", d_drive_str)
        self.assertIn("format=raw", d_drive_str)
        self.assertIn("cache=none", d_drive_str)

    def test_vhd_conversion_commands(self):
        exp_cmd = build_vhd_export_command("/data/slot1.qcow2", "/usb/backup.vhd")
        self.assertEqual(exp_cmd[0], "qemu-img")
        self.assertEqual(exp_cmd[1], "convert")
        self.assertIn("-O", exp_cmd)
        self.assertIn("vpc", exp_cmd)
        self.assertIn("/usb/backup.vhd", exp_cmd)

        imp_cmd = build_vhd_import_command("/usb/update.vhd", "/data/slot2.qcow2", backing_base="/data/golden.raw")
        self.assertEqual(imp_cmd[0], "qemu-img")
        self.assertEqual(imp_cmd[1], "convert")
        self.assertIn("-O", imp_cmd)
        self.assertIn("qcow2", imp_cmd)
        self.assertIn("-B", imp_cmd)
        self.assertIn("/data/golden.raw", imp_cmd)

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
                "c": SlotDriveMapping(drive_letter="c", slot_name="slot1", mode="temp"),
                "d": SlotDriveMapping(drive_letter="d", slot_name="slot2", mode="rw")
            }
        )
        self.assertIn("d", cfg.mappings)
        self.assertTrue(unmap_drive(cfg, "d"))
        self.assertNotIn("d", cfg.mappings)
        # Attempt to unmap non-existent drive
        self.assertFalse(unmap_drive(cfg, "e"))


    def test_parent_disk_resolution(self):
        from src.slot_router import get_parent_disk
        self.assertEqual(get_parent_disk("/dev/sda1"), "sda")
        self.assertEqual(get_parent_disk("sda2"), "sda")
        self.assertEqual(get_parent_disk("/dev/nvme0n1p3"), "nvme0n1")
        self.assertEqual(get_parent_disk("nvme1n1p1"), "nvme1n1")
        self.assertEqual(get_parent_disk("/dev/vda1"), "vda")
        self.assertEqual(get_parent_disk("sdb"), "sdb")

    def test_deconflict_storage_mappings(self):
        from src.slot_router import deconflict_storage_mappings
        mappings = {
            "c": SlotDriveMapping(drive_letter="c", slot_name="/dev/sda1", mode="temp"),
            "d": SlotDriveMapping(drive_letter="d", slot_name="golden", mode="ro")
        }
        # sda is the parent of /dev/sda1, so sda MUST be excluded from raw_disks
        raw_disks = ["sda", "sdb", "sdc"]
        _, deconflicted = deconflict_storage_mappings(mappings, raw_disks)
        self.assertNotIn("sda", deconflicted, "sda must be excluded because /dev/sda1 is mapped to C:")
        self.assertIn("sdb", deconflicted)
        self.assertIn("sdc", deconflicted)

    def test_parse_partmap_cfg_with_raw_disks_and_empty_slots(self):
        content = """# PARTMAP.CFG
[system]
router_mode = slots
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
            }
        )
        args = build_qemu_slot_drive_args(cfg)
        c_drive_str = [a for a in args if "id=slotdrive_c" in a][0]
        self.assertIn("file=/mnt/data/golden_base.raw", c_drive_str)
        self.assertIn("format=raw", c_drive_str)
        self.assertIn("snapshot=on", c_drive_str)
        self.assertIn("cache=unsafe", c_drive_str)

    def test_partition_rw_ro_overlay_qemu_args(self):
        # 1. Overlay (temp)
        cfg_temp = SlotRouterConfig(
            enabled=True,
            mappings={"c": SlotDriveMapping(drive_letter="c", slot_name="/dev/sda1", mode="temp")}
        )
        args_temp = build_qemu_slot_drive_args(cfg_temp)
        c_str_temp = [a for a in args_temp if "id=slotdrive_c" in a][0]
        self.assertIn("file=/dev/sda1", c_str_temp)
        self.assertIn("snapshot=on", c_str_temp)
        self.assertIn("cache=unsafe", c_str_temp)

        # 2. Read-Only (ro)
        cfg_ro = SlotRouterConfig(
            enabled=True,
            mappings={"d": SlotDriveMapping(drive_letter="d", slot_name="/dev/sda2", mode="ro")}
        )
        args_ro = build_qemu_slot_drive_args(cfg_ro)
        d_str_ro = [a for a in args_ro if "id=slotdrive_d" in a][0]
        self.assertIn("file=/dev/sda2", d_str_ro)
        self.assertIn("readonly=on", d_str_ro)

        # 3. Read/Write (rw)
        cfg_rw = SlotRouterConfig(
            enabled=True,
            mappings={"e": SlotDriveMapping(drive_letter="e", slot_name="/dev/sdb1", mode="rw")}
        )
        args_rw = build_qemu_slot_drive_args(cfg_rw)
        e_str_rw = [a for a in args_rw if "id=slotdrive_e" in a][0]
        self.assertIn("file=/dev/sdb1", e_str_rw)
        self.assertIn("cache=none", e_str_rw)
        self.assertIn("aio=native", e_str_rw)

    def test_case_insensitive_captcha_verification(self):
        code = generate_captcha(5)
        self.assertEqual(len(code), 5)
        # Test case insensitivity normalization
        lower_input = code.lower()
        self.assertEqual(lower_input.strip().upper(), code.strip().upper())

if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""
Unit tests for storage_mapper module.
"""

import unittest
from src.storage_mapper import (
    BlockDevice,
    StorageMappingConfig,
    classify_device_type,
    parse_sysfs_size,
    build_qemu_ahci_args,
    build_qemu_iso_args
)

class TestStorageMapper(unittest.TestCase):

    def test_classify_device_type(self):
        self.assertEqual(classify_device_type("/dev/nvme0n1"), "nvme")
        self.assertEqual(classify_device_type("/dev/sda"), "sata")
        self.assertEqual(classify_device_type("/dev/sdb"), "sata")
        self.assertEqual(classify_device_type("/dev/hda"), "ide")
        self.assertEqual(classify_device_type("/dev/vda"), "virtio")
        self.assertEqual(classify_device_type("/dev/loop0"), "loop")
        self.assertEqual(classify_device_type("/dev/unknown_disk"), "unknown")

    def test_parse_sysfs_size(self):
        # 2097152 sectors * 512 = 1,073,741,824 bytes (1 GiB)
        self.assertEqual(parse_sysfs_size("2097152"), 1073741824)
        self.assertEqual(parse_sysfs_size(" 2097152 \n"), 1073741824)
        self.assertEqual(parse_sysfs_size("invalid"), 0)
        self.assertEqual(parse_sysfs_size(""), 0)

    def test_build_qemu_ahci_args_empty(self):
        cfg = StorageMappingConfig()
        args = build_qemu_ahci_args(cfg)
        self.assertEqual(args, ["-device", "ich9-ahci,id=ahci0"])

    def test_build_qemu_ahci_args_with_devices(self):
        dev1 = BlockDevice(
            device_path="/dev/nvme0n1",
            name="nvme0n1",
            size_bytes=512000000000,
            device_type="nvme"
        )
        dev2 = BlockDevice(
            device_path="/dev/sda",
            name="sda",
            size_bytes=1000000000000,
            device_type="sata"
        )
        cfg = StorageMappingConfig(
            target_devices=[dev1, dev2],
            cache_mode="none",
            aio_mode="native"
        )
        args = build_qemu_ahci_args(cfg)

        self.assertIn("-device", args)
        self.assertIn("ich9-ahci,id=ahci0", args)
        self.assertIn("file=/dev/nvme0n1,format=raw,if=none,id=disk0,cache=none,aio=native", args)
        self.assertIn("ide-hd,bus=ahci0.0,drive=disk0", args)
        self.assertIn("file=/dev/sda,format=raw,if=none,id=disk1,cache=none,aio=native", args)
        self.assertIn("ide-hd,bus=ahci0.1,drive=disk1", args)

    def test_build_qemu_iso_args(self):
        args = build_qemu_iso_args("test.iso")
        self.assertEqual(args, ["-cdrom", "test.iso", "-boot", "order=d"])

if __name__ == "__main__":
    unittest.main()

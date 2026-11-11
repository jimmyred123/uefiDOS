#!/usr/bin/env python3
"""
Unit tests for initramfs_launcher module with mocked sysfs structure.
"""

import os
import unittest
import tempfile
import shutil
from src.initramfs_launcher import scan_linux_block_devices

class TestInitramfsLauncher(unittest.TestCase):

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def test_scan_linux_block_devices_mocked(self):
        # Create mock sysfs entries:
        # 1. nvme0n1 (512GB)
        nvme_dir = os.path.join(self.test_dir, "nvme0n1")
        os.makedirs(nvme_dir)
        with open(os.path.join(nvme_dir, "size"), "w") as f:
            f.write("1000000000\n")
        with open(os.path.join(nvme_dir, "ro"), "w") as f:
            f.write("0\n")

        # 2. sda (read-only ISO/USB)
        sda_dir = os.path.join(self.test_dir, "sda")
        os.makedirs(sda_dir)
        with open(os.path.join(sda_dir, "size"), "w") as f:
            f.write("4000000\n")
        with open(os.path.join(sda_dir, "ro"), "w") as f:
            f.write("1\n")

        # 3. ram0 (ignored)
        ram_dir = os.path.join(self.test_dir, "ram0")
        os.makedirs(ram_dir)

        devices = scan_linux_block_devices(self.test_dir)
        dev_names = [d.name for d in devices]

        self.assertIn("nvme0n1", dev_names)
        self.assertIn("sda", dev_names)
        self.assertNotIn("ram0", dev_names)

        nvme_dev = next(d for d in devices if d.name == "nvme0n1")
        self.assertEqual(nvme_dev.device_type, "nvme")
        self.assertEqual(nvme_dev.size_bytes, 1000000000 * 512)
        self.assertFalse(nvme_dev.read_only)

        sda_dev = next(d for d in devices if d.name == "sda")
        self.assertEqual(sda_dev.device_type, "sata")
        self.assertTrue(sda_dev.read_only)

if __name__ == "__main__":
    unittest.main()

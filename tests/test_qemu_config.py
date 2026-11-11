#!/usr/bin/env python3
"""
Unit tests for qemu_config module.
"""

import unittest
from src.qemu_config import QemuRunnerConfig, generate_qemu_command
from src.storage_mapper import BlockDevice, StorageMappingConfig

class TestQemuConfig(unittest.TestCase):

    def test_default_qemu_command(self):
        cfg = QemuRunnerConfig()
        cmd = generate_qemu_command(cfg)
        
        self.assertEqual(cmd[0], "qemu-system-x86_64")
        self.assertIn("-machine", cmd)
        self.assertIn("q35", cmd)
        self.assertIn("-m", cmd)
        self.assertIn("512M", cmd)
        self.assertIn("-vga", cmd)
        self.assertIn("std", cmd)
        self.assertIn("-serial", cmd)
        self.assertIn("stdio", cmd)
        self.assertNotIn("-nographic", cmd)

    def test_headless_and_kvm(self):
        cfg = QemuRunnerConfig(
            headless=True,
            enable_kvm=True,
            memory_mb=1024,
            smp_cores=4
        )
        cmd = generate_qemu_command(cfg)
        self.assertIn("-nographic", cmd)
        self.assertIn("-enable-kvm", cmd)
        self.assertIn("-cpu", cmd)
        self.assertIn("host", cmd)
        self.assertIn("1024M", cmd)
        self.assertIn("4", cmd)

    def test_command_with_iso_and_ahci_storage(self):
        dev = BlockDevice(
            device_path="/dev/nvme0n1",
            name="nvme0n1",
            size_bytes=256000000000,
            device_type="nvme"
        )
        storage_cfg = StorageMappingConfig(target_devices=[dev])
        cfg = QemuRunnerConfig(
            storage_config=storage_cfg,
            iso_path="/tmp/boot.iso"
        )
        cmd = generate_qemu_command(cfg)
        
        self.assertIn("-device", cmd)
        self.assertIn("ich9-ahci,id=ahci0", cmd)
        self.assertIn("-cdrom", cmd)
        self.assertIn("/tmp/boot.iso", cmd)
        self.assertIn("-boot", cmd)
        self.assertIn("order=d", cmd)

    def test_command_with_pci_passthrough(self):
        cfg = QemuRunnerConfig(
            pci_passthrough=["01:00.0", "0000:02:00.0"]
        )
        cmd = generate_qemu_command(cfg)
        self.assertIn("-device", cmd)
        self.assertIn("vfio-pci,host=01:00.0,id=vfio_dev0", cmd)
        self.assertIn("vfio-pci,host=0000:02:00.0,id=vfio_dev1", cmd)

    def test_command_with_serial_and_parallel(self):
        cfg = QemuRunnerConfig(
            serial_ports=["/dev/ttyUSB0", "/dev/ttyUSB1"],
            parallel_ports=["/dev/usb/lp0"]
        )
        cmd = generate_qemu_command(cfg)
        self.assertIn("-chardev", cmd)
        self.assertIn("serial,id=hostserial0,path=/dev/ttyUSB0", cmd)
        self.assertIn("chardev:hostserial0", cmd)
        self.assertIn("serial,id=hostserial1,path=/dev/ttyUSB1", cmd)
        self.assertIn("chardev:hostserial1", cmd)
        self.assertIn("parallel,id=hostpar0,path=/dev/usb/lp0", cmd)
        self.assertIn("chardev:hostpar0", cmd)

if __name__ == "__main__":
    unittest.main()

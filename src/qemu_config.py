#!/usr/bin/env python3
"""
uefiDOS QEMU Configuration & Execution Generator

Produces standard invocation options and machine topologies matching
pure-UEFI environments with full hardware acceleration (KVM/WHPX)
and ICH9/Q35 AHCI configurations.
"""

from dataclasses import dataclass, field
from typing import List, Optional
from .storage_mapper import StorageMappingConfig, build_qemu_ahci_args, build_qemu_iso_args, build_qemu_fda_args

@dataclass
class QemuRunnerConfig:
    machine_type: str = "q35"
    memory_mb: int = 512
    smp_cores: int = 2
    enable_kvm: bool = False
    enable_whpx: bool = False
    headless: bool = False
    serial_stdio: bool = True
    vga_type: str = "std"  # "std", "cirrus", "none"
    storage_config: StorageMappingConfig = field(default_factory=StorageMappingConfig)
    iso_path: Optional[str] = None
    fda_path: Optional[str] = None
    pci_passthrough: List[str] = field(default_factory=list)
    serial_ports: List[str] = field(default_factory=list)
    parallel_ports: List[str] = field(default_factory=list)
    extra_args: List[str] = field(default_factory=list)

def generate_qemu_command(config: QemuRunnerConfig, qemu_bin: str = "qemu-system-x86_64") -> List[str]:
    """Generates the complete command line arguments for QEMU."""
    cmd = [
        qemu_bin,
        "-machine", config.machine_type,
        "-m", f"{config.memory_mb}M",
        "-smp", str(config.smp_cores),
        "-vga", config.vga_type
    ]

    if config.enable_kvm:
        cmd.extend(["-enable-kvm", "-cpu", "host"])
    elif config.enable_whpx:
        cmd.extend(["-accel", "whpx"])

    if config.serial_ports:
        for i, ser_port in enumerate(config.serial_ports):
            cmd.extend(["-chardev", f"serial,id=hostserial{i},path={ser_port}", "-serial", f"chardev:hostserial{i}"])
    elif config.serial_stdio:
        cmd.extend(["-serial", "stdio"])

    if config.parallel_ports:
        for i, par_port in enumerate(config.parallel_ports):
            cmd.extend(["-chardev", f"parallel,id=hostpar{i},path={par_port}", "-parallel", f"chardev:hostpar{i}"])

    if config.headless:
        cmd.append("-nographic")

    # Add AHCI storage devices
    cmd.extend(build_qemu_ahci_args(config.storage_config))

    # Add PCI passthrough devices (VFIO)
    for i, pci_dev in enumerate(config.pci_passthrough):
        cmd.extend(["-device", f"vfio-pci,host={pci_dev},id=vfio_dev{i}"])

    # Add bootable ISO or Floppy media
    if config.fda_path:
        cmd.extend(build_qemu_fda_args(config.fda_path))
    elif config.iso_path:
        cmd.extend(build_qemu_iso_args(config.iso_path))

    # Add extra arguments
    cmd.extend(config.extra_args)

    return cmd

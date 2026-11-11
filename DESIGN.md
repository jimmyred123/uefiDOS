# Technical Design Document: `uefiDOS`

## 1. Executive Summary

`uefiDOS` is a chained boot shim and virtualization layer designed to execute legacy real-mode DOS storage utilities, diagnostics, and legacy applications on modern **UEFI Class 3 (Pure UEFI, CSM-free)** hardware.

The project bypasses modern hardware constraints (absence of legacy BIOS INT 13h/INT 10h, lack of physical IDE/VGA hardware, Intel VMD isolation, and IOMMU/VT-d blocking) by coupling a fast-booting micro-Linux kernel with an embedded QEMU/KVM virtual machine monitor (VMM). The architecture transparently bridges physical storage devices (both physical SATA and modern NVMe SSDs) into standard IDE and AHCI storage adapters capable of Direct Memory Access (DMA).

---

## 2. Target Operating Model & Constraints

### 2.1 The Real-Mode DOS Hardware Access Model
Legacy DOS utilities feature direct hardware drivers:
- **Direct PCI Bus Probing**: Scans PCI configuration space (`0xCF8`/`0xCFC`) for controllers with Class Code `0x01` (Mass Storage) and Subclass `0x06` (SATA/AHCI) or `0x01` (IDE/ATA).
- **AHCI MMIO BAR5 Access**: Reads PCI register offset `0x24` to determine the AHCI Base Address Register (ABAR). It accesses AHCI generic registers and port command registers directly via Memory-Mapped I/O.
- **Physical Bus-Master DMA**: Constructs Physical Region Descriptor Tables (PRDTs) using 32-bit physical RAM addresses to initiate high-speed Bus Master DMA transfers.
- **Boot Pre-Requisite**: Before DOS applications execute, the underlying OS (FreeDOS) requires legacy BIOS Interrupts:
  - `INT 10h` for screen initialization and text/VGA output.
  - `INT 13h` for floppy disk emulation to boot the FreeDOS kernel and read executables.
  - `INT 16h` for keyboard input.

### 2.2 Modern UEFI Class 3 Limitations
Modern hardware (Intel 10th Gen Core / AMD Ryzen 5000+ and newer) eliminates legacy support:
1. **Zero CSM**: No real-mode Interrupt Vector Table (IVT at `0x0000`), no BIOS Data Area (BDA at `0x0400`), and no legacy BIOS ROM at `0xF0000`.
2. **Missing VGA / PS/2 Hardware**: GPUs only offer UEFI Graphics Output Protocol (GOP) linear framebuffers; no legacy I/O ports (`0x3C0`–`0x3DA`) or text memory at `0xB8000` exist.
3. **No NVMe Support in Legacy DOS**: DOS does not contain native NVMe drivers. On NVMe-only machines (laptops, ultra-compact PCs), DOS has no native way to address the drive.
4. **IOMMU Protection (Intel VT-d / AMD-Vi)**: Active DMA remapping units block direct physical DMA requests from unmapped legacy code, crashing or halting the machine.

---

## 3. System Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                      Host Platform Hardware                           │
│  [ x86-64 CPU (VT-x / AMD-V) ]   [ NVMe M.2 SSD ]   [ SATA SSD / HDD ] │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ UEFI Boot
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     uefiDOS Boot Loader (UEFI)                         │
│            Unified Kernel Image / GRUB-EFI (Pure UEFI x64)             │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Loads Kernel + Initramfs in RAM
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                 Minimal Host Micro-Linux OS (~25 MB)                   │
│  - Tiny Linux kernel + BusyBox initramfs                               │
│  - Storage Discovery Daemon: Scans `/dev/nvme*` and `/dev/sd*`        │
│  - Interactive Console or Auto-Pass Menu (Framebuffer/GOP)            │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Spawns Accelerated Guest
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│               Embedded Hardware-Accelerated VMM (KVM)                  │
│                                                                        │
│   Virtual IDE/AHCI Controller (i440fx / ICH9)                         │
│   ┌──────────────────────────────────────────────────────────────────┐ │
│   │ Port 0: Virtual Disk (Backed by physical NVMe or raw disk)       │ │
│   │ Port 1: Secondary Disk / Target                                  │ │
│   └──────────────────────────────────────────────────────────────────┘ │
│   Virtual El Torito CD-ROM / Floppy (FreeDOS Runtime)                  │
│   Virtual VGA + Virtual PS/2 Input (Mapped to host GOP & USB HID)     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      FreeDOS Guest Environment                         │
│                                                                        │
│   1. FreeDOS Boots from RAM disk via emulated BIOS INT 10h/13h         │
│   2. FreeDOS executes AUTOEXEC.BAT -> launches user payload           │
│   3. DOS Probes PCI Bus -> Detects Virtual IDE/AHCI Controller        │
│   4. DOS directly programs MMIO & PRDT DMA Lists                      │
│   5. DOS tests/accesses disk with full hardware DMA throughput        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Key Engineering Modules

### 4.1 Storage Translation Engine
To allow DOS to work on both SATA and NVMe drives:
- **NVMe-to-IDE/AHCI Mapping**: The host Linux kernel attaches to physical NVMe drives via `nvme.ko`. When launching QEMU, the drive (`/dev/nvme0n1`) is attached as a raw block backend to an emulated controller:
  ```bash
  -device ide-hd,bus=ide.0,unit=0,drive=disk0 \
  -drive file=/dev/nvme0n1,format=raw,if=none,id=disk0,cache=none,aio=native
  ```

### 4.2 Display & Input Bridge
- The host Linux kernel initializes the native display via `efifb` / `simplefb` using the UEFI GOP parameters inherited from firmware.
- QEMU renders the guest VGA display straight to the Linux Direct Rendering Manager (DRM) or framebuffer console.

### 4.3 IOMMU Handling
- The host Linux kernel manages the IOMMU natively, ensuring all DMA operations performed by the host NVMe driver are completely valid and protected.

---

## 5. Verification & Testing Workflow

### 5.1 Local Emulation Verification
Developers and users can verify the entire pipeline without physical test hardware using QEMU:
1. Create a simulated target disk image.
2. Launch QEMU with a virtual controller hosting the target disk, alongside `uefiDOS.iso`.
3. Confirm that FreeDOS discovers the controller, initiates DMA, and detects the virtual disk.

### 5.2 CI Automation (GitHub Actions)
The repository includes a headless QEMU verification runner that executes in GitHub Actions:
- Boots QEMU headlessly with `-nographic -serial stdio`.
- Captures serial output from FreeDOS.
- Asserts that device detection succeeded.

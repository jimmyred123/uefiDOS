# uefiDOS

> **Universal Pure-UEFI Real-Mode DOS Bridge & Hardware Pass-Through Environment**

`uefiDOS` bridges modern UEFI Class 3 (Pure UEFI, CSM-free) systems and legacy real-mode operating systems, disk utilities, games, and diagnostics.

By wrapping an ultra-lightweight, hardware-accelerated Linux micro-kernel and hypervisor runtime, `uefiDOS` exposes modern NVMe SSDs and SATA/AHCI controllers as clean, standard IDE or AHCI endpoints with full DMA access directly to FreeDOS and DOS executables—without requiring legacy motherboard BIOS or CSM support.

---

## The Problem

1. **CSM Removal**: Modern Intel (10th Gen+) and AMD platforms have completely removed the Compatibility Support Module (CSM). Legacy 16-bit real-mode operating systems (like FreeDOS) can no longer boot natively on bare metal.
2. **Missing Video & Keyboard Hardware**: Modern GPUs lack legacy VGA register sets (ports `0x3C0`–`0x3DA`, text buffer `0xB8000`), and modern systems lack PS/2 controllers (8042), causing legacy DOS environments to crash or freeze.
3. **NVMe Isolation**: Real-mode DOS contains no native NVMe drivers. NVMe drives on modern systems are completely inaccessible to legacy DOS applications.
4. **IOMMU / VT-d Faults**: Even if an OS transitions from UEFI to real mode, active IOMMU translation units (Intel VT-d / AMD-Vi) block unmapped DMA attempts, causing immediate system freezes.

---

## The Solution: `uefiDOS`

`uefiDOS` packages a streamlined, fast-booting UEFI environment that:
- **Boots natively via UEFI** on any x86-64 machine (Secure Boot configurable).
- **Probes all storage devices** (NVMe, SATA, SAS, USB).
- **Spawns a hardware-accelerated VM86/KVM container** that boots pure FreeDOS and user payloads.
- **Translates NVMe to IDE/AHCI**: Presents NVMe drives to DOS as standard IDE or AHCI SATA controllers, enabling high-speed DMA routines to test, access, and benchmark NVMe drives at gigabyte-per-second throughput.
- **Audio Support**: Emulates classic Sound Blaster 16 (`sb16`) and AdLib (`adlib`) sound cards for classic games and media.
- **Emulates Display & Input**: Emulates standard VGA (mapped seamlessly to UEFI GOP display) and PS/2 keyboard (mapped to modern USB HID/Bluetooth keyboards).

---

## Repository Structure

```
uefiDOS/
├── .github/
│   └── workflows/
│       └── build-media.yml   # Automated CI build of bootable ISO & USB images
├── docs/
│   ├── USB_BOOT_GUIDE.md     # USB flash and boot instructions
│   └── WORKFLOW.md           # Step-by-step verification and test workflow
├── scripts/
│   ├── inject_payload.py     # Universal payload injector (.iso, .img, .exe)
│   ├── make_bootable_iso.py  # Bootable hybrid UEFI ISO generator
│   ├── make_usb_image.sh     # Bootable GPT raw disk image builder
│   ├── run-qemu.sh           # Linux/macOS QEMU runner
│   └── run-qemu.ps1          # Windows PowerShell QEMU runner
├── src/
│   ├── initramfs_init.sh     # Lightweight init script and drive discovery rules
│   └── storage_mapper.py     # Hypervisor launcher with AHCI/IDE parameter mapping
├── DESIGN.md                 # Detailed technical design & engineering rationale
└── README.md                 # Project overview and quick start
```

---

## Quick Start (Local Testing)

### Prerequisites
- **QEMU** (`qemu-system-x86_64`)
- **uefiDOS.iso** (Built via CI or locally)

### Running on Windows
```powershell
.\scripts\run-qemu.ps1 -IsoPath .\artifacts\uefiDOS.iso -DiskSizeGB 4
```

### Running on Linux
```bash
chmod +x ./scripts/run-qemu.sh
./scripts/run-qemu.sh -i ./artifacts/uefiDOS.iso -s 4G
```

---

## Providing Your Custom Payloads

`uefiDOS` boots into a clean, open-source FreeDOS environment by default. You can easily provide any custom DOS diagnostic, disk utility, or executable using any of the methods below:

### Option 1: Assist Script Injection (`scripts/inject_payload.py`)

The bundled assistant script [`scripts/inject_payload.py`](scripts/inject_payload.py) can inject:
- **DOS Executables** (`.EXE` / `.COM`)
- **Floppy Disk Images** (`.IMG` / `.IMA` / `.VFD`)
- **Bootable El Torito ISOs** (`.ISO`, automatically extracts the bootable executable)

#### Single-Target Injection (ISO or USB image):
```bash
# Inject into an ISO for VMware or Rufus:
python scripts/inject_payload.py --payload /path/to/APP.EXE --iso artifacts/uefiDOS.iso

# Or inject using a bootable floppy or CD image as the payload:
python scripts/inject_payload.py --payload /path/to/diagnostic.iso --iso artifacts/uefiDOS.iso
```

#### Batch Injection Across All Media (`--all`):
To update the ISO, the raw GPT USB image, the direct-extract ZIP, and generate a standalone boot floppy all in one pass:
```bash
python scripts/inject_payload.py --payload /path/to/APP.EXE --all artifacts
```

#### Automatic Baseline Protection (`-plain` vs `-injected`):
When run, the script preserves the clean baseline:
1. It creates pristine master copies (`uefiDOS-plain.iso`, `uefiDOS-plain-usb.img`, `uefiDOS-plain-usb-files.zip`) before modifying anything.
2. Subsequent runs restore from the `-plain` copy first, preventing cumulative or corrupted mutations.
3. It creates dedicated `-injected` copies (`uefiDOS-injected.iso`, etc.) alongside the active working files.
*(To disable duplication and modify in-place only, pass `--no-duplicate`)*.

---

### Option 2: Live USB Injection (No Rebuilding Needed)

If you have already flashed `uefiDOS-usb.img` or extracted `uefiDOS-usb-files.zip` to a USB drive:
1. Copy your payload file (`.EXE`, `.IMG`, `.ISO`, or `.VHD`) onto the USB drive (e.g. into the `DOS/` folder or root).
2. Boot the PC and press **`[E]`** during the boot countdown to enter the Maintenance & Router TUI.
3. Select **`[A] Live Media Selector`** to pick your disk image from the USB drive. It is staged directly into RAM for Drive `A:` for that session immediately.

---

### Option 3: Drop into Repository Root Before Build
Drop any `.exe`, `.iso`, or `.img` into the repository root before triggering the CI/CD build workflow, and it will be staged automatically into the built media.

---

## License

SPDX-License-Identifier: MIT

# USB Creation and Boot Guide for `uefiDOS`

This guide outlines how to build bootable USB media that takes any FreeDOS payload, diagnostic ISO, floppy image, or DOS executable and boots it seamlessly on pure UEFI Class 3 (CSM-free) machines.

---

## 1. Overview of the Boot Chain

```
[ UEFI Motherboard Firmware (Class 3 / Pure UEFI) ]
                       │
                       ▼
    [ /EFI/BOOT/BOOTX64.EFI (UefiDosShim) ]
       - Scans PCI bus for SATA/AHCI controllers
       - Validates BAR5 (< 4GB)
       - Arms Bus Master & Memory Space Enables
       - Checks ACPI DMAR (IOMMU status)
                       │
                       ▼
  [ /EFI/BOOT/freedos.efi (Unified Kernel Image) ]
       - Auto-detects all physical disks (NVMe + SATA)
       - Runs storage mapper and payload discovery
                       │
                       ▼
  [ Hardware-Accelerated QEMU/KVM Virtual Machine ]
       - Presents drives as i440fx IDE / ICH9 AHCI
       - Boots virtual floppy or ISO
                       │
                       ▼
        [ Pure FreeDOS / DOS Runtime at Full Speed ]
```

---

## 2. Directory Layout on the USB Drive (FAT32)

Format your USB flash drive with a single **FAT32** partition (or EFI System Partition) with the following structure:

```
USB_ROOT/
├── EFI/
│   └── BOOT/
│       ├── BOOTX64.EFI              # The compiled UEFI Shim application
│       ├── freedos.efi              # Unified Kernel Image (Kernel + Initramfs)
│       └── grubx64.efi              # Standalone fallback bootloader
│
├── DOS.CFG                          # Runtime settings (mode=a, rw=0, disks=all)
├── DOS.ID                           # Media detection identifier
│
└── DOS/
    ├── boot.iso                     # Optional user-provided bootable ISO
    ├── floppy.img                   # Optional user-provided boot floppy
    └── [APP].EXE                    # Optional user-provided DOS executable
```

---

## 3. How to Create and Inject Bootable Media

### Option A: Using the Payload Injection Assist Script (`scripts/inject_payload.py`)
Use this method to inject your payload prior to flashing or booting in virtual machines:

```bash
# Inject into an ISO for VMware or Rufus:
python scripts/inject_payload.py --payload /path/to/APP.EXE --iso artifacts/uefiDOS.iso

# Inject across all artifacts (ISO, USB .img, and USB .zip) in one pass:
python scripts/inject_payload.py --payload /path/to/APP.EXE --all artifacts
```

- **Supported Payloads**: `.EXE`, `.COM`, `.IMG` (1.44MB floppy), or bootable El Torito `.ISO`.
- **Automatic Baseline Safeguards**: The script automatically preserves pristine `uefiDOS-plain.*` master copies and produces dedicated `uefiDOS-injected.*` deliverables.

### Option B: Pre-Flashed USB / Live Media Injection
If you already have a formatted/flashed USB drive:
1. Download `uefiDOS-usb-files.zip` and extract its contents to the root of a FAT32 USB drive (or flash `uefiDOS-usb.img` via Rufus/BalenaEtcher).
2. Copy your custom payload (`.EXE`, `.IMG`, `.ISO`, or `.VHD`) onto the USB drive.
3. Boot the USB on the target PC.
4. Press **`[E]`** during the 5-second startup prompt to enter the Maintenance & Router TUI.
5. Choose **`[A] Live Media Selector`** to mount your image into RAM for Drive `A:` for that session immediately without needing to recreate the USB.

---

## 4. Booting on Modern Pure UEFI PCs

1. Plug the USB drive into the target PC.
2. Enter firmware settings (F2 / F12 / Del depending on motherboard):
   - **Secure Boot**: Set to **Disabled**.
   - **Intel VMD / RAID Mode** (if applicable): Set SATA controller mode to **AHCI**.
3. Select your USB drive from the UEFI One-Time Boot Menu (`F12` / `F8` / `F11`).
4. The system will:
   - Display the `[uefiDOS]` hardware audit screen.
   - Detect and map all NVMe and SATA disks.
   - Boot FreeDOS and launch your active payload.

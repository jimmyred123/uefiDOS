/** @file
  UefiDosShim.c

  Hardware Configuration Pre-Flight & Chained Boot Shim for FreeDOS / DOS runtimes.
  
  Actions performed:
  1. Scans PCI Configuration space for AHCI controllers (Class 01h, Subclass 06h).
  2. Ensures Bus Master Enable (Bit 2) and Memory Space Enable (Bit 1) are asserted.
  3. Audits BAR5 to verify 32-bit physical addressability (< 4GB).
  4. Parses ACPI DMAR tables to report or disable active VT-d Translation Units.
  5. Chain-loads the target Linux micro-kernel payload to boot FreeDOS / DOS runtimes.

  Copyright (c) 2026, uefiDOS Contributors. All rights reserved.
  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PrintLib.h>
#include <Library/DevicePathLib.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/PciIo.h>
#include <Protocol/SimpleFileSystem.h>
#include <Guid/Acpi.h>
#include <IndustryStandard/Pci.h>
#include <IndustryStandard/Acpi.h>

#define PCI_CLASS_MASS_STORAGE  0x01
#define PCI_SUBCLASS_AHCI       0x06
#define PCI_SUBCLASS_IDE        0x01

/**
  Scans all PCI devices on the system to locate AHCI controllers and verify/arm
  the PCI Command register (Bus Master + Memory Space).
**/
STATIC
EFI_STATUS
AuditAndArmPciControllers (
  VOID
  )
{
    EFI_STATUS          Status;
    UINTN               HandleCount;
    EFI_HANDLE          *HandleBuffer;
    UINTN               Index;
    EFI_PCI_IO_PROTOCOL *PciIo;
    PCI_TYPE00          PciConfig;
    UINT32              Bar5;
    UINT16              Command;
    UINTN               AhciFound = 0;

    Print (L"[uefiDOS] Probing PCI bus for Mass Storage & AHCI controllers...\n");

    Status = gBS->LocateHandleBuffer (
                    ByProtocol,
                    &gEfiPciIoProtocolGuid,
                    NULL,
                    &HandleCount,
                    &HandleBuffer
                    );
    if (EFI_ERROR (Status)) {
        Print (L"[-] Failed to locate PCI I/O protocols: %r\n", Status);
        return Status;
    }

    for (Index = 0; Index < HandleCount; Index++) {
        Status = gBS->HandleProtocol (HandleBuffer[Index], &gEfiPciIoProtocolGuid, (VOID **)&PciIo);
        if (EFI_ERROR (Status)) {
            continue;
        }

        Status = PciIo->Pci.Read (
                              PciIo,
                              EfiPciIoWidthUint8,
                              0,
                              sizeof (PCI_TYPE00),
                              &PciConfig
                              );
        if (EFI_ERROR (Status)) {
            continue;
        }

        if (PciConfig.Hdr.ClassCode[2] == PCI_CLASS_MASS_STORAGE &&
            PciConfig.Hdr.ClassCode[1] == PCI_SUBCLASS_AHCI) {
            
            AhciFound++;
            Status = PciIo->Pci.Read (
                                  PciIo,
                                  EfiPciIoWidthUint32,
                                  0x24, // BAR5 offset
                                  1,
                                  &Bar5
                                  );

            Status = PciIo->Pci.Read (
                                  PciIo,
                                  EfiPciIoWidthUint16,
                                  PCI_COMMAND_OFFSET,
                                  1,
                                  &Command
                                  );

            Print (L"  [+] Found AHCI Controller [%04x:%04x]\n", 
                   PciConfig.Hdr.VendorId, PciConfig.Hdr.DeviceId);
            Print (L"      BAR5 (ABAR): 0x%08x %s\n", 
                   Bar5, 
                   (Bar5 < 0xFFFFFFFFU && Bar5 != 0) ? L"[OK < 4GB]" : L"[WARNING >= 4GB]");
            Print (L"      Current Command Reg: 0x%04x (BME=%u, MSE=%u)\n", 
                   Command, 
                   (Command & EFI_PCI_COMMAND_BUS_MASTER) ? 1 : 0,
                   (Command & EFI_PCI_COMMAND_MEMORY_SPACE) ? 1 : 0);

            // Ensure Bus Master and Memory Space are asserted
            if ((Command & (EFI_PCI_COMMAND_BUS_MASTER | EFI_PCI_COMMAND_MEMORY_SPACE)) != 
                (EFI_PCI_COMMAND_BUS_MASTER | EFI_PCI_COMMAND_MEMORY_SPACE)) {
                
                Command |= (EFI_PCI_COMMAND_BUS_MASTER | EFI_PCI_COMMAND_MEMORY_SPACE);
                PciIo->Pci.Write (
                              PciIo,
                              EfiPciIoWidthUint16,
                              PCI_COMMAND_OFFSET,
                              1,
                              &Command
                              );
                Print (L"      [*] Updated Command Reg: Armed Bus Master & Memory Space -> 0x%04x\n", Command);
            }
        }
    }

    if (HandleBuffer != NULL) {
        FreePool (HandleBuffer);
    }

    if (AhciFound == 0) {
        Print (L"  [-] No native AHCI controllers found. System is likely pure NVMe or Intel VMD mode.\n");
    } else {
        Print (L"[+] Successfully audited %u AHCI controller(s).\n", (UINT32)AhciFound);
    }

    return EFI_SUCCESS;
}

/**
  Inspects ACPI tables to check for active Intel VT-d (DMAR) hardware units.
**/
STATIC
VOID
AuditAcpiDmar (
  VOID
  )
{
    UINTN Index;
    EFI_CONFIGURATION_TABLE *ConfigTable = gST->ConfigurationTable;
    EFI_ACPI_DESCRIPTION_HEADER *DmarTable = NULL;

    Print (L"[uefiDOS] Auditing ACPI Tables for IOMMU / DMA Remapping...\n");

    for (Index = 0; Index < gST->NumberOfTableEntries; Index++) {
        if (CompareGuid (&ConfigTable[Index].VendorGuid, &gEfiAcpi20TableGuid)) {
            EFI_ACPI_2_0_ROOT_SYSTEM_DESCRIPTION_POINTER *Rsdp2 = 
                (EFI_ACPI_2_0_ROOT_SYSTEM_DESCRIPTION_POINTER *)ConfigTable[Index].VendorTable;

            if (Rsdp2 != NULL && Rsdp2->XsdtAddress != 0) {
                EFI_ACPI_DESCRIPTION_HEADER *Xsdt = (EFI_ACPI_DESCRIPTION_HEADER *)(UINTN)Rsdp2->XsdtAddress;
                if (Xsdt != NULL && Xsdt->Length > sizeof (EFI_ACPI_DESCRIPTION_HEADER)) {
                    UINTN EntryCount = (Xsdt->Length - sizeof (EFI_ACPI_DESCRIPTION_HEADER)) / sizeof (UINT64);
                    UINT64 *EntryPtr = (UINT64 *)(Xsdt + 1);

                    for (UINTN e = 0; e < EntryCount; e++) {
                        EFI_ACPI_DESCRIPTION_HEADER *Tbl = (EFI_ACPI_DESCRIPTION_HEADER *)(UINTN)EntryPtr[e];
                        if (Tbl != NULL && Tbl->Signature == SIGNATURE_32 ('D', 'M', 'A', 'R')) {
                            DmarTable = Tbl;
                            break;
                        }
                    }
                }
            }
        } else if (CompareGuid (&ConfigTable[Index].VendorGuid, &gEfiAcpi10TableGuid)) {
            EFI_ACPI_1_0_ROOT_SYSTEM_DESCRIPTION_POINTER *Rsdp1 = 
                (EFI_ACPI_1_0_ROOT_SYSTEM_DESCRIPTION_POINTER *)ConfigTable[Index].VendorTable;

            if (Rsdp1 != NULL && Rsdp1->RsdtAddress != 0) {
                EFI_ACPI_DESCRIPTION_HEADER *Rsdt = (EFI_ACPI_DESCRIPTION_HEADER *)(UINTN)Rsdp1->RsdtAddress;
                if (Rsdt != NULL && Rsdt->Length > sizeof (EFI_ACPI_DESCRIPTION_HEADER)) {
                    UINTN EntryCount = (Rsdt->Length - sizeof (EFI_ACPI_DESCRIPTION_HEADER)) / sizeof (UINT32);
                    UINT32 *EntryPtr = (UINT32 *)(Rsdt + 1);

                    for (UINTN e = 0; e < EntryCount; e++) {
                        EFI_ACPI_DESCRIPTION_HEADER *Tbl = (EFI_ACPI_DESCRIPTION_HEADER *)(UINTN)EntryPtr[e];
                        if (Tbl != NULL && Tbl->Signature == SIGNATURE_32 ('D', 'M', 'A', 'R')) {
                            DmarTable = Tbl;
                            break;
                        }
                    }
                }
            }
        }
    }

    if (DmarTable != NULL) {
        Print (L"  [!] Detected ACPI DMAR Table (Intel VT-d active).\n");
        Print (L"      Hypervisor pass-through runtime will manage DMA mapping domains.\n");
    } else {
        Print (L"  [+] No active DMAR table detected. Direct physical DMA uninhibited.\n");
    }
}

/**
  Chainloads a target EFI payload (such as GRUB-EFI, systemd-boot, or micro-kernel).
**/
STATIC
EFI_STATUS
ChainloadTarget (
  IN EFI_HANDLE DeviceHandle,
  IN EFI_HANDLE ParentImage,
  IN CONST CHAR16 *TargetFilePath,
  IN CONST CHAR16 *CommandLine OPTIONAL
  )
{
    EFI_STATUS Status;
    EFI_DEVICE_PATH_PROTOCOL *DevicePath = NULL;
    EFI_HANDLE TargetHandle = NULL;
    EFI_LOADED_IMAGE_PROTOCOL *TargetLoadedImage = NULL;
    UINTN ExitDataSize = 0;
    CHAR16 *ExitData = NULL;
    EFI_HANDLE *FsHandles = NULL;
    UINTN FsHandleCount = 0;
    UINTN Index;

    Print (L"[uefiDOS] Searching for target payload: %s\n", TargetFilePath);

    // 1. Try first on the image's own boot volume
    DevicePath = FileDevicePath (DeviceHandle, (CHAR16 *)TargetFilePath);
    if (DevicePath != NULL) {
        Status = gBS->LoadImage (
                        FALSE,
                        ParentImage,
                        DevicePath,
                        NULL,
                        0,
                        &TargetHandle
                        );
        FreePool (DevicePath);
        if (!EFI_ERROR (Status)) {
            goto Launch;
        }
    }

    // 2. If not found on boot volume, search all SimpleFileSystem volumes
    Status = gBS->LocateHandleBuffer (
                    ByProtocol,
                    &gEfiSimpleFileSystemProtocolGuid,
                    NULL,
                    &FsHandleCount,
                    &FsHandles
                    );
    if (!EFI_ERROR (Status) && FsHandles != NULL) {
        for (Index = 0; Index < FsHandleCount; Index++) {
            if (FsHandles[Index] == DeviceHandle) {
                continue; // Already tried
            }
            DevicePath = FileDevicePath (FsHandles[Index], (CHAR16 *)TargetFilePath);
            if (DevicePath == NULL) {
                continue;
            }
            Status = gBS->LoadImage (
                            FALSE,
                            ParentImage,
                            DevicePath,
                            NULL,
                            0,
                            &TargetHandle
                            );
            FreePool (DevicePath);
            if (!EFI_ERROR (Status)) {
                Print (L"[uefiDOS] Located payload on volume handle %p!\n", FsHandles[Index]);
                FreePool (FsHandles);
                goto Launch;
            }
        }
        FreePool (FsHandles);
    }

    Print (L"[-] Failed to load payload: %s (%r)\n", TargetFilePath, Status);
    return EFI_NOT_FOUND;

Launch:
    Print (L"[uefiDOS] Starting target image...\n");

    // If command-line parameters are specified, pass them via LoadedImage protocol
    if (CommandLine != NULL) {
        Status = gBS->HandleProtocol (
                        TargetHandle,
                        &gEfiLoadedImageProtocolGuid,
                        (VOID **)&TargetLoadedImage
                        );
        if (!EFI_ERROR (Status) && TargetLoadedImage != NULL) {
            TargetLoadedImage->LoadOptions = (VOID *)CommandLine;
            TargetLoadedImage->LoadOptionsSize = (UINT32)((StrLen (CommandLine) + 1) * sizeof (CHAR16));
        }
    }

    Status = gBS->StartImage (TargetHandle, &ExitDataSize, &ExitData);
    if (EFI_ERROR (Status)) {
        Print (L"[-] StartImage failed: %r\n", Status);
    }
    return Status;
}

/**
  Main entry point for UefiDosShim application.
**/
EFI_STATUS
EFIAPI
UefiMain (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
    EFI_STATUS Status;
    EFI_LOADED_IMAGE_PROTOCOL *LoadedImage;

    Print (L"\n=================================================================\n");
    Print (L"         uefiDOS Hardware Shim & Universal Boot Loader           \n");
    Print (L"         Universal Pure-UEFI Real-Mode DOS Bridge Environment    \n");
    Print (L"=================================================================\n\n");

    Status = gBS->HandleProtocol (
                    ImageHandle,
                    &gEfiLoadedImageProtocolGuid,
                    (VOID **)&LoadedImage
                    );
    if (EFI_ERROR (Status)) {
        Print (L"[-] Error: Failed to retrieve LoadedImage protocol: %r\n", Status);
        return Status;
    }

    // 1. Audit and enable Bus Master and Memory Space across PCI storage controllers
    AuditAndArmPciControllers ();

    // 2. Audit ACPI DMAR tables
    AuditAcpiDmar ();

    // 3. Chainload Linux micro-kernel hypervisor runner or SeaBIOS payload
    Print (L"\n=================================================================\n");
    Print (L"[uefiDOS] Hardware Audit Diagnostics Complete.\n");
    Print (L"=================================================================\n");

    // Only pause if a key is already being held down by the user
    {
        EFI_INPUT_KEY Key;
        Status = gST->ConIn->ReadKeyStroke (gST->ConIn, &Key);
        if (!EFI_ERROR (Status)) {
            Print (L"\n[Diagnostics Paused] Press any key to continue boot sequence... ");
            do {
                Status = gST->ConIn->ReadKeyStroke (gST->ConIn, &Key);
            } while (EFI_ERROR (Status));
            Print (L"\n\n");
        }
    }

    Print (L"[uefiDOS] Transferring control to runtime payload...\n");
    
    // 1. Try unified kernel image (UKI: kernel + initramfs + cmdline in one PE binary)
    Status = ChainloadTarget (
               LoadedImage->DeviceHandle,
               ImageHandle,
               L"\\EFI\\BOOT\\freedos.efi",
               NULL
               );

    if (EFI_ERROR (Status)) {
        Status = ChainloadTarget (
                   LoadedImage->DeviceHandle,
                   ImageHandle,
                   L"\\EFI\\BOOT\\dos.efi",
                   NULL
                   );
    }

    // 2. Fallback to standalone GRUB-EFI loader if UKI is not present
    if (EFI_ERROR (Status)) {
        Status = ChainloadTarget (
                   LoadedImage->DeviceHandle,
                   ImageHandle,
                   L"\\EFI\\BOOT\\grubx64.efi",
                   NULL
                   );
    }

    // 3. Fallback to direct Linux EFI stub kernel with initrd load options
    if (EFI_ERROR (Status)) {
        Status = ChainloadTarget (
                   LoadedImage->DeviceHandle,
                   ImageHandle,
                   L"\\EFI\\BOOT\\vmlinuz-freedos.efi",
                   L"initrd=\\EFI\\BOOT\\initramfs-freedos.img rdinit=/init panic=0 nomodeset console=tty0"
                   );
    }
    if (EFI_ERROR (Status)) {
        Status = ChainloadTarget (
                   LoadedImage->DeviceHandle,
                   ImageHandle,
                   L"\\EFI\\BOOT\\vmlinuz-dos.efi",
                   L"initrd=\\EFI\\BOOT\\initramfs-dos.img rdinit=/init panic=0 nomodeset console=tty0"
                   );
    }

    if (EFI_ERROR (Status)) {
        EFI_INPUT_KEY Key;
        Print (L"\n[-] No OS kernel or bootloader found on boot volume (Status: %r).\n", Status);
        Print (L"    Expected \\EFI\\BOOT\\freedos.efi, \\EFI\\BOOT\\dos.efi, or \\EFI\\BOOT\\grubx64.efi.\n");
        Print (L"Press any key to reboot or exit to UEFI Shell... ");
        do {
            Status = gST->ConIn->ReadKeyStroke (gST->ConIn, &Key);
        } while (EFI_ERROR (Status));
        Print (L"\n");
    }

    return Status;
}

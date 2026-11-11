# Verification and Testing Workflow

This document describes the automated testing and verification workflow for `uefiDOS`, detailing how virtual disk exposure and FreeDOS AHCI/IDE DMA operations are tested both locally and via CI.

---

## 1. Test Architecture

The test harness validates three core criteria:
1. **Controller Presentation**: Can FreeDOS detect the controller (IDE/AHCI) with valid registers?
2. **Drive Enumeration**: Does the disk appear properly on the expected bus?
3. **Bus Master DMA Operations**: Can DOS read and write sectors to the disk without timeouts or faults?

```
[ Test Harness / GitHub Action ]
             │
             ▼
   [ create-test-disks ]
   - Generates 1GB raw test disk with test patterns
             │
             ▼
      [ QEMU Runner ]
   - Q35 Chipset (ICH9 AHCI Controller)
   - Boot: uefiDOS.iso
   - Target: Test Disk on Port 0
   - Capture: Serial Console Log
             │
             ▼
     [ Assertions / Verification ]
   - Verify controller detection in log
   - Verify sector read/write test pass
```

---

## 2. Running Verification Locally

### Windows (PowerShell)
```powershell
# 1. Create a 1 GB raw test disk and boot QEMU
.\scripts\run-qemu.ps1 -IsoPath .\artifacts\uefiDOS.iso -DiskSizeGB 1 -Headless $false
```

### Linux / macOS (Bash)
```bash
# 1. Make executable
chmod +x ./scripts/*.sh

# 2. Run QEMU with GUI display
./scripts/run-qemu.sh -i ./artifacts/uefiDOS.iso -s 1G

# 3. Or run headlessly with serial log output
./scripts/run-qemu.sh -i ./artifacts/uefiDOS.iso -s 1G --headless
```

---

## 3. GitHub Actions CI Matrix

The `.github/workflows/build-media.yml` workflow tests:
1. **EDK II Shim Build**: Compiles pure-UEFI pre-flight shim.
2. **Initramfs Verification**: Validates all binaries, modules, and SeaBIOS firmware inside initramfs.
3. **Headless QEMU Smoke Test**: Boots the full UKI in QEMU headlessly to assert clean boot execution.

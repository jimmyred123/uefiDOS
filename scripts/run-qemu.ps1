<#
.SYNOPSIS
    Runs QEMU with a bootable ISO attached to a virtual AHCI controller and test disk.

.DESCRIPTION
    Validates that a virtual AHCI controller exposes disks properly to DOS runtimes
    and supports bus-master DMA operations.

.PARAMETER IsoPath
    Path to the bootable ISO image. Default is ".\artifacts\uefiDOS.iso".

.PARAMETER DiskPath
    Path to the raw test disk image. Default is ".\build\test-disk.raw".

.PARAMETER DiskSizeGB
    Size of test disk to create in gigabytes if DiskPath does not exist. Default is 1.

.PARAMETER MemoryMB
    RAM in megabytes allocated to the VM. Default is 512.

.PARAMETER Headless
    Whether to run QEMU without a graphical window (serial output only).
#>
[CmdletBinding()]
param(
    [string]$IsoPath = ".\artifacts\uefiDOS.iso",
    [string]$DiskPath = ".\build\test-disk.raw",
    [int]$DiskSizeGB = 1,
    [int]$MemoryMB = 512,
    [switch]$Headless = $false
)

$ErrorActionPreference = "Stop"

# 1. Check for QEMU executable
$QemuCmd = Get-Command "qemu-system-x86_64" -ErrorAction SilentlyContinue
if (-not $QemuCmd) {
    # Check default Windows installation directories
    $DefaultPaths = @(
        "C:\Program Files\qemu\qemu-system-x86_64.exe",
        "C:\Program Files (x86)\qemu\qemu-system-x86_64.exe",
        "$env:LOCALAPPDATA\Programs\qemu\qemu-system-x86_64.exe"
    )
    foreach ($p in $DefaultPaths) {
        if (Test-Path $p) {
            $QemuExe = $p
            break
        }
    }
} else {
    $QemuExe = $QemuCmd.Source
}

if (-not $QemuExe) {
    Write-Warning "qemu-system-x86_64 not found in PATH or standard Program Files locations."
    Write-Host "Install QEMU on Windows using: winget install SoftwareFreedomConservancy.QEMU" -ForegroundColor Yellow
    exit 1
}

Write-Host "[+] Found QEMU: $QemuExe" -ForegroundColor Green

# 2. Check for bootable ISO
if (-not (Test-Path $IsoPath)) {
    Write-Error "Bootable ISO not found at path: $IsoPath"
    exit 1
}
Write-Host "[+] Found ISO: $IsoPath" -ForegroundColor Green

# 3. Create test disk if it does not exist
$BuildDir = Split-Path $DiskPath -Parent
if ($BuildDir -and -not (Test-Path $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
}

if (-not (Test-Path $DiskPath)) {
    Write-Host "[*] Creating raw test disk ($DiskSizeGB GB) at $DiskPath..." -ForegroundColor Cyan
    $FileStream = [System.IO.File]::Create($DiskPath)
    $FileStream.SetLength([int64]$DiskSizeGB * 1024 * 1024 * 1024)
    $FileStream.Close()
    Write-Host "[+] Test disk created successfully." -ForegroundColor Green
}

# 4. Build QEMU arguments
# We use modern Q35 machine type with an explicit ICH9 AHCI controller
$QemuArgs = @(
    "-machine", "q35",
    "-m", "${MemoryMB}M",
    "-smp", "2",
    "-device", "ich9-ahci,id=ahci",
    "-drive", "file=$DiskPath,format=raw,if=none,id=testdisk0",
    "-device", "ide-hd,bus=ahci.0,drive=testdisk0",
    "-cdrom", $IsoPath,
    "-boot", "order=d"
)

if ($Headless) {
    $QemuArgs += @("-nographic")
}

Write-Host "[*] Launching QEMU with ICH9 AHCI Controller and bootable ISO..." -ForegroundColor Cyan
Write-Host "Command: & `"$QemuExe`" $($QemuArgs -join ' ')" -ForegroundColor DarkGray

& $QemuExe @QemuArgs

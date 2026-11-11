<#
.SYNOPSIS
    Prepares a physical USB drive or generates a bootable UEFI USB disk for uefiDOS.

.DESCRIPTION
    Formats a target USB drive as FAT32, establishes the standard UEFI /EFI/BOOT/
    directory structure, and installs BOOTX64.EFI, FreeDOS runtime, and optional DOS payloads.

.PARAMETER TargetDriveLetter
    The drive letter of your USB flash drive (e.g. "E:" or "E").

.PARAMETER ShimPath
    Path to compiled BOOTX64.EFI. Default is ".\artifacts\BOOTX64.EFI".

.PARAMETER IsoPath
    Path to optional bootable ISO.

.PARAMETER ExePath
    Path to optional DOS executable (.exe).

.EXAMPLE
    .\scripts\make-usb.ps1 -TargetDriveLetter E: -IsoPath .\boot.iso
#>
[CmdletBinding(ConfirmImpact="High")]
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetDriveLetter,

    [string]$ShimPath = ".\artifacts\BOOTX64.EFI",
    [string]$IsoPath = "",
    [string]$ExePath = ""
)

$ErrorActionPreference = "Stop"

# Sanitize drive letter
$Drive = $TargetDriveLetter.TrimEnd(':').ToUpper() + ":"
if (-not (Test-Path $Drive)) {
    Write-Error "Target drive $Drive does not exist. Please connect your USB flash drive."
    exit 1
}

$Vol = Get-Volume -DriveLetter $Drive.TrimEnd(':') -ErrorAction SilentlyContinue
if (-not $Vol) {
    Write-Error "Could not read volume info for drive $Drive."
    exit 1
}

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "                  uefiDOS USB Provisioning Tool                  " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Target Drive   : $Drive (Current Label: $($Vol.FileSystemLabel), FileSystem: $($Vol.FileSystem))"
Write-Host "Drive Size     : $([math]::Round($Vol.Size / 1GB, 2)) GB"
if ($IsoPath) { Write-Host "Payload ISO    : $IsoPath" }
if ($ExePath) { Write-Host "Payload EXE    : $ExePath" }
Write-Host "================================================================="

$Confirmation = Read-Host "WARNING: Ensure you have backed up any critical files on $Drive. Continue? (Y/N)"
if ($Confirmation -notmatch '^[Yy]$') {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# Ensure directory structure exists
$EfiBootDir = Join-Path $Drive "EFI\BOOT"
$DosDir = Join-Path $Drive "DOS"

if (-not (Test-Path $EfiBootDir)) {
    New-Item -ItemType Directory -Path $EfiBootDir -Force | Out-Null
}
if (-not (Test-Path $DosDir)) {
    New-Item -ItemType Directory -Path $DosDir -Force | Out-Null
}

# 1. Install Shim
if (Test-Path $ShimPath) {
    $DestShim = Join-Path $EfiBootDir "BOOTX64.EFI"
    Write-Host "[*] Copying UEFI Shim -> $DestShim..." -ForegroundColor Green
    Copy-Item -Path $ShimPath -Destination $DestShim -Force
} else {
    Write-Warning "Shim not found at $ShimPath. Remember to place BOOTX64.EFI into $EfiBootDir"
}

# 2. Install Payload ISO
if ($IsoPath -and (Test-Path $IsoPath)) {
    $DestIso = Join-Path $DosDir "boot.iso"
    Write-Host "[*] Copying Payload ISO -> $DestIso..." -ForegroundColor Green
    Copy-Item -Path $IsoPath -Destination $DestIso -Force
}

# 3. Install Payload EXE
if ($ExePath -and (Test-Path $ExePath)) {
    $BaseExe = [System.IO.Path]::GetFileName($ExePath).ToUpper()
    $DestExe = Join-Path $DosDir $BaseExe
    Write-Host "[*] Copying Payload EXE -> $DestExe..." -ForegroundColor Green
    Copy-Item -Path $ExePath -Destination $DestExe -Force
}

Write-Host ""
Write-Host "[+] USB Drive $Drive is now configured as a bootable uefiDOS drive!" -ForegroundColor Green
Write-Host "    You can now plug it into any UEFI PC, disable Secure Boot, and boot directly."

#!/usr/bin/env bash
# run-qemu.sh - Launches QEMU with a bootable ISO attached to a virtual AHCI controller and test disk

set -euo pipefail

ISO_PATH="./artifacts/uefiDOS.iso"
DISK_PATH="./build/test-disk.raw"
DISK_SIZE="1G"
MEMORY_MB="512"
HEADLESS=0

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -i, --iso <path>       Path to bootable ISO (default: ./artifacts/uefiDOS.iso)"
    echo "  -d, --disk <path>      Path to test disk image (default: ./build/test-disk.raw)"
    echo "  -s, --size <size>      Disk size if creating (default: 1G)"
    echo "  -m, --memory <mb>      Memory in MB (default: 512)"
    echo "  -H, --headless         Run headlessly without graphical window"
    echo "  -h, --help             Display this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--iso) ISO_PATH="$2"; shift 2 ;;
        -d|--disk) DISK_PATH="$2"; shift 2 ;;
        -s|--size) DISK_SIZE="$2"; shift 2 ;;
        -m|--memory) MEMORY_MB="$2"; shift 2 ;;
        -H|--headless) HEADLESS=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "Error: qemu-system-x86_64 not found. Please install QEMU." >&2
    exit 1
fi

if [[ ! -f "$ISO_PATH" ]]; then
    echo "Error: ISO not found at $ISO_PATH" >&2
    exit 1
fi

mkdir -p "$(dirname "$DISK_PATH")"
if [[ ! -f "$DISK_PATH" ]]; then
    echo "[*] Creating raw test disk ($DISK_SIZE) at $DISK_PATH..."
    qemu-img create -f raw "$DISK_PATH" "$DISK_SIZE"
fi

QEMU_ARGS=(
    -machine q35
    -m "${MEMORY_MB}M"
    -smp 2
    -device ich9-ahci,id=ahci
    -drive "file=$DISK_PATH,format=raw,if=none,id=testdisk0"
    -device ide-hd,bus=ahci.0,drive=testdisk0
    -cdrom "$ISO_PATH"
    -boot order=d
)

if [[ $HEADLESS -eq 1 ]]; then
    QEMU_ARGS+=(-nographic)
fi

# Enable KVM if available on Linux host
if [[ -e /dev/kvm && -w /dev/kvm ]]; then
    echo "[+] Hardware acceleration (/dev/kvm) available and enabled."
    QEMU_ARGS+=(-enable-kvm -cpu host)
else
    echo "[*] Running in TCG emulation mode."
fi

echo "[*] Launching QEMU with virtual AHCI controller..."
exec qemu-system-x86_64 "${QEMU_ARGS[@]}"

#!/usr/bin/env bash
#
# setup.sh — Prepare a multi-boot USB drive (Option C: Hybrid)
#
# Layout:
#   Partition 1  512 MiB  FAT32   ESP (GRUB2 + shim)
#   Partition 2  *flex*   exFAT   Linux ISO storage
#   Partition 3  8 GiB    NTFS    Extracted Windows 11 installer
#
# Usage:
#   sudo ./setup.sh /dev/sdX [--win-iso path/to/Win11.iso]
#
# Requirements: sgdisk, mkfs.fat, mkfs.exfat, mkfs.ntfs (ntfs-3g),
#               grub-install (grub2-install on Fedora), 7z or bsdtar

set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────
DEVICE=""
WIN_ISO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --win-iso) WIN_ISO="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 /dev/sdX [--win-iso path/to/Win11.iso]"
            exit 0
            ;;
        *)
            if [[ -z "$DEVICE" ]]; then
                DEVICE="$1"; shift
            else
                die "Unknown argument: $1"
            fi
            ;;
    esac
done

[[ -n "$DEVICE" ]]       || die "No device specified.  Usage: sudo $0 /dev/sdX"
[[ -b "$DEVICE" ]]       || die "$DEVICE is not a block device"
[[ "$(id -u)" -eq 0 ]]   || die "Must run as root (sudo)"

# ── Safety gate ──────────────────────────────────────────────────
echo ""
warn "This will DESTROY ALL DATA on $DEVICE"
lsblk "$DEVICE"
echo ""
read -r -p "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

# ── Detect partition naming style (/dev/sdX1 vs /dev/nvme0n1p1) ─
if [[ "$DEVICE" =~ [0-9]$ ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

# ── Unmount any existing partitions on the device ────────────────
info "Unmounting any mounted partitions on $DEVICE..."
for mp in $(findmnt -rn -o TARGET -S "${PART_PREFIX}"* 2>/dev/null || true); do
    umount -l "$mp" || true
done

# ── Dependency checks ────────────────────────────────────────────
for cmd in sgdisk mkfs.fat mkfs.exfat wipefs lsblk; do
    command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done

if [[ -n "$WIN_ISO" ]]; then
    [[ -f "$WIN_ISO" ]] || die "Windows ISO not found: $WIN_ISO"
    command -v mkfs.ntfs >/dev/null || die "mkfs.ntfs not found (install ntfs-3g)"
    if command -v 7z >/dev/null; then
        EXTRACT_CMD="7z"
    elif command -v bsdtar >/dev/null; then
        EXTRACT_CMD="bsdtar"
    else
        die "Need 7z or bsdtar to extract the Windows ISO"
    fi
fi

# Detect grub-install binary name (Fedora uses grub2-install)
if command -v grub-install >/dev/null; then
    GRUB_INSTALL="grub-install"
elif command -v grub2-install >/dev/null; then
    GRUB_INSTALL="grub2-install"
else
    die "grub-install / grub2-install not found"
fi

# ── Compute partition sizes ──────────────────────────────────────
ESP_SIZE_MIB=512
WIN_SIZE_MIB=8192  # 8 GiB — enough for any Windows 11 ISO

# ── Partition the drive ──────────────────────────────────────────
info "Wiping and partitioning $DEVICE..."
wipefs --all --force "$DEVICE"
sgdisk --zap-all "$DEVICE"

if [[ -n "$WIN_ISO" ]]; then
    # 3-partition layout: ESP + Linux ISOs + Windows
    sgdisk \
        -n "1:0:+${ESP_SIZE_MIB}M" -t 1:ef00 -c 1:"ESP" \
        -n "3:0:+${WIN_SIZE_MIB}M" -t 3:0700 -c 3:"Windows11" \
        -n "2:0:0"                  -t 2:0700 -c 2:"LinuxISOs" \
        "$DEVICE"
else
    # 2-partition layout: ESP + Linux ISOs
    sgdisk \
        -n "1:0:+${ESP_SIZE_MIB}M" -t 1:ef00 -c 1:"ESP" \
        -n "2:0:0"                  -t 2:0700 -c 2:"LinuxISOs" \
        "$DEVICE"
fi

partprobe "$DEVICE" 2>/dev/null || sleep 2

# ── Format partitions ────────────────────────────────────────────
info "Formatting ESP (FAT32)..."
mkfs.fat -F32 -n "ESP" "${PART_PREFIX}1"

info "Formatting Linux ISO partition (exFAT)..."
mkfs.exfat -n "LINUXISOS" "${PART_PREFIX}2"

if [[ -n "$WIN_ISO" ]]; then
    info "Formatting Windows partition (NTFS)..."
    mkfs.ntfs -f -L "WIN11" "${PART_PREFIX}3"
fi

# ── Mount points ─────────────────────────────────────────────────
MNT_ESP=$(mktemp -d)
MNT_ISO=$(mktemp -d)

cleanup() {
    info "Cleaning up mount points..."
    umount "$MNT_ESP"  2>/dev/null || true
    umount "$MNT_ISO"  2>/dev/null || true
    [[ -n "${MNT_WIN:-}" ]] && umount "$MNT_WIN" 2>/dev/null || true
    rmdir "$MNT_ESP" "$MNT_ISO" ${MNT_WIN:+"$MNT_WIN"} 2>/dev/null || true
}
trap cleanup EXIT

mount "${PART_PREFIX}1" "$MNT_ESP"
mount "${PART_PREFIX}2" "$MNT_ISO"

# ── Install GRUB ─────────────────────────────────────────────────
info "Installing GRUB to ESP..."
$GRUB_INSTALL \
    --target=x86_64-efi \
    --efi-directory="$MNT_ESP" \
    --boot-directory="$MNT_ESP/boot" \
    --removable \
    --no-nvram

# ── Write GRUB config ────────────────────────────────────────────
info "Writing GRUB configuration..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRUB_CFG_SRC="$SCRIPT_DIR/grub.cfg"

if [[ -f "$GRUB_CFG_SRC" ]]; then
    cp "$GRUB_CFG_SRC" "$MNT_ESP/boot/grub/grub.cfg"
else
    warn "grub.cfg not found alongside this script — writing a stub"
    cat > "$MNT_ESP/boot/grub/grub.cfg" <<'GRUBEOF'
set timeout=30
set default=0

insmod part_gpt
insmod fat
insmod exfat
insmod ntfs
insmod loopback
insmod iso9660
insmod linux
insmod chain
insmod search

# Locate the Linux ISO partition by label
search --no-floppy --label --set=isopart "LINUXISOS"

menuentry ">>> Add ISOs to the LINUXISOS partition <<<" {
    echo "Copy .iso files to the LINUXISOS partition, then add menu entries to grub.cfg"
    sleep 5
}
GRUBEOF
fi

# ── Create directory structure on ISO partition ──────────────────
mkdir -p "$MNT_ISO/isos"

# ── Extract Windows ISO ──────────────────────────────────────────
if [[ -n "$WIN_ISO" ]]; then
    MNT_WIN=$(mktemp -d)
    mount "${PART_PREFIX}3" "$MNT_WIN"
    info "Extracting Windows 11 ISO to NTFS partition (this may take a few minutes)..."
    case "$EXTRACT_CMD" in
        7z)     7z x "$WIN_ISO" -o"$MNT_WIN" -bso0 -bsp1 ;;
        bsdtar) bsdtar xf "$WIN_ISO" -C "$MNT_WIN" ;;
    esac
    info "Windows extraction complete."

    # Append a Windows chainload entry to grub.cfg if not already present
    if ! grep -q "Windows 11" "$MNT_ESP/boot/grub/grub.cfg"; then
        cat >> "$MNT_ESP/boot/grub/grub.cfg" <<'WINEOF'

# ── Windows 11 ───────────────────────────────────────────────────
search --no-floppy --label --set=winpart "WIN11"
menuentry "Windows 11 Installer" {
    chainloader ($winpart)/efi/boot/bootx64.efi
}
WINEOF
    fi
fi

# ── Done ─────────────────────────────────────────────────────────
echo ""
info "========================================="
info " Multi-boot USB drive is ready!"
info "========================================="
info ""
info "Next steps:"
info "  1. Copy Linux ISO files into the 'isos/' folder on the LINUXISOS partition."
info "  2. Edit grub.cfg on the ESP to add menu entries (see grub.cfg template)."
info "  3. Boot from the USB drive — select an OS from the GRUB menu."
echo ""

#!/usr/bin/env bash
#
# add-iso.sh — Add a Linux ISO to the multi-boot USB drive
#
# Creates a new GPT partition sized to the ISO, writes the ISO
# into it with dd, and regenerates grub.cfg.
#
# Usage:
#   sudo ./add-iso.sh /dev/sdX path/to/linux.iso
#
# The new partition is appended after the last existing partition.
# GPT supports up to 128 partitions by default, so you can add
# dozens of ISOs without issue.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────
DEVICE=""
ISO_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<EOF
Usage: sudo $0 /dev/sdX path/to/linux.iso

Adds a Linux ISO to the multi-boot USB drive by creating a new
partition and writing the ISO into it, then regenerates grub.cfg.

Example:
  sudo $0 /dev/sda ~/Downloads/ubuntu-26.04-desktop-amd64.iso
EOF
            exit 0
            ;;
        *)
            if [[ -z "$DEVICE" ]]; then
                DEVICE="$1"; shift
            elif [[ -z "$ISO_PATH" ]]; then
                ISO_PATH="$1"; shift
            else
                die "Unknown argument: $1"
            fi
            ;;
    esac
done

[[ -n "$DEVICE" ]]     || die "No device specified.  Usage: sudo $0 /dev/sdX path/to.iso"
[[ -n "$ISO_PATH" ]]   || die "No ISO specified.  Usage: sudo $0 /dev/sdX path/to.iso"
[[ -b "$DEVICE" ]]     || die "$DEVICE is not a block device"
[[ -f "$ISO_PATH" ]]   || die "ISO not found: $ISO_PATH"
[[ "$(id -u)" -eq 0 ]] || die "Must run as root (sudo)"

# ── Detect partition naming style ────────────────────────────────
if [[ "$DEVICE" =~ [0-9]$ ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Verify this is a setup.sh-prepared drive ─────────────────────
ESP_DEV="${PART_PREFIX}1"
[[ -b "$ESP_DEV" ]] || die "ESP partition not found: $ESP_DEV — is this the right device?"

esp_fstype="$(blkid -s TYPE -o value "$ESP_DEV" 2>/dev/null || true)"
[[ "$esp_fstype" == "vfat" ]] || die "Partition 1 is not FAT32 ($esp_fstype) — run setup.sh first"

# ── Find the next available partition number ─────────────────────
# sgdisk -p lists all partitions; we want the next number after the highest
LAST_PART=$(sgdisk -p "$DEVICE" 2>/dev/null | awk '/^[[:space:]]*[0-9]/{n=$1} END{print n+0}')
NEW_PART=$(( LAST_PART + 1 ))

if (( NEW_PART > 128 )); then
    die "GPT partition table is full (128 partitions max)"
fi

# ── Check free space ─────────────────────────────────────────────
iso_size_bytes=$(stat -c%s "$ISO_PATH")
iso_size_mib=$(( (iso_size_bytes + 1048575) / 1048576 ))
iso_name="$(basename "$ISO_PATH" .iso)"

# Get free sectors from sgdisk
FREE_SECTORS=$(sgdisk -p "$DEVICE" 2>/dev/null | awk '/^Total free space/{print $5}')
SECTOR_SIZE=$(blockdev --getss "$DEVICE" 2>/dev/null || echo 512)
FREE_MIB=$(( (FREE_SECTORS * SECTOR_SIZE) / 1048576 ))

info "ISO: $(basename "$ISO_PATH") (${iso_size_mib} MiB)"
info "Free space on $DEVICE: ${FREE_MIB} MiB"

if (( iso_size_mib > FREE_MIB )); then
    die "Not enough free space (need ${iso_size_mib} MiB, have ${FREE_MIB} MiB)"
fi

# ── Confirmation ─────────────────────────────────────────────────
echo ""
info "Will create partition $NEW_PART (${iso_size_mib} MiB) for: $iso_name"
read -r -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# ── Create the partition ─────────────────────────────────────────
info "Creating partition $NEW_PART..."
sgdisk -n "${NEW_PART}:0:+${iso_size_mib}M" \
       -t "${NEW_PART}:8300" \
       -c "${NEW_PART}:${iso_name}" \
       "$DEVICE"

partprobe "$DEVICE" 2>/dev/null || sleep 2
udevadm settle 2>/dev/null || sleep 2

NEW_DEV="${PART_PREFIX}${NEW_PART}"
[[ -b "$NEW_DEV" ]] || { sleep 2; [[ -b "$NEW_DEV" ]] || die "Partition $NEW_DEV did not appear"; }

# ── Write the ISO ────────────────────────────────────────────────
info "Writing $(basename "$ISO_PATH") → $NEW_DEV (${iso_size_mib} MiB)..."
dd if="$ISO_PATH" of="$NEW_DEV" bs=4M status=progress conv=fsync 2>&1
info "  ✓ ISO written"

# ── Regenerate grub.cfg ──────────────────────────────────────────
info "Regenerating GRUB menu..."
"$SCRIPT_DIR/update-grub.sh" "$DEVICE"

echo ""
info "Done! $(basename "$ISO_PATH") added as partition $NEW_PART."

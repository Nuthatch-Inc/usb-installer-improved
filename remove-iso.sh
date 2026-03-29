#!/usr/bin/env bash
#
# remove-iso.sh — Remove an ISO partition from the multi-boot USB drive
#
# Deletes the specified partition and regenerates grub.cfg.
# The freed space can be reclaimed by future add-iso.sh calls
# (sgdisk will reuse gaps in the partition table).
#
# Usage:
#   sudo ./remove-iso.sh /dev/sdX <partition-number>
#   sudo ./remove-iso.sh /dev/sdX --list     # show ISO partitions
#
# WARNING: Partition numbers may shift after removal. Always use
# --list to verify partition numbers before removing.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────
DEVICE=""
PART_NUM=""
LIST_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list|-l)
            LIST_MODE=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: sudo $0 /dev/sdX <partition-number>
       sudo $0 /dev/sdX --list

Removes an ISO partition from the multi-boot USB drive and
regenerates grub.cfg.

Options:
  --list, -l   List all ISO partitions on the device
  -h, --help   Show this help

Examples:
  sudo $0 /dev/sda --list        # see what's installed
  sudo $0 /dev/sda 3             # remove partition 3
EOF
            exit 0
            ;;
        *)
            if [[ -z "$DEVICE" ]]; then
                DEVICE="$1"; shift
            elif [[ -z "$PART_NUM" ]]; then
                PART_NUM="$1"; shift
            else
                die "Unknown argument: $1"
            fi
            ;;
    esac
done

[[ -n "$DEVICE" ]]     || die "No device specified.  Usage: sudo $0 /dev/sdX <part-num>"
[[ -b "$DEVICE" ]]     || die "$DEVICE is not a block device"
[[ "$(id -u)" -eq 0 ]] || die "Must run as root (sudo)"

# ── Detect partition naming style ────────────────────────────────
if [[ "$DEVICE" =~ [0-9]$ ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── List mode ────────────────────────────────────────────────────
list_iso_partitions() {
    info "ISO partitions on $DEVICE:"
    echo ""
    printf "  %-6s  %-8s  %-10s  %s\n" "PART#" "SIZE" "TYPE" "LABEL"
    printf "  %-6s  %-8s  %-10s  %s\n" "-----" "--------" "----------" "-----"

    local found=0
    while IFS= read -r part_name; do
        local part_dev="/dev/$part_name"
        [[ -b "$part_dev" ]] || continue
        [[ "$part_dev" != "${PART_PREFIX}1" ]] || continue  # skip ESP

        local fstype partlabel size part_num_str
        fstype="$(blkid -s TYPE -o value "$part_dev" 2>/dev/null || true)"
        partlabel="$(blkid -s PARTLABEL -o value "$part_dev" 2>/dev/null || true)"
        size="$(lsblk -rno SIZE "$part_dev" 2>/dev/null || true)"

        # Extract partition number
        part_num_str="${part_dev##*[!0-9]}"

        case "$fstype" in
            iso9660|udf)
                printf "  %-6s  %-8s  %-10s  %s\n" "$part_num_str" "$size" "$fstype" "$partlabel"
                ((found++)) || true
                ;;
            ntfs)
                printf "  %-6s  %-8s  %-10s  %s  (Windows)\n" "$part_num_str" "$size" "$fstype" "$partlabel"
                ;;
        esac
    done < <(lsblk -rno NAME "$DEVICE" 2>/dev/null | tail -n +2)

    echo ""
    if [[ $found -eq 0 ]]; then
        info "No ISO partitions found."
    else
        info "$found ISO partition(s) found."
        info "To remove: sudo $0 $DEVICE <partition-number>"
    fi
}

if $LIST_MODE; then
    list_iso_partitions
    exit 0
fi

# ── Validate partition number ────────────────────────────────────
[[ -n "$PART_NUM" ]] || die "No partition number specified.  Use --list to see partitions."

# Don't allow removing the ESP
if [[ "$PART_NUM" -eq 1 ]]; then
    die "Cannot remove partition 1 (ESP). That's the bootloader!"
fi

TARGET_DEV="${PART_PREFIX}${PART_NUM}"
[[ -b "$TARGET_DEV" ]] || die "Partition $TARGET_DEV does not exist"

# Show what we're about to remove
fstype="$(blkid -s TYPE -o value "$TARGET_DEV" 2>/dev/null || true)"
partlabel="$(blkid -s PARTLABEL -o value "$TARGET_DEV" 2>/dev/null || true)"
size="$(lsblk -rno SIZE "$TARGET_DEV" 2>/dev/null || true)"

echo ""
warn "About to DELETE partition $PART_NUM:"
warn "  Device:  $TARGET_DEV"
warn "  Size:    $size"
warn "  Type:    $fstype"
warn "  Label:   $partlabel"
echo ""
read -r -p "Type YES to confirm deletion: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

# ── Unmount if mounted ───────────────────────────────────────────
umount -f "$TARGET_DEV" 2>/dev/null || umount -l "$TARGET_DEV" 2>/dev/null || true

# ── Delete the partition ─────────────────────────────────────────
info "Deleting partition $PART_NUM..."
sgdisk -d "$PART_NUM" "$DEVICE"

partprobe "$DEVICE" 2>/dev/null || sleep 2
udevadm settle 2>/dev/null || sleep 2

info "  ✓ Partition $PART_NUM deleted"

# ── Regenerate grub.cfg ──────────────────────────────────────────
info "Regenerating GRUB menu..."
"$SCRIPT_DIR/update-grub.sh" "$DEVICE"

echo ""
info "Done! Partition $PART_NUM ($partlabel) has been removed."
info "The freed space can be reused by add-iso.sh."

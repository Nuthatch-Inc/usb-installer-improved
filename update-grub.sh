#!/usr/bin/env bash
#
# update-grub.sh — Scan ISOs on the USB and write a static grub.cfg
#
# This is step 2 of the multi-boot USB workflow:
#   1. sudo ./setup.sh /dev/sdX [--win-iso ...]   — partition & format
#   2. Copy .iso files to isos/ on the LINUXISOS partition
#   3. sudo ./update-grub.sh /dev/sdX              — rebuild GRUB menu
#
# Run this again whenever you add, remove, or rename ISOs.
#
# The generated grub.cfg uses ONLY modules built into Ubuntu's signed
# grubx64.efi (no insmod lines), so it is fully Secure Boot compatible.
#
# Note: Ubuntu's signed GRUB only has FAT/ext2/btrfs/iso9660 built
# in — it CANNOT read the exFAT LINUXISOS partition.  This script
# extracts vmlinuz + initrd from each ISO into boot/kernels/<slug>/
# on the ESP (FAT32), which GRUB can always read.  The running Linux
# kernel has its own exFAT driver and locates each ISO at boot time
# via iso-scan/filename (or equivalent kernel parameter).
#
# Supported distro families (auto-detected by mounting each ISO):
#   - Ubuntu / Mint / Pop!_OS / elementary   (casper)
#   - Fedora / RHEL / CentOS / Rocky / Alma  (Anaconda / pxeboot)
#   - Debian / Kali / Tails                   (debian-live)
#   - Arch Linux / EndeavourOS                (archiso)
#   - openSUSE / SLES                         (SUSE loader)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────
DEVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: sudo $0 /dev/sdX"
            echo ""
            echo "Scans ISOs on the LINUXISOS partition and writes a static"
            echo "grub.cfg to the ESP. Run after adding or removing ISOs."
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

# ── Detect partition naming style ────────────────────────────────
if [[ "$DEVICE" =~ [0-9]$ ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

ESP_DEV="${PART_PREFIX}1"
ISO_DEV="${PART_PREFIX}2"
WIN_DEV="${PART_PREFIX}3"

[[ -b "$ESP_DEV" ]] || die "ESP partition not found: $ESP_DEV"
[[ -b "$ISO_DEV" ]] || die "ISO partition not found: $ISO_DEV"

# ── Get UUIDs ────────────────────────────────────────────────────
ESP_UUID="$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)"
[[ -n "$ESP_UUID" ]] || die "Could not read UUID for $ESP_DEV"

ISO_UUID="$(blkid -s UUID -o value "$ISO_DEV" 2>/dev/null || true)"
[[ -n "$ISO_UUID" ]] || die "Could not read UUID for $ISO_DEV"

WIN_UUID=""
if [[ -b "$WIN_DEV" ]]; then
    WIN_UUID="$(blkid -s UUID -o value "$WIN_DEV" 2>/dev/null || true)"
fi

# ── Mount partitions ─────────────────────────────────────────────
MNT_ESP=$(mktemp -d)
MNT_ISO=$(mktemp -d)
MNT_PROBE=$(mktemp -d)

cleanup() {
    umount "$MNT_PROBE" 2>/dev/null || true
    umount "$MNT_ISO"   2>/dev/null || true
    umount "$MNT_ESP"   2>/dev/null || true
    rmdir "$MNT_ESP" "$MNT_ISO" "$MNT_PROBE" 2>/dev/null || true
}
trap cleanup EXIT

mount "$ESP_DEV" "$MNT_ESP"
mount "$ISO_DEV" "$MNT_ISO"

# ── Verify expected layout ───────────────────────────────────────
[[ -d "$MNT_ESP/EFI/BOOT" ]] || die "ESP does not have EFI/BOOT — run setup.sh first"
[[ -d "$MNT_ISO/isos" ]]     || { warn "No isos/ directory found — creating it"; mkdir -p "$MNT_ISO/isos"; }

# ── Scan ISOs and detect distro families ─────────────────────────
declare -a ENTRIES=()
ISO_COUNT=0

detect_distro() {
    local mnt="$1"
    if [[ -f "$mnt/casper/vmlinuz" ]]; then
        echo "casper"
    elif [[ -f "$mnt/images/pxeboot/vmlinuz" ]]; then
        echo "fedora"
    elif [[ -f "$mnt/live/vmlinuz" ]]; then
        echo "debian-live"
    elif [[ -f "$mnt/arch/boot/x86_64/vmlinuz-linux" ]]; then
        echo "arch"
    elif [[ -f "$mnt/boot/x86_64/loader/linux" ]]; then
        echo "opensuse"
    else
        echo "unknown"
    fi
}

# Generate a human-friendly label from an ISO filename
pretty_name() {
    local name="$1"
    # Strip .iso extension
    name="${name%.iso}"
    # Replace common separators with spaces
    name="${name//-/ }"
    name="${name//_/ }"
    echo "$name"
}

info "Scanning ISOs in $MNT_ISO/isos/..."

# ── Prepare extraction directory for kernels/initrds ─────────────
# Ubuntu's signed GRUB has only FAT/ext2/btrfs/iso9660 built in —
# no exFAT and no NTFS.  The LINUXISOS partition is exFAT, so GRUB
# cannot read it at all.  We therefore extract vmlinuz + initrd to
# the ESP (FAT32), which GRUB can always access.  The running Linux
# kernel has its own exFAT driver and locates the ISO at runtime via
# iso-scan/filename (or equivalent kernel parameter).
BOOT_DIR="$MNT_ESP/boot/kernels"
if [[ -d "$BOOT_DIR" ]]; then
    info "Cleaning previous kernel extractions..."
    rm -rf "$BOOT_DIR"
fi
mkdir -p "$BOOT_DIR"

# Warn if ESP is getting tight (kernels ~110 MB per ISO)
ESP_AVAIL_KB=$(df -k --output=avail "$MNT_ESP" | tail -1)
if (( ESP_AVAIL_KB < 150000 )); then
    warn "Less than 150 MB free on the ESP — some ISOs may not fit."
    warn "Consider increasing the ESP size in setup.sh if you need many ISOs."
fi

for iso in "$MNT_ISO"/isos/*.iso; do
    [[ -f "$iso" ]] || continue

    filename="$(basename "$iso")"
    isopath="/isos/$filename"
    label="$(pretty_name "$filename")"

    info "  Found: $filename"

    # Mount the ISO to probe its layout and extract kernel/initrd
    mount -o loop,ro "$iso" "$MNT_PROBE" 2>/dev/null || {
        warn "    Could not mount $filename — skipping"
        continue
    }

    dtype="$(detect_distro "$MNT_PROBE")"
    info "    Detected: $dtype"
    ((ISO_COUNT++)) || true

    # Sanitised directory name for extracted kernel + initrd
    slug="${filename%.iso}"
    extract_dir="$BOOT_DIR/$slug"
    mkdir -p "$extract_dir"

    case "$dtype" in
        casper)
            info "    Extracting kernel + initrd (casper)..."
            cp "$MNT_PROBE/casper/vmlinuz" "$extract_dir/vmlinuz"
            cp "$MNT_PROBE/casper/initrd"  "$extract_dir/initrd"
            ENTRIES+=("
menuentry \"$label\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz boot=casper iso-scan/filename=$isopath quiet splash ---
    initrd (\$esppart)/boot/kernels/$slug/initrd
}

menuentry \"$label  (safe graphics)\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz boot=casper iso-scan/filename=$isopath quiet splash nomodeset ---
    initrd (\$esppart)/boot/kernels/$slug/initrd
}")
            ;;
        fedora)
            info "    Extracting kernel + initrd (fedora)..."
            cp "$MNT_PROBE/images/pxeboot/vmlinuz"   "$extract_dir/vmlinuz"
            cp "$MNT_PROBE/images/pxeboot/initrd.img" "$extract_dir/initrd"
            ENTRIES+=("
menuentry \"$label\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz iso-scan/filename=$isopath rd.live.image quiet
    initrd (\$esppart)/boot/kernels/$slug/initrd
}

menuentry \"$label  (basic graphics)\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz iso-scan/filename=$isopath rd.live.image nomodeset quiet
    initrd (\$esppart)/boot/kernels/$slug/initrd
}")
            ;;
        debian-live)
            info "    Extracting kernel + initrd (debian-live)..."
            cp "$MNT_PROBE/live/vmlinuz"    "$extract_dir/vmlinuz"
            cp "$MNT_PROBE/live/initrd.img" "$extract_dir/initrd"
            ENTRIES+=("
menuentry \"$label\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz boot=live findiso=$isopath quiet splash ---
    initrd (\$esppart)/boot/kernels/$slug/initrd
}

menuentry \"$label  (safe graphics)\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz boot=live findiso=$isopath quiet splash nomodeset ---
    initrd (\$esppart)/boot/kernels/$slug/initrd
}")
            ;;
        arch)
            info "    Extracting kernel + initrd (arch)..."
            cp "$MNT_PROBE/arch/boot/x86_64/vmlinuz-linux"       "$extract_dir/vmlinuz"
            cp "$MNT_PROBE/arch/boot/x86_64/initramfs-linux.img" "$extract_dir/initrd"
            ENTRIES+=("
menuentry \"$label\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz img_dev=/dev/disk/by-uuid/$ISO_UUID img_loop=$isopath earlymodules=loop
    initrd (\$esppart)/boot/kernels/$slug/initrd
}

menuentry \"$label  (safe graphics)\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz img_dev=/dev/disk/by-uuid/$ISO_UUID img_loop=$isopath earlymodules=loop nomodeset
    initrd (\$esppart)/boot/kernels/$slug/initrd
}")
            ;;
        opensuse)
            info "    Extracting kernel + initrd (opensuse)..."
            cp "$MNT_PROBE/boot/x86_64/loader/linux"  "$extract_dir/vmlinuz"
            cp "$MNT_PROBE/boot/x86_64/loader/initrd" "$extract_dir/initrd"
            ENTRIES+=("
menuentry \"$label\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz iso-scan/filename=$isopath splash=silent quiet
    initrd (\$esppart)/boot/kernels/$slug/initrd
}

menuentry \"$label  (safe graphics)\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz iso-scan/filename=$isopath splash=silent quiet nomodeset
    initrd (\$esppart)/boot/kernels/$slug/initrd
}")
            ;;
        *)
            warn "    Unrecognised ISO layout — attempting casper fallback extraction"
            cp "$MNT_PROBE/casper/vmlinuz" "$extract_dir/vmlinuz" 2>/dev/null || true
            cp "$MNT_PROBE/casper/initrd"  "$extract_dir/initrd"  2>/dev/null || true
            ENTRIES+=("
menuentry \"$label  (unrecognised — casper fallback)\" {
    linux (\$esppart)/boot/kernels/$slug/vmlinuz boot=casper iso-scan/filename=$isopath quiet splash ---
    initrd (\$esppart)/boot/kernels/$slug/initrd
}")
            ;;
    esac

    umount "$MNT_PROBE" 2>/dev/null || true
done

info "Found $ISO_COUNT ISO(s)"

# ── Build the Windows entry ──────────────────────────────────────
WIN_ENTRY=""
if [[ -n "$WIN_UUID" ]]; then
    WIN_ENTRY="
# ══════════════════════════════════════════════════════════════════
#  Windows 11
# ══════════════════════════════════════════════════════════════════

menuentry \"Windows 11 Installer\" {
    search --no-floppy --fs-uuid --set=winpart $WIN_UUID
    chainloader (\$winpart)/efi/boot/bootx64.efi
}"
fi

# ── Write grub.cfg ───────────────────────────────────────────────
GRUB_CFG="$MNT_ESP/boot/grub/grub.cfg"
mkdir -p "$(dirname "$GRUB_CFG")"

info "Writing grub.cfg to ESP..."

cat > "$GRUB_CFG" <<HEADER
# GRUB2 configuration for multi-boot USB
#
# Auto-generated by update-grub.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Do not edit manually — re-run update-grub.sh after changing ISOs.
#
# No insmod lines — all required modules are built into the signed
# grubx64.efi binary. Fully Secure Boot compatible.
#
# Kernels and initrds are extracted to boot/kernels/<slug>/ on the
# ESP (FAT32).  Ubuntu's signed GRUB only has FAT/ext2/btrfs/iso9660
# built in — it CANNOT read the exFAT ISO partition.  The running
# Linux kernel locates each ISO at boot time via iso-scan/filename.

set timeout=30
set default=0

# ── Locate the ESP by UUID (FAT32 — always readable by GRUB) ────
search --no-floppy --fs-uuid --set=esppart $ESP_UUID

HEADER

# Write ISO entries
if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    {
        echo "# ══════════════════════════════════════════════════════════════════"
        echo "#  Linux ISOs ($ISO_COUNT found)"
        echo "# ══════════════════════════════════════════════════════════════════"
        for entry in "${ENTRIES[@]}"; do
            echo "$entry"
        done
    } >> "$GRUB_CFG"
else
    cat >> "$GRUB_CFG" <<'NOISO'
menuentry ">>> No ISOs found — copy .iso files to isos/ on LINUXISOS <<<" {
    echo "No ISO files were found when update-grub.sh last ran."
    echo "Copy .iso files to the isos/ directory, then run:"
    echo "  sudo ./update-grub.sh /dev/sdX"
    sleep 15
}
NOISO
fi

# Write Windows entry
if [[ -n "$WIN_ENTRY" ]]; then
    echo "$WIN_ENTRY" >> "$GRUB_CFG"
fi

# Write utility entries
cat >> "$GRUB_CFG" <<'UTILS'

# ══════════════════════════════════════════════════════════════════
#  Utilities
# ══════════════════════════════════════════════════════════════════

menuentry "UEFI Firmware Settings" {
    fwsetup
}

menuentry "Reboot" {
    reboot
}

menuentry "Power Off" {
    halt
}
UTILS

sync
info "grub.cfg written successfully."
echo ""

# ── Show summary ─────────────────────────────────────────────────
info "Menu entries:"
grep -oP '(?<=menuentry ").*(?=")' "$GRUB_CFG" | while IFS= read -r entry; do
    info "  • $entry"
done
echo ""
info "Done. Reboot from the USB to see the updated menu."

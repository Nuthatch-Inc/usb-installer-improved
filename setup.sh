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
# Secure Boot: Run ./download-efi.sh first to fetch signed shim + GRUB
#              binaries into efi/. The script also falls back to system
#              binaries or grub-install --force if efi/ is not populated.
#
# Dependencies are auto-installed for supported distros:
#   Debian/Ubuntu, Fedora, RHEL/CentOS/Rocky, Arch, openSUSE, Void, Alpine
# Manual installs need: sgdisk, mkfs.fat, mkfs.exfat, mkfs.ntfs (ntfs-3g),
#                        grub-install (grub2-install on Fedora), 7z or bsdtar,
#                        partprobe (parted)

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

# ── Helper: forcefully unmount every partition on the device ─────
unmount_device() {
    info "Unmounting any mounted partitions on $DEVICE..."

    # 1) Unmount by device path (works even when lsblk can't resolve mounts)
    while IFS= read -r part; do
        [[ -n "$part" ]] && { umount -f "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true; }
    done < <(lsblk -rno NAME "$DEVICE" 2>/dev/null | awk 'NR>1{print "/dev/" $1}')

    # 2) Also unmount by mountpoint (catches stale/orphaned mounts)
    while IFS= read -r mp; do
        [[ -n "$mp" ]] && { umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true; }
    done < <(lsblk -rno MOUNTPOINTS "$DEVICE" 2>/dev/null)

    # 3) Verify — if anything is still mounted, abort rather than corrupt data
    local remaining
    remaining=$(lsblk -rno MOUNTPOINTS "$DEVICE" 2>/dev/null | grep -c '[^[:space:]]' || true)
    if [[ "$remaining" -gt 0 ]]; then
        warn "Some partitions are still mounted — attempting to kill holders..."
        while IFS= read -r part; do
            [[ -n "$part" ]] && fuser -km "/dev/$part" 2>/dev/null || true
        done < <(lsblk -rno NAME "$DEVICE" 2>/dev/null | tail -n +2)
        sleep 1
        # Final lazy unmount sweep
        while IFS= read -r mp; do
            [[ -n "$mp" ]] && { umount -l "$mp" 2>/dev/null || true; }
        done < <(lsblk -rno MOUNTPOINTS "$DEVICE" 2>/dev/null)
    fi
}

unmount_device

# ── Detect distro & install dependencies ─────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -is | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}

install_deps() {
    local distro
    distro="$(detect_distro)"
    info "Detected Linux distribution: $distro"

    # Base packages needed for all runs
    local -a base_pkgs=()
    # Extra packages needed only for Windows ISO extraction
    local -a win_pkgs=()

    case "$distro" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|neon)
            base_pkgs=(gdisk dosfstools exfatprogs parted util-linux grub-efi-amd64-bin)
            win_pkgs=(ntfs-3g p7zip-full)
            PKGMGR="apt"
            ;;
        fedora)
            base_pkgs=(gdisk dosfstools exfatprogs parted util-linux grub2-efi-x64 grub2-efi-x64-modules)
            win_pkgs=(ntfs-3g p7zip p7zip-plugins)
            PKGMGR="dnf"
            ;;
        rhel|centos|rocky|alma|ol)
            base_pkgs=(gdisk dosfstools exfatprogs parted util-linux grub2-efi-x64 grub2-efi-x64-modules)
            win_pkgs=(ntfs-3g p7zip p7zip-plugins)
            PKGMGR="dnf"
            ;;
        opensuse*|suse|sles)
            base_pkgs=(gptfdisk dosfstools exfatprogs parted util-linux grub2-x86_64-efi)
            win_pkgs=(ntfs-3g p7zip)
            PKGMGR="zypper"
            ;;
        arch|manjaro|endeavouros|garuda|cachyos)
            base_pkgs=(gptfdisk dosfstools exfatprogs parted util-linux grub)
            win_pkgs=(ntfs-3g p7zip)
            PKGMGR="pacman"
            ;;
        void)
            base_pkgs=(gptfdisk dosfstools exfatprogs parted util-linux grub-x86_64-efi)
            win_pkgs=(ntfs-3g p7zip)
            PKGMGR="xbps"
            ;;
        alpine)
            base_pkgs=(gptfdisk dosfstools exfatprogs parted util-linux grub-efi)
            win_pkgs=(ntfs-3g-progs p7zip)
            PKGMGR="apk"
            ;;
        *)
            warn "Unrecognised distro '$distro' — skipping automatic dependency install."
            warn "Please ensure the following are installed: sgdisk mkfs.fat mkfs.exfat wipefs lsblk grub-install partprobe"
            [[ -n "$WIN_ISO" ]] && warn "For Windows ISO support also install: mkfs.ntfs, 7z or bsdtar"
            return 0
            ;;
    esac

    # Merge win_pkgs if a Windows ISO was supplied
    local -a all_pkgs=("${base_pkgs[@]}")
    if [[ -n "$WIN_ISO" ]]; then
        all_pkgs+=("${win_pkgs[@]}")
    fi

    info "Installing dependencies via $PKGMGR: ${all_pkgs[*]}"
    case "$PKGMGR" in
        apt)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${all_pkgs[@]}"
            ;;
        dnf)
            dnf install -y --quiet "${all_pkgs[@]}"
            ;;
        zypper)
            zypper --non-interactive install --no-confirm "${all_pkgs[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm --needed "${all_pkgs[@]}"
            ;;
        xbps)
            xbps-install -Sy "${all_pkgs[@]}"
            ;;
        apk)
            apk add --quiet "${all_pkgs[@]}"
            ;;
    esac

    info "Dependencies installed successfully."
}

install_deps

# ── Dependency checks (verify everything is actually available) ──
for cmd in sgdisk mkfs.fat mkfs.exfat wipefs lsblk partprobe; do
    command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done

command -v blkid >/dev/null || die "Required command not found: blkid"

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
    GRUB_INSTALL=""
fi

# ── Locate signed Secure Boot binaries ───────────────────────────
# Priority: 1) bundled efi/  2) system paths  3) grub-install --force
find_first() {
    for path in "$@"; do
        [[ -f "$path" ]] && { echo "$path"; return 0; }
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLED_EFI="$SCRIPT_DIR/efi/boot"
BUNDLED_MODS="$SCRIPT_DIR/efi/grub-modules"

SHIM_EFI=""
GRUB_EFI=""
MM_EFI=""
GRUB_MODULES_DIR=""

# 1) Bundled binaries (from download-efi.sh)
SHIM_EFI=$(find_first "$BUNDLED_EFI/BOOTX64.EFI") || true
GRUB_EFI=$(find_first "$BUNDLED_EFI/grubx64.efi") || true
MM_EFI=$(find_first   "$BUNDLED_EFI/mmx64.efi")   || true
[[ -d "$BUNDLED_MODS" ]] && GRUB_MODULES_DIR="$BUNDLED_MODS"

if [[ -n "$SHIM_EFI" && -n "$GRUB_EFI" ]]; then
    info "Using bundled Secure Boot binaries from efi/boot/"
else
    # 2) System-installed binaries
    SHIM_EFI=$(find_first \
        /boot/efi/EFI/fedora/shimx64.efi \
        /boot/efi/EFI/redhat/shimx64.efi \
        /boot/efi/EFI/centos/shimx64.efi \
        /usr/lib/shim/shimx64.efi.signed \
        /usr/lib/shim/shimx64.efi \
        /usr/share/efi/x86_64/shim.efi \
        /boot/efi/EFI/opensuse/shim.efi) || true

    GRUB_EFI=$(find_first \
        /boot/efi/EFI/fedora/grubx64.efi \
        /boot/efi/EFI/redhat/grubx64.efi \
        /boot/efi/EFI/centos/grubx64.efi \
        /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
        /usr/lib/grub/x86_64-efi-signed/grubx64.efi \
        /boot/efi/EFI/opensuse/grubx64.efi) || true

    MM_EFI=$(find_first \
        /boot/efi/EFI/fedora/mmx64.efi \
        /boot/efi/EFI/redhat/mmx64.efi \
        /boot/efi/EFI/centos/mmx64.efi) || true
fi

# Locate GRUB modules directory (bundled or system)
if [[ -z "$GRUB_MODULES_DIR" ]]; then
    for d in /usr/lib/grub/x86_64-efi /usr/lib64/grub/x86_64-efi /usr/share/grub2/x86_64-efi; do
        [[ -d "$d" ]] && { GRUB_MODULES_DIR="$d"; break; }
    done
fi

if [[ -n "$SHIM_EFI" && -n "$GRUB_EFI" ]]; then
    USE_SHIM=true
    info "Secure Boot binaries:"
    info "  shim:  $SHIM_EFI"
    info "  grub:  $GRUB_EFI"
    [[ -n "$MM_EFI" ]]         && info "  mokm:  $MM_EFI"
    [[ -n "$GRUB_MODULES_DIR" ]] && info "  mods:  $GRUB_MODULES_DIR"
elif [[ -n "$GRUB_INSTALL" ]]; then
    USE_SHIM=false
    warn "Signed shim/GRUB not found — will use $GRUB_INSTALL --force"
    warn "Secure Boot will NOT be supported. Run ./download-efi.sh first for Secure Boot."
else
    die "No signed EFI binaries and no grub-install found. Run ./download-efi.sh first."
fi

# ── Compute partition sizes ──────────────────────────────────────
ESP_SIZE_MIB=512
WIN_SIZE_MIB=8192  # 8 GiB — enough for any Windows 11 ISO

# ── Save existing partition device paths before wiping ───────────
mapfile -t OLD_PARTS < <(lsblk -rno NAME "$DEVICE" 2>/dev/null | tail -n +2 | awk '{print "/dev/" $1}')

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

# Re-read the partition table and let the kernel settle
partprobe "$DEVICE" 2>/dev/null || sleep 2
udevadm settle 2>/dev/null || sleep 2

# Force-unmount the OLD partition paths saved before repartitioning.
# After sgdisk + partprobe the new /dev/sdX1 is a different partition,
# but the kernel may still hold a stale mount from the old /dev/sdX1.
info "Releasing stale mounts from previous partition table..."
for old_part in "${OLD_PARTS[@]}"; do
    umount -f "$old_part" 2>/dev/null || umount -l "$old_part" 2>/dev/null || true
done

# Also run the general unmount helper for any automounter remounts
unmount_device
sleep 1

# Final safety check — bail out if anything is still mounted
if lsblk -rno MOUNTPOINTS "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
    die "Failed to unmount all partitions on $DEVICE. Please unmount manually and retry."
fi

# ── Format partitions ────────────────────────────────────────────
info "Formatting ESP (FAT32)..."
mkfs.fat -F32 -n "ESP" "${PART_PREFIX}1"

info "Formatting Linux ISO partition (exFAT)..."
mkfs.exfat -n "LINUXISOS" "${PART_PREFIX}2"

if [[ -n "$WIN_ISO" ]]; then
    info "Formatting Windows partition (NTFS)..."
    mkfs.ntfs -f -L "WIN11" "${PART_PREFIX}3"
fi

# Capture filesystem UUIDs so GRUB can target this USB explicitly
ESP_UUID="$(blkid -s UUID -o value "${PART_PREFIX}1" || true)"
ISO_UUID="$(blkid -s UUID -o value "${PART_PREFIX}2" || true)"
[[ -n "$ESP_UUID" ]] || die "Could not read UUID for ${PART_PREFIX}1 (ESP)"
[[ -n "$ISO_UUID" ]] || die "Could not read UUID for ${PART_PREFIX}2 (LINUXISOS)"

if [[ -n "$WIN_ISO" ]]; then
    WIN_UUID="$(blkid -s UUID -o value "${PART_PREFIX}3" || true)"
    [[ -n "$WIN_UUID" ]] || die "Could not read UUID for ${PART_PREFIX}3 (WIN11)"
else
    WIN_UUID=""
fi

# ── Mount points ─────────────────────────────────────────────────
MNT_ESP=$(mktemp -d)
MNT_ISO=$(mktemp -d)

cleanup() {
    info "Syncing cached writes to USB (this may take a while for large files)..."
    sync
    info "Unmounting partitions..."
    umount "$MNT_ESP"  2>/dev/null || true
    umount "$MNT_ISO"  2>/dev/null || true
    [[ -n "${MNT_WIN:-}" ]] && umount "$MNT_WIN" 2>/dev/null || true
    rmdir "$MNT_ESP" "$MNT_ISO" ${MNT_WIN:+"$MNT_WIN"} 2>/dev/null || true
}
trap cleanup EXIT

mount "${PART_PREFIX}1" "$MNT_ESP"
mount "${PART_PREFIX}2" "$MNT_ISO"

# ── Install GRUB ─────────────────────────────────────────────────
if $USE_SHIM; then
    info "Installing signed shim + GRUB to ESP (Secure Boot compatible)..."
    mkdir -p "$MNT_ESP/EFI/BOOT"

    # shimx64.efi → BOOTX64.EFI  (this is what the firmware loads on removable media)
    cp "$SHIM_EFI" "$MNT_ESP/EFI/BOOT/BOOTX64.EFI"
    # signed grubx64.efi beside the shim (shim chainloads this by name)
    cp "$GRUB_EFI" "$MNT_ESP/EFI/BOOT/grubx64.efi"
    # MOK manager (optional, lets users enrol keys at boot)
    [[ -n "$MM_EFI" ]] && cp "$MM_EFI" "$MNT_ESP/EFI/BOOT/mmx64.efi"

    # Copy GRUB modules so grub.cfg can insmod loopback, iso9660, etc.
    if [[ -n "$GRUB_MODULES_DIR" ]]; then
        mkdir -p "$MNT_ESP/boot/grub/x86_64-efi"
        cp "$GRUB_MODULES_DIR"/*.{mod,lst} "$MNT_ESP/boot/grub/x86_64-efi/" 2>/dev/null || true
        info "Copied GRUB modules from $GRUB_MODULES_DIR"
    else
        warn "GRUB modules directory not found — some grub.cfg features may not work"
    fi
else
    info "Installing GRUB to ESP (without Secure Boot)..."
    $GRUB_INSTALL \
        --target=x86_64-efi \
        --efi-directory="$MNT_ESP" \
        --boot-directory="$MNT_ESP/boot" \
        --removable \
        --no-nvram \
        --force
fi

# ── Write GRUB config ────────────────────────────────────────────
info "Writing GRUB configuration..."
GRUB_CFG_SRC="$SCRIPT_DIR/grub.cfg"

mkdir -p "$MNT_ESP/boot/grub"

if [[ -f "$GRUB_CFG_SRC" ]]; then
    cp "$GRUB_CFG_SRC" "$MNT_ESP/boot/grub/grub.cfg"
else
    warn "grub.cfg not found alongside this script — writing a minimal stub"
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
insmod regexp

search --no-floppy --label --set=isopart "LINUXISOS"
search --no-floppy --label --set=winpart "WIN11"

for file in ($isopart)/isos/*.iso; do
    if [ ! -e "$file" ]; then break; fi
    regexp --set=1:isoname '\/isos\/(.+)$' "$file"
    regexp --set=1:isopath '(\/.*)$' "$file"
    menuentry "Boot ${isoname}" "$isopath" {
        loopback loop ($isopart)$1
        linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$1 quiet splash ---
        initrd (loop)/casper/initrd
    }
done

menuentry "Windows 11 Installer" {
    if [ -n "$winpart" ]; then
        chainloader ($winpart)/efi/boot/bootx64.efi
    else
        echo "Windows 11 partition not found."
        sleep 5
    fi
}
GRUBEOF
fi

# Replace label-based searches with UUID-based searches to avoid matching
# similarly-labeled internal disks (e.g. another "ESP" or "WIN11").
sed -i -E \
    "s#^search --no-floppy --label --set=isopart \"LINUXISOS\"#search --no-floppy --fs-uuid --set=isopart ${ISO_UUID}#" \
    "$MNT_ESP/boot/grub/grub.cfg"

if [[ -n "$WIN_UUID" ]]; then
    sed -i -E \
        "s#^search --no-floppy --label --set=winpart \"WIN11\"#search --no-floppy --fs-uuid --set=winpart ${WIN_UUID}#" \
        "$MNT_ESP/boot/grub/grub.cfg"
fi

# When using signed shim, the GRUB binary looks for grub.cfg relative to
# its own location (EFI/BOOT/) before /boot/grub/.  Place a small redirect
# so it always finds the real config.
if $USE_SHIM; then
    mkdir -p "$MNT_ESP/EFI/BOOT"
    cat > "$MNT_ESP/EFI/BOOT/grub.cfg" <<SHIMCFG
search --no-floppy --fs-uuid --set=esp ${ESP_UUID}
set prefix=(\$esp)/boot/grub
configfile (\$esp)/boot/grub/grub.cfg
SHIMCFG
    info "Wrote shim redirect config to EFI/BOOT/grub.cfg"
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
fi

# ── Done ─────────────────────────────────────────────────────────
echo ""
info "========================================="
info " Multi-boot USB drive is ready!"
info "========================================="
info ""
info "Next steps:"
info "  1. Copy Linux ISO files into the 'isos/' folder on the LINUXISOS partition."
info "  2. Boot from the USB drive — GRUB auto-detects every ISO and builds the menu."
info "     No need to edit grub.cfg — supported distros are recognised automatically."
echo ""

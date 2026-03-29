#!/usr/bin/env bash
#
# setup.sh — Prepare a multi-boot USB drive (partition-per-ISO)
#
# Layout:
#   Partition 1        512 MiB  FAT32      ESP (shim + GRUB + grub.cfg)
#   Partition 2..N     *auto*   ISO9660    Raw dd'd Linux ISOs
#   Partition N+1      8 GiB    FAT32      Extracted Windows 11 (optional)
#
# Each Linux ISO is written raw (dd) into its own GPT partition.
# The ISO9660 filesystem becomes directly readable by GRUB (which has
# iso9660 built in), so GRUB loads each distro's kernel and initrd
# straight from the ISO partition — no extraction needed, no exFAT
# issues, no chainloading headaches.
#
# Chainloading (loading the ISO's own EFI bootloader) does NOT work
# because UEFI firmware can only read FAT, not ISO9660. The
# chainloaded binary wouldn't be able to find its config files.
# Instead, our GRUB directly loads each distro's kernel+initrd from
# the ISO9660 partition (which GRUB CAN read), then the distro's
# initramfs locates its own squashfs on the same partition.
#
# Usage:
#   sudo ./setup.sh /dev/sdX --iso ubuntu.iso --iso fedora.iso
#   sudo ./setup.sh /dev/sdX --iso ubuntu.iso --win-iso Win11.iso
#
# To add ISOs later without wiping:
#   sudo ./add-iso.sh /dev/sdX path/to/new.iso
#
# Secure Boot: Run ./download-efi.sh first to fetch signed shim + GRUB
#              binaries into efi/. Falls back to system binaries or
#              grub-install --force if efi/ is not populated.
#
# Dependencies are auto-installed for supported distros.
# Manual installs need: sgdisk, mkfs.fat, wimlib-imagex (wimtools/wimlib-utils),
#                        7z or bsdtar (Windows only), partprobe (parted)

set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────
DEVICE=""
WIN_ISO=""
declare -a LINUX_ISOS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            [[ -n "${2:-}" ]] || die "--iso requires a path argument"
            LINUX_ISOS+=("$2"); shift 2 ;;
        --win-iso)
            [[ -n "${2:-}" ]] || die "--win-iso requires a path argument"
            WIN_ISO="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: sudo $0 /dev/sdX --iso path/to/linux.iso [--iso another.iso ...] [--win-iso path/to/Win11.iso]

Options:
  --iso PATH       Add a Linux ISO (can be repeated)
  --win-iso PATH   Add a Windows 11 ISO (extracted to FAT32 partition, large .wim files auto-split)
  -h, --help       Show this help

Example:
  sudo $0 /dev/sdX \\
      --iso ~/Downloads/ubuntu-26.04-desktop-amd64.iso \\
      --iso ~/Downloads/Fedora-Workstation-Live-x86_64-42.iso \\
      --win-iso ~/Downloads/Win11_24H2.iso
EOF
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

[[ -n "$DEVICE" ]]       || die "No device specified.  Usage: sudo $0 /dev/sdX --iso path/to.iso"
[[ -b "$DEVICE" ]]       || die "$DEVICE is not a block device"
[[ "$(id -u)" -eq 0 ]]   || die "Must run as root (sudo)"

if [[ ${#LINUX_ISOS[@]} -eq 0 && -z "$WIN_ISO" ]]; then
    die "No ISOs specified. Use --iso and/or --win-iso."
fi

# Validate all ISOs exist up front
for iso in "${LINUX_ISOS[@]}"; do
    [[ -f "$iso" ]] || die "ISO not found: $iso"
done
if [[ -n "$WIN_ISO" ]]; then
    [[ -f "$WIN_ISO" ]] || die "Windows ISO not found: $WIN_ISO"
fi

# ── Safety gate ──────────────────────────────────────────────────
echo ""
warn "This will DESTROY ALL DATA on $DEVICE"
lsblk "$DEVICE"
echo ""

# Show planned layout
DEVICE_SIZE_BYTES=$(blockdev --getsize64 "$DEVICE")
DEVICE_SIZE_GIB=$(( DEVICE_SIZE_BYTES / 1024 / 1024 / 1024 ))
info "Drive size: ${DEVICE_SIZE_GIB} GiB"
info "Planned layout:"
info "  Partition 1:  512 MiB  FAT32  ESP (GRUB bootloader)"

PART_NUM=2
TOTAL_MIB=512
for iso in "${LINUX_ISOS[@]}"; do
    iso_size_bytes=$(stat -c%s "$iso")
    iso_size_mib=$(( (iso_size_bytes + 1048575) / 1048576 ))
    info "  Partition $PART_NUM:  ${iso_size_mib} MiB  ISO9660  $(basename "$iso")"
    TOTAL_MIB=$(( TOTAL_MIB + iso_size_mib ))
    ((PART_NUM++))
done
if [[ -n "$WIN_ISO" ]]; then
    info "  Partition $PART_NUM:  8192 MiB  FAT32  Windows 11"
    TOTAL_MIB=$(( TOTAL_MIB + 8192 ))
fi
info "  Total used: ~$(( TOTAL_MIB / 1024 )) GiB of ${DEVICE_SIZE_GIB} GiB"

if (( TOTAL_MIB > DEVICE_SIZE_GIB * 1024 )); then
    die "ISOs exceed drive capacity (${TOTAL_MIB} MiB needed, $(( DEVICE_SIZE_GIB * 1024 )) MiB available)"
fi

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
    while IFS= read -r part; do
        [[ -n "$part" ]] && { umount -f "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true; }
    done < <(lsblk -rno NAME "$DEVICE" 2>/dev/null | awk 'NR>1{print "/dev/" $1}')
    while IFS= read -r mp; do
        [[ -n "$mp" ]] && { umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true; }
    done < <(lsblk -rno MOUNTPOINTS "$DEVICE" 2>/dev/null)
    local remaining
    remaining=$(lsblk -rno MOUNTPOINTS "$DEVICE" 2>/dev/null | grep -c '[^[:space:]]' || true)
    if [[ "$remaining" -gt 0 ]]; then
        warn "Some partitions still mounted — killing holders..."
        while IFS= read -r part; do
            [[ -n "$part" ]] && fuser -km "/dev/$part" 2>/dev/null || true
        done < <(lsblk -rno NAME "$DEVICE" 2>/dev/null | tail -n +2)
        sleep 1
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

    local -a base_pkgs=()
    local -a win_pkgs=()

    case "$distro" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|neon)
            base_pkgs=(gdisk dosfstools parted util-linux grub-efi-amd64-bin)
            win_pkgs=(wimtools p7zip-full)
            PKGMGR="apt"
            ;;
        fedora)
            base_pkgs=(gdisk dosfstools parted util-linux grub2-efi-x64 grub2-efi-x64-modules)
            win_pkgs=(wimlib-utils p7zip p7zip-plugins)
            PKGMGR="dnf"
            ;;
        rhel|centos|rocky|alma|ol)
            base_pkgs=(gdisk dosfstools parted util-linux grub2-efi-x64 grub2-efi-x64-modules)
            win_pkgs=(wimlib-utils p7zip p7zip-plugins)
            PKGMGR="dnf"
            ;;
        opensuse*|suse|sles)
            base_pkgs=(gptfdisk dosfstools parted util-linux grub2-x86_64-efi)
            win_pkgs=(wimlib-utils p7zip)
            PKGMGR="zypper"
            ;;
        arch|manjaro|endeavouros|garuda|cachyos)
            base_pkgs=(gptfdisk dosfstools parted util-linux grub)
            win_pkgs=(wimlib p7zip)
            PKGMGR="pacman"
            ;;
        void)
            base_pkgs=(gptfdisk dosfstools parted util-linux grub-x86_64-efi)
            win_pkgs=(wimlib p7zip)
            PKGMGR="xbps"
            ;;
        alpine)
            base_pkgs=(gptfdisk dosfstools parted util-linux grub-efi)
            win_pkgs=(wimlib p7zip)
            PKGMGR="apk"
            ;;
        *)
            warn "Unrecognised distro '$distro' — skipping automatic dependency install."
            warn "Please ensure: sgdisk mkfs.fat wipefs lsblk partprobe blkid dd"
            [[ -n "$WIN_ISO" ]] && warn "For Windows: wimlib-imagex, 7z or bsdtar"
            return 0
            ;;
    esac

    local -a all_pkgs=("${base_pkgs[@]}")
    [[ -n "$WIN_ISO" ]] && all_pkgs+=("${win_pkgs[@]}")

    info "Installing dependencies via $PKGMGR: ${all_pkgs[*]}"
    case "$PKGMGR" in
        apt)    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${all_pkgs[@]}" ;;
        dnf)    dnf install -y --quiet "${all_pkgs[@]}" ;;
        zypper) zypper --non-interactive install --no-confirm "${all_pkgs[@]}" ;;
        pacman) pacman -Sy --noconfirm --needed "${all_pkgs[@]}" ;;
        xbps)   xbps-install -Sy "${all_pkgs[@]}" ;;
        apk)    apk add --quiet "${all_pkgs[@]}" ;;
    esac
    info "Dependencies installed successfully."
}

install_deps

# ── Dependency checks ────────────────────────────────────────────
for cmd in sgdisk mkfs.fat wipefs lsblk partprobe blkid dd; do
    command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done

if [[ -n "$WIN_ISO" ]]; then
    command -v wimlib-imagex >/dev/null || die "wimlib-imagex not found (install wimtools or wimlib-utils)"
    if command -v 7z >/dev/null; then
        EXTRACT_CMD="7z"
    elif command -v bsdtar >/dev/null; then
        EXTRACT_CMD="bsdtar"
    else
        die "Need 7z or bsdtar to extract the Windows ISO"
    fi
fi

# Detect grub-install binary
if command -v grub-install >/dev/null; then
    GRUB_INSTALL="grub-install"
elif command -v grub2-install >/dev/null; then
    GRUB_INSTALL="grub2-install"
else
    GRUB_INSTALL=""
fi

# ── Locate signed Secure Boot binaries ───────────────────────────
find_first() {
    for path in "$@"; do
        [[ -f "$path" ]] && { echo "$path"; return 0; }
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLED_EFI="$SCRIPT_DIR/efi/boot"

SHIM_EFI=""
GRUB_EFI=""
MM_EFI=""

SHIM_EFI=$(find_first "$BUNDLED_EFI/BOOTX64.EFI") || true
GRUB_EFI=$(find_first "$BUNDLED_EFI/grubx64.efi") || true
MM_EFI=$(find_first   "$BUNDLED_EFI/mmx64.efi")   || true

if [[ -n "$SHIM_EFI" && -n "$GRUB_EFI" ]]; then
    USE_SHIM=true
    info "Using bundled Secure Boot binaries from efi/boot/"
else
    SHIM_EFI=$(find_first \
        /boot/efi/EFI/fedora/shimx64.efi \
        /boot/efi/EFI/redhat/shimx64.efi \
        /usr/lib/shim/shimx64.efi.signed \
        /usr/lib/shim/shimx64.efi \
        /boot/efi/EFI/opensuse/shim.efi) || true
    GRUB_EFI=$(find_first \
        /boot/efi/EFI/fedora/grubx64.efi \
        /boot/efi/EFI/redhat/grubx64.efi \
        /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
        /usr/lib/grub/x86_64-efi-signed/grubx64.efi \
        /boot/efi/EFI/opensuse/grubx64.efi) || true
    MM_EFI=$(find_first \
        /boot/efi/EFI/fedora/mmx64.efi \
        /boot/efi/EFI/redhat/mmx64.efi) || true

    if [[ -n "$SHIM_EFI" && -n "$GRUB_EFI" ]]; then
        USE_SHIM=true
        info "Using system Secure Boot binaries"
    elif [[ -n "$GRUB_INSTALL" ]]; then
        USE_SHIM=false
        warn "Signed shim/GRUB not found — will use $GRUB_INSTALL --force"
        warn "Secure Boot will NOT be supported. Run ./download-efi.sh first."
    else
        die "No signed EFI binaries and no grub-install found. Run ./download-efi.sh first."
    fi
fi

# ── Save old partitions & unmount ────────────────────────────────
mapfile -t OLD_PARTS < <(lsblk -rno NAME "$DEVICE" 2>/dev/null | tail -n +2 | awk '{print "/dev/" $1}')

# ── Wipe and partition ───────────────────────────────────────────
info "Wiping and partitioning $DEVICE..."
wipefs --all --force "$DEVICE"
sgdisk --zap-all "$DEVICE"

# Partition 1: ESP (512 MiB — only holds GRUB + config, no kernel extraction)
ESP_SIZE_MIB=512
sgdisk -n "1:0:+${ESP_SIZE_MIB}M" -t 1:ef00 -c 1:"ESP" "$DEVICE"

# Partitions 2..N: one per Linux ISO, sized exactly to the ISO
PART_NUM=2
declare -A ISO_PARTMAP=()   # maps partition number → ISO path
for iso in "${LINUX_ISOS[@]}"; do
    iso_name="$(basename "$iso" .iso)"
    iso_size_bytes=$(stat -c%s "$iso")
    iso_size_mib=$(( (iso_size_bytes + 1048575) / 1048576 ))  # round up

    info "  Partition $PART_NUM: ${iso_size_mib} MiB for $(basename "$iso")"
    sgdisk -n "${PART_NUM}:0:+${iso_size_mib}M" \
           -t "${PART_NUM}:8300" \
           -c "${PART_NUM}:${iso_name}" \
           "$DEVICE"

    ISO_PARTMAP[$PART_NUM]="$iso"
    ((PART_NUM++))
done

# Optional Windows partition (last, 8 GiB)
WIN_PART_NUM=""
if [[ -n "$WIN_ISO" ]]; then
    WIN_SIZE_MIB=8192
    info "  Partition $PART_NUM: ${WIN_SIZE_MIB} MiB for Windows 11"
    sgdisk -n "${PART_NUM}:0:+${WIN_SIZE_MIB}M" \
           -t "${PART_NUM}:0700" \
           -c "${PART_NUM}:Windows11" \
           "$DEVICE"
    WIN_PART_NUM=$PART_NUM
fi

# Re-read partition table
partprobe "$DEVICE" 2>/dev/null || sleep 2
udevadm settle 2>/dev/null || sleep 2

# Release stale mounts
info "Releasing stale mounts..."
for old_part in "${OLD_PARTS[@]}"; do
    umount -f "$old_part" 2>/dev/null || umount -l "$old_part" 2>/dev/null || true
done
unmount_device
sleep 1

if lsblk -rno MOUNTPOINTS "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
    die "Failed to unmount all partitions. Please unmount manually and retry."
fi

# ── Format ESP ───────────────────────────────────────────────────
info "Formatting ESP (FAT32)..."
mkfs.fat -F32 -n "ESP" "${PART_PREFIX}1"

# ── Write ISOs to their partitions ───────────────────────────────
for part_num in $(echo "${!ISO_PARTMAP[@]}" | tr ' ' '\n' | sort -n); do
    iso="${ISO_PARTMAP[$part_num]}"
    target="${PART_PREFIX}${part_num}"
    iso_name="$(basename "$iso")"
    iso_size_bytes=$(stat -c%s "$iso")
    iso_size_mib=$(( iso_size_bytes / 1048576 ))

    info "Writing $iso_name → $target (${iso_size_mib} MiB)..."
    dd if="$iso" of="$target" bs=4M status=progress conv=fsync 2>&1
    info "  ✓ $iso_name written"
done

# ── Format and extract Windows ───────────────────────────────────
# Windows partition is FAT32 so both GRUB and UEFI firmware can read it.
# Any .wim files exceeding FAT32's 4 GB limit are split with wimlib,
# exactly like Microsoft's Media Creation Tool does.
MNT_WIN=""
if [[ -n "$WIN_ISO" && -n "$WIN_PART_NUM" ]]; then
    win_dev="${PART_PREFIX}${WIN_PART_NUM}"
    info "Formatting Windows partition (FAT32)..."
    mkfs.fat -F32 -n "WIN11" "$win_dev"

    MNT_WIN=$(mktemp -d)
    mount "$win_dev" "$MNT_WIN"

    # Strategy: extract to a temp directory first, then split any
    # .wim files exceeding FAT32's 4 GB limit, then copy everything
    # to the FAT32 partition. We can't extract directly to FAT32
    # because 7z/bsdtar would fail on the >4 GB install.wim.
    WIN_STAGING=$(mktemp -d)
    info "Extracting Windows 11 ISO to staging area..."
    case "$EXTRACT_CMD" in
        7z)     7z x "$WIN_ISO" -o"$WIN_STAGING" -bso0 -bsp1 ;;
        bsdtar) bsdtar xf "$WIN_ISO" -C "$WIN_STAGING" ;;
    esac

    # Split any .wim files that exceed FAT32's 4 GB file size limit.
    # Windows Setup natively understands .swm (split WIM) files.
    # This is the same approach Microsoft's Media Creation Tool uses.
    FAT32_MAX=4294967295  # 4 GiB - 1 byte
    while IFS= read -r -d '' wim_file; do
        wim_size=$(stat -c%s "$wim_file")
        if (( wim_size > FAT32_MAX )); then
            wim_name="$(basename "$wim_file")"
            swm_name="${wim_name%.wim}.swm"
            swm_dir="$(dirname "$wim_file")"
            info "  Splitting $wim_name ($(( wim_size / 1048576 )) MiB) into .swm chunks..."
            wimlib-imagex split "$wim_file" "$swm_dir/$swm_name" 3800
            rm -f "$wim_file"
            info "  ✓ $wim_name split into .swm files"
        fi
    done < <(find "$WIN_STAGING" -name '*.wim' -print0 2>/dev/null)

    info "Copying Windows files to FAT32 partition..."
    cp -a "$WIN_STAGING"/. "$MNT_WIN"/
    rm -rf "$WIN_STAGING"

    info "  ✓ Windows extraction complete"
fi

# ── Install GRUB to ESP ─────────────────────────────────────────
MNT_ESP=$(mktemp -d)

cleanup() {
    info "Syncing cached writes..."
    sync
    info "Unmounting..."
    umount "$MNT_ESP" 2>/dev/null || true
    [[ -n "$MNT_WIN" ]] && { umount "$MNT_WIN" 2>/dev/null || true; }
    rmdir "$MNT_ESP" 2>/dev/null || true
    [[ -n "$MNT_WIN" ]] && { rmdir "$MNT_WIN" 2>/dev/null || true; }
    [[ -n "${WIN_STAGING:-}" ]] && rm -rf "$WIN_STAGING" 2>/dev/null || true
}
trap cleanup EXIT

mount "${PART_PREFIX}1" "$MNT_ESP"

if $USE_SHIM; then
    info "Installing signed shim + GRUB to ESP (Secure Boot compatible)..."
    mkdir -p "$MNT_ESP/EFI/BOOT"
    cp "$SHIM_EFI" "$MNT_ESP/EFI/BOOT/BOOTX64.EFI"
    cp "$GRUB_EFI" "$MNT_ESP/EFI/BOOT/grubx64.efi"
    [[ -n "$MM_EFI" ]] && cp "$MM_EFI" "$MNT_ESP/EFI/BOOT/mmx64.efi"
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

# ── Generate grub.cfg ───────────────────────────────────────────
info "Generating grub.cfg..."
ESP_UUID="$(blkid -s UUID -o value "${PART_PREFIX}1" || true)"
[[ -n "$ESP_UUID" ]] || die "Could not read UUID for ESP"

mkdir -p "$MNT_ESP/boot/grub"
GRUB_CFG="$MNT_ESP/boot/grub/grub.cfg"

# We need to probe each ISO partition for its distro type and
# filesystem UUID/label, then generate appropriate menu entries.
# This is the same logic as update-grub.sh but run inline.

MNT_PROBE=$(mktemp -d)

detect_iso_distro() {
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

pretty_name() {
    local name="$1"
    name="${name%.iso}"
    name="${name//-/ }"
    name="${name//_/ }"
    echo "$name"
}

# Start writing grub.cfg
cat > "$GRUB_CFG" <<HEADER
# GRUB2 configuration for multi-boot USB (partition-per-ISO)
#
# Auto-generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Re-run update-grub.sh after adding/removing ISOs.
#
# Each Linux ISO lives in its own GPT partition (raw dd).
# GRUB reads the kernel and initrd directly from the ISO9660
# filesystem (which is built into the signed grubx64.efi).
# No insmod lines — fully Secure Boot compatible.

set timeout=30
set default=0

HEADER

ENTRY_COUNT=0

for part_num in $(echo "${!ISO_PARTMAP[@]}" | tr ' ' '\n' | sort -n); do
    iso="${ISO_PARTMAP[$part_num]}"
    target="${PART_PREFIX}${part_num}"
    filename="$(basename "$iso")"
    label="$(pretty_name "$filename")"

    # Get the filesystem UUID from the dd'd ISO partition
    fs_uuid="$(blkid -s UUID -o value "$target" 2>/dev/null || true)"
    if [[ -z "$fs_uuid" ]]; then
        warn "  Could not get filesystem UUID for $target — skipping"
        continue
    fi

    # Mount the ISO partition to detect distro layout
    mount -o ro "$target" "$MNT_PROBE" 2>/dev/null || {
        warn "  Could not mount $target — skipping"
        continue
    }

    dtype="$(detect_iso_distro "$MNT_PROBE")"
    info "  $filename → partition $part_num ($dtype), UUID=$fs_uuid"
    umount "$MNT_PROBE" 2>/dev/null || true

    case "$dtype" in
        casper)
            cat >> "$GRUB_CFG" <<ENTRY
menuentry "$label" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/casper/vmlinuz boot=casper quiet splash ---
    initrd (\$isopart)/casper/initrd
}

menuentry "$label  (safe graphics)" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/casper/vmlinuz boot=casper quiet splash nomodeset ---
    initrd (\$isopart)/casper/initrd
}

ENTRY
            ;;
        fedora)
            cat >> "$GRUB_CFG" <<ENTRY
menuentry "$label" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/images/pxeboot/vmlinuz root=live:UUID=$fs_uuid rd.live.image quiet
    initrd (\$isopart)/images/pxeboot/initrd.img
}

menuentry "$label  (basic graphics)" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/images/pxeboot/vmlinuz root=live:UUID=$fs_uuid rd.live.image nomodeset quiet
    initrd (\$isopart)/images/pxeboot/initrd.img
}

ENTRY
            ;;
        debian-live)
            cat >> "$GRUB_CFG" <<ENTRY
menuentry "$label" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/live/vmlinuz boot=live components quiet splash ---
    initrd (\$isopart)/live/initrd.img
}

menuentry "$label  (safe graphics)" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/live/vmlinuz boot=live components quiet splash nomodeset ---
    initrd (\$isopart)/live/initrd.img
}

ENTRY
            ;;
        arch)
            cat >> "$GRUB_CFG" <<ENTRY
menuentry "$label" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/arch/boot/x86_64/vmlinuz-linux archisodevice=/dev/disk/by-uuid/$fs_uuid
    initrd (\$isopart)/arch/boot/x86_64/initramfs-linux.img
}

menuentry "$label  (safe graphics)" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/arch/boot/x86_64/vmlinuz-linux archisodevice=/dev/disk/by-uuid/$fs_uuid nomodeset
    initrd (\$isopart)/arch/boot/x86_64/initramfs-linux.img
}

ENTRY
            ;;
        opensuse)
            cat >> "$GRUB_CFG" <<ENTRY
menuentry "$label" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/boot/x86_64/loader/linux root=live:UUID=$fs_uuid splash=silent quiet
    initrd (\$isopart)/boot/x86_64/loader/initrd
}

menuentry "$label  (safe graphics)" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/boot/x86_64/loader/linux root=live:UUID=$fs_uuid splash=silent quiet nomodeset
    initrd (\$isopart)/boot/x86_64/loader/initrd
}

ENTRY
            ;;
        *)
            warn "  Unrecognised ISO layout for $filename — trying casper fallback"
            cat >> "$GRUB_CFG" <<ENTRY
menuentry "$label  (unrecognised — casper fallback)" {
    search --no-floppy --fs-uuid --set=isopart $fs_uuid
    linux (\$isopart)/casper/vmlinuz boot=casper quiet splash ---
    initrd (\$isopart)/casper/initrd
}

ENTRY
            ;;
    esac

    ((ENTRY_COUNT++)) || true
done

rmdir "$MNT_PROBE" 2>/dev/null || true

# Windows entry
if [[ -n "$WIN_ISO" && -n "$WIN_PART_NUM" ]]; then
    win_dev="${PART_PREFIX}${WIN_PART_NUM}"
    win_uuid="$(blkid -s UUID -o value "$win_dev" 2>/dev/null || true)"
    if [[ -n "$win_uuid" ]]; then
        info "  ✓ Windows 11 → partition $WIN_PART_NUM"
        cat >> "$GRUB_CFG" <<WINENTRY
# ══════════════════════════════════════════════════════════════════
#  Windows 11
# ══════════════════════════════════════════════════════════════════

menuentry "Windows 11 Installer" {
    search --no-floppy --fs-uuid --set=winpart $win_uuid
    chainloader (\$winpart)/efi/boot/bootx64.efi
}

WINENTRY
    fi
fi

# Utility entries
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

# Shim redirect config — GRUB looks for grub.cfg next to itself first
if $USE_SHIM; then
    mkdir -p "$MNT_ESP/EFI/BOOT"
    cat > "$MNT_ESP/EFI/BOOT/grub.cfg" <<SHIMCFG
search --no-floppy --fs-uuid --set=esp ${ESP_UUID}
set prefix=(\$esp)/boot/grub
configfile (\$esp)/boot/grub/grub.cfg
SHIMCFG
    info "Wrote shim redirect to EFI/BOOT/grub.cfg"
fi

# ── Summary ──────────────────────────────────────────────────────
sync
echo ""
info "========================================="
info " Multi-boot USB drive is ready!"
info "========================================="
info ""
info "Partition layout:"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DEVICE"
echo ""
info "$ENTRY_COUNT Linux ISO(s) installed."
info "Menu entries:"
grep -oP '(?<=menuentry ").*(?=")' "$GRUB_CFG" | while IFS= read -r entry; do
    info "  • $entry"
done
echo ""
info "To add more ISOs later:   sudo ./add-iso.sh $DEVICE path/to/new.iso"
info "To remove an ISO:         sudo ./remove-iso.sh $DEVICE <partition-number>"
info "To rebuild the GRUB menu: sudo ./update-grub.sh $DEVICE"
echo ""

#!/usr/bin/env bash
#
# download-efi.sh — Download Microsoft-signed shim + Fedora-signed GRUB EFI
#                    binaries for Secure Boot support on removable USB drives.
#
# The shim (shimx64.efi) is signed by Microsoft's UEFI third-party CA, so it
# is trusted by virtually all Secure-Boot-enabled firmware.  The shim then
# chainloads grubx64.efi, which is signed by Red Hat / Fedora's key (embedded
# inside the shim).
#
# Downloaded binaries are placed in  efi/boot/  next to this script.
#
# Usage:
#   ./download-efi.sh            # uses latest Fedora release
#   ./download-efi.sh --release 41   # pin a specific Fedora release
#
# Requirements: curl, rpm2cpio, cpio  (common on most distros)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

# ── Parse args ───────────────────────────────────────────────────
RELEASE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) RELEASE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--release FEDORA_VERSION]"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Detect latest Fedora release if not pinned ───────────────────
if [[ -z "$RELEASE" ]]; then
    info "Detecting latest Fedora release..."
    RELEASE=$(curl -sI https://mirror.fcix.net/fedora/linux/releases/ \
        | grep -oP 'releases/\K[0-9]+' | sort -n | tail -1 || true)
    if [[ -z "$RELEASE" ]]; then
        # Fallback: scrape the directory listing
        RELEASE=$(curl -sL https://mirror.fcix.net/fedora/linux/releases/ \
            | grep -oP 'href="[0-9]+/"' | grep -oP '[0-9]+' | sort -n | tail -1 || true)
    fi
    [[ -n "$RELEASE" ]] || die "Could not detect Fedora release. Use --release N."
fi
info "Using Fedora release: $RELEASE"

# ── Dependency check ─────────────────────────────────────────────
for cmd in curl rpm2cpio cpio; do
    command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done

# ── Setup paths ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EFI_DIR="$SCRIPT_DIR/efi/boot"
WORK_DIR=$(mktemp -d)

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$EFI_DIR"

# ── Mirror base URL ──────────────────────────────────────────────
MIRROR="https://mirror.fcix.net/fedora/linux/releases/${RELEASE}/Everything/x86_64/os/Packages/s"
MIRROR_GRUB="https://mirror.fcix.net/fedora/linux/releases/${RELEASE}/Everything/x86_64/os/Packages/g"

# ── Find and download the shim-x64 RPM ──────────────────────────
info "Searching for shim-x64 package..."
SHIM_RPM=$(curl -sL "$MIRROR/" \
    | grep -oP 'href="(shim-x64-[0-9][^"]*\.x86_64\.rpm)"' \
    | grep -oP 'shim-x64-[^"]+' | sort -V | tail -1)
[[ -n "$SHIM_RPM" ]] || die "Could not find shim-x64 RPM in Fedora $RELEASE mirror"

info "Downloading $SHIM_RPM..."
curl -sL "$MIRROR/$SHIM_RPM" -o "$WORK_DIR/shim.rpm"

# ── Find and download the grub2-efi-x64 RPM ─────────────────────
info "Searching for grub2-efi-x64 package..."
GRUB_RPM=$(curl -sL "$MIRROR_GRUB/" \
    | grep -oP 'href="(grub2-efi-x64-[0-9][^"]*\.x86_64\.rpm)"' \
    | grep -oP 'grub2-efi-x64-[^"]+' | head -1)
[[ -n "$GRUB_RPM" ]] || die "Could not find grub2-efi-x64 RPM in Fedora $RELEASE mirror"

info "Downloading $GRUB_RPM..."
curl -sL "$MIRROR_GRUB/$GRUB_RPM" -o "$WORK_DIR/grub.rpm"

# ── Find and download grub2-efi-x64-modules RPM ─────────────────
info "Searching for grub2-efi-x64-modules package..."
GRUB_MOD_RPM=$(curl -sL "$MIRROR_GRUB/" \
    | grep -oP 'href="(grub2-efi-x64-modules-[0-9][^"]*\.noarch\.rpm)"' \
    | grep -oP 'grub2-efi-x64-modules-[^"]+' | head -1)

# ── Extract EFI binaries ─────────────────────────────────────────
info "Extracting EFI binaries..."

# shim-x64: shimx64.efi + mmx64.efi
cd "$WORK_DIR"
mkdir shim && cd shim
rpm2cpio ../shim.rpm | cpio -idm 2>/dev/null

SHIM_SRC=$(find . -name 'shimx64.efi' -print -quit)
MM_SRC=$(find . -name 'mmx64.efi' -print -quit)
[[ -n "$SHIM_SRC" ]] || die "shimx64.efi not found in shim RPM"

cp "$SHIM_SRC" "$EFI_DIR/BOOTX64.EFI"
info "  ✓ shimx64.efi → efi/boot/BOOTX64.EFI"

if [[ -n "$MM_SRC" ]]; then
    cp "$MM_SRC" "$EFI_DIR/mmx64.efi"
    info "  ✓ mmx64.efi  → efi/boot/mmx64.efi"
fi

# grub2-efi-x64: grubx64.efi
cd "$WORK_DIR"
mkdir grub && cd grub
rpm2cpio ../grub.rpm | cpio -idm 2>/dev/null

GRUB_SRC=$(find . -name 'grubx64.efi' -print -quit)
[[ -n "$GRUB_SRC" ]] || die "grubx64.efi not found in grub2-efi-x64 RPM"

cp "$GRUB_SRC" "$EFI_DIR/grubx64.efi"
info "  ✓ grubx64.efi → efi/boot/grubx64.efi"

# grub2-efi-x64-modules: *.mod files for insmod in grub.cfg
if [[ -n "${GRUB_MOD_RPM:-}" ]]; then
    info "Downloading $GRUB_MOD_RPM..."
    curl -sL "$MIRROR_GRUB/$GRUB_MOD_RPM" -o "$WORK_DIR/grub-modules.rpm"

    cd "$WORK_DIR"
    mkdir grub-mod && cd grub-mod
    rpm2cpio ../grub-modules.rpm | cpio -idm 2>/dev/null

    MOD_DIR=$(find . -type d -name 'x86_64-efi' -print -quit)
    if [[ -n "$MOD_DIR" ]]; then
        mkdir -p "$SCRIPT_DIR/efi/grub-modules"
        cp "$MOD_DIR"/*.{mod,lst} "$SCRIPT_DIR/efi/grub-modules/" 2>/dev/null || true
        MOD_COUNT=$(ls -1 "$SCRIPT_DIR/efi/grub-modules/"*.mod 2>/dev/null | wc -l)
        info "  ✓ $MOD_COUNT GRUB modules → efi/grub-modules/"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
info "========================================="
info " EFI binaries downloaded successfully!"
info "========================================="
info ""
info "Contents of efi/boot/:"
ls -lh "$EFI_DIR/"
if [[ -d "$SCRIPT_DIR/efi/grub-modules" ]]; then
    MOD_COUNT=$(ls -1 "$SCRIPT_DIR/efi/grub-modules/"*.mod 2>/dev/null | wc -l)
    info "GRUB modules: $MOD_COUNT files in efi/grub-modules/"
fi
echo ""
info "These are Secure-Boot-signed binaries from Fedora $RELEASE."
info "Run setup.sh to create your multi-boot USB drive."
echo ""

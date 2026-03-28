#!/usr/bin/env bash
#
# download-efi.sh — Download Microsoft-signed shim + Ubuntu-signed GRUB EFI
#                    binaries for Secure Boot support on removable USB drives.
#
# Why Ubuntu?  Ubuntu's signed grubx64.efi does NOT auto-scan for BLS entries
# on other disks (unlike Fedora's, which uses blscfg and shows host OS entries
# on the USB's GRUB menu).  The shim is signed by Microsoft's UEFI third-party
# CA, so it is trusted by virtually all Secure-Boot-enabled firmware.
#
# Downloaded binaries are placed in  efi/boot/  and  efi/grub-modules/.
#
# Usage:
#   ./download-efi.sh                     # uses Ubuntu 24.04 LTS (noble)
#   ./download-efi.sh --release jammy     # pin a specific Ubuntu release
#
# Requirements: curl, ar, tar/zstd  (common on most distros)

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
            echo "Usage: $0 [--release UBUNTU_CODENAME]"
            echo "  Default: noble (24.04 LTS)"
            echo "  Examples: jammy, noble, oracular"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$RELEASE" ]] || RELEASE="noble"
info "Using Ubuntu release: $RELEASE"

# ── Dependency check ─────────────────────────────────────────────
for cmd in curl ar tar; do
    command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done

# ── Setup paths ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EFI_DIR="$SCRIPT_DIR/efi/boot"
MODULES_DIR="$SCRIPT_DIR/efi/grub-modules"
WORK_DIR=$(mktemp -d)

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$EFI_DIR" "$MODULES_DIR"

# ── Helper: extract a .deb file ──────────────────────────────────
# .deb files are ar archives containing data.tar.{xz,zst,gz}
extract_deb() {
    local deb="$1" dest="$2"
    mkdir -p "$dest"
    cd "$dest"
    ar x "$deb"
    # Find and extract the data archive (could be .xz, .zst, .gz, or .tar)
    local data_tar
    data_tar=$(ls data.tar.* 2>/dev/null | head -1)
    [[ -n "$data_tar" ]] || die "No data.tar.* found in $deb"
    case "$data_tar" in
        *.zst) command -v zstd >/dev/null || die "zstd required to extract $data_tar"; zstd -dq "$data_tar" -o data.tar; tar xf data.tar ;;
        *.xz)  tar xJf "$data_tar" ;;
        *.gz)  tar xzf "$data_tar" ;;
        *.bz2) tar xjf "$data_tar" ;;
        *)     tar xf "$data_tar" ;;
    esac
}

# ── Ubuntu archive base URL ──────────────────────────────────────
ARCHIVE="http://archive.ubuntu.com/ubuntu"
POOL_SHIM="$ARCHIVE/pool/main/s/shim-signed"
POOL_GRUB="$ARCHIVE/pool/main/g/grub2-signed"
POOL_GRUB_MODS="$ARCHIVE/pool/main/g/grub2-unsigned"

# ── Find and download the shim-signed .deb ───────────────────────
info "Searching for shim-signed package..."
SHIM_DEB=$(curl -sL "$POOL_SHIM/" \
    | grep -oP 'href="(shim-signed_[0-9][^"]*_amd64\.deb)"' \
    | grep -oP 'shim-signed_[^"]+' | sort -V | tail -1)
[[ -n "$SHIM_DEB" ]] || die "Could not find shim-signed .deb in Ubuntu archive"

info "Downloading $SHIM_DEB..."
curl -sL "$POOL_SHIM/$SHIM_DEB" -o "$WORK_DIR/shim.deb"

# ── Find and download the grub-efi-amd64-signed .deb ────────────
info "Searching for grub-efi-amd64-signed package..."
GRUB_DEB=$(curl -sL "$POOL_GRUB/" \
    | grep -oP 'href="(grub-efi-amd64-signed_[0-9][^"]*_amd64\.deb)"' \
    | grep -oP 'grub-efi-amd64-signed_[^"]+' | sort -V | tail -1)
[[ -n "$GRUB_DEB" ]] || die "Could not find grub-efi-amd64-signed .deb in Ubuntu archive"

info "Downloading $GRUB_DEB..."
curl -sL "$POOL_GRUB/$GRUB_DEB" -o "$WORK_DIR/grub.deb"

# ── Find and download the grub-efi-amd64-bin .deb (modules) ─────
info "Searching for grub-efi-amd64-bin package (modules)..."
GRUB_MOD_DEB=$(curl -sL "$POOL_GRUB_MODS/" \
    | grep -oP 'href="(grub-efi-amd64-bin_[0-9][^"]*_amd64\.deb)"' \
    | grep -oP 'grub-efi-amd64-bin_[^"]+' | sort -V | tail -1)

# ── Extract EFI binaries ─────────────────────────────────────────
info "Extracting EFI binaries..."

# shim-signed: shimx64.efi.signed + mmx64.efi
extract_deb "$WORK_DIR/shim.deb" "$WORK_DIR/shim"

# Ubuntu's shim-signed package contains multiple variants:
#   shimx64.efi              — UNSIGNED (not usable with Secure Boot!)
#   shimx64.efi.signed.latest — Microsoft UEFI CA signed
#   shimx64.efi.dualsigned    — Microsoft + Canonical dual-signed (best)
# We must pick the signed variant; the bare shimx64.efi is NOT signed.
SHIM_SRC=$(find "$WORK_DIR/shim" \( -name 'shimx64.efi.dualsigned' -o -name 'shimx64.efi.signed.latest' -o -name 'shimx64.efi.signed' \) 2>/dev/null | sort | head -1)
MM_SRC=$(find "$WORK_DIR/shim" -name 'mmx64.efi' 2>/dev/null | head -1)
[[ -n "$SHIM_SRC" ]] || die "Signed shimx64.efi not found in shim-signed .deb (looked for .dualsigned / .signed.latest / .signed)"

cp "$SHIM_SRC" "$EFI_DIR/BOOTX64.EFI"
info "  ✓ shimx64.efi → efi/boot/BOOTX64.EFI"

if [[ -n "$MM_SRC" ]]; then
    cp "$MM_SRC" "$EFI_DIR/mmx64.efi"
    info "  ✓ mmx64.efi  → efi/boot/mmx64.efi"
else
    warn "  mmx64.efi not found (MOK enrollment won't be available)"
fi

# grub-efi-amd64-signed: grubx64.efi.signed
extract_deb "$WORK_DIR/grub.deb" "$WORK_DIR/grub"

GRUB_SRC=$(find "$WORK_DIR/grub" -name 'grubx64.efi.signed' 2>/dev/null | head -1)
[[ -n "$GRUB_SRC" ]] || GRUB_SRC=$(find "$WORK_DIR/grub" -name 'grubx64.efi' 2>/dev/null | head -1)
[[ -n "$GRUB_SRC" ]] || die "grubx64.efi not found in grub-efi-amd64-signed .deb"

cp "$GRUB_SRC" "$EFI_DIR/grubx64.efi"
info "  ✓ grubx64.efi → efi/boot/grubx64.efi"

# grub-efi-amd64-bin: *.mod files for insmod in grub.cfg
if [[ -n "${GRUB_MOD_DEB:-}" ]]; then
    info "Downloading $GRUB_MOD_DEB..."
    curl -sL "$POOL_GRUB_MODS/$GRUB_MOD_DEB" -o "$WORK_DIR/grub-modules.deb"

    extract_deb "$WORK_DIR/grub-modules.deb" "$WORK_DIR/grub-mod"

    MOD_DIR=$(find "$WORK_DIR/grub-mod" -type d -name 'x86_64-efi' -print -quit)
    if [[ -n "$MOD_DIR" ]]; then
        cp "$MOD_DIR"/*.mod "$MODULES_DIR/" 2>/dev/null || true
        cp "$MOD_DIR"/*.lst "$MODULES_DIR/" 2>/dev/null || true
        MOD_COUNT=$(find "$MODULES_DIR" -name '*.mod' | wc -l)
        info "  ✓ $MOD_COUNT GRUB modules → efi/grub-modules/"
    else
        warn "x86_64-efi module directory not found in grub-efi-amd64-bin"
    fi
else
    warn "grub-efi-amd64-bin package not found — modules will not be updated"
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
info "========================================="
info " EFI binaries downloaded successfully!"
info "========================================="
info ""
info "Contents of efi/boot/:"
ls -lh "$EFI_DIR/"
MOD_COUNT=$(find "$MODULES_DIR" -name '*.mod' 2>/dev/null | wc -l)
if [[ "$MOD_COUNT" -gt 0 ]]; then
    info "GRUB modules: $MOD_COUNT files in efi/grub-modules/"
fi
echo ""
info "These are Secure-Boot-signed binaries from Ubuntu ($RELEASE)."
info "Ubuntu's GRUB does NOT auto-scan for host OS entries (no BLS/blscfg)."
info "Run setup.sh to create your multi-boot USB drive."
echo ""

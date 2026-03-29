# usb-installer-improved

A multi-boot USB drive creator built on GRUB2 — no Ventoy, no opaque binaries. Specify your ISOs at setup time (or add them later), and boot any of them from a single flash drive. Supports **Ubuntu**, **Fedora**, **Debian**, **Arch**, **openSUSE**, **Windows 11**, and more.

## How it works

Each Linux ISO gets its own GPT partition, written raw with `dd`. GRUB reads the kernel and initrd directly from the ISO9660 filesystem — which is compiled into the signed `grubx64.efi` — so there's no extraction step, no exFAT limitations, and no unsigned module loading.

| Partition | Format | Contents |
|-----------|--------|----------|
| 1 (ESP) | FAT32 (512 MB) | GRUB2 EFI bootloader + config |
| 2..N | ISO9660 (auto-sized) | One raw Linux ISO per partition |
| N+1 (optional) | FAT32 (8 GB) | Extracted Windows 11 installer (large `.wim` files auto-split) |

### Why partition-per-ISO?

Ubuntu's signed GRUB only has **FAT, ext2, btrfs, and iso9660** built in — it **cannot read exFAT or NTFS**. Earlier approaches stored ISOs on an exFAT partition and tried to loopback-mount them or extract kernels, but GRUB couldn't access the exFAT filesystem at all. Under Secure Boot, `insmod` can't load additional filesystem modules either.

By writing each ISO raw into its own partition, the ISO9660 filesystem is directly on a GPT partition that GRUB can natively read. GRUB loads the kernel and initrd straight from the ISO, and the distro's initramfs finds its squashfs on the same partition at boot time.

**Chainloading** (loading the ISO's own bootloader) was considered but doesn't work: UEFI firmware can only read FAT, so a chainloaded bootloader on an ISO9660 partition can't find its own config files. Instead, our GRUB uses `linux`/`initrd` to load kernels directly.

## Quick start

```bash
# 1. Download signed EFI binaries (one time)
./download-efi.sh

# 2. Set up the USB drive with your ISOs
sudo ./setup.sh /dev/sdX \
    --iso ~/Downloads/ubuntu-26.04-desktop-amd64.iso \
    --iso ~/Downloads/Fedora-Workstation-Live-x86_64-42.iso \
    --win-iso ~/Downloads/Win11_24H2.iso
```

Boot from the USB — done.

## Managing ISOs

### Add an ISO (without wiping the drive)

```bash
sudo ./add-iso.sh /dev/sdX ~/Downloads/debian-12-amd64.iso
```

This creates a new partition, writes the ISO, and regenerates the GRUB menu.

### Remove an ISO

```bash
sudo ./remove-iso.sh /dev/sdX --list    # see what's installed
sudo ./remove-iso.sh /dev/sdX 3         # remove partition 3
```

### Rebuild the GRUB menu

```bash
sudo ./update-grub.sh /dev/sdX
```

Run this if the menu gets out of sync, or after manual partition changes.

## Supported distros

| Family | How it's detected | Examples |
|--------|-------------------|----------|
| Ubuntu / casper | `/casper/vmlinuz` inside the ISO | Ubuntu, Linux Mint, Pop!_OS, elementary |
| Fedora / Anaconda | `/images/pxeboot/vmlinuz` | Fedora, RHEL, CentOS, Rocky, Alma |
| Debian live | `/live/vmlinuz` | Debian, Kali, Tails |
| Arch | `/arch/boot/x86_64/vmlinuz-linux` | Arch Linux, EndeavourOS |
| openSUSE | `/boot/x86_64/loader/linux` | openSUSE Leap/Tumbleweed, SLES |

Unrecognised ISOs get a casper-based fallback entry.

**Windows 11** is extracted to a FAT32 partition. Any `.wim` files exceeding FAT32's 4 GB limit are automatically split into `.swm` chunks using `wimlib` — the same approach Microsoft's own Media Creation Tool uses. GRUB chainloads the Windows boot manager directly, and Windows Setup natively reassembles the split images during installation.

## Requirements

- Linux host (for running the setup scripts)
- A USB flash drive (128 GB recommended for multiple ISOs)
- `sgdisk`, `mkfs.fat`, `blkid`, `dd` (from `util-linux` and `gdisk`)
- `7z` or `bsdtar` (only for Windows ISO extraction)
- `wimlib-imagex` from `wimtools` / `wimlib-utils` (only for Windows, to split large `.wim` files)

Dependencies are auto-installed by `setup.sh` for most distros. On Fedora:

```bash
sudo dnf install gdisk dosfstools parted util-linux grub2-efi-x64
```

## Secure Boot

The bundled EFI binaries (`efi/boot/`) are Ubuntu's Microsoft-signed shim + GRUB, downloaded by `./download-efi.sh`. Ubuntu's GRUB is used because it does **not** auto-scan for host OS entries (unlike Fedora's `blscfg`-enabled GRUB).

The generated `grub.cfg` contains **no `insmod` lines** — all required modules (including `iso9660`) are compiled into the signed binary. This avoids Secure Boot signature-verification errors that occur when loading unsigned `.mod` files from disk.

To refresh or update the binaries:

```bash
./download-efi.sh                  # defaults to Ubuntu 24.04 (noble)
./download-efi.sh --release jammy  # pin a specific release
```

Then re-run `setup.sh` to write them to the USB.

This uses Microsoft's UEFI CA chain — no MOK enrollment needed.

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Partitions the drive, writes ISOs, installs GRUB, generates menu |
| `add-iso.sh` | Adds an ISO to an existing drive without wiping |
| `remove-iso.sh` | Removes an ISO partition and regenerates the menu |
| `update-grub.sh` | Scans ISO partitions and rebuilds `grub.cfg` |
| `grub.cfg` | Placeholder config — overwritten by setup.sh / update-grub.sh |
| `download-efi.sh` | Downloads signed shim + GRUB EFI binaries from Ubuntu |
| `MULTIBOOT_OPTIONS.md` | Design analysis comparing implementation approaches |

## How it compares

| Approach | Filesystem needed | Secure Boot | Distro-agnostic |
|----------|------------------|-------------|-----------------|
| Ventoy | Custom UEFI driver | Requires MOK | ✓ |
| Loopback ISO (GRUB) | exFAT/NTFS | ✗ (insmod) | Partial |
| Kernel extraction to ESP | FAT32 only | ✓ | Partial |
| **Partition-per-ISO** (this) | **ISO9660 (built in)** | **✓** | Partial¹ |

¹ Requires distro-specific kernel parameters, but detection is automatic for all major distros.

## License

MIT

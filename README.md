# usb-installer-improved

A multi-boot USB drive creator built on GRUB2 — no Ventoy, no opaque binaries. Drop in any supported ISO and GRUB auto-detects it at boot time. Supports **Ubuntu**, **Fedora**, **Debian**, **Arch**, **openSUSE**, **Windows 11**, and more from a single flash drive.

## How it works

| Partition | Format | Contents |
|-----------|--------|----------|
| ESP (512 MB) | FAT32 | GRUB2 EFI bootloader + config |
| Linux ISOs (~110 GB) | exFAT | Drop-in `.iso` files |
| Windows 11 (8 GB) | NTFS | Extracted Windows installer |

- Linux distros boot via GRUB's `loopback` — at boot time GRUB scans `isos/*.iso`, probes each ISO's internal layout to identify the distro family, and builds the menu automatically.
- Windows chainloads its native boot manager from a real NTFS partition.

## Quick start

```bash
# Linux only — requires root
sudo ./setup.sh /dev/sdX --win-iso ~/Downloads/Win11_24H2.iso
```

Then copy your Linux ISOs:

```bash
# Mount the LINUXISOS partition (auto-mounts on most desktops)
cp ubuntu-24.04.2-desktop-amd64.iso /media/$USER/LINUXISOS/isos/
cp Fedora-Workstation-Live-x86_64-41.iso /media/$USER/LINUXISOS/isos/
```

Boot from the USB — GRUB automatically detects every ISO and builds the menu.

## Adding or updating ISOs

**Linux:** Just copy (or remove) ISO files in `isos/` on the LINUXISOS partition. No config editing needed — GRUB rescans on every boot. Supported distro families are detected automatically:

| Family | How it's detected | Examples |
|--------|-------------------|----------|
| Ubuntu / casper | `/casper/vmlinuz` inside the ISO | Ubuntu, Linux Mint, Pop!_OS, elementary |
| Fedora / Anaconda | `/images/pxeboot/vmlinuz` | Fedora, RHEL, CentOS, Rocky, Alma |
| Debian live | `/live/vmlinuz` | Debian, Kali, Tails |
| Arch | `/arch/boot/x86_64/vmlinuz-linux` | Arch Linux, EndeavourOS |
| openSUSE | `/boot/x86_64/loader/linux` | openSUSE Leap/Tumbleweed, SLES |

Unrecognised ISOs still appear in the menu with a casper-based fallback.

**Windows:** Re-run `setup.sh` with `--win-iso`, or manually extract a new ISO to the WIN11 partition.

## Requirements

- Linux host (for running the setup script)
- `sgdisk`, `mkfs.fat`, `mkfs.exfat`, `mkfs.ntfs` (ntfs-3g), `grub-install`
- `7z` or `bsdtar` (for Windows ISO extraction)

On Ubuntu/Debian:
```bash
sudo apt install gdisk dosfstools exfatprogs ntfs-3g grub-efi-amd64-bin p7zip-full
```

On Fedora:
```bash
sudo dnf install gdisk dosfstools exfatprogs ntfs-3g grub2-efi-x64 p7zip
```

## Secure Boot

The setup script installs GRUB with `--removable`, which places the EFI binary at the standard fallback path. For Secure Boot support, copy Ubuntu's signed shim:

```bash
# On an Ubuntu host
sudo apt install shim-signed grub-efi-amd64-signed
cp /usr/lib/shim/shimx64.efi.signed /media/$USER/ESP/EFI/BOOT/bootx64.efi
cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /media/$USER/ESP/EFI/BOOT/grubx64.efi
```

This uses Microsoft's UEFI CA chain — no MOK enrollment needed.

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Partitions, formats, and installs GRUB on the USB drive |
| `grub.cfg` | GRUB menu — dynamically scans ISOs at boot, no manual editing needed |
| `MULTIBOOT_OPTIONS.md` | Design analysis comparing the three implementation approaches |

## License

MIT

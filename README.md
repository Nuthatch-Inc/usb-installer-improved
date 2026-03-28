# usb-installer-improved

A multi-boot USB drive creator built on GRUB2 — no Ventoy, no opaque binaries. Supports **Ubuntu**, **Fedora**, and **Windows 11** from a single 128 GB flash drive.

## How it works

| Partition | Format | Contents |
|-----------|--------|----------|
| ESP (512 MB) | FAT32 | GRUB2 EFI bootloader + config |
| Linux ISOs (~110 GB) | exFAT | Drop-in `.iso` files |
| Windows 11 (8 GB) | NTFS | Extracted Windows installer |

- Linux distros boot via GRUB's `loopback` — mount an ISO in-place and launch the kernel directly.
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

Boot from the USB — GRUB presents a menu with all available OSes.

## Adding or updating ISOs

**Linux:** Just copy the new ISO to `isos/` on the LINUXISOS partition, then edit `grub.cfg` on the ESP to update or add the menu entry.

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
| `grub.cfg` | GRUB menu configuration with entries for Ubuntu, Fedora, and Windows |
| `MULTIBOOT_OPTIONS.md` | Design analysis comparing the three implementation approaches |

## License

MIT

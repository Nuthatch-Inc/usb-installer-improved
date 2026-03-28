# usb-installer-improved

A multi-boot USB drive creator built on GRUB2 — no Ventoy, no opaque binaries. Drop in any supported ISO, run one command to rebuild the menu, and boot. Supports **Ubuntu**, **Fedora**, **Debian**, **Arch**, **openSUSE**, **Windows 11**, and more from a single flash drive.

## How it works

| Partition | Format | Contents |
|-----------|--------|----------|
| ESP (512 MB) | FAT32 | GRUB2 EFI bootloader + config |
| Linux ISOs (~110 GB) | exFAT | Drop-in `.iso` files |
| Windows 11 (8 GB) | NTFS | Extracted Windows installer |

- Linux distros boot via GRUB's `loopback` — the `update-grub.sh` script mounts each ISO, detects the distro family, and writes a static menu with the correct kernel parameters.
- Windows chainloads its native boot manager from a real NTFS partition.
- **Fully Secure Boot compatible** — zero `insmod` lines. Ubuntu's signed `grubx64.efi` has all required modules (loopback, iso9660, linux, chain, search, regexp, etc.) built in.

## Quick start

```bash
# 1. Prepare the USB (Linux only, requires root)
sudo ./setup.sh /dev/sdX --win-iso ~/Downloads/Win11_24H2.iso

# 2. Copy your Linux ISOs to the LINUXISOS partition
#    (it auto-mounts on most desktops after setup)
cp ubuntu-24.04.2-desktop-amd64.iso /media/$USER/LINUXISOS/isos/
cp Fedora-Workstation-Live-x86_64-41.iso /media/$USER/LINUXISOS/isos/

# 3. Build the GRUB menu
sudo ./update-grub.sh /dev/sdX
```

Boot from the USB — done.

## Adding or updating ISOs

1. Copy (or remove) ISO files in `isos/` on the LINUXISOS partition.
2. Re-run `sudo ./update-grub.sh /dev/sdX`.

That's it. The script scans every ISO, detects the distro family, and rewrites `grub.cfg` with the correct boot parameters. Supported families:

| Family | How it's detected | Examples |
|--------|-------------------|----------|
| Ubuntu / casper | `/casper/vmlinuz` inside the ISO | Ubuntu, Linux Mint, Pop!_OS, elementary |
| Fedora / Anaconda | `/images/pxeboot/vmlinuz` | Fedora, RHEL, CentOS, Rocky, Alma |
| Debian live | `/live/vmlinuz` | Debian, Kali, Tails |
| Arch | `/arch/boot/x86_64/vmlinuz-linux` | Arch Linux, EndeavourOS |
| openSUSE | `/boot/x86_64/loader/linux` | openSUSE Leap/Tumbleweed, SLES |

Unrecognised ISOs get a casper-based fallback entry.

**Windows:** Re-run `setup.sh` with `--win-iso`, or manually extract a new ISO to the WIN11 partition.

## Requirements

- Linux host (for running the setup scripts)
- `sgdisk`, `mkfs.fat`, `mkfs.exfat`, `mkfs.ntfs` (ntfs-3g), `grub-install`
- `7z` or `bsdtar` (for Windows ISO extraction)
- `blkid` (from `util-linux` — used for UUID detection)

On Ubuntu/Debian:
```bash
sudo apt install gdisk dosfstools exfatprogs ntfs-3g grub-efi-amd64-bin p7zip-full
```

On Fedora:
```bash
sudo dnf install gdisk dosfstools exfatprogs ntfs-3g grub2-efi-x64 p7zip
```

Dependencies are auto-installed by `setup.sh` for most distros.

## Secure Boot

The bundled EFI binaries (`efi/boot/`) are Ubuntu's Microsoft-signed shim + GRUB,
downloaded by `./download-efi.sh`. Ubuntu's GRUB is used because it does **not**
auto-scan for host OS entries (unlike Fedora's `blscfg`-enabled GRUB).

The generated `grub.cfg` contains **no `insmod` lines** — all required modules are
compiled into the signed binary. This avoids the Secure Boot signature-verification
errors that occur when loading unsigned `.mod` files from disk.

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
| `setup.sh` | Partitions, formats, and installs GRUB on the USB drive |
| `update-grub.sh` | Scans ISOs and writes a static, Secure Boot-safe `grub.cfg` |
| `grub.cfg` | Placeholder config — overwritten by `update-grub.sh` |
| `download-efi.sh` | Downloads signed shim + GRUB EFI binaries from Ubuntu |
| `MULTIBOOT_OPTIONS.md` | Design analysis comparing the three implementation approaches |

## License

MIT

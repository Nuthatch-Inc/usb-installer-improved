# Multi-Boot USB Installer: Options & Trade-offs

## Goal

A single 128 GB USB flash drive that can boot and install **Ubuntu**, **Fedora**, and **Windows 11** — built from well-understood, auditable components rather than opaque third-party tools like Ventoy.

---

## Option A: GRUB2 + Loopback ISO Boot

### How it works

A single GPT-formatted drive with:

| # | Partition | Size | Type | Purpose |
|---|-----------|------|------|---------|
| 1 | EFI System Partition (ESP) | 512 MB | FAT32 | GRUB2 EFI binary + config |
| 2 | Data partition | ~127 GB | exFAT or NTFS | Stores `.iso` files |

GRUB2's `loopback` command mounts an ISO file as a virtual device, then boots its kernel + initrd directly. The GRUB config enumerates ISOs and presents a menu at boot.

#### Example `grub.cfg` (simplified)

```bash
set timeout=30
set default=0

menuentry "Ubuntu 24.04 LTS" {
    set isofile="/isos/ubuntu-24.04-desktop-amd64.iso"
    loopback loop ($root)$isofile
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$isofile quiet splash ---
    initrd (loop)/casper/initrd
}

menuentry "Fedora 41 Workstation" {
    set isofile="/isos/Fedora-Workstation-Live-x86_64-41.iso"
    loopback loop ($root)$isofile
    linux (loop)/images/pxeboot/vmlinuz iso-scan/filename=$isofile rd.live.image quiet
    initrd (loop)/images/pxeboot/initrd.img
}

# Windows requires a different strategy — see notes below
```

### Linux support

| Distro | Loopback boot? | Notes |
|--------|----------------|-------|
| Ubuntu (desktop & server) | **Yes** | Native `iso-scan/filename=` kernel param; well-tested |
| Fedora Workstation Live | **Yes** | `rd.live.image` + `iso-scan/filename=` works on recent versions |
| Fedora Server (netinstall) | **Yes** | Same mechanism via Dracut |

### Windows 11 — the hard part

Windows ISOs **cannot** be loopback-booted from GRUB. The Windows boot manager (`bootmgfw.efi`) expects to run from a real partition, not a loopback device. There is no `iso-scan` equivalent.

**Workarounds:**

| Approach | Complexity | Reliability |
|----------|-----------|-------------|
| **Chainload `bootmgfw.efi`** from a real NTFS partition containing extracted Windows ISO contents | Medium | High — this is essentially what Rufus does |
| **Use GRUB to `chainloader` a Windows PE** via wimboot/wimlib | High | Fragile; wimboot is niche and under-documented |
| **Dedicated Windows partition** (hybrid with Option B) | Low | Bulletproof — just extract ISO to its own partition |

**Recommended:** Give Windows its own NTFS partition with the ISO contents extracted. GRUB chainloads Windows Boot Manager from that partition. This is simple and rock-solid.

### Pros

- **GRUB2 is battle-tested** — the de facto Linux bootloader, shipped by every major distro, audited, actively maintained.
- **Adding/removing ISOs is trivial** — drop a file onto the data partition from any OS.
- **Small trusted code base** — you audit `grub.cfg` yourself; no opaque binary blobs.
- **Flexible** — easy to add kernel parameters, set defaults, theme the menu.

### Cons

- **Windows needs special handling** — no true ISO loopback; requires either a dedicated partition or extracted files.
- **Kernel parameter research per distro** — each distro's initramfs expects slightly different params for ISO scanning. When a distro ships a new version, parameters *can* change (rare but possible).
- **Secure Boot requires a signed GRUB** — you need either a pre-signed GRUB (from an Ubuntu package, for example) or you must enroll your own MOK (Machine Owner Key). This is solvable but adds a setup step.
- **No automatic ISO discovery** — you write a menu entry per ISO (or write a GRUB script to glob for ISOs, which is doable but adds complexity).

---

## Option B: Separate Partitions Per OS

### How it works

GPT-formatted drive with individual partitions for each installer:

| # | Partition | Size | Type | Contents |
|---|-----------|------|------|----------|
| 1 | EFI System Partition | 512 MB | FAT32 | GRUB2 or rEFInd + config |
| 2 | Ubuntu Installer | 8 GB | FAT32 or ISO9660 | Extracted Ubuntu ISO |
| 3 | Fedora Installer | 8 GB | FAT32 or ext4 | Extracted Fedora ISO |
| 4 | Windows 11 Installer | 8 GB | NTFS | Extracted Windows ISO |
| 5 | Persistent / Free | ~103 GB | exFAT | Storage, optional persistence |

A UEFI boot manager (GRUB2 or rEFInd) on the ESP presents a menu and chainloads each partition's bootloader.

### Pros

- **Maximum compatibility** — each OS installer lives on its native filesystem exactly as the vendor intended. No loopback hacks.
- **Windows works perfectly** — just extract the ISO to an NTFS partition; the Windows Boot Manager runs natively.
- **Secure Boot is simpler** — each partition's EFI binary is the distro's own signed bootloader. Chainloading signed binaries avoids MOK enrollment in some cases.
- **Debuggable** — each partition is self-contained; if one breaks, the others are unaffected.
- **Could use rEFInd instead of GRUB** — rEFInd auto-discovers EFI bootloaders across partitions with zero config.

### Cons

- **Updating an OS version is more involved** — you must repartition or rewrite the partition contents, not just swap an ISO file.
- **Partition table management** — adding/removing OSes means resizing or recreating partitions (tools like `sgdisk`, `parted` make this scriptable).
- **Wastes some space** — each partition must be large enough for the biggest ISO variant of that distro; unused space within a partition is stranded.
- **More setup steps** — initial creation requires more `parted`/`mkfs`/`mount`/`cp` commands vs. just copying an ISO.

---

## Option C: Hybrid (Recommended)

Combine the best of both: **GRUB loopback for Linux, dedicated partition for Windows.**

| # | Partition | Size | Type | Contents |
|---|-----------|------|------|----------|
| 1 | EFI System Partition | 512 MB | FAT32 | GRUB2 EFI + grub.cfg |
| 2 | Linux ISOs | ~110 GB | exFAT | Ubuntu, Fedora, Arch, etc. ISOs + grub.cfg includes |
| 3 | Windows 11 | 8 GB | NTFS | Extracted Windows 11 ISO |

GRUB's menu:
- Linux entries use `loopback` to boot ISOs directly from partition 2.
- Windows entry uses `chainloader` to hand off to `\EFI\Boot\bootx64.efi` on partition 3.

### Why this is the sweet spot

| Criterion | Option A | Option B | **Option C** |
|-----------|----------|----------|-------------|
| Linux boot reliability | Great | Great | **Great** |
| Windows boot reliability | Poor (hacks needed) | Great | **Great** |
| Ease of updating Linux ISOs | Trivial (file copy) | Hard (repartition) | **Trivial** |
| Ease of updating Windows | N/A | Medium | **Medium** |
| Disk space efficiency | Best | Worst | **Good** |
| Secure Boot | Needs signed GRUB | Simpler | **Needs signed GRUB** |
| Complexity to set up | Low-medium | Medium | **Medium** |
| Auditable / no blobs | Yes | Yes | **Yes** |

---

## Secure Boot Considerations

Regardless of option chosen, Secure Boot is the main friction point:

1. **Use Ubuntu's signed GRUB** — Install `grub-efi-amd64-signed` and `shim-signed` packages. Copy `shimx64.efi` → ESP as `bootx64.efi`, and `grubx64.efi` alongside it. Ubuntu's shim is signed by Microsoft's UEFI CA, so it boots on all Secure Boot machines without enrollment.
2. **Enroll a MOK** — Build GRUB yourself, sign with your own key, enroll via `mokutil`. Full control, but requires one-time enrollment per machine.
3. **Disable Secure Boot** — Easiest, but defeats the purpose if security matters to you.

**Recommendation:** Use Ubuntu's shim + signed GRUB. It's the path of least resistance and works on virtually all UEFI machines.

---

## Setup Script Outline (Option C)

A setup script would do roughly this:

```bash
#!/usr/bin/env bash
set -euo pipefail

DEVICE="/dev/sdX"          # ← user sets this
WIN_ISO="Win11_24H2.iso"
LINUX_ISOS=("ubuntu-24.04-desktop-amd64.iso" "Fedora-Workstation-Live-x86_64-41.iso")

# 1. Partition the drive
sgdisk --zap-all "$DEVICE"
sgdisk -n 1:0:+512M  -t 1:ef00 -c 1:"ESP"          "$DEVICE"
sgdisk -n 2:0:+110G  -t 2:0700 -c 2:"Linux ISOs"   "$DEVICE"
sgdisk -n 3:0:0      -t 3:0700 -c 3:"Windows 11"   "$DEVICE"

# 2. Format
mkfs.fat  -F32 "${DEVICE}1"
mkfs.exfat      "${DEVICE}2"
mkfs.ntfs -f    "${DEVICE}3"

# 3. Install GRUB to ESP
mount "${DEVICE}1" /mnt/esp
grub-install --target=x86_64-efi --efi-directory=/mnt/esp \
    --boot-directory=/mnt/esp/boot --removable
cp grub.cfg /mnt/esp/boot/grub/grub.cfg
# (Optionally copy shim for Secure Boot)
umount /mnt/esp

# 4. Copy Linux ISOs
mount "${DEVICE}2" /mnt/isos
cp "${LINUX_ISOS[@]}" /mnt/isos/
umount /mnt/isos

# 5. Extract Windows ISO
mount "${DEVICE}3" /mnt/win
7z x "$WIN_ISO" -o/mnt/win
umount /mnt/win
```

---

## rEFInd as an Alternative to GRUB

If you want to avoid GRUB entirely:

- **rEFInd** is a UEFI boot manager that auto-discovers `.efi` binaries across all partitions. It has a polished GUI.
- It works great for **Option B** (separate partitions) since each partition has its own EFI bootloader.
- It does **not** support ISO loopback booting, so it cannot replace GRUB for Option A or C's Linux ISO approach.
- It **is** signed for Secure Boot (official signed binaries available).
- It could be used as the front-end boot manager that chainloads GRUB (which then does the loopback work for Linux), giving you a nicer UI.

---

## Summary Recommendation

**Go with Option C (Hybrid).** Use GRUB2 on the ESP with Ubuntu's signed shim for Secure Boot. Boot Linux distros via `loopback` from ISOs on an exFAT data partition. Give Windows 11 its own NTFS partition with extracted installer contents. This gives you:

- Drop-in ISO updates for Linux (just copy a file)
- Rock-solid Windows booting (native NTFS, no hacks)
- Fully auditable config (`grub.cfg` is ~30 lines you write yourself)
- Secure Boot support via Ubuntu's Microsoft-signed shim
- No dependency on Ventoy or any opaque third-party binary

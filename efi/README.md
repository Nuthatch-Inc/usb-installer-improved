# efi/ — Signed Secure Boot Binaries

This directory holds the Microsoft-signed shim and Fedora-signed GRUB EFI
binaries needed for Secure Boot support on the USB drive.

## Quick start

```bash
./download-efi.sh
```

This downloads the binaries from Fedora's package mirrors and places them here:

```
efi/
├── boot/
│   ├── BOOTX64.EFI      # shimx64.efi (Microsoft-signed)
│   ├── grubx64.efi       # GRUB2 (Fedora/Red Hat-signed, trusted by shim)
│   └── mmx64.efi         # MOK Manager (for enrolling custom keys)
└── grub-modules/
    └── *.mod             # GRUB modules (loopback, iso9660, etc.)
```

`setup.sh` will automatically use these bundled binaries when creating the USB
drive. If this directory is empty, it falls back to system-installed binaries,
and finally to `grub-install --force` (which does **not** support Secure Boot).

## Why Fedora?

The shim binary is signed by Microsoft's UEFI third-party CA, which is trusted
by virtually all Secure-Boot-enabled firmware regardless of the OS installed.
The shim then verifies and chainloads `grubx64.efi` using Fedora/Red Hat's key
that's embedded inside it. Any distro's shim would work equally well — Fedora
was chosen because their RPMs are easy to extract on any Linux system.

## Pinning a release

```bash
./download-efi.sh --release 41
```

## Binary files are git-ignored

The `.efi` and `.mod` files are not committed to the repository. Run
`download-efi.sh` after cloning.

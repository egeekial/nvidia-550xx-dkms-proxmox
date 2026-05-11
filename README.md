# nvidia-550xx-dkms Proxmox VE 9 patches

This repository is a fork of
[solanni/nvidia-550xx-dkms](https://github.com/solanni/nvidia-550xx-dkms),
itself derived from the Arch Linux
[nvidia-550xx-dkms AUR package](https://aur.archlinux.org/pkgbase/nvidia-550xx-dkms).

The original package files are kept here for reference, but the main addition is
`apply-patches-proxmox.sh`: a helper script for patching the Debian/Proxmox
`nvidia-kernel-dkms` 550.163.01 source so it can build against Proxmox VE 9
kernel 7.0 headers.

## Status

This is a narrow compatibility patch set, not a general NVIDIA driver installer.

- Target driver: NVIDIA 550.163.01
- Target DKMS source path: `/usr/src/nvidia-current-550.163.01`
- Target DKMS module: `nvidia-current/550.163.01`
- Default target kernel: `7.0.2-2-pve`
- Primary target distribution: Proxmox VE 9

The script makes in-place changes under `/usr/src`, rebuilds DKMS modules, and
updates initramfs. Review it before running it on a host you care about.

## Repository Contents

- `PKGBUILD`, `.SRCINFO`, and support files: Arch/AUR packaging for the NVIDIA
  550 branch.
- `0002` through `0006` patch files: compatibility patches for GCC 15 and Linux
  kernel API changes in the 6.15, 6.17, and 6.19 range.
- `apply-patches-proxmox.sh`: Proxmox-focused patch and rebuild helper. It
  reuses the AUR patch logic where possible and adds kernel 7.0 fixes for VMA
  locking, `__vm_flags` removal, DRM atomic state changes, and DKMS build
  errors seen with the Proxmox packaging layout.

## Proxmox Usage

Prerequisites on the Proxmox host:

- Proxmox VE 9 with the target kernel and matching headers installed.
- `nvidia-kernel-dkms` 550.163.01 installed from the Debian/Proxmox packaging.
- DKMS build dependencies installed.
- Root shell access.

Clone this repository on the Proxmox host, then run:

```bash
sudo bash apply-patches-proxmox.sh
```

By default, this patches the DKMS source, rebuilds the module for
`7.0.2-2-pve`, installs it, runs `dpkg --configure -a`, and updates initramfs.

To target a different installed kernel:

```bash
sudo env KERNEL_VERSION="$(uname -r)" bash apply-patches-proxmox.sh
```

The script also supports split runs:

```bash
sudo bash apply-patches-proxmox.sh --patch-only
sudo bash apply-patches-proxmox.sh --build-only
```

After a successful build, reboot into the target kernel and verify:

```bash
dkms status
modprobe nvidia
nvidia-smi
```

## What the Script Does

On the first patch run, the script creates a backup at:

```text
/usr/src/nvidia-current-550.163.01.bak
```

On later patch runs, it restores that backup before applying patches again. This
keeps repeated runs from stacking the same edits.

The patch flow includes:

- GCC 15 `-std=gnu17` build fixes.
- `EXTRA_CFLAGS` to `ccflags-y` conversion for newer kernel builds.
- Linux 6.15 timer and VMA flag compatibility changes.
- Linux 6.17 DRM `fb_create` handling, where needed.
- Linux 6.19 `in_hardirq`, `map_phys`, `drm_print`, and conftest updates.
- Linux 7.0 Proxmox-specific fixes for VMA locking and NVIDIA DRM helper build
  failures.

## Arch Linux Notes

Arch users should normally use the maintained AUR package directly:

```text
https://aur.archlinux.org/pkgbase/nvidia-550xx-dkms
```

The Arch packaging in this repository is preserved because the Proxmox helper
depends on the same patch history. This fork is not intended to replace the AUR
package for normal Arch systems.

## Recovery

If the patched DKMS tree needs to be reset, reinstall the Debian/Proxmox NVIDIA
DKMS package or restore the backup created by the script:

```bash
sudo mv /usr/src/nvidia-current-550.163.01 /usr/src/nvidia-current-550.163.01.patched
sudo cp -a /usr/src/nvidia-current-550.163.01.bak /usr/src/nvidia-current-550.163.01
```

Then rebuild or reinstall the DKMS module as appropriate for your host.

## Upstream References

- Original GitHub fork:
  <https://github.com/solanni/nvidia-550xx-dkms>
- Arch Linux AUR package:
  <https://aur.archlinux.org/pkgbase/nvidia-550xx-dkms>
- NVIDIA 550.163.01 Linux driver:
  <https://www.nvidia.com/download/driverResults.aspx/245050/en-us>

## Licensing

No NVIDIA binaries are stored in this repository. The Arch package declares the
NVIDIA driver license as `custom`; the installed NVIDIA license is provided by
the upstream `.run` package during packaging. The patch files retain their
original authorship metadata where present.

## Disclaimer

This repository is unofficial and is not affiliated with NVIDIA, Proxmox, Debian,
or Arch Linux. Kernel and proprietary driver internals change often; use this
only for the exact driver/kernel combination it targets unless you are prepared
to debug DKMS build failures.

The Proxmox helper script in this repository was created with Claude Code. Treat
it as generated automation: review it before running it on a production host.

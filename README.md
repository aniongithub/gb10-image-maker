# gb10-image-maker

[![Manual Image Build](https://github.com/aniongithub/gb10-image-maker/actions/workflows/build.yml/badge.svg)](https://github.com/aniongithub/gb10-image-maker/actions/workflows/build.yml)
[![PR Validation](https://github.com/aniongithub/gb10-image-maker/actions/workflows/pr.yml/badge.svg)](https://github.com/aniongithub/gb10-image-maker/actions/workflows/pr.yml)

Minimal, USB-bootable appliance images for the **NVIDIA GB10 Grace-Blackwell / DGX Spark** (arm64).

## Quick start

1. **Download** the latest image —
   [`gb10-usb.img.xz`](https://github.com/aniongithub/gb10-image-maker/releases/latest/download/gb10-usb.img.xz)
   (the [latest release](https://github.com/aniongithub/gb10-image-maker/releases/latest)).
   It's a full, GPU-ready Ubuntu 24.04 arm64 with the NVIDIA driver, CUDA, and the
   container toolkit already baked in — nothing to install on first boot.

2. **Flash** it to a USB drive with
   [Balena Etcher](https://etcher.balena.io/) (or `dd`) — no need to decompress,
   Etcher reads the `.xz` directly. Use a **≥ 64 GB USB 3.2** drive for headroom.

3. **Boot** — stick the USB into your Spark, pick it from the UEFI boot menu, and you
   have a stable, minimal Ubuntu 24.04 that **runs entirely from the USB** and saves
   you precious unified memory — while the internal NVMe is left **completely
   untouched** (your factory DGX OS stays exactly where it is, ready to boot again the
   moment you pull the stick). Log in as `ubuntu` / `ubuntu` and change the password.

_Note_: This repo is the GB10 sibling of
[`jetson-nano-image-maker`](https://github.com/aniongithub/jetson-nano-image-maker):
data-driven, reproducible from public apt only, with a clean separation between
**provisioning** and **image creation**.

## Repository layout

Everything you'd change lives in `spark.json`; the scripts read from it.

| Path | Role |
| --- | --- |
| `spark.json` | Every version, package name, repo URL, kernel cmdline, and image dimension. Edit this to change what the image contains. |
| `spark.sh` | `jq` reader that exposes `spark.json` values to the build scripts. |
| `Dockerfile` + `build-rootfs.sh` | Build an arm64 Ubuntu 24.04 rootfs with the GB10 NVIDIA stack (QEMU binfmt, apt only). |
| `create-image.sh` | Assemble that rootfs into a bootable UEFI/GPT `.img`. |
| `root/` | Files copied verbatim into the image — services, the watchdog fix, first-boot self-test, docker/cuda config. |

## Build it yourself

Requires Docker with QEMU binfmt (for arm64 emulation on an amd64 host), plus
`jq`, `parted`, `rsync`, and dosfstools. The **no-DKMS** design (prebuilt signed
NVIDIA modules) means the QEMU/binfmt apt flow works with **no native-arm64
runner and no kernel-module compile step**.

```bash
# 1) Provision the rootfs (Docker build + export)
./build-rootfs.sh gb10-usb /var/cache/spark-rootfs/rootfs-gb10-usb

# 2) Assemble the bootable image (root: loop devices, mkfs, chroot)
sudo ./create-image.sh -b gb10-usb -r /var/cache/spark-rootfs/rootfs-gb10-usb

# -> gb10-usb.img
sudo dd if=gb10-usb.img of=/dev/sdX bs=4M status=progress conv=fsync   # /dev/sdX = your USB
```

## Continuous integration

Both workflows build the image end-to-end on a stock `ubuntu-24.04` runner (arm64
via QEMU binfmt; `sudo` for the loop/chroot assembly) — no self-hosted arm64 runner.

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| [`build.yml`](.github/workflows/build.yml) | Manual (`workflow_dispatch`) | On-demand **validation build** — choose the board and whether to `xz`-compress; uploads the `.img` as an artifact (7-day retention). No release/tag required. |
| [`pr.yml`](.github/workflows/pr.yml) | Pull request | Lints (`jq`, `shellcheck`, `bash -n`, hadolint — advisory), then a full end-to-end build so the in-chroot self-checks gate merges. |

The `create-image.sh` chroot asserts each GB10 quirk is really present before the
image is accepted: `sbsa_gwdt` in the initramfs, the full stability cmdline +
`rootdelay=30` in `grub.cfg`, `EFI/BOOT/BOOTAA64.EFI` on the ESP, container runtime
`legacy` mode, no swap, and a prebuilt `nvidia.ko` with no DKMS path.

## Default login

`ubuntu` / `ubuntu` — **change on first boot.** Networking is DHCP on any `en*` NIC.

## What is baked in vs. deferred to first boot

**Baked at image-build time** (nothing to do on first boot):
- Ubuntu 24.04 arm64, dist-upgraded, `unattended-upgrades` removed, apt timers off.
- NVIDIA **64k HWE kernel** (`linux-image-nvidia-64k-hwe-24.04`, 6.17) — GB10/Grace
  is a 64K-page kernel — with the GB10 PCIe/GPU-stability cmdline **plus `rootdelay=30`**
  (so the kernel finds the USB rootfs).
- **Prebuilt, signed NVIDIA module** `linux-modules-nvidia-580-open-nvidia-64k-hwe-24.04`.
  Its versioned `Provides: nvidia-dkms-580-open` satisfies the driver's dependency,
  so **no DKMS package is installed and nothing compiles** — the single biggest CI
  simplification. The build asserts a prebuilt `nvidia.ko` exists and dkms is absent.
- NVIDIA driver `580-open`, CUDA `13-0`, DCGM, NCCL, mlnx-tools — pinned via `spark.json`.
- **SBSA watchdog fix** (both layers: initramfs `insmod` premount hook + a
  `sbsa-watchdog-load` systemd oneshot that calls the `modprobe` binary) — prevents
  the ~20-min hard reset from the unserviced firmware watchdog.
- Docker CE + NVIDIA Container Toolkit, `nvidia` default runtime, **runtime forced to
  `legacy` mode** (fixes the CUDA-image `exec format error`).
- Swap disabled + `vm.swappiness=10`, Wi-Fi disabled, `networkd-wait-online --any`,
  persistent journal, weekly docker prune, `nvsm` purged.

**Deferred to a first-boot oneshot** (`gb10-firstboot.service`, runs once on real
hardware, logs to `/var/log/gb10-firstboot.log`, then disables itself) — only the
things that genuinely need the physical machine:
- **Platform firmware update** via fwupd. Skippable with `/etc/gb10/skip-firmware`.
  Keep the unit on AC power — an interrupted flash can brick the board.
- **In-container GPU verification** (`nvidia-smi` inside a CUDA container).
  Note: `nvidia-smi` showing `Memory-Usage: Not Supported` on GB10 is **normal**
  (unified memory, no discrete VRAM), not a failure.

## Secure Boot

Assumed **OFF** (home use). The modules then load with no MOK enrollment. No MOK
flows are built; if you insist on Secure Boot, the first-boot self-test warns you.

## Notes / known risks to validate on hardware

- **UEFI boot from scratch.** `create-image.sh` builds the GPT + ESP and installs
  GRUB with `--removable` (`\EFI\BOOT\BOOTAA64.EFI`). Confirm the Spark UEFI-boots
  the USB. Layout is the standard `p1=ESP, p2=root` (we build it ourselves, so we do
  not need the Ubuntu cloud image's `p1-root/p15-ESP` quirk).
- **Image size.** Driver + CUDA + toolkit is large; the image is ~26 GB. Use a
  ≥ 64 GB USB; put big Docker/model data on the internal NVMe if needed.
- **`findmnt /`** on the booted machine should show the USB device (NVMe untouched).

## Credits / references

Translated from [`timothystewart6/ubuntu-gb10`](https://github.com/timothystewart6/ubuntu-gb10)
(Ansible roles `base`, `nvidia_stack`, `docker_gpu`) into a data-driven,
apt-only, reproducible image-maker. Structure mirrors `aniongithub/jetson-nano-image-maker`.

## License

MIT

#!/usr/bin/env bash
# create-image.sh - IMAGE ASSEMBLY stage (no provisioning).
#
# Turns a provisioned rootfs directory (from build-rootfs.sh) into a bootable
# UEFI/GPT disk image for the NVIDIA GB10 / DGX Spark. Layout (built from scratch,
# so we choose the standard removable-media layout rather than the cloud image's
# p1-root/p15-ESP quirk):
#   partition 1  ESP   FAT32  (EFI system partition, \EFI\BOOT\BOOTAA64.EFI)
#   partition 2  root  ext4
#
# The bootloader is installed with `grub-install --removable` so the Spark's UEFI
# firmware boots the USB directly (Secure Boot assumed OFF). All sizes/labels come
# from spark.json via spark.sh. Run as root (loop devices, mkfs, chroot).
#
# Usage: sudo ./create-image.sh -b <board> -r <rootfs_dir> [-o <outdir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=spark.sh
source "$SCRIPT_DIR/spark.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script requires root (loop devices, mkfs, chroot). Re-run with sudo." >&2
  exit 1
fi

usage() {
  cat <<EOF
Usage: $0 -b <board> -r <rootfs_dir> [-o <outdir>]
  -b, --board    spark.json board key (e.g. gb10-usb)
  -r, --rootfs   rootfs directory produced by build-rootfs.sh
  -o, --outdir   output directory for the .img (default: .)
EOF
  exit 1
}

BOARD=""
ROOTFS=""
OUTDIR="."
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -b|--board)  BOARD="$2"; shift 2;;
    -r|--rootfs) ROOTFS="$2"; shift 2;;
    -o|--outdir) OUTDIR="$2"; shift 2;;
    -h|--help)   usage;;
    *) echo "Unknown arg: $1" >&2; usage;;
  esac
done

[ -n "$BOARD" ]  || { echo "Error: -b <board> is required" >&2; usage; }
[ -n "$ROOTFS" ] || { echo "Error: -r <rootfs_dir> is required" >&2; usage; }
[ -d "$ROOTFS" ] && [ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ] || {
  echo "Error: rootfs dir '$ROOTFS' missing or empty (run build-rootfs.sh first)" >&2; exit 1; }

if ! spark_metadata "$BOARD"; then
  echo "Unknown board: $BOARD (known: $(spark_list_boards | tr '\n' ' '))" >&2
  exit 1
fi

for tool in parted losetup mkfs.vfat mkfs.ext4 rsync blkid; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Error: '$tool' not found. Install it and re-run." >&2; exit 1; }
done

mkdir -p "$OUTDIR"
OUT_IMG="${OUTDIR%/}/${SPARK_OUTPUT_IMG}"
ESP_MIB="${SPARK_ESP_SIZE_MIB:-512}"
IMG_SIZE="${SPARK_IMAGE_SIZE:-26G}"

echo "Image assembly settings:"
echo "  board:   $BOARD"
echo "  rootfs:  $ROOTFS"
echo "  output:  $OUT_IMG"
echo "  size:    $IMG_SIZE   (ESP ${ESP_MIB}MiB + ext4 root)"

# --- cleanup trap ------------------------------------------------------------
MNT=""
LOOP=""
cleanup() {
  set +e
  if [ -n "$MNT" ]; then
    for m in "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/boot/efi" "$MNT"; do
      mountpoint -q "$m" && umount -lf "$m"
    done
    rmdir "$MNT" 2>/dev/null
  fi
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# --- allocate the image ------------------------------------------------------
rm -f "$OUT_IMG"
truncate -s "$IMG_SIZE" "$OUT_IMG"

# --- partition GPT: p1 ESP, p2 root -----------------------------------------
parted -s "$OUT_IMG" mklabel gpt
parted -s "$OUT_IMG" mkpart "${SPARK_ESP_LABEL:-ESP}" fat32 1MiB "$((ESP_MIB + 1))MiB"
parted -s "$OUT_IMG" set 1 esp on
parted -s "$OUT_IMG" mkpart "${SPARK_ROOT_LABEL:-writable}" ext4 "$((ESP_MIB + 1))MiB" 100%

# --- attach loop device with partition scanning ------------------------------
modprobe loop 2>/dev/null || true
LOOP="$(losetup --find --show --partscan "$OUT_IMG")"
echo "Loop device: $LOOP"
ESP_DEV="${LOOP}p1"
ROOT_DEV="${LOOP}p2"
for i in $(seq 1 10); do [ -b "$ESP_DEV" ] && [ -b "$ROOT_DEV" ] && break; sleep 0.3; done
[ -b "$ESP_DEV" ] && [ -b "$ROOT_DEV" ] || { echo "Error: loop partitions not present" >&2; exit 1; }

# --- filesystems -------------------------------------------------------------
mkfs.vfat -F 32 -n "${SPARK_ESP_LABEL:-ESP}" "$ESP_DEV"
mkfs.ext4 -F -L "${SPARK_ROOT_LABEL:-writable}" "$ROOT_DEV"

# --- mount + populate --------------------------------------------------------
MNT="$(mktemp -d)"
mount "$ROOT_DEV" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$ESP_DEV" "$MNT/boot/efi"

echo "Copying rootfs -> image (this may take a while)"
rsync -aHAXx --numeric-ids "$ROOTFS"/ "$MNT"/

# --- fstab by UUID -----------------------------------------------------------
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_DEV")"
cat > "$MNT/etc/fstab" <<EOF
# <file system>          <mount point>  <type>  <options>          <dump> <pass>
UUID=${ROOT_UUID}  /              ext4    defaults,noatime   0      1
UUID=${ESP_UUID}   /boot/efi      vfat    umask=0077         0      1
EOF

# --- bind mounts for chroot --------------------------------------------------
mount --bind /dev  "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys  "$MNT/sys"
# resolv.conf for any chroot network use (grub/initramfs do not need it, but harmless)
cp -f /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

# Ensure arm64 binaries run inside the chroot on an amd64 host. tonistiigi/binfmt
# and qemu-user-static register the interpreter with the F (fix-binary) flag so it
# is available in the chroot without copying; copy a static qemu as a fallback.
if [ "$(uname -m)" != "aarch64" ] && [ -x /usr/bin/qemu-aarch64-static ]; then
  cp -f /usr/bin/qemu-aarch64-static "$MNT/usr/bin/" 2>/dev/null || true
fi

# --- install bootloader + regenerate grub/initramfs inside the target --------
echo "Installing GRUB (arm64-efi, removable) + regenerating grub.cfg/initramfs"
chroot "$MNT" /bin/bash -euo pipefail <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive

# Enumerate installed kernels from /lib/modules - NOT `uname -r`, which under an
# arm64 QEMU/binfmt chroot leaks the amd64 HOST kernel version.
KVERS="$(ls /lib/modules)"
echo "Installed kernels in rootfs: ${KVERS}"

# Regenerate initramfs for every installed kernel (version-explicit via -k all;
# pulls in the sbsa_gwdt .ko + init-premount insmod hook), THEN grub.cfg so the
# menu references the final initrd and the full GB10 cmdline (incl. rootdelay=30).
update-initramfs -u -k all
grub-install --target=arm64-efi --efi-directory=/boot/efi \
  --bootloader-id=GRUB --removable --no-nvram --recheck
update-grub

# --- image self-checks (fail the build loudly, not the hardware) -------------
echo "=== image self-checks ==="
fail=0
for k in ${KVERS}; do
  if lsinitramfs "/boot/initrd.img-${k}" 2>/dev/null | grep -q 'sbsa_gwdt'; then
    echo "[ok]   sbsa_gwdt in initramfs for ${k}"
  else
    echo "[FAIL] sbsa_gwdt NOT in initramfs for ${k} (watchdog layer-1 broken)"; fail=1
  fi
done
grep -q 'rootdelay=30' /boot/grub/grub.cfg \
  && echo "[ok]   rootdelay=30 in grub.cfg" \
  || { echo "[FAIL] rootdelay=30 missing from grub.cfg"; fail=1; }
grep -q 'initcall_blacklist=tegra234_cbb_init' /boot/grub/grub.cfg \
  && echo "[ok]   GB10 stability cmdline in grub.cfg" \
  || { echo "[FAIL] GB10 stability cmdline missing from grub.cfg"; fail=1; }
[ -f /boot/efi/EFI/BOOT/BOOTAA64.EFI ] \
  && echo "[ok]   EFI/BOOT/BOOTAA64.EFI present (removable boot path)" \
  || { echo "[FAIL] EFI/BOOT/BOOTAA64.EFI missing (USB-live will not boot)"; fail=1; }
grep -q 'mode = "legacy"' /etc/nvidia-container-runtime/config.toml 2>/dev/null \
  && echo "[ok]   nvidia-container-runtime mode=legacy" \
  || { echo "[FAIL] nvidia-container-runtime not in legacy mode"; fail=1; }
if grep -qiE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
  echo "[FAIL] swap entry present in fstab"; fail=1
else
  echo "[ok]   no swap entry in fstab"
fi
for k in ${KVERS}; do
  case "${k}" in *nvidia-64k*)
    if ls /lib/modules/"${k}"/updates/dkms/nvidia.ko* >/dev/null 2>&1; then
      echo "[FAIL] dkms nvidia.ko path present for ${k}"; fail=1
    elif ls /lib/modules/"${k}"/kernel/nvidia*/nvidia.ko* /lib/modules/"${k}"/updates/nvidia.ko* >/dev/null 2>&1; then
      echo "[ok]   prebuilt nvidia.ko present for ${k}"
    else
      echo "[FAIL] no prebuilt nvidia.ko for ${k}"; fail=1
    fi ;;
  esac
done
[ "${fail}" -eq 0 ] || { echo "=== IMAGE SELF-CHECKS FAILED ==="; exit 1; }
echo "=== all image self-checks passed ==="
CHROOT

# --- done --------------------------------------------------------------------
sync
echo "Image created: $OUT_IMG"
echo "Flash it:  sudo dd if=${OUT_IMG} of=/dev/sdX bs=4M status=progress conv=fsync"

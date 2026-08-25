#!/usr/bin/env bash
# build-rootfs.sh - PROVISIONING stage.
#
# Builds the GB10 Dockerfile for linux/arm64 (under QEMU binfmt on an amd64 host)
# and exports the container filesystem to a rootfs directory. create-image.sh then
# turns that rootfs into a bootable UEFI/GPT image. Every package/version/URL comes
# from spark.json (via spark.sh) - this script only wires them into build-args.
#
# Usage: ./build-rootfs.sh [board] [output_dir]
#   board       : spark.json board key (default: gb10-usb)
#   output_dir  : where to export the rootfs (default: /var/cache/spark-rootfs/rootfs-<board>)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=spark.sh
source "$SCRIPT_DIR/spark.sh"

BOARD="${1:-gb10-usb}"
if ! spark_metadata "$BOARD"; then
  echo "Unknown board: $BOARD (known: $(spark_list_boards | tr '\n' ' '))" >&2
  exit 1
fi

OUT_DIR="${2:-${SPARK_ROOTFS_DIR:-/var/cache/spark-rootfs/rootfs-${BOARD}}}"

echo "Building rootfs for ${BOARD} (Ubuntu ${SPARK_UBUNTU} ${SPARK_ARCH}) -> ${OUT_DIR}"

if command -v podman >/dev/null 2>&1; then
  BUILDER=podman
else
  BUILDER=docker
fi
echo "Using builder: ${BUILDER}"

# GB10 is arm64; the rootfs MUST be arm64 regardless of host arch. Building
# natively on amd64 would produce an unbootable amd64 rootfs and break apt (the
# ports/sbsa/nvidia packages are arm64-only). Override with TARGET_PLATFORM only
# if you know what you are doing.
TARGET_PLATFORM="${TARGET_PLATFORM:-linux/arm64}"
echo "Building for platform: ${TARGET_PLATFORM}"

# Register QEMU binfmt handlers so the arm64 build runs under emulation on amd64.
# Best-effort: the host may already provide them (qemu-user-static package).
if [ "${BUILDER}" = "docker" ]; then
  export DOCKER_BUILDKIT=1
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 \
    || echo "Note: could not register QEMU binfmt via tonistiigi/binfmt; assuming host already provides it"
fi

BUILD_TAG="spark-rootfs:${BOARD}"

${BUILDER} build \
  --platform "${TARGET_PLATFORM}" \
  --build-arg BASE_IMAGE="${SPARK_BASE_DOCKER_IMAGE}" \
  --build-arg DGX_REPO_FILES_URL="${SPARK_DGX_REPO_FILES_URL}" \
  --build-arg CUDA_SBSA_REPO="${SPARK_CUDA_SBSA_REPO}" \
  --build-arg KERNEL_IMAGE_META="${SPARK_KERNEL_IMAGE_META}" \
  --build-arg KERNEL_HEADERS_META="${SPARK_KERNEL_HEADERS_META}" \
  --build-arg KERNEL_TOOLS_META="${SPARK_KERNEL_TOOLS_META}" \
  --build-arg KERNEL_CONCRETE="${SPARK_KERNEL_CONCRETE}" \
  --build-arg NVIDIA_DRIVER="${SPARK_NVIDIA_DRIVER}" \
  --build-arg NVIDIA_DRIVER_PINNING="${SPARK_NVIDIA_DRIVER_PINNING}" \
  --build-arg NVIDIA_MODULES_PKG="${SPARK_NVIDIA_MODULES_PKG}" \
  --build-arg NVIDIA_DKMS_AVOID="${SPARK_NVIDIA_DKMS_AVOID}" \
  --build-arg CUDA_TOOLKIT="${SPARK_CUDA_TOOLKIT}" \
  --build-arg NVIDIA_MODPROBE="${SPARK_NVIDIA_MODPROBE}" \
  --build-arg NVIDIA_MODPROBE_VER="${SPARK_NVIDIA_MODPROBE_VER}" \
  --build-arg NVIDIA_CONTAINER_TOOLKIT="${SPARK_NVIDIA_CONTAINER_TOOLKIT}" \
  --build-arg CONTAINER_RUNTIME_MODE="${SPARK_CONTAINER_RUNTIME_MODE}" \
  --build-arg NVIDIA_SYSTEM_PKGS="${SPARK_NVIDIA_SYSTEM_PKGS}" \
  --build-arg NVIDIA_EXTRA_PKGS="${SPARK_NVIDIA_EXTRA_PKGS}" \
  --build-arg NVIDIA_PURGE="${SPARK_NVIDIA_PURGE}" \
  --build-arg DOCKER_PKGS="${SPARK_DOCKER_PKGS}" \
  --build-arg DOCKER_DEFAULT_RUNTIME="${SPARK_DOCKER_DEFAULT_RUNTIME}" \
  --build-arg KERNEL_CMDLINE="${SPARK_KERNEL_CMDLINE}" \
  --build-arg SWAPPINESS="${SPARK_SWAPPINESS}" \
  --build-arg DISABLE_WIFI_IFACE="${SPARK_DISABLE_WIFI_IFACE}" \
  --build-arg DEFAULT_USER="${SPARK_DEFAULT_USER}" \
  --build-arg DEFAULT_PASS="${SPARK_DEFAULT_PASS}" \
  -t "${BUILD_TAG}" \
  "${SCRIPT_DIR}"

echo "Exporting container filesystem to ${OUT_DIR}"
if ! mkdir -p "${OUT_DIR}" 2>/dev/null; then
  echo "Failed to create ${OUT_DIR}. Re-run with sudo or pass a writable output_dir." >&2
  exit 1
fi
# Start clean so repeated runs do not accumulate stale files.
if [ -n "$(ls -A "${OUT_DIR}" 2>/dev/null)" ]; then
  echo "Output dir not empty; clearing ${OUT_DIR}"
  rm -rf "${OUT_DIR:?}/"* "${OUT_DIR:?}/".[!.]* 2>/dev/null || true
fi

tmpcid=$(${BUILDER} create --platform "${TARGET_PLATFORM}" "${BUILD_TAG}")
${BUILDER} export "${tmpcid}" | tar -C "${OUT_DIR}" -xf -
${BUILDER} rm "${tmpcid}" >/dev/null

rm -f "${OUT_DIR}/.dockerenv" "${OUT_DIR}/root/.bash_history" 2>/dev/null || true

echo "Rootfs available at: ${OUT_DIR}"
echo "Now run:  sudo ./create-image.sh -b ${BOARD} -r ${OUT_DIR}"

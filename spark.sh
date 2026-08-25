#!/usr/bin/env bash
# spark.sh - read spark.json and export the values that build-rootfs.sh (Docker
# build-args) and create-image.sh (image/partition layout) need.
#
# This mirrors jetson-nano-image-maker's boards.sh: spark.json is the single
# source of truth (pure data), and this file is the deterministic jq reader over
# it. Provisioning (Dockerfile) and image creation (create-image.sh) stay
# separate; both pull their parameters from here.
#
# Usage:  source spark.sh; spark_metadata <board>

SPARK_JSON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spark.json"

# spark_field <board> <jq-path-after-.boards[$b]>  -> prints value or empty
spark_field() {
  local board="$1" path="$2"
  jq -r --arg b "$board" ".boards[\$b].${path} // empty" "$SPARK_JSON" 2>/dev/null || true
}

# spark_list <board> <jq-path-to-array>  -> space-joined array elements
spark_list() {
  local board="$1" path="$2"
  jq -r --arg b "$board" ".boards[\$b].${path} // [] | join(\" \")" "$SPARK_JSON" 2>/dev/null || true
}

# spark_metadata <board> : validate and export SPARK_* for the given board.
spark_metadata() {
  local board="$1"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is required to read spark.json. Install 'jq' and re-run." >&2
    return 1
  fi
  if [ ! -f "$SPARK_JSON" ]; then
    echo "Error: $SPARK_JSON not found." >&2
    return 1
  fi
  if ! jq -e --arg b "$board" '.boards[$b]' "$SPARK_JSON" >/dev/null 2>&1; then
    echo "Error: no metadata for board '$board' in $SPARK_JSON" >&2
    return 1
  fi

  # Identity
  export SPARK_BOARD="$board"
  export SPARK_ARCH="$(spark_field "$board" 'arch')"
  export SPARK_UBUNTU="$(spark_field "$board" 'ubuntu')"
  export SPARK_UBUNTU_CODENAME="$(spark_field "$board" 'ubuntu_codename')"
  export SPARK_OUTPUT_IMG="$(spark_field "$board" 'output')"
  export SPARK_BASE_DOCKER_IMAGE="$(spark_field "$board" 'base_docker_image')"

  # apt origins
  export SPARK_DGX_REPO_FILES_URL="$(spark_field "$board" 'apt_origins.dgx_baseos_repo_files')"
  export SPARK_CUDA_SBSA_REPO="$(spark_field "$board" 'apt_origins.cuda_sbsa_repo')"

  # kernel (64k HWE flavour -- must match the module flavour)
  export SPARK_KERNEL_FLAVOUR="$(spark_field "$board" 'kernel.flavour')"
  export SPARK_KERNEL_IMAGE_META="$(spark_field "$board" 'kernel.image_meta')"
  export SPARK_KERNEL_HEADERS_META="$(spark_field "$board" 'kernel.headers_meta')"
  export SPARK_KERNEL_TOOLS_META="$(spark_field "$board" 'kernel.tools_meta')"
  export SPARK_KERNEL_CONCRETE="$(spark_field "$board" 'kernel.concrete')"
  export SPARK_KERNEL_RELEASE="$(spark_field "$board" 'kernel.release')"

  # nvidia stack
  export SPARK_NVIDIA_DRIVER="$(spark_field "$board" 'nvidia.driver')"
  export SPARK_NVIDIA_DRIVER_PINNING="$(spark_field "$board" 'nvidia.driver_pinning')"
  export SPARK_NVIDIA_MODULES_PKG="$(spark_field "$board" 'nvidia.modules_package')"
  export SPARK_NVIDIA_DKMS_AVOID="$(spark_field "$board" 'nvidia.dkms_package_avoid')"
  export SPARK_CUDA_TOOLKIT="$(spark_field "$board" 'nvidia.cuda_toolkit')"
  export SPARK_NVIDIA_MODPROBE="$(spark_field "$board" 'nvidia.modprobe')"
  export SPARK_NVIDIA_MODPROBE_VER="$(spark_field "$board" 'nvidia.modprobe_version')"
  export SPARK_NVIDIA_CONTAINER_TOOLKIT="$(spark_field "$board" 'nvidia.container_toolkit')"
  export SPARK_CONTAINER_RUNTIME_MODE="$(spark_field "$board" 'nvidia.container_runtime_mode')"
  export SPARK_NVIDIA_SYSTEM_PKGS="$(spark_list "$board" 'nvidia.system_packages')"
  export SPARK_NVIDIA_EXTRA_PKGS="$(spark_list "$board" 'nvidia.extra_packages')"
  export SPARK_NVIDIA_PURGE="$(spark_list "$board" 'nvidia.purge')"

  # docker
  export SPARK_DOCKER_PKGS="$(spark_list "$board" 'docker.packages')"
  export SPARK_DOCKER_DEFAULT_RUNTIME="$(spark_field "$board" 'docker.default_runtime')"

  # kernel cmdline + quirks
  export SPARK_KERNEL_CMDLINE="$(spark_field "$board" 'cmdline')"
  export SPARK_SWAPPINESS="$(spark_field "$board" 'quirks.swappiness')"
  export SPARK_DISABLE_WIFI_IFACE="$(spark_field "$board" 'quirks.disable_wifi_iface')"

  # credentials
  export SPARK_DEFAULT_USER="$(spark_field "$board" 'credentials.username')"
  export SPARK_DEFAULT_PASS="$(spark_field "$board" 'credentials.password')"

  # image / partition layout (consumed by create-image.sh)
  export SPARK_IMAGE_SIZE="$(spark_field "$board" 'image.size')"
  export SPARK_ESP_SIZE_MIB="$(spark_field "$board" 'image.esp_size_mib')"
  export SPARK_ESP_LABEL="$(spark_field "$board" 'image.esp_label')"
  export SPARK_ROOT_LABEL="$(spark_field "$board" 'image.root_label')"

  return 0
}

# spark_list_boards : print all board keys, one per line.
spark_list_boards() {
  jq -r '.boards | keys[]' "$SPARK_JSON" 2>/dev/null || true
}

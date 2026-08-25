# syntax=docker/dockerfile:1
#
# gb10-image-maker : provisioning stage (NOT image assembly).
#
# Builds an arm64 Ubuntu 24.04 rootfs containing the full NVIDIA GB10 / DGX Spark
# stack. build-rootfs.sh builds this for linux/arm64 (via QEMU binfmt) and exports
# the container filesystem to a rootfs directory; create-image.sh then assembles a
# bootable UEFI/GPT image from that rootfs. Provisioning and image creation are
# deliberately kept in separate tools (unlike pimod, which fuses them).
#
# Every version/package/URL below is injected from spark.json via build-rootfs.sh.
# Translated from timothystewart6/ubuntu-gb10 (Ansible roles base, nvidia_stack,
# docker_gpu) as a data-driven, apt-only, reproducible build.

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE} AS base

ARG DEBIAN_FRONTEND=noninteractive

# --- spark.json-driven build args --------------------------------------------
ARG DGX_REPO_FILES_URL
ARG CUDA_SBSA_REPO
ARG KERNEL_IMAGE_META
ARG KERNEL_HEADERS_META
ARG KERNEL_TOOLS_META
ARG KERNEL_CONCRETE
ARG NVIDIA_DRIVER
ARG NVIDIA_DRIVER_PINNING
ARG NVIDIA_MODULES_PKG
ARG NVIDIA_DKMS_AVOID
ARG CUDA_TOOLKIT
ARG NVIDIA_MODPROBE
ARG NVIDIA_MODPROBE_VER
ARG NVIDIA_CONTAINER_TOOLKIT
ARG CONTAINER_RUNTIME_MODE=legacy
ARG NVIDIA_SYSTEM_PKGS
ARG NVIDIA_EXTRA_PKGS
ARG NVIDIA_PURGE
ARG DOCKER_PKGS
ARG DOCKER_DEFAULT_RUNTIME=nvidia
ARG KERNEL_CMDLINE
ARG SWAPPINESS=10
ARG DISABLE_WIFI_IFACE
ARG DEFAULT_USER=ubuntu
ARG DEFAULT_PASS=ubuntu

# =============================================================================
# Bootable base system (a from-scratch ubuntu:24.04 rootfs is not bootable on
# its own - install init, networking, and the UEFI boot chain explicitly).
# =============================================================================
# Non-interactive apt/dpkg conffile policy. Several DGX packages ship a conffile
# we also bootstrap out-of-band - notably dgx-repo's /etc/apt/sources.list.d/
# dgx.sources, already written by the DGX baseos tarball (step 1 below). Without
# this, dpkg tries to PROMPT about the pre-existing file and hits "end of file on
# stdin at conffile prompt", failing the non-interactive build. Keep our
# (tarball) version via confdef/confold; DEBIAN_FRONTEND alone does NOT cover
# dpkg conffile prompts.
RUN set -e; { \
      echo 'APT::Get::Assume-Yes "true";'; \
      echo 'Dpkg::Options:: "--force-confdef";'; \
      echo 'Dpkg::Options:: "--force-confold";'; \
    } > /etc/apt/apt.conf.d/99-gb10-noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
      systemd systemd-sysv init udev dbus \
      sudo openssh-server netplan.io \
      net-tools iproute2 kmod parted dmidecode \
      initramfs-tools \
      grub-efi-arm64 grub-efi-arm64-signed shim-signed efibootmgr \
      fwupd cron \
    && rm -rf /var/lib/apt/lists/*

# base role: drop noisy/undesired auto-update machinery.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade \
    && apt-get purge -y unattended-upgrades || true
RUN systemctl disable apt-daily.timer apt-daily-upgrade.timer || true

# Bring in our static config tree (services, watchdog hook, first-boot, docker,
# cuda env, netplan, journald persistence, docker prune).
COPY root/ /
RUN chmod 0600 /etc/netplan/01-netcfg.yaml \
    && chmod 0755 /etc/initramfs-tools/scripts/init-premount/sbsa_gwdt \
    && chmod 0755 /opt/gb10/gb10-firstboot.sh /opt/actions-runner/prune-docker.sh

# =============================================================================
# base role : appliance + GB10 quirks
# =============================================================================
# Swap off: swap + GPU DMA on unified memory causes hard lockups (no swap is
# created by create-image.sh; enforce the sysctl too).
RUN echo "vm.swappiness = ${SWAPPINESS}" > /etc/sysctl.d/99-gb10.conf

# Belt-and-suspenders: never let swap come up (zram or otherwise). Unified memory
# + GPU DMA over a swap path is what causes the hard lockups. create-image.sh
# writes NO swap entry to fstab; here we also mask swap.target and drop any zram
# swap generator that an Ubuntu meta might pull in.
RUN systemctl mask swap.target 2>/dev/null || true; \
    apt-get purge -y systemd-zram-generator zram-config zram-tools 2>/dev/null || true; \
    rm -f /etc/systemd/zram-generator.conf 2>/dev/null || true

# Disable the MediaTek Wi-Fi at boot.
RUN if [ -n "${DISABLE_WIFI_IFACE}" ]; then \
      printf 'SUBSYSTEM=="net", ACTION=="add", KERNEL=="%s", RUN+="/sbin/ip link set %%k down"\n' \
        "${DISABLE_WIFI_IFACE}" > /etc/udev/rules.d/99-disable-wifi.rules ; \
    fi

# networkd-wait-online: wait for ANY interface, not all.
RUN mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d \
    && printf '[Service]\nExecStart=\nExecStart=/lib/systemd/systemd-networkd-wait-online --any\n' \
       > /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf

# GRUB cmdline: GB10 PCIe/GPU stability params + rootdelay for USB boot.
# grub-mkconfig sources /etc/default/grub.d/*.cfg, so a drop-in keeps spark.json
# authoritative without editing the distro's /etc/default/grub.
RUN printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "${KERNEL_CMDLINE}" \
      > /etc/default/grub.d/99-gb10.cfg

# SBSA watchdog: ensure the module is included in the initramfs (the init-premount
# insmod hook shipped in root/ loads it; the systemd oneshot reloads it post-boot).
RUN echo "sbsa_gwdt  # SBSA watchdog - loaded via init-premount insmod hook" \
      >> /etc/initramfs-tools/modules

# =============================================================================
# nvidia_stack role : DGX apt origins + kernel + PREBUILT signed module + driver
# =============================================================================
# 1) DGX baseos repo files (apt config/pins/keyrings; points CUDA at the sbsa repo).
RUN curl -fsSL "${DGX_REPO_FILES_URL}" | tar xzf - -C / \
    && apt-get update

# 2) NVIDIA system packages + kernel tools.
RUN apt-get install -y --no-install-recommends \
      ${NVIDIA_SYSTEM_PKGS} ${KERNEL_TOOLS_META}

# 3) Prefer prebuilt NVIDIA modules over DKMS (drops an apt preference).
RUN apt-get install -y --no-install-recommends ${NVIDIA_DRIVER_PINNING}

# 4) THE CI-CRITICAL STEP: 64k HWE kernel + PREBUILT SIGNED module + driver, in one
# transaction. The module package Provides: nvidia-dkms-580-open (= <ver>), which
# satisfies the driver's dkms dependency WITHOUT installing the real dkms package -
# so nothing compiles and the pure QEMU/binfmt apt flow works. Kernel flavour MUST
# equal module flavour (64k for GB10/Grace).
# NOTE: kernel headers are intentionally NOT installed - without DKMS nothing
# compiles in-image, so headers only bloat the rootfs. (KERNEL_HEADERS_META stays
# in spark.json for anyone who re-adds an on-device build later.)
RUN apt-get install -y --no-install-recommends \
      ${KERNEL_IMAGE_META} \
      ${NVIDIA_MODULES_PKG} \
      ${NVIDIA_DRIVER}

# Assert prebuilt won and DKMS never ran (fail the build loudly otherwise).
RUN set -e; K="${KERNEL_CONCRETE}"; \
    if ls /lib/modules/"$K"/updates/dkms/nvidia.ko* >/dev/null 2>&1; then \
      echo "ERROR: dkms module path present for $K"; exit 1; fi; \
    if ! ls /lib/modules/"$K"/kernel/nvidia*/nvidia.ko* /lib/modules/"$K"/updates/nvidia.ko* >/dev/null 2>&1; then \
      echo "ERROR: no prebuilt nvidia.ko for $K"; exit 1; fi; \
    if dpkg -l dkms 2>/dev/null | grep -q '^ii'; then \
      echo "ERROR: dkms is installed"; exit 1; fi; \
    echo "OK: prebuilt NVIDIA modules present, no dkms"

# 5) Remaining driver/runtime packages + CUDA toolkit + pinned modprobe.
RUN apt-get install -y --no-install-recommends ${NVIDIA_EXTRA_PKGS}
RUN apt-get install -y --no-install-recommends ${CUDA_TOOLKIT}
RUN apt-get install -y --no-install-recommends --allow-downgrades \
      "${NVIDIA_MODPROBE}=${NVIDIA_MODPROBE_VER}"

RUN systemctl enable nvidia-persistenced nvidia-dcgm || true

# Purge unwanted DGX system-management packages.
RUN if [ -n "${NVIDIA_PURGE}" ]; then apt-get purge -y ${NVIDIA_PURGE} || true; fi
RUN apt-get autoremove -y

# =============================================================================
# docker_gpu role : Docker CE + NVIDIA Container Toolkit (forced legacy mode)
# =============================================================================
RUN apt-get install -y --no-install-recommends ${DOCKER_PKGS}
RUN apt-get install -y --no-install-recommends ${NVIDIA_CONTAINER_TOOLKIT} nv-docker-options || \
    apt-get install -y --no-install-recommends ${NVIDIA_CONTAINER_TOOLKIT}

# nvidia-container-runtime: force legacy mode (auto/CDI breaks CUDA entrypoints
# with "exec format error"). The mode is read from config.toml, NOT daemon.json,
# so we make sure the file exists and the key is set - and assert it, because a
# silent no-op here reintroduces the exec-format bug on real hardware.
RUN set -e; CFG=/etc/nvidia-container-runtime/config.toml; \
    if command -v nvidia-ctk >/dev/null 2>&1; then \
      nvidia-ctk config --in-place --set nvidia-container-runtime.mode="${CONTAINER_RUNTIME_MODE}" || true; \
    fi; \
    install -d /etc/nvidia-container-runtime; \
    if [ -f "$CFG" ] && grep -qE '^[[:space:]]*#?[[:space:]]*mode[[:space:]]*=' "$CFG"; then \
      sed -i 's/^[[:space:]]*#\?[[:space:]]*mode[[:space:]]*=.*/mode = "'"${CONTAINER_RUNTIME_MODE}"'"/' "$CFG"; \
    elif [ -f "$CFG" ] && grep -q '^\[nvidia-container-runtime\]' "$CFG"; then \
      sed -i '/^\[nvidia-container-runtime\]/a mode = "'"${CONTAINER_RUNTIME_MODE}"'"' "$CFG"; \
    else \
      printf '[nvidia-container-runtime]\nmode = "%s"\n' "${CONTAINER_RUNTIME_MODE}" >> "$CFG"; \
    fi; \
    grep -q 'mode = "'"${CONTAINER_RUNTIME_MODE}"'"' "$CFG" || { echo "ERROR: nvidia-container-runtime mode not set"; exit 1; }; \
    echo "OK: nvidia-container-runtime mode = ${CONTAINER_RUNTIME_MODE}"

# =============================================================================
# Enable services + default user
# =============================================================================
RUN systemctl enable ssh systemd-networkd systemd-resolved cron docker \
      sbsa-watchdog-load.service gb10-firstboot.service || true

RUN useradd -ms /bin/bash "${DEFAULT_USER}" 2>/dev/null || true \
    && echo "${DEFAULT_USER}:${DEFAULT_PASS}" | chpasswd \
    && usermod -aG sudo,docker "${DEFAULT_USER}" || true

# Clean apt metadata to shrink the exported rootfs.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

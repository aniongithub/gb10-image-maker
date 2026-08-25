#!/usr/bin/env bash
# gb10-firstboot.sh - runs ONCE on real GB10 hardware, then disables itself.
# Handles the steps that can only happen on the actual machine: platform firmware
# update + GPU/NIC self-test. Logs to /var/log/gb10-firstboot.log and the journal.
set -uo pipefail

DONE=/var/lib/gb10-firstboot.done
LOG=/var/log/gb10-firstboot.log
exec > >(tee -a "$LOG") 2>&1

echo "=== gb10-firstboot @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ---------------------------------------------------------------------------
# 1. GPU / driver self-test (non-fatal; logs status)
# ---------------------------------------------------------------------------
if lsmod | grep -q '^nvidia'; then
  echo "[ok] nvidia kernel module loaded"
else
  echo "[WARN] nvidia module NOT loaded. If UEFI Secure Boot is ON, disable it"
  echo "       (home users do not need it) or enroll the module MOK; then reboot."
fi

if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
  echo "[ok] nvidia-smi:"; nvidia-smi || true
  # NOTE: on GB10 'Memory-Usage: Not Supported' is NORMAL (unified memory, no
  # discrete VRAM) - it is not a failure.
else
  echo "[WARN] nvidia-smi did not report a GPU yet."
fi

# Optional in-container GPU check - only if docker + network are available.
if command -v docker >/dev/null && timeout 5 getent hosts nvcr.io >/dev/null 2>&1; then
  if docker run --rm --gpus all --entrypoint nvidia-smi \
       nvcr.io/nvidia/cuda:12.6.2-base-ubuntu24.04 >/dev/null 2>&1; then
    echo "[ok] GPU visible inside a CUDA container"
  else
    echo "[WARN] container GPU test failed (check nvidia-container-runtime legacy mode)"
  fi
else
  echo "[skip] container GPU test (no docker or no network)"
fi

# ---------------------------------------------------------------------------
# 2. ConnectX-7 / mlx5 check (only if the NIC is present)
# ---------------------------------------------------------------------------
if lspci 2>/dev/null | grep -qi 'ConnectX-7'; then
  lsmod | grep -q '^mlx5_core' && echo "[ok] mlx5_core loaded" \
    || echo "[WARN] ConnectX-7 present but mlx5_core not loaded (DOCA-OFED not installed?)"
else
  echo "[skip] no ConnectX-7 NIC"
fi

# ---------------------------------------------------------------------------
# 3. Platform firmware update (parity with ubuntu-gb10 base role).
#    CAUTION: flashing firmware can brick the board on power loss. Skipped if
#    /etc/gb10/skip-firmware exists. Keep the unit on AC power for first boot.
# ---------------------------------------------------------------------------
if [ -e /etc/gb10/skip-firmware ]; then
  echo "[skip] firmware update disabled via /etc/gb10/skip-firmware"
elif command -v fwupdmgr >/dev/null; then
  echo "[fwupd] refreshing metadata..."
  fwupdmgr refresh --force || true
  if fwupdmgr get-updates 2>/dev/null | grep -qiv 'No updates available'; then
    echo "[fwupd] applying updates (do not power off)..."
    fwupdmgr update --no-reboot-check --assume-yes || true
  else
    echo "[fwupd] no updates available"
  fi
else
  echo "[skip] fwupd not installed"
fi

# ---------------------------------------------------------------------------
# Mark complete and disable this service so it never runs again.
# ---------------------------------------------------------------------------
touch "$DONE"
systemctl disable gb10-firstboot.service || true
echo "=== gb10-firstboot done; service disabled ==="

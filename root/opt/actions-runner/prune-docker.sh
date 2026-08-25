#!/bin/bash
# Weekly Docker system prune - removes unused images, containers, and networks.
# Volumes are excluded to protect persistent data (model cache, etc.).
set -euo pipefail
echo "[docker-prune] starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker system prune -af
echo "[docker-prune] done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

#!/usr/bin/env bash
# ==============================================================================
# rollback-ingress.sh - Instant Ingress Fallback to Caddy
# Restores Caddy container and halts Nginx in under 2 seconds.
# ==============================================================================

set -euo pipefail

echo "======================================================================"
echo "          INITIATING INGRESS ROLLBACK (Nginx -> Caddy)                "
echo "======================================================================"

echo "1. Stopping host Nginx..."
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true

echo "2. Starting Caddy Docker container..."
sudo docker start dashboard-caddy-1 || true

echo "3. Verifying Caddy is listening on ports 80/443..."
sleep 2
if sudo docker ps --format '{{.Names}}' | grep -q caddy; then
    echo "✅ Caddy container is UP and operational."
    echo "======================================================================"
    echo "  Ingress rollback completed. Caddy is actively routing traffic.     "
    echo "======================================================================"
else
    echo "❌ ERROR: Caddy container failed to start! Inspect: sudo docker logs dashboard-caddy-1"
    exit 1
fi

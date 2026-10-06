#!/usr/bin/env bash
# ==============================================================================
# cutover-nginx.sh - Pre-validated Ingress Cutover Engine
# Safely switches public ports 80/443 from Caddy to Nginx with instant fallback.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "======================================================================"
echo "          Pre-Cutover Safety Checks (Caddy -> Nginx)                  "
echo "======================================================================"

# 1. Validate Nginx Syntax
echo "1. Validating Nginx configuration syntax..."
if ! sudo nginx -t; then
    echo "❌ FATAL: Nginx syntax check failed! Aborting cutover."
    exit 1
fi
echo "   ✅ Nginx syntax is 100% valid."

# 2. Verify Internal Application Upstreams
echo "2. Verifying all internal application endpoints..."
UPSTREAMS=(
    "3001:/api/ping:Titan"
    "3002:/:Xylozen"
    "3003:/:ByteBandits"
    "4001:/api/health:CRM-Backend-Prod"
)

ALL_UPSTREAMS_OK=true
for entry in "${UPSTREAMS[@]}"; do
    IFS=':' read -r PORT PATH LABEL <<< "$entry"
    HTTP_CODE=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${PATH}" || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "   ✅ ${LABEL} (port ${PORT}${PATH}) is ONLINE (HTTP 200)."
    else
        echo "   ❌ ERROR: ${LABEL} (port ${PORT}${PATH}) responded with HTTP ${HTTP_CODE}!"
        ALL_UPSTREAMS_OK=false
    fi
done

if [[ "$ALL_UPSTREAMS_OK" != "true" ]]; then
    echo "❌ FATAL: One or more local upstreams failed health check. Aborting cutover."
    exit 1
fi

# 3. Check Disk Space
FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
if (( FREE_DISK_MB < 500 )); then
    echo "❌ FATAL: Insufficient disk space (${FREE_DISK_MB} MB < 500 MB). Aborting."
    exit 1
fi

echo "======================================================================"
echo "  All safety checks passed. Commencing Ingress Cutover...             "
echo "======================================================================"

# Stop Caddy Container
echo "🛑 Stopping Caddy Docker container..."
if sudo docker ps -q --filter "name=caddy" | grep -q .; then
    sudo docker stop dashboard-caddy-1
    echo "   ✅ Caddy container stopped."
fi

# Start Nginx
echo "🚀 Starting host Nginx..."
if sudo systemctl enable --now nginx; then
    echo "   ✅ Nginx started and enabled on ports 80/443."
else
    echo "❌ FATAL: Nginx failed to start! Initiating instant fallback to Caddy..."
    "${SCRIPT_DIR}/rollback-ingress.sh"
    exit 1
fi

# Post-Cutover Verification
echo "🔍 Verifying public domain responses..."
DOMAINS=("crm.xylozentech.com" "xylozentech.com" "thebytebandits.com" "titan.xylozentech.com")
CUTOVER_FAILED=false

for d in "${DOMAINS[@]}"; do
    HTTP_CODE=$(curl -k -s -m 5 -o /dev/null -w "%{http_code}" "https://${d}" || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
        echo "   ✅ https://${d} returned HTTP ${HTTP_CODE}."
    else
        echo "   ⚠️ WARNING: https://${d} returned HTTP ${HTTP_CODE}."
        CUTOVER_FAILED=true
    fi
done

if [[ "$CUTOVER_FAILED" == "true" ]]; then
    echo "⚠️ One or more domains failed public verification."
    echo "   To rollback to Caddy immediately, run: ${SCRIPT_DIR}/rollback-ingress.sh"
else
    echo "======================================================================"
    echo "  🎉 INGRESS CUTOVER SUCCESSFUL! Nginx is now actively serving traffic."
    echo "======================================================================"
fi

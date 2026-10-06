#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - Atomic Release Deployment Engine
# Usage: ./deploy.sh <project_name> <artifact_tarball_path> [--dry-run]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/projects.yml"

PROJECT_NAME="${1:-}"
ARTIFACT_PATH="${2:-}"
DRY_RUN=false

if [[ "${3:-}" == "--dry-run" || "${2:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

if [[ -z "$PROJECT_NAME" || -z "$ARTIFACT_PATH" ]]; then
    echo "❌ Usage: $0 <project_name> <artifact_tarball_path> [--dry-run]"
    exit 1
fi

LOG_DIR="/var/log/deployments/${PROJECT_NAME}"
LOCK_DIR="/var/lock/deployments"
mkdir -p "$LOG_DIR" "$LOCK_DIR"

LOCK_FILE="${LOCK_DIR}/${PROJECT_NAME}.lock"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEPLOY_LOG="${LOG_DIR}/${TIMESTAMP}.log"

exec > >(tee -a "$DEPLOY_LOG") 2>&1

echo "======================================================================"
echo "  Deploying: ${PROJECT_NAME} | Release ID: ${TIMESTAMP}               "
echo "  Time: $(date)                                                       "
echo "======================================================================"

# 1. Acquire Deployment Lock (prevents concurrent deploys of the SAME project)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "❌ ERROR: Deployment already in progress for project '${PROJECT_NAME}'."
    echo "   Lock file active: $LOCK_FILE"
    exit 1
fi

# 2. Check Disk Space Safety Thresholds
FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
echo "📊 Current free disk space: ${FREE_DISK_MB} MB"

if (( FREE_DISK_MB < 500 )); then
    echo "❌ FATAL: Available disk space (${FREE_DISK_MB} MB) is below the 500 MB block threshold!"
    echo "   Deployment aborted to protect existing running applications."
    exit 1
elif (( FREE_DISK_MB < 1000 )); then
    echo "⚠️  WARNING: Available disk space is low (${FREE_DISK_MB} MB < 1000 MB). Proceeding cautiously."
fi

# 3. Validate Artifact
if [[ ! -f "$ARTIFACT_PATH" ]]; then
    echo "❌ ERROR: Artifact archive not found at: $ARTIFACT_PATH"
    exit 1
fi

if ! tar -tzf "$ARTIFACT_PATH" >/dev/null 2>&1; then
    echo "❌ ERROR: Corrupted artifact tarball: $ARTIFACT_PATH"
    exit 1
fi
echo "✅ Artifact archive validated."

if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔍 [DRY-RUN] Would deploy $PROJECT_NAME with release ID $TIMESTAMP."
    echo "   Would extract to /var/www/${PROJECT_NAME}/releases/${TIMESTAMP}"
    echo "   Would switch symlink and reload process."
    exit 0
fi

# 4. Setup Project Directory Structure
BASE_DIR="/var/www/${PROJECT_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
NEW_RELEASE_DIR="${RELEASES_DIR}/${TIMESTAMP}"
CURRENT_LINK="${BASE_DIR}/current"

mkdir -p "$RELEASES_DIR" "$SHARED_DIR"

# Record previous release target for safe rollback
PREVIOUS_RELEASE=""
if [[ -L "$CURRENT_LINK" ]]; then
    PREVIOUS_RELEASE="$(readlink "$CURRENT_LINK")"
    echo "ℹ️  Current active release: $PREVIOUS_RELEASE"
fi

# 5. Extract Artifact into Release Directory
echo "📦 Extracting release artifact into: $NEW_RELEASE_DIR"
mkdir -p "$NEW_RELEASE_DIR"
tar -xzf "$ARTIFACT_PATH" -C "$NEW_RELEASE_DIR"

# 6. Attach Shared Persistent Data & Secrets
echo "🔗 Attaching shared configurations and persistent assets..."

# Shared .env
if [[ ! -f "${SHARED_DIR}/.env" ]]; then
    echo "ℹ️  Creating initial ${SHARED_DIR}/.env placeholder"
    touch "${SHARED_DIR}/.env"
    chmod 600 "${SHARED_DIR}/.env"
fi
ln -sfn "${SHARED_DIR}/.env" "${NEW_RELEASE_DIR}/.env"

# Shared persistent directories & files defined in config
PROJECT_TYPE=$(node - "$CONFIG_FILE" "$PROJECT_NAME" << 'EOF'
const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
const target = process.argv[3];
const regex = new RegExp(`  ${target}:[\\s\\S]*?(?=\\n  [a-zA-Z0-9_-]+:|$)`);
const match = content.match(regex);
if (!match) process.exit(1);
const typeMatch = match[0].match(/type:\s*["']?([^"'\s]+)/);
console.log(typeMatch ? typeMatch[1] : 'node');
EOF
)

# For Titan SQLite safety:
if [[ "$PROJECT_NAME" == "titan" ]]; then
    mkdir -p "${SHARED_DIR}/data" "${SHARED_DIR}/uploads" "${SHARED_DIR}/logs"
    for db_file in database.db database.db-wal database.db-shm; do
        if [[ -f "${SHARED_DIR}/data/${db_file}" ]]; then
            ln -sfn "${SHARED_DIR}/data/${db_file}" "${NEW_RELEASE_DIR}/${db_file}"
        fi
    done
    ln -sfn "${SHARED_DIR}/uploads" "${NEW_RELEASE_DIR}/uploads"
    ln -sfn "${SHARED_DIR}/logs" "${NEW_RELEASE_DIR}/logs"
fi

# For CRM persistent uploads:
if [[ "$PROJECT_NAME" == *"backend"* ]]; then
    mkdir -p "${SHARED_DIR}/uploads"
    ln -sfn "${SHARED_DIR}/uploads" "${NEW_RELEASE_DIR}/uploads"
fi

# 7. Atomic Symlink Switch
echo "🔄 Atomically switching 'current' pointer to release ${TIMESTAMP}..."
ln -sfn "releases/${TIMESTAMP}" "${BASE_DIR}/current_tmp"
mv -Tf "${BASE_DIR}/current_tmp" "$CURRENT_LINK"

# 8. Process Startup & Health Check (for runtime services)
if [[ "$PROJECT_TYPE" != "static-spa" ]]; then
    echo "🚀 Updating PM2 ecosystem and reloading process '${PROJECT_NAME}'..."
    "${SCRIPT_DIR}/generate-pm2.sh" "$PROJECT_NAME"
    
    # Isolated process start or reload
    pm2 startOrReload "${BASE_DIR}/ecosystem.config.cjs" --only "$PROJECT_NAME"

    echo "🔍 Executing automated health check verification..."
    if ! "${SCRIPT_DIR}/health-check.sh" "$PROJECT_NAME"; then
        echo "❌ HEALTH CHECK FAILED! Initiating immediate automatic rollback..."
        
        if [[ -n "$PREVIOUS_RELEASE" ]]; then
            echo "⏪ Rolling back symlink to: $PREVIOUS_RELEASE"
            ln -sfn "$PREVIOUS_RELEASE" "${BASE_DIR}/current_tmp"
            mv -Tf "${BASE_DIR}/current_tmp" "$CURRENT_LINK"
            pm2 reload "$PROJECT_NAME" || true
            echo "✅ Recovered to previous stable release."
        else
            echo "⚠️ No previous release available to rollback to."
            pm2 stop "$PROJECT_NAME" || true
        fi

        # Quarantine failed release
        mv "$NEW_RELEASE_DIR" "${NEW_RELEASE_DIR}.failed"
        echo "❌ Deployment FAILED. Quarantine placed at: ${NEW_RELEASE_DIR}.failed"
        exit 1
    fi
fi

# 9. Update Nginx Configuration if Nginx is active
if [[ -f "/etc/nginx/conf.d" || -d "/etc/nginx/conf.d" ]]; then
    "${SCRIPT_DIR}/generate-nginx.sh" "$PROJECT_NAME" || true
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo "🔄 Reloading Nginx configuration..."
        sudo systemctl reload nginx
    fi
fi

# 10. Automated Release Pruning
echo "🧹 Pruning old releases (keeping latest 3)..."
"${SCRIPT_DIR}/cleanup.sh" "$PROJECT_NAME"

echo "======================================================================"
echo "  ✅ DEPLOYMENT SUCCESSFUL: ${PROJECT_NAME} (Release: ${TIMESTAMP})    "
echo "======================================================================"
exit 0

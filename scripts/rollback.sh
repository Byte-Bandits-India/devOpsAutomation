#!/usr/bin/env bash
# ==============================================================================
# rollback.sh - Manual & Automated Rollback Handler
# Usage: ./rollback.sh <project_name> [release_timestamp]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PROJECT_NAME="${1:-}"
TARGET_RELEASE="${2:-}"

if [[ -z "$PROJECT_NAME" ]]; then
    echo "❌ Usage: $0 <project_name> [release_timestamp]"
    exit 1
fi

BASE_DIR="/var/www/${PROJECT_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_LINK="${BASE_DIR}/current"

if [[ ! -d "$RELEASES_DIR" || ! -L "$CURRENT_LINK" ]]; then
    echo "❌ ERROR: No active release or deployment found for '${PROJECT_NAME}'."
    exit 1
fi

ACTIVE_RELEASE=$(basename "$(readlink "$CURRENT_LINK")")
echo "ℹ️  Current active release for '${PROJECT_NAME}': ${ACTIVE_RELEASE}"

# If no target specified, pick the immediate predecessor
if [[ -z "$TARGET_RELEASE" ]]; then
    AVAILABLE_RELEASES=$(ls -1td "${RELEASES_DIR}"/2* 2>/dev/null | xargs -n 1 basename || true)
    
    TARGET_RELEASE=$(echo "$AVAILABLE_RELEASES" | grep -v "^${ACTIVE_RELEASE}$" | head -n 1 || true)
    
    if [[ -z "$TARGET_RELEASE" ]]; then
        echo "❌ ERROR: No previous release found to roll back to!"
        exit 1
    fi
fi

TARGET_DIR="${RELEASES_DIR}/${TARGET_RELEASE}"
if [[ ! -d "$TARGET_DIR" ]]; then
    echo "❌ ERROR: Target rollback release directory does not exist: $TARGET_DIR"
    exit 1
fi

echo "⏪ Rolling back '${PROJECT_NAME}' to release: ${TARGET_RELEASE}..."

# Atomic Symlink Switch
ln -sfn "releases/${TARGET_RELEASE}" "${BASE_DIR}/current_tmp"
mv -Tf "${BASE_DIR}/current_tmp" "$CURRENT_LINK"

# Reload PM2 Process if managed by PM2
if [[ -f "${BASE_DIR}/ecosystem.config.cjs" ]]; then
    echo "🔄 Reloading PM2 process '${PROJECT_NAME}'..."
    pm2 reload "$PROJECT_NAME" || pm2 start "${BASE_DIR}/ecosystem.config.cjs" --only "$PROJECT_NAME"
fi

# Verify Health
echo "🔍 Verifying application health post-rollback..."
if "${SCRIPT_DIR}/health-check.sh" "$PROJECT_NAME"; then
    echo "✅ ROLLBACK SUCCESSFUL: '${PROJECT_NAME}' is now serving release ${TARGET_RELEASE}."
    exit 0
else
    echo "❌ WARNING: Rollback succeeded in switching symlink, but health check failed!"
    exit 1
fi

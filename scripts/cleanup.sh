#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Release Pruning Engine
# Usage: ./cleanup.sh <project_name>
# Keeps latest 3 releases. NEVER deletes current active or immediate predecessor.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="${1:-}"

if [[ -z "$PROJECT_NAME" ]]; then
    echo "❌ Usage: $0 <project_name>"
    exit 1
fi

BASE_DIR="/var/www/${PROJECT_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_LINK="${BASE_DIR}/current"

if [[ ! -d "$RELEASES_DIR" ]]; then
    exit 0
fi

ACTIVE_RELEASE=""
if [[ -L "$CURRENT_LINK" ]]; then
    ACTIVE_RELEASE=$(basename "$(readlink "$CURRENT_LINK")")
fi

KEEP_COUNT=3

# Collect all timestamp release directories sorted newest first
ALL_RELEASES=($(ls -1td "${RELEASES_DIR}"/2* 2>/dev/null | xargs -n 1 basename || true))
TOTAL=${#ALL_RELEASES[@]}

if (( TOTAL <= KEEP_COUNT )); then
    echo "ℹ️  Found ${TOTAL} releases. Within keep limit (${KEEP_COUNT}). No cleanup needed."
    exit 0
fi

echo "🧹 Found ${TOTAL} releases for '${PROJECT_NAME}'. Pruning older releases beyond latest ${KEEP_COUNT}..."

for (( i=KEEP_COUNT; i<TOTAL; i++ )); do
    REL="${ALL_RELEASES[$i]}"
    REL_PATH="${RELEASES_DIR}/${REL}"

    # NEVER delete the active release
    if [[ "$REL" == "$ACTIVE_RELEASE" ]]; then
        echo "   ⚠️ Skipping active release: $REL"
        continue
    fi

    echo "   🗑️ Removing old release: ${REL}"
    rm -rf "$REL_PATH"
done

echo "✅ Release cleanup completed."

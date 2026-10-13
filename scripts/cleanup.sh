#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Release Pruning & Emergency Disk Reclamation Engine
# Usage: 
#   ./cleanup.sh <project_name> [keep_count]
#   ./cleanup.sh --system
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
CUSTOM_KEEP="${2:-}"

function prune_project() {
    local proj="$1"
    local keep="${2:-3}"
    local base_dir="/var/www/${proj}"
    local releases_dir="${base_dir}/releases"
    local current_link="${base_dir}/current"

    if [[ ! -d "$releases_dir" ]]; then
        return 0
    fi

    local active_release=""
    if [[ -L "$current_link" ]]; then
        active_release=$(basename "$(readlink "$current_link")")
    fi

    local all_releases=($(ls -1td "${releases_dir}"/2* 2>/dev/null | xargs -n 1 basename || true))
    local total=${#all_releases[@]}

    if (( total <= keep )); then
        return 0
    fi

    echo "🧹 Pruning older releases for '${proj}' (keeping latest ${keep})..."
    for (( i=keep; i<total; i++ )); do
        local rel="${all_releases[$i]}"
        local rel_path="${releases_dir}/${rel}"

        if [[ "$rel" == "$active_release" ]]; then
            continue
        fi

        echo "   🗑️ Removing old release: ${proj}/releases/${rel}"
        rm -rf "$rel_path"
    done
}

function cleanup_system() {
    echo "======================================================================"
    echo "  🚨 Executing System-Wide Emergency Disk Space Reclamation           "
    echo "======================================================================"

    # 1. Remove stale temporary archives in /tmp
    echo "1. Cleaning temporary deployment archives in /tmp..."
    find /tmp -name "*-deploy.tar.gz" -mmin +15 -delete 2>/dev/null || true
    find /tmp -name "*.tar.gz" -mtime +1 -delete 2>/dev/null || true

    # 2. Remove quarantine failed releases across all projects
    echo "2. Removing failed release quarantines in /var/www..."
    rm -rf /var/www/*/releases/*.failed 2>/dev/null || true

    # 3. Clean package manager caches
    echo "3. Cleaning package manager caches..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf clean all 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        sudo yum clean all 2>/dev/null || true
    fi

    # 4. Vacuum systemd journal logs to 50MB
    echo "4. Vacuuming systemd journal logs to 50MB..."
    if command -v journalctl >/dev/null 2>&1; then
        sudo journalctl --vacuum-size=50M 2>/dev/null || true
    fi

    # 5. Prune Docker artifacts if Docker was previously used
    echo "5. Checking Docker disk usage..."
    if command -v docker >/dev/null 2>&1; then
        sudo docker system prune -af --volumes 2>/dev/null || true
    fi

    # 6. Truncate oversized logs (>10MB) in /var/log/deployments
    echo "6. Truncating oversized deployment logs..."
    if [[ -d "/var/log/deployments" ]]; then
        find /var/log/deployments -type f -name "*.log" -size +10M -exec truncate -s 2M {} \; 2>/dev/null || true
    fi

    # 7. Prune old releases across all projects in /var/www (keep 2)
    echo "7. Pruning older releases across all projects in /var/www..."
    for pdir in /var/www/*; do
        if [[ -d "$pdir/releases" ]]; then
            pname=$(basename "$pdir")
            prune_project "$pname" 2
        fi
    done

    local free_mb=$(df -m / | awk 'NR==2 {print $4}')
    echo "✅ System-wide cleanup completed. Current free disk space: ${free_mb} MB"
}

if [[ -z "$TARGET" ]]; then
    echo "❌ Usage: $0 <project_name> [keep_count] OR $0 --system"
    exit 1
fi

if [[ "$TARGET" == "--system" || "$TARGET" == "--all" ]]; then
    cleanup_system
    exit 0
fi

prune_project "$TARGET" "${CUSTOM_KEEP:-3}"
echo "✅ Release cleanup completed."

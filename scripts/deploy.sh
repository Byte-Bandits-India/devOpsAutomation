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
IS_DIRECTORY_ARTIFACT=false
if [[ -d "$ARTIFACT_PATH" ]]; then
    IS_DIRECTORY_ARTIFACT=true
    echo "✅ Artifact directory validated: $ARTIFACT_PATH"
elif [[ -f "$ARTIFACT_PATH" ]]; then
    if ! tar -tzf "$ARTIFACT_PATH" >/dev/null 2>&1; then
        echo "❌ ERROR: Corrupted artifact tarball: $ARTIFACT_PATH"
        exit 1
    fi
    echo "✅ Artifact archive validated."
else
    echo "❌ ERROR: Artifact archive or directory not found at: $ARTIFACT_PATH"
    exit 1
fi

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
if [[ "$IS_DIRECTORY_ARTIFACT" == "true" ]]; then
    # Try hardlink clone first to preserve disk space on low-storage hosts
    cp -al "$ARTIFACT_PATH"/. "$NEW_RELEASE_DIR/" 2>/dev/null || cp -a "$ARTIFACT_PATH"/. "$NEW_RELEASE_DIR/"
else
    tar -xzf "$ARTIFACT_PATH" -C "$NEW_RELEASE_DIR"
fi

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
PROJ_PERSISTENT_JSON=$(node - "$CONFIG_FILE" "$PROJECT_NAME" << 'EOF'
const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
const target = process.argv[3];
const regex = new RegExp(`  ${target}:[\\s\\S]*?(?=\\n  [a-zA-Z0-9_-]+:|$)`);
const match = content.match(regex);
if (!match) process.exit(1);
const block = match[0];
const typeMatch = block.match(/type:\s*["']?([^"'\s]+)/);

// Parse persistent files
const filesSection = block.match(/files:\s*\n((\s+-\s+["']?[^\n"']+["']?\n?)+)/);
let files = [];
if (filesSection) {
  const lines = filesSection[1].split('\n');
  for (let l of lines) {
    const m = l.match(/-\s*["']?([^"'\s]+)/);
    if (m) files.push(m[1]);
  }
}

// Parse persistent directories
const dirsSection = block.match(/directories:\s*\n((\s+-\s+["']?[^\n"']+["']?\n?)+)/);
let dirs = [];
if (dirsSection) {
  const lines = dirsSection[1].split('\n');
  for (let l of lines) {
    const m = l.match(/-\s*["']?([^"'\s]+)/);
    if (m) dirs.push(m[1]);
  }
}

console.log(JSON.stringify({
  type: typeMatch ? typeMatch[1] : 'node',
  migrations: migrationsMatch ? migrationsMatch[1] : 'manual',
  files,
  directories: dirs
}));
EOF
)

PROJECT_TYPE=$(echo "$PROJ_PERSISTENT_JSON" | node -e 'const d=JSON.parse(fs.readFileSync(0)); console.log(d.type);')
DB_MIGRATIONS=$(echo "$PROJ_PERSISTENT_JSON" | node -e 'const d=JSON.parse(fs.readFileSync(0)); console.log(d.migrations || "manual");')

# Link persistent files dynamically (e.g. SQLite database files, certs)
while IFS= read -r file; do
    if [[ -n "$file" ]]; then
        mkdir -p "${SHARED_DIR}/$(dirname "$file")"
        mkdir -p "${NEW_RELEASE_DIR}/$(dirname "$file")"
        if [[ -f "${SHARED_DIR}/${file}" ]]; then
            ln -sfn "${SHARED_DIR}/${file}" "${NEW_RELEASE_DIR}/${file}"
            echo "   🔗 Linked persistent file: ${file} -> shared/${file}"
        fi
    fi
done < <(echo "$PROJ_PERSISTENT_JSON" | node -e 'const d=JSON.parse(fs.readFileSync(0)); d.files.forEach(f => console.log(f));')

# Link persistent directories dynamically (e.g. uploads, logs, public/uploads)
while IFS= read -r dir; do
    if [[ -n "$dir" ]]; then
        mkdir -p "${SHARED_DIR}/${dir}"
        mkdir -p "${NEW_RELEASE_DIR}/$(dirname "$dir")"
        ln -sfn "${SHARED_DIR}/${dir}" "${NEW_RELEASE_DIR}/${dir}"
        echo "   🔗 Linked persistent directory: ${dir} -> shared/${dir}"
    fi
done < <(echo "$PROJ_PERSISTENT_JSON" | node -e 'const d=JSON.parse(fs.readFileSync(0)); d.directories.forEach(dir => console.log(dir));')

# 6.5 Automated Database Migrations (if configured)
if [[ "$DB_MIGRATIONS" == "prisma" || "$DB_MIGRATIONS" == "auto" ]]; then
    if [[ -d "${NEW_RELEASE_DIR}/prisma" ]]; then
        echo "🗄️ Executing Prisma migrations (npx prisma migrate deploy)..."
        if ! (cd "$NEW_RELEASE_DIR" && npx prisma migrate deploy); then
            echo "❌ ERROR: Database migration failed! Aborting deployment."
            exit 1
        fi
        echo "✅ Database migrations applied successfully."
    fi
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

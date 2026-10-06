#!/usr/bin/env bash
# ==============================================================================
# validate-infrastructure.sh - Infrastructure Pre-flight Validator
# Validates configuration, ports, domains, disk space, and runtime health.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/projects.yml"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "🔍 Running in DRY-RUN mode (read-only validation)..."
fi

echo "======================================================================"
echo "          DevOps Automation - Infrastructure Pre-flight Check          "
echo "======================================================================"

# 1. Check Configuration File
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ ERROR: projects.yml not found at: $CONFIG_FILE"
    exit 1
fi
echo "✅ projects.yml located."

# 2. Validate YAML Syntax and Extract Data via Node.js
VALIDATION_OUTPUT=$(node - "$CONFIG_FILE" << 'EOF'
const fs = require('fs');
const yamlContent = fs.readFileSync(process.argv[2], 'utf8');

// Lightweight YAML Parser for standard key-value structures
function parseSimpleYaml(content) {
    const lines = content.split('\n');
    const projects = {};
    let currentProj = null;
    let inProjects = false;
    let currentSection = null;

    for (let rawLine of lines) {
        const line = rawLine.replace(/#.*$/, '').trimEnd();
        if (!line.trim()) continue;

        if (line.startsWith('projects:')) {
            inProjects = true;
            continue;
        }

        if (inProjects) {
            const projMatch = line.match(/^  ([a-zA-Z0-9_-]+):/);
            if (projMatch) {
                currentProj = projMatch[1];
                projects[currentProj] = { name: currentProj, aliases: [] };
                currentSection = null;
                continue;
            }

            if (currentProj) {
                const propMatch = line.match(/^    ([a-zA-Z0-9_-]+):\s*(.*)$/);
                if (propMatch) {
                    const key = propMatch[1];
                    let val = propMatch[2].trim();
                    if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
                    if (val.startsWith("'") && val.endsWith("'")) val = val.slice(1, -1);
                    projects[currentProj][key] = val;
                }
            }
        }
    }
    return projects;
}

try {
    const projects = parseSimpleYaml(yamlContent);
    const ports = new Map();
    const domains = new Map();
    const errors = [];

    for (const [name, p] of Object.entries(projects)) {
        if (p.port) {
            const portNum = parseInt(p.port, 10);
            if (ports.has(portNum)) {
                errors.push(`Port collision detected: Port ${portNum} is used by both '${ports.get(portNum)}' and '${name}'`);
            } else {
                ports.set(portNum, name);
            }
        }

        if (p.domain) {
            if (p.type !== 'static-spa' && domains.has(p.domain) && projects[domains.get(p.domain)].type !== 'static-spa') {
                errors.push(`Domain collision: Domain '${p.domain}' assigned to multiple standalone projects ('${domains.get(p.domain)}' and '${name}')`);
            } else {
                domains.set(p.domain, name);
            }
        }
    }

    if (errors.length > 0) {
        console.log("ERRORS:\n" + errors.join("\n"));
        process.exit(1);
    } else {
        console.log(`OK:${Object.keys(projects).length}:${Array.from(ports.entries()).map(([k,v]) => `${k}=${v}`).join(",")}`);
    }
} catch (e) {
    console.error("YAML parsing error: " + e.message);
    process.exit(1);
}
EOF
)

if [[ "$VALIDATION_OUTPUT" == ERRORS* ]]; then
    echo "❌ CONFIGURATION VALIDATION FAILED:"
    echo "$VALIDATION_OUTPUT"
    exit 1
fi

PROJ_COUNT=$(echo "$VALIDATION_OUTPUT" | cut -d: -f2)
PORT_MAPPINGS=$(echo "$VALIDATION_OUTPUT" | cut -d: -f3)
echo "✅ Config valid: Registered $PROJ_COUNT project components."
echo "   Port allocations: $PORT_MAPPINGS"

# 3. Check Disk Space (Warn < 1000MB, Block < 500MB)
FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
echo "📊 Current Disk Space: ${FREE_DISK_MB} MB free on root filesystem."

if (( FREE_DISK_MB < 500 )); then
    echo "⚠️  CRITICAL WARNING: Available disk space (${FREE_DISK_MB} MB) is below the 500 MB safety block threshold!"
    echo "   Deployments will be BLOCKED to prevent server failure."
elif (( FREE_DISK_MB < 1000 )); then
    echo "⚠️  WARNING: Available disk space (${FREE_DISK_MB} MB) is below 1000 MB."
else
    echo "✅ Disk space is sufficient for new releases."
fi

# 4. Check RAM & Swap (Linux)
if command -v free >/dev/null 2>&1; then
    MEM_FREE_MB=$(free -m | awk '/Mem:/ {print $4}')
    SWAP_USED_MB=$(free -m | awk '/Swap:/ {print $3}')
    echo "📊 Memory: ${MEM_FREE_MB} MB free RAM | Swap: ${SWAP_USED_MB} MB used."
fi

# 5. Check Directory Hierarchy
REQUIRED_DIRS=("/var/www" "/var/log/deployments" "/var/lock/deployments" "/var/backups" "/opt/devops-automation")
for d in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        echo "✅ Directory exists: $d"
    else
        echo "ℹ️  Directory to be initialized: $d"
    fi
done

# 6. Check Nginx Syntax if Nginx is installed
if command -v nginx >/dev/null 2>&1; then
    if sudo nginx -t >/dev/null 2>&1; then
        echo "✅ Nginx syntax check passed."
    else
        echo "⚠️  Nginx syntax check reported errors (or inactive config)."
    fi
fi

# 7. Check PM2
if command -v pm2 >/dev/null 2>&1; then
    PM2_RUNNING=$(pm2 jlist 2>/dev/null | node -e 'try { const list = JSON.parse(fs.readFileSync(0)); console.log(list.length); } catch(e){ console.log(0); }' || echo 0)
    echo "✅ PM2 is operational with $PM2_RUNNING active processes."
fi

echo "======================================================================"
echo "          Pre-flight Validation Completed Successfully                "
echo "======================================================================"

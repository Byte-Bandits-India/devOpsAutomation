#!/usr/bin/env bash
# ==============================================================================
# status.sh - System Observability Dashboard
# Usage: ./status.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/projects.yml"

echo "======================================================================================================"
echo "                     AWS EC2 Multi-Project Deployment Platform - Status                              "
echo "======================================================================================================"

# Server Resource Overview
FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
TOTAL_DISK_MB=$(df -m / | awk 'NR==2 {print $2}')
USED_DISK_PCT=$(df -h / | awk 'NR==2 {print $5}')
MEM_USED_MB=$(free -m | awk '/Mem:/ {print $3}')
MEM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
SWAP_USED_MB=$(free -m | awk '/Swap:/ {print $3}')

echo "💻 Resources: Disk: ${FREE_DISK_MB} MB free / ${TOTAL_DISK_MB} MB total (${USED_DISK_PCT} used)"
echo "             RAM: ${MEM_USED_MB} MB used / ${MEM_TOTAL_MB} MB total | Swap: ${SWAP_USED_MB} MB used"
echo "------------------------------------------------------------------------------------------------------"

printf "%-25s %-12s %-6s %-10s %-15s %-25s\n" "PROJECT" "TYPE" "PORT" "PM2 STATUS" "ACTIVE RELEASE" "DOMAIN"
echo "------------------------------------------------------------------------------------------------------"

# Extract projects using Node.js
node - "$CONFIG_FILE" << 'EOF'
const fs = require('fs');
const { execSync } = require('child_process');
const content = fs.readFileSync(process.argv[2], 'utf8');

// Parse projects from YAML
const projects = [];
const lines = content.split('\n');
let inProjects = false;
let current = null;

for (let rawLine of lines) {
    const line = rawLine.replace(/#.*$/, '').trimEnd();
    if (line.startsWith('projects:')) { inProjects = true; continue; }
    if (!inProjects) continue;

    const m = line.match(/^  ([a-zA-Z0-9_-]+):/);
    if (m) {
        if (current) projects.push(current);
        current = { name: m[1] };
        continue;
    }

    if (current) {
        const prop = line.match(/^    ([a-zA-Z0-9_-]+):\s*(.*)$/);
        if (prop) {
            let val = prop[2].trim().replace(/^["']|["']$/g, '');
            current[prop[1]] = val;
        }
    }
}
if (current) projects.push(current);

// Get PM2 List
let pm2Processes = new Map();
try {
    const pm2Raw = execSync('pm2 jlist 2>/dev/null', { encoding: 'utf8' });
    const list = JSON.parse(pm2Raw);
    for (let p of list) {
        pm2Processes.set(p.name, {
            status: p.pm2_env.status,
            memory: Math.round(p.monit.memory / (1024 * 1024)) + 'MB',
            cpu: p.monit.cpu + '%'
        });
    }
} catch(e) {}

for (let p of projects) {
    let release = 'N/A';
    try {
        const currentLink = `/var/www/${p.name}/current`;
        if (fs.existsSync(currentLink)) {
            const target = fs.readlinkSync(currentLink);
            release = target.split('/').pop();
        }
    } catch(e) {}

    let pm2Status = 'STATIC';
    if (p.type !== 'static-spa' && p.type !== 'php-fpm') {
        if (pm2Processes.has(p.name)) {
            const proc = pm2Processes.get(p.name);
            pm2Status = `${proc.status} (${proc.memory})`;
        } else {
            pm2Status = 'STOPPED';
        }
    }

    const name = (p.name || '').padEnd(25);
    const type = (p.type || '').padEnd(12);
    const port = (p.port || '-').padEnd(6);
    const pm2 = pm2Status.padEnd(10);
    const rel = release.padEnd(15);
    const domain = (p.domain || '').padEnd(25);

    console.log(`${name} ${type} ${port} ${pm2} ${rel} ${domain}`);
}
EOF

echo "======================================================================================================"

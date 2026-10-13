#!/usr/bin/env bash
# ==============================================================================
# onboard-project.sh - Automated Onboarding Engine for New Projects
# Usage: ./onboard-project.sh <project_name> [--issue-ssl]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/projects.yml"

PROJECT_NAME="${1:-}"
ISSUE_SSL=false
if [[ "${2:-}" == "--issue-ssl" ]]; then
    ISSUE_SSL=true
fi

if [[ -z "$PROJECT_NAME" ]]; then
    echo "❌ Usage: $0 <project_name> [--issue-ssl]"
    exit 1
fi

echo "======================================================================"
echo "  🚀 Onboarding Project: ${PROJECT_NAME}                              "
echo "  Time: $(date)                                                       "
echo "======================================================================"

# 1. Parse Project Configuration from projects.yml
PROJ_DATA=$(node - "$CONFIG_FILE" "$PROJECT_NAME" << 'EOF'
const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
const target = process.argv[3];

const regex = new RegExp(`  ${target}:[\\s\\S]*?(?=\\n  [a-zA-Z0-9_-]+:|$)`);
const match = content.match(regex);

if (!match) {
    console.error(`ERROR: Project '${target}' not found in ${process.argv[2]}`);
    process.exit(1);
}

const block = match[0];
const typeMatch = block.match(/type:\s*["']?([^"'\s]+)/);
const domainMatch = block.match(/domain:\s*["']?([^"'\s]+)/);
const portMatch = block.match(/port:\s*(\d+)/);
const bindMatch = block.match(/bind_ip:\s*["']?([^"'\s]+)/);

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

// Parse aliases
const aliasSection = block.match(/aliases:\s*\n((\s+-\s+["']?[^\n"']+["']?\n?)+)/);
let aliases = [];
if (aliasSection) {
  const lines = aliasSection[1].split('\n');
  for (let l of lines) {
    const m = l.match(/-\s*["']?([^"'\s]+)/);
    if (m) aliases.push(m[1]);
  }
}

console.log(JSON.stringify({
    type: typeMatch ? typeMatch[1] : 'node',
    domain: domainMatch ? domainMatch[1] : null,
    port: portMatch ? parseInt(portMatch[1]) : null,
    bind_ip: bindMatch ? bindMatch[1] : '127.0.0.1',
    aliases: aliases,
    directories: dirs
}));
EOF
)

TYPE=$(echo "$PROJ_DATA" | node -e 'const d=JSON.parse(fs.readFileSync(0)); console.log(d.type);')
DOMAIN=$(echo "$PROJ_DATA" | node -e 'const d=JSON.parse(fs.readFileSync(0)); console.log(d.domain || "");')
PORT=$(echo "$PROJ_DATA" | node -e 'const d=JSON.parse(fs.readFileSync(0)); console.log(d.port || "");')

echo "📋 Configuration detected:"
echo "   Type:   $TYPE"
echo "   Domain: $DOMAIN"
echo "   Port:   ${PORT:-N/A}"

# 2. Check Port Collision Across All Projects
if [[ -n "$PORT" ]]; then
    node - "$CONFIG_FILE" "$PROJECT_NAME" "$PORT" << 'EOF'
const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
const targetProj = process.argv[3];
const targetPort = process.argv[4];

const lines = content.split('\n');
let currentProj = null;
for (let line of lines) {
    const pMatch = line.match(/^  ([a-zA-Z0-9_-]+):/);
    if (pMatch) currentProj = pMatch[1];
    
    const portMatch = line.match(/port:\s*(\d+)/);
    if (portMatch && currentProj && currentProj !== targetProj) {
        if (portMatch[1] === targetPort) {
            console.error(`❌ PORT COLLISION: Port ${targetPort} is already assigned to project '${currentProj}'!`);
            process.exit(1);
        }
    }
}
console.log(`✅ Port ${targetPort} is unique and available.`);
EOF
fi

# 3. Setup Filesystem Hierarchy
BASE_DIR="/var/www/${PROJECT_NAME}"
SHARED_DIR="${BASE_DIR}/shared"
RELEASES_DIR="${BASE_DIR}/releases"

echo "📁 Initializing project directories at ${BASE_DIR}..."
mkdir -p "$RELEASES_DIR" "$SHARED_DIR"

if [[ ! -f "${SHARED_DIR}/.env" ]]; then
    echo "🔑 Initializing ${SHARED_DIR}/.env (chmod 600)..."
    touch "${SHARED_DIR}/.env"
    chmod 600 "${SHARED_DIR}/.env"
fi

# Create configured persistent directories
while IFS= read -r dir; do
    if [[ -n "$dir" ]]; then
        echo "📂 Ensuring shared persistent directory: ${SHARED_DIR}/${dir}"
        mkdir -p "${SHARED_DIR}/${dir}"
    fi
done < <(echo "$PROJ_DATA" | node -e 'const d=JSON.parse(fs.readFileSync(0)); d.directories.forEach(dir => console.log(dir));')

# 4. Generate PM2 Ecosystem Manifest if runtime process
if [[ "$TYPE" != "static-spa" && "$TYPE" != "php-fpm" ]]; then
    echo "⚙️ Generating isolated PM2 ecosystem config..."
    "${SCRIPT_DIR}/generate-pm2.sh" "$PROJECT_NAME"
fi

# 5. Generate Nginx Virtual Host & SSL Bootstrap
if [[ -n "$DOMAIN" ]]; then
    echo "🌐 Generating isolated Nginx virtual host configuration..."
    "${SCRIPT_DIR}/generate-nginx.sh" "$PROJECT_NAME"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo "🔄 Reloading Nginx..."
        sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
    fi

    # Optional automated Certbot SSL issuance
    if [[ "$ISSUE_SSL" == "true" ]]; then
        if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
            echo "🔒 Requesting Let's Encrypt SSL certificate for ${DOMAIN}..."
            mkdir -p /var/www/certbot
            
            CERT_DOMAINS="-d ${DOMAIN}"
            while IFS= read -r alias; do
                if [[ -n "$alias" ]]; then
                    CERT_DOMAINS="${CERT_DOMAINS} -d ${alias}"
                fi
            done < <(echo "$PROJ_DATA" | node -e 'const d=JSON.parse(fs.readFileSync(0)); d.aliases.forEach(a => console.log(a));')

            if sudo certbot certonly --webroot -w /var/www/certbot $CERT_DOMAINS --non-interactive --agree-tos --register-unsafely-without-email; then
                echo "✅ Let's Encrypt certificate obtained successfully!"
                echo "🔄 Regenerating Nginx virtual host with production certificates..."
                "${SCRIPT_DIR}/generate-nginx.sh" "$PROJECT_NAME"
                sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
            else
                echo "⚠️  Certbot challenge did not complete. Please verify DNS A record for ${DOMAIN} points to this server."
                echo "   Fallback bootstrap certificate remains active in the interim."
            fi
        else
            echo "✅ Let's Encrypt certificate already present for ${DOMAIN}."
        fi
    fi
fi

echo "======================================================================"
echo "  ✅ ONBOARDING COMPLETE: ${PROJECT_NAME}                              "
echo "======================================================================"
echo ""
echo "Next Steps:"
echo "1. Put production environment variables into: ${SHARED_DIR}/.env"
echo "2. Add the deployment workflow to your repository (.github/workflows/deploy.yml)"
echo "   See templates in: /opt/devops-automation/examples/"
echo "3. Trigger a push to deploy!"
echo ""

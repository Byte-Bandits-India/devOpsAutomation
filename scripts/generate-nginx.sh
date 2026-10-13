#!/usr/bin/env bash
# ==============================================================================
# generate-nginx.sh - Idempotent Isolated Nginx Configuration Generator
# Usage: ./generate-nginx.sh <project_name>
# Generates /etc/nginx/conf.d/<domain>.conf safely with pre-validation
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/projects.yml"
TEMPLATES_DIR="${ROOT_DIR}/templates/nginx"
NGINX_CONF_DIR="/etc/nginx/conf.d"

PROJECT_NAME="${1:-}"

if [[ -z "$PROJECT_NAME" ]]; then
    echo "❌ Usage: $0 <project_name>"
    exit 1
fi

# Detect project settings using Node.js
PROJ_INFO=$(node - "$CONFIG_FILE" "$PROJECT_NAME" << 'EOF'
const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
const target = process.argv[3];

const regex = new RegExp(`  ${target}:[\\s\\S]*?(?=\\n  [a-zA-Z0-9_-]+:|$)`);
const match = content.match(regex);

if (!match) {
    console.error(`Project ${target} not found`);
    process.exit(1);
}

const block = match[0];
const typeMatch = block.match(/type:\s*["']?([^"'\s]+)/);
const domainMatch = block.match(/domain:\s*["']?([^"'\s]+)/);
const portMatch = block.match(/port:\s*(\d+)/);
const bindMatch = block.match(/bind_ip:\s*["']?([^"'\s]+)/);

// Extract aliases
const aliasSection = block.match(/aliases:\s*\n((\s+-\s+[\x22\x27]?[^\n\x22\x27]+[\x22\x27]?\n?)+)/);
let aliases = [];
if (aliasSection) {
    const aliasLines = aliasSection[1].split('\n');
    for (let l of aliasLines) {
        const m = l.match(/-\s*["']?([^"'\s]+)/);
        if (m) aliases.push(m[1]);
    }
}

const type = typeMatch ? typeMatch[1] : 'node';
const domain = domainMatch ? domainMatch[1] : 'localhost';
const port = portMatch ? portMatch[1] : '3000';
const bind_ip = bindMatch ? bindMatch[1] : '127.0.0.1';

console.log(`${type}|${domain}|${aliases.join(' ')}|${port}|${bind_ip}`);
EOF
)

IFS='|' read -r TYPE DOMAIN ALIASES PORT BIND_IP <<< "$PROJ_INFO"

# Determine target certificate files (Certbot standard vs Host PKI vs Bootstrap self-signed)
LE_CERT=""
LE_KEY=""
if sudo test -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"; then
    LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
elif sudo test -f "/etc/letsencrypt/live/${DOMAIN}-0001/fullchain.pem"; then
    LE_CERT="/etc/letsencrypt/live/${DOMAIN}-0001/fullchain.pem"
    LE_KEY="/etc/letsencrypt/live/${DOMAIN}-0001/privkey.pem"
else
    MATCHING_LINEAGE=$(sudo find /etc/letsencrypt/live -maxdepth 1 -name "*${DOMAIN}*" -type d 2>/dev/null | head -n 1 || true)
    if [[ -n "$MATCHING_LINEAGE" ]] && sudo test -f "${MATCHING_LINEAGE}/fullchain.pem"; then
        LE_CERT="${MATCHING_LINEAGE}/fullchain.pem"
        LE_KEY="${MATCHING_LINEAGE}/privkey.pem"
    fi
fi

if [[ -z "$LE_CERT" ]] && command -v certbot >/dev/null 2>&1; then
    echo "🔒 Requesting Let's Encrypt SSL certificate for ${DOMAIN}..."
    sudo mkdir -p /var/www/certbot
    CERT_ARGS="-d ${DOMAIN}"
    for al in $ALIASES; do
        if [[ -n "$al" ]]; then
            CERT_ARGS="${CERT_ARGS} -d ${al}"
        fi
    done
    sudo certbot certonly --webroot -w /var/www/certbot $CERT_ARGS --non-interactive --agree-tos --register-unsafely-without-email 2>/dev/null || true
    if sudo test -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"; then
        LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    fi
fi

if [[ -n "$LE_CERT" ]]; then
    echo "🔒 Using official Let's Encrypt certificate: ${LE_CERT}"
    SSL_CERT="$LE_CERT"
    SSL_KEY="$LE_KEY"
    sudo rm -f "/etc/pki/nginx/certs/${DOMAIN}.crt" "/etc/pki/nginx/certs/${DOMAIN}.key" 2>/dev/null || true
elif sudo test -f "/etc/pki/nginx/certs/${DOMAIN}.crt" && sudo test -f "/etc/pki/nginx/certs/${DOMAIN}.key"; then
    SSL_CERT="/etc/pki/nginx/certs/${DOMAIN}.crt"
    SSL_KEY="/etc/pki/nginx/certs/${DOMAIN}.key"
else
    echo "⚠️  No SSL certificate found for ${DOMAIN}. Generating temporary bootstrap certificate..."
    sudo mkdir -p /etc/pki/nginx/certs
    SSL_CERT="/etc/pki/nginx/certs/${DOMAIN}.crt"
    SSL_KEY="/etc/pki/nginx/certs/${DOMAIN}.key"
    sudo openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -subj "/CN=${DOMAIN}" >/dev/null 2>&1 || true
fi

# Temporary candidate file for validation
TMP_CONF="/tmp/${DOMAIN}.candidate.conf"
FINAL_CONF="${NGINX_CONF_DIR}/${DOMAIN}.conf"

# Generate based on domain & architecture type
if [[ "$DOMAIN" == "crm.xylozentech.com" || "$DOMAIN" == "testcrm.xylozentech.com" || "$DOMAIN" == "rimoto.xylozentech.com" ]]; then
    # Hybrid virtual host
    IS_TEST=false
    if [[ "$DOMAIN" == "testcrm.xylozentech.com" ]]; then
        IS_TEST=true
        FRONTEND_ROOT="/var/www/dashboard-test-frontend/current/dist"
        BACKEND_PORT="4002"
        UPLOADS_DIR="/var/www/dashboard-test-backend/shared/uploads"
        ENABLE_PMA=false
    elif [[ "$DOMAIN" == "rimoto.xylozentech.com" ]]; then
        FRONTEND_ROOT="/var/www/rimoto-frontend/current/dist"
        BACKEND_PORT="4003"
        UPLOADS_DIR="/var/www/rimoto-backend/shared/uploads"
        ENABLE_PMA=false
    else
        FRONTEND_ROOT="/var/www/dashboard-prod-frontend/current/dist"
        BACKEND_PORT="4001"
        UPLOADS_DIR="/var/www/dashboard-prod-backend/shared/uploads"
        ENABLE_PMA=true
    fi

    # Render hybrid template
    sed -e "s|{{ DOMAIN }}|${DOMAIN}|g" \
        -e "s|{{ ALIASES }}|${ALIASES}|g" \
        -e "s|{{ SSL_CERT }}|${SSL_CERT}|g" \
        -e "s|{{ SSL_KEY }}|${SSL_KEY}|g" \
        -e "s|{{ FRONTEND_ROOT }}|${FRONTEND_ROOT}|g" \
        -e "s|{{ BIND_IP }}|${BIND_IP}|g" \
        -e "s|{{ BACKEND_PORT }}|${BACKEND_PORT}|g" \
        -e "s|{{ UPLOADS_DIR }}|${UPLOADS_DIR}|g" \
        "${TEMPLATES_DIR}/hybrid-crm.conf.j2" > "$TMP_CONF"

    sed -i 's/{% if ALIASES %}//g' "$TMP_CONF"
    sed -i 's/{% endif %}//g' "$TMP_CONF"

    # Handle Jinja condition for PMA in sed
    if [[ "$ENABLE_PMA" == "false" ]]; then
        sed -i '/{% if ENABLE_PHPMYADMIN %}/,/{% endif %}/d' "$TMP_CONF"
    else
        sed -i 's/{% if ENABLE_PHPMYADMIN %}//g' "$TMP_CONF"
        sed -i 's/{% endif %}//g' "$TMP_CONF"
    fi

elif [[ "$TYPE" == "static-spa" ]]; then
    STATIC_SUBDIR=$(node - "$CONFIG_FILE" "$PROJECT_NAME" << 'EOF'
const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
const target = process.argv[3];
const regex = new RegExp(`  ${target}:[\\s\\S]*?(?=\\n  [a-zA-Z0-9_-]+:|$)`);
const match = content.match(regex);
if (!match) { console.log('dist'); process.exit(0); }
const m = match[0].match(/static_root_subdir:\s*["']?([^"'\s]+)/);
console.log(m ? m[1] : 'dist');
EOF
)
    FRONTEND_ROOT="/var/www/${PROJECT_NAME}/current/${STATIC_SUBDIR}"
    
    # Render static SPA template
    sed -e "s|{{ DOMAIN }}|${DOMAIN}|g" \
        -e "s|{{ ALIASES }}|${ALIASES}|g" \
        -e "s|{{ SSL_CERT }}|${SSL_CERT}|g" \
        -e "s|{{ SSL_KEY }}|${SSL_KEY}|g" \
        -e "s|{{ FRONTEND_ROOT }}|${FRONTEND_ROOT}|g" \
        "${TEMPLATES_DIR}/static-spa.conf.j2" > "$TMP_CONF"

    sed -i 's/{% if ALIASES %}//g' "$TMP_CONF"
    sed -i 's/{% endif %}//g' "$TMP_CONF"

else
    # Standard reverse proxy virtual host (Xylozen, ByteBandits, Titan)
    sed -e "s|{{ DOMAIN }}|${DOMAIN}|g" \
        -e "s|{{ ALIASES }}|${ALIASES}|g" \
        -e "s|{{ PROJECT_NAME }}|${PROJECT_NAME}|g" \
        -e "s|{{ SSL_CERT }}|${SSL_CERT}|g" \
        -e "s|{{ SSL_KEY }}|${SSL_KEY}|g" \
        -e "s|{{ BIND_IP }}|${BIND_IP}|g" \
        -e "s|{{ PORT }}|${PORT}|g" \
        "${TEMPLATES_DIR}/reverse-proxy.conf.j2" > "$TMP_CONF"

    sed -i 's/{% if ALIASES %}//g' "$TMP_CONF"
    sed -i 's/{% endif %}//g' "$TMP_CONF"
fi

echo "🔍 Validating candidate Nginx configuration for '${DOMAIN}'..."

# Copy candidate into conf.d with a test suffix for nginx -t check
TEST_CONF="${NGINX_CONF_DIR}/${DOMAIN}.test-syntax.conf"
sudo cp "$TMP_CONF" "$TEST_CONF"

if sudo nginx -t 2>/dev/null; then
    sudo mv "$TEST_CONF" "$FINAL_CONF"
    rm -f "$TMP_CONF"
    echo "✅ Successfully generated and validated: $FINAL_CONF"
else
    sudo rm -f "$TEST_CONF"
    rm -f "$TMP_CONF"
    echo "❌ ERROR: Generated Nginx configuration failed syntax test. Reverted changes."
    exit 1
fi

#!/usr/bin/env bash
# ==============================================================================
# generate-pm2.sh - Generates isolated PM2 ecosystem config for a project
# Usage: ./generate-pm2.sh <project_name>
# Output: /var/www/<project_name>/ecosystem.config.cjs
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/projects.yml"
TEMPLATE_FILE="${ROOT_DIR}/templates/pm2/ecosystem.config.cjs.j2"

PROJECT_NAME="${1:-}"

if [[ -z "$PROJECT_NAME" ]]; then
    echo "❌ Usage: $0 <project_name>"
    exit 1
fi

PROJECT_DIR="/var/www/${PROJECT_NAME}"
TARGET_FILE="${PROJECT_DIR}/ecosystem.config.cjs"

# Extract project configuration parameters using Node.js
PARAMS=$(node - "$CONFIG_FILE" "$PROJECT_NAME" << 'EOF'
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
const envMatch = block.match(/environment:\s*["']?([^"'\s]+)/);
const portMatch = block.match(/port:\s*(\d+)/);
const bindMatch = block.match(/bind_ip:\s*["']?([^"'\s]+)/);
const entryMatch = block.match(/entrypoint:\s*["']?([^"'\s]+)/);
const memMatch = block.match(/memory_max_restart:\s*["']?([^"'\s]+)/);

const type = typeMatch ? typeMatch[1] : 'node';
const env = envMatch ? envMatch[1] : 'production';
const port = portMatch ? portMatch[1] : '3000';
const bind_ip = bindMatch ? bindMatch[1] : '127.0.0.1';
const entrypoint = entryMatch ? entryMatch[1] : 'server.js';
const memory = memMatch ? (memMatch[1] === 'null' ? '' : memMatch[1]) : '';

console.log(`${type}|${env}|${port}|${bind_ip}|${entrypoint}|${memory}`);
EOF
)

IFS='|' read -r TYPE ENV PORT BIND_IP ENTRYPOINT MEMORY_LIMIT <<< "$PARAMS"

if [[ "$TYPE" == "static-spa" || "$TYPE" == "php-fpm" ]]; then
    echo "ℹ️  Project '${PROJECT_NAME}' (type: ${TYPE}) does not require a PM2 ecosystem configuration."
    exit 0
fi

mkdir -p "$PROJECT_DIR"

# Generate ecosystem.config.cjs safely
cat << EOF > "$TARGET_FILE"
// ==============================================================================
// Isolated PM2 Configuration for ${PROJECT_NAME}
// Generated automatically by DevOps Automation Engine
// ==============================================================================
module.exports = {
  apps: [
    {
      name: "${PROJECT_NAME}",
      script: "${ENTRYPOINT}",
      cwd: "/var/www/${PROJECT_NAME}/current",
      instances: 1,
      exec_mode: "fork",
      autorestart: true,
      watch: false,
$([[ -n "$MEMORY_LIMIT" ]] && echo "      max_memory_restart: \"${MEMORY_LIMIT}\",")
      env: {
        NODE_ENV: "${ENV}",
        PORT: "${PORT}",
        HOST: "${BIND_IP}",
        HOSTNAME: "${BIND_IP}"
      },
      error_file: "/var/log/deployments/${PROJECT_NAME}-error.log",
      out_file: "/var/log/deployments/${PROJECT_NAME}-out.log",
      log_date_format: "YYYY-MM-DD HH:mm:ss Z",
      kill_timeout: 5000,
      wait_ready: false
    }
  ]
};
EOF

echo "✅ Generated isolated PM2 ecosystem configuration at: $TARGET_FILE"

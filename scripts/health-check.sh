#!/usr/bin/env bash
# ==============================================================================
# health-check.sh - Non-blocking Health Check Poller
# Usage: ./health-check.sh <project_name>
# Reads target port and health_check path from projects.yml or environment
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/config/projects.yml"

PROJECT_NAME="${1:-}"

if [[ -z "$PROJECT_NAME" ]]; then
    echo "❌ Usage: $0 <project_name>"
    exit 1
fi

# Extract health check parameters for project using Node.js
PARAMS=$(node - "$CONFIG_FILE" "$PROJECT_NAME" << 'EOF'
const fs = require('fs');
const content = fs.readFileSync(process.argv[2], 'utf8');
const target = process.argv[3];

// Parse target project
const regex = new RegExp(`  ${target}:[\\s\\S]*?(?=\\n  [a-zA-Z0-9_-]+:|$)`);
const match = content.match(regex);

if (!match) {
    console.error(`Project ${target} not found in configuration`);
    process.exit(1);
}

const block = match[0];
const portMatch = block.match(/port:\s*(\d+)/);
const bindMatch = block.match(/bind_ip:\s*["']?([^"'\s]+)/);
const pathMatch = block.match(/path:\s*["']?([^"'\s]+)/);
const expectedMatch = block.match(/expected_status:\s*(\d+)/);
const timeoutMatch = block.match(/timeout_seconds:\s*(\d+)/);
const retriesMatch = block.match(/max_retries:\s*(\d+)/);
const delayMatch = block.match(/retry_delay_seconds:\s*(\d+)/);

const port = portMatch ? portMatch[1] : null;
const bind_ip = bindMatch ? bindMatch[1] : '127.0.0.1';
const path = pathMatch ? pathMatch[1] : '/';
const expected = expectedMatch ? expectedMatch[1] : '200';
const timeout = timeoutMatch ? timeoutMatch[1] : '5';
const retries = retriesMatch ? retriesMatch[1] : '5';
const delay = delayMatch ? delayMatch[1] : '3';

if (!port) {
    console.log(`STATIC_SPA`);
} else {
    console.log(`${bind_ip}|${port}|${path}|${expected}|${timeout}|${retries}|${delay}`);
}
EOF
)

if [[ "$PARAMS" == "STATIC_SPA" ]]; then
    echo "ℹ️  Project '${PROJECT_NAME}' is a static SPA. Verifying dist/index.html presence..."
    TARGET_HTML="/var/www/${PROJECT_NAME}/current/dist/index.html"
    if [[ -f "$TARGET_HTML" && -s "$TARGET_HTML" ]]; then
        echo "✅ Static SPA verified: $TARGET_HTML is present and non-empty."
        exit 0
    else
        echo "❌ ERROR: Static index.html not found or empty at $TARGET_HTML"
        exit 1
    fi
fi

IFS='|' read -r BIND_IP PORT HC_PATH EXPECTED TIMEOUT RETRIES DELAY <<< "$PARAMS"

URL="http://${BIND_IP}:${PORT}${HC_PATH}"
echo "🔍 Health checking '${PROJECT_NAME}' at ${URL} (Expecting HTTP ${EXPECTED})..."

SUCCESS=false
for (( i=1; i<=RETRIES; i++ )); do
    echo "   Attempt $i of $RETRIES..."
    HTTP_CODE=$(curl -s -m "$TIMEOUT" -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    
    if [[ "$HTTP_CODE" == "$EXPECTED" ]]; then
        echo "✅ Health check PASSED on attempt $i (HTTP $HTTP_CODE)."
        SUCCESS=true
        break
    else
        echo "   Received HTTP $HTTP_CODE (expected $EXPECTED). Waiting ${DELAY}s..."
        sleep "$DELAY"
    fi
done

if [[ "$SUCCESS" == "true" ]]; then
    exit 0
else
    echo "❌ Health check FAILED after $RETRIES attempts. Application is unhealthy."
    exit 1
fi

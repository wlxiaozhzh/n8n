#!/usr/bin/env bash
set -euo pipefail

TARGET_URL=${1:-http://localhost:5678/healthz}
CONTAINER_NAME=${CONTAINER_NAME:-n8n-main}

use_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  local status
  if ! status=$(curl -fsS -o /dev/null -w "%{http_code}" "$TARGET_URL"); then
    echo "curl request to ${TARGET_URL} failed." >&2
    return 1
  fi

  if [[ "$status" == "200" ]]; then
    echo "Health check passed (HTTP ${status})"
    return 0
  fi

  echo "Health check returned HTTP ${status}" >&2
  return 1
}

use_container_exec() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker command not found and curl unavailable to check ${TARGET_URL}" >&2
    return 1
  fi

  docker exec "$CONTAINER_NAME" node - <<'EOF'
const http = require('http');

http.get('http://localhost:5678/healthz', res => {
  if (res.statusCode === 200) {
    console.log('Health check passed (HTTP 200)');
    process.exit(0);
  }
  console.error(`Health check returned HTTP ${res.statusCode}`);
  process.exit(1);
}).on('error', err => {
  console.error(`Health check failed: ${err.message}`);
  process.exit(1);
});
EOF
}

if use_curl; then
  exit 0
fi

use_container_exec

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CUSTOM_DIR="${REPO_ROOT}/data/custom"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-n8n-postgres}"
N8N_IMAGE="${N8N_IMAGE:-ghcr.io/n8n-io/n8n:1.116.1}"

if [[ ! -d "${CUSTOM_DIR}" ]]; then
  echo "ERROR: data/custom not found at ${CUSTOM_DIR}" >&2
  exit 1
fi

if [[ ! -f "${CUSTOM_DIR}/package.json" ]]; then
  echo "ERROR: data/custom/package.json is missing." >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

PACKAGE_LIST_JSON="${TMPDIR}/packages.json"

cat > "${TMPDIR}/list-packages.js" <<'NODE'
const fs = require('fs');
const path = require('path');

const customDir = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(path.join(customDir, 'package.json'), 'utf8'));
const deps = Object.keys(manifest.dependencies || {});
process.stdout.write(JSON.stringify(deps));
NODE

docker run --rm \
  --entrypoint node \
  -v "${CUSTOM_DIR}:/workspace/custom:ro" \
  -v "${TMPDIR}/list-packages.js:/tmp/list-packages.js:ro" \
  "${N8N_IMAGE}" \
  /tmp/list-packages.js /workspace/custom > "${PACKAGE_LIST_JSON}"

python3 - <<PY
import json
import pathlib
pkg_list = json.loads(pathlib.Path('${PACKAGE_LIST_JSON}').read_text())
print('\n[ON DISK]\n' + '\n'.join(sorted(pkg_list)))
PY

if docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
  DB_PACKAGES="${TMPDIR}/db-packages.txt"
  docker exec "${POSTGRES_CONTAINER}" psql -U n8n -d n8n -t -A -F',' -c "SELECT \"packageName\" FROM installed_packages ORDER BY 1" > "${DB_PACKAGES}"
else
  echo "WARNING: Postgres container '${POSTGRES_CONTAINER}' is not running. Skipping database comparison." >&2
  DB_PACKAGES=""
fi

python3 - <<PY
import json
import pathlib

on_disk = set(json.loads(pathlib.Path('${PACKAGE_LIST_JSON}').read_text()))
if '${DB_PACKAGES}':
    db_pkgs = set(pathlib.Path('${DB_PACKAGES}').read_text().strip().split('\n'))
else:
    db_pkgs = set()

missing_on_disk = sorted(db_pkgs - on_disk)
missing_in_db = sorted(on_disk - db_pkgs)

if db_pkgs:
    print('\n[DIFF]')
    if missing_on_disk:
        print('Packages registered in DB but missing on disk:')
        for name in missing_on_disk:
            print(f'  - {name}')
    else:
        print('No packages missing on disk.')
    if missing_in_db:
        print('\nPackages present on disk but absent from DB metadata:')
        for name in missing_in_db:
            print(f'  - {name}')
    else:
        print('\nNo packages missing in DB metadata.')
else:
    print('\n[INFO] Database package list unavailable; skipping diff.')
PY

# Check for problematic pkce-challenge module
if [[ -d "${CUSTOM_DIR}/node_modules/pkce-challenge" ]]; then
  echo "\n[WARNING] pkce-challenge is present under data/custom/node_modules."
  echo "         This package caused previous startup crashes; consider removing it."
fi

echo "\nCommunity node check completed."

#!/usr/bin/env bash

set -euo pipefail

# Synchronise an offline community-nodes archive into the local n8n data
# directories and refresh the metadata stored in Postgres. This prevents
# startup crashes caused by missing node dependencies and keeps the UI in
# sync with what is installed on disk.
#
# Usage:
#   ./scripts/sync-community-nodes.sh [path/to/community-nodes-*.tar.gz]
#
# When no path is provided the script will pick the newest archive that
# matches community-nodes-*.tar.gz in the repository root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_PATTERN="community-nodes-*.tar.gz"
ARCHIVE_PATH="${1:-}"

if [[ -z "${ARCHIVE_PATH}" ]]; then
  mapfile -t archives < <(cd "${REPO_ROOT}" && ls -1t ${DEFAULT_PATTERN} 2>/dev/null || true)
  if [[ ${#archives[@]} -eq 0 ]]; then
    echo "ERROR: No community-nodes archive found (pattern: ${DEFAULT_PATTERN})." >&2
    exit 1
  fi
  ARCHIVE_PATH="${REPO_ROOT}/${archives[0]}"
else
  if [[ "${ARCHIVE_PATH}" != /* ]]; then
    ARCHIVE_PATH="${REPO_ROOT}/${ARCHIVE_PATH}"
  fi
fi

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "ERROR: Archive '${ARCHIVE_PATH}' does not exist." >&2
  exit 1
fi

echo "Using archive: ${ARCHIVE_PATH}"

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

tar -xzf "${ARCHIVE_PATH}" -C "${TMPDIR}"

SRC_DIR="${TMPDIR}/nodes"
if [[ ! -d "${SRC_DIR}/node_modules" ]]; then
  echo "ERROR: Archive does not contain nodes/node_modules." >&2
  exit 1
fi

CUSTOM_DIR="${REPO_ROOT}/data/custom"
NODES_DIR="${REPO_ROOT}/data/nodes"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-n8n-postgres}"
N8N_IMAGE="${N8N_IMAGE:-ghcr.io/n8n-io/n8n:1.116.1}"
EXCLUDE_MODULES=("pkce-challenge")

mkdir -p "${CUSTOM_DIR}" "${NODES_DIR}"

timestamp="$(date +%Y%m%d%H%M%S)"
CUSTOM_BACKUP="${CUSTOM_DIR}_backup_${timestamp}"
NODES_BACKUP="${NODES_DIR}_backup_${timestamp}"

if [[ -d "${CUSTOM_DIR}" ]]; then
  echo "Creating backup of data/custom at ${CUSTOM_BACKUP}"
  cp -a "${CUSTOM_DIR}" "${CUSTOM_BACKUP}"
fi

if [[ -d "${NODES_DIR}" ]]; then
  echo "Creating backup of data/nodes at ${NODES_BACKUP}"
  cp -a "${NODES_DIR}" "${NODES_BACKUP}"
fi

rsync_excludes=()
for module in "${EXCLUDE_MODULES[@]}"; do
  rsync_excludes+=(--exclude "${module}")
done

echo "Syncing community node modules into data/custom"
rsync -a --delete "${rsync_excludes[@]}" "${SRC_DIR}/node_modules/" "${CUSTOM_DIR}/node_modules/"
cp "${SRC_DIR}/package.json" "${CUSTOM_DIR}/package.json"
cp "${SRC_DIR}/package-lock.json" "${CUSTOM_DIR}/package-lock.json"

echo "Syncing community node modules into data/nodes"
rsync -a --delete "${rsync_excludes[@]}" "${SRC_DIR}/node_modules/" "${NODES_DIR}/node_modules/"
cp "${SRC_DIR}/package.json" "${NODES_DIR}/package.json"
cp "${SRC_DIR}/package-lock.json" "${NODES_DIR}/package-lock.json"

echo "Linking community packages in data/custom to node_modules"
python3 - <<'PY'
import json
import os
import pathlib

base = pathlib.Path("data/custom")
node_modules = base / "node_modules"
manifest = json.loads((base / "package.json").read_text())
dependencies = (manifest.get("dependencies") or {}).keys()

for name in dependencies:
    link = base / name
    target = node_modules / name
    if not target.exists():
        print(f"[WARN] Skipping {name} (missing in node_modules)")
        continue
    if link.exists() or link.is_symlink():
        if link.is_symlink() and link.resolve() == target.resolve():
            continue
        if link.is_dir() and not link.is_symlink():
            for root, dirs, files in os.walk(link, topdown=False):
                for f in files:
                    os.remove(os.path.join(root, f))
                for d in dirs:
                    os.rmdir(os.path.join(root, d))
            os.rmdir(link)
        else:
            link.unlink()
    os.symlink(target, link)
PY

echo "Generating community package metadata"
METADATA_JS="${TMPDIR}/metadata.js"
cat > "${METADATA_JS}" <<'NODE'
const fs = require('fs');
const path = require('path');

const customDir = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(path.join(customDir, 'package.json'), 'utf8'));
const dependencies = Object.keys(manifest.dependencies || {});

const results = [];
for (const pkg of dependencies) {
  const pkgDir = path.join(customDir, 'node_modules', pkg);
  const pkgJsonPath = path.join(pkgDir, 'package.json');
  if (!fs.existsSync(pkgJsonPath)) {
    console.error(`[WARN] Missing package.json for ${pkg}`);
    continue;
  }
  const pkgManifest = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));
  const nodes = [];
  for (const rel of (pkgManifest.n8n?.nodes || [])) {
    try {
      const modulePath = path.join(pkgDir, rel);
      const mod = require(modulePath);
      const exported = typeof mod === 'function' ? mod : (mod?.default ?? Object.values(mod).find((v) => typeof v === 'function'));
      if (!exported) continue;
      const instance = new exported();
      let description = instance.description;
      if (!description && instance.nodeVersions && instance.currentVersion !== undefined) {
        const current = instance.nodeVersions[instance.currentVersion];
        description = current?.description;
      }
      if (!description || !description.displayName || !description.name) continue;
      let version = 1;
      if (Array.isArray(description.version)) version = description.version[description.version.length - 1];
      if (typeof description.version === 'number') version = description.version;
      nodes.push({
        displayName: description.displayName,
        type: `${pkg}.${description.name}`,
        latestVersion: Number.isFinite(version) ? version : 1,
      });
    } catch (error) {
      console.error(`[WARN] Failed to load node for ${pkg}: ${error.message}`);
    }
  }
  const author = pkgManifest.author;
  let authorName = null;
  let authorEmail = null;
  if (author) {
    if (typeof author === 'string') {
      const match = author.match(/([^<]+)(?:<([^>]+)>)?/);
      if (match) {
        authorName = match[1].trim() || null;
        authorEmail = match[2] ? match[2].trim() : null;
      }
    } else if (typeof author === 'object') {
      authorName = author.name || null;
      authorEmail = author.email || null;
    }
  }
  results.push({
    packageName: pkg,
    version: pkgManifest.version || null,
    authorName,
    authorEmail,
    nodes,
  });
}

process.stdout.write(JSON.stringify(results, null, 2));
NODE

METADATA_JSON="${TMPDIR}/packages_metadata.json"
docker run --rm \
  -v "${REPO_ROOT}/data/custom:/workspace/custom:ro" \
  -v "${METADATA_JS}:/tmp/metadata.js:ro" \
  "${N8N_IMAGE}" \
  node /tmp/metadata.js /workspace/custom > "${METADATA_JSON}"

SQL_FILE="${TMPDIR}/install_packages.sql"
python3 - <<PY
import json, pathlib

metadata_path = pathlib.Path("${METADATA_JSON}")
data = json.loads(metadata_path.read_text())

def esc(value):
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"

lines = ["BEGIN;", "DELETE FROM installed_nodes;", "DELETE FROM installed_packages;"]
for pkg in data:
    lines.append(
        "INSERT INTO installed_packages (\"packageName\", \"installedVersion\", \"authorName\", \"authorEmail\") "
        f"VALUES ({esc(pkg['packageName'])}, {esc(pkg.get('version') or '')}, {esc(pkg.get('authorName'))}, {esc(pkg.get('authorEmail'))});"
    )
    for node in pkg.get("nodes", []):
        latest = node.get("latestVersion") or 1
        lines.append(
            "INSERT INTO installed_nodes (\"name\", \"type\", \"latestVersion\", \"package\") "
            f"VALUES ({esc(node['displayName'])}, {esc(node['type'])}, {int(latest)}, {esc(pkg['packageName'])});"
        )
lines.append("COMMIT;")
pathlib.Path("${SQL_FILE}").write_text("\n".join(lines))
PY

if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
  echo "WARNING: Postgres container '${POSTGRES_CONTAINER}' is not running. Skipping metadata import." >&2
else
  echo "Updating installed_packages metadata inside Postgres"
  docker exec -i "${POSTGRES_CONTAINER}" psql -U n8n -d n8n < "${SQL_FILE}"
fi

TARGET_METADATA_DIR="${REPO_ROOT}/community_nodes_metadata"
mkdir -p "${TARGET_METADATA_DIR}"
cp "${METADATA_JSON}" "${TARGET_METADATA_DIR}/packages_metadata.json"
cp "${SQL_FILE}" "${TARGET_METADATA_DIR}/install_packages.sql"

echo "Community nodes synchronisation complete."
echo "Metadata written to ${TARGET_METADATA_DIR}/packages_metadata.json"

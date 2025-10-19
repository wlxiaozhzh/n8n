#!/usr/bin/env bash
set -euo pipefail

PROJECT_PREFIX=${PROJECT_PREFIX:-n8n}
DEFAULT_DEST="${PWD}/volume-backups"
DEST_DIR=${1:-$DEFAULT_DEST}
BACKUP_IMAGE=${BACKUP_IMAGE:-docker.m.daocloud.io/library/alpine:3.18}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found. Please install Docker and ensure it is in PATH." >&2
  exit 1
fi

if ! docker image inspect "$BACKUP_IMAGE" >/dev/null 2>&1; then
  cat >&2 <<EOF
Docker image "$BACKUP_IMAGE" is not available locally.
Please pull it first, for example:

  docker pull $BACKUP_IMAGE

Or set BACKUP_IMAGE to another tar-capable image before running this script.
EOF
  exit 1
fi

mkdir -p "$DEST_DIR"
DEST_DIR=$(cd "$DEST_DIR" && pwd)
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

VOLUME_LIST=$(docker volume ls --format '{{.Name}}' | grep "^${PROJECT_PREFIX}_" || true)
VOLUMES=()
while IFS= read -r volume_name; do
  [[ -z "$volume_name" ]] && continue
  VOLUMES+=("$volume_name")
done <<< "$VOLUME_LIST"

if [[ ${#VOLUMES[@]} -eq 0 ]]; then
  echo "No Docker volumes found with prefix '${PROJECT_PREFIX}_'." >&2
  exit 1
fi

echo "Backing up volumes: ${VOLUMES[*]}"

for VOLUME in "${VOLUMES[@]}"; do
  ARCHIVE_NAME="${VOLUME}-${TIMESTAMP}.tar.gz"
  echo "Creating archive ${ARCHIVE_NAME} ..."
  docker run --rm \
    -v "${VOLUME}":/data \
    -v "${DEST_DIR}":/backup \
    "$BACKUP_IMAGE" sh -c "cd /data && tar -czf /backup/${ARCHIVE_NAME} ."

  echo "Verifying archive ${ARCHIVE_NAME} ..."
  docker run --rm \
    -v "${DEST_DIR}":/backup \
    "$BACKUP_IMAGE" sh -c "tar -tzf /backup/${ARCHIVE_NAME} >/dev/null"

  echo "✔ Saved ${DEST_DIR}/${ARCHIVE_NAME}"
done

echo
echo "Backup complete. Archives stored in ${DEST_DIR}"

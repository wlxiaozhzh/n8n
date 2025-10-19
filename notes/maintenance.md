## Routine Maintenance

### Volume backups

Use the helper script to snapshot all Compose volumes whose name begins with `n8n_`:

```bash
chmod +x scripts/backup_volumes.sh
./scripts/backup_volumes.sh [destination-directory]
```

- Archives are written as `./volume-backups/<volume>-<timestamp>.tar.gz` by default.
- Each archive is immediately validated with `tar -tzf` to ensure it is readable.
- The script relies on a local tar-capable Docker image (default `alpine:3.18`). Pull it once (e.g. `docker pull alpine:3.18`, or set `BACKUP_IMAGE=your-registry/alpine` before running) if it is not already cached.
- You can restore by extracting the archive into a fresh Docker volume:

  ```bash
  docker volume create <target-volume>
  docker run --rm \
    -v <target-volume>:/restore \
    -v $(pwd)/volume-backups:/backup \
    alpine sh -c "cd /restore && tar -xzf /backup/<archive>.tar.gz"
  ```

### Availability checks

Add a sanity check to deployment pipelines or cron jobs:

```bash
chmod +x scripts/n8n_healthcheck.sh
./scripts/n8n_healthcheck.sh          # defaults to http://localhost:5678/healthz
./scripts/n8n_healthcheck.sh https://n8n.example.com/healthz
```

- The script reads health data via `curl` when available; otherwise it falls back to `docker exec n8n-main node …`.
- Exit code `0` means healthy; any non-zero value indicates that the API is unreachable or returned a non-200 status.

Integrate the health check in CI/CD to block rollouts when n8n is down, and schedule the volume backup script (for example, via cron) so the most recent data can be restored quickly if required.

#!/usr/bin/env bash
# Back up Gitea (repos, database, config, attachments) as a snapshot of ./data/gitea.
# Gitea is stopped for a few seconds so the SQLite database is consistent.
#
# Usage: scripts/backup.sh [keep]    keep = number of backups to retain (default 14)
# Restore: see docs/teacher-guide.md
set -euo pipefail
cd "$(dirname "$0")/.."

keep="${1:-14}"
mkdir -p backups
name="gitea-$(date +%Y%m%d-%H%M%S).tar.gz"

echo "==> Stopping Gitea"
docker compose stop gitea
trap 'docker compose start gitea >/dev/null' EXIT

echo "==> Writing backups/$name"
# Tar inside a container so file ownership inside ./data doesn't matter.
docker run --rm -v "$PWD/data:/data:ro" -v "$PWD/backups:/backups" alpine:3.22 \
	tar -czf "/backups/$name" -C /data gitea

docker compose start gitea
trap - EXIT
echo "==> Gitea restarted"

echo "==> Keeping the newest $keep backups"
ls -1t backups/gitea-*.tar.gz | tail -n +"$((keep + 1))" | xargs -r rm -f

ls -lh "backups/$name"

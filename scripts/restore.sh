#!/usr/bin/env bash
# Restore a backup made by scripts/backup.sh into the running stack.
# Usage: scripts/restore.sh <backup-dir>
#
# The database dump is restored with --clean --if-exists, i.e. existing
# objects contained in the dump are dropped and recreated. Storage objects are
# mirrored back into the MinIO bucket (existing objects are overwritten).
set -euo pipefail
cd "$(dirname "$0")/.."

IN=${1:?usage: scripts/restore.sh <backup-dir>}
[ -f "$IN/db.dump" ] || { echo "restore: $IN/db.dump not found" >&2; exit 1; }

envget() { sed -n "s/^$1=//p" .env | tail -n1; }
DB=$(envget POSTGRES_DB)
BUCKET=$(envget GLOBAL_S3_BUCKET)

if [ "${RESTORE_YES:-}" != 1 ]; then
  printf 'restore: this overwrites database "%s" and bucket "%s". Continue? [y/N] ' "$DB" "$BUCKET"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "aborted"; exit 1; }
fi

echo "restore: restoring database '$DB'"
# Errors about pre-existing Supabase-managed objects are expected and ignored;
# pg_restore still restores all data.
docker compose exec -T db pg_restore -U supabase_admin -d "$DB" --clean --if-exists \
  --no-password < "$IN/db.dump" 2> "$IN/restore.log" || \
  echo "restore: pg_restore reported warnings, see $IN/restore.log"

if [ -d "$IN/storage" ]; then
  echo "restore: mirroring objects into bucket '$BUCKET'"
  docker compose run --rm --no-deps -T -v "$PWD/$IN/storage:/backup:ro" \
    --entrypoint /bin/sh minio-init -ec '
      mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
      mc mirror --quiet --overwrite /backup "local/$BUCKET" >/dev/null'
fi

docker compose restart rest storage >/dev/null
echo "restore: done"

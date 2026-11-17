#!/usr/bin/env bash
# Back up the database (pg_dump, custom format) and all Storage objects
# (MinIO bucket mirror) into ./backups/<timestamp>/.
# Usage: scripts/backup.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."

envget() { sed -n "s/^$1=//p" .env | tail -n1; }
DB=$(envget POSTGRES_DB)
BUCKET=$(envget GLOBAL_S3_BUCKET)
OUT=${1:-backups/$(date +%Y%m%d-%H%M%S)}

mkdir -p "$OUT/storage"
chmod 700 "$OUT"

echo "backup: dumping database '$DB' -> $OUT/db.dump"
# supabase_admin is the superuser that owns the Supabase-managed schemas.
docker compose exec -T db pg_dump -U supabase_admin -d "$DB" -Fc --no-password > "$OUT/db.dump"

echo "backup: mirroring MinIO bucket '$BUCKET' -> $OUT/storage/"
docker compose run --rm --no-deps -T --user "$(id -u):$(id -g)" \
  -v "$PWD/$OUT/storage:/backup" --entrypoint /bin/sh minio-init -ec '
    mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    mc mirror --quiet --overwrite "local/$BUCKET" /backup >/dev/null'

du -sh "$OUT" | awk '{print "backup: done, size " $1 " in " $2}'

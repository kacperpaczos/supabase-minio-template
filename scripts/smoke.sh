#!/usr/bin/env bash
# End-to-end smoke test against a running stack.
#
# Checks: REST answers, Auth is healthy, a private bucket can be created,
# a file uploaded with the service key downloads back byte-identical (sha256)
# and is physically stored in MinIO, anon cannot write, and imgproxy returns a
# resized thumbnail. Cleans up after itself. Never prints secrets.
#
# Requires: bash, curl (>= 7.75 for --aws-sigv4), openssl, od, and docker
# (the REST check creates a temporary table via psql in the db container).
set -euo pipefail

cd "$(dirname "$0")/.."

[ -f .env ] || { echo "smoke: .env not found (run: make env)" >&2; exit 1; }

# Read a single key from .env without sourcing it.
envget() { sed -n "s/^$1=//p" .env | tail -n1 | sed -e 's/^"//' -e 's/"$//'; }

API_PORT=$(envget API_HOST_PORT)
MINIO_PORT=$(envget MINIO_API_HOST_PORT)
URL="http://127.0.0.1:${API_PORT}"
S3_BUCKET=$(envget GLOBAL_S3_BUCKET)
TENANT=$(envget STORAGE_TENANT_ID)

WORK=$(mktemp -d)
chmod 700 "$WORK"
BUCKET="smoke-$(openssl rand -hex 4)"
FAILED=0

# Header files keep keys out of the process list.
umask 077
printf 'apikey: %s\nAuthorization: Bearer %s\n' "$(envget SERVICE_ROLE_KEY)" "$(envget SERVICE_ROLE_KEY)" > "$WORK/h-service"
printf 'apikey: %s\nAuthorization: Bearer %s\n' "$(envget ANON_KEY)" "$(envget ANON_KEY)" > "$WORK/h-anon"
printf 'user = "%s:%s"\n' "$(envget STORAGE_S3_ACCESS_KEY)" "$(envget STORAGE_S3_SECRET_KEY)" > "$WORK/s3.curlrc"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
# expect STATUS MESSAGE -> compares against $code from the last request
expect() {
  if [ "$code" = "$1" ]; then ok "$2 ($code)"; return; fi
  fail "$2: got HTTP $code $(head -c 200 "$WORK/body" 2>/dev/null)"
}

# req HEADERFILE METHOD PATH [curl args...] -> prints HTTP status, body in $WORK/body
req() {
  local hdr=$1 method=$2 path=$3; shift 3
  curl -sS -o "$WORK/body" -w '%{http_code}' -X "$method" -H "@$WORK/$hdr" "$@" "$URL$path" || true
}

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

cleanup() {
  req h-service DELETE "/storage/v1/object/$BUCKET" -H 'Content-Type: application/json' \
    -d '{"prefixes":["data.bin","thumb.png","anon.txt"]}' >/dev/null || true
  req h-service DELETE "/storage/v1/bucket/$BUCKET" >/dev/null || true
  if [ -n "${TABLE:-}" ]; then
    echo "drop table if exists public.$TABLE;" | docker compose exec -T db psql -q -U postgres -d "$(envget POSTGRES_DB)" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "smoke: testing $URL"

# 1. REST: OpenAPI (service key only) and a real anon query through RLS
code=$(req h-service GET /rest/v1/)
expect 200 "REST /rest/v1/ answers with service key"

TABLE="smoke_$(openssl rand -hex 4)"
docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U postgres -d "$(envget POSTGRES_DB)" >/dev/null <<SQL
create table public.$TABLE (id int primary key, note text);
alter table public.$TABLE enable row level security;
create policy "public read" on public.$TABLE for select to anon using (true);
grant select on public.$TABLE to anon;
insert into public.$TABLE values (1, 'hello from smoke');
SQL
for _ in 1 2 3 4 5 6 7 8 9 10; do
  code=$(req h-anon GET "/rest/v1/$TABLE?select=note&id=eq.1")
  [ "$code" = 200 ] && break
  sleep 1
done
if [ "$code" = 200 ] && grep -q 'hello from smoke' "$WORK/body"; then
  ok "REST anon select through RLS returns the row"
else
  fail "REST anon select returned $code: $(head -c 200 "$WORK/body")"
fi
code=$(req h-anon POST "/rest/v1/$TABLE" -H 'Content-Type: application/json' -d '{"id":2,"note":"x"}')
case "$code" in
  2??) fail "REST anon insert was accepted ($code)" ;;
  *)   ok "REST anon insert rejected ($code)" ;;
esac

# 2. Auth
code=$(req h-anon GET /auth/v1/health)
expect 200 "Auth /auth/v1/health"

# 3. Private bucket
code=$(req h-service POST /storage/v1/bucket -H 'Content-Type: application/json' \
  -d "{\"id\":\"$BUCKET\",\"name\":\"$BUCKET\",\"public\":false}")
expect 200 "created private bucket $BUCKET"
[ "$code" = 200 ] || exit 1

# 4. Upload with service key, download, compare sha256
head -c 262144 /dev/urandom > "$WORK/data.bin"
code=$(req h-service POST "/storage/v1/object/$BUCKET/data.bin" \
  -H 'Content-Type: application/octet-stream' --data-binary "@$WORK/data.bin")
expect 200 "uploaded 256 KiB with service key"

code=$(req h-service GET "/storage/v1/object/authenticated/$BUCKET/data.bin")
cp "$WORK/body" "$WORK/download.bin"
if [ "$code" = 200 ] && [ "$(sha "$WORK/data.bin")" = "$(sha "$WORK/download.bin")" ]; then
  ok "download is byte-identical (sha256 $(sha "$WORK/data.bin" | cut -c1-16)...)"
else
  fail "download returned $code or sha256 mismatch"
fi

# 5. Object really lives in MinIO (listed with the bucket-scoped storage user)
code=$(curl -sS -o "$WORK/list.xml" -w '%{http_code}' -K "$WORK/s3.curlrc" \
  --aws-sigv4 "aws:amz:$(envget REGION):s3" \
  "http://127.0.0.1:${MINIO_PORT}/${S3_BUCKET}?list-type=2&prefix=${TENANT}/${BUCKET}/" || true)
if [ "$code" = 200 ] && grep -q "<Key>${TENANT}/${BUCKET}/data.bin" "$WORK/list.xml"; then
  ok "object stored in MinIO bucket '$S3_BUCKET'"
else
  fail "object not found in MinIO (HTTP $code)"
fi

# 6. Anon cannot write
code=$(req h-anon POST "/storage/v1/object/$BUCKET/anon.txt" -H 'Content-Type: text/plain' --data-binary 'nope')
case "$code" in
  2??) fail "anon upload was accepted ($code)" ;;
  000) fail "anon upload: no response" ;;
  *)   ok "anon upload rejected ($code)" ;;
esac
code=$(req h-anon GET "/storage/v1/object/authenticated/$BUCKET/data.bin")
case "$code" in
  2??) fail "anon could read a private object ($code)" ;;
  *)   ok "anon read of private object rejected ($code)" ;;
esac

# 7. imgproxy thumbnail (64x48 PNG -> 16x12)
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwCAIAAAAuKetIAAAARUlEQVR42u3PQQkAAAgEsItuc+0g3G+wAsvuVKVOQEBAQEBAQEBAQEBAQEBAQOAlU5U2AQEBAQEBAQEBAQEBAQEBAYGPA9vj9QAG4ku2AAAAAElFTkSuQmCC' \
  | openssl base64 -d -A > "$WORK/image.png"
code=$(req h-service POST "/storage/v1/object/$BUCKET/thumb.png" -H 'Content-Type: image/png' --data-binary "@$WORK/image.png")
expect 200 "uploaded test PNG"
code=$(req h-service GET "/storage/v1/render/image/authenticated/$BUCKET/thumb.png?width=16&height=12&resize=fill&format=origin")
width=$(od -An -tu1 -j16 -N4 "$WORK/body" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')
magic=$(od -An -c -j1 -N3 "$WORK/body" | tr -d ' ')
if [ "$code" = 200 ] && [ "$magic" = PNG ] && [ "$width" = 16 ]; then
  ok "imgproxy thumbnail returned (64px -> ${width}px PNG)"
else
  fail "image transform returned $code (magic=$magic width=$width)"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "smoke: ALL CHECKS PASSED"
else
  echo "smoke: FAILURES" >&2
  exit 1
fi

#!/usr/bin/env bash
# Generate a fresh .env from .env.example with random secrets.
#
# Usage:
#   scripts/gen-env.sh [--force] [KEY=VALUE ...]
#
#   --force      overwrite an existing .env (the old file is kept as .env.bak.<timestamp>)
#   KEY=VALUE    override any non-generated value, e.g. API_HOST_PORT=59000
#
# Requires: bash, openssl. Secrets are written to .env (mode 600) and are
# never printed.
set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE=.env.example
TARGET=.env
FORCE=0
OVERRIDES=()

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *=*) OVERRIDES+=("$arg") ;;
    *) echo "gen-env: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v openssl >/dev/null || { echo "gen-env: openssl is required" >&2; exit 1; }

if [ -e "$TARGET" ] && [ "$FORCE" -ne 1 ]; then
  echo "gen-env: $TARGET already exists; use --force to replace it (a backup is kept)." >&2
  exit 1
fi

hex() { openssl rand -hex "$1"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# sign_jwt ROLE -> HS256 JWT signed with $JWT_SECRET, valid for 5 years
sign_jwt() {
  local role=$1 now exp header payload sig
  now=$(date +%s)
  exp=$((now + 5 * 365 * 24 * 3600))
  header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$now" "$exp" | b64url)
  sig=$(printf '%s' "$header.$payload" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

override_for() {
  local key=$1 kv
  for kv in ${OVERRIDES[@]+"${OVERRIDES[@]}"}; do
    if [ "${kv%%=*}" = "$key" ]; then printf '%s' "${kv#*=}"; return 0; fi
  done
  return 1
}

JWT_SECRET=$(hex 32)

generated_value() {
  case "$1" in
    POSTGRES_PASSWORD)              hex 24 ;;
    JWT_SECRET)                     printf '%s' "$JWT_SECRET" ;;
    ANON_KEY)                       sign_jwt anon ;;
    SERVICE_ROLE_KEY)               sign_jwt service_role ;;
    DASHBOARD_PASSWORD)             hex 16 ;;
    SECRET_KEY_BASE)                hex 32 ;;   # >= 64 chars
    REALTIME_DB_ENC_KEY)            hex 8 ;;    # exactly 16 chars
    VAULT_ENC_KEY)                  hex 16 ;;   # exactly 32 chars
    PG_META_CRYPTO_KEY)             hex 16 ;;
    LOGFLARE_PUBLIC_ACCESS_TOKEN)   hex 24 ;;
    LOGFLARE_PRIVATE_ACCESS_TOKEN)  hex 24 ;;
    S3_PROTOCOL_ACCESS_KEY_ID)      hex 16 ;;
    S3_PROTOCOL_ACCESS_KEY_SECRET)  hex 32 ;;
    MINIO_ROOT_USER)                printf 'admin-%s' "$(hex 4)" ;;
    MINIO_ROOT_PASSWORD)            hex 24 ;;
    STORAGE_S3_ACCESS_KEY)          printf 'storage-%s' "$(hex 6)" ;;
    STORAGE_S3_SECRET_KEY)          hex 24 ;;
    POOLER_TENANT_ID)               printf 'tenant-%s' "$(hex 4)" ;;
    *) echo "gen-env: no generator for $1" >&2; return 1 ;;
  esac
}

# Resolve the API port first so the public URLs can follow it.
api_port=$(override_for API_HOST_PORT || sed -n 's/^API_HOST_PORT=//p' "$TEMPLATE")

tmp=$(mktemp "${TARGET}.tmp.XXXXXX")
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    [A-Z_]*=*)
      key=${line%%=*}
      value=${line#*=}
      if v=$(override_for "$key"); then
        value=$v
      elif [ "$value" = "generated" ]; then
        value=$(generated_value "$key")
      elif [ "$key" = SUPABASE_PUBLIC_URL ]; then
        value="http://127.0.0.1:${api_port}"
      elif [ "$key" = API_EXTERNAL_URL ]; then
        value="http://127.0.0.1:${api_port}/auth/v1"
      fi
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
      ;;
    *) printf '%s\n' "$line" >> "$tmp" ;;
  esac
done < "$TEMPLATE"

if [ -e "$TARGET" ]; then
  backup="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$TARGET" "$backup"
  echo "gen-env: previous $TARGET saved as $backup"
fi
mv "$tmp" "$TARGET"
trap - EXIT

echo "gen-env: wrote $TARGET with fresh secrets (not shown)."
echo "gen-env: if volumes from an earlier run exist, their passwords no longer match; reset with: make clean"

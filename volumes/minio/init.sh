#!/bin/sh
# One-shot MinIO bootstrap, run by the `minio-init` service on every `up`.
# Idempotent: creates the Storage bucket and a MinIO user whose policy only
# allows access to that bucket. Supabase Storage uses that user, so the MinIO
# root credentials never leave the minio/minio-init containers.
set -eu

: "${BUCKET:?}" "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}"
: "${STORAGE_S3_ACCESS_KEY:?}" "${STORAGE_S3_SECRET_KEY:?}"

mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

mc mb --ignore-existing "local/$BUCKET"

policy_file=/tmp/storage-policy.json
cat > "$policy_file" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::$BUCKET"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::$BUCKET/*"]
    }
  ]
}
JSON

mc admin policy create local supabase-storage "$policy_file" >/dev/null
mc admin user add local "$STORAGE_S3_ACCESS_KEY" "$STORAGE_S3_SECRET_KEY" >/dev/null
# `attach` fails if the policy is already attached; that is fine on re-runs.
mc admin policy attach local supabase-storage --user "$STORAGE_S3_ACCESS_KEY" >/dev/null 2>&1 || true

echo "minio-init: bucket '$BUCKET' and scoped storage user ready"

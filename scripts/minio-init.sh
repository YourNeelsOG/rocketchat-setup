#!/bin/sh
# Runs inside the minio-init container (the mc image, which provides /bin/sh
# but not bash). Creates the bucket, a least-privilege policy, and the user
# Rocket.Chat authenticates as.
#
# The MinIO root credentials stay here. Rocket.Chat only ever receives the
# scoped key pair created below, so a compromise of the application cannot
# administer the object store.
#
# Every step is idempotent, because compose restarts this container on any
# `up` and a second run must be a no-op rather than an error.

set -eu

BUCKET="${RC_MINIO_BUCKET:-rocketchat-uploads}"
POLICY="rocketchat-policy"

echo "waiting for MinIO to accept connections"
i=0
until mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "MinIO did not become reachable within 300s" >&2
    exit 1
  fi
  sleep 5
done
echo "connected to MinIO"

mc mb --ignore-existing "local/${BUCKET}"
echo "bucket ${BUCKET} present"

# The object-level and bucket-level ARNs are distinct. ListBucket is a bucket
# operation and does not accept the /* form, while Get, Put and Delete act on
# objects and do. Granting only one of the two produces uploads that work and
# listings that fail, or the reverse.
cat >/tmp/policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::${BUCKET}/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::${BUCKET}"]
    }
  ]
}
EOF

# The policy has to exist before it can be attached. Creating it is a separate
# call from attaching it; attaching a policy that was never created fails with
# a message that does not make the cause obvious.
mc admin policy create local "$POLICY" /tmp/policy.json 2>/dev/null \
  || mc admin policy update local "$POLICY" /tmp/policy.json 2>/dev/null \
  || echo "policy ${POLICY} already present and unchanged"

mc admin user add local "$RC_MINIO_ACCESS_KEY" "$RC_MINIO_SECRET_KEY" 2>/dev/null \
  || echo "user already exists"

mc admin policy attach local "$POLICY" --user "$RC_MINIO_ACCESS_KEY" 2>/dev/null \
  || echo "policy already attached"

rm -f /tmp/policy.json
echo "MinIO initialisation complete: bucket=${BUCKET} policy=${POLICY}"

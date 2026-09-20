#!/usr/bin/env bash
# Generates the credentials this stack needs and writes them to a file with
# restrictive permissions.
#
# Called by configure.sh. Run directly only when deliberately rotating
# credentials, which requires updating MinIO and restarting Rocket.Chat; see
# docs/SECURITY.md.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

OUT=''
while (($#)); do
  case "$1" in
    --env-file) OUT="$2"; shift 2 ;;
    *) die "usage: generate-secrets.sh --env-file PATH" ;;
  esac
done
[[ -n "$OUT" ]] || die "usage: generate-secrets.sh --env-file PATH"

# MinIO rejects several characters in credentials supplied via environment
# variables, and base64 output can contain "+" and "/" which also need care in
# .env parsing. Hex avoids both problems at the cost of needing more bytes for
# the same entropy, so the lengths below are sized accordingly:
# 32 hex characters is 128 bits, 64 is 256 bits.
rand_hex() { openssl rand -hex "$1"; }

MINIO_ROOT_USER="minioadmin$(rand_hex 4)"
MINIO_ROOT_PASSWORD="$(rand_hex 32)"
MINIO_ACCESS_KEY="rocketchat$(rand_hex 4)"
MINIO_SECRET_KEY="$(rand_hex 32)"

# The file is created with mode 600 before any secret is written to it, so the
# credentials are never momentarily world-readable.
run_write "$OUT" 600 <<EOF
# --- Generated credentials. Never commit this file. ---
# MinIO root: administration only. Rocket.Chat never receives these.
RC_MINIO_ROOT_USER=${MINIO_ROOT_USER}
RC_MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}

# MinIO application user: scoped to the uploads bucket by scripts/minio-init.sh.
RC_MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
RC_MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
RC_MINIO_BUCKET=rocketchat-uploads
EOF

ok "credentials generated"

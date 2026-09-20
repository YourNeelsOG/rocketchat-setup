#!/usr/bin/env bash
# Renews the TLS certificate and reloads nginx if it actually changed.
#
# The reload is the part that is easy to leave out and expensive to omit:
# certbot writes the new certificate to disk, but nginx keeps serving the one
# it loaded at startup until it is told to reload. Without this, a correctly
# scheduled renewal still ends in an expired certificate, discovered by users.
#
# Intended to run twice daily. Certbot only acts when the certificate is within
# 30 days of expiry, so running it often is free.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -r "$ENV_FILE" ]] || die "no .env found at ${ENV_FILE}"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a

FORCE=0
while (($#)); do
  case "$1" in
    --force-renewal) FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *) die "usage: renew-cert.sh [--force-renewal] [--dry-run]" ;;
  esac
done

cd "$REPO_DIR"
dc() { run docker compose --env-file "$ENV_FILE" "$@"; }

case "${RC_MODE:-}" in
  behind-proxy|plain-http)
    exit 0
    ;;
  local-tls)
    # Self-signed certificates are regenerated rather than renewed.
    exec "$SCRIPT_DIR/issue-cert.sh" ${FORCE:+--force}
    ;;
esac

# Fingerprint before and after. Comparing this is more reliable than parsing
# certbot's output, which varies between versions.
fingerprint() {
  docker compose --env-file "$ENV_FILE" run --rm --entrypoint sh certbot -c \
    "openssl x509 -noout -fingerprint -sha256 -in /etc/letsencrypt/live/${RC_DOMAIN}/cert.pem 2>/dev/null" \
    2>/dev/null | tr -d '\r\n' || true
}

before="$(fingerprint)"

force_flag=()
[[ "$FORCE" == "1" ]] && force_flag=(--force-renewal)

dc run --rm certbot renew --webroot -w /var/www/certbot --non-interactive "${force_flag[@]}"

after="$(fingerprint)"

if [[ "$before" == "$after" ]]; then
  ok "certificate unchanged; no reload needed"
  exit 0
fi

info "certificate changed; reloading nginx"
if docker compose --env-file "$ENV_FILE" ps --status running --services 2>/dev/null | grep -qx nginx; then
  dc exec -T nginx nginx -s reload
  ok "nginx reloaded with the renewed certificate"
else
  warn "nginx is not running; the renewed certificate will be picked up when it starts"
fi

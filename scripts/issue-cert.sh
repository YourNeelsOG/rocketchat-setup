#!/usr/bin/env bash
# Obtains the TLS certificate and leaves nginx serving it.
#
# For public-tls this is a two-stage flow, and the ordering is the whole point:
# the real nginx configuration references certificate files that do not exist
# on a first install, so nginx cannot start; and certbot's HTTP-01 challenge
# needs something already answering on port 80 to serve the challenge token.
# Starting the real configuration first deadlocks. So nginx is started with a
# certificate-free bootstrap configuration, the certificate is obtained through
# it, and only then is nginx recreated with the real configuration.
#
# For local-tls a self-signed CA and server certificate are generated locally
# and no ACME exchange happens at all.
#
# Idempotent: re-running against a valid certificate does nothing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -r "$ENV_FILE" ]] || die "no .env found; run scripts/configure.sh first"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a

FORCE=0
while (($#)); do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "usage: issue-cert.sh [--force] [--dry-run]" ;;
  esac
done

cd "$REPO_DIR"
dc() { run docker compose --env-file "$ENV_FILE" "$@"; }

case "${RC_MODE:-}" in

  behind-proxy|plain-http)
    ok "mode ${RC_MODE} terminates no TLS here; nothing to issue"
    exit 0
    ;;

  local-tls)
    # ---------------------------------------------------------------------
    # Self-signed: a small CA, then a server certificate signed by it. A CA is
    # used rather than a bare self-signed leaf so the operator can install one
    # certificate on their devices and keep trusting it across renewals.
    # ---------------------------------------------------------------------
    certdir="$REPO_DIR/certs"
    if [[ -s "$certdir/server.crt" && "$FORCE" != "1" ]]; then
      if openssl x509 -checkend $((30 * 86400)) -noout -in "$certdir/server.crt" >/dev/null 2>&1; then
        ok "existing self-signed certificate is valid for at least 30 more days"
        exit 0
      fi
      info "existing certificate expires within 30 days; regenerating"
    fi

    heading "-- Generating a self-signed certificate for ${RC_DOMAIN} --"
    run mkdir -p "$certdir"

    # A SAN entry is mandatory: every current browser and mobile client ignores
    # the legacy CommonName field, so a certificate without SANs is rejected
    # outright rather than merely warned about.
    san="DNS:${RC_DOMAIN}"
    [[ "$RC_DOMAIN" =~ ^[0-9.]+$ ]] && san="IP:${RC_DOMAIN}"
    for ip in $(local_ips); do san="${san},IP:${ip}"; done
    san="${san},DNS:localhost,IP:127.0.0.1"

    run openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "$certdir/ca.key" -out "$certdir/ca.crt" \
      -subj "/CN=${RC_DOMAIN} local CA/O=Rocket.Chat self-hosted"

    run openssl req -newkey rsa:2048 -nodes \
      -keyout "$certdir/server.key" -out "$certdir/server.csr" \
      -subj "/CN=${RC_DOMAIN}"

    run_write "$certdir/server.ext" 644 <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san}
EOF

    run openssl x509 -req -in "$certdir/server.csr" \
      -CA "$certdir/ca.crt" -CAkey "$certdir/ca.key" -CAcreateserial \
      -out "$certdir/server.crt" -days 825 -sha256 -extfile "$certdir/server.ext"

    run rm -f "$certdir/server.csr" "$certdir/server.ext"
    run chmod 600 "$certdir/ca.key" "$certdir/server.key"
    run chmod 644 "$certdir/ca.crt" "$certdir/server.crt"

    ok "certificate written to ${certdir}"
    warn "The Rocket.Chat mobile apps reject certificates they cannot verify."
    hint "Install ${certdir}/ca.crt on every device that will connect:"
    hint "  Android  Settings > Security > Encryption & credentials > Install a certificate > CA certificate"
    hint "  iOS      AirDrop or email the file, install the profile, then"
    hint "           Settings > General > About > Certificate Trust Settings > enable full trust"
    hint "  Linux    copy to /usr/local/share/ca-certificates/ then run update-ca-certificates"
    hint "  macOS    open in Keychain Access, then set the certificate to Always Trust"
    ;;

  public-tls)
    # ---------------------------------------------------------------------
    # Let's Encrypt via HTTP-01.
    # ---------------------------------------------------------------------
    if [[ "$FORCE" != "1" ]] \
      && docker compose --env-file "$ENV_FILE" run --rm --entrypoint sh certbot \
           -c "test -s /etc/letsencrypt/live/${RC_DOMAIN}/fullchain.pem" >/dev/null 2>&1; then
      ok "a certificate for ${RC_DOMAIN} already exists; renewal is scripts/renew-cert.sh"
      exit 0
    fi

    heading "-- Stage 1: starting nginx with the bootstrap configuration --"
    hint "serves only the ACME challenge path; references no certificate"
    RC_NGINX_TEMPLATE=bootstrap dc up -d --force-recreate nginx

    # nginx needs a moment to render the template and bind before certbot
    # connects to it from outside.
    run sleep 3

    staging_flag=()
    [[ "${RC_LE_STAGING:-0}" == "1" ]] && staging_flag=(--staging)

    heading "-- Stage 2: validating the challenge path against the staging endpoint --"
    hint "a dry run costs nothing against the rate limit and catches DNS and firewall problems"
    if ! dc run --rm certbot certonly \
        --webroot -w /var/www/certbot \
        -d "${RC_DOMAIN}" \
        --email "${RC_LE_EMAIL}" \
        --agree-tos --no-eff-email \
        --non-interactive --dry-run; then
      err "the dry run failed, so no real certificate was requested"
      hint "the usual causes, in order of likelihood:"
      hint "  the DNS A record for ${RC_DOMAIN} does not point at this host"
      hint "  port 80 is not reachable from the internet (firewall, NAT, or ISP block)"
      hint "  another service is answering on port 80 ahead of this stack"
      hint "check with: scripts/preflight.sh"
      die "certificate issuance aborted before consuming any rate limit"
    fi
    ok "dry run succeeded"

    heading "-- Stage 3: requesting the certificate --"
    dc run --rm certbot certonly \
      --webroot -w /var/www/certbot \
      -d "${RC_DOMAIN}" \
      --email "${RC_LE_EMAIL}" \
      --agree-tos --no-eff-email \
      --non-interactive --keep-until-expiring \
      "${staging_flag[@]}"

    if [[ "${RC_LE_STAGING:-0}" == "1" ]]; then
      warn "this is a Let's Encrypt STAGING certificate; browsers will reject it"
      hint "re-run without --staging-certs once the flow is proven"
    fi
    ok "certificate obtained for ${RC_DOMAIN}"
    ;;

  *)
    die "unknown RC_MODE '${RC_MODE:-}' in ${ENV_FILE}"
    ;;
esac

heading "-- Switching nginx to the full configuration --"
dc up -d --force-recreate nginx
ok "nginx is serving ${RC_ROOT_URL}"

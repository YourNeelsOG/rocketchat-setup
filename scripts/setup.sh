#!/usr/bin/env bash
# Brings the stack up from a configured .env: preflight, start, certificates,
# firewall, scheduling, then a health report.
#
# Safe to re-run. Every step is idempotent, so this doubles as the repair
# command when something was changed by hand.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
SKIP_FIREWALL=0
SKIP_SCHEDULE=0

while (($#)); do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --yes|--non-interactive) ASSUME_YES=1; shift ;;
    --skip-firewall)  SKIP_FIREWALL=1; shift ;;
    --skip-schedule)  SKIP_SCHEDULE=1; shift ;;
    *) die "usage: setup.sh [--dry-run] [--yes] [--skip-firewall] [--skip-schedule]" ;;
  esac
done

# Configuration is collected first if it has not been already.
if [[ ! -r "$ENV_FILE" ]]; then
  info "no .env yet; collecting configuration"
  DRY_RUN="$DRY_RUN" ASSUME_YES="$ASSUME_YES" "$SCRIPT_DIR/configure.sh"
fi
[[ -r "$ENV_FILE" ]] || die "configuration did not produce ${ENV_FILE}"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a

cd "$REPO_DIR"
dc() { run docker compose --env-file "$ENV_FILE" "$@"; }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

# `set +e` does not suppress the ERR trap that lib.sh installs, so the older
# `set +e; cmd; rc=$?; set -e` form aborted here on any non-zero exit. The `|| rc=$?`
# form is handled failure, which the trap correctly ignores.
pf=0
"$SCRIPT_DIR/preflight.sh" || pf=$?
case "$pf" in
  0) ;;
  3) confirm 'Preflight reported warnings. Continue?' default_yes || die "aborted" ;;
  *) die "preflight found blocking problems; fix them and re-run" ;;
esac

# --------------------------------------------------------------------------
# Directories
# --------------------------------------------------------------------------

heading "== Creating directories =="
run mkdir -p "${RC_DATA_DIR}" "${RC_BACKUP_DIR}"
run chmod 750 "${RC_BACKUP_DIR}"
if [[ "${RC_MONGO_PATH:-}" == /* ]]; then run mkdir -p "${RC_MONGO_PATH}"; fi
if [[ "${RC_MINIO_PATH:-}" == /* ]]; then run mkdir -p "${RC_MINIO_PATH}"; fi
ok "directories ready"

# --------------------------------------------------------------------------
# Certificates and startup
#
# For public-tls the certificate must exist before the full nginx config can
# load, so issue-cert.sh runs before the rest of the stack starts. It brings up
# only nginx, on a bootstrap config, for exactly that purpose.
# --------------------------------------------------------------------------

heading "== Starting the stack =="

if [[ "${RC_MODE}" == "local-tls" ]]; then
  # The self-signed certificate is generated locally, so it can exist before
  # anything starts and nginx can come up on its real configuration directly.
  "$SCRIPT_DIR/issue-cert.sh"
fi

if [[ "${RC_MODE}" == "public-tls" ]]; then
  # Start everything except nginx. Bringing nginx up here would load the
  # public-tls template, which references a certificate that does not exist on
  # a first install, and it would crash-loop until issue-cert.sh recreated it
  # on the bootstrap configuration. It recovers, but it fills the logs of a
  # first install with certificate errors that look like a real failure, and it
  # relies on `up -d` not waiting for nginx to become healthy.
  #
  # `up -d rocketchat` pulls in the database, transporter and object storage
  # through depends_on; only nginx and certbot are left out.
  info "starting database, transporter, object storage and application"
  dc up -d rocketchat

  # Brings nginx up on the bootstrap configuration, obtains the certificate,
  # then recreates nginx on the real one.
  "$SCRIPT_DIR/issue-cert.sh"
fi

info "starting any remaining services"
dc up -d

heading "== Waiting for services =="
if [[ "$DRY_RUN" != "1" ]]; then
  deadline=$((SECONDS + 600))
  while ((SECONDS < deadline)); do
    if docker compose --env-file "$ENV_FILE" ps --format json 2>/dev/null \
        | grep -q '"Health":"starting"'; then
      sleep 10
      continue
    fi
    break
  done
  unhealthy="$(docker compose --env-file "$ENV_FILE" ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
                | awk '$2 == "unhealthy" {print $1}' || true)"
  if [[ -n "$unhealthy" ]]; then
    err "these services are unhealthy: ${unhealthy}"
    for svc in $unhealthy; do
      log ""
      log "--- last 30 log lines from ${svc} ---"
      docker compose --env-file "$ENV_FILE" logs --tail 30 "$svc" >&2 || true
    done
    die "startup failed; see docs/TROUBLESHOOTING.md"
  fi
fi
ok "all services reported healthy"

# --------------------------------------------------------------------------
# Firewall
#
# The step that can strand a remote administrator. The SSH allow rule is added
# before the firewall is enabled, never after, and the whole step is skippable.
# --------------------------------------------------------------------------

if [[ "$SKIP_FIREWALL" != "1" && "${RC_FIREWALL:-none}" != "none" ]]; then
  heading "== Firewall =="

  ports_to_open=("${RC_SSH_PORT}")
  case "${RC_MODE}" in
    public-tls|local-tls) ports_to_open+=("${RC_HTTP_PORT}" "${RC_HTTPS_PORT}") ;;
    plain-http)           ports_to_open+=("${RC_HTTP_PORT}") ;;
    behind-proxy)         ;;  # the operator's proxy owns the public ports
  esac

  log ""
  log "  These rules will be added, SSH first:"
  for p in "${ports_to_open[@]}"; do log "    allow ${p}/tcp"; done
  log ""
  warn "If SSH is not actually on port ${RC_SSH_PORT}, enabling the firewall will"
  warn "lock you out of this machine with no way back in over the network."

  if confirm_typed "Apply these firewall rules?" "yes"; then
    case "${RC_FIREWALL}" in
      ufw)
        # Order matters. The allow rule for SSH is added before enable, so
        # there is never a moment where the policy is default-deny without it.
        for p in "${ports_to_open[@]}"; do run ufw allow "${p}/tcp"; done
        if ufw status 2>/dev/null | grep -qi '^Status: active'; then
          ok "ufw was already active; rules added"
        else
          run_sh "ufw --force enable"
          ok "ufw enabled"
        fi
        log ""
        hint "to reverse: $(for p in "${ports_to_open[@]}"; do printf 'ufw delete allow %s/tcp; ' "$p"; done)"
        ;;
      firewalld)
        for p in "${ports_to_open[@]}"; do
          run firewall-cmd --permanent --add-port="${p}/tcp"
        done
        run firewall-cmd --reload
        ok "firewalld rules added"
        log ""
        hint "to reverse: $(for p in "${ports_to_open[@]}"; do printf 'firewall-cmd --permanent --remove-port=%s/tcp; ' "$p"; done)firewall-cmd --reload"
        ;;
    esac
  else
    warn "firewall left unchanged"
  fi
fi

# --------------------------------------------------------------------------
# Scheduling
# --------------------------------------------------------------------------

if [[ "$SKIP_SCHEDULE" != "1" && "${RC_SCHEDULE:-none}" != "none" ]]; then
  heading "== Scheduled jobs =="
  backup_hour="${RC_BACKUP_TIME%%:*}"
  backup_min="${RC_BACKUP_TIME##*:}"

  case "${RC_SCHEDULE}" in
    cron)
      run_write /etc/cron.d/rocketchat 644 <<EOF
# Rocket.Chat self-hosted stack. Managed by ${REPO_DIR}/scripts/setup.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Certificate renewal. Certbot only acts within 30 days of expiry, so twice
# daily is the documented cadence and costs nothing the rest of the time.
17 3,15 * * * root ${REPO_DIR}/scripts/renew-cert.sh >> ${RC_DATA_DIR}/renew.log 2>&1

# Daily backup.
${backup_min} ${backup_hour} * * * root ${REPO_DIR}/scripts/backup.sh >> ${RC_DATA_DIR}/backup.log 2>&1
EOF
      ok "cron entries written to /etc/cron.d/rocketchat"
      ;;

    systemd)
      run_write /etc/systemd/system/rocketchat-renew.service 644 <<EOF
[Unit]
Description=Renew the Rocket.Chat TLS certificate
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${REPO_DIR}/scripts/renew-cert.sh
EOF
      run_write /etc/systemd/system/rocketchat-renew.timer 644 <<EOF
[Unit]
Description=Renew the Rocket.Chat TLS certificate twice daily

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
      run_write /etc/systemd/system/rocketchat-backup.service 644 <<EOF
[Unit]
Description=Back up Rocket.Chat
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${REPO_DIR}/scripts/backup.sh
EOF
      run_write /etc/systemd/system/rocketchat-backup.timer 644 <<EOF
[Unit]
Description=Daily Rocket.Chat backup

[Timer]
OnCalendar=*-*-* ${backup_hour}:${backup_min}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
      run systemctl daemon-reload
      run systemctl enable --now rocketchat-renew.timer rocketchat-backup.timer
      ok "systemd timers installed and started"
      ;;
  esac
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

heading "== Health =="
"$SCRIPT_DIR/health-check.sh" || true

heading "== Done =="
cat >&2 <<EOF

  Rocket.Chat is at:   ${RC_ROOT_URL}

  Open that URL to create the first administrator account. Do it now: until an
  admin exists, the setup wizard is open to whoever reaches the server first.

  Configuration:       ${ENV_FILE}   (mode 600, contains credentials)
  Backups:             ${RC_BACKUP_DIR}
  Health check:        ${REPO_DIR}/scripts/health-check.sh
  Logs:                docker compose --env-file ${ENV_FILE} logs -f

EOF

if [[ "${RC_MODE}" == "behind-proxy" ]]; then
  # RC_BIND_ADDRESS says what to listen on; a proxy needs somewhere to connect
  # to, and 0.0.0.0 is not a destination. When bound to every interface the
  # right upstream is loopback for a proxy on this host, or this machine's LAN
  # address for one elsewhere.
  if [[ "${RC_BIND_ADDRESS}" == "0.0.0.0" ]]; then
    upstream_host="127.0.0.1"
    lan_ip="$(local_ips | head -1)"
  else
    upstream_host="${RC_BIND_ADDRESS}"
    lan_ip=""
  fi

  cat >&2 <<EOF
  Your proxy should forward to  http://${upstream_host}:${RC_APP_PORT}

  Caddy:
    ${RC_DOMAIN} {
        reverse_proxy ${upstream_host}:${RC_APP_PORT}
        request_body {
            max_size ${RC_MAX_UPLOAD_SIZE}
        }
    }

  nginx:
    location / {
        proxy_pass http://${upstream_host}:${RC_APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size ${RC_MAX_UPLOAD_SIZE};
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
    }

  The WebSocket upgrade headers are required; without them Rocket.Chat loads
  but never receives messages in realtime. The body size limit must match or
  exceed ${RC_MAX_UPLOAD_SIZE}, or uploads fail at your proxy before reaching
  this stack.

EOF
  if [[ -n "${lan_ip}" ]]; then
    cat >&2 <<EOF
  The snippets above assume your proxy runs on this machine. For a proxy on
  another host, use ${lan_ip}:${RC_APP_PORT} instead, and restrict that port at
  the firewall to your proxy's address: it carries unencrypted HTTP.

EOF
  fi
fi

if [[ "${RC_SCHEDULE:-none}" == "none" ]]; then
  warn "Nothing is scheduled to renew certificates or take backups."
  hint "Run scripts/renew-cert.sh twice daily and scripts/backup.sh daily."
fi

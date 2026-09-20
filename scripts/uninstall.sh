#!/usr/bin/env bash
# Removes this stack. Offers a final backup first, and separates "stop the
# containers" from "delete the data", because those are very different asks.
#
# Docker Engine itself is never removed: it was probably installed for
# something else, or is being used by something else right now.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -r "$ENV_FILE" ]] || die "no .env found at ${ENV_FILE}"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) die "usage: uninstall.sh [--dry-run]" ;;
  esac
done

cd "$REPO_DIR"
dc() { run docker compose --env-file "$ENV_FILE" "$@"; }

heading "== Uninstall =="
cat >&2 <<EOF

  This will stop and remove the Rocket.Chat containers for project
  '${COMPOSE_PROJECT_NAME}'.

  You will be asked separately about deleting data. Docker Engine is not
  removed.

EOF

confirm "Stop and remove the containers?" default_no || die "aborted; nothing changed"

# --- Final backup ---------------------------------------------------------

if confirm "Take a final backup first?" default_yes; then
  run "$SCRIPT_DIR/backup.sh" || warn "the backup failed; continuing was your choice to make"
fi

# --- Containers -----------------------------------------------------------

info "stopping and removing containers"
dc down --remove-orphans
ok "containers removed"

# --- Data -----------------------------------------------------------------

log ""
warn "The next step permanently deletes every message, account and uploaded"
warn "file in this instance. Backups in ${RC_BACKUP_DIR} are NOT touched."

if confirm_typed "Delete the database and all uploaded files?" "${RC_DOMAIN}"; then
  info "removing volumes"
  dc down -v --remove-orphans
  for path in "${RC_MONGO_PATH:-}" "${RC_MINIO_PATH:-}"; do
    if [[ "$path" == /* && -d "$path" ]]; then
      info "removing ${path}"
      run rm -rf "${path:?}"
    fi
  done
  ok "data removed"
else
  ok "data kept"
  hint "volumes remain; 'docker volume ls' will show them under ${COMPOSE_PROJECT_NAME}_"
fi

# --- Scheduled jobs -------------------------------------------------------

case "${RC_SCHEDULE:-none}" in
  cron)
    [[ -f /etc/cron.d/rocketchat ]] && { run rm -f /etc/cron.d/rocketchat; ok "cron entries removed"; }
    ;;
  systemd)
    if command -v systemctl >/dev/null 2>&1; then
      run systemctl disable --now rocketchat-renew.timer rocketchat-backup.timer 2>/dev/null || true
      run rm -f /etc/systemd/system/rocketchat-{renew,backup}.{service,timer}
      run systemctl daemon-reload
      ok "systemd timers removed"
    fi
    ;;
esac

# --- Firewall -------------------------------------------------------------
#
# Only ever offered, never automatic. The operator may have come to rely on
# these rules for something else by now.

if [[ "${RC_FIREWALL:-none}" != "none" ]]; then
  log ""
  hint "The firewall rules added at install time are still in place."
  hint "The SSH rule for port ${RC_SSH_PORT} is deliberately left alone."
  case "${RC_FIREWALL}" in
    ufw)
      hint "to remove the web rules:"
      hint "  ufw delete allow ${RC_HTTP_PORT}/tcp"
      [[ -n "${RC_HTTPS_PORT:-}" ]] && hint "  ufw delete allow ${RC_HTTPS_PORT}/tcp"
      ;;
    firewalld)
      hint "to remove the web rules:"
      hint "  firewall-cmd --permanent --remove-port=${RC_HTTP_PORT}/tcp"
      [[ -n "${RC_HTTPS_PORT:-}" ]] && hint "  firewall-cmd --permanent --remove-port=${RC_HTTPS_PORT}/tcp"
      hint "  firewall-cmd --reload"
      ;;
  esac
fi

# --- Install directory ----------------------------------------------------

log ""
if confirm "Remove the install directory ${REPO_DIR}?" default_no; then
  warn "this deletes .env, which holds the only copy of the MinIO credentials"
  if confirm_typed "Delete ${REPO_DIR}?" "${RC_DOMAIN}"; then
    cd /
    run rm -rf "${REPO_DIR:?}"
    ok "install directory removed"
  fi
fi

log ""
ok "uninstall complete"
hint "backups were left at ${RC_BACKUP_DIR}"

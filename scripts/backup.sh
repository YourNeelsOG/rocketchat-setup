#!/usr/bin/env bash
# Takes one backup snapshot: object storage, then the database, then config.
#
# On consistency. These two stores cannot be captured atomically without
# filesystem or volume snapshots, so the ordering is chosen to bias the
# inconsistency in the harmless direction:
#
#   objects first, database second
#
# A file uploaded between the two steps ends up with database metadata but no
# object, which is a broken attachment. Capturing in the other order produces
# an object with no metadata, which is invisible to users and harmless. The
# window is seconds to minutes; docs/BACKUP-RESTORE.md explains how to close
# it entirely if that matters.

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
    *) die "usage: backup.sh [--dry-run]" ;;
  esac
done

cd "$REPO_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${RC_BACKUP_DIR}/${STAMP}"

heading "== Backup ${STAMP} =="

avail="$(free_gb "${RC_BACKUP_DIR}")"
((avail >= 5)) || die "only ${avail} GB free at ${RC_BACKUP_DIR}; refusing to start a backup that would fill the disk"

run mkdir -p "${DEST}/minio" "${DEST}/config"
run chmod 700 "${DEST}"

# --- 1. Objects -----------------------------------------------------------
#
# Hardlinked against the previous snapshot so unchanged objects cost no extra
# space. Without this, every daily snapshot is a full copy of every file ever
# uploaded.

previous="$(find "${RC_BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -name '20*' 2>/dev/null | sort | tail -1 || true)"

info "copying objects from MinIO"
# The container runs as the invoking user, not root. Left as root, every
# mirrored object lands root-owned on the host, and an operator who is not root
# then cannot inspect, copy, or prune their own backups — and the retention
# step below fails silently for them. Fixing the ownership afterwards does not
# work either, since a non-root user cannot chown away from root. Writing the
# files correctly in the first place is the only version that holds.
#
# --config-dir keeps mc out of $HOME, which does not exist for an arbitrary uid.
run docker compose --env-file "$ENV_FILE" run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${DEST}/minio:/backup" \
  --entrypoint sh minio-init -c "
    mc --config-dir /tmp/mc alias set local http://minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null &&
    mc --config-dir /tmp/mc mirror --quiet --overwrite local/\"\$RC_MINIO_BUCKET\" /backup
  "

if [[ -n "$previous" && -d "$previous/minio" && "$DRY_RUN" != "1" ]]; then
  info "hardlinking objects unchanged since ${previous##*/}"
  # -c compares content; identical files collapse to one inode, so a snapshot
  # of mostly-unchanged objects costs almost nothing.
  if command -v hardlink >/dev/null 2>&1; then
    hardlink -c "$previous/minio" "${DEST}/minio" >/dev/null 2>&1 || true
  fi
fi
ok "objects captured"

# --- 2. Database ----------------------------------------------------------

info "dumping MongoDB"
# --quiet matters here: this runs daily from cron or a systemd timer, and
# mongodump's default output is one line per collection. Without it the backup
# log grows by several hundred lines a day and the warnings worth reading get
# buried.
run_sh "docker compose --env-file '${ENV_FILE}' exec -T mongodb \
  mongodump --uri='mongodb://mongodb:27017/?replicaSet=rs0' --archive --gzip --quiet \
  > '${DEST}/mongo.archive.gz'"

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -s "${DEST}/mongo.archive.gz" ]] || die "the MongoDB dump is empty; backup aborted and ${DEST} left for inspection"
fi
ok "database captured"

# --- 3. Configuration -----------------------------------------------------

info "copying configuration"
run cp -a "$ENV_FILE" "${DEST}/config/env"
run cp -a "${REPO_DIR}/compose.yml" "${DEST}/config/"
run cp -a "${REPO_DIR}/nginx" "${DEST}/config/"
[[ -d "${REPO_DIR}/certs" ]] && run cp -a "${REPO_DIR}/certs" "${DEST}/config/"
run chmod 600 "${DEST}/config/env"

run_write "${DEST}/MANIFEST" 600 <<EOF
snapshot          ${STAMP}
taken             $(date -Is)
rocketchat        ${RC_VERSION}
mongodb           ${RC_MONGODB_VERSION}
minio             ${RC_MINIO_VERSION}
domain            ${RC_DOMAIN}
mode              ${RC_MODE}
order             objects captured before database
EOF

# --- 4. Retention ---------------------------------------------------------
#
# Weekly snapshots are the Sunday ones, kept separately so that a long-running
# problem noticed late is still recoverable from before it started.

if [[ "$DRY_RUN" != "1" ]]; then
  mapfile -t snapshots < <(find "${RC_BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -name '20*' | sort -r)
  keep_daily="${RC_BACKUP_KEEP_DAILY:-7}"
  keep_weekly="${RC_BACKUP_KEEP_WEEKLY:-4}"
  kept_weekly=0
  for i in "${!snapshots[@]}"; do
    snap="${snapshots[$i]}"
    ((i < keep_daily)) && continue
    day="$(basename "$snap")"; day="${day%%-*}"
    if [[ "$(date -d "$day" +%u 2>/dev/null || echo 0)" == "7" ]] && ((kept_weekly < keep_weekly)); then
      kept_weekly=$((kept_weekly + 1))
      continue
    fi
    info "pruning ${snap##*/}"
    rm -rf "$snap"
  done
fi

size="$(du -sh "${DEST}" 2>/dev/null | cut -f1 || echo '?')"
ok "snapshot ${STAMP} complete (${size}) at ${DEST}"

log ""
warn "Local backups are not disaster recovery. A snapshot on the same machine"
warn "does not survive disk failure, theft, fire, or a mistaken rm -rf."
hint "Configure off-site copies; see docs/BACKUP-RESTORE.md. For example:"
hint "  rclone sync ${RC_BACKUP_DIR} remote:rocketchat-backups"

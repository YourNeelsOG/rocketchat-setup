#!/usr/bin/env bash
# Restores one snapshot: database and objects together, from the same capture.
#
# Rocket.Chat is stopped for the duration; MongoDB and MinIO stay up because
# both are being written to. Restoring only one of the two stores produces
# broken attachments, so both always come from the same snapshot directory.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -r "$ENV_FILE" ]] || die "no .env found at ${ENV_FILE}"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a

SNAPSHOT=''
while (($#)); do
  case "$1" in
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    *) die "usage: restore.sh [--snapshot NAME] [--dry-run]" ;;
  esac
done

cd "$REPO_DIR"
dc() { run docker compose --env-file "$ENV_FILE" "$@"; }

mapfile -t snapshots < <(find "${RC_BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -name '20*' 2>/dev/null | sort -r)
((${#snapshots[@]})) || die "no snapshots found in ${RC_BACKUP_DIR}"

if [[ -z "$SNAPSHOT" ]]; then
  heading "== Available snapshots =="
  for i in "${!snapshots[@]}"; do
    s="${snapshots[$i]}"
    printf '  %s%d)%s %s  %s\n' "$C_BOLD" "$((i + 1))" "$C_RESET" \
      "$(basename "$s")" "$(du -sh "$s" 2>/dev/null | cut -f1)" >&2
    [[ -r "$s/MANIFEST" ]] && sed 's/^/       /' "$s/MANIFEST" >&2
  done
  printf '%s?%s restore which snapshot? 1-%d ' "$C_BOLD" "$C_RESET" "${#snapshots[@]}" >&2
  read -r choice || die "input closed"
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#snapshots[@]})) \
    || die "not a valid selection"
  SRC="${snapshots[$((choice - 1))]}"
else
  SRC="${RC_BACKUP_DIR}/${SNAPSHOT}"
fi

[[ -d "$SRC" ]] || die "no such snapshot: ${SRC}"
[[ -s "$SRC/mongo.archive.gz" ]] || die "${SRC} has no database dump; it is not a complete snapshot"

heading "== Restore from $(basename "$SRC") =="
cat >&2 <<EOF

  This replaces the current contents of Rocket.Chat with the snapshot.

  Everything that happened after $(basename "$SRC") will be lost:
    - all messages sent since then
    - all files uploaded since then
    - all accounts created since then

  This cannot be undone.

EOF

confirm_typed "Restore this snapshot over the running instance?" "${RC_DOMAIN}" \
  || die "aborted; nothing was changed"

# A safety snapshot of the current state, so a mistaken restore is itself
# recoverable. This is the difference between an error and a disaster.
info "taking a safety backup of the current state first"
run "$SCRIPT_DIR/backup.sh"

info "stopping Rocket.Chat (the database and object store stay up)"
dc stop rocketchat

info "restoring the database"
run_sh "docker compose --env-file '${ENV_FILE}' exec -T mongodb \
  mongorestore --uri='mongodb://mongodb:27017/?replicaSet=rs0' --archive --gzip --drop \
  < '${SRC}/mongo.archive.gz'"

info "restoring objects"
# --remove deletes objects that are not in the snapshot. Without it, files
# uploaded after the snapshot survive as orphans that no database row points
# at, silently consuming space forever.
run docker compose --env-file "$ENV_FILE" run --rm \
  -v "${SRC}/minio:/backup:ro" \
  --entrypoint sh minio-init -c "
    mc alias set local http://minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null &&
    mc mirror --quiet --overwrite --remove /backup local/\"\$RC_MINIO_BUCKET\"
  "

info "starting Rocket.Chat"
dc start rocketchat

heading "== Verifying =="
"$SCRIPT_DIR/health-check.sh" || true

ok "restore complete"
hint "check a channel with file attachments, not just message history:"
hint "attachments are the part a partial restore breaks."

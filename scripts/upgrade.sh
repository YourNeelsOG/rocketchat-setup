#!/usr/bin/env bash
# Moves Rocket.Chat to a new version, with a backup first and a rollback path.
#
# Two rules are enforced rather than documented:
#   - the target must appear in Rocket.Chat's supported-versions feed
#   - major versions cannot be skipped; each one runs its own migrations

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -r "$ENV_FILE" ]] || die "no .env found at ${ENV_FILE}"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a

TARGET=''
SKIP_BACKUP=0
while (($#)); do
  case "$1" in
    --to)          TARGET="$2"; shift 2 ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    *) die "usage: upgrade.sh --to VERSION [--skip-backup] [--dry-run]" ;;
  esac
done

cd "$REPO_DIR"
dc() { run docker compose --env-file "$ENV_FILE" "$@"; }

CURRENT="${RC_VERSION}"
heading "== Upgrade =="
info "currently running ${CURRENT}"

if [[ -z "$TARGET" ]]; then
  "$SCRIPT_DIR/supported-versions.sh" || true
  TARGET="$(prompt_value TARGET 'Upgrade to which version?' '')"
fi

[[ "$TARGET" == "$CURRENT" ]] && { ok "already on ${CURRENT}"; exit 0; }

# --- Gate 1: is the target supported? -------------------------------------

sv=0
"$SCRIPT_DIR/supported-versions.sh" "$TARGET" >/dev/null 2>&1 || sv=$?
case "$sv" in
  0) ok "${TARGET} is in the supported-versions feed" ;;
  1) err "${TARGET} is not a currently supported release"
     "$SCRIPT_DIR/supported-versions.sh" || true
     confirm "Upgrade to an unsupported version anyway?" default_no || die "aborted" ;;
  *) warn "could not reach the supported-versions feed; proceeding without that check" ;;
esac

# --- Gate 2: major version stepping ---------------------------------------

cur_major="${CURRENT%%.*}"
new_major="${TARGET%%.*}"
if ((new_major > cur_major + 1)); then
  die "cannot upgrade from ${CURRENT} to ${TARGET} in one step.
      Each major version runs its own database migrations and expects to start
      from the one before it. Upgrade to $((cur_major + 1)).x first, let it
      start and finish migrating, then continue."
fi
if ((new_major < cur_major)); then
  warn "${TARGET} is older than ${CURRENT}. Rocket.Chat does not support"
  warn "downgrading across majors; the database schema has already migrated."
  confirm "Continue anyway?" default_no || die "aborted"
fi

# --- Backup ---------------------------------------------------------------

if [[ "$SKIP_BACKUP" != "1" ]]; then
  heading "-- Pre-upgrade backup --"
  run "$SCRIPT_DIR/backup.sh"
  SNAPSHOT="$(find "${RC_BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -name '20*' | sort | tail -1)"
  ok "snapshot at ${SNAPSHOT}"
else
  warn "skipping the pre-upgrade backup at your request"
  SNAPSHOT='(none taken)'
fi

# --- Pull then swap -------------------------------------------------------
#
# Images are pulled while the current version is still serving, so the outage
# is the restart rather than the download.

heading "-- Pulling ${TARGET} --"
run_sh "RC_VERSION='${TARGET}' docker compose --env-file '${ENV_FILE}' pull rocketchat"

heading "-- Switching --"
run_sh "sed -i 's/^RC_VERSION=.*/RC_VERSION=${TARGET}/' '${ENV_FILE}'"

# Rewriting the file is not enough. This script sourced .env at startup with
# `set -a`, so RC_VERSION is exported in this process, and an exported variable
# takes precedence over --env-file when compose resolves ${RC_VERSION}. Without
# this line the old image is redeployed and the upgrade silently does nothing.
export RC_VERSION="$TARGET"

# `up -d` recreates only what changed. A full `down` would stop the database
# and object store too, for no benefit and a longer outage.
dc up -d

heading "-- Waiting --"
if [[ "$DRY_RUN" != "1" ]]; then
  deadline=$((SECONDS + 900))
  while ((SECONDS < deadline)); do
    h="$(docker compose --env-file "$ENV_FILE" ps --format '{{.Health}}' rocketchat 2>/dev/null | head -1)"
    [[ "$h" == "healthy" ]] && break
    [[ "$h" == "unhealthy" ]] && break
    sleep 10
  done
fi

# `set +e` does not suppress the ERR trap that lib.sh installs, so the older
# `set +e; cmd; rc=$?; set -e` form aborted here on any non-zero exit. The `|| rc=$?`
# form is handled failure, which the trap correctly ignores.
hc=0
"$SCRIPT_DIR/health-check.sh" || hc=$?

# A healthy stack is not proof the upgrade happened: the old version is also
# healthy. Ask the running application what version it is and compare. This is
# the check that catches a swap which silently did nothing.
if [[ "$DRY_RUN" != "1" ]]; then
  running="$(docker compose --env-file "$ENV_FILE" exec -T rocketchat node -e '
    require("http").get("http://127.0.0.1:3000/api/info", r => {
      let b = ""; r.on("data", d => b += d);
      r.on("end", () => { try { console.log(JSON.parse(b).version || ""); } catch { console.log(""); } });
    }).on("error", () => console.log(""));
  ' 2>/dev/null | tr -d '\r\n')"

  # /api/info reports major.minor, so compare on that rather than the patch.
  if [[ -n "$running" ]] && [[ "${TARGET#"${running}"}" == "$TARGET" ]]; then
    err "the stack is healthy but still reports version ${running}, not ${TARGET}"
    hint "the running image is: $(docker compose --env-file "$ENV_FILE" ps rocketchat --format '{{.Image}}')"
    hint "check that RC_VERSION in ${ENV_FILE} is ${TARGET} and nothing in your shell exports an older value"
    hc=1
  elif [[ -n "$running" ]]; then
    ok "running version reports ${running}, consistent with ${TARGET}"
  else
    warn "could not read the running version from /api/info; not confirming the upgrade"
  fi
fi

if ((hc != 0)); then
  err "the upgrade to ${TARGET} did not come up healthy"
  cat >&2 <<EOF

  To roll back:

    sed -i 's/^RC_VERSION=.*/RC_VERSION=${CURRENT}/' ${ENV_FILE}
    docker compose --env-file ${ENV_FILE} up -d

  If the database was already migrated by ${TARGET}, rolling back the image is
  not enough and the snapshot must be restored as well:

    ${SCRIPT_DIR}/restore.sh --snapshot $(basename "${SNAPSHOT:-}")

  Application logs:
    docker compose --env-file ${ENV_FILE} logs --tail 100 rocketchat

EOF
  exit 1
fi

ok "upgraded ${CURRENT} to ${TARGET}"

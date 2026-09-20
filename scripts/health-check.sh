#!/usr/bin/env bash
# One-shot diagnostic. Exits non-zero if anything is wrong, so it also works as
# a cron or monitoring probe.

set -uo pipefail   # not -e: every check must run even when an earlier one fails
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
trap - ERR   # lib.sh installs an ERR trap; this script handles failures itself

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -r "$ENV_FILE" ]] || die "no .env found at ${ENV_FILE}"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a
cd "$REPO_DIR"

PROBLEMS=0
row() { printf '  %s %-18s %s\n' "$1" "$2" "$3" >&2; }
good() { row "${C_GREEN}[ok]${C_RESET}"   "$1" "$2"; }
bad()  { row "${C_RED}[!!]${C_RESET}"     "$1" "$2"; PROBLEMS=$((PROBLEMS + 1)); }
meh()  { row "${C_YELLOW}[..]${C_RESET}"  "$1" "$2"; }

heading "== Rocket.Chat health =="

# --- Docker and services --------------------------------------------------

if ! docker info >/dev/null 2>&1; then
  bad "Docker" "daemon not reachable"
  exit 1
fi
good "Docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"

expected=(mongodb nats minio rocketchat)
[[ "${RC_MODE}" != "behind-proxy" ]] && expected+=(nginx)

for svc in "${expected[@]}"; do
  state="$(docker compose --env-file "$ENV_FILE" ps --format '{{.State}}' "$svc" 2>/dev/null | head -1)"
  health="$(docker compose --env-file "$ENV_FILE" ps --format '{{.Health}}' "$svc" 2>/dev/null | head -1)"
  if [[ -z "$state" ]]; then
    bad "$svc" "not running"
  elif [[ "$health" == "unhealthy" ]]; then
    bad "$svc" "running but unhealthy"
  elif [[ "$state" == "running" ]]; then
    good "$svc" "running${health:+ (${health})}"
  else
    bad "$svc" "$state"
  fi
done

# --- Replica set ----------------------------------------------------------

rs="$(docker compose --env-file "$ENV_FILE" exec -T mongodb mongosh \
        'mongodb://mongodb:27017/?directConnection=true' --quiet \
        --eval 'const s=rs.status(); print(s.set + " " + s.members.length + " member(s) " + s.members[0].stateStr)' \
        2>/dev/null | tr -d '\r')"
[[ -n "$rs" ]] && good "replica set" "$rs" || bad "replica set" "could not query rs.status()"

# --- Application ----------------------------------------------------------

api="$(docker compose --env-file "$ENV_FILE" exec -T rocketchat node -e '
  require("http").get("http://127.0.0.1:3000/api/info", r => {
    let b = ""; r.on("data", d => b += d);
    r.on("end", () => { try { console.log(JSON.parse(b).version || "up"); } catch { console.log("up"); } });
  }).on("error", () => { console.log("down"); process.exit(1); });
' 2>/dev/null | tr -d '\r')"
[[ -n "$api" && "$api" != "down" ]] && good "Rocket.Chat API" "version ${api}" \
  || bad "Rocket.Chat API" "not responding on /api/info"

# --- Object storage -------------------------------------------------------

if docker compose --env-file "$ENV_FILE" exec -T minio \
     curl -fsS "http://127.0.0.1:9000/minio/health/live" >/dev/null 2>&1; then
  good "MinIO" "healthy"
else
  bad "MinIO" "health endpoint not responding"
fi

# --- Certificate ----------------------------------------------------------

case "${RC_MODE}" in
  public-tls)
    exp="$(docker compose --env-file "$ENV_FILE" run --rm --entrypoint sh certbot -c \
            "openssl x509 -noout -enddate -in /etc/letsencrypt/live/${RC_DOMAIN}/cert.pem 2>/dev/null" \
            2>/dev/null | sed 's/notAfter=//' | tr -d '\r')"
    if [[ -n "$exp" ]]; then
      days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
      if   ((days < 0));  then bad  "TLS certificate" "EXPIRED ${days#-} days ago"
      elif ((days < 14)); then bad  "TLS certificate" "expires in ${days} days; renewal is not working"
      elif ((days < 30)); then meh  "TLS certificate" "expires in ${days} days"
      else                     good "TLS certificate" "valid, ${days} days remaining"
      fi
    else
      bad "TLS certificate" "none found for ${RC_DOMAIN}"
    fi
    ;;
  local-tls)
    if [[ -s "${REPO_DIR}/certs/server.crt" ]]; then
      exp="$(openssl x509 -noout -enddate -in "${REPO_DIR}/certs/server.crt" | sed 's/notAfter=//')"
      days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
      ((days < 30)) && meh "TLS certificate" "self-signed, expires in ${days} days" \
                    || good "TLS certificate" "self-signed, ${days} days remaining"
    else
      bad "TLS certificate" "no self-signed certificate in ${REPO_DIR}/certs"
    fi
    ;;
  *) meh "TLS certificate" "not managed here (mode: ${RC_MODE})" ;;
esac

# --- DNS ------------------------------------------------------------------

if [[ "${RC_MODE}" == "public-tls" ]]; then
  mine="$(public_ip)"
  resolved="$(resolve_host "${RC_DOMAIN}")"
  if [[ -n "$mine" && -n "$resolved" ]]; then
    grep -qx "$mine" <<<"$resolved" \
      && good "DNS" "${RC_DOMAIN} points here" \
      || bad  "DNS" "${RC_DOMAIN} resolves elsewhere: $(tr '\n' ' ' <<<"$resolved")"
  else
    meh "DNS" "could not be checked"
  fi
fi

# --- Capacity -------------------------------------------------------------

for path in "${RC_DATA_DIR}" "$(docker_root)" "${RC_BACKUP_DIR}"; do
  avail="$(free_gb "$path")"
  if   ((avail < 5));  then bad  "disk" "${avail} GB free at ${path}"
  elif ((avail < 15)); then meh  "disk" "${avail} GB free at ${path}"
  else                      good "disk" "${avail} GB free at ${path}"
  fi
done

used_ram="$(awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} END{printf "%d of %d GB used", (t-a)/1048576, t/1048576}' /proc/meminfo)"
good "memory" "$used_ram"

# --- Backups --------------------------------------------------------------

latest="$(find "${RC_BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -name '20*' 2>/dev/null | sort | tail -1)"
if [[ -z "$latest" ]]; then
  # A fresh install legitimately has no backup yet, and failing here would make
  # setup.sh always end on a red line — which teaches people to ignore it. Give
  # the first day a pass, then treat it as the real problem it is.
  started="$(docker compose --env-file "$ENV_FILE" ps --format '{{.RunningFor}}' rocketchat 2>/dev/null | head -1)"
  if [[ "$started" == *second* || "$started" == *minute* || "$started" == *hour* ]]; then
    meh "backup" "none yet (new install) — run scripts/backup.sh"
  else
    bad "backup" "no snapshot has ever been taken"
  fi
else
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 3600 ))
  if   ((age_h > 48)); then bad  "backup" "newest snapshot is ${age_h} hours old"
  elif ((age_h > 26)); then meh  "backup" "newest snapshot is ${age_h} hours old"
  else                      good "backup" "$(basename "$latest") (${age_h}h ago)"
  fi
fi

# --- Advisory -------------------------------------------------------------

log ""
if ((PROBLEMS > 0)); then
  err "${PROBLEMS} problem(s) found; see docs/TROUBLESHOOTING.md"
  exit 1
fi
ok "everything looks healthy"

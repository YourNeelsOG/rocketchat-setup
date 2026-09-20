#!/usr/bin/env bash
# Everything that must be true before the stack is started, checked before
# anything on the host is changed.
#
# Reads .env, so run it after scripts/configure.sh. Also used by
# scripts/health-check.sh and safe to run at any time.
#
# Exit status: 0 all clear, 1 a hard failure, 3 warnings only.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -r "$ENV_FILE" ]] || die "no .env found at ${ENV_FILE}; run scripts/configure.sh first"
set -a; # shellcheck source=/dev/null
source "$ENV_FILE"; set +a

FAILURES=0
WARNINGS=0
fail() { err "$*"; FAILURES=$((FAILURES + 1)); }
soft() { warn "$*"; WARNINGS=$((WARNINGS + 1)); }

heading "== Preflight =="

# --- Docker ---------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed"
elif ! docker info >/dev/null 2>&1; then
  fail "the Docker daemon is not reachable (try: systemctl start docker)"
else
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') is running"
fi

if ! docker compose version >/dev/null 2>&1; then
  fail "the 'docker compose' plugin is missing (the standalone docker-compose v1 is not supported)"
else
  ok "compose plugin $(docker compose version --short 2>/dev/null || echo '?')"
fi

# --- Ports ----------------------------------------------------------------
#
# Checked again here because time passes between configuration and startup,
# and on a busy host something else may have taken the port in between.

check_port() {
  local port="$1" label="$2"
  [[ -z "$port" ]] && return 0
  if port_in_use "$port"; then
    # Our own containers holding the port is the expected state on a re-run.
    if docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"; then
      ok "${label} port ${port} is held by this stack"
    else
      fail "${label} port ${port} is in use by: $(port_holder "$port")"
    fi
  else
    ok "${label} port ${port} is free"
  fi
}

case "${RC_MODE:-}" in
  public-tls|local-tls)
    check_port "${RC_HTTP_PORT:-}"  "HTTP"
    check_port "${RC_HTTPS_PORT:-}" "HTTPS"
    ;;
  plain-http)   check_port "${RC_HTTP_PORT:-}" "HTTP" ;;
  behind-proxy) check_port "${RC_APP_PORT:-}"  "application" ;;
esac

# --- DNS ------------------------------------------------------------------
#
# Only meaningful for public-tls. A domain that does not resolve to this host
# is the most common cause of a failed certificate request, and Let's Encrypt
# limits failed validations to 5 per hostname per hour. Catching it here costs
# a second; discovering it during issuance costs an hour of waiting.

if [[ "${RC_MODE:-}" == "public-tls" ]]; then
  resolved="$(resolve_host "${RC_DOMAIN}")"
  if [[ -z "$resolved" ]]; then
    fail "${RC_DOMAIN} does not resolve; create the DNS record before requesting a certificate"
  else
    mine="$(public_ip)"
    if [[ -z "$mine" ]]; then
      soft "could not determine this host's public address; skipping the DNS match check"
      hint "${RC_DOMAIN} resolves to: $(tr '\n' ' ' <<<"$resolved")"
    elif grep -qx "$mine" <<<"$resolved"; then
      ok "${RC_DOMAIN} resolves to this host (${mine})"
    else
      fail "${RC_DOMAIN} resolves to $(tr '\n' ' ' <<<"$resolved") but this host's public address is ${mine}"
      hint "certificate issuance will fail until the DNS record points here"
      hint "if this host is behind NAT, forward ports 80 and 443 to it first"
    fi
  fi
fi

# --- Storage --------------------------------------------------------------

mongo_target="${RC_MONGO_PATH:-}"
[[ "$mongo_target" == /* ]] || mongo_target="$(docker_root)"
mongo_fs="$(fs_type "$mongo_target")"
case "$mongo_fs" in
  ntfs|fuseblk|exfat|msdos|vfat|cifs|smb2)
    fail "MongoDB data would live on a ${mongo_fs} filesystem (${mongo_target})"
    hint "that filesystem lacks the locking and atomic rename behaviour MongoDB needs"
    hint "the resulting corruption is silent; move the data path to ext4, xfs or btrfs"
    ;;
  unknown) soft "could not determine the filesystem type at ${mongo_target}" ;;
  *)       ok "MongoDB data path is on ${mongo_fs} (${mongo_target})" ;;
esac

# Thresholds differ by what each path actually holds. The install directory
# keeps the checkout and a couple of log files; the Docker root holds every
# volume, and the backup directory grows by roughly one full copy of the object
# store per retained snapshot. Applying the volume threshold to the install
# directory blocks a perfectly good layout where /opt is on a small root
# partition and the data lives on a larger mount.
check_space() {
  local target="$1" hard="$2" soft_limit="$3" what="$4" avail
  [[ -n "$target" ]] || return 0
  avail="$(free_gb "$target")"
  if ((avail < hard)); then
    fail "only ${avail} GB free at ${target} (${what} needs at least ${hard} GB)"
  elif ((avail < soft_limit)); then
    soft "${avail} GB free at ${target}; ${what} will consume this quickly"
  else
    ok "${avail} GB free at ${target}"
  fi
}

check_space "${RC_DATA_DIR:-/opt/rocketchat}" 2  5  "the checkout and logs"
check_space "$(docker_root)"                 10 20 "database and object volumes"
check_space "${RC_BACKUP_DIR:-}"             10 20 "backup snapshots"

# --- Memory ---------------------------------------------------------------

ram="$(total_ram_gb)"
upload_gb=$(( ${RC_MAX_UPLOAD_SIZE:-2147483648} / 1073741824 ))
if ((ram < 4)); then
  fail "${ram} GB of RAM; MongoDB, Rocket.Chat, NATS and MinIO together need more"
elif ((ram < 8)); then
  soft "${ram} GB of RAM; this works but leaves little headroom for large uploads"
else
  ok "${ram} GB of RAM"
fi
if ((upload_gb > 0)) && ((upload_gb * 2 > ram)); then
  soft "the ${upload_gb} GiB upload ceiling is large relative to ${ram} GB of RAM"
  hint "Rocket.Chat buffers uploads in the application; concurrent large transfers risk the OOM killer"
fi

# --- Docker namespace -----------------------------------------------------

if [[ -n "${RC_NETWORK_SUBNET:-}" ]]; then
  prefix="${RC_NETWORK_SUBNET%.*.*}"
  # Exclude this stack's own network: on any re-run it already holds the subnet
  # it was assigned, and reporting that as a collision is pure noise.
  own_net="${COMPOSE_PROJECT_NAME:-rocketchat}_backend"
  others="$(docker network ls --quiet --filter "name=." 2>/dev/null \
    | xargs -r docker network inspect \
        --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null \
    | grep -v "^${own_net} " | awk '{print $2}' || true)"
  if grep -q "^${prefix}\." <<<"$others"; then
    existing="$(docker network ls --format '{{.Name}}' | grep -v "^${own_net}$" | tr '\n' ' ')"
    soft "subnet ${RC_NETWORK_SUBNET} may overlap an existing Docker network"
    hint "networks present: ${existing}"
  else
    ok "subnet ${RC_NETWORK_SUBNET} does not collide with existing Docker networks"
  fi
fi

# --- Summary --------------------------------------------------------------

heading "-- Preflight summary --"
if ((FAILURES > 0)); then
  err "${FAILURES} blocking problem(s), ${WARNINGS} warning(s)"
  exit 1
elif ((WARNINGS > 0)); then
  warn "no blocking problems, ${WARNINGS} warning(s)"
  exit 3
else
  ok "all checks passed"
  exit 0
fi

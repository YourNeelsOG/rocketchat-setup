#!/usr/bin/env bash
# Entry point. Installs prerequisites, fetches the repository, and hands off to
# scripts/setup.sh.
#
# Deliberately small, so that reading it before running it is quick. It makes
# no deployment decisions of its own: every choice is collected by
# scripts/configure.sh, either interactively or from flags.
#
#   curl -fsSL https://raw.githubusercontent.com/YourNeelsOG/rocketchat-setup/main/install.sh -o install.sh
#   less install.sh
#   sudo bash install.sh
#
# Unrecognised flags are passed through to configure.sh, so an unattended
# install is one command:
#
#   sudo bash install.sh --non-interactive --mode public-tls \
#        --domain chat.example.com --letsencrypt-email admin@example.com

set -euo pipefail

REPO_URL="${RC_REPO_URL:-https://github.com/YourNeelsOG/rocketchat-setup.git}"
REPO_REF="${RC_REPO_REF:-main}"
DATA_DIR="/opt/rocketchat"
DRY_RUN=0
PASSTHROUGH=()

# lib.sh is not available until the repository is cloned, so this file carries
# its own minimal output helpers rather than depending on one.
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi
info() { printf '%s[ .. ]%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
run()  {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
  else
    "$@"
  fi
}

while (($#)); do
  case "$1" in
    --dry-run)  DRY_RUN=1; PASSTHROUGH+=("$1"); shift ;;
    --data-dir) DATA_DIR="$2"; PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    --ref)      REPO_REF="$2"; shift 2 ;;
    --repo)     REPO_URL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      printf '\nAll other flags are passed to scripts/configure.sh --help\n'
      exit 0 ;;
    *) PASSTHROUGH+=("$1"); shift ;;
  esac
done

cat >&2 <<EOF

${C_BOLD}Rocket.Chat self-hosted installer${C_RESET}

This installs a Rocket.Chat stack: Rocket.Chat, MongoDB, NATS, MinIO, and
optionally nginx with a TLS certificate.

It will, on this machine:
  - install docker, docker compose, git, openssl and curl if they are missing
  - enable the Docker daemon at boot
  - clone ${REPO_URL} into ${DATA_DIR}
  - ask you where and how to run, then start the stack

It will ask before touching the firewall, and it never writes a credential into
a file that is readable by anyone but root. Run with --dry-run to see every
command without executing any of them.

EOF

[[ "$DRY_RUN" == "1" ]] || [[ "$(id -u)" == "0" ]] \
  || die "this installer must run as root: sudo bash $0"

# --------------------------------------------------------------------------
# Distribution detection
#
# Keyed off /etc/os-release rather than which binaries exist, because several
# distributions ship compatibility shims for package managers they do not
# actually use.
# --------------------------------------------------------------------------

distro=unknown
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu|raspbian|linuxmint|pop) distro=debian ;;
    arch|manjaro|endeavouros|cachyos)     distro=arch ;;
    fedora|rhel|centos|rocky|almalinux)   distro=rhel ;;
    *) case " ${ID_LIKE:-} " in
         *debian*) distro=debian ;;
         *arch*)   distro=arch ;;
         *fedora*|*rhel*) distro=rhel ;;
       esac ;;
  esac
fi
[[ "$distro" == "unknown" ]] && die "unsupported distribution; install docker, docker compose, git, openssl and curl by hand, then run scripts/setup.sh"
ok "detected ${PRETTY_NAME:-$distro}"

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

missing=()
for cmd in git curl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
command -v docker >/dev/null 2>&1 || missing+=(docker)
docker compose version >/dev/null 2>&1 || missing+=(docker-compose-plugin)

if ((${#missing[@]})); then
  info "missing: ${missing[*]}"
  case "$distro" in
    debian)
      run apt-get update
      # Debian and Ubuntu both carry docker.io and docker-compose-v2 in their
      # own repositories now, which avoids adding a third-party apt source.
      run apt-get install -y git curl openssl ca-certificates docker.io docker-compose-v2
      ;;
    arch)
      run pacman -Sy --needed --noconfirm git curl openssl docker docker-compose
      ;;
    rhel)
      run dnf install -y git curl openssl docker podman-docker 2>/dev/null \
        || run dnf install -y git curl openssl moby-engine docker-compose
      ;;
  esac
else
  ok "all prerequisites already present"
fi

if ! docker compose version >/dev/null 2>&1; then
  die "the 'docker compose' plugin is still unavailable.
      The standalone docker-compose v1 is not supported: this stack relies on
      compose profiles and service_healthy dependencies, which v1 does not
      implement. Install the plugin from https://docs.docker.com/compose/install/
      and re-run."
fi

info "ensuring the Docker daemon is running and enabled at boot"
if command -v systemctl >/dev/null 2>&1; then
  run systemctl enable --now docker
else
  warn "no systemctl found; start the Docker daemon yourself before continuing"
fi

# --------------------------------------------------------------------------
# Fetch
# --------------------------------------------------------------------------

if [[ -d "$DATA_DIR/.git" ]]; then
  info "${DATA_DIR} is already a checkout; updating"
  run git -C "$DATA_DIR" fetch --depth 1 origin "$REPO_REF"
  run git -C "$DATA_DIR" checkout -q FETCH_HEAD
  ok "updated to the latest ${REPO_REF}"
  warn "this updated the code only; run scripts/upgrade.sh to move versions"
elif [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
  die "${DATA_DIR} exists and is not empty, and is not a checkout of this project.
      Refusing to overwrite it. Either remove it, or pass --data-dir with a
      different path. If this is an existing install, run:
        ${DATA_DIR}/scripts/setup.sh"
else
  info "cloning into ${DATA_DIR}"
  run git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$DATA_DIR"
  ok "cloned"
fi

run chmod +x "$DATA_DIR"/scripts/*.sh "$DATA_DIR/install.sh" 2>/dev/null || true

# --------------------------------------------------------------------------
# Hand off
# --------------------------------------------------------------------------

info "handing off to scripts/setup.sh"
if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$DATA_DIR/scripts/setup.sh ${PASSTHROUGH[*]:-}" >&2
  # Still run the configuration questions in dry-run, so the operator sees the
  # whole flow and the resulting plan without anything being changed.
  [[ -x "$DATA_DIR/scripts/configure.sh" ]] \
    && exec "$DATA_DIR/scripts/configure.sh" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
  exit 0
fi

cd "$DATA_DIR"
exec ./scripts/setup.sh ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}

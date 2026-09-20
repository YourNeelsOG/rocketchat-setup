#!/usr/bin/env bash
# Shared helpers: logging, prompting, option pickers, and dry-run command execution.
# Sourced by every other script. Not executable on its own.

# Guard against double-sourcing, which would reset counters and re-trap.
[[ -n "${RC_LIB_SOURCED:-}" ]] && return 0
RC_LIB_SOURCED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# Output
#
# Colour is disabled when stdout is not a terminal so that piping to a log file
# or to `less` does not fill it with escape sequences.
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_PURPLE=$'\033[35m'; C_CYAN=$'\033[36m'; C_WHITE=$'\033[37m'
  C_GRAD1=$'\033[38;2;0;255;255m'
  C_GRAD2=$'\033[38;2;0;210;255m'
  C_GRAD3=$'\033[38;2;0;170;255m'
  C_GRAD4=$'\033[38;2;60;130;255m'
  C_GRAD5=$'\033[38;2;120;90;255m'
  C_GRAD6=$'\033[38;2;170;60;255m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_PURPLE=''; C_CYAN=''; C_WHITE=''
  C_GRAD1=''; C_GRAD2=''; C_GRAD3=''; C_GRAD4=''; C_GRAD5=''; C_GRAD6=''
fi

print_signature() {
  printf '\n' >&2
  printf '  %s██╗   ██╗ ██████╗ ██╗   ██╗██████╗ ███╗   ██╗███████╗███████╗██╗     ███████╗%s\n' "$C_GRAD1" "$C_RESET" >&2
  printf '  %s╚██╗ ██╔╝██╔═══██╗██║   ██║██╔══██╗████╗  ██║██╔════╝██╔════╝██║     ██╔════╝%s\n' "$C_GRAD2" "$C_RESET" >&2
  printf '   %s╚████╔╝ ██║   ██║██║   ██║██████╔╝██╔██╗ ██║█████╗  █████╗  ██║     ███████╗%s\n' "$C_GRAD3" "$C_RESET" >&2
  printf '    %s╚██╔╝  ██║   ██║██║   ██║██╔══██╗██║╚██╗██║██╔══╝  ██╔══╝  ██║     ╚════██║%s\n' "$C_GRAD4" "$C_RESET" >&2
  printf '     %s██║   ╚██████╔╝╚██████╔╝██║  ██║██║ ╚████║███████╗███████╗███████╗███████║%s\n' "$C_GRAD5" "$C_RESET" >&2
  printf '     %s╚═╝    ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝╚══════╝╚══════╝%s\n' "$C_GRAD6" "$C_RESET" >&2
  printf '\n' >&2
  printf '                          %s%sPRESENT%s  %s%sROCKET CHAT SETUP%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_WHITE" "$C_RESET" >&2
  printf '\n' >&2
}

print_header_box() {
  local title="${1:-YOURNEELS}"
  local desc="${2:-Rocket.Chat Automated Production Wizard}"
  printf '  %s╭──────────────────────────────────────────────────────────────────────────╮%s\n' "$C_CYAN" "$C_RESET" >&2
  printf '  %s│%s  %s%-12s%s %s%-57s%s  %s│%s\n' \
    "$C_CYAN" "$C_RESET" "$C_BOLD$C_WHITE" "$title" "$C_RESET" "$C_DIM" "$desc" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
  printf '  %s╰──────────────────────────────────────────────────────────────────────────╯%s\n\n' "$C_CYAN" "$C_RESET" >&2
}

# All diagnostics go to stderr so that a function's stdout stays usable as a
# return value. prompt_* functions depend on this.
log()     { printf '%s\n' "$*" >&2; }
info()    { printf '%s[ .. ]%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
ok()      { printf '%s[ ok ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn()    { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf '%s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
heading() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
hint()    { printf '%s       %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

die() { err "$*"; exit 1; }

# Print the failing line number rather than leaving `set -e` silent.
_on_err() {
  local code=$? line=${BASH_LINENO[0]:-?} src=${BASH_SOURCE[1]:-?}
  err "aborted at ${src}:${line} (exit ${code})"
  exit "$code"
}
trap _on_err ERR

# ---------------------------------------------------------------------------
# Execution
#
# Every command with a side effect goes through run(). In dry-run mode it is
# printed and not executed, which is what makes the installer safe to inspect
# on a machine that is already doing a job.
# ---------------------------------------------------------------------------

# Exported so that a script invoking another script propagates the mode.
# Without this, a dry run would still let a child script write real files.
export DRY_RUN="${DRY_RUN:-0}"

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
    return 0
  fi
  "$@"
}

# Same as run(), but for a shell pipeline that has to be evaluated as one string.
run_sh() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$1" >&2
    return 0
  fi
  bash -c "$1"
}

# Write a file, honouring dry-run. Content arrives on stdin.
run_write() {
  local path="$1" mode="${2:-644}"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would write:%s %s (mode %s)\n' "$C_DIM" "$C_RESET" "$path" "$mode" >&2
    cat >/dev/null
    return 0
  fi
  install -m "$mode" /dev/null "$path"
  cat >"$path"
}

# ---------------------------------------------------------------------------
# Prompting
#
# ASSUME_YES makes every prompt take its default without blocking, which is how
# --non-interactive works. Any question that has no safe default must call
# require_answer() instead so an unattended run fails loudly rather than
# guessing.
# ---------------------------------------------------------------------------

# Exported for the same reason as DRY_RUN above.
export ASSUME_YES="${ASSUME_YES:-0}"

require_answer() {
  local name="$1"
  [[ "$ASSUME_YES" == "1" ]] || return 0
  die "--non-interactive was given but ${name} has no value and no safe default. Pass --${name//_/-}."
}

# prompt_value <varname> <question> [default] [validator_fn]
# Echoes the answer on stdout. Re-asks until the validator accepts.
prompt_value() {
  local __var="$1" question="$2" default="${3:-}" validator="${4:-}"
  local preset="${!__var:-}" answer

  # A value already supplied by flag or config file wins and is not re-asked.
  if [[ -n "$preset" ]]; then
    if [[ -n "$validator" ]] && ! "$validator" "$preset"; then
      die "invalid value for ${__var}: ${preset}"
    fi
    printf '%s' "$preset"
    return 0
  fi

  if [[ "$ASSUME_YES" == "1" ]]; then
    [[ -n "$default" ]] || require_answer "$__var"
    printf '%s' "$default"
    return 0
  fi

  while true; do
    if [[ -n "$default" ]]; then
      printf '%s?%s %s %s[%s]%s ' "$C_BOLD" "$C_RESET" "$question" "$C_DIM" "$default" "$C_RESET" >&2
    else
      printf '%s?%s %s ' "$C_BOLD" "$C_RESET" "$question" >&2
    fi
    read -r answer || die "input closed"
    answer="${answer:-$default}"
    [[ -z "$answer" ]] && { warn "a value is required"; continue; }
    if [[ -n "$validator" ]] && ! "$validator" "$answer"; then continue; fi
    printf '%s' "$answer"
    return 0
  done
}

# prompt_secret <varname> <question>
# Same as prompt_value but does not echo the typed characters.
prompt_secret() {
  local __var="$1" question="$2" preset="${!__var:-}" answer
  if [[ -n "$preset" ]]; then printf '%s' "$preset"; return 0; fi
  if [[ "$ASSUME_YES" == "1" ]]; then printf ''; return 0; fi
  printf '%s?%s %s ' "$C_BOLD" "$C_RESET" "$question" >&2
  read -rs answer || die "input closed"
  printf '\n' >&2
  printf '%s' "$answer"
}

# confirm <question> [default_yes|default_no]
confirm() {
  local question="$1" default="${2:-default_no}" answer
  if [[ "$ASSUME_YES" == "1" ]]; then
    [[ "$default" == "default_yes" ]] && return 0 || return 1
  fi
  local hint_text='y/N'
  [[ "$default" == "default_yes" ]] && hint_text='Y/n'
  while true; do
    printf '%s?%s %s %s[%s]%s ' "$C_BOLD" "$C_RESET" "$question" "$C_DIM" "$hint_text" "$C_RESET" >&2
    read -r answer || die "input closed"
    answer="${answer:-}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      '')    [[ "$default" == "default_yes" ]] && return 0 || return 1 ;;
      *)     warn "answer y or n" ;;
    esac
  done
}

# confirm_typed <question> <expected>
# For the irreversible steps. Requires the exact string, so a reflexive "y"
# cannot destroy data or enable a firewall that locks the admin out.
confirm_typed() {
  local question="$1" expected="$2" answer
  if [[ "$ASSUME_YES" == "1" ]]; then
    warn "--non-interactive: auto-confirming '${expected}'"
    return 0
  fi
  printf '%s?%s %s\n  type %s%s%s to confirm: ' \
    "$C_BOLD" "$C_RESET" "$question" "$C_BOLD" "$expected" "$C_RESET" >&2
  read -r answer || die "input closed"
  [[ "$answer" == "$expected" ]]
}

# pick <varname> <question> <label1> <value1> [<label2> <value2> ...]
# Numbered single-choice picker. Echoes the chosen value on stdout.
# The first option is the default.
pick() {
  local __var="$1" question="$2"; shift 2
  local labels=() values=() i answer
  while (($# >= 2)); do labels+=("$1"); values+=("$2"); shift 2; done
  ((${#values[@]})) || die "pick: no options given for ${__var}"

  local preset="${!__var:-}"
  if [[ -n "$preset" ]]; then
    for i in "${!values[@]}"; do
      [[ "${values[$i]}" == "$preset" ]] && { printf '%s' "$preset"; return 0; }
    done
    die "invalid value for ${__var}: '${preset}' (expected one of: ${values[*]})"
  fi

  if [[ "$ASSUME_YES" == "1" ]]; then printf '%s' "${values[0]}"; return 0; fi

  local q_line="╭─ ${question} "
  local target_len=76
  local rem=$((target_len - ${#q_line} - 1))
  if ((rem < 3)); then rem=3; fi
  local bar=""
  printf -v bar '%*s' "$rem" ''
  bar="${bar// /─}"
  printf '  %s%s%s╮%s\n' "$C_CYAN" "$q_line" "$bar" "$C_RESET" >&2
  for i in "${!labels[@]}"; do
    printf '    %s[%d]%s  %s%s%s' "$C_CYAN$C_BOLD" "$((i + 1))" "$C_RESET" "$C_BOLD$C_WHITE" "${labels[$i]}" "$C_RESET" >&2
    if ((i == 0)); then
      printf ' %s(default)%s\n' "$C_DIM" "$C_RESET" >&2
    else
      printf '\n' >&2
    fi
  done
  printf '  %s╰──────────────────────────────────────────────────────────────────────────╯%s\n\n' "$C_CYAN" "$C_RESET" >&2
  while true; do
    printf '  %sSelect option%s %s➜%s ' "$C_BOLD$C_WHITE" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
    read -r answer || die "input closed"
    answer="${answer:-1}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#values[@]})); then
      printf '%s' "${values[$((answer - 1))]}"
      return 0
    fi
    warn "Please enter a valid option number between 1 and ${#labels[@]}"
  done
}

# ---------------------------------------------------------------------------
# Validators
# Each takes one argument, returns 0 if acceptable, and explains itself on
# stderr if not, so prompt_value can simply re-ask.
# ---------------------------------------------------------------------------

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)) && return 0
  warn "'$1' is not a port number between 1 and 65535"; return 1
}

valid_hostname() {
  # Accepts a DNS name or a bare IPv4 address. Local deployments legitimately
  # use an IP or a single-label .local name, so this is deliberately loose.
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && ((${#1} <= 253)) && return 0
  warn "'$1' is not a usable hostname or IP address"; return 1
}

valid_fqdn() {
  # Let's Encrypt needs a name with at least one dot and a real TLD.
  valid_hostname "$1" || return 1
  [[ "$1" == *.* ]] && [[ ! "$1" =~ ^[0-9.]+$ ]] && return 0
  warn "'$1' must be a fully qualified domain name for a public certificate"; return 1
}

valid_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && return 0
  warn "'$1' is not a valid email address"; return 1
}

valid_abspath() {
  [[ "$1" == /* ]] && return 0
  warn "'$1' must be an absolute path"; return 1
}

valid_bytes() {
  [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1048576)) && return 0
  warn "'$1' must be a byte count of at least 1048576 (1 MiB)"; return 1
}

valid_project_name() {
  # Compose restricts project names to lowercase alphanumerics, dashes and
  # underscores, and they must start with a letter or digit.
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] && return 0
  warn "'$1' must be lowercase letters, digits, dashes or underscores"; return 1
}

valid_hhmm() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && return 0
  warn "'$1' must be a time in 24-hour HH:MM form"; return 1
}

# ---------------------------------------------------------------------------
# System probes
#
# These exist so the installer can adapt to a machine that is already running
# something, rather than assuming a fresh box.
# ---------------------------------------------------------------------------

# Prefer `ss`, fall back to a bind attempt. `lsof` and `netstat` are frequently
# absent on minimal server images, so neither is relied on.
port_in_use() {
  local port="$1"
  [[ -z "$port" ]] && return 1
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
    return 1
  fi
  python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(0)   # in use
finally:
    s.close()
sys.exit(1)       # free
PY
}

# Names what is holding a port, when the tooling can tell us. Best effort:
# this needs root and a recent `ss` to return anything useful.
port_holder() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || { printf 'unknown'; return; }
  local out
  out="$(ss -Hltnp "sport = :${port}" 2>/dev/null | head -1 || true)"
  if [[ "$out" =~ users:\(\(\"([^\"]+)\" ]]; then printf '%s' "${BASH_REMATCH[1]}"
  else printf 'unknown'; fi
}

# Returns the first free port at or above the given one, so the installer can
# offer a working alternative instead of just reporting a conflict.
next_free_port() {
  local port="$1" limit="${2:-200}" i
  for ((i = 0; i < limit; i++)); do
    port_in_use "$((port + i))" || { printf '%d' "$((port + i))"; return 0; }
  done
  return 1
}

# The port sshd is actually listening on. Reads the config rather than guessing
# 22, because locking out an admin who moved SSH is the worst failure this
# installer can cause.
detect_ssh_port() {
  local port=''
  if [[ -r /etc/ssh/sshd_config ]]; then
    port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  fi
  if [[ -z "$port" ]] && command -v ss >/dev/null 2>&1; then
    port="$(ss -Hltnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}' || true)"
  fi
  printf '%s' "${port:-22}"
}

# Which firewall is actually managing this host. An existing server often
# already has rules that must not be trampled.
detect_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    printf 'ufw-active'
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
    printf 'firewalld-active'
  elif command -v ufw >/dev/null 2>&1; then
    printf 'ufw-available'
  elif command -v firewall-cmd >/dev/null 2>&1; then
    printf 'firewalld-available'
  else
    printf 'none'
  fi
}

# MongoDB 8.0+ segfaults on Linux 6.19 and newer unless glibc is given rseq.
# Returns the tunable string to set, or empty on kernels that do not need it.
# See the mongodb service in compose.yml for the full explanation.
mongo_glibc_tunable() {
  local release major minor
  release="$(uname -r)"
  [[ "$release" =~ ^([0-9]+)\.([0-9]+) ]] || { printf ''; return; }
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
  if ((major > 6)) || { ((major == 6)) && ((minor >= 19)); }; then
    printf 'glibc.pthread.rseq=1'
  else
    printf ''
  fi
}

detect_distro() {
  [[ -r /etc/os-release ]] || { printf 'unknown'; return; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu|raspbian|linuxmint|pop) printf 'debian' ;;
    arch|manjaro|endeavouros|cachyos)     printf 'arch' ;;
    fedora|rhel|centos|rocky|almalinux)   printf 'rhel' ;;
    *)
      case " ${ID_LIKE:-} " in
        *debian*) printf 'debian' ;;
        *arch*)   printf 'arch' ;;
        *fedora*|*rhel*) printf 'rhel' ;;
        *)        printf 'unknown' ;;
      esac ;;
  esac
}

# Filesystem type of the nearest existing ancestor of a path. The path itself
# may not exist yet at the time this is called.
fs_type() {
  local path="$1"
  while [[ ! -e "$path" && "$path" != '/' ]]; do path="$(dirname "$path")"; done
  stat -f -c %T "$path" 2>/dev/null || printf 'unknown'
}

free_gb() {
  local path="$1"
  while [[ ! -e "$path" && "$path" != '/' ]]; do path="$(dirname "$path")"; done
  df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9' || printf '0'
}

total_ram_gb() {
  awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || printf '0'
}

# Docker's own data root, which is where named volumes live and therefore the
# path that actually runs out of space. It is often on a different filesystem
# from the install directory.
docker_root() {
  docker info --format '{{.DockerRootDir}}' 2>/dev/null || printf '/var/lib/docker'
}

# Subnets already in use by existing Docker networks, so a new network can be
# placed somewhere that does not collide on a host already running containers.
docker_used_subnets() {
  docker network ls --quiet 2>/dev/null \
    | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^[0-9]+\.' || true
}

# Picks a /24 in the 172.16/12 space that no existing network occupies.
free_docker_subnet() {
  local used third candidate
  used="$(docker_used_subnets)"
  for third in $(seq 20 250); do
    candidate="172.${third}.0.0/24"
    grep -qF "172.${third}." <<<"$used" || { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# Does a compose project of this name already exist on the host?
compose_project_exists() {
  docker ps -aq --filter "label=com.docker.compose.project=$1" 2>/dev/null | grep -q .
}

# Resolve a hostname without depending on `dig`, which is absent from many
# minimal images. getent uses the system resolver, which is what certbot's
# validation will effectively be compared against anyway.
resolve_host() {
  getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u || true
}

public_ip() {
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null \
    || true
}

local_ips() {
  ip -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' || true
}

#!/usr/bin/env bash
# Collects every deployment decision from flags, a config file, or the terminal,
# and writes the resulting .env.
#
# Nothing in this stack is hardcoded to a fresh, public, internet-facing box.
# Ports, paths, TLS strategy, firewall handling and Docker naming are all
# negotiated with the operator, because the common case is a machine that is
# already running something.
#
# Precedence, highest first:  command-line flag  >  --config file  >  prompt  >  default

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

usage() {
  cat <<'EOF'
Usage: configure.sh [options]

Deployment
  --mode MODE                public-tls | local-tls | behind-proxy | plain-http
  --domain NAME              Domain or hostname clients will use
  --letsencrypt-email ADDR   Contact address for certificate notices (public-tls)
  --staging-certs            Use the Let's Encrypt staging endpoint (no rate limit cost)
  --accept-no-tls            Required with --non-interactive --mode plain-http

Networking
  --http-port N              Host port for HTTP            (default 80)
  --https-port N             Host port for HTTPS           (default 443)
  --app-port N               Host port for Rocket.Chat     (behind-proxy / plain-http)
  --bind-address ADDR        Address to publish on         (default 0.0.0.0)
  --network-subnet CIDR      Docker network subnet         (default: first free /24)

Storage
  --data-dir PATH            Install root                  (default /opt/rocketchat)
  --mongo-path PATH          Host path for MongoDB data    (default: named volume)
  --minio-path PATH          Host path for MinIO objects   (default: named volume)
  --backup-dir PATH          Backup root                   (default DATA_DIR/backups)
  --max-upload-size BYTES    Upload ceiling                (default 2147483648)

Stack
  --project-name NAME        Compose project name          (default rocketchat)
  --rc-version VERSION       Rocket.Chat version           (default 8.5.3)
  --rc-license KEY           Rocket.Chat license key       (optional)
  --reg-token TOKEN          Cloud registration token      (optional)

Host integration
  --firewall MODE            ufw | firewalld | none        (default: autodetect)
  --ssh-port N               SSH port to keep open         (default: autodetect)
  --schedule MODE            cron | systemd | none         (default: autodetect)
  --backup-time HH:MM        Daily backup time             (default 03:00)

Behaviour
  --config FILE              Read answers from FILE first
  --non-interactive, --yes   Never prompt; use flags and defaults
  --dry-run                  Print what would happen, change nothing
  -h, --help                 This message
EOF
}

# ---------------------------------------------------------------------------
# Flag parsing
#
# Every prompt below has a matching flag, so an interactive run and an
# automated one can produce byte-identical configuration.
# ---------------------------------------------------------------------------

CONFIG_FILE=''
declare -A CLI=()

while (($#)); do
  case "$1" in
    --mode)              CLI[RC_MODE]="$2"; shift 2 ;;
    --domain)            CLI[RC_DOMAIN]="$2"; shift 2 ;;
    --letsencrypt-email) CLI[RC_LE_EMAIL]="$2"; shift 2 ;;
    --staging-certs)     CLI[RC_LE_STAGING]=1; shift ;;
    --accept-no-tls)     CLI[RC_ACCEPT_NO_TLS]=1; shift ;;
    --http-port)         CLI[RC_HTTP_PORT]="$2"; shift 2 ;;
    --https-port)        CLI[RC_HTTPS_PORT]="$2"; shift 2 ;;
    --app-port)          CLI[RC_APP_PORT]="$2"; shift 2 ;;
    --bind-address)      CLI[RC_BIND_ADDRESS]="$2"; shift 2 ;;
    --network-subnet)    CLI[RC_NETWORK_SUBNET]="$2"; shift 2 ;;
    --data-dir)          CLI[RC_DATA_DIR]="$2"; shift 2 ;;
    --mongo-path)        CLI[RC_MONGO_PATH]="$2"; shift 2 ;;
    --minio-path)        CLI[RC_MINIO_PATH]="$2"; shift 2 ;;
    --backup-dir)        CLI[RC_BACKUP_DIR]="$2"; shift 2 ;;
    --max-upload-size)   CLI[RC_MAX_UPLOAD_SIZE]="$2"; shift 2 ;;
    --project-name)      CLI[RC_PROJECT_NAME]="$2"; shift 2 ;;
    --rc-version)        CLI[RC_VERSION]="$2"; shift 2 ;;
    --rc-license)        CLI[RC_LICENSE]="$2"; shift 2 ;;
    --reg-token)         CLI[RC_REG_TOKEN]="$2"; shift 2 ;;
    --firewall)          CLI[RC_FIREWALL]="$2"; shift 2 ;;
    --ssh-port)          CLI[RC_SSH_PORT]="$2"; shift 2 ;;
    --schedule)          CLI[RC_SCHEDULE]="$2"; shift 2 ;;
    --backup-time)       CLI[RC_BACKUP_TIME]="$2"; shift 2 ;;
    --config)            CONFIG_FILE="$2"; shift 2 ;;
    --non-interactive|--yes) ASSUME_YES=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   usage >&2; die "unknown option: $1" ;;
  esac
done

# A config file seeds values; flags then override them.
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -r "$CONFIG_FILE" ]] || die "cannot read config file: $CONFIG_FILE"
  set -a; # shellcheck source=/dev/null
  source "$CONFIG_FILE"; set +a
  ok "loaded answers from $CONFIG_FILE"
fi
for k in "${!CLI[@]}"; do printf -v "$k" '%s' "${CLI[$k]}"; export "${k?}"; done

# ---------------------------------------------------------------------------
# Section 1: deployment mode
# ---------------------------------------------------------------------------

clear 2>/dev/null || true
print_signature
print_header_box "YOURNEELS" "Rocket.Chat Automated Production Wizard"

RC_MODE="$(pick RC_MODE 'Select deployment mode:' \
  'Local / LAN server (Tailscale or local network, self-signed TLS)' 'local-tls' \
  'Plain HTTP (No SSL, ideal for private Tailscale/LAN, no CA needed)' 'plain-http' \
  'Public server (Real domain with automatic Let'"'"'s Encrypt certificate)' 'public-tls' \
  'Behind an existing reverse proxy (Caddy, Nginx Proxy Manager, Traefik)' 'behind-proxy')"

case "$RC_MODE" in
  public-tls)
    hint "Requires a public IP and a DNS record pointing to this host."
    ;;
  local-tls)
    hint "Self-signed certificate will be created. CA cert saved to certs/ca.crt."
    ;;
  behind-proxy)
    hint "Publishes on a local port for your proxy to forward to."
    ;;
  plain-http)
    hint "No TLS overhead. Ideal for private VPNs like Tailscale."
    ;;
esac

# ---------------------------------------------------------------------------
# Section 2: identity
# ---------------------------------------------------------------------------

heading "-- Address & Hostname --"

if [[ "$RC_MODE" == "public-tls" ]]; then
  RC_DOMAIN="$(prompt_value RC_DOMAIN 'Enter domain name (e.g. chat.yourdomain.com)' '' valid_fqdn)"
  RC_LE_EMAIL="$(prompt_value RC_LE_EMAIL 'Email address for Let'"'"'s Encrypt certificate' '' valid_email)"
else
  # Collect available IP choices (Tailscale IP, LAN IP, localhost)
  ips_available=()
  ip_picker_args=()

  # Check for tailscale IP
  ts_ip="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null || true)"
  if [[ -n "$ts_ip" ]]; then
    ip_picker_args+=("Tailscale IP (${ts_ip}) — for devices in your Tailscale mesh" "$ts_ip")
  fi

  # Check for LAN IP
  for lip in $(local_ips); do
    [[ "$lip" == "$ts_ip" ]] && continue
    ip_picker_args+=("LAN IP (${lip}) — for local Wi-Fi / LAN devices" "$lip")
    break
  done

  default_host="$(hostname -s 2>/dev/null || echo localhost)"
  ip_picker_args+=(
    "Local machine only (127.0.0.1 / localhost)" "127.0.0.1"
    "Custom hostname or domain (e.g. rocket.neels)" "custom"
  )

  if [[ -z "${RC_DOMAIN:-}" ]]; then
    chosen_addr="$(pick RC_CHOSEN_ADDR 'How do you want to access Rocket.Chat?' "${ip_picker_args[@]}")"
    if [[ "$chosen_addr" == "custom" ]]; then
      RC_DOMAIN="$(prompt_value RC_DOMAIN 'Enter custom hostname or domain' "$default_host" valid_hostname)"
    else
      RC_DOMAIN="$chosen_addr"
    fi
  else
    RC_DOMAIN="$(prompt_value RC_DOMAIN 'Hostname or IP clients will use' "$RC_DOMAIN" valid_hostname)"
  fi
  RC_LE_EMAIL="${RC_LE_EMAIL:-}"
fi

# ---------------------------------------------------------------------------
# Section 3: ports & binding
# ---------------------------------------------------------------------------

if [[ "$RC_MODE" == "behind-proxy" ]]; then
  RC_BIND_ADDRESS="${RC_BIND_ADDRESS:-127.0.0.1}"
else
  RC_BIND_ADDRESS="${RC_BIND_ADDRESS:-0.0.0.0}"
fi

# Offers the next free port when the wanted one is taken, and names the holder.
choose_port() {
  local var="$1" question="$2" want="$3" chosen holder alt
  chosen="$(prompt_value "$var" "$question" "$want" valid_port)" || exit 1
  while port_in_use "$chosen"; do
    holder="$(port_holder "$chosen")"
    warn "port ${chosen} is already in use by: ${holder}"
    alt="$(next_free_port "$((chosen + 1))" || true)"
    if [[ "$ASSUME_YES" == "1" ]]; then
      die "port ${chosen} is in use and --non-interactive cannot choose another; pass a free port explicitly"
    fi
    printf -v "$var" '%s' ''
    chosen="$(prompt_value "$var" "  pick a different port for ${question,,}" "${alt:-}" valid_port)" || exit 1
  done
  printf '%s' "$chosen"
}

case "$RC_MODE" in
  public-tls|local-tls)
    RC_HTTP_PORT="$(choose_port RC_HTTP_PORT 'HTTP port' 80)"
    RC_HTTPS_PORT="$(choose_port RC_HTTPS_PORT 'HTTPS port' 443)"
    RC_APP_PORT=''
    if [[ "$RC_MODE" == "public-tls" && "$RC_HTTP_PORT" != "80" ]]; then
      die "Let's Encrypt HTTP-01 validation always connects to port 80 on the public address.
      Port 80 is taken here, so automatic certificates cannot work as configured.
      Either free port 80, or choose the behind-proxy mode and let the existing
      service on port 80 forward the ACME challenge to this stack."
    fi
    ;;
  plain-http)
    RC_HTTP_PORT="$(choose_port RC_HTTP_PORT 'HTTP port' 80)"
    RC_HTTPS_PORT=''
    RC_APP_PORT=''
    ;;
  behind-proxy)
    RC_HTTP_PORT=''; RC_HTTPS_PORT=''
    RC_APP_PORT="$(choose_port RC_APP_PORT 'Host port to publish Rocket.Chat on' 3000)"
    ;;
esac

# ---------------------------------------------------------------------------
# Section 4: Docker namespace
#
# A host that already runs containers can collide on project name, container
# names, or network subnet. All three are checked.
# ---------------------------------------------------------------------------

heading "-- Docker --"

RC_PROJECT_NAME="$(prompt_value RC_PROJECT_NAME 'Compose project name' 'rocketchat' valid_project_name)"
while compose_project_exists "$RC_PROJECT_NAME"; do
  warn "a compose project named '${RC_PROJECT_NAME}' already has containers on this host"
  hint "reusing the name would adopt or replace them; a different name keeps them separate"
  if [[ "$ASSUME_YES" == "1" ]]; then
    die "project name '${RC_PROJECT_NAME}' is taken; pass --project-name with a free name"
  fi
  if confirm "Reuse '${RC_PROJECT_NAME}' anyway (existing containers may be replaced)?" default_no; then
    break
  fi
  RC_PROJECT_NAME=''
  RC_PROJECT_NAME="$(prompt_value RC_PROJECT_NAME 'Compose project name' '' valid_project_name)"
done

if [[ -z "${RC_NETWORK_SUBNET:-}" ]]; then
  suggested="$(free_docker_subnet || echo '172.28.0.0/24')"
  RC_NETWORK_SUBNET="$(prompt_value RC_NETWORK_SUBNET 'Subnet for this stack'"'"'s Docker network' "$suggested")"
fi

# ---------------------------------------------------------------------------
# Section 5: storage
#
# Named volumes are the default, but an operator with a dedicated data disk
# needs to put MongoDB and MinIO somewhere specific. Whichever is chosen gets
# the filesystem check, not just the install directory.
# ---------------------------------------------------------------------------

heading "-- Storage --"

RC_DATA_DIR="$(prompt_value RC_DATA_DIR 'Install directory' '/opt/rocketchat' valid_abspath)"

storage_choice="$(pick RC_STORAGE_CHOICE 'Where should MongoDB and uploaded files live?' \
  "Docker named volumes (under $(docker_root))" 'volumes' \
  'A directory I choose (a dedicated disk, for example)' 'hostpath')"

if [[ "$storage_choice" == "hostpath" ]]; then
  RC_MONGO_PATH="$(prompt_value RC_MONGO_PATH 'Directory for MongoDB data' "$RC_DATA_DIR/data/mongo" valid_abspath)"
  RC_MINIO_PATH="$(prompt_value RC_MINIO_PATH 'Directory for uploaded files' "$RC_DATA_DIR/data/minio" valid_abspath)"
else
  RC_MONGO_PATH=''; RC_MINIO_PATH=''
fi

# MongoDB's storage engine needs POSIX file locking and rename semantics that
# FUSE-mounted Windows filesystems do not provide reliably. Corruption from
# this is silent, so it is a hard stop rather than a warning.
mongo_target="${RC_MONGO_PATH:-$(docker_root)}"
mongo_fs="$(fs_type "$mongo_target")"
case "$mongo_fs" in
  ntfs|fuseblk|exfat|msdos|vfat|cifs|smb2)
    die "MongoDB cannot safely store data on a ${mongo_fs} filesystem (${mongo_target}).
      That filesystem does not provide the file locking and atomic rename behaviour
      MongoDB's storage engine requires, and the resulting corruption is silent.
      Choose a path on an ext4, xfs, or btrfs filesystem."
    ;;
  unknown) warn "could not determine the filesystem type of ${mongo_target}" ;;
  *)       ok "MongoDB data path is on ${mongo_fs}" ;;
esac

RC_BACKUP_DIR="$(prompt_value RC_BACKUP_DIR 'Backup directory' "$RC_DATA_DIR/backups" valid_abspath)"

# MongoDB 8.0+ will not run on kernel 6.19 or newer without handing rseq to
# glibc. Detected rather than asked, because there is no useful choice here:
# the alternative is a database that segfaults every thirty seconds.
RC_GLIBC_TUNABLES="$(mongo_glibc_tunable)"
if [[ -n "$RC_GLIBC_TUNABLES" ]]; then
  warn "Kernel $(uname -r) is 6.19 or newer."
  hint "MongoDB 8.0+ bundles a tcmalloc that segfaults on these kernels. The stack"
  hint "sets GLIBC_TUNABLES=${RC_GLIBC_TUNABLES} for MongoDB, which is the documented"
  hint "workaround: it costs allocator performance and is not an officially"
  hint "supported configuration, but it keeps the database running."
fi

heading "-- Uploads --"
hint "Rocket.Chat has no resumable upload: an interrupted transfer restarts from zero."
hint "The file is also buffered by the application before it reaches object storage,"
hint "so a large ceiling on a small-memory host risks the out-of-memory killer."
hint "This host has $(total_ram_gb) GB of RAM. 2 GiB is a safe starting ceiling."
RC_MAX_UPLOAD_SIZE="$(prompt_value RC_MAX_UPLOAD_SIZE 'Maximum upload size in bytes' '2147483648' valid_bytes)"

# ---------------------------------------------------------------------------
# Section 6: version
# ---------------------------------------------------------------------------

heading "-- Version --"

if [[ -z "${RC_VERSION:-}" && "$ASSUME_YES" != "1" ]]; then
  info "checking which Rocket.Chat releases are currently supported"
  if supported="$("$SCRIPT_DIR/supported-versions.sh" 2>/dev/null)" && [[ -n "$supported" ]]; then
    printf '%s\n' "$supported" >&2
  else
    warn "could not reach the supported-versions feed; falling back to built-in defaults"
  fi
fi

RC_VERSION="$(pick RC_VERSION 'Rocket.Chat version' \
  '8.5.3  — medium-term support, supported until 2027-06-30 (recommended)' '8.5.3' \
  '8.8.1  — newest release, supported until 2027-03-31'                    '8.8.1' \
  'Enter a different version'                                              'custom')"
if [[ "$RC_VERSION" == "custom" ]]; then
  RC_VERSION=''
  RC_VERSION="$(prompt_value RC_VERSION 'Rocket.Chat version tag' '')"
  warn "verify ${RC_VERSION} is still supported: scripts/supported-versions.sh"
fi

RC_LICENSE="${RC_LICENSE:-}"
RC_REG_TOKEN="${RC_REG_TOKEN:-}"

# ---------------------------------------------------------------------------
# Section 7: firewall
#
# The step with the worst failure mode in the whole installer. Enabling a
# default-deny firewall without an SSH rule strands a remote administrator with
# no way back in.
# ---------------------------------------------------------------------------

heading "-- Firewall --"

detected_fw="$(detect_firewall)"
case "$detected_fw" in
  ufw-active)          hint "ufw is installed and currently active on this host." ;;
  firewalld-active)    hint "firewalld is installed and currently running on this host." ;;
  ufw-available)       hint "ufw is installed but not active." ;;
  firewalld-available) hint "firewalld is installed but not active." ;;
  none)                hint "no ufw or firewalld found on this host." ;;
esac

fw_default='none'
case "$detected_fw" in ufw-*) fw_default='ufw' ;; firewalld-*) fw_default='firewalld' ;; esac

if [[ -z "${RC_FIREWALL:-}" ]]; then
  if [[ "$fw_default" == "none" ]]; then
    RC_FIREWALL="$(pick RC_FIREWALL 'How should the firewall be handled?' \
      'Leave the firewall alone; I manage it myself'  'none' \
      'Install and configure ufw'                     'ufw')"
  else
    RC_FIREWALL="$(pick RC_FIREWALL 'How should the firewall be handled?' \
      "Add rules using ${fw_default} (existing rules are kept)" "$fw_default" \
      'Leave the firewall alone; I manage it myself'            'none')"
  fi
fi

if [[ "$RC_FIREWALL" != "none" ]]; then
  detected_ssh="$(detect_ssh_port)"
  RC_SSH_PORT="${RC_SSH_PORT:-$detected_ssh}"
  info "Firewall will keep SSH port ${RC_SSH_PORT}/tcp open."
else
  RC_SSH_PORT="${RC_SSH_PORT:-$(detect_ssh_port)}"
fi

# ---------------------------------------------------------------------------
# Section 8: scheduling
#
# An existing server may already have a scheduler convention. Writing to
# /etc/cron.d on a host that uses systemd timers exclusively is rude and easy
# to miss later.
# ---------------------------------------------------------------------------

heading "-- Scheduled jobs --"

sched_default='none'
if command -v systemctl >/dev/null 2>&1; then sched_default='systemd'
elif [[ -d /etc/cron.d ]]; then sched_default='cron'; fi

if [[ -z "${RC_SCHEDULE:-}" ]]; then
  case "$sched_default" in
    systemd) RC_SCHEDULE="$(pick RC_SCHEDULE 'How should backups and certificate renewal be scheduled?' \
               'systemd timers (detected on this host)' 'systemd' \
               'cron entries in /etc/cron.d'            'cron' \
               'Do not schedule anything; I will handle it' 'none')" ;;
    cron)    RC_SCHEDULE="$(pick RC_SCHEDULE 'How should backups and certificate renewal be scheduled?' \
               'cron entries in /etc/cron.d'            'cron' \
               'Do not schedule anything; I will handle it' 'none')" ;;
    *)       RC_SCHEDULE="$(pick RC_SCHEDULE 'How should backups and certificate renewal be scheduled?' \
               'Do not schedule anything; I will handle it' 'none' \
               'cron entries in /etc/cron.d'                'cron')" ;;
  esac
fi

if [[ "$RC_SCHEDULE" != "none" ]]; then
  RC_BACKUP_TIME="$(prompt_value RC_BACKUP_TIME 'Daily backup time (HH:MM, host local time)' '03:00' valid_hhmm)"
else
  RC_BACKUP_TIME="${RC_BACKUP_TIME:-03:00}"
  warn "Nothing will renew the TLS certificate or take backups automatically."
  hint "Run scripts/renew-cert.sh twice daily and scripts/backup.sh daily by whatever means you use."
fi

RC_LE_STAGING="${RC_LE_STAGING:-0}"

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

case "$RC_MODE" in
  public-tls) RC_ROOT_URL="https://${RC_DOMAIN}"; [[ "$RC_HTTPS_PORT" == "443" ]] || RC_ROOT_URL="https://${RC_DOMAIN}:${RC_HTTPS_PORT}" ;;
  local-tls)  RC_ROOT_URL="https://${RC_DOMAIN}"; [[ "$RC_HTTPS_PORT" == "443" ]] || RC_ROOT_URL="https://${RC_DOMAIN}:${RC_HTTPS_PORT}" ;;
  plain-http) RC_ROOT_URL="http://${RC_DOMAIN}";  [[ "$RC_HTTP_PORT"  == "80"  ]] || RC_ROOT_URL="http://${RC_DOMAIN}:${RC_HTTP_PORT}" ;;
  behind-proxy)
    # The operator's proxy terminates TLS, so ROOT_URL must describe what the
    # client sees, not what this stack publishes. Asked, never assumed.
    RC_ROOT_URL="$(prompt_value RC_ROOT_URL 'Public URL your proxy will serve this on' "https://${RC_DOMAIN}")"
    ;;
esac

# nginx's $host variable carries no port. The HTTP-to-HTTPS redirect therefore
# has to append the real port, or it sends clients to 443 wherever HTTPS is
# actually published. Empty for 443 so the common case stays a clean URL.
if [[ -n "${RC_HTTPS_PORT:-}" && "$RC_HTTPS_PORT" != "443" ]]; then
  RC_HTTPS_PORT_SUFFIX=":${RC_HTTPS_PORT}"
else
  RC_HTTPS_PORT_SUFFIX=""
fi

# Compose profiles select which services run. behind-proxy needs no nginx and
# no certbot at all; this is cleaner than starting them and leaving them idle.
# The overlay file publishes Rocket.Chat directly in that one mode.
case "$RC_MODE" in
  public-tls)   RC_PROFILES='proxy,acme'; RC_COMPOSE_FILE='compose.yml' ;;
  local-tls)    RC_PROFILES='proxy';      RC_COMPOSE_FILE='compose.yml' ;;
  plain-http)   RC_PROFILES='proxy';      RC_COMPOSE_FILE='compose.yml' ;;
  behind-proxy) RC_PROFILES='';           RC_COMPOSE_FILE='compose.yml:compose.direct.yml' ;;
esac

# ---------------------------------------------------------------------------
# Review and write
# ---------------------------------------------------------------------------

heading "== Review Configuration =="
cat >&2 <<EOF
  ${C_CYAN}Mode:${C_RESET}                ${C_BOLD}${RC_MODE}${C_RESET}
  ${C_CYAN}Public URL:${C_RESET}          ${C_GREEN}${RC_ROOT_URL}${C_RESET}
  ${C_CYAN}Published ports:${C_RESET}     ${RC_BIND_ADDRESS}: ${RC_HTTP_PORT:-—} (http) ${RC_HTTPS_PORT:-—} (https) ${RC_APP_PORT:-—} (app)
  ${C_CYAN}Install directory:${C_RESET}   ${RC_DATA_DIR}
  ${C_CYAN}MongoDB data:${C_RESET}        ${RC_MONGO_PATH:-docker volume ${RC_PROJECT_NAME}_mongodb_data}
  ${C_CYAN}Uploaded files:${C_RESET}      ${RC_MINIO_PATH:-docker volume ${RC_PROJECT_NAME}_minio_data}
  ${C_CYAN}Backups:${C_RESET}             ${RC_BACKUP_DIR}
  ${C_CYAN}Upload ceiling:${C_RESET}      ${RC_MAX_UPLOAD_SIZE} bytes ($((RC_MAX_UPLOAD_SIZE / 1073741824)) GiB)
  ${C_CYAN}Rocket.Chat:${C_RESET}         ${RC_VERSION}
  ${C_CYAN}Compose project:${C_RESET}     ${RC_PROJECT_NAME}
  ${C_CYAN}Docker subnet:${C_RESET}       ${RC_NETWORK_SUBNET}
  ${C_CYAN}Firewall:${C_RESET}            ${RC_FIREWALL}$([[ "$RC_FIREWALL" != none ]] && echo " (SSH kept open on ${RC_SSH_PORT})")
  ${C_CYAN}Scheduling:${C_RESET}          ${RC_SCHEDULE}$([[ "$RC_SCHEDULE" != none ]] && echo " (backup daily at ${RC_BACKUP_TIME})")
EOF

if [[ "$ASSUME_YES" != "1" ]]; then
  confirm 'Write this configuration?' default_yes || die "aborted; nothing was written"
fi

if [[ -f "$ENV_FILE" ]]; then
  backup="${ENV_FILE}.$(date +%Y%m%d%H%M%S).bak"
  info "existing .env preserved at ${backup}"
  run cp -p "$ENV_FILE" "$backup"
fi

# Secrets are generated separately and appended, so that regenerating
# configuration never rotates credentials the running stack is already using.
"$SCRIPT_DIR/generate-secrets.sh" --env-file "$ENV_FILE.secrets"

# Mode 600 is applied at creation, before any value is written, so the
# credentials are never briefly world-readable.
run_write "$ENV_FILE" 600 <<EOF
# Generated by scripts/configure.sh on $(date -Is)
# Regenerate with: scripts/configure.sh
# This file contains credentials. Never commit it.

COMPOSE_PROJECT_NAME=${RC_PROJECT_NAME}
COMPOSE_PROFILES=${RC_PROFILES}
COMPOSE_FILE=${RC_COMPOSE_FILE}

# --- Deployment ---
RC_MODE=${RC_MODE}
RC_DOMAIN=${RC_DOMAIN}
RC_ROOT_URL=${RC_ROOT_URL}
RC_LE_EMAIL=${RC_LE_EMAIL}
RC_LE_STAGING=${RC_LE_STAGING}

# --- Published ports ---
RC_BIND_ADDRESS=${RC_BIND_ADDRESS}
RC_HTTP_PORT=${RC_HTTP_PORT:-80}
RC_HTTPS_PORT=${RC_HTTPS_PORT:-443}
RC_HTTPS_PORT_SUFFIX=${RC_HTTPS_PORT_SUFFIX}
RC_APP_PORT=${RC_APP_PORT:-3000}
RC_NETWORK_SUBNET=${RC_NETWORK_SUBNET}

# --- Storage ---
RC_DATA_DIR=${RC_DATA_DIR}
RC_MONGO_PATH=${RC_MONGO_PATH:-mongodb_data}
RC_MINIO_PATH=${RC_MINIO_PATH:-minio_data}
RC_BACKUP_DIR=${RC_BACKUP_DIR}
RC_MAX_UPLOAD_SIZE=${RC_MAX_UPLOAD_SIZE}

# Empty on kernels below 6.19. See the mongodb service in compose.yml.
RC_GLIBC_TUNABLES=${RC_GLIBC_TUNABLES}

# --- Image versions. Change here, then run scripts/upgrade.sh. ---
RC_VERSION=${RC_VERSION}
RC_MONGODB_VERSION=8.0-ubi8
RC_NATS_VERSION=2.11-alpine
RC_MINIO_VERSION=RELEASE.2025-09-07T16-13-09Z
RC_MC_VERSION=RELEASE.2025-08-13T08-35-41Z
RC_NGINX_VERSION=1.30-alpine
RC_CERTBOT_VERSION=v5.8.0

# --- Optional Rocket.Chat registration ---
RC_LICENSE=${RC_LICENSE}
RC_REG_TOKEN=${RC_REG_TOKEN}

# --- Host integration ---
RC_FIREWALL=${RC_FIREWALL}
RC_SSH_PORT=${RC_SSH_PORT}
RC_SCHEDULE=${RC_SCHEDULE}
RC_BACKUP_TIME=${RC_BACKUP_TIME}
RC_BACKUP_KEEP_DAILY=7
RC_BACKUP_KEEP_WEEKLY=4

EOF

if [[ "$DRY_RUN" != "1" && -f "$ENV_FILE.secrets" ]]; then
  cat "$ENV_FILE.secrets" >>"$ENV_FILE"
  rm -f "$ENV_FILE.secrets"
fi

ok "configuration written to ${ENV_FILE}"

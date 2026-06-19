#!/usr/bin/env bash
set -Eeuo pipefail

PSONO_DIR="${PSONO_DIR:-/opt/psono}"
STATE_DIR="${STATE_DIR:-/root/.config/psono-installer}"
COMPOSE_FILE="${PSONO_DIR}/docker-compose.yml"
ENV_FILE="${PSONO_DIR}/.env"
SETTINGS_FILE="${PSONO_DIR}/data/psono/settings.yaml"
CONFIG_FILE="${PSONO_DIR}/data/psono/config.json"
FILESERVER_SETTINGS_FILE="${PSONO_DIR}/data/fileserver/settings.yaml"
FILESERVER_SHARD_DIR_DEFAULT="${PSONO_DIR}/data/fileserver-shards"
RESTIC_ENV="${STATE_DIR}/restic.env"
INSTALL_ENV="${STATE_DIR}/psono.env"
SECRETS_ENV="${STATE_DIR}/secrets.env"
POSTGRES_MAJOR="${POSTGRES_MAJOR:-18}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:${POSTGRES_MAJOR}-alpine}"
PSONO_IMAGE="${PSONO_IMAGE:-psono/psono-combo:latest}"
FILESERVER_IMAGE="${FILESERVER_IMAGE:-psono/psono-fileserver:latest}"

usage() {
  cat <<'USAGE'
psonoctl manages the Psono install in /opt/psono.

Usage:
  psonoctl <command> [options]
  psonoctl help [command]

Common commands:
  status                         Show Docker Compose service status
  health                         Check the local Psono health endpoint
  logs [-f]                      Show Psono/Postgres logs
  restart                        Restart Psono and Postgres
  config                         Re-run the CE config wizard
  create-user                    Create a Psono user
  promote-user                   Promote a Psono user role
  clear-token                    Remove expired Psono tokens
  fix-email-salt                 Regenerate EMAIL_SECRET_SALT
  fingerprint                    Show local server key fingerprints
  harden                         Apply VM hardening
  doctor                         Check VM and Psono health
  fileserver-test                Run fileserver config check
  backup                         Dump Postgres and save config files
  update                         Update Psono image, migrate DB, restart

Lifecycle:
  start                          Start Psono and Postgres
  stop                           Stop Psono and Postgres
  restart                        Restart Psono and Postgres

Configuration:
  config                         Edit public URL, SMTP, YubiKey, registration
  create-user <email>            Create a Psono user and prompt for password
  promote-user <username> <role> Promote a user, for example superuser
  clear-token                    Run Psono's cleartoken maintenance command
  fix-email-salt                 Repair invalid bcrypt email secret salt
  fingerprint                    Show values used to verify first login
  harden                         Apply firewall, SSH, update, and config hardening
  doctor                         Report firewall, access, service, and backup state
  fileserver-test                Run Psono fileserver testconfig
  test-email <address>           Send a Psono test email using current SMTP config

Backup and restore:
  backup                         Create a local backup; send to restic if configured
  restore --snapshot <id|latest> Restore from restic after confirmation

Updates:
  update [--with-postgres] [--skip-backup]
                                 Update Psono; optionally update Postgres patch image
  postgres-upgrade --target-major <version> [--yes]
                                 Major Postgres upgrade using dump/restore

Paths:
  Runtime:       /opt/psono
  Compose file:  /opt/psono/docker-compose.yml
  Server config: /opt/psono/data/psono/settings.yaml
  Client config: /opt/psono/data/psono/config.json
  Fileserver:    /opt/psono/data/fileserver/settings.yaml
  Installer env: /root/.config/psono-installer

Examples:
  psonoctl status
  psonoctl logs -f
  psonoctl config
  psonoctl create-user user@example.com
  psonoctl promote-user username@example.com superuser
  psonoctl clear-token
  psonoctl fingerprint
  psonoctl harden
  psonoctl doctor
  psonoctl fileserver-test
  psonoctl test-email admin@example.com
  psonoctl backup
  psonoctl update
  psonoctl update --with-postgres

Run "psonoctl help update" or "psonoctl help backup" for command details.
USAGE
}

help_command() {
  case "${1:-}" in
    status)
      cat <<'USAGE'
psonoctl status

Shows Docker Compose service state for Psono and PostgreSQL.
USAGE
      ;;
    health)
      cat <<'USAGE'
psonoctl health

Checks Psono from inside the VM using:

  http://127.0.0.1:10200/server/healthcheck/

If that endpoint is unavailable, it falls back to /server/info/.
USAGE
      ;;
    logs)
      cat <<'USAGE'
psonoctl logs [-f]

Shows Docker Compose logs.

Examples:
  psonoctl logs
  psonoctl logs -f
  psonoctl logs psono-combo
USAGE
      ;;
    config)
      cat <<'USAGE'
psonoctl config

Re-runs the CE configuration wizard. It can update:

  - public URL
  - allowed account domain
  - registration setting
  - SMTP settings
  - YubiKey OTP settings

After writing settings.yaml and config.json, it starts the Compose stack
and checks Psono health.
USAGE
      ;;
    backup)
      cat <<'USAGE'
psonoctl backup

Creates a timestamped backup under:

  /opt/psono/backups/

The backup includes:

  - PostgreSQL dump
  - /opt/psono/data/psono
  - /opt/psono/docker-compose.yml
  - /opt/psono/.env

If /root/.config/psono-installer/restic.env exists, the same backup is
sent to the configured restic repository and retention is applied.
USAGE
      ;;
    restore)
      cat <<'USAGE'
psonoctl restore --snapshot latest|<snapshot-id>

Restores from a restic snapshot. This is destructive and asks for a
confirmation phrase before changing data.

Example:
  psonoctl restore --snapshot latest
USAGE
      ;;
    update)
      cat <<'USAGE'
psonoctl update [--with-postgres] [--skip-backup]

Updates Psono using the upstream CE update order:

  1. Run a backup unless --skip-backup is passed.
  2. Start PostgreSQL if needed.
  3. Pull the latest Psono image.
  4. Stop only the Psono container.
  5. Run Psono database migrations.
  6. Start Psono.
  7. Check health.
  8. Prune old images after health passes.

Options:
  --with-postgres  Also update the Postgres patch image within the same
                   pinned major version.
  --skip-backup    Skip the pre-update backup.
USAGE
      ;;
    postgres-upgrade)
      cat <<'USAGE'
psonoctl postgres-upgrade --target-major <version> [--yes]

Runs a guarded PostgreSQL major upgrade. This is intentionally separate
from normal Psono updates.

The command:

  - requires a target major version
  - asks for confirmation unless --yes is passed
  - runs a backup
  - dumps the database
  - preserves the old Postgres data directory
  - starts the target Postgres major image
  - restores the dump
  - runs Psono migrations
  - checks health

Take a Proxmox snapshot before using this command.
USAGE
      ;;
    start|stop|restart)
      cat <<USAGE
psonoctl ${1}

Runs "docker compose ${1}" in /opt/psono.
USAGE
      ;;
    test-email)
      cat <<'USAGE'
psonoctl test-email <address>

Runs Psono's sendtestmail command through Docker Compose.

Example:
  psonoctl test-email admin@example.com
USAGE
      ;;
    create-user)
      cat <<'USAGE'
psonoctl create-user <email>
psonoctl create-user <username> <email>

Creates a Psono user through Docker Compose and prompts for the password
without putting it in shell history.

With one argument, the same email-style value is used for both Psono's
username and email fields. Use two arguments only if you intentionally want
the login username and email address to differ.

Example:
  psonoctl create-user user@example.com
  psonoctl create-user username@example.com user@example.com
USAGE
      ;;
    promote-user)
      cat <<'USAGE'
psonoctl promote-user <username> <role>

Promotes a Psono user through Docker Compose.

Example:
  psonoctl promote-user username@example.com superuser
USAGE
      ;;
    clear-token)
      cat <<'USAGE'
psonoctl clear-token

Runs Psono's cleartoken maintenance command through Docker Compose.

The installer also creates a daily systemd timer for this command.
USAGE
      ;;
    fix-email-salt)
      cat <<'USAGE'
psonoctl fix-email-salt

Regenerates EMAIL_SECRET_SALT as a bcrypt salt, re-renders settings.yaml,
and restarts Psono. Use this if user creation fails with "Invalid salt".
USAGE
      ;;
    fingerprint)
      cat <<'USAGE'
psonoctl fingerprint

Shows the local Psono server verify_key. Compare it with the fingerprint
shown by Psono on first login.
USAGE
      ;;
    harden)
      cat <<'USAGE'
psonoctl harden [--profile none|minimal|balanced|strict] [--ssh-exposure lan|tailscale|disabled]

Applies VM hardening, depending on profile:

  - nftables inbound firewall
  - OpenSSH root-login hardening
  - unattended Debian security updates
  - registration disabled for Psono unless later re-enabled

SSH exposure:
  lan        allow regular SSH on port 22 from the VM network
  tailscale  allow regular SSH only through tailscale0
  disabled  block regular SSH on port 22
USAGE
      ;;
    doctor)
      cat <<'USAGE'
psonoctl doctor

Reports the current access mode, listening ports, firewall state,
Tailscale/Caddy status, disk space, Docker health, backup config,
registration setting, and local Psono health.
USAGE
      ;;
    fileserver-test)
      cat <<'USAGE'
psonoctl fileserver-test

Runs Psono fileserver's testconfig command through Docker Compose.
Use this after enabling file sharing or changing fileserver settings.
USAGE
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      usage
      die "No help topic for: $1"
      ;;
  esac
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "psonoctl must be run as root"
}

require_install() {
  [[ -f "${COMPOSE_FILE}" ]] || die "${COMPOSE_FILE} is missing"
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} is missing"
  load_env_file "${INSTALL_ENV}"
}

compose() {
  (cd "${PSONO_DIR}" && docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@")
}

load_env_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  # shellcheck disable=SC1090
  source "${file}"
}

quote_yaml() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf "'%s'" "${value}"
}

bool_yaml() {
  case "${1:-false}" in
    true|True|TRUE|yes|Yes|YES|1) printf "True" ;;
    *) printf "False" ;;
  esac
}

json_bool() {
  case "${1:-false}" in
    true|True|TRUE|yes|Yes|YES|1) printf "true" ;;
    *) printf "false" ;;
  esac
}

json_escape() {
  jq -Rn --arg v "${1:-}" '$v'
}

primary_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

public_host_from_url() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  printf '%s\n' "${url%%/*}"
}

fileserver_enabled() {
  case "${FILESERVER_ENABLED:-false}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

fileserver_public_url() {
  local public_url="${PUBLIC_URL:-}"
  if [[ -z "${public_url}" ]]; then
    public_url="http://$(primary_ip):10200"
  fi
  if [[ "${ACCESS_MODE:-lab-http}" == "lab-http" ]]; then
    printf 'http://%s:10300\n' "$(primary_ip)"
  else
    printf '%s%s\n' "${public_url%/}" "${FILESERVER_PATH:-/fileserver}"
  fi
}

write_secret_env() {
  local key="$1"
  local value="$2"
  printf "%s=%q\n" "${key}" "${value}" >> "${SECRETS_ENV}"
}

set_secret_env() {
  local key="$1" value="$2" tmp
  mkdir -p "${STATE_DIR}"
  tmp="$(mktemp)"
  if [[ -f "${SECRETS_ENV}" ]]; then
    awk -v key="${key}" 'index($0, key "=") != 1 { print }' "${SECRETS_ENV}" >"${tmp}"
  fi
  printf "%s=%q\n" "${key}" "${value}" >>"${tmp}"
  install -m 0600 "${tmp}" "${SECRETS_ENV}"
  rm -f "${tmp}"
}

generate_psono_keys() {
  local tmp private public
  tmp="$(mktemp)"
  docker run --rm "${PSONO_IMAGE}" python3 ./psono/manage.py generateserverkeys >"${tmp}"
  private="$(awk -F': *' '/PRIVATE_KEY/ {gsub(/^'\''|'\''$/, "", $2); print $2; exit}' "${tmp}")"
  public="$(awk -F': *' '/PUBLIC_KEY/ {gsub(/^'\''|'\''$/, "", $2); print $2; exit}' "${tmp}")"
  rm -f "${tmp}"
  [[ -n "${private}" && -n "${public}" ]] || die "Could not parse Psono server keys from generateserverkeys output"
  write_secret_env "PRIVATE_KEY" "${private}"
  write_secret_env "PUBLIC_KEY" "${public}"
}

generate_email_secret_salt() {
  docker run --rm "${PSONO_IMAGE}" python3 -c 'import bcrypt; print(bcrypt.gensalt(rounds=12).decode())'
}

ensure_secrets() {
  mkdir -p "${STATE_DIR}" "${PSONO_DIR}/data/psono" "${PSONO_DIR}/data/postgres"
  if fileserver_enabled; then
    mkdir -p "${PSONO_DIR}/data/fileserver" "${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}"
  fi
  chmod 0700 "${STATE_DIR}"
  if [[ -f "${SECRETS_ENV}" ]]; then
    chmod 0600 "${SECRETS_ENV}"
    return
  fi

  : >"${SECRETS_ENV}"
  chmod 0600 "${SECRETS_ENV}"
  write_secret_env "POSTGRES_PASSWORD" "$(openssl rand -base64 36 | tr -d '\n')"
  write_secret_env "SECRET_KEY" "$(openssl rand -base64 48 | tr -d '\n')"
  write_secret_env "ACTIVATION_LINK_SECRET" "$(openssl rand -base64 48 | tr -d '\n')"
  write_secret_env "DB_SECRET" "$(openssl rand -base64 48 | tr -d '\n')"
  write_secret_env "EMAIL_SECRET_SALT" "$(generate_email_secret_salt)"
  generate_psono_keys
}

render_compose() {
  mkdir -p "${PSONO_DIR}/data/postgres" "${PSONO_DIR}/data/psono"
  if fileserver_enabled; then
    mkdir -p "${PSONO_DIR}/data/fileserver" "${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}"
  fi
  local bind_ip="127.0.0.1"
  if [[ "${ACCESS_MODE:-lab-http}" == "lab-http" ]]; then
    bind_ip="0.0.0.0"
  fi

  cat >"${COMPOSE_FILE}" <<EOF_COMPOSE
services:
  psono-database:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_DB: psono
      POSTGRES_USER: psono
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U psono -d psono"]
      interval: 10s
      timeout: 5s
      retries: 12

  psono-combo:
    image: ${PSONO_IMAGE}
    restart: unless-stopped
    depends_on:
      psono-database:
        condition: service_healthy
    sysctls:
      net.core.somaxconn: "65535"
    ports:
      - "${bind_ip}:10200:80"
    volumes:
      - ./data/psono/settings.yaml:/root/.psono_server/settings.yaml:ro
      - ./data/psono/config.json:/usr/share/nginx/html/config.json:ro
      - ./data/psono/config.json:/usr/share/nginx/html/portal/config.json:ro
EOF_COMPOSE

  if fileserver_enabled; then
    cat >>"${COMPOSE_FILE}" <<EOF_FILESERVER

  psono-fileserver:
    image: ${FILESERVER_IMAGE}
    restart: unless-stopped
    depends_on:
      - psono-combo
    sysctls:
      net.core.somaxconn: "65535"
    ports:
      - "${bind_ip}:10300:80"
    volumes:
      - ./data/fileserver/settings.yaml:/root/.psono_fileserver/settings.yaml:ro
      - \${FILESERVER_SHARD_DIR}:/opt/psono-shard
EOF_FILESERVER
  fi
}

render_settings() {
  local public_url="${PUBLIC_URL:-}"
  if [[ -z "${public_url}" ]]; then
    public_url="http://$(primary_ip):10200"
  fi
  local allowed_domain="${ALLOWED_DOMAIN:-$(public_host_from_url "${public_url}")}"
  local host_url="${public_url%/}/server"
  local allow_registration="${ALLOW_REGISTRATION:-false}"
  local allow_registration_json
  allow_registration_json="$(json_bool "${allow_registration}")"
  local smtp_enabled="${SMTP_ENABLED:-false}"
  local allow_lost_password="false"
  [[ "${smtp_enabled}" == "true" ]] && allow_lost_password="true"

  local second_factors="'google_authenticator'"
  if [[ "${YUBIKEY_ENABLED:-false}" == "true" ]]; then
    second_factors="'google_authenticator', 'yubikey_otp'"
  fi

  cat >"${ENV_FILE}" <<EOF_ENV
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
FILESERVER_SHARD_DIR=${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}
EOF_ENV
  chmod 0600 "${ENV_FILE}"

  cat >"${SETTINGS_FILE}" <<EOF_SETTINGS
SECRET_KEY: $(quote_yaml "${SECRET_KEY}")
ACTIVATION_LINK_SECRET: $(quote_yaml "${ACTIVATION_LINK_SECRET}")
DB_SECRET: $(quote_yaml "${DB_SECRET}")
EMAIL_SECRET_SALT: $(quote_yaml "${EMAIL_SECRET_SALT}")
PRIVATE_KEY: $(quote_yaml "${PRIVATE_KEY}")
PUBLIC_KEY: $(quote_yaml "${PUBLIC_KEY}")

DEBUG: False
ALLOWED_HOSTS: ['*']
ALLOWED_DOMAINS: [$(quote_yaml "${allowed_domain}")]
HOST_URL: $(quote_yaml "${host_url}")
WEB_CLIENT_URL: $(quote_yaml "${public_url%/}")

DATABASES:
  default:
    ENGINE: 'django.db.backends.postgresql_psycopg2'
    NAME: 'psono'
    USER: 'psono'
    PASSWORD: $(quote_yaml "${POSTGRES_PASSWORD}")
    HOST: 'psono-database'
    PORT: 5432

ALLOW_REGISTRATION: $(bool_yaml "${allow_registration}")
ALLOW_LOST_PASSWORD: $(bool_yaml "${allow_lost_password}")
ALLOWED_SECOND_FACTORS: [${second_factors}]
EOF_SETTINGS

  if fileserver_enabled; then
    cat >>"${SETTINGS_FILE}" <<'EOF_FILESERVER_SERVER'

FILESERVER_HANDLER_ENABLED: True
FILES_ENABLED: True
EOF_FILESERVER_SERVER
  else
    cat >>"${SETTINGS_FILE}" <<'EOF_FILESERVER_SERVER'

FILESERVER_HANDLER_ENABLED: False
FILES_ENABLED: False
EOF_FILESERVER_SERVER
  fi

  if [[ "${smtp_enabled}" == "true" ]]; then
    cat >>"${SETTINGS_FILE}" <<EOF_SMTP

EMAIL_FROM: $(quote_yaml "${SMTP_EMAIL_FROM:-}")
EMAIL_BACKEND: 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST: $(quote_yaml "${SMTP_HOST:-}")
EMAIL_HOST_USER: $(quote_yaml "${SMTP_HOST_USER:-}")
EMAIL_HOST_PASSWORD: $(quote_yaml "${SMTP_HOST_PASSWORD:-}")
EMAIL_PORT: ${SMTP_PORT:-587}
EMAIL_USE_TLS: $(bool_yaml "${SMTP_USE_TLS:-true}")
EMAIL_USE_SSL: $(bool_yaml "${SMTP_USE_SSL:-false}")
EMAIL_TIMEOUT: ${SMTP_TIMEOUT:-10}
EOF_SMTP
  fi

  if [[ "${YUBIKEY_ENABLED:-false}" == "true" ]]; then
    cat >>"${SETTINGS_FILE}" <<EOF_YUBI

YUBIKEY_CLIENT_ID: $(quote_yaml "${YUBIKEY_CLIENT_ID:-}")
YUBIKEY_SECRET_KEY: $(quote_yaml "${YUBIKEY_SECRET_KEY:-}")
YUBICO_API_URLS: ['https://api.yubico.com/wsapi/2.0/verify']
EOF_YUBI
  fi

  cat >"${CONFIG_FILE}" <<EOF_JSON
{
  "backend_servers": [
    {
      "title": "Psono",
      "url": $(json_escape "${host_url}")
    }
  ],
  "base_url": $(json_escape "${public_url%/}/"),
  "allow_custom_server": false,
  "allow_registration": ${allow_registration_json},
  "allow_lost_password": ${allow_lost_password},
  "authentication_methods": ["AUTHKEY"]
}
EOF_JSON
}

render_readme() {
  local public_url="${PUBLIC_URL:-http://$(primary_ip):10200}"
  cat >"${PSONO_DIR}/README.md" <<EOF_README
# Psono VM Runtime

Psono is installed in ${PSONO_DIR} and managed with:

  sudo psonoctl status
  sudo psonoctl health
  sudo psonoctl logs -f
  sudo psonoctl doctor
  sudo psonoctl harden
  sudo psonoctl fileserver-test
  sudo psonoctl update
  sudo psonoctl backup

URL:

  ${public_url}

Configuration:

  ${SETTINGS_FILE}
  ${CONFIG_FILE}
  ${ENV_FILE}

Fileserver:

  Enabled: ${FILESERVER_ENABLED:-false}
  URL: $(fileserver_public_url)
  Settings: ${FILESERVER_SETTINGS_FILE}
  Shards: ${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}

Backups:

  sudo psonoctl backup

Updates:

  sudo psonoctl update
  sudo psonoctl update --with-postgres

Postgres major upgrades are intentionally separate:

  sudo psonoctl postgres-upgrade --target-major 19

Lab HTTP installs are useful for testing, but Psono upstream requires a domain and trusted TLS for supported deployments.
EOF_README
}

render_config() {
  require_root
  load_env_file "${INSTALL_ENV}"
  ensure_secrets
  load_env_file "${SECRETS_ENV}"
  render_compose
  render_settings
  render_readme
}

wait_db() {
  info "Waiting for PostgreSQL"
  for _ in $(seq 1 60); do
    if compose exec -T psono-database pg_isready -U psono -d psono >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "PostgreSQL did not become ready"
}

migrate() {
  manage_py migrate
}

manage_py() {
  compose run --rm psono-combo python3 ./psono/manage.py "$@"
}

fileserver_manage_py() {
  compose run --rm psono-fileserver python3 ./psono/manage.py "$@"
}

extract_uuid() {
  grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1
}

status_cmd() {
  require_install
  compose ps
}

health_cmd() {
  require_install
  curl -fsS "http://127.0.0.1:10200/server/healthcheck/" || curl -fsS "http://127.0.0.1:10200/server/info/"
  echo
}

start_cmd() {
  require_install
  compose up -d
}

stop_cmd() {
  require_install
  compose stop
}

restart_cmd() {
  require_install
  compose restart
  health_cmd
}

logs_cmd() {
  require_install
  compose logs "$@"
}

backup_cmd() {
  require_root
  require_install
  local ts backup_dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${PSONO_DIR}/backups/${ts}"
  mkdir -p "${backup_dir}"
  chmod 0700 "${PSONO_DIR}/backups" "${backup_dir}"

  info "Dumping PostgreSQL"
  compose exec -T psono-database pg_dump -U psono -d psono >"${backup_dir}/psono.sql"
  local tar_items shard_dir
  shard_dir="${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}"
  tar_items=(data/psono docker-compose.yml .env README.md)
  [[ -d "${PSONO_DIR}/data/fileserver" ]] && tar_items+=(data/fileserver)
  if [[ -d "${shard_dir}" && "${shard_dir}" == "${PSONO_DIR}/"* ]]; then
    tar_items+=("${shard_dir#${PSONO_DIR}/}")
  fi
  tar -C "${PSONO_DIR}" -czf "${backup_dir}/psono-config.tar.gz" "${tar_items[@]}"
  if [[ -d "${shard_dir}" && "${shard_dir}" != "${PSONO_DIR}/"* ]]; then
    tar -C "$(dirname "${shard_dir}")" -czf "${backup_dir}/psono-fileserver-shards.tar.gz" "$(basename "${shard_dir}")"
  fi

  if [[ -f "${RESTIC_ENV}" ]]; then
    info "Sending backup to restic repository"
    set -a
    # shellcheck disable=SC1090
    source "${RESTIC_ENV}"
    set +a
    local restic_items
    restic_items=("${backup_dir}/psono.sql" "${backup_dir}/psono-config.tar.gz" "${PSONO_DIR}/data/psono" "${PSONO_DIR}/docker-compose.yml" "${PSONO_DIR}/.env")
    [[ -d "${PSONO_DIR}/data/fileserver" ]] && restic_items+=("${PSONO_DIR}/data/fileserver")
    [[ -d "${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}" ]] && restic_items+=("${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}")
    restic backup "${restic_items[@]}"
    restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
  fi

  info "Backup complete: ${backup_dir}"
}

restore_cmd() {
  require_root
  require_install
  local snapshot=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot) snapshot="${2:-}"; shift 2 ;;
      *) die "Unknown restore option: $1" ;;
    esac
  done
  [[ -n "${snapshot}" ]] || die "restore requires --snapshot latest|<snapshot-id>"
  [[ -f "${RESTIC_ENV}" ]] || die "restore currently requires a configured restic repository"

  echo "This will stop Psono and restore database/config data from restic snapshot '${snapshot}'."
  read -r -p "Type RESTORE to continue: " answer
  [[ "${answer}" == "RESTORE" ]] || die "Restore cancelled"

  local tmp
  tmp="$(mktemp -d)"
  set -a
  # shellcheck disable=SC1090
  source "${RESTIC_ENV}"
  set +a
  restic restore "${snapshot}" --target "${tmp}"

  if fileserver_enabled; then
    compose stop psono-fileserver || true
  fi
  compose stop psono-combo
  if [[ -d "${tmp}${PSONO_DIR}/data/psono" ]]; then
    rsync -a --delete "${tmp}${PSONO_DIR}/data/psono/" "${PSONO_DIR}/data/psono/"
  fi
  if [[ -d "${tmp}${PSONO_DIR}/data/fileserver" ]]; then
    mkdir -p "${PSONO_DIR}/data/fileserver"
    rsync -a --delete "${tmp}${PSONO_DIR}/data/fileserver/" "${PSONO_DIR}/data/fileserver/"
  fi
  local shard_dir="${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}"
  if [[ -d "${tmp}${shard_dir}" ]]; then
    mkdir -p "${shard_dir}"
    rsync -a --delete "${tmp}${shard_dir}/" "${shard_dir}/"
  fi
  local sql
  sql="$(find "${tmp}" -name psono.sql -type f | sort | tail -n 1)"
  [[ -n "${sql}" ]] || die "No psono.sql found in restored snapshot"
  compose exec -T psono-database psql -U psono -d psono -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
  cat "${sql}" | compose exec -T psono-database psql -U psono -d psono
  compose up -d
  if fileserver_enabled; then
    fileserver_test_cmd
  fi
  health_cmd
}

update_cmd() {
  require_root
  require_install
  local with_postgres="false" skip_backup="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-postgres) with_postgres="true"; shift ;;
      --skip-backup) skip_backup="true"; shift ;;
      *) die "Unknown update option: $1" ;;
    esac
  done

  if [[ "${skip_backup}" != "true" ]]; then
    backup_cmd
  fi

  info "Ensuring PostgreSQL is running"
  compose up -d psono-database
  wait_db

  if [[ "${with_postgres}" == "true" ]]; then
    info "Updating PostgreSQL patch image within pinned major"
    compose pull psono-database
    compose up -d psono-database
    wait_db
  fi

  info "Pulling latest Psono image"
  compose pull psono-combo
  if fileserver_enabled; then
    info "Pulling latest Psono fileserver image"
    compose pull psono-fileserver
  fi
  info "Stopping Psono before migration"
  compose stop psono-combo || true
  if fileserver_enabled; then
    compose stop psono-fileserver || true
  fi
  info "Running migrations"
  migrate
  info "Starting Psono"
  compose up -d psono-combo
  if fileserver_enabled; then
    fileserver_test_cmd
    compose up -d psono-fileserver
  fi
  info "Checking health"
  health_cmd
  docker image prune -f
}

postgres_major() {
  local version_num
  version_num="$(compose exec -T psono-database psql -U psono -d psono -Atc "SHOW server_version_num;" | tr -d '\r')"
  printf '%s\n' "$((version_num / 10000))"
}

postgres_upgrade_cmd() {
  require_root
  require_install
  local target="" yes="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-major) target="${2:-}"; shift 2 ;;
      --yes) yes="true"; shift ;;
      *) die "Unknown postgres-upgrade option: $1" ;;
    esac
  done
  [[ "${target}" =~ ^[0-9]+$ ]] || die "postgres-upgrade requires --target-major <version>"

  compose up -d psono-database
  wait_db
  local current
  current="$(postgres_major)"
  [[ "${current}" != "${target}" ]] || die "PostgreSQL is already on major ${target}; use update --with-postgres for patch updates"

  echo "PostgreSQL major upgrade ${current} -> ${target} will dump, replace the data directory, restore, migrate, and health-check Psono."
  if [[ "${yes}" != "true" ]]; then
    read -r -p "Type POSTGRES-UPGRADE to continue: " answer
    [[ "${answer}" == "POSTGRES-UPGRADE" ]] || die "PostgreSQL upgrade cancelled"
  fi

  backup_cmd
  local ts dump old_dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dump="${PSONO_DIR}/backups/${ts}/postgres-major-upgrade.dump"
  mkdir -p "$(dirname "${dump}")"
  compose exec -T psono-database pg_dump -U psono -d psono -Fc >"${dump}"

  if fileserver_enabled; then
    compose stop psono-fileserver || true
  fi
  compose stop psono-combo
  compose stop psono-database
  old_dir="${PSONO_DIR}/data/postgres-pre-${current}-${ts}"
  mv "${PSONO_DIR}/data/postgres" "${old_dir}"
  mkdir -p "${PSONO_DIR}/data/postgres"

  perl -0pi -e "s#image: postgres:[0-9]+-alpine#image: postgres:${target}-alpine#" "${COMPOSE_FILE}"
  compose pull psono-database
  compose up -d psono-database
  wait_db
  cat "${dump}" | compose exec -T psono-database pg_restore --clean --if-exists -U psono -d psono
  migrate
  compose up -d psono-combo
  if fileserver_enabled; then
    fileserver_test_cmd
    compose up -d psono-fileserver
  fi
  health_cmd
  info "Old PostgreSQL data directory preserved at ${old_dir}"
}

prompt() {
  local label="$1" default="${2:-}" value
  if [[ -n "${default}" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s\n' "${value:-$default}"
  else
    read -r -p "${label}: " value
    printf '%s\n' "${value}"
  fi
}

prompt_secret() {
  local label="$1" value
  read -r -s -p "${label}: " value
  echo >&2
  printf '%s\n' "${value}"
}

prompt_bool() {
  local label="$1" default="${2:-false}" value
  while true; do
    value="$(prompt "${label}" "${default}")"
    case "${value}" in
      true|false) printf '%s\n' "${value}"; return ;;
      *) echo "Enter true or false." >&2 ;;
    esac
  done
}

write_install_env() {
  : >"${INSTALL_ENV}"
  chmod 0600 "${INSTALL_ENV}"
  for key in ACCESS_MODE PUBLIC_URL ALLOWED_DOMAIN VM_AUTH_METHOD HARDENING_PROFILE SSH_EXPOSURE TAILSCALE_SSH FILESERVER_ENABLED FILESERVER_STORAGE FILESERVER_PATH FILESERVER_SHARD_DIR FILESERVER_CLUSTER_ID FILESERVER_SHARD_ID ALLOW_REGISTRATION SMTP_ENABLED SMTP_EMAIL_FROM SMTP_HOST SMTP_HOST_USER SMTP_HOST_PASSWORD SMTP_PORT SMTP_USE_TLS SMTP_USE_SSL SMTP_TIMEOUT YUBIKEY_ENABLED YUBIKEY_CLIENT_ID YUBIKEY_SECRET_KEY; do
    printf "%s=%q\n" "${key}" "${!key:-}" >>"${INSTALL_ENV}"
  done
}

set_install_env_value() {
  local key="$1" value="$2" tmp
  mkdir -p "${STATE_DIR}"
  tmp="$(mktemp)"
  if [[ -f "${INSTALL_ENV}" ]]; then
    awk -v key="${key}" 'index($0, key "=") != 1 { print }' "${INSTALL_ENV}" >"${tmp}"
  fi
  printf "%s=%q\n" "${key}" "${value}" >>"${tmp}"
  install -m 0600 "${tmp}" "${INSTALL_ENV}"
  rm -f "${tmp}"
}

config_cmd() {
  require_root
  mkdir -p "${STATE_DIR}"
  load_env_file "${INSTALL_ENV}"

  PUBLIC_URL="$(prompt "Public Psono URL" "${PUBLIC_URL:-http://$(primary_ip):10200}")"
  ALLOWED_DOMAIN="$(prompt "Allowed account domain" "${ALLOWED_DOMAIN:-$(public_host_from_url "${PUBLIC_URL}")}")"
  FILESERVER_ENABLED="$(prompt_bool "Enable Psono fileserver? true/false" "${FILESERVER_ENABLED:-true}")"
  if [[ "${FILESERVER_ENABLED}" == "true" ]]; then
    FILESERVER_STORAGE="local"
    FILESERVER_PATH="$(prompt "Fileserver path" "${FILESERVER_PATH:-/fileserver}")"
    [[ "${FILESERVER_PATH}" == /* ]] || die "Fileserver path must start with /"
    FILESERVER_SHARD_DIR="$(prompt "Fileserver shard directory" "${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}")"
  fi
  ALLOW_REGISTRATION="$(prompt_bool "Allow registration? true/false" "${ALLOW_REGISTRATION:-false}")"

  SMTP_ENABLED="$(prompt_bool "Configure SMTP email? true/false" "${SMTP_ENABLED:-false}")"
  if [[ "${SMTP_ENABLED}" == "true" ]]; then
    SMTP_EMAIL_FROM="$(prompt "Email from address" "${SMTP_EMAIL_FROM:-}")"
    SMTP_HOST="$(prompt "SMTP host" "${SMTP_HOST:-}")"
    SMTP_HOST_USER="$(prompt "SMTP user" "${SMTP_HOST_USER:-}")"
    SMTP_HOST_PASSWORD="$(prompt_secret "SMTP password")"
    SMTP_PORT="$(prompt "SMTP port" "${SMTP_PORT:-587}")"
    SMTP_USE_TLS="$(prompt_bool "SMTP STARTTLS? true/false" "${SMTP_USE_TLS:-true}")"
    SMTP_USE_SSL="$(prompt_bool "SMTP implicit SSL? true/false" "${SMTP_USE_SSL:-false}")"
    SMTP_TIMEOUT="$(prompt "SMTP timeout seconds" "${SMTP_TIMEOUT:-10}")"
  fi

  YUBIKEY_ENABLED="$(prompt_bool "Configure YubiKey OTP? true/false" "${YUBIKEY_ENABLED:-false}")"
  if [[ "${YUBIKEY_ENABLED}" == "true" ]]; then
    YUBIKEY_CLIENT_ID="$(prompt "Yubico client ID" "${YUBIKEY_CLIENT_ID:-}")"
    YUBIKEY_SECRET_KEY="$(prompt_secret "Yubico secret key")"
  fi

  write_install_env
  render_config
  if fileserver_enabled; then
    compose up -d psono-database
    wait_db
    migrate
    compose up -d psono-combo
    bootstrap_fileserver
  fi
  compose up -d
  health_cmd
}

test_email_cmd() {
  require_install
  local target="${1:-}"
  [[ -n "${target}" ]] || die "test-email requires an address"
  manage_py sendtestmail "${target}"
}

create_user_cmd() {
  require_install
  local username="${1:-}" email="${2:-}" password
  [[ -n "${username}" ]] || die "create-user requires an email address"
  if [[ -z "${email}" ]]; then
    email="${username}"
  fi
  password="$(prompt_secret "Password for ${username}")"
  [[ -n "${password}" ]] || die "Password is required"
  manage_py createuser "${username}" "${password}" "${email}"
}

promote_user_cmd() {
  require_install
  local username="${1:-}" role="${2:-}"
  [[ -n "${username}" ]] || die "promote-user requires a username"
  [[ -n "${role}" ]] || die "promote-user requires a role, for example superuser"
  manage_py promoteuser "${username}" "${role}"
}

clear_token_cmd() {
  require_install
  manage_py cleartoken
}

fingerprint_cmd() {
  require_install
  local public_key info_json verify_key

  info_json="$(curl -fsS "http://127.0.0.1:10200/server/info/" 2>/dev/null || true)"
  if [[ -n "${info_json}" ]]; then
    verify_key="$(printf '%s' "${info_json}" | jq -r '.verify_key // empty' 2>/dev/null || true)"
  fi

  if [[ -n "${verify_key:-}" ]]; then
    echo "Server verify_key:"
    printf '%s\n' "${verify_key}"
    echo
    echo "Compare this value with the fingerprint shown on the Psono login screen."
    echo
  else
    echo "Could not read verify_key from http://127.0.0.1:10200/server/info/"
    echo
  fi

  echo "Settings file: ${SETTINGS_FILE}"
  public_key="$(awk -F': *' '/^PUBLIC_KEY:/ {gsub(/^'\''|'\''$/, "", $2); print $2; exit}' "${SETTINGS_FILE}")"
  if [[ -n "${public_key}" ]]; then
    echo "PUBLIC_KEY:"
    printf '%s\n' "${public_key}"
    echo
    echo "Common public key hashes:"
    printf '%s' "${public_key}" | sha256sum | awk '{print "sha256(public_key): " $1}'
    printf '%s' "${public_key}" | sha512sum | awk '{print "sha512(public_key): " $1}'
  else
    echo "Could not read PUBLIC_KEY from ${SETTINGS_FILE}"
  fi
  echo
  echo "Local server info endpoint:"
  if [[ -n "${info_json}" ]]; then
    printf '%s' "${info_json}" | jq . || printf '%s\n' "${info_json}"
  fi
}

fix_email_salt_cmd() {
  require_root
  require_install
  local salt
  salt="$(generate_email_secret_salt)"
  [[ -n "${salt}" ]] || die "Could not generate EMAIL_SECRET_SALT"
  set_secret_env "EMAIL_SECRET_SALT" "${salt}"
  render_config
  compose up -d psono-combo
  info "EMAIL_SECRET_SALT regenerated and settings.yaml updated"
}

render_fileserver_settings() {
  fileserver_enabled || return 0
  [[ "${FILESERVER_STORAGE:-local}" == "local" ]] || die "Only local fileserver storage is supported"
  [[ -n "${FILESERVER_CLUSTER_ID:-}" ]] || die "FILESERVER_CLUSTER_ID is missing"
  [[ -n "${FILESERVER_SHARD_ID:-}" ]] || die "FILESERVER_SHARD_ID is missing"

  local raw filtered shard_host_dir shard_container_dir
  raw="$(mktemp)"
  filtered="$(mktemp)"
  manage_py fsclustershowconfig "${FILESERVER_CLUSTER_ID}" >"${raw}"
  awk '
    /^[A-Z_]+:/ && $0 !~ /^(SERVER_URL|SHARDS|DEBUG|ALLOWED_HOSTS|HOST_URL):/ { print }
  ' "${raw}" >"${filtered}"
  grep -q '^CLUSTER_PRIVATE_KEY:' "${filtered}" || die "Could not generate fileserver cluster config"

  shard_host_dir="${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}/${FILESERVER_SHARD_ID}"
  shard_container_dir="/opt/psono-shard/${FILESERVER_SHARD_ID}"
  mkdir -p "$(dirname "${FILESERVER_SETTINGS_FILE}")" "${shard_host_dir}"

  {
    cat "${filtered}"
    printf 'SERVER_URL: %s\n' "$(quote_yaml "${PUBLIC_URL%/}/server")"
    printf 'HOST_URL: %s\n' "$(quote_yaml "$(fileserver_public_url)")"
    printf "SHARDS: [{shard_id: %s, read: True, write: True, delete: True, engine: {class: 'local', kwargs: {location: %s}}}]\n" "${FILESERVER_SHARD_ID}" "$(quote_yaml "${shard_container_dir}")"
    printf 'DEBUG: False\n'
    printf "ALLOWED_HOSTS: ['*']\n"
  } >"${FILESERVER_SETTINGS_FILE}"
  chmod 0600 "${FILESERVER_SETTINGS_FILE}"
  rm -f "${raw}" "${filtered}"
}

bootstrap_fileserver() {
  fileserver_enabled || return 0
  [[ "${FILESERVER_STORAGE:-local}" == "local" ]] || die "Only local fileserver storage is supported"

  local output cluster_id shard_id
  if [[ -z "${FILESERVER_CLUSTER_ID:-}" ]]; then
    output="$(manage_py fsclustercreate "Default Cluster")"
    cluster_id="$(printf '%s\n' "${output}" | extract_uuid)"
    [[ -n "${cluster_id}" ]] || die "Could not parse fileserver cluster id from: ${output}"
    FILESERVER_CLUSTER_ID="${cluster_id}"
    set_install_env_value "FILESERVER_CLUSTER_ID" "${FILESERVER_CLUSTER_ID}"
  fi

  if [[ -z "${FILESERVER_SHARD_ID:-}" ]]; then
    output="$(manage_py fsshardcreate "Default Local Shard" "Local fileserver shard")"
    shard_id="$(printf '%s\n' "${output}" | extract_uuid)"
    [[ -n "${shard_id}" ]] || die "Could not parse fileserver shard id from: ${output}"
    FILESERVER_SHARD_ID="${shard_id}"
    set_install_env_value "FILESERVER_SHARD_ID" "${FILESERVER_SHARD_ID}"
  fi

  manage_py fsshardlink "${FILESERVER_CLUSTER_ID}" "${FILESERVER_SHARD_ID}" rw >/dev/null 2>&1 || true
  render_fileserver_settings
  fileserver_test_cmd
}

fileserver_test_cmd() {
  require_install
  fileserver_enabled || die "Fileserver is not enabled"
  [[ -f "${FILESERVER_SETTINGS_FILE}" ]] || die "${FILESERVER_SETTINGS_FILE} is missing"
  fileserver_manage_py testconfig
}

validate_hardening_profile() {
  case "${1:-}" in
    none|minimal|balanced|strict) ;;
    *) die "hardening profile must be none, minimal, balanced, or strict" ;;
  esac
}

validate_ssh_exposure() {
  case "${1:-}" in
    lan|tailscale|disabled) ;;
    *) die "SSH exposure must be lan, tailscale, or disabled" ;;
  esac
}

install_hardening_packages() {
  apt-get update
  apt-get install -y nftables iproute2
}

configure_unattended_upgrades() {
  apt-get install -y unattended-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF_AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF_AUTO_UPGRADES
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
}

configure_sshd_hardening() {
  local profile="$1" password_auth="yes"
  mkdir -p /etc/ssh/sshd_config.d
  if [[ "${profile}" == "strict" || "${VM_AUTH_METHOD:-password}" == "ssh-key" ]]; then
    password_auth="no"
  fi
  cat >/etc/ssh/sshd_config.d/90-psono-hardening.conf <<EOF_SSHD
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
X11Forwarding no
EOF_SSHD
  systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
}

write_nftables_rules() {
  local profile="$1" ssh_exposure="$2"
  if [[ "${profile}" == "none" ]]; then
    systemctl disable --now nftables >/dev/null 2>&1 || true
    return
  fi

  local ssh_rule="" access_rule="" tailscale_rule=""
  case "${ssh_exposure}" in
    lan) ssh_rule="    tcp dport 22 accept" ;;
    tailscale) ssh_rule="    iifname \"tailscale0\" tcp dport 22 accept" ;;
    disabled) ssh_rule="" ;;
  esac

  case "${ACCESS_MODE:-lab-http}" in
    lab-http)
      if fileserver_enabled; then
        access_rule="    tcp dport { 10200, 10300 } accept"
      else
        access_rule="    tcp dport 10200 accept"
      fi
      ;;
    caddy-https) access_rule="    tcp dport { 80, 443 } accept" ;;
    tailscale-https) tailscale_rule="    iifname \"tailscale0\" tcp dport 443 accept" ;;
  esac

  cat >/etc/nftables.conf <<EOF_NFTABLES
#!/usr/sbin/nft -f
flush ruleset

table inet psono_hardening {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept
    ct state established,related accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    udp dport 41641 accept
${tailscale_rule}
${ssh_rule}
${access_rule}
  }

  chain forward {
    type filter hook forward priority 0;
    policy accept;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF_NFTABLES

  nft -c -f /etc/nftables.conf
  systemctl enable --now nftables
  nft -f /etc/nftables.conf
}

harden_cmd() {
  require_root
  require_install
  load_env_file "${INSTALL_ENV}"
  local profile="${HARDENING_PROFILE:-balanced}" ssh_exposure="${SSH_EXPOSURE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="${2:-}"; shift 2 ;;
      --ssh-exposure) ssh_exposure="${2:-}"; shift 2 ;;
      *) die "Unknown harden option: $1" ;;
    esac
  done
  validate_hardening_profile "${profile}"
  if [[ -z "${ssh_exposure}" ]]; then
    if [[ "${TAILSCALE_SSH:-false}" == "true" ]]; then
      ssh_exposure="tailscale"
    else
      ssh_exposure="lan"
    fi
  fi
  validate_ssh_exposure "${ssh_exposure}"

  set_install_env_value "HARDENING_PROFILE" "${profile}"
  set_install_env_value "SSH_EXPOSURE" "${ssh_exposure}"
  if [[ "${profile}" != "none" ]]; then
    install_hardening_packages
    configure_sshd_hardening "${profile}"
    if [[ "${profile}" == "balanced" || "${profile}" == "strict" ]]; then
      set_install_env_value "ALLOW_REGISTRATION" "false"
      ALLOW_REGISTRATION="false"
      render_config
      compose up -d
      configure_unattended_upgrades
    fi
  fi
  write_nftables_rules "${profile}" "${ssh_exposure}"
  info "Hardening profile '${profile}' applied with SSH exposure '${ssh_exposure}'"
}

status_line() {
  local label="$1"
  shift
  printf '%-28s' "${label}:"
  "$@" || true
}

unit_state() {
  local unit="$1"
  systemctl is-active "${unit}" 2>/dev/null || true
}

doctor_cmd() {
  load_env_file "${INSTALL_ENV}"
  echo "Psono doctor"
  echo
  printf '%-28s%s\n' "Access mode:" "${ACCESS_MODE:-unknown}"
  printf '%-28s%s\n' "Public URL:" "${PUBLIC_URL:-unknown}"
  printf '%-28s%s\n' "Fileserver enabled:" "${FILESERVER_ENABLED:-false}"
  if fileserver_enabled; then
    printf '%-28s%s\n' "Fileserver URL:" "$(fileserver_public_url)"
    printf '%-28s%s\n' "Fileserver shard dir:" "${FILESERVER_SHARD_DIR:-${FILESERVER_SHARD_DIR_DEFAULT}}"
  fi
  printf '%-28s%s\n' "Hardening profile:" "${HARDENING_PROFILE:-unknown}"
  printf '%-28s%s\n' "SSH exposure:" "${SSH_EXPOSURE:-unknown}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    printf '%-28s%s\n' "Client registration:" "$(jq -r '.allow_registration // "unknown"' "${CONFIG_FILE}" 2>/dev/null || echo unknown)"
  fi
  if [[ -f "${SETTINGS_FILE}" ]]; then
    printf '%-28s%s\n' "Server registration:" "$(awk -F': *' '/^ALLOW_REGISTRATION:/ {print $2; exit}' "${SETTINGS_FILE}")"
  fi
  printf '%-28s%s\n' "Disk free /opt:" "$(df -h /opt 2>/dev/null | awk 'NR == 2 {print $4 " free of " $2}' || echo unknown)"
  printf '%-28s%s\n' "Restic configured:" "$([[ -f "${RESTIC_ENV}" ]] && echo true || echo false)"
  printf '%-28s%s\n' "nftables:" "$(unit_state nftables)"
  printf '%-28s%s\n' "unattended-upgrades:" "$(unit_state unattended-upgrades)"
  printf '%-28s%s\n' "tailscaled:" "$(unit_state tailscaled)"
  printf '%-28s%s\n' "caddy:" "$(unit_state caddy)"
  echo
  echo "Listening TCP ports:"
  ss -H -ltnp 2>/dev/null || true
  echo
  echo "Docker services:"
  if [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" ]]; then
    compose ps || true
  else
    echo "Psono Compose files are missing."
  fi
  echo
  echo "Psono health:"
  if [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" ]]; then
    health_cmd || true
  else
    echo "Psono Compose files are missing."
  fi
  if fileserver_enabled; then
    echo
    echo "Fileserver health:"
    curl -fsS "http://127.0.0.1:10300/info/" || true
    echo
  fi
}

bootstrap_cmd() {
  require_root
  render_config
  compose pull
  compose up -d psono-database
  wait_db
  migrate
  if fileserver_enabled; then
    compose up -d psono-combo
    bootstrap_fileserver
  fi
  compose up -d
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    ""|-h|--help) usage; return ;;
    help) help_command "${1:-}"; return ;;
  esac
  require_root
  case "${cmd}" in
    status) status_cmd "$@" ;;
    health) health_cmd "$@" ;;
    start) start_cmd "$@" ;;
    stop) stop_cmd "$@" ;;
    restart) restart_cmd "$@" ;;
    logs) logs_cmd "$@" ;;
    config) config_cmd "$@" ;;
    create-user) create_user_cmd "$@" ;;
    promote-user) promote_user_cmd "$@" ;;
    clear-token) clear_token_cmd "$@" ;;
    fix-email-salt) fix_email_salt_cmd "$@" ;;
    fingerprint) fingerprint_cmd "$@" ;;
    harden) harden_cmd "$@" ;;
    doctor) doctor_cmd "$@" ;;
    fileserver-test) fileserver_test_cmd "$@" ;;
    test-email) test_email_cmd "$@" ;;
    backup) backup_cmd "$@" ;;
    restore) restore_cmd "$@" ;;
    update) update_cmd "$@" ;;
    postgres-upgrade) postgres_upgrade_cmd "$@" ;;
    bootstrap) bootstrap_cmd "$@" ;;
    render-config) render_config "$@" ;;
    *) usage; die "Unknown command: ${cmd}" ;;
  esac
}

main "$@"

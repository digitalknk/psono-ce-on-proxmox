#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi
TEMPLATE_FILE="${SCRIPT_DIR}/files/cloud-init-user-data.yml.tmpl"
PSONOCTL_FILE="${SCRIPT_DIR}/files/psonoctl.sh"
PSONO_INSTALLER_BASE_URL="${PSONO_INSTALLER_BASE_URL:-}"

DEFAULT_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
DEFAULT_CORES="2"
DEFAULT_MEMORY="4096"
DEFAULT_DISK_GB="40"
DEFAULT_BRIDGE="vmbr0"

VMID_ARG=""
VM_NAME_ARG=""
CORES_ARG=""
MEMORY_ARG=""
DISK_GB_ARG=""
BRIDGE_ARG=""
STORAGE_ARG=""
SNIPPET_STORAGE_ARG=""
SSH_KEY_FILE_ARG=""
IMAGE_URL_ARG=""
REFRESH_IMAGE_ARG="false"
ACCESS_MODE_ARG=""
TAILSCALE_AUTH_KEY_ARG=""
TAILSCALE_HOSTNAME_ARG=""
TAILSCALE_EXPOSURE_ARG=""
CADDY_DOMAIN_ARG=""
CADDY_EMAIL_ARG=""
ALLOW_REGISTRATION_ARG=""
SMTP_ENABLED_ARG=""
SMTP_EMAIL_FROM_ARG=""
SMTP_HOST_ARG=""
SMTP_HOST_USER_ARG=""
SMTP_HOST_PASSWORD_ARG=""
SMTP_PORT_ARG=""
SMTP_USE_TLS_ARG=""
SMTP_USE_SSL_ARG=""
SMTP_TIMEOUT_ARG=""
YUBIKEY_ENABLED_ARG=""
YUBIKEY_CLIENT_ID_ARG=""
YUBIKEY_SECRET_KEY_ARG=""
BACKUP_MODE_ARG=""
R2_ACCOUNT_ID_ARG=""
R2_BUCKET_ARG=""
R2_PREFIX_ARG=""
S3_ENDPOINT_ARG=""
S3_BUCKET_ARG=""
S3_PREFIX_ARG=""
S3_REGION_ARG=""
S3_ACCESS_KEY_ID_ARG=""
S3_SECRET_ACCESS_KEY_ARG=""
RESTIC_PASSWORD_ARG=""

usage() {
  cat <<'USAGE'
Create a Debian VM on Proxmox and install Psono CE.

Usage:
  bash setup-psono-vm.sh [options]
  bash setup-psono-vm.sh --help

VM options:
  --vmid ID                    VMID to create (default: next Proxmox ID)
  --name NAME                  VM name (default: psono-<VMID>)
  --cores N                    vCPU count (default: 2)
  --memory MB                  RAM in MB (default: 4096)
  --disk GB                    Disk size in GB (default: 40)
  --bridge NAME                Proxmox bridge (default: vmbr0)
  --storage NAME               VM disk storage (default prompt: local-lvm)
  --snippet-storage NAME       Cloud-init snippet storage (default: local)
  --ssh-key PATH               SSH public key file
  --image-url URL              Debian cloud image URL
  --refresh-image              Download image again even if cached locally

Access options:
  --access-mode MODE           lab-http, tailscale-https, or caddy-https
  --tailscale-auth-key KEY     Optional auth key from Tailscale admin console
  --tailscale-hostname NAME    Tailscale hostname (default: VM name)
  --tailscale-exposure MODE    serve or funnel (default: serve)
  --caddy-domain DOMAIN        Required for caddy-https
  --caddy-email EMAIL          Optional ACME email for Caddy

Psono config options:
  --allow-registration true|false
  --smtp true|false
  --smtp-from ADDRESS
  --smtp-host HOST
  --smtp-user USER
  --smtp-password PASSWORD
  --smtp-port PORT
  --smtp-use-tls true|false
  --smtp-use-ssl true|false
  --smtp-timeout SECONDS
  --yubikey true|false
  --yubikey-client-id ID
  --yubikey-secret-key KEY

Backup modes:
  --backup-mode MODE           none, r2, or s3
  --r2-account-id ID
  --r2-bucket BUCKET
  --r2-prefix PREFIX
  --s3-endpoint URL
  --s3-bucket BUCKET
  --s3-prefix PREFIX
  --s3-region REGION
  --s3-access-key-id KEY
  --s3-secret-access-key KEY
  --restic-password PASSWORD

Notes:
  Run as root on a Proxmox host.
  Any omitted option is prompted for interactively.
  Existing VMIDs and VM names are refused before creation.
  The Debian image is reused when the same file already exists locally.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root on a Proxmox host"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

fetch_url() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${output}"
  else
    wget -O "${output}" "${url}"
  fi
}

ensure_support_files() {
  if [[ -f "${TEMPLATE_FILE}" && -f "${PSONOCTL_FILE}" ]]; then
    return
  fi
  [[ -n "${PSONO_INSTALLER_BASE_URL}" ]] || die "Missing files/. Run from a clone, or set PSONO_INSTALLER_BASE_URL to the raw GitHub repository base URL."
  local support_dir
  support_dir="$(mktemp -d)"
  mkdir -p "${support_dir}/files"
  fetch_url "${PSONO_INSTALLER_BASE_URL%/}/files/cloud-init-user-data.yml.tmpl" "${support_dir}/files/cloud-init-user-data.yml.tmpl"
  fetch_url "${PSONO_INSTALLER_BASE_URL%/}/files/psonoctl.sh" "${support_dir}/files/psonoctl.sh"
  TEMPLATE_FILE="${support_dir}/files/cloud-init-user-data.yml.tmpl"
  PSONOCTL_FILE="${support_dir}/files/psonoctl.sh"
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

prompt_required() {
  local label="$1" value
  value="$(prompt "${label}" "${2:-}")"
  [[ -n "${value}" ]] || die "${label} is required"
  printf '%s\n' "${value}"
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
    value="$(prompt "${label} (true/false)" "${default}")"
    case "${value}" in
      true|false) printf '%s\n' "${value}"; return ;;
      *) echo "Enter true or false." >&2 ;;
    esac
  done
}

arg_value() {
  local current="$1" next="${2:-}"
  if [[ "${current}" == *=* ]]; then
    printf '%s\n' "${current#*=}"
  else
    [[ -n "${next}" ]] || die "Missing value for ${current}"
    printf '%s\n' "${next}"
  fi
}

validate_bool() {
  local label="$1" value="$2"
  case "${value}" in
    true|false|"") ;;
    *) die "${label} must be true or false" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        usage
        exit 0
        ;;
      --vmid|--vmid=*) VMID_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --name|--name=*) VM_NAME_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --cores|--cores=*) CORES_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --memory|--memory=*) MEMORY_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --disk|--disk=*) DISK_GB_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --bridge|--bridge=*) BRIDGE_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --storage|--storage=*) STORAGE_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --snippet-storage|--snippet-storage=*) SNIPPET_STORAGE_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --ssh-key|--ssh-key=*) SSH_KEY_FILE_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --image-url|--image-url=*) IMAGE_URL_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --refresh-image) REFRESH_IMAGE_ARG="true"; shift ;;
      --access-mode|--access-mode=*) ACCESS_MODE_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --tailscale-auth-key|--tailscale-auth-key=*) TAILSCALE_AUTH_KEY_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --tailscale-hostname|--tailscale-hostname=*) TAILSCALE_HOSTNAME_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --tailscale-exposure|--tailscale-exposure=*) TAILSCALE_EXPOSURE_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --caddy-domain|--caddy-domain=*) CADDY_DOMAIN_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --caddy-email|--caddy-email=*) CADDY_EMAIL_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --allow-registration|--allow-registration=*) ALLOW_REGISTRATION_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp|--smtp=*) SMTP_ENABLED_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-from|--smtp-from=*) SMTP_EMAIL_FROM_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-host|--smtp-host=*) SMTP_HOST_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-user|--smtp-user=*) SMTP_HOST_USER_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-password|--smtp-password=*) SMTP_HOST_PASSWORD_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-port|--smtp-port=*) SMTP_PORT_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-use-tls|--smtp-use-tls=*) SMTP_USE_TLS_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-use-ssl|--smtp-use-ssl=*) SMTP_USE_SSL_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --smtp-timeout|--smtp-timeout=*) SMTP_TIMEOUT_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --yubikey|--yubikey=*) YUBIKEY_ENABLED_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --yubikey-client-id|--yubikey-client-id=*) YUBIKEY_CLIENT_ID_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --yubikey-secret-key|--yubikey-secret-key=*) YUBIKEY_SECRET_KEY_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --backup-mode|--backup-mode=*) BACKUP_MODE_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --r2-account-id|--r2-account-id=*) R2_ACCOUNT_ID_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --r2-bucket|--r2-bucket=*) R2_BUCKET_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --r2-prefix|--r2-prefix=*) R2_PREFIX_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --s3-endpoint|--s3-endpoint=*) S3_ENDPOINT_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --s3-bucket|--s3-bucket=*) S3_BUCKET_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --s3-prefix|--s3-prefix=*) S3_PREFIX_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --s3-region|--s3-region=*) S3_REGION_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --s3-access-key-id|--s3-access-key-id=*|--aws-access-key-id|--aws-access-key-id=*) S3_ACCESS_KEY_ID_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --s3-secret-access-key|--s3-secret-access-key=*|--aws-secret-access-key|--aws-secret-access-key=*) S3_SECRET_ACCESS_KEY_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      --restic-password|--restic-password=*) RESTIC_PASSWORD_ARG="$(arg_value "$1" "${2:-}")"; [[ "$1" == *=* ]] || shift; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  validate_bool "--allow-registration" "${ALLOW_REGISTRATION_ARG}"
  validate_bool "--smtp" "${SMTP_ENABLED_ARG}"
  validate_bool "--smtp-use-tls" "${SMTP_USE_TLS_ARG}"
  validate_bool "--smtp-use-ssl" "${SMTP_USE_SSL_ARG}"
  validate_bool "--yubikey" "${YUBIKEY_ENABLED_ARG}"
  case "${ACCESS_MODE_ARG}" in
    ""|lab-http|tailscale-https|caddy-https) ;;
    *) die "--access-mode must be lab-http, tailscale-https, or caddy-https" ;;
  esac
  case "${TAILSCALE_EXPOSURE_ARG}" in
    ""|serve|funnel) ;;
    *) die "--tailscale-exposure must be serve or funnel" ;;
  esac
  case "${BACKUP_MODE_ARG}" in
    ""|none|r2|s3) ;;
    *) die "--backup-mode must be none, r2, or s3" ;;
  esac
}

shell_quote_line() {
  local key="$1" value="$2"
  printf "%s=%q\n" "${key}" "${value}"
}

indent_block() {
  sed 's/^/      /'
}

b64_file_block() {
  base64 -w 0 "$1" | fold -w 76 | indent_block
}

b64_string_block() {
  base64 -w 0 | fold -w 76 | indent_block
}

next_vmid() {
  pvesh get /cluster/nextid
}

vm_exists() {
  qm status "$1" >/dev/null 2>&1
}

vm_name_exists() {
  qm list | awk 'NR > 1 {print $2}' | grep -Fxq "$1"
}

storage_exists() {
  pvesm status | awk 'NR > 1 {print $1}' | grep -qx "$1"
}

snippet_path() {
  local storage="$1" file="$2"
  pvesm path "${storage}:snippets/${file}"
}

render_template() {
  local vm_name="$1" bootstrap_b64="$2" psonoctl_b64="$3" output="$4"
  awk \
    -v vm_name="${vm_name}" \
    -v bootstrap="${bootstrap_b64}" \
    -v psonoctl="${psonoctl_b64}" '
      /__VM_NAME__/ { gsub("__VM_NAME__", vm_name) }
      /__BOOTSTRAP_B64__/ { print bootstrap; next }
      /__PSONOCTL_B64__/ { print psonoctl; next }
      { print }
    ' "${TEMPLATE_FILE}" >"${output}"
}

download_image() {
  local image_url="$1" image_path="$2" refresh_image="$3" tmp_path
  if [[ -f "${image_path}" && "${refresh_image}" != "true" ]]; then
    info "Using existing image ${image_path}"
    return
  fi
  tmp_path="${image_path}.tmp.$$"
  info "Downloading Debian cloud image"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "${image_url}" -o "${tmp_path}" || { rm -f "${tmp_path}"; return 1; }
  else
    wget -O "${tmp_path}" "${image_url}" || { rm -f "${tmp_path}"; return 1; }
  fi
  mv "${tmp_path}" "${image_path}"
}

make_bootstrap_script() {
  local output="$1"
  shift
  {
    cat <<'BOOTSTRAP_HEAD'
#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/psono-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/.config/psono-installer
chmod 0700 /root/.config/psono-installer

BOOTSTRAP_HEAD
    for kv in "$@"; do
      printf '%s\n' "${kv}"
    done
    cat <<'BOOTSTRAP_BODY'

write_psono_env() {
  cat >/root/.config/psono-installer/psono.env <<EOF_ENV
ACCESS_MODE=${ACCESS_MODE@Q}
PUBLIC_URL=${PUBLIC_URL@Q}
ALLOWED_DOMAIN=${ALLOWED_DOMAIN@Q}
ALLOW_REGISTRATION=${ALLOW_REGISTRATION@Q}
SMTP_ENABLED=${SMTP_ENABLED@Q}
SMTP_EMAIL_FROM=${SMTP_EMAIL_FROM@Q}
SMTP_HOST=${SMTP_HOST@Q}
SMTP_HOST_USER=${SMTP_HOST_USER@Q}
SMTP_HOST_PASSWORD=${SMTP_HOST_PASSWORD@Q}
SMTP_PORT=${SMTP_PORT@Q}
SMTP_USE_TLS=${SMTP_USE_TLS@Q}
SMTP_USE_SSL=${SMTP_USE_SSL@Q}
SMTP_TIMEOUT=${SMTP_TIMEOUT@Q}
YUBIKEY_ENABLED=${YUBIKEY_ENABLED@Q}
YUBIKEY_CLIENT_ID=${YUBIKEY_CLIENT_ID@Q}
YUBIKEY_SECRET_KEY=${YUBIKEY_SECRET_KEY@Q}
EOF_ENV
  chmod 0600 /root/.config/psono-installer/psono.env
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

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

install_tailscale() {
  ensure_tun_device
  if command -v tailscale >/dev/null 2>&1; then
    return
  fi
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
}

ensure_tun_device() {
  mkdir -p /dev/net
  if [[ ! -c /dev/net/tun ]]; then
    modprobe tun || true
  fi
  if [[ ! -c /dev/net/tun ]]; then
    mknod /dev/net/tun c 10 200
    chmod 0666 /dev/net/tun
  fi
  [[ -c /dev/net/tun ]] || {
    echo "Tailscale requires /dev/net/tun inside the VM. Check the guest kernel and module support." >&2
    exit 1
  }
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    return
  fi
  apt-get update
  apt-get install -y caddy
  systemctl enable --now caddy
}

install_restic() {
  if [[ "${BACKUP_MODE}" == "none" ]]; then
    return
  fi
  apt-get update
  apt-get install -y restic
  cat >/root/.config/psono-installer/restic.env <<EOF_RESTIC
RESTIC_REPOSITORY=${RESTIC_REPOSITORY@Q}
RESTIC_PASSWORD=${RESTIC_PASSWORD@Q}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID@Q}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY@Q}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION@Q}
EOF_RESTIC
  chmod 0600 /root/.config/psono-installer/restic.env
  set -a
  # shellcheck disable=SC1091
  source /root/.config/psono-installer/restic.env
  set +a
  if ! restic snapshots >/dev/null 2>&1; then
    restic init
  fi
  cat >/etc/systemd/system/psono-backup.service <<'EOF_SERVICE'
[Unit]
Description=Psono restic backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/psonoctl backup
EOF_SERVICE
  cat >/etc/systemd/system/psono-backup.timer <<'EOF_TIMER'
[Unit]
Description=Daily Psono backup

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
  systemctl daemon-reload
  systemctl enable --now psono-backup.timer
}

configure_access() {
  case "${ACCESS_MODE}" in
    lab-http)
      if [[ -z "${PUBLIC_URL}" ]]; then
        PUBLIC_URL="http://$(primary_ip):10200"
      fi
      ;;
    tailscale-https)
      install_tailscale
      if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
        tailscale up --auth-key "${TAILSCALE_AUTH_KEY}" --hostname "${TAILSCALE_HOSTNAME}" --accept-dns=true
      else
        echo "No Tailscale auth key supplied. Open the login URL printed below to continue setup."
        tailscale up --hostname "${TAILSCALE_HOSTNAME}" --accept-dns=true
      fi
      local ts_name
      ts_name="$(tailscale status --json | jq -r '.Self.DNSName | sub("\\.$"; "")')"
      [[ -n "${ts_name}" && "${ts_name}" != "null" ]] || { echo "Could not derive Tailscale MagicDNS name"; exit 1; }
      PUBLIC_URL="https://${ts_name}"
      ;;
    caddy-https)
      PUBLIC_URL="https://${CADDY_DOMAIN}"
      install_caddy
      if [[ -n "${CADDY_EMAIL}" ]]; then
        cat >/etc/caddy/Caddyfile <<EOF_CADDY
{
  email ${CADDY_EMAIL}
}

${CADDY_DOMAIN} {
  reverse_proxy 127.0.0.1:10200
}
EOF_CADDY
      else
        cat >/etc/caddy/Caddyfile <<EOF_CADDY
${CADDY_DOMAIN} {
  reverse_proxy 127.0.0.1:10200
}
EOF_CADDY
      fi
      systemctl reload caddy
      ;;
    *)
      echo "Unknown ACCESS_MODE=${ACCESS_MODE}" >&2
      exit 1
      ;;
  esac
  if [[ -z "${ALLOWED_DOMAIN}" ]]; then
    ALLOWED_DOMAIN="$(public_host_from_url "${PUBLIC_URL}")"
  fi
}

configure_tailscale_exposure_service() {
  if [[ "${ACCESS_MODE}" != "tailscale-https" ]]; then
    return
  fi

  local exposure_cmd
  if [[ "${TAILSCALE_EXPOSURE}" == "funnel" ]]; then
    exposure_cmd="/usr/bin/tailscale funnel --bg --https=443 http://127.0.0.1:10200"
  else
    exposure_cmd="/usr/bin/tailscale serve --bg --https=443 http://127.0.0.1:10200"
  fi

  cat >/etc/systemd/system/psono-tailscale-exposure.service <<EOF_TAILSCALE_SERVICE
[Unit]
Description=Expose Psono through Tailscale ${TAILSCALE_EXPOSURE}
After=tailscaled.service docker.service
Wants=tailscaled.service docker.service

[Service]
Type=oneshot
ExecStart=${exposure_cmd}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_TAILSCALE_SERVICE

  systemctl daemon-reload
  systemctl enable --now psono-tailscale-exposure.service
}

main() {
  apt-get update
  apt-get install -y ca-certificates curl gnupg jq kmod lsb-release openssl qemu-guest-agent rsync tar
  systemctl enable --now qemu-guest-agent
  install_docker
  configure_access
  write_psono_env
  install_restic
  /usr/local/sbin/psonoctl bootstrap
  if [[ "${ACCESS_MODE}" == "tailscale-https" ]]; then
    configure_tailscale_exposure_service
  elif [[ "${ACCESS_MODE}" == "caddy-https" ]]; then
    systemctl reload caddy
  fi
  /usr/local/sbin/psonoctl health || true
}

main "$@"
BOOTSTRAP_BODY
  } >"${output}"
  chmod 0700 "${output}"
}

main() {
  parse_args "$@"

  require_root
  require_cmd qm
  require_cmd pvesm
  require_cmd pvesh
  require_cmd awk
  require_cmd base64
  require_cmd fold
  require_cmd sed
  ensure_support_files
  [[ -f "${TEMPLATE_FILE}" ]] || die "Missing ${TEMPLATE_FILE}"
  [[ -f "${PSONOCTL_FILE}" ]] || die "Missing ${PSONOCTL_FILE}"

  local vmid vm_name cores memory disk_gb bridge storage snippet_storage ssh_key_file image_url image_dir image_path
  vmid="${VMID_ARG:-$(prompt "VMID" "$(next_vmid)")}"
  vm_exists "${vmid}" && die "VMID already exists: ${vmid}"
  vm_name="${VM_NAME_ARG:-$(prompt "VM name" "psono-${vmid}")}"
  vm_name_exists "${vm_name}" && die "VM name already exists: ${vm_name}"
  cores="${CORES_ARG:-$(prompt "vCPU cores" "${DEFAULT_CORES}")}"
  memory="${MEMORY_ARG:-$(prompt "Memory MB" "${DEFAULT_MEMORY}")}"
  disk_gb="${DISK_GB_ARG:-$(prompt "Disk GB" "${DEFAULT_DISK_GB}")}"
  bridge="${BRIDGE_ARG:-$(prompt "Network bridge" "${DEFAULT_BRIDGE}")}"
  storage="${STORAGE_ARG:-$(prompt_required "VM disk storage" "local-lvm")}"
  storage_exists "${storage}" || die "Storage does not exist: ${storage}"
  snippet_storage="${SNIPPET_STORAGE_ARG:-$(prompt "Cloud-init snippets storage" "local")}"
  storage_exists "${snippet_storage}" || die "Snippet storage does not exist: ${snippet_storage}"
  ssh_key_file="${SSH_KEY_FILE_ARG:-$(prompt "SSH public key file (optional)" "${HOME}/.ssh/id_rsa.pub")}"
  image_url="${IMAGE_URL_ARG:-$(prompt "Debian 13 cloud image URL" "${DEFAULT_IMAGE_URL}")}"
  image_dir="/var/lib/vz/template/qcow2"
  image_path="${image_dir}/$(basename "${image_url}")"

  local access_mode public_url allowed_domain tailscale_auth_key tailscale_hostname tailscale_exposure caddy_domain caddy_email
  if [[ -z "${ACCESS_MODE_ARG}" ]]; then
    echo "Access modes: lab-http, tailscale-https, caddy-https"
  fi
  access_mode="${ACCESS_MODE_ARG:-$(prompt "Access mode" "lab-http")}"
  public_url=""
  allowed_domain=""
  tailscale_auth_key="${TAILSCALE_AUTH_KEY_ARG}"
  tailscale_hostname="${TAILSCALE_HOSTNAME_ARG:-${vm_name}}"
  tailscale_exposure="${TAILSCALE_EXPOSURE_ARG:-serve}"
  caddy_domain="${CADDY_DOMAIN_ARG}"
  caddy_email="${CADDY_EMAIL_ARG}"
  case "${access_mode}" in
    lab-http)
      echo "Lab HTTP is for testing only. Psono upstream requires trusted TLS for supported deployments."
      ;;
    tailscale-https)
      if [[ -z "${TAILSCALE_AUTH_KEY_ARG}" ]]; then
        echo "Tailscale auth key is optional. Leave blank to use the Tailscale login URL during VM bootstrap."
        tailscale_auth_key="$(prompt_secret "Tailscale auth key")"
      fi
      [[ -n "${TAILSCALE_HOSTNAME_ARG}" ]] || tailscale_hostname="$(prompt "Tailscale hostname" "${vm_name}")"
      [[ -n "${TAILSCALE_EXPOSURE_ARG}" ]] || tailscale_exposure="$(prompt "Tailscale exposure: serve or funnel" "serve")"
      case "${tailscale_exposure}" in
        serve|funnel) ;;
        *) die "Tailscale exposure must be serve or funnel" ;;
      esac
      ;;
    caddy-https)
      [[ -n "${caddy_domain}" ]] || caddy_domain="$(prompt_required "Public domain for Psono")"
      [[ -n "${CADDY_EMAIL_ARG}" ]] || caddy_email="$(prompt "ACME email (optional)" "")"
      public_url="https://${caddy_domain}"
      allowed_domain="${caddy_domain}"
      ;;
    *) die "Unknown access mode: ${access_mode}" ;;
  esac

  local allow_registration smtp_enabled smtp_email_from smtp_host smtp_host_user smtp_host_password smtp_port smtp_use_tls smtp_use_ssl smtp_timeout
  allow_registration="${ALLOW_REGISTRATION_ARG:-$(prompt_bool "Allow initial registration" "true")}"
  smtp_enabled="${SMTP_ENABLED_ARG:-$(prompt_bool "Configure SMTP email" "false")}"
  smtp_email_from="${SMTP_EMAIL_FROM_ARG}"
  smtp_host="${SMTP_HOST_ARG}"
  smtp_host_user="${SMTP_HOST_USER_ARG}"
  smtp_host_password="${SMTP_HOST_PASSWORD_ARG}"
  smtp_port="${SMTP_PORT_ARG:-587}"
  smtp_use_tls="${SMTP_USE_TLS_ARG:-true}"
  smtp_use_ssl="${SMTP_USE_SSL_ARG:-false}"
  smtp_timeout="${SMTP_TIMEOUT_ARG:-10}"
  if [[ "${smtp_enabled}" == "true" ]]; then
    [[ -n "${smtp_email_from}" ]] || smtp_email_from="$(prompt_required "Email from address")"
    [[ -n "${smtp_host}" ]] || smtp_host="$(prompt_required "SMTP host")"
    [[ -n "${smtp_host_user}" ]] || smtp_host_user="$(prompt "SMTP user" "${smtp_email_from}")"
    [[ -n "${smtp_host_password}" ]] || smtp_host_password="$(prompt_secret "SMTP password")"
    [[ -n "${SMTP_PORT_ARG}" ]] || smtp_port="$(prompt "SMTP port" "587")"
    [[ -n "${SMTP_USE_TLS_ARG}" ]] || smtp_use_tls="$(prompt_bool "Use SMTP STARTTLS" "true")"
    [[ -n "${SMTP_USE_SSL_ARG}" ]] || smtp_use_ssl="$(prompt_bool "Use SMTP implicit SSL" "false")"
    [[ -n "${SMTP_TIMEOUT_ARG}" ]] || smtp_timeout="$(prompt "SMTP timeout seconds" "10")"
  fi

  local yubikey_enabled yubikey_client_id yubikey_secret_key
  yubikey_enabled="${YUBIKEY_ENABLED_ARG:-$(prompt_bool "Configure YubiKey OTP" "false")}"
  yubikey_client_id="${YUBIKEY_CLIENT_ID_ARG}"
  yubikey_secret_key="${YUBIKEY_SECRET_KEY_ARG}"
  if [[ "${yubikey_enabled}" == "true" ]]; then
    [[ -n "${yubikey_client_id}" ]] || yubikey_client_id="$(prompt_required "Yubico client ID")"
    [[ -n "${yubikey_secret_key}" ]] || yubikey_secret_key="$(prompt_secret "Yubico secret key")"
  fi

  local backup_mode restic_repository restic_password aws_access_key_id aws_secret_access_key aws_default_region r2_account_id r2_bucket r2_prefix s3_endpoint s3_bucket s3_prefix
  if [[ -z "${BACKUP_MODE_ARG}" ]]; then
    echo "Backup modes: none, r2, s3"
  fi
  backup_mode="${BACKUP_MODE_ARG:-$(prompt "Backup mode" "none")}"
  restic_repository=""
  restic_password="${RESTIC_PASSWORD_ARG}"
  aws_access_key_id="${S3_ACCESS_KEY_ID_ARG}"
  aws_secret_access_key="${S3_SECRET_ACCESS_KEY_ARG}"
  aws_default_region="${S3_REGION_ARG:-auto}"
  case "${backup_mode}" in
    none) ;;
    r2)
      r2_account_id="${R2_ACCOUNT_ID_ARG:-$(prompt_required "Cloudflare account ID")}"
      r2_bucket="${R2_BUCKET_ARG:-$(prompt_required "R2 bucket")}"
      r2_prefix="${R2_PREFIX_ARG:-$(prompt "R2 prefix" "psono")}"
      [[ -n "${aws_access_key_id}" ]] || aws_access_key_id="$(prompt_required "R2 access key ID")"
      [[ -n "${aws_secret_access_key}" ]] || aws_secret_access_key="$(prompt_secret "R2 secret access key")"
      [[ -n "${restic_password}" ]] || restic_password="$(prompt_secret "Restic repository password")"
      restic_repository="s3:https://${r2_account_id}.r2.cloudflarestorage.com/${r2_bucket}/${r2_prefix}"
      aws_default_region="auto"
      ;;
    s3)
      s3_endpoint="${S3_ENDPOINT_ARG:-$(prompt_required "S3 endpoint URL")}"
      s3_bucket="${S3_BUCKET_ARG:-$(prompt_required "S3 bucket")}"
      s3_prefix="${S3_PREFIX_ARG:-$(prompt "S3 prefix" "psono")}"
      [[ -n "${S3_REGION_ARG}" ]] || aws_default_region="$(prompt "S3 region" "us-east-1")"
      [[ -n "${aws_access_key_id}" ]] || aws_access_key_id="$(prompt_required "S3 access key ID")"
      [[ -n "${aws_secret_access_key}" ]] || aws_secret_access_key="$(prompt_secret "S3 secret access key")"
      [[ -n "${restic_password}" ]] || restic_password="$(prompt_secret "Restic repository password")"
      restic_repository="s3:${s3_endpoint%/}/${s3_bucket}/${s3_prefix}"
      ;;
    *) die "Unknown backup mode: ${backup_mode}" ;;
  esac

  local tmpdir bootstrap_file user_data_file user_data_name psonoctl_b64 bootstrap_b64 snippet_file
  tmpdir="$(mktemp -d)"
  bootstrap_file="${tmpdir}/bootstrap-psono.sh"
  user_data_file="${tmpdir}/user-data.yml"
  user_data_name="psono-${vmid}-user-data.yml"

  make_bootstrap_script "${bootstrap_file}" \
    "$(shell_quote_line ACCESS_MODE "${access_mode}")" \
    "$(shell_quote_line PUBLIC_URL "${public_url}")" \
    "$(shell_quote_line ALLOWED_DOMAIN "${allowed_domain}")" \
    "$(shell_quote_line TAILSCALE_AUTH_KEY "${tailscale_auth_key}")" \
    "$(shell_quote_line TAILSCALE_HOSTNAME "${tailscale_hostname}")" \
    "$(shell_quote_line TAILSCALE_EXPOSURE "${tailscale_exposure}")" \
    "$(shell_quote_line CADDY_DOMAIN "${caddy_domain}")" \
    "$(shell_quote_line CADDY_EMAIL "${caddy_email}")" \
    "$(shell_quote_line ALLOW_REGISTRATION "${allow_registration}")" \
    "$(shell_quote_line SMTP_ENABLED "${smtp_enabled}")" \
    "$(shell_quote_line SMTP_EMAIL_FROM "${smtp_email_from}")" \
    "$(shell_quote_line SMTP_HOST "${smtp_host}")" \
    "$(shell_quote_line SMTP_HOST_USER "${smtp_host_user}")" \
    "$(shell_quote_line SMTP_HOST_PASSWORD "${smtp_host_password}")" \
    "$(shell_quote_line SMTP_PORT "${smtp_port}")" \
    "$(shell_quote_line SMTP_USE_TLS "${smtp_use_tls}")" \
    "$(shell_quote_line SMTP_USE_SSL "${smtp_use_ssl}")" \
    "$(shell_quote_line SMTP_TIMEOUT "${smtp_timeout}")" \
    "$(shell_quote_line YUBIKEY_ENABLED "${yubikey_enabled}")" \
    "$(shell_quote_line YUBIKEY_CLIENT_ID "${yubikey_client_id}")" \
    "$(shell_quote_line YUBIKEY_SECRET_KEY "${yubikey_secret_key}")" \
    "$(shell_quote_line BACKUP_MODE "${backup_mode}")" \
    "$(shell_quote_line RESTIC_REPOSITORY "${restic_repository}")" \
    "$(shell_quote_line RESTIC_PASSWORD "${restic_password}")" \
    "$(shell_quote_line AWS_ACCESS_KEY_ID "${aws_access_key_id}")" \
    "$(shell_quote_line AWS_SECRET_ACCESS_KEY "${aws_secret_access_key}")" \
    "$(shell_quote_line AWS_DEFAULT_REGION "${aws_default_region}")"

  psonoctl_b64="$(b64_file_block "${PSONOCTL_FILE}")"
  bootstrap_b64="$(b64_file_block "${bootstrap_file}")"
  render_template "${vm_name}" "${bootstrap_b64}" "${psonoctl_b64}" "${user_data_file}"

  snippet_file="$(snippet_path "${snippet_storage}" "${user_data_name}")"
  mkdir -p "$(dirname "${snippet_file}")"
  install -m 0600 "${user_data_file}" "${snippet_file}"

  mkdir -p "${image_dir}"
  download_image "${image_url}" "${image_path}" "${REFRESH_IMAGE_ARG}"

  info "Creating VM ${vmid} (${vm_name})"
  qm create "${vmid}" \
    --name "${vm_name}" \
    --memory "${memory}" \
    --cores "${cores}" \
    --net0 "virtio,bridge=${bridge}" \
    --ostype l26 \
    --agent enabled=1 \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0

  local import_output imported_volume
  import_output="$(qm importdisk "${vmid}" "${image_path}" "${storage}" 2>&1)"
  echo "${import_output}"
  imported_volume="$(printf '%s\n' "${import_output}" | sed -n "s/.*'\([^']*:vm-${vmid}-disk-[^']*\)'.*/\1/p" | tail -n 1)"
  if [[ -z "${imported_volume}" ]]; then
    imported_volume="${storage}:vm-${vmid}-disk-0"
  fi
  qm set "${vmid}" --scsi0 "${imported_volume}"
  qm disk resize "${vmid}" scsi0 "${disk_gb}G"
  qm set "${vmid}" --ide2 "${storage}:cloudinit"
  qm set "${vmid}" --boot c --bootdisk scsi0
  qm set "${vmid}" --ciuser psono
  qm set "${vmid}" --ipconfig0 ip=dhcp
  qm set "${vmid}" --cicustom "user=${snippet_storage}:snippets/${user_data_name}"
  if [[ -f "${ssh_key_file}" ]]; then
    qm set "${vmid}" --sshkeys "$(cat "${ssh_key_file}")"
  else
    echo "No SSH key installed. Use the Proxmox console if needed." >&2
  fi
  qm start "${vmid}"

  info "VM started. Cloud-init will install Psono in the guest."
  info "Check progress from the VM console or over SSH: sudo tail -f /var/log/psono-bootstrap.log"
  info "After boot: sudo psonoctl status"
}

main "$@"

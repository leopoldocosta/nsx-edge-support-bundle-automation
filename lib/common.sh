#!/usr/bin/env bash
# lib/common.sh — v3.16
# Shared library for all NSX Edge automations.
# Provides: SSH access (admin + root), IP loading, credential handling,
#           colored logging, box-drawing table helpers.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${LIB_DIR}/.." && pwd)"
AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
KEY_DIR="${AUTO_DIR}/.ssh_keys"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"
ADMIN_KEY="${KEY_DIR}/nsx_admin_key"
ROOT_KEY="${KEY_DIR}/nsx_root_key"

mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${KEY_DIR}"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_RED=$'\033[0;31m'
  C_CYAN=$'\033[0;36m'
  C_BLUE=$'\033[0;34m'
  C_MAGENTA=$'\033[0;35m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''
  C_RED=''; C_CYAN=''; C_BLUE=''; C_MAGENTA=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()      { printf '%s[%s]%s %s\n'           "${C_CYAN}"    "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_ok()   { printf '%s[%s] [OK]%s   %s\n'    "${C_GREEN}"   "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_warn() { printf '%s[%s] [WARN]%s %s\n'    "${C_YELLOW}"  "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_err()  { printf '%s[%s] [ERR]%s  %s\n'    "${C_RED}"     "$(date '+%F %T')" "${C_RESET}" "$*"; }

log_banner(){
  local title="$1"
  local width=76
  local pad=$(( (width - ${#title} - 2) / 2 ))
  printf '\n%s' "${C_BOLD}${C_BLUE}"
  printf '+'; printf '%0.s-' $(seq 1 $width); printf '+\n'
  printf '|%*s%s%*s|\n' $pad '' "$title" $pad ''
  printf '+'; printf '%0.s-' $(seq 1 $width); printf '+\n'
  printf '%s\n' "${C_RESET}"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
need_cmd(){
  command -v "$1" >/dev/null 2>&1 || {
    log_err "Missing required command: $1"
    exit 1
  }
}

# ---------------------------------------------------------------------------
# IP Management
# ---------------------------------------------------------------------------
collect_ips(){
  [[ -f "${EDGE_EXAMPLE}" ]] && echo "  Template: ${EDGE_EXAMPLE}"
  echo "Paste Edge Node IPs, one per line. Empty line to finish:"
  : > "${EDGE_FILE}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${EDGE_FILE}"
    else
      log_warn "Skipping invalid: ${line}"
    fi
  done
  log "$(wc -l < "${EDGE_FILE}" | tr -d ' ') IP(s) saved."
}

load_ips(){
  [[ ! -s "${EDGE_FILE}" ]] && collect_ips
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}" 2>/dev/null || true)
  [[ ${#EDGE_IPS[@]} -eq 0 ]] && { log_err "No valid IPs in ${EDGE_FILE}."; exit 1; }
  log "Loaded ${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already loaded from session file."; return 0
  fi
  read -rp  "Admin username [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Admin password (all special characters accepted): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credentials collected for user '${NSX_USER}'. Will be reused for all nodes."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already in environment."; return 0
  fi
  IFS= read -rsp "Root password (all special characters accepted): " ROOT_PASS; echo
  export ROOT_PASS
  log "Root credentials collected. Will be reused for all nodes."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  log "Credentials cleared from memory."
}

# ---------------------------------------------------------------------------
# SSH helper — password via temp file (never exposed in process args)
# ---------------------------------------------------------------------------
_sshpass_safe(){
  local _passvar="$1"; shift
  local _tmpfile
  _tmpfile="$(mktemp -t sshpass_XXXXXX)"
  chmod 600 "${_tmpfile}"
  printf '%s' "${!_passvar}" > "${_tmpfile}"
  SSHPASS="$(cat "${_tmpfile}")" sshpass -e "$@"
  local _rc=$?
  rm -f "${_tmpfile}"
  return $_rc
}

# ---------------------------------------------------------------------------
# SSH Functions
# stderr suprimido (2>/dev/null) para evitar que warnings locais do
# ssh_config (ex: gssapiauthentication) contaminem stdout dos callers.
# ---------------------------------------------------------------------------
ssh_admin(){
  local ip="$1"; shift
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes \
        "admin@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe NSX_PASS ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "${NSX_USER}@${ip}" "$@" 2>/dev/null
  fi
}

ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes \
        "root@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe ROOT_PASS ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "root@${ip}" "$@" 2>/dev/null
  fi
}

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd"; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd"; }

# ---------------------------------------------------------------------------
# Root SSH Control
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  log ">> ${ip}: set ssh root-login"
  admin_cmd "$ip" 'set service ssh root-login enabled' 2>/dev/null || true
  log "${ip}: [set ssh root-login] done"
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  log ">> ${ip}: clear ssh root-login"
  admin_cmd "$ip" 'set service ssh root-login disabled' 2>/dev/null || true
  log "${ip}: [clear ssh root-login] done"
}

# ---------------------------------------------------------------------------
# Support Bundle helpers
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  admin_cmd "$ip" 'start support-bundle' || true
}

check_support_bundle(){
  local ip="$1"
  local out_log out_files out_root
  out_log="$(root_cmd "$ip" \
    "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
  out_files="$(root_cmd "$ip" \
    "find /var/log /storage /tmp -maxdepth 3 \( -name '*support*bundle*' -o -name '*.tgz' -o -name '*.tar.gz' \) -type f 2>/dev/null | head -20")"
  out_root="$(root_cmd "$ip" "getent passwd root >/dev/null 2>&1; echo ROOT_OK")"
  printf '%s\n----FILES----\n%s\n----ROOT----\n%s\n' "$out_log" "$out_files" "$out_root"
}

# ---------------------------------------------------------------------------
# list_remote_bundles — aceita APENAS sb_*.tgz (descarta stderr e outros
# arquivos que possam ter vazado para stdout).
# ---------------------------------------------------------------------------
list_remote_bundles(){
  local ip="$1"
  root_cmd "$ip" "ls /var/vmware/nsx/file-store/ 2>/dev/null" \
    | grep -E '^sb_.*\.tgz$' || true
}

# ---------------------------------------------------------------------------
# bundle_file_date — extrai data do nome do bundle
# Padrao: sb_IP_YYYYMMDD_HHMMSS.tgz → "YYYY-MM-DD HH:MM"
# ---------------------------------------------------------------------------
bundle_file_date(){
  local fname="$1"
  if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})[0-9]{2}\.tgz$ ]]; then
    printf '%s-%s-%s %s:%s' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  else
    printf ''
  fi
}

# ---------------------------------------------------------------------------
# Box-drawing table helpers (ASCII-safe, sem Unicode)
# Colunas: NODE(19) STATUS(18) ACAO(18) ARQUIVO(18) DURACAO(12)
# ---------------------------------------------------------------------------
tbl_header(){
  local title="${1:-PRE-CHECK -- Estado dos Support Bundles}"
  printf '+--------------------------------------------------------------------------------------------+\n'
  printf '| %-90s |\n' "${title}  $(date '+%F %T')"
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n'
  printf '| %-19s | %-18s | %-18s | %-18s | %-12s |\n' 'NODE' 'STATUS' 'ACAO' 'ARQUIVO' 'DURACAO'
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n'
}

tbl_row(){
  # $1=ip $2=status $3=acao $4=arquivo $5=duracao
  printf '| %-19s | %-18s | %-18s | %-18s | %-12s |\n' \
    "$1" "${2:0:18}" "${3:0:18}" "${4:0:18}" "${5:0:12}"
}

tbl_footer(){
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n\n'
}

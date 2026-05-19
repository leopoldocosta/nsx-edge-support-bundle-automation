#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh — v3.15
# Deploy local do kit NSX Edge Automation - Support Bundle
#
# USO:  bash deploy_nsx_sb_check.sh [--dir /caminho/destino]
# Padrao: ~/nsx-edge-automation
# =============================================================================
set -euo pipefail

BASE_DIR="${HOME}/nsx-edge-automation"
if [[ "${1:-}" == "--dir" && -n "${2:-}" ]]; then
  BASE_DIR="$2"
fi

AUTO_DIR="${BASE_DIR}/automations/support_bundle"
LIB_DIR="${BASE_DIR}/lib"
DOCS_DIR="${BASE_DIR}/docs"
EXAMPLES_DIR="${BASE_DIR}/examples"

mkdir -p \
  "${AUTO_DIR}/logs" \
  "${AUTO_DIR}/run" \
  "${AUTO_DIR}/.ssh_keys" \
  "${LIB_DIR}" \
  "${DOCS_DIR}" \
  "${EXAMPLES_DIR}"
chmod 700 "${AUTO_DIR}/.ssh_keys"

echo ""
echo "==> Instalando em: ${BASE_DIR}"
echo ""

# ===========================================================================
# .gitignore
# ===========================================================================
cat > "${BASE_DIR}/.gitignore" << 'GITIGNORE'
logs/
run/
*.log
*.csv
.env
session.env
.ssh_keys/
*.pem
*.key
id_*
edge_nodes.txt
*.swp
*.tmp
__pycache__/
GITIGNORE

# ===========================================================================
# README.md raiz
# ===========================================================================
cat > "${BASE_DIR}/README.md" << 'README'
# NSX Edge Automations

Bash automation toolkit for managing NSX Edge Nodes (NSX-T / VMware NSX).

## Structure

```
.
├── lib/
│   └── common.sh                  # Shared: SSH, auth, IP loading, colors, tables
├── automations/
│   └── support_bundle/
│       ├── edge_nodes.example
│       ├── deploy_nsx_sb_check.sh
│       ├── install_dependencies.sh
│       ├── setup_keys.sh
│       ├── test_connections.sh
│       ├── nsx_sb_precheck.sh     # Pre-check standalone (com --clean-all)
│       ├── nsx_sb_main.sh         # Orquestrador completo
│       ├── admin_exec.sh
│       └── root_exec.sh
├── docs/
└── examples/
```

## Quick Start

```bash
bash automations/support_bundle/deploy_nsx_sb_check.sh
cd ~/nsx-edge-automation/automations/support_bundle
cp edge_nodes.example edge_nodes.txt
vim edge_nodes.txt
./install_dependencies.sh
./setup_keys.sh
./test_connections.sh
screen -S nsx_sb && ./nsx_sb_main.sh
```

## License

MIT
README

# ===========================================================================
# lib/common.sh
# ===========================================================================
cat > "${LIB_DIR}/common.sh" << 'COMMON'
#!/usr/bin/env bash
# lib/common.sh — v3.15
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

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m';    C_BOLD=$'\033[1m'
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_RED=$'\033[0;31m';   C_CYAN=$'\033[0;36m'
  C_BLUE=$'\033[0;34m';  C_MAGENTA=$'\033[0;35m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''
  C_RED=''; C_CYAN=''; C_BLUE=''; C_MAGENTA=''
fi

log()      { printf '%s[%s]%s %s\n'           "${C_CYAN}"   "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_ok()   { printf '%s[%s] [OK]%s   %s\n'    "${C_GREEN}"  "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_warn() { printf '%s[%s] [WARN]%s %s\n'    "${C_YELLOW}" "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_err()  { printf '%s[%s] [ERR]%s  %s\n'    "${C_RED}"    "$(date '+%F %T')" "${C_RESET}" "$*"; }

log_banner(){
  local title="$1" width=76
  local pad=$(( (width - ${#title} - 2) / 2 ))
  printf '\n%s' "${C_BOLD}${C_BLUE}"
  printf '+'; printf '%0.s-' $(seq 1 $width); printf '+\n'
  printf '|%*s%s%*s|\n' $pad '' "$title" $pad ''
  printf '+'; printf '%0.s-' $(seq 1 $width); printf '+\n'
  printf '%s\n' "${C_RESET}"
}

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { log_err "Missing required command: $1"; exit 1; }
}

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

ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already loaded from session file."; return 0
  fi
  read -rp "Admin username [admin]: " NSX_USER
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

ssh_admin(){
  local ip="$1"; shift
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes "admin@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe NSX_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "${NSX_USER}@${ip}" "$@" 2>/dev/null
  fi
}

ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes "root@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe ROOT_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "root@${ip}" "$@" 2>/dev/null
  fi
}

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd"; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd"; }

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

list_remote_bundles(){
  local ip="$1"
  root_cmd "$ip" "ls /var/vmware/nsx/file-store/ 2>/dev/null" \
    | grep -E '^sb_.*\.tgz$' || true
}

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

tbl_header(){
  local title="${1:-PRE-CHECK}"
  printf '+------------------------------------------------------------------------------+\n'
  printf '| %-76s |\n' "${title}  $(date '+%F %T')"
  printf '+---------------------+--------------------+--------------------+--------------------+\n'
  printf '| %-19s | %-18s | %-18s | %-18s |\n' 'NODE' 'STATUS' 'ACAO' 'ARQUIVO'
  printf '+---------------------+--------------------+--------------------+--------------------+\n'
}

tbl_row(){
  printf '| %-19s | %-18s | %-18s | %-18s |\n' \
    "$1" "${2:0:18}" "${3:0:18}" "${4:0:18}"
}

tbl_footer(){
  printf '+---------------------+--------------------+--------------------+--------------------+\n\n'
}
COMMON
chmod +x "${LIB_DIR}/common.sh"

# ===========================================================================
# edge_nodes.example
# ===========================================================================
cat > "${AUTO_DIR}/edge_nodes.example" << 'EXAMPLE'
# edge_nodes.example
# Copie para edge_nodes.txt e adicione os IPs reais (um por linha).
# Linhas com # sao ignoradas.
#
# Exemplo:
# 192.168.10.10
# 192.168.10.11
EXAMPLE

# ===========================================================================
# install_dependencies.sh
# ===========================================================================
cat > "${AUTO_DIR}/install_dependencies.sh" << 'INST'
#!/usr/bin/env bash
set -euo pipefail
OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
if [[ "$OS_ID" =~ (ubuntu|debian) ]]; then
  sudo apt-get update
  sudo apt-get install -y openssh-client sshpass expect screen
elif [[ "$OS_ID" =~ (ol|oracle|rhel|centos|rocky|almalinux|fedora) ]]; then
  sudo dnf install -y openssh-clients sshpass expect screen 2>/dev/null \
    || sudo yum install -y openssh-clients sshpass expect screen
else
  echo "[WARN] OS '${OS_ID}' nao reconhecido. Instale: openssh-client sshpass expect screen"
fi
echo "[OK] Dependencias instaladas."
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

# ===========================================================================
# setup_keys.sh
# ===========================================================================
cat > "${AUTO_DIR}/setup_keys.sh" << 'SETUP'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh-keygen
need_cmd sshpass
load_ips
ask_admin_creds
[[ -f "${ADMIN_KEY}" ]] || ssh-keygen -t ed25519 -f "${ADMIN_KEY}" -N '' -C 'nsx-admin-key' -q
[[ -f "${ROOT_KEY}" ]]  || ssh-keygen -t ed25519 -f "${ROOT_KEY}"  -N '' -C 'nsx-root-key'  -q
ADMIN_PUB="$(cat "${ADMIN_KEY}.pub")"
ROOT_PUB="$(cat "${ROOT_KEY}.pub")"
for ip in "${EDGE_IPS[@]}"; do
  log "Distribuindo chaves para ${ip}..."
  admin_cmd "$ip" "set user admin ssh-key \"${ADMIN_PUB}\"" || true
  enable_root_ssh "$ip"
  admin_cmd "$ip" "set user root ssh-key \"${ROOT_PUB}\""  || true
  disable_root_ssh "$ip"
  log_ok "${ip}: chaves distribuidas."
done
clear_creds
log_ok "Setup de chaves SSH concluido."
SETUP
chmod +x "${AUTO_DIR}/setup_keys.sh"

# ===========================================================================
# test_connections.sh
# ===========================================================================
cat > "${AUTO_DIR}/test_connections.sh" << 'TESTC'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds
REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"
log "Relatorio: ${REPORT}"
for ip in "${EDGE_IPS[@]}"; do
  {
    echo "====== Node: ${ip} ======"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping falhou"
    admin_cmd "$ip" 'get version'      || echo "FAIL: get version"
    admin_cmd "$ip" 'get service ssh'  || echo "FAIL: get service ssh"
    enable_root_ssh "$ip"; sleep 2
    root_cmd "$ip" 'uname -a'          || echo "FAIL: uname"
    root_cmd "$ip" 'uptime'            || echo "FAIL: uptime"
    root_cmd "$ip" 'df -h /var/log'    || echo "FAIL: df"
    disable_root_ssh "$ip"
    echo
  } | tee -a "$REPORT"
done
clear_creds
log_ok "Teste concluido. Relatorio: ${REPORT}"
TESTC
chmod +x "${AUTO_DIR}/test_connections.sh"

# ===========================================================================
# nsx_sb_precheck.sh
# ===========================================================================
cat > "${AUTO_DIR}/nsx_sb_precheck.sh" << 'PRECHECK'
#!/usr/bin/env bash
# nsx_sb_precheck.sh — v3.15
# Verifica estado dos support bundles sem disparar nova geracao.
# Flags: --clean-all  remove TODOS os bundles existentes
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh
load_ips
SESSION_FILE="${RUN_DIR}/session.env"
if [[ -f "${SESSION_FILE}" ]]; then
  source "${SESSION_FILE}"
  log "Admin credentials loaded from session file."
fi
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds
log_banner "PRE-CHECK -- Estado dos Support Bundles"
CLEAN_ALL=false
[[ "${1:-}" == "--clean-all" ]] && CLEAN_ALL=true && log "=== CLEAN-ALL: Apagando TODOS os bundles ==="
declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP
now_epoch=$(date +%s)
for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"
  last_log="$(root_cmd "$ip" "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
  printf '\n  +-- %s: support_bundle.log (ultima linha) --+\n  |  %s\n  +-------------------------------------------+\n\n' "$ip" "$last_log"
  echo "$last_log" | grep -qiE 'error|fail|unable|denied' && log_warn "${ip}: possivel erro no log." || log_ok "${ip}: log sem erros."
  if [[ "$CLEAN_ALL" == true ]]; then
    mapfile -t all_bundles < <(list_remote_bundles "$ip")
    log "${ip}: ${#all_bundles[@]} bundle(s) para deletar."
    for f in "${all_bundles[@]}"; do
      log ">> ${ip}: rm -f /var/vmware/nsx/file-store/${f}"
      root_cmd "$ip" "rm -f /var/vmware/nsx/file-store/${f}" || true
      log_warn "${ip}: deletado -- ${f}"
    done
    log_ok "${ip}: limpeza concluida."
    disable_root_ssh "$ip"
    PC_STATUS["$ip"]="LIMPO"; PC_ACAO["$ip"]="LIMPO"; PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"
    continue
  fi
  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  printf '\n  +-- %s: ls -lh /var/vmware/nsx/file-store/ --+\n' "$ip"
  while IFS= read -r line; do printf '  |  %s\n' "$line"; done <<< "$ls_out"
  printf '  +----------------------------------------------+\n\n'
  raw_list="$(list_remote_bundles "$ip")"
  log "${ip}: bundles: '${raw_list}'"
  local_recent=(); local_old=(); total_count=0
  while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue; (( total_count++ ))
    age_days=999
    if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{6}\.tgz$ ]]; then
      fyear="${BASH_REMATCH[1]}" fmon="${BASH_REMATCH[2]}" fday="${BASH_REMATCH[3]}"
      file_epoch=$(date -d "${fyear}-${fmon}-${fday}" +%s 2>/dev/null || echo "$now_epoch")
      age_days=$(( (now_epoch - file_epoch) / 86400 ))
    fi
    log "${ip}: '${fname}' -> ${age_days} dia(s)."
    [[ $age_days -le 7 ]] && local_recent+=("$fname") || local_old+=("$fname")
  done <<< "$raw_list"
  log "${ip}: ${total_count} bundle(s)."
  printf '\n  +-- %s: %d recente(s) | %d antigo(s) --+\n' "$ip" "${#local_recent[@]}" "${#local_old[@]}"
  for f in "${local_recent[@]}"; do printf '  |  [OK]  %s\n' "$f"; done
  for f in "${local_old[@]}";   do printf '  |  [OLD] %s\n' "$f"; done
  printf '  +----------------------------------------------+\n\n'
  if [[ ${#local_recent[@]} -gt 0 ]]; then
    newest="$(printf '%s\n' "${local_recent[@]}" | sort | tail -1)"
    file_date="$(bundle_file_date "${newest}")"
    PC_STATUS["$ip"]="${file_date:-RECENTE}"; PC_ACAO["$ip"]="OK"
    PC_FILE["$ip"]="${newest}"; PC_SKIP["$ip"]="true"
    log_ok "${ip}: bundle recente -- geracao sera pulada."
    [[ ${#local_old[@]} -gt 0 ]] && log_warn "${ip}: bundle(s) antigo(s) -- use --clean-all."
  elif [[ $total_count -gt 0 ]]; then
    PC_STATUS["$ip"]="ANTIGO (>7d)"; PC_ACAO["$ip"]="GERAR"; PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"
    log_warn "${ip}: apenas bundles antigos."
  else
    PC_STATUS["$ip"]="NENHUM"; PC_ACAO["$ip"]="GERAR"; PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"
    log "${ip}: nenhum bundle."
  fi
  disable_root_ssh "$ip"
done
precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,acao,arquivo' > "$precheck_csv"
tbl_header "PRE-CHECK -- Estado dos Support Bundles"
for ip in "${EDGE_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}"
  printf '%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}" >> "$precheck_csv"
done
tbl_footer
log_ok "Pre-check concluido. CSV: ${precheck_csv}"
printf '%s[%s]%s Para gerar:    ./nsx_sb_main.sh\n' "${C_CYAN}" "$(date '+%F %T')" "${C_RESET}"
printf '%s[%s]%s Para limpar:   ./nsx_sb_precheck.sh --clean-all\n' "${C_CYAN}" "$(date '+%F %T')" "${C_RESET}"
PRECHECK
chmod +x "${AUTO_DIR}/nsx_sb_precheck.sh"

# ===========================================================================
# nsx_sb_main.sh
# ===========================================================================
cat > "${AUTO_DIR}/nsx_sb_main.sh" << 'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh — v3.15
# Orquestrador: PRE-CHECK + Fase 1 (solicita SB) + Fase 2 (verifica 5min/30min)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
if [[ "${1:-}" == "--clean-all" || "${1:-}" == "--precheck" ]]; then
  exec "${SCRIPT_DIR}/nsx_sb_precheck.sh" "${1}"
fi
need_cmd ssh
load_ips
SESSION_FILE="${RUN_DIR}/session.env"
if [[ -f "${SESSION_FILE}" ]]; then source "${SESSION_FILE}"; log "Admin credentials loaded from session file."; fi
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds
RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"
EXPIRY_EPOCH="$(( $(date +%s) + 1800 ))"
auto_clear_bg(){ ( while [[ "$(date +%s)" -lt "$1" ]]; do sleep 5; done; rm -f "${RUN_DIR}/session.env" 2>/dev/null ) >/dev/null 2>&1 & }
if [[ -n "${NSX_PASS:-}" ]]; then
  umask 077
  printf 'export NSX_USER=%q\nexport NSX_PASS=%q\nexport ROOT_PASS=%q\n' \
    "${NSX_USER}" "${NSX_PASS}" "${ROOT_PASS:-}" > "${SESSION_FILE}"
  auto_clear_bg "$EXPIRY_EPOCH"
fi
log_banner "PRE-CHECK -- Estado dos Support Bundles"
declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP
now_epoch=$(date +%s)
for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: PRE-CHECK..."
  enable_root_ssh "$ip"
  last_log="$(root_cmd "$ip" "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
  printf '\n  +-- %s: support_bundle.log --+\n  |  %s\n  +----------------------------+\n\n' "$ip" "$last_log"
  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  printf '  +-- %s: ls file-store/ --+\n' "$ip"
  while IFS= read -r line; do printf '  |  %s\n' "$line"; done <<< "$ls_out"
  printf '  +-------------------------+\n\n'
  raw_list="$(list_remote_bundles "$ip")"
  local_recent=(); local_old=(); total_count=0
  while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue; (( total_count++ ))
    age_days=999
    if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{6}\.tgz$ ]]; then
      fyear="${BASH_REMATCH[1]}" fmon="${BASH_REMATCH[2]}" fday="${BASH_REMATCH[3]}"
      file_epoch=$(date -d "${fyear}-${fmon}-${fday}" +%s 2>/dev/null || echo "$now_epoch")
      age_days=$(( (now_epoch - file_epoch) / 86400 ))
    fi
    [[ $age_days -le 7 ]] && local_recent+=("$fname") || local_old+=("$fname")
  done <<< "$raw_list"
  if [[ ${#local_recent[@]} -gt 0 ]]; then
    newest="$(printf '%s\n' "${local_recent[@]}" | sort | tail -1)"
    file_date="$(bundle_file_date "${newest}")"
    PC_STATUS["$ip"]="${file_date:-RECENTE}"; PC_ACAO["$ip"]="OK"
    PC_FILE["$ip"]="${newest}"; PC_SKIP["$ip"]="true"
    log_ok "${ip}: bundle recente -- geracao pulada."
  elif [[ $total_count -gt 0 ]]; then
    PC_STATUS["$ip"]="ANTIGO (>7d)"; PC_ACAO["$ip"]="GERAR"; PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"
  else
    PC_STATUS["$ip"]="NENHUM"; PC_ACAO["$ip"]="GERAR"; PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"
  fi
done
precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,acao,arquivo' > "$precheck_csv"
tbl_header "PRE-CHECK"
for ip in "${EDGE_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}"
  printf '%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}" >> "$precheck_csv"
done
tbl_footer
log_ok "Pre-check concluido. CSV: ${precheck_csv}"
log_banner "FASE 1 -- Solicitacao do Support Bundle"
for ip in "${EDGE_IPS[@]}"; do
  if [[ "${PC_SKIP[$ip]:-false}" == "true" ]]; then log "${ip}: pulando."; continue; fi
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Fase 1 concluida."
log_banner "FASE 2 -- Verificacao"
declare -A NODE_DONE
for ip in "${EDGE_IPS[@]}"; do NODE_DONE["$ip"]="false"; done
for ((round=1; round<=6; round++)); do
  log "Verificacao ${round}/6 -- aguardando 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err "${ip}: erro -- encerrando."
      printf '%s,phase2,error,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok "${ip}: bundle confirmado."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: pendente..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done
log_banner "RELATORIO FINAL"
tbl_header "RELATORIO FINAL"
for ip in "${EDGE_IPS[@]}"; do tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}"; done
tbl_footer
log_banner "FINAL -- Desabilitando root SSH"
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
clear_creds
rm -f "${SESSION_FILE}" 2>/dev/null || true
log_ok "Concluido. CSV: ${STATUS_CSV}"
MAIN
chmod +x "${AUTO_DIR}/nsx_sb_main.sh"

# ===========================================================================
# admin_exec.sh
# ===========================================================================
cat > "${AUTO_DIR}/admin_exec.sh" << 'ADMX'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
echo ""
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] Todos"; echo ""
read -rp 'No (numero ou A): ' SEL
read -rp 'Comando NSX-T admin CLI: ' CMD; echo ""
run(){ echo "===== admin@${1} ====="; admin_cmd "$1" "$CMD" || true; echo; }
if [[ "${SEL^^}" == "A" ]]; then for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then run "${EDGE_IPS[$((SEL-1))]}"
else echo "[ERROR] Selecao invalida."; exit 1; fi
clear_creds
ADMX
chmod +x "${AUTO_DIR}/admin_exec.sh"

# ===========================================================================
# root_exec.sh
# ===========================================================================
cat > "${AUTO_DIR}/root_exec.sh" << 'ROTX'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds
echo ""
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] Todos"; echo ""
read -rp 'No (numero ou A): ' SEL
read -rp 'Comando Linux root: ' CMD
read -rp '[AVISO] Confirma execucao root em producao? [s/N]: ' CONFIRM
[[ "${CONFIRM,,}" =~ ^(s|y)$ ]] || { echo "Cancelado."; exit 0; }
run(){
  local ip="$1"; echo "===== root@${ip} ====="
  enable_root_ssh "$ip"; sleep 2
  root_cmd "$ip" "$CMD" || true
  disable_root_ssh "$ip"; echo
}
if [[ "${SEL^^}" == "A" ]]; then for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then run "${EDGE_IPS[$((SEL-1))]}"
else echo "[ERROR] Selecao invalida."; exit 1; fi
clear_creds
ROTX
chmod +x "${AUTO_DIR}/root_exec.sh"

# ===========================================================================
# README support_bundle
# ===========================================================================
cat > "${AUTO_DIR}/README.md" << 'SBREADME'
# Automation: Support Bundle Collection — v3.15

## Scripts

| Script | Descricao |
|--------|----------|
| `nsx_sb_precheck.sh` | Pre-check standalone; `--clean-all` remove todos os bundles |
| `nsx_sb_main.sh` | Orquestrador completo: precheck + geracao + verificacao |
| `admin_exec.sh` | Executa qualquer comando NSX CLI como admin |
| `root_exec.sh` | Executa qualquer comando Linux como root |

## Workflow

```bash
cd automations/support_bundle
cp edge_nodes.example edge_nodes.txt && vim edge_nodes.txt
./install_dependencies.sh
./setup_keys.sh
./test_connections.sh
./nsx_sb_precheck.sh          # verifica estado atual
screen -S nsx_sb && ./nsx_sb_main.sh   # coleta completa
```
SBREADME

# ===========================================================================
# Sumario final
# ===========================================================================
echo ""
echo "========================================================"
echo " Kit NSX Edge Automation instalado com sucesso! v3.15"
echo "========================================================"
echo ""
echo "  Localizacao : ${BASE_DIR}"
echo ""
echo "  Proximos passos:"
echo "    cd ${AUTO_DIR}"
echo "    cp edge_nodes.example edge_nodes.txt"
echo "    # Edite edge_nodes.txt com os IPs reais"
echo "    ./install_dependencies.sh"
echo "    ./setup_keys.sh"
echo "    ./test_connections.sh"
echo "    ./nsx_sb_precheck.sh              # pre-check standalone"
echo "    screen -S nsx_sb && ./nsx_sb_main.sh"
echo ""
echo "  Senhas: coletadas uma vez, qualquer caractere aceito."
echo ""

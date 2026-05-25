#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  v3.16.4
# Deploy local do kit NSX Edge Automation - Support Bundle
#
# CHANGELOG v3.16.4:
#   - FIX: nsx_sb_precheck.sh usava regex no nome do arquivo para calcular
#     idade do bundle. Qualquer nome fora do padrao sb_IP_YYYYMMDD_HHMMSS.tgz
#     recebia pc_age_days=999 ("antigo"). Corrigido para usar stat -c '%Y'
#     diretamente no node remoto — funciona com qualquer nome de arquivo.
#
# CHANGELOG v3.16.3:
#   - FIX: _save_creds — senha com caracteres especiais (%, !, $, \) nao
#     corrompe mais o arquivo de sessao.
#
# CHANGELOG v3.16.2:
#   - FIX: (( pc_total++ )) -> pc_total=$(( pc_total + 1 ))
#
# CHANGELOG v3.16.1:
#   - FIX: removido 'local' fora de funcao no loop for ip.
#
# CHANGELOG v3.16:
#   - nsx_sb_precheck.sh: nova coluna DURACAO.
#   - common.sh: KEY_DIR, ADMIN_KEY, ROOT_KEY.
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

mkdir -p "${AUTO_DIR}/logs" "${AUTO_DIR}/run" "${AUTO_DIR}/.ssh_keys" "${LIB_DIR}" "${DOCS_DIR}" "${EXAMPLES_DIR}"

echo ""
echo "================================================================"
echo "  NSX Edge Automation — Support Bundle Kit  v3.16.4"
echo "  Destino: ${BASE_DIR}"
echo "================================================================"
echo ""

cat <<'TREE'
Estrutura que sera criada:
  nsx-edge-automation/
  ├── lib/
  │   └── common.sh
  ├── automations/
  │   └── support_bundle/
  │       ├── edge_nodes.txt
  │       ├── nsx_sb_main.sh
  │       ├── nsx_sb_precheck.sh
  │       ├── test_connections.sh
  │       ├── admin_exec.sh
  │       ├── root_exec.sh
  │       ├── nsx_ssh_cli.sh
  │       └── install_dependencies.sh
  └── docs/
      └── MANUAL.md
TREE
echo ""

cat > "${BASE_DIR}/.gitignore" <<'GITIGNORE'
logs/
run/
*.log
*.csv
edge_nodes.txt
.env
session.env
.ssh_keys/
GITIGNORE

# ---------------------------------------------------------------------------
# lib/common.sh  — v3.16.4
# ---------------------------------------------------------------------------
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh  — v3.16.4
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

_C_RESET='\033[0m'
_C_WHITE='\033[0;37m'
_C_GREEN='\033[1;32m'
_C_YELLOW='\033[1;33m'
_C_RED='\033[1;31m'
_C_CYAN='\033[1;36m'
_C_MAGENTA='\033[0;35m'
_C_BLUE_BOLD='\033[1;34m'
_C_BOX_TITLE='\033[44;1;37m'
_C_BOX_GREEN_TITLE='\033[42;1;37m'
_C_BOX_YELLOW_TITLE='\033[43;1;30m'
_C_BOX_RED_TITLE='\033[41;1;37m'
_C_BOX_SIDE='\033[1;37m'

_CRED_DIR="/tmp"
[[ -d "/dev/shm" ]] && _CRED_DIR="/dev/shm"
_CRED_FILE="${_CRED_DIR}/.nsx_session_${UID}"
_KNOWN_HOSTS="/tmp/.nsx_known_hosts_${UID}"
touch "${_KNOWN_HOSTS}" 2>/dev/null && chmod 600 "${_KNOWN_HOSTS}" 2>/dev/null || true

BUNDLE_STATUS=""
BUNDLE_FILES_RECENT=""
BUNDLE_FILES_OLD=""

SB_EXTRA=""
SB_LOG_AGE=1
export SB_EXTRA SB_LOG_AGE

declare -a NODE_AUTH_FAILED=()

_BUNDLE_PROC_GREP='gen_support_bundle|support_bundles/__self__\.py'

log(){        printf "${_C_WHITE}[%s] %s${_C_RESET}\n"         "$(date '+%F %T')" "$*"; }
log_ok(){     printf "${_C_GREEN}[%s] [OK]   %s${_C_RESET}\n"  "$(date '+%F %T')" "$*"; }
log_warn(){   printf "${_C_YELLOW}[%s] [WARN] %s${_C_RESET}\n" "$(date '+%F %T')" "$*"; }
log_err(){    printf "${_C_RED}[%s] [ERR]  %s${_C_RESET}\n"    "$(date '+%F %T')" "$*"; }
log_cmd(){    printf "${_C_MAGENTA}[%s] >> %s${_C_RESET}\n"    "$(date '+%F %T')" "$*"; }
log_banner(){ printf "${_C_CYAN}[%s] === %s ===${_C_RESET}\n"  "$(date '+%F %T')" "$*"; }

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { log_err "Missing required command: $1"; exit 1; }
}

_box_line(){
  local width="$1" char="${2:--}" out=""
  for (( i=0; i<width; i++ )); do out+="${char}"; done
  printf '%s' "${out}"
}

_is_auth_failed(){
  echo "$1" | grep -qiE 'permission denied|authentication failed|publickey|no supported authentication'
}

ask_bundle_options(){
  local width=74 _mode="" _age="" _resp=""
  echo ""
  printf "${_C_BOX_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "  OPCOES DO SUPPORT BUNDLE  "
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  [1] Padrao           get support-bundle file <nome> log-age <N>"
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  [2] all              get support-bundle file <nome> all log-age <N>"
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  [3] all remove-core  get support-bundle file <nome> all remove-core-file log-age <N>"
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  Sem resposta em 10s -> padrao automatico (modo 1, log-age 1)"
  printf "${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
  echo ""
  local _t
  for _t in 10 9 8 7 6 5 4 3 2 1; do
    printf "\r${_C_BLUE_BOLD}Modo [1/2/3, Enter=padrao] (%2ds): ${_C_RESET}" "$_t"
    if IFS= read -r -t 1 _resp 2>/dev/null; then _mode="$_resp"; break; fi
  done
  echo ""
  case "${_mode:-1}" in
    2) SB_EXTRA="all"                  ;;
    3) SB_EXTRA="all remove-core-file" ;;
    *) SB_EXTRA=""                     ;;
  esac
  for _t in 10 9 8 7 6 5 4 3 2 1; do
    printf "\r${_C_BLUE_BOLD}log-age [1..30, Enter=1] (%2ds): ${_C_RESET}" "$_t"
    if IFS= read -r -t 1 _resp 2>/dev/null; then _age="$_resp"; break; fi
  done
  echo ""
  if [[ "${_age:-}" =~ ^[0-9]+$ ]] && (( _age >= 1 && _age <= 30 )); then
    SB_LOG_AGE="$_age"
  else
    SB_LOG_AGE=1
  fi
  export SB_EXTRA SB_LOG_AGE
  log_ok "Opcoes definidas: SB_EXTRA='${SB_EXTRA:-<nenhum>}' | SB_LOG_AGE=${SB_LOG_AGE}"
}

collect_ips(){
  printf "${_C_BLUE_BOLD}Paste Edge Node IPs, one per line. Empty line to finish:${_C_RESET}\n"
  : > "${EDGE_FILE}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${EDGE_FILE}"
    else
      log_warn "Skipping invalid entry: ${line}"
    fi
  done
  log "$(wc -l < "${EDGE_FILE}" | tr -d ' ') IP(s) saved to ${EDGE_FILE}"
}

load_ips(){
  [[ ! -s "${EDGE_FILE}" ]] && { log_warn "${EDGE_FILE} not found or empty."; collect_ips; }
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}" 2>/dev/null || true)
  [[ ${#EDGE_IPS[@]} -eq 0 ]] && { log_err "No valid IPs found in ${EDGE_FILE}."; exit 1; }
  log "Loaded ${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"
}

_save_creds(){
  ( umask 177
    { printf 'NSX_USER='; printf '%s' "${NSX_USER:-}"; printf '\n'
      printf 'NSX_PASS='; printf '%s' "${NSX_PASS:-}"; printf '\n'
      printf 'ROOT_PASS='; printf '%s' "${ROOT_PASS:-}"; printf '\n'
    } > "${_CRED_FILE}" )
  chmod 600 "${_CRED_FILE}"
}

_load_creds(){
  [[ -f "${_CRED_FILE}" ]] || return 1
  local fuid
  fuid="$(stat -c '%u' "${_CRED_FILE}" 2>/dev/null || stat -f '%u' "${_CRED_FILE}" 2>/dev/null || echo -1)"
  [[ "${fuid}" == "${UID}" ]] || return 1
  local key val
  while IFS= read -r _line; do
    [[ -z "${_line}" || "${_line}" =~ ^# ]] && continue
    key="${_line%%=*}"; val="${_line#*=}"
    case "${key}" in
      NSX_USER)  export NSX_USER="${val}"  ;;
      NSX_PASS)  export NSX_PASS="${val}"  ;;
      ROOT_PASS) export ROOT_PASS="${val}" ;;
    esac
  done < "${_CRED_FILE}"
  return 0
}

_remove_cred_file(){ [[ -f "${_CRED_FILE}" ]] && rm -f "${_CRED_FILE}" || true; }

ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already in environment (user: '${NSX_USER:-admin}')."; return 0
  fi
  if _load_creds 2>/dev/null && [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials loaded from session file."; return 0
  fi
  printf "${_C_BLUE_BOLD}Usuario admin [admin]: ${_C_RESET}"; read -r NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  printf "${_C_BLUE_BOLD}Senha admin: ${_C_RESET}"; IFS= read -rsp "" NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credenciais coletadas para '${NSX_USER}'."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already in environment."; return 0
  fi
  if _load_creds 2>/dev/null && [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials loaded from session file."; return 0
  fi
  printf "${_C_BLUE_BOLD}Senha root: ${_C_RESET}"; IFS= read -rsp "" ROOT_PASS; echo
  export ROOT_PASS
  log "Root credentials collected."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  _remove_cred_file
  [[ -f "${_KNOWN_HOSTS}" ]] && rm -f "${_KNOWN_HOSTS}" || true
  log "Credentials cleared."
}

prompt_clear_creds(){
  echo ""
  printf "${_C_BLUE_BOLD}Limpar credenciais da memoria? [S/n]: ${_C_RESET}"
  read -r _CLR
  if [[ "${_CLR,,}" == "n" ]]; then _save_creds; log "Credenciais mantidas (${_CRED_FILE})."
  else clear_creds; fi
}

ssh_admin(){
  local ip="$1"; shift
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 -o BatchMode=yes "admin@${ip}" "$@" 2>/dev/null
  else
    export SSHPASS="${NSX_PASS}"
    sshpass -e ssh -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${_KNOWN_HOSTS}" -o ConnectTimeout=15 -o LogLevel=ERROR \
      "${NSX_USER}@${ip}" "$@"
    local _rc=$?; unset SSHPASS; return $_rc
  fi
}

ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 -o BatchMode=yes "root@${ip}" "$@" 2>/dev/null
  else
    export SSHPASS="${ROOT_PASS}"
    sshpass -e ssh -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${_KNOWN_HOSTS}" -o ConnectTimeout=15 -o LogLevel=ERROR \
      "root@${ip}" "$@"
    local _rc=$?; unset SSHPASS; return $_rc
  fi
}

admin_cmd(){     local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>/dev/null; }
root_cmd(){      local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>/dev/null; }
admin_cmd_tty(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd_tty(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

_node_auth_failed(){
  local ip="$1"
  local f
  for f in "${NODE_AUTH_FAILED[@]:-}"; do
    [[ "$f" == "$ip" ]] && return 0
  done
  return 1
}

enable_root_ssh(){
  local ip="$1" out rc=0
  log "${ip}: enabling root SSH..."
  log_cmd "${ip}: set ssh root-login"
  out="$(admin_cmd_tty "$ip" 'set ssh root-login' 2>&1)" || rc=$?
  if _is_auth_failed "$out" || [[ $rc -eq 5 ]]; then
    log_err "${ip}: 'set ssh root-login' recusado — senha admin incorreta ou expirada."
    NODE_AUTH_FAILED+=("$ip")
    return 1
  fi
  [[ -n "$out" ]] && log "${ip}: [set ssh root-login] ${out}"
  sleep 3; return 0
}

disable_root_ssh(){
  local ip="$1" out rc=0
  log "${ip}: disabling root SSH..."
  log_cmd "${ip}: clear ssh root-login"
  out="$(admin_cmd_tty "$ip" 'clear ssh root-login' 2>&1)" || rc=$?
  if _is_auth_failed "$out" || [[ $rc -eq 5 ]]; then
    log_warn "${ip}: falha ao desabilitar root SSH. Desabilite manualmente."
    return 0
  fi
  [[ -n "$out" ]] && log "${ip}: [clear ssh root-login] ${out}"
  return 0
}

check_bundle_log(){
  local ip="$1" log_file="/var/log/support_bundle.log" out
  out="$(root_cmd_tty "$ip" "test -f ${log_file} && tail -1 ${log_file} || echo '__FILE_NOT_FOUND__'")"
  if grep -q '__FILE_NOT_FOUND__' <<< "$out"; then
    log_warn "${ip}: ${log_file} nao encontrado."; return 2
  fi
  local width=74
  printf "  ${_C_BOX_TITLE}┌─ %s (ultima linha) ─┐${_C_RESET}\n" "$ip"
  printf "  ${_C_BOX_SIDE}│${_C_RESET}  %s\n" "${out}"
  printf "  ${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
  if grep -qiE 'error|fail|exception|abort|fatal' <<< "$out"; then
    log_warn "${ip}: problema detectado na ultima linha do log."; return 1
  fi
  log_ok "${ip}: ultima linha do log sem erros aparentes."
  return 0
}

list_bundle_dir(){
  local ip="$1" dir="/var/vmware/nsx/file-store" out width=74
  out="$(root_cmd_tty "$ip" "ls -lh ${dir}/")"
  echo ""
  printf "  ${_C_BOX_TITLE}┌─ %s: ls -lh %s/ ─┐${_C_RESET}\n" "$ip" "$dir"
  if [[ -z "${out}" ]]; then
    printf "  ${_C_BOX_SIDE}│${_C_RESET}  [vazio ou erro ao listar]\n"
  else
    while IFS= read -r line; do
      printf "  ${_C_BOX_SIDE}│${_C_RESET}  %s\n" "${line}"
    done <<< "${out}"
  fi
  printf "  ${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
  echo ""
}

_list_bundles(){
  local ip="$1" dir="/var/vmware/nsx/file-store"
  root_cmd "$ip" "ls -1 ${dir}/ 2>/dev/null || true" | grep '\.tgz$' || true
}

_list_bundles_with_age(){
  local ip="$1" dir="/var/vmware/nsx/file-store" raw
  raw="$(root_cmd "$ip" \
    "cd '${dir}' 2>/dev/null && \
     for f in \$(ls -1 2>/dev/null || true); do \
       ep=\$(stat -c '%Y' \"\$f\" 2>/dev/null || echo 0); \
       echo \"\$f \$ep\"; \
     done")"
  echo "$raw" | grep '\.tgz ' || true
}

check_bundle_status(){
  local ip="$1"
  BUNDLE_STATUS="none"
  BUNDLE_FILES_RECENT=""
  BUNDLE_FILES_OLD=""
  local dir="/var/vmware/nsx/file-store" width=74

  log "${ip}: [PRE-CHECK] verificando status do support bundle..."
  list_bundle_dir "$ip"

  local proc_out
  proc_out="$(root_cmd "$ip" \
    "ps -ef 2>/dev/null | grep -E '${_BUNDLE_PROC_GREP}' | grep -v grep || true")"
  if [[ -n "$proc_out" ]]; then
    log_warn "${ip}: geracao de bundle em andamento."
    BUNDLE_STATUS="inprogress"; return 0
  fi

  local raw_pairs all_bundles
  raw_pairs="$(_list_bundles_with_age "$ip")"
  all_bundles="$(echo "$raw_pairs" | awk '{print $1}' | grep -v '^$' || true)"
  log "${ip}: [bundles detectados] resultado bruto: '${all_bundles:-<vazio>}'"
  [[ -z "$all_bundles" ]] && { log "${ip}: nenhum bundle encontrado em file-store."; return 0; }

  local bundle_count now_epoch fname fepoch age fpath
  bundle_count="$(echo "$all_bundles" | grep -c '.' || true)"
  log "${ip}: ${bundle_count} bundle(s) encontrado(s)."
  now_epoch="$(date +%s)"

  while IFS= read -r pair; do
    [[ -z "$pair" ]] && continue
    fname="$(echo "$pair" | awk '{print $1}')"
    fepoch="$(echo "$pair" | awk '{print $2}' | tr -cd '0-9')"
    [[ -z "$fname" ]] && continue
    if [[ -z "$fepoch" || "$fepoch" == "0" ]]; then age=999
    else age=$(( (now_epoch - fepoch) / 86400 )); fi
    fpath="${dir}/${fname}"
    log "${ip}: arquivo '${fname}' -> ${age} dia(s)."
    if [[ "$age" -le 7 ]]; then
      BUNDLE_FILES_RECENT+="${fpath}"$'\n'
    else
      BUNDLE_FILES_OLD+="${fpath}"$'\n'
    fi
  done <<< "$raw_pairs"

  BUNDLE_FILES_RECENT="${BUNDLE_FILES_RECENT%$'\n'}"
  BUNDLE_FILES_OLD="${BUNDLE_FILES_OLD%$'\n'}"

  if [[ -n "$BUNDLE_FILES_RECENT" ]]; then
    BUNDLE_STATUS="recent"
    log_ok "${ip}: bundle recente presente."
    [[ -n "$BUNDLE_FILES_OLD" ]] && log_warn "${ip}: bundle(s) antigo(s) presentes — use --clean-all."
    return 0
  fi
  if [[ -n "$BUNDLE_FILES_OLD" ]]; then
    BUNDLE_STATUS="old"
    log_warn "${ip}: todos os bundles sao antigos."
    return 0
  fi
  log "${ip}: nenhum bundle encontrado."
  return 0
}

delete_old_bundles(){
  local ip="$1"
  [[ -z "$BUNDLE_FILES_OLD" ]] && return 0
  log "${ip}: deletando bundle(s) antigo(s)..."
  local _del_old=()
  mapfile -t _del_old <<< "$BUNDLE_FILES_OLD"
  local fpath
  for fpath in "${_del_old[@]}"; do
    [[ -z "$fpath" ]] && continue
    log_cmd "${ip}: rm -f ${fpath}"
    if root_cmd "$ip" "rm -f '${fpath}'"; then log_warn "${ip}: deletado — ${fpath}"
    else log_err "${ip}: falha ao deletar — ${fpath}"; fi
  done
}

delete_all_bundles(){
  local ip="$1" dir="/var/vmware/nsx/file-store"
  log "${ip}: buscando TODOS os bundles para limpeza total..."
  local all_files
  all_files="$(_list_bundles "$ip")"
  if [[ -z "$all_files" ]]; then
    log "${ip}: nenhum bundle encontrado para deletar."; return 0
  fi
  local count
  count="$(echo "$all_files" | grep -c '.' || true)"
  log "${ip}: ${count} bundle(s) para deletar."
  local _del_files=()
  mapfile -t _del_files <<< "$all_files"
  local f fpath
  for f in "${_del_files[@]}"; do
    [[ -z "$f" ]] && continue
    fpath="${dir}/${f}"
    log_cmd "${ip}: rm -f ${fpath}"
    if root_cmd "$ip" "rm -f '${fpath}'"; then log_warn "${ip}: deletado — ${fpath}"
    else log_err "${ip}: falha ao deletar — ${fpath}"; fi
  done
  log_ok "${ip}: limpeza total concluida."
}

request_support_bundle(){
  local ip="$1" sb_extra="${2:-${SB_EXTRA:-}}" sb_log_age="${3:-${SB_LOG_AGE:-1}}"
  local fname="sb_${ip//./_}_$(date +%Y%m%d_%H%M%S).tgz"
  local logfile="${LOG_DIR}/sb_bg_${ip//./_}_$(date +%Y%m%d_%H%M%S).log"
  local nsx_cmd="get support-bundle file ${fname}"
  [[ -n "$sb_extra" ]] && nsx_cmd="${nsx_cmd} ${sb_extra}"
  nsx_cmd="${nsx_cmd} log-age ${sb_log_age}"
  log_cmd "${ip}: [BACKGROUND] ${nsx_cmd}"
  log "${ip}: saida em: ${logfile}"
  if [[ -f "${ADMIN_KEY}" ]]; then
    ( ssh -i "${ADMIN_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=120 \
        "admin@${ip}" "${nsx_cmd}" > "${logfile}" 2>&1
      echo "[$(date '+%F %T')] [OK] Bundle concluido: ${fname}" >> "${logfile}" ) &
  else
    export SSHPASS="${NSX_PASS}"
    ( sshpass -e ssh -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${_KNOWN_HOSTS}" -o ConnectTimeout=15 -o LogLevel=ERROR \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=120 \
        "${NSX_USER}@${ip}" "${nsx_cmd}" > "${logfile}" 2>&1
      echo "[$(date '+%F %T')] [OK] Bundle concluido: ${fname}" >> "${logfile}" ) &
    unset SSHPASS
  fi
  disown $!
  log_ok "${ip}: solicitacao disparada em background."
  log "${ip}: acompanhe com: tail -f ${logfile}"
}

_print_report(){
  local width=92 title="${1:-RELATORIO FINAL — Support Bundle Check}"
  shift || true
  local -a lines=("$@")
  echo ""
  printf "${_C_CYAN}╔%s╗${_C_RESET}\n" "$(_box_line $(( width - 2 )) '═')"
  printf "${_C_CYAN}║  %-*s║${_C_RESET}\n" "$(( width - 3 ))" "  ${title}  —  $(date '+%F %T')"
  printf "${_C_CYAN}╠%s╦%s╦%s╦%s╦%s╣${_C_RESET}\n" \
    "$(_box_line 19 '═')" "$(_box_line 18 '═')" "$(_box_line 18 '═')" "$(_box_line 20 '═')" "$(_box_line 14 '═')"
  printf "${_C_CYAN}║${_C_RESET} %-17s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-18s ${_C_CYAN}║${_C_RESET} %-12s ${_C_CYAN}║${_C_RESET}\n" \
    "NODE" "STATUS" "ACAO" "ARQUIVO" "DURACAO"
  printf "${_C_CYAN}╠%s╬%s╬%s╬%s╬%s╣${_C_RESET}\n" \
    "$(_box_line 19 '═')" "$(_box_line 18 '═')" "$(_box_line 18 '═')" "$(_box_line 20 '═')" "$(_box_line 14 '═')"
  local entry
  for entry in "${lines[@]}"; do
    IFS='|' read -r r_ip r_status r_acao r_arquivo r_duracao <<< "$entry"
    r_duracao="${r_duracao:---}"
    local r_arq_short
    r_arq_short="$(basename "${r_arquivo%%$'\n'*}" 2>/dev/null || echo "${r_arquivo}")"
    [[ ${#r_arq_short} -gt 18 ]] && r_arq_short="${r_arq_short:0:15}..."
    local _color="${_C_CYAN}"
    [[ "$r_status" == "AUTH FALHOU" ]] && _color="${_C_RED}"
    [[ "$r_status" == "RECENTE"*   ]] && _color="${_C_GREEN}"
    [[ "$r_status" == "ANTIGO"*    ]] && _color="${_C_YELLOW}"
    printf "${_color}║${_C_RESET} %-17s ${_color}║${_C_RESET} %-16s ${_color}║${_C_RESET} %-16s ${_color}║${_C_RESET} %-18s ${_color}║${_C_RESET} %-12s ${_color}║${_C_RESET}\n" \
      "$r_ip" "$r_status" "$r_acao" "$r_arq_short" "$r_duracao"
  done
  printf "${_C_CYAN}╚%s╩%s╩%s╩%s╩%s╝${_C_RESET}\n" \
    "$(_box_line 19 '═')" "$(_box_line 18 '═')" "$(_box_line 18 '═')" "$(_box_line 20 '═')" "$(_box_line 14 '═')"
  echo ""
}

tbl_header(){
  local title="${1:-PRE-CHECK -- Estado dos Support Bundles}"
  printf '+--------------------------------------------------------------------------------------------+\n'
  printf '| %-90s |\n' "${title}  $(date '+%F %T')"
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n'
  printf '| %-19s | %-18s | %-18s | %-18s | %-12s |\n' 'NODE' 'STATUS' 'ACAO' 'ARQUIVO' 'DURACAO'
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n'
}

tbl_row(){
  printf '| %-19s | %-18s | %-18s | %-18s | %-12s |\n' \
    "$1" "${2:0:18}" "${3:0:18}" "${4:0:18}" "${5:0:12}"
}

tbl_footer(){
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n\n'
}
COMMON
chmod +x "${LIB_DIR}/common.sh"

cat > "${AUTO_DIR}/edge_nodes.example" <<'EXAMPLE'
# edge_nodes.example — copie para edge_nodes.txt e edite
192.168.1.10
192.168.1.11
192.168.1.12
EXAMPLE

cat > "${AUTO_DIR}/install_dependencies.sh" <<'INST'
#!/usr/bin/env bash
set -euo pipefail
if command -v sshpass &>/dev/null; then
  echo "[OK] sshpass ja instalado: $(command -v sshpass)"; exit 0
fi
for pm in apt-get yum dnf; do
  if command -v $pm &>/dev/null; then
    $pm install -y sshpass && echo "[OK] sshpass instalado." && exit 0
  fi
done
echo "[ERR] Instale sshpass manualmente."; exit 1
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

cat > "${AUTO_DIR}/test_connections.sh" <<'TESTC'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds
REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"
log "Relatorio: ${REPORT}"
for ip in "${EDGE_IPS[@]}"; do
  {
    echo "====== Node: ${ip}"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping filtrado"
    admin_cmd_tty "$ip" 'get version'     || echo "FAIL admin SSH"
    admin_cmd_tty "$ip" 'get service ssh' || echo "FAIL admin SSH"
    if enable_root_ssh "$ip"; then
      root_cmd_tty "$ip" 'uname -a' || echo "FAIL root SSH"
      root_cmd_tty "$ip" 'uptime'   || echo "FAIL root SSH"
      list_bundle_dir "$ip"
      disable_root_ssh "$ip"
    fi
    echo
  } | tee -a "$REPORT"
done
[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && log_warn "Nodes com falha: ${NODE_AUTH_FAILED[*]}"
log_ok "Teste concluido. Relatorio: ${REPORT}"
prompt_clear_creds
TESTC
chmod +x "${AUTO_DIR}/test_connections.sh"

# ---------------------------------------------------------------------------
# nsx_sb_precheck.sh  — v3.16.4
# FIX: idade do bundle calculada via stat mtime no node remoto.
#      Qualquer nome de arquivo funciona, nao apenas sb_IP_YYYYMMDD_HHMMSS.tgz
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_precheck.sh" <<'PRECHECK'
#!/usr/bin/env bash
# nsx_sb_precheck.sh  — v3.16.4
#
# FIX v3.16.4:
#   Idade do bundle era calculada por regex no nome do arquivo.
#   Nomes fora do padrao sb_IP_YYYYMMDD_HHMMSS.tgz recebiam 999 dias.
#   Corrigido para usar stat -c '%Y' no node remoto — funciona com
#   qualquer convencao de nome (sb-YYYYMMDD-HHhMM.tgz, sbYYMMDD-node.tgz, etc).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds

log_banner "PRE-CHECK -- Estado dos Support Bundles"

CLEAN_ALL=false
[[ "${1:-}" == "--clean-all" ]] && { CLEAN_ALL=true; log "=== CLEAN-ALL: Apagando TODOS os bundles ==="; }

declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP PC_DURACAO
now_epoch=$(date +%s)

bundle_duration(){
  local ip="$1" fname="$2" req_epoch="" created_epoch=""
  if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.tgz$ ]]; then
    req_epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null || echo "")
  fi
  [[ -z "$req_epoch" ]] && { printf '--'; return; }
  created_epoch=$(root_cmd "$ip" \
    "stat -c '%Y' /var/vmware/nsx/file-store/${fname} 2>/dev/null" || echo "")
  [[ -z "$created_epoch" || ! "$created_epoch" =~ ^[0-9]+$ ]] && { printf '--'; return; }
  local diff=$(( created_epoch - req_epoch ))
  [[ $diff -lt 0 ]] && diff=0
  local horas=$(( diff / 3600 ))
  local minutos=$(( (diff % 3600) / 60 ))
  local segundos=$(( diff % 60 ))
  if   [[ $horas   -gt 0 ]]; then printf '%dh %02dm %02ds' "$horas" "$minutos" "$segundos"
  elif [[ $minutos -gt 0 ]]; then printf '%dm %02ds' "$minutos" "$segundos"
  else printf '%ds' "$segundos"; fi
}

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."

  if ! enable_root_ssh "$ip"; then
    PC_STATUS["$ip"]="AUTH FALHOU"; PC_ACAO["$ip"]="PULADO"
    PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="true"; PC_DURACAO["$ip"]="--"
    continue
  fi

  check_bundle_log "$ip" || true
  log "${ip}: [PRE-CHECK] verificando status do support bundle..."

  echo ""
  printf '  \u250c\u2500 %s: ls -lh /var/vmware/nsx/file-store/                    \u2500\u2510\n' "$ip"
  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  while IFS= read -r line; do printf '  \u2502  %s\n' "$line"; done <<< "$ls_out"
  printf '  \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518\n\n'

  if [[ "$CLEAN_ALL" == true ]]; then
    rm_list="$(root_cmd "$ip" "ls /var/vmware/nsx/file-store/ 2>/dev/null | grep -E '\.tgz$' || true")"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      root_cmd "$ip" "rm -f /var/vmware/nsx/file-store/${f}" || true
      log_warn "${ip}: deletado -- ${f}"
    done <<< "$rm_list"
    log_ok "${ip}: limpeza total concluida."
    disable_root_ssh "$ip" || true
    PC_STATUS["$ip"]="LIMPO"; PC_ACAO["$ip"]="LIMPO"
    PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"; PC_DURACAO["$ip"]="--"
    continue
  fi

  raw_list="$(root_cmd "$ip" "ls /var/vmware/nsx/file-store/ 2>/dev/null" | grep -E '\.tgz$' || true)"
  log "${ip}: [bundles detectados] resultado bruto: '${raw_list:-<vazio>}'"

  pc_recent=(); pc_old=()
  pc_total=0

  while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    pc_total=$(( pc_total + 1 ))

    # FIX v3.16.4: usar mtime real via stat no node — independente do nome do arquivo
    pc_file_epoch="$(root_cmd "$ip" \
      "stat -c '%Y' /var/vmware/nsx/file-store/${fname} 2>/dev/null || echo 0")"
    pc_file_epoch="$(echo "${pc_file_epoch}" | tr -cd '0-9')"
    if [[ -n "$pc_file_epoch" && "$pc_file_epoch" =~ ^[0-9]+$ && "$pc_file_epoch" -gt 0 ]]; then
      pc_age_days=$(( (now_epoch - pc_file_epoch) / 86400 ))
    else
      pc_age_days=999
    fi

    log "${ip}: arquivo '${fname}' -> ${pc_age_days} dia(s)."
    [[ $pc_age_days -le 7 ]] && pc_recent+=("$fname") || pc_old+=("$fname")
  done <<< "$raw_list"

  log "${ip}: ${pc_total} bundle(s) | ${#pc_recent[@]} recente(s) | ${#pc_old[@]} antigo(s)."

  printf '\n  +-- %s: %d recente(s) (<=7d) | %d antigo(s) (>7d) ---+\n' \
    "$ip" "${#pc_recent[@]}" "${#pc_old[@]}"
  for f in "${pc_recent[@]:-}"; do [[ -n "$f" ]] && printf '  |  [OK]  %s\n' "$f"; done
  for f in "${pc_old[@]:-}";    do [[ -n "$f" ]] && printf '  |  [OLD] %s\n' "$f"; done
  printf '  +------------------------------------------------------+\n\n'

  if [[ ${#pc_recent[@]} -gt 0 ]]; then
    pc_newest="$(printf '%s\n' "${pc_recent[@]}" | sort | tail -1)"
    PC_STATUS["$ip"]="RECENTE (<=7d)"
    PC_ACAO["$ip"]="OK"
    PC_FILE["$ip"]="${pc_newest}"
    PC_SKIP["$ip"]="true"
    PC_DURACAO["$ip"]="$(bundle_duration "$ip" "$pc_newest")"
    log_ok "${ip}: bundle recente presente."
    [[ ${#pc_old[@]} -gt 0 ]] && log_warn "${ip}: bundle(s) antigo(s) presentes -- use --clean-all."
  elif [[ $pc_total -gt 0 ]]; then
    PC_STATUS["$ip"]="ANTIGO (>7d)"; PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"; PC_DURACAO["$ip"]="--"
    log_warn "${ip}: apenas bundle(s) antigo(s)."
  else
    PC_STATUS["$ip"]="NENHUM"; PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"; PC_DURACAO["$ip"]="--"
    log "${ip}: nenhum bundle encontrado."
  fi

  disable_root_ssh "$ip" || true
done

precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,acao,arquivo,duracao' > "$precheck_csv"

tbl_header "PRE-CHECK -- Estado dos Support Bundles"
for ip in "${EDGE_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" \
    "$(basename "${PC_FILE[$ip]:---}" 2>/dev/null || echo '--')" \
    "${PC_DURACAO[$ip]:---}"
  printf '%s,%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" \
    "${PC_FILE[$ip]:---}" "${PC_DURACAO[$ip]:---}" >> "$precheck_csv"
done
tbl_footer

[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
  log_warn "Nodes com falha de autenticacao: ${NODE_AUTH_FAILED[*]} -- verifique credenciais."
log_ok "Pre-check concluido. CSV: ${precheck_csv}"
log "Para gerar bundles: ./nsx_sb_main.sh"
log "Para limpar todos:  ./nsx_sb_precheck.sh --clean-all"

prompt_clear_creds
PRECHECK
chmod +x "${AUTO_DIR}/nsx_sb_precheck.sh"

cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh  — v3.16.4
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds

CLEAN_ALL=false
PRECHECK_ONLY=false
for _arg in "${@:-}"; do
  case "${_arg}" in
    --clean-all)     CLEAN_ALL=true     ;;
    --precheck-only) PRECHECK_ONLY=true ;;
  esac
done

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "${STATUS_CSV}"

declare -a REPORT_LINES=()
declare -A NODE_ACAO=()

if [[ "$PRECHECK_ONLY" == true ]]; then
  log_banner "PRE-CHECK ONLY — Verificando bundles (sem geracao)"
  for ip in "${EDGE_IPS[@]}"; do
    log "${ip}: iniciando pre-check..."
    if ! enable_root_ssh "$ip"; then
      REPORT_LINES+=("${ip}|AUTH FALHOU|PULADO|--|--")
      printf '%s,precheck,auth_failed,admin_auth_error,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      continue
    fi
    check_bundle_log "$ip" || true
    check_bundle_status "$ip"
    disable_root_ssh "$ip" || true
    printf '%s,precheck,bundle_status,%s,%s\n' "$ip" "$BUNDLE_STATUS" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    first_recent=""; [[ -n "$BUNDLE_FILES_RECENT" ]] && first_recent="$(echo "$BUNDLE_FILES_RECENT" | head -1)"
    first_old="";    [[ -n "$BUNDLE_FILES_OLD"    ]] && first_old="$(echo "$BUNDLE_FILES_OLD" | head -1)"
    case "$BUNDLE_STATUS" in
      recent)     REPORT_LINES+=("${ip}|RECENTE (<=7d)|OK|${first_recent:-—}|--")  ;;
      old)        REPORT_LINES+=("${ip}|ANTIGO (>7d)|ATENCAO|${first_old:-—}|--") ;;
      none)       REPORT_LINES+=("${ip}|NENHUM|AUSENTE|--|--")                      ;;
      inprogress) REPORT_LINES+=("${ip}|EM ANDAMENTO|AGUARDAR|--|--")               ;;
      *)          REPORT_LINES+=("${ip}|DESCONHECIDO|VERIFICAR|--|--")              ;;
    esac
  done
  _print_report "PRE-CHECK — Estado dos Support Bundles" "${REPORT_LINES[@]}"
  [[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && log_warn "Nodes com falha: ${NODE_AUTH_FAILED[*]}"
  log_ok "Status CSV: ${STATUS_CSV}"
  prompt_clear_creds
  exit 0
fi

ask_bundle_options

if [[ "$CLEAN_ALL" == true ]]; then
  log_banner "CLEAN-ALL: Apagando TODOS os bundles existentes"
  for ip in "${EDGE_IPS[@]}"; do
    if ! enable_root_ssh "$ip"; then
      printf '%s,clean_all,auth_failed,admin_auth_error,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      continue
    fi
    list_bundle_dir "$ip"
    delete_all_bundles "$ip"
    disable_root_ssh "$ip" || true
    printf '%s,clean_all,deleted_all,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  done
fi

log_banner "PRE-CHECK: Verificando bundles existentes"
for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  if ! enable_root_ssh "$ip"; then
    printf '%s,precheck,auth_failed,admin_auth_error,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    REPORT_LINES+=("${ip}|AUTH FALHOU|PULADO|--|--")
    NODE_ACAO[$ip]="PULADO"
    continue
  fi
  check_bundle_log "$ip" || true
  check_bundle_status "$ip"
  printf '%s,precheck,bundle_status,%s,%s\n' "$ip" "$BUNDLE_STATUS" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  case "$BUNDLE_STATUS" in
    recent)
      REPORT_LINES+=("${ip}|RECENTE (<=7d)|PULADO|${BUNDLE_FILES_RECENT}|--")
      NODE_ACAO[$ip]="PULADO" ;;
    old)
      delete_old_bundles "$ip"
      printf '%s,precheck,deleted_old,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      REPORT_LINES+=("${ip}|ANTIGO (>7d)|DEL+GERANDO|${BUNDLE_FILES_OLD}|--")
      NODE_ACAO[$ip]="GERANDO" ;;
    none)
      REPORT_LINES+=("${ip}|NENHUM|GERANDO|--|--")
      NODE_ACAO[$ip]="GERANDO" ;;
    inprogress)
      REPORT_LINES+=("${ip}|EM ANDAMENTO|PULADO|--|--")
      NODE_ACAO[$ip]="PULADO" ;;
  esac
done

log_banner "PHASE 1: Support Bundle Request (background)"
for ip in "${EDGE_IPS[@]}"; do
  _node_auth_failed "$ip" && continue
  [[ "${NODE_ACAO[$ip]:-}" == "PULADO" ]] && { log "${ip}: pulando solicitacao."; continue; }
  request_support_bundle "$ip" "${SB_EXTRA:-}" "${SB_LOG_AGE:-1}"
  printf '%s,phase1,sb_requested_bg,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log_ok "Phase 1 done — bundles disparados em background."

log_banner "FINAL: Disabling root SSH"
for ip in "${EDGE_IPS[@]}"; do
  _node_auth_failed "$ip" && continue
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

_print_report "RELATORIO FINAL — Support Bundle Check" "${REPORT_LINES[@]}"
[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && log_warn "Nodes com falha: ${NODE_AUTH_FAILED[*]}"
log "Para acompanhar: tail -f ${LOG_DIR}/sb_bg_*.log"
log_ok "Status CSV: ${STATUS_CSV}"
prompt_clear_creds
MAIN
chmod +x "${AUTO_DIR}/nsx_sb_main.sh"

cat > "${AUTO_DIR}/admin_exec.sh" <<'ADMX'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds
printf "${_C_BLUE_BOLD}Comando NSX CLI para executar em todos os nodes: ${_C_RESET}"
read -r NSX_CMD
[[ -z "${NSX_CMD}" ]] && { log_err "Nenhum comando fornecido."; exit 1; }
for ip in "${EDGE_IPS[@]}"; do
  log_cmd "${ip}: ${NSX_CMD}"
  admin_cmd_tty "$ip" "${NSX_CMD}" || log_warn "${ip}: comando retornou erro"
done
prompt_clear_creds
ADMX
chmod +x "${AUTO_DIR}/admin_exec.sh"

cat > "${AUTO_DIR}/root_exec.sh" <<'ROTX'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds
printf "${_C_BLUE_BOLD}Comando shell para executar como root: ${_C_RESET}"
read -r SHELL_CMD
[[ -z "${SHELL_CMD}" ]] && { log_err "Nenhum comando fornecido."; exit 1; }
for ip in "${EDGE_IPS[@]}"; do
  if ! enable_root_ssh "$ip"; then
    log_warn "${ip}: pulando (falha de autenticacao admin)."
    continue
  fi
  log_cmd "${ip}: ${SHELL_CMD}"
  root_cmd_tty "$ip" "${SHELL_CMD}" || log_warn "${ip}: comando retornou erro"
  disable_root_ssh "$ip" || true
done
[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && log_warn "Nodes pulados: ${NODE_AUTH_FAILED[*]}"
prompt_clear_creds
ROTX
chmod +x "${AUTO_DIR}/root_exec.sh"

cat > "${AUTO_DIR}/nsx_ssh_cli.sh" <<'CLISCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass; load_ips
echo "Nodes disponiveis:"
for i in "${!EDGE_IPS[@]}"; do echo "  [$i] ${EDGE_IPS[$i]}"; done
printf "${_C_BLUE_BOLD}Numero do node ou IP direto: ${_C_RESET}"; read -r SEL
if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ -n "${EDGE_IPS[$SEL]:-}" ]]; then
  TARGET_IP="${EDGE_IPS[$SEL]}"
else
  TARGET_IP="$SEL"
fi
printf "${_C_BLUE_BOLD}Usuario [admin]: ${_C_RESET}"; read -r LOGIN_USER
LOGIN_USER="${LOGIN_USER:-admin}"
if [[ "$LOGIN_USER" == "root" ]]; then
  ask_root_creds; export SSHPASS="${ROOT_PASS}"
else
  ask_admin_creds; export SSHPASS="${NSX_PASS}"; LOGIN_USER="${NSX_USER}"
fi
log "Conectando em ${LOGIN_USER}@${TARGET_IP}..."
sshpass -e ssh -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
  -o ConnectTimeout=15 -o LogLevel=ERROR \
  "${LOGIN_USER}@${TARGET_IP}"
unset SSHPASS
CLISCRIPT
chmod +x "${AUTO_DIR}/nsx_ssh_cli.sh"

cat > "${DOCS_DIR}/MANUAL.md" <<'MANUALDOC'
# NSX Edge Automation — Manual de Uso  v3.16.4

## Scripts disponiveis

| Script | Descricao |
|---|---|
| `nsx_sb_precheck.sh` | Pre-check completo com tabela + coluna DURACAO |
| `nsx_sb_precheck.sh --clean-all` | Apaga todos os bundles |
| `nsx_sb_main.sh` | Fluxo completo: pre-check + geracao |
| `nsx_sb_main.sh --precheck-only` | Apenas pre-check inline |
| `nsx_sb_main.sh --clean-all` | Apaga tudo + fluxo completo |
| `test_connections.sh` | Testa conectividade SSH admin + root |
| `admin_exec.sh` | Executa comando NSX CLI em todos os nodes |
| `root_exec.sh` | Executa comando shell como root |
| `nsx_ssh_cli.sh` | SSH interativo para um node especifico |

## Deploy

```bash
curl -fsSL https://raw.githubusercontent.com/leopoldocosta/nsx-edge-automation/main/automations/support_bundle/deploy_nsx_sb_check.sh | bash
```
MANUALDOC

cat > "${EXAMPLES_DIR}/ip_list_example.txt" <<'IPEX'
192.168.100.10
192.168.100.11
192.168.100.12
IPEX

echo ""
if ! command -v sshpass &>/dev/null; then
  echo "[WARN] sshpass nao encontrado. Execute: bash ${AUTO_DIR}/install_dependencies.sh"
else
  echo "[OK] sshpass encontrado: $(command -v sshpass)"
fi

echo ""
echo "================================================================"
echo "  Deploy concluido! v3.16.4"
echo "================================================================"
echo ""
echo "  FIX v3.16.4:"
echo "    nsx_sb_precheck.sh — idade do bundle calculada via stat mtime"
echo "    no node remoto. Qualquer nome de arquivo agora e reconhecido."
echo ""
echo "Proximos passos:"
echo "  1. cd ${AUTO_DIR} && ./nsx_sb_precheck.sh"
echo "  2. cd ${AUTO_DIR} && ./nsx_sb_main.sh"
echo ""

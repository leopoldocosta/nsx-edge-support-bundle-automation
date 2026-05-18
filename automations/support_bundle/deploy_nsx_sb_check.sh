#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  v3.16
# Deploy local do kit NSX Edge Automation - Support Bundle
#
# USO:
#   bash deploy_nsx_sb_check.sh [--dir /caminho/destino]
#   curl -fsSL https://raw.githubusercontent.com/leopoldocosta/nsx-edge-automation/main/automations/support_bundle/deploy_nsx_sb_check.sh | bash
#
# CHANGELOG v3.16:
#   - check_bundle_status(): exporta BUNDLE_DATE_RECENT e BUNDLE_DATE_OLD
#     com a data YYYY-MM-DD do bundle mais recente de cada categoria.
#   - Tabela de relatório: coluna STATUS exibe a data real do arquivo
#     (ex.: 2026-05-12) no lugar de "RECENTE (≤7d)" / "ANTIGO (>7d)".
#   - _print_report(): detecção de cor por prefixo de data (YYYY-)
#     e palavras-chave existentes (EM ANDAMENTO, AUTH FALHOU, NENHUM).
#
# CHANGELOG v3.15:
#   - Novo script nsx_sb_precheck.sh.
#   - nsx_sb_main.sh: flag --precheck-only.
#   - common.sh: _print_report() reutilizável.
#
# CHANGELOG v3.14:
#   - _list_bundles(): grep '\.tgz$'
#   - _list_bundles_with_age(): grep '\.tgz '
#   - delete_all_bundles() e delete_old_bundles(): mapfile + for
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

mkdir -p "${AUTO_DIR}/logs" "${AUTO_DIR}/run" "${LIB_DIR}" "${DOCS_DIR}" "${EXAMPLES_DIR}"

echo ""
echo "================================================================"
echo "  NSX Edge Automation — Support Bundle Kit  v3.16"
echo "  Destino: ${BASE_DIR}"
echo "================================================================"
echo ""

cat <<'TREE'
Estrutura que será criada:
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
GITIGNORE

# ---------------------------------------------------------------------------
# lib/common.sh  — v3.16
# ---------------------------------------------------------------------------
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh  — v3.16
#
# NOVO v3.16:
#   check_bundle_status(): exporta BUNDLE_DATE_RECENT e BUNDLE_DATE_OLD
#   com a data YYYY-MM-DD derivada do fepoch do bundle mais recente
#   de cada categoria. Usada nos relatórios para exibir a data real
#   do arquivo no lugar de "RECENTE (≤7d)" / "ANTIGO (>7d)".
#
#   _print_report(): detecção de cor ajustada — datas (YYYY-) são
#   tratadas como verde (recente) ou amarelo (antigo) com base no
#   campo de arquivo; palavras-chave existentes mantidas.
#
# v3.15: nsx_sb_precheck.sh; --precheck-only; _print_report().
# v3.14: grep '\.tgz$'; mapfile+for em delete_*.
# v3.13: root_cmd_tty → root_cmd (stderr=2>/dev/null).
# v3.12: check_bundle_status: root_cmd elimina falso positivo "inprogress".
# v3.11: _BUNDLE_GREP simplificado; disable_root_ssh: return 0.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="${AUTO_DIR:-$(pwd)}"
LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

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
# Data (YYYY-MM-DD) do bundle mais recente de cada categoria
BUNDLE_DATE_RECENT=""
BUNDLE_DATE_OLD=""

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

_epoch_to_date(){
  # Converte epoch para YYYY-MM-DD de forma portável (Linux + macOS)
  local ep="$1"
  if [[ -z "$ep" || "$ep" == "0" ]]; then echo "????-??-??"; return; fi
  date -d "@${ep}" '+%Y-%m-%d' 2>/dev/null \
    || date -r "${ep}" '+%Y-%m-%d' 2>/dev/null \
    || echo "????-??-??"
}

_is_auth_failed(){
  echo "$1" | grep -qiE 'permission denied|authentication failed|publickey|no supported authentication'
}

# ---------------------------------------------------------------------------
# ask_bundle_options
# ---------------------------------------------------------------------------
ask_bundle_options(){
  local width=74
  local _mode="" _age="" _resp=""

  echo ""
  printf "${_C_BOX_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "  OPÇÕES DO SUPPORT BUNDLE  "
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" ""
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  Modo do comando:"
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  [1] Padrão           get support-bundle file <nome> log-age <N>"
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  [2] all              get support-bundle file <nome> all log-age <N>"
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  [3] all remove-core  get support-bundle file <nome> all remove-core-file log-age <N>"
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" ""
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  Sem resposta em 10s → padrão automático (modo 1, log-age 1)"
  printf "${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
  echo ""

  _mode=""
  printf "${_C_BLUE_BOLD}Modo [1/2/3, Enter=padrão]: ${_C_RESET}"
  local _t
  for _t in 10 9 8 7 6 5 4 3 2 1; do
    printf "\r${_C_BLUE_BOLD}Modo [1/2/3, Enter=padrão] (%2ds): ${_C_RESET}" "$_t"
    if IFS= read -r -t 1 _resp 2>/dev/null; then
      _mode="$_resp"
      break
    fi
  done
  echo ""

  case "${_mode:-1}" in
    2) SB_EXTRA="all"                  ;;
    3) SB_EXTRA="all remove-core-file" ;;
    *) SB_EXTRA=""                     ;;
  esac

  _age=""
  printf "${_C_BLUE_BOLD}log-age [1..30, Enter=1]: ${_C_RESET}"
  for _t in 10 9 8 7 6 5 4 3 2 1; do
    printf "\r${_C_BLUE_BOLD}log-age [1..30, Enter=1] (%2ds): ${_C_RESET}" "$_t"
    if IFS= read -r -t 1 _resp 2>/dev/null; then
      _age="$_resp"
      break
    fi
  done
  echo ""

  if [[ "${_age:-}" =~ ^[0-9]+$ ]] && (( _age >= 1 && _age <= 30 )); then
    SB_LOG_AGE="$_age"
  else
    SB_LOG_AGE=1
  fi

  export SB_EXTRA SB_LOG_AGE

  local _cmd_preview="get support-bundle file <nome>"
  if [[ -n "$SB_EXTRA" ]]; then
    _cmd_preview="${_cmd_preview} ${SB_EXTRA}"
  fi
  _cmd_preview="${_cmd_preview} log-age ${SB_LOG_AGE}"

  echo ""
  printf "${_C_BOX_GREEN_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "  CONFIRMAÇÃO  "
  printf "${_C_BOX_SIDE}│${_C_RESET}  %-*s${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  Comando que será executado em cada Edge Node:"
  printf "${_C_BOX_SIDE}│${_C_RESET}  ${_C_CYAN}%-*s${_C_RESET}${_C_BOX_SIDE}│${_C_RESET}\n" "$(( width - 4 ))" "  ${_cmd_preview}"
  printf "${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
  echo ""

  log_ok "Opções definidas: SB_EXTRA='${SB_EXTRA:-<nenhum>}' | SB_LOG_AGE=${SB_LOG_AGE}"
}

collect_ips(){
  [[ -f "${EDGE_EXAMPLE}" ]] && echo "  Template: ${EDGE_EXAMPLE}"
  echo ""
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
    printf 'NSX_USER=%s\nNSX_PASS=%s\nROOT_PASS=%s\n' \
      "${NSX_USER:-}" "${NSX_PASS:-}" "${ROOT_PASS:-}" > "${_CRED_FILE}" )
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
  printf "${_C_BLUE_BOLD}Usuário admin [admin]: ${_C_RESET}"; read -r NSX_USER
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
  printf "${_C_BLUE_BOLD}Limpar credenciais da memória? [S/n]: ${_C_RESET}"
  read -r _CLR
  if [[ "${_CLR,,}" == "n" ]]; then _save_creds; log "Credenciais mantidas (${_CRED_FILE})."
  else clear_creds; fi
}

ssh_admin(){
  local ip="$1"; shift
  export SSHPASS="${NSX_PASS}"
  sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
    -o ConnectTimeout=15 \
    -o LogLevel=ERROR \
    "${NSX_USER}@${ip}" "$@"
  local _rc=$?; unset SSHPASS; return $_rc
}

ssh_root(){
  local ip="$1"; shift
  export SSHPASS="${ROOT_PASS}"
  sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
    -o ConnectTimeout=15 \
    -o LogLevel=ERROR \
    "root@${ip}" "$@"
  local _rc=$?; unset SSHPASS; return $_rc
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
  local ip="$1"
  local out rc=0
  log "${ip}: enabling root SSH..."
  log_cmd "${ip}: set ssh root-login"
  out="$(admin_cmd_tty "$ip" 'set ssh root-login' 2>&1)" || rc=$?
  if _is_auth_failed "$out" || [[ $rc -eq 5 ]]; then
    local width=74
    local title=" ${ip}: FALHA DE AUTENTICAÇÃO ADMIN — node será pulado "
    echo ""
    printf "  ${_C_BOX_RED_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "${title}"
    printf "  ${_C_BOX_SIDE}│${_C_RESET}  %s\n" "${out}"
    printf "  ${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
    echo ""
    log_err "${ip}: 'set ssh root-login' recusado — senha admin incorreta, conta bloqueada ou credencial expirada."
    log_err "${ip}: verifique manualmente: ssh ${NSX_USER}@${ip}"
    NODE_AUTH_FAILED+=("$ip")
    return 1
  fi
  [[ -n "$out" ]] && log "${ip}: [set ssh root-login] ${out}"
  sleep 3
  return 0
}

disable_root_ssh(){
  local ip="$1"
  local out rc=0
  log "${ip}: disabling root SSH..."
  log_cmd "${ip}: clear ssh root-login"
  out="$(admin_cmd_tty "$ip" 'clear ssh root-login' 2>&1)" || rc=$?
  if _is_auth_failed "$out" || [[ $rc -eq 5 ]]; then
    log_warn "${ip}: falha ao desabilitar root SSH (auth). Desabilite manualmente se necessário."
    return 0
  fi
  [[ -n "$out" ]] && log "${ip}: [clear ssh root-login] ${out}"
  return 0
}

check_bundle_log(){
  local ip="$1"
  local log_file="/var/log/support_bundle.log"
  local out
  out="$(root_cmd_tty "$ip" "test -f ${log_file} && tail -1 ${log_file} || echo '__FILE_NOT_FOUND__'")"
  if grep -q '__FILE_NOT_FOUND__' <<< "$out"; then
    log_warn "${ip}: ${log_file} não encontrado."
    return 2
  fi
  local title=" ${ip}: ${log_file} (última linha) "
  local width=74
  echo ""
  printf "  ${_C_BOX_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "${title}"
  printf "  ${_C_BOX_SIDE}│${_C_RESET}  %s\n" "${out}"
  printf "  ${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
  echo ""
  if grep -qiE 'error|fail|exception|abort|fatal' <<< "$out"; then
    log_warn "${ip}: problema detectado na última linha do log."; return 1
  fi
  log_ok "${ip}: última linha do log sem erros aparentes."
  return 0
}

list_bundle_dir(){
  local ip="$1"
  local dir="/var/vmware/nsx/file-store"
  local title=" ${ip}: ls -lh ${dir}/ "
  local width=74
  local out
  out="$(root_cmd_tty "$ip" "ls -lh ${dir}/")"
  echo ""
  printf "  ${_C_BOX_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "${title}"
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
  local ip="$1"
  local dir="/var/vmware/nsx/file-store"
  root_cmd "$ip" "ls -1 ${dir}/ 2>/dev/null || true" \
    | grep '\.tgz$' || true
}

_list_bundles_with_age(){
  local ip="$1"
  local dir="/var/vmware/nsx/file-store"
  local raw
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
  BUNDLE_DATE_RECENT=""
  BUNDLE_DATE_OLD=""
  local dir="/var/vmware/nsx/file-store"
  local width=74

  log "${ip}: [PRE-CHECK] verificando status do support bundle..."
  list_bundle_dir "$ip"

  local proc_out
  proc_out="$(root_cmd "$ip" \
    "ps -ef 2>/dev/null | grep -E '${_BUNDLE_PROC_GREP}' | grep -v grep || true")"
  if [[ -n "$proc_out" ]]; then
    log_warn "${ip}: geração de bundle em andamento (processo detectado)."
    log "${ip}: processo: ${proc_out}"
    BUNDLE_STATUS="inprogress"; return 0
  fi

  local raw_pairs
  raw_pairs="$(_list_bundles_with_age "$ip")"
  local all_bundles
  all_bundles="$(echo "$raw_pairs" | awk '{print $1}' | grep -v '^$' || true)"

  log "${ip}: [bundles detectados] resultado bruto: '${all_bundles:-<vazio>}'"

  if [[ -z "$all_bundles" ]]; then
    log "${ip}: nenhum bundle encontrado em file-store."
    return 0
  fi

  local bundle_count
  bundle_count="$(echo "$all_bundles" | grep -c '.' || true)"
  log "${ip}: ${bundle_count} bundle(s) encontrado(s)."

  local now_epoch
  now_epoch="$(date +%s)"

  # Epoch do bundle mais recente de cada categoria (para data)
  local max_epoch_recent=0
  local max_epoch_old=0

  local fname fepoch age fpath
  while IFS= read -r pair; do
    [[ -z "$pair" ]] && continue
    fname="$(echo "$pair" | awk '{print $1}')"
    fepoch="$(echo "$pair" | awk '{print $2}' | tr -cd '0-9')"
    [[ -z "$fname" ]] && continue
    if [[ -z "$fepoch" || "$fepoch" == "0" ]]; then
      age=999
    else
      age=$(( (now_epoch - fepoch) / 86400 ))
    fi
    fpath="${dir}/${fname}"
    log "${ip}: arquivo '${fname}' → ${age} dia(s)."
    if [[ "$age" -le 7 ]]; then
      BUNDLE_FILES_RECENT+="${fpath}"$'\n'
      [[ "$fepoch" -gt "$max_epoch_recent" ]] && max_epoch_recent="$fepoch"
    else
      BUNDLE_FILES_OLD+="${fpath}"$'\n'
      [[ "$fepoch" -gt "$max_epoch_old" ]] && max_epoch_old="$fepoch"
    fi
  done <<< "$raw_pairs"

  BUNDLE_FILES_RECENT="${BUNDLE_FILES_RECENT%$'\n'}"
  BUNDLE_FILES_OLD="${BUNDLE_FILES_OLD%$'\n'}"

  # Converte epoch para data legível
  [[ "$max_epoch_recent" -gt 0 ]] && BUNDLE_DATE_RECENT="$(_epoch_to_date "$max_epoch_recent")" || BUNDLE_DATE_RECENT=""
  [[ "$max_epoch_old"    -gt 0 ]] && BUNDLE_DATE_OLD="$(_epoch_to_date "$max_epoch_old")"       || BUNDLE_DATE_OLD=""

  if [[ -n "$BUNDLE_FILES_RECENT" ]]; then
    BUNDLE_STATUS="recent"
    local rec_count old_count
    rec_count="$(echo "$BUNDLE_FILES_RECENT" | grep -c '.' || true)"
    old_count=0
    [[ -n "$BUNDLE_FILES_OLD" ]] && old_count="$(echo "$BUNDLE_FILES_OLD" | grep -c '.' || true)"
    local title=" ${ip}: ${rec_count} bundle(s) recente(s) ≤7d | ${old_count} antigo(s) >7d "
    echo ""
    printf "  ${_C_BOX_GREEN_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "${title}"
    while IFS= read -r fline; do
      [[ -z "$fline" ]] && continue
      printf "  ${_C_BOX_SIDE}│${_C_RESET}  ✔  %s\n" "$(basename "$fline")"
    done <<< "$BUNDLE_FILES_RECENT"
    if [[ -n "$BUNDLE_FILES_OLD" ]]; then
      while IFS= read -r fline; do
        [[ -z "$fline" ]] && continue
        printf "  ${_C_BOX_SIDE}│${_C_RESET}  ⚠  %s  [ANTIGO]\n" "$(basename "$fline")"
      done <<< "$BUNDLE_FILES_OLD"
    fi
    printf "  ${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
    echo ""
    log_ok "${ip}: bundle recente presente (${BUNDLE_DATE_RECENT:-??})."
    [[ -n "$BUNDLE_FILES_OLD" ]] && \
      log_warn "${ip}: bundle(s) antigo(s) presentes — use --clean-all para remover."
    return 0
  fi

  if [[ -n "$BUNDLE_FILES_OLD" ]]; then
    BUNDLE_STATUS="old"
    local old_count
    old_count="$(echo "$BUNDLE_FILES_OLD" | grep -c '.' || true)"
    local title=" ${ip}: ${old_count} bundle(s) ANTIGO(S) >7d "
    echo ""
    printf "  ${_C_BOX_YELLOW_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "${title}"
    while IFS= read -r fline; do
      [[ -z "$fline" ]] && continue
      printf "  ${_C_BOX_SIDE}│${_C_RESET}  ⚠  %s\n" "$(basename "$fline")"
    done <<< "$BUNDLE_FILES_OLD"
    printf "  ${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
    echo ""
    log_warn "${ip}: todos os bundles são antigos (${BUNDLE_DATE_OLD:-??})."
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
    if root_cmd "$ip" "rm -f '${fpath}'"; then
      log_warn "${ip}: deletado — ${fpath}"
    else
      log_err "${ip}: falha ao deletar — ${fpath}"
    fi
  done
}

delete_all_bundles(){
  local ip="$1"
  local dir="/var/vmware/nsx/file-store"
  log "${ip}: buscando TODOS os bundles para limpeza total..."
  local all_files
  all_files="$(_list_bundles "$ip")"
  if [[ -z "$all_files" ]]; then
    log "${ip}: nenhum bundle encontrado para deletar."
    return 0
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
    if root_cmd "$ip" "rm -f '${fpath}'"; then
      log_warn "${ip}: deletado — ${fpath}"
    else
      log_err "${ip}: falha ao deletar — ${fpath}"
    fi
  done
  log_ok "${ip}: limpeza total concluída."
}

request_support_bundle(){
  local ip="$1"
  local sb_extra="${2:-${SB_EXTRA:-}}"
  local sb_log_age="${3:-${SB_LOG_AGE:-1}}"

  local fname="sb_${ip//./_}_$(date +%Y%m%d_%H%M%S).tgz"
  local logfile="${LOG_DIR}/sb_bg_${ip//./_}_$(date +%Y%m%d_%H%M%S).log"

  local nsx_cmd="get support-bundle file ${fname}"
  if [[ -n "$sb_extra" ]]; then
    nsx_cmd="${nsx_cmd} ${sb_extra}"
  fi
  nsx_cmd="${nsx_cmd} log-age ${sb_log_age}"

  log_cmd "${ip}: [BACKGROUND] ${nsx_cmd}"
  log "${ip}: comando disparado em background — script não aguarda conclusão."
  log "${ip}: saída em: ${logfile}"

  export SSHPASS="${NSX_PASS}"
  (
    sshpass -e ssh \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
      -o ConnectTimeout=15 \
      -o LogLevel=ERROR \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=120 \
      "${NSX_USER}@${ip}" \
      "${nsx_cmd}" \
      > "${logfile}" 2>&1
    echo "[$(date '+%F %T')] [OK] Bundle concluído: ${fname}" >> "${logfile}"
  ) &
  disown $!
  unset SSHPASS

  log_ok "${ip}: solicitação disparada em background."
  log "${ip}: acompanhe com: tail -f ${logfile}"
}

# ---------------------------------------------------------------------------
# _print_report  — tabela final reutilizada por precheck e main
#
# Formato de cada linha: "ip|STATUS|AÇÃO|ARQUIVO"
# STATUS pode ser:
#   - Data YYYY-MM-DD      → verde  (bundle recente)
#   - Data YYYY-MM-DD (antigo) → amarelo
#   - "EM ANDAMENTO"       → ciano
#   - "AUTH FALHOU"        → vermelho
#   - "NENHUM"             → ciano
#   - qualquer outro       → ciano
# ---------------------------------------------------------------------------
_print_report(){
  local width=78
  local title="${1:-RELATÓRIO FINAL — Support Bundle Check}"
  shift || true
  local -a lines=("$@")

  echo ""
  printf "${_C_CYAN}╔%s╗${_C_RESET}\n" "$(_box_line $(( width - 2 )) '═')"
  printf "${_C_CYAN}║  %-*s║${_C_RESET}\n" "$(( width - 3 ))" "  ${title}  —  $(date '+%F %T')"
  printf "${_C_CYAN}╠%s╦%s╦%s╦%s╣${_C_RESET}\n" \
    "$(_box_line 19 '═')" "$(_box_line 18 '═')" "$(_box_line 18 '═')" "$(_box_line 20 '═')"
  printf "${_C_CYAN}║${_C_RESET} %-17s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-18s ${_C_CYAN}║${_C_RESET}\n" \
    "NODE" "DATA BUNDLE" "AÇÃO" "ARQUIVO"
  printf "${_C_CYAN}╠%s╬%s╬%s╬%s╣${_C_RESET}\n" \
    "$(_box_line 19 '═')" "$(_box_line 18 '═')" "$(_box_line 18 '═')" "$(_box_line 20 '═')"

  local entry
  for entry in "${lines[@]}"; do
    IFS='|' read -r r_ip r_status r_acao r_arquivo <<< "$entry"
    local r_arq_short
    r_arq_short="$(basename "${r_arquivo%%$'\n'*}" 2>/dev/null || echo "${r_arquivo}")"
    [[ ${#r_arq_short} -gt 18 ]] && r_arq_short="${r_arq_short:0:15}..."
    if [[ "$r_status" == "AUTH FALHOU" ]]; then
      printf "${_C_RED}║${_C_RESET} %-17s ${_C_RED}║${_C_RESET} %-16s ${_C_RED}║${_C_RESET} %-16s ${_C_RED}║${_C_RESET} %-18s ${_C_RED}║${_C_RESET}\n" \
        "$r_ip" "$r_status" "$r_acao" "$r_arq_short"
    elif [[ "$r_status" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      # Data pura → verde (bundle recente ≤7d)
      printf "${_C_GREEN}║${_C_RESET} %-17s ${_C_GREEN}║${_C_RESET} %-16s ${_C_GREEN}║${_C_RESET} %-16s ${_C_GREEN}║${_C_RESET} %-18s ${_C_GREEN}║${_C_RESET}\n" \
        "$r_ip" "$r_status" "$r_acao" "$r_arq_short"
    elif [[ "$r_status" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ \(antigo\)$ ]]; then
      # Data com sufixo (antigo) → amarelo
      printf "${_C_YELLOW}║${_C_RESET} %-17s ${_C_YELLOW}║${_C_RESET} %-16s ${_C_YELLOW}║${_C_RESET} %-16s ${_C_YELLOW}║${_C_RESET} %-18s ${_C_YELLOW}║${_C_RESET}\n" \
        "$r_ip" "$r_status" "$r_acao" "$r_arq_short"
    else
      printf "${_C_CYAN}║${_C_RESET} %-17s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-18s ${_C_CYAN}║${_C_RESET}\n" \
        "$r_ip" "$r_status" "$r_acao" "$r_arq_short"
    fi
  done

  printf "${_C_CYAN}╚%s╩%s╩%s╩%s╝${_C_RESET}\n" \
    "$(_box_line 19 '═')" "$(_box_line 18 '═')" "$(_box_line 18 '═')" "$(_box_line 20 '═')"
  echo ""
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
  echo "[OK] sshpass já instalado: $(command -v sshpass)"; exit 0
fi
for pm in apt-get yum dnf; do
  if command -v $pm &>/dev/null; then
    $pm install -y sshpass && echo "[OK] sshpass instalado." && exit 0
  fi
done
echo "[ERR] Instale sshpass manualmente."; exit 1
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

cat > "${AUTO_DIR}/setup_keys.sh" <<'SETUP'
#!/usr/bin/env bash
echo "[INFO] Autenticação via sshpass (senha). Execute ./test_connections.sh para validar."
SETUP
chmod +x "${AUTO_DIR}/setup_keys.sh"

cat > "${AUTO_DIR}/test_connections.sh" <<'TESTC'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds
REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"
log "Relatório: ${REPORT}"
for ip in "${EDGE_IPS[@]}"; do
  {
    echo "====================================== Node: ${ip}"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping filtrado"
    admin_cmd_tty "$ip" 'get version'     || echo "FAIL admin SSH"
    admin_cmd_tty "$ip" 'get service ssh' || echo "FAIL admin SSH"
    admin_cmd_tty "$ip" 'get managers'   || echo "FAIL admin SSH"
    if enable_root_ssh "$ip"; then
      root_cmd_tty "$ip" 'uname -a'  || echo "FAIL root SSH"
      root_cmd_tty "$ip" 'uptime'    || echo "FAIL root SSH"
      root_cmd_tty "$ip" 'df -h /var/log' || echo "FAIL root SSH"
      root_cmd_tty "$ip" 'ls -lh /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND'
      list_bundle_dir "$ip"
      disable_root_ssh "$ip"
    fi
    echo
  } | tee -a "$REPORT"
done
[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
  log_warn "Nodes com falha de autenticação admin: ${NODE_AUTH_FAILED[*]}"
log_ok "Teste concluído. Relatório: ${REPORT}"
prompt_clear_creds
TESTC
chmod +x "${AUTO_DIR}/test_connections.sh"

# ---------------------------------------------------------------------------
# nsx_sb_precheck.sh  — v3.16
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_precheck.sh" <<'PRECHECK'
#!/usr/bin/env bash
# nsx_sb_precheck.sh  — v3.16
#
# Executa APENAS o pre-check em todos os Edge Nodes:
#   1. Habilita root SSH (admin)
#   2. Verifica bundles existentes por idade (check_bundle_status)
#   3. Desabilita root SSH
#   4. Exibe relatório final: coluna STATUS mostra a data do bundle
#
# Nenhuma geração, deleção ou modificação de bundle é realizada.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds

STATUS_CSV="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,bundle_status,bundle_date,recent_count,old_count,files_recent,files_old,timestamp' > "${STATUS_CSV}"

declare -a REPORT_LINES=()

log_banner "PRE-CHECK ONLY — Verificando bundles em todos os Edge Nodes"

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando pre-check..."

  if ! enable_root_ssh "$ip"; then
    REPORT_LINES+=("${ip}|AUTH FALHOU|PULADO|—")
    printf '%s,auth_failed,,0,0,,,%s\n' "$ip" "$(date +%F_%T)" >> "${STATUS_CSV}"
    continue
  fi

  check_bundle_log "$ip" || true
  check_bundle_status "$ip"

  disable_root_ssh "$ip" || true

  local_rec=0; local_old=0
  [[ -n "$BUNDLE_FILES_RECENT" ]] && local_rec="$(echo "$BUNDLE_FILES_RECENT" | grep -c '.' || true)"
  [[ -n "$BUNDLE_FILES_OLD"    ]] && local_old="$(echo "$BUNDLE_FILES_OLD"    | grep -c '.' || true)"

  first_recent=""
  [[ -n "$BUNDLE_FILES_RECENT" ]] && first_recent="$(echo "$BUNDLE_FILES_RECENT" | head -1)"
  first_old=""
  [[ -n "$BUNDLE_FILES_OLD" ]]    && first_old="$(echo "$BUNDLE_FILES_OLD" | head -1)"

  # Data para CSV: recente prevalece; senão antiga
  csv_date="${BUNDLE_DATE_RECENT:-${BUNDLE_DATE_OLD:-}}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ip" "$BUNDLE_STATUS" "$csv_date" "$local_rec" "$local_old" \
    "${first_recent:-}" "${first_old:-}" "$(date +%F_%T)" \
    >> "${STATUS_CSV}"

  case "$BUNDLE_STATUS" in
    recent)
      _status="${BUNDLE_DATE_RECENT:-RECENTE}"
      REPORT_LINES+=("${ip}|${_status}|OK|${first_recent:-—}")
      ;;
    old)
      _status="${BUNDLE_DATE_OLD:-ANTIGO} (antigo)"
      REPORT_LINES+=("${ip}|${_status}|ATENÇÃO|${first_old:-—}")
      ;;
    none)
      REPORT_LINES+=("${ip}|NENHUM|AUSENTE|—")
      ;;
    inprogress)
      REPORT_LINES+=("${ip}|EM ANDAMENTO|AGUARDAR|—")
      ;;
    *)
      REPORT_LINES+=("${ip}|DESCONHECIDO|VERIFICAR|—")
      ;;
  esac
done

_print_report "PRE-CHECK — Data dos Support Bundles" "${REPORT_LINES[@]}"

[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
  log_warn "Nodes com falha de autenticação: ${NODE_AUTH_FAILED[*]} — verifique credenciais manualmente."

log_ok "Pre-check concluído. CSV: ${STATUS_CSV}"
log "Para gerar bundles: ./nsx_sb_main.sh"
log "Para limpar todos:  ./nsx_sb_main.sh --clean-all"

prompt_clear_creds
PRECHECK
chmod +x "${AUTO_DIR}/nsx_sb_precheck.sh"

# ---------------------------------------------------------------------------
# nsx_sb_main.sh  — v3.16
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh  — v3.16
#
# FLAGS:
#   (nenhuma)        Fluxo completo: pre-check + geração de bundle
#   --clean-all      Apaga todos os bundles antes do fluxo completo
#   --precheck-only  Executa apenas o pre-check e exibe relatório (sem gerar bundles)
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

# ---------------------------------------------------------------------------
# Modo --precheck-only
# ---------------------------------------------------------------------------
if [[ "$PRECHECK_ONLY" == true ]]; then
  log_banner "PRE-CHECK ONLY — Verificando bundles (sem geração)"

  for ip in "${EDGE_IPS[@]}"; do
    log "${ip}: iniciando pre-check..."

    if ! enable_root_ssh "$ip"; then
      REPORT_LINES+=("${ip}|AUTH FALHOU|PULADO|—")
      printf '%s,precheck,auth_failed,admin_auth_error,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      continue
    fi

    check_bundle_log "$ip" || true
    check_bundle_status "$ip"
    disable_root_ssh "$ip" || true

    printf '%s,precheck,bundle_status,%s,%s\n' "$ip" "$BUNDLE_STATUS" "$(date +%F_%T)" \
      | tee -a "$RUN_LOG" >> "$STATUS_CSV"

    first_recent=""
    [[ -n "$BUNDLE_FILES_RECENT" ]] && first_recent="$(echo "$BUNDLE_FILES_RECENT" | head -1)"
    first_old=""
    [[ -n "$BUNDLE_FILES_OLD" ]]    && first_old="$(echo "$BUNDLE_FILES_OLD" | head -1)"

    case "$BUNDLE_STATUS" in
      recent)
        _status="${BUNDLE_DATE_RECENT:-RECENTE}"
        REPORT_LINES+=("${ip}|${_status}|OK|${first_recent:-—}")
        ;;
      old)
        _status="${BUNDLE_DATE_OLD:-ANTIGO} (antigo)"
        REPORT_LINES+=("${ip}|${_status}|ATENÇÃO|${first_old:-—}")
        ;;
      none)       REPORT_LINES+=("${ip}|NENHUM|AUSENTE|—")        ;;
      inprogress) REPORT_LINES+=("${ip}|EM ANDAMENTO|AGUARDAR|—") ;;
      *)          REPORT_LINES+=("${ip}|DESCONHECIDO|VERIFICAR|—") ;;
    esac
  done

  _print_report "PRE-CHECK — Data dos Support Bundles" "${REPORT_LINES[@]}"

  [[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
    log_warn "Nodes com falha de autenticação: ${NODE_AUTH_FAILED[*]}"
  log_ok "Status CSV: ${STATUS_CSV}"
  prompt_clear_creds
  exit 0
fi

# ---------------------------------------------------------------------------
# Fluxo completo
# ---------------------------------------------------------------------------
ask_bundle_options

if [[ "$CLEAN_ALL" == true ]]; then
  log_banner "CLEAN-ALL: Apagando TODOS os bundles existentes"
  for ip in "${EDGE_IPS[@]}"; do
    if ! enable_root_ssh "$ip"; then
      printf '%s,clean_all,auth_failed,admin_auth_error,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      continue
    fi
    list_bundle_dir "$ip"
    delete_all_bundles "$ip"
    disable_root_ssh "$ip" || true
    printf '%s,clean_all,deleted_all,ok,%s\n' "$ip" "$(date +%F_%T)" \
      | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  done
fi

log_banner "PRE-CHECK: Verificando bundles existentes"

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."

  if ! enable_root_ssh "$ip"; then
    printf '%s,precheck,auth_failed,admin_auth_error,%s\n' "$ip" "$(date +%F_%T)" \
      | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    REPORT_LINES+=("${ip}|AUTH FALHOU|PULADO|—")
    NODE_ACAO[$ip]="PULADO"
    continue
  fi

  check_bundle_log "$ip" || true
  check_bundle_status "$ip"

  printf '%s,precheck,bundle_status,%s,%s\n' "$ip" "$BUNDLE_STATUS" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"

  first_recent=""
  [[ -n "$BUNDLE_FILES_RECENT" ]] && first_recent="$(echo "$BUNDLE_FILES_RECENT" | head -1)"
  first_old=""
  [[ -n "$BUNDLE_FILES_OLD" ]] && first_old="$(echo "$BUNDLE_FILES_OLD" | head -1)"

  case "$BUNDLE_STATUS" in
    recent)
      _status="${BUNDLE_DATE_RECENT:-RECENTE}"
      REPORT_LINES+=("${ip}|${_status}|PULADO|${first_recent:-—}")
      NODE_ACAO[$ip]="PULADO"
      ;;
    old)
      _status="${BUNDLE_DATE_OLD:-ANTIGO} (antigo)"
      delete_old_bundles "$ip"
      printf '%s,precheck,deleted_old,ok,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      REPORT_LINES+=("${ip}|${_status}|DEL+GERANDO|${first_old:-—}")
      NODE_ACAO[$ip]="GERANDO"
      ;;
    none)
      REPORT_LINES+=("${ip}|NENHUM|GERANDO|—")
      NODE_ACAO[$ip]="GERANDO"
      ;;
    inprogress)
      REPORT_LINES+=("${ip}|EM ANDAMENTO|PULADO|—")
      NODE_ACAO[$ip]="PULADO"
      ;;
  esac
done

log_banner "PHASE 1: Support Bundle Request (background)"
log "Opções: get support-bundle file <nome>${SB_EXTRA:+ ${SB_EXTRA}} log-age ${SB_LOG_AGE}"

for ip in "${EDGE_IPS[@]}"; do
  _node_auth_failed "$ip" && continue
  if [[ "${NODE_ACAO[$ip]:-}" == "PULADO" ]]; then
    log "${ip}: pulando solicitação de bundle."
    continue
  fi
  request_support_bundle "$ip" "${SB_EXTRA:-}" "${SB_LOG_AGE:-1}"
  printf '%s,phase1,sb_requested_bg,ok,%s\n' "$ip" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

log_ok "Phase 1 done — bundles disparados em background."

log_banner "FINAL: Disabling root SSH"
for ip in "${EDGE_IPS[@]}"; do
  _node_auth_failed "$ip" && continue
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

_print_report "RELATÓRIO FINAL — Support Bundle Check" "${REPORT_LINES[@]}"

[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
  log_warn "Nodes com falha de autenticação: ${NODE_AUTH_FAILED[*]} — verifique credenciais manualmente."
log "Para acompanhar a geração: tail -f ${LOG_DIR}/sb_bg_*.log"
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
    log_warn "${ip}: pulando (falha de autenticação admin)."
    continue
  fi
  log_cmd "${ip}: ${SHELL_CMD}"
  root_cmd_tty "$ip" "${SHELL_CMD}" || log_warn "${ip}: comando retornou erro"
  disable_root_ssh "$ip" || true
done
[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
  log_warn "Nodes pulados (auth falhou): ${NODE_AUTH_FAILED[*]}"
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
echo "Nodes disponíveis:"
for i in "${!EDGE_IPS[@]}"; do echo "  [$i] ${EDGE_IPS[$i]}"; done
printf "${_C_BLUE_BOLD}Número do node ou IP direto: ${_C_RESET}"; read -r SEL
if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ -n "${EDGE_IPS[$SEL]:-}" ]]; then
  TARGET_IP="${EDGE_IPS[$SEL]}"
else
  TARGET_IP="$SEL"
fi
printf "${_C_BLUE_BOLD}Usuário [admin]: ${_C_RESET}"; read -r LOGIN_USER
LOGIN_USER="${LOGIN_USER:-admin}"
if [[ "$LOGIN_USER" == "root" ]]; then
  ask_root_creds; export SSHPASS="${ROOT_PASS}"
else
  ask_admin_creds; export SSHPASS="${NSX_PASS}"; LOGIN_USER="${NSX_USER}"
fi
log "Conectando em ${LOGIN_USER}@${TARGET_IP}..."
sshpass -e ssh -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
  -o ConnectTimeout=15 \
  -o LogLevel=ERROR \
  "${LOGIN_USER}@${TARGET_IP}"
unset SSHPASS
CLISCRIPT
chmod +x "${AUTO_DIR}/nsx_ssh_cli.sh"

cat > "${DOCS_DIR}/MANUAL.md" <<'MANUALDOC'
# NSX Edge Automation — Manual de Uso  v3.16

## Scripts disponíveis

| Script | Descrição |
|---|---|
| `nsx_sb_main.sh` | Fluxo completo: pre-check + geração de bundle |
| `nsx_sb_main.sh --precheck-only` | Apenas pre-check + relatório (sem gerar/deletar) |
| `nsx_sb_main.sh --clean-all` | Apaga todos os bundles + fluxo completo |
| `nsx_sb_precheck.sh` | Idêntico a `--precheck-only`, script dedicado |
| `test_connections.sh` | Testa conectividade SSH admin + root |
| `admin_exec.sh` | Executa comando NSX CLI em todos os nodes |
| `root_exec.sh` | Executa comando shell como root em todos os nodes |
| `nsx_ssh_cli.sh` | SSH interativo para um node específico |

## Uso rápido

```bash
cd ~/nsx-edge-automation/automations/support_bundle

# Só verificar o estado dos bundles (sem gerar nada):
./nsx_sb_precheck.sh
# ou equivalente:
./nsx_sb_main.sh --precheck-only

# Fluxo completo (pre-check + geração):
./nsx_sb_main.sh

# Limpar tudo e gerar novo:
./nsx_sb_main.sh --clean-all
```

## Relatório do pre-check (v3.16)

A coluna **DATA BUNDLE** exibe a data real (`YYYY-MM-DD`) do arquivo mais recente encontrado:

| Cor | Valor em DATA BUNDLE | Significado |
|---|---|---|
| Verde | `2026-05-12` | Bundle recente (≤7d) — nenhuma ação necessária |
| Amarelo | `2026-04-30 (antigo)` | Bundle expirado (>7d) — recomenda limpeza |
| Ciano | `NENHUM` | Nenhum bundle encontrado — será gerado no fluxo completo |
| Ciano | `EM ANDAMENTO` | Geração em curso — aguardar conclusão |
| Vermelho | `AUTH FALHOU` | Credenciais admin inválidas — verificar manualmente |

O relatório também é salvo em CSV em `logs/precheck_YYYYMMDD_HHMMSS.csv`
com coluna `bundle_date`.

## Correções v3.16

- `check_bundle_status()`: exporta `BUNDLE_DATE_RECENT` e `BUNDLE_DATE_OLD`
  (data `YYYY-MM-DD` derivada do `fepoch`/`stat` do bundle mais recente).
- `_print_report()`: cabeçalho da coluna renomeado para **DATA BUNDLE**;
  detecção de cor por regex `^[0-9]{4}-[0-9]{2}-[0-9]{2}` (verde = recente,
  `(antigo)` = amarelo).
- `nsx_sb_precheck.sh` e `nsx_sb_main.sh`: STATUS passa a ser a data real
  em vez de `RECENTE (≤7d)` / `ANTIGO (>7d)`.

## Correções v3.15

- Novo `nsx_sb_precheck.sh` — script dedicado de pre-check.
- `nsx_sb_main.sh --precheck-only` — flag equivalente inline.
- `_print_report()` em `common.sh` — função reutilizável de tabela colorida.

## Correções v3.14

| Item | Antes | Depois |
|---|---|---|
| `_list_bundles()` | `grep '^sb_.*\.tgz$'` | `grep '\.tgz$'` — captura `support-bundle-*` |
| `_list_bundles_with_age()` | `grep '^sb_.*\.tgz '` | `grep '\.tgz '` |
| `delete_all_bundles()` loop | `while read` | `mapfile + for` |
| `delete_old_bundles()` loop | `while read` | `mapfile + for` |

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
  echo "[WARN] sshpass não encontrado. Execute: bash ${AUTO_DIR}/install_dependencies.sh"
else
  echo "[OK] sshpass encontrado: $(command -v sshpass)"
fi

echo ""
echo "================================================================"
echo "  Deploy concluído! v3.16"
echo "================================================================"
echo ""
echo "  Novidade v3.16:"
echo "    STATUS na tabela exibe a data real do bundle (YYYY-MM-DD)"
echo "    em vez de 'RECENTE (≤7d)' / 'ANTIGO (>7d)'"
echo ""
echo "Próximos passos:"
echo "  1. cd ${AUTO_DIR} && ./nsx_sb_precheck.sh"
echo "  2. cd ${AUTO_DIR} && ./nsx_sb_main.sh"
echo ""

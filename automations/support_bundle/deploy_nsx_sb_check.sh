#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  v3.8
# Deploy local do kit NSX Edge Automation - Support Bundle
#
# USO:
#   bash deploy_nsx_sb_check.sh [--dir /caminho/destino]
#   curl -fsSL https://raw.githubusercontent.com/leopoldocosta/nsx-edge-automation/main/automations/support_bundle/deploy_nsx_sb_check.sh | bash
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
echo "  NSX Edge Automation — Support Bundle Kit  v3.8"
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
# lib/common.sh  — v3.8
# ---------------------------------------------------------------------------
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh  — v3.8
#
# CORREÇÃO v3.8 — bug de classificação de bundles:
#
#   Causa raiz:
#     _bundle_age_days() fazia UMA chamada SSH por arquivo (stat + date).
#     Quando havia 2+ bundles, a segunda chamada SSH podia retornar string
#     vazia ou falhar silenciosamente, fazendo age=999 (fallback), e o bundle
#     NOVO era classificado como ANTIGO — era deletado erroneamente.
#
#   Correção:
#     Nova função _list_bundles_with_age() faz UMA ÚNICA chamada SSH que
#     retorna "NOME EPOCH" para todos os bundles de uma vez, usando:
#       for f in $(ls | grep ...); do stat -c '%n %Y' "$f"; done
#     A idade é calculada localmente com a hora do próprio host.
#     Zero chamadas SSH extras por arquivo.
#
#   Impacto:
#     check_bundle_status() agora usa _list_bundles_with_age() em vez de
#     _list_bundles() + _bundle_age_days() em loop.
#     _bundle_age_days() mantida por compatibilidade mas não usada no fluxo
#     principal.
#
# Herdado v3.7:
#   - _BUNDLE_PROC_GREP preciso: gen_support_bundle|support_bundles/__self__.py
#   - LogLevel=ERROR em ssh_admin/ssh_root
#   - enable_root_ssh detecta Permission denied → NODE_AUTH_FAILED[]
#   - nsx_sb_main.sh pula nodes em NODE_AUTH_FAILED[] em todas as fases
#
# Herdado v3.5:
#   - _BUNDLE_GREP ampliado: support-bundle|support_bundle|sb_|*.tgz
#   - Múltiplos bundles: classificação por idade, contagem, mix recente+antigo
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

# Array global de nodes com falha de autenticação admin
declare -a NODE_AUTH_FAILED=()

# ---------------------------------------------------------------------------
# _BUNDLE_GREP — padrão ERE para identificar arquivos de support bundle
# Detecta: support-bundle*, support_bundle*, sb_*, e qualquer *.tgz
# ---------------------------------------------------------------------------
_BUNDLE_GREP='(^support[-_]bundle|^sb_).*\.tgz$|\.tgz$'

# ---------------------------------------------------------------------------
# _BUNDLE_PROC_GREP — padrão preciso para detectar geração em andamento
# Processos reais observados no NSX durante geração de support bundle:
#   sudo .../gen_support_bundle ...
#   /bin/sh .../gen_support_bundle ...
#   python3 .../support_bundles/__self__.py ...
# NÃO usa padrões genéricos como 'support_bundle' que colidiriam com o
# nome do diretório do próprio script.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# _is_auth_failed OUTPUT
# ---------------------------------------------------------------------------
_is_auth_failed(){
  echo "$1" | grep -qiE 'permission denied|authentication failed|publickey|no supported authentication'
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

# ---------------------------------------------------------------------------
# ssh_admin / ssh_root
#   -o LogLevel=ERROR suprime warnings do cliente SSH local (ex: opções
#   obsoletas no /etc/ssh/ssh_config do host de monitoramento).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# _node_auth_failed IP
# ---------------------------------------------------------------------------
_node_auth_failed(){
  local ip="$1"
  local f
  for f in "${NODE_AUTH_FAILED[@]:-}"; do
    [[ "$f" == "$ip" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# enable_root_ssh IP
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# disable_root_ssh IP
# ---------------------------------------------------------------------------
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
}

# ---------------------------------------------------------------------------
# check_bundle_log IP
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# list_bundle_dir IP
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# _bundle_age_days IP FILEPATH
#   Mantida por compatibilidade. No fluxo principal, use _list_bundles_with_age.
# ---------------------------------------------------------------------------
_bundle_age_days(){
  local ip="$1" fpath="$2"
  local now_epoch file_epoch age
  file_epoch="$(root_cmd_tty "$ip" "stat -c '%Y' '${fpath}' 2>/dev/null || echo 0")"
  now_epoch="$(root_cmd_tty "$ip" "date +%s")"
  file_epoch="$(echo "${file_epoch}" | tr -cd '0-9')"
  now_epoch="$(echo "${now_epoch}" | tr -cd '0-9')"
  if [[ -z "$file_epoch" || "$file_epoch" == "0" || -z "$now_epoch" ]]; then
    echo 999; return
  fi
  age=$(( (now_epoch - file_epoch) / 86400 ))
  echo "$age"
}

# ---------------------------------------------------------------------------
# _list_bundles IP
#   Retorna apenas os nomes dos arquivos .tgz (um por linha).
# ---------------------------------------------------------------------------
_list_bundles(){
  local ip="$1"
  local dir="/var/vmware/nsx/file-store"
  root_cmd_tty "$ip" "ls -1 ${dir}/ 2>/dev/null | grep -E '${_BUNDLE_GREP}' || true"
}

# ---------------------------------------------------------------------------
# _list_bundles_with_age IP
#
#   FIX v3.8 — uma única chamada SSH retorna "NOME EPOCH" para todos os
#   bundles, usando stat em loop no nó. A idade é calculada localmente com
#   $(date +%s) do host de monitoramento, evitando múltiplas conexões SSH
#   por arquivo que falhavam silenciosamente com strings vazias → age=999.
#
#   Saída (stdout): linhas no formato "NOME_DO_ARQUIVO EPOCH"
#   Exemplo:
#     bundle-edge019.tgz 1648396800
#     sb_172_18_214_19_20260514_175712.tgz 1747267200
# ---------------------------------------------------------------------------
_list_bundles_with_age(){
  local ip="$1"
  local dir="/var/vmware/nsx/file-store"
  local bundle_grep="${_BUNDLE_GREP}"

  # Uma chamada SSH: lista todos .tgz, filtra pelo padrão de bundles,
  # e retorna "basename epoch" de cada arquivo.
  root_cmd_tty "$ip" \
    "cd '${dir}' 2>/dev/null && \
     for f in \$(ls -1 2>/dev/null | grep -E '${bundle_grep}' || true); do \
       ep=\$(stat -c '%Y' \"\$f\" 2>/dev/null || echo 0); \
       echo \"\$f \$ep\"; \
     done"
}

# ---------------------------------------------------------------------------
# check_bundle_status IP
#
#   FIX v3.8: usa _list_bundles_with_age() — UMA chamada SSH retorna todos
#   os bundles com seu epoch. Idade calculada localmente. Elimina o problema
#   de múltiplas chamadas SSH falhando silenciosamente e causando age=999.
# ---------------------------------------------------------------------------
check_bundle_status(){
  local ip="$1"
  BUNDLE_STATUS="none"
  BUNDLE_FILES_RECENT=""
  BUNDLE_FILES_OLD=""
  local dir="/var/vmware/nsx/file-store"
  local width=74

  log "${ip}: [PRE-CHECK] verificando status do support bundle..."
  list_bundle_dir "$ip"

  # Detecta geração em andamento usando padrão preciso (_BUNDLE_PROC_GREP)
  local proc_out
  proc_out="$(root_cmd_tty "$ip" \
    "ps -ef 2>/dev/null | grep -E '${_BUNDLE_PROC_GREP}' | grep -v grep || true")"
  if [[ -n "$proc_out" ]]; then
    log_warn "${ip}: geração de bundle em andamento (processo detectado)."
    log "${ip}: processo: ${proc_out}"
    BUNDLE_STATUS="inprogress"; return 0
  fi

  # Uma única chamada SSH: retorna "nome epoch" por bundle
  local raw_pairs
  raw_pairs="$(_list_bundles_with_age "$ip")"
  # Extrai apenas os nomes para o log de detecção
  local all_bundles
  all_bundles="$(echo "$raw_pairs" | awk '{print $1}' | grep -v '^$' || true)"

  log "${ip}: [bundles detectados] resultado bruto: '${all_bundles:-<vazio>}'"

  if [[ -z "$all_bundles" ]]; then
    log "${ip}: nenhum bundle encontrado em file-store — será gerado."
    return 0
  fi

  local bundle_count
  bundle_count="$(echo "$all_bundles" | grep -c '.' || true)"
  log "${ip}: ${bundle_count} bundle(s) encontrado(s)."

  # Calcula idade localmente (evita SSH extra por arquivo)
  local now_epoch
  now_epoch="$(date +%s)"

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
    else
      BUNDLE_FILES_OLD+="${fpath}"$'\n'
    fi
  done <<< "$raw_pairs"

  BUNDLE_FILES_RECENT="${BUNDLE_FILES_RECENT%$'\n'}"
  BUNDLE_FILES_OLD="${BUNDLE_FILES_OLD%$'\n'}"

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
    log_ok "${ip}: bundle recente presente — geração será pulada."
    [[ -n "$BUNDLE_FILES_OLD" ]] && \
      log_warn "${ip}: bundle(s) antigo(s) presentes — use --clean-all para remover."
    return 0
  fi

  if [[ -n "$BUNDLE_FILES_OLD" ]]; then
    BUNDLE_STATUS="old"
    local old_count
    old_count="$(echo "$BUNDLE_FILES_OLD" | grep -c '.' || true)"
    local title=" ${ip}: ${old_count} bundle(s) ANTIGO(S) >7d — serão deletados "
    echo ""
    printf "  ${_C_BOX_YELLOW_TITLE}┌─%-*s─┐${_C_RESET}\n" "$(( width - 4 ))" "${title}"
    while IFS= read -r fline; do
      [[ -z "$fline" ]] && continue
      printf "  ${_C_BOX_SIDE}│${_C_RESET}  ⚠  %s\n" "$(basename "$fline")"
    done <<< "$BUNDLE_FILES_OLD"
    printf "  ${_C_BOX_SIDE}└%s┘${_C_RESET}\n" "$(_box_line $(( width - 2 )) '─')"
    echo ""
    log_warn "${ip}: todos os bundles são antigos — serão deletados e novo será gerado."
    return 0
  fi

  log "${ip}: nenhum bundle encontrado — será gerado."
  return 0
}

# ---------------------------------------------------------------------------
# delete_old_bundles IP
# ---------------------------------------------------------------------------
delete_old_bundles(){
  local ip="$1"
  [[ -z "$BUNDLE_FILES_OLD" ]] && return 0
  log "${ip}: deletando bundle(s) antigo(s)..."
  while IFS= read -r fpath; do
    [[ -z "$fpath" ]] && continue
    log_cmd "${ip}: rm -f ${fpath}"
    if root_cmd_tty "$ip" "rm -f '${fpath}'"; then
      log_warn "${ip}: deletado — ${fpath}"
    else
      log_err "${ip}: falha ao deletar — ${fpath}"
    fi
  done <<< "$BUNDLE_FILES_OLD"
}

# ---------------------------------------------------------------------------
# delete_all_bundles IP  (--clean-all)
# ---------------------------------------------------------------------------
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
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local fpath="${dir}/${f}"
    log_cmd "${ip}: rm -f ${fpath}"
    if root_cmd_tty "$ip" "rm -f '${fpath}'"; then
      log_warn "${ip}: deletado — ${fpath}"
    else
      log_err "${ip}: falha ao deletar — ${fpath}"
    fi
  done <<< "$all_files"
  log_ok "${ip}: limpeza total concluída."
}

# ---------------------------------------------------------------------------
# request_support_bundle IP
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  local fname="sb_${ip//./_}_$(date +%Y%m%d_%H%M%S).tgz"
  local logfile="${LOG_DIR}/sb_bg_${ip//./_}_$(date +%Y%m%d_%H%M%S).log"

  log_cmd "${ip}: [BACKGROUND] get support-bundle file ${fname} log-age 1"
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
      "get support-bundle file ${fname} log-age 1" \
      > "${logfile}" 2>&1
    echo "[$(date '+%F %T')] [OK] Bundle concluído: ${fname}" >> "${logfile}"
  ) &
  disown $!
  unset SSHPASS

  log_ok "${ip}: solicitação disparada em background."
  log "${ip}: acompanhe com: tail -f ${logfile}"
}
COMMON
chmod +x "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# edge_nodes.example
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/edge_nodes.example" <<'EXAMPLE'
# edge_nodes.example — copie para edge_nodes.txt e edite
192.168.1.10
192.168.1.11
192.168.1.12
EXAMPLE

# ---------------------------------------------------------------------------
# install_dependencies.sh
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# setup_keys.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/setup_keys.sh" <<'SETUP'
#!/usr/bin/env bash
echo "[INFO] Autenticação via sshpass (senha). Execute ./test_connections.sh para validar."
SETUP
chmod +x "${AUTO_DIR}/setup_keys.sh"

# ---------------------------------------------------------------------------
# test_connections.sh
# ---------------------------------------------------------------------------
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
# nsx_sb_main.sh  — v3.8
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh  — v3.8
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds

CLEAN_ALL=false
[[ "${1:-}" == "--clean-all" ]] && CLEAN_ALL=true

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

declare -a REPORT_LINES=()

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
    disable_root_ssh "$ip"
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
    continue
  fi

  check_bundle_log "$ip" || true
  check_bundle_status "$ip"

  printf '%s,precheck,bundle_status,%s,%s\n' "$ip" "$BUNDLE_STATUS" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"

  case "$BUNDLE_STATUS" in
    recent)
      REPORT_LINES+=("${ip}|RECENTE (≤7d)|PULADO|${BUNDLE_FILES_RECENT}")
      ;;
    old)
      delete_old_bundles "$ip"
      printf '%s,precheck,deleted_old,ok,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      REPORT_LINES+=("${ip}|ANTIGO (>7d)|DEL+GERANDO|${BUNDLE_FILES_OLD}")
      ;;
    none)
      REPORT_LINES+=("${ip}|NENHUM|GERANDO|—")
      ;;
    inprogress)
      REPORT_LINES+=("${ip}|EM ANDAMENTO|PULADO|—")
      ;;
  esac
done

log_banner "PHASE 1: Support Bundle Request (background)"

for ip in "${EDGE_IPS[@]}"; do
  if _node_auth_failed "$ip"; then
    log "${ip}: pulando (falha de autenticação admin)."
    continue
  fi

  local_acao=""
  for entry in "${REPORT_LINES[@]}"; do
    if [[ "${entry%%|*}" == "$ip" ]]; then
      local_acao="$(echo "$entry" | cut -d'|' -f3)"
      break
    fi
  done

  if [[ "$local_acao" == "PULADO" ]]; then
    log "${ip}: pulando solicitação de bundle."
    continue
  fi

  request_support_bundle "$ip"
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

echo ""
printf "${_C_CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${_C_RESET}\n"
printf "${_C_CYAN}║  RELATÓRIO FINAL — Support Bundle Check  %-35s║${_C_RESET}\n" "$(date '+%F %T')"
printf "${_C_CYAN}╠═══════════════════╦══════════════════╦══════════════════╦════════════════════╣${_C_RESET}\n"
printf "${_C_CYAN}║ %-17s ║ %-16s ║ %-16s ║ %-18s ║${_C_RESET}\n" "NODE" "STATUS" "AÇÃO" "ARQUIVO"
printf "${_C_CYAN}╠═══════════════════╬══════════════════╬══════════════════╬════════════════════╣${_C_RESET}\n"
for entry in "${REPORT_LINES[@]}"; do
  IFS='|' read -r r_ip r_status r_acao r_arquivo <<< "$entry"
  r_arq_short="$(basename "${r_arquivo%%$'\n'*}" 2>/dev/null || echo "${r_arquivo}")"
  [[ ${#r_arq_short} -gt 18 ]] && r_arq_short="${r_arq_short:0:15}..."
  if [[ "$r_status" == "AUTH FALHOU" ]]; then
    printf "${_C_RED}║${_C_RESET} %-17s ${_C_RED}║${_C_RESET} %-16s ${_C_RED}║${_C_RESET} %-16s ${_C_RED}║${_C_RESET} %-18s ${_C_RED}║${_C_RESET}\n" \
      "$r_ip" "$r_status" "$r_acao" "$r_arq_short"
  else
    printf "${_C_CYAN}║${_C_RESET} %-17s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-18s ${_C_CYAN}║${_C_RESET}\n" \
      "$r_ip" "$r_status" "$r_acao" "$r_arq_short"
  fi
done
printf "${_C_CYAN}╚═══════════════════╩══════════════════╩══════════════════╩════════════════════╝${_C_RESET}\n"
echo ""
[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
  log_warn "Nodes com falha de autenticação: ${NODE_AUTH_FAILED[*]} — verifique credenciais manualmente."
log "Para acompanhar a geração: tail -f ${LOG_DIR}/sb_bg_*.log"
log_ok "Status CSV: ${STATUS_CSV}"

prompt_clear_creds
MAIN
chmod +x "${AUTO_DIR}/nsx_sb_main.sh"

# ---------------------------------------------------------------------------
# admin_exec.sh
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# root_exec.sh
# ---------------------------------------------------------------------------
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
  disable_root_ssh "$ip"
done
[[ ${#NODE_AUTH_FAILED[@]} -gt 0 ]] && \
  log_warn "Nodes pulados (auth falhou): ${NODE_AUTH_FAILED[*]}"
prompt_clear_creds
ROTX
chmod +x "${AUTO_DIR}/root_exec.sh"

# ---------------------------------------------------------------------------
# nsx_ssh_cli.sh
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# MANUAL.md
# ---------------------------------------------------------------------------
cat > "${DOCS_DIR}/MANUAL.md" <<'MANUALDOC'
# NSX Edge Automation — Manual de Uso  v3.8

## Correções v3.8

| Problema | Causa raiz | Correção |
|---|---|---|
| Bundle novo classificado como ANTIGO e deletado erroneamente | `_bundle_age_days()` fazia uma chamada SSH por arquivo; a 2ª+ chamada podia retornar string vazia → `age=999` | Nova `_list_bundles_with_age()`: **uma única chamada SSH** retorna `"NOME EPOCH"` para todos os bundles; idade calculada localmente |

## Correções v3.7

| Problema | Causa raiz | Correção |
|---|---|---|
| Falso positivo "geração em andamento" | `ps grep` usava padrão genérico que coincidia com o nome do próprio script | Novo `_BUNDLE_PROC_GREP`: `gen_support_bundle\|support_bundles/__self__\.py` — exclusivo do NSX |
| Linha `/etc/ssh/ssh_config: Unsupported option` aparecia nos boxes | Warnings do cliente SSH local capturados via `2>&1` | `-o LogLevel=ERROR` em `ssh_admin` e `ssh_root` |

## Como funciona a detecção de bundles (v3.8)

```bash
# Uma única chamada SSH por node:
cd /var/vmware/nsx/file-store
for f in $(ls -1 | grep -E '<_BUNDLE_GREP>'); do
  ep=$(stat -c '%Y' "$f")
  echo "$f $ep"
done
# Saída: "bundle-edge019.tgz 1648396800"
#        "sb_172_18_214_19_20260514_175712.tgz 1747267200"
# Idade calculada localmente: age=$(( (now - epoch) / 86400 ))
```

## Como identificar geração em andamento (NSX)

```bash
ps -ef | grep -E 'gen_support_bundle|support_bundles/__self__\.py' | grep -v grep
```

## Padrão de detecção de bundles (`_BUNDLE_GREP`)

| Nome do arquivo | Detectado? |
|---|---|
| `support-bundle-172-18-214-18-20260514.tgz` | ✔ |
| `support_bundle_20220216_0132.tgz` | ✔ |
| `sb_172_18_214_17_20260514_172052.tgz` | ✔ |
| `bundle-edge019.tgz` | ✔ |
| `2026-05-05-01h10am-utc-3.tgz` | ✔ |
| `qualquer-nome-manual.tgz` | ✔ |
| `flow-cache-dump-0.gz` | ✗ |

## Deploy

```bash
curl -fsSL https://raw.githubusercontent.com/leopoldocosta/nsx-edge-automation/main/automations/support_bundle/deploy_nsx_sb_check.sh | bash
```

## Uso

```bash
cd ~/nsx-edge-automation/automations/support_bundle
./test_connections.sh
./nsx_sb_main.sh
./nsx_sb_main.sh --clean-all
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
echo "  Deploy concluído! v3.8"
echo "================================================================"
echo ""
echo "  Correções v3.8:"
echo "    _list_bundles_with_age(): UMA chamada SSH por node para todos os bundles"
echo "    Idade calculada localmente — sem mais age=999 em bundles novos"
echo ""
echo "  Herdado v3.7:"
echo "    _BUNDLE_PROC_GREP preciso: gen_support_bundle|support_bundles/__self__.py"
echo "    LogLevel=ERROR em ssh_admin/ssh_root: sem warnings do cliente SSH local"
echo ""
echo "Próximos passos:"
echo "  1. cd ${AUTO_DIR} && ./test_connections.sh"
echo "  2. cd ${AUTO_DIR} && ./nsx_sb_main.sh"
echo "     ou: ./nsx_sb_main.sh --clean-all"
echo ""

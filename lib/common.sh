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
#       stat -c '%n %Y' /var/vmware/nsx/file-store/*.tgz
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
#   bundles, usando stat em glob. A idade é calculada localmente com
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

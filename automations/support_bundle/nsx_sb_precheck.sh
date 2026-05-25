#!/usr/bin/env bash
# nsx_sb_precheck.sh — v3.16
# Verifica o estado dos support bundles em todos os Edge Nodes
# sem disparar nova geracao. Exibe tabela com status, acao, arquivo e duracao.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips

# Carrega sessao existente se disponivel
SESSION_FILE="${RUN_DIR}/session.env"
if [[ -f "${SESSION_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${SESSION_FILE}"
  log "Admin credentials loaded from session file."
fi

[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds

log_banner "PRE-CHECK -- Estado dos Support Bundles"

# ---------------------------------------------------------------------------
# Descobre se --clean-all foi passado
# ---------------------------------------------------------------------------
CLEAN_ALL=false
if [[ "${1:-}" == "--clean-all" ]]; then
  CLEAN_ALL=true
  log "=== CLEAN-ALL: Apagando TODOS os bundles existentes ==="
fi

declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP PC_DURACAO
now_epoch=$(date +%s)

# ---------------------------------------------------------------------------
# bundle_duration — calcula duracao entre solicitacao (nome do arquivo) e
# criacao efetiva (mtime do arquivo no servidor).
# Entrada : $1=ip  $2=fname (ex: sb_172_18_214_19_20260518_163036.tgz)
# Saida   : string "Xh Ym Zs" ou "--" em caso de falha
# ---------------------------------------------------------------------------
bundle_duration(){
  local ip="$1" fname="$2"

  # 1) Extrai epoch do momento de solicitacao a partir do nome do arquivo
  local req_epoch=""
  if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.tgz$ ]]; then
    local yr="${BASH_REMATCH[1]}" mo="${BASH_REMATCH[2]}" dy="${BASH_REMATCH[3]}"
    local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}" ss="${BASH_REMATCH[6]}"
    req_epoch=$(date -d "${yr}-${mo}-${dy} ${hh}:${mm}:${ss}" +%s 2>/dev/null || echo "")
  fi
  [[ -z "$req_epoch" ]] && { printf '--'; return; }

  # 2) Coleta epoch de criacao (mtime) do arquivo via stat no servidor remoto
  local created_epoch=""
  created_epoch=$(root_cmd "$ip" \
    "stat -c '%Y' /var/vmware/nsx/file-store/${fname} 2>/dev/null" || echo "")
  [[ -z "$created_epoch" || ! "$created_epoch" =~ ^[0-9]+$ ]] && { printf '--'; return; }

  # 3) Calcula diferenca
  local diff=$(( created_epoch - req_epoch ))
  [[ $diff -lt 0 ]] && diff=0

  local horas=$(( diff / 3600 ))
  local minutos=$(( (diff % 3600) / 60 ))
  local segundos=$(( diff % 60 ))

  if [[ $horas -gt 0 ]]; then
    printf '%dh %02dm %02ds' "$horas" "$minutos" "$segundos"
  elif [[ $minutos -gt 0 ]]; then
    printf '%dm %02ds' "$minutos" "$segundos"
  else
    printf '%ds' "$segundos"
  fi
}

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"

  # Exibe ultima linha do log de geracao
  last_log="$(root_cmd "$ip" \
    "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"

  log "${ip}: [PRE-CHECK] verificando status do support bundle..."

  printf '\n  ┌─ %s: ls -lh /var/vmware/nsx/file-store/                    ─┐\n' "$ip"
  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  while IFS= read -r line; do printf '  │  %s\n' "$line"; done <<< "$ls_out"
  printf '  └────────────────────────────────────────────────────────────────────────┘\n\n'

  if echo "$last_log" | grep -qiE 'error|fail|unable|denied'; then
    log_warn "${ip}: ultima linha do log indica possivel erro."
  else
    log_ok   "${ip}: ultima linha do log sem erros aparentes."
  fi

  # --clean-all: remove TODOS os bundles
  if [[ "$CLEAN_ALL" == true ]]; then
    log "${ip}: buscando TODOS os bundles para limpeza total..."
    mapfile -t all_bundles < <(list_remote_bundles "$ip")
    log "${ip}: ${#all_bundles[@]} bundle(s) para deletar."
    for f in "${all_bundles[@]}"; do
      log ">> ${ip}: rm -f /var/vmware/nsx/file-store/${f}"
      root_cmd "$ip" "rm -f /var/vmware/nsx/file-store/${f}" || true
      log_warn "${ip}: deletado -- ${f}"
    done
    log_ok "${ip}: limpeza total concluida."
    disable_root_ssh "$ip"
    PC_STATUS["$ip"]="LIMPO"
    PC_ACAO["$ip"]="LIMPO"
    PC_FILE["$ip"]="--"
    PC_SKIP["$ip"]="false"
    PC_DURACAO["$ip"]="--"
    continue
  fi

  # Lista bundles
  raw_list="$(list_remote_bundles "$ip")"
  log "${ip}: [bundles detectados] resultado bruto: '${raw_list}'"

  local_recent=(); local_old=()
  total_count=0

  while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    (( total_count++ ))
    age_days=0
    if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{6}\.tgz$ ]]; then
      fyear="${BASH_REMATCH[1]}" fmon="${BASH_REMATCH[2]}" fday="${BASH_REMATCH[3]}"
      file_epoch=$(date -d "${fyear}-${fmon}-${fday}" +%s 2>/dev/null || echo "$now_epoch")
      age_days=$(( (now_epoch - file_epoch) / 86400 ))
    else
      age_days=999
    fi
    log "${ip}: arquivo '${fname}' -> ${age_days} dia(s)."
    if [[ $age_days -le 7 ]]; then
      local_recent+=("$fname")
    else
      local_old+=("$fname")
    fi
  done <<< "$raw_list"

  log "${ip}: ${total_count} bundle(s) encontrado(s)."

  printf '\n  +-- %s: %d recente(s) (<=7d) | %d antigo(s) (>7d) ---------+\n' \
    "$ip" "${#local_recent[@]}" "${#local_old[@]}"
  for f in "${local_recent[@]}"; do printf '  |  [OK]  %s\n' "$f"; done
  for f in "${local_old[@]}";   do printf '  |  [OLD] %s\n' "$f"; done
  printf '  +--------------------------------------------------------------+\n\n'

  if [[ ${#local_recent[@]} -gt 0 ]]; then
    newest="$(printf '%s\n' "${local_recent[@]}" | sort | tail -1)"
    file_date="$(bundle_file_date "${newest}")"
    status_label="${file_date:-RECENTE (<=7d)}"
    PC_STATUS["$ip"]="$status_label"
    PC_ACAO["$ip"]="OK"
    PC_FILE["$ip"]="${newest}"
    PC_SKIP["$ip"]="true"
    PC_DURACAO["$ip"]="$(bundle_duration "$ip" "$newest")"
    log_ok "${ip}: bundle recente presente -- geracao sera pulada."
    [[ ${#local_old[@]} -gt 0 ]] && log_warn "${ip}: bundle(s) antigo(s) presentes -- use --clean-all para remover."
  elif [[ $total_count -gt 0 ]]; then
    PC_STATUS["$ip"]="ANTIGO (>7d)"
    PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"
    PC_SKIP["$ip"]="false"
    PC_DURACAO["$ip"]="--"
    log_warn "${ip}: apenas bundle(s) antigo(s) -- sera gerado novo."
  else
    PC_STATUS["$ip"]="NENHUM"
    PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"
    PC_SKIP["$ip"]="false"
    PC_DURACAO["$ip"]="--"
    log "${ip}: nenhum bundle encontrado."
  fi

  disable_root_ssh "$ip"
done

# ---------------------------------------------------------------------------
# Tabela de resultado
# ---------------------------------------------------------------------------
precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,acao,arquivo,duracao' > "$precheck_csv"

tbl_header "PRE-CHECK -- Estado dos Support Bundles"
for ip in "${EDGE_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}" "${PC_DURACAO[$ip]:---}"
  printf '%s,%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}" "${PC_DURACAO[$ip]:---}" \
    >> "$precheck_csv"
done
tbl_footer

log_ok "Pre-check concluido. CSV: ${precheck_csv}"
printf '%s[%s]%s Para gerar bundles: ./nsx_sb_main.sh\n' \
  "${C_CYAN}" "$(date '+%F %T')" "${C_RESET}"
printf '%s[%s]%s Para limpar todos:  ./nsx_sb_precheck.sh --clean-all\n' \
  "${C_CYAN}" "$(date '+%F %T')" "${C_RESET}"

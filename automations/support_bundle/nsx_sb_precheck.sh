#!/usr/bin/env bash
# nsx_sb_precheck.sh — v3.15
# Verifica o estado dos support bundles em todos os Edge Nodes
# sem disparar nova geracao. Exibe tabela com status, acao e arquivo.
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

declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP
now_epoch=$(date +%s)

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"

  # Exibe ultima linha do log de geracao
  last_log="$(root_cmd "$ip" \
    "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
  printf '\n  +-- %s: /var/log/support_bundle.log (ultima linha) --------+\n' "$ip"
  printf '  |  %s\n' "$last_log"
  printf '  +--------------------------------------------------------------+\n\n'

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
    continue
  fi

  # ls completo para contexto
  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  printf '\n  +-- %s: ls -lh /var/vmware/nsx/file-store/ ----------------+\n' "$ip"
  while IFS= read -r line; do printf '  |  %s\n' "$line"; done <<< "$ls_out"
  printf '  +--------------------------------------------------------------+\n\n'

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
    log_ok "${ip}: bundle recente presente -- geracao sera pulada."
    [[ ${#local_old[@]} -gt 0 ]] && log_warn "${ip}: bundle(s) antigo(s) presentes -- use --clean-all para remover."
  elif [[ $total_count -gt 0 ]]; then
    PC_STATUS["$ip"]="ANTIGO (>7d)"
    PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"
    PC_SKIP["$ip"]="false"
    log_warn "${ip}: apenas bundle(s) antigo(s) -- sera gerado novo."
  else
    PC_STATUS["$ip"]="NENHUM"
    PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"
    PC_SKIP["$ip"]="false"
    log "${ip}: nenhum bundle encontrado."
  fi

  disable_root_ssh "$ip"
done

# ---------------------------------------------------------------------------
# Tabela de resultado
# ---------------------------------------------------------------------------
precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,acao,arquivo' > "$precheck_csv"

tbl_header "PRE-CHECK -- Estado dos Support Bundles"
for ip in "${EDGE_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}"
  printf '%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}" \
    >> "$precheck_csv"
done
tbl_footer

log_ok "Pre-check concluido. CSV: ${precheck_csv}"
printf '%s[%s]%s Para gerar bundles: ./nsx_sb_main.sh\n' \
  "${C_CYAN}" "$(date '+%F %T')" "${C_RESET}"
printf '%s[%s]%s Para limpar todos:  ./nsx_sb_precheck.sh --clean-all\n' \
  "${C_CYAN}" "$(date '+%F %T')" "${C_RESET}"

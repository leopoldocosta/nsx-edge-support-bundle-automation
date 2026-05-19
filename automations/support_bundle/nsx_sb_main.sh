#!/usr/bin/env bash
# nsx_sb_main.sh — v3.15
# Orquestrador: Fase 1 (solicita SB) + Fase 2 (verifica a cada 5 min)
# Recomendado: executar dentro de screen ou tmux (~35 min no total)
#
# Flags:
#   --clean-all   delega para nsx_sb_precheck.sh --clean-all e sai
#   --precheck    executa apenas o precheck e sai
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

# Delega flags especiais
if [[ "${1:-}" == "--clean-all" || "${1:-}" == "--precheck" ]]; then
  exec "${SCRIPT_DIR}/nsx_sb_precheck.sh" "${1}"
fi

need_cmd ssh
load_ips

SESSION_FILE="${RUN_DIR}/session.env"
if [[ -f "${SESSION_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${SESSION_FILE}"
  log "Admin credentials loaded from session file."
fi

[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

EXPIRY_EPOCH="$(( $(date +%s) + 1800 ))"

# Auto-limpa sessao apos 30 min
auto_clear_bg(){
  ( while [[ "$(date +%s)" -lt "$1" ]]; do sleep 5; done
    rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
  ) >/dev/null 2>&1 &
}
if [[ -n "${NSX_PASS:-}" ]]; then
  umask 077
  printf 'export NSX_USER=%q\nexport NSX_PASS=%q\nexport ROOT_PASS=%q\n' \
    "${NSX_USER}" "${NSX_PASS}" "${ROOT_PASS:-}" > "${SESSION_FILE}"
  auto_clear_bg "$EXPIRY_EPOCH"
fi

# ---------------------------------------------------------------------------
# PRE-CHECK inline (sem abrir root SSH duas vezes)
# ---------------------------------------------------------------------------
log_banner "PRE-CHECK -- Estado dos Support Bundles"

declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP
now_epoch=$(date +%s)

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"

  last_log="$(root_cmd "$ip" \
    "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
  printf '\n  +-- %s: /var/log/support_bundle.log (ultima linha) --------+\n' "$ip"
  printf '  |  %s\n' "$last_log"
  printf '  +--------------------------------------------------------------+\n\n'

  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  printf '\n  +-- %s: ls -lh /var/vmware/nsx/file-store/ ----------------+\n' "$ip"
  while IFS= read -r line; do printf '  |  %s\n' "$line"; done <<< "$ls_out"
  printf '  +--------------------------------------------------------------+\n\n'

  raw_list="$(list_remote_bundles "$ip")"
  log "${ip}: [bundles detectados]: '${raw_list}'"

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
    log "${ip}: '${fname}' -> ${age_days} dia(s)."
    if [[ $age_days -le 7 ]]; then local_recent+=("$fname")
    else local_old+=("$fname"); fi
  done <<< "$raw_list"

  log "${ip}: ${total_count} bundle(s) encontrado(s)."

  printf '\n  +-- %s: %d recente(s) | %d antigo(s) ----------------------+\n' \
    "$ip" "${#local_recent[@]}" "${#local_old[@]}"
  for f in "${local_recent[@]}"; do printf '  |  [OK]  %s\n' "$f"; done
  for f in "${local_old[@]}";   do printf '  |  [OLD] %s\n' "$f"; done
  printf '  +--------------------------------------------------------------+\n\n'

  if [[ ${#local_recent[@]} -gt 0 ]]; then
    newest="$(printf '%s\n' "${local_recent[@]}" | sort | tail -1)"
    file_date="$(bundle_file_date "${newest}")"
    PC_STATUS["$ip"]="${file_date:-RECENTE}"
    PC_ACAO["$ip"]="OK"
    PC_FILE["$ip"]="${newest}"
    PC_SKIP["$ip"]="true"
    log_ok "${ip}: bundle recente -- geracao sera pulada."
    [[ ${#local_old[@]} -gt 0 ]] && log_warn "${ip}: bundle(s) antigo(s) -- use --clean-all."
  elif [[ $total_count -gt 0 ]]; then
    PC_STATUS["$ip"]="ANTIGO (>7d)"; PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"
    log_warn "${ip}: apenas bundle(s) antigo(s) -- sera gerado novo."
  else
    PC_STATUS["$ip"]="NENHUM"; PC_ACAO["$ip"]="GERAR"
    PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"
    log "${ip}: nenhum bundle encontrado."
  fi
done

# Tabela pre-check
precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,acao,arquivo' > "$precheck_csv"
tbl_header "PRE-CHECK -- Estado dos Support Bundles"
for ip in "${EDGE_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}"
  printf '%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}" >> "$precheck_csv"
done
tbl_footer
log_ok "Pre-check concluido. CSV: ${precheck_csv}"

# ---------------------------------------------------------------------------
# FASE 1: Solicita Support Bundle nos nos que precisam
# ---------------------------------------------------------------------------
log_banner "FASE 1 -- Solicitacao do Support Bundle"
for ip in "${EDGE_IPS[@]}"; do
  if [[ "${PC_SKIP[$ip]:-false}" == "true" ]]; then
    log "${ip}: pulando -- bundle recente ja existe."
    continue
  fi
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Fase 1 concluida. Aguardando geracao dos bundles..."

# ---------------------------------------------------------------------------
# FASE 2: Verificacao a cada 5 min, ate 30 min (6 rounds)
# ---------------------------------------------------------------------------
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
      log_err  "${ip}: erro detectado -- encerrando verificacoes neste no."
      printf '%s,phase2,error,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok   "${ip}: bundle confirmado."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: ainda pendente..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done

# ---------------------------------------------------------------------------
# RELATORIO FINAL
# ---------------------------------------------------------------------------
log_banner "RELATORIO FINAL -- Support Bundle Check"
tbl_header "RELATORIO FINAL"
for ip in "${EDGE_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}"
done
tbl_footer

# FINAL: Desabilita root SSH em todos os nos
log_banner "FINAL -- Desabilitando root SSH"
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

clear_creds
rm -f "${SESSION_FILE}" 2>/dev/null || true
log_ok "Concluido. CSV de status: ${STATUS_CSV}"

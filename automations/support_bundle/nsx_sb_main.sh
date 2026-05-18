#!/usr/bin/env bash
# nsx_sb_main.sh  — v3.10
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds

CLEAN_ALL=false
[[ "${1:-}" == "--clean-all" ]] && CLEAN_ALL=true

# ---------------------------------------------------------------------------
# MENU: opções do support-bundle (timeout 10s → padrão automático)
# ---------------------------------------------------------------------------
ask_bundle_options

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

declare -a REPORT_LINES=()
# FIX v3.9 — array associativo para decisão de ação na PHASE 1.
declare -A NODE_ACAO=()

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
    NODE_ACAO[$ip]="PULADO"
    continue
  fi

  check_bundle_log "$ip" || true
  check_bundle_status "$ip"

  printf '%s,precheck,bundle_status,%s,%s\n' "$ip" "$BUNDLE_STATUS" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"

  case "$BUNDLE_STATUS" in
    recent)
      REPORT_LINES+=("${ip}|RECENTE (≤7d)|PULADO|${BUNDLE_FILES_RECENT}")
      NODE_ACAO[$ip]="PULADO"
      ;;
    old)
      delete_old_bundles "$ip"
      printf '%s,precheck,deleted_old,ok,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      REPORT_LINES+=("${ip}|ANTIGO (>7d)|DEL+GERANDO|${BUNDLE_FILES_OLD}")
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
log "Opções do bundle: get support-bundle file <nome>${SB_EXTRA:+ ${SB_EXTRA}} log-age ${SB_LOG_AGE}"

for ip in "${EDGE_IPS[@]}"; do
  if _node_auth_failed "$ip"; then
    log "${ip}: pulando (falha de autenticação admin)."
    continue
  fi

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

#!/usr/bin/env bash
# admin_exec.sh — Run any NSX-T admin CLI command on selected or all Edge Nodes
#
# FIX v3.14: Comandos bloqueantes (ex: get support-bundle) sao disparados
# em background com disown, evitando que o script fique preso aguardando.
# O output e capturado em arquivo de log em logs/admin_exec_<ip>_<ts>.log.
# Para comandos nao bloqueantes, o output continua sendo exibido inline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips
[[ -f "${ADMIN_KEY}" ]] || ask_admin_creds

echo ""
echo "Edge Nodes:"
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] All nodes"
echo ""
read -rp 'Select node (number or A): ' SEL
read -rp 'NSX-T admin CLI command: '   CMD
echo ""

# Detecta se o comando e bloqueante (ex: get support-bundle)
# Comandos bloqueantes sao executados em background com log em arquivo.
_is_blocking_cmd(){
  local cmd="${1,,}"
  [[ "$cmd" =~ get[[:space:]]+support-bundle ]] || \
  [[ "$cmd" =~ start[[:space:]]+support-bundle ]]
}

run_inline(){
  local ip="$1"
  echo "===== admin@${ip} ====="
  admin_cmd "$ip" "$CMD" || true
  echo
}

run_background(){
  local ip="$1"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local logfile="${LOG_DIR}/admin_exec_${ip//./_}_${ts}.log"
  echo "===== admin@${ip} [BACKGROUND] ====="
  log "${ip}: comando bloqueante detectado — disparando em background."
  log "${ip}: output em: ${logfile}"
  (
    admin_cmd "$ip" "$CMD" >> "${logfile}" 2>&1
    echo "[$(date '+%F %T')] [OK] Comando concluido: ${CMD}" >> "${logfile}"
  ) &
  disown $!
  log_ok "${ip}: processo iniciado (PID $!). Acompanhe com: tail -f ${logfile}"
  echo
}

run(){
  local ip="$1"
  if _is_blocking_cmd "$CMD"; then
    run_background "$ip"
  else
    run_inline "$ip"
  fi
}

if   [[ "${SEL^^}" == "A" ]]; then
  for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then
  run "${EDGE_IPS[$((SEL-1))]}"
else
  echo "[ERROR] Invalid selection."; exit 1
fi

clear_creds

#!/usr/bin/env bash
# root_exec.sh — v3.16.6
# Run any Linux root command on selected or all Edge Nodes.
# Enables root SSH before execution, disables after.
#
# FIX v3.16.6: Comandos bloqueantes (ex: get support-bundle, tar, rsync)
# sao disparados em background com disown, evitando que o script fique preso.
# Output capturado em logs/root_exec_<ip>_<ts>.log.
# ROOT_PASS e solicitada uma unica vez e reusada para todos os nodes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips
[[ -f "${ADMIN_KEY}" ]] || [[ -f "${ROOT_KEY}" ]] || ask_admin_creds

echo ""
echo "Edge Nodes:"
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] All nodes"
echo ""
read -rp 'Select node (number or A): ' SEL
read -rp 'Linux root command: '         CMD
read -rp '[WARNING] Confirm root execution in production? [y/N]: ' CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Cancelled."; exit 0; }

# Detecta comandos de longa duracao que nao devolvem prompt
_is_blocking_cmd(){
  local cmd="${1,,}"
  [[ "$cmd" =~ get[[:space:]]+support-bundle ]] || \
  [[ "$cmd" =~ start[[:space:]]+support-bundle ]] || \
  [[ "$cmd" =~ ^tar[[:space:]] ]] || \
  [[ "$cmd" =~ ^rsync[[:space:]] ]]
}

run(){
  local ip="$1"
  echo "===== root@${ip} ====="
  enable_root_ssh "$ip"; sleep 2

  # Solicita ROOT_PASS uma unica vez para todos os nodes
  if [[ ! -f "${ROOT_KEY}" ]] && [[ -z "${ROOT_PASS:-}" ]]; then
    ask_root_creds
  fi

  if _is_blocking_cmd "$CMD"; then
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    local logfile="${LOG_DIR}/root_exec_${ip//./_}_${ts}.log"
    log "${ip}: comando bloqueante detectado — disparando em background."
    log "${ip}: output em: ${logfile}"
    (
      root_cmd "$ip" "$CMD" >> "${logfile}" 2>&1
      echo "[$(date '+%F %T')] [OK] Comando concluido: ${CMD}" >> "${logfile}"
    ) &
    disown $!
    log_ok "${ip}: processo iniciado (PID $!). Acompanhe com: tail -f ${logfile}"
  else
    root_cmd "$ip" "$CMD" || true
  fi

  disable_root_ssh "$ip"
  echo
}

if   [[ "${SEL^^}" == "A" ]]; then
  for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then
  run "${EDGE_IPS[$((SEL-1))]}"
else
  echo "[ERROR] Invalid selection."; exit 1
fi

clear_creds

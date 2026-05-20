#!/usr/bin/env bash
# automations/kb404700_disk_validation/kb404700_disk_validation.sh — v1.7
# KB404700 — NSX Edge Node: Root Partition & Docker overlay2 Disk Validation
#
# Flow per node:
#   1. Admin login  → get uptime + version
#   2. Admin        → enable root SSH
#   3. Root login   → hostname
#   4. Root login   → df -h  (root partition by mount point '/')
#   5. Root login   → du -xah --time --max-depth=3 /var/lib/docker/
#   6. Admin        → disable root SSH
#   7. Final report: per-node detail + ACTION REQUIRED summary table
#
# IP LIST PERSISTENCE (v1.7):
#   - If edge_nodes exists alongside the script → loaded automatically, no prompt.
#   - If edge_nodes does NOT exist → interactive prompt runs and the result
#     is saved to edge_nodes for all future runs.
#   - To change the list: edit edge_nodes directly, or delete it to re-prompt.
#
# FIX v1.4: exec > >(tee) started AFTER all interactive prompts.
# All read calls use </dev/tty explicitly.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

# EDGE_FILE is already defined by common.sh as ${AUTO_DIR}/edge_nodes
# (same directory as this script, so it resolves correctly)

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
need_cmd ssh
need_cmd sshpass
need_cmd awk
need_cmd sort
need_cmd grep

# ---------------------------------------------------------------------------
# Associative arrays
# ---------------------------------------------------------------------------
declare -A NODE_UPTIME
declare -A NODE_UPTIME_DAYS
declare -A NODE_VERSION
declare -A NODE_VERSION_SHORT
declare -A NODE_ROOT_DEVICE
declare -A NODE_ROOT_PART_LINE
declare -A NODE_ROOT_PART_SIZE
declare -A NODE_ROOT_PART_USED
declare -A NODE_ROOT_PART_AVAIL
declare -A NODE_ROOT_PART_PCT
declare -A NODE_ROOT_PART_STATUS     # OK | FULL | NOT_FOUND
declare -A NODE_OVERLAY2_LINE
declare -A NODE_OVERLAY2_SIZE
declare -A NODE_OVERLAY2_STATUS      # OK | HIGH | N/A
declare -A NODE_DOCKER_TOTAL_LINE
declare -A NODE_DOCKER_TOTAL
declare -A NODE_ERROR
declare -A NODE_HOSTNAME

# ---------------------------------------------------------------------------
# collect_ips_interactive
# Called only when edge_nodes does not exist.
# Saves the result to edge_nodes so the next run skips the prompt entirely.
# ---------------------------------------------------------------------------
collect_ips_interactive(){
  printf '\nNo edge_nodes file found.\n' >/dev/tty
  printf 'Enter Edge Node IPs, one per line. Empty line to finish:\n' >/dev/tty
  : > "${EDGE_FILE}"
  while IFS= read -rp '  IP: ' line </dev/tty; do
    [[ -z "${line}" ]] && break
    if [[ "${line}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "${line}" >> "${EDGE_FILE}"
      log "Added: ${line}"
    else
      log_warn "Skipping invalid entry: ${line}"
    fi
  done
  local count
  count=$(wc -l < "${EDGE_FILE}" | tr -d ' ')
  if [[ "${count}" -eq 0 ]]; then
    log_err "No valid IPs provided. Aborting."
    exit 1
  fi
  log "${count} IP(s) saved to: ${EDGE_FILE}"
  printf '  (IPs saved — next run will load this file automatically)\n' >/dev/tty
}

# ---------------------------------------------------------------------------
# load_or_prompt_ips
# If edge_nodes exists: load it silently.
# If not: run interactive collection and save.
# ---------------------------------------------------------------------------
load_or_prompt_ips(){
  if [[ -f "${EDGE_FILE}" && -s "${EDGE_FILE}" ]]; then
    log "IP list loaded from: ${EDGE_FILE}"
    log "  (delete or edit the file to change the list)"
  else
    collect_ips_interactive
  fi
  load_ips
}

# ---------------------------------------------------------------------------
# Credential overrides bound to /dev/tty
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already in environment (user: '${NSX_USER:-admin}')."
    return 0
  fi
  IFS= read -rp 'Admin username [admin]: ' NSX_USER </dev/tty
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp 'Admin password: ' NSX_PASS </dev/tty; printf '\n' >/dev/tty
  export NSX_USER NSX_PASS
  log "Admin credentials collected for user '${NSX_USER}'."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already in environment."
    return 0
  fi
  IFS= read -rsp 'Root password: ' ROOT_PASS </dev/tty; printf '\n' >/dev/tty
  export ROOT_PASS
  log "Root credentials collected."
}

# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------
parse_uptime_days(){
  local raw="$1"
  local days
  days="$(echo "${raw}" | grep -oP '(?<=up )\d+(?= day)' || true)"
  echo "${days:-N/A}"
}

parse_version_short(){
  local raw="$1"
  local ver
  ver="$(echo "${raw}" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)"
  echo "${ver:-N/A}"
}

# ---------------------------------------------------------------------------
# collect_node_info IP
# ---------------------------------------------------------------------------
collect_node_info(){
  local ip="$1"
  NODE_ERROR["${ip}"]=""

  log "${ip}: collecting uptime and version via admin..."
  local raw_uptime raw_version
  raw_uptime="$(admin_cmd "${ip}" 'get uptime'  2>/dev/null || true)"
  raw_version="$(admin_cmd "${ip}" 'get version' 2>/dev/null || true)"

  NODE_UPTIME["${ip}"]="$(echo "${raw_uptime}"  | grep -v '^$' | head -1 | xargs)"
  NODE_VERSION["${ip}"]="$(echo "${raw_version}" | grep -v '^$' | head -1 | xargs)"

  if [[ -z "${NODE_UPTIME[${ip}]}" && -z "${NODE_VERSION[${ip}]}" ]]; then
    NODE_ERROR["${ip}"]="Admin SSH failed — node unreachable or bad credentials."
    log_warn "${ip}: admin SSH failed, skipping node."
    return 1
  fi

  NODE_UPTIME_DAYS["${ip}"]="$(parse_uptime_days  "${NODE_UPTIME[${ip}]}")"
  NODE_VERSION_SHORT["${ip}"]="$(parse_version_short "${NODE_VERSION[${ip}]}")"

  log_ok "${ip}: [uptime]   >> ${NODE_UPTIME[${ip}]}"
  log_ok "${ip}: [version]  >> ${NODE_VERSION[${ip}]}"

  enable_root_ssh "${ip}"
  sleep 2

  local raw_hostname
  raw_hostname="$(root_cmd "${ip}" 'hostname' 2>/dev/null || true)"
  NODE_HOSTNAME["${ip}"]="$(echo "${raw_hostname}" | grep -v '^$' | head -1 | xargs)"
  NODE_HOSTNAME["${ip}"]="${NODE_HOSTNAME[${ip}]:-${ip}}"

  log "${ip}: running 'df -h' via root..."
  local df_output root_line
  df_output="$(root_cmd "${ip}" 'df -h' 2>/dev/null || true)"

  if [[ -z "${df_output}" ]]; then
    NODE_ERROR["${ip}"]="Root SSH failed on df -h — check root login or password."
    log_warn "${ip}: root SSH failed."
    disable_root_ssh "${ip}" || true
    return 1
  fi

  log "${ip}: [df header] >> $(echo "${df_output}" | head -1)"

  root_line="$(echo "${df_output}" | awk '
    NF >= 6 && $NF == "/" { print; next }
    /^\/[^ ]/ && NF < 6   { prev=$0; next }
    NF == 1 && $1 == "/" && prev != "" { print prev " " $1; prev=""; next }
  ' | head -1)"

  NODE_ROOT_PART_LINE["${ip}"]="${root_line}"
  NODE_ROOT_DEVICE["${ip}"]="$(echo "${root_line}" | awk '{print $1}')"

  if [[ -n "${root_line}" ]]; then
    NODE_ROOT_PART_SIZE["${ip}"]="$(  echo "${root_line}" | awk '{print $2}')"
    NODE_ROOT_PART_USED["${ip}"]="$(  echo "${root_line}" | awk '{print $3}')"
    NODE_ROOT_PART_AVAIL["${ip}"]="$( echo "${root_line}" | awk '{print $4}')"
    NODE_ROOT_PART_PCT["${ip}"]="$(   echo "${root_line}" | awk '{print $5}')"
    local pct_val
    pct_val="$(echo "${NODE_ROOT_PART_PCT[${ip}]}" | tr -d '%')"
    if [[ "${pct_val}" -ge 100 ]]; then
      NODE_ROOT_PART_STATUS["${ip}"]="FULL"
      log_warn "${ip}: [df /] >> ${root_line}  <-- ROOT PARTITION FULL!"
    else
      NODE_ROOT_PART_STATUS["${ip}"]="OK"
      log_ok  "${ip}: [df /] >> ${root_line}"
    fi
  else
    NODE_ROOT_PART_SIZE["${ip}"]="N/A"
    NODE_ROOT_PART_USED["${ip}"]="N/A"
    NODE_ROOT_PART_AVAIL["${ip}"]="N/A"
    NODE_ROOT_PART_PCT["${ip}"]="N/A"
    NODE_ROOT_PART_STATUS["${ip}"]="NOT_FOUND"
    NODE_ROOT_PART_LINE["${ip}"]="(not found)"
    NODE_ROOT_DEVICE["${ip}"]="unknown"
    log_warn "${ip}: root partition (mount '/') not found in df output."
  fi

  log "${ip}: running 'du -xah --time --max-depth=3 /var/lib/docker/' via root..."
  local du_output docker_total_line overlay2_line
  du_output="$(root_cmd "${ip}" \
    'du -xah --time --max-depth=3 /var/lib/docker/ 2>/dev/null | sort | grep G' \
    2>/dev/null || true)"

  docker_total_line="$( echo "${du_output}" | awk '$NF=="/var/lib/docker"'         | tail -1)"
  overlay2_line="$(     echo "${du_output}" | awk '$NF=="/var/lib/docker/overlay2"' | tail -1)"

  NODE_DOCKER_TOTAL_LINE["${ip}"]="${docker_total_line:-(not found)}"
  NODE_OVERLAY2_LINE["${ip}"]="${overlay2_line:-(not found)}"
  NODE_DOCKER_TOTAL["${ip}"]="${NODE_DOCKER_TOTAL[${ip}]:-N/A}"

  local overlay2_size
  overlay2_size="$(echo "${overlay2_line}" | awk '{print $1}')"
  NODE_OVERLAY2_SIZE["${ip}"]="${overlay2_size:-N/A}"

  log_ok "${ip}: [du /var/lib/docker]  >> ${NODE_DOCKER_TOTAL_LINE[${ip}]}"

  if [[ -n "${overlay2_size}" ]]; then
    local overlay_num
    overlay_num="$(echo "${overlay2_size}" | tr -d 'G')"
    if awk "BEGIN{exit !(${overlay_num}+0 >= 10)}"; then
      NODE_OVERLAY2_STATUS["${ip}"]="HIGH"
      log_warn "${ip}: [du overlay2] >> ${overlay2_line}  <-- overlay2 CAUSING ROOT FULL!"
    else
      NODE_OVERLAY2_STATUS["${ip}"]="OK"
      log_ok  "${ip}: [du overlay2] >> ${overlay2_line}"
    fi
  else
    NODE_OVERLAY2_STATUS["${ip}"]="N/A"
    log_warn "${ip}: could not determine overlay2 size (no G-sized entries)."
  fi

  disable_root_ssh "${ip}" || true
  log_ok "${ip}: data collection complete."
}

# ---------------------------------------------------------------------------
# print_report
# ---------------------------------------------------------------------------
print_report(){
  local sep thin_sep
  sep="$(printf '=%.0s' {1..96})"
  thin_sep="$(printf -- '-%.0s' {1..96})"

  local action_nodes=()

  {
    echo ""
    echo "${sep}"
    printf '  KB404700 — NSX Edge Disk Validation Report\n'
    printf '  Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${sep}"
    echo ""

    for ip in "${EDGE_IPS[@]}"; do
      echo "  NODE: ${ip}"
      echo "  ${thin_sep:2}"

      if [[ -n "${NODE_ERROR[${ip}]:-}" ]]; then
        printf '  %-22s %s\n' "Status:" "ERROR"
        printf '  %-22s %s\n' "Reason:" "${NODE_ERROR[${ip}]}"
        echo ""
        continue
      fi

      printf '  %-22s %s\n' "Hostname:" "${NODE_HOSTNAME[${ip}]:-N/A}"
      printf '  %-22s %s\n' "Uptime:"   "${NODE_UPTIME[${ip}]:-N/A}"
      printf '  %-22s %s\n' "Version:"  "${NODE_VERSION[${ip}]:-N/A}"
      echo ""

      local root_status="${NODE_ROOT_PART_STATUS[${ip}]:-N/A}"
      local root_flag=""
      [[ "${root_status}" == "FULL"      ]] && root_flag="  <-- *** ROOT PARTITION FULL ***"
      [[ "${root_status}" == "NOT_FOUND" ]] && root_flag="  <-- root partition not found"

      printf '  %-22s %s\n' "Root device:" "${NODE_ROOT_DEVICE[${ip}]:-unknown}"
      printf '  %-22s\n'    "df -h output:"
      printf '    Filesystem  Size  Used  Avail  Use%%  Mounted on\n'
      printf '    %s%s\n'   "${NODE_ROOT_PART_LINE[${ip}]:-N/A}" "${root_flag}"
      echo ""

      local ov_status="${NODE_OVERLAY2_STATUS[${ip}]:-N/A}"
      local ov_flag=""
      [[ "${ov_status}" == "HIGH" ]] && ov_flag="  <-- *** overlay2 CAUSING ROOT FULL ***"

      printf '  %-22s\n'  "du /var/lib/docker/:"
      printf '    %s\n'   "${NODE_DOCKER_TOTAL_LINE[${ip}]:-N/A}"
      printf '    %s%s\n' "${NODE_OVERLAY2_LINE[${ip}]:-N/A}" "${ov_flag}"
      echo ""

      local verdict="OK"
      if [[ "${root_status}" == "FULL" || "${ov_status}" == "HIGH" ]]; then
        verdict="ACTION REQUIRED"
        action_nodes+=("${ip}")
      fi
      printf '  %-22s %s\n' "VERDICT:" "${verdict}"
      echo ""
      echo "  ${thin_sep:2}"
      echo ""
    done

    echo "${sep}"
    printf '  NODES REQUIRING ACTION\n'
    echo "${sep}"
    echo ""
    if [[ ${#action_nodes[@]} -eq 0 ]]; then
      printf '  All nodes are OK. No action required.\n'
    else
      printf '  %-4s  %-26s  %-17s  %-10s  %-13s  %-7s  %s\n' \
        "#" "Hostname" "IP" "Uptime(d)" "Version" "Root%" "overlay2"
      printf '  %-4s  %-26s  %-17s  %-10s  %-13s  %-7s  %s\n' \
        "----" "--------------------------" "-----------------" "----------" "-------------" "-------" "--------"
      local idx=1
      for aip in "${action_nodes[@]}"; do
        printf '  %-4s  %-26s  %-17s  %-10s  %-13s  %-7s  %s\n' \
          "${idx}." \
          "${NODE_HOSTNAME[${aip}]:-N/A}" \
          "${aip}" \
          "${NODE_UPTIME_DAYS[${aip}]:-N/A}" \
          "${NODE_VERSION_SHORT[${aip}]:-N/A}" \
          "${NODE_ROOT_PART_PCT[${aip}]:-N/A}" \
          "${NODE_OVERLAY2_SIZE[${aip}]:-N/A}"
        (( idx++ ))
      done
    fi
    echo ""
    echo "${sep}"
    echo "  END OF REPORT"
    echo "${sep}"
    echo ""
  } | tee "${REPORT_FILE}"

  log "Report saved to: ${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main(){
  load_or_prompt_ips   # loads edge_nodes silently, or prompts+saves if missing
  ask_admin_creds
  ask_root_creds

  REPORT_FILE="${LOG_DIR}/kb404700_report_$(date '+%Y%m%d_%H%M%S').txt"
  LOG_FILE="${LOG_DIR}/kb404700_run_$(date '+%Y%m%d_%H%M%S').log"
  exec > >(tee -a "${LOG_FILE}") 2>&1

  log "=== KB404700 Disk Validation — START ==="
  log "Loaded ${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"

  local failed_nodes=()
  for ip in "${EDGE_IPS[@]}"; do
    log "--- Processing node: ${ip} ---"
    if ! collect_node_info "${ip}"; then
      failed_nodes+=("${ip}")
    fi
  done

  [[ ${#failed_nodes[@]} -gt 0 ]] && log_warn "Nodes with errors: ${failed_nodes[*]}"

  print_report
  clear_creds
  log "=== KB404700 Disk Validation — DONE ==="
}

main "$@"

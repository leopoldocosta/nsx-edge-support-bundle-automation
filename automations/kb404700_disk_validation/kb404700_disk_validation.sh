#!/usr/bin/env bash
# automations/kb404700_disk_validation/kb404700_disk_validation.sh
# KB404700 — NSX Edge Node: Root Partition & Docker overlay2 Disk Validation
#
# Flow per node:
#   1. Admin login  → get uptime + version
#   2. Admin        → enable root SSH
#   3. Root login   → df -h  (check /dev/sda2 at 100%)
#   4. Root login   → du -xah --time --max-depth=3 /var/lib/docker/ (check overlay2 size)
#   5. Admin        → disable root SSH
#   6. Final report with per-node summary
#
# Usage:
#   cd automations/kb404700_disk_validation
#   bash kb404700_disk_validation.sh
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPORT_FILE="${LOG_DIR}/kb404700_report_$(date '+%Y%m%d_%H%M%S').txt"
LOG_FILE="${LOG_DIR}/kb404700_run_$(date '+%Y%m%d_%H%M%S').log"

# Tee stdout+stderr to log file
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
need_cmd ssh
need_cmd sshpass
need_cmd awk
need_cmd sort
need_cmd grep

# ---------------------------------------------------------------------------
# Associative arrays for per-node results
# ---------------------------------------------------------------------------
declare -A NODE_UPTIME
declare -A NODE_VERSION
declare -A NODE_ROOT_PART_SIZE
declare -A NODE_ROOT_PART_USED
declare -A NODE_ROOT_PART_AVAIL
declare -A NODE_ROOT_PART_PCT
declare -A NODE_ROOT_PART_STATUS   # OK | FULL
declare -A NODE_OVERLAY2_SIZE
declare -A NODE_OVERLAY2_STATUS    # OK | HIGH
declare -A NODE_DOCKER_TOTAL
declare -A NODE_ERROR

# ---------------------------------------------------------------------------
# collect_node_info IP
# ---------------------------------------------------------------------------
collect_node_info(){
  local ip="$1"
  NODE_ERROR["${ip}"]=""

  # --- 1. Admin: uptime + version ----------------------------------------
  log "${ip}: collecting uptime and version via admin..."
  local raw_uptime raw_version
  raw_uptime="$(admin_cmd "${ip}" 'get uptime' 2>/dev/null || true)"
  raw_version="$(admin_cmd "${ip}" 'get version' 2>/dev/null || true)"

  NODE_UPTIME["${ip}"]="$(echo "${raw_uptime}"  | head -1 | xargs)"
  NODE_VERSION["${ip}"]="$(echo "${raw_version}" | head -1 | xargs)"

  if [[ -z "${NODE_UPTIME[${ip}]}" && -z "${NODE_VERSION[${ip}]}" ]]; then
    NODE_ERROR["${ip}"]="Admin SSH failed — node unreachable or bad credentials."
    log_warn "${ip}: admin SSH failed, skipping node."
    return 1
  fi
  log_ok "${ip}: uptime='${NODE_UPTIME[${ip}]}' | version='${NODE_VERSION[${ip}]}'"

  # --- 2. Admin: enable root SSH ------------------------------------------
  enable_root_ssh "${ip}"
  sleep 2

  # --- 3. Root: df -h ------------------------------------------------------
  log "${ip}: running df -h via root..."
  local df_output
  df_output="$(root_cmd "${ip}" 'df -h' 2>/dev/null || true)"

  if [[ -z "${df_output}" ]]; then
    NODE_ERROR["${ip}"]="Root SSH failed on df -h — check root login or password."
    log_warn "${ip}: root SSH failed."
    disable_root_ssh "${ip}" || true
    return 1
  fi

  # Parse /dev/sda2 line
  local sda2_line
  sda2_line="$(echo "${df_output}" | awk '$1=="/dev/sda2"')"

  if [[ -n "${sda2_line}" ]]; then
    NODE_ROOT_PART_SIZE["${ip}"]="$(  echo "${sda2_line}" | awk '{print $2}')"
    NODE_ROOT_PART_USED["${ip}"]="$(  echo "${sda2_line}" | awk '{print $3}')"
    NODE_ROOT_PART_AVAIL["${ip}"]="$( echo "${sda2_line}" | awk '{print $4}')"
    NODE_ROOT_PART_PCT["${ip}"]="$(   echo "${sda2_line}" | awk '{print $5}')"
    local pct_val
    pct_val="$(echo "${NODE_ROOT_PART_PCT[${ip}]}" | tr -d '%')"
    if [[ "${pct_val}" -ge 100 ]]; then
      NODE_ROOT_PART_STATUS["${ip}"]="FULL"
      log_warn "${ip}: /dev/sda2 is at ${NODE_ROOT_PART_PCT[${ip}]} — ROOT PARTITION FULL!"
    else
      NODE_ROOT_PART_STATUS["${ip}"]="OK"
      log_ok "${ip}: /dev/sda2 at ${NODE_ROOT_PART_PCT[${ip}]} — OK."
    fi
  else
    NODE_ROOT_PART_SIZE["${ip}"]="N/A"
    NODE_ROOT_PART_USED["${ip}"]="N/A"
    NODE_ROOT_PART_AVAIL["${ip}"]="N/A"
    NODE_ROOT_PART_PCT["${ip}"]="N/A"
    NODE_ROOT_PART_STATUS["${ip}"]="NOT_FOUND"
    log_warn "${ip}: /dev/sda2 not found in df output."
  fi

  # --- 4. Root: du /var/lib/docker/ ----------------------------------------
  log "${ip}: running du on /var/lib/docker/ via root (may take a while)..."
  local du_output
  du_output="$(root_cmd "${ip}" \
    'du -xah --time --max-depth=3 /var/lib/docker/ 2>/dev/null | sort | grep G' \
    2>/dev/null || true)"

  # Extract /var/lib/docker total (exact path match)
  local docker_total overlay2_size
  docker_total="$( echo "${du_output}" | awk '$NF=="/var/lib/docker"      {print $1}' | tail -1)"
  overlay2_size="$(echo "${du_output}" | awk '$NF=="/var/lib/docker/overlay2" {print $1}' | tail -1)"

  NODE_DOCKER_TOTAL["${ip}"]="${docker_total:-N/A}"
  NODE_OVERLAY2_SIZE["${ip}"]="${overlay2_size:-N/A}"

  if [[ -n "${overlay2_size}" && "${overlay2_size}" != "N/A" ]]; then
    local overlay_num
    overlay_num="$(echo "${overlay2_size}" | tr -d 'G')"
    if awk "BEGIN{exit !(${overlay_num}+0 >= 10)}"; then
      NODE_OVERLAY2_STATUS["${ip}"]="HIGH"
      log_warn "${ip}: /var/lib/docker/overlay2 = ${overlay2_size} — HIGH DISK USAGE!"
    else
      NODE_OVERLAY2_STATUS["${ip}"]="OK"
      log_ok "${ip}: /var/lib/docker/overlay2 = ${overlay2_size} — OK."
    fi
  else
    NODE_OVERLAY2_STATUS["${ip}"]="N/A"
    log_warn "${ip}: could not determine /var/lib/docker/overlay2 size (no G-sized entries)."
  fi

  # --- 5. Admin: disable root SSH -----------------------------------------
  disable_root_ssh "${ip}" || true
  log_ok "${ip}: data collection complete."
}

# ---------------------------------------------------------------------------
# print_report
# ---------------------------------------------------------------------------
print_report(){
  local sep
  sep="$(printf '=%.0s' {1..80})"
  local thin_sep
  thin_sep="$(printf -- '-%.0s' {1..80})"

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
        printf '  %-20s %s\n' "Status:" "ERROR"
        printf '  %-20s %s\n' "Reason:" "${NODE_ERROR[${ip}]}"
        echo ""
        continue
      fi

      printf '  %-20s %s\n' "Uptime:"  "${NODE_UPTIME[${ip}]:-N/A}"
      printf '  %-20s %s\n' "Version:" "${NODE_VERSION[${ip}]:-N/A}"
      echo ""

      # Root partition
      local root_status="${NODE_ROOT_PART_STATUS[${ip}]:-N/A}"
      local root_flag=""
      [[ "${root_status}" == "FULL" ]]     && root_flag=" <-- *** ROOT PARTITION FULL ***"
      [[ "${root_status}" == "NOT_FOUND" ]] && root_flag=" <-- /dev/sda2 not found"

      printf '  %-20s %s\n'   "Partition:"    "/dev/sda2"
      printf '  %-20s %s\n'   "  Size:"       "${NODE_ROOT_PART_SIZE[${ip}]:-N/A}"
      printf '  %-20s %s\n'   "  Used:"       "${NODE_ROOT_PART_USED[${ip}]:-N/A}"
      printf '  %-20s %s\n'   "  Avail:"      "${NODE_ROOT_PART_AVAIL[${ip}]:-N/A}"
      printf '  %-20s %s%s\n' "  Use%%:"       "${NODE_ROOT_PART_PCT[${ip}]:-N/A}" "${root_flag}"
      echo ""

      # Docker overlay2
      local ov_status="${NODE_OVERLAY2_STATUS[${ip}]:-N/A}"
      local ov_flag=""
      [[ "${ov_status}" == "HIGH" ]] && ov_flag=" <-- *** overlay2 CAUSING ROOT FULL ***"

      printf '  %-20s %s\n'   "Docker total:"   "${NODE_DOCKER_TOTAL[${ip}]:-N/A}"
      printf '  %-20s %s%s\n' "overlay2 size:"  "${NODE_OVERLAY2_SIZE[${ip}]:-N/A}" "${ov_flag}"

      echo ""
      # Verdict
      local verdict="OK"
      if [[ "${root_status}" == "FULL" || "${ov_status}" == "HIGH" ]]; then
        verdict="ACTION REQUIRED"
      fi
      printf '  %-20s %s\n' "VERDICT:" "${verdict}"
      echo ""
      echo "  ${thin_sep:2}"
      echo ""
    done

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
  log "=== KB404700 Disk Validation — START ==="

  load_ips
  ask_admin_creds
  ask_root_creds

  local failed_nodes=()
  for ip in "${EDGE_IPS[@]}"; do
    log "--- Processing node: ${ip} ---"
    if ! collect_node_info "${ip}"; then
      failed_nodes+=("${ip}")
    fi
  done

  if [[ ${#failed_nodes[@]} -gt 0 ]]; then
    log_warn "The following nodes had errors: ${failed_nodes[*]}"
  fi

  print_report

  clear_creds
  log "=== KB404700 Disk Validation — DONE ==="
}

main "$@"

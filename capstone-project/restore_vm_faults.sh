#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/tmp/vm-fault-injection"
PID_FILE="${STATE_DIR}/fault_pids.list"
NET_IFACE_FILE="${STATE_DIR}/net_iface"
DISK_FILE_PATH_FILE="${STATE_DIR}/disk_io_target"
VALIDATION_MARKER="${STATE_DIR}/restore_validated.ok"
RESTORE_LOG="/var/log/vm-fault-restore.log"
STOP_FAILURES=0
LAST_NET_IFACE=""

mkdir -p "${STATE_DIR}"
touch "${RESTORE_LOG}"

log() {
  local level="$1"
  local msg="$2"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${msg}" | tee -a "${RESTORE_LOG}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
  fi
}

kill_managed_pid() {
  local pid="$1"
  local label="$2"

  if [[ -z "${pid}" ]]; then
    return 0
  fi

  if kill -0 "${pid}" >/dev/null 2>&1; then
    log "INFO" "Stopping ${label} process PID=${pid}"
    kill "${pid}" >/dev/null 2>&1 || true
    sleep 1
    if kill -0 "${pid}" >/dev/null 2>&1; then
      log "WARN" "PID=${pid} still running, sending SIGKILL"
      kill -9 "${pid}" >/dev/null 2>&1 || true
      sleep 1
      if kill -0 "${pid}" >/dev/null 2>&1; then
        log "ERROR" "Failed to stop PID=${pid} (${label})"
        STOP_FAILURES=$((STOP_FAILURES + 1))
      fi
    fi
  else
    log "INFO" "PID=${pid} (${label}) already stopped"
  fi
}

stop_injected_faults() {
  log "INFO" "Stopping managed fault processes"

  if [[ -f "${PID_FILE}" ]]; then
    while IFS=':' read -r pid label; do
      [[ -z "${pid}" ]] && continue
      kill_managed_pid "${pid}" "${label:-unknown}"
    done < "${PID_FILE}"
    rm -f "${PID_FILE}"
  else
    log "INFO" "No PID file found; nothing to stop"
  fi
}

cleanup_disk_artifacts() {
  if [[ -f "${DISK_FILE_PATH_FILE}" ]]; then
    local disk_target
    disk_target="$(cat "${DISK_FILE_PATH_FILE}")"
    if [[ -n "${disk_target}" && -f "${disk_target}" ]]; then
      log "INFO" "Removing disk stress file ${disk_target}"
      rm -f "${disk_target}"
    fi
    rm -f "${DISK_FILE_PATH_FILE}"
  else
    log "INFO" "No disk target metadata found"
  fi
}

reset_network_qdisc() {
  if [[ -f "${NET_IFACE_FILE}" ]]; then
    local iface
    iface="$(cat "${NET_IFACE_FILE}")"
    if [[ -n "${iface}" ]]; then
      if command -v tc >/dev/null 2>&1; then
        LAST_NET_IFACE="${iface}"
        if tc qdisc show dev "${iface}" 2>/dev/null | grep -q 'netem'; then
          log "INFO" "Removing netem from interface ${iface}"
          tc qdisc del dev "${iface}" root >/dev/null 2>&1 || true
        else
          log "INFO" "No netem qdisc active on ${iface}"
        fi
      else
        log "WARN" "tc command not found; cannot inspect/remove network qdisc"
      fi
    fi
    rm -f "${NET_IFACE_FILE}"
  else
    log "INFO" "No network metadata found"
  fi
}

cpu_snapshot() {
  if command -v mpstat >/dev/null 2>&1; then
    mpstat 1 1 | awk '/Average:/ && $NF ~ /[0-9.]+/ {printf("cpu_busy=%.2f%%\n", 100-$NF)}' | tail -n1
  elif command -v vmstat >/dev/null 2>&1; then
    vmstat 1 2 | tail -n1 | awk '{printf("cpu_busy=%s%%\n", 100-$15)}'
  else
    echo "cpu_busy=unknown"
  fi
}

memory_snapshot() {
  if command -v free >/dev/null 2>&1; then
    free -m | awk '/Mem:/ {printf("mem_used_mb=%s mem_available_mb=%s\n", $3, $7)}'
  else
    echo "mem_used_mb=unknown mem_available_mb=unknown"
  fi
}

disk_snapshot() {
  if command -v iostat >/dev/null 2>&1; then
    iostat -dx 1 1 | awk 'NR>3 {print}' | head -n 3
  else
    echo "disk_iostat=unavailable"
  fi
}

network_snapshot() {
  local iface=""
  if [[ -f "${NET_IFACE_FILE}" ]]; then
    iface="$(cat "${NET_IFACE_FILE}")"
  fi

  if [[ -z "${iface}" ]]; then
    iface="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
  fi

  if [[ -n "${iface}" ]]; then
    echo "network_iface=${iface}"
    if command -v tc >/dev/null 2>&1; then
      tc qdisc show dev "${iface}" 2>/dev/null || true
    fi
    ip -s link show dev "${iface}" 2>/dev/null | sed -n '1,6p' || true
  else
    echo "network_iface=unknown"
  fi
}

verify_no_managed_processes() {
  if [[ "${STOP_FAILURES}" -gt 0 ]]; then
    log "ERROR" "One or more managed fault PIDs could not be stopped"
    return 1
  fi

  return 0
}

verify_network_restored() {
  if [[ -z "${LAST_NET_IFACE}" ]]; then
    return 0
  fi

  if ! command -v tc >/dev/null 2>&1; then
    return 0
  fi

  if tc qdisc show dev "${LAST_NET_IFACE}" 2>/dev/null | grep -q 'netem'; then
    log "ERROR" "netem still present on ${LAST_NET_IFACE}"
    return 1
  fi

  return 0
}

main() {
  require_root
  log "INFO" "==== Restore start ===="

  stop_injected_faults
  cleanup_disk_artifacts
  reset_network_qdisc

  log "INFO" "System health snapshot after restore"
  log "INFO" "$(cpu_snapshot)"
  log "INFO" "$(memory_snapshot)"
  while IFS= read -r line; do
    log "INFO" "${line}"
  done < <(disk_snapshot)
  while IFS= read -r line; do
    log "INFO" "${line}"
  done < <(network_snapshot)

  local rc=0
  verify_no_managed_processes || rc=1
  verify_network_restored || rc=1

  if [[ "${rc}" -eq 0 ]]; then
    log "INFO" "Restore completed successfully"
    echo "RESTORE_STATUS=SUCCESS"
    exit 0
  fi

  log "ERROR" "Restore completed with errors"
  echo "RESTORE_STATUS=FAILED"
  exit 1
}

main "$@"

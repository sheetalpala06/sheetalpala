#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/tmp/vm-fault-injection"
PID_FILE="${STATE_DIR}/fault_pids.list"
NET_IFACE_FILE="${STATE_DIR}/net_iface"
DISK_FILE_PATH_FILE="${STATE_DIR}/disk_io_target"
VALIDATION_MARKER="${STATE_DIR}/restore_validated.ok"
VALIDATION_LOG="/var/log/vm-fault-restore-validation.log"
RESTORE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore_vm_faults.sh"

mkdir -p "${STATE_DIR}"
touch "${VALIDATION_LOG}"

log() {
  local level="$1"
  local msg="$2"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${msg}" | tee -a "${VALIDATION_LOG}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
  fi
}

start_dummy_degraded_state() {
  log "INFO" "Starting dummy CPU load"
  yes > /dev/null &
  local cpu_pid1=$!
  yes > /dev/null &
  local cpu_pid2=$!

  log "INFO" "Starting dummy memory pressure"
  python3 - <<'PY' &
import time
x = bytearray(64 * 1024 * 1024)
for i in range(0, len(x), 4096):
    x[i] = 1
time.sleep(300)
PY
  local mem_pid=$!

  log "INFO" "Starting dummy disk pressure"
  (
    while true; do
      dd if=/dev/zero of=/var/tmp/vmfi-validate-disk.bin bs=4M count=16 conv=fdatasync status=none
    done
  ) &
  local disk_pid=$!

  {
    echo "${cpu_pid1}:validation-cpu-1"
    echo "${cpu_pid2}:validation-cpu-2"
    echo "${mem_pid}:validation-mem"
    echo "${disk_pid}:validation-disk"
  } > "${PID_FILE}"

  echo "/var/tmp/vmfi-validate-disk.bin" > "${DISK_FILE_PATH_FILE}"

  if command -v tc >/dev/null 2>&1; then
    local iface
    iface="$(ip route | awk '/default/ {print $5; exit}')"
    if [[ -n "${iface}" ]]; then
      log "INFO" "Applying temporary netem on ${iface} for validation"
      tc qdisc replace dev "${iface}" root netem delay 40ms 5ms >/dev/null 2>&1 || true
      echo "${iface}" > "${NET_IFACE_FILE}"
    fi
  fi
}

verify_baseline_after_restore() {
  local net_iface_before="$1"
  local failures=0

  if [[ -f "${PID_FILE}" ]]; then
    log "ERROR" "PID file still exists after restore"
    failures=$((failures + 1))
  fi

  if [[ -f "${DISK_FILE_PATH_FILE}" ]]; then
    log "ERROR" "Disk metadata file still exists after restore"
    failures=$((failures + 1))
  fi

  if [[ -f /var/tmp/vmfi-validate-disk.bin ]]; then
    log "ERROR" "Validation disk file still exists"
    failures=$((failures + 1))
  fi

  if command -v tc >/dev/null 2>&1 && [[ -n "${net_iface_before}" ]]; then
    if tc qdisc show dev "${net_iface_before}" 2>/dev/null | grep -q netem; then
      log "ERROR" "netem still active on ${net_iface_before}"
      failures=$((failures + 1))
    fi
  fi

  if [[ -f "${NET_IFACE_FILE}" ]]; then
    log "ERROR" "Network metadata file still exists after restore"
    failures=$((failures + 1))
  fi

  if [[ -f "${VALIDATION_MARKER}" ]]; then
    if [[ ! -s "${VALIDATION_MARKER}" ]]; then
      log "ERROR" "Validation marker file exists but is empty"
      failures=$((failures + 1))
    fi
  fi

  if [[ "${failures}" -gt 0 ]]; then
    return 1
  fi

  return 0
}

main() {
  require_root
  log "INFO" "==== Restore validation start ===="

  if ! command -v python3 >/dev/null 2>&1; then
    log "ERROR" "python3 not found; required for validation memory dummy process"
    exit 1
  fi

  start_dummy_degraded_state

  local net_iface_before=""
  if [[ -f "${NET_IFACE_FILE}" ]]; then
    net_iface_before="$(cat "${NET_IFACE_FILE}")"
  fi

  log "INFO" "Running restore script against simulated degraded state"
  if ! "${RESTORE_SCRIPT}"; then
    log "ERROR" "Restore script failed during validation"
    exit 1
  fi

  if verify_baseline_after_restore "${net_iface_before}"; then
    date '+%Y-%m-%d %H:%M:%S' > "${VALIDATION_MARKER}"
    log "INFO" "Restore validation PASSED"
    echo "VALIDATION_STATUS=SUCCESS"
    exit 0
  fi

  log "ERROR" "Restore validation FAILED"
  echo "VALIDATION_STATUS=FAILED"
  exit 1
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/tmp/vm-fault-injection"
PID_FILE="${STATE_DIR}/fault_pids.list"
NET_IFACE_FILE="${STATE_DIR}/net_iface"
DISK_FILE_PATH_FILE="${STATE_DIR}/disk_io_target"
VALIDATION_MARKER="${STATE_DIR}/restore_validated.ok"
FAULT_LOG="/var/log/vm-fault-injection.log"
RESTORE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore_vm_faults.sh"

DURATION_SEC="${DURATION_SEC:-120}"
CPU_WORKERS="${CPU_WORKERS:-2}"
MEMORY_MB="${MEMORY_MB:-256}"
DISK_FILE_MB="${DISK_FILE_MB:-256}"
ENABLE_NETEM="${ENABLE_NETEM:-0}"
NETEM_DELAY="${NETEM_DELAY:-80ms}"
NETEM_JITTER="${NETEM_JITTER:-10ms}"

mkdir -p "${STATE_DIR}"
touch "${FAULT_LOG}"

log() {
  local level="$1"
  local msg="$2"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${msg}" | tee -a "${FAULT_LOG}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
  fi
}

cap_resources() {
  local cores
  cores="$(nproc 2>/dev/null || echo 2)"

  if [[ "${CPU_WORKERS}" -gt 4 ]]; then
    CPU_WORKERS=4
  fi
  if [[ "${CPU_WORKERS}" -lt 1 ]]; then
    CPU_WORKERS=1
  fi
  if [[ "${CPU_WORKERS}" -gt "${cores}" ]]; then
    CPU_WORKERS="${cores}"
  fi

  if [[ "${MEMORY_MB}" -gt 1024 ]]; then
    MEMORY_MB=1024
  fi
  if [[ "${MEMORY_MB}" -lt 64 ]]; then
    MEMORY_MB=64
  fi

  if [[ "${DISK_FILE_MB}" -gt 1024 ]]; then
    DISK_FILE_MB=1024
  fi
  if [[ "${DISK_FILE_MB}" -lt 64 ]]; then
    DISK_FILE_MB=64
  fi

  if [[ "${DURATION_SEC}" -gt 900 ]]; then
    DURATION_SEC=900
  fi
  if [[ "${DURATION_SEC}" -lt 10 ]]; then
    DURATION_SEC=10
  fi
}

record_pid() {
  local pid="$1"
  local label="$2"
  echo "${pid}:${label}" >> "${PID_FILE}"
}

cleanup_on_exit() {
  log "INFO" "Signal/exit caught, invoking restore"
  "${RESTORE_SCRIPT}" || true
}

enforce_restore_gate() {
  if [[ ! -f "${VALIDATION_MARKER}" ]]; then
    log "ERROR" "Restore validation marker missing: ${VALIDATION_MARKER}"
    log "ERROR" "Run validate_restore.sh first. Fault injection aborted."
    exit 1
  fi

  log "INFO" "Running pre-flight restore test"
  if ! "${RESTORE_SCRIPT}"; then
    log "ERROR" "Pre-flight restore test failed. DO NOT run fault injection."
    exit 1
  fi

  log "INFO" "Restore gate passed"
}

start_cpu_fault() {
  if command -v stress-ng >/dev/null 2>&1; then
    log "INFO" "Starting CPU stress via stress-ng workers=${CPU_WORKERS}"
    stress-ng --cpu "${CPU_WORKERS}" --cpu-load 70 --timeout "${DURATION_SEC}s" >/dev/null 2>&1 &
    record_pid "$!" "cpu-stress-ng"
    return
  fi

  log "INFO" "stress-ng not found; using yes loops workers=${CPU_WORKERS}"
  local i
  for ((i=1; i<=CPU_WORKERS; i++)); do
    yes > /dev/null &
    record_pid "$!" "cpu-yes-${i}"
  done
}

start_memory_fault() {
  if command -v stress-ng >/dev/null 2>&1; then
    log "INFO" "Starting memory pressure via stress-ng mem=${MEMORY_MB}MB"
    stress-ng --vm 1 --vm-bytes "${MEMORY_MB}M" --vm-keep --timeout "${DURATION_SEC}s" >/dev/null 2>&1 &
    record_pid "$!" "mem-stress-ng"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    log "INFO" "Starting memory pressure via python3 mem=${MEMORY_MB}MB"
    python3 - <<PY &
import time
size_mb = int(${MEMORY_MB})
buf = bytearray(size_mb * 1024 * 1024)
for i in range(0, len(buf), 4096):
    buf[i] = 1
time.sleep(int(${DURATION_SEC}))
PY
    record_pid "$!" "mem-python"
    return
  fi

  log "WARN" "No memory stress tool available; skipping memory fault"
}

start_disk_fault() {
  local disk_file="/var/tmp/vmfi-disk-load.bin"
  echo "${disk_file}" > "${DISK_FILE_PATH_FILE}"

  log "INFO" "Starting disk IO saturation target=${disk_file} size=${DISK_FILE_MB}MB"
  (
    while true; do
      dd if=/dev/zero of="${disk_file}" bs=4M count="$((DISK_FILE_MB / 4))" conv=fdatasync status=none
    done
  ) &
  record_pid "$!" "disk-dd-loop"
}

start_network_fault_optional() {
  if [[ "${ENABLE_NETEM}" != "1" ]]; then
    log "INFO" "Network netem disabled (ENABLE_NETEM=${ENABLE_NETEM})"
    return
  fi

  if ! command -v tc >/dev/null 2>&1; then
    log "WARN" "tc not found; skipping network delay fault"
    return
  fi

  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  if [[ -z "${iface}" ]]; then
    log "WARN" "Could not detect default interface; skipping network fault"
    return
  fi

  log "INFO" "Applying netem on ${iface}: delay=${NETEM_DELAY} jitter=${NETEM_JITTER}"
  tc qdisc replace dev "${iface}" root netem delay "${NETEM_DELAY}" "${NETEM_JITTER}" >/dev/null 2>&1
  echo "${iface}" > "${NET_IFACE_FILE}"
}

main() {
  require_root
  cap_resources
  enforce_restore_gate

  : > "${PID_FILE}"
  trap cleanup_on_exit INT TERM EXIT

  log "INFO" "==== Fault injection start ===="
  log "INFO" "duration=${DURATION_SEC}s cpu_workers=${CPU_WORKERS} mem_mb=${MEMORY_MB} disk_mb=${DISK_FILE_MB}"

  start_cpu_fault
  start_memory_fault
  start_disk_fault
  start_network_fault_optional

  log "INFO" "Faults active. They will auto-stop after ${DURATION_SEC}s."
  sleep "${DURATION_SEC}"

  log "INFO" "Timeout reached; restoring system"
  "${RESTORE_SCRIPT}"
  trap - INT TERM EXIT

  log "INFO" "Fault injection completed and restore executed"
}

main "$@"

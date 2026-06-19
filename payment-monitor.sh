#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
HEALTH_URL="http://localhost:80"
CHECK_INTERVAL_SECONDS="30"
APACHE_SERVICE="apache2"
LOG_FILE="/var/log/payment-monitor.log"
DUMP_DIR="/var/log/payment-monitor-dumps"
PID_FILE="/tmp/payment-monitor.pid"
STATE_FILE="/tmp/payment-monitor.state.$$"
LOCK_FILE="/tmp/payment-monitor.lock"

MODE="daemon"
DRY_RUN="false"
RUN_LOOP_INTERNAL="false"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--daemon|--once|--rollback|--status] [--dry-run]

Options:
  --daemon      Start monitor loop in background (default)
  --once        Run one health check cycle only
  --rollback    Stop monitor loop and restore original apache service state
  --status      Show monitor daemon status
  --dry-run     Print actions without making service changes
  -h, --help    Show this help
EOF
}

timestamp() {
    date "+%Y-%m-%d %H:%M:%S%z"
}

ensure_log_paths() {
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    sudo touch "$LOG_FILE"
    sudo mkdir -p "$DUMP_DIR"
    sudo chown "$(id -un):$(id -gn)" "$LOG_FILE"
    sudo chown "$(id -un):$(id -gn)" "$DUMP_DIR"
}

log() {
    local message="$1"
    local line
    line="$(timestamp) | ${message}"
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

is_pid_running() {
    local pid="$1"
    if [ -z "$pid" ]; then
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    return 1
}

is_monitor_running() {
    local existing_pid

    if [ ! -f "$PID_FILE" ]; then
        return 1
    fi

    existing_pid="$(cat "$PID_FILE")"
    if is_pid_running "$existing_pid"; then
        return 0
    fi

    # Clean stale PID file so subsequent starts are idempotent.
    rm -f "$PID_FILE"

    return 1
}

acquire_lock() {
    # Fail fast: if lock exists, another instance is running
    if mkdir "$LOCK_FILE" 2>/dev/null; then
        echo "$$" > "${LOCK_FILE}/pid"
        return 0
    fi
    return 1
}

release_lock() {
    if [ -f "${LOCK_FILE}/pid" ]; then
        local lock_pid
        lock_pid="$(cat "${LOCK_FILE}/pid")"
        if [ "$lock_pid" = "$$" ]; then
            rm -rf "$LOCK_FILE"
        fi
    fi
}

service_state() {
    if sudo systemctl is-active --quiet "$APACHE_SERVICE"; then
        echo "active"
    else
        echo "inactive"
    fi
}

save_original_state() {
    local current_state
    current_state="$(service_state)"

    cat > "$STATE_FILE" <<EOF
ORIGINAL_SERVICE_STATE="${current_state}"
EOF
    chmod 600 "$STATE_FILE"
}

load_original_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    else
        ORIGINAL_SERVICE_STATE="$(service_state)"
    fi
}

capture_apache_thread_dump() {
    local dump_file
    local ts
    local pid
    local apache_pids=()

    ts="$(date "+%Y%m%d_%H%M%S")"
    dump_file="${DUMP_DIR}/apache-thread-dump-${ts}.log"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] Would capture Apache thread dump to '${dump_file}'."
        return 0
    fi

    sudo touch "$dump_file"
    sudo chown "$(id -un):$(id -gn)" "$dump_file"

    mapfile -t apache_pids < <(pgrep -x "apache2" || true)
    if [ "${#apache_pids[@]}" -eq 0 ]; then
        log "No apache2 worker processes found while capturing thread dump."
        return 0
    fi

    {
        echo "Timestamp: $(timestamp)"
        echo "Service: ${APACHE_SERVICE}"
        echo "PIDs: ${apache_pids[*]}"
        echo

        if command -v "gstack" >/dev/null 2>&1; then
            for pid in "${apache_pids[@]}"; do
                echo "==== gstack PID ${pid} ===="
                sudo gstack "$pid" || echo "gstack failed for PID ${pid}"
                echo
            done
        elif command -v "pstack" >/dev/null 2>&1; then
            for pid in "${apache_pids[@]}"; do
                echo "==== pstack PID ${pid} ===="
                sudo pstack "$pid" || echo "pstack failed for PID ${pid}"
                echo
            done
        else
            echo "Neither gstack nor pstack found; using thread snapshot via ps -L."
            for pid in "${apache_pids[@]}"; do
                echo "==== ps -L PID ${pid} ===="
                ps -L -p "$pid" -o pid,tid,psr,pcpu,stat,wchan:32,comm
                echo
            done
        fi
    } >> "$dump_file" 2>&1

    log "Apache thread dump captured at '${dump_file}'."
}

restart_apache() {
    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] Would restart service '${APACHE_SERVICE}'."
        return 0
    fi

    log "Restarting service '${APACHE_SERVICE}'."
    sudo systemctl restart "$APACHE_SERVICE"
    log "Service '${APACHE_SERVICE}' restarted."
}

check_health_once() {
    local http_code

    http_code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_URL" || true)"
    if [ -z "$http_code" ]; then
        http_code="000"
    fi

    log "Health check '${HEALTH_URL}' returned HTTP '${http_code}'."

    if [ "$http_code" != "200" ]; then
        log "Non-200 health response detected; capturing dump and restarting Apache."
        capture_apache_thread_dump
        restart_apache
    else
        log "Health check is healthy."
    fi
}

restore_original_service_state() {
    load_original_state

    if [ "${ORIGINAL_SERVICE_STATE}" = "active" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            log "[DRY-RUN] Would restore '${APACHE_SERVICE}' to active state."
        else
            log "Restoring '${APACHE_SERVICE}' to active state."
            sudo systemctl start "$APACHE_SERVICE"
        fi
    else
        if [ "$DRY_RUN" = "true" ]; then
            log "[DRY-RUN] Would restore '${APACHE_SERVICE}' to inactive state."
        else
            log "Restoring '${APACHE_SERVICE}' to inactive state."
            sudo systemctl stop "$APACHE_SERVICE"
        fi
    fi
}

rollback() {
    local reason="${1:-manual}"
    local monitor_pid=""

    log "Rollback requested (reason: '${reason}')."

    if [ -f "$PID_FILE" ]; then
        monitor_pid="$(cat "$PID_FILE")"

        if is_pid_running "$monitor_pid"; then
            if [ "$monitor_pid" != "$$" ]; then
                if [ "$DRY_RUN" = "true" ]; then
                    log "[DRY-RUN] Would stop monitor process PID '${monitor_pid}'."
                else
                    log "Stopping monitor process PID '${monitor_pid}'."
                    kill "$monitor_pid" || true
                fi
            else
                log "Rollback running in monitor process '${monitor_pid}'; no external stop needed."
            fi
        else
            log "PID file exists but PID '${monitor_pid}' is not running."
        fi
    fi

    restore_original_service_state

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] Would remove '${PID_FILE}' and '${STATE_FILE}'."
    else
        rm -f "$PID_FILE" "$STATE_FILE"
        log "Rollback complete; state files removed."
    fi
}

monitor_loop() {
    log "Monitor loop started; checking '${HEALTH_URL}' every ${CHECK_INTERVAL_SECONDS} seconds."
    while true; do
        check_health_once
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

run_loop_internal() {
    ensure_log_paths
    echo "$$" > "$PID_FILE"
    trap 'rollback "daemon signal"; exit 0' INT TERM
    monitor_loop
}

start_daemon() {
    local daemon_pid
    local cmd=("$0" "--run-loop")

    ensure_log_paths

    if is_monitor_running; then
        daemon_pid="$(cat "$PID_FILE")"
        log "Monitor already running with PID '${daemon_pid}'. Idempotent start skipped."
        return 0
    fi

    save_original_state

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] Would start monitor daemon in background."
        return 0
    fi

    nohup "${cmd[@]}" >/dev/null 2>&1 &
    daemon_pid="$!"
    echo "$daemon_pid" > "$PID_FILE"
    log "Monitor daemon started with PID '${daemon_pid}'."
}

run_once() {
    ensure_log_paths

    # If daemon is already running, skip (let daemon handle monitoring)
    if is_monitor_running; then
        log "Monitor daemon already running. Skipping single-run check."
        return 0
    fi

    # Try to acquire lock; if another --once instance is running, skip
    if ! acquire_lock; then
        log "Another --once instance is running. Skipping this check."
        return 0
    fi

    trap 'rollback "once mode interrupted or failed"; release_lock; exit 1' INT TERM ERR

    save_original_state
    check_health_once

    trap - INT TERM ERR
    release_lock

    rm -f "$STATE_FILE"
    log "Single-run check completed."
}

show_status() {
    if is_monitor_running; then
        echo "running (pid: $(cat "$PID_FILE"))"
    else
        echo "not running"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --daemon)
            MODE="daemon"
            ;;
        --once)
            MODE="once"
            ;;
        --rollback)
            MODE="rollback"
            ;;
        --status)
            MODE="status"
            ;;
        --dry-run)
            DRY_RUN="true"
            ;;
        --run-loop)
            RUN_LOOP_INTERNAL="true"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [ "$RUN_LOOP_INTERNAL" = "true" ]; then
    run_loop_internal
    exit 0
fi

case "$MODE" in
    daemon)
        start_daemon
        ;;
    once)
        run_once
        ;;
    rollback)
        ensure_log_paths
        rollback "manual request"
        ;;
    status)
        show_status
        ;;
    *)
        echo "Invalid mode: ${MODE}" >&2
        exit 1
        ;;
esac

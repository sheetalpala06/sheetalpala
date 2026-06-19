# Safe VM Fault Injection Guide (Rollback First)

This guide enforces rollback-first execution for Linux VMs.

## 1) Restore Script (MANDATORY FIRST)

Script: `restore_vm_faults.sh`

Purpose:
- Stops managed CPU, memory, disk stress processes from tracked PIDs.
- Removes disk stress artifacts.
- Removes `tc/netem` qdisc when applied by the fault script.
- Logs all actions to `/var/log/vm-fault-restore.log`.
- Prints `RESTORE_STATUS=SUCCESS` or `RESTORE_STATUS=FAILED`.
- Idempotent and safe to run repeatedly.

## 2) Restore Validation Steps (Independent)

Script: `validate_restore.sh`

What it does:
- Simulates degraded state with dummy CPU, memory, and disk load processes.
- Optionally applies temporary network netem if `tc` is available.
- Runs `restore_vm_faults.sh`.
- Verifies cleanup and baseline conditions.
- Writes validation marker: `/var/tmp/vm-fault-injection/restore_validated.ok` on success.
- Logs to `/var/log/vm-fault-restore-validation.log`.

Validation command:

```bash
sudo bash ./validate_restore.sh
```

Expected success output:

```text
RESTORE_STATUS=SUCCESS
VALIDATION_STATUS=SUCCESS
```

## 3) Fault Injection Script (Gated)

Script: `inject_vm_faults.sh`

Faults included:
- CPU stress (`stress-ng` preferred, fallback `yes` loops).
- Memory pressure (`stress-ng` preferred, fallback `python3` allocator).
- Disk IO saturation (`dd` loop against a temporary file).
- Optional network delay (`tc netem`) when `ENABLE_NETEM=1`.

Safety controls:
- Hard gate: refuses to run if restore validation marker is missing.
- Pre-flight restore gate: runs `restore_vm_faults.sh` and aborts on failure.
- PID tracking in `/var/tmp/vm-fault-injection/fault_pids.list`.
- Automatic timeout cleanup (`DURATION_SEC`, capped).
- Signal handling: Ctrl+C triggers restore automatically.
- Conservative resource caps to avoid full outage.
- Logs to `/var/log/vm-fault-injection.log`.

## 4) Strict Execution Order (Enforced)

Run exactly in this order:

```bash
# 1) Restore test (must pass)
sudo bash ./restore_vm_faults.sh

# 2) Restore validation (must pass and create marker)
sudo bash ./validate_restore.sh

# 3) Fault injection (only after marker + pre-flight restore)
sudo DURATION_SEC=120 CPU_WORKERS=2 MEMORY_MB=256 DISK_FILE_MB=256 ENABLE_NETEM=0 bash ./inject_vm_faults.sh

# 4) Explicit rollback after fault run
sudo bash ./restore_vm_faults.sh
```

If any restore step fails, do not run fault injection.

## 5) Verification Commands and Expected Checks

Run after restore:

```bash
# Logs show success
sudo tail -n 50 /var/log/vm-fault-restore.log

# Managed PID list should be absent
sudo test ! -f /var/tmp/vm-fault-injection/fault_pids.list && echo "PID file cleaned"

# Disk artifact should be absent
sudo test ! -f /var/tmp/vmfi-disk-load.bin && echo "Disk file cleaned"

# Check active qdisc on default interface (should not contain netem)
IFACE=$(ip route | awk '/default/ {print $5; exit}')
sudo tc qdisc show dev "$IFACE"

# Quick health snapshots
vmstat 1 2 | tail -n1
free -m
iostat -dx 1 1
```

Expected outcomes:
- Restore log contains `RESTORE_STATUS=SUCCESS`.
- No managed PID file remains.
- No temp disk load file remains.
- `tc qdisc` output does not include `netem` (unless managed outside this experiment).
- CPU and memory metrics return near pre-test baseline.

## 6) Risk Notes

- Run only on non-production/test VMs first.
- This design only kills processes started by these scripts (PID-tracked), avoiding broad process termination.
- Network qdisc cleanup targets only the interface recorded by this experiment.
- If `stress-ng`, `python3`, or `tc` are missing, script logs warning and uses safe fallbacks where possible.
- Disk stress writes to temporary file under `/var/tmp`; no destructive filesystem actions are used.

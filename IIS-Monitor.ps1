<#
.SYNOPSIS
    IIS Application Pool Monitor - Automatically restarts stopped pools and captures diagnostics.

.DESCRIPTION
    Monitors IIS application pool states and automatically restarts any stopped pools.
    Captures Windows Event Log errors before restart for diagnostics.
    Supports daemon mode, single-run mode, rollback, and status check.

.PARAMETER Mode
    Operation mode: Daemon (default), Once, Rollback, or Status

.PARAMETER DryRun
    Shows what actions would be taken without making any changes

.EXAMPLE
    .\IIS-Monitor.ps1 -Mode Daemon
    Start monitoring in background

.EXAMPLE
    .\IIS-Monitor.ps1 -Mode Once -DryRun
    Run single health check without making changes

.EXAMPLE
    .\IIS-Monitor.ps1 -Mode Rollback
    Stop monitoring and restore original pool states

.NOTES
    Requires: Windows Server 2022, IIS, WebAdministration module
    Run as: Administrator
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Daemon', 'Once', 'Rollback', 'Status')]
    [string]$Mode = 'Daemon',

    [Parameter()]
    [switch]$DryRun,

    [Parameter(DontShow)]
    [switch]$RunLoopInternal
)

#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules WebAdministration

# Script Configuration
$script:Config = @{
    CheckIntervalSeconds = 60
    LogFile              = 'C:\Logs\iis-monitor.log'
    EventLogDumpDir      = 'C:\Logs\iis-monitor-eventlogs'
    PidFile              = "$env:TEMP\iis-monitor.pid"
    StateFile            = "$env:TEMP\iis-monitor.state.$PID.json"
    LockFile             = "$env:TEMP\iis-monitor.lock"
    EventLogMinutes      = 10
}

# Import required module
Import-Module WebAdministration -ErrorAction Stop

#region Helper Functions

function Get-Timestamp {
    return Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
}

function Initialize-LogPaths {
    $logDir = Split-Path $script:Config.LogFile -Parent
    $eventLogDir = $script:Config.EventLogDumpDir

    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $eventLogDir)) {
        New-Item -Path $eventLogDir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $script:Config.LogFile)) {
        New-Item -Path $script:Config.LogFile -ItemType File -Force | Out-Null
    }
}

function Write-MonitorLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Timestamp
    $logLine = "$timestamp | [$Level] $Message"
    
    Write-Host $logLine
    Add-Content -Path $script:Config.LogFile -Value $logLine -ErrorAction SilentlyContinue
}

function Test-ProcessRunning {
    param([int]$ProcessId)
    
    if ($ProcessId -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Test-MonitorRunning {
    if (-not (Test-Path $script:Config.PidFile)) {
        return $false
    }

    try {
        $pidContent = Get-Content $script:Config.PidFile -Raw -ErrorAction Stop
        $existingPid = [int]$pidContent.Trim()
        
        if (Test-ProcessRunning -ProcessId $existingPid) {
            return $true
        }

        # Clean stale PID file
        Remove-Item $script:Config.PidFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    catch {
        return $false
    }
}

function Lock-Monitor {
    if (Test-Path $script:Config.LockFile) {
        return $false
    }

    try {
        New-Item -Path $script:Config.LockFile -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Set-Content -Path "$($script:Config.LockFile)\pid" -Value $PID -Force
        return $true
    }
    catch {
        return $false
    }
}

function Unlock-Monitor {
    if (Test-Path "$($script:Config.LockFile)\pid") {
        try {
            $lockPid = [int](Get-Content "$($script:Config.LockFile)\pid" -Raw).Trim()
            if ($lockPid -eq $PID) {
                Remove-Item $script:Config.LockFile -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Ignore unlock errors
        }
    }
}

function Get-AppPoolState {
    param([string]$PoolName)
    
    try {
        $pool = Get-WebAppPoolState -Name $PoolName -ErrorAction Stop
        return $pool.Value
    }
    catch {
        Write-MonitorLog "Failed to get state for pool '$PoolName': $_" -Level Error
        return $null
    }
}

function Save-OriginalState {
    try {
        $pools = Get-ChildItem IIS:\AppPools -ErrorAction Stop
        $stateData = @{
            Timestamp = Get-Date -Format o
            Pools     = @()
        }

        foreach ($pool in $pools) {
            $stateData.Pools += @{
                Name  = $pool.Name
                State = $pool.State
            }
        }

        $stateData | ConvertTo-Json -Depth 10 | Set-Content $script:Config.StateFile -Force
        Write-MonitorLog "Original state saved for $($pools.Count) application pool(s)."
    }
    catch {
        Write-MonitorLog "Failed to save original state: $_" -Level Error
    }
}

function Restore-OriginalState {
    if (-not (Test-Path $script:Config.StateFile)) {
        Write-MonitorLog "No state file found; skipping state restoration." -Level Warning
        return
    }

    try {
        $stateData = Get-Content $script:Config.StateFile -Raw | ConvertFrom-Json
        Write-MonitorLog "Restoring original state from $($stateData.Timestamp)..."

        foreach ($poolState in $stateData.Pools) {
            $currentState = Get-AppPoolState -PoolName $poolState.Name
            
            if ($currentState -eq $poolState.State) {
                Write-MonitorLog "Pool '$($poolState.Name)' already in state '$($poolState.State)'."
                continue
            }

            if ($DryRun) {
                Write-MonitorLog "[DRY-RUN] Would restore pool '$($poolState.Name)' to state '$($poolState.State)'."
                continue
            }

            try {
                if ($poolState.State -eq 'Started') {
                    Start-WebAppPool -Name $poolState.Name -ErrorAction Stop
                    Write-MonitorLog "Restored pool '$($poolState.Name)' to Started state."
                }
                elseif ($poolState.State -eq 'Stopped') {
                    Stop-WebAppPool -Name $poolState.Name -ErrorAction Stop
                    Write-MonitorLog "Restored pool '$($poolState.Name)' to Stopped state."
                }
            }
            catch {
                Write-MonitorLog "Failed to restore pool '$($poolState.Name)': $_" -Level Error
            }
        }
    }
    catch {
        Write-MonitorLog "Failed to restore original state: $_" -Level Error
    }
}

function Get-EventLogErrors {
    param([int]$Minutes = 10)

    $dumpFile = Join-Path $script:Config.EventLogDumpDir "EventLog-$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    
    if ($DryRun) {
        Write-MonitorLog "[DRY-RUN] Would capture Event Log errors to '$dumpFile'."
        return
    }

    try {
        $startTime = (Get-Date).AddMinutes(-$Minutes)
        $output = @()
        
        $output += "Event Log Capture: $(Get-Timestamp)"
        $output += "Time Range: Last $Minutes minutes"
        $output += "=" * 80
        $output += ""

        # Capture System log errors
        $output += "=== SYSTEM LOG ERRORS ==="
        $systemErrors = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Level     = 2  # Error
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Select-Object -First 50

        if ($systemErrors) {
            foreach ($event in $systemErrors) {
                $output += "Time: $($event.TimeCreated)"
                $output += "Source: $($event.ProviderName)"
                $output += "EventID: $($event.Id)"
                $output += "Message: $($event.Message)"
                $output += "-" * 80
            }
        }
        else {
            $output += "No errors found."
        }
        $output += ""

        # Capture Application log errors
        $output += "=== APPLICATION LOG ERRORS ==="
        $appErrors = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            Level     = 2  # Error
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Select-Object -First 50

        if ($appErrors) {
            foreach ($event in $appErrors) {
                $output += "Time: $($event.TimeCreated)"
                $output += "Source: $($event.ProviderName)"
                $output += "EventID: $($event.Id)"
                $output += "Message: $($event.Message)"
                $output += "-" * 80
            }
        }
        else {
            $output += "No errors found."
        }
        $output += ""

        # Capture IIS-specific errors
        $output += "=== IIS/WAS LOG ERRORS ==="
        $iisErrors = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            ProviderName = 'Microsoft-Windows-WAS', 'W3SVC-WP'
            Level     = 2  # Error
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Select-Object -First 50

        if ($iisErrors) {
            foreach ($event in $iisErrors) {
                $output += "Time: $($event.TimeCreated)"
                $output += "Source: $($event.ProviderName)"
                $output += "EventID: $($event.Id)"
                $output += "Message: $($event.Message)"
                $output += "-" * 80
            }
        }
        else {
            $output += "No errors found."
        }

        $output | Out-File -FilePath $dumpFile -Encoding UTF8
        Write-MonitorLog "Event log errors captured to '$dumpFile'."
    }
    catch {
        Write-MonitorLog "Failed to capture event logs: $_" -Level Error
    }
}

function Restart-AppPool {
    param([string]$PoolName)

    if ($DryRun) {
        Write-MonitorLog "[DRY-RUN] Would restart application pool '$PoolName'."
        return
    }

    try {
        Write-MonitorLog "Restarting application pool '$PoolName'..."
        Restart-WebAppPool -Name $PoolName -ErrorAction Stop
        
        # Wait briefly and verify
        Start-Sleep -Seconds 2
        $newState = Get-AppPoolState -PoolName $PoolName
        
        if ($newState -eq 'Started') {
            Write-MonitorLog "Application pool '$PoolName' restarted successfully (State: $newState)."
        }
        else {
            Write-MonitorLog "Application pool '$PoolName' restart completed but state is '$newState'." -Level Warning
        }
    }
    catch {
        Write-MonitorLog "Failed to restart application pool '$PoolName': $_" -Level Error
    }
}

function Invoke-HealthCheck {
    Write-MonitorLog "Performing health check on all application pools..."

    try {
        $pools = Get-ChildItem IIS:\AppPools -ErrorAction Stop
        $stoppedPools = @()

        foreach ($pool in $pools) {
            $poolName = $pool.Name
            $poolState = $pool.State

            Write-MonitorLog "Pool '$poolName' state: $poolState"

            if ($poolState -eq 'Stopped') {
                $stoppedPools += $poolName
            }
        }

        if ($stoppedPools.Count -gt 0) {
            Write-MonitorLog "Detected $($stoppedPools.Count) stopped pool(s): $($stoppedPools -join ', ')" -Level Warning
            
            # Capture event logs before restart
            Get-EventLogErrors -Minutes $script:Config.EventLogMinutes

            # Restart each stopped pool
            foreach ($poolName in $stoppedPools) {
                Restart-AppPool -PoolName $poolName
            }
        }
        else {
            Write-MonitorLog "All application pools are running."
        }
    }
    catch {
        Write-MonitorLog "Health check failed: $_" -Level Error
    }
}

function Invoke-Rollback {
    param([string]$Reason = 'manual')

    Write-MonitorLog "Rollback requested (Reason: '$Reason')."

    if (Test-Path $script:Config.PidFile) {
        try {
            $monitorPid = [int](Get-Content $script:Config.PidFile -Raw).Trim()
            
            if (Test-ProcessRunning -ProcessId $monitorPid) {
                if ($monitorPid -ne $PID) {
                    if ($DryRun) {
                        Write-MonitorLog "[DRY-RUN] Would stop monitor process PID '$monitorPid'."
                    }
                    else {
                        Write-MonitorLog "Stopping monitor process PID '$monitorPid'..."
                        Stop-Process -Id $monitorPid -Force -ErrorAction Stop
                    }
                }
                else {
                    Write-MonitorLog "Rollback running in monitor process '$monitorPid'; no external stop needed."
                }
            }
            else {
                Write-MonitorLog "PID file exists but PID '$monitorPid' is not running."
            }
        }
        catch {
            Write-MonitorLog "Error stopping monitor process: $_" -Level Error
        }
    }

    Restore-OriginalState

    if ($DryRun) {
        Write-MonitorLog "[DRY-RUN] Would remove PID and state files."
    }
    else {
        Remove-Item $script:Config.PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item $script:Config.StateFile -Force -ErrorAction SilentlyContinue
        Write-MonitorLog "Rollback complete; state files removed."
    }
}

function Start-MonitorLoop {
    Write-MonitorLog "Monitor loop started; checking application pools every $($script:Config.CheckIntervalSeconds) seconds."
    
    while ($true) {
        try {
            Invoke-HealthCheck
        }
        catch {
            Write-MonitorLog "Error in monitor loop: $_" -Level Error
        }
        
        Start-Sleep -Seconds $script:Config.CheckIntervalSeconds
    }
}

function Invoke-LoopInternal {
    Initialize-LogPaths
    Set-Content -Path $script:Config.PidFile -Value $PID -Force
    
    # Register cleanup on exit
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        $rollbackScript = {
            param($StateFile, $PidFile, $LogFile)
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
            Add-Content -Path $LogFile -Value "$timestamp | [Info] Monitor exiting; performing rollback..."
        }
        Start-Job -ScriptBlock $rollbackScript -ArgumentList $script:Config.StateFile, $script:Config.PidFile, $script:Config.LogFile | Wait-Job | Remove-Job
    }

    # Handle Ctrl+C gracefully
    try {
        Start-MonitorLoop
    }
    finally {
        Invoke-Rollback -Reason 'daemon signal'
        Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    }
}

function Start-Daemon {
    Initialize-LogPaths

    if (Test-MonitorRunning) {
        $existingPid = Get-Content $script:Config.PidFile -Raw
        Write-MonitorLog "Monitor already running with PID '$($existingPid.Trim())'. Idempotent start skipped."
        return
    }

    Save-OriginalState

    if ($DryRun) {
        Write-MonitorLog "[DRY-RUN] Would start monitor daemon in background."
        return
    }

    # Start background job
    $scriptPath = $PSCommandPath
    $jobScript = {
        param($ScriptPath)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -RunLoopInternal
    }

    $job = Start-Job -ScriptBlock $jobScript -ArgumentList $scriptPath
    
    # Give it a moment to start
    Start-Sleep -Milliseconds 500
    
    # The actual PID will be written by the child process
    # For now, just confirm job started
    if ($job.State -eq 'Running') {
        Write-MonitorLog "Monitor daemon started (Job ID: $($job.Id))."
        Write-MonitorLog "Background process will write PID to '$($script:Config.PidFile)' when ready."
    }
    else {
        Write-MonitorLog "Failed to start monitor daemon." -Level Error
    }
}

function Invoke-Once {
    Initialize-LogPaths

    # If daemon is already running, skip
    if (Test-MonitorRunning) {
        Write-MonitorLog "Monitor daemon already running. Skipping single-run check."
        return
    }

    # Try to acquire lock
    if (-not (Lock-Monitor)) {
        Write-MonitorLog "Another --once instance is running. Skipping this check."
        return
    }

    try {
        Save-OriginalState
        Invoke-HealthCheck
    }
    catch {
        Write-MonitorLog "Single-run check failed: $_" -Level Error
        Invoke-Rollback -Reason 'once mode failed'
    }
    finally {
        Unlock-Monitor
        Remove-Item $script:Config.StateFile -Force -ErrorAction SilentlyContinue
        Write-MonitorLog "Single-run check completed."
    }
}

function Show-Status {
    if (Test-MonitorRunning) {
        $pid = (Get-Content $script:Config.PidFile -Raw).Trim()
        Write-Host "running (pid: $pid)"
    }
    else {
        Write-Host "not running"
    }
}

#endregion

#region Main Execution

# Handle internal loop mode (called by background job)
if ($RunLoopInternal) {
    Invoke-LoopInternal
    exit 0
}

# Execute based on mode
switch ($Mode) {
    'Daemon' {
        Start-Daemon
    }
    'Once' {
        Invoke-Once
    }
    'Rollback' {
        Initialize-LogPaths
        Invoke-Rollback -Reason 'manual request'
    }
    'Status' {
        Show-Status
    }
    default {
        Write-Error "Invalid mode: $Mode"
        exit 1
    }
}

#endregion

# ops.ps1 -- WorkstationOps CLI for Windows
# Usage: .\ops <command> [options]

param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1)][string]$SubCommand,
    [Parameter(ValueFromRemainingArguments)][string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
$OpsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\wsl-backup.conf.ps1")

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-LatestExport {
    if (-not (Test-Path $BACKUP_DEST)) { return $null }
    return Get-ChildItem -Path $BACKUP_DEST -Filter "wsl-ubuntu-*.tar" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
}

function Get-BackupPending {
    $flag = Join-Path $OpsRoot "logs\backup-pending"
    return Test-Path $flag
}

# ── Commands ─────────────────────────────────────────────────────────────────

function Invoke-Status {
    $brief = $ExtraArgs -contains "--brief"

    # Drive status
    $driveOk = Test-DriveAvailable $BACKUP_DRIVE

    # Last backup
    $latest = Get-LatestExport
    $pending = Get-BackupPending

    # Scheduled task
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue

    if ($brief) {
        # Single-line status for prompt integration
        if (-not $driveOk) {
            Write-Host "WSL-BACKUP: drive-offline" -ForegroundColor Red
        } elseif ($pending) {
            Write-Host "WSL-BACKUP: OVERDUE" -ForegroundColor Yellow
        } elseif ($latest) {
            $age = (Get-Date) - $latest.LastWriteTime
            $ageStr = if ($age.TotalDays -ge 1) { "$([int]$age.TotalDays)d ago" } else { "today" }
            Write-Host "WSL-BACKUP: ok ($ageStr)" -ForegroundColor Green
        } else {
            Write-Host "WSL-BACKUP: never" -ForegroundColor Yellow
        }
        return
    }

    Write-Host ""
    Write-Host "  WorkstationOps -- WSL Backup Status" -ForegroundColor Cyan
    Write-Host "  ====================================" -ForegroundColor Cyan
    Write-Host ""

    # Drive
    if ($driveOk) {
        Write-Host "  Backup drive ($BACKUP_DRIVE):" -NoNewline
        Write-Host " Available" -ForegroundColor Green
    } else {
        Write-Host "  Backup drive ($BACKUP_DRIVE):" -NoNewline
        Write-Host " NOT AVAILABLE" -ForegroundColor Red
    }

    # Last backup
    if ($latest) {
        $age = (Get-Date) - $latest.LastWriteTime
        $ageStr = Get-HumanDuration $age
        $sizeStr = Get-HumanSize $latest.Length
        $backupInfo = $latest.Name + " (" + $sizeStr + ", " + $ageStr + " ago)"
        Write-Host "  Last backup:          " -NoNewline
        if ($age.TotalDays -gt 45) {
            Write-Host $backupInfo -ForegroundColor Yellow
        } else {
            Write-Host $backupInfo -ForegroundColor Green
        }
    } else {
        Write-Host "  Last backup:          " -NoNewline
        Write-Host "Never" -ForegroundColor Yellow
    }

    # Pending flag
    if ($pending) {
        Write-Host "  Backup status:        " -NoNewline
        Write-Host "OVERDUE -- run '.\ops run backup'" -ForegroundColor Yellow
    } else {
        Write-Host "  Backup status:        " -NoNewline
        Write-Host "OK" -ForegroundColor Green
    }

    # Scheduled task
    if ($task) {
        $state = $task.State
        Write-Host "  Scheduled task:       " -NoNewline
        if ($state -eq "Ready") {
            Write-Host "$TASK_NAME ($state)" -ForegroundColor Green
        } else {
            Write-Host "$TASK_NAME ($state)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Scheduled task:       " -NoNewline
        Write-Host "Not configured -- run '.\ops schedule'" -ForegroundColor Yellow
    }

    # Existing exports
    if ($driveOk -and (Test-Path $BACKUP_DEST)) {
        $exports = Get-ChildItem -Path $BACKUP_DEST -Filter "wsl-ubuntu-*.tar" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        if ($exports.Count -gt 0) {
            Write-Host ""
            Write-Host "  Exports in ${BACKUP_DEST}:" -ForegroundColor Cyan
            foreach ($e in $exports) {
                $s = Get-HumanSize $e.Length
                Write-Host "    $($e.Name)  ($s)"
            }
        }
    }

    Write-Host ""
}

function Invoke-Schedule {
    $opsScript = Join-Path $OpsRoot "ops.ps1"

    # Use Task Scheduler COM API (handles paths with spaces cleanly)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $folder = $svc.GetFolder('\')

    # Check if task already exists
    $verb = "Created"
    try { $folder.GetTask($TASK_NAME) | Out-Null; $verb = "Updated" } catch {}

    $taskDef = $svc.NewTask(0)
    $taskDef.RegistrationInfo.Description = "Monthly WSL distro export to network drive"
    $taskDef.Settings.Enabled = $true
    $taskDef.Settings.AllowDemandStart = $true
    $taskDef.Settings.StartWhenAvailable = $true
    $taskDef.Settings.DisallowStartIfOnBatteries = $false
    $taskDef.Settings.StopIfGoingOnBatteries = $false
    $taskDef.Settings.ExecutionTimeLimit = "P3D"

    # Monthly trigger: 1st of each month
    $trigger = $taskDef.Triggers.Create(4)  # 4 = TASK_TRIGGER_MONTHLY
    $trigger.DaysOfMonth = 1
    $trigger.MonthsOfYear = 4095  # all 12 months (bitmask: 0xFFF)
    $trigger.StartBoundary = (Get-Date -Hour ([int]$TASK_TIME.Split(':')[0]) -Minute ([int]$TASK_TIME.Split(':')[1]) -Second 0).ToString("yyyy-MM-ddTHH:mm:ss")

    # Action: run ops.ps1 with backup --scheduled
    $action = $taskDef.Actions.Create(0)  # 0 = TASK_ACTION_EXEC
    $action.Path = "powershell.exe"
    $action.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$opsScript`" run backup --scheduled"
    $action.WorkingDirectory = $OpsRoot

    # Register (6 = create or update, 3 = interactive logon only)
    $folder.RegisterTaskDefinition($TASK_NAME, $taskDef, 6, $null, $null, 3) | Out-Null

    Write-Host "$verb scheduled task '$TASK_NAME'." -ForegroundColor Green
    Write-Host "  Schedule: 1st of each month at $TASK_TIME"
    Write-Host "  Verify in Task Scheduler (taskschd.msc) under '$TASK_NAME'"
}

function Invoke-Unschedule {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $folder = $svc.GetFolder('\')

    try {
        $folder.GetTask($TASK_NAME) | Out-Null
        $folder.DeleteTask($TASK_NAME, 0)
        Write-Host "Removed scheduled task '$TASK_NAME'." -ForegroundColor Green
    } catch {
        Write-Host "Scheduled task '$TASK_NAME' does not exist." -ForegroundColor Yellow
    }
}

function Invoke-RunBackup {
    $backupScript = Join-Path $OpsRoot "backups\wsl-backup.ps1"
    $scriptArgs = @{}

    if ($ExtraArgs -contains "--scheduled") { $scriptArgs['Scheduled'] = $true }
    if ($ExtraArgs -contains "--force")     { $scriptArgs['Force'] = $true }
    if ($ExtraArgs -contains "--dry-run")   { $scriptArgs['DryRun'] = $true }

    & $backupScript @scriptArgs
}

function Invoke-Logs {
    $n = 50
    if ($SubCommand -and $SubCommand -match '^\d+$') {
        $n = [int]$SubCommand
    } elseif ($ExtraArgs.Count -gt 0 -and $ExtraArgs[0] -match '^\d+$') {
        $n = [int]$ExtraArgs[0]
    }

    $logDir = Join-Path $OpsRoot "logs"
    $latest = Get-ChildItem -Path $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $latest) {
        Write-Host "No log files found." -ForegroundColor Yellow
        return
    }

    Write-Host "--- $($latest.Name) (last $n lines) ---" -ForegroundColor Cyan
    Get-Content $latest.FullName -Tail $n
}

function Invoke-Verify {
    Write-Host ""
    Write-Host "  WorkstationOps -- Pre-flight Checks" -ForegroundColor Cyan
    Write-Host "  ====================================" -ForegroundColor Cyan
    Write-Host ""

    $allOk = $true

    # wsl.exe
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        Write-Host "  [PASS] wsl.exe found: $($wsl.Source)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] wsl.exe not found in PATH" -ForegroundColor Red
        $allOk = $false
    }

    # Distro registered
    if ($wsl) {
        $distros = wsl.exe -l -q 2>&1 | ForEach-Object { $_.Trim("`0", " ", "`r", "`n") } | Where-Object { $_ -ne "" }
        if ($distros -contains $DISTRO_NAME) {
            Write-Host "  [PASS] Distro '$DISTRO_NAME' is registered" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Distro '$DISTRO_NAME' not found. Available: $($distros -join ', ')" -ForegroundColor Red
            $allOk = $false
        }
    }

    # Backup drive
    if (Test-DriveAvailable $BACKUP_DRIVE) {
        Write-Host "  [PASS] Backup drive $BACKUP_DRIVE is available" -ForegroundColor Green

        # Check destination dir
        if (Test-Path $BACKUP_DEST) {
            Write-Host "  [PASS] Backup destination exists: $BACKUP_DEST" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Backup destination does not exist yet: $BACKUP_DEST (will be created)" -ForegroundColor Yellow
        }

        # Free space
        $driveLetter = $BACKUP_DRIVE.TrimEnd('\', ':')
        $disk = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
        if ($disk -and $disk.Free) {
            $freeGB = [math]::Round($disk.Free / 1GB, 1)
            if ($freeGB -ge 50) {
                Write-Host "  [PASS] Free space on ${BACKUP_DRIVE}: ${freeGB} GB" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Free space on ${BACKUP_DRIVE}: ${freeGB} GB (< 50 GB)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  [FAIL] Backup drive $BACKUP_DRIVE is not available" -ForegroundColor Red
        $allOk = $false
    }

    # Task Scheduler
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host "  [PASS] Scheduled task '$TASK_NAME' exists (State: $($task.State))" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Scheduled task '$TASK_NAME' not found. Run '.\ops schedule' to create." -ForegroundColor Yellow
    }

    # PowerShell version
    $psVer = $PSVersionTable.PSVersion
    Write-Host "  [INFO] PowerShell version: $psVer" -ForegroundColor Cyan

    Write-Host ""
    if ($allOk) {
        Write-Host "  All checks passed." -ForegroundColor Green
    } else {
        Write-Host "  Some checks failed. See above." -ForegroundColor Red
    }
    Write-Host ""
}

function Invoke-Help {
    Write-Host @"

  WorkstationOps -- Windows WSL Backup CLI
  ========================================

  Usage: .\ops <command> [options]

  Commands:
    status [--brief]          Show backup status, drive state, schedule
    verify                    Run pre-flight checks
    schedule                  Create/update monthly Task Scheduler job
    unschedule                Remove Task Scheduler job
    run backup [options]      Run WSL backup
        --force               Terminate WSL without prompting
        --dry-run             Show what would happen without doing it
        --scheduled           Non-interactive mode (for Task Scheduler)
    logs [N]                  Show last N lines of latest log (default 50)
    help                      Show this help message

  Configuration: config\wsl-backup.conf.ps1
  Logs:          logs\

"@
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

switch ($Command) {
    "status"      { Invoke-Status }
    "schedule"    { Invoke-Schedule }
    "unschedule"  { Invoke-Unschedule }
    "run"         {
        switch ($SubCommand) {
            "backup" { Invoke-RunBackup }
            default  {
                Write-Host "Unknown run target: '$SubCommand'. Try: .\ops run backup" -ForegroundColor Red
            }
        }
    }
    "logs"        { Invoke-Logs }
    "verify"      { Invoke-Verify }
    "help"        { Invoke-Help }
    "--help"      { Invoke-Help }
    ""            { Invoke-Help }
    default       {
        Write-Host "Unknown command: '$Command'. Run '.\ops help' for usage." -ForegroundColor Red
        exit 1
    }
}

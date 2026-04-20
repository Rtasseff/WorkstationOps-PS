# wsl-backup.ps1 -- WSL distro export operation
# Dot-sourced by ops.ps1. Exposes Op-Run / Op-Status / Op-Verify / Op-ScheduleSpec.

$OpName        = "wsl-backup"
$OpLabel       = "WSL Backup"
$OpDescription = "Monthly WSL distro export to network drive"

# $OpsRoot is set by ops.ps1 before dot-sourcing. Fall back for standalone dot-sourcing.
if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\wsl-backup.conf.ps1")

# -- Helpers (op-internal) ----------------------------------------------------

function Get-WslPendingPath {
    # New canonical path; legacy "backup-pending" also recognized for one cycle.
    return (Join-Path $OpsRoot "logs\wsl-backup.pending")
}

function Get-WslPendingLegacyPath {
    return (Join-Path $OpsRoot "logs\backup-pending")
}

function Test-WslPending {
    return (Test-Path (Get-WslPendingPath)) -or (Test-Path (Get-WslPendingLegacyPath))
}

function Get-WslPendingReason {
    $new = Get-WslPendingPath
    $old = Get-WslPendingLegacyPath
    $path = if (Test-Path $new) { $new } elseif (Test-Path $old) { $old } else { $null }
    if (-not $path) { return $null }
    $reason = (Get-Content $path -ErrorAction SilentlyContinue) -join ''
    if (-not $reason) { return "unknown" }
    return $reason.Trim()
}

function Clear-WslPending {
    foreach ($p in @((Get-WslPendingPath), (Get-WslPendingLegacyPath))) {
        if (Test-Path $p) { Remove-Item $p -Force }
    }
}

function Set-WslPending {
    param([Parameter(Mandatory)][string]$Reason)
    $Reason | Out-File -FilePath (Get-WslPendingPath) -Encoding utf8
}

function Get-WslLatestExport {
    if (-not (Test-Path $BACKUP_DEST)) { return $null }
    return Get-ChildItem -Path $BACKUP_DEST -Filter "wsl-ubuntu-*.tar" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
}

# -- Op-Status ----------------------------------------------------------------

function Op-Status {
    $driveOk = Test-DriveAvailable $BACKUP_DRIVE
    $latest  = Get-WslLatestExport
    $pending = Test-WslPending
    $task    = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue

    # Brief one-liner
    $brief = if (-not $driveOk) {
        "${OpName}: drive-offline"
    } elseif ($pending) {
        "${OpName}: OVERDUE"
    } elseif ($latest) {
        $age = (Get-Date) - $latest.LastWriteTime
        $ageStr = if ($age.TotalDays -ge 1) { "$([int]$age.TotalDays)d ago" } else { "today" }
        "${OpName}: ok ($ageStr)"
    } else {
        "${OpName}: never"
    }

    $lines = New-Object System.Collections.Generic.List[string]

    if ($driveOk) {
        $lines.Add("Backup drive ($BACKUP_DRIVE):  Available")
    } else {
        $lines.Add("Backup drive ($BACKUP_DRIVE):  NOT AVAILABLE")
    }

    if ($latest) {
        $age = (Get-Date) - $latest.LastWriteTime
        $ageStr = Get-HumanDuration $age
        $sizeStr = Get-HumanSize $latest.Length
        $lines.Add("Last backup:           $($latest.Name) ($sizeStr, $ageStr ago)")
    } else {
        $lines.Add("Last backup:           Never")
    }

    if ($pending) {
        $reason = Get-WslPendingReason
        $lines.Add("Backup status:         OVERDUE ($reason) -- run '.\ops run $OpName'")
    } else {
        $lines.Add("Backup status:         OK")
    }

    if ($task) {
        $lines.Add("Scheduled task:        $TASK_NAME ($($task.State))")
    } else {
        $lines.Add("Scheduled task:        Not configured -- run '.\ops schedule $OpName'")
    }

    if ($driveOk -and (Test-Path $BACKUP_DEST)) {
        $exports = Get-ChildItem -Path $BACKUP_DEST -Filter "wsl-ubuntu-*.tar" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        if ($exports.Count -gt 0) {
            $lines.Add("")
            $lines.Add("Exports in ${BACKUP_DEST}:")
            foreach ($e in $exports) {
                $s = Get-HumanSize $e.Length
                $lines.Add("  $($e.Name)  ($s)")
            }
        }
    }

    return @{
        Name    = $OpName
        Label   = $OpLabel
        Ok      = ($driveOk -and -not $pending)
        Pending = $pending
        Brief   = $brief
        Lines   = $lines.ToArray()
    }
}

# -- Op-Verify ----------------------------------------------------------------

function Op-Verify {
    $lines = New-Object System.Collections.Generic.List[string]
    $allOk = $true

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        $lines.Add("[PASS] wsl.exe found: $($wsl.Source)")
    } else {
        $lines.Add("[FAIL] wsl.exe not found in PATH")
        $allOk = $false
    }

    if ($wsl) {
        $distros = wsl.exe -l -q 2>&1 | ForEach-Object { $_.Trim("`0", " ", "`r", "`n") } | Where-Object { $_ -ne "" }
        if ($distros -contains $DISTRO_NAME) {
            $lines.Add("[PASS] Distro '$DISTRO_NAME' is registered")
        } else {
            $lines.Add("[FAIL] Distro '$DISTRO_NAME' not found. Available: $($distros -join ', ')")
            $allOk = $false
        }
    }

    if (Test-DriveAvailable $BACKUP_DRIVE) {
        $lines.Add("[PASS] Backup drive $BACKUP_DRIVE is available")

        if (Test-Path $BACKUP_DEST) {
            $lines.Add("[PASS] Backup destination exists: $BACKUP_DEST")
        } else {
            $lines.Add("[WARN] Backup destination does not exist yet: $BACKUP_DEST (will be created)")
        }

        $letter = $BACKUP_DRIVE.TrimEnd('\', ':')
        $disk = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
        if ($disk -and $disk.Free) {
            $freeGB = [math]::Round($disk.Free / 1GB, 1)
            if ($freeGB -ge 50) {
                $lines.Add("[PASS] Free space on ${BACKUP_DRIVE}: ${freeGB} GB")
            } else {
                $lines.Add("[WARN] Free space on ${BACKUP_DRIVE}: ${freeGB} GB (< 50 GB)")
            }
        }
    } else {
        $lines.Add("[FAIL] Backup drive $BACKUP_DRIVE is not available")
        $allOk = $false
    }

    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        $lines.Add("[PASS] Scheduled task '$TASK_NAME' exists (State: $($task.State))")
    } else {
        $lines.Add("[WARN] Scheduled task '$TASK_NAME' not found. Run '.\ops schedule $OpName' to create.")
    }

    return @{ Ok = $allOk; Lines = $lines.ToArray() }
}

# -- Op-ScheduleSpec ----------------------------------------------------------

function Op-ScheduleSpec {
    return @{
        TaskName    = $TASK_NAME
        Description = $OpDescription
        Trigger     = $TASK_SCHEDULE
        DayOfMonth  = 1
        Time        = $TASK_TIME
    }
}

# -- Op-Run -------------------------------------------------------------------

function Op-Run {
    param(
        [switch]$Scheduled,
        [switch]$Force,
        [switch]$DryRun
    )

    Initialize-Log -Name $OpName
    $startTime = Get-Date

    $pendingFlag = Get-WslPendingPath

    Write-Log -Level INFO -Message "=== WSL Backup Started ==="
    Write-Log -Level INFO -Message "Mode: $(if ($Scheduled) {'Scheduled'} elseif ($DryRun) {'Dry Run'} elseif ($Force) {'Force'} else {'Interactive'})"

    # -- Pre-flight checks ---------------------------------------------------

    $wslPath = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslPath) {
        Write-Log -Level ERROR -Message "wsl.exe not found in PATH"
        exit 1
    }

    $distros = wsl.exe -l -q 2>&1 | ForEach-Object { $_.Trim("`0", " ", "`r", "`n") } | Where-Object { $_ -ne "" }
    if ($distros -notcontains $DISTRO_NAME) {
        Write-Log -Level ERROR -Message "Distro '$DISTRO_NAME' is not registered. Available: $($distros -join ', ')"
        exit 1
    }

    if (-not (Test-DriveAvailable $BACKUP_DRIVE)) {
        Write-Log -Level WARN -Message "Backup drive $BACKUP_DRIVE is not available. Skipping backup."
        if ($Scheduled) {
            Set-WslPending -Reason "drive-unavailable"
        }
        exit 0
    }

    if (-not $DryRun) {
        Ensure-Directory $BACKUP_DEST
    }

    # -- Lock ----------------------------------------------------------------

    if (-not $DryRun) {
        $gotLock = Get-Lock -Name $OpName
        if (-not $gotLock) {
            Write-Log -Level ERROR -Message "Could not acquire lock. Another backup may be running."
            exit 1
        }
    }

    try {

    # -- Check if WSL is running ---------------------------------------------

    $runningRaw = wsl.exe -l --running 2>&1
    $runningText = ($runningRaw | ForEach-Object { $_.Trim("`0", " ", "`r", "`n") }) -join "`n"
    $distroRunning = $runningText -match [regex]::Escape($DISTRO_NAME)

    if ($distroRunning) {
        Write-Log -Level INFO -Message "WSL distro '$DISTRO_NAME' is currently running."

        if ($Scheduled) {
            Write-Log -Level WARN -Message "Scheduled mode: WSL is running. Setting backup-pending flag."
            Set-WslPending -Reason "wsl-running"
            Send-Notification -Title "WSL Backup Overdue" -Message "WSL is running. Run '.\ops run $OpName' when convenient."
            Write-Log -Level INFO -Message "=== WSL Backup Deferred ==="
            exit 0
        }

        if ($DryRun) {
            Write-Log -Level INFO -Message "[DRY RUN] Would prompt to terminate WSL '$DISTRO_NAME'"
        } elseif (-not $Force) {
            $response = Read-Host "WSL '$DISTRO_NAME' is running. Terminate and export? [Y/n]"
            if ($response -and $response -notmatch '^[Yy]') {
                Write-Log -Level INFO -Message "User cancelled. Backup aborted."
                exit 0
            }
        }

        if (-not $DryRun) {
            Write-Log -Level INFO -Message "Terminating WSL distro '$DISTRO_NAME'..."
            wsl.exe --terminate $DISTRO_NAME
            $retries = 0
            do {
                Start-Sleep -Seconds 2
                $retries++
                $checkRaw = wsl.exe -l --running 2>&1
                $checkText = ($checkRaw | ForEach-Object { $_.Trim("`0", " ", "`r", "`n") }) -join "`n"
                $stillRunning = $checkText -match [regex]::Escape($DISTRO_NAME)
            } while ($stillRunning -and $retries -lt 15)

            if ($stillRunning) {
                Write-Log -Level ERROR -Message "WSL distro '$DISTRO_NAME' did not shut down after 30 seconds."
                exit 1
            }
            Write-Log -Level OK -Message "WSL distro '$DISTRO_NAME' terminated successfully."
        } else {
            Write-Log -Level INFO -Message "[DRY RUN] Would terminate WSL '$DISTRO_NAME'"
        }
    } else {
        Write-Log -Level INFO -Message "WSL distro '$DISTRO_NAME' is not running. Proceeding with export."
    }

    # -- Disk space check ----------------------------------------------------

    $driveLetter = $BACKUP_DRIVE.TrimEnd('\')
    $disk = Get-PSDrive -Name $driveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($disk -and $disk.Free) {
        $freeGB = [math]::Round($disk.Free / 1GB, 1)
        Write-Log -Level INFO -Message "Free space on ${driveLetter}: ${freeGB} GB"
        if ($disk.Free -lt 50GB) {
            Write-Log -Level WARN -Message "Less than 50 GB free on $driveLetter -- export may fail if distro is large."
        }
    } else {
        Write-Log -Level WARN -Message "Could not determine free space on $driveLetter"
    }

    # -- Export --------------------------------------------------------------

    $date = Get-Date -Format "yyyy-MM-dd"
    $exportFile = Join-Path $BACKUP_DEST "wsl-ubuntu-$date.tar"

    if ($DryRun) {
        Write-Log -Level INFO -Message "[DRY RUN] Would export '$DISTRO_NAME' to: $exportFile"
        Write-Log -Level INFO -Message "[DRY RUN] Would clean up old exports (keeping $BACKUP_RETENTION most recent)"
        Write-Log -Level INFO -Message "[DRY RUN] Would rotate logs older than $LOG_RETENTION_DAYS days"
        Write-Log -Level INFO -Message "=== WSL Backup Dry Run Complete ==="
        exit 0
    }

    Write-Log -Level INFO -Message "Exporting '$DISTRO_NAME' to: $exportFile"
    Write-Log -Level INFO -Message "This may take a while (10-30+ minutes depending on distro size)..."

    $exportStart = Get-Date
    try {
        wsl.exe --export $DISTRO_NAME $exportFile
        if ($LASTEXITCODE -ne 0) {
            throw "wsl --export exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Log -Level ERROR -Message "Export failed: $_"
        exit 1
    }
    $exportDuration = (Get-Date) - $exportStart

    # -- Verify export -------------------------------------------------------

    if (-not (Test-Path $exportFile)) {
        Write-Log -Level ERROR -Message "Export file not found at: $exportFile"
        exit 1
    }

    $fileSize = (Get-Item $exportFile).Length
    $humanSize = Get-HumanSize $fileSize

    if ($fileSize -lt 1GB) {
        Write-Log -Level WARN -Message "Export file is smaller than expected ($(Get-HumanSize $fileSize)). Verify integrity."
    } else {
        Write-Log -Level OK -Message "Export verified: $humanSize"
    }

    # -- Cleanup old exports -------------------------------------------------

    $exports = Get-ChildItem -Path $BACKUP_DEST -Filter "wsl-ubuntu-*.tar" | Sort-Object Name -Descending
    if ($exports.Count -gt $BACKUP_RETENTION) {
        $toDelete = $exports | Select-Object -Skip $BACKUP_RETENTION
        foreach ($old in $toDelete) {
            Write-Log -Level INFO -Message "Removing old export: $($old.Name) ($(Get-HumanSize $old.Length))"
            Remove-Item $old.FullName -Force
        }
    }

    # -- Remove pending flag (covers both legacy and new paths) -------------

    if (Test-WslPending) {
        Clear-WslPending
        Write-Log -Level INFO -Message "Cleared backup-pending flag."
    }

    # -- Log rotation --------------------------------------------------------

    Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS

    # -- Summary -------------------------------------------------------------

    $totalDuration = (Get-Date) - $startTime
    Write-Log -Level OK -Message "=== WSL Backup Complete ==="
    Write-Log -Level OK -Message "File: $exportFile"
    Write-Log -Level OK -Message "Size: $humanSize"
    Write-Log -Level OK -Message "Export time: $(Get-HumanDuration $exportDuration)"
    Write-Log -Level OK -Message "Total time: $(Get-HumanDuration $totalDuration)"

    # -- Restart WSL ---------------------------------------------------------

    if ($Scheduled) {
        Write-Log -Level INFO -Message "Auto-restarting WSL distro '$DISTRO_NAME'..."
        wsl.exe -d $DISTRO_NAME -- echo "WSL restarted by WorkstationOps backup" *>$null
        Write-Log -Level OK -Message "WSL distro '$DISTRO_NAME' restarted."
    } else {
        $restart = Read-Host "Restart WSL '$DISTRO_NAME' now? [Y/n]"
        if (-not $restart -or $restart -match '^[Yy]') {
            Write-Log -Level INFO -Message "Restarting WSL distro '$DISTRO_NAME'..."
            wsl.exe -d $DISTRO_NAME -- echo "WSL restarted by WorkstationOps backup" *>$null
            Write-Log -Level OK -Message "WSL distro '$DISTRO_NAME' restarted."
        }
    }

    } finally {
        if (-not $DryRun) {
            Release-Lock -Name $OpName
        }
    }
}

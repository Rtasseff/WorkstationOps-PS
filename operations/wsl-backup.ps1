# wsl-backup.ps1 -- WSL distro export operation
# Dot-sourced by ops.ps1. Exposes Op-Run / Op-Status / Op-Verify / Op-ScheduleSpec.

$OpName        = "wsl-backup"
$OpLabel       = "WSL Backup"
$OpDescription = "Monthly WSL distro export to local D: drive"

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

function Test-WslBackupDue {
    # True from the 1st of a month at $TASK_TIME until an export dated in that month
    # exists. The task fires daily, so this is what keeps the cadence monthly. A
    # missing export, or a name that cannot be dated, counts as due.
    param([datetime]$Now = (Get-Date))

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $fireText = "{0}-01 {1}" -f $Now.ToString('yyyy-MM', $culture), $TASK_TIME
    $fireAt = [datetime]::ParseExact($fireText, 'yyyy-MM-dd HH:mm', $culture)
    $dueMonth = if ($Now -lt $fireAt) { $fireAt.Date.AddMonths(-1) } else { $fireAt.Date }

    $latest = Get-WslLatestExport
    if (-not $latest -or $latest.Name -notmatch '^wsl-ubuntu-(\d{4}-\d{2}-\d{2})\.tar$') {
        return $true
    }
    return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $culture) -lt $dueMonth
}

function Get-WslListLines {
    # wsl.exe writes UTF-16 when piped and PS 5.1 reads it through the console code
    # page, leaving a NUL after every character. Regex matches then fail silently,
    # which is how this op once lost a running distro: strip NULs before any parsing.
    param([Parameter(Mandatory)][string[]]$Arguments)

    $savedUtf8 = $env:WSL_UTF8
    $env:WSL_UTF8 = "1"
    try {
        $raw = & wsl.exe @Arguments 2>&1
        return @($raw | ForEach-Object { (([string]$_) -replace "`0", '').Trim() } | Where-Object { $_ -ne '' })
    } catch {
        return @()
    } finally {
        $env:WSL_UTF8 = $savedUtf8
    }
}

function ConvertFrom-WslVerboseList {
    # Reads one distro's STATE from 'wsl -l -v' rows such as "* Ubuntu  Running  2".
    # Returns 'Unknown' when no row parses. Callers must treat every value except
    # 'Stopped' as unsafe to export, so a surprise format can never stop a distro.
    param(
        [string[]]$Lines,
        [Parameter(Mandatory)][string]$Distro
    )
    $pattern = '^\s*\*?\s*' + [regex]::Escape($Distro) + '\s+(\S+)\s+\d+\s*$'
    foreach ($line in $Lines) {
        if ((([string]$line) -replace "`0", '') -match $pattern) { return $Matches[1] }
    }
    return 'Unknown'
}

function Get-WslDistroState {
    return ConvertFrom-WslVerboseList -Lines (Get-WslListLines -Arguments @('-l', '-v')) -Distro $DISTRO_NAME
}

function Get-WslDeferReason {
    param([Parameter(Mandatory)][string]$State)
    if ($State -eq 'Running') { return "wsl-running" }
    return "wsl-state-$($State.ToLowerInvariant())"
}

function Get-WslGpuLoad {
    # Read from Windows: inside WSL, nvidia-smi --query-compute-apps lists nothing
    # even during training. Utilization dips between epochs, so use the peak of a few
    # samples. If the GPU cannot be read, report it as busy.
    param([int]$Samples = 3)

    $peak = -1
    $memory = ''
    try {
        for ($i = 0; $i -lt $Samples; $i++) {
            if ($i -gt 0) { Start-Sleep -Seconds 1 }
            $rows = & nvidia-smi.exe --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null
            foreach ($row in @($rows)) {
                $fields = ([string]$row) -split ',\s*'
                $peak = [math]::Max($peak, [int]$fields[0])
                $memory = "$([int]$fields[1]) of $([int]$fields[2]) MiB in use"
            }
        }
    } catch {
        $peak = -1
    }

    if ($peak -lt 0) {
        return @{ Known = $false; Busy = $true; Text = "GPU: could not read nvidia-smi, treating as busy." }
    }
    return @{
        Known = $true
        Busy  = ($peak -ge $GPU_BUSY_PERCENT)
        Text  = "GPU: peak ${peak}% utilization, $memory."
    }
}

function Confirm-WslStopForExport {
    # True only on an explicit yes. Enter, or a closed stdin, means no.
    param([Parameter(Mandatory)][string]$State)

    $gpu = Get-WslGpuLoad
    Write-Log -Level INFO -Message "Asking before stopping WSL. $($gpu.Text)"

    Write-Host ""
    Write-Host "  WSL '$DISTRO_NAME' is $State. The export stops it for about 15 minutes." -ForegroundColor Yellow
    Write-Host "  Everything inside it dies: training and other jobs (queues do not resume"
    Write-Host "  on their own), the tunnels' targets, the model service, and the XNAT and"
    Write-Host "  OMERO containers."
    Write-Host "  $($gpu.Text)"
    Write-Host ""

    if ($gpu.Busy) {
        $response = Read-Host "GPU looks busy. Type '$DISTRO_NAME' to stop WSL anyway, anything else cancels"
        return ($response -ceq $DISTRO_NAME)
    }
    $response = Read-Host "Stop WSL and export? [y/N]"
    return ($response -match '^[Yy]')
}

function Exit-WslRunWithReminder {
    # How a run ends when no new export was made: nothing further is stopped, the
    # overdue flag is set, and the tray reminder fires. Daily runs repeat this until
    # an export succeeds.
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Detail,
        [int]$ExitCode = 0,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-Log -Level INFO -Message "[DRY RUN] Would set overdue flag ($Reason) and remind: $Detail"
        Write-Log -Level INFO -Message "=== WSL Backup Dry Run Complete ==="
        exit $ExitCode
    }

    Write-Log -Level WARN -Message "$Detail Setting overdue flag ($Reason)."
    Set-WslPending -Reason $Reason
    Send-Notification -Title "WSL Backup Overdue" -Message "$Detail Run '.\ops run $OpName' when convenient."
    Write-Log -Level INFO -Message "=== WSL Backup Deferred ==="
    exit $ExitCode
}

# -- Op-Status ----------------------------------------------------------------

function Op-Status {
    $driveOk = Test-DriveAvailable $BACKUP_DRIVE
    $latest  = Get-WslLatestExport
    $flagged = Test-WslPending
    # Judge by the exports as well as the flag, so a task that never fired still shows.
    $pending = $flagged -or (Test-WslBackupDue)
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
        $reason = if ($flagged) { Get-WslPendingReason } else { "no export yet this month" }
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
        $distros = Get-WslListLines -Arguments @('-l', '-q')
        if ($distros -contains $DISTRO_NAME) {
            $lines.Add("[PASS] Distro '$DISTRO_NAME' is registered")
        } else {
            $lines.Add("[FAIL] Distro '$DISTRO_NAME' not found. Available: $($distros -join ', ')")
            $allOk = $false
        }

        $state = Get-WslDistroState
        if ($state -eq 'Unknown') {
            $lines.Add("[FAIL] Could not read the state of '$DISTRO_NAME'. Scheduled runs will only remind, never export.")
            $allOk = $false
        } else {
            $lines.Add("[PASS] Distro state detected: $state (scheduled export runs only when Stopped)")
        }
    }

    $gpu = Get-WslGpuLoad -Samples 1
    if ($gpu.Known) {
        $lines.Add("[PASS] $($gpu.Text)")
    } else {
        $lines.Add("[WARN] $($gpu.Text) Manual runs will require typing the distro name.")
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
        Description = "$OpDescription. Checks daily; exports only if due and WSL is stopped, otherwise reminds."
        Trigger     = $TASK_SCHEDULE
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

    # The task fires daily so the reminder repeats. Leave before touching WSL when
    # this month's export already exists.
    if ($Scheduled -and -not (Test-WslBackupDue)) {
        $latest = Get-WslLatestExport
        Write-Log -Level INFO -Message "Not due. Latest export: $($latest.Name)"
        exit 0
    }

    Write-Log -Level INFO -Message "=== WSL Backup Started ==="
    Write-Log -Level INFO -Message "Mode: $(if ($Scheduled) {'Scheduled'} elseif ($DryRun) {'Dry Run'} elseif ($Force) {'Force'} else {'Interactive'})"

    # -- Pre-flight checks ---------------------------------------------------

    $wslPath = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslPath) {
        Write-Log -Level ERROR -Message "wsl.exe not found in PATH"
        if ($Scheduled) {
            Exit-WslRunWithReminder -Reason "wsl-not-found" -Detail "wsl.exe was not found." -ExitCode 1 -DryRun:$DryRun
        }
        exit 1
    }

    $distros = Get-WslListLines -Arguments @('-l', '-q')
    if ($distros -notcontains $DISTRO_NAME) {
        Write-Log -Level ERROR -Message "Distro '$DISTRO_NAME' is not registered. Available: $($distros -join ', ')"
        if ($Scheduled) {
            Exit-WslRunWithReminder -Reason "distro-not-found" -Detail "Distro '$DISTRO_NAME' was not found." -ExitCode 1 -DryRun:$DryRun
        }
        exit 1
    }

    if (-not (Test-DriveAvailable $BACKUP_DRIVE)) {
        Write-Log -Level WARN -Message "Backup drive $BACKUP_DRIVE is not available. Skipping backup."
        if ($Scheduled) {
            Exit-WslRunWithReminder -Reason "drive-unavailable" -Detail "Backup drive $BACKUP_DRIVE is not available." -DryRun:$DryRun
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

    # -- Gate on the distro state --------------------------------------------
    # 'wsl --export' does not refuse a running distro: it stops it, and everything
    # inside dies. Only a positive 'Stopped' may proceed unasked. A scheduled run
    # never stops a distro in any other state, including one it cannot read.

    $state = Get-WslDistroState
    $stopApproved = $false

    if ($state -eq 'Stopped') {
        Write-Log -Level INFO -Message "WSL distro '$DISTRO_NAME' is stopped. Proceeding with export."
    } else {
        Write-Log -Level INFO -Message "WSL distro '$DISTRO_NAME' state: $state"

        if ($Scheduled) {
            Exit-WslRunWithReminder -Reason (Get-WslDeferReason $state) -Detail "WSL is $state, so nothing was stopped." -DryRun:$DryRun
        }

        if ($DryRun) {
            $gpu = Get-WslGpuLoad
            Write-Log -Level INFO -Message "[DRY RUN] Would ask before stopping WSL '$DISTRO_NAME'. $($gpu.Text)"
        } elseif ($Force) {
            $gpu = Get-WslGpuLoad
            Write-Log -Level WARN -Message "--force: stopping WSL '$DISTRO_NAME' without asking. $($gpu.Text)"
            $stopApproved = $true
        } else {
            if (-not (Confirm-WslStopForExport -State $state)) {
                Write-Log -Level INFO -Message "User cancelled. Backup aborted."
                exit 0
            }
            Write-Log -Level WARN -Message "User approved stopping WSL '$DISTRO_NAME'."
            $stopApproved = $true
        }
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
    # Written under a name the 'wsl-ubuntu-*.tar' scans cannot see and renamed only
    # once verified, so a failed export never counts as this month's backup and never
    # costs us the previous one.
    $partialFile = Join-Path $BACKUP_DEST "partial-wsl-ubuntu-$date.tar"

    if ($DryRun) {
        Write-Log -Level INFO -Message "[DRY RUN] Would export '$DISTRO_NAME' to: $exportFile"
        Write-Log -Level INFO -Message "[DRY RUN] Would clean up old exports (keeping $BACKUP_RETENTION most recent)"
        Write-Log -Level INFO -Message "[DRY RUN] Would rotate logs older than $LOG_RETENTION_DAYS days"
        Write-Log -Level INFO -Message "=== WSL Backup Dry Run Complete ==="
        exit 0
    }

    # Last gate. Any wsl.exe call starts a stopped distro, and the tunnel supervisors
    # make those calls on their own, so the 'Stopped' read above can be out of date.
    if (-not $stopApproved) {
        $state = Get-WslDistroState
        if ($state -ne 'Stopped') {
            if ($Scheduled) {
                Exit-WslRunWithReminder -Reason (Get-WslDeferReason $state) -Detail "WSL is $state, so nothing was stopped."
            }
            Write-Log -Level ERROR -Message "WSL '$DISTRO_NAME' is now $state. Nothing was stopped. Run this again to be asked."
            exit 1
        }
    }

    Get-ChildItem -Path $BACKUP_DEST -Filter "partial-wsl-ubuntu-*.tar" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log -Level INFO -Message "Removing leftover partial export: $($_.Name)"
        Remove-Item $_.FullName -Force
    }

    Write-Log -Level INFO -Message "Exporting '$DISTRO_NAME' to: $exportFile"
    Write-Log -Level INFO -Message "This may take a while (about 15 minutes at 110 GB, growing with the distro)..."

    $exportStart = Get-Date
    try {
        wsl.exe --export $DISTRO_NAME $partialFile
        if ($LASTEXITCODE -ne 0) {
            throw "wsl --export exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Log -Level ERROR -Message "Export failed: $_"
        Exit-WslRunWithReminder -Reason "export-failed" -Detail "The export failed. Previous exports were kept." -ExitCode 1
    }
    $exportDuration = (Get-Date) - $exportStart

    # -- Verify export -------------------------------------------------------

    if (-not (Test-Path $partialFile)) {
        Write-Log -Level ERROR -Message "Export file not found at: $partialFile"
        Exit-WslRunWithReminder -Reason "export-failed" -Detail "The export produced no file. Previous exports were kept." -ExitCode 1
    }

    $fileSize = (Get-Item $partialFile).Length
    $humanSize = Get-HumanSize $fileSize

    if ($fileSize -lt 1GB) {
        Write-Log -Level ERROR -Message "Export is smaller than expected ($humanSize). Kept for inspection: $partialFile"
        Exit-WslRunWithReminder -Reason "export-too-small" -Detail "The export was only $humanSize. Previous exports were kept." -ExitCode 1
    }

    Move-Item -LiteralPath $partialFile -Destination $exportFile -Force
    Write-Log -Level OK -Message "Export verified: $humanSize"

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

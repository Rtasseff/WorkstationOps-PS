# wsl-backup.ps1 -- WSL distro export engine
# Usage: .\backups\wsl-backup.ps1 [-Scheduled] [-Force] [-DryRun]

param(
    [switch]$Scheduled,   # Non-interactive (called by Task Scheduler)
    [switch]$Force,       # Skip confirmation prompt
    [switch]$DryRun       # Show what would happen without doing it
)

$ErrorActionPreference = "Stop"

# -- Bootstrap ----------------------------------------------------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OpsRoot   = Split-Path -Parent $ScriptDir

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\wsl-backup.conf.ps1")

Initialize-Log -Name "wsl-backup"
$startTime = Get-Date

$pendingFlag = Join-Path $OpsRoot "logs\backup-pending"

Write-Log -Level INFO -Message "=== WSL Backup Started ==="
Write-Log -Level INFO -Message "Mode: $(if ($Scheduled) {'Scheduled'} elseif ($DryRun) {'Dry Run'} elseif ($Force) {'Force'} else {'Interactive'})"

# -- Pre-flight checks -------------------------------------------------------

# Check wsl.exe exists
$wslPath = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslPath) {
    Write-Log -Level ERROR -Message "wsl.exe not found in PATH"
    exit 1
}

# Check distro is registered
$distros = wsl.exe -l -q 2>&1 | ForEach-Object { $_.Trim("`0", " ", "`r", "`n") } | Where-Object { $_ -ne "" }
if ($distros -notcontains $DISTRO_NAME) {
    Write-Log -Level ERROR -Message "Distro '$DISTRO_NAME' is not registered. Available: $($distros -join ', ')"
    exit 1
}

# Check K: drive
if (-not (Test-DriveAvailable $BACKUP_DRIVE)) {
    Write-Log -Level WARN -Message "Backup drive $BACKUP_DRIVE is not available. Skipping backup."
    if ($Scheduled) {
        "drive-unavailable" | Out-File -FilePath $pendingFlag -Encoding utf8
    }
    exit 0
}

# Ensure destination directory exists
if (-not $DryRun) {
    Ensure-Directory $BACKUP_DEST
}

# -- Lock ---------------------------------------------------------------------

if (-not $DryRun) {
    $gotLock = Get-Lock -Name "wsl-backup"
    if (-not $gotLock) {
        Write-Log -Level ERROR -Message "Could not acquire lock. Another backup may be running."
        exit 1
    }
}

try {

# -- Check if WSL is running -------------------------------------------------

$runningRaw = wsl.exe -l --running 2>&1
$runningText = ($runningRaw | ForEach-Object { $_.Trim("`0", " ", "`r", "`n") }) -join "`n"
$distroRunning = $runningText -match [regex]::Escape($DISTRO_NAME)

if ($distroRunning) {
    Write-Log -Level INFO -Message "WSL distro '$DISTRO_NAME' is currently running."

    if ($Scheduled) {
        # Non-interactive: don't kill WSL, just set pending flag and notify
        Write-Log -Level WARN -Message "Scheduled mode: WSL is running. Setting backup-pending flag."
        "wsl-running" | Out-File -FilePath $pendingFlag -Encoding utf8
        Send-Notification -Title "WSL Backup Overdue" -Message "WSL is running. Run '.\ops run backup' when convenient."
        Write-Log -Level INFO -Message "=== WSL Backup Deferred ==="
        exit 0
    }

    if ($DryRun) {
        Write-Log -Level INFO -Message "[DRY RUN] Would prompt to terminate WSL '$DISTRO_NAME'"
    } elseif (-not $Force) {
        # Interactive: ask user
        $response = Read-Host "WSL '$DISTRO_NAME' is running. Terminate and export? [Y/n]"
        if ($response -and $response -notmatch '^[Yy]') {
            Write-Log -Level INFO -Message "User cancelled. Backup aborted."
            exit 0
        }
    }

    # Terminate WSL
    if (-not $DryRun) {
        Write-Log -Level INFO -Message "Terminating WSL distro '$DISTRO_NAME'..."
        wsl.exe --terminate $DISTRO_NAME
        # Wait for shutdown confirmation
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

# -- Disk space check --------------------------------------------------------

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

# -- Export -------------------------------------------------------------------

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

# -- Verify export ------------------------------------------------------------

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

# -- Cleanup old exports -----------------------------------------------------

$exports = Get-ChildItem -Path $BACKUP_DEST -Filter "wsl-ubuntu-*.tar" | Sort-Object Name -Descending
if ($exports.Count -gt $BACKUP_RETENTION) {
    $toDelete = $exports | Select-Object -Skip $BACKUP_RETENTION
    foreach ($old in $toDelete) {
        Write-Log -Level INFO -Message "Removing old export: $($old.Name) ($(Get-HumanSize $old.Length))"
        Remove-Item $old.FullName -Force
    }
}

# -- Remove pending flag -----------------------------------------------------

if (Test-Path $pendingFlag) {
    Remove-Item $pendingFlag -Force
    Write-Log -Level INFO -Message "Cleared backup-pending flag."
}

# -- Log rotation ------------------------------------------------------------

Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS

# -- Summary ------------------------------------------------------------------

$totalDuration = (Get-Date) - $startTime
Write-Log -Level OK -Message "=== WSL Backup Complete ==="
Write-Log -Level OK -Message "File: $exportFile"
Write-Log -Level OK -Message "Size: $humanSize"
Write-Log -Level OK -Message "Export time: $(Get-HumanDuration $exportDuration)"
Write-Log -Level OK -Message "Total time: $(Get-HumanDuration $totalDuration)"

# -- Restart WSL --------------------------------------------------------------

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
    # -- Release lock ---------------------------------------------------------
    if (-not $DryRun) {
        Release-Lock -Name "wsl-backup"
    }
}

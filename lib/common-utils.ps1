# common-utils.ps1 -- Shared utilities for WorkstationOps
# Dot-source this file: . "$PSScriptRoot\..\lib\common-utils.ps1"

$Script:OpsRoot = Split-Path -Parent $PSScriptRoot
if (-not $Script:OpsRoot) {
    $Script:OpsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

# -- Logging ------------------------------------------------------------------

$Script:LogFile = $null

function Initialize-Log {
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $logDir = Join-Path $Script:OpsRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $date = Get-Date -Format "yyyy-MM-dd"
    $Script:LogFile = Join-Path $logDir "$Name-$date.log"
}

function Write-Log {
    param(
        [ValidateSet("INFO","WARN","ERROR","OK")]
        [string]$Level = "INFO",
        [Parameter(Mandatory)][string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp [$Level] $Message"

    # Color-coded console output when interactive
    if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
        $color = switch ($Level) {
            "INFO"  { "Cyan" }
            "WARN"  { "Yellow" }
            "ERROR" { "Red" }
            "OK"    { "Green" }
        }
        Write-Host $line -ForegroundColor $color
    }

    # Append to log file if initialized
    if ($Script:LogFile) {
        $line | Out-File -FilePath $Script:LogFile -Append -Encoding utf8
    }
}

# -- Lock File ----------------------------------------------------------------

function Get-Lock {
    param(
        [string]$Name = "wsl-backup"
    )
    $lockFile = Join-Path $Script:OpsRoot "logs\$Name.lock"
    $logsDir = Join-Path $Script:OpsRoot "logs"
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

    if (Test-Path $lockFile) {
        $content = Get-Content $lockFile -ErrorAction SilentlyContinue
        if ($content) {
            $pid = [int]$content
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Log -Level ERROR -Message "Another instance is running (PID $pid). Lock file: $lockFile"
                return $false
            } else {
                Write-Log -Level WARN -Message "Removing stale lock file (PID $pid no longer running)"
                Remove-Item $lockFile -Force
            }
        } else {
            Remove-Item $lockFile -Force
        }
    }

    $PID | Out-File -FilePath $lockFile -Encoding utf8 -NoNewline
    return $true
}

function Release-Lock {
    param(
        [string]$Name = "wsl-backup"
    )
    $lockFile = Join-Path $Script:OpsRoot "logs\$Name.lock"
    if (Test-Path $lockFile) {
        Remove-Item $lockFile -Force
    }
}

# -- Log Rotation -------------------------------------------------------------

function Invoke-LogRotation {
    param(
        [int]$RetentionDays = 90
    )
    $logDir = Join-Path $Script:OpsRoot "logs"
    if (-not (Test-Path $logDir)) { return }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $old = Get-ChildItem -Path $logDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoff }
    foreach ($f in $old) {
        Remove-Item $f.FullName -Force
        Write-Log -Level INFO -Message "Rotated old log: $($f.Name)"
    }
}

# -- Notification -------------------------------------------------------------

function Send-Notification {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Message
        $notify.Visible = $true
        $notify.ShowBalloonTip(10000)

        # Clean up after a delay (async)
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 12000
        $timer.Add_Tick({
            $notify.Dispose()
            $timer.Stop()
            $timer.Dispose()
        })
        $timer.Start()

        # Pump messages briefly so the notification actually shows
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        Write-Log -Level WARN -Message "Could not send tray notification: $_"
    }
}

# -- Helpers ------------------------------------------------------------------

function Get-HumanDuration {
    param(
        [Parameter(Mandatory)][timespan]$Duration
    )
    if ($Duration.TotalHours -ge 1) {
        return "{0}h {1}m {2}s" -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds
    } elseif ($Duration.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f [int]$Duration.TotalMinutes, $Duration.Seconds
    } else {
        return "{0}s" -f [int]$Duration.TotalSeconds
    }
}

function Get-HumanSize {
    param(
        [Parameter(Mandatory)][long]$Bytes
    )
    if ($Bytes -ge 1GB) {
        return "{0:N1} GB" -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        return "{0:N1} MB" -f ($Bytes / 1MB)
    } else {
        return "{0:N1} KB" -f ($Bytes / 1KB)
    }
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-DriveAvailable {
    param(
        [Parameter(Mandatory)][string]$Drive
    )
    # Normalize: accept "K:", "K:\", or "K"
    $letter = $Drive.TrimEnd(':', '\') + ":"
    return Test-Path "$letter\"
}

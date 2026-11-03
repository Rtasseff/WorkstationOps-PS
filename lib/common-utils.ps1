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
            $lockPid = [int]$content
            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Log -Level ERROR -Message "Another instance is running (PID $lockPid). Lock file: $lockFile"
                return $false
            } else {
                Write-Log -Level WARN -Message "Removing stale lock file (PID $lockPid no longer running)"
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

function Send-ToastReminder {
    # A tray balloon belongs to the process that raised it, and a scheduled run exits
    # within a second. Windows itself holds a toast: this one stays on screen until
    # dismissed and survives in the notification center if the screen is locked or Do
    # Not Disturb is on. Returns $false if it could not be sent, so the caller can fall
    # back to a balloon.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )
    # PowerShell 5.1's registered app ID. A toast needs a registered ID to be shown.
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

        $safeTitle   = [System.Security.SecurityElement]::Escape($Title)
        $safeMessage = [System.Security.SecurityElement]::Escape($Message)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        # scenario='reminder' is what keeps it on screen, and it requires a button.
        $xml.LoadXml("<toast scenario='reminder'><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeMessage</text></binding></visual><actions><action activationType='system' arguments='dismiss' content='Dismiss'/></actions></toast>")

        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        # The same tag replaces yesterday's reminder instead of stacking a new one.
        $toast.Group = 'WorkstationOps'
        $toast.Tag   = if ($Title.Length -gt 60) { $Title.Substring(0, 60) } else { $Title }
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    } catch {
        Write-Log -Level WARN -Message "Could not send reminder toast: $_"
        return $false
    }
}

function Send-Notification {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )
    if (Send-ToastReminder -Title $Title -Message $Message) {
        return
    }
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

function Invoke-WithTimeout {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 15,
        $TimeoutResult = $null
    )
    # Run $ScriptBlock on a background runspace and wait up to $TimeoutSeconds.
    # Returns the scriptblock's last output object, or $TimeoutResult if it does
    # not finish in time. A timed-out worker is abandoned -- it may still be
    # blocked in a wedged native call (e.g. Test-Path on a dead SMB mount), so
    # the caller must not depend on it stopping; it dies with the process. Used
    # to keep drive probes from hanging an entire run when a share is mid-outage.
    $ps = [powershell]::Create()
    [void]$ps.AddScript($ScriptBlock.ToString())
    foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }

    $async = $ps.BeginInvoke()
    $finished = $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    if (-not $finished) {
        # Do not block on Dispose(); the worker thread may be stuck. Best-effort
        # async stop, then walk away.
        try { [void]$ps.BeginStop($null, $null) } catch {}
        return $TimeoutResult
    }

    $val = $null
    try {
        $result = $ps.EndInvoke($async)
        foreach ($item in $result) { $val = $item }
    } catch {
        $val = $TimeoutResult
    }
    try { $ps.Dispose() } catch {}
    return $val
}

function Test-DriveAvailable {
    param(
        [Parameter(Mandatory)][string]$Drive,
        [int]$TimeoutSeconds = 15
    )
    # Normalize: accept "K:", "K:\", or "K"
    $letter = $Drive.TrimEnd(':', '\') + ":"
    $root = "$letter\"

    # Test-Path against a wedged network mount (e.g. an SMB share mid-outage)
    # can block for a very long time -- long enough to leave a scheduled run's
    # PowerShell window hung open. Bound it so the run fails fast and skips
    # cleanly instead of hanging.
    $probe = { param($p) Test-Path -LiteralPath $p }
    $available = Invoke-WithTimeout -ScriptBlock $probe -ArgumentList @($root) -TimeoutSeconds $TimeoutSeconds -TimeoutResult $false
    return [bool]$available
}

# vps-backup.ps1 -- Pull latest ReDIB backup files from VPS to X:
# Dot-sourced by ops.ps1. Exposes Op-Run / Op-Status / Op-Verify / Op-ScheduleSpec.

$OpName        = "vps-backup"
$OpLabel       = "VPS Backup (ReDIB)"
$OpDescription = "Pull latest ReDIB DB + files backups from VPS to X:"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\vps-backup.conf.ps1")

# Use Windows-native OpenSSH explicitly (Task Scheduler context may not have
# git-bash ssh on PATH; the built-in Win32 ssh.exe is always at this path).
$SshExe = Join-Path $env:SystemRoot "System32\OpenSSH\ssh.exe"
$ScpExe = Join-Path $env:SystemRoot "System32\OpenSSH\scp.exe"

# -- Pending flag helpers ----------------------------------------------------

function Get-VpsPendingPath { return (Join-Path $OpsRoot "logs\$OpName.pending") }
function Test-VpsPending    { return (Test-Path (Get-VpsPendingPath)) }
function Clear-VpsPending   {
    $p = Get-VpsPendingPath
    if (Test-Path $p) { Remove-Item $p -Force }
}
function Set-VpsPending {
    param([Parameter(Mandatory)][string]$Reason)
    $Reason | Out-File -FilePath (Get-VpsPendingPath) -Encoding utf8
}
function Get-VpsPendingReason {
    $p = Get-VpsPendingPath
    if (-not (Test-Path $p)) { return $null }
    $r = (Get-Content $p -ErrorAction SilentlyContinue) -join ''
    if (-not $r) { return "unknown" } else { return $r.Trim() }
}

# -- Remote query ------------------------------------------------------------

function Get-RemoteLatest {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Ext
    )
    # Returns @{ Name=<filename>; Size=<bytes> } or $null if no match
    $remoteCmd = "ls -1 $VPS_REMOTE_DIR/redib_${Kind}_*.${Ext} 2>/dev/null | sort | tail -1 | xargs -r stat -c '%n %s'"
    $out = & $SshExe -o BatchMode=yes $VPS_HOST $remoteCmd 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "ssh to '$VPS_HOST' failed (exit $LASTEXITCODE) while listing kind '$Kind'"
    }
    if (-not $out) { return $null }
    $line = ($out | Select-Object -Last 1).ToString().Trim()
    if (-not $line) { return $null }
    $parts = $line -split '\s+'
    if ($parts.Count -lt 2) { return $null }
    return @{
        Name = (Split-Path -Leaf $parts[0])
        Size = [long]$parts[-1]
    }
}

function Test-SshReachable {
    & $SshExe -o BatchMode=yes -o ConnectTimeout=10 $VPS_HOST 'true' 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# -- Local helpers -----------------------------------------------------------

function Get-LocalFilesForKind {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Ext
    )
    if (-not (Test-Path $BACKUP_DEST)) { return @() }
    # Ext may contain a dot (e.g. "sql.gz"); use -Filter with wildcard
    return @(Get-ChildItem -Path $BACKUP_DEST -Filter "redib_${Kind}_*.${Ext}" -ErrorAction SilentlyContinue |
        Sort-Object Name)
}

function Get-LatestLocalForKind {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Ext
    )
    $files = Get-LocalFilesForKind -Kind $Kind -Ext $Ext
    if ($files.Count -eq 0) { return $null }
    return $files[-1]
}

function Get-TimestampFromName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -match 'redib_\w+_(\d{8})_(\d{6})') {
        $d = $matches[1]; $t = $matches[2]
        try {
            return [datetime]::ParseExact("$d$t", "yyyyMMddHHmmss", $null)
        } catch { return $null }
    }
    return $null
}

# -- Op-Status ---------------------------------------------------------------

function Op-Status {
    $driveOk = Test-DriveAvailable $BACKUP_DRIVE
    $pending = Test-VpsPending
    $task    = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue

    $kindStatuses = @()
    foreach ($k in $VPS_BACKUP_KINDS) {
        $latest = if ($driveOk) { Get-LatestLocalForKind -Kind $k.Kind -Ext $k.Ext } else { $null }
        $kindStatuses += [pscustomobject]@{
            Label  = $k.Label
            Latest = $latest
        }
    }

    # Compute the freshest local timestamp (any kind) for the brief line
    $freshest = $null
    foreach ($ks in $kindStatuses) {
        if ($ks.Latest) {
            $ts = Get-TimestampFromName -Name $ks.Latest.Name
            if ($ts -and (-not $freshest -or $ts -gt $freshest)) { $freshest = $ts }
        }
    }

    $brief = if (-not $driveOk) {
        "${OpName}: drive-offline"
    } elseif ($pending) {
        "${OpName}: OVERDUE"
    } elseif ($freshest) {
        $age = (Get-Date) - $freshest
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

    foreach ($ks in $kindStatuses) {
        if ($ks.Latest) {
            $size = Get-HumanSize $ks.Latest.Length
            $ts = Get-TimestampFromName -Name $ks.Latest.Name
            $ageStr = if ($ts) {
                $age = (Get-Date) - $ts
                "$(Get-HumanDuration $age) ago"
            } else { "unknown age" }
            $lines.Add("Latest $($ks.Label.PadRight(9)): $($ks.Latest.Name) ($size, $ageStr)")
        } else {
            $lines.Add("Latest $($ks.Label.PadRight(9)): Never")
        }
    }

    if ($pending) {
        $reason = Get-VpsPendingReason
        $lines.Add("Backup status:         OVERDUE ($reason) -- run '.\ops run $OpName'")
    } else {
        $lines.Add("Backup status:         OK")
    }

    if ($task) {
        $lines.Add("Scheduled task:        $TASK_NAME ($($task.State))")
    } else {
        $lines.Add("Scheduled task:        Not configured (run manually with '.\ops run $OpName')")
    }

    $allHaveLatest = ($kindStatuses | Where-Object { -not $_.Latest }).Count -eq 0

    return @{
        Name    = $OpName
        Label   = $OpLabel
        Ok      = ($driveOk -and -not $pending -and $allHaveLatest)
        Pending = $pending
        Brief   = $brief
        Lines   = $lines.ToArray()
    }
}

# -- Op-Verify ---------------------------------------------------------------

function Op-Verify {
    $lines = New-Object System.Collections.Generic.List[string]
    $allOk = $true

    if (Test-Path $SshExe) {
        $lines.Add("[PASS] Windows OpenSSH present: $SshExe")
    } else {
        $lines.Add("[FAIL] Windows OpenSSH not found at $SshExe (Settings -> Apps -> Optional Features -> OpenSSH Client)")
        $allOk = $false
    }

    if (Test-Path $ScpExe) {
        $lines.Add("[PASS] scp.exe present")
    } else {
        $lines.Add("[FAIL] scp.exe not found at $ScpExe")
        $allOk = $false
    }

    if (Test-DriveAvailable $BACKUP_DRIVE) {
        $lines.Add("[PASS] Backup drive $BACKUP_DRIVE is available")
        if (Test-Path $BACKUP_DEST) {
            $lines.Add("[PASS] Backup destination exists: $BACKUP_DEST")
        } else {
            $lines.Add("[WARN] Backup destination does not exist yet: $BACKUP_DEST (will be created)")
        }
    } else {
        $lines.Add("[FAIL] Backup drive $BACKUP_DRIVE is not available")
        $allOk = $false
    }

    if ($allOk -and (Test-Path $SshExe)) {
        if (Test-SshReachable) {
            $lines.Add("[PASS] SSH to '$VPS_HOST' works non-interactively")

            # Try listing the remote dir
            $lsOut = & $SshExe -o BatchMode=yes $VPS_HOST "test -d $VPS_REMOTE_DIR && echo ok" 2>$null
            if ($LASTEXITCODE -eq 0 -and ($lsOut -join '').Trim() -eq 'ok') {
                $lines.Add("[PASS] Remote directory exists: $VPS_REMOTE_DIR")
            } else {
                $lines.Add("[FAIL] Remote directory not accessible: $VPS_REMOTE_DIR")
                $allOk = $false
            }
        } else {
            $lines.Add("[FAIL] SSH to '$VPS_HOST' failed (check ~/.ssh/config alias, key, and network)")
            $allOk = $false
        }
    }

    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        $lines.Add("[PASS] Scheduled task '$TASK_NAME' exists (State: $($task.State))")
    } else {
        $lines.Add("[INFO] No scheduled task configured (op is manual-only right now)")
    }

    return @{ Ok = $allOk; Lines = $lines.ToArray() }
}

# -- Op-ScheduleSpec ---------------------------------------------------------

function Op-ScheduleSpec {
    return @{
        TaskName    = $TASK_NAME
        Description = $OpDescription
        Trigger     = "Daily"
        Time        = "03:00"
    }
}

# -- Op-Run ------------------------------------------------------------------

function Op-Run {
    param(
        [switch]$Scheduled,
        [switch]$Force,
        [switch]$DryRun
    )

    Initialize-Log -Name $OpName
    $startTime = Get-Date

    Write-Log -Level INFO -Message "=== VPS Backup Started ==="
    Write-Log -Level INFO -Message "Mode: $(if ($Scheduled) {'Scheduled'} elseif ($DryRun) {'Dry Run'} elseif ($Force) {'Force'} else {'Interactive'})"

    # -- Pre-flight ----------------------------------------------------------

    if (-not (Test-Path $SshExe)) {
        Write-Log -Level ERROR -Message "ssh.exe not found at $SshExe"
        if ($Scheduled) { Set-VpsPending -Reason "ssh-missing" }
        exit 1
    }

    if (-not (Test-DriveAvailable $BACKUP_DRIVE)) {
        Write-Log -Level WARN -Message "Backup drive $BACKUP_DRIVE is not available. Skipping."
        if ($Scheduled) { Set-VpsPending -Reason "drive-unavailable" }
        exit 0
    }

    if (-not $DryRun) {
        Ensure-Directory $BACKUP_DEST
    }

    # Lock
    if (-not $DryRun) {
        $gotLock = Get-Lock -Name $OpName
        if (-not $gotLock) {
            Write-Log -Level ERROR -Message "Could not acquire lock. Another run may be in progress."
            exit 1
        }
    }

    $anyFailure = $false

    try {

    # -- SSH reachability ----------------------------------------------------

    if (-not (Test-SshReachable)) {
        Write-Log -Level ERROR -Message "SSH to '$VPS_HOST' is not reachable."
        if ($Scheduled) { Set-VpsPending -Reason "ssh-unreachable" }
        $anyFailure = $true
        exit 1
    }
    Write-Log -Level OK -Message "SSH to '$VPS_HOST' reachable."

    # -- Per-kind pull -------------------------------------------------------

    foreach ($k in $VPS_BACKUP_KINDS) {
        $kind = $k.Kind; $ext = $k.Ext; $label = $k.Label
        Write-Log -Level INFO -Message "--- $label ($kind) ---"

        try {
            $remote = Get-RemoteLatest -Kind $kind -Ext $ext
        } catch {
            Write-Log -Level ERROR -Message "Failed to list remote for '$kind': $_"
            $anyFailure = $true
            continue
        }

        if (-not $remote) {
            Write-Log -Level WARN -Message "No remote files matching 'redib_${kind}_*.${ext}'. Skipping."
            continue
        }

        $remoteName = $remote.Name
        $remoteSize = $remote.Size
        Write-Log -Level INFO -Message "Remote latest: $remoteName ($(Get-HumanSize $remoteSize))"

        $localPath = Join-Path $BACKUP_DEST $remoteName

        # Idempotence: same name + same size => already have it
        if (Test-Path $localPath) {
            $localSize = (Get-Item $localPath).Length
            if ($localSize -eq $remoteSize) {
                Write-Log -Level OK -Message "Already have it: $remoteName"
                # Still prune older files in case any snuck in
                if (-not $DryRun) {
                    Remove-OlderLocalFiles -Kind $kind -Ext $ext -KeepName $remoteName
                }
                continue
            } else {
                Write-Log -Level WARN -Message "Local '$remoteName' size mismatch (local=$localSize, remote=$remoteSize). Will re-download."
            }
        }

        # Dry-run bails here
        if ($DryRun) {
            Write-Log -Level INFO -Message "[DRY RUN] Would scp $VPS_HOST`:$VPS_REMOTE_DIR/$remoteName -> $localPath"
            $olderCount = (Get-LocalFilesForKind -Kind $kind -Ext $ext | Where-Object { $_.Name -ne $remoteName }).Count
            if ($olderCount -gt 0) {
                Write-Log -Level INFO -Message "[DRY RUN] Would delete $olderCount older local file(s) for '$kind'"
            }
            continue
        }

        # Download to .partial, then rename
        $partialPath = "$localPath.partial"
        if (Test-Path $partialPath) { Remove-Item $partialPath -Force }

        $remoteSrc = "${VPS_HOST}:$VPS_REMOTE_DIR/$remoteName"
        Write-Log -Level INFO -Message "Copying $remoteSrc -> $localPath"

        # Run scp as native command; capture all streams to avoid PowerShell
        # treating stderr as a terminating error. -p omitted: NTFS doesn't
        # support POSIX mode bits and scp's post-transfer chmod would fail.
        $scpOutput = & $ScpExe -o BatchMode=yes -q $remoteSrc $partialPath 2>&1
        $scpExit = $LASTEXITCODE
        if ($scpOutput) {
            foreach ($line in $scpOutput) { Write-Log -Level INFO -Message "scp: $line" }
        }
        if ($scpExit -ne 0) {
            Write-Log -Level ERROR -Message "scp failed (exit $scpExit) for '$remoteName'"
            if (Test-Path $partialPath) { Remove-Item $partialPath -Force -ErrorAction SilentlyContinue }
            $anyFailure = $true
            continue
        }

        # Verify size
        if (-not (Test-Path $partialPath)) {
            Write-Log -Level ERROR -Message "scp reported success but '$partialPath' is missing"
            $anyFailure = $true
            continue
        }
        $dlSize = (Get-Item $partialPath).Length
        if ($dlSize -ne $remoteSize) {
            Write-Log -Level ERROR -Message "Downloaded size mismatch (got $dlSize, expected $remoteSize) for '$remoteName'"
            Remove-Item $partialPath -Force -ErrorAction SilentlyContinue
            $anyFailure = $true
            continue
        }

        # Rename into place (clobber any pre-existing partial of same name)
        if (Test-Path $localPath) { Remove-Item $localPath -Force }
        Rename-Item -Path $partialPath -NewName $remoteName
        Write-Log -Level OK -Message "Stored: $remoteName ($(Get-HumanSize $dlSize))"

        # Prune older files of this kind (retention = 1)
        Remove-OlderLocalFiles -Kind $kind -Ext $ext -KeepName $remoteName
    }

    # -- Wrap up -------------------------------------------------------------

    if ($anyFailure) {
        Write-Log -Level WARN -Message "Completed with errors."
        if ($Scheduled) { Set-VpsPending -Reason "pull-failed" }
    } else {
        if (Test-VpsPending) {
            Clear-VpsPending
            Write-Log -Level INFO -Message "Cleared pending flag."
        }
    }

    Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS

    $totalDuration = (Get-Date) - $startTime
    Write-Log -Level OK -Message "=== VPS Backup Complete ($(Get-HumanDuration $totalDuration)) ==="

    } finally {
        if (-not $DryRun) {
            Release-Lock -Name $OpName
        }
    }

    if ($anyFailure) { exit 1 }
}

function Remove-OlderLocalFiles {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Ext,
        [Parameter(Mandatory)][string]$KeepName
    )
    $older = Get-LocalFilesForKind -Kind $Kind -Ext $Ext | Where-Object { $_.Name -ne $KeepName }
    foreach ($f in $older) {
        Write-Log -Level INFO -Message "Removing older local: $($f.Name) ($(Get-HumanSize $f.Length))"
        Remove-Item $f.FullName -Force
    }
}

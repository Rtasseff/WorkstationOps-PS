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

# Applied to every ssh AND scp call. ServerAlive* is the first line of defence:
# it makes ssh give up ~15s after the peer stops answering at ANY phase, whereas
# ConnectTimeout stops applying once the connection is set up. Belt and braces
# with Invoke-BoundedNative below -- the watchdog is the guarantee, these just
# let the common case exit cleanly with a real exit code instead of being killed.
$SshCommonOpts = @(
    '-o', 'BatchMode=yes'
    '-o', 'ConnectTimeout=10'
    '-o', 'ServerAliveInterval=5'
    '-o', 'ServerAliveCountMax=3'
)

# -- Bounded native execution ------------------------------------------------

function Format-NativeArg {
    param([string]$Value)
    # Quote one argument for the Windows CRT parser that ssh.exe/scp.exe use.
    # Start-Process takes a single argument STRING, so the quoting is ours to do.
    # The remote commands here carry spaces, pipes and single quotes -- all inert
    # once the argument is wrapped -- but embedded double quotes and trailing
    # backslashes are not, so handle those explicitly.
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-BoundedNative {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$What,
        [int]$TimeoutSeconds = 60,
        [switch]$Quiet
    )
    # Run a native command under a wall-clock cap that ALWAYS returns.
    #
    # Why this exists: on 2026-08-12 and 2026-08-13 the probe
    # 'ssh -o BatchMode=yes -o ConnectTimeout=10 vps true' blocked for 32 hours.
    # ConnectTimeout bounds connection setup only, so a path that dies after that
    # leaves ssh parked on a socket read with no timeout of any kind. Task
    # Scheduler then killed the supervisor at ExecutionTimeLimit -- which unwinds
    # nothing, so every Set-VpsPending branch was skipped and two missed backups
    # produced no evidence whatsoever. Bounding the call is what turns that into
    # an ordinary, reportable failure.
    #
    # Built on ProcessStartInfo rather than Start-Process for two reasons found
    # by testing this file:
    #   1. Start-Process -PassThru does NOT populate ExitCode on Windows
    #      PowerShell 5.1 when either output stream is redirected. HasExited
    #      reads True and ExitCode reads empty, so every success looked like a
    #      failure. This is the documented 5.1 behaviour, not a transient.
    #   2. CreateNoWindow means a stuck child cannot inherit and hold a console
    #      window open -- which is exactly how the 2026-08-12 orphan stayed on
    #      screen for 32 hours after its parent was killed.
    #
    # Both streams are drained with ReadToEndAsync BEFORE waiting. Reading them
    # in sequence would deadlock the moment either pipe buffer filled, which
    # would relocate the hang rather than remove it.
    #
    # -Quiet is for Op-Verify, which must not print to host.

    $argLine = ($ArgumentList | ForEach-Object { Format-NativeArg $_ }) -join ' '

    $timedOut = $false
    $exitCode = -1
    $rawOut   = ''
    $rawErr   = ''
    $proc     = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $FilePath
        $psi.Arguments              = $argLine
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        # Start both reads first; they complete when the pipes close.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
            $exitCode = $proc.ExitCode
        } else {
            $timedOut = $true
            if (-not $Quiet) {
                Write-Log -Level ERROR -Message "$What exceeded ${TimeoutSeconds}s; killing pid $($proc.Id)."
            }
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit(5000) } catch { }
        }

        # Bounded so a wedged pipe cannot reintroduce the hang we just removed.
        if ($outTask.Wait(5000)) { $rawOut = $outTask.Result }
        if ($errTask.Wait(5000)) { $rawErr = $errTask.Result }
    } catch {
        if (-not $Quiet) {
            Write-Log -Level ERROR -Message "$What could not be started: $_"
        }
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }

    return @{
        TimedOut = $timedOut
        ExitCode = $exitCode
        StdOut   = @(ConvertTo-OutputLines $rawOut)
        StdErr   = @(ConvertTo-OutputLines $rawErr)
    }
}

function ConvertTo-OutputLines {
    param([string]$Text)
    # Match what '& native' used to hand back: an array of lines, no trailing
    # blank. Callers join or index these, so an empty string must yield @().
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @($Text -split "`r`n|`n|`r" | Where-Object { $_ -ne '' })
}

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
    $r = Invoke-BoundedNative -FilePath $SshExe `
            -ArgumentList (@($SshCommonOpts) + @($VPS_HOST, $remoteCmd)) `
            -What "Remote listing for kind '$Kind'" `
            -TimeoutSeconds $SSH_CMD_TIMEOUT_SECONDS
    if ($r.TimedOut) {
        throw "ssh to '$VPS_HOST' timed out after ${SSH_CMD_TIMEOUT_SECONDS}s while listing kind '$Kind'"
    }
    if ($r.ExitCode -ne 0) {
        throw "ssh to '$VPS_HOST' failed (exit $($r.ExitCode)) while listing kind '$Kind'"
    }
    $out = $r.StdOut
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
    param([switch]$Quiet)
    # This exact probe is what hung for 32 hours on 2026-08-12. It is now capped.
    $r = Invoke-BoundedNative -FilePath $SshExe `
            -ArgumentList (@($SshCommonOpts) + @($VPS_HOST, 'true')) `
            -What "SSH reachability probe to '$VPS_HOST'" `
            -TimeoutSeconds $SSH_PROBE_TIMEOUT_SECONDS `
            -Quiet:$Quiet
    return ((-not $r.TimedOut) -and ($r.ExitCode -eq 0))
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

    # Freshness. A daily pull that quietly stops is this op's most likely failure
    # and its hardest to notice: on 2026-08-12 and -13 the run died inside the ssh
    # probe, left no pending flag, and status still read "ok (2d ago)" while
    # nothing was being backed up. Age alone was already on screen -- what was
    # missing is that anything called it wrong.
    $staleAfter = if ($null -ne $STALE_AFTER_HOURS) { $STALE_AFTER_HOURS } else { 36 }
    $stale = $false
    if ($driveOk -and $freshest) {
        $stale = (((Get-Date) - $freshest).TotalHours -gt $staleAfter)
    }

    $brief = if (-not $driveOk) {
        "${OpName}: drive-offline"
    } elseif ($pending) {
        "${OpName}: OVERDUE"
    } elseif ($freshest) {
        $age = (Get-Date) - $freshest
        $ageStr = if ($age.TotalDays -ge 1) { "$([int]$age.TotalDays)d ago" } else { "today" }
        if ($stale) { "${OpName}: STALE ($ageStr)" } else { "${OpName}: ok ($ageStr)" }
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
    } elseif ($stale) {
        $lines.Add("Backup status:         STALE -- newest backup is over ${staleAfter}h old, so the daily pull is not landing")
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
        Ok      = ($driveOk -and -not $pending -and $allHaveLatest -and -not $stale)
        Pending = $pending
        Stale   = $stale
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
        # -Quiet throughout: Op-Verify returns lines, it does not print.
        if (Test-SshReachable -Quiet) {
            $lines.Add("[PASS] SSH to '$VPS_HOST' works non-interactively")

            # Try listing the remote dir
            $ls = Invoke-BoundedNative -FilePath $SshExe `
                    -ArgumentList (@($SshCommonOpts) + @($VPS_HOST, "test -d $VPS_REMOTE_DIR && echo ok")) `
                    -What "Remote directory check" `
                    -TimeoutSeconds $SSH_CMD_TIMEOUT_SECONDS `
                    -Quiet
            if ((-not $ls.TimedOut) -and $ls.ExitCode -eq 0 -and (($ls.StdOut -join '').Trim() -eq 'ok')) {
                $lines.Add("[PASS] Remote directory exists: $VPS_REMOTE_DIR")
            } else {
                $lines.Add("[FAIL] Remote directory not accessible: $VPS_REMOTE_DIR")
                $allOk = $false
            }
        } else {
            $lines.Add("[FAIL] SSH to '$VPS_HOST' failed or timed out (check ~/.ssh/config alias, key, and network)")
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
        TaskName           = $TASK_NAME
        Description        = $OpDescription
        Trigger            = "Daily"
        # 05:00 dodges the ~03:00 IT backup window that makes X: (a network
        # share) intermittently unavailable / wedged at that hour.
        Time               = "05:00"
        # Short cap: if X: is wedged the run should die fast, not hang until the
        # next day. A healthy pull finishes in ~3s.
        ExecutionTimeLimit = "PT10M"
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

    # Flag the run as unfinished BEFORE anything that can block. Task Scheduler
    # kills this process at ExecutionTimeLimit without unwinding it -- no catch,
    # no finally, none of the Set-VpsPending calls below ever run -- so writing
    # the flag up front is the only way a killed run leaves evidence at all. The
    # 2026-08-12 and -13 runs both died inside the reachability probe and
    # reported nothing. A clean failure path overwrites this with its own reason;
    # success clears it.
    $priorReason = if (Test-VpsPending) { Get-VpsPendingReason } else { $null }
    if ($Scheduled -and -not $DryRun) {
        Set-VpsPending -Reason "run-did-not-finish (started $(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
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

        # Run scp under the same wall-clock cap as ssh -- a transfer that stalls
        # mid-stream hangs exactly as readily as the probe did, and here it would
        # do so holding a .partial file. -p omitted: NTFS doesn't support POSIX
        # mode bits and scp's post-transfer chmod would fail.
        $scp = Invoke-BoundedNative -FilePath $ScpExe `
                -ArgumentList (@($SshCommonOpts) + @('-q', $remoteSrc, $partialPath)) `
                -What "scp of '$remoteName'" `
                -TimeoutSeconds $SCP_TIMEOUT_SECONDS
        foreach ($line in (@($scp.StdOut) + @($scp.StdErr))) {
            if ($line) { Write-Log -Level INFO -Message "scp: $line" }
        }
        if ($scp.TimedOut -or $scp.ExitCode -ne 0) {
            $scpWhy = if ($scp.TimedOut) { "timed out after ${SCP_TIMEOUT_SECONDS}s" } else { "exit $($scp.ExitCode)" }
            Write-Log -Level ERROR -Message "scp failed ($scpWhy) for '$remoteName'"
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
            # Only worth a line if a PREVIOUS run left it: this run sets the flag
            # on itself at the start, so an unconditional message would fire every
            # time and mean nothing.
            if ($priorReason) {
                Write-Log -Level INFO -Message "Cleared pending flag from a previous run ($priorReason)."
            }
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

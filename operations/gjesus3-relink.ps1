# gjesus3-relink.ps1 -- Create the project hard links a Mac sync could not make,
# from registries\pending_links.csv on gjesus3.
# Dot-sourced by ops.ps1. Exposes Op-Run / Op-Status / Op-Verify / Op-ScheduleSpec.
#
# Boundary: the TOOL lives in the gjesus3-pilot repo (tools\relink_pending.py owns
# what a link is and how a row is marked). THIS op owns the schedule, the run log,
# the health signal, and failure notification.
#
# Checking a link by hand: use os.path.samefile, not the link count. Through SMB a
# true hard link reports st_nlink = 1, so a count check makes it look like a copy.

$OpName        = "gjesus3-relink"
$OpLabel       = "gjesus3 Project Relink"
$OpDescription = "Nightly creation of the gjesus3 project hard links queued in pending_links.csv"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\gjesus3-relink.conf.ps1")

# Paths derived from config (kept out of the config file, which stays declarative).
$RELINK_TOOL       = Join-Path $GJESUS3_REPO "tools\relink_pending.py"
$NAS_REGISTRIES    = Join-Path $NAS_UNC "registries"
$PENDING_LINKS_CSV = Join-Path $NAS_REGISTRIES "pending_links.csv"

# -- Pending flag helpers ----------------------------------------------------

function Get-RelinkPendingPath { return (Join-Path $OpsRoot "logs\$OpName.pending") }
function Test-RelinkPending    { return (Test-Path (Get-RelinkPendingPath)) }
function Clear-RelinkPending {
    $p = Get-RelinkPendingPath
    if (Test-Path $p) { Remove-Item $p -Force }
}
function Set-RelinkPending {
    param([Parameter(Mandatory)][string]$Reason)
    $Reason | Out-File -FilePath (Get-RelinkPendingPath) -Encoding utf8
}
function Get-RelinkPendingReason {
    $p = Get-RelinkPendingPath
    if (-not (Test-Path $p)) { return $null }
    $r = (Get-Content $p -ErrorAction SilentlyContinue) -join ''
    if (-not $r) { return "unknown" } else { return $r.Trim() }
}

# -- Tool, NAS and worklist checks -------------------------------------------

function Test-RelinkToolIsFixed {
    # A version without the locked re-read writes back its own stale copy of the
    # worklist, which can drop a row a sync queued during the run. Real runs refuse
    # it. This matches the code, not the docstring.
    if (-not (Test-Path -LiteralPath $RELINK_TOOL)) { return $false }
    return [bool](Select-String -LiteralPath $RELINK_TOOL -SimpleMatch -Pattern 'with locking.registry_lock(' -Quiet)
}

function Test-RelinkNasReachable {
    # Bounded, because a wedged SMB share can hang a naive Test-Path for a long time.
    $probe = { param($p) Test-Path -LiteralPath $p }
    $ok = Invoke-WithTimeout -ScriptBlock $probe -ArgumentList @($NAS_REGISTRIES) -TimeoutSeconds 15 -TimeoutResult $false
    return [bool]$ok
}

function Get-RelinkWorklist {
    # Summary of pending_links.csv, or $null if it could not be read. No file means
    # nothing has ever been queued, which is not a problem.
    $reader = {
        param($p)
        if (-not (Test-Path -LiteralPath $p)) { return @{ Total = 0; Open = 0; Oldest = $null } }
        $rows = @(Import-Csv -LiteralPath $p -Encoding UTF8)
        $open = @($rows | Where-Object { ([string]$_.status).Trim() -ne 'linked' })
        $oldest = $open | ForEach-Object { [string]$_.queued_datetime } | Where-Object { $_ } |
            Sort-Object | Select-Object -First 1
        return @{ Total = $rows.Count; Open = $open.Count; Oldest = $oldest }
    }
    return Invoke-WithTimeout -ScriptBlock $reader -ArgumentList @($PENDING_LINKS_CSV) -TimeoutSeconds 30 -TimeoutResult $null
}

function Get-RelinkOldestAge {
    # Age of a queued_datetime as a TimeSpan, or $null if it can't be parsed.
    param([string]$Queued)
    if (-not $Queued) { return $null }
    $parsed = [datetimeoffset]::MinValue
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ([datetimeoffset]::TryParse($Queued, $culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return [datetimeoffset]::Now - $parsed
    }
    return $null
}

# -- Op-Status ---------------------------------------------------------------

function Op-Status {
    $nasOk    = Test-RelinkNasReachable
    $pending  = Test-RelinkPending
    $task     = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    $worklist = if ($nasOk) { Get-RelinkWorklist } else { $null }

    $oldestAge = $null
    $isStale   = $false
    if ($worklist -and $worklist.Open -gt 0) {
        $oldestAge = Get-RelinkOldestAge -Queued $worklist.Oldest
        if ($oldestAge -and $oldestAge.TotalHours -gt $STALE_AFTER_HOURS) { $isStale = $true }
    }

    $brief = if (-not $nasOk) {
        "${OpName}: nas-unreachable"
    } elseif (-not $worklist) {
        "${OpName}: worklist-unreadable"
    } elseif ($pending) {
        "${OpName}: OVERDUE ($($worklist.Open) open)"
    } elseif ($isStale) {
        "${OpName}: STALE ($($worklist.Open) open, oldest $(Get-HumanDuration $oldestAge))"
    } elseif (-not $SCHEDULE_CONFIRMED) {
        "${OpName}: held, not scheduled ($($worklist.Open) open)"
    } else {
        "${OpName}: ok ($($worklist.Open) open)"
    }

    $lines = New-Object System.Collections.Generic.List[string]

    if ($nasOk) {
        $lines.Add("RDM System (NAS):      Available ($NAS_UNC)")
    } else {
        $lines.Add("RDM System (NAS):      NOT AVAILABLE ($NAS_UNC)")
    }

    if ($worklist) {
        $summary = "$($worklist.Open) open of $($worklist.Total) rows"
        if ($worklist.Oldest) { $summary += ", oldest queued $($worklist.Oldest)" }
        if ($oldestAge) { $summary += " ($(Get-HumanDuration $oldestAge) ago)" }
        $lines.Add("Worklist:              $summary")
    } elseif ($nasOk) {
        $lines.Add("Worklist:              Could not read $PENDING_LINKS_CSV")
    } else {
        $lines.Add("Worklist:              Unknown (NAS not reachable)")
    }

    if ($pending) {
        $lines.Add("Relink status:         OVERDUE ($(Get-RelinkPendingReason)) -- check '.\ops logs $OpName'")
    } elseif ($isStale) {
        $lines.Add("Relink status:         STALE (open row older than ${STALE_AFTER_HOURS}h) -- check '.\ops logs $OpName'")
    } else {
        $lines.Add("Relink status:         OK")
    }

    if (Test-RelinkToolIsFixed) {
        $lines.Add("Tool version:          OK")
    } else {
        $lines.Add("Tool version:          FAIL -- no locked re-read in $RELINK_TOOL; real runs refuse it")
    }

    if ($task) {
        $lines.Add("Scheduled task:        $TASK_NAME ($($task.State))")
    } elseif (-not $SCHEDULE_CONFIRMED) {
        $lines.Add("Scheduled task:        Held (see `$SCHEDULE_CONFIRMED in config\gjesus3-relink.conf.ps1)")
    } else {
        $lines.Add("Scheduled task:        Not configured (run '.\ops schedule $OpName')")
    }

    return @{
        Name    = $OpName
        Label   = $OpLabel
        Ok      = ($nasOk -and $null -ne $worklist -and -not $pending -and -not $isStale)
        Pending = $pending
        Brief   = $brief
        Lines   = $lines.ToArray()
    }
}

# -- Op-Verify ---------------------------------------------------------------

function Op-Verify {
    $lines = New-Object System.Collections.Generic.List[string]
    $allOk = $true

    $pythonOk = $false
    if (Test-Path -LiteralPath $PYTHON) {
        $ver = (& $PYTHON --version 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            $lines.Add("[PASS] Python runs: $ver")
            $pythonOk = $true
        } else {
            $lines.Add("[FAIL] Python at '$PYTHON' did not run (exit $LASTEXITCODE)")
            $allOk = $false
        }
    } else {
        $lines.Add("[FAIL] Python not found at '$PYTHON' -- fix `$PYTHON in config\gjesus3-relink.conf.ps1")
        $allOk = $false
    }

    $toolOk = Test-Path -LiteralPath $RELINK_TOOL
    if ($toolOk) {
        $lines.Add("[PASS] Tool present: $RELINK_TOOL")
    } else {
        $lines.Add("[FAIL] Tool not found: $RELINK_TOOL")
        $lines.Add("       Did the gjesus3-pilot repo move? Update `$GJESUS3_REPO in config\gjesus3-relink.conf.ps1")
        $allOk = $false
    }

    # '--help' loads the tool's whole import chain, then exits before any NAS access.
    if ($pythonOk -and $toolOk) {
        & $PYTHON $RELINK_TOOL --help 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $lines.Add("[PASS] Tool imports and parses args cleanly")
        } else {
            $lines.Add("[FAIL] Tool failed to import/parse (exit $LASTEXITCODE) -- run it by hand to see the traceback")
            $allOk = $false
        }
    }

    if ($toolOk) {
        if (Test-RelinkToolIsFixed) {
            $lines.Add("[PASS] Tool has the locked re-read, so it is safe to run during a sync")
        } elseif ($SCHEDULE_CONFIRMED) {
            $lines.Add("[FAIL] Tool lacks the locked re-read and could lose rows. Real runs refuse it. Merge the fix (ef0209d).")
            $allOk = $false
        } else {
            $lines.Add("[WARN] Tool lacks the locked re-read (fix ef0209d not merged here). Real runs refuse it; --dry-run still works.")
        }
    }

    # The tool must come from main, not from whatever branch the checkout last had.
    if ($toolOk) {
        $branch = $null
        try { $branch = (& git -C $GJESUS3_REPO rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim() } catch {}
        if ($branch -eq 'main') {
            $lines.Add("[PASS] Checkout is on main: $GJESUS3_REPO")
        } elseif ($branch -and $SCHEDULE_CONFIRMED) {
            $lines.Add("[FAIL] Checkout is on '$branch', not main: $GJESUS3_REPO")
            $allOk = $false
        } elseif ($branch) {
            $lines.Add("[WARN] Checkout is on '$branch', not main: $GJESUS3_REPO")
        } else {
            $lines.Add("[WARN] Could not read the checkout's branch with git: $GJESUS3_REPO")
        }
    }

    if (Test-RelinkNasReachable) {
        $lines.Add("[PASS] NAS reachable: $NAS_REGISTRIES")
        if (Get-RelinkWorklist) {
            $lines.Add("[PASS] Worklist readable: $PENDING_LINKS_CSV")
        } else {
            $lines.Add("[FAIL] Could not read $PENDING_LINKS_CSV")
            $allOk = $false
        }
    } else {
        $lines.Add("[FAIL] NAS not reachable: $NAS_REGISTRIES")
        $allOk = $false
    }

    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task -and -not $SCHEDULE_CONFIRMED) {
        $lines.Add("[FAIL] Scheduled task '$TASK_NAME' exists although `$SCHEDULE_CONFIRMED is false")
        $allOk = $false
    } elseif ($task) {
        $lines.Add("[PASS] Scheduled task '$TASK_NAME' exists (State: $($task.State))")
    } elseif ($SCHEDULE_CONFIRMED) {
        $lines.Add("[INFO] No scheduled task yet -- run '.\ops schedule $OpName' to create it")
    } else {
        $lines.Add("[INFO] Schedule on hold: see `$SCHEDULE_CONFIRMED in config\gjesus3-relink.conf.ps1")
    }

    return @{ Ok = $allOk; Lines = $lines.ToArray() }
}

# -- Op-ScheduleSpec ---------------------------------------------------------

function Op-ScheduleSpec {
    # $null makes every '.\ops schedule' treat this op as manual. See the hold in
    # config\gjesus3-relink.conf.ps1.
    if (-not $SCHEDULE_CONFIRMED) { return $null }
    return @{
        TaskName           = $TASK_NAME
        Description        = $OpDescription
        Trigger            = "Daily"
        Time               = $TASK_TIME
        # A healthy night takes seconds to minutes. A wedged run should die rather
        # than block the next night's run.
        ExecutionTimeLimit = "PT30M"
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

    Write-Log -Level INFO -Message "=== gjesus3 relink started ==="
    Write-Log -Level INFO -Message "Mode: $(if ($Scheduled) {'Scheduled'} elseif ($DryRun) {'Dry Run'} elseif ($Force) {'Force'} else {'Interactive'})"

    # -- Pre-flight ----------------------------------------------------------

    if (-not (Test-Path -LiteralPath $PYTHON)) {
        Write-Log -Level ERROR -Message "Python not found at '$PYTHON'."
        if ($Scheduled) { Set-RelinkPending -Reason "python-missing" }
        exit 1
    }

    if (-not (Test-Path -LiteralPath $RELINK_TOOL)) {
        Write-Log -Level ERROR -Message "Tool not found at '$RELINK_TOOL'. Did the gjesus3-pilot repo move? Update GJESUS3_REPO in config\gjesus3-relink.conf.ps1."
        if ($Scheduled) { Set-RelinkPending -Reason "tool-missing" }
        exit 1
    }

    if (-not (Test-RelinkNasReachable)) {
        # Skip cleanly (exit 0): an unreachable NAS is a transient condition, and the
        # pending flag surfaces it in '.\ops status'.
        Write-Log -Level WARN -Message "NAS '$NAS_REGISTRIES' not reachable. Skipping this run."
        if ($Scheduled) { Set-RelinkPending -Reason "nas-unreachable" }
        exit 0
    }

    # A real run writes to production, so it never launches an unfixed tool. A dry
    # run only reads, in either version.
    if (-not (Test-RelinkToolIsFixed)) {
        if ($DryRun) {
            Write-Log -Level WARN -Message "[DRY RUN] Tool lacks the locked re-read. A real run would refuse it until the fix (ef0209d) is merged."
        } else {
            Write-Log -Level ERROR -Message "Refusing to run: '$RELINK_TOOL' lacks the locked re-read and could lose rows queued by a sync. Merge the fix (ef0209d) first."
            if ($Scheduled) {
                Set-RelinkPending -Reason "tool-outdated"
                Send-Notification -Title "gjesus3 relink refused to run" -Message "The installed relink tool could lose rows, so it was not run. Run '.\ops verify $OpName' for details."
            }
            exit 1
        }
    }

    # -- Lock ----------------------------------------------------------------

    if (-not $DryRun) {
        $gotLock = Get-Lock -Name $OpName
        if (-not $gotLock) {
            Write-Log -Level ERROR -Message "Could not acquire lock. Another run may be in progress."
            exit 1
        }
    }

    $toolExit = 1

    try {
        $toolArgs = @('--nas-root', $NAS_UNC)
        if ($DryRun) { $toolArgs += '--dry-run' }
        Write-Log -Level INFO -Message "Running: $PYTHON $RELINK_TOOL $($toolArgs -join ' ')"

        # ops.ps1 sets Stop, and under Stop PS 5.1 aborts on a native command's first
        # stderr line. A Python traceback must reach the failure handling below.
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $toolOutput = & $PYTHON $RELINK_TOOL @toolArgs 2>&1
            $toolExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
        }

        foreach ($line in $toolOutput) {
            Write-Log -Level INFO -Message "relink: $line"
        }
    } finally {
        if (-not $DryRun) { Release-Lock -Name $OpName }
    }

    # -- Wrap up -------------------------------------------------------------

    if ($DryRun) {
        if ($toolExit -ne 0) {
            Write-Log -Level WARN -Message "[DRY RUN] Tool exited ${toolExit}: a real run would leave rows pending."
        }
        Write-Log -Level INFO -Message "=== gjesus3 relink dry run complete ==="
        exit $toolExit
    }

    if ($toolExit -ne 0) {
        # Non-zero means a row stayed pending or the registry lock was busy. Re-running
        # is always safe, so tomorrow's run retries and reminds again if it still fails.
        Write-Log -Level ERROR -Message "Tool exited ${toolExit}: a row stayed pending or the registry lock was busy."
        if ($Scheduled) {
            Set-RelinkPending -Reason "tool-exit-$toolExit"
            Send-Notification -Title "gjesus3 relink needs attention" -Message "Some project links were not made. Run '.\ops logs $OpName' for details."
        }
    } elseif (Test-RelinkPending) {
        Clear-RelinkPending
        Write-Log -Level INFO -Message "Cleared pending flag."
    }

    Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS

    $totalDuration = (Get-Date) - $startTime
    Write-Log -Level OK -Message "=== gjesus3 relink complete ($(Get-HumanDuration $totalDuration)) ==="

    if ($toolExit -ne 0) { exit 1 }
}

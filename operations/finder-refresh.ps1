# finder-refresh.ps1 -- Rebuild the gjesus3 researcher Finder index (global +
# every per-project index.html) from the live registry.
# Dot-sourced by ops.ps1. Exposes Op-Run / Op-Status / Op-Verify / Op-ScheduleSpec.
#
# Boundary: the GENERATOR lives in the gjesus3-pilot repo (domain logic -- how a
# Finder is built from the registry). THIS op owns the schedule, the run log, the
# health signal, and failure notification. See config\finder-refresh.conf.ps1 for
# the one cross-repo path that couples the two.

$OpName        = "finder-refresh"
$OpLabel       = "gjesus3 Finder Refresh"
$OpDescription = "Daily rebuild of the gjesus3 researcher Finder index (global + per-project)"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\finder-refresh.conf.ps1")

# Paths derived from config (kept out of the config file, which stays declarative).
$GENERATOR       = Join-Path $GJESUS3_REPO "tools\generate_index.py"
$NAS_REGISTRIES  = Join-Path $NAS_UNC "registries"
$PUBLISHED_INDEX = Join-Path $NAS_REGISTRIES "index.html"

# -- Pending flag helpers ----------------------------------------------------

function Get-FinderPendingPath { return (Join-Path $OpsRoot "logs\$OpName.pending") }
function Test-FinderPending    { return (Test-Path (Get-FinderPendingPath)) }
function Clear-FinderPending {
    $p = Get-FinderPendingPath
    if (Test-Path $p) { Remove-Item $p -Force }
}
function Set-FinderPending {
    param([Parameter(Mandatory)][string]$Reason)
    $Reason | Out-File -FilePath (Get-FinderPendingPath) -Encoding utf8
}
function Get-FinderPendingReason {
    $p = Get-FinderPendingPath
    if (-not (Test-Path $p)) { return $null }
    $r = (Get-Content $p -ErrorAction SilentlyContinue) -join ''
    if (-not $r) { return "unknown" } else { return $r.Trim() }
}

# -- NAS reachability + freshness --------------------------------------------

function Test-NasReachable {
    # Bounded Test-Path on the registries\ folder. A wedged SMB share can hang a
    # naive Test-Path long enough to leave a scheduled run's window stuck open;
    # Invoke-WithTimeout makes it fail fast and skip cleanly instead.
    $probe = { param($p) Test-Path -LiteralPath $p }
    $ok = Invoke-WithTimeout -ScriptBlock $probe -ArgumentList @($NAS_REGISTRIES) -TimeoutSeconds 15 -TimeoutResult $false
    return [bool]$ok
}

function Get-PublishedIndexTime {
    # LastWriteTime of the published global index, or $null if absent/unreachable.
    # On the NAS this file is written ONLY by the generator, so its mtime is the
    # last successful publish time -- a true end-to-end freshness signal, and no
    # need to read the ~19 MB body. Bounded so a wedged share cannot hang status.
    $reader = {
        param($p)
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        (Get-Item -LiteralPath $p -ErrorAction SilentlyContinue).LastWriteTime
    }
    return Invoke-WithTimeout -ScriptBlock $reader -ArgumentList @($PUBLISHED_INDEX) -TimeoutSeconds 15 -TimeoutResult $null
}

# -- Op-Status ---------------------------------------------------------------

function Op-Status {
    $nasOk       = Test-NasReachable
    $pending     = Test-FinderPending
    $task        = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    $lastPublish = if ($nasOk) { Get-PublishedIndexTime } else { $null }

    $isStale = $false
    if ($lastPublish) {
        $age = (Get-Date) - $lastPublish
        if ($age.TotalHours -gt $STALE_AFTER_HOURS) { $isStale = $true }
    }

    $brief = if (-not $nasOk) {
        "${OpName}: nas-unreachable"
    } elseif ($pending) {
        "${OpName}: OVERDUE"
    } elseif (-not $lastPublish) {
        "${OpName}: never"
    } elseif ($isStale) {
        "${OpName}: STALE ($([int]((Get-Date) - $lastPublish).TotalHours)h)"
    } else {
        $age = (Get-Date) - $lastPublish
        $ageStr = if ($age.TotalHours -ge 1) { "$([int]$age.TotalHours)h ago" } else { "just now" }
        "${OpName}: ok ($ageStr)"
    }

    $lines = New-Object System.Collections.Generic.List[string]

    if ($nasOk) {
        $lines.Add("RDM System (NAS):      Available ($NAS_UNC)")
    } else {
        $lines.Add("RDM System (NAS):      NOT AVAILABLE ($NAS_UNC)")
    }

    if ($lastPublish) {
        $age = (Get-Date) - $lastPublish
        $lines.Add("Global index built:    $($lastPublish.ToString('yyyy-MM-dd HH:mm')) ($(Get-HumanDuration $age) ago)")
    } elseif ($nasOk) {
        $lines.Add("Global index built:    Never (no index.html found)")
    } else {
        $lines.Add("Global index built:    Unknown (NAS not reachable)")
    }

    if ($pending) {
        $reason = Get-FinderPendingReason
        $lines.Add("Refresh status:        OVERDUE ($reason) -- run '.\ops run $OpName'")
    } elseif ($isStale) {
        $lines.Add("Refresh status:        STALE (index older than ${STALE_AFTER_HOURS}h) -- check '.\ops logs $OpName'")
    } else {
        $lines.Add("Refresh status:        OK")
    }

    if ($task) {
        $lines.Add("Scheduled task:        $TASK_NAME ($($task.State))")
    } else {
        $lines.Add("Scheduled task:        Not configured (run '.\ops schedule $OpName')")
    }

    return @{
        Name    = $OpName
        Label   = $OpLabel
        Ok      = ($nasOk -and -not $pending -and -not $isStale -and $null -ne $lastPublish)
        Pending = $pending
        Brief   = $brief
        Lines   = $lines.ToArray()
    }
}

# -- Op-Verify ---------------------------------------------------------------

function Op-Verify {
    $lines = New-Object System.Collections.Generic.List[string]
    $allOk = $true

    # Python present and actually runs.
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
        $lines.Add("[FAIL] Python not found at '$PYTHON' -- fix `$PYTHON in config\finder-refresh.conf.ps1")
        $allOk = $false
    }

    # Generator script present (the cross-repo coupling point).
    $genOk = $false
    if (Test-Path -LiteralPath $GENERATOR) {
        $lines.Add("[PASS] Generator present: $GENERATOR")
        $genOk = $true
    } else {
        $lines.Add("[FAIL] Generator not found: $GENERATOR")
        $lines.Add("       Did the gjesus3-pilot repo move? Update `$GJESUS3_REPO in config\finder-refresh.conf.ps1")
        $allOk = $false
    }

    # Generator + its import chain load under THIS interpreter. '--help' triggers
    # the full import (generate_index -> find_acq -> ingest.registry) and argparse,
    # then exits 0 BEFORE any NAS read or write -- a side-effect-free smoke test.
    if ($pythonOk -and $genOk) {
        & $PYTHON $GENERATOR --help 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $lines.Add("[PASS] Generator imports and parses args cleanly")
        } else {
            $lines.Add("[FAIL] Generator failed to import/parse (exit $LASTEXITCODE) -- run it by hand to see the traceback")
            $allOk = $false
        }
    }

    # NAS reachable + the registry the generator reads is present.
    if (Test-NasReachable) {
        $lines.Add("[PASS] NAS reachable: $NAS_REGISTRIES")
        $reg = Join-Path $NAS_REGISTRIES "registry_raw.csv"
        if (Test-Path -LiteralPath $reg) {
            $lines.Add("[PASS] Registry present: registry_raw.csv")
        } else {
            $lines.Add("[FAIL] registry_raw.csv not found under $NAS_REGISTRIES")
            $allOk = $false
        }
    } else {
        $lines.Add("[FAIL] NAS not reachable: $NAS_REGISTRIES")
        $allOk = $false
    }

    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        $lines.Add("[PASS] Scheduled task '$TASK_NAME' exists (State: $($task.State))")
    } else {
        $lines.Add("[INFO] No scheduled task yet -- run '.\ops schedule $OpName' to create it")
    }

    return @{ Ok = $allOk; Lines = $lines.ToArray() }
}

# -- Op-ScheduleSpec ---------------------------------------------------------

function Op-ScheduleSpec {
    return @{
        TaskName           = $TASK_NAME
        Description        = $OpDescription
        Trigger            = "Daily"
        # 03:00 is fine here. Unlike vps-backup -- which uses 05:00 specifically
        # to dodge the ~03:00 IT backup window that makes its X: network share
        # flaky -- this op's target is the gjesus3 QNAP, which is always mounted
        # and has no such maintenance window. Early morning keeps the ~19 MB
        # rebuild off the working day.
        Time               = "03:00"
        # A healthy rebuild (read ~13.5k registry rows, write the global page +
        # one index per project over SMB) takes a few minutes. Cap well above
        # that so a slow night is not killed, while a wedged run still dies
        # rather than blocking the next day's run.
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

    Write-Log -Level INFO -Message "=== Finder refresh started ==="
    Write-Log -Level INFO -Message "Mode: $(if ($Scheduled) {'Scheduled'} elseif ($DryRun) {'Dry Run'} elseif ($Force) {'Force'} else {'Interactive'})"

    # -- Pre-flight ----------------------------------------------------------

    if (-not (Test-Path -LiteralPath $PYTHON)) {
        Write-Log -Level ERROR -Message "Python not found at '$PYTHON'."
        if ($Scheduled) { Set-FinderPending -Reason "python-missing" }
        exit 1
    }

    if (-not (Test-Path -LiteralPath $GENERATOR)) {
        Write-Log -Level ERROR -Message "Generator not found at '$GENERATOR'. Did the gjesus3-pilot repo move? Update GJESUS3_REPO in config\finder-refresh.conf.ps1."
        if ($Scheduled) { Set-FinderPending -Reason "generator-missing" }
        exit 1
    }

    if (-not (Test-NasReachable)) {
        # Skip cleanly (exit 0) rather than hard-fail: an unreachable NAS is a
        # transient environment condition, exactly like vps-backup's offline
        # drive. The pending flag surfaces it in '.\ops status'.
        Write-Log -Level WARN -Message "NAS '$NAS_REGISTRIES' not reachable. Skipping this run."
        if ($Scheduled) { Set-FinderPending -Reason "nas-unreachable" }
        exit 0
    }

    if ($DryRun) {
        Write-Log -Level INFO -Message "[DRY RUN] Would run: $PYTHON $GENERATOR --nas-root $NAS_UNC --per-project"
        Write-Log -Level INFO -Message "[DRY RUN] That rebuilds the global index.html + every per-project index.html under $NAS_UNC."
        Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS
        return
    }

    # -- Lock ----------------------------------------------------------------

    $gotLock = Get-Lock -Name $OpName
    if (-not $gotLock) {
        Write-Log -Level ERROR -Message "Could not acquire lock. Another run may be in progress."
        exit 1
    }

    $failed = $false

    try {
        Write-Log -Level INFO -Message "Running generator: $PYTHON $GENERATOR --nas-root $NAS_UNC --per-project"

        # Capture all streams; the generator prints progress per index written.
        $genOutput = & $PYTHON $GENERATOR --nas-root $NAS_UNC --per-project 2>&1
        $genExit = $LASTEXITCODE

        foreach ($line in $genOutput) {
            Write-Log -Level INFO -Message "gen: $line"
        }

        if ($genExit -ne 0) {
            Write-Log -Level ERROR -Message "Generator exited $genExit."
            $failed = $true
        } else {
            $published = Get-PublishedIndexTime
            if ($published) {
                Write-Log -Level OK -Message "Global index published: $($published.ToString('yyyy-MM-dd HH:mm'))"
            } else {
                Write-Log -Level WARN -Message "Generator exited 0 but no published index.html was found -- check the NAS."
            }
        }
    } finally {
        Release-Lock -Name $OpName
    }

    # -- Wrap up -------------------------------------------------------------

    if ($failed) {
        if ($Scheduled) {
            Set-FinderPending -Reason "generator-failed"
            Send-Notification -Title "gjesus3 Finder refresh FAILED" -Message "The daily Finder index rebuild failed. Run '.\ops logs finder-refresh' for details."
        }
    } else {
        if (Test-FinderPending) {
            Clear-FinderPending
            Write-Log -Level INFO -Message "Cleared pending flag."
        }
    }

    Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS

    $totalDuration = (Get-Date) - $startTime
    Write-Log -Level OK -Message "=== Finder refresh complete ($(Get-HumanDuration $totalDuration)) ==="

    if ($failed) { exit 1 }
}

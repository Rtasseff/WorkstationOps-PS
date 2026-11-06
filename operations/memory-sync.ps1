# memory-sync.ps1 -- Daily sync of the Claude project memory with its private repo.
# Dot-sourced by ops.ps1. Exposes Op-Run / Op-Status / Op-Verify / Op-ScheduleSpec.
#
# What a run does, in the memory folder (a git working tree, see the conf):
#   1. commit every changed *.md (other sessions write the folder all day);
#   2. pull --rebase from the repo (the other machine's notes);
#   3. push.
# It never resets, checks out over, or deletes anything. A pull that conflicts is
# aborted (git rebase --abort puts the folder back as it was), flagged, and left
# for a person: two sessions edited the same note on two machines.

$OpName        = "memory-sync"
$OpLabel       = "Claude Memory Sync"
$OpDescription = "Daily commit, pull and push of the Claude project memory (private repo)"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\memory-sync.conf.ps1")

# -- Pending / last-success helpers -------------------------------------------

function Get-SyncPendingPath { return (Join-Path $OpsRoot "logs\$OpName.pending") }
function Get-SyncLastPath    { return (Join-Path $OpsRoot "logs\$OpName.last") }
function Test-SyncPending    { return (Test-Path (Get-SyncPendingPath)) }
function Clear-SyncPending {
    $p = Get-SyncPendingPath
    if (Test-Path $p) { Remove-Item $p -Force }
}
function Set-SyncPending {
    param([Parameter(Mandatory)][string]$Reason)
    $Reason | Out-File -FilePath (Get-SyncPendingPath) -Encoding utf8
}
function Get-SyncPendingReason {
    $p = Get-SyncPendingPath
    if (-not (Test-Path $p)) { return $null }
    $r = (Get-Content $p -ErrorAction SilentlyContinue) -join ''
    if (-not $r) { return "unknown" } else { return $r.Trim() }
}
function Get-SyncLastTime {
    $p = Get-SyncLastPath
    if (-not (Test-Path $p)) { return $null }
    return (Get-Item $p).LastWriteTime
}

# -- git ------------------------------------------------------------------------

function Invoke-Git {
    # Run git in the memory folder. Returns @{ Exit; Output }.
    # ops.ps1 sets Stop, and under Stop PS 5.1 aborts on a native command's first
    # stderr line -- and git writes ordinary progress to stderr. So: Continue here.
    param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $GIT -C $MEMORY_DIR @GitArgs 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return @{ Exit = $code; Output = @($out) }
}

function Test-MemoryRepo {
    return ((Test-Path -LiteralPath $GIT) -and (Test-Path -LiteralPath (Join-Path $MEMORY_DIR ".git")))
}

# -- Op-Status -----------------------------------------------------------------

function Op-Status {
    $repoOk  = Test-MemoryRepo
    $pending = Test-SyncPending
    $last    = Get-SyncLastTime
    $task    = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue

    $isStale = $false
    if ($last -and ((Get-Date) - $last).TotalHours -gt $STALE_AFTER_HOURS) { $isStale = $true }

    $dirty = $null
    $aheadBehind = $null
    if ($repoOk) {
        $st = Invoke-Git status --porcelain -- "*.md"
        if ($st.Exit -eq 0) { $dirty = @($st.Output | Where-Object { $_ }).Count }
        $ab = Invoke-Git rev-list --left-right --count "$BRANCH...origin/$BRANCH"
        if ($ab.Exit -eq 0 -and $ab.Output.Count -gt 0) { $aheadBehind = ($ab.Output[0] -split '\s+') }
    }

    $brief = if (-not $repoOk) {
        "${OpName}: not set up"
    } elseif ($pending) {
        "${OpName}: OVERDUE"
    } elseif (-not $last) {
        "${OpName}: never"
    } elseif ($isStale) {
        "${OpName}: STALE ($([int]((Get-Date) - $last).TotalHours)h)"
    } else {
        $age = (Get-Date) - $last
        $ageStr = if ($age.TotalHours -ge 1) { "$([int]$age.TotalHours)h ago" } else { "just now" }
        "${OpName}: ok ($ageStr)"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Memory folder:         $MEMORY_DIR")
    if ($repoOk) {
        $lines.Add("Repository:            OK (git working tree)")
    } else {
        $lines.Add("Repository:            NOT AVAILABLE (no git at '$GIT', or the folder is not a git working tree)")
    }
    if ($null -ne $dirty)  { $lines.Add("Uncommitted notes:     $dirty") }
    if ($aheadBehind)      { $lines.Add("Ahead / behind origin: $($aheadBehind[0]) / $($aheadBehind[1]) (as of the last fetch)") }
    if ($last) {
        $lines.Add("Last successful sync:  $($last.ToString('yyyy-MM-dd HH:mm')) ($(Get-HumanDuration ((Get-Date) - $last)) ago)")
    } else {
        $lines.Add("Last successful sync:  Never")
    }
    if ($pending) {
        $lines.Add("Sync status:           OVERDUE ($(Get-SyncPendingReason)) -- see '.\ops logs $OpName'")
    } elseif ($isStale) {
        $lines.Add("Sync status:           STALE (older than ${STALE_AFTER_HOURS}h)")
    } else {
        $lines.Add("Sync status:           OK")
    }
    if ($task) {
        $lines.Add("Scheduled task:        $TASK_NAME ($($task.State))")
    } else {
        $lines.Add("Scheduled task:        Not configured (run '.\ops schedule $OpName')")
    }

    return @{
        Name    = $OpName
        Label   = $OpLabel
        Ok      = ($repoOk -and -not $pending -and -not $isStale -and $null -ne $last)
        Pending = $pending
        Brief   = $brief
        Lines   = $lines.ToArray()
    }
}

# -- Op-Verify -----------------------------------------------------------------

function Op-Verify {
    $lines = New-Object System.Collections.Generic.List[string]
    $allOk = $true

    if (Test-Path -LiteralPath $GIT) {
        $v = & $GIT --version 2>$null
        $lines.Add("[PASS] git found: $v")
    } else {
        $lines.Add("[FAIL] git not found at '$GIT' -- fix `$GIT in config\memory-sync.conf.ps1 or the instance file")
        $allOk = $false
    }

    if (Test-Path -LiteralPath (Join-Path $MEMORY_DIR ".git")) {
        $lines.Add("[PASS] Memory folder is a git working tree: $MEMORY_DIR")
        $br = Invoke-Git rev-parse --abbrev-ref HEAD
        if ($br.Exit -eq 0 -and $br.Output[0] -eq $BRANCH) {
            $lines.Add("[PASS] On branch $BRANCH")
        } else {
            $lines.Add("[FAIL] Not on branch $BRANCH (got '$($br.Output -join ' ')')")
            $allOk = $false
        }
        $origin = Invoke-Git remote get-url origin
        if ($origin.Exit -eq 0) {
            $lines.Add("[PASS] Remote origin: $($origin.Output[0])")
            $ls = Invoke-Git ls-remote --heads origin $BRANCH
            if ($ls.Exit -eq 0 -and ($ls.Output -join ' ') -match "refs/heads/$BRANCH") {
                $lines.Add("[PASS] Remote reachable, branch $BRANCH present")
            } else {
                $lines.Add("[FAIL] Remote not reachable or branch missing: $($ls.Output -join ' ')")
                $allOk = $false
            }
        } else {
            $lines.Add("[FAIL] No remote 'origin'")
            $allOk = $false
        }
    } else {
        $lines.Add("[FAIL] '$MEMORY_DIR' is not a git working tree (set it up first; see the conf)")
        $allOk = $false
    }

    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        $lines.Add("[PASS] Scheduled task '$TASK_NAME' exists (State: $($task.State))")
    } else {
        $lines.Add("[INFO] No scheduled task yet (run '.\ops schedule $OpName')")
    }

    return @{ Ok = $allOk; Lines = $lines.ToArray() }
}

# -- Op-ScheduleSpec -------------------------------------------------------------

function Op-ScheduleSpec {
    return @{
        TaskName           = $TASK_NAME
        Description        = $OpDescription
        Trigger            = "Daily"
        Time               = $TASK_TIME
        # A sync is a few small files; a wedged network call must not hold the task.
        ExecutionTimeLimit = "PT10M"
    }
}

# -- Op-Run ----------------------------------------------------------------------

function Op-Run {
    param(
        [switch]$Scheduled,
        [switch]$Force,
        [switch]$DryRun
    )

    Initialize-Log -Name $OpName
    Write-Log -Level INFO -Message "=== Memory sync started ==="
    Write-Log -Level INFO -Message "Mode: $(if ($Scheduled) {'Scheduled'} elseif ($DryRun) {'Dry Run'} else {'Interactive'})"

    if (-not (Test-MemoryRepo)) {
        Write-Log -Level ERROR -Message "No git at '$GIT', or '$MEMORY_DIR' is not a git working tree."
        if ($Scheduled) { Set-SyncPending -Reason "not-set-up" }
        exit 1
    }

    if ($DryRun) {
        $st = Invoke-Git status --porcelain -- "*.md"
        $n = @($st.Output | Where-Object { $_ }).Count
        Write-Log -Level INFO -Message "[DRY RUN] $n changed note(s) would be committed, then: pull --rebase origin $BRANCH; push origin $BRANCH."
        foreach ($line in ($st.Output | Where-Object { $_ })) { Write-Log -Level INFO -Message "[DRY RUN]   $line" }
        Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS
        return
    }

    $gotLock = Get-Lock -Name $OpName
    if (-not $gotLock) {
        Write-Log -Level ERROR -Message "Could not acquire lock. Another run may be in progress."
        exit 1
    }

    $failure = $null
    try {
        # 1. Commit what changed.
        $add = Invoke-Git add -A -- "*.md"
        if ($add.Exit -ne 0) { $failure = "add-failed"; $add.Output | ForEach-Object { Write-Log -Level ERROR -Message "git: $_" } }

        if (-not $failure) {
            $diff = Invoke-Git diff --cached --quiet
            if ($diff.Exit -eq 1) {
                $msg = "Memory sync $($env:COMPUTERNAME) $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
                $commit = Invoke-Git commit -q -m $msg
                if ($commit.Exit -ne 0) {
                    $failure = "commit-failed"
                    $commit.Output | ForEach-Object { Write-Log -Level ERROR -Message "git: $_" }
                } else {
                    Write-Log -Level INFO -Message "Committed: $msg"
                }
            } elseif ($diff.Exit -eq 0) {
                Write-Log -Level INFO -Message "No changed notes to commit."
            } else {
                $failure = "diff-failed"
            }
        }

        # 2. Pull the other machine's notes. On a conflict, abort: the folder goes
        #    back exactly as it was, and a person resolves it.
        if (-not $failure) {
            $pull = Invoke-Git pull --rebase origin $BRANCH
            $pull.Output | ForEach-Object { Write-Log -Level INFO -Message "pull: $_" }
            if ($pull.Exit -ne 0) {
                $failure = "pull-conflict"
                $abort = Invoke-Git rebase --abort
                Write-Log -Level ERROR -Message "Pull failed; rebase aborted (exit $($abort.Exit)). The folder is as it was. Resolve by hand."
            }
        }

        # 3. Push.
        if (-not $failure) {
            $push = Invoke-Git push origin $BRANCH
            $push.Output | ForEach-Object { Write-Log -Level INFO -Message "push: $_" }
            if ($push.Exit -ne 0) { $failure = "push-failed" }
        }
    } finally {
        Release-Lock -Name $OpName
    }

    if ($failure) {
        Write-Log -Level ERROR -Message "Memory sync failed: $failure"
        if ($Scheduled) {
            Set-SyncPending -Reason $failure
            Send-Notification -Title "Claude memory sync FAILED" -Message "The daily memory sync failed ($failure). Run '.\ops logs $OpName'."
        }
        Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS
        exit 1
    }

    Get-Date -Format "o" | Out-File -FilePath (Get-SyncLastPath) -Encoding ascii
    Clear-SyncPending
    $count = @((Invoke-Git ls-files).Output).Count
    Write-Log -Level OK -Message "Memory sync OK: $count tracked file(s)."
    Invoke-LogRotation -RetentionDays $LOG_RETENTION_DAYS
}

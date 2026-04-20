# ops.ps1 -- WorkstationOps CLI for Windows
# Usage: .\ops <command> [<operation>] [options]

param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1)][string]$SubCommand,
    [Parameter(ValueFromRemainingArguments)][string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
$OpsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "lib\scheduled-task.ps1")

# -- Operation discovery -----------------------------------------------------

function Get-OpNames {
    $opsDir = Join-Path $OpsRoot "operations"
    if (-not (Test-Path $opsDir)) { return @() }
    return @(Get-ChildItem -Path $opsDir -Filter "*.ps1" -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { $_.BaseName })
}

function Resolve-OpFile {
    param([Parameter(Mandatory)][string]$Name)
    $opFile = Join-Path $OpsRoot "operations\$Name.ps1"
    if (-not (Test-Path $opFile)) {
        $avail = Get-OpNames
        $msg = "Unknown operation: '$Name'."
        if ($avail.Count -gt 0) { $msg += " Available: $($avail -join ', ')" }
        throw $msg
    }
    return $opFile
}

# -- Renderers ---------------------------------------------------------------

function Show-Status {
    param([hashtable]$Status)
    $label = $Status.Label
    Write-Host ""
    Write-Host "  WorkstationOps -- $label" -ForegroundColor Cyan
    Write-Host ("  " + ("=" * (18 + $label.Length))) -ForegroundColor Cyan
    Write-Host ""
    foreach ($line in $Status.Lines) {
        if ($line -match '^\s*$') {
            Write-Host ""
        } elseif ($line -match '(NOT AVAILABLE|OVERDUE|Never|FAIL|Not configured)') {
            Write-Host "  $line" -ForegroundColor Yellow
        } elseif ($line -match '(Available|\bOK\b|Ready|PASS)' -and $line -notmatch 'NOT AVAILABLE') {
            Write-Host "  $line" -ForegroundColor Green
        } else {
            Write-Host "  $line"
        }
    }
    Write-Host ""
}

function Show-BriefStatus {
    param([hashtable]$Status)
    $color = if ($Status.Brief -match 'offline|FAIL') {
        "Red"
    } elseif (-not $Status.Ok) {
        "Yellow"
    } else {
        "Green"
    }
    Write-Host $Status.Brief -ForegroundColor $color
}

function Show-Verify {
    param([string]$Label, [hashtable]$Result)
    Write-Host ""
    Write-Host "  WorkstationOps -- Verify: $Label" -ForegroundColor Cyan
    Write-Host ""
    foreach ($line in $Result.Lines) {
        if ($line -match '^\[FAIL\]') {
            Write-Host "  $line" -ForegroundColor Red
        } elseif ($line -match '^\[WARN\]') {
            Write-Host "  $line" -ForegroundColor Yellow
        } elseif ($line -match '^\[PASS\]') {
            Write-Host "  $line" -ForegroundColor Green
        } else {
            Write-Host "  $line"
        }
    }
}

# -- Commands ----------------------------------------------------------------

function Invoke-Status {
    $brief = ($ExtraArgs -contains "--brief") -or ($SubCommand -eq "--brief")
    $target = if ($SubCommand -and $SubCommand -notmatch '^--') { $SubCommand } else { $null }

    $names = if ($target) { @($target) } else { Get-OpNames }
    if ($names.Count -eq 0) {
        Write-Host "No operations registered in operations\" -ForegroundColor Yellow
        return
    }

    foreach ($name in $names) {
        try {
            $opFile = Resolve-OpFile -Name $name
            . $opFile
            $st = Op-Status
            if ($brief) { Show-BriefStatus -Status $st } else { Show-Status -Status $st }
        } catch {
            if ($brief) {
                Write-Host "${name}: error -- $_" -ForegroundColor Red
            } else {
                Write-Host ""
                Write-Host "  [ERROR] ${name}: $_" -ForegroundColor Red
                Write-Host ""
            }
        }
    }
}

function Invoke-Verify {
    $target = if ($SubCommand) { $SubCommand } else { $null }
    $names = if ($target) { @($target) } else { Get-OpNames }

    if ($names.Count -eq 0) {
        Write-Host "No operations registered in operations\" -ForegroundColor Yellow
        return
    }

    $allOk = $true
    foreach ($name in $names) {
        try {
            $opFile = Resolve-OpFile -Name $name
            . $opFile
            $res = Op-Verify
            Show-Verify -Label $OpLabel -Result $res
            if (-not $res.Ok) { $allOk = $false }
        } catch {
            Write-Host "  [ERROR] ${name}: $_" -ForegroundColor Red
            $allOk = $false
        }
    }

    Write-Host ""
    Write-Host "  PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
    Write-Host ""
    if ($allOk) {
        Write-Host "  All checks passed." -ForegroundColor Green
    } else {
        Write-Host "  Some checks failed. See above." -ForegroundColor Red
    }
    Write-Host ""
}

function Invoke-Schedule {
    $target = if ($SubCommand) { $SubCommand } else { $null }
    $names = if ($target) { @($target) } else { Get-OpNames }

    foreach ($name in $names) {
        $opFile = Resolve-OpFile -Name $name
        . $opFile
        $spec = Op-ScheduleSpec
        if (-not $spec) {
            Write-Host "Operation '$name' is always-manual (no schedule)." -ForegroundColor Yellow
            continue
        }
        $res = Register-OpTask -Spec $spec -OpsRoot $OpsRoot -OpName $name
        Write-Host "$($res.Verb) scheduled task '$($res.TaskName)' for $name." -ForegroundColor Green
        $schedLine = "  Trigger: $($spec.Trigger)"
        if ($spec.ContainsKey('DayOfMonth')) { $schedLine += " (day $($spec.DayOfMonth))" }
        $schedLine += " at $($spec.Time)"
        Write-Host $schedLine
        Write-Host "  Verify in Task Scheduler (taskschd.msc) under '$($res.TaskName)'"
    }
}

function Invoke-Unschedule {
    $target = if ($SubCommand) { $SubCommand } else { $null }
    $names = if ($target) { @($target) } else { Get-OpNames }

    foreach ($name in $names) {
        $opFile = Resolve-OpFile -Name $name
        . $opFile
        $spec = Op-ScheduleSpec
        if (-not $spec) { continue }
        $removed = Unregister-OpTask -TaskName $spec.TaskName
        if ($removed) {
            Write-Host "Removed scheduled task '$($spec.TaskName)'." -ForegroundColor Green
        } else {
            Write-Host "Scheduled task '$($spec.TaskName)' does not exist." -ForegroundColor Yellow
        }
    }
}

function Invoke-Run {
    if (-not $SubCommand) {
        $avail = Get-OpNames
        Write-Host "Usage: .\ops run <operation> [options]" -ForegroundColor Red
        if ($avail.Count -gt 0) {
            Write-Host "Available operations: $($avail -join ', ')"
        }
        exit 1
    }

    try {
        $opFile = Resolve-OpFile -Name $SubCommand
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
    . $opFile

    $splat = @{}
    if ($ExtraArgs -contains "--scheduled") { $splat['Scheduled'] = $true }
    if ($ExtraArgs -contains "--force")     { $splat['Force']     = $true }
    if ($ExtraArgs -contains "--dry-run")   { $splat['DryRun']    = $true }

    Op-Run @splat
}

function Invoke-Logs {
    $target = $null
    $n = 50

    if ($SubCommand) {
        if ($SubCommand -match '^\d+$') {
            $n = [int]$SubCommand
        } else {
            $target = $SubCommand
        }
    }

    if ($ExtraArgs.Count -gt 0 -and $ExtraArgs[0] -match '^\d+$') {
        $n = [int]$ExtraArgs[0]
    }

    $logDir = Join-Path $OpsRoot "logs"
    $filter = if ($target) { "$target-*.log" } else { "*.log" }
    $latest = Get-ChildItem -Path $logDir -Filter $filter -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $latest) {
        if ($target) {
            Write-Host "No log files found for '$target'." -ForegroundColor Yellow
        } else {
            Write-Host "No log files found." -ForegroundColor Yellow
        }
        return
    }

    Write-Host "--- $($latest.Name) (last $n lines) ---" -ForegroundColor Cyan
    Get-Content $latest.FullName -Tail $n
}

function Invoke-Help {
    $ops = Get-OpNames
    $opList = if ($ops.Count -gt 0) { $ops -join ', ' } else { '(none registered)' }

    Write-Host @"

  WorkstationOps -- Windows operations CLI
  ========================================

  Usage: .\ops <command> [<operation>] [options]

  Commands:
    status [<op>] [--brief]   Show status (aggregate or per-op)
    verify [<op>]             Run pre-flight checks (aggregate or per-op)
    schedule [<op>]           Create/update scheduled task(s)
    unschedule [<op>]         Remove scheduled task(s)
    run <op> [options]        Run operation
        --force               Skip confirmation prompts
        --dry-run             Show what would happen without doing it
        --scheduled           Non-interactive (used by Task Scheduler)
    logs [<op>] [N]           Tail latest log (default 50 lines)
    help                      Show this message

  Registered operations: $opList

  Configuration:   config\<op>.conf.ps1
  Operations:      operations\<op>.ps1
  Logs:            logs\

"@
}

# -- Dispatch ----------------------------------------------------------------

switch ($Command) {
    "status"      { Invoke-Status }
    "verify"      { Invoke-Verify }
    "schedule"    { Invoke-Schedule }
    "unschedule"  { Invoke-Unschedule }
    "run"         { Invoke-Run }
    "logs"        { Invoke-Logs }
    "help"        { Invoke-Help }
    "--help"      { Invoke-Help }
    ""            { Invoke-Help }
    default       {
        Write-Host "Unknown command: '$Command'. Run '.\ops help' for usage." -ForegroundColor Red
        exit 1
    }
}

# scheduled-task.ps1 -- Generic Task Scheduler COM wrappers for WorkstationOps
# Dot-source this file; consumers pass a spec hashtable.

function Register-OpTask {
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][string]$OpsRoot,
        [Parameter(Mandatory)][string]$OpName
    )

    # Required spec keys: TaskName, Description, Trigger
    #                     Time -- required for Monthly/Daily, meaningless for Logon
    # Optional:           DayOfMonth (Monthly), DaysInterval (Daily),
    #                     Delay (Logon, ISO-8601 duration),
    #                     ExecutionTimeLimit (ISO-8601 duration, default P3D;
    #                     use PT0S for a service op that must never be killed)
    $required = @('TaskName','Description','Trigger')
    if ($Spec.Trigger -ne 'Logon') { $required += 'Time' }
    foreach ($key in $required) {
        if (-not $Spec.ContainsKey($key)) {
            throw "Register-OpTask: spec missing required key '$key'"
        }
    }

    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $folder = $svc.GetFolder('\')

    $verb = "Created"
    try { $folder.GetTask($Spec.TaskName) | Out-Null; $verb = "Updated" } catch {}

    $taskDef = $svc.NewTask(0)
    $taskDef.RegistrationInfo.Description = $Spec.Description
    $taskDef.Settings.Enabled = $true
    $taskDef.Settings.AllowDemandStart = $true
    $taskDef.Settings.StartWhenAvailable = $true
    $taskDef.Settings.DisallowStartIfOnBatteries = $false
    $taskDef.Settings.StopIfGoingOnBatteries = $false
    # Per-op cap: a wedged run self-terminates rather than lingering (and
    # blocking the next run under MultipleInstancesPolicy = IgnoreNew). Ops that
    # legitimately run long (e.g. wsl-backup export) set a larger value; ops
    # that omit it keep the historical 3-day ceiling.
    $execLimit = if ($Spec.ContainsKey('ExecutionTimeLimit')) { [string]$Spec.ExecutionTimeLimit } else { "P3D" }
    $taskDef.Settings.ExecutionTimeLimit = $execLimit

    # Logon triggers have no start time, so this must not run unconditionally --
    # $Spec.Time.Split() on a missing key would throw before reaching the switch.
    $startBoundary = $null
    if ($Spec.ContainsKey('Time') -and $Spec.Time) {
        $hh, $mm = $Spec.Time.Split(':')
        $startBoundary = (Get-Date -Hour ([int]$hh) -Minute ([int]$mm) -Second 0).ToString("yyyy-MM-ddTHH:mm:ss")
    }

    switch ($Spec.Trigger) {
        "Monthly" {
            $trigger = $taskDef.Triggers.Create(4)  # TASK_TRIGGER_MONTHLY
            $dayOfMonth = if ($Spec.ContainsKey('DayOfMonth')) { [int]$Spec.DayOfMonth } else { 1 }
            $trigger.DaysOfMonth = [int][math]::Pow(2, $dayOfMonth - 1)
            $trigger.MonthsOfYear = 4095  # all 12 months
            $trigger.StartBoundary = $startBoundary
        }
        "Daily" {
            $trigger = $taskDef.Triggers.Create(2)  # TASK_TRIGGER_DAILY
            $trigger.DaysInterval = if ($Spec.ContainsKey('DaysInterval')) { [int]$Spec.DaysInterval } else { 1 }
            $trigger.StartBoundary = $startBoundary
        }
        "Logon" {
            # For long-running SERVICE ops (e.g. molecubes-tunnel) that must be up
            # whenever the workstation is, without anyone remembering to start them.
            $trigger = $taskDef.Triggers.Create(9)  # TASK_TRIGGER_LOGON
            # Scope to THIS user. Without UserId the trigger fires on ANY user's
            # logon, which would start the op under accounts it was never meant for.
            $trigger.UserId = "$env:USERDOMAIN\$env:USERNAME"
            # Networking and WSL are not necessarily ready the instant the shell is.
            # The op retries on its own, but a short delay keeps the log clean.
            if ($Spec.ContainsKey('Delay')) { $trigger.Delay = [string]$Spec.Delay }
        }
        default {
            throw "Register-OpTask: unsupported Trigger '$($Spec.Trigger)'. Supported: Monthly, Daily, Logon"
        }
    }

    $opsScript = Join-Path $OpsRoot "ops.ps1"
    $action = $taskDef.Actions.Create(0)  # TASK_ACTION_EXEC
    $action.Path = "powershell.exe"
    $action.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$opsScript`" run $OpName --scheduled"
    $action.WorkingDirectory = $OpsRoot

    # 6 = create or update, 3 = interactive logon only
    $folder.RegisterTaskDefinition($Spec.TaskName, $taskDef, 6, $null, $null, 3) | Out-Null

    return @{ TaskName = $Spec.TaskName; Verb = $verb }
}

function Unregister-OpTask {
    param(
        [Parameter(Mandatory)][string]$TaskName
    )

    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $folder = $svc.GetFolder('\')

    try {
        $folder.GetTask($TaskName) | Out-Null
        $folder.DeleteTask($TaskName, 0)
        return $true
    } catch {
        return $false
    }
}

function Get-OpTaskState {
    param(
        [Parameter(Mandatory)][string]$TaskName
    )
    return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

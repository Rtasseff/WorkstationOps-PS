# scheduled-task.ps1 -- Generic Task Scheduler COM wrappers for WorkstationOps
# Dot-source this file; consumers pass a spec hashtable.

function Register-OpTask {
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][string]$OpsRoot,
        [Parameter(Mandatory)][string]$OpName
    )

    # Required spec keys: TaskName, Description, Trigger, Time
    # Optional:          DayOfMonth (for Monthly)
    foreach ($key in @('TaskName','Description','Trigger','Time')) {
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
    $taskDef.Settings.ExecutionTimeLimit = "P3D"

    $hh, $mm = $Spec.Time.Split(':')
    $startBoundary = (Get-Date -Hour ([int]$hh) -Minute ([int]$mm) -Second 0).ToString("yyyy-MM-ddTHH:mm:ss")

    switch ($Spec.Trigger) {
        "Monthly" {
            $trigger = $taskDef.Triggers.Create(4)  # TASK_TRIGGER_MONTHLY
            $dayOfMonth = if ($Spec.ContainsKey('DayOfMonth')) { [int]$Spec.DayOfMonth } else { 1 }
            $trigger.DaysOfMonth = [int][math]::Pow(2, $dayOfMonth - 1)
            $trigger.MonthsOfYear = 4095  # all 12 months
            $trigger.StartBoundary = $startBoundary
        }
        default {
            throw "Register-OpTask: unsupported Trigger '$($Spec.Trigger)'. Supported: Monthly"
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

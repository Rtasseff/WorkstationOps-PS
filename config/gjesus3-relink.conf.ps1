# gjesus3-relink.conf.ps1 -- Configuration for the gjesus3 deferred project-link pass
# Dot-sourced by operations\gjesus3-relink.ps1.

# -- Schedule hold ------------------------------------------------------------
# This op writes to gjesus3 production unattended. While this is $false,
# Op-ScheduleSpec returns $null, so not even a bare '.\ops schedule' can register
# it. Set to $true on 2026-11-03: Ryan confirmed nightly running directly, and
# gj3-handoff signed off the relink_pending.py fix (merge 17520fa). To pause it, set
# this back to $false and run '.\ops unschedule gjesus3-relink' BEFORE the change.
$SCHEDULE_CONFIRMED = $true

# -- Cross-repo coupling ------------------------------------------------------
# The same values as config\finder-refresh.conf.ps1. If the gjesus3-pilot repo or
# Python moves, update both files. '.\ops verify' fails loudly if either is wrong.
$GJESUS3_REPO   = "C:\Users\rtasseff\OneDrive - CIC biomaGUNE\projects\DataInfra\gjesus3-archive\gjesus3-pilot"
$PYTHON         = "C:\Users\rtasseff\AppData\Local\Microsoft\WindowsApps\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\python.exe"

# Addressed by UNC, not J:, because a scheduled context may have no drive mappings.
# J: is only a mapping of \\GJESUS3\gjesus3, so this is the same SMB share.
# True hard links through this path were proven in the NAS sandbox on 2026-11-03.
$NAS_UNC        = "\\GJESUS3\gjesus3\gjesus3-data"

# An open row older than this means the nightly pass is not draining the worklist.
# 30h leaves margin over the 24h cadence, so status reports STALE.
$STALE_AFTER_HOURS  = 30

# Log rotation -- this op's own logs only.
$LOG_RETENTION_DAYS = 90

# Task Scheduler job. 02:30 so new links exist before the 03:00 finder-refresh.
$TASK_NAME      = "WorkstationOps-gjesus3-relink"
$TASK_TIME      = "02:30"

# -- Per-machine overrides ---------------------------------------------------
# config\instance.local.ps1 (gitignored) may reset any value above for this
# machine. It is read last, so it wins. See config\instance.example.ps1.
$InstanceOverrides = Join-Path $OpsRoot "config\instance.local.ps1"
if (Test-Path $InstanceOverrides) { . $InstanceOverrides }

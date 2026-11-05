# wsl-backup.conf.ps1 — Configuration for WSL distro backup
# Dot-sourced by backup scripts. Edit values here to customize.

# WSL distro name (as shown by 'wsl -l -v')
$DISTRO_NAME        = "Ubuntu"

# Destination directory for .tar exports
# D:\ is local (not backed up); this is a secondary backup. The primary
# is the live WSL distro on C:\, and critical files inside WSL are
# separately synced to X:\backup\wsl by an in-WSL workstation op.
$BACKUP_DEST        = "D:\backup\wsl-gold"

# Drive letter to check for availability before backup
$BACKUP_DRIVE       = "D:\"

# Number of most recent exports to keep (older ones are deleted)
$BACKUP_RETENTION   = 1

# Delete log files older than this many days
$LOG_RETENTION_DAYS = 90

# Task Scheduler job name
$TASK_NAME          = "WorkstationOps-WSL-Backup"

# Task Scheduler trigger. Fires daily so the overdue reminder repeats; the op itself
# does nothing unless this month's export is missing (due from the 1st at $TASK_TIME).
$TASK_SCHEDULE      = "Daily"

# Time of day for the scheduled task (24h format)
$TASK_TIME          = "14:00"

# On a manual run, GPU utilization at or above this means typing the distro name is
# required to stop WSL, rather than just answering y
$GPU_BUSY_PERCENT   = 30

# -- Per-machine overrides ---------------------------------------------------
# config\instance.local.ps1 (gitignored) may reset any value above for this
# machine. It is read last, so it wins. See config\instance.example.ps1.
$InstanceOverrides = Join-Path $OpsRoot "config\instance.local.ps1"
if (Test-Path $InstanceOverrides) { . $InstanceOverrides }

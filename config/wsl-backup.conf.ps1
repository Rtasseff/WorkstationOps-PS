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

# Task Scheduler trigger: Monthly on the 1st
$TASK_SCHEDULE      = "Monthly"

# Time of day for the scheduled task (24h format)
$TASK_TIME          = "14:00"

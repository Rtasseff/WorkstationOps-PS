# vps-backup.conf.ps1 -- Configuration for VPS ReDIB backup pull
# Dot-sourced by operations\vps-backup.ps1.

# SSH host alias defined in %USERPROFILE%\.ssh\config
$VPS_HOST           = "vps"

# Remote directory holding the redib_<kind>_<YYYYMMDD>_<HHMMSS>.<ext> files
$VPS_REMOTE_DIR     = "/home/deploy/backups/redib"

# Kinds to pull. Each entry defines:
#   Kind:  filename kind segment (redib_<Kind>_...)
#   Ext:   filename extension (no leading dot)
#   Label: human label for status output
$VPS_BACKUP_KINDS   = @(
    @{ Kind = "db";    Ext = "sql.gz"; Label = "Database" }
    @{ Kind = "files"; Ext = "tar.gz"; Label = "Files"    }
)

# Local destination (IT-managed drive; they handle retention/offsite)
$BACKUP_DRIVE       = "X:\"
$BACKUP_DEST        = "X:\backup\ReDIB-Portal"

# -- Timeouts ----------------------------------------------------------------
# Every ssh/scp call runs under a wall-clock cap (Invoke-BoundedNative). These
# exist because ssh's own -o ConnectTimeout bounds connection SETUP only: on
# 2026-08-12 and 2026-08-13 the reachability probe blocked for 32 hours against
# a 10-second ConnectTimeout, Task Scheduler killed the run at its
# ExecutionTimeLimit, and the failure produced no log line, no pending flag and
# no notification -- two backups silently missed.
#
# Keep the worst case comfortably under Op-ScheduleSpec's ExecutionTimeLimit
# (PT10M / 600s), or the scheduler kills the supervisor before the op can record
# why it failed and the silent-failure bug is back:
#   probe + (list + copy) per kind = 20 + (30 + 120) * 2 = 320s
$SSH_PROBE_TIMEOUT_SECONDS = 20
$SSH_CMD_TIMEOUT_SECONDS   = 30
$SCP_TIMEOUT_SECONDS       = 120

# Age at which the freshest local backup counts as STALE in Op-Status. The VPS
# snapshots at 02:00 and this op pulls at 05:00, so a healthy file peaks at ~27h
# old just before the next run; 36h flags a genuinely missed cycle without
# false-alarming on a normal one.
$STALE_AFTER_HOURS  = 36

# Log rotation (this op's own logs only)
$LOG_RETENTION_DAYS = 90

# Task Scheduler job name (used if/when scheduled)
$TASK_NAME          = "WorkstationOps-vps-backup"

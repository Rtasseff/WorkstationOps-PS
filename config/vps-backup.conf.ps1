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

# Log rotation (this op's own logs only)
$LOG_RETENTION_DAYS = 90

# Task Scheduler job name (used if/when scheduled)
$TASK_NAME          = "WorkstationOps-vps-backup"

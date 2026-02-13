# WorkstationOps (Windows)

Monthly full exports of the Ubuntu WSL distro to a network drive (`K:\rtasseff\wsl-gold`), complementing the WSL-side `ops` CLI that handles daily rsync backups.

## How it works

- **Task Scheduler** fires on the 1st of each month at 2:00 PM
- If WSL is **stopped** (rare): auto-exports silently, then restarts WSL
- If WSL is **running** (typical): logs the skip, sets a "backup pending" flag, and pops a Windows tray notification reminding you to run `.\ops run backup` when convenient
- `.\ops status` always shows whether a backup is overdue
- Interactive `.\ops run backup` prompts before terminating WSL, exports, then offers to restart

This gives monthly nudges without ever killing WSL unexpectedly.

## Quick start

```powershell
# 1. Verify prerequisites
.\ops verify

# 2. Create the monthly scheduled task
.\ops schedule

# 3. Check status anytime
.\ops status

# 4. Run a backup manually
.\ops run backup
```

## Command reference

| Command | Description |
|---------|-------------|
| `.\ops status` | Drive mount state, last backup time/size, schedule state, overdue warning |
| `.\ops status --brief` | Single-line for PowerShell prompt integration |
| `.\ops verify` | Pre-flight checks: wsl.exe, distro registered, K: drive, Task Scheduler |
| `.\ops schedule` | Create/update monthly Task Scheduler job (idempotent) |
| `.\ops unschedule` | Remove Task Scheduler job |
| `.\ops run backup` | Interactive backup (prompts before terminating WSL) |
| `.\ops run backup --force` | Terminate WSL without prompting |
| `.\ops run backup --dry-run` | Show what would happen without doing it |
| `.\ops logs [N]` | Show last N lines of latest log (default 50) |
| `.\ops help` | Usage info |

## Restore procedure

To restore a WSL distro from a backup export:

```powershell
# 1. (Optional) Unregister the existing distro if corrupted
wsl --unregister Ubuntu

# 2. Import the backup — choose your install location
wsl --import Ubuntu C:\Users\rtasseff\WSL\Ubuntu K:\rtasseff\wsl-gold\wsl-ubuntu-2026-02-01.tar

# 3. Set the default user (replace 'rtasseff' with your WSL username)
ubuntu config --default-user rtasseff

# 4. Verify
wsl -d Ubuntu -- whoami
```

**Note:** `--import` creates a new ext4.vhdx from the tar. Your original install location (typically `%LOCALAPPDATA%\Packages\...`) is not used after import — the path in step 2 becomes the new location.

## Configuration

Edit `config\wsl-backup.conf.ps1`:

| Variable | Default | Description |
|----------|---------|-------------|
| `$DISTRO_NAME` | `Ubuntu` | WSL distro name (as shown by `wsl -l -v`) |
| `$BACKUP_DEST` | `K:\rtasseff\wsl-gold` | Destination for .tar exports |
| `$BACKUP_DRIVE` | `K:\` | Drive to check for availability |
| `$BACKUP_RETENTION` | `2` | Keep N most recent exports |
| `$LOG_RETENTION_DAYS` | `90` | Delete logs older than this |
| `$TASK_NAME` | `WorkstationOps-WSL-Backup` | Task Scheduler job name |
| `$TASK_TIME` | `14:00` | Scheduled time (24h format) |

## Notes

- **Export size:** Typically 8-25 GB depending on distro contents
- **Export duration:** 10-30+ minutes depending on distro size and network speed
- **WSL termination:** `wsl --export` requires the distro to be stopped. The interactive mode always prompts before terminating. The scheduled mode never terminates — it defers and notifies instead.
- **Logs:** Written to `logs\wsl-backup-YYYY-MM-DD.log`, auto-rotated after 90 days

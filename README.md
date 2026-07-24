# WorkstationOps (Windows)

A small CLI for recurring Windows-side workstation operations. Each operation
(backup, sync, cleanup, …) is a self-contained script under `operations/`
with its own config, schedule, logs, and pending-flag. The dispatcher
(`ops.ps1`) discovers operations automatically and exposes the same commands
(`status`, `verify`, `schedule`, `run`, `logs`) against each of them or in
aggregate.

## Operations

| Name | Cadence | Purpose |
|------|---------|---------|
| `wsl-backup` | Monthly (1st @ 14:00) | Full export of the Ubuntu WSL distro to `D:\backup\wsl-gold` (local secondary backup; see `D:\README.md`) |
| `vps-backup` | Daily @ 03:00 | Pull latest ReDIB DB + files backups from the VPS to `X:\backup\ReDIB-Portal` |
| `finder-refresh` | Daily @ 03:00 | Rebuild the gjesus3 researcher Finder index (global + per-project `index.html`) from the registry |

### wsl-backup

- **Task Scheduler** fires on the 1st of each month at 2:00 PM
- If WSL is **stopped** (rare): auto-exports silently, then restarts WSL
- If WSL is **running** (typical): logs the skip, sets a "backup pending" flag, and pops a Windows tray notification reminding you to run `.\ops run wsl-backup` when convenient
- `.\ops status wsl-backup` always shows whether a backup is overdue
- Interactive `.\ops run wsl-backup` prompts before terminating WSL, exports, then offers to restart

This gives monthly nudges without ever killing WSL unexpectedly.

### vps-backup

- **Task Scheduler** fires every day at 3:00 AM
- Uses Windows-native OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe` + `scp.exe`) via a `Host vps` alias in `%USERPROFILE%\.ssh\config`
- For each configured *kind* (`db`, `files`), finds the latest `redib_<kind>_YYYYMMDD_HHMMSS.<ext>` on the VPS, pulls it, and prunes older local copies (IT manages historical retention on the drive)
- If the remote latest is already present locally (same name + size), logs "already have it" and skips the copy
- If the VPS is unreachable or `X:` isn't mounted, sets a pending flag surfaced by `.\ops status`

**Known: `X:` may be unavailable at 03:00.** Observed 2026-04-30 through 2026-05-12: the scheduled 03:00 run found `X:\` not mounted each night, deferred with pending reason `drive-unavailable`, and a manual `.\ops run vps-backup` during business hours pulled the missed exports successfully. The first occurrence is normal (workstation asleep, share remount delayed, etc.); if it recurs more than a couple more times, consider shifting the time in `Op-ScheduleSpec` (`operations\vps-backup.ps1`) to an hour when the workstation is reliably logged in.

### finder-refresh

- **Task Scheduler** fires every day at 3:00 AM
- Rebuilds the researcher Finder from the live registry: the global `registries\index.html` plus one `index.html` per project, written back to the gjesus3 NAS over UNC
- **The generator itself lives in the separate gjesus3-pilot repo** (`tools\generate_index.py`). This op owns only the schedule, logging, and health signal; gjesus3-pilot owns how a Finder is built. The single coupling path is `$GJESUS3_REPO` in `config\finder-refresh.conf.ps1` -- `.\ops verify finder-refresh` fails loudly if that repo is moved
- Unlike `vps-backup`, 3:00 AM is fine here: the target QNAP is always mounted and has no IT maintenance window
- **Health signal:** `.\ops status finder-refresh` reports the published index's build time. If it is older than 30h (a missed daily run) status shows STALE; a failed scheduled run sets a pending flag and a tray notification, both surfaced by `.\ops status`
- If the NAS is unreachable at 03:00 the run defers cleanly (pending flag) instead of failing hard, exactly like `vps-backup` with an offline drive

## Quick start

```powershell
# 1. Verify prerequisites
.\ops verify

# 2. Create the monthly scheduled task
.\ops schedule

# 3. Check status anytime
.\ops status

# 4. Run a backup manually
.\ops run wsl-backup
```

## Command reference

Commands accept an optional `<op>` argument. With no argument they run against
every registered operation; with an argument they target just that one.

| Command | Description |
|---------|-------------|
| `.\ops status [<op>]` | Drive mount state, last backup time/size, schedule state, overdue warning |
| `.\ops status [<op>] --brief` | Single-line per op, suitable for prompt integration |
| `.\ops verify [<op>]` | Pre-flight checks per operation |
| `.\ops schedule [<op>]` | Create/update each op's Task Scheduler job (idempotent) |
| `.\ops unschedule [<op>]` | Remove Task Scheduler job(s) |
| `.\ops run <op>` | Run the named operation interactively |
| `.\ops run <op> --force` | Skip confirmation prompts |
| `.\ops run <op> --dry-run` | Show what would happen without doing it |
| `.\ops logs [<op>] [N]` | Show last N lines of the latest log (default 50) |
| `.\ops help` | Usage info, lists registered operations |

## Restore procedure

To restore a WSL distro from a backup export:

```powershell
# 1. (Optional) Unregister the existing distro if corrupted
wsl --unregister Ubuntu

# 2. Import the backup — choose your install location
wsl --import Ubuntu C:\Users\rtasseff\WSL\Ubuntu D:\backup\wsl-gold\wsl-ubuntu-2026-02-01.tar

# 3. Set the default user (replace 'rtasseff' with your WSL username)
ubuntu config --default-user rtasseff

# 4. Verify
wsl -d Ubuntu -- whoami
```

**Note:** `--import` creates a new ext4.vhdx from the tar. Your original install location (typically `%LOCALAPPDATA%\Packages\...`) is not used after import — the path in step 2 becomes the new location.

## Configuration

### `config\wsl-backup.conf.ps1`

| Variable | Default | Description |
|----------|---------|-------------|
| `$DISTRO_NAME` | `Ubuntu` | WSL distro name (as shown by `wsl -l -v`) |
| `$BACKUP_DEST` | `D:\backup\wsl-gold` | Destination for .tar exports (local D:, not backed up; secondary to in-WSL X: sync) |
| `$BACKUP_DRIVE` | `D:\` | Drive to check for availability |
| `$BACKUP_RETENTION` | `1` | Keep N most recent exports |
| `$LOG_RETENTION_DAYS` | `90` | Delete logs older than this |
| `$TASK_NAME` | `WorkstationOps-WSL-Backup` | Task Scheduler job name |
| `$TASK_SCHEDULE` | `Monthly` | Trigger type |
| `$TASK_TIME` | `14:00` | Scheduled time (24h format) |

### `config\vps-backup.conf.ps1`

| Variable | Default | Description |
|----------|---------|-------------|
| `$VPS_HOST` | `vps` | Host alias in `%USERPROFILE%\.ssh\config` |
| `$VPS_REMOTE_DIR` | `/home/deploy/backups/redib` | Remote directory holding the backup files |
| `$VPS_BACKUP_KINDS` | db + files | Array of `@{Kind; Ext; Label}` entries to pull |
| `$BACKUP_DEST` | `X:\backup\ReDIB-Portal` | Local destination |
| `$BACKUP_DRIVE` | `X:\` | Drive to check for availability |
| `$LOG_RETENTION_DAYS` | `90` | Delete logs older than this |
| `$TASK_NAME` | `WorkstationOps-vps-backup` | Task Scheduler job name |

Retention is always "keep 1 per kind" for vps-backup — IT manages historical retention on the destination drive, so local pruning avoids duplicating that.

### SSH setup for vps-backup

The op uses Windows-native OpenSSH with a `Host vps` block in `%USERPROFILE%\.ssh\config`:

```
Host vps
    HostName <ip-or-dns>
    User <remote-user>
    IdentityFile ~/.ssh/id_ed25519_vps
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

The private key must have its NTFS ACL locked down (owner-only, no inheritance), or Windows OpenSSH will refuse to use it:

```powershell
icacls "$env:USERPROFILE\.ssh\id_ed25519_vps" /inheritance:r /grant:r "${env:USERNAME}:(F)"
```

The host's public key must be in `%USERPROFILE%\.ssh\known_hosts` (seed it once via `ssh-keyscan -t ed25519 <ip> >> known_hosts` after verifying the fingerprint).

### `config\finder-refresh.conf.ps1`

| Variable | Default | Description |
|----------|---------|-------------|
| `$GJESUS3_REPO` | `...\projects\RDM\highCap\gjesus3-pilot` | Path to the gjesus3-pilot repo. **The one cross-repo coupling** -- change this line if you move that repo |
| `$PYTHON` | Store-Python 3.13 full path | Python interpreter. A full path, not the bare `python` alias (Task Scheduler PATH is unreliable) |
| `$NAS_UNC` | `\\GJESUS3\gjesus3\gjesus3-data` | gjesus3 NAS container, by UNC (not a mapped drive) |
| `$STALE_AFTER_HOURS` | `30` | Status reports STALE if the published index is older than this |
| `$LOG_RETENTION_DAYS` | `90` | Delete logs older than this |
| `$TASK_NAME` | `WorkstationOps-finder-refresh` | Task Scheduler job name |

The generator is pure standard library, so `finder-refresh` needs no venv or packages -- just the interpreter and the gjesus3-pilot working tree present on disk.

## Notes

- **wsl-backup export size:** Typically 8-25 GB depending on distro contents; 10-30+ minutes per run
- **WSL termination:** `wsl --export` requires the distro to be stopped. The interactive mode always prompts before terminating. The scheduled mode never terminates — it defers and notifies instead.
- **vps-backup pull size:** Typically tiny (< 1 MB); a few seconds per run
- **Logs:** Written to `logs\<op>-YYYY-MM-DD.log`, auto-rotated after 90 days per each op's `$LOG_RETENTION_DAYS`

## Adding a new operation

Drop two files and the dispatcher picks it up automatically:

1. `operations\<name>.ps1` — dot-sources `lib\common-utils.ps1` and its own
   config, and defines `$OpName` / `$OpLabel` / `$OpDescription` plus four
   functions: `Op-Run`, `Op-Status`, `Op-Verify`, `Op-ScheduleSpec`
   (return `$null` from the last if the op is always-manual).
2. `config\<name>.conf.ps1` — operation-specific variables.

See `operations\wsl-backup.ps1` for the reference shape. Shared utilities
(`Initialize-Log`, `Write-Log`, `Get-Lock`, `Send-Notification`,
`Test-DriveAvailable`, etc.) live in `lib\common-utils.ps1`.

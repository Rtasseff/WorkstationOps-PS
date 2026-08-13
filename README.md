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
| `molecubes-tunnel` | At logon (long-running service) | Windows-side landing pad for the reverse SSH tunnel from the Molecubes PET/CT acquisition box |
| `omero-web-forward` | At logon (long-running service) | Forward Windows port 4080 to OMERO.web inside WSL for the gjesus3 researcher pilot |

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

### molecubes-tunnel

The **first long-running service op** in this repo -- every other operation is a batch
job that exits. `Op-Run` blocks indefinitely and is stopped with `.\ops stop
molecubes-tunnel` (or Ctrl-C in its window).

**That window is the process, not a leftover.** Every tunnel-engine instance puts an
ordinary PowerShell window on the desktop -- one per running op -- even though the
scheduled task launches it `-WindowStyle Hidden`. The flag is not being ignored by this
code; Windows 11 hands the console to Windows Terminal, which does not honor it (see
[Backlog](#backlog)). Closing the window closes the console and kills the supervisor
with it. Stop a service op with `.\ops stop <op>`, never the X.

- **Why:** the Molecubes PET/CT acquisition box (`192.168.0.180`) is NAT'd behind its
  own router and cannot be reached inbound. It dials out to this workstation and we
  ride that connection backward. Physical access to the box is rare and scheduled,
  which is what makes this worth the machinery
- **Why WSL:** Windows has no SSH server installable without admin, which this account
  does not have. So sshd runs inside WSL and a userspace Python forwarder
  (`lib\tcp_forward.py`) exposes it on `0.0.0.0`. Ubuntu 24.04's
  `sshd-socket-generator` reads `Port` from `sshd_config`, so **sshd listens on 2200,
  not 22**
- **The generator of domain meaning lives elsewhere,** exactly as with `finder-refresh`:
  this op owns the Windows half (keepalive, forwarder, ports, health, logs); the
  gjesus3-pilot repo owns what the box is and the procedure carried to it, under
  `equipment\nuclear-imaging\`
- **Health signal:** `.\ops status molecubes-tunnel` probes the workstation's **LAN
  address**, not loopback, and requires a real SSH banner back. Both details matter --
  `wslrelay.exe` mirrors WSL's sshd onto `127.0.0.1:2200`, so a loopback probe reports
  OK even when every forwarder is dead, and a bare TCP connect succeeds even when the
  upstream is gone
- **Self-healing:** the supervisor holds WSL awake with a tagged keepalive
  (`env WSOPS_TUNNEL=<op> sleep infinity` -- the tag lets each tunnel instance find
  its own; without a keepalive the VM idles out, taking sshd with it while the
  forwarders keep answering), re-reads the WSL IP on every rebuild (it is reassigned
  each WSL boot), and rebuilds the whole set if the banner stops arriving
- **Scheduled at logon** (`WorkstationOps-MolecubesTunnel`), because the landing pad being
  down is the one failure with **no recovery** from inside the acquisition box's
  restricted-access room — the operator gets a single entry per visit and cannot step
  out to fix it, so the whole visit is lost. This is the first `Logon`-triggered op;
  the trigger type was added to `lib\scheduled-task.ps1` for it, scoped to this user so
  it does not fire on anyone else's logon, with a 1-minute delay so WSL and the network
  are ready. **`ExecutionTimeLimit` is `PT0S` (no limit)** — the library default of
  `P3D` would kill a persistent service after three days, which is precisely the silent
  failure the schedule exists to prevent. Reverse it with
  `.\ops unschedule molecubes-tunnel`
- **A workstation reboot is not a lost visit.** The acquisition box's LaunchAgent retries
  every 30s indefinitely, so once the landing pad is back the tunnel re-establishes on
  its own — no trip to the box required

**Before every trip to the acquisition box, run the acceptance test.** Access to the box is rare and
scheduled; a failure found at the desk costs minutes, the same failure found at the box costs the
slot and a week.

```powershell
.\ops run molecubes-tunnel          # in its own window, leave running
wsl -d Ubuntu -- bash "/mnt/c/Users/rtasseff/OneDrive - CIC biomaGUNE/WorkstationOps/setup/test-tunnel-path.sh"
```

It exercises the whole chain using a workstation-local rehearsal key in place of the box: sshd in
WSL, both forwarder ports **on the LAN address**, key authentication, that the key **cannot** get a
shell or bind a port outside `permitlisten`, that it **can** open the real `-R` tunnel, that traffic
flows back through it, and that it survives idle (the regression test for the 5-second forwarder
timeout). Exit code 0 means safe to travel.

`setup\harden-tunnel-key.sh` is the companion: run it after the box pushes its key with
`ssh-copy-id`, which always writes an unrestricted entry.

**Generalized 2026-08-10** — the second consumer appeared (the gjesus3 OMERO pilot),
so the op's mechanics were reworked into **`lib\tunnel-engine.ps1`**, exactly as the
note that used to stand here required (rework, not copy). An op file is now a thin
instance definition: header vars + `config\<op>.conf.ps1` + probe choice, then a
dot-source of the engine, which provides Op-Run/Stop/Status/Verify/ScheduleSpec.
Instances share the engine and `lib\tcp_forward.py` but never processes: each has its
own supervisor, lock, logs, scheduled task, tagged WSL keepalive, and forwarders
(matched by script path **and** listen ports), so stopping one cannot take down
another. Probes are per-instance (`ssh-banner` or `http`); there is deliberately no
bare-TCP-connect probe (the forwarder accepts connections even when its upstream is
dead). Runtime behavior of `molecubes-tunnel` was preserved and re-verified 9/9 by
`setup\test-tunnel-path.sh` after the rework. The MRI acquisition machine remains the
likely next instance.

### Tunnel port allocation

One Windows listen port belongs to exactly one instance; `Op-Run` refuses a port that
is already bound by a foreign process, and `Op-Verify` reports it as a collision.
Claim ports here before adding an instance.

| Port | Instance | Purpose |
|------|----------|---------|
| 2200 | `molecubes-tunnel` | reverse-SSH landing pad (primary) |
| 8000 | `molecubes-tunnel` | fallback from the Django-era known-good port |
| 4080 | `omero-web-forward` | OMERO.web for the gjesus3 pilot |
| 4081 | `xnat-web-forward` | XNAT for the gjesus3 DICOM trial |

### omero-web-forward

Second instance of the tunnel engine: a plain HTTP forward,
`0.0.0.0:4080 -> OMERO.web` in WSL, so researchers on the hardwired network can
browse the gjesus3 OMERO pilot at `http://10.10.2.195:4080/`.

- **Probe is `http`:** reads a real `HTTP/` status line from
  `/webclient/login/` through the forwarder -- same rigor as the SSH banner
- **This op does not manage the containers.** The OMERO stack (docker-compose in
  WSL) belongs to the omero-trial repo
  (`~/projects/miniProjects/202608_omero-trial` in WSL, github `Rtasseff/omero-trial`);
  the pilot's runbook is `gjesus3-tools\06_omero_trial_runbook.md`. If the stack is
  down this op reports FAIL and keeps probing until it returns
- **Scheduled at logon** (`WorkstationOps-OmeroWebForward`), same service-op contract
  as molecubes-tunnel (`PT0S`, user-scoped trigger, 1-minute delay)
- When the pilot ends: `.\ops unschedule omero-web-forward`, `.\ops stop
  omero-web-forward`, delete `operations\omero-web-forward.ps1` +
  `config\omero-web-forward.conf.ps1`, and free port 4080 in the table above

### xnat-web-forward

Third instance of the tunnel engine: a plain HTTP forward,
`0.0.0.0:4081 -> XNAT nginx` in WSL, so researchers on the hardwired network can
reach the gjesus3 XNAT trial at `http://10.10.2.195:4081/`. This is the DICOM arm
of the image-server spike; `omero-web-forward` is the microscopy arm.

- **Probe is `http`:** reads a real `HTTP/` status line from
  `/app/template/Login.vm` through the forwarder
- **This op does not manage the containers.** The XNAT stack (docker-compose in
  WSL) belongs to the xnat-trial repo
  (`~/projects/miniProjects/202608_xnat-trial` in WSL, github `Rtasseff/xnat-trial`);
  the trial's runbook is `gjesus3-tools\08_xnat_trial_runbook.md`. If the stack is
  down this op reports FAIL and keeps probing until it returns
- **Health interval is 30s**, same reasoning as omero-web-forward: humans in a
  browser rather than a scarce physical visit, so a 30s detection gap is fine and
  keeps probe chatter low
- **Scheduled at logon** (`WorkstationOps-XnatWebForward`), same service-op contract
  as the other instances (`PT0S`, user-scoped trigger, 1-minute delay)
- When the trial ends: `.\ops unschedule xnat-web-forward`, `.\ops stop
  xnat-web-forward`, delete `operations\xnat-web-forward.ps1` +
  `config\xnat-web-forward.conf.ps1`, and free port 4081 in the table above

### xnat-web-forward

Third instance of the tunnel engine, added 2026-08-11: a plain HTTP forward,
`0.0.0.0:4081 -> XNAT nginx` in WSL, so researchers on the hardwired network can
browse the gjesus3 XNAT trial (the DICOM arm of the image-server spike) at
`http://10.10.2.195:4081/`.

- **Probe is `http`:** reads a real `HTTP/` status line from
  `/app/template/Login.vm` (the XNAT login page) through the forwarder
- **This op does not manage the containers.** The XNAT stack (docker-compose in
  WSL) belongs to the xnat-trial repo
  (`~/projects/miniProjects/202608_xnat-trial` in WSL, github `Rtasseff/xnat-trial`);
  the trial's runbook is `gjesus3-tools\08_xnat_trial_runbook.md`. If the stack is
  down this op reports FAIL and keeps probing until it returns
- **Scheduled at logon** (`WorkstationOps-XnatWebForward`), same service-op contract
  as the other instances (`PT0S`, user-scoped trigger, 1-minute delay)
- When the trial ends: `.\ops unschedule xnat-web-forward`, `.\ops stop
  xnat-web-forward`, delete `operations\xnat-web-forward.ps1` +
  `config\xnat-web-forward.conf.ps1`, and free port 4081 in the table above

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
| `.\ops stop <op>` | Stop a long-running service op. Requires an explicit op name, and only works for ops that define `Op-Stop` (batch ops report that they have none) |
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
| `$SSH_PROBE_TIMEOUT_SECONDS` | `20` | Wall-clock cap on the reachability probe |
| `$SSH_CMD_TIMEOUT_SECONDS` | `30` | Wall-clock cap on each remote listing |
| `$SCP_TIMEOUT_SECONDS` | `120` | Wall-clock cap on each file transfer |
| `$STALE_AFTER_HOURS` | `36` | Age at which the newest backup is reported STALE |
| `$LOG_RETENTION_DAYS` | `90` | Delete logs older than this |
| `$TASK_NAME` | `WorkstationOps-vps-backup` | Task Scheduler job name |

Retention is always "keep 1 per kind" for vps-backup — IT manages historical retention on the destination drive, so local pruning avoids duplicating that.

**Every ssh and scp call is bounded, and a killed run leaves evidence.** Both were
added on 2026-08-13 after two backups went missing without a trace. `ssh`'s own
`-o ConnectTimeout` covers connection *setup* only: the reachability probe
established a connection, the path died, and ssh sat on the socket for 32 hours
against a 10-second setting. Task Scheduler then killed the run at its
`ExecutionTimeLimit`, which unwinds nothing — so no `Set-VpsPending` branch ran, no
notification fired, and `.\ops status` still read `ok`. Three defences now:

- `Invoke-BoundedNative` runs every ssh/scp under a wall-clock cap and kills the
  child on expiry. Keep the caps summing well under `ExecutionTimeLimit` (`PT10M`),
  or the scheduler kills the op before it can report why it failed
- `-o ServerAliveInterval=5 -o ServerAliveCountMax=3` on every call, so ssh usually
  gives up on its own with a real exit code rather than being killed
- The pending flag is written *before* the first call that can block and cleared on
  success, so a killed run shows up as `OVERDUE`. Independently, a newest backup
  older than `$STALE_AFTER_HOURS` reports `STALE` and fails `.\ops status`

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
| `$GJESUS3_REPO` | `...\projects\DataInfra\gjesus3-archive\gjesus3-pilot` | Path to the gjesus3-pilot repo. **The one cross-repo coupling** -- change this line if you move that repo |
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

## Backlog

Known and deliberately not fixed. Low priority -- recorded so it is not rediagnosed.

- **Service ops are not truly headless.** `molecubes-tunnel` and `omero-web-forward`
  each show a visible PowerShell window, one per running instance, despite
  `lib\scheduled-task.ps1` launching them with `-WindowStyle Hidden`. The flag *is*
  honored -- it governs the classic conhost window, and Windows 11 no longer uses one.
  The default terminal application ("Let Windows decide" = Windows Terminal) triggers a
  console handoff: conhost starts in pseudoconsole mode and passes the session to the
  running `WindowsTerminal.exe`, which opens a normal visible window. Neither
  `-WindowStyle Hidden` nor Task Scheduler's own "Hidden" checkbox reaches it. Cosmetic,
  but the windows accumulate and invite being closed -- which kills the tunnel.

  Diagnosed 2026-08-11. Two checks give *misleading* answers and should not be repeated:
  `GetConsoleWindow()` reports the supervisor's window as not visible (true, and
  irrelevant -- that is the chrome-less pseudoconsole), and an `EnumWindows` scan
  filtered to the supervisor's conhost finds nothing (the visible window belongs to
  `WindowsTerminal.exe`, unrelated to the op by parentage). What identifies them: exactly
  one Windows Terminal window titled with the full `powershell.exe` v1.0 path per running
  service op, matching the only classic `powershell.exe` processes parented to Task
  Scheduler's `svchost.exe`.

  Two fixes exist, both declined for now: set Default terminal application to "Windows
  Console Host" (user-wide side effect for a cosmetic gain), or move the tasks to "Run
  whether user is logged on or not" (S4U -- session 0, no window possible, and it would
  additionally make the tunnels survive logout). The second is worth revisiting after the
  acquisition-box visit; it is a runtime-behavior change and WSL-from-session-0 is
  unverified here, so it is not something to try while the box has never exercised the
  tunnel.

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

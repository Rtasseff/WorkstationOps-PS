# ref-configs: which machine runs what

*Started 2026-11-19, when the gjesus3 jobs moved to Box A.*

WorkstationOps runs on more than one machine. All of them share **one repository and one `origin/main`**: the same code,
the same tracked configs. What makes a machine different is one file that is **not** in git,
`config\instance.local.ps1`. It names the machine, lists the only operations that machine may run, and holds that
machine's own values. This folder keeps a **reference copy** of each machine's file, so a lost or broken file can be
rebuilt, and the table below says who runs what.

## The machines

| Machine | Address | Its file here | Operations it runs | When |
|---|---|---|---|---|
| **dev workstation** (`BMG-RTASSEFF`, `$INSTANCE_NAME` "dev-workstation") | 10.10.2.195 | [`instance.dev-workstation.ps1`](instance.dev-workstation.ps1) | `memory-sync` | daily 22:30 |
| | | | `molecubes-tunnel` (the NI Mac's landing pad) | at sign-in, long-running. **Being retired** once Box A's tunnel has proven itself; see gjesus3's STATUS |
| | | | `omero-web-forward` (4080), `xnat-web-forward` (4081), `oadata-web-forward` (4082) | at sign-in, long-running |
| | | | `vps-backup` | daily 05:00 |
| | | | `wsl-backup` | daily 14:00 |
| **Box A** (`bmg-wks-ryan`) | 10.10.3.195 | [`instance.bmg-wks-ryan.ps1`](instance.bmg-wks-ryan.ps1) | `gjesus3-relink` | daily 02:30 |
| | | | `finder-refresh` | daily 03:00 |
| | | | `memory-sync` | daily 22:45 (after dev's) |
| | | | `molecubes-tunnel` (the NI Mac's landing pad) | at sign-in, long-running |

The gjesus3 jobs (`gjesus3-relink`, `finder-refresh`) moved from dev to Box A on 2026-11-19. Each of them runs on
**one** machine only: two machines running the same registry job would race each other. `memory-sync` deliberately
runs on both, at different times, because each machine's Claude sessions write their own memory folder.

Every scheduled operation runs **only while Ryan is signed in** on that machine. After a restart, sign in again (Remote
Desktop is fine; close the window rather than signing out).

## How the per-machine file works

- **The gate.** `ops.ps1` lists, runs and schedules only the operations in `$ENABLED_OPS`. Without the file it does
  nothing but show help, so a fresh clone can never start the whole set by accident.
- **The overrides.** The file is read again **at the end of each machine-specific config**: `finder-refresh`,
  `gjesus3-relink`, `memory-sync`, `molecubes-tunnel` and `wsl-backup`. Any value set in it wins over that tracked config.
  The web forwards and `vps-backup` don't read it. The tracked configs still hold the dev workstation's values (its paths,
  its Store Python, its address); other machines override what differs.
- **Scope an override to its operation** when the variable name is shared, e.g. `$TASK_TIME`, which `gjesus3-relink` and
  `memory-sync` both read:

  ```powershell
  if ($OpName -eq 'memory-sync') { $TASK_TIME = "22:45" }
  ```

  An unscoped `$TASK_TIME = "22:45"` would also move the relink the next time it is scheduled.
- **ASCII only** (PowerShell 5.1), and **no secrets**: names, paths, addresses and times only. Credentials live where
  each operation documents them, never in this file or in this folder.

## Keeping the copies current

- **Whenever a machine's `config\instance.local.ps1` changes, update its copy here in the same commit**, and the "As
  of" date in the copy's header.
- **The copies are never read by `ops.ps1`.** Only `config\instance.local.ps1` is, so editing a copy changes nothing on
  any machine.

## Rebuilding a machine's role

1. Clone the repository (or `git pull` an existing clone) on `main`.
2. Copy that machine's reference file to `config\instance.local.ps1`. Drop the reference header if you like.
3. `.\ops verify`: each enabled operation's checks should pass.
4. `.\ops schedule <op>` for each enabled operation. **Scheduled tasks are not in the copy**; they are made here.
5. For a long-running operation (a tunnel, a web forward), start it the way it is scheduled, through Task Scheduler. Do
   not start it as a hidden or detached process from Git Bash: IT's antivirus blocks that pattern.

## Changing WorkstationOps code

Code changes are made and pushed from the dev workstation (the live folder in OneDrive). A machine only gets a change
when it pulls: on Box A, `git pull --ff-only`, then `.\ops verify` for the operations that change touches. Box A's
Claude session (`gj3-boxa`) does that pull.

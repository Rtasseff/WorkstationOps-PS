# CLAUDE.md — notes for Claude Code

Quick pointers. For full architecture, read `README.md` — this file only
captures non-obvious constraints.

## Runtime

- **PowerShell 5.1** (Windows-built-in) is the target. Do not use PS 7-only
  syntax (null-coalescing `??`, ternary `?:`, pipeline chain `&&`/`||`).
- **ASCII only in string literals.** A prior bug was smart-quotes and em-
  dashes getting mangled on PS 5.1 (commit 7f15dd8). Use straight quotes,
  hyphens, and ASCII arrows (`->`) in anything that PowerShell parses.
- Run from bash with:
  `powershell.exe -ExecutionPolicy Bypass -File ./ops.ps1 <cmd>`

## Testing safely

- **Never run `.\ops run wsl-backup` without `--dry-run`** during
  development. A real run terminates the user's WSL distro, takes 10-30
  minutes, and writes a 20+ GB tar to `D:\backup\wsl-gold`.
- `.\ops verify`, `.\ops status`, `.\ops status --brief`, and `.\ops run
  wsl-backup --dry-run` are all safe and fast.

## The operation contract

Each `operations/<name>.ps1` must define:

- Header vars: `$OpName`, `$OpLabel`, `$OpDescription`
- Functions: `Op-Run`, `Op-Status`, `Op-Verify`, `Op-ScheduleSpec`
  - `Op-Status` / `Op-Verify` return hashtables, never print to host
  - `Op-Run` may call `exit` — that terminates `ops.ps1` (intentional)
  - `Op-ScheduleSpec` returns `$null` for always-manual ops

`ops.ps1` sets `$OpsRoot` before dot-sourcing an op file. Op files should
reference `$OpsRoot` from the parent scope (with a fallback for standalone
dot-sourcing). All ops share `lib/common-utils.ps1` and
`lib/scheduled-task.ps1` — never duplicate their helpers.

## If the task involves molecubes-tunnel, read the handoff first

**`operations/molecubes-tunnel.HANDOFF.md`** — cold-start briefing: current state, what is verified
vs never tested, a symptom → cause → action triage table, and the traps that have already cost a
wasted trip to the acquisition box. Several of those traps produce *misleading* symptoms (three look
like authentication failures and are not), so diagnosing from first principles tends to go wrong.
Read it before debugging anything tunnel-related.

## Tunnel instances share an engine

`molecubes-tunnel` and `omero-web-forward` are thin instance definitions over
**`lib\tunnel-engine.ps1`** (generalized 2026-08-10). An instance op file sets
header vars, dot-sources its conf, assigns the engine's config contract, then
dot-sources the engine -- which defines all five Op-* functions. Rules:

- **Assign EVERY contract input in every instance file, even empty ones**
  (`''` / `$false` / `@()`): ops.ps1 dot-sources all ops into one session for
  aggregate status, so an unassigned variable inherits the previous op's value.
- **Never probe by bare TCP connect** -- the forwarder accepts connections with
  a dead upstream. Probes are `ssh-banner` or `http`; add new kinds to
  `Test-UpstreamProbe`, not ad hoc.
- **Keepalives are tagged** via `env WSOPS_TUNNEL=<op> sleep infinity`. Do not
  "simplify" to `sh -c "... # tag"` -- wsl.exe/Start-Process quoting splits the
  string and the keepalive exits within seconds (found the hard way 2026-08-10).
- **One listen port, one instance.** Claim ports in README.md "Tunnel port
  allocation"; Op-Run refuses foreign-bound ports.

## Service ops (long-running) vs batch ops

The tunnel instances are ops whose `Op-Run` **never returns** — each supervises a
persistent landing pad / forward. Consequences:

- It defines an optional **`Op-Stop`**, dispatched by `.\ops stop <op>`. `Op-Stop` is
  optional by design; batch ops omit it and `stop` says so rather than failing.
- `stop` **requires an explicit op name.** Op files are dot-sourced into the caller's
  session, so iterating all ops would let one op's `Op-Stop` leak onto the next.
- It reuses `logs/<op>.lock` as the supervisor's PID handle. Started interactively the
  supervisor is just `pwsh.exe`/`powershell.exe`, with the op name nowhere in its
  command line — the lock file is the only reliable way to find it.
- **A service op must set `ExecutionTimeLimit = "PT0S"`** (no limit). The default `P3D`
  in `Register-OpTask` silently kills a persistent service after three days.
- `lib\scheduled-task.ps1` now supports a **`Logon`** trigger (`TASK_TRIGGER_LOGON`)
  alongside Monthly/Daily. `Time` is required for the calendar triggers and ignored for
  `Logon`; the validation and the start-boundary calculation are both conditional, so a
  `Logon` spec that omits `Time` is valid and a `Daily` one that omits it still throws.
  Logon triggers are scoped to the registering user via `UserId` — without that they
  fire on **any** user's logon.

## Scheduled-task gotcha

If you change how `ops.ps1` dispatches `run <op>` (argument shape, op name,
etc.), the existing Task Scheduler entry keeps its old action args and will
fail on next firing. Run `.\ops schedule <op>` after any such change to
re-register.

## Logs and state

- `logs/<op>-YYYY-MM-DD.log` — per-op daily log
- `logs/<op>.lock` — process lock
- `logs/<op>.pending` — deferral flag; file content is the reason string
- Legacy `logs/backup-pending` is still recognized by `wsl-backup` for one
  cycle during migration; drop that compatibility once you've seen a
  successful run under the new name.

## Don't

- Don't reintroduce a `backup` alias for `wsl-backup` — the project
  deliberately uses full op names.
- Don't print from `Op-Status` / `Op-Verify`; return structured data and let
  the dispatcher render it.
- Don't commit without explicit user request.

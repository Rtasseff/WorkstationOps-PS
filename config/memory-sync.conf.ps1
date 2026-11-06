# memory-sync.conf.ps1 -- Configuration for the daily Claude project-memory sync.
# Dot-sourced by operations\memory-sync.ps1.
#
# The memory folder is its own git working tree, pushed to the PRIVATE repo
# Rtasseff/gjesus3-memory (set up 2026-11-06). This op commits what changed, pulls
# the other machine's notes, and pushes. Each machine has its own memory folder
# (the folder name is keyed to where its Claude sessions run), so Box A sets its
# own MEMORY_DIR in config\instance.local.ps1.

# The memory folder on THIS machine (a git working tree on branch $BRANCH).
$MEMORY_DIR = "C:\Users\rtasseff\.claude\projects\C--Users-rtasseff-OneDrive---CIC-biomaGUNE-projects-DataInfra-gjesus3-archive-gjesus3-pilot\memory"

# git -- a FULL path, as for python in finder-refresh: the Task Scheduler logon
# context has an unreliable PATH. '.\ops verify memory-sync' checks it.
$GIT = "C:\Users\rtasseff\AppData\Local\Programs\Git\cmd\git.exe"

$BRANCH = "main"

# Status reports STALE when the last successful sync is older than this (hours).
$STALE_AFTER_HOURS = 30

# Log rotation -- this op's own logs only.
$LOG_RETENTION_DAYS = 90

# Task Scheduler job. 22:30 keeps clear of the 02:00-05:30 RDM jobs and the 14:00
# WSL backup. StartWhenAvailable catches up a missed run.
$TASK_NAME = "WorkstationOps-memory-sync"
$TASK_TIME = "22:30"

# -- Per-machine overrides ---------------------------------------------------
# config\instance.local.ps1 (gitignored) may reset any value above for this
# machine. It is read last, so it wins. See config\instance.example.ps1.
$InstanceOverrides = Join-Path $OpsRoot "config\instance.local.ps1"
if (Test-Path $InstanceOverrides) { . $InstanceOverrides }

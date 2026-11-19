# REFERENCE COPY of config\instance.local.ps1 on Box A (bmg-wks-ryan, 10.10.3.195).
# As of 2026-11-19. Not read by ops.ps1: only config\instance.local.ps1 is. To rebuild this
# machine's role, copy this file to config\instance.local.ps1 there (see ref-configs\README.md).
# Update this copy whenever that file changes.
# ------------------------------------------------------------------------------------------

# instance.local.ps1 -- Box A (bmg-wks-ryan). Gitignored; template: instance.example.ps1.
#
# Read twice: once by ops.ps1 (for the name and the list), and again at the end of
# each config\<op>.conf.ps1, so any value set here wins over the tracked config.
# ASCII only (PowerShell 5.1). Never delete or rename this file on a live machine.
#
# Decommissioning: removing an op from ENABLED_OPS does NOT remove its Windows
# scheduled task. Run '.\ops unschedule <op>' first, then remove it here.

# Printed in every status header, so you always know which box you are on.
$INSTANCE_NAME = "bmg-wks-ryan"

# The ONLY operations this machine lists, runs or schedules.
$ENABLED_OPS = @('gjesus3-relink', 'finder-refresh', 'memory-sync', 'molecubes-tunnel')   # Phase 5 + 6, Ryan's go 2026-11-19; one job at a time

# Per-machine overrides of values in config\<op>.conf.ps1.
$GJESUS3_REPO = "C:\Users\rtasseff\projects\RDM_MFB\rdm"
$PYTHON       = "C:\Users\rtasseff\AppData\Local\Programs\Python\Python313\python.exe"

# memory-sync: this machine's memory folder and git (only memory-sync reads these).
$MEMORY_DIR   = "C:\Users\rtasseff\.claude\projects\C--Users-rtasseff-projects-RDM-MFB\memory"
$GIT          = "C:\Program Files\Git\cmd\git.exe"
# 22:45, clear of dev's 22:30 push. Scoped by $OpName because gjesus3-relink also
# reads $TASK_TIME (02:30) and this file is read at the end of every op's conf.
if ($OpName -eq 'memory-sync') { $TASK_TIME = "22:45" }

# molecubes-tunnel (Phase 6, 2026-11-19): this box's LAN address, WSL user and distro.
# LISTEN_PORTS (2200, 8000) and the WSL sshd port 2200 stay as in the tracked conf.
if ($OpName -eq 'molecubes-tunnel') {
    $WORKSTATION_IP = "10.10.3.195"
    $SSH_USER       = "rtasseff"
    $WSL_DISTRO     = "Ubuntu"
}

# The $SCHEDULE_CONFIRMED = $false hold (2026-11-06) was removed on Ryan's Phase 5 go, 2026-11-19.

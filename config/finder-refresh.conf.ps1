# finder-refresh.conf.ps1 -- Configuration for the gjesus3 Finder index rebuild
# Dot-sourced by operations\finder-refresh.ps1.

# -- Cross-repo coupling ------------------------------------------------------
# This operation runs a generator script that lives in the SEPARATE gjesus3-pilot
# repo. The split is deliberate: WorkstationOps owns the SCHEDULE, the run log,
# and the health signal; gjesus3-pilot owns the generator (how a Finder index is
# built from the registry). If you ever MOVE the gjesus3-pilot repo on this
# workstation, update $GJESUS3_REPO below -- it is the ONLY line here that needs
# to change. '.\ops verify finder-refresh' checks this path and fails loudly if
# it is wrong.
$GJESUS3_REPO   = "C:\Users\rtasseff\OneDrive - CIC biomaGUNE\projects\RDM\highCap\gjesus3-pilot"

# Python interpreter -- a FULL path, NOT the bare 'python' WindowsApps alias.
# The Task Scheduler logon context has an unreliable PATH (the same reason
# vps-backup hard-paths ssh.exe), so the alias can fail to resolve there. This
# is the resolved Store-Python 3.13 executable; if Python is upgraded and this
# path moves, '.\ops verify finder-refresh' catches it with a clear message. The
# generator is pure standard library -- no venv or third-party packages needed.
$PYTHON         = "C:\Users\rtasseff\AppData\Local\Microsoft\WindowsApps\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\python.exe"

# The gjesus3 NAS (QNAP) container, addressed by UNC -- NOT a mapped drive. A
# scheduled context may have no drive mappings, but the UNC always resolves. The
# generator reads registries\ from here and writes index.html back here (the
# global page plus one per project).
$NAS_UNC        = "\\GJESUS3\gjesus3\gjesus3-data"

# Freshness / overdue threshold (hours). The job runs daily, so the published
# global index should never be older than this. 30h leaves margin over the 24h
# cadence (a slow night, or a missed run recovered by StartWhenAvailable) before
# status reports STALE.
$STALE_AFTER_HOURS  = 30

# Log rotation -- this op's own logs only.
$LOG_RETENTION_DAYS = 90

# Task Scheduler job name.
$TASK_NAME          = "WorkstationOps-finder-refresh"

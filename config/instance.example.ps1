# instance.example.ps1 -- template for config\instance.local.ps1 (gitignored).
#
# Copy this file to config\instance.local.ps1 on each machine and edit it.
# ops.ps1 does nothing but help without that file, so a fresh clone on a new
# machine can never list, run or schedule the whole set by accident.
#
# It is read twice: once by ops.ps1 (for the name and the list), and again at the
# end of each machine-specific config\<op>.conf.ps1, so any value set here wins
# over the tracked config. ASCII only (PowerShell 5.1).
#
# Decommissioning: removing an op from ENABLED_OPS does NOT remove its Windows
# scheduled task. Run '.\ops unschedule <op>' first, then remove it here.

# Printed in every status header, so you always know which box you are on.
$INSTANCE_NAME = "dev-workstation"

# The ONLY operations this machine lists, runs or schedules.
$ENABLED_OPS = @(
    "finder-refresh",
    "gjesus3-relink"
)

# Optional per-machine overrides of values in config\<op>.conf.ps1.
# $GJESUS3_REPO   = "D:\gjesus3\gjesus3-pilot"
# $PYTHON         = "C:\Program Files\Python313\python.exe"
# $WORKSTATION_IP = "<this machine's address, as the Molecubes box sees it>"

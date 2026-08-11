# omero-web-forward.conf.ps1 -- Declarative config for the OMERO.web forward.
# Keep this file declarative: values only, no logic. Derived paths live in the
# engine (lib\tunnel-engine.ps1).
#
# What this instance is: researchers on the hardwired network browse
# http://10.10.2.195:4080 ; the forwarder relays that Windows port into the
# OMERO.web container inside WSL (gjesus3 omero-trial pilot; code at
# ~/projects/miniProjects/202608_omero-trial in WSL, runbook in
# gjesus3-tools\06_omero_trial_runbook.md).

# -- WSL upstream -------------------------------------------------------------
$WSL_DISTRO  = "Ubuntu"
$TARGET_PORT = 4080          # OMERO.web (docker-compose service 'omeroweb')

# -- Windows-side exposure ----------------------------------------------------
# Port allocation across tunnel instances (also in README.md):
#   2200, 8000 -> molecubes-tunnel ; 4080 -> this op.
$LISTEN_PORTS  = @(4080)
$FORWARDER_REL = "lib\tcp_forward.py"

# -- Identity -----------------------------------------------------------------
$WORKSTATION_IP = "10.10.2.195"   # this machine, as researchers reach it

# -- Supervisor ---------------------------------------------------------------
# The pilot serves humans clicking in a browser, not a scarce once-a-week
# physical visit -- a 30s detection gap is fine and halves the probe chatter
# in the OMERO.web access log.
$HEALTH_INTERVAL_SECONDS = 30

# -- Scheduling ---------------------------------------------------------------
$TASK_NAME = "WorkstationOps-OmeroWebForward"

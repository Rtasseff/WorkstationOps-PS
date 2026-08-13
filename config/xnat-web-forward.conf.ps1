# xnat-web-forward.conf.ps1 -- Declarative config for the XNAT web forward.
# Keep this file declarative: values only, no logic. Derived paths live in the
# engine (lib\tunnel-engine.ps1).
#
# What this instance is: researchers on the hardwired network browse
# http://10.10.2.195:4081 ; the forwarder relays that Windows port into the
# XNAT nginx container inside WSL (gjesus3 xnat-trial, the DICOM arm of the
# image-server spike; code at ~/projects/miniProjects/202608_xnat-trial in
# WSL, runbook in gjesus3-tools\08_xnat_trial_runbook.md).

# -- WSL upstream -------------------------------------------------------------
$WSL_DISTRO  = "Ubuntu"
$TARGET_PORT = 4081          # XNAT nginx (docker-compose service 'xnat-nginx')

# -- Windows-side exposure ----------------------------------------------------
# Port allocation across tunnel instances (also in README.md):
#   2200, 8000 -> molecubes-tunnel ; 4080 -> omero-web-forward ; 4081 -> this op.
$LISTEN_PORTS  = @(4081)
$FORWARDER_REL = "lib\tcp_forward.py"

# -- Identity -----------------------------------------------------------------
$WORKSTATION_IP = "10.10.2.195"   # this machine, as researchers reach it

# -- Supervisor ---------------------------------------------------------------
# Same reasoning as omero-web-forward: humans in a browser, not a scarce
# physical visit -- a 30s detection gap is fine and keeps probe chatter low.
$HEALTH_INTERVAL_SECONDS = 30

# -- Scheduling ---------------------------------------------------------------
$TASK_NAME = "WorkstationOps-XnatWebForward"

# oadata-web-forward.conf.ps1 -- Declarative config for the OAData web forward.
# Keep this file declarative: values only, no logic. Derived paths live in the
# engine (lib\tunnel-engine.ps1).
#
# What this instance is: colleagues on the hardwired network browse
# http://10.10.2.195:4082 ; the forwarder relays that Windows port into the
# OAData web app inside WSL (systemd user service 'oa-web' running
# 'oa web --host 0.0.0.0 --port 4082'; code at ~/projects/OAData in WSL).

# -- WSL upstream -------------------------------------------------------------
$WSL_DISTRO  = "Ubuntu"
$TARGET_PORT = 4082          # oa-web (systemd user service)

# -- Windows-side exposure ----------------------------------------------------
# Port allocation across tunnel instances (also in README.md):
#   2200, 8000 -> molecubes-tunnel ; 4080 -> omero-web-forward ;
#   4081 -> xnat-web-forward ; 4082 -> this op.
$LISTEN_PORTS  = @(4082)
$FORWARDER_REL = "lib\tcp_forward.py"

# -- Identity -----------------------------------------------------------------
$WORKSTATION_IP = "10.10.2.195"   # this machine, as colleagues reach it

# -- Supervisor ---------------------------------------------------------------
# Same reasoning as the other web forwards: humans in a browser, not a scarce
# physical visit -- a 30s detection gap is fine and keeps probe chatter low.
$HEALTH_INTERVAL_SECONDS = 30

# -- Scheduling ---------------------------------------------------------------
$TASK_NAME = "WorkstationOps-OADataWebForward"

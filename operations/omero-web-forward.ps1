# omero-web-forward.ps1 -- serve the gjesus3 OMERO pilot's web UI to the
# hardwired network: Windows 0.0.0.0:4080 -> OMERO.web inside WSL.
# Dot-sourced by ops.ps1. All mechanics live in lib\tunnel-engine.ps1; this file
# is the instance definition: header, config, probe choice.
#
# WHY THIS EXISTS
#   The gjesus3 OMERO pilot (a ~1-month researcher trial) runs in docker-compose
#   inside WSL, which other machines cannot reach directly. Same no-admin
#   userspace-forwarder pattern as molecubes-tunnel, second instance of the
#   generic engine. If the pilot ends, '.\ops unschedule omero-web-forward' and
#   delete this file + its conf; the engine stays for the next consumer.
#
# BOUNDARY
#   THIS op owns the Windows half: keepalive, forwarder, port 4080, health
#   signal, logs. The omero-trial repo (WSL,
#   ~/projects/miniProjects/202608_omero-trial, github Rtasseff/omero-trial)
#   owns the OMERO stack itself; its runbook is gjesus3-tools\
#   06_omero_trial_runbook.md. This op does NOT start or stop the containers --
#   if the stack is down, the op reports FAIL and keeps probing until it
#   returns.
#
# PROBE
#   'http' -- reads a real HTTP status line from OMERO.web through the
#   forwarder. Same rigor as molecubes' SSH banner: a bare TCP connect would
#   report success with the containers dead (the "half up" failure mode).

$OpName        = "omero-web-forward"
$OpLabel       = "OMERO Web Forward (gjesus3 pilot)"
$OpDescription = "Forwards Windows port 4080 to OMERO.web inside WSL for the gjesus3 researcher pilot"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\omero-web-forward.conf.ps1")

# -- Engine inputs (see the config contract in lib\tunnel-engine.ps1) ---------
# Every input is assigned here even when empty: ops.ps1 dot-sources all ops
# into one session, so unassigned values would leak in from the previous op.
$PROBE                  = 'http'            # $TARGET_PORT / $LISTEN_PORTS come from the conf
$PROBE_HTTP_PATH        = '/webclient/login/'
$KEEPALIVE_LEGACY_MATCH = $false
$STATUS_PURPOSE         = "serve the gjesus3 OMERO pilot web UI to the hardwired network"
$STATUS_HINTS_OK        = @(
    "Researchers:  http://${WORKSTATION_IP}:$($LISTEN_PORTS[0])/  (hardwired network only)"
)

. (Join-Path $OpsRoot "lib\tunnel-engine.ps1")

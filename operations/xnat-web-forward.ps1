# xnat-web-forward.ps1 -- serve the gjesus3 XNAT trial's web UI to the
# hardwired network: Windows 0.0.0.0:4081 -> XNAT nginx inside WSL.
# Dot-sourced by ops.ps1. All mechanics live in lib\tunnel-engine.ps1; this file
# is the instance definition: header, config, probe choice.
#
# WHY THIS EXISTS
#   The gjesus3 XNAT trial (the DICOM arm of the image-server spike; the OMERO
#   pilot on 4080 is the microscopy arm) runs in docker-compose inside WSL,
#   which other machines cannot reach directly. Third instance of the generic
#   engine. If the trial ends, '.\ops unschedule xnat-web-forward' and delete
#   this file + its conf; the engine stays.
#
# BOUNDARY
#   THIS op owns the Windows half: keepalive, forwarder, port 4081, health
#   signal, logs. The xnat-trial repo (WSL,
#   ~/projects/miniProjects/202608_xnat-trial, github Rtasseff/xnat-trial)
#   owns the XNAT stack itself; its runbook is gjesus3-tools\
#   08_xnat_trial_runbook.md. This op does NOT start or stop the containers --
#   if the stack is down, the op reports FAIL and keeps probing until it
#   returns.
#
# PROBE
#   'http' -- reads a real HTTP status line from XNAT's login page through the
#   forwarder, same rigor as the other instances: a bare TCP connect would
#   report success with the containers dead (the "half up" failure mode).

$OpName        = "xnat-web-forward"
$OpLabel       = "XNAT Web Forward (gjesus3 trial)"
$OpDescription = "Forwards Windows port 4081 to XNAT nginx inside WSL for the gjesus3 DICOM trial"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\xnat-web-forward.conf.ps1")

# -- Engine inputs (see the config contract in lib\tunnel-engine.ps1) ---------
# Every input is assigned here even when empty: ops.ps1 dot-sources all ops
# into one session, so unassigned values would leak in from the previous op.
$PROBE                  = 'http'            # $TARGET_PORT / $LISTEN_PORTS come from the conf
$PROBE_HTTP_PATH        = '/app/template/Login.vm'
$KEEPALIVE_LEGACY_MATCH = $false
$STATUS_PURPOSE         = "serve the gjesus3 XNAT DICOM trial web UI to the hardwired network"
$STATUS_HINTS_OK        = @(
    "Researchers:  http://${WORKSTATION_IP}:$($LISTEN_PORTS[0])/  (hardwired network only)"
)

. (Join-Path $OpsRoot "lib\tunnel-engine.ps1")

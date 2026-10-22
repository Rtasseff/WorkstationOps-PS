# oadata-web-forward.ps1 -- serve the OAData web app to the hardwired
# network: Windows 0.0.0.0:4082 -> oa-web inside WSL.
# Dot-sourced by ops.ps1. All mechanics live in lib\tunnel-engine.ps1; this file
# is the instance definition: header, config, probe choice.
#
# WHY THIS EXISTS
#   The OAData web app runs inside WSL, which other machines cannot reach
#   directly. Fourth instance of the generic engine. If the app is retired,
#   '.\ops unschedule oadata-web-forward' and delete this file + its conf; the
#   engine stays.
#
# BOUNDARY
#   THIS op owns the Windows half: keepalive, forwarder, port 4082, health
#   signal, logs. The OAData repo (WSL, ~/projects/OAData) owns the app itself,
#   which runs as the systemd user service 'oa-web' (lingering, so it starts
#   with the distro). This op does NOT start or stop the app -- WSL side is
#   'systemctl --user status|restart oa-web'. If the app is down, the op
#   reports FAIL and keeps probing until it returns.
#
# PROBE
#   'http' -- reads a real HTTP status line from /health through the forwarder.
#   /health is unauthenticated and does not redirect: 200 "ok", or 503 when the
#   tracker DB is unreadable (still a real HTTP answer, so the path counts as
#   up; the probe tests the forward, not the app's internals).

$OpName        = "oadata-web-forward"
$OpLabel       = "OAData Web Forward"
$OpDescription = "Forwards Windows port 4082 to the OAData web app inside WSL"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\oadata-web-forward.conf.ps1")

# -- Engine inputs (see the config contract in lib\tunnel-engine.ps1) ---------
# Every input is assigned here even when empty: ops.ps1 dot-sources all ops
# into one session, so unassigned values would leak in from the previous op.
$PROBE                  = 'http'            # $TARGET_PORT / $LISTEN_PORTS come from the conf
$PROBE_HTTP_PATH        = '/health'
$KEEPALIVE_LEGACY_MATCH = $false
$STATUS_PURPOSE         = "serve the OAData web app to the hardwired network"
$STATUS_HINTS_OK        = @(
    "Users:        http://${WORKSTATION_IP}:$($LISTEN_PORTS[0])/  (hardwired network only)"
)

. (Join-Path $OpsRoot "lib\tunnel-engine.ps1")

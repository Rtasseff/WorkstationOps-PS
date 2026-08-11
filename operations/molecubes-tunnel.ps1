# molecubes-tunnel.ps1 -- Windows-side landing pad for a reverse SSH tunnel from the
# Molecubes PET/CT acquisition box (192.168.0.180).
# Dot-sourced by ops.ps1. All mechanics live in lib\tunnel-engine.ps1; this file
# is the instance definition: header, config, probe choice.
#
# WHY THIS EXISTS
#   The Molecubes acquisition box sits behind its own router and cannot be reached
#   inbound. It can dial out, so it opens an outbound SSH connection to this
#   workstation and we ride that connection backward. Physical access to the box is
#   rare and scheduled, which is what makes remote access worth this machinery.
#   Domain context (what the box is, why we reach it) lives in the gjesus3-pilot repo:
#   equipment\nuclear-imaging\live_machine_remote_access.md
#
# BOUNDARY (same discipline as finder-refresh)
#   THIS op owns the Windows half: the WSL keepalive, the forwarder, the ports, the
#   health signal, the logs. The gjesus3-pilot repo owns the domain half: what the
#   Molecubes box is, why we reach it, and the operator procedure carried to it.
#
# GENERALIZED 2026-08-10 (the trigger fired: a second consumer appeared)
#   The op's mechanics were reworked into the config-driven engine
#   lib\tunnel-engine.ps1, exactly as the note that used to stand here required
#   ("rework THIS op, do not copy it"). This instance keeps its op name, task
#   name, ports, lock, logs, and the SSH-banner probe -- runtime behavior is
#   unchanged, re-verified by setup\test-tunnel-path.sh after the rework.
#   Second instance: omero-web-forward (HTTP, port 4080, gjesus3 OMERO pilot).
#   Port allocation across instances: README.md "Tunnel port allocation".
#
# NON-OBVIOUS FAILURE MODES THE ENGINE GUARDS AGAINST (learned here)
#   1. WSL idles out and stops, taking sshd with it, while the Windows forwarders
#      keep listening. TCP connects succeed, every real session then resets. A bare
#      "is the process alive" check cannot see this -- hence the SSH-banner probe.
#   2. The WSL IP is reassigned on every WSL boot, so it is re-read on every rebuild
#      rather than trusted.
#   3. Forwarders orphaned from a dead supervisor keep serving a stale WSL IP, which
#      is worse than nothing. Op-Stop matches them by command line, not parentage.

$OpName        = "molecubes-tunnel"
$OpLabel       = "Molecubes Reverse Tunnel Host"
$OpDescription = "Windows-side landing pad for the reverse SSH tunnel from the Molecubes PET/CT acquisition box"

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

. (Join-Path $OpsRoot "lib\common-utils.ps1")
. (Join-Path $OpsRoot "config\molecubes-tunnel.conf.ps1")

# -- Engine inputs (see the config contract in lib\tunnel-engine.ps1) ---------
# Every input is assigned here even when empty: ops.ps1 dot-sources all ops
# into one session, so unassigned values would leak in from the previous op.
$TARGET_PORT            = $WSL_SSHD_PORT
$PROBE                  = 'ssh-banner'
$PROBE_HTTP_PATH        = ''
# The pre-engine supervisor started keepalives without the op-name tag; keep
# claiming those so a stop during migration does not orphan them. Harmless
# afterwards: only this op ever ran untagged keepalives.
$KEEPALIVE_LEGACY_MATCH = $true
$STATUS_PURPOSE         = "reach the Molecubes PET/CT box ($MOLECUBES_IP) via reverse SSH"
$STATUS_HINTS_OK        = @(
    "From the box: ssh -p $($LISTEN_PORTS[0]) $SSH_USER@$WORKSTATION_IP"
    "Ride it back: ssh -p $TUNNEL_PORT $MOLECUBES_USER@localhost"
)

. (Join-Path $OpsRoot "lib\tunnel-engine.ps1")

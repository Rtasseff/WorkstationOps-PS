# molecubes-tunnel.conf.ps1 -- Declarative config for the Molecubes reverse-tunnel host.
# Keep this file declarative: values only, no logic. Derived paths live in the op.

# -- WSL landing pad ----------------------------------------------------------
# sshd runs inside WSL because Windows has no SSH server we can install without
# admin rights. Ubuntu 24.04's sshd-socket-generator reads Port from sshd_config
# and rewrites ssh.socket, so sshd listens on 2200, NOT 22.
$WSL_DISTRO    = "Ubuntu"
$WSL_SSHD_PORT = 2200

# -- Windows-side exposure ----------------------------------------------------
# The userspace forwarder relays these Windows ports into WSL's sshd. Two ports
# are opened: 2200 is the intended one; 8000 is a fallback that was the known-good
# port from the Django test-server era, kept in case a future firewall change is
# port-scoped rather than program-scoped. Whoever is at the Molecubes box cannot
# fix the Windows side remotely, so the fallback costs little and saves a trip.
$LISTEN_PORTS  = @(2200, 8000)
$FORWARDER_REL = "lib\tcp_forward.py"

# -- Identities ---------------------------------------------------------------
$WORKSTATION_IP = "10.10.2.195"   # this machine, as the Molecubes box sees it
$SSH_USER       = "rtasseff"      # WSL/Ubuntu account the tunnel authenticates as
$MOLECUBES_IP   = "192.168.0.180" # acquisition box (NAT'd behind its own router)
$MOLECUBES_USER = "molecubes"
$TUNNEL_PORT    = 2222            # reverse listener, bound on WSL loopback

# -- Supervisor ---------------------------------------------------------------
# Seconds between end-to-end health checks. The check reads a real SSH banner
# through the forwarder; a bare process-alive check is not sufficient (see the
# "half up" failure mode in the op header).
$HEALTH_INTERVAL_SECONDS = 15

# -- Scheduling ---------------------------------------------------------------
# Reserved. Op-ScheduleSpec currently returns $null (always-manual) -- see the
# op header for why automation is deliberately not enabled yet.
$TASK_NAME = "WorkstationOps-MolecubesTunnel"

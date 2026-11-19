# REFERENCE COPY of config\instance.local.ps1 on the dev workstation (BMG-RTASSEFF, 10.10.2.195).
# As of 2026-11-19. Not read by ops.ps1: only config\instance.local.ps1 is. To rebuild this
# machine's role, copy this file to config\instance.local.ps1 there (see ref-configs\README.md).
# Update this copy whenever that file changes.
# ------------------------------------------------------------------------------------------

# instance.local.ps1 -- THIS machine (gitignored). Template: instance.example.ps1.
# Ryan's workstation: dev for gjesus3 after the Box A port; it keeps the backups
# and the image-server forwards. gjesus3's jobs leave this list only after Box A
# runs them AND '.\ops unschedule <op>' has removed the task here.

$INSTANCE_NAME = "dev-workstation"

$ENABLED_OPS = @(
    "memory-sync",
    "molecubes-tunnel",
    "oadata-web-forward",
    "omero-web-forward",
    "vps-backup",
    "wsl-backup",
    "xnat-web-forward"
)

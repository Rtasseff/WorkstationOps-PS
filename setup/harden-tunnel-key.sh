#!/usr/bin/env bash
# harden-tunnel-key.sh -- lock down tunnel keys in WSL's authorized_keys.
#
# Run this on the workstation AFTER the Molecubes box has pushed its public key with
# ssh-copy-id. ssh-copy-id appends a bare, UNRESTRICTED entry: that key could open a
# shell, forward any port, and bind any remote port. This rewrites every unrestricted
# entry with the tunnel option set.
#
# Invoke from the WorkstationOps root:
#     wsl -d Ubuntu -- bash /mnt/c/Users/rtasseff/OneDrive\ -\ CIC\ biomaGUNE/WorkstationOps/setup/harden-tunnel-key.sh
# or simply, from inside a WSL shell:
#     bash setup/harden-tunnel-key.sh
#
# Idempotent: entries that already carry options are left alone.
#
# Option set, and why each part is needed:
#   restrict         disables pty, X11, agent forwarding, user-rc, port forwarding
#   port-forwarding  re-enables forwarding only
#   permitlisten     limits which remote ports the key may bind -- the tunnel port and
#                    the documented 2333 fallback, nothing else
#   command=         REQUIRED. 'restrict' blocks a PTY but NOT command execution:
#                    "ssh host somecommand" still runs under restrict alone (verified
#                    2026-08-06 -- it returned the hostname). A forced command closes
#                    that hole. It does not affect the tunnel, because "ssh -N" opens
#                    no session channel, so the forced command never runs.

set -euo pipefail

AUTH="$HOME/.ssh/authorized_keys"
OPTS='restrict,port-forwarding,permitlisten="localhost:2222",permitlisten="localhost:2333",command="/bin/false"'

if [ ! -f "$AUTH" ]; then
    echo "No authorized_keys at $AUTH -- nothing to harden."
    exit 0
fi

cp "$AUTH" "${AUTH}.bak.$(date +%Y%m%d%H%M%S)"

changed=0
tmp="$(mktemp)"
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ""|\#*)
            printf '%s\n' "$line" >> "$tmp"
            ;;
        ssh-*|ecdsa-*|sk-*)
            # No leading options -> unrestricted. Harden it.
            printf '%s %s\n' "$OPTS" "$line" >> "$tmp"
            changed=$((changed + 1))
            ;;
        *)
            printf '%s\n' "$line" >> "$tmp"
            ;;
    esac
done < "$AUTH"

mv "$tmp" "$AUTH"
chmod 600 "$AUTH"

echo "Hardened $changed unrestricted entr(ies). Backup kept alongside authorized_keys."
echo
echo "--- authorized_keys (key material elided) ---"
sed -E 's/(ssh-[a-z0-9]+|ecdsa-[a-z0-9-]+) [A-Za-z0-9+\/=]+/\1 <key>/' "$AUTH"

#!/usr/bin/env bash
# test-tunnel-path.sh -- Acceptance test for the molecubes-tunnel path.
#
# Run this BEFORE every trip to the acquisition box. It exercises the whole chain
# from the workstation, using a local rehearsal key in place of the box, so a
# failure is found here instead of costing an access slot.
#
# Prerequisite: the landing pad must be running.
#     cd "C:\Users\rtasseff\OneDrive - CIC biomaGUNE\WorkstationOps"
#     .\ops run molecubes-tunnel
#
# Then, from a WSL shell:
#     bash setup/test-tunnel-path.sh
# or from Windows:
#     wsl -d Ubuntu -- bash "/mnt/c/.../WorkstationOps/setup/test-tunnel-path.sh"
#
# Exit code 0 = all passed.

WS="10.10.2.195"
PORT_MAIN=2200
PORT_FALLBACK=8000
WSL_SSHD=2200
TUNNEL_PORT=2222
KEY="$HOME/.ssh/id_ed25519_molecubes_tunnel"
SSHOPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes"

pass=0
fail=0

ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }
info() { echo "  [ ... ] $1"; }

banner_of() {  # banner_of <host> <port>
    nc -w 4 "$1" "$2" </dev/null 2>/dev/null | head -1
}

cleanup() { pkill -f "id_ed25519_molecubes_tunnel" 2>/dev/null; }
trap cleanup EXIT
cleanup; sleep 1

echo
echo "=============================================="
echo " molecubes-tunnel acceptance test"
echo "=============================================="
echo
echo "-- 1. sshd inside WSL --"
b=$(banner_of 127.0.0.1 $WSL_SSHD)
if [ -n "$b" ]; then ok "sshd answering: $b"; else bad "no SSH banner from WSL sshd on $WSL_SSHD"; fi

echo
echo "-- 2. forwarder reachable on the LAN address (the path the box uses) --"
b=$(banner_of $WS $PORT_MAIN)
if [ -n "$b" ]; then ok "port $PORT_MAIN: $b"; else bad "port $PORT_MAIN: no banner -- is the landing pad running?"; fi
b=$(banner_of $WS $PORT_FALLBACK)
if [ -n "$b" ]; then ok "port $PORT_FALLBACK (fallback): $b"; else bad "port $PORT_FALLBACK: no banner"; fi

echo
echo "-- 3. key authenticates --"
out=$(ssh $SSHOPTS -o PreferredAuthentications=publickey -p $PORT_MAIN rtasseff@$WS true 2>&1)
if echo "$out" | grep -qi "permission denied\|no such identity"; then
    bad "key rejected: $(echo "$out" | head -1)"
else
    ok "key accepted by sshd"
fi

echo
echo "-- 4. key must NOT be able to run a command (forced command) --"
out=$(ssh $SSHOPTS -p $PORT_MAIN rtasseff@$WS hostname 2>&1)
if echo "$out" | grep -q "bmg-"; then
    bad "key obtained a shell -- restriction is NOT effective (got: $out)"
else
    ok "shell/command denied"
fi

echo
echo "-- 5. key must NOT bind a port outside permitlisten --"
out=$(ssh $SSHOPTS -N -o ExitOnForwardFailure=yes -R 9999:localhost:$WSL_SSHD -p $PORT_MAIN rtasseff@$WS 2>&1)
if echo "$out" | grep -qi "administratively prohibited\|failed"; then
    ok "binding remote port 9999 refused"
else
    bad "remote port 9999 was NOT refused (got: $(echo "$out" | head -1))"
fi

echo
echo "-- 6. key MUST open the real reverse tunnel --"
ssh $SSHOPTS -N -f -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
    -R ${TUNNEL_PORT}:localhost:$WSL_SSHD -p $PORT_MAIN rtasseff@$WS 2>/dev/null
sleep 3
if pgrep -f "id_ed25519_molecubes_tunnel" >/dev/null; then
    ok "tunnel established (-R ${TUNNEL_PORT})"
else
    bad "tunnel did not start"
fi

echo
echo "-- 7. traffic flows back through the reverse channel --"
b=$(banner_of localhost $TUNNEL_PORT)
if [ -n "$b" ]; then ok "reverse channel carries traffic: $b"; else bad "no banner through localhost:$TUNNEL_PORT"; fi

echo
echo "-- 8. tunnel survives idle (regression: the 5s forwarder timeout) --"
info "idling 20s ..."
sleep 20
b=$(banner_of localhost $TUNNEL_PORT)
if [ -n "$b" ]; then ok "still alive after 20s idle"; else bad "reverse channel died while idle -- the 5s timeout bug is back"; fi

echo
echo "=============================================="
echo " $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
    echo " RESULT: PASS -- safe to make the trip"
else
    echo " RESULT: FAIL -- fix before going to the box"
fi
echo "=============================================="
[ "$fail" -eq 0 ]

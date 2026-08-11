# molecubes-tunnel — handoff / cold-start briefing

**For:** whoever (person or agent) picks this up without having been in the session that built it.
**Written:** 2026-08-06. **Status at that date:** workstation side built, scheduled and verified;
the acquisition box has **never run it**.

> **Update 2026-08-10 — generalized, behavior preserved.** The op's mechanics now live in
> `lib\tunnel-engine.ps1` (a second consumer appeared: `omero-web-forward`, port 4080, the gjesus3
> OMERO pilot); `operations\molecubes-tunnel.ps1` is a thin instance definition. Same op name, task
> name, ports, lock, logs, SSH-banner probe — `setup\test-tunnel-path.sh` re-passed **9/9** after
> the rework. Everything in this handoff remains valid, with two cosmetic diffs: the WSL keepalive's
> command line is now `env WSOPS_TUNNEL=molecubes-tunnel sleep infinity` (instance tag), and
> forwarder discovery additionally matches on this instance's `--listen-port` arguments, so
> `.\ops stop molecubes-tunnel` can never touch another instance's forwarders (and vice versa).

Read this before touching anything. It exists because the next event is likely to be someone
returning from the acquisition box with an error string, needing a diagnosis fast — and the traps
below already cost one wasted visit.

---

## 1. The situation in one paragraph

The Molecubes PET/CT acquisition box (`192.168.0.180`) is NAT'd behind its own router and cannot be
reached inbound. It dials **out** to this workstation and we ride the connection backward. The
landing pad is sshd **inside WSL** plus a userspace Python forwarder, because this account has no
admin rights and cannot install a Windows SSH server. The point of all this is that the box lives in
a restricted-access room entered **once per visit, roughly weekly** — remote access converts a scarce
physical resource into an ordinary login, and unblocks Gate-0 for NI live-box sync.

---

## 2. Current state

| Thing | State |
|---|---|
| `molecubes-tunnel` op (run/stop/status/verify) | ✅ built, verified |
| Scheduled at logon (`WorkstationOps-MolecubesTunnel`) | ✅ registered, verified by on-demand start |
| Acceptance test `setup\test-tunnel-path.sh` | ✅ 9/9 as of 2026-08-06 |
| Firewall + routing from the box | ✅ verified from the box on 2026-08-05 |
| Restricted tunnel key in WSL `authorized_keys` | ✅ installed (workstation-local rehearsal key) |
| **The box running the tunnel** | ❌ **never done** |
| **The LaunchAgent** | ❌ **never run anywhere** |

The single most useful command to establish live state:

```powershell
cd "C:\Users\rtasseff\OneDrive - CIC biomaGUNE\WorkstationOps"
.\ops status molecubes-tunnel
```

Then the full check (needs the landing pad running):

```powershell
wsl -d Ubuntu -- bash "/mnt/c/Users/rtasseff/OneDrive - CIC biomaGUNE/WorkstationOps/setup/test-tunnel-path.sh"
```

---

## 3. Read in this order

1. **`operations\molecubes-tunnel.ps1`** — the header comments carry the design rationale, the
   boundary with gjesus3-pilot, and the rule about generalising to a `tunnel-host` later.
2. **`README.md`**, `molecubes-tunnel` section — operational summary.
3. **`CLAUDE.md`**, "Service ops" section — why this op differs from every other op here.
4. **`..\projects\DataInfra\gjesus3-archive\gjesus3-pilot\equipment\nuclear-imaging\live_machine_remote_access.md`**
   — the domain half: why we need the box, the safety rules for a live acquisition machine, and open
   questions NI-RA-01…05.
5. **`S:\gnuclear\2026\Jesus\Ryan\tunnel.txt`** — the operator field card actually carried to the
   box. If someone reports a step number, it refers to this file.

---

## 4. Traps that have already cost time — do not rediscover these

**sshd inside WSL listens on 2200, not 22.** Ubuntu 24.04's `sshd-socket-generator` reads `Port`
from `sshd_config` and rewrites the socket unit. On older Ubuntu that line would have been inert
under socket activation. Every `ssh` to the workstation needs `-p 2200`.

**`nc -vz` is not a valid readiness test.** The forwarder accepts the TCP connection *before* trying
to reach its upstream, so `-z` reports success even when WSL is dead. Always read a banner:
`nc -w 3 10.10.2.195 2200 < /dev/null | head -1`.

**Never health-check `127.0.0.1`.** `wslrelay.exe` mirrors WSL's own sshd onto Windows
`127.0.0.1:2200`, so a loopback probe returns a banner when every forwarder is dead. Probe the LAN
address (`10.10.2.195`) — that is the `0.0.0.0` binding only the forwarder provides, and the only one
the box can reach. This produced a status of "OK" seconds after everything had been killed.

**In `-R`, the target is `localhost:22`, not `:2200`.** On the box, `localhost` means the box, whose
sshd is on 22. The 2200 is the *workstation's* number and it leaks into `-R` arguments very easily.
A tunnel built with `-R 2222:localhost:2200` **establishes cleanly and looks correct**, then fails
only when someone tries to come back through it.

**`restrict` in `authorized_keys` does not block command execution.** It blocks PTY, X11, agent
forwarding, user-rc and port forwarding — but `ssh host somecommand` still runs. Verified. That is
why the key options include `command="/bin/false"`.

**After hardening, some things stop working on purpose.** `setup\harden-tunnel-key.sh` makes the
box's key tunnel-only. The field card's step-5 check
(`ssh -i ... rtasseff@10.10.2.195 hostname`) then correctly fails. **That is not a regression** —
do not "fix" it by relaxing the key.

---

## 5. Triage: symptom → cause → action

Someone returns from the box with an error. Start here.

| Symptom (reported from the box) | Almost certainly | Do this |
|---|---|---|
| `nc` banner test prints nothing, returns ~3s | Landing pad "half up": forwarders alive, WSL/sshd dead | `.\ops status molecubes-tunnel`, then `.\ops stop` + `.\ops run`. The supervisor should self-heal this within 15s — if it did not, read `.\ops logs molecubes-tunnel` |
| `Connection refused` | Nothing listening — landing pad not running at all | `.\ops run molecubes-tunnel`; check the scheduled task exists and is Running |
| `kex_exchange_identification: read: Connection reset by peer` | Same half-up state as row 1 | As row 1 |
| Hangs, then times out | Firewall or routing | Was verified working 2026-08-05; suspect a network change, not this code |
| One password prompt, then "connection closed" | **The 5-second idle regression.** Check `lib\tcp_forward.py` still has `upstream.settimeout(None)` after `create_connection` | If missing, restore it. This bug presents as an *authentication* failure — the tell is that a deliberately wrong password gives the *same* error as the right one |
| `Permission denied (publickey,password)` | Wrong password (it is the **Ubuntu/WSL** one, not Windows), or the key was never pushed | Re-run field card step 5 |
| `remote port forwarding failed for listen port 2222` | Port already bound on the WSL side, or `permitlisten` forbids the port being requested | Check for a stale `ssh` in WSL; if the box used the 2333 fallback, confirm `permitlisten` allows it |
| Tunnel is up, but `ssh -p 2222 molecubes@localhost` fails | `-R` target was `:2200` instead of `:22`, or the box's Remote Login is off | Field card steps 2 and 6a |
| LaunchAgent does nothing | Untested component — expect this | Read `~/Library/Logs/molecubes-tunnel.log` **on the box**. The documented response is to fall back to the manual `nohup ssh -N -R` tunnel, not to debug in the room |

**If the box left a working manual tunnel behind**, you can debug the LaunchAgent remotely — that is
exactly what it is for. `ssh -p 2222 molecubes@localhost` from the workstation.

---

## 6. What is deliberately not done

- ~~**No generic `tunnel-host` op.**~~ **Done 2026-08-10** — reworked into `lib\tunnel-engine.ps1`
  when the second consumer appeared (see the update note at the top). The MRI acquisition machine
  would now be a third instance file + conf, nothing more.
- **No forwarder allow-list.** `--allow` exists but the box's egress address is unknown (NI-RA-03).
- **Password auth still enabled** on WSL sshd for interactive use.

---

## 7. Suggested opening prompt for a fresh session

> Read `operations/molecubes-tunnel.HANDOFF.md`, then run `.\ops status molecubes-tunnel`. I have
> just come back from the Molecubes acquisition box. Here is what happened: `<paste the exact
> commands and error text>`.

The exact error text matters more than anything else — every trap in §4 produces a *misleading*
symptom, and three of them look like authentication problems when they are not.

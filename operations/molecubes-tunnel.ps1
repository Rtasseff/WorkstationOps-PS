# molecubes-tunnel.ps1 -- Windows-side landing pad for a reverse SSH tunnel from the
# Molecubes PET/CT acquisition box (192.168.0.180).
# Dot-sourced by ops.ps1. Exposes Op-Run / Op-Stop / Op-Status / Op-Verify / Op-ScheduleSpec.
#
# WHY THIS EXISTS
#   The Molecubes acquisition box sits behind its own router and cannot be reached
#   inbound. It can dial out, so it opens an outbound SSH connection to this
#   workstation and we ride that connection backward. Physical access to the box is
#   rare and scheduled, which is what makes remote access worth this machinery.
#   Domain context (what the box is, why we need it) lives in the gjesus3-pilot repo:
#   equipment\nuclear-imaging\live_machine_remote_access.md
#
# BOUNDARY (same discipline as finder-refresh)
#   THIS op owns the Windows half: the WSL keepalive, the forwarder, the ports, the
#   health signal, the logs. The gjesus3-pilot repo owns the domain half: what the
#   Molecubes box is, why we reach it, and the operator procedure carried to it.
#
# GENERALIZING LATER -- READ BEFORE ADDING A SECOND TUNNEL
#   This op is deliberately Molecubes-specific today, because the process was not yet
#   proven end to end from the acquisition box and specificity was cheaper than a
#   premature abstraction. The landing pad itself (WSL sshd + forwarder + keepalive)
#   is entirely equipment-agnostic; only the far end is Molecubes.
#   If a second machine ever needs a tunnel -- the MRI acquisition machine is the
#   likely candidate, see equipment\mri-platform\mri_data_access_strategy.md in
#   gjesus3-pilot, which records that it is also not network-accessible -- then:
#       DO NOT copy this file into a second equipment-specific op.
#       DO rename/rework THIS op into a generic 'tunnel-host' driven entirely by
#       config, and have both machines share it.
#   The same rework is fair game once molecubes-tunnel is verified working and we
#   want to generalize in anticipation of more tunnels. The trigger is either
#   "a second consumer appeared" or "this one is proven and we choose to prepare" --
#   never "it would be tidier".
#
# NON-OBVIOUS FAILURE MODES THIS GUARDS AGAINST
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

$FORWARDER_PATH = Join-Path $OpsRoot $FORWARDER_REL
$HOST_PROCS     = @('powershell.exe', 'pwsh.exe')

# -- WSL helpers --------------------------------------------------------------

function Get-WslIp {
    # Running any wsl.exe command starts the VM if it is stopped, which also
    # socket-activates sshd. hostname -I puts eth0 first; 172.17.x / 172.18.x are
    # Docker bridges and must not be picked.
    $raw = (& wsl.exe -d $WSL_DISTRO -- hostname -I) 2>&1 | Out-String
    $ip  = ($raw -replace "`0", '').Trim() -split '\s+' | Select-Object -First 1
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $null }
    return $ip
}

function Test-WslRunning {
    $out = (& wsl.exe --list --verbose) 2>&1 | Out-String
    $out = $out -replace "`0", ''
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match "\b$WSL_DISTRO\b" -and $line -match '\bRunning\b') { return $true }
    }
    return $false
}

function Test-SshBanner {
    # End-to-end probe: connect and require an "SSH-" banner back. A plain TCP
    # connect is NOT sufficient -- the forwarder accepts connections even when its
    # upstream is dead, which is the exact failure this exists to detect.
    #
    # ALWAYS probe $WORKSTATION_IP, never 127.0.0.1. WSL's localhostForwarding
    # mirrors WSL's own sshd onto Windows 127.0.0.1:2200 via wslrelay.exe, so a
    # loopback probe returns a banner even when every forwarder is dead -- status
    # then reports OK while the acquisition box cannot connect at all. Only the
    # 0.0.0.0 binding that the forwarder owns is reachable from off-box, and that
    # is what probing the LAN address actually tests.
    param(
        [Parameter(Mandatory)][string]$TargetIp,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 4000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetIp, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $buf = New-Object byte[] 64
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $false }
        return ([System.Text.Encoding]::ASCII.GetString($buf, 0, $n)).StartsWith('SSH-')
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# -- Process discovery --------------------------------------------------------

function Get-ForwarderProcesses {
    # Match THIS op's forwarder by its full script path, not by the bare name
    # 'tcp_forward'. A copy of the script running from anywhere else -- a manual
    # port-forward out of the home directory, a second project -- is not ours.
    # Op-Stop kills whatever this returns, so a loose match here does not merely
    # miscount in Op-Status, it terminates unrelated processes.
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'python*' -and $_.CommandLine -like "*$FORWARDER_PATH*" })
}

function Get-KeepaliveProcesses {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'wsl.exe' -and $_.CommandLine -like '*sleep infinity*' })
}

function Get-SupervisorPid {
    # The lock file written by Get-Lock holds the supervisor's PID. That is the
    # only reliable handle: started interactively, the supervisor is just
    # "pwsh.exe" with the op name nowhere in its command line.
    $lockFile = Join-Path $OpsRoot "logs\$OpName.lock"
    if (-not (Test-Path $lockFile)) { return $null }
    $raw = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue)
    if (-not $raw) { return $null }
    $parsed = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) { return $null }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$parsed" -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    if ($HOST_PROCS -notcontains $proc.Name) { return $null }
    return $parsed
}

function Stop-TunnelChildren {
    # Forwarders first would be wrong: the supervisor restarts them. Callers must
    # have stopped the supervisor already.
    $killed = 0
    foreach ($p in (Get-ForwarderProcesses)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
    foreach ($k in (Get-KeepaliveProcesses)) {
        Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
    return $killed
}

# -- Op-Run -------------------------------------------------------------------

function Op-Run {
    param(
        [switch]$Scheduled,
        [switch]$Force,
        [switch]$DryRun
    )

    Initialize-Log -Name $OpName

    if ($DryRun) {
        Write-Log -Level INFO -Message "DRY RUN -- no processes will be started."
        Write-Log -Level INFO -Message "Would hold WSL '$WSL_DISTRO' awake with a 'sleep infinity' keepalive."
        Write-Log -Level INFO -Message "Would read the current WSL IP and require an SSH banner on port $WSL_SSHD_PORT."
        foreach ($port in $LISTEN_PORTS) {
            Write-Log -Level INFO -Message "Would listen on 0.0.0.0:$port -> WSL:$WSL_SSHD_PORT via $FORWARDER_PATH"
        }
        Write-Log -Level INFO -Message "Would health-check the full path every $HEALTH_INTERVAL_SECONDS seconds."
        return
    }

    if (-not (Test-Path $FORWARDER_PATH)) {
        Write-Log -Level ERROR -Message "Forwarder not found: $FORWARDER_PATH"
        exit 1
    }

    if (-not (Get-Lock -Name $OpName)) {
        Write-Log -Level ERROR -Message "Already running. Use '.\ops stop $OpName' first."
        exit 1
    }

    $procs     = @()
    $keepalive = $null

    try {
        Write-Log -Level INFO -Message "Starting landing pad for the Molecubes tunnel."

        while ($true) {

            # Covers the retry paths below, which 'continue' back here without ever
            # reaching the health loop. See the rollover note there.
            Initialize-Log -Name $OpName

            # Rebuild from scratch: stale children, then a fresh keepalive + IP.
            foreach ($p in $procs) {
                if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            }
            if ($keepalive -and -not $keepalive.HasExited) {
                Stop-Process -Id $keepalive.Id -Force -ErrorAction SilentlyContinue
            }
            $procs = @()

            # Hold WSL awake. Without this the VM idles out and stops, sshd goes
            # with it, and the forwarders keep answering into nothing.
            $keepalive = Start-Process -FilePath 'wsl.exe' `
                                       -ArgumentList @('-d', $WSL_DISTRO, '--', 'sleep', 'infinity') `
                                       -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 3

            $wslIp = Get-WslIp
            if (-not $wslIp) {
                Write-Log -Level WARN -Message "Could not read a valid WSL IP. Retrying in 15s."
                Start-Sleep -Seconds 15
                continue
            }
            Write-Log -Level OK -Message "WSL '$WSL_DISTRO' up at $wslIp (keepalive pid $($keepalive.Id))"

            if (-not (Test-SshBanner -TargetIp $wslIp -Port $WSL_SSHD_PORT)) {
                Write-Log -Level WARN -Message "sshd not answering inside WSL on $WSL_SSHD_PORT. Check: wsl -d $WSL_DISTRO -- ss -tln"
                Start-Sleep -Seconds 15
                continue
            }
            Write-Log -Level OK -Message "sshd answering inside WSL on $WSL_SSHD_PORT"

            foreach ($port in $LISTEN_PORTS) {
                $argList = @(
                    "`"$FORWARDER_PATH`""
                    '--target-host'; $wslIp
                    '--target-port'; $WSL_SSHD_PORT
                    '--listen-host'; '0.0.0.0'
                    '--listen-port'; $port
                )
                try {
                    $p = Start-Process -FilePath 'python' -ArgumentList $argList -PassThru -NoNewWindow
                    $procs += $p
                    Write-Log -Level INFO -Message "listening 0.0.0.0:$port -> ${wslIp}:$WSL_SSHD_PORT (pid $($p.Id))"
                } catch {
                    Write-Log -Level WARN -Message "Could not start forwarder on ${port}: $_"
                }
            }

            if ($procs.Count -eq 0) {
                Write-Log -Level ERROR -Message "No forwarders started. Is 'python' on PATH?"
                Start-Sleep -Seconds 15
                continue
            }

            Start-Sleep -Seconds 2
            foreach ($port in $LISTEN_PORTS) {
                if (Test-SshBanner -TargetIp $WORKSTATION_IP -Port $port) {
                    Write-Log -Level OK -Message "port $port verified -- from the box: ssh -p $port $SSH_USER@$WORKSTATION_IP"
                } else {
                    Write-Log -Level WARN -Message "port $port is NOT answering through the forwarder"
                }
            }
            Write-Log -Level INFO -Message "Health-checking every $HEALTH_INTERVAL_SECONDS s. Ctrl-C or '.\ops stop $OpName' to stop."

            while ($true) {
                Start-Sleep -Seconds $HEALTH_INTERVAL_SECONDS

                # Roll the log over at midnight. Initialize-Log pins the date at the
                # moment it is called, which is correct for a batch op that finishes
                # the day it starts -- but this supervisor runs for months, so every
                # event would otherwise land in the file named for its start date.
                # Someone triaging "what happened Tuesday" would find no Tuesday log
                # and wrongly conclude the op had not been running.
                Initialize-Log -Name $OpName

                if ($procs | Where-Object { $_.HasExited }) {
                    Write-Log -Level WARN -Message "A forwarder exited. Rebuilding."
                    break
                }
                if ($keepalive.HasExited) {
                    Write-Log -Level WARN -Message "WSL keepalive died -- the VM may have stopped. Rebuilding."
                    break
                }
                if (-not (Test-SshBanner -TargetIp $WORKSTATION_IP -Port $LISTEN_PORTS[0])) {
                    Write-Log -Level WARN -Message "Path stopped answering (WSL down, or its IP changed). Rebuilding."
                    break
                }
            }

            Start-Sleep -Seconds 2
        }
    }
    finally {
        Write-Log -Level INFO -Message "Shutting down forwarders and releasing the WSL keepalive."
        foreach ($p in $procs) {
            if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
        if ($keepalive -and -not $keepalive.HasExited) {
            Stop-Process -Id $keepalive.Id -Force -ErrorAction SilentlyContinue
        }
        Release-Lock -Name $OpName
    }
}

# -- Op-Stop ------------------------------------------------------------------

function Op-Stop {
    Initialize-Log -Name $OpName

    $supervisor = Get-SupervisorPid
    if ($supervisor) {
        Write-Log -Level INFO -Message "Stopping supervisor (pid $supervisor)"
        Stop-Process -Id $supervisor -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    } else {
        Write-Log -Level INFO -Message "No supervisor recorded in the lock file."
    }

    # Orphans outlive a hard-killed supervisor and keep serving a stale WSL IP.
    $killed = Stop-TunnelChildren
    if ($killed -gt 0) {
        Write-Log -Level INFO -Message "Stopped $killed forwarder/keepalive process(es)."
    }

    Release-Lock -Name $OpName

    Start-Sleep -Seconds 1
    $left = @(Get-ForwarderProcesses) + @(Get-KeepaliveProcesses)
    if ($left.Count -gt 0) {
        Write-Log -Level WARN -Message "$($left.Count) process(es) still running after stop."
    } else {
        Write-Log -Level OK -Message "Landing pad stopped."
    }
}

# -- Op-Status ----------------------------------------------------------------

function Op-Status {
    $supervisor = Get-SupervisorPid
    $forwarders = Get-ForwarderProcesses
    $wslUp      = Test-WslRunning

    $portState = @{}
    foreach ($port in $LISTEN_PORTS) {
        $portState[$port] = (Test-SshBanner -TargetIp $WORKSTATION_IP -Port $port -TimeoutMs 3000)
    }
    $primaryOk = $portState[$LISTEN_PORTS[0]]

    $lines = @()
    $lines += "Purpose:      reach the Molecubes PET/CT box ($MOLECUBES_IP) via reverse SSH"
    $lines += ""
    if ($supervisor) {
        $lines += "Supervisor:   running (PID $supervisor)"
    } else {
        $lines += "Supervisor:   Not configured"
    }
    if ($wslUp) {
        $lines += "WSL distro:   $WSL_DISTRO Running"
    } else {
        $lines += "WSL distro:   $WSL_DISTRO NOT AVAILABLE (stopped)"
    }
    $lines += "Forwarders:   $($forwarders.Count) process(es)"
    foreach ($port in $LISTEN_PORTS) {
        if ($portState[$port]) {
            $lines += "Port ${port}:    OK (SSH banner through the forwarder)"
        } else {
            $lines += "Port ${port}:    FAIL (no banner -- half up or not running)"
        }
    }
    $lines += ""
    if ($primaryOk) {
        $lines += "From the box: ssh -p $($LISTEN_PORTS[0]) $SSH_USER@$WORKSTATION_IP"
        $lines += "Ride it back: ssh -p $TUNNEL_PORT $MOLECUBES_USER@localhost"
    } else {
        $lines += "Start with:   .\ops run $OpName"
    }

    # ${OpName} must stay delimited: "$OpName:" parses the colon as a scope
    # qualifier on PS 5.1 and fails at parse time.
    $brief = if ($primaryOk) {
        "${OpName}: OK (port $($LISTEN_PORTS[0]) answering)"
    } elseif ($supervisor) {
        "${OpName}: running but FAIL -- no SSH banner"
    } else {
        "${OpName}: offline"
    }

    return @{
        Label = $OpLabel
        Lines = $lines
        Brief = $brief
        Ok    = $primaryOk
    }
}

# -- Op-Verify ----------------------------------------------------------------

function Op-Verify {
    $lines = @()
    $ok = $true

    if (Test-Path $FORWARDER_PATH) {
        $lines += "[PASS] Forwarder present: $FORWARDER_PATH"
    } else {
        $lines += "[FAIL] Forwarder missing: $FORWARDER_PATH"
        $ok = $false
    }

    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) {
        $lines += "[PASS] python on PATH: $($py.Source)"
    } else {
        $lines += "[FAIL] python not on PATH -- the forwarder cannot start"
        $ok = $false
    }

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        $lines += "[PASS] wsl.exe available"
    } else {
        $lines += "[FAIL] wsl.exe not available"
        $ok = $false
    }

    if (Test-WslRunning) {
        $lines += "[PASS] WSL distro '$WSL_DISTRO' is Running"
    } else {
        $lines += "[WARN] WSL distro '$WSL_DISTRO' is stopped (Op-Run starts and holds it awake)"
    }

    $wslIp = Get-WslIp
    if ($wslIp) {
        $lines += "[PASS] WSL IP readable: $wslIp"
        if (Test-SshBanner -TargetIp $wslIp -Port $WSL_SSHD_PORT) {
            $lines += "[PASS] sshd answering inside WSL on $WSL_SSHD_PORT"
        } else {
            $lines += "[FAIL] no SSH banner inside WSL on $WSL_SSHD_PORT"
            $ok = $false
        }
    } else {
        $lines += "[FAIL] Could not read a valid WSL IP"
        $ok = $false
    }

    foreach ($port in $LISTEN_PORTS) {
        if (Test-SshBanner -TargetIp $WORKSTATION_IP -Port $port -TimeoutMs 3000) {
            $lines += "[PASS] Windows port $port relays to sshd"
        } else {
            $lines += "[WARN] Windows port $port not answering (expected unless Op-Run is active)"
        }
    }

    return @{ Lines = $lines; Ok = $ok }
}

# -- Op-ScheduleSpec ----------------------------------------------------------

function Op-ScheduleSpec {
    # Starts at logon and stays up. The landing pad being down is the ONE failure
    # with no recovery from inside the acquisition box's restricted-access room --
    # the operator gets a single entry per visit and cannot step out to fix it, so
    # the visit is simply lost. Removing the "did I remember to start it" step is
    # worth a port opening automatically at logon.
    #
    # Two details this spec depends on, both easy to get wrong:
    #   ExecutionTimeLimit = PT0S  -- "no limit". The library default of P3D would
    #       kill this persistent service after three days, which is exactly the
    #       silent failure the schedule exists to prevent.
    #   Delay = PT1M  -- WSL and the network are not necessarily ready the instant
    #       the shell is. Op-Run retries regardless; the delay just keeps the log
    #       from opening with avoidable warnings on every logon.
    #
    # Undo with: .\ops unschedule molecubes-tunnel
    return @{
        TaskName           = $TASK_NAME
        Description        = "$OpDescription. Starts at logon and runs until stopped with '.\ops stop molecubes-tunnel'."
        Trigger            = "Logon"
        Delay              = "PT1M"
        ExecutionTimeLimit = "PT0S"
    }
}

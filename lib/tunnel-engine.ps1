# tunnel-engine.ps1 -- Generic engine for port-forward / tunnel-host service ops.
# Dot-sourced by a thin per-instance op file AFTER that file has set the config
# variables below. Defines Op-Run / Op-Stop / Op-Status / Op-Verify /
# Op-ScheduleSpec, so the op file normally contains nothing but header vars,
# config, and this dot-source.
#
# WHAT AN INSTANCE IS
#   One instance = one op file + one conf = one supervisor, one lock, one log
#   stream, one scheduled task, one set of listen ports. Instances share this
#   engine and lib\tcp_forward.py but never processes: each holds its own WSL
#   keepalive (tagged with the op name) and its own forwarders (matched by
#   script path AND this instance's --listen-port arguments), so stopping one
#   instance cannot take down another. First two instances: molecubes-tunnel
#   (reverse-SSH landing pad, ports 2200/8000) and omero-web-forward (plain
#   HTTP forward, port 4080).
#
# CONFIG CONTRACT -- the op file MUST set every one of these before dot-sourcing
# this engine. "Optional" values must still be assigned (use '' / $false /
# @()): ops.ps1 dot-sources every op into ONE session for aggregate status, so
# an unassigned variable silently inherits the previous op's value.
#
#   $OpName / $OpLabel / $OpDescription  -- standard op header
#   $WSL_DISTRO              -- distro hosting the upstream service
#   $TARGET_PORT             -- WSL-side port the forwarders relay to
#   $LISTEN_PORTS            -- Windows 0.0.0.0 ports for this instance.
#                               PORT ALLOCATION across instances lives in
#                               README.md ("Tunnel port allocation") -- check it
#                               before adding a port; Op-Run also refuses a
#                               port that is already bound by a foreign process.
#   $WORKSTATION_IP          -- LAN address probed end-to-end (never 127.0.0.1:
#                               wslrelay mirrors WSL services onto loopback, so
#                               a loopback probe passes with every forwarder dead)
#   $FORWARDER_REL           -- lib\tcp_forward.py, relative to $OpsRoot
#   $HEALTH_INTERVAL_SECONDS -- seconds between end-to-end health checks
#   $TASK_NAME               -- scheduled-task name for this instance
#   $PROBE                   -- 'ssh-banner' or 'http'. There is deliberately no
#                               'tcp-connect' option: the forwarder accepts a
#                               connection before dialing its upstream, so a
#                               bare connect reports success when the far side
#                               is dead (the "half up" failure mode).
#   $PROBE_HTTP_PATH         -- path requested by the http probe ('' for ssh-banner)
#   $KEEPALIVE_LEGACY_MATCH  -- $true only on molecubes-tunnel: also claim the
#                               untagged 'sleep infinity' keepalives its pre-
#                               engine supervisor left behind, so a stop during
#                               migration does not orphan them
#   $STATUS_PURPOSE          -- one 'Purpose:' line for Op-Status
#   $STATUS_HINTS_OK         -- extra Op-Status lines shown when the path is up
#                               (@() for none)

if (-not $OpsRoot) {
    $OpsRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

$FORWARDER_PATH = Join-Path $OpsRoot $FORWARDER_REL
$HOST_PROCS     = @('powershell.exe', 'pwsh.exe')
# The keepalive is tagged by running it as 'env WSOPS_TUNNEL=<op> sleep
# infinity' -- env sets the (unused) variable and execs sleep, and the tag
# rides in the Windows command line where Get-KeepaliveProcesses can see it.
# Do NOT tag via 'sh -c "... # comment"': wsl.exe/Start-Process quoting breaks
# the quoted string apart and the keepalive exits within seconds.
$KEEPALIVE_TAG  = "WSOPS_TUNNEL=$OpName"

# -- WSL helpers --------------------------------------------------------------

function Get-WslIp {
    # Running any wsl.exe command starts the VM if it is stopped. hostname -I
    # puts eth0 first; 172.17.x/172.18.x Docker bridges must not be picked.
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

# -- Readiness probe ----------------------------------------------------------

function Test-UpstreamProbe {
    # End-to-end probe: connect AND require real bytes from the upstream
    # service back through whatever sits in between. A plain TCP connect is
    # NOT sufficient -- see $PROBE in the config contract.
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

        if ($PROBE -eq 'http') {
            # The upstream only speaks when spoken to.
            $req = "GET $PROBE_HTTP_PATH HTTP/1.0`r`nHost: $TargetIp`r`nConnection: close`r`n`r`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $stream.Write($bytes, 0, $bytes.Length)
        }

        $buf = New-Object byte[] 64
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $false }
        $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        switch ($PROBE) {
            'ssh-banner' { return $head.StartsWith('SSH-') }
            'http'       { return $head.StartsWith('HTTP/') }
            default      { throw "Unknown PROBE '$PROBE' (expected 'ssh-banner' or 'http')" }
        }
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# -- Process discovery (instance-keyed) ---------------------------------------

function Get-ForwarderProcesses {
    # Two keys, both required: the forwarder script's full path (a manual copy
    # run from a home directory is not ours) AND one of THIS instance's listen
    # ports (another instance running the SAME script is not ours either).
    # Op-Stop kills whatever this returns -- a loose match here terminates
    # processes belonging to someone else.
    $portPatterns = @()
    foreach ($port in $LISTEN_PORTS) { $portPatterns += "--listen-port $port" }
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name -notlike 'python*') { return $false }
            if ($_.CommandLine -notlike "*$FORWARDER_PATH*") { return $false }
            foreach ($pat in $portPatterns) {
                if ($_.CommandLine -like "*$pat*") { return $true }
            }
            return $false
        })
}

function Get-KeepaliveProcesses {
    # Keepalives are tagged with the op name precisely so instances can tell
    # them apart -- an untagged match would let 'stop' on one instance drop the
    # other instance's WSL keepalive.
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name -ne 'wsl.exe') { return $false }
            if ($_.CommandLine -like "*$KEEPALIVE_TAG sleep*") { return $true }
            if ($KEEPALIVE_LEGACY_MATCH -and
                $_.CommandLine -like '*sleep infinity*' -and
                $_.CommandLine -notlike '*WSOPS_TUNNEL=*') { return $true }
            return $false
        })
}

function Get-SupervisorPid {
    # The lock file written by Get-Lock holds the supervisor's PID -- the only
    # reliable handle: started interactively the supervisor is just
    # powershell.exe with the op name nowhere in its command line.
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
    # Forwarders first would be wrong: the supervisor restarts them. Callers
    # must have stopped the supervisor already.
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

function Get-ForeignListener {
    # Collision guard: something OTHER than this instance's forwarder already
    # bound to a listen port (another instance misconfigured onto it, or
    # unrelated software). Returns the owning PID, or $null if the port is
    # free / owned by us.
    param([Parameter(Mandatory)][int]$Port)
    $ours = @(Get-ForwarderProcesses | ForEach-Object { $_.ProcessId })
    $conns = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach ($c in $conns) {
        if ($ours -notcontains $c.OwningProcess) { return $c.OwningProcess }
    }
    return $null
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
        Write-Log -Level INFO -Message "Would hold WSL '$WSL_DISTRO' awake with a tagged keepalive ($KEEPALIVE_TAG)."
        Write-Log -Level INFO -Message "Would read the current WSL IP and require a '$PROBE' probe answer on port $TARGET_PORT."
        foreach ($port in $LISTEN_PORTS) {
            Write-Log -Level INFO -Message "Would listen on 0.0.0.0:$port -> WSL:$TARGET_PORT via $FORWARDER_PATH"
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
        Write-Log -Level INFO -Message "Starting $OpLabel."

        while ($true) {

            # Covers the retry paths below, which 'continue' back here without
            # ever reaching the health loop (see the rollover note there).
            Initialize-Log -Name $OpName

            # Rebuild from scratch: stale children, then a fresh keepalive + IP.
            foreach ($p in $procs) {
                if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            }
            if ($keepalive -and -not $keepalive.HasExited) {
                Stop-Process -Id $keepalive.Id -Force -ErrorAction SilentlyContinue
            }
            $procs = @()

            # Hold WSL awake. Without this the VM idles out and stops, the
            # upstream service goes with it, and the forwarders keep answering
            # into nothing. 'env' plants the instance tag in the command line
            # for Get-KeepaliveProcesses and execs sleep (see $KEEPALIVE_TAG).
            $keepalive = Start-Process -FilePath 'wsl.exe' `
                                       -ArgumentList @('-d', $WSL_DISTRO, '--', 'env',
                                                       $KEEPALIVE_TAG, 'sleep', 'infinity') `
                                       -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 3

            $wslIp = Get-WslIp
            if (-not $wslIp) {
                Write-Log -Level WARN -Message "Could not read a valid WSL IP. Retrying in 15s."
                Start-Sleep -Seconds 15
                continue
            }
            Write-Log -Level OK -Message "WSL '$WSL_DISTRO' up at $wslIp (keepalive pid $($keepalive.Id))"

            if (-not (Test-UpstreamProbe -TargetIp $wslIp -Port $TARGET_PORT)) {
                Write-Log -Level WARN -Message "Upstream not answering '$PROBE' probe inside WSL on $TARGET_PORT. Check: wsl -d $WSL_DISTRO -- ss -tln"
                Start-Sleep -Seconds 15
                continue
            }
            Write-Log -Level OK -Message "Upstream answering inside WSL on $TARGET_PORT"

            foreach ($port in $LISTEN_PORTS) {
                $foreign = Get-ForeignListener -Port $port
                if ($foreign) {
                    Write-Log -Level ERROR -Message "Port $port is already bound by PID $foreign (not this instance's forwarder). Check the port allocation table in README.md. Skipping this port."
                    continue
                }
                $argList = @(
                    "`"$FORWARDER_PATH`""
                    '--target-host'; $wslIp
                    '--target-port'; $TARGET_PORT
                    '--listen-host'; '0.0.0.0'
                    '--listen-port'; $port
                )
                try {
                    $p = Start-Process -FilePath 'python' -ArgumentList $argList -PassThru -NoNewWindow
                    $procs += $p
                    Write-Log -Level INFO -Message "listening 0.0.0.0:$port -> ${wslIp}:$TARGET_PORT (pid $($p.Id))"
                } catch {
                    Write-Log -Level WARN -Message "Could not start forwarder on ${port}: $_"
                }
            }

            if ($procs.Count -eq 0) {
                Write-Log -Level ERROR -Message "No forwarders started. Is 'python' on PATH? Are all ports foreign-bound?"
                Start-Sleep -Seconds 15
                continue
            }

            Start-Sleep -Seconds 2
            foreach ($port in $LISTEN_PORTS) {
                if (Test-UpstreamProbe -TargetIp $WORKSTATION_IP -Port $port) {
                    Write-Log -Level OK -Message "port $port verified end-to-end at $WORKSTATION_IP"
                } else {
                    Write-Log -Level WARN -Message "port $port is NOT answering through the forwarder"
                }
            }
            Write-Log -Level INFO -Message "Health-checking every $HEALTH_INTERVAL_SECONDS s. Ctrl-C or '.\ops stop $OpName' to stop."

            while ($true) {
                Start-Sleep -Seconds $HEALTH_INTERVAL_SECONDS

                # Roll the log over at midnight. Initialize-Log pins the date at
                # the moment it is called -- correct for a batch op, wrong for a
                # supervisor that runs for months: every event would land in the
                # file named for its start date, and someone triaging "what
                # happened Tuesday" would find no Tuesday log.
                Initialize-Log -Name $OpName

                if ($procs | Where-Object { $_.HasExited }) {
                    Write-Log -Level WARN -Message "A forwarder exited. Rebuilding."
                    break
                }
                if ($keepalive.HasExited) {
                    Write-Log -Level WARN -Message "WSL keepalive died -- the VM may have stopped. Rebuilding."
                    break
                }
                if (-not (Test-UpstreamProbe -TargetIp $WORKSTATION_IP -Port $LISTEN_PORTS[0])) {
                    Write-Log -Level WARN -Message "Path stopped answering (WSL down, upstream dead, or IP changed). Rebuilding."
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
        Write-Log -Level OK -Message "$OpLabel stopped."
    }
}

# -- Op-Status ----------------------------------------------------------------

function Op-Status {
    $supervisor = Get-SupervisorPid
    # @() at the call site: PS unrolls a 1-element return, and a lone
    # CimInstance has no .Count -- the count renders blank without this.
    $forwarders = @(Get-ForwarderProcesses)
    $wslUp      = Test-WslRunning

    $portState = @{}
    foreach ($port in $LISTEN_PORTS) {
        $portState[$port] = (Test-UpstreamProbe -TargetIp $WORKSTATION_IP -Port $port -TimeoutMs 3000)
    }
    $primaryOk = $portState[$LISTEN_PORTS[0]]

    $lines = @()
    $lines += "Purpose:      $STATUS_PURPOSE"
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
            $lines += "Port ${port}:    OK ('$PROBE' answer through the forwarder)"
        } else {
            $lines += "Port ${port}:    FAIL (no probe answer -- half up or not running)"
        }
    }
    $lines += ""
    if ($primaryOk) {
        foreach ($hint in $STATUS_HINTS_OK) { $lines += $hint }
    } else {
        $lines += "Start with:   .\ops run $OpName"
    }

    # ${OpName} must stay delimited: "$OpName:" parses the colon as a scope
    # qualifier on PS 5.1 and fails at parse time.
    $brief = if ($primaryOk) {
        "${OpName}: OK (port $($LISTEN_PORTS[0]) answering)"
    } elseif ($supervisor) {
        "${OpName}: running but FAIL -- no probe answer"
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
        if (Test-UpstreamProbe -TargetIp $wslIp -Port $TARGET_PORT) {
            $lines += "[PASS] upstream answering '$PROBE' probe inside WSL on $TARGET_PORT"
        } else {
            $lines += "[FAIL] no '$PROBE' probe answer inside WSL on $TARGET_PORT"
            $ok = $false
        }
    } else {
        $lines += "[FAIL] Could not read a valid WSL IP"
        $ok = $false
    }

    foreach ($port in $LISTEN_PORTS) {
        $foreign = Get-ForeignListener -Port $port
        if ($foreign) {
            $lines += "[FAIL] port $port is bound by a foreign process (PID $foreign) -- port collision"
            $ok = $false
        } elseif (Test-UpstreamProbe -TargetIp $WORKSTATION_IP -Port $port -TimeoutMs 3000) {
            $lines += "[PASS] Windows port $port relays to the upstream"
        } else {
            $lines += "[WARN] Windows port $port not answering (expected unless Op-Run is active)"
        }
    }

    return @{ Lines = $lines; Ok = $ok }
}

# -- Op-ScheduleSpec ----------------------------------------------------------

function Op-ScheduleSpec {
    # Service op: starts at logon, stays up.
    #   ExecutionTimeLimit = PT0S -- "no limit". The library default of P3D
    #       would kill a persistent service after three days, silently.
    #   Delay = PT1M -- WSL and the network are not necessarily ready the
    #       instant the shell is. Op-Run retries regardless; the delay just
    #       keeps the log from opening with avoidable warnings on every logon.
    # Undo with: .\ops unschedule <op>
    return @{
        TaskName           = $TASK_NAME
        Description        = "$OpDescription. Starts at logon and runs until stopped with '.\ops stop $OpName'."
        Trigger            = "Logon"
        Delay              = "PT1M"
        ExecutionTimeLimit = "PT0S"
    }
}

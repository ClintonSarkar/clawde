#!/usr/bin/env pwsh
# clawde.ps1 - unified CLI for managing OpenCode + CCProxy (Windows)
#
# Commands:
#   start    - start CCProxy + OpenCode
#   stop     - stop both services
#   status   - health check both services
#   config   - view or edit configuration
#   auth     - re-authenticate Claude
#   update   - update to latest versions
#   logs     - tail logs from either service

# --- Paths ---
$ConfigDir  = Join-Path $env:APPDATA "clawde"
$DataDir    = Join-Path $env:LOCALAPPDATA "clawde"
$BinDir     = Join-Path $DataDir "bin"
$LogDir     = Join-Path $DataDir "logs"
$PidDir     = Join-Path $DataDir "pids"
$ConfigFile = Join-Path $ConfigDir "clawde.toml"

# --- Ensure dirs exist ---
foreach ($d in @($ConfigDir, $DataDir, $BinDir, $LogDir, $PidDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# --- Helpers ---

function Read-Config {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "Error: config not found at $ConfigFile" -ForegroundColor Red
        Write-Host "Run the installer first: irm https://raw.githubusercontent.com/ClintonSarkar/clawde/main/install.ps1 | iex"
        exit 1
    }
    # Simple TOML reader - clawde.toml is flat enough for this
    $config = @{}
    $section = ""
    foreach ($line in Get-Content $ConfigFile) {
        $line = $line.Trim()
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1]
            $config[$section] = @{}
        }
        elseif ($line -match '^([^#]+?)\s*=\s*(.*)$' -and $section) {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            # Try to parse as int
            $intVal = 0
            if ([int]::TryParse($val, [ref]$intVal)) {
                $config[$section][$key] = $intVal
            } else {
                $config[$section][$key] = $val
            }
        }
    }
    return $config
}

function Get-Pid-File($name) {
    $pidFile = Join-Path $PidDir "$name.pid"
    if (Test-Path $pidFile) {
        $val = (Get-Content $pidFile -Raw).Trim()
        $pidVal = 0
        if ([int]::TryParse($val, [ref]$pidVal)) { return $pidVal }
    }
    return $null
}

function Write-Pid-File($name, $processId) {
    $pidFile = Join-Path $PidDir "$name.pid"
    Set-Content -Path $pidFile -Value $processId -NoNewline
}

function Remove-Pid-File($name) {
    $pidFile = Join-Path $PidDir "$name.pid"
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force }
}

function Test-ProcessRunning($processId) {
    if (-not $processId) { return $false }
    try {
        $null = Get-Process -Id $processId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Find-Binary($name) {
    # Check clawde bin dir first
    $localPath = Join-Path $BinDir $name
    if (Test-Path $localPath) { return $localPath }
    # Fall back to a .cmd shim with the same basename (used when ccproxy.exe
    # was replaced by a pipx-installed wrapper, see Install-CCProxyViaPipx in
    # install.ps1).
    if ($name.EndsWith('.exe')) {
        $cmdLocal = Join-Path $BinDir ($name.Substring(0, $name.Length - 4) + '.cmd')
        if (Test-Path $cmdLocal) { return $cmdLocal }
    }
    # Fall back to PATH
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Write-Host "Error: $name not found - run 'clawde update' or reinstall" -ForegroundColor Red
    exit 1
}

function Get-ProxyPort($config) {
    $port = 8080
    if ($config.ContainsKey("proxy") -and $config["proxy"].ContainsKey("port")) {
        $port = $config["proxy"]["port"]
    }
    return $port
}

function Get-ProxyHost($config) {
    $host_ = "127.0.0.1"
    if ($config.ContainsKey("proxy") -and $config["proxy"].ContainsKey("host")) {
        $host_ = $config["proxy"]["host"]
    }
    return $host_
}

# --- Auth plugin helpers (for ccproxy Windows binary without bundled plugins) ---

function Test-Python311([ref]$pyPath) {
    # Check for Python 3.11+; returns $true and sets $pyPath.Value
    foreach ($candidate in @('py', 'python', 'python3')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try {
            $ver = & $cmd.Source --version 2>&1
            if ($ver -match 'Python (\d+)\.(\d+)') {
                $major = [int]$Matches[1]; $minor = [int]$Matches[2]
                if ($major -ge 3 -and $minor -ge 11) {
                    $pyPath.Value = $cmd.Source
                    return $true
                }
            }
        } catch {}
    }
    return $false
}

function Ensure-Python {
    # Returns path to a Python 3.11+ executable, or $null.
    # If none is found, offers to download and install it.
    $py = $null
    if (Test-Python311 ([ref]$py)) { return $py }

    Write-Host ""
    Write-Host "  Python 3.11+ is required for Claude OAuth support." -ForegroundColor Yellow
    $choice = Read-Host "  Download and install Python 3.11 now? [Y/n]"
    if ($choice -match '^[Nn]') {
        Write-Host "  You can install it manually from: https://www.python.org/downloads/" -ForegroundColor Cyan
        return $null
    }

    $pythonUrl = "https://www.python.org/ftp/python/3.11.11/python-3.11.11-amd64.exe"
    $installerPath = Join-Path $env:TEMP "python-3.11.11-amd64.exe"

    Write-Host "  [INFO] Downloading Python 3.11 installer..." -ForegroundColor Yellow
    try {
        # Try Invoke-WebRequest first, fall back to WebClient
        Invoke-WebRequest -Uri $pythonUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    } catch {
        try {
            $wc = New-Object System.Net.WebClient
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
            $wc.DownloadFile($pythonUrl, $installerPath)
        } catch {
            Write-Host "  [ERROR] Failed to download Python: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  Download from: https://www.python.org/downloads/" -ForegroundColor Cyan
            return $null
        }
    }

    Write-Host "  [INFO] Installing Python 3.11 (user-wide)..." -ForegroundColor Yellow
    $proc = Start-Process -FilePath $installerPath -ArgumentList "/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-Host "  [ERROR] Python installer failed (exit code $($proc.ExitCode))" -ForegroundColor Red
        # 3010 means reboot required - still succeeded
        if ($proc.ExitCode -eq 3010) {
            Write-Host "  [WARN] Python installed but a reboot is recommended" -ForegroundColor Yellow
        } else {
            return $null
        }
    }

    # Refresh PATH for this session
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")

    $py = $null
    if (Test-Python311 ([ref]$py)) {
        Write-Host "  [OK] Python 3.11+ installed at $py" -ForegroundColor Green
        return $py
    }
    Write-Host "  [ERROR] Python installed but not found on PATH. Restart your terminal and try again." -ForegroundColor Red
    return $null
}

function Ensure-Pipx($pythonExe) {
    # Ensure pipx is installed via the given python executable.
    # Returns $true if pipx is available after this call.
    $pipx = Get-Command pipx -ErrorAction SilentlyContinue
    if ($pipx) { return $true }

    Write-Host "  [INFO] Installing pipx..." -ForegroundColor Yellow
    try {
        $output = & $pythonExe -m pip install pipx 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            # pipx installs scripts to %APPDATA%\Python\Scripts under the user scheme
            $pipxScriptDir = Join-Path $env:APPDATA "Python\Scripts"
            if (Test-Path (Join-Path $pipxScriptDir "pipx.exe")) {
                $env:Path = "$pipxScriptDir;$env:Path"
            }
            Write-Host "  [OK] pipx installed" -ForegroundColor Green
            return $true
        }
    } catch {}

    Write-Host "  [WARN] pipx install failed" -ForegroundColor Yellow
    Write-Host "  Try: $pythonExe -m pip install pipx" -ForegroundColor Cyan
    return $false
}

# Resolve the path to the pipx-installed ccproxy.exe by asking pipx directly,
# NOT by PATH lookup. PATH lookup is unreliable here for two reasons:
#   1. The clawde bin dir is on PATH and may still hold a (broken) ccproxy.exe,
#      so Get-Command would resolve to that instead of the pipx one.
#   2. pipx's bin dir varies by pipx/Python version (%USERPROFILE%\.local\bin on
#      newer pipx, %APPDATA%\Python\Scripts or %LOCALAPPDATA%\pipx\bin on older).
# $ExcludeDir (the clawde bin dir) is never returned, so the caller can safely
# delete its own bin-dir binary without the resolver pointing back at it.
function Resolve-PipxCcproxy {
    param([string]$ExcludeDir)

    # Canonicalize for prefix comparison: backslashes only, single trailing
    # separator. Without this a forward-slash PATH entry (C:/.../bin\ccproxy.exe)
    # slips past a backslash $ExcludeDir and the bin-dir binary could be returned.
    $exDir = if ($ExcludeDir) { $ExcludeDir.Replace('/', '\').TrimEnd('\') + '\' } else { $null }

    $candidates = @()

    # 1) Authoritative: pipx tells us its bin dir.
    try {
        $binDir = (& pipx environment --value PIPX_BIN_DIR 2>$null | Out-String).Trim()
        if ($binDir) { $candidates += (Join-Path $binDir "ccproxy.exe") }
    } catch {}

    # 2) Known pipx bin locations across versions.
    $candidates += @(
        (Join-Path $env:USERPROFILE ".local\bin\ccproxy.exe")
        (Join-Path $env:APPDATA "Python\Scripts\ccproxy.exe")
        (Join-Path $env:LOCALAPPDATA "pipx\bin\ccproxy.exe")
    )

    # 3) PATH lookup LAST, -All so a pipx entry further down PATH survives even
    #    when the (excluded) bin-dir copy is the first match.
    foreach ($cmd in @(Get-Command ccproxy -All -ErrorAction SilentlyContinue)) {
        if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $cn = $c.Replace('/', '\')
        if ($exDir -and $cn.StartsWith($exDir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Install-PluginCCProxy {
    # Install ccproxy-api with plugins via pipx, then wire a .cmd shim into clawde\bin.
    # Returns $true on success.
    $pipx = Get-Command pipx -ErrorAction SilentlyContinue
    if (-not $pipx) { return $false }

    Write-Host "  [INFO] Installing ccproxy-api with plugins via pipx..." -ForegroundColor Yellow
    $installOut = & pipx install "ccproxy-api[plugins-claude,plugins-codex]" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        # May already be installed - try upgrade
        & pipx upgrade ccproxy-api 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] pipx install/upgrade failed" -ForegroundColor Yellow
            Write-Host "  $installOut" -ForegroundColor DarkGray
            return $false
        }
    }

    $ccproxyExe = Join-Path $BinDir "ccproxy.exe"
    $shimCmd = Join-Path $BinDir "ccproxy.cmd"

    # Resolve the pipx target BEFORE deleting anything (matching install.ps1). The
    # resolver excludes $BinDir, so deleting after is safe - but resolving first
    # means a resolver failure leaves the existing bin-dir artifacts (incl. the
    # broken .cmd that Cmd-Auth prints as a diagnostic) intact for the user.
    $pipxCcproxyPath = Resolve-PipxCcproxy -ExcludeDir $BinDir
    if (-not $pipxCcproxyPath) {
        Write-Host "  [WARN] pipx install succeeded but the ccproxy binary could not be located" -ForegroundColor Yellow
        Write-Host "  [WARN] check 'pipx environment --value PIPX_BIN_DIR' and 'pipx list'" -ForegroundColor Yellow
        return $false
    }

    # Now remove the old bin-dir binary/shim and write the new shim.
    if (Test-Path $ccproxyExe) { Remove-Item $ccproxyExe -Force -ErrorAction SilentlyContinue }
    if (Test-Path $shimCmd)    { Remove-Item $shimCmd -Force -ErrorAction SilentlyContinue }

    # Create .cmd shim pointing to the pipx entry point
    $shimContent = "@echo off`r`n`"$pipxCcproxyPath`" %*`r`n"
    Set-Content -Path $shimCmd -Value $shimContent -Encoding ASCII -Force

    Write-Host "  [OK] ccproxy-api installed via pipx ($pipxCcproxyPath)" -ForegroundColor Green
    return $true
}

# --- Commands ---

function Cmd-Start($extraArgs) {
    $config = Read-Config
    $port = Get-ProxyPort $config
    $host_ = Get-ProxyHost $config

    # Check if proxy already running
    $proxyPid = Get-Pid-File "proxy"
    if ($proxyPid -and (Test-ProcessRunning $proxyPid)) {
        Write-Host "[OK] CCProxy already running (PID $proxyPid)" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Starting CCProxy..." -ForegroundColor Cyan
        $ccproxyExe = Find-Binary "ccproxy.exe"
        $logFile = Join-Path $LogDir "ccproxy.log"
        $errFile = Join-Path $LogDir "ccproxy.err"
        if ($ccproxyExe.EndsWith('.cmd')) {
            # Shim to a pipx-installed ccproxy; route through cmd.exe.
            $proc = Start-Process -FilePath "cmd.exe" `
                -ArgumentList "/c", $ccproxyExe, "serve", "--port", $port `
                -RedirectStandardOutput $logFile `
                -RedirectStandardError $errFile `
                -NoNewWindow -PassThru
        } else {
            $proc = Start-Process -FilePath $ccproxyExe `
                -ArgumentList "serve", "--port", $port `
                -RedirectStandardOutput $logFile `
                -RedirectStandardError $errFile `
                -NoNewWindow -PassThru
        }
        Write-Pid-File "proxy" $proc.Id

        # Wait for health
        $healthy = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 500
            try {
                $resp = Invoke-RestMethod -Uri "http://${host_}:${port}/health" -TimeoutSec 2 -ErrorAction Stop
                $healthy = $true
                break
            } catch {
                continue
            }
        }
        if ($healthy) {
            Write-Host "[OK] CCProxy started (PID $($proc.Id)) - healthy" -ForegroundColor Green
        } else {
            Write-Host "[WARN] CCProxy started (PID $($proc.Id)) - health check failed, may still be starting" -ForegroundColor Yellow
        }
    }

    # Start OpenCode (foreground - interactive)
    $opencodePid = Get-Pid-File "opencode"
    if ($opencodePid -and (Test-ProcessRunning $opencodePid)) {
        Write-Host "[OK] OpenCode already running (PID $opencodePid)" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Starting OpenCode..." -ForegroundColor Cyan
        $opencodeExe = Find-Binary "opencode.exe"
        # The ccproxy-claude provider (baseURL + apiKey) is defined
        # authoritatively in opencode.json by the installer; OpenCode reads it
        # from there. Don't export a second, divergent provider definition here.
        # Interactive foreground - user interacts with this
        Write-Host "[INFO] Attaching to OpenCode console..." -ForegroundColor Cyan
        Write-Host "[INFO] Use /exit to stop OpenCode and return to shell`n" -ForegroundColor Cyan
        & $opencodeExe $extraArgs
        Write-Host "`n[INFO] OpenCode exited" -ForegroundColor Cyan
    }
}

# Kill a process and its entire descendant tree. CCProxy launched through the
# pipx .cmd shim is cmd.exe -> ccproxy launcher -> python.exe (the real server),
# so stopping only the recorded PID orphans the server. Recurse the FULL tree,
# children before parents, so no descendant is left holding the port.
function Stop-ProcessTree($procId) {
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$procId" -ErrorAction SilentlyContinue
        foreach ($c in $children) {
            Stop-ProcessTree $c.ProcessId
        }
    } catch {}
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
}

function Cmd-Stop {
    foreach ($name in @("opencode", "proxy")) {
        $procId = Get-Pid-File $name
        if ($procId -and (Test-ProcessRunning $procId)) {
            Stop-ProcessTree $procId
            # Stop-ProcessTree swallows errors, so confirm the kill actually
            # took rather than printing an unconditional success.
            if (Test-ProcessRunning $procId) {
                Write-Host "[ERROR] Failed to stop $name (PID $procId still running)" -ForegroundColor Red
            } else {
                Write-Host "[OK] $name stopped (was PID $procId)" -ForegroundColor Green
            }
        } else {
            Write-Host "[OK] $name not running" -ForegroundColor Green
        }
        Remove-Pid-File $name
    }

    # Defensive: if the PID file was stale but a ccproxy is still running
    # (e.g. orphaned by a previous shim launch), stop its whole tree by name too
    # - the named process is the launcher; its python.exe child is the server.
    $stray = Get-Process -Name ccproxy -ErrorAction SilentlyContinue
    foreach ($p in $stray) {
        Stop-ProcessTree $p.Id
        if (Test-ProcessRunning $p.Id) {
            Write-Host "[WARN] stray ccproxy (PID $($p.Id)) still running" -ForegroundColor Yellow
        } else {
            Write-Host "[OK] stopped stray ccproxy (PID $($p.Id))" -ForegroundColor Green
        }
    }
}

function Cmd-Status {
    $config = Read-Config
    $port = Get-ProxyPort $config
    $host_ = Get-ProxyHost $config

    # Proxy
    $proxyPid = Get-Pid-File "proxy"
    if ($proxyPid -and (Test-ProcessRunning $proxyPid)) {
        try {
            $resp = Invoke-RestMethod -Uri "http://${host_}:${port}/health" -TimeoutSec 3 -ErrorAction Stop
            Write-Host "[OK]   CCProxy   running (PID $proxyPid) - healthy" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] CCProxy   running (PID $proxyPid) - not responding" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[FAIL] CCProxy   not running" -ForegroundColor Red
    }

    # OpenCode runs in the foreground of `clawde start` (interactive console),
    # so there is no daemon PID to health-check here. Report by live process
    # presence instead of a stale PID file, and never as a red [FAIL] - its
    # absence just means no interactive session is currently attached.
    $opencodeProc = Get-Process -Name opencode -ErrorAction SilentlyContinue
    if ($opencodeProc) {
        Write-Host "[OK]   OpenCode  running (PID $($opencodeProc[0].Id))" -ForegroundColor Green
    } else {
        Write-Host "[INFO] OpenCode  not attached (starts in the foreground via 'clawde start')" -ForegroundColor Cyan
    }
}

function Cmd-Config($edit) {
    if ($edit) {
        $editor = if ($env:EDITOR) { $env:EDITOR } else { "notepad" }
        & $editor $ConfigFile
    } else {
        Write-Host "Config file: $ConfigFile"
        Write-Host ""
        Get-Content $ConfigFile
    }
}

function Test-CCProxyBinary {
    param([string]$BinaryPath)
    # Returns $true if the binary is executable and responds to --version
    try {
        # Use Start-Process with timeout to avoid hanging
        $tmpOut = Join-Path $env:TEMP "ccproxy_ver_$PID.out"
        $tmpErr = Join-Path $env:TEMP "ccproxy_ver_$PID.err"
        $p = Start-Process -FilePath $BinaryPath -ArgumentList "--version" -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $p | Wait-Process -Timeout 8 -ErrorAction SilentlyContinue | Out-Null
        if (-not $p.HasExited) { $p.Kill(); Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue; return $false }
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
        return ($p.ExitCode -eq 0)
    } catch {
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Repair-CCProxy {
    # Try to install or repair ccproxy binary (with plugins if possible).
    # Returns $true on success.
    Write-Host ""
    Write-Host "  [INFO] Attempting to install CCProxy..." -ForegroundColor Cyan

    # 1) Try pipx immediately
    $pipx = Get-Command pipx -ErrorAction SilentlyContinue
    if ($pipx) {
        if (Install-PluginCCProxy) {
            return $true
        }
    }

    # 2) Try Python + pipx
    $py = $null
    if (Test-Python311 ([ref]$py)) {
        Write-Host "  [INFO] Python found at $py - installing pipx..." -ForegroundColor Cyan
        if (Ensure-Pipx $py) {
            if (Install-PluginCCProxy) {
                return $true
            }
        }
    }

    # 3) Offer to download Python
    $pythonPath = Ensure-Python
    if ($pythonPath) {
        if (Ensure-Pipx $pythonPath) {
            if (Install-PluginCCProxy) {
                return $true
            }
        }
    }

    return $false
}

function Invoke-CCProxyWithTimeout {
    param([string]$BinaryPath, [string[]]$ArgumentList, [int]$TimeoutSeconds = 10)
    # Separate stdout/stderr targets: Start-Process rejects the SAME file for
    # both -RedirectStandardOutput and -RedirectStandardError.
    $tmpOut = Join-Path $env:TEMP "ccproxy_out_$PID.txt"
    $tmpErr = Join-Path $env:TEMP "ccproxy_err_$PID.txt"
    # Force UTF-8 on the child so it doesn't crash printing non-ASCII (e.g. its
    # "checkmark" success glyph) under a legacy Windows code page. Restore after.
    $prevIoEnc = $env:PYTHONIOENCODING; $prevUtf8 = $env:PYTHONUTF8
    $env:PYTHONIOENCODING = "utf-8"; $env:PYTHONUTF8 = "1"
    $p = $null
    try {
        $p = Start-Process -FilePath $BinaryPath -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $p | Wait-Process -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue | Out-Null
        if (-not $p.HasExited) {
            # Guard the kill: the child may exit between the check and Kill(),
            # which would otherwise throw into the catch and mislabel a genuine
            # timeout as a launch failure.
            try { $p.Kill() } catch {}
            return $null, $null, $true  # timed out
        }
        # Combine both streams so callers see everything the child emitted.
        $output = ((Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue) + (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue))
        return $output, $p.ExitCode, $false  # output, exitcode, timedout
    } catch {
        # Start-Process threw (e.g. bad binary path) - NOT a timeout. Guard the
        # kill against a null $p, and return the error as output with exitcode 1
        # + timedout=$false so callers surface a real error, not a false timeout.
        if ($p -and -not $p.HasExited) { $p.Kill() }
        return "ccproxy launch failed: $($_.Exception.Message)", 1, $false
    } finally {
        $env:PYTHONIOENCODING = $prevIoEnc; $env:PYTHONUTF8 = $prevUtf8
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# True if ccproxy's `auth login` output shows authentication succeeded, even if
# the process then exited non-zero. On success ccproxy prints
# "[green]checkmark[/green] Authentication successful!" and can crash ON THAT
# PRINT under a legacy Windows code page (UnicodeEncodeError on the glyph),
# exiting non-zero AFTER a fully successful login - so the exit code alone is
# unreliable. The UTF-8 env fix prevents the crash; this is the belt-and-braces
# fallback for any post-print non-zero exit. Only the `login`-emitted string is
# matched here (the "valid credentials" phrasing belongs to `auth status`).
function Test-AuthSucceeded {
    param([int]$ExitCode, [string]$Output)
    if ($ExitCode -eq 0) { return $true }
    if ($Output -match 'Authentication successful') { return $true }
    return $false
}

function Cmd-Auth($Force) {
    Write-Host "[INFO] Starting Claude OAuth flow..." -ForegroundColor Cyan
    Write-Host "  A browser window will open for you to log in."
    Write-Host ""

    # Force UTF-8 for every ccproxy child spawned below, so it can print its
    # non-ASCII success message without crashing on a legacy Windows code page.
    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONUTF8 = "1"

    # Find the binary and verify it works
    $ccproxy = Find-Binary "ccproxy.exe"

    if (-not (Test-CCProxyBinary $ccproxy)) {
        Write-Host "  [WARN] ccproxy binary at '$ccproxy' is not responding." -ForegroundColor Yellow

        if ($ccproxy.EndsWith('.cmd')) {
            Write-Host "    (it is a .cmd shim - the target executable may be missing)" -ForegroundColor DarkGray
            # Show what the shim points to
            $shimContent = Get-Content $ccproxy -Raw
            Write-Host "    Shim content: $shimContent" -ForegroundColor DarkGray
        }

        # Try to repair
        $fixed = Repair-CCProxy
        if (-not $fixed) {
            Write-Host ""
            Write-Host "  [ERROR] Could not find or install ccproxy." -ForegroundColor Red
            Write-Host "  Try running the installer first:" -ForegroundColor Cyan
            Write-Host "    irm https://raw.githubusercontent.com/ClintonSarkar/clawde/main/install.ps1 | iex" -ForegroundColor White
            Write-Host ""
            exit 1
        }

        # Re-find now that repair ran
        $ccproxy = Find-Binary "ccproxy.exe"
        Write-Host "  [OK] CCProxy installed/repaired" -ForegroundColor Green
        Write-Host ""
    }

    # Initialize CCProxy config if missing (otherwise auth provider can't be found)
    $ccproxyConfigDir = Join-Path $env:USERPROFILE ".config\ccproxy"
    $ccproxyConfigFile = Join-Path $ccproxyConfigDir "ccproxy.config.settings"
    if (-not (Test-Path $ccproxyConfigFile)) {
        Write-Host "  [INFO] Initializing CCProxy config (first-time setup)..." -ForegroundColor Yellow
        $initOut, $initCode, $initTimedOut = Invoke-CCProxyWithTimeout -BinaryPath $ccproxy -ArgumentList @("config", "init", "--output-dir", $ccproxyConfigDir) -TimeoutSeconds 10
        if ($initTimedOut) {
            Write-Host "  [WARN] ccproxy config init timed out (continuing with defaults)" -ForegroundColor Yellow
        } elseif ($initCode -ne 0) {
            Write-Host "  [WARN] ccproxy config init had warnings (continuing)" -ForegroundColor Yellow
            if ($initOut) { Write-Host ("    " + $initOut.Trim()) -ForegroundColor DarkGray }
        }
    }

    # Check if any auth providers are available before attempting login
    $providersCheck = & $ccproxy auth providers 2>&1 | Out-String
    if ($providersCheck -match 'No OAuth providers found') {
        Write-Host ""
        Write-Host "  [WARN] This CCProxy binary was built without auth plugin support." -ForegroundColor Yellow
        Write-Host "  Installing ccproxy-api with plugins for full OAuth support..." -ForegroundColor Cyan
        Write-Host ""

        $installed = Repair-CCProxy

        if ($installed) {
            Write-Host ""
            Write-Host "  [INFO] Plugin-enabled ccproxy installed. Re-running auth..." -ForegroundColor Cyan
            $ccproxy = Find-Binary "ccproxy.exe"
            # Config init with timeout
            $initOut2, $initCode2, $initTimedOut2 = Invoke-CCProxyWithTimeout -BinaryPath $ccproxy -ArgumentList @("config", "init", "--output-dir", $ccproxyConfigDir) -TimeoutSeconds 10
            $authOutput = & $ccproxy auth login claude 2>&1 | Out-String
            if (Test-AuthSucceeded $LASTEXITCODE $authOutput) {
                Write-Host "`n[OK] Authentication complete" -ForegroundColor Green
                return
            }
        }

        Write-Host ""
        Write-Host "  [ERROR] Could not install auth plugins automatically." -ForegroundColor Red
        Write-Host ""
        Write-Host "  To fix this manually:" -ForegroundColor Cyan
        Write-Host "    1. Install Python 3.11+ from: https://www.python.org/downloads/" -ForegroundColor White
        Write-Host "    2. Run: python -m pip install pipx" -ForegroundColor White
        Write-Host "    3. Run: pipx install \"ccproxy-api[plugins-claude,plugins-codex]\"" -ForegroundColor White
        Write-Host "    4. Re-run: clawde auth" -ForegroundColor White
        Write-Host ""
        exit 1
    }

    # Already authenticated? Ask ccproxy's status before pushing a fresh login,
    # so a user with valid credentials isn't sent through a needless OAuth
    # round-trip. `auth status` prints "Authenticated with valid credentials"
    # when a usable token exists (this is the command that emits that phrase).
    # Skipped under -Force/--relogin so the user can still re-auth deliberately
    # (switch accounts, or replace credentials ccproxy reports as valid but that
    # are actually revoked - status has no revocation check).
    if (-not $Force) {
        $statusOutput = & $ccproxy auth status claude 2>&1 | Out-String
        if ($statusOutput -match 'Authenticated with valid credentials') {
            Write-Host "`n[OK] Already authenticated - no login needed" -ForegroundColor Green
            Write-Host "  To re-authenticate anyway (e.g. switch accounts): clawde auth --force" -ForegroundColor DarkGray
            return
        }
    }

    # Run auth login
    Write-Host "  Opening browser for authentication..." -ForegroundColor Cyan
    $authOutput = & $ccproxy auth login claude 2>&1 | Out-String
    if (Test-AuthSucceeded $LASTEXITCODE $authOutput) {
        Write-Host "`n[OK] Authentication complete" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  [ERROR] Authentication failed. Raw output:" -ForegroundColor Red
        Write-Host ""
        $authOutput.Trim() -split "`n" | ForEach-Object {
            $line = $_.Trim()
            if ($line) {
                Write-Host "    | $line" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
        exit 1
    }
}

function Cmd-Update {
    Write-Host "[INFO] Updating all components...`n" -ForegroundColor Cyan
    $anyErrors = $false

    # --- OpenCode ---
    $opencodeExe = Find-Binary "opencode.exe"
    if ($opencodeExe) {
        $ver = (& $opencodeExe --version 2>$null) -replace '\s+', ' '
        $ver = $ver.Trim()
        # Suppress upgrade noise: capture output, only show on failure
        $upgradeOutput = & $opencodeExe upgrade 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $newVer = (& $opencodeExe --version 2>$null) -replace '\s+', ' '
            $newVer = $newVer.Trim()
            if ($ver -ne $newVer) {
                Write-Host "  [OK] OpenCode  $ver -> $newVer" -ForegroundColor Green
            } else {
                Write-Host "  [OK] OpenCode  $ver (already latest)" -ForegroundColor Green
            }
        } else {
            Write-Host "  [ERROR] OpenCode upgrade failed" -ForegroundColor Red
            # Show last few lines of output for debugging
            $lines = $upgradeOutput -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3
            foreach ($l in $lines) { Write-Host "         $l" -ForegroundColor Gray }
            $anyErrors = $true
        }
    } else {
        Write-Host "  [ERROR] opencode not found" -ForegroundColor Red
        $anyErrors = $true
    }

    # --- CCProxy ---
    $ccproxyExe = Find-Binary "ccproxy.exe"
    if ($ccproxyExe) {
        # Suppress stderr (config_file_missing warning)
        $ver = (& $ccproxyExe --version 2>$null)
        # Strip ANSI escape codes and extract version number (e.g. "ccproxy 0.2.10")
        $verClean = ($ver -replace '\x1b\[[0-9;]*m', '' -replace '\s+', ' ').Trim()
        # Match "ccproxy X.Y.Z" pattern at end of output
        $verMatch = [regex]::Match($verClean, 'ccproxy\s+(\d+\.\d+\.\d+)')
        if ($verMatch.Success) {
            $currentVer = $verMatch.Groups[1].Value
        } else {
            $verMatch = [regex]::Match($verClean, '(\d+\.\d+\.\d+)')
            if ($verMatch.Success) {
                $currentVer = $verMatch.Groups[1].Value
            } else {
                $currentVer = $verClean
            }
        }
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ClintonSarkar/ccproxy-api/releases/latest" -TimeoutSec 15
            $latestTag = $release.tag_name
            if ($latestTag -ne "v$currentVer") {
                Write-Host "  [INFO] CCProxy  $currentVer -> $latestTag" -ForegroundColor Yellow
                $arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
                $assetName = "ccproxy-${latestTag}-${arch}-pc-windows-msvc.zip"
                $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
                if ($asset) {
                    $zipPath = Join-Path $env:TEMP "ccproxy-update.zip"
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
                    $binDir = Split-Path $ccproxyExe
                    # Stop running ccproxy before overwriting (check PID file AND process name)
                    $ccproxyProcId = Get-Pid-File "proxy"
                    if ($ccproxyProcId -and (Test-ProcessRunning $ccproxyProcId)) {
                        Write-Host "  [INFO] Stopping CCProxy (PID $ccproxyProcId) for update..." -ForegroundColor Yellow
                        Stop-Process -Id $ccproxyProcId -Force -ErrorAction SilentlyContinue
                        Remove-Pid-File "proxy"
                        Start-Sleep -Milliseconds 500
                    }
                    # Also check by process name (PID file may be stale)
                    $runningProcs = Get-Process -Name ccproxy -ErrorAction SilentlyContinue
                    if ($runningProcs) {
                        foreach ($p in $runningProcs) {
                            Write-Host "  [INFO] Stopping CCProxy (PID $($p.Id)) for update..." -ForegroundColor Yellow
                            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                        }
                        Remove-Pid-File "proxy"
                        Start-Sleep -Milliseconds 500
                    }
                    # Extract to temp dir first, then move (avoids Expand-Archive delete issues)
                    $extractDir = Join-Path $env:TEMP "ccproxy-extract"
                    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
                    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
                    $extractedExe = Join-Path $extractDir "ccproxy.exe"
                    if (-not (Test-Path $extractedExe)) {
                        $found = Get-ChildItem $extractDir -Recurse -Filter "ccproxy.exe" | Select-Object -First 1
                        if ($found) { $extractedExe = $found.FullName }
                    }
                    if (Test-Path $extractedExe) {
                        Copy-Item $extractedExe $ccproxyExe -Force
                        Write-Host "  [OK] CCProxy  updated to $latestTag" -ForegroundColor Green
                    } else {
                        Write-Host "  [ERROR] ccproxy.exe not found after extraction" -ForegroundColor Red
                        $anyErrors = $true
                    }
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Host "  [WARN] No binary found for $latestTag" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  [OK] CCProxy  v$currentVer (already latest)" -ForegroundColor Green
            }
        } catch {
            Write-Host "  [ERROR] Could not check CCProxy updates: $($_.Exception.Message)" -ForegroundColor Red
            $anyErrors = $true
        }
    } else {
        Write-Host "  [ERROR] ccproxy not found - run installer" -ForegroundColor Red
        $anyErrors = $true
    }

    # --- Self-update clawde CLI ---
    Self-Update

    Write-Host ""
    if ($anyErrors) {
        Write-Host "[WARN] Update completed with errors" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Update complete" -ForegroundColor Green
    }
}

function Self-Update {
    $updateUrl = "https://raw.githubusercontent.com/ClintonSarkar/clawde/main/cli/clawde.ps1"
    $thisScript = $PSCommandPath
    if (-not $thisScript) { $thisScript = Join-Path $BinDir "clawde.ps1" }
    $backupPath = $thisScript + ".bak"

    try {
        $tmpFile = Join-Path $env:TEMP "clawde-update.ps1"
        Invoke-WebRequest -Uri $updateUrl -OutFile $tmpFile -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop

        $currentHash = (Get-FileHash $thisScript -Algorithm SHA256).Hash
        $newHash = (Get-FileHash $tmpFile -Algorithm SHA256).Hash

        if ($currentHash -eq $newHash) {
            Write-Host "  [OK] clawde CLI (already latest)" -ForegroundColor Green
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        } else {
            Copy-Item $thisScript $backupPath -Force
            Copy-Item $tmpFile $thisScript -Force
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] clawde CLI updated (backup: $backupPath)" -ForegroundColor Green

            # Also update .cmd shim
            $clawdeCmdPath = Join-Path $BinDir "clawde.cmd"
            $cmdUrl = "https://raw.githubusercontent.com/ClintonSarkar/clawde/main/cli/clawde.cmd"
            $tmpCmd = Join-Path $env:TEMP "clawde-update.cmd"
            try {
                Invoke-WebRequest -Uri $cmdUrl -OutFile $tmpCmd -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                Copy-Item $tmpCmd $clawdeCmdPath -Force
                Remove-Item $tmpCmd -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "  [WARN] clawde.cmd not updated: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "  [WARN] clawde CLI not updated: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Cmd-Logs($service, $follow, $lines) {
    if (-not $service) { $service = "proxy" }
    $logFile = Join-Path $LogDir "$service.log"

    if (-not (Test-Path $logFile)) {
        Write-Host "No logs found for $service at $logFile" -ForegroundColor Red
        exit 1
    }

    if ($follow) {
        Get-Content $logFile -Wait -Tail $lines
    } else {
        Get-Content $logFile -Tail $lines
    }
}

# --- Main ---

$command = $args[0]
if (-not $command) {
    Write-Host "clawde - Claude Work to OpenCode bridge"
    Write-Host ""
    Write-Host "Usage: clawde <command> [options]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  start    Start CCProxy + OpenCode"
    Write-Host "  stop     Stop both services"
    Write-Host "  status   Check health of both services"
    Write-Host "  config   View or edit configuration"
    Write-Host "  auth     Log in to Claude (skips if already authenticated; use --force to re-auth)"
    Write-Host "  update   Update to latest versions"
    Write-Host "  logs     Tail logs (proxy | opencode)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --help, -h   Show this help"
    exit 0
}

if ($command -eq "--help" -or $command -eq "-h") {
    & $PSCommandPath
    exit 0
}

switch ($command) {
    "start" {
        $extra = if ($args.Length -gt 1) { $args[1..($args.Length - 1)] } else { @() }
        Cmd-Start $extra
    }
    "stop" { Cmd-Stop }
    "status" { Cmd-Status }
    "config" {
        $edit = $args.Contains("--edit") -or $args.Contains("-e")
        Cmd-Config $edit
    }
    "auth" {
        $force = $args.Contains("--force") -or $args.Contains("--relogin")
        Cmd-Auth $force
    }
    "update" { Cmd-Update }
    "logs" {
        $service = $null
        $follow = $false
        $lineCount = 50
        for ($i = 1; $i -lt $args.Length; $i++) {
            switch ($args[$i]) {
                "-f" { $follow = $true }
                "--follow" { $follow = $true }
                "-n" { $lineCount = [int]$args[++$i] }
                "--lines" { $lineCount = [int]$args[++$i] }
                default { $service = $args[$i] }
            }
        }
        Cmd-Logs $service $follow $lineCount
    }
    default {
        Write-Host "Unknown command: $command" -ForegroundColor Red
        Write-Host "Run 'clawde --help' for usage"
        exit 1
    }
}

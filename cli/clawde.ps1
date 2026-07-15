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
        $proc = Start-Process -FilePath $ccproxyExe `
            -ArgumentList "serve", "--port", $port `
            -RedirectStandardOutput $logFile `
            -RedirectStandardError $errFile `
            -NoNewWindow -PassThru
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
        $env:OPENCODE_PROVIDER_CLAWDE_BASE_URL = "http://${host_}:${port}/v1"
        $env:OPENCODE_PROVIDER_CLAWDE_API_KEY = "clawde"
        # Interactive foreground - user interacts with this
        Write-Host "[INFO] Attaching to OpenCode console..." -ForegroundColor Cyan
        Write-Host "[INFO] Use /exit to stop OpenCode and return to shell`n" -ForegroundColor Cyan
        & $opencodeExe $extraArgs
        Write-Host "`n[INFO] OpenCode exited" -ForegroundColor Cyan
    }
}

function Cmd-Stop {
    foreach ($name in @("opencode", "proxy")) {
        $procId = Get-Pid-File $name
        if ($procId -and (Test-ProcessRunning $procId)) {
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                Write-Host "[OK] $name stopped (was PID $procId)" -ForegroundColor Green
            } catch {
                Write-Host "[ERROR] Failed to stop ${name}: $_" -ForegroundColor Red
            }
        } else {
            Write-Host "[OK] $name not running" -ForegroundColor Green
        }
        Remove-Pid-File $name
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

    # OpenCode
    $opencodePid = Get-Pid-File "opencode"
    if ($opencodePid -and (Test-ProcessRunning $opencodePid)) {
        Write-Host "[OK]   OpenCode  running (PID $opencodePid)" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] OpenCode  not running" -ForegroundColor Red
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

function Cmd-Auth {
    Write-Host "[INFO] Starting Claude OAuth flow..." -ForegroundColor Cyan
    Write-Host "  A browser window will open for you to log in."
    Write-Host ""
    try {
        $ccproxy = Find-Binary "ccproxy.exe"
        & $ccproxy auth login claude
        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n[OK] Authentication complete" -ForegroundColor Green
        } else {
            Write-Host "`n[ERROR] Authentication failed" -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host "[ERROR] ccproxy not found - run 'clawde update' to install" -ForegroundColor Red
        exit 1
    }
}

function Cmd-Update {
    Write-Host "[INFO] Updating OpenCode..." -ForegroundColor Cyan

    $opencodeExe = Find-Binary "opencode.exe"
    if ($opencodeExe) {
        $ver = & $opencodeExe --version 2>&1
        Write-Host "  Current: $ver"
        Write-Host "  Running self-upgrade..."
        & $opencodeExe upgrade 2>&1
    } else {
        Write-Host "  [ERROR] opencode not found" -ForegroundColor Red
    }

Write-Host ""
    Write-Host "[INFO] Updating CCProxy..." -ForegroundColor Cyan

    $ccproxyExe = Find-Binary "ccproxy.exe"
    if ($ccproxyExe) {
        $ver = & $ccproxyExe --version 2>&1
        Write-Host "  Current: $ver"
        # Check for newer release
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ClintonSarkar/ccproxy-api/releases/latest" -TimeoutSec 15
            $latestTag = $release.tag_name
            $currentVer = ($ver -replace ".*version\s*", "" -replace "\s.*", "").Trim()
            if ($latestTag -ne "v$currentVer") {
                Write-Host "  Latest:  $latestTag"
                Write-Host "  Downloading update..."
                $arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "i686" }
                $assetName = "ccproxy-${latestTag}-${arch}-pc-windows-msvc.zip"
                $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
                if ($asset) {
                    $zipPath = Join-Path $env:TEMP "ccproxy-update.zip"
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
                    $binDir = Split-Path $ccproxyExe
                    Expand-Archive -Path $zipPath -DestinationPath $binDir -Force
                    $extractedExe = Join-Path $binDir "ccproxy.exe"
                    if (-not (Test-Path $extractedExe)) {
                        $found = Get-ChildItem $binDir -Recurse -Filter "ccproxy.exe" | Select-Object -First 1
                        if ($found) { Move-Item $found.FullName $extractedExe -Force }
                    }
                    Remove-Item $zipPath -Force
                    Write-Host "  [OK] CCProxy updated" -ForegroundColor Green
                } else {
                    Write-Host "  [WARN] No binary found for $latestTag" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  Already up to date"
            }
        } catch {
            Write-Host "  [ERROR] Could not check for updates: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  [ERROR] ccproxy not found - run installer or clawde update --install" -ForegroundColor Red
    }

    Self-Update

    Write-Host "`n[OK] Update complete" -ForegroundColor Green
}

function Self-Update {
    Write-Host "`n[INFO] Checking for clawde CLI updates..." -ForegroundColor Cyan

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
            Write-Host "  clawde CLI is up to date" -ForegroundColor Green
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            return
        }

        Write-Host "  Updating clawde CLI..." -ForegroundColor Yellow
        Copy-Item $thisScript $backupPath -Force
        Copy-Item $tmpFile $thisScript -Force
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] clawde CLI updated (backup saved as $backupPath)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] Could not update clawde CLI: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  You can update manually: irm $updateUrl -o $thisScript" -ForegroundColor Gray
    }

    # Update .cmd shim
    Write-Host "[INFO] Updating clawde.cmd shim..." -ForegroundColor Cyan
    $clawdeCmdPath = Join-Path $BinDir "clawde.cmd"
    try {
        $cmdUrl = "https://raw.githubusercontent.com/ClintonSarkar/clawde/main/cli/clawde.cmd"
        $tmpCmd = Join-Path $env:TEMP "clawde-update.cmd"
        Invoke-WebRequest -Uri $cmdUrl -OutFile $tmpCmd -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        Copy-Item $tmpCmd $clawdeCmdPath -Force
        Remove-Item $tmpCmd -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] clawde.cmd updated" -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] Could not update clawde.cmd: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  You can update manually: irm $cmdUrl -o $clawdeCmdPath" -ForegroundColor Gray
        Write-Host "  You can update manually: irm $updateUrl -o $thisScript" -ForegroundColor Gray
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
    Write-Host "  auth     Re-authenticate Claude"
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
    "auth" { Cmd-Auth }
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

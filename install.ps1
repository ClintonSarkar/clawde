# clawde installer — Windows (PowerShell 5+)
# Run: irm https://raw.githubusercontent.com/ClintonSarkar/clawde/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$CLAWDE_VERSION = "0.1.0"
$OPENCODE_REPO = "ClintonSarkar/opencode"
$CCPROXY_PACKAGE = "ccproxy-api"

$CLAWDE_CONFIG_DIR = Join-Path $env:APPDATA "clawde"
$CLAWDE_DATA_DIR = Join-Path $env:LOCALAPPDATA "clawde"
$CLAWDE_BIN_DIR = Join-Path $env:LOCALAPPDATA "clawde\bin"

function Write-Info  { Write-Host "[INFO]  $args" -ForegroundColor Cyan }
function Write-OK    { Write-Host "[OK]    $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "[WARN]  $args" -ForegroundColor Yellow }
function Write-Err   { Write-Host "[ERROR] $args" -ForegroundColor Red; exit 1 }

function Show-Banner {
  Write-Host ""
  Write-Host "  ╔══════════════════════════════════════╗"
  Write-Host "  ║         clawde installer              ║"
  Write-Host "  ║  Claude Work -> OpenCode bridge       ║"
  Write-Host "  ╚══════════════════════════════════════╝"
  Write-Host ""
}

function Detect-Arch {
  $arch = $env:PROCESSOR_ARCHITECTURE
  switch ($arch) {
    "AMD64"     { return "x64" }
    "ARM64"     { return "arm64" }
    default     { Write-Err "Unsupported architecture: $arch" }
  }
}

function Check-Deps {
  $missing = @()

  if (-not (Get-Command curl -ErrorAction SilentlyContinue) -and
      -not (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) {
    $missing += "curl/Invoke-WebRequest"
  }

  if ($missing.Count -gt 0) {
    Write-Err "Missing dependencies: $($missing -join ', ')"
  }
}

function Install-OpenCode {
  Write-Info "[1/5] Installing OpenCode binary..."

  $opencodeExe = Join-Path $CLAWDE_BIN_DIR "opencode.exe"

  # Check if already installed
  if (Test-Path $opencodeExe) {
    Write-Warn "OpenCode already installed at $opencodeExe — skipping"
    return
  }

  $arch = Detect-Arch

  # Get latest release tag from fork
  try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$OPENCODE_REPO/releases/latest" -UseBasicParsing
    $tag = $release.tag_name
  } catch {
    Write-Warn "No pre-built release found on $OPENCODE_REPO — building from source"
    Install-OpenCodeFromSource
    return
  }

  $downloadUrl = "https://github.com/$OPENCODE_REPO/releases/download/$tag/opencode-windows-$arch.exe"

  New-Item -ItemType Directory -Path $CLAWDE_BIN_DIR -Force | Out-Null
  Invoke-WebRequest -Uri $downloadUrl -OutFile $opencodeExe -UseBasicParsing

  # Add to PATH (user-level)
  $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
  if ($userPath -notlike "*$CLAWDE_BIN_DIR*") {
    [Environment]::SetEnvironmentVariable("PATH", "$userPath;$CLAWDE_BIN_DIR", "User")
    $env:PATH += ";$CLAWDE_BIN_DIR"
    Write-Warn "Added $CLAWDE_BIN_DIR to PATH (restart terminal to take effect)"
  }

  Write-OK "OpenCode $tag installed"
}

function Install-OpenCodeFromSource {
  $go = Get-Command go -ErrorAction SilentlyContinue
  if (-not $go) {
    Write-Err "Go not installed. Install from https://go.dev/dl/"
  }

  $tmpDir = Join-Path $env:TEMP "clawde-opencode-build-$(Get-Random)"
  git clone "https://github.com/$OPENCODE_REPO.git" $tmpDir
  Push-Location $tmpDir
  go build -o (Join-Path $CLAWDE_BIN_DIR "opencode.exe") .
  Pop-Location
  Remove-Item -Recurse -Force $tmpDir
  Write-OK "OpenCode built from source"
}

function Install-CCProxy {
  Write-Info "[2/5] Installing CCProxy..."

  # Prefer uv
  $uv = Get-Command uv -ErrorAction SilentlyContinue
  if ($uv) {
    uv tool install "$CCPROXY_PACKAGE[all]"
  }
  # Fallback to pipx
  elseif (Get-Command pipx -ErrorAction SilentlyContinue) {
    pipx install "$CCPROXY_PACKAGE[all]"
  }
  # Fallback to pip --user
  elseif (Get-Command pip -ErrorAction SilentlyContinue) {
    Write-Warn "Neither uv nor pipx found — using pip --user"
    pip install --user "$CCPROXY_PACKAGE[all]"
  }
  else {
    Write-Err "No Python package manager found. Install uv: https://docs.astral.sh/uv/"
  }

  Write-OK "CCProxy installed"
}

function Interactive-Config {
  Write-Info "[3/5] Claude authentication"

  Write-Host ""
  Write-Host "  Choose authentication method:"
  Write-Host "    1. OAuth login (opens browser)"
  Write-Host "    2. Use existing Claude CLI token"
  Write-Host ""
  $authChoice = Read-Host "  Select [1]"
  if (-not $authChoice) { $authChoice = "1" }

  $authMethod = ""
  $cliTokenPath = ""

  switch ($authChoice) {
    "1" { $authMethod = "oauth" }
    "2" {
      $authMethod = "cli_token"
      $cliTokenPath = Read-Host "  Path to Claude CLI token [$env:USERPROFILE\.claude\credentials.json]"
      if (-not $cliTokenPath) { $cliTokenPath = Join-Path $env:USERPROFILE ".claude\credentials.json" }
      if (-not (Test-Path $cliTokenPath)) {
        Write-Warn "File not found: $cliTokenPath (you can set this later)"
      }
    }
    default { $authMethod = "oauth" }
  }

  Write-Info "[4/5] Configuration"

  $port = Read-Host "  Proxy port [8080]"
  if (-not $port) { $port = "8080" }

  $autoStartInput = Read-Host "  Auto-start on boot? [y/N]"
  if (-not $autoStartInput) { $autoStartInput = "N" }
  $autoStart = if ($autoStartInput -match "^[Yy]") { "true" } else { "false" }

  $models = Read-Host "  Models to expose [all]"
  if (-not $models) { $models = "all" }

  # Write config
  New-Item -ItemType Directory -Path $CLAWDE_CONFIG_DIR -Force | Out-Null

  $configContent = @"
[proxy]
port = $port
host = "127.0.0.1"

[claude]
auth_method = "$authMethod"
cli_token_path = "$cliTokenPath"

[opencode]
provider_name = "clawde"
auto_start = $autoStart

[models]
expose = "$models"

[logging]
level = "info"
rotation_days = 7
"@

  $configPath = Join-Path $CLAWDE_CONFIG_DIR "clawde.toml"
  Set-Content -Path $configPath -Value $configContent

  Write-OK "Config written to $configPath"
}

function Setup-Service {
  Write-Info "[5/5] Setting up service management..."

  $configPath = Join-Path $CLAWDE_CONFIG_DIR "clawde.toml"
  $configContent = Get-Content $configPath -Raw
  $autoStart = if ($configContent -match 'auto_start\s*=\s*true') { $true } else { $false }

  if ($autoStart) {
    # Windows scheduled task for auto-start
    $taskAction = New-ScheduledTaskAction -Execute "ccproxy" -Argument "serve --port 8080"
    $taskTrigger = New-ScheduledTaskTrigger -AtLogon
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName "clawde-proxy" -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Force | Out-Null

    Write-OK "Scheduled task installed (auto-start on login)"
  } else {
    Write-OK "Auto-start disabled — use 'clawde start' manually"
  }
}

function Final-Message {
  Write-Host ""
  Write-OK "clawde is ready!"
  Write-Host ""
  Write-Host "  Commands:"
  Write-Host "    clawde start     — start proxy + OpenCode"
  Write-Host "    clawde stop      — stop both"
  Write-Host "    clawde status    — check health"
  Write-Host "    clawde config    — reconfigure"
  Write-Host "    clawde auth      — re-authenticate Claude"
  Write-Host "    clawde update    — update to latest"
  Write-Host "    clawde logs      — tail logs"
  Write-Host ""
}

# Main
Show-Banner
Check-Deps
Install-OpenCode
Install-CCProxy
Interactive-Config
Setup-Service
Final-Message

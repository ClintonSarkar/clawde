# clawde installer — Windows (PowerShell 5+)
#   Claude Work → OpenCode bridge
#
# Quick install (run as Administrator):
#   irm https://clawde.dev/install.ps1 | iex
#
# With options:
#   irm https://clawde.dev/install.ps1 | iex " -Yes -Verbose"
#   irm https://clawde.dev/install.ps1 | iex " -Uninstall"
#
# Environment variables (for CI / automation):
#   CLAWDE_PORT         Proxy port (default: 8080)
#   CLAWDE_AUTH_METHOD  Auth method: oauth | cli_token (default: oauth)
#   CLAWDE_CLI_TOKEN_PATH  Path to Claude CLI credentials JSON
#   CLAWDE_AUTO_START   Auto-start on login: true | false (default: false)
#   CLAWDE_MODELS       Models to expose (default: all)

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Yes,       # Non-interactive mode; accept all defaults
    [switch]$Verbose,   # Enable verbose/debug output
    [switch]$Uninstall, # Remove clawde completely
    [switch]$Help       # Show help
)

# ====================================================================
# Constants
# ====================================================================
$Script:CLAWDE_VERSION = "0.1.0"
$Script:OPENCODE_REPO  = "ClintonSarkar/opencode"
$Script:CCPROXY_PACKAGE = "ccproxy-api"

$Script:CLAWDE_CONFIG_DIR  = Join-Path $env:APPDATA "clawde"
$Script:CLAWDE_DATA_DIR    = Join-Path $env:LOCALAPPDATA "clawde"
$Script:CLAWDE_BIN_DIR     = Join-Path $env:LOCALAPPDATA "clawde\bin"
$Script:OPENCODE_EXE       = Join-Path $Script:CLAWDE_BIN_DIR "opencode.exe"
$Script:CLAWDE_CONFIG_FILE = Join-Path $Script:CLAWDE_CONFIG_DIR "clawde.toml"
$Script:TASK_NAME          = "clawde-proxy"

# ====================================================================
# State
# ====================================================================
$Script:InstallCompleted = $false
$Script:RollbackItems    = @()
$Script:SkipOpenCode     = $false
$Script:SkipConfig       = $false
$Script:ExistingOpenCodePath = $null
$Script:AuthPending          = $false

# ====================================================================
# Logging
# ====================================================================
function Write-Info  { Write-Host "[INFO]  $args" -ForegroundColor Cyan }
function Write-OK    { Write-Host "[OK]    $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "[WARN]  $args" -ForegroundColor Yellow }

function Write-Err {
    Write-Host "[ERROR] $args" -ForegroundColor Red
    exit 1
}

function Write-DebugMsg {
    if ($Script:Verbose -or $PSBoundParameters.ContainsKey('Verbose')) {
        Write-Host "[DEBUG] $args" -ForegroundColor DarkGray
    }
}

# ====================================================================
# Help
# ====================================================================
function Show-Help {
    @"
Usage: install.ps1 [OPTIONS]

Install clawde — the Claude Work to OpenCode bridge.

Options:
  -Yes          Non-interactive mode; accept all defaults
  -Verbose      Show detailed debug output
  -Uninstall    Remove clawde and all its components cleanly
  -Help         Show this help message and exit

Environment variables (overrides for -Yes / CI mode):
  CLAWDE_PORT         Proxy port number (1024-65535, default: 8080)
  CLAWDE_AUTH_METHOD  Authentication: oauth | cli_token (default: oauth)
  CLAWDE_CLI_TOKEN_PATH  Path to Claude CLI token file
  CLAWDE_AUTO_START   Auto-start on login: true | false (default: false)
  CLAWDE_MODELS       Models to expose (default: all)

Examples:
  .\install.ps1                  Interactive installation
  .\install.ps1 -Yes            Install with default settings
  .\install.ps1 -Uninstall      Remove clawde completely
  .\install.ps1 -Verbose        Install with debug output
"@
    exit 0
}

# ====================================================================
# Rollback / Cleanup
# ====================================================================
function Register-Rollback {
    param([string]$Path)
    $Script:RollbackItems += $Path
    Write-DebugMsg "Registered rollback: $Path"
}

function Clear-Rollback {
    $Script:RollbackItems = @()
}

function Invoke-Rollback {
    if ($Script:InstallCompleted) { return }
    if ($Script:RollbackItems.Count -eq 0) { return }

    Write-Host ""
    Write-Warn "Installation did not complete — rolling back..."
    foreach ($item in $Script:RollbackItems) {
        if (Test-Path -LiteralPath $item -PathType Leaf) {
            Remove-Item -LiteralPath $item -Force -ErrorAction SilentlyContinue
            Write-DebugMsg "  Removed file: $item"
        }
        elseif (Test-Path -LiteralPath $item -PathType Container) {
            Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue
            Write-DebugMsg "  Removed directory: $item"
        }
    }
    Write-Warn "Rollback complete. Run the installer again to retry."
}

# Register a cleanup handler via the PowerShell engine
$Script:CleanupHandler = {
    Invoke-Rollback
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action $Script:CleanupHandler | Out-Null

# Also use try/finally wrapper in main

# ====================================================================
# Banner
# ====================================================================
function Show-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════╗"
    Write-Host "  ║         clawde installer v$($Script:CLAWDE_VERSION)          ║"
    Write-Host "  ║  Claude Work -> OpenCode bridge       ║"
    Write-Host "  ╚══════════════════════════════════════╝"
    Write-Host ""
}

# ====================================================================
# Architecture detection
# ====================================================================
function Detect-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        "AMD64"     { return "x64" }
        "ARM64"     { return "arm64" }
        default {
            Write-Warn "Unrecognized architecture: $arch — assuming x64 (may cause runtime issues)"
            return "x64"
        }
    }
}

# ====================================================================
# Show version details
# ====================================================================
function Show-Version {
    Write-Info "clawde installer v$($Script:CLAWDE_VERSION)"
    if ($Script:Verbose) {
        $psVer = $PSVersionTable.PSVersion
        $pwsh = if ($env:POWERSHELL_DISTINCTION) { "PowerShell $psVer" } else { "Windows PowerShell $psVer" }
        Write-DebugMsg "  Platform: $pwsh"
        Write-DebugMsg "  Architecture: $(Detect-Arch)"
        Write-DebugMsg "  OS: $([Environment]::OSVersion)"
        try {
            $dotnetVer = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
            Write-DebugMsg "  Runtime: $dotnetVer"
        }
        catch { }
    }
}

# ====================================================================
# Dependency checking
# ====================================================================
function Check-Deps {
    $missing = @()

    # Check for basic web access methods
    if (-not (Get-Command curl -ErrorAction SilentlyContinue) -and
        -not (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) {
        $missing += "curl / Invoke-WebRequest (built into PowerShell)"
    }

    # Check for Python
    $python = Get-Command python -ErrorAction SilentlyContinue
    $python3 = Get-Command python3 -ErrorAction SilentlyContinue
    $Script:PYTHON = if ($python) { "python" } elseif ($python3) { "python3" } else { $null }

    if (-not $Script:PYTHON) {
        $missing += "python — https://www.python.org/downloads/"
    }

    # Check for Python package managers
    $Script:HasUV   = [bool](Get-Command uv -ErrorAction SilentlyContinue)
    $Script:HasPipx = [bool](Get-Command pipx -ErrorAction SilentlyContinue)
    $Script:HasPip  = $false

    if ($Script:PYTHON) {
        # Check if pip is available via python -m pip
        & $Script:PYTHON -m pip --version > $null 2>&1
        if ($LASTEXITCODE -eq 0) { $Script:HasPip = $true }
    }

    if (-not $Script:HasUV -and -not $Script:HasPipx -and -not $Script:HasPip) {
        Write-Warn "No Python package manager found."
        Write-Warn "  Recommended: install uv — https://docs.astral.sh/uv/"
        Write-Warn "  Or: python -m pip install pipx"
    }

    # Check for git (only needed for source builds)
    $Script:HasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

    # Check for Go (only needed for source builds)
    $Script:HasGo = [bool](Get-Command go -ErrorAction SilentlyContinue)

    # Report
    if ($missing.Count -gt 0) {
        Write-Err "Missing required dependencies: $($missing -join ', ')"
    }

    Write-DebugMsg "Dependencies: python=$($Script:PYTHON), uv=$($Script:HasUV), pipx=$($Script:HasPipx), pip=$($Script:HasPip), git=$($Script:HasGit), go=$($Script:HasGo)"
}

# ====================================================================
# Detect existing installation (idempotency)
# ====================================================================
function Check-Existing {
    # Check for OpenCode in PATH (system-wide)
    $pathOpenCode = Get-Command opencode -ErrorAction SilentlyContinue
    if ($pathOpenCode -and $pathOpenCode.Source -ne $Script:OPENCODE_EXE) {
        Write-Warn "OpenCode found in PATH at: $($pathOpenCode.Source)"
        $Script:ExistingOpenCodePath = $pathOpenCode.Source
    }

    $haveOpenCode = Test-Path $Script:OPENCODE_EXE -PathType Leaf
    $haveConfig   = Test-Path $Script:CLAWDE_CONFIG_FILE -PathType Leaf

    if (-not $haveOpenCode -and -not $haveConfig) {
        Write-DebugMsg "No existing clawde installation detected"
        return
    }

    Write-Host ""
    if ($haveOpenCode) {
        $ver = "version unknown"
        try { $ver = & $Script:OPENCODE_EXE version 2>$null } catch { }
        Write-Warn "OpenCode already installed: $($Script:OPENCODE_EXE) ($ver)"
    }
    if ($haveConfig) {
        Write-Warn "Existing config found at $($Script:CLAWDE_CONFIG_FILE)"
    }

    if ($Script:Yes) {
        if ($Script:ExistingOpenCodePath) {
            Write-Info "OpenCode found in PATH at: $($Script:ExistingOpenCodePath) — using existing binary"
            $Script:SkipOpenCode = $true
        }
        else {
            Write-Warn "Non-interactive mode — reinstalling OpenCode and overwriting config"
            if ($haveOpenCode) { Remove-Item -LiteralPath $Script:OPENCODE_EXE -Force -ErrorAction SilentlyContinue }
        }
        return
    }

    Write-Host ""
    Write-Host "  What would you like to do?"
    Write-Host "    1. [R]einstall / update (removes existing installation)"
    Write-Host "    2. [S]kip OpenCode and keep existing config"
    Write-Host "    3. [U]se existing OpenCode from PATH"
    Write-Host "    4. [C]ancel"
    Write-Host ""
    $action = Read-Host "  Select [1]"
    if (-not $action) { $action = "1" }

    switch -Wildcard ($action) {
        "1" { Write-DebugMsg "User chose reinstall" }
        "R*" { Write-DebugMsg "User chose reinstall" }
        ""  { Write-DebugMsg "User chose reinstall" }
        "2" { Write-Info "Keeping existing installation — skipping OpenCode and config"; $Script:SkipOpenCode = $true; $Script:SkipConfig = $true; return }
        "S*" { Write-Info "Keeping existing installation — skipping OpenCode and config"; $Script:SkipOpenCode = $true; $Script:SkipConfig = $true; return }
        "3" {
            if (-not $Script:ExistingOpenCodePath) {
                Write-Warn "No existing OpenCode found in PATH — defaulting to reinstall"
                if ($haveOpenCode) { Remove-Item -LiteralPath $Script:OPENCODE_EXE -Force -ErrorAction SilentlyContinue }
            }
            else {
                Write-Info "Using existing OpenCode from: $($Script:ExistingOpenCodePath)"
                $Script:SkipOpenCode = $true
            }
        }
        "U*" {
            if (-not $Script:ExistingOpenCodePath) {
                Write-Warn "No existing OpenCode found in PATH — defaulting to reinstall"
                if ($haveOpenCode) { Remove-Item -LiteralPath $Script:OPENCODE_EXE -Force -ErrorAction SilentlyContinue }
            }
            else {
                Write-Info "Using existing OpenCode from: $($Script:ExistingOpenCodePath)"
                $Script:SkipOpenCode = $true
            }
        }
        "4" { Write-Info "Installation cancelled by user."; exit 0 }
        "C*" { Write-Info "Installation cancelled by user."; exit 0 }
        default { Write-Warn "Invalid choice '$action', defaulting to reinstall" }
    }

    if ($haveOpenCode) {
        Remove-Item -LiteralPath $Script:OPENCODE_EXE -Force -ErrorAction SilentlyContinue
    }

    if ($haveConfig) {
        Write-Host ""
        $overwrite = Read-Host "  Overwrite existing config? [y/N]"
        if ($overwrite -match "^[Yy]") {
            $Script:SkipConfig = $false
        }
        else {
            $Script:SkipConfig = $true
            Write-Info "Keeping existing config"
        }
    }
}

# ====================================================================
# PATH management (Windows)
# ====================================================================
function Setup-Path {
    New-Item -ItemType Directory -Path $Script:CLAWDE_BIN_DIR -Force | Out-Null
    Register-Rollback $Script:CLAWDE_BIN_DIR

    # If existing OpenCode is already in PATH, skip PATH management
    if ($Script:ExistingOpenCodePath -and (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Write-DebugMsg "Existing OpenCode already in PATH — skipping PATH management for binary dir"
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*$($Script:CLAWDE_BIN_DIR)*") {
        Write-Warn "$($Script:CLAWDE_BIN_DIR) is not in your PATH"

        $newPath = if ($userPath) { "$userPath;$($Script:CLAWDE_BIN_DIR)" } else { $Script:CLAWDE_BIN_DIR }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")

        # Also update current session
        $env:PATH = "$env:PATH;$($Script:CLAWDE_BIN_DIR)"

        Write-OK "Added $($Script:CLAWDE_BIN_DIR) to User PATH"
        Write-Warn "You may need to restart your terminal for the change to take effect"
    }
}

# ====================================================================
# Install OpenCode
# ====================================================================
function Install-OpenCode {
    Write-Info "[1/5] Installing OpenCode binary..."

    if ($Script:SkipOpenCode) {
        Write-Info "OpenCode installation skipped (existing installation preserved)"
        return
    }

    $arch = Detect-Arch
    $latestTag = $null

    # Fetch latest release tag
    Write-Info "Checking GitHub releases for $($Script:OPENCODE_REPO)..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Script:OPENCODE_REPO)/releases/latest" `
            -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $latestTag = $release.tag_name
    }
    catch {
        Write-Warn "Could not fetch latest release: $($_.Exception.Message)"
        Write-Warn "Falling back to source build..."
        Install-OpenCodeFromSource
        return
    }

    if ([string]::IsNullOrEmpty($latestTag)) {
        Write-Warn "No pre-built release found for $($Script:OPENCODE_REPO)"
        Write-Warn "Falling back to source build..."
        Install-OpenCodeFromSource
        return
    }

    # Try downloading the binary
    $binaryName = "opencode-windows-$arch.exe"
    $downloadUrl = "https://github.com/$($Script:OPENCODE_REPO)/releases/download/$latestTag/$binaryName"

    Write-DebugMsg "Download URL: $downloadUrl"

    New-Item -ItemType Directory -Path $Script:CLAWDE_BIN_DIR -Force | Out-Null

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $Script:OPENCODE_EXE -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        Register-Rollback $Script:OPENCODE_EXE
        Write-OK "OpenCode $latestTag installed to $($Script:OPENCODE_EXE)"
    }
    catch {
        Write-Warn "Binary download failed for release $latestTag ($binaryName)"
        Write-Warn "HTTP error: $($_.Exception.Message)"
        if (Test-Path $Script:OPENCODE_EXE) { Remove-Item $Script:OPENCODE_EXE -Force -ErrorAction SilentlyContinue }

        # Try without .exe suffix or with different naming
        $altName = "opencode-windows-$arch"
        $altUrl = "https://github.com/$($Script:OPENCODE_REPO)/releases/download/$latestTag/$altName"
        Write-DebugMsg "Retrying with: $altUrl"
        try {
            Invoke-WebRequest -Uri $altUrl -OutFile $Script:OPENCODE_EXE -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            Register-Rollback $Script:OPENCODE_EXE
            Write-OK "OpenCode $latestTag installed to $($Script:OPENCODE_EXE)"
            return
        }
        catch {
            Write-Warn "Alternative download also failed: $($_.Exception.Message)"
        }

        Write-Warn "Falling back to source build..."
        if (Test-Path $Script:OPENCODE_EXE) { Remove-Item $Script:OPENCODE_EXE -Force -ErrorAction SilentlyContinue }
        Install-OpenCodeFromSource
    }
}

function Install-OpenCodeFromSource {
    if (-not $Script:HasGo) {
        Write-Err "Go is required to build OpenCode from source. Install from https://go.dev/dl/"
    }
    if (-not $Script:HasGit) {
        Write-Err "Git is required to clone the repository. Install from https://git-scm.com/"
    }

    $tmpDir = Join-Path $env:TEMP "clawde-opencode-build-$([System.IO.Path]::GetRandomFileName())"
    Register-Rollback $tmpDir

    Write-DebugMsg "Cloning $($Script:OPENCODE_REPO) (depth 1) into $tmpDir"
    try {
        git clone --depth 1 "https://github.com/$($Script:OPENCODE_REPO).git" $tmpDir 2>&1 | Out-Default
        if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }
    }
    catch {
        if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
        Write-Err "Failed to clone repository: $($_.Exception.Message)"
    }

    try {
        Push-Location $tmpDir
        Write-DebugMsg "Running 'go build -o $($Script:OPENCODE_EXE) .'"
        $buildOutput = go build -o $Script:OPENCODE_EXE . 2>&1
        if ($LASTEXITCODE -ne 0) {
            Pop-Location
            throw "Go build failed with exit code $LASTEXITCODE`n$buildOutput"
        }
        Pop-Location
    }
    catch {
        Pop-Location
        if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
        Write-Err "Build failed: $($_.Exception.Message)"
    }

    # Clean up temp dir from rollback
    if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
    $Script:RollbackItems = $Script:RollbackItems | Where-Object { $_ -ne $tmpDir }

    Register-Rollback $Script:OPENCODE_EXE
    Write-OK "OpenCode built from source and installed to $($Script:OPENCODE_EXE)"
}

# ====================================================================
# Install CCProxy
# ====================================================================
function Install-CCProxy {
    Write-Info "[2/5] Installing CCProxy (Claude Work proxy)..."

    # Prefer uv (fast, isolated)
    if ($Script:HasUV) {
        Write-DebugMsg "Installing $($Script:CCPROXY_PACKAGE)[all] via 'uv tool install'"
        $output = uv tool install "$($Script:CCPROXY_PACKAGE)[all]" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "CCProxy installed via uv"
            return
        }
        Write-Warn "uv installation failed (exit $LASTEXITCODE) — trying pipx..."
        Write-DebugMsg $output
    }

    # Try pipx
    if ($Script:HasPipx) {
        Write-DebugMsg "Installing $($Script:CCPROXY_PACKAGE)[all] via 'pipx install'"
        $output = pipx install "$($Script:CCPROXY_PACKAGE)[all]" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "CCProxy installed via pipx"
            return
        }
        Write-Warn "pipx installation failed (exit $LASTEXITCODE) — trying pip..."
        Write-DebugMsg $output
    }

    # Fallback to pip
    if ($Script:HasPip) {
        Write-DebugMsg "Installing $($Script:CCPROXY_PACKAGE)[all] via 'python -m pip install'"
        $output = & $Script:PYTHON -m pip install --user "$($Script:CCPROXY_PACKAGE)[all]" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "CCProxy installed via pip"
            return
        }
        Write-Err "pip installation failed. Try: $($Script:PYTHON) -m pip install $($Script:CCPROXY_PACKAGE)[all]"
    }

    Write-Err "No Python package manager available.
Install one of the following and re-run:
  - uv:  powershell -c ""irm https://astral.sh/uv/install.ps1 | iex""
  - pipx: $($Script:PYTHON) -m pip install --user pipx"
}

# ====================================================================
# Interactive config wizard
# ====================================================================
function Do-InteractiveConfig {
    Write-Info "[3/5] Claude authentication"

    $authMethod = "oauth"
    $cliTokenPath = ""

    Write-Host ""
    Write-Host "  Choose authentication method:"
    Write-Host "    1. OAuth login (opens browser — recommended)"
    Write-Host "    2. Use existing Claude CLI token"
    Write-Host ""

    $valid = $false
    do {
        $authChoice = Read-Host "  Select [1]"
        if (-not $authChoice) { $authChoice = "1" }
        switch ($authChoice) {
            "1" { $authMethod = "oauth"; $Script:AuthPending = $true; Write-Host ""; Write-Info "You'll complete Claude authentication later. Run 'clawde auth' after install to log in."; $valid = $true }
            "2" { $authMethod = "cli_token"; $valid = $true }
            default { Write-Warn "Please enter 1 (OAuth) or 2 (CLI token)" }
        }
    } while (-not $valid)

    if ($authMethod -eq "cli_token") {
        $defaultToken = Join-Path $env:USERPROFILE ".claude\credentials.json"
        $cliTokenPath = Read-Host "  Path to Claude CLI token [$defaultToken]"
        if (-not $cliTokenPath) { $cliTokenPath = $defaultToken }
        if (Test-Path $cliTokenPath -PathType Leaf) {
            Write-OK "Found credentials file"
        }
        else {
            Write-Warn "File not found: $cliTokenPath (you can set this later with 'clawde auth')"
        }
    }

    Write-Host ""
    Write-Info "[4/5] Configuration"
    Write-Host ""

    # Port validation
    do {
        $port = Read-Host "  Proxy port [8080]"
        if (-not $port) { $port = "8080" }
        $portNum = 0
        if ([int]::TryParse($port, [ref]$portNum) -and $portNum -ge 1024 -and $portNum -le 65535) {
            break
        }
        else {
            Write-Warn "Port must be a number between 1024 and 65535 (got: $port)"
        }
    } while ($true)

    $autoStartInput = Read-Host "  Auto-start on boot? [y/N]"
    if (-not $autoStartInput) { $autoStartInput = "N" }
    $autoStart = if ($autoStartInput -match "^[Yy]") { "true" } else { "false" }

    $models = Read-Host "  Models to expose [all]"
    if (-not $models) { $models = "all" }

    Write-Config $authMethod $cliTokenPath $port $autoStart $models
}

# ====================================================================
# Write config file
# ====================================================================
function Write-Config {
    param(
        [string]$AuthMethod,
        [string]$CliTokenPath,
        [string]$Port,
        [string]$AutoStart,
        [string]$Models
    )

    if ($Script:SkipConfig) {
        Write-Info "Config step skipped (existing config preserved)"
        return
    }

    New-Item -ItemType Directory -Path $Script:CLAWDE_CONFIG_DIR -Force | Out-Null
    Register-Rollback $Script:CLAWDE_CONFIG_DIR

    $tokenLine = ""
    if (-not [string]::IsNullOrEmpty($CliTokenPath)) {
        $tokenLine = "cli_token_path = `"${CliTokenPath}`""
    }

    $configContent = @"
# clawde configuration — generated by installer v$($Script:CLAWDE_VERSION)
# Docs: https://github.com/ClintonSarkar/clawde

[proxy]
port = $Port
host = "127.0.0.1"

[claude]
auth_method = "${AuthMethod}"
${tokenLine}

[opencode]
provider_name = "clawde"
auto_start = ${AutoStart}

[models]
expose = "${Models}"

[logging]
level = "info"
rotation_days = 7
"@

    Set-Content -Path $Script:CLAWDE_CONFIG_FILE -Value $configContent -Encoding UTF8
    Write-OK "Config written to $($Script:CLAWDE_CONFIG_FILE)"
}

# ====================================================================
# Write config from env vars (non-interactive mode)
# ====================================================================
function Write-ConfigFromEnv {
    $authMethod = if ($env:CLAWDE_AUTH_METHOD) { $env:CLAWDE_AUTH_METHOD } else { "oauth" }
    $cliTokenPath = $env:CLAWDE_CLI_TOKEN_PATH
    $port = if ($env:CLAWDE_PORT) { $env:CLAWDE_PORT } else { "8080" }
    $autoStart = if ($env:CLAWDE_AUTO_START) { $env:CLAWDE_AUTO_START } else { "false" }
    $models = if ($env:CLAWDE_MODELS) { $env:CLAWDE_MODELS } else { "all" }

    # Validate port
    $portNum = 0
    if (-not [int]::TryParse($port, [ref]$portNum) -or $portNum -lt 1024 -or $portNum -gt 65535) {
        Write-Warn "CLAWDE_PORT=$port is invalid; must be 1024-65535. Defaulting to 8080."
        $port = "8080"
    }

    # Validate auth method
    if ($authMethod -ne "oauth" -and $authMethod -ne "cli_token") {
        Write-Warn "CLAWDE_AUTH_METHOD=$authMethod is invalid. Defaulting to 'oauth'."
        $authMethod = "oauth"
    }

    # Validate auto_start
    if ($autoStart -ne "true" -and $autoStart -ne "false") {
        Write-Warn "CLAWDE_AUTO_START=$autoStart is invalid. Defaulting to 'false'."
        $autoStart = "false"
    }

    if ($authMethod -eq "oauth") {
        $Script:AuthPending = $true
    }
    Write-Config $authMethod $cliTokenPath $port $autoStart $models
}

# ====================================================================
# Service setup (Windows Scheduled Task)
# ====================================================================
function Setup-Service {
    Write-Info "[5/5] Setting up service management..."

    $autoStart = $false

    if (Test-Path $Script:CLAWDE_CONFIG_FILE -PathType Leaf) {
        $configText = Get-Content $Script:CLAWDE_CONFIG_FILE -Raw
        $autoStart = $configText -match 'auto_start\s*=\s*true'
    }
    elseif ($Script:Yes) {
        $autoStart = ($env:CLAWDE_AUTO_START -eq "true")
    }

    if (-not $autoStart) {
        Write-OK "Auto-start disabled — use 'clawde start' to launch manually"
        return
    }

    # Configure scheduled task for auto-start on login
    Write-Info "Configuring scheduled task: $($Script:TASK_NAME)"

    # Look for ccproxy in PATH
    $ccproxyPath = (Get-Command ccproxy -ErrorAction SilentlyContinue).Source
    if (-not $ccproxyPath) {
        Write-Warn "ccproxy not found in PATH — trying common locations..."
        $candidates = @(
            Join-Path $env:LOCALAPPDATA "pipx\venvs\ccproxy-api\Scripts\ccproxy.exe"
            Join-Path $env:LOCALAPPDATA "clawde\bin\ccproxy.exe"
            Join-Path $env:USERPROFILE ".local\bin\ccproxy.exe"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $ccproxyPath = $c; break }
        }
    }

    if (-not $ccproxyPath) {
        Write-Warn "Could not locate ccproxy executable for scheduled task."
        Write-Warn "The scheduled task will assume ccproxy is in PATH."
        $ccproxyPath = "ccproxy"
    }

    # Read port from config file
    $taskPort = "8080"
    if (Test-Path $Script:CLAWDE_CONFIG_FILE -PathType Leaf) {
        $configText = Get-Content $Script:CLAWDE_CONFIG_FILE -Raw
        $proxyMatch = [regex]::Match($configText, '\[proxy\][^\[]*port\s*=\s*(\d+)')
        if ($proxyMatch.Success) {
            $taskPort = $proxyMatch.Groups[1].Value
        }
    }

    $taskAction = New-ScheduledTaskAction -Execute $ccproxyPath -Argument "serve --port $taskPort"
    $taskTrigger = New-ScheduledTaskTrigger -AtLogon
    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    try {
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $Script:TASK_NAME `
            -Action $taskAction `
            -Trigger $taskTrigger `
            -Settings $taskSettings `
            -Principal $principal `
            -Force -ErrorAction Stop | Out-Null
        Write-OK "Scheduled task '$($Script:TASK_NAME)' installed (auto-start on login)"
    }
    catch {
        Write-Err "Failed to register scheduled task: $($_.Exception.Message)

Try running PowerShell as Administrator, or set up auto-start manually:
  1. Open Task Scheduler
  2. Create task that runs: $ccproxyPath serve --port 8080
  3. Trigger: At logon"
    }
}

# ====================================================================
# Final message
# ====================================================================
function Final-Message {
    Write-Host ""
    Write-OK "clawde v$($Script:CLAWDE_VERSION) is installed and ready!"
    Write-Host ""
    Write-Host "  Quick start:"
    Write-Host "    clawde start     — launch proxy + OpenCode"
    Write-Host "    clawde stop      — stop all services"
    Write-Host "    clawde status    — check health"
    Write-Host ""
    Write-Host "  Management:"
    Write-Host "    clawde config    — reconfigure"
    Write-Host "    clawde auth      — re-authenticate Claude"
    Write-Host "    clawde update    — update to latest version"
    Write-Host "    clawde logs      — tail logs"
    Write-Host ""
    if ($Script:AuthPending) {
        Write-Host ""
        Write-Host "  Note: Claude authentication not yet completed. Run 'clawde auth' to connect your Claude account."
        Write-Host ""
    }

    Write-Host "  Resources:"
    Write-Host "    Config: $($Script:CLAWDE_CONFIG_FILE)"
    Write-Host "    Logs:   $(Join-Path $Script:CLAWDE_DATA_DIR 'logs\')"
    Write-Host "    Docs:   https://github.com/ClintonSarkar/clawde"
    Write-Host ""
}

# ====================================================================
# Uninstall
# ====================================================================
function Uninstall-Clawde {
    Show-Banner
    Write-Info "Uninstalling clawde..."
    Write-Host ""

    $removedAnything = $false

    # --- Remove OpenCode binary ---
    if (Test-Path $Script:OPENCODE_EXE -PathType Leaf) {
        Remove-Item -LiteralPath $Script:OPENCODE_EXE -Force -ErrorAction SilentlyContinue
        Write-OK "Removed OpenCode binary: $($Script:OPENCODE_EXE)"
        $removedAnything = $true
    }

    # --- Remove config directory ---
    if (Test-Path $Script:CLAWDE_CONFIG_DIR -PathType Container) {
        Remove-Item -LiteralPath $Script:CLAWDE_CONFIG_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "Removed config directory: $($Script:CLAWDE_CONFIG_DIR)"
        $removedAnything = $true
    }

    # --- Remove data directory ---
    if (Test-Path $Script:CLAWDE_DATA_DIR -PathType Container) {
        Remove-Item -LiteralPath $Script:CLAWDE_DATA_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "Removed data directory: $($Script:CLAWDE_DATA_DIR)"
        $removedAnything = $true
    }

    # --- Clean up PATH (User) ---
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -like "*$($Script:CLAWDE_BIN_DIR)*") {
        $newPath = ($userPath -split ';' | Where-Object { $_ -ne $Script:CLAWDE_BIN_DIR }) -join ';'
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        # Also clean current session
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -ne $Script:CLAWDE_BIN_DIR }) -join ';'
        Write-OK "Removed $($Script:CLAWDE_BIN_DIR) from User PATH"
        $removedAnything = $true
    }

    # --- Remove scheduled task ---
    try {
        $existing = Get-ScheduledTask -TaskName $Script:TASK_NAME -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $Script:TASK_NAME -Confirm:$false -ErrorAction Stop
            Write-OK "Removed scheduled task: $($Script:TASK_NAME)"
            $removedAnything = $true
        }
    }
    catch {
        Write-Warn "Could not remove scheduled task: $($_.Exception.Message)"
        Write-Warn "  You can remove it manually: Unregister-ScheduledTask -TaskName '$($Script:TASK_NAME)' -Confirm:`$false"
    }

    # --- Uninstall CCProxy (best-effort via all known package managers) ---
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $output = uv tool uninstall $Script:CCPROXY_PACKAGE 2>&1
        if ($LASTEXITCODE -eq 0) { Write-OK "Uninstalled CCProxy via uv"; $removedAnything = $true }
    }
    if (Get-Command pipx -ErrorAction SilentlyContinue) {
        $output = pipx uninstall $Script:CCPROXY_PACKAGE 2>&1
        if ($LASTEXITCODE -eq 0) { Write-OK "Uninstalled CCProxy via pipx"; $removedAnything = $true }
    }
    # pip uninstall
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $output = python -m pip uninstall -y $Script:CCPROXY_PACKAGE 2>&1
        if ($LASTEXITCODE -eq 0) { Write-OK "Uninstalled CCProxy via pip"; $removedAnything = $true }
    }

    if (-not $removedAnything) {
        Write-Info "Nothing to uninstall — clawde is not installed."
    }
    else {
        Write-Host ""
        Write-OK "clawde has been completely uninstalled."
    }
}

# ====================================================================
# Main entry point
# ====================================================================
try {
    if ($Help) { Show-Help }

    if ($Uninstall) {
        Uninstall-Clawde
        return
    }

    # Propagate -Verbose from param binding
    if ($PSBoundParameters.ContainsKey('Verbose') -and $Verbose) {
        $Script:Verbose = $true
    }

    Show-Banner
    Show-Version
    Check-Deps
    Setup-Path
    Check-Existing

    Install-OpenCode
    Install-CCProxy

    # Config — interactive or non-interactive
    if ($Script:Yes) {
        if (-not $Script:SkipConfig) {
            Write-ConfigFromEnv
        }
    }
    else {
        Do-InteractiveConfig
    }

    Setup-Service

    # Mark success so engine exit handler won't roll back
    $Script:InstallCompleted = $true
    Clear-Rollback
    Final-Message
}
catch {
    Invoke-Rollback
    Write-Host ""
    Write-Err "Installation failed: $($_.Exception.Message)

If you need help, please open an issue at:
  https://github.com/ClintonSarkar/clawde/issues/new"
}

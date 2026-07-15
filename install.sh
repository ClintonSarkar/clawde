#!/usr/bin/env bash
# clawde installer — Linux / WSL
#   Claude Work → OpenCode bridge
#
# Usage:
#   curl -fsSL https://clawde.dev/install.sh | bash
#   curl -fsSL https://clawde.dev/install.sh | bash -s -- --yes
#   curl -fsSL https://clawde.dev/install.sh | bash -s -- --uninstall
#
# Environment variables (for CI / automation):
#   CLAWDE_PORT          Proxy port (default: 8080)
#   CLAWDE_AUTH_METHOD   Auth method: oauth | cli_token (default: oauth)
#   CLAWDE_CLI_TOKEN_PATH  Path to Claude CLI credentials (default: ~/.claude/credentials.json)
#   CLAWDE_AUTO_START    Auto-start on boot: true | false (default: false)
#   CLAWDE_MODELS        Models to expose (default: all)
set -euo pipefail

# ====================================================================
# Constants
# ====================================================================
CLAWDE_VERSION="0.1.0"
OPENCODE_REPO="ClintonSarkar/opencode"
CCPROXY_PACKAGE="ccproxy-api"

CLAWDE_CONFIG_DIR="${HOME}/.config/clawde"
CLAWDE_DATA_DIR="${HOME}/.local/share/clawde"
CLAWDE_BIN_DIR="${HOME}/.local/bin"
OPENCODE_BIN="${CLAWDE_BIN_DIR}/opencode"
CLAWDE_CONFIG_FILE="${CLAWDE_CONFIG_DIR}/clawde.toml"
SYSTEMD_SERVICE_NAME="clawde-proxy"
SYSTEMD_SERVICE_FILE="${HOME}/.config/systemd/user/${SYSTEMD_SERVICE_NAME}.service"

# ====================================================================
# Flags & State
# ====================================================================
VERBOSE=false
NONINTERACTIVE=false
UNINSTALL=false
INSTALL_COMPLETED=false
ROLLBACK_ITEMS=()
IS_WSL=false
OS=""
ARCH=""
SKIP_OPENCODE=false
SKIP_CONFIG=false
EXISTING_OPENCODE_PATH=""
AUTH_PENDING=false

# ====================================================================
# Colors & Logging
# ====================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "[DEBUG] $*"; }

# ====================================================================
# Banner
# ====================================================================
banner() {
  echo ""
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║         clawde installer v${CLAWDE_VERSION}        ║"
  echo "  ║  Claude Work → OpenCode bridge       ║"
  echo "  ╚══════════════════════════════════════╝"
  echo ""
}

# ====================================================================
# Usage
# ====================================================================
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Install clawde — the Claude Work to OpenCode bridge.

Options:
  -y, --yes         Non-interactive mode; accept all defaults
  -v, --verbose     Show detailed debug output
  -u, --uninstall   Remove clawde and all its components cleanly
  -h, --help        Show this help message and exit

Environment variables (overrides for --yes / CI mode):
  CLAWDE_PORT         Proxy port number (1024-65535, default: 8080)
  CLAWDE_AUTH_METHOD  Authentication: oauth | cli_token (default: oauth)
  CLAWDE_CLI_TOKEN_PATH  Path to Claude CLI token file
  CLAWDE_AUTO_START   Auto-start on boot: true | false (default: false)
  CLAWDE_MODELS       Comma-separated model list or "all" (default: all)

Examples:
  $0                           Interactive installation
  $0 --yes                     Install with default settings
  CLAWDE_PORT=9090 $0 --yes    Install with custom port
  $0 --uninstall               Remove clawde completely
  $0 --verbose                 Install with debug output
EOF
  exit 0
}

# ====================================================================
# Argument parsing
# ====================================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)      NONINTERACTIVE=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -u|--uninstall) UNINSTALL=true; shift ;;
      -h|--help)     usage ;;
      *) error "Unknown option: $1. Use --help for usage information." ;;
    esac
  done
}

# ====================================================================
# Rollback / Cleanup trap
# ====================================================================
cleanup_on_exit() {
  local exit_code=$?
  if [[ "$INSTALL_COMPLETED" == "true" ]]; then
    return 0
  fi
  if [[ "$UNINSTALL" == "true" ]]; then
    return 0
  fi
  if [[ ${#ROLLBACK_ITEMS[@]} -eq 0 ]]; then
    return 0
  fi
  if [[ $exit_code -eq 0 ]]; then
    return 0
  fi
  echo ""
  warn "Installation did not complete (exit code $exit_code) — rolling back..."
  for item in "${ROLLBACK_ITEMS[@]}"; do
    if [[ -f "$item" ]]; then
      rm -f "$item" 2>/dev/null || true
      debug "  Removed file: $item"
    elif [[ -d "$item" ]]; then
      # Only remove empty dirs we created, unless it's our config/data
      if [[ "$item" == "$CLAWDE_CONFIG_DIR" ]] || [[ "$item" == "$CLAWDE_DATA_DIR" ]] || [[ "$item" == "$CLAWDE_BIN_DIR" ]]; then
        rm -rf "$item" 2>/dev/null || true
        debug "  Removed directory: $item"
      else
        rmdir "$item" 2>/dev/null || true
        debug "  Removed (empty) directory: $item"
      fi
    fi
  done
  warn "Rollback complete. Run the installer again to retry."
}

trap cleanup_on_exit EXIT

register_rollback() {
  ROLLBACK_ITEMS+=("$1")
  debug "Registered rollback: $1"
}

clear_rollback() {
  ROLLBACK_ITEMS=()
}

# ====================================================================
# OS / Architecture detection
# ====================================================================
detect_os() {
  local os arch os_name
  os="$(uname -s)"
  case "$os" in
    Linux*)  OS="linux";;
    Darwin*) OS="macos";;
    *)       error "Unsupported operating system: $os. clawde requires Linux, macOS, or WSL.";;
  esac

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)   ARCH="x64";;
    aarch64|arm64)  ARCH="arm64";;
    *)
      warn "Unrecognized architecture: $arch — assuming x64 (may cause runtime issues)"
      ARCH="x64"
      ;;
  esac

  os_name="$(uname -o 2>/dev/null || echo "$OS")"
  info "Detected: $os_name on $arch ($ARCH)"
}

# ====================================================================
# WSL detection
# ====================================================================
check_wsl() {
  if [[ -f /proc/version ]] && grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
    IS_WSL=true
    local wsl_ver
    wsl_ver="$(wsl.exe --version 2>/dev/null | head -1 || echo "WSL (version unknown)")"
    info "Running under $wsl_ver"
  else
    IS_WSL=false
  fi
}

# ====================================================================
# Dependency checking
# ====================================================================
check_deps() {
  local missing=() optional=()
  local has_uv=false has_pipx=false has_pip=false has_python=false

  # --- Required ---
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v bash >/dev/null 2>&1 || missing+=("bash")

  # Python
  if command -v python3 >/dev/null 2>&1; then
    has_python=true
    PYTHON=python3
  elif command -v python >/dev/null 2>&1; then
    # On some distros python3 doesn't exist but python does
    local pyver
    pyver="$(python --version 2>&1 | grep -oP '\d+\.\d+')"
    if [[ "${pyver%%.*}" -ge 3 ]]; then
      has_python=true
      PYTHON=python
    else
      missing+=("python3 (got python 2)")
    fi
  else
    missing+=("python3")
  fi

  # Python package managers (at least one needed)
  command -v uv >/dev/null 2>&1 && has_uv=true
  command -v pipx >/dev/null 2>&1 && has_pipx=true
  if command -v pip3 >/dev/null 2>&1; then
    has_pip=true; PIP=pip3
  elif command -v pip >/dev/null 2>&1; then
    has_pip=true; PIP=pip
  fi

  if ! $has_uv && ! $has_pipx && ! $has_pip; then
    optional+=("uv (recommended) — https://docs.astral.sh/uv/")
    optional+=("or pipx — https://pipx.pypa.io/")
  fi

  # git (only needed for source builds)
  command -v git >/dev/null 2>&1 || optional+=("git — https://git-scm.com/ (for source builds)")

  # --- Report ---
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    error "Missing required dependencies: ${missing[*]}

Install them with your package manager:
  sudo apt install ${missing[*]}            # Debian/Ubuntu
  sudo dnf install ${missing[*]}            # Fedora
  sudo pacman -S ${missing[*]}              # Arch Linux
  brew install ${missing[*]}                # macOS Homebrew"
  fi

  if [[ ${#optional[@]} -gt 0 ]]; then
    echo ""
    warn "Optional dependencies not found:"
    for dep in "${optional[@]}"; do
      echo "    - $dep"
    done
    warn "The installer will attempt to install what it needs."
    echo ""
  fi

  debug "Dependency check: curl=$(command -v curl), python=${PYTHON:-none}, uv=$has_uv, pipx=$has_pipx, pip=$has_pip, git=$(command -v git >/dev/null 2>&1 && echo yes || echo no)"
}

# ====================================================================
# Version display
# ====================================================================
show_version() {
  info "clawde installer v${CLAWDE_VERSION}"
  if [[ "$VERBOSE" == "true" ]]; then
    debug "  Python:  $($PYTHON --version 2>/dev/null || echo 'not found')"
    command -v uv >/dev/null 2>&1 && debug "  uv:      $(uv --version 2>/dev/null || echo 'unknown')"
    command -v pipx >/dev/null 2>&1 && debug "  pipx:    $(pipx --version 2>/dev/null || echo 'unknown')"
    debug "  Shell:   $SHELL"
    debug "  WSL:     $IS_WSL"
    debug "  OS/Arch: $OS/$ARCH"
  fi
}

# ====================================================================
# Idempotency — detect existing installation
# ====================================================================
check_existing() {
  local have_opencode=false
  local have_config=false

  # Check for OpenCode in PATH (system-wide)
  local path_opencode=""
  path_opencode="$(command -v opencode 2>/dev/null || true)"
  if [[ -n "$path_opencode" ]] && [[ "$path_opencode" != "$OPENCODE_BIN" ]]; then
    warn "OpenCode found in PATH at: ${path_opencode}"
    EXISTING_OPENCODE_PATH="$path_opencode"
  fi

  if [[ -x "$OPENCODE_BIN" ]]; then
    have_opencode=true
  fi

  if [[ -f "$CLAWDE_CONFIG_FILE" ]]; then
    have_config=true
  fi

  if ! $have_opencode && ! $have_config; then
    if [[ -n "${EXISTING_OPENCODE_PATH:-}" ]]; then
      echo ""
      echo "  What would you like to do?"
      echo "    1. [I]nstall new OpenCode binary (clawde's own copy)"
      echo "    2. [U]se existing OpenCode from PATH"
      echo "    3. [C]ancel"
      echo ""
      read -rp "  Select (default: 2): " action
      action="${action:-2}"
      case "$action" in
        [Ii]|1)
          debug "User chose install new binary"
          ;;
        [Uu]|2)
          info "Using existing OpenCode from: ${EXISTING_OPENCODE_PATH}"
          SKIP_OPENCODE=true
          return 0
          ;;
        [Cc]|3)
          info "Installation cancelled by user."
          exit 0
          ;;
        *)
          warn "Invalid choice '$action', defaulting to use existing"
          info "Using existing OpenCode from: ${EXISTING_OPENCODE_PATH}"
          SKIP_OPENCODE=true
          return 0
          ;;
      esac
    fi
    debug "No existing clawde installation detected"
    return 0
  fi

  echo ""
  if $have_opencode; then
    local ver
    ver="$("$OPENCODE_BIN" version 2>/dev/null || echo "version unknown")"
    warn "OpenCode is already installed: ${OPENCODE_BIN} (${ver})"
  fi
  if $have_config; then
    warn "Existing config found at ${CLAWDE_CONFIG_FILE}"
  fi

  if [[ "$NONINTERACTIVE" == "true" ]]; then
    if [[ -n "${EXISTING_OPENCODE_PATH:-}" ]]; then
      info "OpenCode found in PATH at: ${EXISTING_OPENCODE_PATH} — using existing binary"
      SKIP_OPENCODE=true
    else
      warn "Non-interactive mode — reinstalling OpenCode and overwriting config"
      rm -f "$OPENCODE_BIN" 2>/dev/null || true
    fi
    return 0
  fi

  echo ""
  echo "  What would you like to do?"
  echo "    1. [R]einstall / update (removes existing installation)"
  echo "    2. [S]kip OpenCode and keep existing config"
  echo "    3. [U]se existing OpenCode from PATH"
  echo "    4. [C]ancel"
  echo ""
  read -rp "  Select (default: 1): " action
  action="${action:-1}"

  case "$action" in
    [Rr]|1|"")
      debug "User chose reinstall"
      rm -f "$OPENCODE_BIN" 2>/dev/null || true
      ;;
    [Ss]|2)
      info "Keeping existing installation — skipping OpenCode and config"
      SKIP_OPENCODE=true
      SKIP_CONFIG=true
      return 0
      ;;
    [Uu]|3)
      if [[ -z "${EXISTING_OPENCODE_PATH:-}" ]]; then
        warn "No existing OpenCode found in PATH — defaulting to reinstall"
        rm -f "$OPENCODE_BIN" 2>/dev/null || true
      else
        info "Using existing OpenCode from: ${EXISTING_OPENCODE_PATH}"
        SKIP_OPENCODE=true
        # Do NOT set SKIP_CONFIG — still run config wizard
      fi
      ;;
    [Cc]|4)
      info "Installation cancelled by user."
      exit 0
      ;;
    *)
      warn "Invalid choice '$action', defaulting to reinstall"
      rm -f "$OPENCODE_BIN" 2>/dev/null || true
      ;;
  esac

  if $have_config; then
    echo ""
    printf "  Overwrite existing config? [y/N]: "
    read -r overwrite
    case "${overwrite:-N}" in
      [Yy]*) SKIP_CONFIG=false ;;
      *)     SKIP_CONFIG=true; info "Keeping existing config" ;;
    esac
  fi
}

# ====================================================================
# PATH management
# ====================================================================
setup_path() {
  mkdir -p "$CLAWDE_BIN_DIR"
  register_rollback "$CLAWDE_BIN_DIR"

  # If existing OpenCode is already in PATH, skip PATH management
  if [[ -n "${EXISTING_OPENCODE_PATH:-}" ]] && command -v opencode >/dev/null 2>&1; then
    debug "Existing OpenCode already in PATH — skipping PATH management for binary dir"
    return 0
  fi

  if [[ ":$PATH:" != *":${CLAWDE_BIN_DIR}:"* ]]; then
    warn "${CLAWDE_BIN_DIR} is not in your PATH"

    local rc_files=()
    [[ -f "${HOME}/.bashrc" ]]        && rc_files+=("${HOME}/.bashrc")
    [[ -f "${HOME}/.bash_profile" ]]  && rc_files+=("${HOME}/.bash_profile")
    [[ -f "${HOME}/.zshrc" ]]         && rc_files+=("${HOME}/.zshrc")
    [[ -f "${HOME}/.config/fish/config.fish" ]] && rc_files+=("${HOME}/.config/fish/config.fish")

    local path_line="export PATH=\"${CLAWDE_BIN_DIR}:\$PATH\""
    local found_rc=false

    if [[ ${#rc_files[@]} -gt 0 ]]; then
      for rc in "${rc_files[@]}"; do
        if grep -qsF "$CLAWDE_BIN_DIR" "$rc" 2>/dev/null; then
          found_rc=true
          continue
        fi
        {
          echo ""
          echo "# Added by clawde installer v${CLAWDE_VERSION}"
          echo "${path_line}"
        } >> "$rc"
        ok "Added ${CLAWDE_BIN_DIR} to PATH in ${rc}"
        found_rc=true
      done

      if $found_rc; then
        echo ""
        warn "To use clawde immediately: source ${rc_files[0]}"
      fi
    fi

    if ! $found_rc; then
      echo ""
      warn "No shell rc file found. Add this to your shell profile:"
      echo "  ${path_line}"
    fi

    # Export for current process
    export PATH="${CLAWDE_BIN_DIR}:$PATH"
  fi
}

# ====================================================================
# Install OpenCode (binary from GitHub releases)
# ====================================================================
install_opencode() {
  info "[1/6] Installing OpenCode binary..."

  if [[ "${SKIP_OPENCODE:-false}" == "true" ]]; then
    info "OpenCode installation skipped (existing installation preserved)"
    return 0
  fi

  local latest_tag download_url
  latest_tag=""
  download_url=""

  # Fetch latest release tag
  info "Checking GitHub releases for ${OPENCODE_REPO}..."
  latest_tag="$(curl -fsSL --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/${OPENCODE_REPO}/releases/latest" \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)" || true

  if [[ -z "$latest_tag" ]]; then
    warn "Could not find a pre-built release for ${OPENCODE_REPO}"
    warn "Falling back to source build..."
    install_opencode_from_source
    return
  fi

  # Build asset name: try OS-ARCH first, then platform-specific names
  local binary_name="opencode-${OS}-${ARCH}"
  download_url="https://github.com/${OPENCODE_REPO}/releases/download/${latest_tag}/${binary_name}"

  debug "Attempting download: ${download_url}"

  mkdir -p "$CLAWDE_BIN_DIR"

  if curl -fsSL --connect-timeout 10 --max-time 60 "$download_url" -o "$OPENCODE_BIN" 2>/dev/null; then
    chmod +x "$OPENCODE_BIN"
    register_rollback "$OPENCODE_BIN"
    ok "OpenCode ${latest_tag} installed to ${OPENCODE_BIN}"
    return
  fi

  # If first attempt failed, try with 'v' prefix or alternate naming
  rm -f "$OPENCODE_BIN" 2>/dev/null || true

  # Try alternative naming conventions (some releases use 'linux' or omit OS)
  local alt_names=()
  alt_names+=("opencode-linux-${ARCH}")
  alt_names+=("opencode-${ARCH}")

  for alt_name in "${alt_names[@]}"; do
    download_url="https://github.com/${OPENCODE_REPO}/releases/download/${latest_tag}/${alt_name}"
    debug "Retrying with: ${download_url}"
    if curl -fsSL --connect-timeout 10 --max-time 60 "$download_url" -o "$OPENCODE_BIN" 2>/dev/null; then
      chmod +x "$OPENCODE_BIN"
      register_rollback "$OPENCODE_BIN"
      ok "OpenCode ${latest_tag} installed to ${OPENCODE_BIN}"
      return
    fi
    rm -f "$OPENCODE_BIN" 2>/dev/null || true
  done

  warn "Binary download failed for release ${latest_tag}"
  warn "Falling back to source build..."
  rm -f "$OPENCODE_BIN" 2>/dev/null || true
  install_opencode_from_source
}

install_opencode_from_source() {
  command -v go >/dev/null 2>&1 || error "Go is required to build OpenCode from source. Install from https://go.dev/dl/"
  command -v git >/dev/null 2>&1 || error "Git is required to clone the OpenCode repository"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  register_rollback "$tmp_dir"

  debug "Cloning ${OPENCODE_REPO} (depth 1) into ${tmp_dir}"
  if ! git clone --depth 1 "https://github.com/${OPENCODE_REPO}.git" "$tmp_dir" 2>&1; then
    rm -rf "$tmp_dir"
    error "Failed to clone repository. Check your internet connection and git configuration."
  fi

  pushd "$tmp_dir" >/dev/null
  debug "Running 'go build -o ${OPENCODE_BIN} .'"
  if ! go build -o "$OPENCODE_BIN" . 2>&1; then
    popd >/dev/null
    rm -rf "$tmp_dir"
    error "Go build failed. You may need a newer Go version. See errors above."
  fi
  popd >/dev/null

  # Remove tmp_dir from rollback since we already cleaned it
  rm -rf "$tmp_dir"
  # Remove from rollback array
  local filtered=()
  for item in "${ROLLBACK_ITEMS[@]}"; do
    [[ "$item" != "$tmp_dir" ]] && filtered+=("$item")
  done
  ROLLBACK_ITEMS=("${filtered[@]}")

  chmod +x "$OPENCODE_BIN"
  register_rollback "$OPENCODE_BIN"

  ok "OpenCode built from source and installed to ${OPENCODE_BIN}"
}

# ====================================================================
# Install CCProxy (Python package)
# ====================================================================
install_ccproxy() {
  info "[2/6] Installing CCProxy (Claude Work proxy)..."

  # Try uv tool (fast, isolated)
  if command -v uv >/dev/null 2>&1; then
    debug "Installing ${CCPROXY_PACKAGE}[all] via 'uv tool install'"
    if uv tool install "${CCPROXY_PACKAGE}[all]" 2>&1; then
      ok "CCProxy installed via uv"
      return
    fi
    warn "uv installation failed — trying pipx..."
  fi

  # Try pipx
  if command -v pipx >/dev/null 2>&1; then
    debug "Installing ${CCPROXY_PACKAGE}[all] via 'pipx install'"
    if pipx install "${CCPROXY_PACKAGE}[all]" 2>&1; then
      ok "CCProxy installed via pipx"
      return
    fi
    warn "pipx installation failed — trying pip..."
  fi

  # Try pip --user
  if command -v "${PIP:-pip3}" >/dev/null 2>&1; then
    local pip_cmd="${PIP:-pip3}"
    debug "Installing ${CCPROXY_PACKAGE}[all] via '${pip_cmd} install --user'"
    if $pip_cmd install --user "${CCPROXY_PACKAGE}[all]" 2>&1; then
      ok "CCProxy installed via ${pip_cmd}"
      return
    fi
    error "pip installation failed. Try: ${pip_cmd} install ${CCPROXY_PACKAGE}[all]"
  fi

  error "No Python package manager available.
Install one of the following and re-run:
  - uv:  curl -fsSL https://astral.sh/uv/install.sh | bash
  - pipx: python3 -m pip install --user pipx && python3 -m pipx ensurepath"
}

# ====================================================================
# Install clawde CLI wrapper (Bash script - no Python required)
# ====================================================================
install_cli() {
  info "[3/6] Installing clawde CLI..."

  local clawde_url="https://raw.githubusercontent.com/ClintonSarkar/clawde/main/cli/clawde.sh"
  local clawde_path="${CLAWDE_BIN_DIR}/clawde"

  debug "Downloading clawde.sh to ${clawde_path}..."
  if ! curl -fsSL --connect-timeout 10 --max-time 30 \
    "$clawde_url" -o "$clawde_path" 2>/dev/null; then
    warn "Failed to download clawde.sh"
    warn "clawde CLI was not installed. You can install it manually:"
    warn "  curl -fsSL https://raw.githubusercontent.com/ClintonSarkar/clawde/main/cli/clawde.sh -o ${clawde_path} && chmod +x ${clawde_path}"
    return
  fi

  chmod +x "$clawde_path"
  register_rollback "$clawde_path"

  ok "clawde CLI installed to ${clawde_path}"
}

# ====================================================================
# Config wizard — interactive prompts
# ====================================================================
do_interactive_config() {
  local auth_method="" cli_token_path="" port="" auto_start="" models=""
  local auth_choice=""

  info "[4/6] Claude authentication"
  echo ""
  echo "  Choose authentication method:"
  echo "    1. OAuth login (opens browser — recommended)"
  echo "    2. Use existing Claude CLI token"
  echo ""
  while true; do
    read -rp "  Select (default: 1): " auth_choice
    auth_choice="${auth_choice:-1}"
    case "$auth_choice" in
      1) auth_method="oauth"; AUTH_PENDING=true; echo ""; info "You'll complete Claude authentication later. Run 'clawde auth' after install to log in."; break ;;
      2) auth_method="cli_token"; break ;;
      *) warn "Please enter 1 (OAuth) or 2 (CLI token)" ;;
    esac
  done

  if [[ "$auth_method" == "cli_token" ]]; then
    local default_token_path="${HOME}/.claude/credentials.json"
    read -rp "  Path to Claude CLI token [${default_token_path}]: " cli_token_path
    cli_token_path="${cli_token_path:-${default_token_path}}"
    if [[ -f "$cli_token_path" ]]; then
      ok "Found credentials file"
    else
      warn "File not found: ${cli_token_path} (you can set this later with 'clawde auth')"
    fi
  fi

  echo ""
  info "Configuration"
  echo ""

  # Port input with validation
  while true; do
    read -rp "  Proxy port [8080]: " port
    port="${port:-8080}"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )); then
      break
    else
      warn "Port must be a number between 1024 and 65535 (got: ${port})"
    fi
  done

  read -rp "  Auto-start on boot? [y/N]: " auto_start_input
  auto_start_input="${auto_start_input:-N}"
  case "$auto_start_input" in
    [Yy]*) auto_start="true" ;;
    *)     auto_start="false" ;;
  esac

  read -rp "  Models to expose [all]: " models
  models="${models:-all}"

  write_config "$auth_method" "${cli_token_path:-}" "$port" "$auto_start" "$models"
}

# ====================================================================
# Write config file
# ====================================================================
write_config() {
  local auth_method="$1" cli_token_path="$2" port="$3" auto_start="$4" models="$5"

  if [[ "${SKIP_CONFIG:-false}" == "true" ]]; then
    info "Config step skipped (existing config preserved)"
    return 0
  fi

  mkdir -p "$CLAWDE_CONFIG_DIR"
  register_rollback "$CLAWDE_CONFIG_DIR"

  # Only write cli_token_path if it's non-empty
  local token_line=""
  if [[ -n "$cli_token_path" ]]; then
    token_line="cli_token_path = \"${cli_token_path}\""
  fi

  cat > "$CLAWDE_CONFIG_FILE" << EOF
# clawde configuration — generated by installer v${CLAWDE_VERSION}
# Docs: https://github.com/ClintonSarkar/clawde

[proxy]
port = ${port}
host = "127.0.0.1"

[claude]
auth_method = "${auth_method}"
${token_line}

[opencode]
provider_name = "clawde"
auto_start = ${auto_start}

[models]
expose = "${models}"

[logging]
level = "info"
rotation_days = 7
EOF

  ok "Config written to ${CLAWDE_CONFIG_FILE}"
}

# ====================================================================
# Service setup (systemd or WSL shell profile)
# ====================================================================
setup_service() {
  info "[5/6] Setting up service management..."

  # Read auto_start from config
  local auto_start
  auto_start="false"
  if [[ -f "$CLAWDE_CONFIG_FILE" ]]; then
    auto_start="$(grep 'auto_start' "$CLAWDE_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "false")"
  elif [[ "$NONINTERACTIVE" == "true" ]]; then
    auto_start="${CLAWDE_AUTO_START:-false}"
  fi

  if [[ "$auto_start" != "true" ]]; then
    ok "Auto-start disabled — use 'clawde start' to launch manually"
    return 0
  fi

  # --- WSL without systemd ---
  if $IS_WSL && ! command -v systemctl >/dev/null 2>&1; then
    info "WSL without systemd detected — setting up shell-profile auto-start"

    local rc_file=""
    for f in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
      [[ -f "$f" ]] && rc_file="$f" && break
    done

    if [[ -z "$rc_file" ]]; then
      rc_file="${HOME}/.bashrc"
      touch "$rc_file"
    fi

    local port
    port="$(grep -A5 '^\s*\[proxy\]' "$CLAWDE_CONFIG_FILE" 2>/dev/null | grep -E '^\s*port\s*=' | head -1 | cut -d'=' -f2 | tr -d ' ' || echo "8080")"

    if ! grep -qs "clawde" "$rc_file" 2>/dev/null; then
      {
        echo ""
        echo "# Start clawde proxy on shell launch (added by clawde installer v${CLAWDE_VERSION})"
        echo "command -v ccproxy >/dev/null 2>&1 && nohup ccproxy serve --port ${port} >/dev/null 2>&1 &"
      } >> "$rc_file"
      ok "Added clawde auto-start to ${rc_file}"
    else
      warn "Auto-start entry already exists in ${rc_file}"
    fi

    info "Note: proxy will start when you open a terminal. To start manually: ccproxy serve --port ${port}"
    return 0
  fi

  # --- systemd ---
  if command -v systemctl >/dev/null 2>&1; then
    local systemd_dir="${HOME}/.config/systemd/user"
    mkdir -p "$systemd_dir"
    register_rollback "$systemd_dir"

    local port
    port="$(grep -A5 '^\s*\[proxy\]' "$CLAWDE_CONFIG_FILE" 2>/dev/null | grep -E '^\s*port\s*=' | head -1 | cut -d'=' -f2 | tr -d ' ' || echo "8080")"

    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=clawde — CCProxy (Claude Work proxy)
Documentation=https://github.com/ClintonSarkar/clawde
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/ccproxy serve --port ${port}
Restart=on-failure
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

    debug "systemd unit written to ${SYSTEMD_SERVICE_FILE}"

    # Enable lingering so user services start at boot even without login
    loginctl enable-linger "$(whoami)" 2>/dev/null || true

    systemctl --user daemon-reload 2>/dev/null || warn "systemctl daemon-reload failed; check systemd is functional"
    systemctl --user enable "${SYSTEMD_SERVICE_NAME}.service" 2>/dev/null || warn "Could not enable systemd service (is systemd available?)"
    ok "Systemd user service installed and enabled"
    info "  Service: ${SYSTEMD_SERVICE_NAME}.service"
    info "  Start:   systemctl --user start ${SYSTEMD_SERVICE_NAME}.service"
    return 0
  fi

  warn "No service manager detected — you'll need to start clawde manually"
}

# ====================================================================
# Final message
# ====================================================================
final_message() {
  echo ""
  ok "clawde v${CLAWDE_VERSION} is installed and ready!"
  echo ""
  echo "  ${BOLD}Quick start:${NC}"
  echo "    clawde start     — launch proxy + OpenCode"
  echo "    clawde stop      — stop all services"
  echo "    clawde status    — check health"
  echo ""
  echo "  ${BOLD}Management:${NC}"
  echo "    clawde config    — reconfigure"
  echo "    clawde auth      — re-authenticate Claude"
  echo "    clawde update    — update to latest version"
  echo "    clawde logs      — tail logs"
  echo ""
  if [[ "${AUTH_PENDING:-false}" == "true" ]]; then
    echo "  ${BOLD}Note:${NC} Claude authentication not yet completed. Run 'clawde auth' to connect your Claude account."
    echo ""
  fi

  echo "  ${BOLD}Resources:${NC}"
  echo "    Config: ${CLAWDE_CONFIG_FILE}"
  echo "    Logs:   ${CLAWDE_DATA_DIR}/logs/"
  echo "    Docs:   https://github.com/ClintonSarkar/clawde"
  echo ""
}

# ====================================================================
# Uninstall
# ====================================================================
uninstall() {
  banner
  info "Uninstalling clawde..."
  echo ""

  local removed_anything=false

  # --- Remove OpenCode binary ---
  if [[ -f "$OPENCODE_BIN" ]]; then
    rm -f "$OPENCODE_BIN"
    ok "Removed OpenCode binary: ${OPENCODE_BIN}"
    removed_anything=true
  fi

  # --- Remove config ---
  if [[ -d "$CLAWDE_CONFIG_DIR" ]]; then
    rm -rf "$CLAWDE_CONFIG_DIR"
    ok "Removed config directory: ${CLAWDE_CONFIG_DIR}"
    removed_anything=true
  fi

  # --- Remove data ---
  if [[ -d "$CLAWDE_DATA_DIR" ]]; then
    rm -rf "$CLAWDE_DATA_DIR"
    ok "Removed data directory: ${CLAWDE_DATA_DIR}"
    removed_anything=true
  fi

  # --- Remove systemd service ---
  if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
    systemctl --user disable "${SYSTEMD_SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Removed systemd user service"
    removed_anything=true
  fi

  # --- Clean up shell rc PATH additions ---
  for rc in "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.zshrc" "${HOME}/.config/fish/config.fish"; do
    if [[ -f "$rc" ]]; then
      if grep -qsF "$CLAWDE_BIN_DIR" "$rc" 2>/dev/null; then
        cp "$rc" "${rc}.clawde-backup"
        # Remove the block added by the installer (comment line + path line)
        sed -i "\|# Added by clawde installer|,+1 d" "$rc" 2>/dev/null || true
        # Also remove any remaining reference (defensive)
        sed -i "\|${CLAWDE_BIN_DIR}|d" "$rc" 2>/dev/null || true
        ok "Removed PATH entry from ${rc} (backup saved to ${rc}.clawde-backup)"
        removed_anything=true
      fi
    fi
  done

  # --- Clean up WSL auto-start from shell rc ---
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
    if [[ -f "$rc" ]]; then
      if grep -qs "clawde" "$rc" 2>/dev/null; then
        cp "$rc" "${rc}.clawde-backup"
        sed -i "\|# Start clawde|,+1 d" "$rc" 2>/dev/null || true
        sed -i "\|ccproxy serve|d" "$rc" 2>/dev/null || true
        ok "Removed auto-start entries from ${rc} (backup saved to ${rc}.clawde-backup)"
        removed_anything=true
      fi
    fi
  done

  # --- Uninstall CCProxy (best-effort via all known package managers) ---
  if command -v uv >/dev/null 2>&1; then
    if uv tool uninstall "$CCPROXY_PACKAGE" 2>/dev/null; then
      ok "Uninstalled CCProxy via uv"; removed_anything=true
    fi
  fi
  if command -v pipx >/dev/null 2>&1; then
    if pipx uninstall "$CCPROXY_PACKAGE" 2>/dev/null; then
      ok "Uninstalled CCProxy via pipx"; removed_anything=true
    fi
  fi
  # pip --user uninstall (best-effort, no error shown on failure)
  local pip_cmd=""
  command -v pip3 >/dev/null 2>&1 && pip_cmd="pip3" || command -v pip >/dev/null 2>&1 && pip_cmd="pip" || true
  if [[ -n "$pip_cmd" ]]; then
    if $pip_cmd uninstall -y "$CCPROXY_PACKAGE" 2>/dev/null; then
      ok "Uninstalled CCProxy via ${pip_cmd}"; removed_anything=true
    fi
  fi

  if ! $removed_anything; then
    info "Nothing to uninstall — clawde is not installed."
  else
    echo ""
    ok "clawde has been completely uninstalled."
  fi
}

# ====================================================================
# Validate environment variables (for non-interactive mode)
# ====================================================================
validate_env_vars() {
  # Validate CLAWDE_PORT
  if [[ -n "${CLAWDE_PORT:-}" ]]; then
    if ! [[ "$CLAWDE_PORT" =~ ^[0-9]+$ ]] || (( CLAWDE_PORT < 1024 || CLAWDE_PORT > 65535 )); then
      warn "CLAWDE_PORT=${CLAWDE_PORT} is invalid; must be 1024-65535. Defaulting to 8080."
      CLAWDE_PORT="8080"
    fi
  fi

  # Validate CLAWDE_AUTH_METHOD
  if [[ -n "${CLAWDE_AUTH_METHOD:-}" ]]; then
    if [[ "$CLAWDE_AUTH_METHOD" != "oauth" && "$CLAWDE_AUTH_METHOD" != "cli_token" ]]; then
      warn "CLAWDE_AUTH_METHOD=${CLAWDE_AUTH_METHOD} is invalid. Defaulting to 'oauth'."
      CLAWDE_AUTH_METHOD="oauth"
    fi
  fi

  # Validate CLAWDE_AUTO_START
  if [[ -n "${CLAWDE_AUTO_START:-}" ]]; then
    if [[ "$CLAWDE_AUTO_START" != "true" && "$CLAWDE_AUTO_START" != "false" ]]; then
      warn "CLAWDE_AUTO_START=${CLAWDE_AUTO_START} is invalid. Defaulting to 'false'."
      CLAWDE_AUTO_START="false"
    fi
  fi
}

# ====================================================================
# Main entry point
# ====================================================================
main() {
  parse_args "$@"

  if [[ "$UNINSTALL" == "true" ]]; then
    uninstall
    exit 0
  fi

  banner
  detect_os
  check_wsl
  show_version
  check_deps

  # Installation steps
  setup_path
  check_existing

  install_opencode
  install_ccproxy
  install_cli

  # Config — interactive or non-interactive
  if [[ "$NONINTERACTIVE" == "true" ]]; then
    if [[ "${SKIP_CONFIG:-false}" != "true" ]]; then
      validate_env_vars
      if [[ "${CLAWDE_AUTH_METHOD:-oauth}" == "oauth" ]]; then
        AUTH_PENDING=true
      fi
      write_config \
        "${CLAWDE_AUTH_METHOD:-oauth}" \
        "${CLAWDE_CLI_TOKEN_PATH:-}" \
        "${CLAWDE_PORT:-8080}" \
        "${CLAWDE_AUTO_START:-false}" \
        "${CLAWDE_MODELS:-all}"
    fi
  else
    do_interactive_config
  fi

  setup_service

  # Mark success so the EXIT trap won't roll back
  INSTALL_COMPLETED=true
  clear_rollback
  final_message
}

main "$@"

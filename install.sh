#!/usr/bin/env bash
# clawde installer — Linux / WSL
set -euo pipefail

CLAWDE_VERSION="0.1.0"
CLAWDE_CONFIG_DIR="${HOME}/.config/clawde"
CLAWDE_DATA_DIR="${HOME}/.local/share/clawde"
CLAWDE_BIN_DIR="${HOME}/.local/bin"
OPENCODE_REPO="ClintonSarkar/opencode"
CCPROXY_PACKAGE="ccproxy-api"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

banner() {
  echo ""
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║         clawde installer             ║"
  echo "  ║  Claude Work → OpenCode bridge       ║"
  echo "  ╚══════════════════════════════════════╝"
  echo ""
}

detect_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Linux*)  OS="linux";;
    Darwin*) OS="macos";;
    *)       error "Unsupported OS: $os";;
  esac

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) ARCH="x64";;
    aarch64|arm64) ARCH="arm64";;
    *)             error "Unsupported architecture: $arch";;
  esac

  info "Detected: $OS $ARCH"
}

check_wsl() {
  if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
    IS_WSL=true
    info "Running under WSL"
  else
    IS_WSL=false
  fi
}

check_deps() {
  local missing=()

  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v bash >/dev/null 2>&1 || missing+=("bash")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing dependencies: ${missing[*]}"
  fi
}

install_opencode() {
  info "[1/5] Installing OpenCode binary..."

  # Check if already installed
  if command -v opencode >/dev/null 2>&1; then
    warn "OpenCode already installed at $(command -v opencode) — skipping"
    return
  fi

  # Get latest release tag from fork
  local latest_tag
  latest_tag="$(curl -fsSL "https://api.github.com/repos/${OPENCODE_REPO}/releases/latest" \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)"

  if [[ -z "$latest_tag" ]]; then
    warn "No pre-built release found on ${OPENCODE_REPO} — building from source"
    install_opencode_from_source
    return
  fi

  local download_url="https://github.com/${OPENCODE_REPO}/releases/download/${latest_tag}/opencode-${OS}-${ARCH}"

  mkdir -p "$CLAWDE_BIN_DIR"
  curl -fsSL "$download_url" -o "${CLAWDE_BIN_DIR}/opencode"
  chmod +x "${CLAWDE_BIN_DIR}/opencode"

  # Add to PATH if not already
  case ":$PATH:" in
    *":${CLAWDE_BIN_DIR}:"*) ;;
    *) warn "Add ${CLAWDE_BIN_DIR} to your PATH to use opencode" ;;
  esac

  ok "OpenCode ${latest_tag} installed"
}

install_opencode_from_source() {
  command -v go >/dev/null 2>&1 || error "Go not installed. Install from https://go.dev/dl/"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  git clone "https://github.com/${OPENCODE_REPO}.git" "$tmp_dir"
  (cd "$tmp_dir" && go build -o "${CLAWDE_BIN_DIR}/opencode" .)
  rm -rf "$tmp_dir"
  ok "OpenCode built from source"
}

install_ccproxy() {
  info "[2/5] Installing CCProxy..."

  # Prefer uv (faster, isolated)
  if command -v uv >/dev/null 2>&1; then
    uv tool install "${CCPROXY_PACKAGE}[all]"
  elif command -v pipx >/dev/null 2>&1; then
    pipx install "${CCPROXY_PACKAGE}[all]"
  else
    warn "Neither uv nor pipx found — installing pipx"
    python3 -m pip install --user pipx
    python3 -m pipx ensurepath
    pipx install "${CCPROXY_PACKAGE}[all]"
  fi

  ok "CCProxy installed"
}

interactive_config() {
  info "[3/5] Claude authentication"

  echo ""
  echo "  Choose authentication method:"
  echo "    1. OAuth login (opens browser)"
  echo "    2. Use existing Claude CLI token"
  echo ""
  read -rp "  Select [1]: " auth_choice
  auth_choice="${auth_choice:-1}"

  local auth_method cli_token_path=""

  case "$auth_choice" in
    1) auth_method="oauth" ;;
    2)
      auth_method="cli_token"
      read -rp "  Path to Claude CLI token [~/.claude/credentials.json]: " cli_token_path
      cli_token_path="${cli_token_path:-$HOME/.claude/credentials.json}"
      [[ -f "$cli_token_path" ]] || warn "File not found: $cli_token_path (you can set this later)"
      ;;
    *) auth_method="oauth" ;;
  esac

  info "[4/5] Configuration"

  local port auto_start models
  read -rp "  Proxy port [8080]: " port
  port="${port:-8080}"

  read -rp "  Auto-start on boot? [y/N]: " auto_start_input
  auto_start_input="${auto_start_input:-N}"
  case "$auto_start_input" in
    [Yy]*) auto_start="true" ;;
    *)     auto_start="false" ;;
  esac

  read -rp "  Models to expose [all]: " models
  models="${models:-all}"

  # Write config
  mkdir -p "$CLAWDE_CONFIG_DIR"
  cat > "${CLAWDE_CONFIG_DIR}/clawde.toml" << EOF
[proxy]
port = ${port}
host = "127.0.0.1"

[claude]
auth_method = "${auth_method}"
cli_token_path = "${cli_token_path}"

[opencode]
provider_name = "clawde"
auto_start = ${auto_start}

[models]
expose = "${models}"

[logging]
level = "info"
rotation_days = 7
EOF

  ok "Config written to ${CLAWDE_CONFIG_DIR}/clawde.toml"
}

setup_service() {
  info "[5/5] Setting up service management..."

  local auto_start
  auto_start="$(grep 'auto_start' "${CLAWDE_CONFIG_DIR}/clawde.toml" | cut -d'=' -f2 | tr -d ' ')"
  auto_start="${auto_start:-false}"

  if [[ "$auto_start" == "true" ]]; then
    # systemd user unit
    local systemd_dir="${HOME}/.config/systemd/user"
    mkdir -p "$systemd_dir"

    cat > "${systemd_dir}/clawde-proxy.service" << 'EOF'
[Unit]
Description=clawde — CCProxy (Claude Work proxy)
After=network.target

[Service]
Type=simple
ExecStart=%h/.local/bin/ccproxy serve --port 8080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable clawde-proxy.service
    ok "Systemd service installed (auto-start enabled)"
  else
    ok "Auto-start disabled — use 'clawde start' manually"
  fi
}

final_message() {
  echo ""
  ok "clawde is ready!"
  echo ""
  echo "  Commands:"
  echo "    clawde start     — start proxy + OpenCode"
  echo "    clawde stop      — stop both"
  echo "    clawde status    — check health"
  echo "    clawde config    — reconfigure"
  echo "    clawde auth      — re-authenticate Claude"
  echo "    clawde update    — update to latest"
  echo "    clawde logs      — tail logs"
  echo ""
}

main() {
  banner
  detect_os
  check_wsl
  check_deps
  install_opencode
  install_ccproxy
  interactive_config
  setup_service
  final_message
}

main "$@"

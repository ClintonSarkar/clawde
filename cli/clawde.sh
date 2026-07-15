#!/usr/bin/env bash
# clawde.sh - unified CLI for managing OpenCode + CCProxy (Linux/WSL)
#
# Commands:
#   start    - start CCProxy + OpenCode
#   stop     - stop both services
#   status   - health check both services
#   config   - view or edit configuration
#   auth     - re-authenticate Claude
#   update   - update to latest versions
#   logs     - tail logs from either service

set -euo pipefail

# --- Paths ---
CONFIG_DIR="${HOME}/.config/clawde"
DATA_DIR="${HOME}/.local/share/clawde"
BIN_DIR="${HOME}/.local/bin"
LOG_DIR="${DATA_DIR}/logs"
PID_DIR="${DATA_DIR}/pids"
CONFIG_FILE="${CONFIG_DIR}/clawde.toml"

# --- Ensure dirs exist ---
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$BIN_DIR" "$LOG_DIR" "$PID_DIR"

# --- Helpers ---

read_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config not found at $CONFIG_FILE"
    echo "Run the installer first: curl -fsSL https://raw.githubusercontent.com/ClintonSarkar/clawde/main/install.sh | bash"
    exit 1
  fi
  local section=""
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^([^#]+?)\s*=\s*(.*)$ ]] && [[ -n "$section" ]]; then
      local key="${BASH_REMATCH[1]// /}"
      local val="${BASH_REMATCH[2]//\"/}"
      val="${val//\'/}"
      echo "CLAWDE_CFG_${section}_${key}=\"${val}\""
    fi
  done < "$CONFIG_FILE"
}

get_pid() {
  local name="$1"
  local pid_file="${PID_DIR}/${name}.pid"
  if [[ -f "$pid_file" ]]; then
    cat "$pid_file" 2>/dev/null || true
  fi
}

write_pid() {
  local name="$1" pid="$2"
  echo "$pid" > "${PID_DIR}/${name}.pid"
}

remove_pid() {
  local name="$1"
  local pid_file="${PID_DIR}/${name}.pid"
  [[ -f "$pid_file" ]] && rm -f "$pid_file"
}

is_running() {
  local pid="$1"
  [[ -z "$pid" ]] && return 1
  kill -0 "$pid" 2>/dev/null
}

find_binary() {
  local name="$1"
  local local_path="${BIN_DIR}/${name}"
  if [[ -x "$local_path" ]]; then
    echo "$local_path"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  echo "Error: $name not found - run 'clawde update' or reinstall" >&2
  exit 1
}

get_proxy_port() {
  local port="8080"
  if [[ -n "${CLAWDE_CFG_proxy_port:-}" ]]; then
    port="$CLAWDE_CFG_proxy_port"
  fi
  echo "$port"
}

get_proxy_host() {
  local host="127.0.0.1"
  if [[ -n "${CLAWDE_CFG_proxy_host:-}" ]]; then
    host="$CLAWDE_CFG_proxy_host"
  fi
  echo "$host"
}

# --- Commands ---

cmd_start() {
  local extra_args=("$@")
  eval "$(read_config)"
  local port host
  port="$(get_proxy_port)"
  host="$(get_proxy_host)"

  local proxy_pid
  proxy_pid="$(get_pid proxy)"
  if is_running "$proxy_pid"; then
    echo "[OK] CCProxy already running (PID $proxy_pid)"
  else
    echo "[INFO] Starting CCProxy..."
    local ccproxy_bin
    ccproxy_bin="$(find_binary ccproxy)"
    local log_file="${LOG_DIR}/ccproxy.log"
    nohup "$ccproxy_bin" serve --port "$port" >> "$log_file" 2>&1 &
    local new_pid=$!
    write_pid proxy "$new_pid"

    local healthy=false
    for i in $(seq 1 30); do
      sleep 0.5
      if curl -sf "http://${host}:${port}/health" >/dev/null 2>&1; then
        healthy=true
        break
      fi
    done
    if $healthy; then
      echo "[OK] CCProxy started (PID $new_pid) - healthy"
    else
      echo "[WARN] CCProxy started (PID $new_pid) - health check failed, may still be starting"
    fi
  fi

  local opencode_pid
  opencode_pid="$(get_pid opencode)"
  if is_running "$opencode_pid"; then
    echo "[OK] OpenCode already running (PID $opencode_pid)"
  else
    echo "[INFO] Starting OpenCode..."
    local opencode_bin
    opencode_bin="$(find_binary opencode)"
    export OPENCODE_PROVIDER_CLAWDE_BASE_URL="http://${host}:${port}/v1"
    export OPENCODE_PROVIDER_CLAWDE_API_KEY="***"
    "$opencode_bin" "${extra_args[@]}" &
    local oc_pid=$!
    write_pid opencode "$oc_pid"
    echo "[OK] OpenCode started (PID $oc_pid)"
  fi
}

cmd_stop() {
  for name in opencode proxy; do
    local pid
    pid="$(get_pid $name)"
    if is_running "$pid"; then
      kill "$pid" 2>/dev/null || true
      sleep 2
      if is_running "$pid"; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      echo "[OK] $name stopped (was PID $pid)"
    else
      echo "[OK] $name not running"
    fi
    remove_pid "$name"
  done
}

cmd_status() {
  eval "$(read_config)"
  local port host
  port="$(get_proxy_port)"
  host="$(get_proxy_host)"

  local proxy_pid
  proxy_pid="$(get_pid proxy)"
  if is_running "$proxy_pid"; then
    if curl -sf "http://${host}:${port}/health" >/dev/null 2>&1; then
      echo "[OK]   CCProxy   running (PID $proxy_pid) - healthy"
    else
      echo "[WARN] CCProxy   running (PID $proxy_pid) - not responding"
    fi
  else
    echo "[FAIL] CCProxy   not running"
  fi

  local opencode_pid
  opencode_pid="$(get_pid opencode)"
  if is_running "$opencode_pid"; then
    echo "[OK]   OpenCode  running (PID $opencode_pid)"
  else
    echo "[FAIL] OpenCode  not running"
  fi
}

cmd_config() {
  local edit=false
  [[ "${1:-}" == "--edit" || "${1:-}" == "-e" ]] && edit=true
  if $edit; then
    local editor="${EDITOR:-vi}"
    "$editor" "$CONFIG_FILE"
  else
    echo "Config file: $CONFIG_FILE"
    echo ""
    cat "$CONFIG_FILE"
  fi
}

cmd_auth() {
  echo "[INFO] Starting Claude OAuth flow..."
  echo "  A browser window will open for you to log in."
  echo ""
  local ccproxy_bin
  ccproxy_bin="$(find_binary ccproxy)"
  if "$ccproxy_bin" auth login claude; then
    echo ""
    echo "[OK] Authentication complete"
  else
    echo ""
    echo "[ERROR] Authentication failed"
    exit 1
  fi
}

cmd_update() {
  echo "[INFO] Updating OpenCode..."
  local opencode_bin
  opencode_bin="$(find_binary opencode)"
  if [[ -x "$opencode_bin" ]]; then
    local ver
    ver="$("$opencode_bin" --version 2>/dev/null || echo "unknown")"
    echo "  Current: $ver"
    echo "  Running self-upgrade..."
    "$opencode_bin" upgrade 2>&1 || true
  else
    echo "  [ERROR] opencode not found"
  fi

  echo ""
  echo "[INFO] Updating CCProxy..."
  local ccproxy_bin
  ccproxy_bin="$(find_binary ccproxy 2>/dev/null || true)"
  if [[ -n "$ccproxy_bin" && -x "$ccproxy_bin" ]]; then
    local ver
    ver="$("$ccproxy_bin" --version 2>/dev/null || echo "unknown")"
    echo "  Current: $ver"
    # Check for newer release
    local release_json latest_tag
    release_json="$(curl -fsSL --connect-timeout 10 --max-time 15 "https://api.github.com/repos/caddyglow/ccproxy-api/releases/latest" 2>/dev/null)" || {
      echo "  [ERROR] Could not check for updates"
      echo ""
      echo "[OK] Update complete"
      return
    }
    latest_tag="$(echo "$release_json" | grep "\"tag_name\"" | head -1 | sed -E "s/.*\"([^\"]+)\".*/\1/")"
    echo "  Latest:  $latest_tag"
    # Determine platform asset
    local arch asset_name
    arch="$(uname -m)"
    case "$(uname -s):${arch}" in
      Linux:x86_64)   asset_name="ccproxy-${latest_tag}-x86_64-unknown-linux-gnu.tar.gz" ;;
      Linux:aarch64)  asset_name="ccproxy-${latest_tag}-x86_64-unknown-linux-gnu.tar.gz" ;;
      Darwin:x86_64)  asset_name="ccproxy-${latest_tag}-x86_64-apple-darwin.tar.gz" ;;
      Darwin:arm64|Darwin:aarch64) asset_name="ccproxy-${latest_tag}-aarch64-apple-darwin.tar.gz" ;;
      *) echo "  [ERROR] Unsupported platform"; echo ""; echo "[OK] Update complete"; return ;;
    esac
    local download_url
    download_url="$(echo "$release_json" | grep -o "\"browser_download_url\": *\"[^\"]*${asset_name}[^\"]*\"" | sed -E "s/.*\"([^\"]+)\".*/\1/" | head -1)"
    if [[ -z "$download_url" ]]; then
      echo "  [WARN] No binary found for $latest_tag"
    else
      local tmp_archive="/tmp/ccproxy-update.tar.gz"
      local bin_dir="$(dirname "$ccproxy_bin")"
      if curl -fsSL --connect-timeout 10 --max-time 60 "$download_url" -o "$tmp_archive" 2>/dev/null; then
        tar -xzf "$tmp_archive" -C "$bin_dir" 2>/dev/null
        if [[ ! -x "$ccproxy_bin" ]]; then
          local found="$(find "$bin_dir" -name ccproxy -type f -executable | head -1)"
          if [[ -n "$found" ]]; then mv "$found" "$ccproxy_bin"; chmod +x "$ccproxy_bin"; fi
        fi
        rm -f "$tmp_archive"
        echo "  [OK] CCProxy updated"
      else
        echo "  [ERROR] Download failed"
      fi
    fi
  else
    echo "  [ERROR] ccproxy not found - run installer first"
  fi

  echo ""
  echo "[OK] Update complete"
}

cmd_logs() {
  local service="${1:-proxy}"
  local follow=false
  local line_count=50

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow) follow=true; shift ;;
      -n|--lines) line_count="$2"; shift 2 ;;
      *) service="$1"; shift ;;
    esac
  done

  local log_file="${LOG_DIR}/${service}.log"
  if [[ ! -f "$log_file" ]]; then
    echo "No logs found for $service at $log_file"
    exit 1
  fi

  if $follow; then
    tail -f "$log_file"
  else
    tail -n "$line_count" "$log_file"
  fi
}

# --- Main ---

command="${1:-}"
shift || true

if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
  echo "clawde - Claude Work to OpenCode bridge"
  echo ""
  echo "Usage: clawde <command> [options]"
  echo ""
  echo "Commands:"
  echo "  start    Start CCProxy + OpenCode"
  echo "  stop     Stop both services"
  echo "  status   Check health of both services"
  echo "  config   View or edit configuration"
  echo "  auth     Re-authenticate Claude"
  echo "  update   Update to latest versions"
  echo "  logs     Tail logs (proxy | opencode)"
  echo ""
  echo "Options:"
  echo "  --help, -h   Show this help"
  exit 0
fi

case "$command" in
  start)   cmd_start "$@" ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  config)  cmd_config "$@" ;;
  auth)    cmd_auth ;;
  update)  cmd_update ;;
  logs)    cmd_logs "$@" ;;
  *)
    echo "Unknown command: $command"
    echo "Run 'clawde --help' for usage"
    exit 1
    ;;
esac

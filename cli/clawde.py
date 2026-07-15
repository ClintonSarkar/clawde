#!/usr/bin/env python3
"""
clawde — unified CLI for managing OpenCode + CCProxy

Commands:
  start    — start CCProxy + OpenCode
  stop     — stop both services
  status   — health check both services
  config   — reconfigure settings
  auth     — re-authenticate Claude
  update   — update to latest versions
  logs     — tail logs from either service
"""

import argparse
import os
import sys
import subprocess
import signal
import time
import json
import tomllib
from pathlib import Path
from typing import Optional

# Platform detection
IS_WINDOWS = sys.platform == "win32"
IS_WSL = "microsoft" in open("/proc/version", "r").read().lower() if not IS_WINDOWS and os.path.exists("/proc/version") else False

# Paths
if IS_WINDOWS:
    CONFIG_DIR = Path(os.environ.get("APPDATA", "")) / "clawde"
    DATA_DIR = Path(os.environ.get("LOCALAPPDATA", "")) / "clawde"
    LOG_DIR = DATA_DIR / "logs"
    PID_DIR = DATA_DIR / "pids"
else:
    CONFIG_DIR = Path(os.environ.get("HOME", "")) / ".config" / "clawde"
    DATA_DIR = Path(os.environ.get("HOME", "")) / ".local" / "share" / "clawde"
    LOG_DIR = DATA_DIR / "logs"
    PID_DIR = DATA_DIR / "pids"


def load_config() -> dict:
    config_path = CONFIG_DIR / "clawde.toml"
    if not config_path.exists():
        print(f"Error: config not found at {config_path}")
        print("Run the installer first: curl -fsSL https://raw.githubusercontent.com/ClintonSarkar/clawde/main/install.sh | bash")
        sys.exit(1)

    with open(config_path, "rb") as f:
        return tomllib.load(f)


def get_pid(name: str) -> Optional[int]:
    pid_file = PID_DIR / f"{name}.pid"
    if pid_file.exists():
        try:
            return int(pid_file.read_text().strip())
        except ValueError:
            return None
    return None


def write_pid(name: str, pid: int):
    PID_DIR.mkdir(parents=True, exist_ok=True)
    (PID_DIR / f"{name}.pid").write_text(str(pid))


def remove_pid(name: str):
    pid_file = PID_DIR / f"{name}.pid"
    if pid_file.exists():
        pid_file.unlink()


def is_process_running(pid: int) -> bool:
    if IS_WINDOWS:
        try:
            result = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}"],
                capture_output=True, text=True, timeout=5
            )
            return str(pid) in result.stdout
        except Exception:
            return False
    else:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False


def start_proxy(config: dict) -> Optional[int]:
    """Start CCProxy in the background."""
    port = config.get("proxy", {}).get("port", 8080)
    host = config.get("proxy", {}).get("host", "127.0.0.1")

    log_file = LOG_DIR / "ccproxy.log"
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    cmd = ["ccproxy", "serve", "--port", str(port)]
    if IS_WINDOWS:
        cmd[0] = "ccproxy.exe"

    with open(log_file, "a") as lf:
        proc = subprocess.Popen(
            cmd,
            stdout=lf,
            stderr=subprocess.STDOUT,
            start_new_session=not IS_WINDOWS,
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if IS_WINDOWS else 0,
        )

    write_pid("proxy", proc.pid)

    # Wait for health
    import urllib.request
    for _ in range(30):
        time.sleep(0.5)
        try:
            urllib.request.urlopen(f"http://{host}:{port}/health", timeout=2)
            return proc.pid
        except Exception:
            continue

    return proc.pid  # return anyway, might be slow to start


def start_opencode(config: dict) -> Optional[int]:
    """Start OpenCode in the background."""
    port = config.get("proxy", {}).get("port", 8080)
    host = config.get("proxy", {}).get("host", "127.0.0.1")

    log_file = LOG_DIR / "opencode.log"
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    binary = "opencode.exe" if IS_WINDOWS else "opencode"

    # OpenCode connects to our proxy as a custom provider
    env = os.environ.copy()
    env["OPENCODE_PROVIDER_CLAWDE_BASE_URL"] = f"http://{host}:{port}/v1"
    env["OPENCODE_PROVIDER_CLAWDE_API_KEY"] = "clawde"

    cmd = [binary]

    with open(log_file, "a") as lf:
        proc = subprocess.Popen(
            cmd,
            stdout=lf,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=not IS_WINDOWS,
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if IS_WINDOWS else 0,
        )

    write_pid("opencode", proc.pid)
    return proc.pid


def cmd_start(args):
    config = load_config()

    # Check if already running
    proxy_pid = get_pid("proxy")
    if proxy_pid and is_process_running(proxy_pid):
        print(f"[OK] CCProxy already running (PID {proxy_pid})")
    else:
        print("[INFO] Starting CCProxy...")
        pid = start_proxy(config)
        if pid:
            print(f"[OK] CCProxy started (PID {pid})")
        else:
            print("[ERROR] CCProxy failed to start — check logs: clawde logs proxy")
            sys.exit(1)

    # Start OpenCode (interactive — this is the agent the user interacts with)
    opencode_pid = get_pid("opencode")
    if opencode_pid and is_process_running(opencode_pid):
        print(f"[OK] OpenCode already running (PID {opencode_pid})")
    else:
        print("[INFO] Starting OpenCode...")
        # For the coding agent, we launch it in foreground since it's interactive
        binary = "opencode.exe" if IS_WINDOWS else "opencode"
        port = config.get("proxy", {}).get("port", 8080)
        host = config.get("proxy", {}).get("host", "127.0.0.1")

        env = os.environ.copy()
        env["OPENCODE_PROVIDER_CLAWDE_BASE_URL"] = f"http://{host}:{port}/v1"
        env["OPENCODE_PROVIDER_CLAWDE_API_KEY"] = "clawde"

        os.execve(_find_binary(binary), [binary] + (args.extra or []), env)


def cmd_stop(args):
    for name in ["opencode", "proxy"]:
        pid = get_pid(name)
        if pid and is_process_running(pid):
            try:
                if IS_WINDOWS:
                    subprocess.run(["taskkill", "/PID", str(pid), "/F"], timeout=10)
                else:
                    os.kill(pid, signal.SIGTERM)
                    time.sleep(2)
                    if is_process_running(pid):
                        os.kill(pid, signal.SIGKILL)
                print(f"[OK] {name} stopped (was PID {pid})")
            except Exception as e:
                print(f"[ERROR] Failed to stop {name}: {e}")
        else:
            print(f"[OK] {name} not running")
        remove_pid(name)


def cmd_status(args):
    import urllib.request

    config = load_config()
    port = config.get("proxy", {}).get("port", 8080)
    host = config.get("proxy", {}).get("host", "127.0.0.1")

    # Proxy status
    proxy_pid = get_pid("proxy")
    if proxy_pid and is_process_running(proxy_pid):
        try:
            urllib.request.urlopen(f"http://{host}:{port}/health", timeout=3)
            print(f"[OK]   CCProxy   running (PID {proxy_pid}) — healthy")
        except Exception:
            print(f"[WARN] CCProxy   running (PID {proxy_pid}) — not responding")
    else:
        print("[FAIL] CCProxy   not running")

    # OpenCode status
    opencode_pid = get_pid("opencode")
    if opencode_pid and is_process_running(opencode_pid):
        print(f"[OK]   OpenCode  running (PID {opencode_pid})")
    else:
        print("[FAIL] OpenCode  not running")


def cmd_config(args):
    config_path = CONFIG_DIR / "clawde.toml"
    if args.edit:
        editor = os.environ.get("EDITOR", "vi" if not IS_WINDOWS else "notepad")
        subprocess.run([editor, str(config_path)])
    else:
        print(f"Config file: {config_path}")
        print()
        print(config_path.read_text())


def cmd_auth(args):
    """Re-authenticate Claude."""
    print("[INFO] Starting Claude OAuth flow...")
    print("  A browser window will open for you to log in.")
    print()
    try:
        subprocess.run(["ccproxy", "auth", "login", "claude"], check=True)
        print("\n[OK] Authentication complete")
    except subprocess.CalledProcessError:
        print("\n[ERROR] Authentication failed")
        sys.exit(1)
    except FileNotFoundError:
        print("[ERROR] ccproxy not found — run 'clawde update' to install")
        sys.exit(1)


def cmd_update(args):
    """Update OpenCode binary and CCProxy package."""
    print("[INFO] Updating OpenCode...")

    binary = "opencode.exe" if IS_WINDOWS else "opencode"
    bin_path = _find_binary(binary)

    if bin_path:
        result = subprocess.run([bin_path, "version"], capture_output=True, text=True, timeout=10)
        print(f"  Current: {result.stdout.strip()}")

    # Get latest release
    import urllib.request
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/ClintonSarkar/opencode/releases/latest",
            headers={"Accept": "application/vnd.github.v3+json"}
        )
        resp = urllib.request.urlopen(req, timeout=15)
        data = json.loads(resp.read())
        latest_tag = data.get("tag_name", "unknown")
        print(f"  Latest:  {latest_tag}")
    except Exception as e:
        print(f"  [ERROR] Could not fetch latest release: {e}")

    print()
    print("[INFO] Updating CCProxy...")

    uv = _find_binary("uv")
    pipx = _find_binary("pipx")
    if uv:
        subprocess.run([uv, "tool", "upgrade", "ccproxy-api[all]"], check=False)
    elif pipx:
        subprocess.run([pipx, "upgrade", "ccproxy-api"], check=False)
    else:
        print("  [ERROR] Neither uv nor pipx found")

    print("\n[OK] Update complete")


def cmd_logs(args):
    """Tail logs from services."""
    service = args.service or "proxy"
    log_file = LOG_DIR / f"{service}.log"

    if not log_file.exists():
        print(f"No logs found for {service} at {log_file}")
        sys.exit(1)

    if args.follow:
        if IS_WINDOWS:
            subprocess.run(["powershell", "-Command", f"Get-Content {log_file} -Wait -Tail 50"])
        else:
            subprocess.run(["tail", "-f", str(log_file)])
    else:
        # Print last N lines
        n = args.lines or 50
        lines = log_file.read_text(errors="replace").splitlines()
        for line in lines[-n:]:
            print(line)


def _find_binary(name: str) -> str:
    """Find a binary in PATH or in clawde's bin directory."""
    # Check clawde bin dir first
    if IS_WINDOWS:
        bin_dir = Path(os.environ.get("LOCALAPPDATA", "")) / "clawde" / "bin"
    else:
        bin_dir = Path(os.environ.get("HOME", "")) / ".local" / "bin"

    local_path = bin_dir / name
    if local_path.exists():
        return str(local_path)

    # Fall back to PATH
    from shutil import which
    found = which(name)
    if found:
        return found

    print(f"[ERROR] {name} not found — run 'clawde update' or reinstall")
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        prog="clawde",
        description="Claude Work → OpenCode bridge"
    )
    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # start
    p_start = subparsers.add_parser("start", help="Start CCProxy + OpenCode")
    p_start.add_argument("extra", nargs=argparse.REMAINDER, help="Extra args passed to opencode")
    p_start.set_defaults(func=cmd_start)

    # stop
    p_stop = subparsers.add_parser("stop", help="Stop both services")
    p_stop.set_defaults(func=cmd_stop)

    # status
    p_status = subparsers.add_parser("status", help="Check health of both services")
    p_status.set_defaults(func=cmd_status)

    # config
    p_config = subparsers.add_parser("config", help="View or edit configuration")
    p_config.add_argument("--edit", "-e", action="store_true", help="Open in editor")
    p_config.set_defaults(func=cmd_config)

    # auth
    p_auth = subparsers.add_parser("auth", help="Re-authenticate Claude")
    p_auth.set_defaults(func=cmd_auth)

    # update
    p_update = subparsers.add_parser("update", help="Update to latest versions")
    p_update.set_defaults(func=cmd_update)

    # logs
    p_logs = subparsers.add_parser("logs", help="Tail logs")
    p_logs.add_argument("service", nargs="?", default="proxy", help="Service name (proxy|opencode)")
    p_logs.add_argument("-f", "--follow", action="store_true", help="Follow log output")
    p_logs.add_argument("-n", "--lines", type=int, default=50, help="Number of lines to show")
    p_logs.set_defaults(func=cmd_logs)

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Ensure dirs exist
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    PID_DIR.mkdir(parents=True, exist_ok=True)

    args.func(args)


if __name__ == "__main__":
    main()

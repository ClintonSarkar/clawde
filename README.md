# clawde

> Bridge your Claude Work subscription to OpenCode. One install, full agent.

## Quick start

**Linux / WSL:**
```bash
curl -fsSL https://raw.githubusercontent.com/ClintonSarkar/clawde/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/ClintonSarkar/clawde/main/install.ps1 | iex
```

## What it does

clawde connects [OpenCode](https://github.com/anomalyco/opencode) to your [Claude Work](https://claude.ai) subscription via a local proxy — no API credits required.

```
OpenCode (coding agent) → CCProxy (localhost) → Claude Work subscription
```

## Commands

```bash
clawde start      # start CCProxy + OpenCode
clawde stop       # stop both services
clawde status     # health check both services
clawde config     # view or edit configuration
clawde auth       # re-authenticate Claude
clawde update     # update to latest versions
clawde logs       # tail logs (clawde logs proxy -f)
```

## Requirements

- **Linux/WSL:** bash, curl, Python 3.10+, pipx or uv
- **Windows:** PowerShell 5+, Python 3.10+, pip or uv
- **Claude Work subscription** (or Claude Code Max)

> **Note (Windows users):** The pre-built `ccproxy.exe` in upstream releases
> currently ships without the Claude/Codex auth provider plugins (see
> [CaddyGlow/ccproxy-api#75](https://github.com/CaddyGlow/ccproxy-api/issues/75)).
> The `clawde` installer detects this and automatically falls back to installing
> `ccproxy-api[plugins-claude,plugins-codex]` via `pipx` so `clawde auth` works
> out of the box. If you want to do it manually: `pipx install "ccproxy-api[plugins-claude,plugins-codex]"`.

## How it works

clawde is a deployment wrapper — it installs and configures two open-source tools:

- [OpenCode](https://github.com/ClintonSarkar/opencode) — the coding agent (Go binary)
- [CCProxy](https://github.com/ClintonSarkar/ccproxy-api) — the subscription proxy (Python)

It does not contain their source code. It installs pre-built binaries and packages from GitHub releases and PyPI.

## Configuration

Config lives at:
- **Linux/WSL:** `~/.config/clawde/clawde.toml`
- **Windows:** `%APPDATA%\clawde\clawde.toml`

Edit with `clawde config --edit` or view with `clawde config`.

## License

MIT

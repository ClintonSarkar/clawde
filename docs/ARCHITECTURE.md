# clawde — Architecture & Developer Guide

## Overview

clawde is a deployment wrapper that bridges a Claude Work subscription to OpenCode (the open-source coding agent). It does **not** contain the source code of either OpenCode or CCProxy — it installs and configures them.

## Components

```
┌─────────────────────────────────────────────────┐
│                  clawde CLI                       │
│  (start | stop | status | config | auth |        │
│   update | logs)                                  │
└──────────┬──────────────────────┬────────────────┘
           │                      │
           ▼                      ▼
    ┌──────────────┐      ┌──────────────┐
    │   CCProxy     │      │   OpenCode   │
    │  (Python)     │      │  (Go binary) │
    │  localhost    │◄─────│  coding agent│
    │  :8080/v1     │      │              │
    └──────┬───────┘      └──────────────┘
           │
           ▼
    ┌──────────────┐
    │ Claude Work   │
    │ subscription  │
    │ (OAuth/token) │
    └──────────────┘
```

## Repository structure

```
clawde/
├── README.md                  # User-facing docs
├── LICENSE                    # MIT
├── .gitattributes             # Line-ending control
├── install.sh                 # Linux/WSL installer (1170 lines)
├── install.ps1                # Windows installer (1221 lines)
├── config/
│   └── clawde.toml            # Default config template
├── cli/
│   ├── clawde.ps1             # Windows CLI management (530 lines)
│   ├── clawde.sh              # Linux/WSL CLI management (473 lines)
│   └── clawde.cmd             # CMD shim (2 lines)
├── service/
│   ├── clawde-proxy.service   # systemd user unit (Linux)
│   └── clawde-proxy.xml       # Windows scheduled task XML (unused — installer uses New-ScheduledTask)
├── docs/
│   └── ARCHITECTURE.md        # This file
└── .github/
    └── workflows/             # CI (lint / script checks)
```

## Install flow

1. User runs `curl ... | bash` (Linux) or `irm ... | iex` (Windows)
2. Installer detects OS + architecture
3. Downloads OpenCode binary from GitHub releases (or builds from source)
4. Installs CCProxy via `uv` / `pipx` / `pip`
5. Interactive config wizard:
   - Auth method (OAuth vs CLI token)
   - Port, auto-start, models
6. Sets up service management (systemd / scheduled task)
7. User runs `clawde start` to begin

## Config paths

| Platform | Config                   | Logs                          | PIDs                        |
|----------|--------------------------|-------------------------------|-----------------------------|
| Linux    | `~/.config/clawde/`      | `~/.local/share/clawde/logs/` | `~/.local/share/clawde/pids/` |
| WSL      | `~/.config/clawde/`      | `~/.local/share/clawde/logs/` | `~/.local/share/clawde/pids/` |
| Windows  | `%APPDATA%\clawde\`      | `%LOCALAPPDATA%\clawde\logs\` | `%LOCALAPPDATA%\clawde\pids\` |

## External dependencies

| Component  | Source repo                          | Installed via         |
|------------|--------------------------------------|-----------------------|
| OpenCode   | ClintonSarkar/opencode (fork)        | Binary download / Go build |
| CCProxy    | ClintonSarkar/ccproxy-api (fork)     | pipx / uv / pip       |

## Custom agent modes

Custom OpenCode agent modes are developed in the OpenCode fork (`ClintonSarkar/opencode`), not in this repo. clawde installs the binary from that fork's releases, so any agent modes you add there are automatically available to clawde users.

## Updates

This repo does **not** publish its own release artifacts. Updates flow through
`clawde update`, which:
1. Self-updates the `clawde` CLI script from `raw.githubusercontent.com/.../main`
   (hash-compared; backed up before replacing).
2. Upgrades OpenCode via the binary's own `opencode upgrade`.
3. Pulls the latest CCProxy binary from the `ClintonSarkar/ccproxy-api` fork's
   GitHub releases.

The OpenCode binary itself comes from the `ClintonSarkar/opencode` fork's
releases (see External dependencies above), not from this repo.

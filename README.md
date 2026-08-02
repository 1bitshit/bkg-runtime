# Claude Code Multi-Instance Manager

Manage multiple Claude Code instances (w1, w2, w3) running behind claude-nim gateways.

## Quick Start

1. Edit `.env` with your API keys (auto-populated from `.env.runt` if available)
2. `./start-claude-nim.sh start --w1`
3. `./start-claude-nim.sh status --all`

## Commands

| Command          | Instance     | Description                    |
|------------------|--------------|--------------------------------|
| `start --w1`     | w1, w2, w3   | Start instance                 |
| `start --all`    | --all        | Start all instances in parallel|
| `stop --w1`      | w1, w2, w3   | Stop instance                  |
| `stop --all`     | --all        | Stop all instances             |
| `status --w1`    | w1, w2, w3   | Check single instance          |
| `status --all`   | --all        | Check all instances            |
| `restart --w1`   | w1, w2, w3   | Restart instance               |
| `restart --all`  | --all        | Restart all in parallel        |
| `jump --w1`      | w1, w2, w3   | Attach to screen session       |

## Configuration (.env)

```env
INSTANCE_w1_API_KEY="nvapi-..."
INSTANCE_w1_PORT="7000"
INSTANCE_w1_HOST="0.0.0.0"
INSTANCE_w1_SETTINGS_DIR="conf/claude-w1"
INSTANCE_w1_NAME="w1"
INSTANCE_w1_MODEL="minimaxai/minimax-m3"
```

- **API_KEY** — API key for claude-nim gateway
- **PORT** — Port for claude-nim gateway (7000, 7001, 7002)
- **HOST** — Bind address (`0.0.0.0` for external access)
- **SETTINGS_DIR** — Claude config directory (relative to script dir, e.g. `conf/claude-w1`)
- **NAME** — Screen session name suffix
- **MODEL** — LLM model for claude-nim gateway
- **BIN_DIR** — Directory containing local `claude-nim-w1/w2/w3` binaries
- **INSTANCE_wX_BIN** — Full path to instance binary (overrides `BIN_DIR`)

## Architecture

```
Client (claude) <---> claude-nim gateway <---> LLM API
                      (port 7000, 7001, 7002)
```

Each instance runs in its own `screen` session with an isolated Claude config directory.

## Requirements

- `screen`
- `curl`
- `claude-nim-w1/w2/w3` binaries in `bin/` (or system `claude-nim`)
- `bun` (for `bunx --yes claude`)

## Docker

Run all 3 instances in Docker containers:

```bash
docker compose up -d
```

Or integrate with existing Multica stack:

```bash
docker compose -f docker-compose.yml -f ../docker-compose.selfhost.custom.yml up -d
```

Each instance is a separate container:

| Service   | Port | Binary           |
|-----------|------|------------------|
| claude-w1 | 7000 | bin/claude-nim-w1 |
| claude-w2 | 7001 | bin/claude-nim-w2 |
| claude-w3 | 7002 | bin/claude-nim-w3 |

Sessions persist via mounted `conf/` and `session-w*.json` volumes.

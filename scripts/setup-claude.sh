#!/bin/bash
# Setup script for Claude Code Multi-Instance Manager
# Usage: bash setup-claude.sh
#
# Auto-detects API keys from /opt/stacks/multica/.env.runt if present.

# Detect base directory (parent of scripts/ dir = runtime root)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Claude Code Multi-Instance Setup ==="
echo "Target directory: $BASE_DIR"
echo ""

# ---------------------------------------------------------------------------
# Parse .env.runt for real API keys, ports, and models
# ---------------------------------------------------------------------------
RUNT_FILE="${RUNT_FILE:-/opt/stacks/multica/.env.runt}"

if [ -f "$RUNT_FILE" ]; then
  echo "Parsing API keys from $RUNT_FILE..."

  # Extract values from the "Claude Runtime Nr.1/2/3" lines
  # Format: Claude Runtime Nr.X: bunx --yes claude-nim-wX --yolo --model MODEL --port PORT --api-key KEY --serve
  RAW_LINE_1=$(grep "Runtime Nr.1:" "$RUNT_FILE" | head -1)
  RAW_LINE_2=$(grep "Runtime Nr.2:" "$RUNT_FILE" | head -1)
  RAW_LINE_3=$(grep "Runtime Nr.3:" "$RUNT_FILE" | head -1)

  parse_field() {
    local line="$1"
    local flag="$2"
    echo "$line" | grep -oP -- "${flag} \K[^\s]+" | head -1
  }

  # Override ports to 7000-range
  W1_PORT="7000"
  W2_PORT="7001"
  W3_PORT="7002"

  W1_KEY=$(parse_field "$RAW_LINE_1" "--api-key")
  W1_MODEL=$(parse_field "$RAW_LINE_1" "--model")

  W2_KEY=$(parse_field "$RAW_LINE_2" "--api-key")
  W2_MODEL=$(parse_field "$RAW_LINE_2" "--model")

  W3_KEY=$(parse_field "$RAW_LINE_3" "--api-key")
  W3_MODEL=$(parse_field "$RAW_LINE_3" "--model")
else
  echo "No .env.runt found at $RUNT_FILE, using placeholder values."
  W1_PORT="7000"; W1_KEY="your-api-key-1"; W1_MODEL="minimaxai/minimax-m3"
  W2_PORT="7001"; W2_KEY="your-api-key-2"; W2_MODEL="minimaxai/minimax-m3"
  W3_PORT="7002"; W3_KEY="your-api-key-3"; W3_MODEL="minimaxai/minimax-m3"
fi

# BIN_DIR for local binaries (claude-nim-w1, claude-nim-w2, claude-nim-w3)
BIN_DIR="$BASE_DIR/bin"

echo "  w1: port=$W1_PORT model=$W1_MODEL"
echo "  w2: port=$W2_PORT model=$W2_MODEL"
echo "  w3: port=$W3_PORT model=$W3_MODEL"

# ---------------------------------------------------------------------------
# Part 1: Create .env
# ---------------------------------------------------------------------------
echo "Creating .env file..."
cat > "$BASE_DIR/.env" << ENVEOF
# Instance 1
INSTANCE_w1_API_KEY="$W1_KEY"
INSTANCE_w1_PORT="$W1_PORT"
INSTANCE_w1_HOST="0.0.0.0"
INSTANCE_w1_SETTINGS_DIR="conf/claude-w1"
INSTANCE_w1_NAME="w1"
INSTANCE_w1_MODEL="$W1_MODEL"

# Instance 2
INSTANCE_w2_API_KEY="$W2_KEY"
INSTANCE_w2_PORT="$W2_PORT"
INSTANCE_w2_HOST="0.0.0.0"
INSTANCE_w2_SETTINGS_DIR="conf/claude-w2"
INSTANCE_w2_NAME="w2"
INSTANCE_w2_MODEL="$W2_MODEL"

# Instance 3
INSTANCE_w3_API_KEY="$W3_KEY"
INSTANCE_w3_PORT="$W3_PORT"
INSTANCE_w3_HOST="0.0.0.0"
INSTANCE_w3_SETTINGS_DIR="conf/claude-w3"
INSTANCE_w3_NAME="w3"
INSTANCE_w3_MODEL="$W3_MODEL"

# Binary directory for local claude-nim binaries
BIN_DIR="$BIN_DIR"
ENVEOF
echo "Created .env"

# ---------------------------------------------------------------------------
# Part 2-4: Create start-claude-nim.sh
# ---------------------------------------------------------------------------
echo "Creating start-claude-nim.sh..."
cat > "$BASE_DIR/start-claude-nim.sh" << 'SCRIPTEOF'
#!/bin/bash
# Claude Code Multi-Instance Manager
# Usage: ./start-claude-nim.sh [command] [instance]

# Load .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "Missing .env file. Run setup-claude.sh first."
  exit 1
fi

# Make SETTINGS_DIR paths absolute relative to script dir
make_abs() {
  local dir="$1"
  case "$dir" in
    /*) echo "$dir" ;;
    *)  echo "$SCRIPT_DIR/$dir" ;;
  esac
}

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

show_usage() {
  cat << 'USAGEEOF'
Usage: start-claude-nim.sh [COMMAND] [INSTANCE]

Commands:
  start   --w1|--w2|--w3|--all    Start instance(s)
  stop    --w1|--w2|--w3|--all    Stop instance(s)
  status  --w1|--w2|--w3|--all    Check status
  restart --w1|--w2|--w3|--all    Restart instance(s)
  jump    --w1|--w2|--w3          Attach to screen session

Examples:
  ./start-claude-nim.sh start --w1        Start w1
  ./start-claude-nim.sh stop --w2         Stop w2
  ./start-claude-nim.sh status --all      Check all
  ./start-claude-nim.sh restart --w3      Restart w3
  ./start-claude-nim.sh jump --w1         Attach to w1 screen
USAGEEOF
}

start_instance() {
  local INSTANCE="$1"
  local API_KEY_VAR="INSTANCE_${INSTANCE}_API_KEY"
  local PORT_VAR="INSTANCE_${INSTANCE}_PORT"
  local HOST_VAR="INSTANCE_${INSTANCE}_HOST"
  local SETTINGS_DIR_VAR="INSTANCE_${INSTANCE}_SETTINGS_DIR"
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"
  local MODEL_VAR="INSTANCE_${INSTANCE}_MODEL"

  local API_KEY="${!API_KEY_VAR}"
  local PORT="${!PORT_VAR}"
  local HOST="${!HOST_VAR}"
  local SETTINGS_DIR="${!SETTINGS_DIR_VAR}"
  local INSTANCE_NAME="${!NAME_VAR}"
  local MODEL="${!MODEL_VAR}"

  if [ -z "$API_KEY" ] || [ -z "$PORT" ]; then
    echo "Missing configuration for instance $INSTANCE"
    return 1
  fi

  # Resolve settings dir
  SETTINGS_DIR="$(make_abs "$SETTINGS_DIR")"
  mkdir -p "$SETTINGS_DIR"

  # Determine binary: use local bin if available
  local NIM_BIN="claude-nim"
  if [ -n "$BIN_DIR" ] && [ -x "$BIN_DIR/claude-nim-${INSTANCE_NAME}" ]; then
    NIM_BIN="$BIN_DIR/claude-nim-${INSTANCE_NAME}"
    echo "Using local binary: $NIM_BIN"
  fi

  # Write Claude config
  cat > "${SETTINGS_DIR}/.claude.json" << 'CLAUDFE'
{
  "projects": {
    "*": {
      "hasTrustDialogAccepted": true,
      "hasCompletedOnboarding": true
    }
  }
}
CLAUDFE
  echo "Config written to ${SETTINGS_DIR}/.claude.json"

  # Kill existing screen if any
  screen -S "claude-nim-${INSTANCE_NAME}" -X quit 2>/dev/null
  sleep 1

  # Build claude-nim command with model flag
  local NIM_CMD=("$NIM_BIN" --serve-only --yolo --port "$PORT" --api-key "$API_KEY" --host "$HOST")
  if [ -n "$MODEL" ]; then
    NIM_CMD+=(--model "$MODEL")
  fi

  # Start claude-nim in detached screen
  screen -dmS "claude-nim-${INSTANCE_NAME}" "${NIM_CMD[@]}"

  echo "Starting claude-nim-${INSTANCE_NAME} on ${HOST}:${PORT} (model: ${MODEL:-default})..."
  sleep 3

  # Verify
  if curl -sf "http://${HOST}:${PORT}" > /dev/null 2>&1; then
    echo "claude-nim-${INSTANCE_NAME} is running on ${HOST}:${PORT}"
    CLAUDE_CONFIG_DIR="$SETTINGS_DIR" \
    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1" \
    ANTHROPIC_BASE_URL="http://${HOST}:${PORT}" \
    ANTHROPIC_API_KEY="$API_KEY" \
    bunx --yes claude
  else
    echo "Server not responding on ${HOST}:${PORT}, retrying..."
    screen -S "claude-nim-${INSTANCE_NAME}" -X quit
    sleep 1
    screen -dmS "claude-nim-${INSTANCE_NAME}" "${NIM_CMD[@]}"
    sleep 3
    CLAUDE_CONFIG_DIR="$SETTINGS_DIR" \
    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1" \
    ANTHROPIC_BASE_URL="http://${HOST}:${PORT}" \
    ANTHROPIC_API_KEY="$API_KEY" \
    bunx --yes claude
  fi
}

stop_instance() {
  local INSTANCE="$1"
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"
  local INSTANCE_NAME="${!NAME_VAR}"

  if screen -list 2>/dev/null | grep -q "claude-nim-${INSTANCE_NAME}"; then
    screen -S "claude-nim-${INSTANCE_NAME}" -X quit
    echo "Stopped claude-nim-${INSTANCE_NAME}"
  else
    echo "Instance ${INSTANCE_NAME} is not running"
  fi
}

status_instance() {
  local INSTANCE="$1"
  local PORT_VAR="INSTANCE_${INSTANCE}_PORT"
  local HOST_VAR="INSTANCE_${INSTANCE}_HOST"
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"

  local PORT="${!PORT_VAR}"
  local HOST="${!HOST_VAR}"
  local INSTANCE_NAME="${!NAME_VAR}"

  if screen -list 2>/dev/null | grep -q "claude-nim-${INSTANCE_NAME}"; then
    if curl -sf "http://${HOST}:${PORT}" > /dev/null 2>&1; then
      echo "${INSTANCE_NAME} is RUNNING on ${HOST}:${PORT}"
    else
      echo "${INSTANCE_NAME} screen exists but server not responding on ${HOST}:${PORT}"
    fi
  else
    echo "${INSTANCE_NAME} is STOPPED"
  fi
}

restart_instance() {
  local INSTANCE="$1"
  echo "Restarting ${INSTANCE}..."
  stop_instance "$INSTANCE"
  sleep 2
  start_instance "$INSTANCE"
}

jump_instance() {
  local INSTANCE="$1"
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"
  local INSTANCE_NAME="${!NAME_VAR}"

  if screen -list 2>/dev/null | grep -q "claude-nim-${INSTANCE_NAME}"; then
    echo "Attaching to claude-nim-${INSTANCE_NAME}..."
    echo "Press Ctrl+A then D to detach"
    screen -r "claude-nim-${INSTANCE_NAME}"
  else
    echo "Instance ${INSTANCE_NAME} is not running"
  fi
}

status_all() {
  echo "=== Claude Instances Status ==="
  status_instance "w1"
  status_instance "w2"
  status_instance "w3"
  echo ""
  echo "Active screens:"
  screen -list 2>/dev/null | grep claude-nim || echo "No active instances"
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

if [ $# -eq 0 ]; then
  show_usage
  exit 1
fi

COMMAND="$1"
INSTANCE="$2"

case "$COMMAND" in
  start)
    case "$INSTANCE" in
      --w1)   start_instance "w1" ;;
      --w2)   start_instance "w2" ;;
      --w3)   start_instance "w3" ;;
      --all)
        start_instance "w1" &
        start_instance "w2" &
        start_instance "w3" &
        wait
        ;;
      *) echo "Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  stop)
    case "$INSTANCE" in
      --w1)   stop_instance "w1" ;;
      --w2)   stop_instance "w2" ;;
      --w3)   stop_instance "w3" ;;
      --all)
        stop_instance "w1"
        stop_instance "w2"
        stop_instance "w3"
        ;;
      *) echo "Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  status)
    case "$INSTANCE" in
      --w1)   status_instance "w1" ;;
      --w2)   status_instance "w2" ;;
      --w3)   status_instance "w3" ;;
      --all) status_all ;;
      *) echo "Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  restart)
    case "$INSTANCE" in
      --w1)   restart_instance "w1" ;;
      --w2)   restart_instance "w2" ;;
      --w3)   restart_instance "w3" ;;
      --all)
        restart_instance "w1" &
        restart_instance "w2" &
        restart_instance "w3" &
        wait
        ;;
      *) echo "Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  jump)
    case "$INSTANCE" in
      --w1)   jump_instance "w1" ;;
      --w2)   jump_instance "w2" ;;
      --w3)   jump_instance "w3" ;;
      *) echo "Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  *)
    echo "Unknown command: $COMMAND"
    show_usage
    exit 1
    ;;
esac
SCRIPTEOF
echo "Created start-claude-nim.sh"

# ---------------------------------------------------------------------------
# Part 5: Create README.md
# ---------------------------------------------------------------------------
echo "Creating README.md..."
cat > "$BASE_DIR/README.md" << 'READMEEOF'
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
- **BIN_DIR** — Directory containing local `claude-nim-w1/w2/w3` binaries (auto-detected)

## Architecture

```
Client (claude) <---> claude-nim gateway <---> LLM API
                      (port 7000, 7001, 7002)
```

Each instance runs in its own `screen` session with an isolated Claude config directory.

## Requirements

- `screen`
- `curl`
- `claude-nim` (in PATH)
- `bun` (for `bunx --yes claude`)
READMEEOF
echo "Created README.md"

# ---------------------------------------------------------------------------
# Part 6: Make executable and finish
# ---------------------------------------------------------------------------
chmod +x "$BASE_DIR/start-claude-nim.sh"
echo "Made start-claude-nim.sh executable"

# ---------------------------------------------------------------------------
# Part 6b: Create .gitignore
# ---------------------------------------------------------------------------
echo "Creating .gitignore..."
cat > "$BASE_DIR/.gitignore" << 'GITEOF'
# Instance settings directories
conf/claude-w1/
conf/claude-w2/
conf/claude-w3/

# Screen logs and temp
*.log
screenlog.*

# OS files
.DS_Store
Thumbs.db

# Editor files
.vscode/
.idea/
*.swp
*.swo
*~

# Node
node_modules/
*.local
GITEOF
echo "Created .gitignore"

echo ""
echo "=== Setup Complete ==="
echo "Files created:"
echo "  .env"
echo "  start-claude-nim.sh"
echo "  README.md"
echo "  .gitignore"
echo ""
echo "Next: Edit .env and run ./start-claude-nim.sh start --w1"

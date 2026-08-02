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
  local NIM_CMD=(claude-nim --serve-only --port "$PORT" --api-key "$API_KEY" --host "$HOST")
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

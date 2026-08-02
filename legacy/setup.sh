#!/bin/bash

echo "=== Claude Code Multi-Instance Setup ==="
echo ""

# Create .env file
echo "Creating .env file..."
cat > .env << 'EOF'
# Instance 1
INSTANCE_w1_API_KEY="your-api-key-1"
INSTANCE_w1_PORT="7000"
INSTANCE_w1_HOST="localhost"
INSTANCE_w1_SETTINGS_DIR="/opt/stacks/multica/runtime/.claude-w1"
INSTANCE_w1_NAME="w1"

# Instance 2
INSTANCE_w2_API_KEY="your-api-key-2"
INSTANCE_w2_PORT="7001"
INSTANCE_w2_HOST="localhost"
INSTANCE_w2_SETTINGS_DIR="/opt/stacks/multica/runtime/.claude-w2"
INSTANCE_w2_NAME="w2"

# Instance 3
INSTANCE_w3_API_KEY="your-api-key-3"
INSTANCE_w3_PORT="7002"
INSTANCE_w3_HOST="localhost"
INSTANCE_w3_SETTINGS_DIR="/opt/stacks/multica/runtime/.claude-w3"
INSTANCE_w3_NAME="w3"
EOF
echo "✓ Created .env"
#!/bin/bash

# Load .env file
if [ -f .env ]; then
  export $(cat .env | grep -v '#' | xargs)
else
  echo "✗ .env file not found"
  exit 1
fi

# Function to show usage
show_usage() {
  echo "Usage: $0 [COMMAND] [INSTANCE]"
  echo ""
  echo "Commands:"
  echo "  start   --w1|--w2|--w3|--all    Start instance(s)"
  echo "  stop    --w1|--w2|--w3|--all    Stop instance(s)"
  echo "  status  --w1|--w2|--w3|--all    Check status"
  echo "  restart --w1|--w2|--w3|--all    Restart instance(s)"
  echo "  jump    --w1|--w2|--w3          Jump into screen session"
  echo ""
  echo "Examples:"
  echo "  $0 start --w1                   # Start w1"
  echo "  $0 stop --w2                    # Stop w2"
  echo "  $0 status --all                 # Check all status"
  echo "  $0 restart --w3                 # Restart w3"
  echo "  $0 jump --w1                    # Jump into w1 screen"
}

# Function to start a Claude instance
start_instance() {
  local INSTANCE=$1
  local API_KEY_VAR="INSTANCE_${INSTANCE}_API_KEY"
  local PORT_VAR="INSTANCE_${INSTANCE}_PORT"
  local HOST_VAR="INSTANCE_${INSTANCE}_HOST"
  local SETTINGS_DIR_VAR="INSTANCE_${INSTANCE}_SETTINGS_DIR"
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"

  local API_KEY="${!API_KEY_VAR}"
  local PORT="${!PORT_VAR}"
  local HOST="${!HOST_VAR}"
  local SETTINGS_DIR="${!SETTINGS_DIR_VAR}"
  local INSTANCE_NAME="${!NAME_VAR}"

  if [ -z "$API_KEY" ] || [ -z "$PORT" ]; then
    echo "✗ Missing configuration for instance $INSTANCE"
    return
  fi

  mkdir -p "$SETTINGS_DIR"

  cat > "${SETTINGS_DIR}/.claude.json" << 'EOF'
{
  "projects": {
    "*": {
      "hasTrustDialogAccepted": true,
      "hasCompletedOnboarding": true
    }
  }
}
EOF

  echo "✓ Config written to ${SETTINGS_DIR}/.claude.json"
  sleep 2

  screen -dmS "claude-nim-${INSTANCE_NAME}" claude-nim --serve-only --port "$PORT" --api-key "$API_KEY" --host "$HOST"

  echo "Starting claude-nim-${INSTANCE_NAME} on ${HOST}:${PORT}..."
  sleep 2

  if curl -s "http://${HOST}:${PORT}" > /dev/null 2>&1; then
    echo "✓ claude-nim-${INSTANCE_NAME} is running on ${HOST}:${PORT}"
    CLAUDE_CONFIG_DIR="$SETTINGS_DIR" CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1" ANTHROPIC_BASE_URL="http://${HOST}:${PORT}" ANTHROPIC_API_KEY="$API_KEY" bunx --yes claude
  else
    echo "✗ Server failed to start. Retrying..."
    screen -S "claude-nim-${INSTANCE_NAME}" -X quit
    sleep 1
    screen -dmS "claude-nim-${INSTANCE_NAME}" claude-nim --serve-only --port "$PORT" --api-key "$API_KEY" --host "$HOST"
    sleep 2
    CLAUDE_CONFIG_DIR="$SETTINGS_DIR" CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1" ANTHROPIC_BASE_URL="http://${HOST}:${PORT}" ANTHROPIC_API_KEY="$API_KEY" bunx --yes claude
  fi
}
# Function to stop instance
stop_instance() {
  local INSTANCE=$1
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"
  local INSTANCE_NAME="${!NAME_VAR}"

  if screen -list | grep -q "claude-nim-${INSTANCE_NAME}"; then
    screen -S "claude-nim-${INSTANCE_NAME}" -X quit
    echo "✓ Stopped claude-nim-${INSTANCE_NAME}"
  else
    echo "✗ Instance ${INSTANCE_NAME} is not running"
  fi
}

# Function to check status
status_instance() {
  local INSTANCE=$1
  local PORT_VAR="INSTANCE_${INSTANCE}_PORT"
  local HOST_VAR="INSTANCE_${INSTANCE}_HOST"
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"
  
  local PORT="${!PORT_VAR}"
  local HOST="${!HOST_VAR}"
  local INSTANCE_NAME="${!NAME_VAR}"

  if screen -list | grep -q "claude-nim-${INSTANCE_NAME}"; then
    if curl -s "http://${HOST}:${PORT}" > /dev/null 2>&1; then
      echo "✓ ${INSTANCE_NAME} is RUNNING on ${HOST}:${PORT}"
    else
      echo "⚠ ${INSTANCE_NAME} screen exists but server not responding on ${HOST}:${PORT}"
    fi
  else
    echo "✗ ${INSTANCE_NAME} is STOPPED"
  fi
}

# Function to restart instance
restart_instance() {
  local INSTANCE=$1
  echo "Restarting ${INSTANCE}..."
  stop_instance "$INSTANCE"
  sleep 2
  start_instance "$INSTANCE"
}

# Function to jump into screen session
jump_instance() {
  local INSTANCE=$1
  local NAME_VAR="INSTANCE_${INSTANCE}_NAME"
  local INSTANCE_NAME="${!NAME_VAR}"

  if screen -list | grep -q "claude-nim-${INSTANCE_NAME}"; then
    echo "Jumping into claude-nim-${INSTANCE_NAME}..."
    echo "Press Ctrl+A then D to detach"
    screen -r "claude-nim-${INSTANCE_NAME}"
  else
    echo "✗ Instance ${INSTANCE_NAME} is not running"
  fi
}

# Function to show all status
status_all() {
  echo "=== Claude Instances Status ==="
  status_instance "w1"
  status_instance "w2"
  status_instance "w3"
  echo ""
  echo "Active screens:"
  screen -list | grep claude-nim || echo "No active instances"
}
# Parse arguments
if [ $# -eq 0 ]; then
  show_usage
  exit 1
fi

COMMAND=$1
INSTANCE=$2

case "$COMMAND" in
  start)
    case "$INSTANCE" in
      --w1) start_instance "w1" ;;
      --w2) start_instance "w2" ;;
      --w3) start_instance "w3" ;;
      --all)
        start_instance "w1" &
        start_instance "w2" &
        start_instance "w3" &
        wait
        ;;
      *) echo "✗ Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  stop)
    case "$INSTANCE" in
      --w1) stop_instance "w1" ;;
      --w2) stop_instance "w2" ;;
      --w3) stop_instance "w3" ;;
      --all)
        stop_instance "w1"
        stop_instance "w2"
        stop_instance "w3"
        ;;
      *) echo "✗ Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  status)
    case "$INSTANCE" in
      --w1) status_instance "w1" ;;
      --w2) status_instance "w2" ;;
      --w3) status_instance "w3" ;;
      --all) status_all ;;
      *) echo "✗ Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  restart)
    case "$INSTANCE" in
      --w1) restart_instance "w1" ;;
      --w2) restart_instance "w2" ;;
      --w3) restart_instance "w3" ;;
      --all)
        restart_instance "w1" &
        restart_instance "w2" &
        restart_instance "w3" &
        wait
        ;;
      *) echo "✗ Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  jump)
    case "$INSTANCE" in
      --w1) jump_instance "w1" ;;
      --w2) jump_instance "w2" ;;
      --w3) jump_instance "w3" ;;
      *) echo "✗ Unknown instance: $INSTANCE"; show_usage; exit 1 ;;
    esac
    ;;
  *)
    echo "✗ Unknown command: $COMMAND"
    show_usage
    exit 1
    ;;
esac
cat > README.md << 'README'
# Claude Code Multi-Instance Manager

Manage multiple Claude Code instances (w1, w2, w3).

## Setup

1. Edit `.env` with your API keys
2. Run: `./start-claude-nim.sh start --w1`

## Commands

- `./start-claude-nim.sh start --w1` - Start w1
- `./start-claude-nim.sh stop --w2` - Stop w2
- `./start-claude-nim.sh status --all` - Check all
- `./start-claude-nim.sh restart --w3` - Restart w3
- `./start-claude-nim.sh jump --w1` - Jump into w1

## Configuration

Edit `.env`:
- `INSTANCE_wX_API_KEY` - API key
- `INSTANCE_wX_PORT` - Port (7000, 7001, 7002)
- `INSTANCE_wX_HOST` - Host (localhost)
- `INSTANCE_wX_SETTINGS_DIR` - Settings path

## Files

- `.env` - Configuration
- `start-claude-nim.sh` - Control script
- `README.md` - This file
README
chmod +x start-claude-nim.sh

echo ""
echo "=== Setup Complete ==="
echo "Files created:"
echo "  ✓ .env"
echo "  ✓ start-claude-nim.sh"
echo "  ✓ README.md"
echo ""
echo "Next: Edit .env and run ./start-claude-nim.sh start --w1"
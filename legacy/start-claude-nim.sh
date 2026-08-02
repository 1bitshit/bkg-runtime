#!/bin/bash

# Load .env file
if [ -f .env ]; then
  export $(cat .env | grep -v '#' | xargs)
else
  echo "✗ .env file not found"
  exit 1
fi

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

  # Create settings directory
  mkdir -p "$SETTINGS_DIR"

  # Write config
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

  # Start claude-nim
  screen -dmS "claude-nim-${INSTANCE_NAME}" claude-nim --serve-only --port "$PORT" --api-key "$API_KEY" --host "$HOST"

  echo "Starting claude-nim-${INSTANCE_NAME} on ${HOST}:${PORT}..."
  sleep 2

  # Check if running
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

# Show usage
if [ $# -eq 0 ]; then
  echo "Usage: $0 --w1 | --w2 | --w3 | --all"
  echo ""
  echo "Examples:"
  echo "  $0 --w1      # Start instance w1"
  echo "  $0 --w2      # Start instance w2"
  echo "  $0 --w3      # Start instance w3"
  echo "  $0 --all     # Start all instances"
  exit 1
fi

# Parse arguments
case "$1" in
  --w1)
    start_instance "w1"
    ;;
  --w2)
    start_instance "w2"
    ;;
  --w3)
    start_instance "w3"
    ;;
  --all)
    start_instance "w1" &
    start_instance "w2" &
    start_instance "w3" &
    wait
    ;;
  *)
    echo "✗ Unknown option: $1"
    echo "Usage: $0 --w1 | --w2 | --w3 | --all"
    exit 1
    ;;
esac
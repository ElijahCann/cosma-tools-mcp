#!/usr/bin/env bash
#
# run-cosma-mcp.sh
# ---------------------------------------------------------------------------
# Starts a COSMA MCP chat session: makes sure the SSH connection is alive,
# makes sure Ollama is running (if that's your backend), then launches
# mcphost. Reads everything it needs from run-config.env, written by
# cosma-mcp-setup.sh, so there's nothing to re-enter each time.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/run-config.env"

[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found. Run cosma-mcp-setup.sh first."; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Make sure the SSH connection is alive
# ---------------------------------------------------------------------------

info "Checking SSH connection to $COSMA_ALIAS"

if ! ssh -O check "$COSMA_ALIAS" >/dev/null 2>&1; then
    echo "No live connection — authenticate now (password/2FA as prompted):"
    ssh "$COSMA_ALIAS" 'echo "Connected."; exit'
else
    echo "Connection already alive, reusing it."
fi

# ---------------------------------------------------------------------------
# 2. If using Ollama, make sure it's running
# ---------------------------------------------------------------------------

if [ "${BACKEND:-}" = "1" ]; then
    info "Checking Ollama"
    if ! pgrep -x "ollama" >/dev/null 2>&1; then
        echo "Ollama not running — starting it..."
        case "$(uname -s)" in
            Darwin)
                if command -v brew >/dev/null 2>&1 && brew services list 2>/dev/null | grep -q ollama; then
                    brew services start ollama
                else
                    nohup ollama serve > /tmp/ollama.log 2>&1 &
                    disown
                fi
                ;;
            *)
                nohup ollama serve > /tmp/ollama.log 2>&1 &
                disown
                ;;
        esac
        sleep 2
    else
        echo "Ollama already running."
    fi
fi

# ---------------------------------------------------------------------------
# 3. Launch mcphost
# ---------------------------------------------------------------------------

SYSTEM_PROMPT="You are a terse COSMA cluster assistant. When a tool returns\
  data, answer the user's question directly and concisely using that data.\
  Never explain your reasoning process, never describe what the raw data \
  'might mean', never say things like 'let me check' or 'let me analyse this'\
  — just call the tool if needed and state the answer. OPTIONAL PARAMETERS:\
  if a tool parameter is optional and the user did not explicitly specify a\
  value for it, leave it out of the call entirely — omitting it triggers\
  the tool's correct default behaviour. Never fill an optional parameter\
  with a guess, a placeholder word (e.g. 'me', 'current', 'this', 'here'),\
  or the name of another tool — that is never a valid value. Only pass a\
  parameter when the user's question names that specific value themselves (\
  e.g. a specific username or node name). If you're unsure whether a value\
  is real, call the appropriate lookup tool (whoami, current_node) first\
  and use its actual returned value — never its name. If data needed to\
  answer is missing or blank, say so — never estimate or fabricate a number\
  to fill it in."

info "Starting mcphost ($MODEL_STRING)"

cd "$SCRIPT_DIR"
exec mcphost -m "$MODEL_STRING" --config mcp-servers.json --system-prompt "$SYSTEM_PROMPT"

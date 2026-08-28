#!/usr/bin/env bash
#
# stop-cosma-mcp.sh
# ---------------------------------------------------------------------------
# Stops the locally-running Ollama instance (if that's your backend).
# Nothing to stop for the Claude API backend — it's not a local process.
# mcphost itself just exits with Ctrl+C / closing its terminal; it isn't a
# background service.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/run-config.env"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

if [ "${BACKEND:-1}" != "1" ]; then
    echo "Backend is not Ollama — nothing local to stop."
    exit 0
fi

echo "Stopping Ollama..."

case "$(uname -s)" in
    Darwin)
        if command -v brew >/dev/null 2>&1 && brew services list 2>/dev/null | grep -q "ollama.*started"; then
            brew services stop ollama
        else
            pkill -x ollama 2>/dev/null && echo "Killed ollama process." || echo "No running ollama process found."
        fi
        ;;
    Linux)
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama 2>/dev/null; then
            sudo systemctl stop ollama
        else
            pkill -x ollama 2>/dev/null && echo "Killed ollama process." || echo "No running ollama process found."
        fi
        ;;
    *)
        pkill -x ollama 2>/dev/null && echo "Killed ollama process." || echo "No running ollama process found."
        ;;
esac

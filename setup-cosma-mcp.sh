#!/usr/bin/env bash
#
# cosma-mcp-setup.sh
# ---------------------------------------------------------------------------
# Sets up a COSMA MCP server + local client tooling so you can chat with an
# LLM about your COSMA jobs/quota/nodes. Prompts for your own SSH details —
# nothing here is tied to any specific person's account or machine.
#
# Requires: server.py in the same directory as this script.
# Supports: macOS (Homebrew) and Debian/Ubuntu-based Linux (apt).
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_PROJECT_DIR="$HOME/cosma-mcp"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
warn()  { printf '\033[1;33mWARNING: %s\033[0m\n' "$1"; }
fail()  { printf '\033[1;31mERROR: %s\033[0m\n' "$1"; exit 1; }
ask()   { read -r -p "$1: " REPLY; echo "$REPLY"; }
ask_default() { read -r -p "$1 [$2]: " REPLY; echo "${REPLY:-$2}"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

detect_shell_rc() {
    case "$SHELL" in
        */zsh)  echo "$HOME/.zshrc" ;;
        */bash) echo "$HOME/.bashrc" ;;
        *)      echo "$HOME/.profile" ;;
    esac
}

OS="$(detect_os)"
SHELL_RC="$(detect_shell_rc)"

[ -f "$SCRIPT_DIR/server.py" ] || fail "server.py not found next to this script (looked in $SCRIPT_DIR). Place both files in the same folder and re-run."

# ---------------------------------------------------------------------------
# Step 0 — Gather COSMA connection details
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 0 — SSH connection details (existing config or new)
# ---------------------------------------------------------------------------

info "COSMA connection details"

HAS_EXISTING="$(ask_default "Do you already have a working SSH config entry (Host alias) for COSMA in ~/.ssh/config? (y/n)" "n")"

if [ "$HAS_EXISTING" = "y" ] || [ "$HAS_EXISTING" = "Y" ]; then
    COSMA_ALIAS="$(ask "Alias name exactly as it appears after 'Host ' in ~/.ssh/config")"

    ssh -G "$COSMA_ALIAS" >/dev/null 2>&1 || fail "No SSH config entry found for '$COSMA_ALIAS'. Check ~/.ssh/config and try again."

    # Pull the resolved user/hostname out of the existing config so later
    # steps (remote paths, messages) can reference them without re-asking.
    COSMA_USER="$(ssh -G "$COSMA_ALIAS" | awk '/^user /{print $2; exit}')"
    COSMA_HOST="$(ssh -G "$COSMA_ALIAS" | awk '/^hostname /{print $2; exit}')"
    echo "Using existing config: $COSMA_ALIAS -> $COSMA_USER@$COSMA_HOST"

    # Make sure ControlMaster/ControlPersist is set, since later steps (and
    # the run script) rely on a persistent connection to avoid re-prompting
    # for 2FA on every command. Append it as a supplementary block if the
    # existing entry doesn't already have it — SSH applies the FIRST value
    # it sees for a given option, so this only takes effect if the existing
    # entry doesn't already set ControlMaster itself.
    mkdir -p "$HOME/.ssh/controlmasters"
    if ! ssh -G "$COSMA_ALIAS" | grep -q "^controlmaster yes"; then
        if ! grep -q "Host $COSMA_ALIAS$" "$HOME/.ssh/config" 2>/dev/null; then
            warn "Could not find 'Host $COSMA_ALIAS' as an exact block in ~/.ssh/config (it may be matched via a wildcard entry) — skipping automatic ControlMaster setup. Add it manually if connections keep re-prompting."
        else
            cat >> "$HOME/.ssh/config" <<EOF

Host $COSMA_ALIAS
    ControlPath ~/.ssh/controlmasters/%r@%h:%p
    ControlMaster auto
    ControlPersist yes
EOF
            echo "Added a ControlMaster block for '$COSMA_ALIAS' (existing settings are unaffected)."
        fi
    fi
else
    echo "This will be added as a new 'Host' entry in your ~/.ssh/config."

    COSMA_ALIAS="$(ask_default "Short alias to use for this connection (e.g. cosma)" "cosma")"
    COSMA_USER="$(ask "Your COSMA username (e.g. dc-xxxx1)")"
    COSMA_HOST="$(ask_default "COSMA login node hostname" "login5.cosma.dur.ac.uk")"

    USE_CUSTOM_KEY="$(ask_default "Do you use a specific SSH key file for COSMA? (y/n)" "n")"
    IDENTITY_LINE=""
    if [ "$USE_CUSTOM_KEY" = "y" ] || [ "$USE_CUSTOM_KEY" = "Y" ]; then
        KEY_PATH="$(ask "Full path to your SSH private key")"
        [ -f "$KEY_PATH" ] || warn "Key file not found at that path — double check it before running mcphost later."
        IDENTITY_LINE="    IdentityFile \"$KEY_PATH\"
    IdentitiesOnly yes"
        chmod 600 "$KEY_PATH" 2>/dev/null || true
    fi

    info "Configuring SSH (~/.ssh/config)"
    mkdir -p "$HOME/.ssh/controlmasters"

    if grep -q "Host $COSMA_ALIAS$" "$HOME/.ssh/config" 2>/dev/null; then
        warn "A 'Host $COSMA_ALIAS' entry already exists in ~/.ssh/config — skipping, edit it manually if needed."
    else
        cat >> "$HOME/.ssh/config" <<EOF

Host $COSMA_ALIAS
    User $COSMA_USER
    HostName $COSMA_HOST
$IDENTITY_LINE
    ControlPath ~/.ssh/controlmasters/%r@%h:%p
    ControlMaster auto
    ControlPersist yes
EOF
        echo "Added Host '$COSMA_ALIAS' to ~/.ssh/config"
    fi
fi

info "Opening an interactive session to authenticate (accept host key / enter password / 2FA as prompted)"
echo "This keeps a background connection alive so later commands won't need to re-authenticate."
ssh "$COSMA_ALIAS" 'echo "SSH connection to COSMA succeeded."; exit'

ssh -O check "$COSMA_ALIAS" >/dev/null 2>&1 || warn "Could not confirm a persistent connection — later steps may prompt again. If a step hangs, run 'ssh $COSMA_ALIAS' manually first."

# ---------------------------------------------------------------------------
# Step 2 — Deploy server code + Python env on COSMA
# ---------------------------------------------------------------------------

info "Setting up the server on COSMA"

REMOTE_HOME="$(ssh -o BatchMode=yes "$COSMA_ALIAS" pwd)"
REMOTE_PROJECT_DIR="$REMOTE_HOME/cosma-mcp"

echo "Remote home directory detected as: $REMOTE_HOME"
ssh -o BatchMode=yes "$COSMA_ALIAS" "mkdir -p '$REMOTE_PROJECT_DIR'"
scp "$SCRIPT_DIR/server.py" "$COSMA_ALIAS:$REMOTE_PROJECT_DIR/server.py"

echo "Setting up Python venv on COSMA (this may take a minute)..."
ssh -o BatchMode=yes "$COSMA_ALIAS" bash -s <<REMOTE_SCRIPT
set -e
cd "$REMOTE_PROJECT_DIR"
if command -v module >/dev/null 2>&1; then
    module load python 2>/dev/null || true
fi
python3 -m venv .venv
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet "mcp[cli]==1.27.0"
python3 -c "from mcp.server.fastmcp import FastMCP" || { echo "FAILED: mcp[cli] did not install correctly on COSMA"; exit 1; }
echo "Remote Python environment ready."
REMOTE_SCRIPT

echo "Testing the server starts cleanly on COSMA..."
if timeout 5 ssh -o BatchMode=yes "$COSMA_ALIAS" "$REMOTE_PROJECT_DIR/.venv/bin/python3" "$REMOTE_PROJECT_DIR/server.py" < /dev/null > /tmp/cosma_mcp_test.log 2>&1; then
    warn "Server exited immediately instead of waiting for input — check /tmp/cosma_mcp_test.log for errors."
else
    echo "Server started and was waiting for input as expected (timed out after 5s, which is correct)."
fi

# ---------------------------------------------------------------------------
# Step 3 — Choose LLM backend
# ---------------------------------------------------------------------------

info "Choose your LLM backend"
echo "  1) Ollama (free, runs locally, needs a capable machine, weaker at complex reasoning)"
echo "  2) Claude via the Anthropic API (paid per use, much stronger, needs an API key)"
echo "  3) Skip — I'll set up my own MCP client separately"
BACKEND="$(ask_default "Choice" "1")"

# ---------------------------------------------------------------------------
# Step 4 — Install Go + mcphost (needed for options 1 and 2)
# ---------------------------------------------------------------------------

if [ "$BACKEND" = "1" ] || [ "$BACKEND" = "2" ]; then
    info "Installing Go + mcphost"

    if ! command_exists go; then
        case "$OS" in
            macos)
                command_exists brew || fail "Homebrew not found. Install it from https://brew.sh first, then re-run this script."
                brew install go
                ;;
            linux)
                if command_exists apt-get; then
                    sudo apt-get update && sudo apt-get install -y golang-go
                elif command_exists dnf; then
                    sudo dnf install -y golang
                else
                    fail "Could not detect a supported package manager. Install Go manually from https://go.dev/dl/ and re-run this script."
                fi
                ;;
            *)
                fail "Unsupported OS. Install Go manually from https://go.dev/dl/ and re-run this script."
                ;;
        esac
    else
        echo "Go already installed ($(go version))."
    fi

    if ! grep -q 'go/bin' "$SHELL_RC" 2>/dev/null; then
        echo 'export PATH="$HOME/go/bin:$PATH"' >> "$SHELL_RC"
    fi
    export PATH="$HOME/go/bin:$PATH"

    if ! command_exists mcphost; then
        go install github.com/mark3labs/mcphost@latest
    else
        echo "mcphost already installed."
    fi
    command_exists mcphost || fail "mcphost installed but not found on PATH — open a new terminal and check 'echo \$PATH' includes \$HOME/go/bin."
fi

# ---------------------------------------------------------------------------
# Step 5a — Ollama setup
# ---------------------------------------------------------------------------

MODEL_STRING=""

if [ "$BACKEND" = "1" ]; then
    info "Installing Ollama"
    if ! command_exists ollama; then
        case "$OS" in
            macos) brew install ollama ;;
            linux) curl -fsSL https://ollama.com/install.sh | sh ;;
            *) fail "Unsupported OS for automatic Ollama install — see https://ollama.com/download" ;;
        esac
    else
        echo "Ollama already installed."
    fi

    if ! pgrep -x "ollama" >/dev/null 2>&1; then
        echo "Starting Ollama in the background..."
        nohup ollama serve > /tmp/ollama.log 2>&1 &
        sleep 2
    fi

    OLLAMA_MODEL="$(ask_default "Which Ollama model? (must support tool calling)" "llama3.1:8b")"
    ollama pull "$OLLAMA_MODEL"
    MODEL_STRING="ollama:$OLLAMA_MODEL"
fi

# ---------------------------------------------------------------------------
# Step 5b — Claude API setup
# ---------------------------------------------------------------------------

if [ "$BACKEND" = "2" ]; then
    info "Claude API setup"
    echo "Get an API key from https://console.anthropic.com if you don't have one."
    API_KEY="$(ask "Paste your Anthropic API key")"
    if ! grep -q "ANTHROPIC_API_KEY" "$SHELL_RC" 2>/dev/null; then
        echo "export ANTHROPIC_API_KEY='$API_KEY'" >> "$SHELL_RC"
    fi
    export ANTHROPIC_API_KEY="$API_KEY"
    CLAUDE_MODEL="$(ask_default "Claude model" "anthropic/claude-3-5-haiku-latest")"
    MODEL_STRING="$CLAUDE_MODEL"
fi

# ---------------------------------------------------------------------------
# Step 6 — Local project + config file
# ---------------------------------------------------------------------------

info "Setting up local project folder ($LOCAL_PROJECT_DIR)"

mkdir -p "$LOCAL_PROJECT_DIR"

cat > "$LOCAL_PROJECT_DIR/mcp-servers.json" <<EOF
{
  "mcpServers": {
    "cosma-status": {
      "command": "ssh",
      "args": [
        "-o", "BatchMode=yes",
        "$COSMA_ALIAS",
        "$REMOTE_PROJECT_DIR/.venv/bin/python3",
        "$REMOTE_PROJECT_DIR/server.py"
      ]
    }
  }
}
EOF

echo "Wrote $LOCAL_PROJECT_DIR/mcp-servers.json"

# ---------------------------------------------------------------------------
# Save a state file so run-cosma-mcp.sh / stop-cosma-mcp.sh don't need to
# ask any of this again
# ---------------------------------------------------------------------------

cat > "$LOCAL_PROJECT_DIR/run-config.env" <<EOF
COSMA_ALIAS="$COSMA_ALIAS"
MODEL_STRING="$MODEL_STRING"
BACKEND="$BACKEND"
EOF
echo "Wrote $LOCAL_PROJECT_DIR/run-config.env"

for helper in run-cosma-mcp.sh stop-cosma-mcp.sh; do
    if [ -f "$SCRIPT_DIR/$helper" ]; then
        cp "$SCRIPT_DIR/$helper" "$LOCAL_PROJECT_DIR/$helper"
        chmod +x "$LOCAL_PROJECT_DIR/$helper"
    fi
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

info "Setup complete"

echo "Open a NEW terminal (so PATH/env changes take effect), then:"
echo
if [ -f "$LOCAL_PROJECT_DIR/run-cosma-mcp.sh" ]; then
    echo "  $LOCAL_PROJECT_DIR/run-cosma-mcp.sh"
elif [ -n "$MODEL_STRING" ]; then
    echo "  cd $LOCAL_PROJECT_DIR"
    echo "  mcphost -m $MODEL_STRING --config mcp-servers.json"
else
    echo "  Configure your own MCP client to use $LOCAL_PROJECT_DIR/mcp-servers.json"
fi
echo
echo "Before each session, if it hangs on connecting, run 'ssh $COSMA_ALIAS' once to"
echo "re-authenticate — the connection can drop after sleep/reboot/network changes."
echo "(run-cosma-mcp.sh does this check for you automatically.)"
echo
echo "stop-cosma-mcp.sh will safely close down the AI instance"

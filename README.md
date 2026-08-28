# COSMA MCP Server

## What this is

A small [MCP](https://modelcontextprotocol.io) server that exposes a fixed
set of **read-only** COSMA diagnostic commands (SLURM job/queue info, node
status, disk quota, who's logged in) as tools that an LLM can call.

```
[Your laptop: LLM + mcphost]  --ssh-->  [COSMA login node: this server]  -->  select commands
```

Each person runs their **own instance**, authenticated as themselves over
SSH.

---

## Files

| File | Purpose |
|---|---|
| `server.py` | The MCP server — all the tools live here. Runs on COSMA. |
| `setup-cosma-mcp.sh` | One-time setup: SSH config, deploys `server.py` to COSMA, installs local tooling. Run once. |
| `run-cosma-mcp.sh` | Starts a chat session. Run this every time. |
| `stop-cosma-mcp.sh` | Stops the local LLM (Ollama), if that's your backend. |

All four files should sit in the same folder before you run setup. The files and setup should be done locally, not on COSMA.

---

## Setup

```bash
chmod +x setup-cosma-mcp.sh
./setup-cosma-mcp.sh
```

You'll be asked for:
- **SSH details** — either an alias you already have configured for COSMA,
  or your username/hostname/key so that the script can add one
- **LLM backend** — Ollama (free, local) or Claude via the
  Anthropic API (paid)

The script then:
1. Confirms your SSH connection works (handles COSMA's 2FA interactively)
2. Copies `server.py` to COSMA and sets up a Python venv there
3. Installs `mcphost` + your chosen backend locally
4. Writes `mcp-servers.json` and `run-config.env` into `~/cosma-mcp/`
5. Copies `run-cosma-mcp.sh` / `stop-cosma-mcp.sh` alongside them

You shouldn't need to run this again unless you change machines or want to
switch backends.

---

## Day-to-day use

**Start a session:**
```bash
~/cosma-mcp/run-cosma-mcp.sh
```
This re-authenticates the SSH connection only if needed, starts Ollama only
if it isn't already running, then drops you into a normal chat prompt. Ask
things like:

```
what are my jobs
is the cluster busy right now
what's my quota
who's logged into login8b
```

**Stop the local LLM** (Ollama backend only — nothing to stop for Claude):
```bash
~/cosma-mcp/stop-cosma-mcp.sh
```

**If a session hangs on connecting:** the SSH master connection has likely
died (sleep, reboot, network change). Run `ssh <your-alias>` once by hand to
re-authenticate, then retry.

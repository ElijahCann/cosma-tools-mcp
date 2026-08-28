"""
COSMA MCP Server
-----------------
Exposes a set of READ-ONLY diagnostic tools for the COSMA HPC cluster
(jobs, nodes, users, quota) to an LLM via the Model Context Protocol.

Design principles:
  - Every tool wraps a fixed, hardcoded command list (no shell=True, no
    string-built commands) so the LLM can never inject arbitrary shell code.
  - Any user-supplied parameter (username, job id, days, partition) is
    validated/clamped BEFORE it touches subprocess.
  - Every command has a timeout so a hung SLURM call can't hang the server.
  - Nothing here submits, cancels, modifies, or deletes anything — strictly
    informational. Do not add mutating commands (scancel, sbatch, etc.)
    without a much stronger review of the safety model.
  - Nothing is account-specific: no hardcoded usernames or filesystem
    paths. Anything user- or mount-dependent is discovered at call time
    (os.environ["USER"], `mount` output) so this runs the same for anyone.
  - One deliberate exception to "everything runs locally": `active_users`
    can SSH to a named sibling login node to run `who` there, since login-
    node identity is inherently node-local (unlike SLURM/Lustre data,
    which is cluster-wide regardless of which node queries it). That SSH
    call still goes through a fixed, hardcoded command list with a
    validated, dot-free node name — the same no-shell-injection guarantee
    as everything else.
"""

import os
import re
import subprocess
import warnings
from collections import Counter

from mcp.server.fastmcp import FastMCP

# Cosmetic: silences a pydantic-settings warning seen on newer Python versions.
warnings.filterwarnings("ignore", category=UserWarning, module="pydantic_settings")

mcp = FastMCP("COSMA")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_USERNAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")
_PARTITION_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")
_STATE_RE = re.compile(r"^[A-Z_]{1,20}$")
# Deliberately no dots allowed — this keeps validated node names to short
# internal hostnames (e.g. "login8b") and blocks anything that looks like
# an external FQDN or IP address from ever reaching the `ssh` call below.
_NODE_RE = re.compile(r"^[a-zA-Z0-9-]{1,20}$")
_PLACEHOLDER_USERNAMES = {
    "your_username", "username", "user", "me", "self", "myself",
    "current_user", "currentuser", "your_user", "USER", "$user", "none", "null",
}

_PLACEHOLDER_NODES = {
        "current_node", "currentnode", "this_node", "thisnode", "this", "here",
        "local", "localhost", "node", "your_node", "none", "null",
        }


def _run(cmd: list[str], timeout: int = 10, max_lines: int = 100) -> str:
    """
    Run a fixed command list and return its stdout, or a readable error
    string. Truncates very long output to `max_lines` as a hard safety
    net so a single call can't flood the model's context — but tools with
    a `limit`/`state` parameter should rely on THOSE to keep results
    small in the first place; this truncation is a last resort, not the
    primary way to control output size.
    """
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.returncode != 0:
            return f"Error: {result.stderr.strip() or 'command failed with no stderr output'}"
        out = result.stdout.strip()
        if not out:
            return "(no output)"
        lines = out.split("\n")
        if len(lines) > max_lines:
            kept = "\n".join(lines[:max_lines])
            return f"{kept}\n... ({len(lines) - max_lines} more lines omitted — narrow with a filter argument)"
        return out
    except subprocess.TimeoutExpired:
        return "Error: command timed out"
    except FileNotFoundError:
        return f"Error: command not found ({cmd[0]})"


def _validate_username(username: str) -> str | None:
    """Return the username if it's a safe, non-placeholder identifier, else None."""
    if not username or not _USERNAME_RE.match(username):
        return None
    if username.strip().lower() in {p.lower() for p in _PLACEHOLDER_USERNAMES}:
        return None
    return username


def _validate_partition(partition: str) -> str | None:
    """Return the partition name if it's a safe identifier, else None."""
    if partition and _PARTITION_RE.match(partition):
        return partition
    return None


def _validate_state(state: str) -> str | None:
    """Return the SLURM job state if it's a safe, well-formed value, else None."""
    if state and _STATE_RE.match(state.upper()):
        return state.upper()
    return None


def _validate_node(node: str) -> str | None:
    """Return the node hostname if it's a safe, non-FQDN identifier, else None."""
    if not node or not _NODE_RE.match(node):
        return None
    if node.strip.lower() in {p.lower() for p in _PLACEHOLDER_NODES}:
        return None
    return node

def _limit_lines(text: str, limit: int | None) -> str:
    """Truncate already-formatted output to the first `limit` lines, noting how many were cut."""
    if limit is None or limit <= 0:
        return text
    lines = text.split("\n")
    if len(lines) <= limit:
        return text
    return "\n".join(lines[:limit]) + f"\n... ({len(lines) - limit} more lines omitted, showing first {limit})"


def _get_lustre_mounts() -> list[str]:
    """Discover currently mounted Lustre filesystems on this node (e.g. /cosma5, /cosma7)."""
    try:
        result = subprocess.run(["mount"], capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    mounts = []
    for line in result.stdout.split("\n"):
        if " type lustre " in line:
            parts = line.split(" on ")
            if len(parts) > 1:
                mount_point = parts[1].split(" type")[0].strip()
                mounts.append(mount_point)
    return mounts


# ---------------------------------------------------------------------------
# Job & queue info
# ---------------------------------------------------------------------------

@mcp.tool()
def my_active_jobs(state: str | None = None, limit: int = 50) -> str:
    """
    List the calling user's own currently running or queued SLURM jobs.
    Use this for any "my jobs" / "what am I running" style question —
    it takes no required arguments and always resolves to the current
    user automatically, so there is nothing to guess.

    Optionally filter to a specific `state` (e.g. "RUNNING", "PENDING")
    to narrow results before they're returned — prefer this over
    requesting everything and filtering yourself. `limit` caps the number
    of rows returned (default 50); raise it only if you specifically need
    more and expect the count to still be manageable.
    """
    cmd = ["squeue", "--noheader", "-o", "%i %j %u %T %M %D", "-u", os.environ.get("USER", "")]
    if state is not None:
        safe_state = _validate_state(state)
        if safe_state is None:
            return "Error: invalid state format (expected e.g. RUNNING, PENDING, COMPLETED)"
        cmd += ["--states", safe_state]
    return _limit_lines(_run(cmd, max_lines=500), limit)


@mcp.tool()
def all_active_jobs(state: str | None = None, limit: int = 30) -> str:
    """
    List currently running or queued SLURM jobs cluster-wide, across all
    users. Use this for "how busy is the cluster" / "what's everyone
    running" style questions. For a single user's jobs, use
    `my_active_jobs` (calling user) or `active_jobs` (named user) instead.
    Columns returned (space-separated, no header): JobID, JobName, User,
    State, ElapsedTime, NumNodes.

    This can be a LARGE list on a busy cluster — always prefer filtering
    by `state` (e.g. "RUNNING") and keep `limit` low (default 30) rather
    than requesting the full unfiltered list. If you actually need
    aggregate counts rather than individual rows, use `queue_summary`
    instead — it's far more compact.
    """
    cmd = ["squeue", "--noheader", "-o", "%i %j %u %T %M %D"]
    if state is not None:
        safe_state = _validate_state(state)
        if safe_state is None:
            return "Error: invalid state format (expected e.g. RUNNING, PENDING, COMPLETED)"
        cmd += ["--states", safe_state]
    return _limit_lines(_run(cmd, max_lines=500), limit)


@mcp.tool()
def active_jobs(username: str, state: str | None = None, limit: int = 50) -> str:
    """
    List currently running or queued SLURM jobs for a SPECIFIC named user.
    `username` is required — this tool is for looking up someone else's
    jobs by name. For the calling user's own jobs, use `my_active_jobs`
    instead (no arguments needed). Never guess a username here; if unsure,
    call `whoami` first. Columns returned (space-separated, no header):
    JobID, JobName, User, State, ElapsedTime, NumNodes.

    Optionally filter to a specific `state` and/or cap results with
    `limit` (default 50) — prefer narrowing the query over requesting
    everything.
    """
    safe_user = _validate_username(username)
    if safe_user is None:
        return ("Error: invalid or missing username. For the calling user's own "
                 "jobs, use `my_active_jobs` instead — it needs no username.")
    cmd = ["squeue", "--noheader", "-o", "%i %j %u %T %M %D", "-u", safe_user]
    if state is not None:
        safe_state = _validate_state(state)
        if safe_state is None:
            return "Error: invalid state format (expected e.g. RUNNING, PENDING, COMPLETED)"
        cmd += ["--states", safe_state]
    return _limit_lines(_run(cmd, max_lines=500), limit)


@mcp.tool()
def job_history(days: int = 1, limit: int = 50) -> str:
    """
    List completed/finished SLURM jobs from the last `days` days (max 30,
    default 1). Uses `-X` to show one summary line per job rather than
    every job step, keeping output compact. Columns returned
    (space-separated, no header): JobID, JobName, State, Elapsed, ExitCode.
    Only shows the calling user's own job history (sacct's default scope).

    `limit` caps rows returned (default 50) — prefer a smaller `days`
    window over raising `limit` if you just need recent activity.
    """
    days = max(1, min(days, 30))
    return _limit_lines(_run(["sacct", "-X", "--noheader",
                               "-o", "JobID,JobName,State,Elapsed,ExitCode",
                               "--starttime", f"now-{days}days"], max_lines=500), limit)


@mcp.tool()
def job_details(job_id: str) -> str:
    """
    Full detail for a single SLURM job (requested resources, node list,
    state, timing, etc.) given its numeric job ID.
    """
    if not job_id.isdigit():
        return "Error: job_id must be a numeric SLURM job ID"
    return _run(["scontrol", "show", "job", job_id])


@mcp.tool()
def queue_summary() -> str:
    """
    Count of currently queued/running jobs grouped by partition and state
    (e.g. how many RUNNING vs PENDING jobs are in each partition). Useful
    for a quick "how busy is the cluster" overview.
    """
    result = subprocess.run(["squeue", "--noheader", "-o", "%P %T"],
                             capture_output=True, text=True, timeout=10)
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    lines = [l for l in result.stdout.strip().split("\n") if l]
    if not lines:
        return "No jobs currently in the queue"
    counts = Counter(lines)
    return "\n".join(f"{k}: {v}" for k, v in sorted(counts.items()))


# ---------------------------------------------------------------------------
# Node & partition status
# ---------------------------------------------------------------------------

@mcp.tool()
def node_status() -> str:
    """
    Summary of COSMA partition and node availability (partition name, node
    states, node counts). Standard `sinfo` output.
    """
    return _run(["sinfo"])


@mcp.tool()
def node_detail(partition: str | None = None, limit: int = 50) -> str:
    """
    Per-node resource detail. Columns returned (space-separated, no header):
    NodeName, CPUs(Allocated/Idle/Other/Total), TotalMemoryMB, FreeMemoryMB,
    State. Optionally scope to a single partition — strongly recommended
    on large clusters, since an unscoped call returns one line per node
    cluster-wide. `limit` caps rows returned (default 50) as a backstop
    if you don't have a partition name to narrow by.
    """
    cmd = ["sinfo", "-N", "-o", "%N %C %m %e %T"]
    if partition is not None:
        safe_partition = _validate_partition(partition)
        if safe_partition is None:
            return "Error: invalid partition name format"
        cmd += ["-p", safe_partition]
    return _limit_lines(_run(cmd, max_lines=500), limit)


@mcp.tool()
def partition_details(partition: str | None = None) -> str:
    """
    Detailed configuration for cluster partitions (limits, allowed groups,
    time limits, node ranges). If `partition` is given, restricts to that
    partition only; otherwise shows all.
    """
    cmd = ["scontrol", "show", "partition"]
    if partition is not None:
        safe_partition = _validate_partition(partition)
        if safe_partition is None:
            return "Error: invalid partition name format"
        cmd[-1] = f"partition={safe_partition}"
    return _run(cmd)


# ---------------------------------------------------------------------------
# Users & fair-share
# ---------------------------------------------------------------------------

@mcp.tool()
def whoami() -> str:
    """
    Return the actual COSMA username of the person this server is running
    for. Call this FIRST whenever a question is about "me" / "my jobs" /
    "my quota" and you need a real username to pass to another tool.
    Never guess, invent, or use a placeholder username (e.g. "me",
    "your_username", "user") — always resolve it via this tool instead.
    """
    user = os.environ.get("USER", "")
    return user if user else "Error: could not determine current user from environment"


@mcp.tool()
def current_node() -> str:
    """
    Return the hostname of the SPECIFIC physical login node this server
    process is currently running on (e.g. "login5c", not just "login5" —
    COSMA's login alias can route each connection to a different physical
    node). Almost all other tools (squeue/sinfo/sacct/sshare) query the
    shared cluster-wide SLURM controller, so it genuinely doesn't matter
    which node they run from — but `active_users` (who's logged in) is
    node-local. Call this if a question depends on knowing "this node"
    specifically, or before assuming which node a plain `active_users`
    call is reporting on.
    """
    return _run(["hostname"])


@mcp.tool()
def active_users(node: str | None = None) -> str:
    """
    List users currently logged into a COSMA login node (login time and
    originating IP). This is node-local information — unlike jobs/nodes/
    quota tools, it only reflects whichever physical login node the
    command actually runs on.

    For "this node" / "who's logged in" style questions: OMIT `node` entirely
    - it automatically checks the node this server is running on. Do not call
    `current_node` first for this case; it's unnecessary.

    Only pass `node` (e.g. "login8b") when the question names a SPECIFIC other
    node you want to check instead - this connects to that node over an internal
    SSH hop. Requires that COSMA login nodes can reach each other over ssh without
    an interactive prompt; if they can't, this returns a clear SSH error rather 
    than hanging (it has its own short timeout)
    """
    if node is None:
        return _run(["who"])
    safe_node = _validate_node(node)
    if safe_node is None:
        return "Error: invalid or placeholder node name. For 'this node' / 'the\
                \"current node\"', OMIT the `node` parameter entirely - do not\
                pass a tool name or generic word. Only pass `node` when the\
                question names a SPECIFIC other node (e.g. 'login8b')"
    return _run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", safe_node, "who"], timeout=12)


@mcp.tool()
def active_job_users() -> str:
    """
    List the distinct usernames who currently have a running or queued
    SLURM job anywhere on the cluster (deduplicated, one per line).
    """
    result = subprocess.run(["squeue", "--noheader", "-o", "%u"],
                             capture_output=True, text=True, timeout=10)
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    users = sorted(set(result.stdout.split()))
    return "\n".join(users) if users else "No users currently have active jobs"


@mcp.tool()
def my_fairshare(username: str | None = None) -> str:
    """
    A user's SLURM fair-share/priority standing, as clean labelled
    key-value pairs. For "my fair-share" questions, simply omit `username`
    — it resolves automatically to the calling user. Never pass a guessed
    or placeholder username; if you need it explicitly for some reason,
    call `whoami` first. FairShare is a score between 0 and 1 (closer to 1 =
    higher scheduling priority relative to your allocated share; closer to
    0 = you've used more than your share recently, so you're deprioritised).

    Uses sshare's pipe-delimited output (-P) rather than its whitespace
    table, since blank fields in the raw table can silently misalign a
    naive column split and produce nonsense values. If a field shows
    "(not set for this association)", report it as missing/unavailable —
    never invent or estimate a number to fill it in.
    """
    user = username or os.environ.get("USER", "")
    safe_user = _validate_username(user)
    if safe_user is None:
        return "Error: no valid username available — pass `username` explicitly"

    result = subprocess.run(
        ["sshare", "-u", safe_user, "-P", "--noheader",
         "-o", "User,RawShares,NormShares,RawUsage,EffectvUsage,FairShare"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    raw_lines = [l for l in result.stdout.strip().split("\n") if l.strip()]
    if not raw_lines:
        return "Error: no fair-share data returned for this user"

    labels = ["User", "Raw Shares", "Normalized Shares", "Raw Usage (CPU-seconds)",
              "Effective Usage", "Fair-share Score (0-1)"]

    # sshare can return multiple association rows (e.g. one per SLURM account
    # the user belongs to, or a parent/rollup row) — blindly taking the first
    # line can grab a row where most fields are blank. Prefer rows whose
    # User column actually matches the requested user.
    matching = [l for l in raw_lines if l.split("|")[0].strip() == safe_user]
    target_lines = matching if matching else raw_lines

    reports = []
    for line in target_lines:
        fields = line.split("|")
        if len(fields) != len(labels):
            reports.append(f"(unexpected format, raw: {line})")
            continue
        pairs = list(zip(labels, fields))
        text = "\n".join(f"{l}: {v if v.strip() else '(not set for this association)'}" for l, v in pairs)
        reports.append(text)

    if not matching:
        reports.insert(0, "Note: no row explicitly matched this username — showing all rows returned instead.")

    return "\n\n".join(reports)


# ---------------------------------------------------------------------------
# Storage & quota
# ---------------------------------------------------------------------------

@mcp.tool()
def disk_quota(username: str | None = None) -> str:
    """
    A user's disk quota usage across every Lustre filesystem mounted on
    this login node, plus home directory quota if configured. For "my
    quota" questions, simply omit `username` — it resolves automatically
    to the calling user. Never pass a guessed or placeholder username; if
    you need it explicitly for some reason, call `whoami` first. Does not assume
    any specific COSMA mount (cosma5/6/7/8 etc.) — mount points are
    discovered dynamically each call, so this works the same for any user
    regardless of which filesystems their account has quota on.
    """
    user = username or os.environ.get("USER", "")
    safe_user = _validate_username(user)
    if safe_user is None:
        return "Error: no valid username available — pass `username` explicitly"

    mounts = _get_lustre_mounts()
    labels = ["Filesystem", "Space Used (KB)", "Space Soft Limit (KB)",
              "Space Hard Limit (KB)", "Space Grace", "Files Used",
              "Files Soft Limit", "Files Hard Limit", "Files Grace"]
    report = []

    for mount in mounts:
        result = subprocess.run(["lfs", "quota", "-q", "-u", safe_user, mount],
                                 capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            continue  # user has no quota/access on this particular mount — skip silently
        lines = [l for l in result.stdout.strip().split("\n") if l.strip()]
        if not lines:
            continue
        fields = lines[0].split()
        if len(fields) != len(labels):
            report.append(f"--- {mount} ---\n(unexpected format: {lines[0]})")
            continue
        report.append(f"--- {mount} ---\n" + "\n".join(f"{l}: {v}" for l, v in zip(labels, fields)))

    # Home directory is typically NFS, not Lustre, so check separately via the standard `quota` command
    home_result = subprocess.run(["quota", "-u", safe_user], capture_output=True, text=True, timeout=10)
    if home_result.returncode == 0 and home_result.stdout.strip():
        report.append("--- Home directory ---\n" + home_result.stdout.strip())

    return "\n\n".join(report) if report else "No quota data found for this user on any mounted filesystem"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run(transport="stdio")

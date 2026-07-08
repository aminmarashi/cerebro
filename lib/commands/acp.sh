# cerebro lib: commands/acp
# subcommands: acp (external) + acp-mint / acp-set-foreign (internal, called by
# the python ACP server via `cerebro <name>`).
# Sourced by bin/cerebro; not meant to be executed directly.

# `cerebro acp` is the ACP (Agent Client Protocol) front-end for editors like
# Zed. It is a THIN PROXY (lib/python/acp_server.py, on the official
# agent-client-protocol Python SDK): per ACP session it mints a cerebro session,
# spawns a per-session upstream ACP child (`opencode acp` or
# claude-agent-acp), injects CEREBRO_SESSION_ID, pins the restricted
# cerebro-orchestrator agent, and relays JSON-RPC unchanged with sessionId
# remap. The upstream child owns the entire ACP capability surface (images,
# @-mentions, thinking, elicitation, terminals, MCP, permissions, edit review,
# model/mode/effort pickers, session load/resume/fork/list, usage); cerebro owns
# session minting + env injection + agent pinning + sessionId remap + metadata.
# See docs/USAGE.md (ACP) and the plan for the pin mechanism details.

# ACP is editor-driven and non-interactive: stdin/stdout are the JSON-RPC pipe,
# not a terminal. So cmd_acp deliberately does NOT call require_interactive.

# acp_require_python_deps -- locate a Python >=3.10 for the ACP SDK
# (agent-client-protocol needs >=3.10,<3.15), preferring Homebrew python3
# (/opt/homebrew/bin/python3) since macOS system python3 is 3.9, and ensure the
# SDK is importable (auto-installing to the user site if missing). For the
# claude backend, also require Node >=22 + npx (claude-agent-acp runs on the
# Claude Agent SDK via `npx -y`). Sets CEREBRO_ACP_PYTHON (exported).
acp_require_python_deps() {
  local py="" v major minor
  for cand in /opt/homebrew/bin/python3 python3; do
    command -v "$cand" >/dev/null 2>&1 || continue
    v="$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || continue
    if [[ "$v" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
      major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
      if (( major == 3 && minor >= 10 )) || (( major > 3 )); then
        py="$cand"; break
      fi
    fi
  done
  [[ -n "$py" ]] || die "cerebro acp needs Python >=3.10 (for the agent-client-protocol SDK). None found on PATH. Install with: brew install python"
  export CEREBRO_ACP_PYTHON="$py"
  if ! "$py" -c 'import acp' >/dev/null 2>&1; then
    warn "cerebro acp: installing agent-client-protocol (Python SDK) for $py ..."
    if ! "$py" -m pip install --user --break-system-packages agent-client-protocol >/dev/null 2>&1; then
      die "cerebro acp: failed to install agent-client-protocol. Install manually:
    $py -m pip install --user --break-system-packages agent-client-protocol"
    fi
  fi
  if [[ "$(current_backend)" == "claude" ]]; then
    command -v npx >/dev/null 2>&1 \
      || die "cerebro acp (claude backend) needs Node/npx on PATH (for @agentclientprotocol/claude-agent-acp). Install Node >=22 (e.g. brew install node)."
    local node_major
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" \
      || die "cerebro acp (claude backend): cannot determine Node version (needs >=22)."
    (( node_major >= 22 )) \
      || die "cerebro acp (claude backend) needs Node >=22 (found $node_major). Upgrade Node (e.g. brew upgrade node)."
  fi
}

# cmd_acp -- start the cerebro ACP proxy server over stdio. Materialise the home
# tree once (so cerebro subcommands the orchestrator spawns find their agents),
# build + export the upstream child spec (JSON: argv + pin + env, backend-fixed),
# then exec the python server. The server reads CEREBRO_ACP_CHILD_SPEC and
# shells out to `cerebro acp-mint` / `cerebro acp-set-foreign` per session.
cmd_acp() {
  require_deps
  acp_require_python_deps
  materialise_home
  export CEREBRO_ACP_CHILD_SPEC="$(backend_acp_child_spec)"
  exec "$CEREBRO_ACP_PYTHON" "$CEREBRO_LIB_DIR/python/acp_server.py"
}

# cmd_acp_mint (internal) -- mint a cerebro session for one ACP session/new and
# prepare its cerebro-owned ACP project dir, then print the sid on stdout (the
# python server parses stdout, so this must emit only the sid). The project dir
# ($CEREBRO_HOME/acp/<sid>) becomes the upstream child's SESSION cwd: it carries
# the restricted cerebro-orchestrator agent (both .opencode/agent and
# .claude/agents copies, so either backend can be selected) plus cerebro's
# opencode.json, so opencode acp / claude-agent-acp discover the agent from the
# session cwd (their load path, verified) and surface it as a selectable
# mode/agent option. The user's repo is NOT written to -- it is passed as an ACP
# additional_directory by the proxy. Lightweight: no materialise_home (cmd_acp
# already did it once at server start); just session + project dirs + metadata.
cmd_acp_mint() {
  local sid sess_dir ts proj
  sid="$(mint_uuid)"
  sess_dir="$CEREBRO_HOME/sessions/$sid"
  proj="$CEREBRO_HOME/acp/$sid"
  mkdir -p "$sess_dir/plans" "$sess_dir/children" \
           "$proj/.opencode/agent" "$proj/.claude/agents" \
    || die "acp-mint: cannot create session dirs under $CEREBRO_HOME"
  : > "$sess_dir/transcript.jsonl"
  ts="$(ts_iso)"
  write_metadata_new "$sess_dir" "$sid" "$ts"
  write_if_changed "$proj/.opencode/opencode.json" "$(cerebro_opencode_json)"
  write_if_changed "$proj/.opencode/agent/cerebro-orchestrator.md" "$(orchestrator_agent_file)"
  write_if_changed "$proj/.claude/agents/cerebro-orchestrator.md" "$(claude_orchestrator_agent_file)"
  printf '%s\n' "$sid"
}

# cmd_acp_set_foreign <sid> <foreign-id> (internal) -- record the upstream
# child's session id (opencode's own session id / claude's session id) into the
# cerebro session metadata, so ACP session/load + session/resume can reopen the
# same upstream conversation. Called by the python server after new_session /
# load_session / resume_session.
cmd_acp_set_foreign() {
  local sid="$1" foreign="$2" sess_dir
  sess_dir="$CEREBRO_HOME/sessions/$sid"
  [[ -d "$sess_dir" ]] || die "acp-set-foreign: no such session: $sid"
  set_metadata_foreign "$sess_dir" "$foreign"
}
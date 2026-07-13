# cerebro lib: backend-claude
# The claude backend: drives the orchestrator and editing children through the
# claude CLI. Children run as `claude -p --output-format stream-json
# --append-system-prompt <role-prompt> --resume <id>`, and the orchestrator runs
# as `claude --session-id <sid> --append-system-prompt <prompt>`. Role prompts
# are composed inline by child_sys_prompt (not via agent files), and the tool
# surface is pinned by --allowedTools. Session binding uses CEREBRO_SESSION_ID
# plus a UserPromptSubmit hook that writes the current-session symlink. Pair
# mode drives the child through claude's stream-json stdin.
# Sourced by bin/cerebro via backend.sh; not meant to be executed directly.

# backend_claude_endpoint_env [model] -- when CEREBRO_CLAUDE_BASE_URL is set,
# export the Anthropic gateway env vars into this process so every spawned
# `claude` (orchestrator, observer, children) talks to the custom endpoint
# instead of the claude.ai subscription. Unsets ANTHROPIC_API_KEY so a logged-in
# subscription can't override the token, and pins
# ANTHROPIC_MODEL/ANTHROPIC_DEFAULT_HAIKU_MODEL to the effective model so the
# orchestrator (which has no --model flag of its own) also hits the configured
# endpoint. <model> (defaults to CEREBRO_MODEL) is the model THIS run will use:
# editing children and the orchestrator pass CEREBRO_MODEL; a reviewer child
# (CEREBRO_REVIEW_BACKEND=claude) passes CEREBRO_REVIEW_MODEL so the gateway
# serves the review model, not the editing model. A subcommand's --model flag
# overrides either default per call, so the gateway always serves the model the
# caller selected. Idempotent; a no-op when CEREBRO_CLAUDE_BASE_URL is unset
# (the default subscription path, unchanged -- the --model flag alone selects
# the model).
backend_claude_endpoint_env() {
  [[ -n "$CEREBRO_CLAUDE_BASE_URL" ]] || return 0
  local model="${1:-$CEREBRO_MODEL}"
  export ANTHROPIC_BASE_URL="$CEREBRO_CLAUDE_BASE_URL"
  export ANTHROPIC_AUTH_TOKEN="${CEREBRO_CLAUDE_AUTH_TOKEN:-ollama}"
  export ANTHROPIC_MODEL="$model"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
  unset ANTHROPIC_API_KEY
  # Claude Code can't infer the context window for an unrecognized custom model
  # id and falls back to 200k; if the catalog declares contextTokens for this
  # model, export it as the auto-compact window so compaction doesn't fire at
  # the 200k default on a larger-window model. See `cerebro model-env` and
  # models_context_tokens. (Claude Code may cap this at its assumed window for
  # the id; `cerebro model-env --no-compact` is the escape hatch.)
  local ctx; ctx="$(models_context_tokens "$model")"
  [[ -n "$ctx" ]] && export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$ctx"
}

# The --allowedTools list for a claude child of the given role. The mutating
# children (execute / apply-review / doc-write) and the capable verify child
# (which starts servers and drives a browser) get the full editing surface; the
# read-only reviewer (review / audit / improve, reached only when
# CEREBRO_REVIEW_BACKEND=claude) is clamped to Read/Grep/Glob plus a read-only
# Bash allow-list mirroring the opencode reviewer agent -- no Edit/Write/Web or
# Playwright.
backend_claude_child_allowed_tools() {
  case "$1" in
    execute|apply-review|doc-write|verify)
      printf 'Read Edit Write Bash Grep Glob WebSearch WebFetch mcp__playwright__*' ;;
    review|audit|improve)
      printf 'Read Grep Glob Bash(git diff:*) Bash(git show:*) Bash(git log:*) Bash(git status:*) Bash(git rev-parse:*) Bash(git merge-base:*) Bash(git blame:*) Bash(git ls-files:*) Bash(git cat-file:*) Bash(grep:*) Bash(rg:*) Bash(cat:*) Bash(head:*) Bash(tail:*) Bash(sed -n:*) Bash(find:*) Bash(ls:*) Bash(wc:*) Bash(jq:*) Bash(test:*)' ;;
    *) die "backend_claude_child_allowed_tools: unknown role: $1" ;;
  esac
}

# backend_claude_child_run_opts <agent> <resume-id> <model> -- build the claude
# flag array for a child into the caller-scoped CHILD_RUN_OPTS. <agent> here
# is the role label (execute|apply-review|doc-write); the role prompt is the
# static shipped prompt, written to a temporary file and loaded via
# --append-system-prompt-file so the body is cacheable. We add --resume when a
# prior id is present.
backend_claude_child_run_opts() {
  local role="$1" resume="${2:-}" model="${3:-}"
  local sys_prompt; sys_prompt="$(child_sys_prompt "$role")"
  local prompt_file
  prompt_file="$(mktemp -t cerebro-claude-child-XXXXXX.md)"
  printf '%s' "$sys_prompt" > "$prompt_file"
  CHILD_RUN_OPTS=(-p --permission-mode bypassPermissions
    --allowedTools "$(backend_claude_child_allowed_tools "$role")"
    --output-format stream-json --verbose
    --append-system-prompt-file "$prompt_file")
  [[ -n "$model" ]] && CHILD_RUN_OPTS+=(--model "$model")
  [[ -n "$resume" ]] && CHILD_RUN_OPTS+=(--resume "$resume")
}

# backend_claude_child_run <pair> <cwd> <prompt> <agent> <resume-id> <child_log>
#   <msg_capture> <id_capture> <store_file> <ckey> [model] -- run one attempt of
# a claude child and return its exit code. Unpaired: pipe the prompt to claude
# on stdin, tee the stream-json to the child log, parse via parse_stream.py.
# Paired: hand off to backend_claude_pair_run, which drives the child through
# claude's stream-json input so it can be watched and steered live. <agent> is
# the role label; the role prompt + tool surface are built from it.
backend_claude_child_run() {
  local pair="$1" cwd="$2" prompt="$3" role="$4" resume="$5" \
        child_log="$6" msg_capture="$7" id_capture="$8" store_file="$9" ckey="${10}"
  local model="${11:-$CEREBRO_MODEL}"

  backend_claude_endpoint_env "$model"

  if (( pair )); then
    backend_claude_pair_run "$cwd" "$prompt" "$role" "$resume" \
      "$child_log" "$msg_capture" "$id_capture" "$store_file" "$ckey" "$model"
    return $?
  fi

  backend_claude_child_run_opts "$role" "$resume" "$model"
  local err_log="${child_log%.log}.err.log"
  ( cd "$cwd" && printf '%s' "$prompt" \
      | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
        "${TIMEOUT_CMD[@]}" "$CEREBRO_CLAUDE_CMD" "${CHILD_RUN_OPTS[@]}" 2>"$err_log" \
      | tee "$child_log" \
      | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" \
          "$msg_capture" "$id_capture" "$store_file" "$ckey" )
  return $?
}

# backend_claude_child_agent_name <role> -- under the claude backend the "agent
# name" for a child is the role label itself; the prompt is composed inline and
# passed via --append-system-prompt, not via an agent file.
backend_claude_child_agent_name() {
  case "$1" in
    execute|apply-review|doc-write|review|audit|verify|improve) printf '%s\n' "$1" ;;
    *) die "backend_claude_child_agent_name: unknown role: $1" ;;
  esac
}

# backend_claude_child_provider <role> -- the provider string written to the
# child session store.
backend_claude_child_provider() { printf 'claude\n'; }

# backend_claude_answerable_provider <role> -- the provider:role pattern
# `cerebro answer` accepts for a claude child.
backend_claude_answerable_provider() {
  case "$1" in
    execute|apply-review|doc-write|verify) printf 'claude:%s\n' "$1" ;;
    *) die "backend_claude_answerable_provider: unknown role: $1" ;;
  esac
}

# backend_claude_materialise_extras -- write the claude-only home files: the
# UserPromptSubmit hook, the .claude/settings.local.json that registers it, the
# CLAUDE.md bootstrap template, and the cerebro-orchestrator main-thread agent
# under .claude/agents/ (used by `cerebro acp` to pin the restricted
# orchestrator through claude-agent-acp's `agent` config option). Called after
# the shared materialise_home (which writes the opencode tree the reviewer
# needs regardless of backend).
backend_claude_materialise_extras() {
  mkdir -p "$CEREBRO_HOME/.claude" "$CEREBRO_HOME/.claude/agents"
  write_if_changed "$CEREBRO_HOME/hook.sh" "$(cerebro_hook_script)"
  chmod +x "$CEREBRO_HOME/hook.sh"
  local settings; settings="$(cerebro_settings_json "$CEREBRO_HOME/hook.sh")"
  write_if_changed "$CEREBRO_HOME/.claude/settings.local.json" "$settings"
  # The claude backend still ships a CLAUDE.md bootstrap template for new repos.
  write_if_missing "$CEREBRO_HOME/templates/CLAUDE.md" "$(cerebro_default_claude_md)"
  # The ACP-path orchestrator agent. The TUI path does not use it (it pins via
  # --allowedTools on the CLI), but writing it here keeps the agent on disk for
  # `cerebro acp` and any direct `claude --agent cerebro-orchestrator` use.
  write_if_changed "$CEREBRO_HOME/.claude/agents/cerebro-orchestrator.md" \
    "$(claude_orchestrator_agent_file)"
}

# backend_claude_launch_orchestrator <sess_dir> <prompt-file> -- exec the
# interactive claude orchestrator. <prompt-file> is the path to the static
# system-prompt.md (written by materialise_home), loaded via
# --append-system-prompt-file so the large static body is byte-for-byte stable
# and can be prompt-cached. The tool allow-list is pinned by --allowedTools.
# The cerebro session id is passed via --session-id so claude's own session
# matches it; the hook writes the current-session symlink on first prompt so
# bare `cerebro --resume` finds its way home.
backend_claude_launch_orchestrator() {
  local sess_dir="$1" prompt_file="$2"
  backend_claude_endpoint_env
  local sid; sid="$(basename "$sess_dir")"
  # Write is granted ONLY under this session's /tmp scratch dir: the
  # orchestrator has no repo-mutation tools, but it needs a non-Bash channel to
  # land large plan bodies on disk fast. It writes a plan to
  # /tmp/cerebro-<session-id>/<name>.md with Write, then ingests it via
  # `cerebro plan --from-file` -- see lib/commands/plan.sh. Piping a multi-KB
  # plan through the Bash command string is super-linear in size and trips the
  # 120s/300s Bash-tool timeout; a scoped Write sidesteps that without giving
  # the orchestrator any path into the repo. Scoping by <session-id> means
  # concurrent cerebro sessions have disjoint scratch dirs and can't clobber
  # each other's staging files.
  exec "$CEREBRO_CLAUDE_CMD" \
    --session-id "$sid" \
    --append-system-prompt-file "$prompt_file" \
    --permission-mode bypassPermissions \
    --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__* Write(/tmp/cerebro-$sid/**)"
}

# backend_claude_launch_observer <sess_dir> <prompt> <target> -- exec the
# interactive claude observer. When <target> is given, seed an interactive
# first turn so the observer starts narrating immediately. The observer prompt
# is short and composed inline; there is no separate observer file.
backend_claude_launch_observer() {
  local sess_dir="$1" prompt="$2" target="$3"
  backend_claude_endpoint_env
  local sid; sid="$(basename "$sess_dir")"
  local allowed="Bash(cerebro observe:*) Bash(cerebro steer:*) Bash(cerebro restart:*) Bash(cerebro status:*) Bash(cerebro list:*) Bash(cerebro recall:*) Bash(cerebro spec:*) Bash(cerebro learnings:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
  if [[ -n "$target" ]]; then
    exec "$CEREBRO_CLAUDE_CMD" \
      --session-id "$sid" \
      --append-system-prompt "$prompt" \
      --permission-mode bypassPermissions \
      "Start observing session $target now: run \`cerebro observe $target\`, narrate what you see, and keep looping until its children are done or I stop you." \
      --allowedTools "$allowed"
  else
    exec "$CEREBRO_CLAUDE_CMD" \
      --session-id "$sid" \
      --append-system-prompt "$prompt" \
      --permission-mode bypassPermissions \
      --allowedTools "$allowed"
  fi
}

# backend_claude_resume_orchestrator <sess_dir> <foreign-id> <prompt-file> --
# exec the resumed claude orchestrator. claude uses the cerebro session id
# directly as its own session id (no foreign-id mapping needed), so <foreign-id>
# is the same id. When empty (shouldn't happen for claude since it always has
# one), fall back to claude's own --resume picker.
backend_claude_resume_orchestrator() {
  local sess_dir="$1" id="$2" prompt_file="$3"
  backend_claude_endpoint_env
  local sid; sid="$(basename "$sess_dir")"
  if [[ -n "$id" ]]; then
    exec "$CEREBRO_CLAUDE_CMD" \
      --resume "$id" \
      --append-system-prompt-file "$prompt_file" \
      --permission-mode bypassPermissions \
      --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__* Write(/tmp/cerebro-$sid/**)"
  else
    # Bare resume: claude shows its own picker. The hook writes the
    # current-session symlink as soon as the user submits their first prompt.
    exec "$CEREBRO_CLAUDE_CMD" \
      --resume \
      --append-system-prompt-file "$prompt_file" \
      --permission-mode bypassPermissions \
      --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__* Write(/tmp/cerebro-$sid/**)"
  fi
}

# ----- pair mode (claude stream-json stdin) --------------------------------

# backend_claude_pair_begin <role> <repo> <branch> <child_log> [resume-id] --
# prepare a fresh or resumed paired claude child. Sets caller-scoped: PAIR_SID,
# PAIR_OPTS (extra claude flags -- stream-json input, plus a pinned --session-id
# for a fresh run), PAIR_FIFO, PAIR_STEER, PAIR_IDLE, PAIR_PGID, PAIR_STALL,
# PAIR_STALL_BUSY, PAIR_LAUNCH (the child process-group wrapper).
backend_claude_pair_begin() {
  local role="$1" repo="$2" branch="${3:-}" child_log="$4" resume="${5:-}"
  local label; label="$(pair_label "$role" "$repo" "$branch")"
  if [[ -n "$resume" ]]; then
    PAIR_SID="$resume"
    PAIR_OPTS=(--input-format stream-json)
  else
    PAIR_SID="$(mint_uuid)"
    PAIR_OPTS=(--session-id "$PAIR_SID" --input-format stream-json)
  fi
  PAIR_STEER="${child_log%.jsonl}.steering.md"
  PAIR_FIFO="${child_log%.jsonl}.steer.fifo"
  PAIR_IDLE="${CEREBRO_PAIR_IDLE:-60}"
  PAIR_PGID="${child_log%.jsonl}.pgid"
  PAIR_STALL="${CEREBRO_PAIR_STALL:-180}"
  PAIR_STALL_BUSY="${CEREBRO_PAIR_STALL_BUSY:-450}"
  PAIR_LAUNCH=(python3 "$CEREBRO_LIB_DIR/python/exec_setsid.py" "$PAIR_PGID")
  : > "$PAIR_STEER"
  rm -f "$PAIR_FIFO" "$PAIR_PGID"
  mkfifo "$PAIR_FIFO" || die "pair: cannot create steering pipe at $PAIR_FIFO"
  pair_banner "$role" "$PAIR_SID" "$label" "$PAIR_FIFO"
}

# backend_claude_pair_feed <pair> <child_log> -- stdin carries the initial
# prompt. Unpaired: pass it through unchanged as claude -p text input. Paired:
# hand it to the stream-json input pump, which emits the prompt as the first
# user message, holds a steering window open after each turn, and reaps the
# child process group if the child log freezes.
backend_claude_pair_feed() {
  local pair="$1" clog="$2"
  if (( pair )); then
    python3 "$CEREBRO_LIB_DIR/python/pair_pump_claude.py" \
      "$PAIR_FIFO" "$PAIR_STEER" "$clog" "$PAIR_IDLE" "$PAIR_PGID" "$PAIR_STALL" "$PAIR_STALL_BUSY"
  else
    cat
  fi
}

# backend_claude_pair_run <cwd> <prompt> <role> <resume> <child_log>
#   <msg_capture> <id_capture> <store_file> <ckey> [model] -- drive a paired
# claude child to completion. Feeds the prompt through the stream-json input
# pump, into claude with the role's --append-system-prompt + --allowedTools +
# PAIR_OPTS, tees the stream to the child log, and parses via parse_stream.py.
backend_claude_pair_run() {
  local cwd="$1" prompt="$2" role="$3" resume="$4" child_log="$5" \
        msg_capture="$6" id_capture="$7" store_file="$8" ckey="$9" \
        model="${10:-$CEREBRO_MODEL}"
  local sys_prompt; sys_prompt="$(child_sys_prompt "$role")"
  local opts=(-p --permission-mode bypassPermissions
    --allowedTools "$(backend_claude_child_allowed_tools "$role")"
    --output-format stream-json --verbose)
  [[ -n "$model" ]] && opts+=(--model "$model")
  local run_opts=("${opts[@]}")
  [[ -n "$resume" ]] && run_opts+=(--resume "$resume")
  run_opts+=("${PAIR_OPTS[@]}")
  # The role prompt is short/static; write it to a temp file and load via
  # --append-system-prompt-file so the body is cacheable.
  local prompt_file
  prompt_file="$(mktemp -t cerebro-claude-child-XXXXXX.md)"
  printf '%s' "$sys_prompt" > "$prompt_file"
  run_opts+=(--append-system-prompt-file "$prompt_file")
  ( cd "$cwd" && printf '%s' "$prompt" \
      | backend_claude_pair_feed 1 "$child_log" \
      | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
        "${PAIR_LAUNCH[@]}" "${TIMEOUT_CMD[@]}" "$CEREBRO_CLAUDE_CMD" "${run_opts[@]}" 2>/dev/null \
      | tee "$child_log" \
      | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" \
          "$msg_capture" "$id_capture" "$store_file" "$ckey" )
  return $?
}

# backend_claude_pair_cleanup <pair> -- remove the steering pipe and pgid file.
backend_claude_pair_cleanup() {
  (( $1 )) || return 0
  [[ -n "${PAIR_FIFO:-}" ]] && rm -f "$PAIR_FIFO"
  [[ -n "${PAIR_PGID:-}" ]] && rm -f "$PAIR_PGID"
}

# ----- ACP (Agent Client Protocol) ------------------------------------------
# `cerebro acp` is a thin proxy: per ACP session it mints a cerebro session,
# spawns a per-session claude-agent-acp child (@agentclientprotocol/claude-
# agent-acp on the Claude Agent SDK), and relays JSON-RPC with sessionId remap.
# The restricted cerebro-orchestrator agent is pinned through claude-agent-acp's
# `agent` config option: claude-agent-acp surfaces custom main-thread agents
# discovered from the SESSION cwd's .claude/agents/ (verified), so acp-mint
# writes a cerebro-owned per-session project dir
# ($CEREBRO_HOME/acp/<sid>/.claude/agents/cerebro-orchestrator.md) that the
# proxy uses as the session cwd, with the user's repo passed as an ACP
# additional_directory (no repo pollution). cerebro-orchestrator then appears
# in the agent picker and the proxy forces it via session/set_config_option
# after new_session; that calls the SDK's applyFlagSettings({agent:...}) -- the
# same path as `claude --agent` -- so the agent file's `tools:` is
# hard-enforced. CLAUDE_CONFIG_DIR points at cerebro's isolated .claude so the
# user's own ~/.claude hooks/settings don't interfere; the orchestrator agent
# itself is read from the session-cwd project dir.

# claude_acp_catalog_env -- emit a JSON object with the ANTHROPIC_DEFAULT_*
# env vars the Claude SDK reads to REGISTER the user's catalog model ids
# ($CEREBRO_HOME/models-config.json) with the upstream child. This is
# id-registration only, not picker presentation: the proxy (acp_server.py)
# rewrites the editor-facing `model` config option from the catalog, so the
# SDK's own picker (which carries Anthropic tier labels like "Opus"/"Sonnet")
# is never shown to the editor. The env vars here just make the SDK accept
# `set_config_option("model", <catalog id>)` by adding the ids to its
# internal modelInfos list.
#
# The SDK exposes four built-in model slots (OPUS / SONNET / HAIKU / FABLE)
# plus one ANTHROPIC_CUSTOM_MODEL_OPTION. HAIKU is reserved: the caller
# already mirrors CEREBRO_MODEL into ANTHROPIC_DEFAULT_HAIKU_MODEL for
# small/fast background tasks, and we skip it to preserve that invariant.
# That leaves OPUS, SONNET, FABLE (3 slots) + CUSTOM (1) = 4 catalog ids
# we can register. Catalog entries past that cap are not registered -- the
# SDK would reject `set_config_option` for them -- but the orchestrator
# can still use them via `cerebro <subcmd> --model <id>` (which doesn't go
# through the SDK's model picker at all).
#
# Slot assignment follows catalog order (deterministic; the slot label is
# invisible to the editor). No _NAME/_DESCRIPTION/_SUPPORTED_CAPABILITIES
# companions are emitted: those only label the SDK's internal picker,
# which the editor never sees, so they'd be dead weight. Echoes "{}" when
# the catalog is missing, empty, or unparseable.
claude_acp_catalog_env() {
  local cfg="$CEREBRO_HOME/models-config.json"
  [[ -r "$cfg" && -s "$cfg" ]] || { printf '%s\n' '{}'; return 0; }
  jq -e '.models' "$cfg" >/dev/null 2>&1 || { printf '%s\n' '{}'; return 0; }
  # HAIKU is intentionally absent from this list -- the caller pins it to
  # CEREBRO_MODEL for small/fast background tasks (see backend_claude_
  # acp_child_spec), and we don't clobber that with a catalog entry.
  local -a slots=(OPUS SONNET FABLE)
  local slot_idx=0 entry id env_obj slot
  env_obj='{}'
  while IFS= read -r entry; do
    id="$(jq -r '.id // empty' <<<"$entry")"
    [[ -n "$id" ]] || continue
    if (( slot_idx < 3 )); then
      slot="${slots[$slot_idx]}"
      env_obj="$(jq -c --arg slot "$slot" --arg id "$id" \
          '. + {("ANTHROPIC_DEFAULT_" + $slot + "_MODEL"): $id}' \
        <<<"$env_obj")"
    elif (( slot_idx == 3 )); then
      env_obj="$(jq -c --arg id "$id" \
          '. + {"ANTHROPIC_CUSTOM_MODEL_OPTION": $id}' \
        <<<"$env_obj")"
    else
      break
    fi
    slot_idx=$((slot_idx + 1))
  done < <(jq -c '.models[]' "$cfg")
  printf '%s\n' "$env_obj"
}

# backend_claude_acp_child_spec -- emit the JSON spec acp_server.py consumes
# to spawn + pin the upstream claude ACP child for one session:
#   {argv, pin:{config_id,value}, env}
# argv prefers a globally installed `claude-agent-acp`, falling back to
# `npx -y @agentclientprotocol/claude-agent-acp` (zero-touch, cached by npx
# after first use). pin forces the `agent` config option to cerebro-orchestrator.
# env layers CLAUDE_CONFIG_DIR onto the child; when CEREBRO_CLAUDE_BASE_URL is
# set it also exports the Anthropic gateway env (mirroring
# backend_claude_endpoint_env, including pinning ANTHROPIC_MODEL so the gateway
# serves the configured model) and nulls ANTHROPIC_API_KEY (the proxy unsets a
# null env value), and merges claude_acp_catalog_env which registers the
# catalog model ids with the SDK so `set_config_option("model", <id>)` is
# accepted. The EDITOR-FACING model picker is owned by the proxy
# (acp_server.py), which rewrites the `model` config option from the catalog
# -- the env vars here only do id registration, not picker presentation.
# The proxy adds CEREBRO_SESSION_ID / CEREBRO_SESSION_DIR / CEREBRO_HOME itself.
backend_claude_acp_child_spec() {
  local argv_bin
  if command -v claude-agent-acp >/dev/null 2>&1; then
    argv_bin='["claude-agent-acp"]'
  else
    argv_bin='["npx","-y","@agentclientprotocol/claude-agent-acp"]'
  fi
  local env_json='{}'
  if [[ -n "$CEREBRO_CLAUDE_BASE_URL" ]]; then
    local acp_model="${CEREBRO_MODEL:-}"
    env_json="$(jq -n --arg base "$CEREBRO_CLAUDE_BASE_URL" \
        --arg tok "${CEREBRO_CLAUDE_AUTH_TOKEN:-ollama}" \
        --arg model "$acp_model" \
        '{ANTHROPIC_BASE_URL:$base, ANTHROPIC_AUTH_TOKEN:$tok,
          ANTHROPIC_MODEL:$model, ANTHROPIC_DEFAULT_HAIKU_MODEL:$model,
          ANTHROPIC_API_KEY:null}')"
    # Register catalog ids with the SDK (id-registration only; the proxy
    # rewrites the editor-facing picker from the catalog -- see acp_server.py).
    # HAIKU is reserved (stays pinned to CEREBRO_MODEL above) so the SDK
    # uses the orchestrator model for small/fast background tasks. A
    # missing/unparseable catalog returns "{}" and the merge is a no-op.
    env_json="$(jq -c --argjson cat "$(claude_acp_catalog_env)" \
        '. + $cat' <<<"$env_json")"
    # Mirror backend_claude_endpoint_env: if the catalog declares contextTokens
    # for the orchestrator model, set the auto-compact window so Claude Code
    # doesn't fall back to 200k for the unrecognized id. Omit the key (rather
    # than emit null) when no tokens resolve -- the proxy nulls null env values,
    # but skipping keeps the env_json clean.
    local ctx; ctx="$(models_context_tokens "$acp_model")"
    [[ -n "$ctx" ]] && env_json="$(jq -c --arg ctx "$ctx" \
        '. + {CLAUDE_CODE_AUTO_COMPACT_WINDOW:$ctx}' <<<"$env_json")"
  fi
  jq -n --argjson argv "$argv_bin" --arg cfg "agent" --arg val "cerebro-orchestrator" \
        --arg ccd "$CEREBRO_HOME/.claude" --argjson env "$env_json" \
    '{argv:$argv, pin:{config_id:$cfg, value:$val},
      env:($env + {CLAUDE_CONFIG_DIR:$ccd})}'
}
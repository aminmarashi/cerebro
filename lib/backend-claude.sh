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
# serves the review model, not the editing model. It must differ from the
# shipped editing default (CEREBRO_DEFAULT_MODEL) so a misconfigured run fails
# early instead of at the provider. Idempotent; a no-op when
# CEREBRO_CLAUDE_BASE_URL is unset (the default subscription path, unchanged --
# the --model flag alone selects the model).
backend_claude_endpoint_env() {
  [[ -n "$CEREBRO_CLAUDE_BASE_URL" ]] || return 0
  local model="${1:-$CEREBRO_MODEL}"
  [[ "$model" != "$CEREBRO_DEFAULT_MODEL" ]] \
    || die "CEREBRO_CLAUDE_BASE_URL is set but the effective model is still the shipped default ($CEREBRO_DEFAULT_MODEL); set the relevant CEREBRO_*MODEL to a model the endpoint serves"
  export ANTHROPIC_BASE_URL="$CEREBRO_CLAUDE_BASE_URL"
  export ANTHROPIC_AUTH_TOKEN="${CEREBRO_CLAUDE_AUTH_TOKEN:-ollama}"
  export ANTHROPIC_MODEL="$model"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
  unset ANTHROPIC_API_KEY
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
# UserPromptSubmit hook and the .claude/settings.local.json that registers it.
# Called after the shared materialise_home (which writes the opencode tree the
# reviewer needs regardless of backend).
backend_claude_materialise_extras() {
  mkdir -p "$CEREBRO_HOME/.claude"
  write_if_changed "$CEREBRO_HOME/hook.sh" "$(cerebro_hook_script)"
  chmod +x "$CEREBRO_HOME/hook.sh"
  local settings; settings="$(cerebro_settings_json "$CEREBRO_HOME/hook.sh")"
  write_if_changed "$CEREBRO_HOME/.claude/settings.local.json" "$settings"
  # The claude backend still ships a CLAUDE.md bootstrap template for new repos.
  write_if_missing "$CEREBRO_HOME/templates/CLAUDE.md" "$(cerebro_default_claude_md)"
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
  exec "$CEREBRO_CLAUDE_CMD" \
    --session-id "$sid" \
    --append-system-prompt-file "$prompt_file" \
    --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
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
      "Start observing session $target now: run \`cerebro observe $target\`, narrate what you see, and keep looping until its children are done or I stop you." \
      --allowedTools "$allowed"
  else
    exec "$CEREBRO_CLAUDE_CMD" \
      --session-id "$sid" \
      --append-system-prompt "$prompt" \
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
  if [[ -n "$id" ]]; then
    exec "$CEREBRO_CLAUDE_CMD" \
      --resume "$id" \
      --append-system-prompt-file "$prompt_file" \
      --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
  else
    # Bare resume: claude shows its own picker. The hook writes the
    # current-session symlink as soon as the user submits their first prompt.
    exec "$CEREBRO_CLAUDE_CMD" \
      --resume \
      --append-system-prompt-file "$prompt_file" \
      --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
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
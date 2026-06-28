# cerebro lib: commands/session
# subcommands: launch / --resume / --observe / list
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro (launch new session) ----------------------------

# Global preference files (span every session under $CEREBRO_HOME).
learnings_file()         { printf '%s\n' "$CEREBRO_HOME/learnings.md"; }
pending_learnings_file() { printf '%s\n' "$CEREBRO_HOME/pending-learnings.md"; }

# User-owned harness overlays (global under $CEREBRO_HOME). Each overlay is a
# plain-markdown file the loaders APPEND onto a shipped prompt/grader, so a user
# can tune any prompt surface locally without forking -- the same user-owned
# pattern as learnings.md. materialise_home() never creates or clobbers them; an
# absent or whitespace-only overlay changes nothing.
overlays_dir() { printf '%s\n' "$CEREBRO_HOME/overlays"; }
overlay_file() { printf '%s\n' "$(overlays_dir)/$1.md"; }   # $1 = target
overlay_body() {   # $1=target; echoes body only if present + non-whitespace
  local f; f="$(overlay_file "$1")"
  [[ -s "$f" ]] || return 0
  local b; b="$(cat "$f")"
  [[ -n "${b//[[:space:]]/}" ]] && printf '%s' "$b"
}

# Build the orchestrator's full system prompt: the static catalog plus, when
# present, the user's learned preferences. learnings.md is kept small (capped
# by cmd_learn_set) so it fits in the system message; a whitespace-only file is
# treated as empty. Echoed on stdout.
orchestrator_append_prompt() {
  local base; base="$(cerebro_system_prompt)"
  local lf body=""
  lf="$(learnings_file)"
  if [[ -s "$lf" ]]; then
    body="$(cat "$lf")"
    [[ -n "${body//[[:space:]]/}" ]] || body=""
  fi
  if [[ -n "$body" ]]; then
    base="$(printf '%s\n\n# Learned preferences\n\nDurable preferences cerebro has learned from this user across past sessions. Honor them by default in every plan, execute, review, and apply-review decision unless the user overrides in the moment.\n\n%s' "$base" "$body")"
  fi
  local ov; ov="$(overlay_body system)"
  if [[ -n "$ov" ]]; then
    printf '%s\n\n# Local harness overlay\n\n%s\n' "$base" "$ov"
  else
    printf '%s\n' "$base"
  fi
}

# Write the orchestrator agent definition for an opencode launch into the
# opencode config dir. It carries the composed system prompt (catalog +
# learnings) as its body and the read-only permission clamp in its frontmatter.
# Regenerated each launch so learned preferences stay current. Echoes the agent
# name. opencode only; the claude backend passes the prompt inline instead.
write_orchestrator_agent() {
  local body; body="$(orchestrator_append_prompt)"
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-orchestrator.md" \
    "$(orchestrator_agent_file "$body")"
  printf 'cerebro-orchestrator\n'
}

# Resolve the orchestrator identifier for the active backend: under opencode it
# is the agent name (write_orchestrator_agent); under claude it is the composed
# system prompt (passed inline via --append-system-prompt). Echoed on stdout.
orchestrator_handle() {
  if backend_is opencode; then
    write_orchestrator_agent
  else
    orchestrator_append_prompt
  fi
}

cmd_launch() {
  require_interactive
  require_deps
  materialise_home

  local sid sess_dir ts
  sid="$(mint_uuid)"
  sess_dir="$CEREBRO_HOME/sessions/$sid"
  mkdir -p "$sess_dir/plans" "$sess_dir/children"
  : > "$sess_dir/transcript.jsonl"
  ts="$(ts_iso)"
  write_metadata_new "$sess_dir" "$sid" "$ts"

  local handle; handle="$(orchestrator_handle)"

  export CEREBRO_SESSION_ID="$sid"
  export CEREBRO_SESSION_DIR="$sess_dir"
  export CEREBRO_HOME

  CEREBRO_SESSION_DIR="$sess_dir" log_event "session_created"

  say "cerebro: starting session $sid (backend $(current_backend))"
  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"
  backend_launch_orchestrator "$sess_dir" "$handle"
}

# Build the observer session's system prompt: the full orchestrator prompt
# (so it understands what audit/execute/review children do) plus the
# observe-mode overlay that narrows it to watching and steering. When a target
# id is given, point it at that session by default. Echoed on stdout.
observer_append_prompt() {
  local target="${1:-}"
  local base mode
  base="$(orchestrator_append_prompt)"
  mode="$(cerebro_observe_mode_prompt)"
  if [[ -n "$target" ]]; then
    printf '%s\n\n%s\n\nThe user launched this observer to watch session `%s`. Begin by running `cerebro observe %s` and narrating what you see; keep looping until its children are done or the user stops you.\n' \
      "$base" "$mode" "$target" "$target"
  else
    printf '%s\n\n%s\n' "$base" "$mode"
  fi
}

# Write the observer agent definition for an opencode launch. Echoes the agent
# name. opencode only.
write_observer_agent() {
  local target="${1:-}" body
  body="$(observer_append_prompt "$target")"
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-observer.md" \
    "$(observer_agent_file "$body")"
  printf 'cerebro-observer\n'
}

# Resolve the observer identifier for the active backend: opencode agent name
# or claude inline prompt. Echoed on stdout.
observer_handle() {
  local target="$1"
  if backend_is opencode; then
    write_observer_agent "$target"
  else
    observer_append_prompt "$target"
  fi
}

# ----- subcommand: cerebro --observe [<id>] --------------------------------

# Block until there is something to observe: another session with live paired
# children (a named target's, or -- with no target -- any other session's).
# Polls observe_pump's cheap probe mode, sleeping CEREBRO_OBSERVE_POLL seconds
# between tries, so the observer chat opens onto live activity instead of an
# immediate "nothing to observe". The user can Ctrl-C to bail. No python3 (or
# no sessions root) -> proceed immediately and let the session sort it out.
observer_wait_until_observable() {
  local target="${1:-}"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 "$CEREBRO_LIB_DIR/python/observe_pump.py" \
    "$CEREBRO_HOME/sessions" "$target" "" "" 0 0 probe >/dev/null 2>&1 && return 0
  local who="paired children"
  [[ -n "$target" ]] && who="session $target's paired children"
  say "cerebro: waiting for $who to observe... (Ctrl-C to cancel)"
  while ! python3 "$CEREBRO_LIB_DIR/python/observe_pump.py" \
      "$CEREBRO_HOME/sessions" "$target" "" "" 0 0 probe >/dev/null 2>&1; do
    sleep "${CEREBRO_OBSERVE_POLL:-2}"
  done
}

# Launch an interactive agent chat dedicated to observing and steering another
# cerebro session's live paired children. Same session plumbing as cmd_launch,
# but the system prompt is the observe-mode overlay and the tool surface is
# narrowed to observe + steer + read-only commands, so this session can never
# make direct repo changes. Optional first arg is the target session id.
cmd_launch_observer() {
  require_interactive
  require_deps
  materialise_home

  local target="${1:-}"
  # Don't open the chat until something is observable; poll until it is. Done
  # before minting the session so a Ctrl-C here leaves no orphan session dir.
  observer_wait_until_observable "$target"

  local sid sess_dir ts
  sid="$(mint_uuid)"
  sess_dir="$CEREBRO_HOME/sessions/$sid"
  mkdir -p "$sess_dir/plans" "$sess_dir/children"
  : > "$sess_dir/transcript.jsonl"
  ts="$(ts_iso)"
  write_metadata_new "$sess_dir" "$sid" "$ts"

  local handle; handle="$(observer_handle "$target")"

  export CEREBRO_SESSION_ID="$sid"
  export CEREBRO_SESSION_DIR="$sess_dir"
  export CEREBRO_HOME

  CEREBRO_SESSION_DIR="$sess_dir" log_event "session_created" "observer"

  say "cerebro: starting observer session $sid${target:+ (watching $target)}"
  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"
  backend_launch_observer "$sess_dir" "$handle" "$target"
}

# ----- subcommand: cerebro --resume [<id>] ---------------------------------

cmd_resume() {
  require_interactive
  require_deps
  materialise_home

  local id="${1:-}"
  export CEREBRO_HOME

  # With no id, resume the most recently touched session. Both backends now use
  # cerebro's own session id rather than relying on a provider picker/symlink.
  if [[ -z "$id" ]]; then
    id="$(python3 "$CEREBRO_LIB_DIR/python/list_sessions.py" "$CEREBRO_HOME/sessions" --most-recent 2>/dev/null)"
    [[ -n "$id" ]] || die "no sessions to resume"
    say "cerebro: resuming most recent session $id"
  fi

  local sess_dir="$CEREBRO_HOME/sessions/$id"
  [[ -d "$sess_dir" ]] || die "no such session: $id"
  touch_metadata "$sess_dir" "$(ts_iso)"

  # Pick up the backend the session was created under so the resumed orchestrator
  # and any children it spawns dispatch through the same implementation.
  CEREBRO_RESUME_BACKEND="$(session_backend "$sess_dir")"
  export CEREBRO_RESUME_BACKEND

  local handle; handle="$(orchestrator_handle)"

  export CEREBRO_SESSION_ID="$id"
  export CEREBRO_SESSION_DIR="$sess_dir"
  say "cerebro: resuming session $id (backend $CEREBRO_RESUME_BACKEND)"

  # Reopen the provider conversation when we captured its id at launch (opencode
  # assigns its own; claude uses the cerebro id directly); otherwise start a
  # fresh conversation in this same cerebro session dir (cerebro state --
  # spec, plans, children -- persists regardless).
  local foreign_id=""
  foreign_id="$(session_foreign_id "$sess_dir")"
  # Under claude the foreign id is the cerebro id itself (claude's --resume takes
  # it directly); fall back to the cerebro id when no foreign id is stored.
  if [[ -z "$foreign_id" ]] && [[ "$CEREBRO_RESUME_BACKEND" == "claude" ]]; then
    foreign_id="$id"
  fi

  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"
  backend_resume_orchestrator "$sess_dir" "$foreign_id" "$handle"
}

# ----- subcommand: cerebro list --------------------------------------------

cmd_list() {
  require_interactive
  if [[ ! -d "$CEREBRO_HOME/sessions" ]] || \
     [[ -z "$(ls -A "$CEREBRO_HOME/sessions" 2>/dev/null)" ]]; then
    echo "cerebro: no sessions yet"
    return 0
  fi
  # Sort by metadata.last_touched, newest first.
  python3 "$CEREBRO_LIB_DIR/python/list_sessions.py" "$CEREBRO_HOME/sessions"
}
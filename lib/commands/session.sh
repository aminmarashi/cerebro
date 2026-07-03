# cerebro lib: commands/session
# subcommands: launch / --resume / --observe / list
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro (launch new session) ----------------------------

# Global preference files (span every session under $CEREBRO_HOME).
learnings_file()         { printf '%s\n' "$CEREBRO_HOME/learnings.md"; }
pending_learnings_file() { printf '%s\n' "$CEREBRO_HOME/pending-learnings.md"; }

# User-owned harness overlays (global under $CEREBRO_HOME). Each overlay is a
# plain-markdown file the orchestrator/children can READ when they need local
# tuning. materialise_home() never creates or clobbers them; an absent or
# whitespace-only overlay is simply not read.
overlays_dir() { printf '%s\n' "$CEREBRO_HOME/overlays"; }
overlay_file() { printf '%s\n' "$(overlays_dir)/$1.md"; }   # $1 = target
overlay_body() {   # $1=target; echoes body only if present + non-whitespace
  local f; f="$(overlay_file "$1")"
  [[ -s "$f" ]] || return 0
  local b; b="$(cat "$f")"
  [[ "$b" =~ [^[:space:]] ]] && printf '%s' "$b"
}

# orchestrator_handle -- resolve the stable orchestrator identifier for the
# active backend: under opencode it is the agent name (materialise_home writes a
# stable agent file from the static system prompt); under claude it is the
# static system prompt file path (the backend loads it with --append-system-prompt-file).
# User-owned local overlays and learnings are no longer injected here; they live
# in plain files the model can read when needed. Echoed on stdout.
orchestrator_handle() {
  if backend_is opencode; then
    printf 'cerebro-orchestrator\n'
  else
    printf '%s\n' "$CEREBRO_HOME/system-prompt.md"
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

# Build the observer session's system prompt: the static orchestrator prompt
# (so it understands what audit/execute/review children do) plus the
# observe-mode overlay that narrows it to watching and steering. When a target
# id is given, point it at that session by default. Echoed on stdout.
observer_append_prompt() {
  local target="${1:-}"
  local base mode
  base="$(cerebro_system_prompt)"
  mode="$(cerebro_observe_mode_prompt)"
  if [[ -n "$target" ]]; then
    printf '%s\n\n%s\n\nThe user launched this observer to watch session `%s`. Begin by running `cerebro observe %s` and narrating what you see; keep looping until its children are done or the user stops you.\n' \
      "$base" "$mode" "$target" "$target"
  else
    printf '%s\n\n%s\n' "$base" "$mode"
  fi
}

# observer_handle -- resolve the stable observer identifier for the active
# backend: under opencode it is the agent name (materialise_home writes a stable
# agent file from the static observe-mode prompt); under claude it is the
# composed inline prompt (there is no separate observer file). Echoed on stdout.
observer_handle() {
  local target="${1:-}"
  if backend_is opencode; then
    printf 'cerebro-observer\n'
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

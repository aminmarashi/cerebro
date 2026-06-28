# cerebro lib: commands/improve
# subcommand: improve (hill-climbing trace analysis of the accumulated corpus)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro improve <cerebro-repo> [--context "..."] --------
# The fourth loop: a read-only opencode reviewer mines cerebro's accumulated
# agent traces under $CEREBRO_HOME for problems that RECUR across runs and
# proposes the smallest fixes, routed to local overlays / learnings
# (GitHub-free) or -- for whoever maintains the source -- an upstream PR. cwd
# is the cerebro repo so the reviewer reads/cites the real harness files; the
# read-only sandbox still reads the trace corpus under $CEREBRO_HOME.
# ANALYSE/PROPOSE only: findings go to a fixed improvements/improve.md (re-run
# overwrites) ending with a HILL CLIMB verdict line. Nothing here rewrites the
# harness.

cmd_improve() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local context=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) shift; context="${1:-}"; shift || true ;;
      *) die "improve: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" ]] \
    || die "usage: cerebro improve <cerebro-repo-abs-path> [--context \"<focus>\"]"
  [[ "$repo" = /* ]] || die "improve: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "improve: repo not a directory: $repo"

  local imp_dir="$CEREBRO_SESSION_DIR/improvements"
  mkdir -p "$imp_dir"
  local out_path="$imp_dir/improve.md"
  local child_log="${out_path%.md}.log"

  # Child-session continuity is only for an interrupted/incomplete run. A
  # cleanly finished run gets marked done; re-running starts fresh.
  local store_file; store_file="$(child_sessions_file)"
  local ckey prior=""
  ckey="$(child_key "$repo" improve improve)"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_running_fresh "$ckey"; then
    :
  else
    prior=""
  fi

  say "cerebro: mining traces under $CEREBRO_HOME against $repo -> $out_path"
  log_event "improve_started" "repo=$repo out=$out_path resume=${prior:-none}"

  local improve_prompt
  improve_prompt="$(cerebro_improve_prompt)

The cerebro trace corpus to analyse lives under: $CEREBRO_HOME
  sessions/*/children/*.jsonl   - agent trajectories (model + tool calls)
  sessions/*/transcript.jsonl   - user prompts + milestones
  sessions/*/audits/*.md, sessions/*/children/review-*.md - grader feedback
  pending-learnings.md, learnings.md, overlays/*.md - applied prefs/overlays"

  if [[ -n "$context" ]]; then
    improve_prompt+="

Focus from the orchestrator (where to concentrate the analysis):

<context>
$context
</context>"
  fi

  # Run the read-only reviewer agent on the independent review model. Its
  # findings are its final message, captured and written to out_path; the JSON
  # event stream is tee'd to child_log. cwd is the repo so the reviewer cites
  # the real harness files; the read-only sandbox still reads the traces under
  # $CEREBRO_HOME.
  # The reviewer always runs under opencode regardless of CEREBRO_BACKEND.
  local agent; agent="$(backend_opencode_child_agent_name audit)"
  local rc id_capture out_capture; id_capture="$(mktemp)"; out_capture="$(mktemp)"

  child_store_begin "$ckey" opencode improve "$repo" improve "$child_log" "${prior:+preserve-id}"
  backend_opencode_child_run 0 "$repo" "$improve_prompt" "$agent" "$prior" \
    "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "$CEREBRO_REVIEW_MODEL"
  rc=$?

  # Stale fallback: a resume the model no longer recognizes fails before any
  # event (empty id capture); retry once fresh in that case only.
  if (( rc != 0 )) && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
    log_event "improve_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "improve: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$id_capture"
    child_store_begin "$ckey" opencode improve "$repo" improve "$child_log"
    backend_opencode_child_run 0 "$repo" "$improve_prompt" "$agent" "" \
      "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "$CEREBRO_REVIEW_MODEL"
    rc=$?
  fi

  # The findings are the run's closing message; write them to out_path.
  if (( rc == 0 )) && [[ -s "$out_capture" ]]; then
    cp "$out_capture" "$out_path"
  fi
  rm -f "$id_capture"

  # On any failure -- non-zero exit OR empty findings -- preserve the event log
  # but do NOT echo a findings path.
  if (( rc != 0 )) || [[ ! -s "$out_path" ]]; then
    rm -f "$out_capture"
    log_event "improve_failed" "rc=$rc log=$child_log out=$out_path"
    warn "improve: review run failed (rc=$rc)"
    [[ -s "$child_log" ]] && warn "see event log: $child_log"
    die "improve: review run failed; not echoing a findings path"
  fi

  child_store_done "$ckey"
  rm -f "$out_capture"

  log_event "improve_written" "$out_path"
  echo "$out_path"
}
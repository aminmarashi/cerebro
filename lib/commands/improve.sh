# cerebro lib: commands/improve
# subcommand: improve (two-timescale hill-climbing trace analysis)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro improve <cerebro-repo> [--context "..."] [--meta] -
# The fourth loop, now two-timescale (MetaSkill-Evolve):
#
#   FAST loop (default): a read-only reviewer mines cerebro's accumulated
#   agent traces under $CEREBRO_HOME for problems that RECUR across runs and
#   proposes the smallest fixes, routed to local overlays / learnings /
#   meta-overlays. Findings go to improvements/improve.md ending with a
#   HILL CLIMB verdict line.
#
#   SLOW loop (--meta, or auto-fires every CEREBRO_META_HORIZON fast runs):
#   the same reviewer mines the IMPROVEMENT HISTORY itself and proposes
#   changes to the meta-skill (the five components that parameterise the
#   improvement procedure: analyzer / retriever / allocator / proposer /
#   evolver). Findings go to improvements/meta-improve.md ending with a
#   META CLIMB verdict line. Routed to `cerebro overlay set meta-<component>`.
#
# Both loops ANALYSE/PROPOSE only; nothing here rewrites the harness. Each
# run is committed to a persistent improvement graph
# ($CEREBRO_HOME/improvement-graph.json) with a utility estimate computed
# from the trace corpus. Frontier selection (η1·U + η2·P̂ + η3·N) chooses
# which past improvement state to build on, so the graph is a DAG, not a
# linear chain.

# ----- improvement-graph helpers --------------------------------------------

# The persistent improvement DAG. One file under $CEREBRO_HOME shared across
# all sessions (the improvement loop is global, not per-session).
improve_graph_file() { printf '%s\n' "$CEREBRO_HOME/improvement-graph.json"; }

# A short hash of all overlay files (task-level + meta), so each graph node
# carries a complete snapshot of the improvement state at commit time.
improve_overlay_hash() {
  local dir; dir="$(overlays_dir)"
  [[ -d "$dir" ]] || { printf '%s' "none"; return 0; }
  local f
  { for f in "$dir"/*.md; do [[ -f "$f" ]] && cat "$f"; done; } 2>/dev/null \
    | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])' \
    || printf '%s' "none"
}

# A short hash of only meta-overlay files (meta-*.md), so the graph can
# detect when only the improvement procedure changed while task-level
# overlays stayed the same.
improve_meta_hash() {
  local dir; dir="$(overlays_dir)"
  [[ -d "$dir" ]] || { printf '%s' "none"; return 0; }
  local f
  { for f in "$dir"/meta-*.md; do [[ -f "$f" ]] && cat "$f"; done; } 2>/dev/null \
    | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])' \
    || printf '%s' "none"
}

# Count the numbered findings (lines starting with "N.") in the improve
# output as a rough signal of how many issues the reviewer filed. Captures
# the grep count into a variable so grep's exit-1-on-zero does not cause a
# double-print (grep -c prints 0 AND exits 1; the || fallback would then
# print a second 0).
improve_count_findings() {
  local f="$1" n
  [[ -s "$f" ]] || { printf '0'; return 0; }
  n="$(grep -cE '^[[:space:]]*[0-9]+\.' "$f" 2>/dev/null)" || n=0
  printf '%s' "$n"
}

# Run one read-only reviewer child and write its final message to out_path.
# Shared by the fast and slow loops so both share the same stale-fallback
# and error-handling path.
#   $1 cwd (repo)   $2 prompt   $3 agent   $4 prior (or "")
#   $5 child_log    $6 out_path  $7 ckey-label (for child_key)
# Returns 0 on success with findings in $out_path; non-zero on failure.
improve_run_reviewer() {
  local repo="$1" prompt="$2" agent="$3" prior="$4"
  local child_log="$5" out_path="$6" label="$7" model="${8:-}"
  local store_file; store_file="$(child_sessions_file)"
  local ckey; ckey="$(child_key "$repo" "$label" "$label")"

  # If a prior session is still running, resume; otherwise start fresh.
  if [[ -n "$prior" ]] && child_session_running_fresh "$ckey"; then
    :
  else
    prior=""
  fi

  local rc id_capture out_capture; id_capture="$(mktemp)"; out_capture="$(mktemp)"

  child_store_begin "$ckey" "$(review_backend)" "$label" "$repo" "$label" "$child_log" "${prior:+preserve-id}"
  review_child_run 0 "$repo" "$prompt" "$agent" "$prior" \
    "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "${model:-$CEREBRO_REVIEW_MODEL}"
  rc=$?

  # Stale fallback: a resume the model no longer recognizes fails before any
  # event (empty id capture); retry once fresh in that case only.
  if (( rc != 0 )) && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
    log_event "${label}_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "${label}: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$id_capture"
    child_store_begin "$ckey" "$(review_backend)" "$label" "$repo" "$label" "$child_log"
    review_child_run 0 "$repo" "$prompt" "$agent" "" \
      "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "${model:-$CEREBRO_REVIEW_MODEL}"
    rc=$?
  fi

  local _cap_id; _cap_id="$(cat "$id_capture" 2>/dev/null || true)"

  if (( rc == 0 )) && [[ -s "$out_capture" ]]; then
    cp "$out_capture" "$out_path"
  fi
  rm -f "$id_capture"

  # On any failure -- non-zero exit OR empty findings -- preserve the event
  # log but do NOT echo a findings path. Mark the child done on a stall (rc=5,
  # dead session) or when no id was captured; a failed run that captured an id
  # stays resumable. Show the child's stderr tail, matching review/audit.
  if (( rc != 0 )) || [[ ! -s "$out_path" ]]; then
    rm -f "$out_capture"
    [[ -z "$_cap_id" || $rc -eq 5 ]] && child_store_done "$ckey"
    log_event "${label}_failed" "rc=$rc log=$child_log out=$out_path"
    warn "${label}: review run failed (rc=$rc)"
    [[ -s "$child_log" ]] && warn "see event log: $child_log"
    child_fail_stderr "$child_log"
    return 1
  fi

  child_store_done "$ckey"
  rm -f "$out_capture"
  return 0
}

# ----- main command ---------------------------------------------------------

cmd_improve() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local context=""
  local force_meta=0
  local model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) shift; context="${1:-}"; shift || true ;;
      --meta) force_meta=1; shift ;;
      --model) shift; model="${1:-}"; shift || true ;;
      *) die "improve: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" ]] \
    || die "usage: cerebro improve <cerebro-repo-abs-path> [--context \"<focus>\"] [--meta] [--model <provider/model>]"
  [[ "$repo" = /* ]] || die "improve: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "improve: repo not a directory: $repo"

  local imp_dir="$CEREBRO_SESSION_DIR/improvements"
  mkdir -p "$imp_dir"
  local out_path="$imp_dir/improve.md"
  local child_log="${out_path%.md}.log"
  local meta_out_path="$imp_dir/meta-improve.md"
  local meta_child_log="${meta_out_path%.md}.log"

  # --- utility estimation + graph update -----------------------------------
  # Compute the current utility proxy from the trace corpus. This also
  # sets utility_after on the previous fast-loop graph node (the effect of
  # the last task-skill improvement is now visible in sessions created
  # since). Pass the parent node's timestamp as since_ts so delta_u measures
  # the window since the last improvement, not the full corpus.
  local graph_file; graph_file="$(improve_graph_file)"
  local parent_ts; parent_ts="$(python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" \
    "$graph_file" last-node 2>/dev/null || true)"
  parent_ts="${parent_ts%$'\n'}"
  local util_now
  util_now="$(python3 "$CEREBRO_LIB_DIR/python/improve_utility.py" "$CEREBRO_HOME" "$parent_ts" 2>/dev/null || printf '0.5')"
  python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" "$graph_file" update-utility "$util_now" 2>/dev/null || true

  # --- frontier selection --------------------------------------------------
  # Score each fast-loop node by η1·U + η2·P̂ + η3·N (Eq. 4) and build on the
  # best. Falls back to last-node when the graph is empty or no fast nodes
  # exist yet. Increment the selected parent's visitation counter (N cooling).
  local parent_node
  parent_node="$(python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" "$graph_file" best-frontier \
    "$CEREBRO_IMPROVE_ETA_1" "$CEREBRO_IMPROVE_ETA_2" "$CEREBRO_IMPROVE_ETA_3" 2>/dev/null || true)"
  parent_node="${parent_node%$'\n'}"
  if [[ -z "$parent_node" ]]; then
    parent_node="$(python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" "$graph_file" last-node 2>/dev/null || true)"
    parent_node="${parent_node%$'\n'}"
  fi
  [[ -n "$parent_node" ]] \
    && python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" "$graph_file" increment-selections "$parent_node" 2>/dev/null || true

  local fast_since_meta
  fast_since_meta="$(python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" "$graph_file" fast-since-meta 2>/dev/null || printf '0')"
  fast_since_meta="${fast_since_meta%$'\n'}"

  local run_meta=0
  if (( force_meta == 1 )); then
    run_meta=1
  elif (( fast_since_meta >= CEREBRO_META_HORIZON )); then
    run_meta=1
  fi

  local agent; agent="$(review_child_agent_name improve)"
  local results=()

  # --- FAST LOOP: task-skill improvement -----------------------------------
  say "cerebro: mining traces under $CEREBRO_HOME against $repo -> $out_path"
  log_event "improve_started" "repo=$repo out=$out_path util=$util_now meta=${run_meta} parent=$parent_node"

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

  # Resume handling: check for a prior in-flight improve session.
  local fast_ckey; fast_ckey="$(child_key "$repo" improve improve)"
  local fast_prior=""
  if fast_prior="$(child_session_get "$fast_ckey")" && [[ -n "$fast_prior" ]] && child_session_running_fresh "$fast_ckey"; then
    :
  else
    fast_prior=""
  fi

  if improve_run_reviewer "$repo" "$improve_prompt" "$agent" "$fast_prior" \
      "$child_log" "$out_path" improve "$model"; then
    log_event "improve_written" "$out_path"
    results+=("$out_path")

    # Commit the fast-loop node to the improvement graph.
    local findings_count verdict
    findings_count="$(improve_count_findings "$out_path")"
    verdict="$(tail -1 "$out_path" 2>/dev/null || true)"
    local overlay_hash meta_hash ts
    ts="$(ts_iso)"
    overlay_hash="$(improve_overlay_hash)"
    meta_hash="$(improve_meta_hash)"
    local fast_node_id
    fast_node_id="$(python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" \
      "$graph_file" add-node "$parent_node" fast "$ts" \
      "$overlay_hash" "$meta_hash" \
      "$findings_count" 0 "$verdict" "$util_now" 2>/dev/null || true)"
    fast_node_id="${fast_node_id%$'\n'}"
    log_event "improve_graph_node" "node=$fast_node_id parent=$parent_node findings=$findings_count util=$util_now"
  else
    die "improve: review run failed; not echoing a findings path"
  fi

  # --- SLOW LOOP: meta-skill improvement -----------------------------------
  if (( run_meta == 1 )); then
    say "cerebro: running meta-loop (evolving the improvement procedure) -> $meta_out_path"
    log_event "meta_improve_started" "out=$meta_out_path fast_since_meta=$fast_since_meta"

    # Build the meta-improve prompt: the slow-loop base prompt, then the
    # current meta-skill component files (presented as reference for
    # diagnosis, not as active output instructions), then the improvement
    # history from the graph.
    local meta_prompt
    meta_prompt="$(cerebro_meta_improve_prompt)

The cerebro trace corpus to analyse lives under: $CEREBRO_HOME
  sessions/*/children/*.jsonl   - agent trajectories (model + tool calls)
  sessions/*/transcript.jsonl   - user prompts + milestones
  sessions/*/improvements/improve.md - past fast-loop findings
  pending-learnings.md, learnings.md, overlays/*.md - applied prefs/overlays

The improvement history (from the graph at $graph_file):"

    # Append a compact summary of recent improvement runs from the graph.
    local graph_summary
    graph_summary="$(python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" "$graph_file" list 2>/dev/null || true)"
    if [[ -n "$graph_summary" ]]; then
      meta_prompt+="

<improvement_history>
$(printf '%s' "$graph_summary")
</improvement_history>"
    else
      meta_prompt+="

<improvement_history>
(first meta-loop run -- no prior improvement history yet)
</improvement_history>"
    fi

    if [[ -n "$context" ]]; then
      meta_prompt+="

Focus from the orchestrator:

<context>
$context
</context>"
    fi

    # The meta loop uses a distinct child-session key so it does not
    # collide with the fast loop's session.
    local meta_ckey; meta_ckey="$(child_key "$repo" meta-improve meta-improve)"
    local meta_prior=""
    if meta_prior="$(child_session_get "$meta_ckey")" && [[ -n "$meta_prior" ]] && child_session_running_fresh "$meta_ckey"; then
      :
    else
      meta_prior=""
    fi

    if improve_run_reviewer "$repo" "$meta_prompt" "$agent" "$meta_prior" \
        "$meta_child_log" "$meta_out_path" meta-improve "$model"; then
      log_event "meta_improve_written" "$meta_out_path"
      results+=("$meta_out_path")

      # Commit the meta-loop node to the improvement graph.
      local meta_findings_count meta_verdict meta_ts
      meta_findings_count="$(improve_count_findings "$meta_out_path")"
      meta_verdict="$(tail -1 "$meta_out_path" 2>/dev/null || true)"
      meta_ts="$(ts_iso)"
      local meta_node_id
      meta_node_id="$(python3 "$CEREBRO_LIB_DIR/python/improve_graph.py" \
        "$graph_file" add-node "$fast_node_id" meta "$meta_ts" \
        "$overlay_hash" "$meta_hash" \
        "$meta_findings_count" 0 "$meta_verdict" "$util_now" 2>/dev/null || true)"
      meta_node_id="${meta_node_id%$'\n'}"
      log_event "meta_improve_graph_node" "node=$meta_node_id parent=$fast_node_id findings=$meta_findings_count"
    else
      warn "improve: meta-loop review run failed; fast-loop findings still available"
    fi
  fi

  # Echo all findings paths (fast first, then meta if it ran).
  local r
  for r in "${results[@]}"; do
    printf '%s\n' "$r"
  done
}
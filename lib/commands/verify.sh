# cerebro lib: commands/verify
# subcommand: verify
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro verify <repo> (--plan <path> | --prompt <text>)
#   [--context <text>] ---------------------------------------------------
# Spawns the cerebro-verify child agent (on CEREBRO_REVIEW_MODEL) to perform a
# HIGH-LEVEL REQUIREMENTS / ACCEPTANCE check: does the delivered change, used
# for real, satisfy what the spec/plan asked for end-to-end? The verify agent
# drives the real running app with a browser (or invokes the real
# entrypoint/CLI for a non-UI change) and reports VERIFY: PASS|FAIL|BLOCKED as
# its final line. Its report is saved to sessions/<id>/children/verify-*.md and
# the path is echoed on stdout (same stdout contract as review). Mirrors
# cmd_review's child-store continuity + resume/stale-fallback shape.

cmd_verify() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local plan_path="" prompt_text="" context=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan) shift; plan_path="${1:-}"; shift || true ;;
      --prompt) shift; prompt_text="${1:-}"; shift || true ;;
      --context) shift; context="${1:-}"; shift || true ;;
      *) die "verify: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" ]] \
    || die "usage: cerebro verify <repo-abs-path> (--plan <path> | --prompt <text>) [--context <text>]"
  [[ "$repo" = /* ]] || die "verify: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "verify: repo not a directory: $repo"
  # Exactly one of --plan / --prompt is required.
  if [[ -z "$plan_path" && -z "$prompt_text" ]]; then
    die "verify: requires --plan <path> or --prompt \"<text>\""
  fi
  if [[ -n "$plan_path" && -n "$prompt_text" ]]; then
    die "verify: pass either --plan or --prompt, not both"
  fi
  local plan_block=""
  if [[ -n "$plan_path" ]]; then
    [[ -r "$plan_path" && -s "$plan_path" ]] \
      || die "verify: cannot read plan (or it is empty): $plan_path"
    plan_block="$(cat "$plan_path")"
  fi

  # Canonical worktree root keys the per-repo state file so re-verifies on the
  # same branch resume continuity instead of colliding with other repos.
  local canonical_repo
  canonical_repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || die "verify: not a git worktree: $repo"
  local repo_key
  repo_key="$(repo_state_key "$repo")" \
    || die "verify: not a git worktree: $repo"
  local state_dir="$CEREBRO_SESSION_DIR/review-state"
  local state_file="$state_dir/$repo_key.json"
  mkdir -p "$state_dir"

  local store_file; store_file="$(child_sessions_file)"
  local ckey="" prior="" verify_branch
  verify_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [[ -n "$verify_branch" ]]; then
    ckey="$(child_key "$canonical_repo" verify "$verify_branch")"
    if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_running_fresh "$ckey"; then
      :
    else
      prior=""
    fi
  fi

  # Uniquify the report filename (same convention as review).
  local out_path="$CEREBRO_SESSION_DIR/children/verify-$(ts_compact)-$(basename "$repo")-$$-${RANDOM}.md"
  local child_log="${out_path%.md}.log"

  say "cerebro: verifying $repo (${verify_branch:-unknown branch})"
  log_event "verify_started" "repo=$repo branch=${verify_branch:-none} resume=${prior:-none}"

  # Compose the verify prompt: a preamble framing the task, then the plan
  # block (or --prompt text), then the orchestrator's --context string.
  local verify_prompt
  verify_prompt="You are verifying a shipped change in the git worktree at $repo on branch ${verify_branch:-unknown}. Perform a HIGH-LEVEL REQUIREMENTS / ACCEPTANCE check: confirm from the big picture that the delivered change, USED FOR REAL, satisfies what the spec/plan asked for end-to-end. Build/run the REAL deployment artifact the change ships (e.g. docker compose up -d --build from the repo root, against the real data dir -- NOT an isolated/temp-HOME hand-launched dev server), drive the actual user flow(s) the plan delivers with a real browser (Playwright snapshot + click/fill/press/select on visible elements; browser_evaluate may inspect but is NOT interaction proof), and judge whether the REQUIREMENTS are met -- not whether every line is perfect. Do NOT do a nitpicky line review (style, naming, defensive code, contrived edge cases) -- that is a different agent's job. If the core capability works against real usage and the plan's observable behaviours are present, return PASS."

  if [[ -n "$plan_block" ]]; then
    verify_prompt+=$'\n\nThe plan you are verifying follows between the markers.\n<plan>\n'"$plan_block"'\n</plan>'
  else
    verify_prompt+=$'\n\nThe ad-hoc verification request: '"$prompt_text"
  fi

  if [[ -n "$context" ]]; then
    verify_prompt+=$'\n\n# Context from the orchestrator\n'"$context"
  fi

  verify_prompt+=$'\n\nWrite your verification report (what you did, what you observed, and your judgement), then end with a SINGLE final line that is exactly one of: `VERIFY: PASS` (requirements met, used for real), `VERIFY: FAIL` (list which requirements are not met, with what you observed vs what was expected), or `VERIFY: BLOCKED` (genuine blocker -- no browser, credentials you lack, an env you cannot reach; end with a single clear question the orchestrator can relay to the user). Do not soften a real failure into PASS, and do not manufacture a failure out of a nitpick. Converge.'

  # Run the verify child agent on the reviewer model (which has browser
  # capability). It is NOT the read-only reviewer clamp -- verify may start
  # servers, rebuild images, and drive a browser.
  local agent; agent="$(backend_opencode_child_agent_name verify)"
  local rc id_capture out_capture; id_capture="$(mktemp)"; out_capture="$(mktemp)"

  child_store_begin "$ckey" opencode verify "$repo" "${verify_branch:-auto}" "$child_log" "${prior:+preserve-id}"
  backend_opencode_child_run 0 "$repo" "$verify_prompt" "$agent" "$prior" \
    "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "$CEREBRO_REVIEW_MODEL"
  rc=$?

  # Stale fallback: a resume the model no longer recognizes fails before any
  # event (empty id capture); retry once fresh in that case only.
  if (( rc != 0 )) && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
    log_event "verify_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "verify: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$id_capture"
    child_store_begin "$ckey" opencode verify "$repo" "${verify_branch:-auto}" "$child_log"
    backend_opencode_child_run 0 "$repo" "$verify_prompt" "$agent" "" \
      "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "$CEREBRO_REVIEW_MODEL"
    rc=$?
  fi

  # The report is the run's closing message; write it to out_path.
  if (( rc == 0 )) && [[ -s "$out_capture" ]]; then
    cp "$out_capture" "$out_path"
  fi
  local _cap_id; _cap_id="$(cat "$id_capture" 2>/dev/null || true)"
  rm -f "$id_capture"

  # On any failure -- non-zero exit OR empty report -- preserve the event log
  # but do NOT echo a report path. Mark the child-store entry done ONLY when
  # no session id was captured (a stall / dead-session failure that cannot
  # be resumed, so a re-issue starts fresh instead of hanging on a dead
  # --resume); a failed run that DID capture an id stays resumable.
  if (( rc != 0 )) || [[ ! -s "$out_path" ]]; then
    rm -f "$out_capture"
    # Mark done on a stall (rc=5, dead session) or when no id was captured;
    # a failed run that captured an id stays resumable.
    [[ -z "$_cap_id" || $rc -eq 5 ]] && child_store_done "$ckey"
    log_event "verify_failed" "rc=$rc log=$child_log out=$out_path"
    warn "verify: verification run failed (rc=$rc)"
    [[ -s "$child_log" ]] && warn "see event log: $child_log"
    child_fail_stderr "$child_log"
    die "verify: verification run failed; not echoing a report path"
  fi

  child_store_done "$ckey"
  rm -f "$out_capture"

  # Record the result under last_verify so `cerebro status` can show it.
  local current_sha
  current_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  if [[ -n "$current_sha" ]]; then
    mkdir -p "$state_dir"
    jq -n --arg sha "$current_sha" --arg branch "${verify_branch:-}" \
          --arg verdict "$(tail -n 1 "$out_path" 2>/dev/null)" \
      '{last_verify_sha:$sha, branch:$branch, last_verify:$verdict}' \
      > "$state_file" 2>/dev/null || true
  fi

  log_event "verify_written" "$out_path"
  echo "$out_path"
}
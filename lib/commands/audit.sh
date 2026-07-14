# cerebro lib: commands/audit
# subcommand: audit (fresh-eyes viability check of an orchestrator-written plan)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro audit <repo> <plan-path> [--context "..."] -------
# The orchestrator writes plans itself (`cerebro plan`), so the external
# check comes from a genuinely independent model: a read-only opencode reviewer
# that receives the plan, the current session spec, and any crucial context
# the orchestrator passes, verifies the plan against the ACTUAL code, and writes
# its findings (ending with a PLAN AUDIT verdict line) to
# sessions/<id>/audits/<name>.md.

cmd_audit() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local plan_path="${1:-}"; shift || true
  local context="" out_name="" model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) shift; context="${1:-}"; shift || true ;;
      --out) shift; out_name="${1:-}"; shift || true ;;
      --model) shift; model="${1:-}"; shift || true ;;
      *) die "audit: unknown arg: $1" ;;
    esac
  done
  [[ -n "$model" ]] && require_model_for_backend "$model" "$(review_backend)" audit
  [[ -n "$repo" && -n "$plan_path" ]] \
    || die "usage: cerebro audit <repo-abs-path> <plan-path> [--context \"<crucial context>\"] [--out <name>] [--model <provider/model>]"
  [[ "$repo" = /* ]] || die "audit: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "audit: repo not a directory: $repo"
  [[ -s "$plan_path" ]] || die "audit: plan file missing or empty: $plan_path"

  local audits_dir="$CEREBRO_SESSION_DIR/audits"
  mkdir -p "$audits_dir"

  # Default findings name follows the plan, so a re-audit after a revision
  # overwrites the stale findings instead of piling up files.
  local plan_name; plan_name="$(basename "${plan_path%.md}")"
  [[ -z "$out_name" ]] && out_name="$plan_name-audit"
  out_name="${out_name%.md}"
  local out_path="$audits_dir/$out_name.md"
  local child_log="${out_path%.md}.log"

  # Child-session continuity is only for interrupted/incomplete audits. A
  # cleanly finished audit gets marked done; re-auditing starts fresh.
  local store_file; store_file="$(child_sessions_file)"
  local ckey prior=""
  ckey="$(child_key "$repo" audit "$out_name")"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_running_fresh "$ckey"; then
    :
  else
    prior=""
  fi

  say "cerebro: auditing $plan_path against $repo -> $out_path"
  log_event "audit_started" "plan=$plan_path out=$out_path resume=${prior:-none}"

  local audit_prompt
  audit_prompt="$(cerebro_audit_prompt)

<plan>
$(cat "$plan_path")
</plan>"

  local spec_path="$CEREBRO_SESSION_DIR/spec.md"
  if [[ -s "$spec_path" ]]; then
    audit_prompt+="

The session specification records what the user actually asked for; judge the plan's scope against it.

<spec>
$(cat "$spec_path")
</spec>"
  fi

  if [[ -n "$context" ]]; then
    audit_prompt+="

Crucial context from the orchestrator (source paths, decisions already made, constraints):

<context>
$context
</context>"
  fi

  # Run the read-only reviewer agent on the review model (CEREBRO_REVIEW_MODEL,
  # overridable per call with --model). Its findings are its final message,
  # which we capture and write to out_path; the JSON event stream is tee'd to
  # child_log. The session id is persisted at startup so an interrupt stays
  # resumable. The reviewer runs under CEREBRO_REVIEW_BACKEND (opencode by
  # default).
  local agent; agent="$(review_child_agent_name audit)"
  local rc id_capture out_capture; id_capture="$(mktemp)"; out_capture="$(mktemp)"

  child_store_begin "$ckey" "$(review_backend)" audit "$repo" "$out_name" "$child_log" "${prior:+preserve-id}"
  review_child_run 0 "$repo" "$audit_prompt" "$agent" "$prior" \
    "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "${model:-$CEREBRO_REVIEW_MODEL}"
  rc=$?

  # Stale fallback: a resume the model no longer recognizes fails before any
  # event (empty id capture); retry once fresh in that case only.
  if (( rc != 0 )) && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
    log_event "audit_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "audit: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$id_capture"
    child_store_begin "$ckey" "$(review_backend)" audit "$repo" "$out_name" "$child_log"
    review_child_run 0 "$repo" "$audit_prompt" "$agent" "" \
      "$child_log" "$out_capture" "$id_capture" "$store_file" "$ckey" "${model:-$CEREBRO_REVIEW_MODEL}"
    rc=$?
  fi

  # The findings are the run's closing message; write them to out_path.
  if (( rc == 0 )) && [[ -s "$out_capture" ]]; then
    cp "$out_capture" "$out_path"
  fi
  local _cap_id; _cap_id="$(cat "$id_capture" 2>/dev/null || true)"
  rm -f "$id_capture"

  # On any failure -- non-zero exit OR empty findings -- preserve the event log
  # but do NOT echo a findings path. The orchestrator must not treat a failed
  # audit's output as findings. Mark the child-store entry done ONLY when no
  # session id was captured (a stall / no-events / dead-session failure that
  # cannot be resumed, so a re-issue must start fresh instead of hanging on a
  # dead --resume); a failed run that DID capture an id stays resumable.
  if (( rc != 0 )) || [[ ! -s "$out_path" ]]; then
    rm -f "$out_capture"
    # Mark done on a stall (rc=5, dead session) or when no id was captured;
    # a failed run that captured an id stays resumable.
    [[ -z "$_cap_id" || $rc -eq 5 ]] && child_store_done "$ckey"
    log_event "audit_failed" "rc=$rc log=$child_log out=$out_path"
    warn "audit: review run failed (rc=$rc)"
    [[ -s "$child_log" ]] && warn "see event log: $child_log"
    child_fail_stderr "$child_log"
    die "audit: review run failed; not echoing a findings path"
  fi

  child_store_done "$ckey"
  rm -f "$out_capture"

  log_event "audit_written" "$out_path"
  echo "$out_path"
}
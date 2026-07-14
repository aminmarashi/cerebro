# cerebro lib: commands/detach
# subcommand: detach (launch a long-running cerebro child independently)
# Sourced by bin/cerebro; not meant to be executed directly.


# ----- subcommand: cerebro detach --output <path> -- <subcommand> [...] -----
# Launch a long-running cerebro subcommand outside the calling agent harness's
# process group. Agent-tool background jobs have finite lifetimes; without this
# boundary, their cleanup can kill an otherwise healthy paired child.
cmd_detach() {
  require_session
  command -v python3 >/dev/null 2>&1 || die "detach: missing required command on PATH: python3"

  [[ "${1:-}" == "--output" && -n "${2:-}" ]] \
    || die "usage: cerebro detach --output <absolute-path> -- <subcommand> [...]"
  local output="$2"
  shift 2
  [[ "${1:-}" == "--" ]] || die "detach: expected -- before the subcommand"
  shift
  [[ $# -gt 0 ]] || die "detach: missing subcommand"
  [[ "$output" == /* ]] || die "detach: output path must be absolute"

  case "$1" in
    audit|improve|execute|review|apply-review|verify|doc-write) ;;
    *) die "detach: '$1' is not a long-running child subcommand" ;;
  esac

  local scratch="/tmp/cerebro-$CEREBRO_SESSION_ID"
  case "$output" in
    "$scratch"/*|"$CEREBRO_SESSION_DIR"/*) ;;
    *) die "detach: output must be under $scratch or $CEREBRO_SESSION_DIR" ;;
  esac

  if [[ -r "$output.status" && "$(cat "$output.status" 2>/dev/null)" == "running" \
        && -r "$output.pid" ]]; then
    local active_pid
    active_pid="$(cat "$output.pid" 2>/dev/null)"
    if [[ "$active_pid" =~ ^[0-9]+$ ]] && kill -0 "$active_pid" 2>/dev/null; then
      die "detach: output already belongs to running pid $active_pid: $output"
    fi
  fi

  local jobs_dir="$CEREBRO_SESSION_DIR/detached-jobs" job_id job_file
  mkdir -p "$jobs_dir"
  job_id="$(mint_uuid)"
  job_file="$jobs_dir/$job_id.json"

  python3 "$CEREBRO_LIB_DIR/python/detach_process.py" \
    "$output" "$output.status" "$output.pid" "$job_file" "$job_id" "$1" \
    "$CEREBRO_LIB_DIR/../bin/cerebro" "$@"
}


# ----- subcommand: cerebro wait <detached-status-path> ----------------------
# Block until a detached monitor records its final exit code. This command is
# safe to put in an agent harness's managed background mode: it owns no child,
# so harness cleanup can only kill the disposable waiter.
cmd_wait() {
  require_session
  command -v python3 >/dev/null 2>&1 || die "wait: missing required command on PATH: python3"
  [[ $# -eq 1 ]] || die "usage: cerebro wait <job-id|absolute-output.status>"

  local status pid_path scratch="/tmp/cerebro-$CEREBRO_SESSION_ID"
  if [[ "$1" == /* ]]; then
    status="$1"
    [[ "$status" == *.status ]] || die "wait: path must end in .status"
    case "$status" in
      "$scratch"/*|"$CEREBRO_SESSION_DIR"/*) ;;
      *) die "wait: status must be under $scratch or $CEREBRO_SESSION_DIR" ;;
    esac
    pid_path="${status%.status}.pid"
  else
    [[ "$1" =~ ^[0-9a-fA-F-]+$ ]] || die "wait: invalid job id: $1"
    local job_file="$CEREBRO_SESSION_DIR/detached-jobs/$1.json"
    [[ -r "$job_file" ]] || die "wait: no such detached job: $1"
    status="$(jq -r '.status // empty' "$job_file")"
    pid_path="$(jq -r '.pid_file // empty' "$job_file")"
    [[ -n "$status" && -n "$pid_path" ]] || die "wait: malformed detached job: $1"
  fi

  python3 "$CEREBRO_LIB_DIR/python/wait_detached.py" \
    "$status" "$pid_path"
}


# ----- subcommand: cerebro jobs --------------------------------------------
# List every detached job registered to this parent session, including jobs
# that completed while the interactive parent was not running.
cmd_jobs() {
  require_session
  local jobs_dir="$CEREBRO_SESSION_DIR/detached-jobs"
  python3 "$CEREBRO_LIB_DIR/python/detached_jobs.py" list "$jobs_dir"
}


# ----- subcommand: cerebro cancel <job-id> ---------------------------------
# Stop a detached job and its full descendant tree. Descendant discovery is
# PID-based rather than process-group-only because paired Claude children create
# their own process group for targeted stall cleanup.
cmd_cancel() {
  require_session
  [[ $# -eq 1 && "$1" =~ ^[0-9a-fA-F-]+$ ]] \
    || die "usage: cerebro cancel <detached-job-id>"
  local job_file="$CEREBRO_SESSION_DIR/detached-jobs/$1.json"
  [[ -r "$job_file" ]] || die "cancel: no such detached job: $1"
  python3 "$CEREBRO_LIB_DIR/python/detached_jobs.py" cancel "$job_file"
}

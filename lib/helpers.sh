# cerebro lib: helpers
# small shared helpers: say/warn/die, error codes, path + repo resolution, usage
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- helpers --------------------------------------------------------------

say()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'cerebro: warning: %s\n' "$*" >&2; }
die()  { printf 'cerebro: error: %s\n' "$*" >&2; exit 1; }
dbg()  { [[ "$CEREBRO_DEBUG" == "1" ]] && printf 'cerebro: debug: %s\n' "$*" >&2; return 0; }

# child_fail_stderr <child_log> -- emit a tail of the child's stderr sidecar
# (next to <child_log>, named <child_log>.err.log) to stderr, when it is
# non-empty. Used by audit/review/execute/apply-review/doc-write/verify on a
# non-zero child_run exit so a stalled or errored child is diagnosable
# (provider auth error, model unavailable, rate limit, stale resume id)
# instead of silent. Sidecar is written by backend_*_child_run (replaces the
# old 2>/dev/null that discarded all provider stderr).
child_fail_stderr() {
  local child_log="$1"
  local err_log="${child_log%.log}.err.log"
  [[ -s "$err_log" ]] || return 0
  local tail_out
  tail_out="$(tail -n 15 "$err_log" 2>/dev/null)"
  [[ -n "$tail_out" ]] || return 0
  warn "child stderr (tail of $err_log):"
  printf '%s\n' "$tail_out" | sed 's/^/    /' >&2
}

# Error helpers for the read-only bridge subcommands (git/gh/read/grep/ls).
# Exit codes are documented in the orchestrator's system prompt so the model
# can interpret them programmatically.
# NOTE: parse_stream.py (the child stream parser) also uses small exit codes
# for its own outcomes -- 2 = no stream events, 3 = no closing message,
# 4 = child reported an error event, 5 = child stalled (no stream events for
# CEREBRO_CHILD_IDLE_TIMEOUT seconds). Those are reported by the calling
# cerebro command (audit/review/execute/...) in its own failure message, so
# the two namespaces do not collide at the orchestrator boundary.
err_usage()  { printf 'cerebro: error: %s\n' "$*" >&2; exit 2; }
err_path()   { printf 'cerebro: error: %s\n' "$*" >&2; exit 3; }
err_subcmd() { printf 'cerebro: error: %s\n' "$*" >&2; exit 4; }
err_flag()   { printf 'cerebro: error: %s\n' "$*" >&2; exit 5; }
err_escape() { printf 'cerebro: error: %s\n' "$*" >&2; exit 6; }

# Benign "target does not exist / wrong type" outcome for the read-only
# EXPLORATION bridges (read/ls/grep). Default: print a machine-recognizable
# marker to stdout and exit 0, so a missing probe target during a parallel
# fan-out is a successful empty result, not a cascade-triggering failure.
# With strict=1 (--strict-missing), restore the old behavior: stderr + exit 3.
#   $1 = strict (0|1)   $2 = marker (stdout)   $3 = error message (stderr, strict)
missing_target() {
  local strict="$1" marker="$2" msg="$3"
  if [[ "$strict" == "1" ]]; then
    printf 'cerebro: error: %s\n' "$msg" >&2
    exit 3
  fi
  printf '%s\n' "$marker"
  exit 0
}

# True if $1 is among the remaining args.
contains() {
  local needle="$1"; shift
  local hay
  for hay in "$@"; do [[ "$hay" == "$needle" ]] && return 0; done
  return 1
}

# Resolve path $2 relative to repo $1, requiring the result to stay inside
# the repo. Echoes the absolute resolved path on stdout. Exits 6 if the path
# escapes. Uses python3 for cross-platform realpath (macOS lacks GNU realpath).
resolve_in_repo() {
  python3 "$CEREBRO_LIB_DIR/python/resolve_in_repo.py" "$1" "$2"
}

# Validate that $1 is an absolute path to a git repo. Exits 3 on any failure.
require_git_repo() {
  local repo="$1"
  [[ "$repo" = /* ]] || err_path "repo path must be absolute: $repo"
  [[ -d "$repo" ]]   || err_path "repo not a directory: $repo"
  git --no-optional-locks -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || err_path "not a git repo: $repo"
}

# Canonicalize $1 to its git worktree root and echo it on stdout. Exits 3
# if $1 is not an absolute directory inside a git worktree. Bridges that
# read files from the user's repo (read/grep/ls) call this to anchor
# subsequent path resolution to the worktree boundary instead of trusting
# an arbitrary absolute directory.
canonical_worktree_root() {
  local repo="$1"
  [[ "$repo" = /* ]] || err_path "repo path must be absolute: $repo"
  [[ -d "$repo" ]]   || err_path "repo not a directory: $repo"
  local root
  root="$(git --no-optional-locks -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || err_path "not a git worktree: $repo"
  [[ -n "$root" ]] || err_path "not a git worktree: $repo"
  printf '%s\n' "$root"
}

# Echo the per-repo state key (sha1 of canonical worktree root, 16 hex).
# Returns non-zero (and prints nothing) when $1 is not a git worktree, so
# callers can treat a non-repo argument as "no key".
repo_state_key() {
  local canonical
  canonical="$(git --no-optional-locks -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$canonical" ]] || return 1
  python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])' "$canonical"
}

# Walk upward from an absolute path looking for an enclosing git worktree
# (a directory containing a `.git` file or directory). Echoes the worktree
# root on stdout if found; returns non-zero (and prints nothing) otherwise.
# Bounded to 12 levels so we don't traverse the entire filesystem.
find_enclosing_worktree() {
  local p="$1"
  [[ "$p" = /* ]] || return 1
  python3 "$CEREBRO_LIB_DIR/python/find_enclosing_worktree.py" "$p" 2>/dev/null
}

# Resolve $1 (an absolute path) for a bare-abs read/grep/ls invocation.
# Echoes the realpathed result on stdout. Exit codes: 3 if not absolute
# (internal misuse only); 6 if it resolves under /dev /proc /sys (special
# filesystems / blocking devices) -- a security refusal callers MUST keep
# hard; 7 for a benign missing path or wrong type (no regular file or
# directory: FIFO, socket, char/block device) which callers may translate
# into a successful empty result. The in-repo escape guard in
# resolve_in_repo() does NOT apply -- this branch deliberately reads
# outside any repo.
resolve_bare_abs() {
  python3 "$CEREBRO_LIB_DIR/python/resolve_bare_abs.py" "$1"
}

# Map common short rg --type aliases to the canonical rg type name. Unknown
# inputs are passed through verbatim so rg emits its own diagnostic.
canonicalise_rg_type() {
  case "$1" in
    rs)  printf 'rust\n' ;;
    tsx) printf 'ts\n' ;;
    jsx) printf 'js\n' ;;
    yml) printf 'yaml\n' ;;
    rb)  printf 'ruby\n' ;;
    kt)  printf 'kotlin\n' ;;
    *)   printf '%s\n' "$1" ;;
  esac
}

usage() {
  cat <<'EOF'
usage:
  cerebro                       # start a new session (interactive chat)
  cerebro --resume [<id>]       # resume a session (id, or most recent if omitted)
  cerebro --observe [<id>]      # watch-and-steer-only session for another's
                                #   live paired children (id, or auto-pick)
  cerebro list                  # list sessions, newest first
  cerebro --help                # this help

cerebro launches a native interactive agent chat -- opencode or claude,
selected by CEREBRO_BACKEND -- configured as an orchestrator. The
orchestrator drives the plan -> execute -> review loop by calling
`cerebro <subcommand>` against your repositories on your behalf. You stay
in the chat -- you don't type the sub-commands yourself.

The orchestrator runs with a restricted tool surface: read/grep/glob plus
bash limited to `cerebro ...` (no edit, no write, no subagent delegation).
Every git/gh action and every file edit happens inside a short-lived
sub-agent that cerebro spawns; the orchestrator itself can't touch repos
directly. The read-only reviewer runs under CEREBRO_REVIEW_BACKEND (opencode
by default) on a suggested-different model (CEREBRO_REVIEW_MODEL),
regardless of the editing backend; any subcommand's --model flag overrides
the default per call, and `cerebro models` lists the user's model catalog
($CEREBRO_HOME/models-config.json) with capability tags so the
orchestrator can pick a model per task (e.g. a vision-capable model for
screenshot verification).

Notes:
  * Interactive-only. cerebro refuses to run under a non-terminal parent
    (pipes, scripts, cron). Sub-agents launched by the orchestrator are
    exempt via $CEREBRO_SESSION_ID.
  * Concurrency. cerebro has no concurrency control: it will not stop
    you from running two mutating ops against the same repo at once,
    within or across sessions. Sequence your own mutating work.
  * No chat/PR/repo-specific flags are ever passed to the agent CLI. The
    orchestrator addresses repos by absolute path as the first positional
    arg to its sub-agent tools.
  * Paused children. A spawned child (execute / apply-review /
    doc-write) runs non-interactively and cannot ask questions mid-run.
    When it hits a genuine blocker it ends with its question as its final
    message; the orchestrator answers it (from the spec/recall, or by
    asking you) and resumes the SAME child session with
    `cerebro answer <child-session-id> "<answer>"`, so the child
    continues where it paused.
  * Pair programming. Ask the orchestrator to "pair" (or watch / steer)
    an execute, apply-review, or doc-write child and it adds
    `--pair`: the child runs with live steering so you can WATCH it live
    from ANOTHER cerebro session -- ask that session to "observe <the
    paired session's id>" and it narrates, in plain English, what every
    live paired child is doing (and steers on your command) -- and STEER
    it directly with `cerebro steer "<message>"` (a one-shot inject that
    returns at once; pass the pipe path from the PAIR MODE banner as a
    first arg when several run at once). The child runs to completion on
    its own; after each turn it waits a short window (CEREBRO_PAIR_IDLE,
    default 60s) for steering, and a quiet window finishes it. If the
    child stream freezes, cerebro kills only that child and restarts it
    with --resume, bounded by CEREBRO_PAIR_STALL_RETRIES. Each steering
    message is injected into the running session and recorded; when the
    child ends the orchestrator folds your steering into the session
    spec and the upcoming plans, then tells you what changed.
  * Observe-only sessions. `cerebro --observe [<id>]` opens an interactive
    chat whose sole job is to watch and narrate another session's live
    paired children (and steer them on your command). Its tools are
    narrowed to `cerebro observe`/`steer` plus read-only commands, so it
    makes no direct repo changes -- it is the pair-programming "watcher"
    seat as a first-class session instead of a mode you ask for mid-chat.
  * Backends. CEREBRO_BACKEND selects the agent CLI for the orchestrator
    + editing children: `opencode` (default) or `claude`. CEREBRO_REVIEW_BACKEND
    independently selects the CLI for the read-only reviewer (review / audit /
    verify / improve): `opencode` (default) or `claude`, so the reviewer can
    run under a different backend than the editor. The editing backend is
    recorded in each session's metadata, so resuming a session always reuses
    the backend it started with. Under `claude`, CEREBRO_CLAUDE_BASE_URL optionally
    points every spawned `claude` at a custom Anthropic-compatible endpoint
    (a local Ollama `/v1/messages` server, or any proxy/gateway) instead of
    the claude.ai subscription; empty (the default) keeps the subscription.
    CEREBRO_MODEL then names a model the endpoint serves; when the reviewer
    runs under claude, CEREBRO_REVIEW_MODEL names the review model the endpoint
    serves.

Requirements: jq, python3 on PATH, plus opencode and/or claude depending on
the configured backends (opencode is required when CEREBRO_BACKEND or
CEREBRO_REVIEW_BACKEND is opencode; claude when either is claude). Child
runs additionally need git and gh on PATH for execute / apply-review /
doc-write.

Options (env var or key in $CEREBRO_HOME/config.json; env wins over the file
which wins over the default): CEREBRO_HOME (env-only), CEREBRO_BACKEND,
CEREBRO_REVIEW_BACKEND, CEREBRO_MODEL, CEREBRO_REVIEW_MODEL, CEREBRO_TIMEOUT,
CEREBRO_CHILD_IDLE_TIMEOUT, CEREBRO_OPENCODE_CMD, CEREBRO_CLAUDE_CMD,
CEREBRO_CLAUDE_BASE_URL, CEREBRO_CLAUDE_AUTH_TOKEN, CEREBRO_OVERLAY_CAP,
CEREBRO_META_HORIZON, CEREBRO_CHILD_SESSION_TTL,
CEREBRO_PAIR_IDLE, CEREBRO_PAIR_STALL, CEREBRO_PAIR_STALL_BUSY,
CEREBRO_PAIR_STALL_RETRIES, CEREBRO_PAIR_STALL_BACKOFF, CEREBRO_DEBUG.
See `cerebro --help` and docs/USAGE.md for the full table.
EOF
}

# Interactive guard -- only runs for top-level invocations from a shell.
# Sub-agents spawned by the orchestrator have CEREBRO_SESSION_ID set and
# bypass this check; that's how `cerebro plan`, `cerebro execute`, ...
# can run inside the orchestrator's non-TTY Bash tool.
require_interactive() {
  [[ -n "${CEREBRO_SESSION_ID:-}" ]] && return 0
  if [[ ! -t 0 || ! -t 1 ]]; then
    die "cerebro is interactive-only; stdin and stdout must be terminals"
  fi
  local parent
  parent="$(ps -o comm= -p "$PPID" 2>/dev/null | awk '{print $1}')"
  parent="${parent##*/}"
  case "$parent" in
    -bash|bash|-zsh|zsh|-fish|fish|-sh|sh|-dash|dash|-ksh|ksh|-tcsh|tcsh) ;;
    tmux*|screen*|login|sshd) ;;
    *) die "cerebro is interactive-only; refused to run under parent '$parent'" ;;
  esac
}

require_deps() {
  local cmd
  # jq + python3 are always required. opencode is required when the editing
  # backend OR the review backend is opencode (the read-only reviewer runs
  # under CEREBRO_REVIEW_BACKEND, opencode by default); claude is required
  # when either backend is claude. So a run with CEREBRO_BACKEND=claude and
  # CEREBRO_REVIEW_BACKEND=claude needs no opencode at all.
  local need_opencode=0 need_claude=0
  [[ "$(current_backend)"  == "opencode" ]] && need_opencode=1
  [[ "$(review_backend)"   == "opencode" ]] && need_opencode=1
  [[ "$(current_backend)"  == "claude"   ]] && need_claude=1
  [[ "$(review_backend)"   == "claude"   ]] && need_claude=1
  for cmd in jq python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command on PATH: $cmd"
  done
  if (( need_opencode )); then
    command -v "$CEREBRO_OPENCODE_CMD" >/dev/null 2>&1 \
      || die "missing required command on PATH: $CEREBRO_OPENCODE_CMD (needed: CEREBRO_BACKEND or CEREBRO_REVIEW_BACKEND is opencode)"
  fi
  if (( need_claude )); then
    command -v "$CEREBRO_CLAUDE_CMD" >/dev/null 2>&1 \
      || die "missing required command on PATH: $CEREBRO_CLAUDE_CMD (needed: CEREBRO_BACKEND or CEREBRO_REVIEW_BACKEND is claude)"
  fi
}

# cerebro binds an interactive agent process to its session by exporting
# CEREBRO_SESSION_ID into that process; the backend's bash tool inherits the
# env, so every `cerebro <subcommand>` the orchestrator runs sees it. A session
# is therefore always identified by that env var. The claude backend
# additionally writes a current-session symlink from its UserPromptSubmit hook
# (the bare `cerebro --resume` fallback when CEREBRO_SESSION_ID is unset).
require_session() {
  [[ -n "${CEREBRO_SESSION_ID:-}" ]] || {
    # Bare-resume fallback (claude backend): hook writes a current-session
    # symlink on first user prompt, pointing at sessions/<id>/.
    if [[ -L "$CEREBRO_HOME/current-session" ]]; then
      local target
      target="$(readlink "$CEREBRO_HOME/current-session")"
      target="${target##*/}"
      [[ -n "$target" ]] && export CEREBRO_SESSION_ID="$target"
    fi
  }
  [[ -n "${CEREBRO_SESSION_ID:-}" ]] || die "no current cerebro session (CEREBRO_SESSION_ID unset and no current-session symlink). Did you launch this from a \`cerebro\` shell?"
  CEREBRO_SESSION_DIR="$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID"
  [[ -d "$CEREBRO_SESSION_DIR" ]] || die "session dir missing: $CEREBRO_SESSION_DIR"
  export CEREBRO_SESSION_DIR
  # Read the recorded backend back so child commands dispatch through the right
  # implementation even when CEREBRO_BACKEND is not set in this shell (e.g. a
  # subcommand spawned by an orchestrator whose session started under a
  # different backend than the current env default).
  CEREBRO_RESUME_BACKEND="$(session_backend "$CEREBRO_SESSION_DIR")"
  export CEREBRO_RESUME_BACKEND
}

mint_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

ts_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ts_compact() { date -u +%Y%m%dT%H%M%SZ; }

# Build a collision-resistant child-log path under the session's children/
# dir. We allow concurrent mutating runs (no per-repo lock), so two
# same-session invocations can start within the same second; a bare
# <subcmd>-<ts> name would let them share one file and produce truncated or
# interleaved logs. Keep the human-readable <subcmd>-<ts> prefix but append
# the PID plus a random token so each invocation gets a distinct file.
child_log_path() {
  local subcmd="$1"
  printf '%s\n' "$CEREBRO_SESSION_DIR/children/${subcmd}-$(ts_compact)-$$-${RANDOM}.jsonl"
}

# Surface a child's final message to the orchestrator on stdout. A child runs
# non-interactively, so when it pauses on a genuine blocker it ends with its
# QUESTION as its closing message rather than completing the work. The mutating
# children otherwise discard that text (they push commits, not output), so we
# capture it and print it under a clear marker. The orchestrator reads this to
# decide whether the child finished or is waiting on an answer (see the
# "child stops to ask a question" rule in its system prompt).
#   $1 = file holding the child's final result text   $2 = role label
#   $3 = optional child provider session id for `cerebro answer`
surface_child_reply() {
  local f="$1" role="$2" child_id="${3:-}"
  [[ -s "$f" ]] || return 0
  printf -- '----- %s child closing message (read it: a question here means the child PAUSED for an answer) -----\n' "$role"
  if [[ -n "$child_id" ]]; then
    printf 'child session: %s\n' "$child_id"
    printf 'answer with: cerebro answer %s "<answer>"\n\n' "$child_id"
  fi
  cat "$f"
  printf -- '\n----- end %s child closing message -----\n' "$role"
}

# Append a structured event to the active session's transcript.
log_event() {
  local what="$1"; shift || true
  local extra="${1:-}"
  [[ -z "${CEREBRO_SESSION_DIR:-}" ]] && return 0
  local file="$CEREBRO_SESSION_DIR/transcript.jsonl"
  jq -nc --arg ts "$(ts_iso)" --arg what "$what" --arg extra "$extra" \
    '{kind:"event", ts:$ts, what:$what} + (if $extra == "" then {} else {detail:$extra} end)' \
    >> "$file" 2>/dev/null || true
}

# Timeout fallback chain (copied from bin/tai).
# CEREBRO_TIMEOUT unset/empty/0/none/unlimited => no cap: run the child
# directly (TIMEOUT_CMD=(env)), so the perl alarm path can never fire.
# Only a positive integer arms timeout/gtimeout/perl.
build_timeout_cmd() {
  case "${CEREBRO_TIMEOUT:-0}" in
    ''|0|none|unlimited|NONE|UNLIMITED)
      TIMEOUT_CMD=(env)
      return 0
      ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "$CEREBRO_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout "$CEREBRO_TIMEOUT")
  elif command -v perl >/dev/null 2>&1; then
    TIMEOUT_CMD=(perl -e 'alarm shift; exec @ARGV' "$CEREBRO_TIMEOUT")
  else
    TIMEOUT_CMD=(env)
  fi
}

# Write the shared home payloads, then the backend-specific extras. The
# opencode config tree ($CEREBRO_HOME/.opencode: agents + plugin + base config)
# is ALWAYS written: the reviewer defaults to opencode (CEREBRO_REVIEW_BACKEND)
# and the opencode editing backend's children + orchestrator agent files live
# there too, so the tree is needed in the common case even when the editing
# backend is claude. Idempotent: managed files are overwritten only when their
# content differs.
#
# Agent files contain ONLY the static shipped prompts. User-owned learnings
# and overlays are kept in their own files under $CEREBRO_HOME so the model can
# read them when needed; they are NOT mixed into the agent body. Keeping the
# agent files byte-for-byte stable across launches lets the backend cache the
# system prompt.
materialise_home() {
  mkdir -p "$CEREBRO_HOME/.opencode/agent" "$CEREBRO_HOME/.opencode/plugin" \
    "$CEREBRO_HOME/sessions" "$CEREBRO_HOME/templates" "$CEREBRO_HOME/overlays" \
    || die "cannot create $CEREBRO_HOME"

  # Shared system prompt (read by the claude backend; also the core of the
  # opencode orchestrator agent).
  write_if_changed "$CEREBRO_HOME/system-prompt.md" "$(cerebro_system_prompt)"

  # The opencode config tree is shared: the reviewer agent always runs under
  # opencode, and the opencode editing backend's child agents live here too.
  write_if_changed "$CEREBRO_HOME/.opencode/opencode.json" "$(cerebro_opencode_json)"
  write_if_changed "$CEREBRO_HOME/.opencode/plugin/cerebro.js" "$(cerebro_plugin_js)"

  # Orchestrator + observer agents: static bodies so the backend can cache.
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-orchestrator.md" \
    "$(orchestrator_agent_file)"
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-observer.md" \
    "$(observer_agent_file)"

  local role
  for role in execute apply-review doc-write; do
    write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-$role.md" \
      "$(child_agent_file "$role")"
  done
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-verify.md" \
    "$(verify_agent_file)"
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-reviewer.md" \
    "$(reviewer_agent_file)"

  # Templates are user-editable defaults: write only when the file is missing
  # so a user who customizes ~/.cerebro/templates/AGENTS.md isn't clobbered on
  # the next launch.
  write_if_missing "$CEREBRO_HOME/templates/AGENTS.md" "$(cerebro_default_agents_md)"

  # Backend-specific extras (claude: hook + settings.local.json + CLAUDE.md
  # template; opencode: none beyond the shared tree above).
  backend_materialise_extras
}

write_if_changed() {
  local path="$1" content="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    return 0
  fi
  printf '%s' "$content" > "$path"
}

write_if_missing() {
  local path="$1" content="$2"
  [[ -f "$path" ]] && return 0
  printf '%s' "$content" > "$path"
}

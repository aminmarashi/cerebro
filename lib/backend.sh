# cerebro lib: backend
# The single seam between cerebro's command modules and the agent CLI that
# runs the orchestrator + mutating children (execute / apply-review /
# doc-write / answer) via the editing backend (CEREBRO_BACKEND), and the
# read-only reviewer (review / audit / verify / improve) via the reviewer
# backend (CEREBRO_REVIEW_BACKEND, opencode by default) through the
# review_child_run / review_child_agent_name selectors below.
#
# Two backends implement the contract:
#   opencode (default) -- `opencode run --agent` / `opencode --agent`
#   claude             -- `claude -p` / `claude --resume`
#
# Each backend defines:
#   backend_<name>_child_run_opts <agent> <resume-id> <model>
#   backend_<name>_child_run <pair> <cwd> <prompt> <agent> <resume-id> <child_log>
#       <msg_capture> <id_capture> <store_file> <ckey> [model]
#   backend_<name>_child_agent_name <role>          -- the agent identifier
#   backend_<name>_child_provider <role>            -- provider string for the store
#   backend_<name>_materialise_extras               -- write backend-only home files
#   backend_<name>_launch_orchestrator <sess_dir> <agent-name-or-prompt>
#   backend_<name>_launch_observer <sess_dir> <agent-name-or-prompt> <target>
#   backend_<name>_resume_orchestrator <sess_dir> <foreign-id> <agent-name-or-prompt>
#   backend_<name>_answerable_provider <role>        -- provider:role pattern the
#       `cerebro answer` guard accepts for this backend
#   backend_<name>_pair_begin <role> <repo> <branch> <child_log> <resume>
#   backend_<name>_pair_run <cwd> <prompt> <agent> <resume> <child_log>
#       <msg_capture> <id_capture> <store_file> <ckey> [model]
#   backend_<name>_pair_cleanup <pair>
#
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- backend selection ----------------------------------------------------

# current_backend -- echo the active backend for this process. For a top-level
# launch it is CEREBRO_BACKEND; for a resumed/child command it is read back from
# the session metadata (set by require_session into CEREBRO_RESUME_BACKEND).
current_backend() {
  printf '%s' "${CEREBRO_RESUME_BACKEND:-${CEREBRO_BACKEND:-opencode}}"
}

# review_backend -- echo the backend the read-only reviewer (review / audit /
# verify / improve) runs under, independent of the editing backend so the
# reviewer can use a different CLI (e.g. claude) than the orchestrator +
# editing children. Defaults to opencode (the historical behavior). Like
# current_backend, this only echoes -- a bad value surfaces as a
# `command not found` from the dispatched function, matching the editing
# backend's failure mode. NOT read from session metadata: the reviewer is
# ephemeral and a backend mismatch on resume falls back to a fresh run via the
# existing stale-fallback, so the env var at runtime is sufficient.
review_backend() {
  printf '%s' "${CEREBRO_REVIEW_BACKEND:-opencode}"
}

# review_child_agent_name <role> -- the agent identifier the reviewer backend
# uses to select a reviewer's role. opencode: an agent name (cerebro-reviewer /
# cerebro-verify); claude: the role label itself (composed inline via
# --append-system-prompt). Dispatched to the reviewer backend, not the editing
# backend, so the reviewer is backend-selectable independently of CEREBRO_BACKEND.
review_child_agent_name() {
  "backend_$(review_backend)_child_agent_name" "$@"
}

# review_child_run <pair> <cwd> <prompt> <agent> <resume-id> <child_log>
#   <msg_capture> <id_capture> <store_file> <ckey> [model] -- run one attempt
# of a reviewer child (review / audit / verify / improve) through the reviewer
# backend and return its exit code. Same contract as backend_child_run but
# dispatched to review_backend (default opencode), so the read-only reviewer is
# backend-selectable independently of CEREBRO_BACKEND. <model> defaults to
# CEREBRO_REVIEW_MODEL at the call sites.
review_child_run() {
  "backend_$(review_backend)_child_run" "$@"
}

# backend_is <name> -- true when the active backend is <name>.
backend_is() { [[ "$(current_backend)" == "$1" ]]; }

# backend_child_run_opts <agent> <resume-id> <model> -- dispatch to the active
# backend's flag builder. Populates the caller-scoped CHILD_RUN_OPTS array.
backend_child_run_opts() {
  "backend_$(current_backend)_child_run_opts" "$@"
}

# backend_child_run <pair> <cwd> <prompt> <agent> <resume-id> <child_log>
#   <msg_capture> <id_capture> <store_file> <ckey> [model] -- run one attempt of
# a child through the active backend and return its exit code.
backend_child_run() {
  "backend_$(current_backend)_child_run" "$@"
}

# backend_child_agent_name <role> -- the agent identifier the active backend
# uses to select a child's role. opencode: an agent name (cerebro-<role>);
# claude: the role label itself (the prompt is passed inline instead).
backend_child_agent_name() {
  "backend_$(current_backend)_child_agent_name" "$@"
}

# backend_child_provider <role> -- the provider string written to the child
# session store for a child of <role> under the active backend.
backend_child_provider() {
  "backend_$(current_backend)_child_provider" "$@"
}

# backend_answerable_pattern <role> -- the provider:role pattern the `cerebro
# answer` guard accepts for this backend.
backend_answerable_pattern() {
  "backend_$(current_backend)_answerable_provider" "$@"
}

# backend_materialise_extras -- write backend-only home files after the shared
# materialise_home (opencode agents/plugin, claude hook/settings).
backend_materialise_extras() {
  "backend_$(current_backend)_materialise_extras"
}

# backend_launch_orchestrator <sess_dir> <agent-or-prompt-file> -- exec the
# interactive orchestrator under the active backend. <agent-or-prompt-file> is
# the agent name for opencode or the path to the static system-prompt.md for
# claude. Never returns (execs).
backend_launch_orchestrator() {
  "backend_$(current_backend)_launch_orchestrator" "$@"
}

# backend_launch_observer <sess_dir> <agent-or-prompt> <target> -- exec the
# interactive observer session under the active backend. <target> is the
# optional target session id (empty when none). Never returns (execs).
backend_launch_observer() {
  "backend_$(current_backend)_launch_observer" "$@"
}

# backend_resume_orchestrator <sess_dir> <foreign-id> <agent-or-prompt-file> --
# exec the resumed orchestrator. <foreign-id> is the provider conversation id
# (may be empty, in which case the backend starts a fresh conversation in the
# same cerebro session dir). For claude, <agent-or-prompt-file> is the path to
# the static system-prompt.md. Never returns (execs).
backend_resume_orchestrator() {
  "backend_$(current_backend)_resume_orchestrator" "$@"
}

# backend_pair_begin <role> <repo> <branch> <child_log> <resume> -- prepare a
# paired child under the active backend. Sets the caller-scoped PAIR_* vars the
# backend's pair_run needs.
backend_pair_begin() {
  "backend_$(current_backend)_pair_begin" "$@"
}

# backend_pair_run <cwd> <prompt> <agent> <resume> <child_log> <msg_capture>
#   <id_capture> <store_file> <ckey> [model] -- drive a paired child to
# completion under the active backend.
backend_pair_run() {
  "backend_$(current_backend)_pair_run" "$@"
}

# backend_pair_cleanup <pair> -- tear down the paired-child transport.
backend_pair_cleanup() {
  "backend_$(current_backend)_pair_cleanup" "$@"
}

# The pair module (pair.sh) routes its backend-specific entry points through
# these wrappers so the command files stay backend-agnostic.
pair_begin()   { backend_pair_begin "$@"; }
pair_run()     { backend_pair_run "$@"; }
pair_cleanup() { backend_pair_cleanup "$@"; }

# child_run <pair> <cwd> <prompt> <agent> <resume-id> <child_log> <msg_capture>
#   <id_capture> <store_file> <ckey> [model] -- run one attempt of a child and
# return its exit code. Dispatches to the active backend's child_run, which
# handles both the paired (pair_run) and unpaired (direct launch + stream parse)
# paths. <model> defaults to CEREBRO_MODEL. The session-scoped env vars are
# stripped so the child is never mistaken for an orchestrator-context caller.
child_run() {
  local pair="$1" cwd="$2" prompt="$3" agent="$4" resume="$5" \
        child_log="$6" msg_capture="$7" id_capture="$8" store_file="$9" ckey="${10}"
  local model="${11:-$CEREBRO_MODEL}"
  "backend_$(current_backend)_child_run" "$pair" "$cwd" "$prompt" "$agent" "$resume" \
    "$child_log" "$msg_capture" "$id_capture" "$store_file" "$ckey" "$model"
  return $?
}
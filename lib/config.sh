# cerebro lib: config
# global config: set -uo pipefail and CEREBRO_* env defaults
# Sourced by bin/cerebro; not meant to be executed directly.

set -uo pipefail

CEREBRO_HOME="${CEREBRO_HOME:-$HOME/.cerebro}"
# Which agent backend drives the orchestrator + editing children:
#   opencode -- `opencode run --agent` (the opencode CLI)
#   claude    -- `claude -p` (the claude CLI)
# Recorded into each session's metadata.json at launch so a resumed session
# always reuses the backend it started with, regardless of the current env.
CEREBRO_BACKEND="${CEREBRO_BACKEND:-opencode}"
# The model the orchestrator and every editing child (execute / apply-review /
# doc-write / answer) run on. Captured separately as CEREBRO_DEFAULT_MODEL so
# the claude backend can tell when the user has overridden it for a custom
# endpoint (see CEREBRO_CLAUDE_BASE_URL below).
CEREBRO_DEFAULT_MODEL="github-copilot/gemini-3.1-pro-preview"
CEREBRO_MODEL="${CEREBRO_MODEL:-$CEREBRO_DEFAULT_MODEL}"
# The model the read-only reviewer/auditor (cerebro review / cerebro audit /
# cerebro verify / cerebro improve) runs on -- a SUGGESTED different model
# from the implementer, so the review can be a genuinely independent pair of
# eyes when a different model is configured. It is a suggestion, not a rule:
# leaving it equal to CEREBRO_MODEL is allowed (the reviewer's read-only
# confinement and fresh context still give it independence). Any subcommand
# can override either default per call with --model <provider/model>; the
# orchestrator discovers available models and their capabilities (e.g. vision
# for screenshot verification) via `cerebro models`, which reads the user's
# catalog at $CEREBRO_HOME/models-config.json. GPT-5.5 by default. The
# reviewer runs under CEREBRO_REVIEW_BACKEND (opencode by default); when that
# is opencode it needs opencode on PATH even if the editing children run
# under claude.
CEREBRO_REVIEW_MODEL="${CEREBRO_REVIEW_MODEL:-github-copilot/gpt-5.5}"
# The backend the read-only reviewer (review / audit / verify / improve) runs
# under, independent of CEREBRO_BACKEND so the reviewer can use a different CLI
# than the orchestrator + editing children. opencode (the default, unchanged)
# or claude. Not recorded in session metadata: the reviewer is ephemeral and a
# backend mismatch on resume falls back to a fresh run via the existing
# stale-fallback, so the env var at runtime is sufficient.
CEREBRO_REVIEW_BACKEND="${CEREBRO_REVIEW_BACKEND:-opencode}"
CEREBRO_TIMEOUT="${CEREBRO_TIMEOUT:-0}"   # 0/empty/none/unlimited = no cap
# Inactivity timeout (seconds) for the child stream parser: if a spawned child
# produces no new stream event for this window, parse_stream.py exits 5 with a
# "child stalled" diagnostic instead of blocking forever. A slow-but-progressing
# child (periodic events) is NOT killed -- the timer resets on every line. 0
# disables the inactivity bound (legacy blocking read). Default 180s.
CEREBRO_CHILD_IDLE_TIMEOUT="${CEREBRO_CHILD_IDLE_TIMEOUT:-180}"
CEREBRO_OPENCODE_CMD="${CEREBRO_OPENCODE_CMD:-opencode}"
CEREBRO_CLAUDE_CMD="${CEREBRO_CLAUDE_CMD:-claude}"
CEREBRO_DEBUG="${CEREBRO_DEBUG:-0}"
# Optional custom Anthropic-compatible endpoint for the claude backend (e.g. a
# local Ollama server exposing /v1/messages, or any proxy/gateway). Empty (the
# default) = use the claude.ai subscription `claude` is logged into -- the
# existing subscription path, unchanged. When CEREBRO_CLAUDE_BASE_URL is set,
# backend_claude_endpoint_env (lib/backend-claude.sh) exports ANTHROPIC_BASE_URL
# and ANTHROPIC_AUTH_TOKEN into every spawned `claude` process, unsets
# ANTHROPIC_API_KEY (so a logged-in subscription can't hijack the run), and pins
# ANTHROPIC_MODEL/ANTHROPIC_DEFAULT_HAIKU_MODEL to CEREBRO_MODEL -- including
# for the orchestrator, which has no --model flag of its own. CEREBRO_MODEL must
# then name a model the endpoint actually serves. CEREBRO_CLAUDE_AUTH_TOKEN
# defaults to a non-empty placeholder the endpoint ignores (local no-auth
# servers); set it to the real key for an authenticated gateway.
CEREBRO_CLAUDE_BASE_URL="${CEREBRO_CLAUDE_BASE_URL:-}"
CEREBRO_CLAUDE_AUTH_TOKEN="${CEREBRO_CLAUDE_AUTH_TOKEN:-}"
# cerebro ships its own opencode config tree (agents + plugin) under
# $CEREBRO_HOME/.opencode and points every opencode invocation -- the
# interactive orchestrator (when backend=opencode), every spawned opencode
# child, and the read-only reviewer (when CEREBRO_REVIEW_BACKEND=opencode) --
# at it via OPENCODE_CONFIG_DIR. The user's global ~/.config/opencode (auth,
# providers, models) still loads underneath it, so credentials keep working;
# this dir only layers cerebro's agents and the session-binding plugin on top.
# Always exported: the reviewer defaults to opencode, and the editing backend
# may be opencode too, so the tree is needed in the common case even when the
# editing backend is claude.
export OPENCODE_CONFIG_DIR="$CEREBRO_HOME/.opencode"

# Max chars in a single harness overlay file. Larger than learnings' cap since
# overlays aren't all carried in one system message, but still bounded.
CEREBRO_OVERLAY_CAP="${CEREBRO_OVERLAY_CAP:-4000}"

# ----- two-timescale self-improvement (MetaSkill-Evolve) --------------------
# The fast loop (cerebro improve) evolves task-level overlays; the slow loop
# (cerebro improve --meta) evolves the meta-skill (the improvement procedure
# itself) every H fast-loop runs. Frontier-selection weights balance task
# utility, meta-productivity, and visitation novelty when choosing which
# past improvement state to build on.
CEREBRO_META_HORIZON="${CEREBRO_META_HORIZON:-2}"
CEREBRO_IMPROVE_ETA_1="${CEREBRO_IMPROVE_ETA_1:-1.0}"   # utility U
CEREBRO_IMPROVE_ETA_2="${CEREBRO_IMPROVE_ETA_2:-0.5}"   # meta-productivity P
CEREBRO_IMPROVE_ETA_3="${CEREBRO_IMPROVE_ETA_3:-0.25}"  # novelty N
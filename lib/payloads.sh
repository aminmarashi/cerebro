# cerebro lib: payloads
# loaders + generators for the on-disk payloads under lib/payloads/: opencode
# agent generators (child roles + orchestrator + observer), the
# session-binding plugin, opencode config, orchestrator system prompt, child
# role prompts, default templates, and the claude-backend-only hook + settings.
# The files live beside the code (resolved via CEREBRO_LIB_DIR), so a `git pull`
# updates them and materialise_home() copies the home-resident ones into
# $CEREBRO_HOME on next launch.
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- payload loaders -------------------------------------------------------

cerebro_payloads_dir() { printf '%s\n' "$CEREBRO_LIB_DIR/payloads"; }

# The directory holding the shipped Claude Code skill files
# (lib/payloads/skills/<topic>/SKILL.md). materialise_home copies each into
# $CEREBRO_HOME/.claude/skills/<topic>/SKILL.md so the orchestrator (which runs
# with cwd $CEREBRO_HOME) discovers them as project skills and can load a body
# on demand via the Skill tool, keeping the always-loaded orchestrator prompt
# small. The same source is also materialised as a plain guide (frontmatter
# stripped) under $CEREBRO_HOME/guides/<topic>.md for the opencode backend,
# which has no Skill tool / SKILL.md format and instead Reads the guide file.
cerebro_skills_dir() { printf '%s\n' "$CEREBRO_LIB_DIR/payloads/skills"; }

# cerebro_skill_body <skill-md-path> -- print only the body of a SKILL.md, i.e.
# everything after the closing `---` of the YAML frontmatter. Used to derive
# the opencode guide copy from the same source as the claude skill (so the two
# never diverge). A file with no frontmatter prints verbatim.
cerebro_skill_body() {
  awk 'BEGIN{f=0} /^---$/{if(!f){f=1;next};if(f==1){f=2;next}} f==2||f==0{print}' "$1"
}

# The session-binding plugin for opencode. Records the opencode-assigned session
# id into the active cerebro session's metadata (so `cerebro --resume` can reopen
# the same conversation) and appends each user prompt to the transcript (so
# observers can narrate the orchestrator track). Only active for opencode
# processes with CEREBRO_SESSION_DIR set.
cerebro_plugin_js() { cat "$(cerebro_payloads_dir)/plugin/cerebro.js"; }

# The opencode config cerebro layers on top of the user's global config for
# every cerebro-launched opencode process.
cerebro_opencode_json() { cat "$(cerebro_payloads_dir)/opencode.json"; }

# The UserPromptSubmit hook for the claude backend. Reads claude's hook payload
# from stdin, routes the prompt to the matching cerebro session's transcript,
# and writes the current-session symlink for bare-resume.
cerebro_hook_script() { cat "$(cerebro_payloads_dir)/hook.sh"; }

# cerebro_settings_json <hook-path> -- the .claude/settings.local.json that
# registers the UserPromptSubmit hook (claude backend only). The template
# carries a __CEREBRO_HOOK_PATH__ placeholder; substitute it with bash
# expansion so any character in the path is inert.
cerebro_settings_json() {
  local hook_path="$1" tpl
  tpl="$(cat "$(cerebro_payloads_dir)/settings.json")"
  printf '%s\n' "${tpl//__CEREBRO_HOOK_PATH__/$hook_path}"
}

cerebro_system_prompt() { cat "$(cerebro_payloads_dir)/system-prompt.md"; }

# The observe-mode overlay appended after the orchestrator prompt when a
# session is launched with `cerebro --observe`: it narrows the session to
# watching and steering live paired children and forbids direct changes.
cerebro_observe_mode_prompt() { cat "$(cerebro_payloads_dir)/observe-mode.md"; }

# Runtime note shared by the read-only opencode reviewer/auditor children.
cerebro_reviewer_note() {
  cat "$(cerebro_payloads_dir)/prompts/reviewer-note.md"
}

# The plan-audit prompt fed to the read-only reviewer child spawned by
# `cerebro audit` (the plan / spec / context blocks are appended after it). The
# read-only constraints live in the reviewer agent, so this is just the audit
# task.
cerebro_audit_prompt() {
  local out; out="$(printf '%s\n\n%s' \
    "$(cerebro_reviewer_note)" \
    "$(cat "$(cerebro_payloads_dir)/prompts/audit.md")")"
  local ov; ov="$(overlay_body grader)"
  [[ -n "$ov" ]] && out="$(printf '%s\n\n# Local grader overlay\n%s' "$out" "$ov")"
  printf '%s\n' "$out"
}

# The meta-skill component names, in pipeline order (analyzer=retriever=
# allocator=proposer=evolver). Each has a base prompt at
# lib/payloads/prompts/meta/<name>.md and an optional local overlay at
# $CEREBRO_HOME/overlays/meta-<name>.md. The composition appends the overlay
# after the base so the improvement procedure is evolveable in-place.
CEREBRO_META_COMPONENTS="analyzer retriever allocator proposer evolver"

# The hill-climbing analysis prompt fed to the read-only reviewer child spawned
# by `cerebro improve` (the trace-corpus locations / context are appended after
# it). Composed from the five meta-skill components (analyzer / retriever /
# allocator / proposer / evolver) plus any local meta-overlays, so the
# improvement procedure itself is evolveable via `cerebro overlay set
# meta-<component>` -- the two-timescale recursive self-improvement loop.
cerebro_improve_prompt() {
  local out comp ov
  out="$(printf '%s\n\n%s' \
    "$(cerebro_reviewer_note)" \
    "$(cat "$(cerebro_payloads_dir)/prompts/meta/intro.md")")"
  for comp in $CEREBRO_META_COMPONENTS; do
    out="$(printf '%s\n\n%s' "$out" \
      "$(cat "$(cerebro_payloads_dir)/prompts/meta/$comp.md")")"
    ov="$(overlay_body "meta-$comp")"
    [[ -n "$ov" ]] && out="$(printf '%s\n\n# Local meta-%s overlay\n%s' "$out" "$comp" "$ov")"
  done
  printf '%s\n' "$out"
}

# The slow-loop (meta-skill evolution) prompt fed to the read-only reviewer
# child spawned by `cerebro improve --meta`. The chronological history of
# successful runs and their verdict/finding counts is appended after this
# prompt in cmd_improve. The meta-skill component files
# are cited as read-only reference (the model diagnoses them, not follows
# their output instructions), so the component prompts' HILL CLIMB verdict
# does not conflict with the meta-loop's META CLIMB verdict.
cerebro_meta_improve_prompt() {
  local out; out="$(printf '%s\n\n%s' \
    "$(cerebro_reviewer_note)" \
    "$(cat "$(cerebro_payloads_dir)/prompts/meta-improve.md")")"
  local comp ov
  out="$(printf '%s\n\n## Current meta-skill components (for reference -- diagnose them, do not follow their output instructions)\n' "$out")"
  for comp in $CEREBRO_META_COMPONENTS; do
    out="$(printf '%s\n\n### %s\n%s' "$out" "$comp" \
      "$(cat "$(cerebro_payloads_dir)/prompts/meta/$comp.md")")"
    ov="$(overlay_body "meta-$comp")"
    [[ -n "$ov" ]] && out="$(printf '%s\n\n# Local meta-%s overlay\n%s' "$out" "$comp" "$ov")"
  done
  printf '%s\n' "$out"
}

# ----- child role prompts ---------------------------------------------------
# The role base prompt for each child (execute / apply-review / doc-write) lives
# at lib/payloads/prompts/<role>.md, plus a shared non-interactive note beside
# them. Under the opencode backend these are wrapped in an agent markdown file
# (child_agent_file, below); under the claude backend they are composed inline
# by child_sys_prompt and passed via --append-system-prompt. Either way, a
# single source feeds both the original command and `cerebro answer` (which
# resumes the same child and must re-present the identical role constraints).

# The note every child shares: it cannot ask questions interactively, but it
# may pause by ending its run with its question as its final message for cerebro
# to answer and resume.
child_noninteractive_note() {
  cat "$(cerebro_payloads_dir)/prompts/noninteractive-note.md"
}

# child_sys_prompt <role> -- the full --append-system-prompt for a claude child
# of the given role: its role base prompt followed by the shared non-interactive
# note. User-owned local overlays are no longer appended here; they are written
# to $CEREBRO_HOME/overlays/<role>.md and the model can read them when needed.
# Keeping this body stable lets the backend cache the system prompt. The
# read-only reviewer roles (review / audit / improve, reached only when
# CEREBRO_REVIEW_BACKEND=claude) carry the shared reviewer note -- exactly the
# body the opencode reviewer_agent_file carries -- so the read-only constraints
# are present as system-level guidance (the review task prompt is composed
# inline and otherwise has none); audit/improve already embed the note in their
# task prompt, so this duplicates it the same way the opencode reviewer agent
# already does.
child_sys_prompt() {
  local role="$1"
  case "$role" in
    execute|apply-review|doc-write|verify)
      local f="$(cerebro_payloads_dir)/prompts/$role.md"
      printf '%s\n\n%s' "$(cat "$f")" "$(child_noninteractive_note)" ;;
    review|audit|improve)
      printf '%s\n' "$(cerebro_reviewer_note)" ;;
    *) die "child_sys_prompt: unknown role: $role" ;;
  esac
}

# ----- opencode agent generators --------------------------------------------
# Under the opencode backend, every spawned child (execute / apply-review /
# doc-write) runs as a non-interactive `opencode run --agent cerebro-<role>`.
# The agent's role prompt and tool permissions live in an opencode agent
# markdown file under $CEREBRO_HOME/.opencode/agent/, generated here from the
# role base prompt + the shared non-interactive note, wrapped in YAML
# frontmatter that pins the agent's permissions. Because the role lives in the
# agent file, `cerebro answer` (which resumes the same child) re-selects the
# same agent by name and inherits the identical role constraints with no
# per-call prompt plumbing. The read-only reviewer agent is shared by review
# and audit.

# child_agent_file <role> -- the full opencode agent markdown for a child of
# the given role: YAML frontmatter pinning its mode + tool permissions, then its
# role base prompt followed by the shared non-interactive note. User-owned local
# overlays are no longer appended here; they are written to
# $CEREBRO_HOME/overlays/<role>.md and the model can read them when needed.
# Keeping this body stable lets the backend cache the system prompt.
child_agent_file() {
  local role="$1"
  local f="$(cerebro_payloads_dir)/prompts/$role.md"
  local desc
  case "$role" in
    execute)      desc="cerebro execute child: implement a plan in an isolated worktree and open a PR" ;;
    apply-review) desc="cerebro apply-review child: apply review findings or a fix on the current branch" ;;
    doc-write)    desc="cerebro doc-write child: update user-facing docs for a shipped change" ;;
    verify)       desc="cerebro verify child: high-level requirements/acceptance e2e verification of a shipped change" ;;
    *) die "child_agent_file: unknown role: $role" ;;
  esac
  local out
  out=$(cat <<EOF
---
description: $desc
mode: all
permission:
  edit: allow
  bash: allow
  webfetch: allow
  websearch: allow
  external_directory: allow
---
EOF
)
  printf '%s\n%s\n\n%s' "$out" "$(cat "$f")" "$(child_noninteractive_note)"
}

# verify_agent_file -- the opencode agent markdown for the cerebro verify child.
# Same capable permission shape as child_agent_file (edit/bash/web/external
# allow) since it must start servers, rebuild images, and drive a browser; NOT
# the read-only reviewer clamp. Body = verify.md + noninteractive-note.md.
# User-owned local overlays are no longer appended here; they are written to
# $CEREBRO_HOME/overlays/verify.md and the model can read them when needed.
# Keeping this body stable lets the backend cache the system prompt.
verify_agent_file() {
  local out
  out=$(cat <<'EOF'
---
description: cerebro verify child: high-level requirements/acceptance e2e verification of a shipped change
mode: all
permission:
  edit: allow
  bash: allow
  webfetch: allow
  websearch: allow
  external_directory: allow
---
EOF
)
  printf '%s\n%s\n\n%s' "$out" \
    "$(cat "$(cerebro_payloads_dir)/prompts/verify.md")" \
    "$(child_noninteractive_note)"
}

# reviewer_agent_file -- the opencode agent markdown for the read-only reviewer
# used by `cerebro review` and `cerebro audit`. Clamped to genuine read-only
# operation: no edit/write/task, and bash denied except the inspection commands
# a reviewer needs. Its findings are the run's final message. Runs on
# CEREBRO_REVIEW_MODEL (independent of the implementer).
reviewer_agent_file() {
  cat <<'EOF'
---
description: cerebro reviewer/auditor: read-only, independent review of a diff or plan
mode: all
permission:
  edit: deny
  write: deny
  task: deny
  webfetch: deny
  websearch: deny
  external_directory: allow
  bash:
    "*": deny
    "git diff*": allow
    "git show*": allow
    "git log*": allow
    "git status*": allow
    "git rev-parse*": allow
    "git merge-base*": allow
    "git blame*": allow
    "git ls-files*": allow
    "git cat-file*": allow
    "grep *": allow
    "rg *": allow
    "cat *": allow
    "head *": allow
    "tail *": allow
    "sed -n*": allow
    "find *": allow
    "ls*": allow
    "wc *": allow
    "jq *": allow
    "test *": allow
---
EOF
  printf '%s\n' "$(cerebro_reviewer_note)"
}

# orchestrator_agent_file -- the opencode agent markdown for the interactive
# orchestrator. Its tools are clamped so it can never touch a repo directly:
# no edit/write anywhere except a per-session scratch dir under
# /tmp/cerebro-*/ (a non-Bash channel for landing large plan bodies fast,
# ingested by `cerebro plan --from-file`), no Task delegation, and bash denied
# except `cerebro ...`. The agent file is shared + byte-for-byte stable across
# sessions (so it can be prompt-cached), so the write scope is a /tmp/cerebro-*/
# namespace wildcard, not a single session's id -- the orchestrator writes to
# /tmp/cerebro-<its-own-session-id>/ (given by `cerebro plan --scratch-dir`), so
# concurrent sessions use disjoint dirs and don't clobber each other. Read/grep
# /glob and web tools stay on. Body is the static system-prompt.md only;
# user-owned local overlays and learnings are no longer appended here, so this
# file is byte-for-byte stable across launches and can be prompt-cached.
orchestrator_agent_file() {
  cat <<'EOF'
---
description: cerebro orchestrator -- drives the plan/execute/review loop via cerebro subcommands
mode: primary
permission:
  edit:
    "*": deny
    "/tmp/cerebro-*/**": allow
  write:
    "*": deny
    "/tmp/cerebro-*/**": allow
  task: deny
  external_directory: allow
  bash:
    "*": deny
    "cerebro": allow
    "cerebro *": allow
---
EOF
  cat "$(cerebro_payloads_dir)/system-prompt.md"
}

# claude_orchestrator_agent_file -- the Claude Code main-thread agent markdown
# for the cerebro orchestrator, used by the ACP path (claude-agent-acp). The
# claude TUI path does NOT use an agent file (it pins via --append-system-prompt
# + --allowedTools on the CLI); this file exists so `cerebro acp` can pin the
# restricted orchestrator through claude-agent-acp's `agent` config option,
# which calls the SDK's applyFlagSettings({agent: "cerebro-orchestrator"}) --
# the same selection path as `claude --agent`, so the frontmatter `tools:` is
# hard-enforced. The tool surface mirrors the opencode orchestrator agent
# (orchestrator_agent_file): read/grep/glob + web + Bash limited to `cerebro`,
# plus a scoped Write/Edit into /tmp/cerebro-*/ (the non-Bash channel for
# landing large plan bodies fast, ingested by `cerebro plan --from-file`), no
# Task delegation, no unrestricted Bash/git/gh. The scope is the shared
# /tmp/cerebro-*/ namespace (the agent file is static across sessions so it
# can be prompt-cached); the orchestrator writes to /tmp/cerebro-<its-own-
# session-id>/ so concurrent sessions stay disjoint. Body is the static
# system-prompt.md only.
claude_orchestrator_agent_file() {
  cat <<'EOF'
---
name: cerebro-orchestrator
description: cerebro orchestrator -- drives the plan/execute/review loop via cerebro subcommands
tools: Read, Grep, Glob, WebSearch, WebFetch, Bash(cerebro:*), Write(/tmp/cerebro-*/**), Edit(/tmp/cerebro-*/**), Skill, mcp__playwright__*
---
EOF
  cat "$(cerebro_payloads_dir)/system-prompt.md"
}

# observer_agent_file -- the opencode agent markdown for a `cerebro --observe`
# session. Same read-only clamp as the orchestrator, but bash is narrowed to
# observe/steer/restart + read-only status commands. Body is the static
# observe-mode.md only; no dynamic additions.
observer_agent_file() {
  cat <<'EOF'
---
description: cerebro observer -- watch and steer another session's live paired children
mode: primary
permission:
  edit: deny
  write: deny
  task: deny
  external_directory: allow
  bash:
    "*": deny
    "cerebro observe": allow
    "cerebro observe *": allow
    "cerebro steer": allow
    "cerebro steer *": allow
    "cerebro restart": allow
    "cerebro restart *": allow
    "cerebro status": allow
    "cerebro status *": allow
    "cerebro list": allow
    "cerebro list *": allow
    "cerebro recall": allow
    "cerebro recall *": allow
    "cerebro spec": allow
    "cerebro spec *": allow
    "cerebro learnings": allow
    "cerebro learnings *": allow
---
EOF
  cat "$(cerebro_payloads_dir)/observe-mode.md"
}

# ----- default templates ----------------------------------------------------

# Default AGENTS.md that `cerebro execute` drops into a repo that doesn't
# already have one. Not authoritative rules -- a user-editable template at
# $CEREBRO_HOME/templates/AGENTS.md. opencode reads AGENTS.md as its project
# rules file, so a single AGENTS.md serves both cerebro and opencode. Written
# by materialise_home (shared, write_if_missing).
cerebro_default_agents_md() { cat "$(cerebro_payloads_dir)/templates/AGENTS.md"; }

# Default CLAUDE.md template (claude backend only). Written by the claude
# backend's materialise_extras alongside AGENTS.md so a fresh repo gets both.
cerebro_default_claude_md() { cat "$(cerebro_payloads_dir)/templates/CLAUDE.md"; }

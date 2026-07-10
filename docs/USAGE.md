# Using cerebro

Everything cerebro can do for you and how to drive it. You never type
`cerebro` subcommands yourself — you talk to the orchestrator in plain
English and it runs the machinery. For what happens under the hood,
see [ARCHITECTURE.md](ARCHITECTURE.md).

## Sessions

```bash
cerebro                       # mint a new session, drop into the chat
cerebro --resume <id>         # resume a specific session
cerebro --resume              # claude's session picker
cerebro --observe [<id>]      # watch-and-steer-only session for another
                              #   session's live paired children
cerebro list                  # list sessions, newest first
```

`cerebro --observe` opens an interactive chat dedicated to looking over the
shoulder of another session's live `--pair` children: it polls `cerebro
observe`, narrates the design taking shape, and steers an agent only when you
tell it to. Its tools are narrowed to `observe`/`steer` plus read-only
commands, so it makes no direct repo changes. It first waits until there is
something to observe -- a session with live paired children -- polling quietly
until one appears (Ctrl-C to cancel), so the chat opens onto live activity
rather than an immediate "nothing to observe". Pass a target session id and it
waits on, then narrates, that session; omit the id and it waits for any other
session to start live paired children (auto-picking the most recently active).

## Ship a feature (the core loop)

Describe the change and the repo. The orchestrator:

1. Records what you asked for as the **session spec** — the
   requirements of record (see [Guardrails](#guardrails-and-autonomy)).
2. Drafts a plan into the session's `plans/` dir. Alongside the
   detailed technical plan it also writes a plain-English **companion**
   (`<name>-readable.md`) — the same plan with the dense code references
   stripped — and the path it gives you is the companion's; the
   companion links back to the technical plan, which stays the source of
   truth that gets executed. For high-blast-radius changes (many files,
   shared modules, public APIs, schemas, auth paths) it first
   **audits** the technical plan against the actual code — phantom
   targets, missed call sites, scope creep, over-engineering — and
   revises it before proposing it.
3. Waits for your explicit **"go"**.
4. Executes the plan in a sub-agent running in an **isolated git
   worktree** of the repo (under `$CEREBRO_HOME/worktrees/`), never your
   live checkout: it fetches the base branch, creates a feature branch,
   implements, commits, pushes, and opens a PR via `gh` — all inside the
   worktree. On success it announces the worktree path, which the
   orchestrator then uses as the repo argument for that task's review /
   apply-review / doc-write. Worktrees persist between runs; stale ones
   are reclaimed with `cerebro worktrees cleanup`.
5. Runs codex review against the diff, summarises the findings,
   applies the in-scope important ones, and loops review →
   apply-review until codex is quiet. Re-reviews are incremental: only
   the changes since the last review are inspected, so the loop stays
   cheap. Out-of-scope or gold-plating findings are named to you, not
   silently applied.
6. **Verifies the change end to end by actually using the running
   app** — Playwright-driven where possible, or manual testing with
   you when it can't be automated. Static review and unit tests never
   count as "done" on their own.
7. Optionally updates docs on the same branch (`doc-write`).

First time it touches a repo with no `AGENTS.md`/`CLAUDE.md`, it adds
them from the user-editable templates at `~/.cerebro/templates/` as a
separate first commit (defaults: Conventional Commits, ≤ 80-char
subjects, `feat/`-style branches, no commits and no DB/infra changes
without an explicit ask). It never overwrites existing files.

## Ship a large change (stacked PRs)

Give it a spec too big for one coherent PR and it decomposes the work
into an **ordered suite of plans — one PR each**, stacked so each PR
branches off the previous one. Every step must satisfy the
**workable-state invariant**: each PR is independently shippable and
leaves the app building, green, and fully working — merging the stack
one PR at a time never leaves the app broken at any boundary. If the
spec can't be split that way, it says so and proposes a different cut
instead of emitting breaking plans.

You approve the decomposition once; it then executes the suite
autonomously. Each step is gated by a **checkpoint**: a codex review
fed the plan's acceptance criteria (verdict line `ACCEPTANCE CRITERIA:
MET` / `NOT MET`), zero important in-scope findings, *and* an
end-to-end check of that step's user flow against the running app. On
a failing checkpoint it makes up to three bounded corrective attempts
(scoped fixes, or replanning the failing step and its downstream
plans), then escalates to you. At the end you get the full PR stack,
ready to review and merge in order.

## Ask about a repo

"What does HEAD look like vs main?", "is CI green on the PR?", "where
is the retry logic?" — the orchestrator answers these without spawning
an agent, through guaranteed read-only bridges (`cerebro git`, `gh`,
`grep`, `read`, `ls`) that allow-list every verb and flag. It also
checks `cerebro recall` — a literal search across all your past
sessions' transcripts and agent logs — before re-asking you something
you already answered in a prior session.

## Pair: watch and steer a live agent

Ask to *pair* (or *watch*, *steer*, *let me drive*) and the child runs
in pair mode (`plan`, `execute`, `apply-review`, `doc-write`; codex
review has no live-steer):

* **Observe** — from a *second* cerebro session, say "observe
  \<session-id\>" (the id from the `PAIR MODE` banner; it names the
  orchestrator session, not a child). That session tails every live
  paired child at once and narrates in plain English what each one is
  doing — following the gist, flagging the decisions that matter (new
  abstractions, schema changes, security paths, public APIs) and
  quoting the shaping code. Observation only reads logs; it never
  disturbs the agents.
* **Steer** — `cerebro steer "<message>"` injects one instruction into
  the live child as its next turn and returns immediately. (Pass the
  pipe path from the banner first when several paired children run at
  once.) After each turn the child waits a short window
  (`CEREBRO_PAIR_IDLE`, default 60s) for steering; a quiet window lets
  it finish on its own. Steer is for small nudges.
* **Restart** — `cerebro restart "<diagnosis>"` is for when a paired
  execute child has gone fundamentally off (wrong assumptions, drifted
  from the spec) and steering its poisoned context is futile. It
  abandons the child and unconditionally tears down everything the run
  produced — the fresh branch, its PR, and the task's worktree are all
  deleted (your main checkout was never touched) — then hands the
  orchestrator the diagnosis so it can relaunch a fresh execute with a
  corrected prompt. Same arg shape as steer (pass the pipe path first
  when several run at once).

When the child finishes, your steering is reported back and the
orchestrator folds it in automatically — updating the session spec and
revising affected plans — then tells you what changed.

## Drive it from your editor (ACP)

`cerebro acp` speaks the [Agent Client Protocol](https://agentclientprotocol.com),
so any ACP-aware editor — Zed, and anything else that implements it — can drive
cerebro's orchestrator directly, turn by turn, with the **full** agent
experience: images, @-mentions / embedded context, thinking, structured
clarifying questions, terminals, MCP servers, permission prompts, edit review,
model / mode / effort pickers, and usage — whatever the upstream agent CLI
exposes. cerebro does not re-implement any of it.

cerebro is a **thin proxy** (on the official `agent-client-protocol` Python
SDK). For each editor session it:

1. **mints a cerebro session** (the same durable session `cerebro --resume`
   reopens), and a cerebro-owned ACP project dir that carries the restricted
   `cerebro-orchestrator` agent;
2. **spawns a per-session upstream ACP child** — `opencode acp` (opencode
   backend) or `claude-agent-acp` (claude backend) — with `CEREBRO_SESSION_ID`
   injected, so every `cerebro` subcommand the orchestrator spawns binds to that
   session;
3. **pins the restricted agent** — forcing the `cerebro-orchestrator` mode
   (opencode) or `agent` (claude) config option — so the orchestrator's
   read-only + `Bash(cerebro:*)` restriction is harness-enforced, never just
   promised, and every edit/git/PR still routes through spawned children in
   worktrees;
4. **relays JSON-RPC unchanged** with sessionId remap (the editor sees cerebro
   session ids; the child sees its own), and records the upstream conversation
   id in cerebro metadata so `session/load` + `session/resume` reopen the same
   upstream conversation.

Your repo is never written to from the ACP path: it is passed to the child as an
ACP `additional_directory`, and the child's session cwd is the cerebro-owned
project dir.

### Register it in Zed

Add a custom agent server to your Zed `settings.json`:

```jsonc
"agent_servers": {
  "Cerebro": { "type": "custom", "command": "cerebro", "args": ["acp"] }
}
```

Zed launches `cerebro acp` once (long-lived); each thread's cwd comes from the
editor. Open a Cerebro thread in a repo, send "draft a plan first" → "go", and
the `cerebro execute` child binds to the session (visible in `cerebro list`),
opens its PR, and reports back through the editor. Restart Zed and resume the
thread — the upstream conversation reopens.

### Restart the proxy after a config change

`cerebro acp` reads `$CEREBRO_HOME/config.json` and the `CEREBRO_*` env vars
once at startup, then reuses the resolved values for the lifetime of the
proxy (and for every per-session upstream child it spawns). To pick up a
config change without restarting the editor, run

```bash
cerebro acp restart
```

This signals the running proxy (for your current `CEREBRO_HOME`) to exit;
the editor respawns `cerebro acp` and the next session materialises with
fresh config. Idempotent — a no-op when no proxy is running.

### Backends and dependencies

* **opencode (default):** uses `opencode acp`. No extra deps beyond cerebro's
  normal ones.
* **claude:** uses `@agentclientprotocol/claude-agent-acp` via `npx`, which
  needs **Node ≥ 22** + `npx` on PATH. Set `CEREBRO_BACKEND=claude` (and, for a
  gateway, `CEREBRO_CLAUDE_BASE_URL`).

ACP needs **Python ≥ 3.10** plus the `agent-client-protocol` package. `cerebro
acp` prefers Homebrew's `python3` (`/opt/homebrew/bin/python3`) — macOS system
python3 is 3.9, too old — and auto-installs the SDK to your user site
(`pip install --user --break-system-packages`) on first run if it's missing.
Install them yourself if you prefer:

```bash
brew install python
/opt/homebrew/bin/python3 -m pip install --user --break-system-packages agent-client-protocol
```

### Scope

ACP is **editor-driven and turn-by-turn**. The interactive **pair / observe /
watch-and-steer** features stay TUI-only (`cerebro` / `cerebro --observe`): the
ACP orchestrator is a sequence of per-turn upstream sessions, not a persistent
pairable process. `cerebro list` shows ACP-created sessions and `cerebro
--resume <id>` works on them like any other.

## Resume and interrupted work

Sessions are durable. `cerebro --resume <id>` (or the picker) drops
you back into the same conversation, with the session spec, plans,
review state, and transcripts intact on disk.

Interrupting mid-run loses nothing: every child's resumable
conversation id is persisted the instant it starts. On "continue" the
orchestrator checks `cerebro status` for interrupted in-flight
children and resumes each one — continuing half-done work via
`--resume` instead of redoing it (and instead of duplicating commits).
Stored ids stay resumable for `CEREBRO_CHILD_SESSION_TTL` seconds
(default 24h), but normal child launches only auto-resume children still
marked in-flight. Once a child finishes cleanly, the next sub-agent starts
a fresh provider conversation even if it runs on the same repo and branch.

A child that hits a genuine blocker doesn't guess and doesn't die: it
**pauses with a question** as its closing message. The orchestrator
answers from the spec or past sessions when the record settles it, and
only relays to you when the decision is genuinely yours. The closing
message prints the child session id, and
`cerebro answer <child-session-id> "<answer>"` resumes that same child
exactly where it stopped.

## Teach it your preferences

When you reveal a general preference — directly ("always keep diffs
small") or by repeatedly correcting in the same direction — the
orchestrator records the signal, and once the evidence is clear (one
explicit directive, or the same signal twice) consolidates it into a
small global `learnings.md` that is injected into the system prompt of
**every future session**, across all repos. Ambiguous signals get a
clarifying question first. `cerebro learnings` (ask the orchestrator)
prints the active set.

For tuning a specific prompt surface that `learnings.md` cannot reach —
a child role prompt or the codex grader — ask the orchestrator to set a
**local overlay**. Up to five user-owned markdown files under
`~/.cerebro/overlays/` (`system`, `execute`, `apply-review`,
`doc-write`, `grader`) are *appended* onto the corresponding shipped
prompt. They are local, never materialised, and survive `git pull`, so
you can adjust any prompt surface without forking. `cerebro overlay
show` lists them.

## Improve the harness from its own traces

`cerebro improve <cerebro-source-repo>` runs the configured reviewer as a read-only
analysis agent over the accumulated trace corpus under `~/.cerebro`,
mining problems that **recur across runs** and proposing the smallest
fixes back into the harness. It only proposes — findings end in a
`HILL CLIMB:` verdict, and the orchestrator routes each accepted item
into a local overlay or `learnings.md` (or, if you maintain the cerebro
source, an upstream PR). Nothing rewrites the harness unsupervised; run
it on request. Successful runs are recorded chronologically in
`~/.cerebro/improvement-history.json`. Every `meta_horizon` successful fast
runs, or whenever `--meta` is passed, a second read-only pass reviews that
history and can propose a change to one of the local `meta-*` overlays. The
history records findings and verdicts, not acceptance decisions or causal
utility deltas.

## Skip the ceremony

Planning and review are the default, never skipped on the
orchestrator's own judgement. Say "just do it", "skip the plan", or
"fix it directly" and it uses the inline-prompt shortcuts instead —
straight to an editing child, no plan file or findings file in
between.

## Guardrails and autonomy

cerebro is built to be autonomous *within* your requirements, never
about them:

* **The session spec is the contract.** Before planning, the
  orchestrator records what you actually asked for; every requirement
  change updates it (prior versions are archived, never lost). It
  lives on disk, so it survives context compaction. During execution
  the orchestrator may adapt a plan that turns out wrong and keep
  going **as long as the adjusted work still satisfies the spec** — but
  anything that would (or even might) drop a requirement, change
  asked-for behaviour, or expand scope stops and asks you first. Doubt
  counts as divergence.
* **Plan-first by default.** Skipping the plan or the review requires
  you to ask for it explicitly.
* **The orchestrator cannot mutate anything.** Its tools are
  restricted to read/search/web plus `cerebro:*`; the restriction is
  enforced by the harness, not by promise. Mutations happen only in
  role-scoped children; the reviewer is sandboxed read-only.
* **Done means observed working.** End-to-end verification in the
  running app is a non-negotiable part of the definition of done.

## Install details

The installer clones into `~/.local/share/cerebro` (override with
`CEREBRO_SRC`), symlinks `cerebro` into `~/bin` (override with
`CEREBRO_BINDIR`), and adds that directory to your PATH if needed.
Re-running it updates the clone in place. To pin a ref, set
`CEREBRO_REF`.

Prefer to manage it yourself:

```bash
git clone https://github.com/aminmarashi/cerebro.git ~/.local/share/cerebro
ln -s ~/.local/share/cerebro/bin/cerebro ~/bin/cerebro   # ~/bin must be on PATH
```

To uninstall without a working `cerebro-uninstall` symlink:

```bash
curl -fsSL https://raw.githubusercontent.com/aminmarashi/cerebro/main/uninstall.sh | bash
```

## Configuration

Every option below can be set two ways: as an env var (`CEREBRO_*`) or as a
key in the options file at `$CEREBRO_HOME/config.json` (alongside the model
catalog at `$CEREBRO_HOME/models-config.json`). **Env vars take precedence**
over the file, and the file takes precedence over the hardcoded default
(`env > config.json > default`). The file is handy for options you want set on
every run without polluting your shell; use env vars for per-invocation
overrides. Keys are lower-case option names without the `CEREBRO_` prefix
(e.g. `backend`, `review_model`, `pair_idle`). Unknown keys are ignored, and a
missing/invalid file is not an error. `CEREBRO_HOME` itself is env-only (the
file lives under it).

```json
{
  "backend": "claude",
  "model": "anthropic/claude-opus-4",
  "review_model": "github-copilot/gpt-5.5",
  "timeout": 0,
  "pair_idle": 60,
  "child_session_ttl": 86400,
  "debug": 0
}
```

Options and their defaults (all optional):

| option (key) | env var | meaning | default |
|-----|-----|---------|---------|
| `home` | `CEREBRO_HOME` | base dir for all state (env-only, not read from config.json) | `~/.cerebro` |
| `backend` | `CEREBRO_BACKEND` | agent CLI for the orchestrator + editing children | `opencode` |
| `review_backend` | `CEREBRO_REVIEW_BACKEND` | agent CLI for the read-only reviewer (`review` / `audit` / `verify` / `improve`), independent of `CEREBRO_BACKEND` so the reviewer can use a different backend than the editor | `opencode` |
| `model` | `CEREBRO_MODEL` | model alias for child `claude -p` | provider default |
| `review_model` | `CEREBRO_REVIEW_MODEL` | model alias for the read-only reviewer | `github-copilot/gpt-5.5` |
| `claude_base_url` | `CEREBRO_CLAUDE_BASE_URL` | optional Anthropic-compatible endpoint for the claude backend (e.g. a local Ollama `/v1/messages` server, or any proxy). empty = the claude.ai subscription `claude` is logged into. when set, the effective model (`CEREBRO_MODEL`, or `CEREBRO_REVIEW_MODEL` when the reviewer runs under claude) must name a model the endpoint serves | empty (subscription) |
| `claude_auth_token` | `CEREBRO_CLAUDE_AUTH_TOKEN` | bearer token for `CEREBRO_CLAUDE_BASE_URL` (local no-auth servers ignore it; set the real key for an authed gateway) | `ollama` |
| `timeout` | `CEREBRO_TIMEOUT` | wall-clock cap (s) per child call | `0` (no cap, so e2e runs and CI waits are never killed) |
| `child_idle_timeout` | `CEREBRO_CHILD_IDLE_TIMEOUT` | inactivity window (s) before the stream parser declares a child stalled | `180` |
| `child_session_ttl` | `CEREBRO_CHILD_SESSION_TTL` | how long (s) a stored child id stays resumable | `86400` (24h) |
| `pair_idle` | `CEREBRO_PAIR_IDLE` | steering window (s) after each paired turn | `60` |
| `pair_stall` | `CEREBRO_PAIR_STALL` | stream-freeze window (s) before a paired child is restarted | `180` |
| `pair_stall_busy` | `CEREBRO_PAIR_STALL_BUSY` | busy-but-stalled window (s) before a restart | `450` |
| `pair_stall_retries` | `CEREBRO_PAIR_STALL_RETRIES` | max restart attempts for a stalled paired child | `2` |
| `pair_stall_backoff` | `CEREBRO_PAIR_STALL_BACKOFF` | base (s) for the exponential restart backoff | `5` |
| `opencode_cmd` | `CEREBRO_OPENCODE_CMD` | opencode executable | `opencode` |
| `claude_cmd` | `CEREBRO_CLAUDE_CMD` | claude executable | `claude` |
| `overlay_cap` | `CEREBRO_OVERLAY_CAP` | max chars in a single harness overlay file | `4000` |
| `meta_horizon` | `CEREBRO_META_HORIZON` | fast-loop runs between meta-skill (`--meta`) runs | `2` |
| `debug` | `CEREBRO_DEBUG` | `1` for verbose logs | `0` |

Two deliberate limits to know about:

* **Interactive-only.** `cerebro` refuses to run under a non-terminal
  parent (pipes, scripts, cron). The sub-agents the orchestrator
  spawns are exempt.
* **No concurrency control.** cerebro won't stop you from running two
  mutating operations against the same repo at once, within or across
  sessions — sequence your own mutating work.

### Using a local model (Ollama, any Anthropic-compatible gateway)

The `claude` backend normally uses the claude.ai subscription `claude`
is logged into. Point it at a local model server instead by setting
`CEREBRO_CLAUDE_BASE_URL` and a model the server serves — cerebro
exports the endpoint into every spawned `claude` (orchestrator and
children), unsets `ANTHROPIC_API_KEY` so a logged-in subscription can't
hijack the run, and pins the background "haiku" model to the same name so
housekeeping calls also stay local:

```bash
ollama serve                       # local server on :11434
CEREBRO_BACKEND=claude \
CEREBRO_CLAUDE_BASE_URL=http://localhost:11434 \
CEREBRO_MODEL=qwen2.5-coder:14b \
cerebro
```

Leave `CEREBRO_CLAUDE_BASE_URL` unset to keep using the subscription.
For an authenticated gateway, set `CEREBRO_CLAUDE_AUTH_TOKEN` to the
real key (the default is a placeholder local no-auth servers ignore).
Small local models (7B-14B) frequently botch tool-call JSON and will
struggle with cerebro's agentic loop; pick the largest model you can run.

Claude Code can't infer the context window for a model id it doesn't
recognize (anything not a built-in Claude alias) and falls back to 200k.
If your catalog entry for `CEREBRO_MODEL` declares a `contextTokens`
field (see "Model catalog" below), cerebro also exports
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=<tokens>` into every spawned `claude` so
auto-compaction doesn't fire at the 200k default on a larger-window model.
Claude Code may still cap that value at its assumed window for the id (the
status line can read 200k); for direct `claude --model <id>` launches use
`cerebro model-env <id> [--no-compact]` to print the same exports, with
`--no-compact` as the escape hatch that forces the true window at the cost
of disabling compaction.

### Reviewer under claude

The read-only reviewer (`cerebro review` / `audit` / `verify` / `improve`)
runs under `CEREBRO_REVIEW_BACKEND`, which defaults to `opencode` (on
`CEREBRO_REVIEW_MODEL`, a suggested-different model) so it can stay a
genuinely independent pair of eyes. The difference is a suggestion, not a
rule: leaving `CEREBRO_REVIEW_MODEL` equal to `CEREBRO_MODEL` is allowed.
Any subcommand also takes `--model <provider/model>` to override its default
model per call, and `cerebro models` lists the user's model catalog (see
"Model catalog" below) so the orchestrator can pick a model per task --
e.g. a vision-capable model for `cerebro verify`'s screenshot verification.
Set `CEREBRO_REVIEW_BACKEND=claude` to run the reviewer under
the `claude` CLI instead -- e.g. to review on a Claude model, or to keep the
whole stack on one provider:

```bash
CEREBRO_REVIEW_BACKEND=claude CEREBRO_REVIEW_MODEL=<claude-model-alias> cerebro
```

When `CEREBRO_REVIEW_BACKEND=claude` and `CEREBRO_CLAUDE_BASE_URL` is set, the
reviewer points at the same custom endpoint as the editing children, and
`CEREBRO_REVIEW_MODEL` (or the `--model` you pass) must then name a model
that endpoint serves (cerebro pins the gateway to that model for the
reviewer run). With `CEREBRO_CLAUDE_BASE_URL` unset the reviewer uses the
claude.ai subscription `claude` is logged into.

### Model catalog

`cerebro models` prints the catalog you maintain at
`$CEREBRO_HOME/models-config.json`. Each entry has an `id` (the exact
`provider/model` string passed to a subcommand's `--model` flag, same shape
as `CEREBRO_MODEL`), a `capabilities` list (an open set of present tags;
`vision` = multimodal image input, the one that matters for reading browser
screenshots during `verify`), a free-text `description` for judgement
the orchestrator reasons about (context window, reasoning depth, cost), and
an optional integer `contextTokens` -- the model's context-window size in
tokens. When the claude backend runs behind a custom endpoint
(`CEREBRO_CLAUDE_BASE_URL`), cerebro exports `contextTokens` as
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` so Claude Code doesn't fall back to its
200k default for an unrecognized id; `cerebro model-env <id>` prints the same
export for a direct `claude --model <id>` launch.

```json
{
  "models": [
    { "id": "github-copilot/gemini-3.1-pro-preview",
      "capabilities": ["vision", "tools", "thinking"],
      "contextTokens": 256000,
      "description": "Strong generalist; smaller context window." },
    { "id": "minimax/minimax-m3",
      "capabilities": ["vision", "tools", "audio"],
      "contextTokens": 512000,
      "description": "Vision + audio; use for screenshot/visual verification." }
  ]
}
```

`cerebro model-env <id> [--no-compact]` prints shell `export` lines that tell
Claude Code the model's real context window, for use before a direct
`claude --model <id>` launch against a custom endpoint:

```bash
eval "$(cerebro model-env glm-5.2:cloud)" \
  && claude --model glm-5.2:cloud --dangerously-skip-permissions
```

By default it exports `CLAUDE_CODE_AUTO_COMPACT_WINDOW=<tokens>` (keeps
auto-compaction, but Claude Code may cap it at its assumed window for the id
and the status line can still read 200k). `--no-compact` exports
`CLAUDE_CODE_MAX_CONTEXT_TOKENS=<tokens>` and `DISABLE_COMPACT=1` instead --
the documented override that makes `/context` reflect the true window, at the
cost of disabling auto-compaction. A model with no `contextTokens` (or an
unknown id) prints a note and no exports, so the `eval` is a safe no-op.

The orchestrator reads this catalog with `cerebro models` and chooses a
model per task -- e.g. routing `cerebro verify` to a `vision`-capable model
when the default review model lacks vision, or fanning a `cerebro review`
across several models by calling it once per catalog entry with `--model`.
A missing catalog is not an error: the subcommands fall back to their
env-var defaults.

## Session state

Everything durable is a plain file under `$CEREBRO_HOME` (default
`~/.cerebro/`), and the orchestrator will happily hand you paths to
open in your editor:

```
~/.cerebro/
  learnings.md                       # confirmed preferences (injected into the prompt)
  overlays/<target>.md               # user-owned prompt overlays (append onto shipped prompts)
  templates/AGENTS.md, CLAUDE.md     # defaults dropped into new repos (edit freely)
  worktrees/<ckey>/                  # isolated per-task execute worktrees
                                     #   (GC stale ones with `cerebro worktrees cleanup`)
  sessions/<id>/
    spec.md                          # current session spec (requirements of record)
    spec-history.jsonl               # every prior spec version
    plans/                           # plan markdown files
                                     #   (each <name>.md has a plain-English
                                     #    <name>-readable.md companion beside it)
    children/                        # stream-json logs of every sub-agent + codex findings
    audits/                          # codex plan-audit findings
    improvements/improve.md          # latest `cerebro improve` hill-climbing findings
    review-state/                    # per-repo last-reviewed SHA
```

The full layout, the hook that routes prompts to the right session,
and the reasoning behind file-based state are covered in
[ARCHITECTURE.md](ARCHITECTURE.md#3-everything-durable-is-a-plain-file).

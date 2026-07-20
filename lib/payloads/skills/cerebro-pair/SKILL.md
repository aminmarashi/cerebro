---
name: cerebro-pair
description: Pair programming mode -- running a paired (watchable, steerable) child via --pair, relaying the session id, the steer/restart side channel, and folding steering back into the spec and plans (auto-apply then report). Invoke when the user asks to pair/watch/steer a live child.
---
# Pair programming mode

The user can PAIR with a child agent: watch it live and steer it as it
works. Pass `--pair` to `cerebro execute`, `apply-review`, or
`doc-write` when the user asks to "pair", "watch", "steer", "follow
along", "let me drive", "I want to jump in", or similar. (Pairing is not
available for `cerebro review` or `cerebro audit` -- the reviewer has no
live-steer.) `--pair`
drives the child through claude's stream-json input: cerebro feeds the
task as the first message, then after each turn waits a short window for
steering injected over a named pipe.

A paired child is WATCHED from ANOTHER cerebro session: the user opens a
second cerebro and asks it to "observe" this one, and that session runs
`cerebro observe` in a loop and narrates the live agents (see "# Observing
another cerebro session"). It is STEERED with `cerebro steer "<message>"`
(a ONE-SHOT inject that sends one instruction into the live child and
returns at once -- pass the child's steer-pipe path as a first arg when
several paired children run at once).
Steering is a side channel straight into the child: the user's messages
and the child's replies do NOT enter your chat -- only a compact summary
of what they steered comes back at the end.

How to run a paired child:

  1. RUN IT DETACHED. A paired child is meant to be watched and steered WHILE
     it runs, so launch it with `cerebro detach --output
     $CEREBRO_SESSION_DIR/detached-output/<name>.out -- <subcommand> ... --pair`.
     Never use the Bash tool's `run_in_background`: harness task cleanup can
     kill the paired child while it is being observed. cerebro prints a "PAIR MODE"
     banner to stderr as soon as it starts, with this session's id and the
     `cerebro steer` command.
     Put `cerebro wait <job-id>` in `run_in_background` immediately
     afterward so the harness notifies you on completion without owning the
     paired child.
  2. RELAY THE DETAILS IMMEDIATELY. As soon as that banner appears, tell
     the user this paired child is running and give them this session's id,
     so from ANOTHER cerebro session they can ask it to "observe <this
     session id>" and watch the child live (see "# Observing another
     cerebro session"); `cerebro steer "<message>"` redirects it. The child
     runs to completion on its own; after each turn it waits a short window
     (CEREBRO_PAIR_IDLE, default 60s) for steering, so a steer has to land
     within that window to take effect. Only steer on the user's behalf
     when they explicitly tell you to.
  3. LET IT RUN. Narrate progress briefly as usual. An un-steered child
     just finishes on its own after the quiet window.
  4. ON COMPLETION, COLLECT THE STEERING. When the child finishes,
     cerebro emits a block on stdout delimited by
     `=== PAIR STEERING (N message(s), applied live) ===` ... `=== END
     PAIR STEERING (file: <path>) ===` listing the steering the user
     injected. READ it. If no steering was sent, cerebro says so and
     there is nothing to fold in -- proceed normally.

Folding steering back in (AUTO-APPLY, then report):

Steering is the user talking to you through the child -- treat it as a
DIRECT INSTRUCTION (rule 0): it takes precedence, and you apply it
WITHOUT asking again. The child already acted on it live; your job is to
keep the spec and the rest of the suite coherent with it. After a paired
child returns with steering:

  * UPDATE THE SPEC. If the steering adds, changes, or drops a
    requirement, capture it with `cerebro spec set` so the spec stays
    the record of record (rule 9).
  * REVISE THE PLANS. Rewrite the affected plan yourself to reflect the
    steer and re-record it (`cerebro plan "<full revised plan>" --out
    <same-name>` OVERWRITES it), regenerate its `-readable` companion so
    the two stay in sync, and adjust any not-yet-executed downstream
    plans (and their companions) so the suite stays coherent. If the
    steering invalidates the approach itself, REPLAN rather than patch.
  * RE-EXECUTE IF NEEDED. If the steered child already did the work the
    new direction asked for, you are done; if the steer arrived too late
    to land in that child, apply it on the same branch with the normal
    follow-up (`apply-review --prompt`) or the next plan step.
  * THEN REPORT. Tell the user, in a few lines, what you heard them
    steer and exactly what you changed in response (spec edits, plan
    revisions, replans, re-runs).

This auto-apply autonomy covers HOW you satisfy the spec. If the steering
would change WHAT the spec asks for in a way that is genuinely ambiguous
or conflicts with a standing requirement, fall back to the spec-divergence
rule above: make the change you are confident in, but STOP and confirm the
part that is a real product decision rather than guessing.

Restart vs steer (replacing a rogue agent):

Steering is for small in-flight NUDGES. But sometimes a paired execute
child is FUNDAMENTALLY off -- it started from wrong assumptions, rebuilt
something the plan said to extend, or its context is so poisoned that
nudging it cannot recover it. That agent is RESTARTED, not steered. When
the user (or a watching observer session) runs `cerebro restart <pipe>
"<diagnosis>"`, cerebro reaps the child and UNCONDITIONALLY tears down
everything the run produced -- the fresh branch, its PR, and the task's
worktree are all deleted (the user's main checkout was never touched, so
the clean slate is automatic) -- and your detached `cerebro execute`
returns 0 with a block delimited by `=== RESTART REQUESTED ===` ... `===
END RESTART REQUESTED ===` carrying the diagnosis. When you see that
block:

  * The work is ALREADY gone -- cerebro tore down the branch, PR, and
    worktree. Do not try to clean any of it up yourself.
  * FOLD THE DIAGNOSIS INTO A CORRECTED PROMPT. Revise the plan/prompt so
    the prior mistake is made EXPLICIT at the START of the fresh agent's
    prompt (e.g. "Do NOT rebuild X; extend the existing Y as the spec
    requires"). Update the spec/plans if the diagnosis reveals a
    requirement the first run misread -- and when you correct a technical
    plan, regenerate its `-readable` companion so the two stay in sync.
  * RE-RUN `cerebro execute` FRESH (you may reuse the same branch name --
    the old branch was deleted, and execute creates a brand-new worktree
    and branch) -- a new session with clean context, never a resume of
    the abandoned one. Use the NEW run's announced worktree path for its
    follow-ups.

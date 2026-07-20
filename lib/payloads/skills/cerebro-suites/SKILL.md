---
name: cerebro-suites
description: How to decompose a too-big-for-one-PR specification into an ordered multi-plan suite -- the workable-state invariant, stacked-PR execute, checkpoint verify with the reviewer, bounded revise-and-retry, and finishing the stack. Invoke when a spec is too big for one PR.
---
# Large specifications: multi-plan suites

When the user asks for a large change or a specification too big for one
coherent PR, do NOT cram it into a single plan. Break it into an ORDERED
SUITE of smaller plans, each of which becomes ONE pull request, stacked
so that executing them all in order implements the specification FULLY
and CORRECTLY. You orchestrate the whole suite yourself using the
existing subcommands -- there is no special "suite" command. YOU are the
persistent mind that keeps the suite coherent across plans; hold the
plan list, their order, the branch chain, and per-checkpoint attempt
counts in your working context and narrate progress as you go.

Work like a lazy senior engineer: keep it SIMPLE. The suite exists only
to make a big change reviewable -- not as licence to gold-plate it. Use
the FEWEST plans that deliver the spec, scope each plan to exactly what
the spec asks for (no speculative steps, extra options, or
future-proofing nobody requested), and never let the suite balloon
beyond the request. Each plan must also read as a SELF-CONTAINED
implementation plan, in its own terms: do NOT mention the suite, the
other plans, step numbers, the decomposition, or the branch names inside
a plan's body. Those are YOUR orchestration bookkeeping, not the plan's
content; the overview/sibling context you thread into a plan prompt is
there to set boundaries, not to be echoed back into the plan.

## The workable-state invariant (non-negotiable)

Every plan in the suite MUST leave the application in a fully WORKABLE
state on its own: it builds, its tests pass, and everything that worked
before the plan still works after it. Each plan is a SELF-CONTAINED,
independently shippable, independently mergeable increment -- never a
half-finished fragment that only makes sense once a LATER plan lands.
Merging the stack one PR at a time must NEVER, at any boundary, leave the
app broken, non-building, or with a regressed or dead feature waiting on a
future step.

Concretely, no plan may: call something only a later plan defines; remove
or rename something the running app still needs until the same plan also
updates every user; or ship a schema / interface / API change without the
code that keeps the app working against it. If a change cannot be split
without breaking the app between the halves, the whole workable unit
belongs in ONE plan -- do not cut it across plans.

Decompose so this invariant holds at EVERY step boundary. If you cannot
find an ordering where each plan is independently workable and shippable
-- if every possible split necessarily breaks the app between steps --
then do NOT emit breaking plans. STOP and report to the user: explain why
the spec cannot be decomposed into self-contained workable steps and
propose the alternative (one larger plan, or a different cut). Failing
loudly is REQUIRED; shipping a suite whose middle leaves the app broken is
never acceptable under any circumstance.

This invariant also binds you DURING execution. If at any point you
discover the current plan would leave the app broken at its boundary and
cannot be made whole within its own scope, STOP -- do not advance the
suite. That is a plan-level discovery: follow "# Adapting plans
mid-flight against the session spec" -- tell the user what you found and
the re-cut you propose (fold the breaking change together with whatever
makes it whole, or re-order the steps), and wait. On their go, apply the
re-cut: update the executed plans with the facts, rewrite the affected
downstream plans and <slug>-00-overview, and continue. If no workable
re-cut exists, say so plainly rather than pushing a broken state
forward.

## 1. Decompose (then WAIT for go)

First record the whole specification as the session spec with
`cerebro spec set "<the full specification and requirements>"` -- this is
the record of record the suite as a whole must satisfy, and what you
measure any mid-flight plan adjustment against (rule 9). Then decompose.

Decomposition is just `cerebro plan` called more than once -- you write
every file yourself. Pick a short suite slug (e.g. the feature name) and:

  a. Write an OVERVIEW: decompose the specification into an ORDERED set
     of PR-sized implementation steps. For each step give a one-line
     summary and its dependencies on earlier steps, argue why the steps
     in order fully and correctly satisfy the spec, and keep each step
     independently reviewable. Record it with `cerebro plan "<overview
     markdown>" --out <slug>-00-overview`, then record its readable
     companion `<slug>-00-overview-readable` whose reference block names
     the overview's absolute path.
  b. Write one DETAILED plan per step, in order, keeping the overview
     and the spec in mind so the boundaries stay coherent. Each plan is
     a STANDALONE deliverable in its own terms: the smallest change that
     satisfies THIS step (no scope creep, no gold-plating, no
     future-proofing the spec did not ask for), and it does NOT mention
     the other steps, the overview, the suite, the decomposition, or any
     branch names in its body -- those are your orchestration
     bookkeeping. END each plan with a section titled exactly
     '## Acceptance criteria (checkpoint)' -- a checklist of concrete,
     independently VERIFIABLE conditions (commands to run, behaviours to
     observe, files/functions that must exist and work) that define DONE
     for this step and must be confirmed before the next step starts.
     The criteria MUST include (a) that the whole app still builds and
     its existing tests pass after this step -- the step leaves the app
     in a fully workable state -- and (b) an explicit END-TO-END usage
     check: the concrete user flow this step delivers, to be verified by
     `cerebro verify` (which drives the running app with a browser) or
     the real entrypoint/CLI/endpoint run end to end, not just unit
     tests. State the exact flow to drive and what to observe. Phrase every criterion
     BEHAVIORALLY -- tie it to observable behavior, not to a specific
     guessed path; avoid hard-pinning guessed internal filenames/symbols
     of third-party or vendored code, since a criterion naming the wrong
     file reads NOT MET forever and wastes re-review rounds. Tests must
     verify POSITIVELY: assert the new and preserved-legacy strings
     APPEAR; never use negative-absence assertions to prove a
     legacy/removed string is gone. Record each with
     `cerebro plan "<plan markdown>" --out <slug>-NN-<short>`, using
     zero-padded NN (01, 02, ...) so `cerebro plans` lists them in
     order. For each detailed plan ALSO record a readable companion
     `<slug>-NN-<short>-readable` whose reference block names that
     plan's absolute path. When you summarise the suite, the paths you
     surface to the user are the COMPANIONS (the overview companion and
     each step's companion).

A multi-plan suite is HIGH blast radius by definition. Before summarising
it to the user, AUDIT the suite against the real code (see "# Audit
high-blast-radius plans before executing them"): run `cerebro audit` on
every detailed plan -- always the technical `<name>.md`, never its
`-readable` companion (the companion is user-facing only). Pass the
overview and what earlier steps deliver in --context so the auditor
judges the boundaries correctly, and confirm
the steps in order actually deliver the spec against how the code works.
Revise the overview and any affected plans (`cerebro plan ... --out
<same-name>`) and re-check until the suite is correctly scoped. Only then
propose it.

Then summarise the suite to the user -- the ordered plan list, each
plan's COMPANION path, and its acceptance criteria -- and WAIT for an
explicit "go" before executing anything (rule 3 applies to the whole
suite). The user approves the decomposition ONCE.

## 2. Execute the suite autonomously (stacked PRs)

After "go", execute the plans IN ORDER without pausing between them
(pause only to escalate per step 4). Every `cerebro execute` /
`cerebro audit` / `cerebro review --criteria-file` in the suite is
given the technical `<slug>-NN-<short>.md` (or `<slug>-00-overview.md`),
NEVER the `-readable` companion -- companions are user-facing only. The
PRs STACK: the first branches off the repo's default base (main); every
later plan branches off the PREVIOUS plan's branch and targets it as the
PR base. Drive this with the execute flags, naming branches yourself so
you always know the next plan's base:

  * Plan 1: `cerebro execute <repo> <slug>-01-... --branch <feat/slug-01>`
    (no --base: forks from main).
  * Plan N (N>1): `cerebro execute <repo> <slug>-NN-...
    --base <feat/slug-(N-1)> --branch <feat/slug-NN>`.

Choose conventional branch names (feat/..., per AGENTS.md). Run exactly
one mutating subcommand at a time (rule 8); finish a plan's checkpoint
before starting the next plan's execute. Each plan's execute runs in its
OWN worktree and announces a `=== TASK WORKTREE: <path> ... ===` line --
capture each plan's <path> and use it as the <repo> argument for that
plan's review / apply-review / doc-write (the next plan still passes
--base/--branch to `cerebro execute` against the main repo path, since
the new worktree is created fresh from that base ref).

## 3. Verify each checkpoint with the reviewer

After each plan's `cerebro execute`, gate advancement on the acceptance
criteria via the reviewer, addressing the review at THIS plan's worktree path:

  `cerebro review <wt> --criteria-file <the-plan-you-just-ran>`

Because the PR's base is the previous plan's branch, the review's
default base resolves to that branch, so the reviewer sees only THIS plan's
diff. READ the findings file. The checkpoint PASSES only when ALL THREE
hold: the final line says `ACCEPTANCE CRITERIA: MET` for the
code-reviewable criteria; there are no in-scope, genuinely-important
findings (apply the same scope/importance gates as the normal loop); AND
you have VERIFIED THE STEP END TO END per
"# Definition of done: end-to-end verification" -- the app still builds
and its tests pass, and you have run `cerebro verify <wt> --plan <the-plan>`
and it reported `VERIFY: PASS` (or, when verify returned `VERIFY: BLOCKED`,
the user has manually confirmed it). Codex never runs the app, and any
`EXTERNAL` criterion in its output is your responsibility to verify; its
MET verdict alone is NOT a pass. Only when all three hold do you advance to the next
plan, using this plan's branch as the next --base. If the e2e check shows
the step does not actually work, treat it as a failed checkpoint (step 4)
-- never advance on green static signals while the app is broken.

## 4. When a checkpoint fails: bounded revise-and-retry, then escalate

If the checkpoint does not pass, make corrective attempts -- but no more
than THREE attempts on any single checkpoint. Pick the right kind of
correction each time:

  * Implementation is buggy but the plan's approach is SOUND -> scope
    the real, in-scope findings and run `cerebro apply-review <wt>` on
    this plan's worktree path, then re-review with --criteria-file.
    (Small fix.)
  * The PLAN ITSELF is wrong -- the criteria are unreachable as written,
    or the approach can't satisfy the spec -> that is a plan-level
    discovery, not a retry: STOP and follow "# Adapting plans mid-flight
    against the session spec" (tell the user what you learned and what
    you propose, and wait). On their go: update the executed plans with
    the newly discovered facts, rewrite the failing plan to route around
    the failure so it cannot recur (keeping the acceptance criteria
    verifiable; `cerebro plan "<full revised plan>" --out
    <slug>-NN-<short>` OVERWRITES it), and revise the affected
    DOWNSTREAM plans, their criteria, and <slug>-00-overview the same
    way so the suite stays coherent (regenerating each revised plan's
    `-readable` companion so the pair never diverges). Shipped plans'
    WORK is history -- never re-execute them -- but their text gets the
    new facts folded in so the record stays true. Then re-implement the
    revised plan on the SAME branch with `cerebro apply-review <wt>
    --prompt "<the revised plan / the delta to apply>"` (the worktree
    already has that branch checked out) and re-review.

Count every apply-review/replan round as one attempt. If the checkpoint
still fails after the third attempt, STOP and ask the user: summarise
what failed, the criteria that won't pass, what you tried, and the
revision you propose next. Do not loop indefinitely.

## 5. Finish

When the last checkpoint passes, summarise the full PR stack to the user
(each PR, its base, what it delivers, that its criteria were met) so
they can review and merge the stack in order. Optionally `cerebro
doc-write` at the end. If the user merges and asks you to continue,
remember the stack base may shift -- re-derive bases from the open PRs
with `cerebro gh <repo> pr list` if unsure.

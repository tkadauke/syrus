# Landing merge-train (Fix 4)

_Status check 2026-08-26: complete as the v1 Epic merge-train
implementation plan. Current operator-facing behavior lives in
`config/syrus_docs/merge_train.md`, `config/syrus_docs/landing_queue.md`, and
`config/syrus_docs/app_settings.md`; this file is retained as design history._

Status: **implemented (v1)** — controlled by `AppSetting.merge_train_enabled`.

## Implementation status (v1)

Shipped: `MergeTrain`/`MergeTrainMember` models, `MergeTrainAssembler`
(Epic readiness + topo order), `Workflows::MergeTrain`
(`merge_train_assemble → merge_train_build → prepare →
retry_until(graders, repair: landing_fix) → merge_train_land`),
`MergeTrainDispatcher` (queue dispatch + member locking),
`MergeTrainFailureHandler` (revert members), and `EpicLandingRetrier`
(bulk re-approve). `LandingQueueProcessor` dispatches a train for a ready
Epic and keeps Epic children off the per-Job path when the flag is on.

v1 deviations / deferred:
- **Build rebases each member onto the integration tip** in topo order.
  The mechanical `git rebase` is always tried first — a member that only
  needs to move forward or whose changes don't overlap replays cleanly
  with no agent (git's patch-id detection skips already-integrated
  commits, so stacked members replay only their own). Only when git stops
  on a real conflict does Syrus hand that in-progress rebase (already
  targeting the integration branch) to the agent in a single call to
  resolve AND complete; Syrus then verifies the outcome by observable
  end-state and fast-forwards. Verification does NOT use rebase-internal
  refs (`REBASE_HEAD` persists after a rebase completes, so it can't tell
  "still rebasing" from "done"): it checks out the scratch branch (git
  refuses checkout while a rebase is mid-flight), requires a clean
  worktree, and requires the integration branch to be an ancestor of the
  result (catching a wrong-base rebase). The agent owns completion because
  it runs git autonomously, so Syrus can't assume the rebase is still
  mid-flight afterward. A failure to finish / wrong target / agent failure
  fails the whole attempt; logical conflicts are still caught by the grade
  & fix loop.
  (`git rerere` to reuse resolutions across retries is a planned follow-up.)
- **Retry storm guard:** after a train fails,
  `MergeTrainDispatcher::RETRY_COOLDOWN` (30 min) blocks re-dispatch for
  that Epic, so a genuinely-stuck Epic surfaces for an operator instead
  of re-training every tick (fail_landing → auto-re-approve → doomed
  train). 
- **Land** opens one synthetic integration PR (integration branch → base)
  and merges it; member PRs are closed with a back-link (they show
  "Closed", not "Merged" — the accepted atomicity tradeoff).
- **Epic-level retry** ships as the `EpicLandingRetrier` service; a
  dashboard button / admin endpoint is not yet wired (operator can
  re-approve children via the existing per-Job UI in the meantime).
- **Readiness = `whole_epic` only**; no `green_prefix`, no chunking of
  Epics larger than `merge_train_max_size` (those fall back to the
  per-Job path).

## Why

Landing is strictly serialized per repository: only one Job per repo is
`landing` at a time (`LandingQueueProcessor#landing_in_progress_for_repository?`).
When many approved PRs share one base branch (an Epic batch), every merge
moves the base and re-dirties all the others. The cost is roughly
**O(N²)** in rebases and grader runs.

Production evidence (24h, before the incremental fixes below):

| Metric | Count |
|---|---|
| PRs merged | 14 |
| auto_merge workflows cancelled/deferred | 16 (13 on `unknown`) |
| Grader runs on auto_merge workflows | 236 (~17 per merge) |
| Rebase workflows | 58 + 3 failed (~4 per merge) |

One Job (804) sat in `landing` for ~41h.

### Incremental fixes already shipped (the baseline this builds on)

1. **Wait out transient mergeability** (`Steps::AutoMerge`) — poll for a
   post-push `unknown` to settle before deferring, instead of discarding
   a green grade. Removes the dominant cancellation cause.
2. **Front-of-queue rebasing only** (`PollMergeStateJob` +
   `LandingQueueProcessor.rebase_prefetch_candidate?`) — stop rebasing
   the whole approved backlog every poll; only the front
   `REBASE_PREFETCH_DEPTH` Jobs.
3. **Opt-in `trust_clean_rebase_grade`** (`Steps::ForcePush` +
   `LandingValidationCache`) — carry a green grade across a clean rebase
   so the next attempt skips re-grading.

These cut the wasted work dramatically but do **not** raise the
throughput ceiling: PRs still land one-at-a-time, each rebased onto the
previous merge and graded once. For a 30-PR batch that's still 30
sequential (rebase + grade + merge) cycles. The merge-train removes that
ceiling.

## Goal / non-goals

**Goal:** land an **Epic's** children in far fewer than N sequential grade
cycles, while (a) preserving the safety guarantee that what lands on the
base is graded green *as it will exist after merge*, and (b) guaranteeing
**Epic consistency** — an Epic advances as a whole, green, dependency-closed
set or not at all, never as a half-merged state on `main`.

**Non-goals:**
- Cross-repo changes (landing is already parallel across repos).
- Changing the approval model, dependency/Epic gating, or the rebase
  conflict-resolution chain.
- Removing the final gate's *correctness* (only its redundant repetition).
- Batching loose, non-Epic PRs in v1 (kept on the existing per-Job path).

## Options

### Option A — GitHub native merge queue

Enable GitHub's merge queue on the repo; Syrus enqueues approved PRs and
lets GitHub build the speculative merge group, run required checks once
per group, and merge in order.

- **Pros:** GitHub owns batching, speculation, and bisection on failure;
  no Syrus-side train state machine.
- **Cons:** requires required status checks configured on GitHub (Syrus
  graders are local, not GitHub checks — a significant integration: we'd
  have to publish grader results as commit statuses/checks); branch
  protection + merge-queue config per repo; weaker fit with Syrus's
  polling-only, no-inbound-callback architecture (merge queue is
  event-driven); less control over the agent `landing_fix` repair loop.
- **Verdict:** strong for repos already living in GitHub-checks land;
  poor fit for Syrus's local-grader, poll-driven model today. Revisit if
  we ever publish graders as GitHub checks.

### Option B — Syrus-internal merge train, scoped per Epic (recommended)

Syrus builds a *train* from one Epic's child Jobs: topologically sort the
Epic's ready children, rebase them in order into a single integration
branch, then run a **grade & fix loop on the integration tip** — the same
`retry_until(graders, repair: landing_fix)` used for single-PR landing.
If it goes green, land the whole integration branch into the base in a
**single atomic merge**. If the fix loop exhausts its budget, the whole
Epic attempt fails and **nothing lands**.

The defining property is **Epic consistency**: an Epic advances as a
whole, green, dependency-closed set, or it does not advance at all. There
are never half-merged Epics on `main` — no state where child 3 has landed
but child 5 (which child 7 depends on) is still open or failing.

**No bisection.** An integration failure is frequently *not* attributable
to a single child — two children that each pass alone can break a grader
in combination (a logical conflict). There is no "culprit" to isolate;
the fix is a reconciliation commit that belongs to neither PR. The agentic
`landing_fix` step, working on the whole integrated tree, commits that
reconciliation directly on the integration branch, which then lands with
the atomic merge. This is both simpler than bisection *and* strictly more
capable for the combinatorial case (bisection would eject a child that was
fine). Bisection is noted only as a possible future optimization if the
fix loop proves insufficient in practice.

- **Pros:** one grade per Epic attempt instead of one per child; atomic
  landing eliminates partial-Epic states; the Epic is the *natural*
  batching unit (shared base, shared intent, already dependency-linked);
  topological order is already computed (`dependency_order`); reuses
  graders, rebase chain, workspace, and `landing_fix` *as-is* — no new
  bisection machinery. Stays poll-driven.
- **Cons:** Syrus owns the train state machine and build/integration.
  Atomic landing of the integration branch means child PRs show **Closed**
  rather than **Merged** on GitHub (see "Atomicity vs. PR status"). One
  genuinely-unfixable child blocks the whole Epic until an operator
  intervenes (same semantics as a single PR `landing_fix` can't save).

The rest of this doc designs Option B.

## Design (Option B — per-Epic)

### Trigger

A merge-train attempt is dispatched for an **Epic** (not a loose set of
PRs) when, for that Epic's children on one repository/base:

- `AppSetting.merge_train_enabled?` and the repo opts in, and
- the **readiness policy** is met (see below).

Non-Epic Jobs keep today's single-Job `AutoMerge` path unchanged — the
train is purely additive and Epic-scoped, which keeps the blast radius
small.

**Readiness policy:** dispatch only when **every** open child of the Epic
is `approved` (or already merged). The Epic then lands all-or-nothing.
This is the strong reading of "no half-merged Epics": maximal consistency,
at the cost of latency (the train waits for the slowest child). Dropping
bisection also drops the `green_prefix` partial-landing variant — its only
cheap implementation was prefix-grading, which *is* bisection. `whole_epic`
is the model; a partial-landing policy can be revisited later if the wait
proves painful.

### Steps

`Workflow#trigger_kind = "merge_train"`, queue `:merges`. Belongs to the
Epic (not a single Job); occupies the repo landing slot for the duration.

```
merge_train_assemble -> merge_train_build ->
  retry_until(grader_fanout -> grader_collect, repair: landing_fix) ->
  merge_train_land
```

1. **`merge_train_assemble`** (non-agentic) — gather the Epic's eligible
   children, **topologically sort** them via the existing
   `LandingQueueProcessor#dependency_order` scoped to the Epic, lock the
   repo landing slot (transition members to `landing`), persist the
   ordered member list.
2. **`merge_train_build`** (non-agentic, may dispatch agent rebases) —
   create integration branch `syrus/merge-train-epic-<epic_id>-<n>` at the
   base tip; rebase each member's branch onto the integration tip in
   topological order (reuse `AutoRebase`; on conflict, the agent rebase
   chain). A member that won't rebase cleanly **fails the Epic attempt**
   (you can't skip a child and stay consistent); the conflict surfaces for
   operator/agent handling and the next attempt retries the whole Epic.
3. **grade & fix loop** — `retry_until(graders, repair: landing_fix)` on
   the integration tip (the exact tree that will exist on base after the
   Epic merges), reusing the existing steps verbatim. The common green
   path is exactly one grade for the whole Epic. On a grader failure the
   agent commits a reconciliation fix on the integration branch and
   re-grades, bounded by `AppSetting.grade_max_iterations`.
4. **`merge_train_land`** (non-agentic) — green → land the integration
   branch into base in a **single merge**, then reconcile child PRs
   (close with a "landed via Epic merge-train" comment linking the merge).
   Mark each child Job `closed/pr_merged`. Close the Epic if all children
   are now merged.

### Failure handling (no bisection)

If the grade & fix loop exhausts `grade_max_iterations` without going
green (or build hits an irreparable conflict), the train **fails and
lands nothing** — Epic consistency is preserved by construction.

The agent's reconciliation commits live on the integration branch and
land with the atomic merge; the child PR branches are discarded (the PRs
are closed, not merged), so there's no need to back-port fixes onto them.
When the attempt fails, the integration branch is discarded and the child
PRs are left untouched.

#### What happens to the member Jobs (and how the operator retries)

Reuse the existing per-PR landing-failure semantics, applied to every
member, via `LandingFailureHandler` keyed on the failure reason:

- **Transient blocker** (infra: ENOSPC/disk; flaky GitHub; rebase still
  settling) → `defer_landing` each member (`landing → approved`, approval
  preserved). The Epic stays ready, and the next `LandingQueueProcessor`
  tick **re-attempts the train automatically**. No operator action.
- **Genuine failure** (graders still red after the fix budget; irreparable
  build conflict) → `fail_landing` each member (`landing → implemented`,
  **`approved_at` cleared**). This is the deliberate "give up; require
  re-approval" path that already exists for single PRs — it stops an
  infinite auto-retry loop on a genuinely-broken Epic and surfaces it for
  a human, with the final grader output on the run.

So **the operator re-triggers a failed Epic landing by re-approving its
children** — re-approval resets `approved_at`, the Epic becomes "all
children approved" again, and the next tick dispatches a fresh train.
Typically the operator first fixes the offending child (Retry → new
implementation, or a `pr_comment` follow-up), then re-approves.

Because re-approving N children one by one is tedious, the train needs an
**Epic-level "Retry landing" affordance**: one action that bulk-re-approves
all of the Epic's `implemented` (formerly-approved) children at once. This
reuses the existing bulk-approve path scoped to the Epic; no new Job state.

### Atomicity vs. PR status (decision)

Landing the integration branch in one merge means child PR head SHAs are
not ancestors of base (they were rebased), so GitHub marks them
**Closed**, not **Merged**. Options:

- **(recommended) Atomic + close:** one merge of the integration branch
  (via a synthetic Epic integration PR, or by pointing the tip child's PR
  at the integration branch and merging that), then close the other child
  PRs with a back-link. True atomicity; child PRs show "Closed".
- **Per-PR fast-forward in order:** preserves "Merged" badges but is
  **not atomic** — a failure midway leaves a half-merged Epic, defeating
  the goal. Rejected.

### Data model

`merge_trains`: `id, epic_id, repository_id, base_branch, state
(building|grading|landing|succeeded|failed|cancelled), integration_branch,
integration_sha, created_at, finished_at`.

`merge_train_members`: `merge_train_id, job_id, position, state
(included|merged|failed), reason`.

Jobs gain no new AASM state — members ride the normal
`landing → closed/pr_merged` on success or revert to `approved` when the
attempt fails. The Epic is the unit; the train is its single landing
occupant for the repo.

### Control flow / integration with LandingQueueProcessor

- `LandingQueueProcessor#call` gains an Epic branch: for each repo not
  already occupied, if an Epic is ready (all children approved) and the
  flag is on, dispatch a `MergeTrain` for that Epic instead of single-Job
  `AutoMerge`s for its children. Loose (non-Epic) approved Jobs continue
  through the existing per-Job path.
- The existing same-Epic dependency relaxation (a stack inside one Epic
  keeps flowing while the queue serializes merges) composes naturally:
  the train *is* that serialized merge, done once for the whole Epic.
- The train holds the repo landing slot; the recurring loop won't
  double-dispatch.

### Safety

Stronger than per-PR landing: graders run on the **exact integrated tree**
that will exist on base after the Epic merges, and the Epic lands as that
graded tree in one operation. No clean-rebase-trust needed inside a train
(`trust_clean_rebase_grade` is a per-PR optimization for the non-train
path). Consistency is guaranteed *by construction* — all-or-nothing
landing — not by isolating a culprit.

### Rollout

- `AppSetting.merge_train_enabled` (default **off**),
  `merge_train_max_size` (cap members per attempt; very large Epics land
  in capped chunks, each still a consistent dependency-closed prefix).
- Ship dark; enable for `tkadauke/raytracer` first (the Epic-batch repo).
- Metrics: merges/hour, grades per Epic landed, fix-loop iterations per
  Epic, build/grade failures, time-from-all-approved to Epic-landed.

### Testing

- Assemble: topological order within an Epic; readiness gating (waits for
  all children approved); size cap.
- Build: clean rebases, irreparable conflict fails the attempt,
  base-moved-mid-build.
- Grade & fix: green-on-first-grade lands; a repair commit on the
  integration tip turns red→green and lands with the merge.
- Failure recovery: a transient blocker `defer_landing`s members (stay
  `approved`, auto-retry next tick); a genuine red after the fix budget
  `fail_landing`s members (`implemented`, `approved_at` cleared) and lands
  nothing; re-approving the children re-dispatches a fresh train; the
  Epic-level "Retry landing" bulk-re-approves all formerly-approved
  children.
- Land: atomic merge closes child PRs + marks Jobs merged + closes Epic;
  per-repo serialization holds.
- All via existing seams (`RunJob.agent_runner`, stubbed graders, WebMock
  for Octokit). No real `claude`/GitHub.

## Estimate

Medium: 2 models + migration, 1 workflow + 3 step handlers (assemble,
build, land) that *reuse* the existing grader and `landing_fix` steps
unchanged, the LandingQueueProcessor Epic branch, AppSettings, and a
focused spec suite. Dropping bisection removes the most complex part
(speculative prefix grading + dependent ejection). Land behind the
disabled flag, then enable per-repo.

## Decisions needed

1. Option A (GitHub merge queue) vs **B (internal, per-Epic train)** —
   recommends B.
2. Atomicity: accept child PRs showing **Closed** (recommended) to keep
   the merge truly atomic?
3. Loose (non-Epic) Jobs: leave on the per-Job path for v1 (recommended),
   or generalize the train to same-base non-Epic batches later?
4. Confirm dropping bisection in favor of the integration-tip grade & fix
   loop, with whole-attempt failure on budget exhaustion (recommended).
5. Operator retry: on genuine failure, `fail_landing` members so re-approval
   is required (recommended — reuses the existing path, avoids auto-retry
   loops), plus an Epic-level "Retry landing" bulk re-approve. Transient
   failures `defer_landing` and auto-retry.

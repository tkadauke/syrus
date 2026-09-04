# Workflow Engine V3: One Failure Vocabulary

Syrus's execution engine works, and its individual layers are reasonably
factored. The cost that shows up as "special casing" is not inside any one
layer — it is at the seams between four control planes that each maintain their
own name for the same event.

This plan proposes a shared `Problem` vocabulary, a single remediation table,
node-owned control flow, data-defined templates, unit-scoped nodes, and a policy
layer. On top of those it defines an attention model: deterministic repair
first, bounded agentic judgment second, and human decisions that reduce future
human decisions.

## Current Status

As of 2026-09-04 every phase has landed at least its core primitive, and the
plan's own success criteria are met or partly met:

| Criterion | State |
| --- | --- |
| One failure code across classification, `Try` branch and reconciler issue | met -- `Problem::Kind` aliases all three |
| `StepDispatcher` names no specific reviewer step kind | met, and it now names no step kind at all |
| No `OneShotAgent` outside the Judgment primitive | met |
| A project's risk posture readable from one value | met -- `Repository#risk_profile` |
| A new capability without touching the dispatcher/reconciler/executor | partly -- reviewer gates and runtime-inserted kinds are registry entries now; adding a *work shape* still touches more |
| Escalations per landing trending down | measurable -- `Metrics::EscalationsPerLanding` exists; no data yet |

What is deliberately not done, with the reason in each phase below: the
merge-train shape still lives in `Steps::MergeTrainBuild` (A6), repo-local
template resolution is built but opt-in because it would put a GitHub
round-trip on workflow instantiation (A4/A7), classification is not yet a Run
inside a `triage` template (C2), and the decision queue has no UI surface (B2).

## Relationship To Other Plans

- `docs/plans/work-units-and-execution-resilience.md` — the v2 plan, largely
  shipped. `WorkIntent`/`WorkUnit`/`WorkDefinitions` are the ownership and
  scheduling layer this plan builds on, not replaces. That document remains the
  design rationale for the admission plane.
- `docs/plans/magic-constants-INDEX.md` and its per-scope siblings — the
  [Policy And Risk Profiles](#policy-and-risk-profiles) section here supersedes
  the "which constants become settings" framing with "what is the resolution
  rule, and what is the reviewable unit". The inventory in those documents is
  still the source list.
- `docs/plans/delivery-tracks-and-promotion.md` — delivery is already on the
  engine (`promotion`, `hotfix_sync`, `upstream_export`). This plan does not
  change it; primitive E tidies it.

## Problem

### Four control planes, four vocabularies

| Plane | Owns | Speaks |
| --- | --- | --- |
| Chain composition | what runs next inside one workflow (`Workflows::Base`, `Loop`/`RetryUntil`/`Try`, `StepDispatcher`) | step kinds, control nodes, `failure_code` strings |
| Admission and ownership | may this start, who holds locks, what preempts what (`WorkDefinitions`, `WorkUnits::Gates`, `LandingQueueProcessor`) | work kinds, gates, lock keys, block reasons |
| Failure classification | what kind of broken this is (`RunFailureClassifier`, `Step::Kind#fail_policy`, `#repair_semantics`) | 29 classifications, 3 fail policies, 4 repair semantics |
| Reconciliation | after the fact, what is stuck (`WorkEngine::Reconciler` → `RepairPlanner` → `RepairExecutor`, 6,125 lines) | 51 issue kinds, 63 plan policies, 51 executor actions |

Each plane is individually defensible. The cost is that a single event is
renamed on every hop, and no compiler checks the translations.

Trace a push rejected because the remote branch moved:

1. `Steps::Base` raises `StepFailed`.
2. `mark_failure_code!` stamps `"remote_branch_advanced_rebase_conflict"` onto
   `step.details` so a `Workflows::Try` branch can match it.
3. `RunFailureClassifier` independently labels the Run `"branch_diverged"`.
4. If it wedges, `WorkEngine::Reconciler` raises `branch_diverged_pr_open`,
   routed to the executor action `cancel_superseded_active_workflow`.

Four names, one event, zero enforced relationship. Adding a failure mode means
editing three or four registries that nothing cross-checks, then choosing among
five remediation mechanisms (`fail_policy`, `Try#on_failure`, `RetryUntil`,
`WorkUnits::RetryPolicies`, `RepairExecutor`) by convention rather than by rule.

### Where the seams show in code

- **Reviewer loops are duplicated into the dispatcher.**
  `StepDispatcher#handle_successful_adversarial_loop_iteration` hardcodes the
  step kind, artifact key, and exit verdicts;
  `handle_successful_visual_review_loop_iteration` is the same method with three
  constants swapped. A third reviewer costs a third copy.
- **Runtime insertion is not modeled.** `StepDispatcher#loop_node_for` must
  `reject { |k| k == "grader" }` because `Steps::GraderFanout` inserts steps the
  template does not describe. `waits_for_terminal_step_kind` plus the
  `WAITING_FOR_BATCH` sentinel implement fan-in for exactly one case.
- **Multi-job work runs over a representative Job.** `WorkUnit` models members
  and locks honestly, but the graph does not run over them, so a merge train's
  real shape lives inside `Steps::MergeTrainBuild` and needs its own retry
  policy, failure handler, `EpicLandingRetrier`, and the `:rebuild`
  `repair_semantics` value.
- **Two schedulers.** `LandingQueueProcessor` (1,009 lines) does dependency
  ordering, unit grouping, and blocker analysis over ready work — which is what
  `WorkIntent` exists to represent.

## Goals

- One vocabulary for failure, shared by in-flight handling and reconciliation.
- One resolution rule for remediation, and one for policy.
- Control flow owned by the node that declares it, not by the dispatcher.
- Workflow templates as inspectable, versioned data with recorded provenance.
- Human attention spent once per distinct problem, not once per occurrence.
- A single reviewable answer to "what risk posture is this project in?"

## Non-Goals

- A general workflow engine. Every primitive below must name the existing
  special case it deletes; if it cannot, it does not ship.
- Replacing `WorkIntent`/`WorkUnit`. That layer is the foundation here.
- Removing `WorkEngine::Reconciler`. Its 51 detectors encode real production
  scar tissue. Only its private copy of failure semantics goes away.

## What Already Exists

Worth stating plainly, because roughly four of the five things a "v3" wants are
already shipped in some corner:

- `Step::Kind` and `Workflow::TriggerKind` are registries with declarative
  metadata (`fail_policy`, `repair_semantics`, `reconcile_strategy`,
  `skip_if_artifact`, `advance_handler`).
- `WorkDefinitions` already pulled retry, lock, preemption and gate policy out
  of the dispatcher into composable modules.
- `Workflow#chain_template` already persists the chain as JSON.
- `Steps::GraderFanout` already mutates a live graph at runtime.
- `Skills.for` already implements repo-local override with recorded provenance
  (`:repo_override` vs `:built_in`) — the model for template resolution.
- `AutoApprovalRule` already implements an ordered policy candidate chain.
- `.syrus.yml` `grade.failures: allow_inherited` and
  `MainBranchFailureClassifier` already implement deterministic, evidence-based
  grader override.

The gap is that none of them share a vocabulary.

## Primitives

### A. Problem — the shared failure vocabulary

One registry, `Problem::Kind`, in the shape of `Step::Kind`. Every failure is a
`Problem` with a code, structured evidence, a scope (`:run`, `:step`,
`:workflow`, `:unit`, `:external`), and a default remediation.

```ruby
Steps::Outcome.ok(artifacts:, effects: [])
Steps::Outcome.problem(Problem[:remote_branch_advanced, evidence: { ... }])
```

Handlers return outcomes rather than returning-or-raising. Raw exceptions still
work: `RunFailureClassifier` becomes the adapter that maps them into the shared
vocabulary instead of maintaining a private one. `Try` branches,
`RunFailureClassification`, `Reconciler::Issue`, and
`AutoRetryFailureClassifier` all key on the same symbols.

This is load-bearing. Everything else in this plan assumes it.

### B. Remediation — one policy table

Collapse `fail_policy`, `Try#on_failure`, `RetryUntil`,
`WorkUnits::RetryPolicies`, and the 51 `RepairExecutor` actions into one closed
action set: `retry_step`, `resume_step`, `repair_with(kind)`, `insert(nodes)`,
`branch(nodes)`, `skip`, `advance`, `restart_workflow`, `rebuild_unit`,
`defer(until:)`, `preempt(other)`, `escalate(to:)`, `fail`.

One resolution rule:

```
step override → template override → work-definition policy → problem default
```

The payoff is that in-flight remediation and out-of-band reconciliation stop
being separate implementations. The reconciler detects a `Problem` and applies
the same table an in-flight failure would have used.

### C. Nodes that own their control flow

Move loop and branch semantics out of `StepDispatcher` into the node classes,
with one interface: `#materialize(iteration)`, `#on_step_success(step)`,
`#on_step_problem(problem)`. Generalize the two hardcoded reviewer loops into
one node type:

```ruby
Gate.new(step: :adversarial_review,
         verdict_artifact: "adversarial_review_iterations",
         exit_on: %w[approved], repair: :implement,
         max_iterations: 3, review_first: true)
```

`visual_review` is the same node with `exit_on: %w[approved skipped]`. The
dispatcher shrinks to "find runnable nodes, ask the node what is next,
materialize" — roughly 400 lines lighter.

This also makes DAG v2 (see `ROADMAP.md`, "Job as execution DAG") cheap: once
nodes own advancement, `next_step_id` becomes `Step#depends_on` edges and "find
next" is a ready-set query. `WAITING_FOR_BATCH` retires into a real fan-in node.

### D. Templates as data, with provenance

`Workflows::Initial.steps_for(job)` already emits JSON that is persisted as
`chain_template`. Promote that JSON to the source of truth; the Ruby classes
become compilers that emit it.

- `WorkflowTemplate`: `key`, `version`, `source` (`built_in` / `instance` /
  `repo` / `runtime`), `graph`, `parent_version`.
- Resolution copies `Skills.for`: repo-local `.syrus/workflows/<key>.yml`
  shadows the built-in, and the resolved source is recorded on the Workflow so a
  shadowed template is never a silent debugging trap.
- Runtime changes are append-only typed patches (`insert_after`, `add_gate`,
  `bind_grader`, `mark_optional_done`) recorded with an author (`agent`,
  `operator`, `system`).

That last point is the ROADMAP's "DAG v3 — agent-authored edges", implemented as
the mechanism `GraderFanout` and `Try`-branch expansion already use. On-the-fly
customization is a patch; permanent customization is a repo-local template file
written through the existing pending-action confirmation flow.

### E. Unit-scoped nodes

Add `for_each_member(...)` and `barrier(...)` node types so the graph runs over
a `WorkUnit`'s members rather than a representative Job. A merge train's shape
moves from `Steps::MergeTrainBuild` into its template. Preemption policies
(`checkpoint`, `cancel`, `rebuild` — all three already exist) attach to nodes as
well as definitions, so "what happens if this is preempted mid-train" has a
declared per-node answer.

With that, `LandingQueueProcessor` can shrink toward a scheduler over ready
`WorkIntent`s.

### F. Policy, resolved once

See [Policy And Risk Profiles](#policy-and-risk-profiles).

## Attention Model

The engine work exists to serve one outcome: work runs smoothly and human
attention is not spent on mechanical problems.

### Why the supervisor chat did not work

`SupervisorEvents.publish!` has two call sites, and the load-bearing one is
`NotificationService.create_for`. Every notification becomes a supervisor event,
with severity derived mechanically from the notification kind. The supervisor
chat is a mirror of the notification firehose. `ChatEventEvaluator` then gets a
summary string and two foreign keys and must reconstruct the situation from
scratch, per event, with no memory of the previous ones. Its own
`deterministic_result` fast path is the tell that most events should never have
cost an agent turn.

A notification says *something happened*. Remediation needs *a decision is due,
and here is the evidence*. Those are different objects and only the first exists.

### The ladder

Five rungs, configured per work definition. Each runs only when the rung below
returns inconclusive.

| Rung | Cost | Exists today as |
| --- | --- | --- |
| 0 · Deterministic adjudication | free | `grade.failures: allow_inherited`, `GraderFailureSignal`, `LandingValidationCache` |
| 1 · Deterministic repair | cheap | `format`/`generate`, `auto_rebase`, `AutoRetryAttempt` backoff |
| 2 · Agentic repair | one turn | `landing_fix`, the `implement` repair loop, `agent_rebase` |
| 3 · Agentic adjudication | one turn | **new** |
| 4 · Human decision | expensive | `PendingActions::OverrideLandingBlockerOnce` and ~50 siblings |

Per-definition ladders:

| Work definition | Ladder | Rationale |
| --- | --- | --- |
| `auto_merge` | deterministic → adjudicate → agentic repair → escalate | never gives up silently; a stalled landing is the expensive failure |
| `rebase` | deterministic → agentic → abandon | never escalates; the next merge-state poll retries anyway |
| `initial` | deterministic → agentic → fail quietly | failure is normal and cheap; batch into a low-urgency notification |
| `main_branch_repair` | deterministic → agentic → escalate urgently | broken main blocks everything |

### Rung 3: agentic adjudication

Syrus already ships the deterministic form of "the grader is wrong". `.syrus.yml`
`grade.failures: allow_inherited`, implemented by `MainBranchFailureClassifier`,
overrides a failing required grader when the same failure is provably inherited
from the base revision — matching exact failed test identities from ingested
JUnit, falling back to a normalized output fingerprint. It is configurable per
grader, with `strict` reserved for invariants.
`GraderFailureSignal.timeout_like_step?` does the same for timeouts.

Agentic adjudication is therefore the *inconclusive branch* of an existing
mechanism, not a new authority.

```ruby
Adjudication(verdict: :dismiss,          # uphold | dismiss | inconclusive
             confidence: 0.9,
             reason: "failure predates the branch; same 3 examples fail on base",
             evidence: [ "base_sha:a1b2c3", "junit:spec/foo_spec.rb:42" ])
```

Three rules:

1. **Adjudication never takes the action.** A verdict either matches a
   pre-authorized policy for that repository and workflow (auto-apply), or it
   becomes a one-click human decision with the reasoning pre-written. Judgment
   lives in the agent; authority lives in policy. `AutoApprovalRule` already
   demonstrates the shape, including its `repo_committed_grader?` guard so a
   grader the branch itself introduced authorizes nothing.
2. **The adjudicator is never the agent that produced the diff.** Fresh
   read-only session, workspace discarded — the `adversarial_review` contract. A
   model that has spent six turns failing a grader is the worst-calibrated judge
   of whether the grader is right.
3. **`inconclusive` is first class.** It must be cheaper to say "I cannot tell"
   than to guess. Track the inconclusive rate per problem kind; a rising rate
   means the evidence or the prompt is wrong.

### Decisions must compound

A ladder alone does not reduce attention; it reformats the same escalations.
`PendingActions::OverrideLandingBlockerOnce` is well built — admin-only, reason
required, re-checks the current blocker, single-use, audited — and it teaches
Syrus nothing.

Record every human decision against a *problem signature* (problem code plus a
normalized evidence fingerprint; `MainBranchFailureClassifier` already computes
this kind of fingerprint):

```ruby
DecisionRecord(
  signature:  "grader_failed:eager_load:a9f2…",
  decision:   :dismiss,
  reason:     "known upstream gem issue, tracked in #4412",
  scope:      "repository:12",   # never global by default
  decided_by: user, decided_at: ..., expires_at: ...)
```

Rung 0 consults matching decisions before anything escalates. Two guardrails:
scope to a repository rather than globally, and expire — a dismissal that made
sense against one base revision should not silently outlive it.

Metric: **escalations per landing, trending down.** Flat means the ladder is not
learning.

### The surface is a decision queue

Today the unit of attention is a Job: the `inbox` preset in
`Filters::Chips::Jobs::Attention` unions unread feedback, failed jobs, landing
failures, needs-review and awaiting-approval, and the operator reconstructs the
problem from workflow state and logs.

The unit should be a `Decision`: one problem, its evidence, the adjudicator's
verdict, and one to three typed actions bound to existing `PendingActions`.

Bug triage needs a *second* queue on the same mechanism — different audience
(the front door for people who are not the operator), different SLA, different
actions. Same shape, separate routing. Merging them buries the rare important
decision under the frequent cheap one.

Chat remains useful for reading and explaining the queue. It should not be the
transport.

## Scale

### Axis check

| Axis | Verdict | Notes |
| --- | --- | --- |
| Delivery tracks | on engine | `promotion`/`hotfix_sync`/`upstream_export` trigger kinds, `DeliveryPolicy`, `JobPrLink` roles |
| Infrastructure jobs | on engine | `main_grader`, `agent_insight`, `deploy` as `runtime_role: infrastructure` |
| PR intake | on engine, improves | `external_pr_ingest` (same-repo and fork), `external_pr_feedback`, `external_pr_merge`, four `ExternalPrIngestions` classifiers, `ForkReviewApprover`, `IngestPolicy`. The fork chain becomes a second template under primitive D |
| Triage and dedup | off engine | `IngestionClassifier` already does agentic Epic assignment and duplicate detection, but not as Runs |
| Multi-user | real gap | authorization is done (Teams, `RepositoryMembership` tiers, Pundit); resource isolation does not exist |

`AppSetting.max_concurrent_agent_runs` is one global integer and
`WorkflowAdmissionBudget` scopes to repository, never to user. One user's large
Epic can starve the instance. Admission keys need an actor dimension and the
ladder needs a fairness rung.

### Blind spots

1. **An unnamed fifth control plane: short-lived judgment agents.** Four
   separate classes named `OneShotAgent` are nested privately inside
   `IngestionClassifier`, `PrCommentClassifier`, `ChatTitleGenerator`, and
   `DirectJobTitleGenerator`. None are Runs, so none get cost accounting,
   transcripts, retries, admission control, reconciler coverage, or provider
   circuit breaking. Both agentic triage and rung 3 want more of this shape.
   Fix: a **Judgment** primitive — a Run with no workspace, a declared output
   schema, a cost ceiling, and a default remediation on timeout. Retrofitting
   the four existing copies is the proof it is the right shape.
2. **The engine starts too late.** It begins at "a valid Job exists". Intake,
   classification, dedup and Epic assignment are a thinner parallel stack;
   `ReapClassifierPendingJob` reimplements stale-work reaping that
   `WorkEngine::Reconciler` already does properly, because the classifier is not
   a Run it can see. Intake is the highest-volume surface and inherits none of
   this plan.
3. **Triage queue ≠ decision queue.** Same mechanism, separate queues.
4. **No backpressure, only concurrency limits.** 43 recurring jobs;
   `PollAllRepositoriesJob` walks every active repository each tick. The polling
   plane grows independently of execution and nothing sheds load.
   `AppSetting.polling_paused` is a kill switch, not backpressure.
5. **Cost is observed, never enforced.** `Run#cost_usd` and
   `ChatSession#cumulative_cost_usd` roll up into `App::SpendingPayload` and
   nothing caps them. There are storage budgets but no compute or spend budget,
   and none per user. The risk is at the cheap end — triage and adjudication
   turns — not the already-capped `implement` runs.
6. **Cross-source identity.** With `input_source` plugins, GitHub issues, PR
   intake, chat proposals and bug reports, one request can enter through several
   doors. A stable `source_ref` is cheap now and awkward later.
7. **Infrastructure work borrows a person's credentials.**
   `PollMainBranchHealthJob` and `MainHealthChangedService` resolve through
   `repository.user`, which is `optional: true`. Instance-owned work needs an
   instance identity.

### Worth stealing

- **Suspendable human-in-the-loop steps.** An `await_decision` node that
  suspends mid-flight and resumes on a typed answer. Under primitive C this is a
  node type, and it is the natural home for both queues.
- **Compensation.** `:publication` steps have no `undo`. Merge trains and
  promotions are where saga-style compensation earns its keep.
- **Dry-run.** Generalize speculative landing builds to "execute this template
  against real state without publishing". This is what makes agent-authored
  templates testable rather than merely trusted.

## Policy And Risk Profiles

Different projects need different postures. Today that is spread across four
unconnected tiers — `AppSetting` (38 `AppSettingRegistry` definitions),
`Repository` columns (~25), `.syrus.yml`, and `User` columns — plus `Feature`
flags and a fifth tier of hardcoded constants.

### The probe: main-branch health

| Knob | Scope | Governs |
| --- | --- | --- |
| `main_branch_health_enabled` | Repository | whether main is graded; turning it off force-clears `main_branch_repair_blocks_work` |
| `main_branch_repair_enabled` | Repository | whether a break opens a repair Job |
| `main_branch_repair_auto_approve` | Repository | whether that repair lands without a human |
| `main_branch_repair_blocks_work` | Repository | whether other work halts during repair |
| `main_branch_breakage_policy` | **Instance** | `strict` pauses unrelated work; `isolate_unrelated_failures` keeps it moving |
| `main_concern_report_threshold` | **Instance** | agent concern reports before main is suspected |

Six knobs, two scopes, consumed in 21 files, with no single place answering the
question a person actually has. Two of the six are instance-wide, so an instance
hosting a throwaway repo and a production service must pick one posture for both.

### There is no precedence rule

Three sibling resolvers give three different answers to "what if the repo does
not say":

- `RepoAdversarialReviewPlan` returns disabled, and
  `Workflows::Base.adversarial_review_rounds` un-disables it with a special case
  (`plan.source == ".syrus.yml" && plan.note.nil?`) to reach the instance
  default. The fallback lives in the caller.
- `RepoVisualReviewPlan` returns the instance default from inside the resolver.
- `RepoCoveragePlanReader` returns disabled with no instance tier at all.

`AppSetting.grade_max_iterations` is applied as a default twice on one path:
while parsing `.syrus.yml`, and again in `StepDispatcher#loop_max_iterations`.

Two consequences worth treating as defects:

- **Policy fails open.** Every repo-file resolver degrades to a default when the
  GitHub client is unavailable (`credentials_available?`, a rescued exception, a
  missing file), recorded only in a `note`. A transient GitHub outage silently
  relaxes a project's risk posture. Policy that cannot be read should fail
  closed, or defer the work.
- **Same name, two meanings.** `landing_paused` exists on both `User` and
  `Repository`, but the user column is a circuit breaker tripped by
  `LandingFailureHandler` and the repository column is set by
  `MainHealthChangedService` when main breaks.

### The resolver already exists, once

`AutoApprovalRule` builds an explicit ordered candidate chain — ScheduledTask →
Epic → Repository → User — and reports which link answered. Generalizing it is
promotion, not invention.

### Risk profiles are bundles, not more knobs

Those six knobs do not compose: "how much do we tolerate a broken main?" is one
question whose answer must be consistent across all of them. A seventh knob makes
that worse.

| Profile | Main-branch posture | Ladder and landing posture |
| --- | --- | --- |
| `prototype` | do not grade main; nothing blocks | fail quietly, never escalate, auto-merge on green |
| `standard` | grade and repair main; isolate unrelated failures | adjudicate before escalating; landing failures escalate, the rest batches |
| `production` | grade main; repair urgently; halt unrelated work; no auto-approved repairs | strict graders; no agentic dismissal of a failing check; every override human and audited |

A profile is a single reviewable object, which no combination of six booleans
provides. It is also the natural authority scope for the attention model: which
ladder rungs are enabled, whether an agent may dismiss a grader verdict at all,
and how far an agent-authored template may deviate. `production` simply does not
grant rung 3.

## Incremental Plan

Three tracks. Track A phases 1–2 change no behavior and unblock the others.

### Track A — Engine

- **A1 · Problem vocabulary — done.** `Problem::Kind` is a `Syrus::KindRegistry`
  of 30 codes, each with a scope, a retryable flag, and the remediation B will
  read. Every other plane's name for the same event is declared as an alias:
  `RunFailureClassifier::Result#problem` resolves its classification through it,
  `mark_failure_code!` stamps `problem_code` beside the `failure_code` a `Try`
  branch still matches on, and reconciler issue kinds map through the same
  index. Coverage is pinned statically (`spec/models/problem/kind_spec.rb`)
  rather than enforced at runtime: the emitters run on the failure path, where
  a new raise would turn a handled failure into a crash. No behavior changed.
- **A2 · Remediation table — resolver landed; executor actions still to
  delegate.** `Remediation` is the closed action set and `Remediation::Resolver`
  is the one rule, seeded to reproduce today's decisions: tier 3 asks the work
  definition's retry policy rather than reimplementing it, so nothing moved.
  `RetryFailedStepEnqueuer` and `StepDispatcher#fail!` now go through it, and
  `Step::Kind.remediation_for` states `fail_policy` in the shared action set
  (`:advance` stays `:advance`; `:loop_iteration` is `:retry_step`; `:default`
  means "no step-kind opinion", so later tiers decide). Tiers 1 and 2 have no
  producers yet -- they exist because the order is the contract.
  `spec/services/work_engine/resilience_matrix_spec.rb` stayed green
  throughout, which is what makes this a refactor rather than a leap. Still to
  do: `Workflows::Try`/`RetryUntil` declaring their branches as template
  overrides, and the RepairExecutor actions resolving through the same table.
- **A3 · Node objects — reviewer Gate landed; node classes still to do.** The
  two reviewer-loop copies are one gate: `Step::Kind#review_gate` declares the
  artifact its verdicts land in, which verdicts exit, and the cancellation
  reason, so `StepDispatcher` reads a declaration instead of carrying a
  hardcoded copy per reviewer. The success criterion "StepDispatcher no longer
  names any specific reviewer step kind" holds and is pinned by
  `spec/architecture/reviewer_gate_spec.rb`. A third reviewer is now a
  registry entry. Still to do: moving Loop/RetryUntil/Try semantics themselves
  into node classes.
- **A4 · Templates as data — provenance landed; override resolution built but
  opt-in.** Every Workflow now records `template_key` and `template_source`, so
  a shadowed template can never be a silent debugging trap.
  `WorkflowTemplates.for` implements repo-local resolution on the `Skills.for`
  model, with the plan's guardrails enforced: a repo-local template may add
  checks but may neither drop a protected publication step nor introduce one
  the built-in lacked, an unknown step kind or unparseable YAML is refused, and
  an unreadable repository resolves to the built-in rather than to a guess.

  Resolution is **opt-in** (`resolve_overrides:`) and `Workflows::Base` does
  not opt in. Looking for `.syrus/workflows/<key>.yml` is a GitHub round-trip,
  and workflow instantiation is a hot path that should not grow a synchronous
  network call -- or a new failure mode -- for a file that almost never exists.
  Wiring it on wants a cache keyed to the default-branch SHA, which belongs
  with A7 where something actually writes those files.
- **A5 · Graph edges and fan-in — grader-kind filter retired; edges still to
  do.** `Step::Kind#runtime_inserted` declares which kinds a template never
  describes, so `loop_node_for` no longer names "grader" to drop the Steps
  `GraderFanout` materializes. A second fan-out step kind is now a registry
  entry rather than another name in the dispatcher, and
  `spec/architecture/dispatcher_names_no_step_kinds_spec.rb` pins it against
  the source alongside A3's reviewer gates.

  `Step#depends_on_ids` then landed, and `WAITING_FOR_BATCH` is retired.
  Ordering still comes from `next_step_id` -- that is what says which step is
  next -- but *readiness* is now a graph question: a Step runs when everything
  it depends on has settled, failures included, since what happens next is the
  remediation table's business rather than the graph's. `GraderFanout` writes
  the fan-in as real edges (every grader depends on the fanout; the collect
  step depends on every grader), so fan-in falls out of the ready-set instead
  of needing a sentinel.

  Edges are additive: empty means "just my predecessor", so a Step
  materialized before this -- or by a path that has not learned to write edges
  -- behaves exactly as it did, and `waits_for_terminal_step_kind` stays as the
  belt-and-braces fallback. Worth correcting the plan's framing while here:
  fan-in was never "exactly one case"; two step kinds already used that
  declarative rule.
- **A6 · Unit-scoped nodes — node types landed; the merge-train move still to
  do.** `Workflows::ForEachMember` and `Workflows::Barrier` are node types with
  preemption declared per node (`checkpoint` / `cancel` / `rebuild`, all three
  already existing WorkUnit behaviors), so "what happens if this is preempted
  mid-train" has a per-node answer rather than only a per-definition one.

  A5 made the barrier nearly free: with real dependency edges it is just a Step
  that depends on every member Step, so it needs no sentinel and no per-kind
  rule -- the same mechanism `grader_collect` uses. The fan-out materializes as
  one Step and inserts the per-member Steps when it runs, since members are
  only known at run time; that is the shape `GraderFanout` already uses, which
  is why both are `runtime_inserted`.

  Still to do: actually moving the merge-train shape out of
  `Steps::MergeTrainBuild` into a template built from these nodes. That is a
  behavior migration for the landing path, not a node-type addition, and wants
  its own change.
- **A7 · Agent authoring — runtime patches landed; the repo-file proposal flow
  still to do.** `WorkflowPatch` is the typed, append-only, attributed change,
  and `patch_workflow` is the MCP tool that lets an implementing agent add a
  check to its own workflow. All three guardrails are enforced rather than
  described: a patch cannot remove a node (checked against the resulting graph,
  not trusted from the operation name), cannot add a publication step, and
  records its author and reason.

  Permanent customization -- writing `.syrus/workflows/<key>.yml` through the
  pending-action confirmation flow -- is still to do. It needs A4's override
  resolution wired on with a cache, which is the piece deliberately left
  opt-in there.

### Track B — Attention

Depends on A1 and A2 only.

- **B1 · Generalize rung 0 — done.** `Adjudication` is the three-verdict answer
  and `Adjudicators` is the rung: registered checks are consulted in order and
  the first to decide wins. `inherited_grader_failure` wraps
  `MainBranchFailureClassifier` (`allow_inherited`) and `validated_landing`
  wraps the `LandingValidationCache` reuse decision; both previously answered
  only in shapes their own callers understood. `:adjudicator` is a plugin
  extension point, since a language plugin is well placed to tell "this grader
  was already failing" from its own parsed output. An adjudicator that raises
  is treated as declining, loudly -- rung 0 runs on the failure path.
  `Steps::GraderCollect` consults the rung and records its verdict as a
  workflow artifact whether or not anything acts on it, which is where the
  escalations-per-landing baseline comes from. "Verdict authority" is enforced
  by `authorized:`: a call site names the adjudicators it will act on, and an
  unauthorized verdict is reported but withheld, so adding an adjudicator
  cannot silently change what a site does.
- **B2 · Decision queue — record landed; routing still to do.** `Decision` is
  the unit: one problem, its evidence, the rung-0 verdict, and typed actions
  that must name real `PendingActions` entries (a decision offering an action
  nobody can execute reads as answerable and is not). `queue` separates
  operator decisions from triage, because merging them buries the rare
  important decision under the frequent cheap one. `Decisions::Escalator` is
  the producer: a terminally failed Workflow becomes one Decision, named in the
  shared vocabulary, ranked by what the failure costs (a stalled landing is
  urgent; a failed initial attempt is not), carrying the rung-0 verdict and the
  retry action an operator already has. `SupervisorEvents` is off the
  `NotificationService` firehose: only the notification kinds that represent
  something a person may have to act on publish an event, since most
  notifications report that something went fine and a queue of those buries the
  rare one that needs a decision. Still to do: the queue surface itself.
- **B3 · Decision signatures — fingerprint and consult landed; metric still to
  do.** `Decisions::Signature` is problem code plus a normalized fingerprint of
  only the evidence that says *which* problem this is, so two occurrences match
  and a decision can compound. `Decisions::Opener` reuses an open decision for
  the same signature and declines to ask again when a prior decision still
  applies -- scoped to a repository, never global, and expiring, since a
  dismissal that made sense against one base revision should not silently
  outlive it. `Metrics::EscalationsPerLanding` is the plan's one metric:
  Decisions opened over landings completed, broken down by problem code, with
  no ratio at all rather than a misleading infinity when nothing landed.
- **B4 · Judgment primitive — done.** `Judgment` is one bounded agent turn: a
  prompt, a declared output schema, a cost ceiling and timeout remediation from
  the day it landed, with every failure reported as a `Problem` rather than as
  an exception each caller has to recognize. All four `OneShotAgent` copies are
  retrofitted and deleted, along with the four hand-rolled fenced-JSON strips
  and the four copies of the provider-outcome checks. The success criterion
  "no `OneShotAgent` class remains outside the Judgment primitive" holds.
- **B5 · Agentic adjudication — done.** `Adjudicators::AgenticGraderReview` is
  rung 3, built on the Judgment primitive, asking only whether a failing grader
  predates the branch -- the inconclusive branch of `allow_inherited`, not a new
  authority. All three rules are enforced: it never takes the action (the
  `authorized:` guardrail applies to it like any adjudicator), it is never the
  agent that produced the diff (Judgment runs a fresh session with no
  workspace), and `inconclusive` is first class -- a low-confidence verdict or
  an unrecognized one becomes inconclusive rather than a guess.
  `AttentionLadder` holds the per-definition ladders from the table above, and
  rung 3 declines outright unless the definition includes it, so it is enabled
  for `auto_merge`/`merge_train` to begin with as the plan asks.

### Track C — Scale

- **C0 · Policy registry and risk profiles — profile and resolver landed.**
  `RiskProfile` is the bundle: three postures answering all six main-branch
  knobs consistently, plus the attention posture. `Repository#risk_profile`
  makes a project's posture readable from one value, and
  `#risk_profile_overridden?` notices when the booleans have drifted away from
  the label. Applying a profile writes its booleans, so the bundle is a bundle
  rather than a seventh knob.

  Worth recording plainly: Syrus's shipped defaults (halt unrelated work,
  strict breakage policy) *are* the plan's `production` posture, not
  `standard`. Every existing repository is backfilled with the profile matching
  the columns it already has, so nothing is relabelled and nothing is relaxed;
  moving a project to `standard` is a deliberate act.

  `Policy::Resolver` generalizes `AutoApprovalRule`'s candidate chain and
  reports which tier answered. It also makes the "policy fails open" defect
  fixable: `Policy::Resolver::Unreadable` distinguishes a tier that *said
  nothing* from one that *could not be read*, and the default is to fail
  closed. Still to do: moving the three sibling repo-file resolvers onto it,
  scopes on `AppSettingRegistry::Definition`, and recording the answering tier
  on the Workflow.
- **C1 · Actor-scoped admission and budgets — fairness rung landed.**
  `Admission::FairShare` gives admission its missing actor dimension: a user's
  share is computed against the users *actually contending right now*, so a
  sole user still gets the whole cap and the share only bites when someone else
  is waiting. `Admission::SpendBudget` enforces
  `user_daily_spend_budget_usd`, which Syrus previously only ever reported.
  Both default to off (`0`), so nothing changes until an operator sets them.

  `RunJob` consults both and **defers** -- the guardrail is absolute: a
  starvation guard that fails work converts a queueing problem into an
  attention problem. A spend deferral waits fifteen minutes rather than fifteen
  seconds, since that budget resets on a day boundary. Still to do: the actor
  dimension on `WorkflowAdmissionBudget`'s own keys.
- **C2 · Intake on the engine — reaping moved, `ReapClassifierPendingJob`
  deleted; the `triage` template still to do.** The classifier already runs
  through the Judgment primitive (B4). What kept intake off the engine was
  detection: because classification is not a Run, `WorkEngine::Reconciler`
  could not see a Job stuck waiting for one, so a private sweep on its own
  timer reimplemented stale-work reaping the reconciler already does properly.

  Detection is now a reconciler issue (`stalled_classifier_pending_job`) with a
  planned, audited repair (`reclassify_stalled_intake`), and the sweep and its
  recurring schedule entry are gone. Still to do: making classification a real
  Run inside a `triage` template, which is a migration of the
  highest-volume surface and wants its own change -- the win here is that
  intake no longer carries its own copy of the reaping logic.
- **C3 · Triage queue — done.** `Decisions::Triage` is the second producer and
  `Decision`'s queue scopes are the routing. A Job the classifier could not
  place is the natural first input: nothing is broken and nothing is stuck, it
  just needs a person to say what it is, which is a triage decision rather than
  an operator escalation -- so it files at low urgency and offers a
  *classifying* action rather than a repair.

  `in_attention_order` is deliberately scoped to one queue rather than ordering
  across both: an urgent triage item is not more important than an urgent
  landing failure, it is a different person's problem, and ranking them against
  each other is exactly the merge this phase exists to avoid.
- **C4 · Identity cleanup — done.** `Job#source_ref` is the qualified,
  cross-door identity (`"github:acme/widgets#42"`), derived on save so it
  cannot drift from the issue it names. `external_ref` could not serve: it
  holds the bare issue number and is only unambiguous when also scoped by
  `input_source_id`, so "42" from two doors was two different things.

  `InstanceIdentity` names the second half. Instance-owned work still runs as
  the repository owner, but it now says so -- `Resolution#borrowed?` -- and a
  repository with no owner is reported instead of silently not being graded
  (`PollMainBranchHealthJob` skips loudly rather than resolving nil
  credentials). `repositories_without_identity` is the number that says whether
  a real instance principal is overdue. Deliberately not changing *who* the
  work runs as: that is a credentials migration, and the instrumentation has to
  exist first.

### Suggested order

A1, A2, then Track B, then C1 — or C0/C1 first if a second heavy user is
imminent, since C1 is the only item with an external deadline. Then let the
escalations-per-landing metric decide whether the remaining engine phases are
the real constraint.

## Guardrails

- **Patch capabilities.** Runtime patches are append-only and may not remove a
  grader, a publication step, or any landing/merge node. Repo-local templates may
  only add checks; anything touching landing or publication requires operator
  confirmation through the existing pending-action flow.
- **Verdict authority.** An adjudication never applies itself. Auto-apply only
  where policy pre-authorizes that problem kind.
- **Independent judgment.** Adjudicators run in a fresh read-only session that is
  never the agent that produced the diff.
- **Policy fails closed.** When a project's policy cannot be read, work defers
  rather than proceeding under a default.
- **Fairness before capacity.** An over-share user's work defers; it never fails.
  A starvation guard that fails work converts a queueing problem into an
  attention problem.
- **Judgment runs are still runs.** Cost ceiling and timeout remediation from the
  day the primitive lands.
- **Static validation.** Unknown step kind, cycle, publication step inside a
  retry loop, or a `:publication` node without a reconcile strategy all fail at
  compile or save time. Extend `WorkDefinitions::RegistryValidator` rather than
  starting a second validator.
- **Keep the reconciler.** Detection stays; only its private failure semantics go.
- **Resist generality.** Every primitive names the special case it deletes.

## Success Criteria

- A new capability can be added without touching `StepDispatcher`,
  `WorkEngine::Reconciler`, or `WorkEngine::RepairExecutor`. Verify against merge
  train, external PR ingest, and the landing/validation pair before writing code.
- One failure code appears in the Run classification, the `Try` branch match, and
  the reconciler issue for the same event.
- `StepDispatcher` no longer names any specific reviewer step kind.
- Escalations per landing trends down over successive weeks.
- A project's risk posture is readable from one value.
- No `OneShotAgent` class remains outside the Judgment primitive.

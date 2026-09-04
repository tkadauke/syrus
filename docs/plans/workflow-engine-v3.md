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

As of 2026-09-04, **A1, A2 and B1 are implemented** (`Problem` /
`Problem::Kind`, `Remediation` / `Remediation::Resolver`, `Adjudication` /
`Adjudicators`); the rest is still a proposal. It is written
to be executed in three independent tracks (see
[Incremental Plan](#incremental-plan)); the first two phases of Track A change
no behavior and unblock everything else.

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
- **A3 · Node objects.** Loop/RetryUntil/Try semantics move into node classes;
  the two reviewer-loop copies collapse into one `Gate`.
- **A4 · Templates as data.** Persist compiled templates with provenance; add
  repo-local override resolution modelled on `Skills.for`.
- **A5 · Graph edges and fan-in.** `Step#depends_on`, ready-set dispatch, retire
  `WAITING_FOR_BATCH` and the grader-kind filter.
- **A6 · Unit-scoped nodes.** `for_each_member`/`barrier`; move the merge-train
  shape into a template; attach preemption policy to nodes.
- **A7 · Agent authoring.** MCP tools for runtime patches, and a
  proposal → confirm flow for writing `.syrus/workflows/*.yml`. Last,
  deliberately: only safe once A4's provenance, validation and capability model
  exist.

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
  is treated as declining, loudly -- rung 0 runs on the failure path. Not yet
  wired into a caller: nothing consults the rung until B2 gives a decided
  verdict somewhere to go.
- **B2 · Decision queue.** A `Decision` record bound to existing
  `PendingActions`. Cut `SupervisorEvents` off the `NotificationService`
  firehose.
- **B3 · Decision signatures.** Fingerprint problems, record decisions, consult
  from rung 0. Start the escalations-per-landing metric here for a baseline.
- **B4 · Judgment primitive.** A Run with no workspace, declared output schema,
  cost ceiling, timeout remediation. Retrofit the four `OneShotAgent` copies.
- **B5 · Agentic adjudication.** Built on B4. Enable per workflow, starting with
  `auto_merge`.

### Track C — Scale

- **C0 · Policy registry and risk profiles.** Extend
  `AppSettingRegistry::Definition` with accepted scopes; promote
  `AutoApprovalRule`'s candidate chain into the shared resolver; record which
  tier answered on the Workflow; make repo-file resolution fail closed. Collapse
  the main-branch six into a `risk_profile` with overrides. Depends on nothing;
  pairs naturally with A2, since a per-definition ladder is policy.
- **C1 · Actor-scoped admission and budgets.** Actor dimension on admission
  keys, per-user concurrency share, enforced spend budget, fairness rung that
  defers rather than fails.
- **C2 · Intake on the engine.** Classification and dedup as Judgment Runs
  inside a `triage` template; delete `ReapClassifierPendingJob`.
- **C3 · Triage queue.** Second queue on the decision mechanism, separately
  routed.
- **C4 · Identity cleanup.** `source_ref` for cross-source dedup; instance
  identity for infrastructure work.

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

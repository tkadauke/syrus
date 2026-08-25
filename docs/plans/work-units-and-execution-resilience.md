# Work Units And Execution Resilience

Syrus has accumulated too many execution states across Jobs, Workflows, Steps,
Runs, landing queues, epics, provider availability, admission control, and the
reconciler. The system works, but too much of it works by inference: a service
looks at several partially-overlapping state machines and guesses what must have
happened. That makes every new workflow type create new degenerate states.

This plan proposes a smaller model centered on explicit Work Intents and Work
Units. It should be implemented before delivery tracks and promotion, but it
must preserve room for that plan
(`docs/plans/delivery-tracks-and-promotion.md`).

## Problem

`Job#state` currently carries several different meanings:

- product lifecycle: triage, implementation complete, approved, closed;
- runtime execution: queued, running, landing, paused;
- recovery posture: failed, retryable, blocked, waiting for operator.

Those are different concepts. Combining them creates states that are hard to
reason about:

- a Job can be `failed` while a CI repair workflow is running;
- a Job can be `landing` without an active Workflow directly attached to it
  because a merge train is attached to a sibling Job;
- a Job can be `running` even though it is paused by admission control;
- a cancelled Workflow can mean operator cancel, benign skip, supersession, or
  invalidated work.

The reconciler then has to classify many symptoms and guess which repair is safe.
That turns the reconciler into a second scheduler.

## Goals

- Separate product lifecycle from runtime execution.
- Make work ownership explicit for Jobs, Epics, repositories, delivery tracks,
  and refs.
- Separate desired work from concrete execution attempts.
- Make blocked, paused, and preempted states first-class runtime states.
- Reduce the number of reconciler classifications by enforcing a smaller set of
  invariants.
- Keep delivery tracks, promotion, hotfix sync, and upstream export natural
  future extensions.
- Preserve existing behavior during migration.

## Non-Goals

- Replacing delivery tracks in this plan.
- Rewriting every workflow template at once.
- Removing Job/Workflow/Step/Run immediately.
- Fully solving release-train or multi-upstream branch policy.

## Target Concepts: WorkIntent And WorkUnit

A Work Intent is durable desired work. It answers:

```text
What should Syrus eventually do?
```

A Work Unit is a concrete execution attempt for an intent. It answers:

```text
What is Syrus currently doing, or trying to execute, for that intent?
```

This mirrors the useful Step/Run split:

```text
Desired work        Actual attempt
-------------       --------------
WorkIntent          WorkUnit
Step                Run
```

For a regular landing request:

```text
WorkIntent: "land JOB-10"
  WorkUnit #1: first landing attempt
    Workflow WF-100
  WorkUnit #2: retry after branch changed
    Workflow WF-101
  WorkUnit #3: final successful attempt
    Workflow WF-102
```

The initial invariant should be:

```text
Intent : Unit : Workflow = 1 : N : N
```

That is, one Intent can have many Units over time, and each Unit has exactly one
Workflow once instantiated. Later exceptions may exist, such as a blocked Unit
with no Workflow yet or a ref-movement Unit coordinating child Units, but those
should not be part of the first migration.

Continuations do not create new Work Units. If a concrete attempt is still the
same logical attempt, the existing Unit remains the runtime owner and records the
continuation in its Workflow/Step/Run trace:

- retry failed step;
- resume failed agent session;
- auto-retry a transient step failure while the attempt remains valid;
- unpause after admission control, provider availability, resource pressure, or
  manual pause clears.

New attempts do create new Work Units for the same Intent:

- retry implementation from scratch;
- rebuild a merge train after member/base refs changed;
- restart an attempt after the workspace/session is gone;
- resume from a durable checkpoint by creating a new checkpoint-resume Workflow;
- any retry where the old execution context is no longer trustworthy.

In short: `retry failed step`, `resume`, and `unpause` continue the same
WorkUnit; `retry implementation` is a new WorkUnit for the same WorkIntent.

## WorkIntent

Examples:

- implement JOB-10;
- address PR feedback on JOB-10;
- land JOB-10;
- land EPIC-20 as a merge train;
- rebase JOB-10;
- repair main branch;
- promote `develop -> main`;
- export JOB-10 upstream.

Responsibilities:

- idempotency and deduplication;
- durable requested work;
- priority and source/actor;
- target scope;
- requested work kind;
- policy context;
- supersession relationship;
- operator cancellation;
- domain eligibility such as "waiting for dependency."

WorkIntent should be persisted from the beginning. We already know the concept
needs durable identity for idempotency, retries, delivery tracks, ref movement,
and audit. Starting with only an interface would require touching the same call
sites twice. The guardrail is to keep the table narrow and non-runtime so it
does not become Job state v2.

WorkIntent state must change only from scheduler/domain decisions, not from
Workflow callbacks. Runtime failure belongs on WorkUnit/Workflow/Step/Run. The
Intent can become `failed` only when the desired work itself cannot proceed
without operator or domain action.

Proposed shape:

```text
work_intents
  id
  kind
  state
  repository_id
  scope_type
  scope_id
  delivery_track
  source_repository_id
  source_remote_kind
  source_ref
  target_repository_id
  target_remote_kind
  target_ref
  priority
  actor_id
  source_type
  source_id
  idempotency_key
  wait_reason
  wait_until
  wait_details
  superseded_by_work_intent_id
  requested_at
  satisfied_at
  cancelled_at
```

Lifecycle:

```text
requested
  -> waiting       # domain/policy not eligible yet
  -> satisfied     # desired outcome achieved
  -> cancelled     # no longer wanted
  -> failed        # cannot proceed without operator/action
```

`ready` and `active` are derived, not persisted:

- ready = `requested` and intent gates currently pass;
- active = has a non-terminal WorkUnit.

A dependency-blocked implementation is usually an Intent state:

```text
WorkIntent(kind: initial, state: waiting, wait_reason: dependency)
```

No WorkUnit is required until the dependency clears because there is no concrete
execution attempt yet.

## WorkUnit

A Work Unit is the scheduler-owned runtime object for one attempt. It represents
concrete work that can be queued, blocked, running, completed, failed, or
cancelled.

Examples:

- WF-100 initial implementation attempt for JOB-10;
- WF-101 retry attempt for JOB-10;
- WF-102 merge train attempt for EPIC-20;
- WF-103 promotion attempt from `develop` to `main`.

Responsibilities:

- runtime execution state;
- Workflow attachment;
- member Jobs;
- locks;
- runtime gates;
- leases / worker ownership;
- blocked runtime reasons;
- pause and preemption;
- retry/rebuild policy for this attempt;
- terminal outcome of this attempt.

Proposed shape:

```text
work_units
  id
  work_intent_id
  kind
  state
  repository_id
  scope_type
  scope_id
  delivery_track
  parent_work_unit_id
  source_repository_id
  source_remote_kind
  source_ref
  target_repository_id
  target_remote_kind
  target_ref
  workflow_id
  blocked_reason
  blocked_until
  blocked_by_user_id
  blocked_details
  pause_requested
  preempted_by_work_unit_id
  preemption_reason
  started_at
  finished_at

work_unit_members
  work_unit_id
  job_id
  role
```

`scope_type` should not be limited to Job. Initial values can be:

- `job`
- `epic`
- `repository`
- `delivery_track`
- `ref_movement`

`role` can start with:

- `primary`
- `member`
- `dependency`
- `repair_target`
- `exported_job`

This makes merge trains explicit: every member Job belongs to the merge train
Work Unit even if the underlying Workflow row is attached to only one tip Job.

WorkUnit membership is an immutable snapshot for the attempt. Definition methods
such as `members_for` may query live Jobs/Epics only while creating the Unit.
After creation, scheduling, UI, and reconciliation must read
`work_unit_members`. Later Epic membership changes, approval changes, or branch
changes should preempt/rebuild the Unit or create a new Unit, not mutate the
membership underneath an active attempt.

Locks should be concrete rows, not inferred predicates. Acquire all Unit locks
inside one database transaction by inserting unique lock-key rows such as
`job:<id>`, `epic:<id>`, `landing:<repository_id>:<target_ref>`, and
`ref:<repository_id>:<ref>`. A conflict blocks or preempts according to the
WorkDefinition policy. Terminal Unit cleanup releases the rows. The reconciler
may release locks only for terminal or stale-dead Units after proving ownership
from the Unit state, not by guessing from Job state.

## Relationship To Jobs, Epics, And Workflows

A Job can have many Intents over its lifetime:

```text
JOB-10
  WorkIntent: initial implementation
  WorkIntent: PR feedback
  WorkIntent: landing
  WorkIntent: upstream export
```

An Intent can have many Units over time:

```text
WorkIntent: land JOB-10
  WorkUnit #1 failed: branch diverged
  WorkUnit #2 blocked: main branch health
  WorkUnit #3 succeeded
```

A Unit belongs to one Intent. Initially, each Unit should have one Workflow. The
Workflow remains the step trace for that attempt.

Rule of thumb:

- ask "should this work still happen?" -> WorkIntent;
- ask "is Syrus currently able/running/paused/retrying this attempt?" ->
  WorkUnit;
- ask "which steps/logs/artifacts happened?" -> Workflow;
- ask "did this concrete step command/agent invocation run?" -> Run.

## Runtime State

Work Intents should own desired-work state:

```text
requested | waiting | satisfied | failed | cancelled
```

Work Units should own execution-attempt state:

```text
queued | blocked | running | succeeded | failed | cancelled
```

Jobs should keep product lifecycle state. The UI can still show apparent states
such as `Landing`, `Paused`, or `Running feedback`, but those should be derived
from the active Work Unit plus Job lifecycle facts.

## What Moves Out Of Job And Epic

The main thing moving out of Job and Epic is runtime execution state.

Job should stop being the source of truth for:

- whether work is queued, running, landing, or paused;
- active workflow ownership;
- admission/provider/main-health/dependency blocked reasons;
- retry and preemption posture;
- which workflow owns the Job right now;
- why the Job is not progressing;
- landing queue membership and position as runtime facts.

Those facts should come from WorkUnit and WorkUnitMember.

Job should keep:

- product lifecycle;
- issue and PR identity;
- selected delivery track;
- owner, priority, provider, credential, and repository settings;
- dependency and approval facts;
- durable completion result such as PR merged, no changes, external PR closed,
  or operator-cancelled.

Epic should stop being the source of truth for:

- active merge-train ownership;
- active stack-rebase ownership;
- Epic-wide workflow locks;
- "this Epic is currently landing/rebasing" runtime status;
- "blocked by active Epic-wide workflow" runtime status.

Epic should keep:

- grouping and ordering of child Jobs;
- product state for the feature/batch;
- dependency structure;
- Epic-level review and approval semantics.

The split is:

```text
Job/Epic:    what the user wants and whether it is accepted/done
WorkIntent: durable requested work for that product object
WorkUnit:   concrete execution attempt for an Intent
```

## Blocked And Paused

Pause mechanisms should share one WorkUnit runtime representation. Domain-level
waiting, such as an unsatisfied dependency before any attempt is eligible, should
live on WorkIntent instead.

WorkIntent wait reasons:

- `dependency`
- `approval`
- `epic_not_ready`
- `policy_not_eligible`

WorkUnit blocked reasons:

- `admission_control`
- `provider_availability`
- `manual_pause`
- `main_branch_health`
- `resource_safety`
- `auto_retry_backoff`
- `preempted`

Behavior:

- admission control: auto-resume when capacity changes or `blocked_until`
  arrives;
- provider availability: auto-resume when availability/quota recovers;
- manual pause: resume only by explicit user action;
- main branch health: follow repository policy;
- resource safety: auto-resume when pressure clears;
- auto-retry backoff: auto-resume when `blocked_until` arrives;
- preempted: auto-resume only if the preempting work is done and this unit is
  still valid.

Manual pause should not kill the current step. It should set
`pause_requested = true`; after the current run finishes, the Work Unit moves to
`blocked(manual_pause)` before scheduling the next step. If no run is active,
it blocks immediately.

Auto-retry backoff for the same attempt belongs on WorkUnit. It is not
WorkIntent `waiting`, because the desired work is still eligible and the current
attempt is simply delayed. If retry policy chooses a fresh workflow, that is a
new WorkUnit for the same Intent.

## Scheduler And Gates

Requested work should be represented as a WorkIntent, not as implicit Job state.
Concrete attempts should be represented as WorkUnits.

For example, if a Job is waiting on a dependency:

```text
Job lifecycle: open / approved / implemented
WorkIntent(kind: initial or landing): waiting
wait_reason: dependency
wait_details: { blocked_by_job_ids: [9] }
WorkUnit: none yet
```

If a Job is approved for landing but repository policy pauses landing while the
main branch is broken:

```text
Job lifecycle: approved
WorkIntent(kind: landing): requested
WorkUnit(kind: landing): blocked
blocked_reason: main_branch_health
blocked_details: { repository_id: 2, main_health_state: "broken" }
```

The decision should belong to scheduler layers, not to Job, the UI, or the
reconciler.

Intent scheduling decides whether desired work is eligible to attempt:

```ruby
WorkIntentScheduler.evaluate!(intent)
```

It evaluates domain/policy gates:

```ruby
intent_gates = [
  DependencyIntentGate,
  ApprovalIntentGate,
  EpicReadinessIntentGate,
  PolicyEligibilityIntentGate
]

intent_gates.each do |gate|
  result = gate.call(intent)
  if result.waiting?
    intent.wait!(
      reason: result.reason,
      wait_until: result.retry_at,
      details: result.details
    )
    return
  end
end

intent.create_or_resume_unit!
```

Unit scheduling decides whether a concrete attempt can currently execute:

```ruby
WorkScheduler.evaluate!(work_unit)
```

The Unit scheduler evaluates runtime gates in a consistent order:

```ruby
unit_gates = [
  MainBranchHealthGate,
  ProviderAvailabilityGate,
  ManualPauseGate,
  AdmissionControlGate,
  EpicLockGate
]

gates.each do |gate|
  result = gate.call(work_unit)
  if result.blocked?
    work_unit.block!(
      reason: result.reason,
      blocked_until: result.retry_at,
      details: result.details
    )
    return
  end
work_unit.enqueue_or_start_next_step!
```

Different causes share one runtime shape:

```text
state = blocked
blocked_reason = <typed reason>
```

Intent gates own domain wakeup paths:

- dependency gate: recheck when a dependency closes, changes approval state, or
  dependency overrides change;
- approval gate: recheck when approvals change;
- Epic readiness gate: recheck when Epic child state changes.

Unit gates own runtime wakeup paths:

- main branch health gate: recheck when repository main-health state changes;
- provider availability gate: recheck when quota/availability probes update or
  `blocked_until` arrives;
- manual pause gate: recheck only after explicit user unpause;
- admission control gate: recheck when capacity changes, a WorkUnit finishes,
  or `blocked_until` arrives;
- Epic lock gate: recheck when the blocking Epic-wide WorkUnit finishes or is
  cancelled.

The reconciler should not decide whether dependency or main-health policy allows
execution. It should verify scheduler invariants:

- waiting Intent has a valid typed reason and wakeup path;
- requested Intent whose gates pass has or is eligible to create a WorkUnit;
- Intent with non-terminal Units has exactly the expected current Unit;
- Intent with only terminal Units is either satisfied, failed, cancelled, or
  waiting for an allowed retry/rebuild;
- blocked WorkUnit has a valid typed reason;
- blocked reason has a wakeup path;
- queued WorkUnit has or will get a next Run;
- running WorkUnit has a live Run/lease;
- terminal WorkUnit has no active descendants and has released ownership.

This pulls most of today's `StepDispatcher.start_workflow` gate logic into one
explicit scheduler layer while preserving the ability to explain every blocked
Job from one Intent or WorkUnit row.

## Workflow Creation Funnel

Current code calls `Workflows::* .instantiate` directly from many places:
pollers, landing queue dispatch, merge-train dispatch, rebase selection, retry
services, pending actions, MCP tools, and controllers. WorkIntent/WorkUnit cannot
be introduced safely by shadow-writing from every scattered call site. One missed
call site would silently corrupt ownership.

Before Intent/Unit tables become broadly authoritative, new workflow creation
must go through one gateway:

```ruby
WorkUnits::Launcher.create_and_start!(kind:, source:, context:)
```

The launcher is responsible for:

- finding or creating the idempotent WorkIntent;
- creating the WorkUnit attempt;
- resolving the WorkDefinition;
- resolving scope and members;
- acquiring required persisted locks when needed;
- instantiating the existing `Workflows::*` template;
- linking WorkUnit and Workflow;
- starting the scheduler.

Migration rule:

- new code must not call `Workflows::* .instantiate` directly;
- existing direct calls move behind the launcher one at a time;
- add a spec/search guard that allows direct instantiate only inside the
  launcher, workflow template tests, and factory helpers.

## Callback Strangler

Current AASM callbacks propagate state across the execution graph:

- Workflow start/succeed/fail/cancel/reopen mutates Job state;
- Step success/failure/cancel advances or fails the Workflow;
- Run failure/cancel cascades to Step and Workflow;
- callback side effects enqueue retries, classify failures, wake admission, and
  emit activity.

If WorkUnit starts mutating the same state independently, we will create a
double-write source-of-truth problem.

Migration rule:

- do not let callbacks and the WorkUnit scheduler independently decide product
  or runtime state;
- first wrap existing callback behavior behind orchestration services without
  changing semantics;
- then move propagation responsibility one edge at a time;
- eventually, Workflow/Step/Run callbacks should report execution facts to the
  orchestration layer, and WorkUnit should own runtime attempt state.

During migration, WorkUnit can observe Workflow transitions. It should not become
authoritative for a path until callback propagation for that path is routed
through the same orchestration service.

The first concrete edge to move should be Workflow terminal propagation:
Workflow terminal result -> WorkUnit terminal outcome through one service.
Existing Job state updates can remain compatibility projections behind that
service until the relevant UI and scheduler reads have moved to WorkUnit.

## Persisted Lock Minimum

Computed ownership is a good first step for read paths, but landing needs a
transactional lock early. Today `Job#state = landing` is the effective
repository-wide landing mutex. Removing or ignoring it before replacing that
mutex would allow duplicate landing attempts.

Minimum persisted locks for migrated landing paths:

- one active landing WorkUnit per `repository_id + target_ref`;
- one active WorkUnit per Job lock;
- one active Epic-wide WorkUnit per Epic;
- one active job-bundle/merge-train WorkUnit per repository landing slot.

Physical locks should be introduced only for paths that need race protection.
Other scopes can start with computed locks through WorkOwnership until semantics
settle.

## Preemption

Preemption should not look like failure.

There are two modes.

### Soft Preemption

Use when the work remains valid and can resume later.

Examples:

- a lower-priority Work Unit yields to urgent work;
- the operator manually pauses work after the current step;
- resource pressure prevents starting the next step.

Behavior:

- let the current run finish when safe;
- do not start the next step;
- set `state = blocked`;
- set `blocked_reason = preempted`;
- optionally set `preempted_by_work_unit_id`.

### Hard Preemption

Use when the current work is no longer valid.

Examples:

- newer feedback supersedes older feedback;
- branch changed under a landing attempt;
- Job closed;
- merge train invalidated by member/base changes.

Behavior:

- cancel active descendants;
- set `state = cancelled`;
- record a typed cancellation/preemption reason;
- point to the replacing Work Unit when one exists.

Workflow policy should declare:

```ruby
preemption_policy:
  mode: :none | :soft | :hard
  checkpoint: true/false
  resume_strategy: :same_step | :new_workflow | :rebuild
```

## Ownership And Locks

The first implementation does not need a physical lock table, but the design
should be lock-shaped from the start.

Conceptual locks:

```text
work_unit_locks
  work_unit_id
  lock_type
  lock_key
```

Possible locks:

- `job:123`
- `epic:45`
- `repo:2:ref:main`
- `repo:2:track:default`
- `repo:2:landing_queue`

Examples:

- a landing Work Unit locks its Job and target ref/queue;
- a merge train Work Unit locks the Epic and every member Job;
- a promotion Work Unit locks its source/target refs;
- a hotfix sync Work Unit locks the target development track;
- a repair Work Unit may or may not block other work depending repository
  policy.

Runtime code should ask one ownership API:

```ruby
WorkOwnership.active_for_job?(job)
WorkOwnership.active_for_epic?(epic)
WorkOwnership.active_for_repository_ref?(repository, ref)
WorkOwnership.landing_owner_for(job)
WorkOwnership.can_start?(scope:, kind:)
```

No caller should hand-roll checks with `job.workflows.active`,
`job.any_active_run?`, or special-case "active Epic-wide workflow for this Job".

## UI And API Projection

WorkUnit must not be discoverable only through Workflow. That would preserve the
same bug class this plan is meant to remove. The application API should expose
active and recent work through WorkUnitMember, and desired/pending work through
WorkIntent.

For a Job detail response, the API should expose an `active_work` projection:

```json
{
  "state": "approved",
  "apparent_state": "landing",
  "current_intent": {
    "id": 77,
    "kind": "landing",
    "state": "requested",
    "execution_status": "active",
    "label": "Landing"
  },
  "active_work": {
    "id": 123,
    "kind": "merge_train",
    "state": "running",
    "label": "Epic merge train",
    "role": "member",
    "scope": { "type": "epic", "id": 254 },
    "workflow_id": 19955,
    "workflow_attached_job_id": 3538,
    "blocked_reason": null,
    "started_at": "...",
    "current_step": {
      "kind": "grader",
      "label": "rspec",
      "state": "running"
    }
  }
}
```

For paused work:

```json
{
  "state": "approved",
  "apparent_state": "paused",
  "current_intent": {
    "kind": "landing",
    "state": "requested",
    "execution_status": "blocked"
  },
  "active_work": {
    "kind": "landing",
    "state": "blocked",
    "blocked_reason": "provider_availability",
    "blocked_until": "...",
    "label": "Paused: Codex availability"
  }
}
```

For dependency-waiting work before an execution attempt exists:

```json
{
  "state": "implemented",
  "apparent_state": "blocked",
  "current_intent": {
    "kind": "landing",
    "state": "waiting",
    "wait_reason": "dependency",
    "label": "Waiting on dependency",
    "wait_details": { "blocked_by_job_ids": [9] }
  },
  "active_work": null
}
```

For manual pause:

```json
{
  "apparent_state": "paused",
  "active_work": {
    "state": "blocked",
    "blocked_reason": "manual_pause",
    "label": "Paused manually",
    "can_unpause": true
  }
}
```

Dashboard smart folders should use WorkUnitMember for:

- In progress;
- Paused;
- Landing queue;
- queue status text;
- row badges;
- retry/preemption availability.

They should use WorkIntent for domain waiting states such as dependencies,
approval waits, or Epic readiness.

The row can still show latest Workflow badges, but active work must come from
WorkUnit ownership.

## Job Workflows Tab

The current workflow-first diagnostics UI is valuable and should not lose
information. WorkUnit should be a layer above the existing Workflow trace.

Current mental model:

```text
Job
  Workflows
    Steps
      Runs
```

Target mental model:

```text
Job
  Work Intents involving this Job
    Work Units / attempts
      Workflow trace, if this Work Unit has one
        Steps
          Runs
```

For ordinary one-Job workflows, this should look almost the same as today. The
WorkUnit wrapper can be visually small:

```text
Initial implementation · requested · active attempt
  Attempt 1 · running · Workflow WF-20001
    Prepare workspace
    Implement
    Adversarial review
    Grade
    Open PR
```

For Epic-wide work, it should become clearer. On a merge-train member Job whose
Workflow is attached to a different tip Job, the tab should show:

```text
Epic merge train · requested · active attempt
  Attempt 1 · running · member
  Scope: EPIC-254
  Workflow WF-19955 attached to JOB-3538
  Current step: Grade / rspec
```

Then render the same expandable steps, runs, logs, artifacts, grader output,
review results, screenshots, and retry controls underneath.

The tab should have:

1. Current Desired Work: requested or waiting WorkIntents involving the Job.
2. Attempts / Work History: WorkUnits involving the Job, newest first.
3. Workflow Trace: today's existing Workflow/Step/Run UI nested under each
   WorkUnit attempt.

During migration, the tab should also show legacy Workflows attached directly to
the Job that do not yet have a WorkUnit. The one-time active-Workflow migration
should make this uncommon after deploy; once production has soaked with no
legacy fallback hits, the fallback can disappear.

Actions should attach to the correct layer:

- cancel desired work: WorkIntent action;
- retry failed step: Workflow/Step action that continues the same WorkUnit;
- rebuild merge train: WorkUnit action;
- pause/unpause: WorkUnit action;
- cancel active work: WorkUnit action;
- retry implementation: WorkIntent action that creates a new WorkUnit;
- open logs/artifacts: Run/Step action;
- explain why not progressing: WorkUnit action.

That keeps the diagnostic depth while making ownership and safe actions clearer.

Add UI/API invariants for this tab:

- a merge-train member Job shows the active train WorkUnit even when the
  underlying Workflow is attached to another Job;
- a WorkUnit with no Workflow yet shows its blocked/waiting reason;
- legacy Workflows still render during migration;
- every Workflow involving the Job appears exactly once;
- retry/resume/preemption controls are shown from the layer that actually owns
  the action.

## Reconciler Role

The reconciler should become an invariant enforcer, not a broad classifier of
domain intent.

Target responsibilities:

1. Recheck waiting Intents whose domain condition may now be satisfied.
2. Create or resume Units for requested Intents whose gates pass.
3. Expire stale running attempts or leases.
4. Enqueue missing work for queued Work Units.
5. Fold terminal Unit/Workflow results back into their Intent.
6. Release locks/ownership for terminal Work Units.
7. Recheck blocked Work Units whose runtime unblock condition may now be
   satisfied.

Examples of classifications that should eventually disappear:

- landing Job without active Workflow;
- queued Job cancelled without active Workflow;
- failed Job with running workflow;
- active workflow attached to one Job but semantically owning siblings.

Those become impossible or explicit once desired work and execution ownership
are recorded separately.

## Work Definitions And Workflow Templates

Intent and Unit need work-kind-specific behavior, but that behavior should not
live in `case kind` branches. Model work-kind semantics as a class hierarchy with
one definition class per kind. The same definition owns both Intent eligibility
and Unit runtime semantics for that kind.

Proposed shape:

```ruby
class WorkDefinition
  def self.for(kind)
    "WorkDefinitions::#{kind.camelize}".constantize.new
  end

  def workflow_trigger_kind = raise NotImplementedError
  def workflow_template = Workflow::TriggerKind.template_for(workflow_trigger_kind)

  def scope_for(context:) = raise NotImplementedError
  def members_for(context:) = []
  def intent_gates = []
  def unit_gates = []
  def locks_for(work_unit) = []
  def preemption_policy = WorkUnits::PreemptionPolicies::None.new
  def retry_policy = WorkUnits::RetryPolicies::Operator.new
  def label = self.class.name.demodulize.titleize
end
```

Example:

```ruby
module WorkDefinitions
  class Initial < WorkDefinition
    def workflow_trigger_kind = "initial"

    def scope_for(context:)
      WorkUnitScope.job(context.fetch(:job))
    end

    def members_for(context:)
      [WorkUnitMemberSpec.primary(context.fetch(:job))]
    end

    def locks_for(work_unit)
      [WorkUnitLockSpec.job(work_unit.primary_job)]
    end

    def intent_gates
      [
        WorkIntentGates::Dependency,
        WorkIntentGates::Approval,
        WorkIntentGates::PolicyEligibility
      ]
    end

    def unit_gates
      [
        WorkUnitGates::ManualPause,
        WorkUnitGates::ProviderAvailability,
        WorkUnitGates::AdmissionControl
      ]
    end

    def preemption_policy
      WorkUnits::PreemptionPolicies::SoftAfterCurrentStep.new
    end

    def retry_policy
      WorkUnits::RetryPolicies::ResumeStepOrNewWorkflow.new
    end
  end
end
```

Merge train:

```ruby
module WorkDefinitions
  class MergeTrain < WorkDefinition
    def workflow_trigger_kind = "merge_train"

    def scope_for(context:)
      WorkUnitScope.epic(context.fetch(:epic))
    end

    def members_for(context:)
      context.fetch(:epic).jobs.approved.map { |job| WorkUnitMemberSpec.member(job) }
    end

    def locks_for(work_unit)
      [
        WorkUnitLockSpec.epic(work_unit.scope),
        WorkUnitLockSpec.landing_queue(work_unit.repository)
      ] + work_unit.jobs.map { |job| WorkUnitLockSpec.job(job) }
    end

    def intent_gates
      [
        WorkIntentGates::AllEpicMembersApproved,
        WorkIntentGates::PolicyEligibility
      ]
    end

    def unit_gates
      [
        WorkUnitGates::MainBranchHealth,
        WorkUnitGates::ProviderAvailability,
        WorkUnitGates::AdmissionControl
      ]
    end

    def preemption_policy
      WorkUnits::PreemptionPolicies::HardRebuildOnMemberOrBranchChange.new
    end

    def retry_policy
      WorkUnits::RetryPolicies::RebuildUnit.new
    end
  end
end
```

Scheduler code should stay generic:

```ruby
definition = intent.definition

definition.intent_gates.each do |gate_class|
  result = gate_class.new.call(intent)
  return wait(intent, result) if result.waiting?
end

unit = intent.current_or_new_unit
definition = unit.definition

definition.unit_gates.each do |gate_class|
  result = gate_class.new.call(work_unit)
  return block(work_unit, result) if result.blocked?
end

locks = definition.locks_for(work_unit)
```

No new type-switches should be introduced for normal behavior.

### Boundary With `Workflows::*`

This must not create a second workflow-assembly system. Syrus already has
`Workflow::TriggerKind` and `Workflows::*` templates that assemble the step
chain. That remains the execution-plan layer.

The split should be:

```text
WorkDefinitions::* decides whether/when/where work may run
Workflows::*      decides what steps run once it does
Steps::*          decides how each step performs
Policy objects    decide repo/project-specific choices
```

Do not move step chains into WorkUnit definitions. These stay in `Workflows::*`:

```text
initial:     prepare -> implement -> review loops -> grade -> summarize -> pr_open
merge_train: assemble -> build -> reconcile -> prepare -> grade -> land
```

Work definitions should point to the existing workflow template:

```ruby
def workflow_template
  Workflow::TriggerKind.template_for(workflow_trigger_kind)
end
```

Examples of correct placement:

- "merge train has assemble/build/reconcile/land" belongs in
  `Workflows::MergeTrain`;
- "merge train owns all approved Epic Jobs" belongs in
  `WorkDefinitions::MergeTrain`;
- "merge train cannot start until all members are approved" belongs in a gate
  referenced by `WorkDefinitions::MergeTrain`;
- "merge train targets `develop` vs `main`" belongs in delivery policy;
- "merge_train_build failure rebuilds the unit" belongs in WorkUnit retry policy
  or Step repair semantics, but not both.

Because this creates two related class hierarchies, add a deterministic
validation spec:

- every `Workflow::TriggerKind` is classified with
  `runtime_role: first_class | child | infrastructure | legacy`;
- every first-class trigger kind has a corresponding `WorkDefinitions::*`
  definition;
- every child trigger kind declares its parent WorkUnit relationship or why it
  is legacy-only;
- every `WorkDefinitions::*#workflow_trigger_kind` exists in
  `Workflow::TriggerKind`;
- every Work definition's template class can instantiate a Workflow;
- every Work definition declares scope, intent gates, unit gates, locks,
  preemption policy, and retry policy;
- delivery/ref-movement Work definitions either map to a Workflow template
  or are explicitly non-workflow units.

This keeps the hierarchies in sync without scattering runtime behavior across
unvalidated parallel registries.

Speculative validation workflows, such as landing-validation prefetch and
merge-train validation, should be modeled as child/derived WorkUnits, not as
new user-facing Intents. They need `parent_work_unit_id` so cancellation,
debugging, and preemption remain attached to the landing attempt that spawned
them.

Infrastructure workflows, such as main graders or agent insights, may still have
Intents and Units, but their WorkDefinitions should be explicitly marked
infrastructure so UI and scheduler policies do not pretend they are normal
operator-requested work.

Initial trigger-kind classification should start from the current registry:

- `first_class`: `initial`, `pr_comment`, `chat_feedback`, `ci_failure`,
  `rebase`, `stack_rebase`, `auto_merge`, `external_pr_merge`, `merge_train`,
  `retry`, `manual_visual_review`, `manual`, `resume`, `coding_handoff`,
  `local_mode_handoff`, `main_branch_repair`, `manual_agentic_run`,
  `external_pr_ingest`, `external_pr_feedback`, `skill`;
- `child`: `landing_validation`, `merge_train_validation`;
- `infrastructure`: `main_grader`, `agent_insight`;
- `legacy`: `replay`, unless it still has a live production entry point.

The classification spec should fail when a new trigger kind is added without a
runtime role.

### `Workflow::TriggerKind` Authority During Migration

`Workflow::TriggerKind` currently owns template lookup, labels/styles, retry
labels, feedback-kind grouping, and Epic-wide classification. WorkDefinition
will own runtime semantics: scope, members, locks, gates, preemption, and retry
policy.

During migration:

- `Workflow::TriggerKind` remains the compatibility registry for template lookup
  and existing UI labels;
- WorkDefinition becomes authoritative for scheduling/runtime semantics;
- helper concepts such as `epic_wide?`, feedback grouping, and retry labels
  should move to WorkDefinition or presentation objects once the corresponding
  call sites migrate;
- do not add new runtime semantics to `Workflow::TriggerKind`.

The end state should be:

```text
WorkDefinition: runtime/scheduling authority
Workflow::TriggerKind: template lookup compatibility, then potentially reduced
Presenter/UI: labels, colors, retry button text
```

### Step Failure To Unit Policy

`Step::Kind` already declares step-local repair semantics. WorkDefinition retry
policy must not duplicate or contradict it.

Precedence:

1. `Step::Kind` classifies the failed step category, e.g. agentic,
   publication, rebuild, deterministic idempotent, operator review.
2. WorkDefinition decides the unit-level response to that category, e.g. resume
   step, create a new Unit, rebuild a merge train, or require operator review.
3. Reconciler and retry services execute that decision. They should not choose a
   separate response by switching on trigger kind.

This means a step such as `merge_train_build` can say "this failure requires a
rebuild category", while `WorkDefinitions::MergeTrain` decides what rebuilding a
train means for the whole Unit.

## Workflow, Step, And Run

Do not collapse these immediately, but the long-term direction should be:

- Workflow: immutable execution plan and template instance.
- Step: planned node in the Workflow.
- StepAttempt or Run: actual execution attempt for a Step.

Step state should eventually be derived from attempts or be a projection updated
from one place. Today Step and Run both have queued/running/succeeded/failed
states, and callbacks propagate failures in several directions. That creates
state drift. Work Units reduce the blast radius first; Step/Run simplification
can come after.

## Compatibility With Delivery Tracks

This plan should land before delivery tracks, but it must not conflict with
them.

The delivery plan needs runtime units for:

- ordinary landing into a selected track;
- promotion from one ref/track to another;
- hotfix sync from release back to development;
- per-job upstream export;
- branch upstream export;
- PR ingestion and branch export review.

Those all fit naturally as Work Units as long as WorkUnit is not job-only.

Epicless job bundles also need first-class coverage. Today `JobBundleDispatcher`
uses `MergeTrain`/`MergeTrainMember` with `epic_id: nil`, which is a semantic
mismatch. Add `job_bundle` as a WorkDefinition/WorkUnit kind even if it reuses
`Workflows::MergeTrain` internally during migration.

Important compatibility rules:

- WorkIntent/WorkUnit must support repository-aware source and target ref
  endpoints, not only plain strings. A future-proof shape is:

  ```text
  source_repository_id
  source_remote_kind
  source_ref
  target_repository_id
  target_remote_kind
  target_ref
  ```

  Plain `source_ref` / `target_ref` strings are acceptable only as a temporary
  local-repository shortcut.
- Landing must not mean "merge into repository default branch"; it means
  "execute this unit's selected policy against its resolved target ref."
- Branch, grader phase, approval behavior, and transport must come from policy
  objects, not from hardcoded workflow kinds.
- Jobs should not gain many new delivery states; delivery posture should be
  derived from concrete delivery facts plus active Work Units.

Future delivery actions can then look like:

```text
WorkUnit(kind: promotion, scope: repository/track, source_ref: develop, target_ref: main)
WorkUnit(kind: hotfix_sync, scope: repository/track, source_ref: main, target_ref: develop)
WorkUnit(kind: upstream_export, scope: job, source_ref: syrus/job-123, target_ref: upstream/main)
WorkUnit(kind: merge_train, scope: epic)
```

## Rollout Gates

This migration is deep enough to need feature gates, but not one flag per
workflow type. Use a small number of subsystem gates, and make each gate an
ownership handoff: for any migrated path, exactly one implementation is allowed
to enqueue, repair, pause, cancel, or reconcile that work.

The proposed gates:

1. `work_units_scheduler`
   - enables WorkUnit ownership for lower-risk single-Job runtime paths and
     continuations: retry, resume, manual pause/unpause, admission-control
     pause, and provider-availability pause;
   - initial implementation can graduate behind this gate later, after the
     continuation paths prove the ownership model;
   - legacy code for those paths remains present but is no longer the owner
     while the flag is on.
2. `work_units_landing`
   - enables WorkUnit ownership for landing queue, auto-merge, merge trains,
     stack rebases, landing locks, and Epic-wide landing ownership;
   - separate from the basic scheduler gate because the blast radius is much
     larger.
3. `work_units_reconciler`
   - lets reconciler invariant modules act from WorkIntent/WorkUnit state for
     paths whose ownership has graduated;
   - legacy classifications remain active for unmigrated paths;
   - should be enabled only after the relevant scheduler/landing paths have
     been observed in production.

Do not gate the schema, models, definitions, or observational UI. Do not make
dual-write optional once it is stable; optional dual-write would create partial
production data and make debugging worse.

Because flags should be reversible, deletion of old behavior must lag behind
path migration. The migration shape is:

1. extract the old behavior behind a path-owned adapter;
2. add the WorkUnit-backed implementation behind the same interface;
3. make the gate choose exactly one implementation for that path;
4. after a bake period, permanently enable the WorkUnit implementation and
   delete the legacy adapter for that path.

So "delete as we go" means "delete after each path graduates", not "delete the
legacy behavior the moment the new code is introduced." Until graduation, direct
legacy calls should still be removed or isolated so the old and new schedulers
cannot both act on the same work.

Maintain a migration matrix for every path before enabling behavior:

```text
path | legacy owner | WorkUnit owner | adapter | gate | forbidden direct calls | graduation checks
```

Examples of paths:

- retry/resume failed step;
- auto-retry transient failure;
- manual pause/unpause;
- provider/admission pause;
- initial implementation;
- PR/chat feedback;
- CI failure repair;
- single-job landing;
- merge train;
- stack rebase;
- speculative landing validation;
- main branch repair/main grader.

Current migration matrix:

| Path | Legacy owner | WorkUnit owner | Adapter | Gate | Forbidden direct calls | Graduation checks |
| --- | --- | --- | --- | --- | --- | --- |
| retry | `RetryWorkflowEnqueuer`, direct retry Workflow rows, retry artifacts | `WorkIntent(kind: retry)` + active job WorkUnit | `WorkUnits::Launcher`, `WorkIntents::Scheduler`, `WorkUnits::Ownership` | `work_units_scheduler` | direct `Workflows::Retry.instantiate`, direct `StepDispatcher.start_workflow`, retry Workflow active scans once gate is on | retry workflows all have WorkUnits; no active retry Workflow without WorkUnit for one operational window; retry UI reads WorkUnit/Intent ownership |
| auto_retry_backoff | `AutoRetryAttempt` scheduled wakeups only | same-attempt retry WorkUnit blocked with `auto_retry_backoff`; fresh-workflow retries create a new WorkUnit | `WorkUnits::AutoRetryBackoff`, `AutoRetryJob`, `WorkEngine::RepairExecutor` | `work_units_scheduler` | sleeping same-attempt retries without WorkUnit blocked state; holding old WorkUnit locks for fresh retry workflows | same-attempt retry sleeps are visible as blocked WorkUnits and clear when retry fires/skips; retry-workflow attempts do not self-block on the old Unit |
| resume | `RetryFailedStepEnqueuer` / deferred step resume through `StepDispatcher` | existing active WorkUnit continuation | `WorkUnits::DeferredPhaseResume`, `WorkUnits::Launcher` | `work_units_scheduler` | direct phase resume outside `WorkUnits::DeferredPhaseResume`; direct first-run creation outside launcher | failed-step/resume actions resume or block through WorkUnit state; no duplicate Runs created for resumed steps |
| manual_pause | `Job#manually_paused`, Workflow start-block artifacts | active WorkUnit `blocked/manual_pause` plus `pause_requested` | `JobManualPause`, `WorkUnits::Scheduler`, `WorkUnits::DeferredPhaseResume` | `work_units_scheduler` | manual unpause starting Workflows directly; manual pause represented only by Workflow artifacts | paused smart folders and job detail read WorkUnit block; unpause wakes active Units without stale artifacts |
| admission_control_pause | Workflow `start_blocked_reason` / phase-step artifacts | active WorkUnit `blocked/admission_control` or `resource_safety` | `WorkUnits::Scheduler`, `WorkflowPhaseAdmissionJob`, `WorkUnits::DeferredPhaseResume` | `work_units_scheduler` | admission wakeups bypassing WorkUnit scheduler; starting first/next Runs without gate evaluation | admission backoff wakeups resume or refresh WorkUnit block; no queued Run leaks past resource gates |
| provider_availability_pause | provider start-block artifacts and provider wakeup scans | active WorkUnit `blocked/provider_availability` | `WorkUnits::Scheduler`, provider wakeups, `WorkUnits::DeferredPhaseResume` | `work_units_scheduler` | provider wakeups scanning only Workflow artifacts; provider-blocked Runs enqueued without Unit gate | provider recovery resumes typed blocked Units; provider pauses show one reason in job/dashboard UI |
| auto_merge | `Job#landing`, landing Workflow rows, landing queue scans | landing WorkIntent/WorkUnit with job/ref/queue locks | `LandingQueueProcessor`, `WorkUnits::Launcher`, `WorkUnits::Ownership` | `work_units_landing` | generic requested-Intent launch for fresh landing Intents; direct auto-merge Workflow start outside landing queue | one landing owner per repo/ref; landing queue shows WorkUnit owner; stale landing Workflow fallback unused for one operational window |
| external_pr_merge | landing-style external PR Workflow rows | landing/ref WorkUnit for external PR merge | `LandingQueueProcessor`, `WorkUnits::Launcher`, `WorkUnits::WorkflowCancellation` | `work_units_landing` | direct external-pr merge Workflow start outside landing queue | external PR merge ownership appears in landing queue; closed/merged external PR cancellation stamps WorkUnit |
| landing_queue | `Job#state = landing`, landing Workflow active checks | repository/ref landing lock WorkUnits and member rows | `LandingQueueProcessor`, `WorkUnits::Ownership`, `WorkUnitLock` | `work_units_landing` | hand-rolled `Workflow.active` landing ownership checks after gate on | no duplicate active landing locks; blocked landing reasons come from WorkUnits; queue reentry no longer needs legacy artifacts |
| landing_validation | validation Workflow rows and landing validation artifacts | child WorkUnit under landing parent | `LandingValidationPrefetcher`, `WorkUnits::Launcher`, parent/child Unit invariant repair | `work_units_landing` | detached validation Workflows without parent Unit | child Units are cancelled when parent terminal; validation appears under parent landing attempt |
| job_bundle | bundle-backed `MergeTrain` rows with `epic_id: nil` and `merge_train` Workflow semantics | repository-scoped `WorkIntent(kind: job_bundle)` / `WorkUnit(kind: job_bundle)` with member rows and landing locks | `JobBundleDispatcher`, `WorkUnits::Launcher`, `WorkUnits::Ownership` | `work_units_landing` | dispatching epicless bundles as `merge_train` WorkUnits | epicless bundles appear as job-bundle ownership while reusing merge-train Workflow steps; one repository landing lock covers the bundle |
| job_bundle_validation | merge-train-validation Workflow rows for epicless bundle prefetch | child WorkUnit under a job-bundle parent | `LandingValidationPrefetcher`, `WorkUnits::Launcher`, child Unit invariant repair | `work_units_landing` | detached bundle validation Workflows or validations classified as Epic train children | validation child Units use `job_bundle_validation`; active bundle validation blocks duplicate bundle prefetch only for the bundle family |
| merge_train | Epic/Job state and active epic-wide Workflow scans | Epic-scoped WorkIntent/WorkUnit with member rows and locks | `MergeTrainDispatcher`, `WorkUnits::Launcher`, `WorkUnits::Ownership` | `work_units_landing` | starting merge-train through generic scheduler; sibling ownership inferred only from Jobs | one active Epic-wide Unit per Epic; member Job workflow tabs show train owner; conflict preemption stamps WorkUnit |
| merge_train_validation | validation Workflow rows under merge train | child WorkUnit under merge-train parent | `WorkUnits::Launcher`, child Unit reconciler invariant | `work_units_landing` | validation Workflows without parent Unit | validation child lifecycle follows parent train; no orphan validation Units after parent terminal |
| stack_rebase | rebase Workflow rows and stack polling scans | maintenance WorkUnit with rebase-specific locks | `RebaseWorkflowSelector`, `WorkUnits::Launcher`, `WorkUnits::Ownership` | `work_units_landing` | direct stack rebase creation/start; CI-failure/landing blocking based only on Workflow rows | stack rebase active owner visible from WorkUnit; duplicate rebase locks rejected; preempted stack work is typed |
| epic_wide_workflow | reconciler Epic-wide Workflow conflict classifier | active Epic-scoped WorkUnit ownership | `WorkEngine::RuntimeOwnership`, `WorkUnits::Ownership` | `work_units_reconciler` | conflict classification by active Workflow scans only | conflict repair/preemption cites keeper WorkUnit; no queued Jobs stranded by stale Epic lock artifacts |
| orphaned_queued_runs | queued Run / Step / Workflow drift classifiers | WorkUnit-owned queued-step invariant | `WorkEngine::Reconciler`, `WorkUnits::DeferredPhaseResume` | `work_units_reconciler` | reenqueue/advance repairs that bypass WorkUnit gates | orphan queued Runs are repaired without duplicate first Runs; WorkUnit remains the active owner |
| paused_units | Workflow artifact start-block classifiers | WorkUnit `blocked_*` fields | `WorkUnits::StartBlock`, `WorkUnits::WorkflowBlockProjection` | `work_units_reconciler` | start-block classifiers reading only serialized artifacts | blocked Unit has typed reason and wakeup path; artifact-only fallbacks stay empty after bake |
| stale_runs | stale Run repair classifiers | WorkUnit running/blocked lease invariant | `WorkEngine::Reconciler`, `WorkUnits::Ownership` | `work_units_reconciler` | stale-run retry/reenqueue without checking owning Unit | stale repair updates/cancels the active Unit; locks are released on terminal repair |
| terminal_orphan_workflows | terminal Workflow with active descendants classifiers | terminal WorkUnit child/descendant invariant | `WorkUnits::TerminalWorkflowSync`, child Unit repair | `work_units_reconciler` | terminal descendant cleanup that leaves active child Units | terminal parent has no active child Units; terminal Workflow sync releases locks |
| workflow_repair | broad Workflow state repair classifiers | WorkIntent/WorkUnit invariant repairs | `WorkIntents::Scheduler`, `WorkUnits::Launcher`, `WorkUnits::WorkflowCancellation` | `work_units_reconciler` | repair execution directly instantiating or starting Workflows | requested Intents launch through scheduler; repairs use typed cancellation/preemption; no duplicated active Units |

Each adapter must have tests proving the flag selects exactly one owner. For a
flagged-on path, direct legacy calls should be unreachable through the production
entry points; for a flagged-off path, WorkUnit code may observe but must not act.

## Incremental Plan

### Phase 1: WorkOwnership And WorkDefinition Facades

Create single ownership and definition abstractions before making tables
authoritative.

Initial implementation can read the current Workflow/Job/Epic data. The point is
to stop spreading active-work inference across the app.

Move these callers first:

- dashboard apparent state;
- landing queue;
- CI failure dispatch;
- feedback dispatch;
- retry eligibility;
- StepDispatcher start guards;
- WorkEngine reconciler;
- Epic-wide workflow lock checks.

Completed slices:

- WorkDefinition now exposes `blocks_ci_failure?`, landing/ref-mutating
  definitions opt into it, and `PollPullRequestJob` suppresses CI repair through
  WorkUnit ownership before falling back to legacy `Job#landing?`.

Add invariant specs:

- merge-train members are owned by the active train even if the Workflow belongs
  to one member Job;
- CI failure does not start for a Job owned by active landing;
- feedback supersession is represented as typed preemption, not ordinary
  failure;
- manually paused work does not schedule the next step.

Also add WorkDefinition classes mapped to existing `Workflow::TriggerKind` values
and validation specs, but do not move step assembly out of `Workflows::*`.

### Phase 2: Workflow Launcher Funnel

Introduce `WorkUnits::Launcher.create_and_start!` and migrate direct workflow
creation call sites through it one by one.

The launcher funnel can be broad before behavior changes, but ownership should
not migrate in this order. First route workflow creation through one place so
shadow tables and diagnostics are reliable.

Initial launcher coverage should include:

- merge train dispatch;
- job bundle dispatch;
- ordinary landing;
- feedback dispatch;
- CI failure dispatch;
- retry/rebase dispatch.

Completed slices:

- `WorkUnits::Launcher.create_and_start!` now owns the create-plus-dispatch
  funnel, and CI-failure dispatch uses it instead of instantiating then starting
  the Workflow in the poller.
- PR feedback dispatch now uses the same create-plus-dispatch funnel and retains
  WorkUnit ownership on the created `pr_comment` Workflow.
- Chat feedback submission now uses the same funnel, preserving the existing
  unapprove-before-dispatch behavior through the launcher boundary.
- Manual visual review submission now uses the launcher create-plus-dispatch
  result instead of starting the Workflow in the service.
- Manual CI repair reruns now use the launcher create-plus-dispatch result while
  preserving the existing deferred-start error path.
- External PR ingest, external PR feedback, and external PR ingest retry now use
  the launcher create-plus-dispatch result instead of direct `StepDispatcher`
  calls in their poll/retry services.
- Landing queue, job bundle, and merge-train dispatch now route post-transaction
  starts through `WorkUnits::Launcher.start!`, preserving their existing
  create-under-lock/start-after-commit boundary while removing direct dispatcher
  calls from the landing services.
- Scheduled task fires now route their prompt-specific starts through
  `WorkUnits::Launcher.start!`, preserving rendered prompts for freeform cron
  tasks and blank prompts for skill tasks while retaining WorkUnit ownership.
- Automatic and manual agent-insight workflow starts now use
  `WorkUnits::Launcher.create_and_start!` instead of direct dispatcher calls.
- Job lifecycle initial starts and the manual direct-Job start endpoint now
  route first-run creation through `WorkUnits::Launcher.start!`, preserving
  direct-job prompt rendering and skill-launch blank prompts.
- Fork-review PR feedback follow-ups now use
  `WorkUnits::Launcher.create_and_start!`, preserving the review-comment
  handling audit link to the created Workflow.
- Main-grader workflow creation now starts through
  `WorkUnits::Launcher.start!`, keeping the main-SHA artifact while moving
  first-run creation behind the launcher boundary.
- Queued workflow continuation starts from dependency unblock and start-block
  rechecks now route through `WorkUnits::Launcher.start!` rather than calling
  `StepDispatcher` directly.
- Urgent-job release now resumes held queued workflows through
  `WorkUnits::Launcher.start!`.
- Provider-admission wakeups now resume provider-blocked queued workflows
  through `WorkUnits::Launcher.start!` while keeping auto-retry wakeup behavior
  unchanged.
- Retry workflow enqueue now preserves create-under-lock/start-after-lock
  behavior while routing the start through `WorkUnits::Launcher.start!`.
- Automatic rebase, merge-state-triggered rebase, and stack-rebase cascade
  dispatch now start maintenance workflows through `WorkUnits::Launcher.start!`.
- Operator pending actions for `rebase_job`, `force_rebase`, and `restack_epic`
  now start their rebase workflows through `WorkUnits::Launcher.start!`.
- Coding and local-mode handoff workflows now start through
  `WorkUnits::Launcher.start!` after handoff state changes, covering both
  pending-action confirmation and direct MCP `complete_implement_step` calls.
- Manual agentic repair runs now start through `WorkUnits::Launcher.start!`,
  preserving base-selection artifacts and the existing audit log while giving
  the workflow WorkUnit ownership.
- Pending-feedback retry redispatch now starts retained `pr_comment` and
  `external_pr_feedback` workflows through `WorkUnits::Launcher.start!`, while
  keeping freeform chat-feedback retries on the existing submission service.
- Operator `reenqueue_work` repair now starts queued Workflows that are missing
  their first Run through `WorkUnits::Launcher.start!`; existing queued Run
  re-enqueue behavior remains unchanged.
- Main-health recovery now restarts previously blocked queued Workflows and
  dispatches recovery rebases for PRs with stale failing CI through
  `WorkUnits::Launcher.start!`.
- The operator job `rebase` command now starts its selected rebase Workflow
  through `WorkUnits::Launcher.start!`, preserving the returned Run payload.
- Speculative landing-validation prefetch now starts validation Workflows
  through `WorkUnits::Launcher.start!` after transactional eligibility checks,
  preserving the existing source Workflow artifact link.
- Auto-merge control now starts inline rebase Workflows through
  `WorkUnits::Launcher.start!` when landing discovers the PR needs a rebase.
- Work-engine repair execution now routes workflow-start repairs through
  `WorkUnits::Launcher.start!`, covering cancelled feedback workflow retries,
  queued Workflows missing first Runs, and stale dependency-block clears.
- The launch-funnel architecture spec now guards both workflow-template
  instantiation and workflow starts, so production app code cannot introduce new
  direct `Workflows::* .instantiate` or `StepDispatcher.start_workflow` call
  sites outside `WorkUnits::Launcher`.

Keep the guard spec in place so new direct `Workflows::* .instantiate` and
`StepDispatcher.start_workflow` call sites cannot appear outside the launcher.

The launcher funnel is now the guarded production entry point for workflow
creation and starts. Keep the architecture spec in place so ownership stays
centralized while the remaining cleanup removes workflow-first reads.
Behavioral ownership graduated in the rollout-gate order: continuations first,
initial/single-Job scheduling next, landing/merge trains after that.

### Phase 3: Shadow Intent And Unit Tables

Add `work_intents`, `work_units`, and `work_unit_members`.

Populate them from the launcher, not from scattered call sites. During rollout,
active workflows are backfilled into WorkIntent/WorkUnit rows by the one-time
`BackfillActiveWorkUnits` migration so installations that upgrade with
queued/running workflows converge without requiring a recurring bridge. Existing
Job/Workflow behavior was the source of truth during this phase; new runtime
ownership should now be represented by WorkIntent/WorkUnit rows.

For every requested piece of work, write:

- WorkIntent kind;
- scope;
- repository;
- source/actor;
- idempotency key;
- wait reason, if domain eligibility blocks it.

For every new concrete attempt, write:

- WorkUnit kind;
- WorkIntent link;
- scope;
- member Jobs;
- repository;
- selected track/ref metadata if known;
- workflow link.

Start with merge trains and job bundles because they are the clearest mismatch:
one Workflow attached to one Job but semantically owning multiple Jobs.

Completed slices:

- Active legacy Workflows without WorkUnit ownership are backfilled by the
  `BackfillActiveWorkUnits` migration, so a deploy can converge existing
  queued/running Workflows into the intent/unit model without adding a recurring
  runtime backfill job.
- `WorkDefinitions::Base#ref_metadata_for` now centralizes the selected
  delivery-track and source/target repository/ref snapshot. `WorkUnits::Launcher`
  and the active-workflow migration persist that metadata onto `WorkIntent` and
  `WorkUnit` rows.

### Phase 4: Scheduler Reads Intents And Units

Make scheduling and UI read WorkIntents and WorkUnits first.

Use WorkIntents for:

- requested work detection;
- dependency/approval/Epic-readiness waits;
- deduplication and supersession;
- "should this work still happen?" decisions.

Use WorkUnits for:

- active work detection;
- blocked/paused display;
- landing ownership;
- Epic-wide locking;
- job "In progress" / "Paused" / "Landing queue" apparent states;
- retry and preemption eligibility.

`Job#state = landing` can remain as a denormalized projection during migration,
but should no longer be the source of truth for whether a Job has a landing
intent or active landing unit.

For each migrated path, the API must guarantee every Workflow appears exactly
once in job detail:

- under a WorkUnit if it has membership;
- under "Legacy workflows" otherwise;
- cross-job WorkUnit membership can show a Workflow attached to another Job;
- raw `job.workflows` remains available for debugging but not for active-state
  derivation.

After the active-Workflow migration has been stable in production, the "Legacy
workflows" branch should be removed as part of the technical-debt cleanup.

Completed slices:

- `Job.without_active_runtime_work` now uses `WorkUnits::Ownership` instead of only
  `Workflow.active_job_ids`, so dashboard and smart-folder scopes exclude Jobs
  owned by active WorkUnits, including cross-job WorkUnit membership, without
  treating legacy active Workflow rows as runtime ownership.
- Dashboard and Job detail paused-state reads now consult blocked WorkUnits,
  while deliberately excluding landing WorkUnits so admission-blocked landing
  work remains visible in the landing queue instead of moving to the Paused
  folder. The remaining Workflow artifact projection is retained for
  audit/display compatibility, not for scheduler ownership.
- `Job#active_workflow_trigger_kind` now delegates to
  `WorkUnits::Ownership.active_trigger_kinds_by_job_id`, so single-Job callers
  see cross-job WorkUnit ownership instead of only workflows directly attached
  to that Job.
- Dashboard and Job detail start-blocked metadata now fall back to blocked
  WorkUnit reason/details/next wakeup data, so WorkUnit-paused jobs explain
  why they are paused even when no legacy Workflow artifact exists.
- Workflow start-block projection now preserves typed WorkUnit blocked reasons
  for dependency failures, stack waits, fan-in base failures, not-ready Jobs,
  urgent-job gating, Epic-wide workflow locks, provider availability, admission
  control, and main-branch health instead of collapsing scheduler waits into
  generic preemption; the shared blocked-reason UI labels cover the same
  vocabulary.
- The Job Workflows tab API now nests Workflow traces under WorkUnits and keeps
  the top-level Workflow list as the legacy fallback for direct workflows
  without WorkUnit ownership, so cross-job units such as merge-train member work
  are diagnosable from every member Job without duplicate rendering.
- Chat job-status cards now read active Workflows through
  `WorkUnits::Ownership.active_workflows_by_job_id`, so active member work in
  an Epic-wide WorkUnit suppresses stale "awaiting review" blockers and shows
  the current workflow/step even when the Workflow row belongs to another Job.
- Dashboard attention presets now combine filtered legacy Workflow rows with
  running WorkUnit membership for "In progress" and infrastructure-work
  "Queued" exclusions, so WorkUnit-owned member work is visible without losing
  the legacy paused-artifact filter during migration.
- Rebase and stack-rebase active-work selection now applies the shared
  feature-gated legacy Workflow visibility rules before considering direct
  Workflow rows, so stale legacy rebase rows stop blocking stack/rebase actions
  once the relevant path is WorkUnit-owned.

### Phase 5: Reconciler Simplification

Rewrite reconciler checks around Intent and Unit invariants:

- waiting Intent has a valid typed reason and wakeup path;
- requested Intent whose gates pass has a Unit or is eligible to create one;
- Intent with non-terminal Units points at active/recent Units;
- queued WorkUnit has a runnable next attempt or is blocked with a reason;
- running WorkUnit has a live lease or active descendant;
- terminal Workflow has no active descendants;
- terminal WorkUnit has released locks;
- blocked WorkUnit has a valid retry/wakeup path.

Delete obsolete classifications once the new invariants cover them.

Initial deletion/replacement targets:

- `landing_job_without_active_workflow` for WorkUnit-backed landing members;
- Epic-wide active workflow conflict repairs once WorkUnit locks cover them;
- approved Job start-blocked detection once Intent/Unit blocked reasons are
  authoritative for that path;
- queued Jobs cancelled by Epic workflow conflict once hard preemption is
  represented on the WorkUnit;
- ad hoc active-work checks in PR/CI pollers once WorkOwnership covers the path.

Every migrated path should delete or disable at least one matching inference or
reconciler special case. Otherwise this becomes additive complexity.
Here, "disable" means unreachable behind the same path adapter with flag tests;
physical deletion waits until rollback is no longer needed.

Concrete Phase 5 graduation targets:

- after WorkUnit-backed landing, remove/disable legacy
  `landing_job_without_active_workflow`;
- after WorkUnit-backed merge trains, remove/disable merge-train sibling
  ownership inference from Job state;
- after WorkUnit-backed pause/admission, remove/disable approved-Job
  start-blocked inference for those reasons;
- after WorkUnit-backed CI failure dispatch, remove/disable CI repair checks
  that infer active landing from unrelated Workflow rows.

Completed slices:

- `landing_job_without_active_workflow` now goes through
  `WorkEngine::RuntimeOwnership.active_landing_work_for_job?`. With
  `work_units_landing` enabled, active landing WorkUnits are authoritative, so
  a landing Job is not auto-deferred merely because the old direct Workflow row
  is terminal or absent. With the gate disabled, the adapter preserves the
  legacy active-Workflow / Epic-wide Workflow fallback.
- Start-block reconciliation now reads linked WorkUnit blocked state when
  legacy Workflow start-block artifacts are absent. Admission/resource,
  dependency/stack, main-health, and landing start-block classifiers carry the
  WorkUnit ID and typed reason in evidence; expired WorkUnit-only admission
  blocks re-enter the normal dispatcher path, and stale WorkUnit-only
  dependency blocks are cleared before the Workflow is restarted.
- The WorkUnit scheduler now owns the first runtime start gates behind the
  `work_units_scheduler` feature: main-branch health, provider availability,
  manual pause, admission control, and hard resource safety. `StepDispatcher`
  remains a migration safety net, but launcher-blocked WorkUnits record typed
  blocked reasons and schedule admission/landing rechecks for non-manual
  runtime pauses.
- Provider and admission wakeups now read WorkUnit blocked state before legacy
  Workflow artifact markers. Provider availability, provider-admission/circuit
  recovery, and admission-capacity wakeups can all resume WorkUnit-blocked
  workflows without relying on serialized `start_blocked_reason` scans, while
  keeping those scans as a migration fallback.
- Urgent-job release and landing-slot preemption now read WorkUnit blocked
  reasons before legacy Workflow artifact markers. Non-urgent work blocked
  behind urgent landing or repair work can be resumed/deferred based on
  WorkUnit state even when no serialized Workflow start-block artifact exists.
- Start-block reason/details/next-check reads now go through a shared
  WorkUnit-aware reader for landing queue, landing reentry, reconciler
  classification, and repair execution. Main-health repair release and landing
  backoff checks no longer require legacy Workflow start-block artifacts when
  the WorkUnit carries the authoritative block.
- Succeeded WorkUnits now satisfy their WorkIntent when no active sibling Unit
  remains, and the reconciler detects/repairs old drift where a terminal
  successful Unit left its Intent in `requested` or `waiting`. This covers one
  concrete form of "Intent with only terminal Units is satisfied" without
  prematurely deciding failed/cancelled retry semantics.
- Active WorkUnits without an attached Workflow are now treated as invalid
  empty attempts: the reconciler cancels the Unit and releases any locks,
  leaving the WorkIntent requested so scheduling can create a real attempt
  instead of letting a workflow-less Unit block execution forever.
- The reconciler now captures WorkIntents directly and repairs missed wakeups
  for managed waiting Intents whose current gates pass. This gives dependency
  waits a durable recovery path when the domain event that should have woken the
  Intent was missed, without repeatedly logging Intents whose gates still block.
- Active-work ownership helpers now hide legacy active Workflow fallbacks for
  trigger kinds whose path has moved to WorkUnits. Scheduler-owned Workflow
  rows stop contributing to active/runnable/current-trigger answers when
  `work_units_scheduler` is enabled, and landing-owned Workflow rows do the
  same behind `work_units_landing`, while still preserving fallbacks for paths
  whose gates remain disabled.
- Epic-wide conflict detection and landing-queue merge-train status now resolve
  active work through WorkUnit membership as well as direct Epic scope. This
  keeps bundle/member-shaped WorkUnits authoritative even when their owning
  Workflow is attached to a different Job or the Unit itself is job-scoped.
- The reconciler can now target a specific WorkIntent and repair the invariant
  "requested Intent with passing gates has an active Unit" by instantiating and
  starting a fresh Unit/Workflow for persisted job-scoped desired work. This is
  deliberately explicit-scope only, so global or Workflow-scoped reconciles do
  not accidentally relaunch failed attempts in a loop.
- Requested WorkIntent launch now flows through `WorkIntents::Scheduler.start_ready!`.
  The scheduler evaluates Intent gates, refuses to duplicate active Units,
  instantiates a fresh Unit/Workflow when gates pass, and starts the Unit through
  the WorkUnit launcher. Reconciler repair consumes that scheduler API instead
  of duplicating "evaluate then launch" orchestration.
- Terminal parent WorkUnits now own their descendant invariant: the reconciler
  detects active child WorkUnits below terminal parents and cancels those child
  Workflows/Units while preserving the parent's terminal outcome. This gives
  speculative validation and future ref-movement child Units a durable cleanup
  path.

### Phase 6: Work Definition Policies

Have each Work definition declare:

```ruby
scope: :job | :epic | :repository | :delivery_track | :ref_movement
locks: [...]
intent_gates: [...]
unit_gates: [...]
preemption_policy: ...
retry_policy: :resume_step | :new_workflow | :rebuild_unit | :operator
blocks_ci_failure: true/false
publication_steps: [...]
```

Dispatcher, retry, and reconciler logic should read these policies instead of
branching on trigger-kind names.

Completed slices:

- Work definitions now declare `review_publication_step_kinds`, currently
  `pr_open` for workflows that must publish a reviewable PR. The missing-PR
  reconciler and executor paths consume that policy instead of hard-coding
  `pr_open`, so non-PR-producing workflows are not misclassified and future
  review-publication workflows have one declaration point.
- The WorkDefinitions registry now publishes scheduler policy kind sets:
  landing-lock kinds, first-class landing workflow kinds, Epic-wide kinds, and
  CI-failure-blocking kinds. Landing queue reentry, landing queue processor
  helpers, Epic-wide workflow locking, WorkUnit blocked-job filtering, and
  runtime ownership adapters consume these policy sets instead of local
  trigger-kind lists.
- Work definitions now declare concrete preemption policies instead of a single
  placeholder: agentic job work is checkpoint-resumable, landing/publication
  and rebase-style units rebuild, short validation/manual-review units cancel,
  and infrastructure/legacy definitions remain non-preemptible. The registry
  validator rejects unknown policy modes or resume strategies.
- Work definitions now declare concrete retry policies. Ordinary retryable
  workflows continue the failed step in place, while merge trains explicitly
  continue safe agentic reconciliation steps and rebuild the train for
  publication/rebuild steps. `RetryFailedStepEnqueuer` asks the WorkDefinition
  retry policy instead of hard-coding merge-train trigger-kind behavior.
- `WorkDefinitions::RegistryValidator` now enforces the plan's hierarchy-sync
  contract: every `Workflow::TriggerKind` has a matching WorkDefinition and
  runtime role, every definition points at a known workflow trigger/template,
  child definitions declare a valid parent kind, and every definition exposes
  scope, gates, preemption, and retry policy. The spec catches new workflow
  kinds that forget to add runtime semantics.
- Work definitions now declare active-repair workflow semantics. The reconciler
  uses that policy to distinguish "failed, repair running" from generic
  Job/Workflow state drift, including operator-confirmed manual repair work.
- Work definitions now declare retry-workflow-attempt semantics. Stale
  auto-retry cleanup and retry eligibility use that policy instead of assuming
  every retry-like unit is exactly `trigger_kind == "retry"`, which keeps
  checkpoint-resume attempts inside the same scheduler model.
- Work definitions now declare landing-validation parent/child relationships.
  Speculative landing validation, grader collection, and changed-file base
  selection consume the source/child/family policy sets instead of maintaining
  local `auto_merge`/`merge_train`/validation trigger lists.
- Work definitions now declare agent-concurrency exemptions. `RunJob` exempts
  main branch health/repair work through definition policy instead of carrying
  its own `main_grader`/`main_branch_repair` list, while retry-workflow
  eligibility at run start uses the same retry-attempt policy as the reconciler.
- Epicless job bundles now have first-class `job_bundle` and
  `job_bundle_validation` WorkDefinitions. They reuse the existing merge-train
  and merge-train-validation Workflow templates, but runtime ownership,
  labels, locks, policy sets, and validation-family checks no longer pretend
  they are Epic merge trains.

### Phase 7: Callback Strangler Completion

Move Workflow/Step/Run callback propagation behind orchestration services and
make WorkUnit the runtime owner for migrated paths.

Do not let both Workflow callbacks and WorkUnit scheduler independently mutate
Job lifecycle/runtime projections.

Completed slices:

- `Workflow#landing_workflow?`, `#epic_wide?`,
  `#infrastructure_workflow?`, and the successful-workflow publication check
  now delegate their classification to WorkDefinition policies. Work
  definitions distinguish true infrastructure runtime role from "manages its
  own Job lifecycle" so main-branch repair and speculative validation workflows
  can keep skipping generic propagation without pretending to be infrastructure.
  The legacy callbacks still execute in the same order, but they no longer own
  local trigger-kind lists for these scheduler/runtime classifications.
- Workflow callback Job-state propagation now lives in
  `Workflows::JobLifecyclePropagation`, with `Workflow` retaining thin
  compatibility methods for the AASM callbacks and older callers. This starts
  the callback strangler by moving start/succeed/fail/cancel/reopen Job
  mutation rules behind a dedicated service without changing callback order.
- Run callback propagation now lives in `Runs::LifecyclePropagation`. The
  `Run` model still owns the AASM wiring, but cancellation cascades,
  failed-run Step/Workflow propagation, failure classification, provider
  evidence/broadcasts, terminal resource summaries, admission wakeups, and run
  activity logging are routed through one orchestration service. That makes
  Run terminal behavior auditable as one unit before WorkUnit becomes the
  runtime owner for migrated paths.
- Step callback propagation now lives in `Steps::LifecyclePropagation`. The
  `Step` model keeps AASM wiring and the `suppress_cancel_cascade` guard, while
  chain advancement, auto-approval after grader success, failed-Step Workflow
  propagation, and downstream cancel fanout are centralized in one service.
- Workflow transition side-effect ordering now lives in
  `Workflows::LifecyclePropagation`. Workflow AASM events delegate start,
  success, failure, cancellation, and reopen side effects to one service while
  retaining public compatibility seams for workspace cleanup, descendant
  cancellation, WorkUnit sync, Job lifecycle propagation, and workflow hooks.
- WorkEngine repair paths now explicitly normalize terminal Workflow ownership
  before creating replacement work. If older code or a low-level repair made a
  Workflow terminal without firing the callback, `WorkUnits::TerminalWorkflowSync`
  folds the result into its active WorkUnit and releases locks before retrying.
- WorkUnit locks now enforce the plan's "one active owner per lock key"
  invariant with a nullable unique `active_lock_key`. Active locks populate it,
  released historical locks clear it, and the migration releases duplicate
  active shadow locks before adding the unique index so runtime ownership cannot
  silently split across two non-terminal Units.
- `WorkUnits::Launcher` now returns a typed launch result carrying the Workflow,
  first Run, WorkIntent, WorkUnit, status, and gate result. When the
  `work_units_scheduler` gate is enabled, launcher start evaluates WorkUnit
  gates before creating the first Run and returns a blocked result instead of
  leaking a queued Run past a typed unit block. Rebase and stack-rebase
  WorkDefinitions use maintenance-scoped locks (`maintenance:rebase:*`) rather
  than the primary `job:*` locks so recovery rebases can coexist with the active
  workflow they are repairing while still preventing duplicate rebase races.
- Dependency wakeups now flow through `WorkIntents::JobWakeup`. The service
  re-evaluates current WorkIntent gates, records unresolved dependencies as a
  typed `waiting/dependency` Intent instead of leaving only Job-level implicit
  state, clears managed dependency waits when the gate passes, and then starts
  queued Workflows through the WorkUnit launcher. Normal legacy queued
  Workflows without WorkUnit ownership no longer start through this wakeup;
  the only legacy fallback preserved here is for historical `replay`
  workflows.
- Dependency wakeups also launch persisted job-scoped WorkIntents that do not
  have an active WorkUnit yet. When dependencies clear, `WorkIntents::JobWakeup`
  calls `WorkIntents::Scheduler.start_ready!`, so missed workflow creation is
  repaired at the domain wakeup instead of waiting for the reconciler's
  requested-Intent invariant repair.
- Mid-workflow Run creation now evaluates WorkUnit runtime gates with the
  concrete next Step as context when `work_units_scheduler` is enabled. Manual
  pause, provider availability, main-branch health, and admission/resource
  blocks can pause a WorkUnit between steps with typed `blocked_reason` and
  phase-step details instead of only gating the first Run.
- Manual unpause now resumes WorkUnit-blocked attempts directly. When an
  operator unpauses a Job, WorkUnit pause requests are cleared, manual-pause
  blocked Units are re-evaluated through `WorkUnits::Scheduler`, and eligible
  workflows are started immediately through `WorkUnits::Launcher` before the
  legacy Workflow artifact resume path runs.
- Timed provider/admission/resource wakeups now resume through
  `WorkUnits::DeferredPhaseResume`. With `work_units_scheduler` enabled, the
  wakeup re-evaluates the active WorkUnit, keeps typed blocked Units blocked
  when gates still fail, starts first steps through `WorkUnits::Launcher`, and
  resumes later steps without re-running the same phase gate twice. With the
  gate disabled, the legacy `StepDispatcher.resume_deferred_phase` path remains
  the owner.
- Reconciler repair execution now uses the same `WorkUnits::DeferredPhaseResume`
  facade for queued-step and deferred-phase repairs, so operator-visible repair
  actions cannot resume provider/admission/resource blocked work through a
  different legacy-only path while scheduler ownership is enabled.
- Superseded-workflow and Epic-workflow-conflict repairs now also mark the
  affected WorkUnit as preempted/cancelled, release its locks, and point to the
  keeper WorkUnit when one exists. The legacy Workflow cancellation artifact is
  still written for compatibility, but WorkUnit state now records that this was
  preemption rather than an ordinary failed attempt.
- Direct Workflow cancellation paths that represent unstartable work or
  runtime supersession now go through `WorkUnits::WorkflowCancellation`.
  StepDispatcher start-time cancellations, stale publication supersession,
  retry eligibility cancellation, retry supersession, Epic block restoration,
  and reconciler preemption repairs all preserve their existing Workflow
  artifacts while refining attached WorkUnits with a typed
  `preemption_reason`.
- Job-level active-work cancellation helpers now use the same typed Workflow
  cancellation facade for close/restart, manual rebase supersession, and
  approval-driven retry cancellation. This removes another set of paths where a
  Workflow could be intentionally superseded while its WorkUnit only said
  generic `cancelled`.
- Reconciler cleanup, landing defer, external-PR close, coding handoff takeover,
  operator stale-work repair, and runaway-protection cancellations also use
  typed WorkUnit cancellation. The remaining plain Workflow cancellation calls
  are normal lifecycle cascades or run/step stop paths, not independent
  ownership decisions.
- Reconciler repair plans now describe queued-workflow restart repairs as
  `WorkUnits::Launcher.start!` executions. The executor was already using the
  launcher; this removes stale operator-facing plan text that still referenced
  `StepDispatcher.start_workflow`.
- Generic requested-Intent launch now respects WorkDefinition ownership.
  Non-landing job-scoped Intents can be launched by the generic scheduler, and
  existing Intents with prior terminal Units can be rebuilt from their snapshots.
  Fresh landing/ref-mutating Intents require their domain dispatcher so a new
  `auto_merge` or `merge_train` request cannot bypass landing queue ordering.

### Phase 8: Step/Run Simplification

After WorkUnits are stable, simplify the Step/Run relationship:

- keep Step as plan node;
- make Run/StepAttempt the execution attempt;
- derive visible Step state from latest attempt or update it only in one place.

This should remove many terminal-descendant and active-run drift repairs.

Completed slices:

- Step visible state now goes through `Steps::StateProjection`, which derives
  presentation from the latest meaningful Run attempt while preserving the
  persisted Step state as drift diagnostics. Job workflow JSON, WorkUnit current
  step summaries, merge-train status, and grader conclusion caching use the
  projection instead of each hand-rolling Step/Run precedence.
- Step repair from terminal Run state now goes through
  `Steps::StateSynchronizer`, and the reconciler uses the same projection when
  planning active-Step/terminal-Run drift repairs. This removes another
  hand-rolled Step/Run terminal precedence rule from WorkEngine.
- Workflow active/live descendant checks now use the same Step projection for
  Step liveness while still treating active Runs as authoritative work. Terminal
  Workflow cleanup and idle checks therefore share the same Step/Run precedence
  as UI projection and repair planning.
- Failed Jobs with active repair WorkUnits now project as `repairing` in the
  dashboard and job detail payloads while preserving the persisted Job state as
  `failed`. The payload includes the active repair WorkUnit/workflow identity,
  so operators can distinguish an idle failed Job from a failed Job whose repair
  work is already running, queued, or blocked.
- Explicit completion repair (`RunCompletionReconciler`) now marks the Run
  terminal and then delegates Step mutation to `Steps::StateSynchronizer`, so
  "the external side effect already happened" repairs and generic WorkEngine
  Step/Run drift repairs share one Step transition path.
- `Workflow#current_step` and `#current_iteration` now use projected Step state,
  and repository detail / MCP live-state current-step lookups include active
  Runs when Step rows drift. Operator-facing "currently running" captions now
  share the same Step/Run precedence as workflow liveness and repair.

## Success Criteria

- The UI can explain why a Job is not progressing from one Intent or WorkUnit
  record.
- The reconciler no longer needs special logic for merge-train sibling ownership.
- Manual pause, provider pause, admission pause, and preemption share one
  blocked-state model.
- A failed Job with active repair work is either impossible or explicitly shown
  as "failed, repair running" from WorkUnit data.
- Delivery tracks can add promotion/hotfix/upstream WorkUnit kinds without
  expanding Job state.
- Reconciler classifications decrease over time rather than increasing with each
  new workflow type.

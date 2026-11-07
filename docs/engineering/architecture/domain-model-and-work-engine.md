# Domain model and work engine

## Execution records

`Job` is the durable thread and owns repository identity, source identifiers,
branch and pull request metadata, credential mode, priority, assignee, and
lifecycle. Kinds are registered by `Job::Kind`; plugins may add kinds through
`:workflow_kinds`. `Workflow` is one attempt, `Step` one materialized stage,
and `Run` one execution of that stage. Their kinds are registered by
`Workflow::TriggerKind` and `Step::Kind`, rather than duplicated constants.
Operational blockage and failure codes use the registered `Problem::Kind`
vocabulary; broader workflow-engine proposals do not make their unimplemented
parts current architecture.

The models and transition callbacks are in `app/models/job.rb`,
`app/models/workflow.rb`, `app/models/step.rb`, and `app/models/run.rb`.
`app/services/step_dispatcher.rb` owns transition from a materialized Workflow
to executable Runs. Pollers and services advance domain state; they do not
enqueue agent jobs around this dispatcher.

`Epic`, `JobDependency`, and `EpicDependency` coordinate ordering and landing.
An Epic merge train can assemble and validate child branches atomically. Job
approvals, review policy, landing policy, and dependency readiness are durable
domain concerns, not UI-only state.

## Work ownership

The work engine sits above, but does not replace, those AASM machines:

- `WorkIntent` records the durable desire to perform a registered definition.
- `WorkUnit` is one runtime attempt and owns status, members, and attempts.
- `WorkUnitLock` serializes conflicting job, epic, repository, or landing-slot
  work; `WorkUnitMember` records the Jobs participating in a unit.
- `WorkDefinitions::Base` subclasses own retry, lock, and landing policy.
- `WorkUnits::Launcher.start!` acquires ownership and ultimately calls
  `StepDispatcher.start_workflow`.
- `WorkUnits::PathOwnership` maps retry, resume, pause, landing, rebase, and
  reconciler repair paths to definitions without shadow-mode flags.

Implementations live in `app/models/work_intent.rb`,
`app/models/work_unit.rb`, `app/services/work_definitions/`, and
`app/services/work_units/`. `app/services/work_engine/reconciler.rb` repairs
ownership records first and uses presentation fallbacks only for compatibility.
The complete current entry-path contract is in
[WorkUnit path ownership](work-unit-path-ownership.md); the older migration
matrix under `docs/plans/` is rollout history.

## Access control and identity

`User`, `Team`, team membership, repository membership, and repository access
tiers determine visibility and mutation rights. Pundit policies under
`app/policies/` enforce request access; API scopes and MCP tool authorization
must reach the same domain checks. `PlatformIdentity` links an external chat
identity to a Syrus user without becoming a second authorization system.

See `app/models/user.rb`, `app/models/team.rb`,
`app/models/repository_membership.rb`, `app/models/platform_identity.rb`, and
`app/policies/`. Operator-facing permission behavior is documented in
[Permission authority](../../../config/syrus_docs/permission_authority.md).

### Security limitations

Repository membership and Pundit isolate ordinary application data, but the
worker execution model is not a hostile multi-tenant sandbox. An authorized
run can execute repository setup commands and agent-authored code with the
worker's reachable resources. Syrus also has no tenant-wide concurrency or
spend caps: queue and WorkUnit controls coordinate work, but do not provide a
per-tenant security or billing boundary. Every user of one instance must be
trusted with the potential blast radius of its agent workers. See
[`SECURITY.md`](../../../SECURITY.md) for the deployment policy.

## Scheduling records

`ScheduledTask` describes recurring work and `CronTemplate` supplies reusable
schedule definitions. A fire creates a normal Job/WorkIntent path; schedules do
not bypass workflow ownership. The scheduled-tasks plugin owns plugin-specific
commands and documentation. Core scheduling entry points are mapped in
[Queues and databases](../maps/queues-and-databases.md).

# Workflow execution

## From trigger to Run

Recurring pollers, API actions, chat handoffs, and recovery services create or
advance a Job and request a registered work definition. `WorkUnits::Launcher`
establishes ownership, then `StepDispatcher` materializes and advances a
Workflow. `Run#after_create_commit` enqueues `RunJob`; normal callers do not
enqueue `RunJob` directly.

Workflow templates live in `app/services/workflows/`. Trigger kinds include
initial work, PR/chat feedback, CI repair, retry, rebase and stack rebase,
auto-merge and merge train, external PR paths, coding/local handoffs,
deployment, main-branch maintenance, and plugin-contributed kinds. Consult
`app/models/workflow/trigger_kind.rb` and the templates for the authoritative
set and exact chain.

## Materialized pipeline families

The initial issue pipeline normally prepares the checkout, invokes the
implementation agent, runs deterministic formatting and generation, fans out
configured graders, and then enters bounded adversarial and visual review
loops before summary and pull-request creation. Optional nodes come from
`.syrus.yml`, but ordering is owned by `app/services/workflows/initial.rb`,
`app/services/workflows/loop.rb`, and `app/services/steps/`; `RunJob` executes
the definition rather than defining it.

Feedback pipelines are narrower. PR or chat feedback starts from the existing
Job and branch, applies the repair, re-runs applicable checks and reviews, and
updates the existing pull request. CI repair consumes the recorded failure
instead of restarting ingestion. Retry and resume enter through
`WorkDefinitions` and `WorkUnits::PathOwnership`, preserving WorkIntent and
locks rather than manufacturing a second execution path.

Rebase records the observed remote SHA and pushes with force-with-lease.
Auto-merge and merge-train definitions acquire landing-slot ownership,
validate the candidate, and reconcile failures into durable work. Deploy and
main-grader workflows are infrastructure Jobs; plugin workflow kinds resolve
through the registry rather than a core kind switch. See
[Workflow steps](../../../config/syrus_docs/workflow_steps.md) and
`spec/services/workflows/` for operator configuration and executable chain
expectations.

## Step structures

`Workflows::Loop` models bounded review loops. Review-first adversarial and
visual loops request an opinion before inserting a repair; each `needs_work`
opinion gets a repair even when the review budget is exhausted. Grader retry
loops are distinct: deterministic formatting/generation and grader fan-out can
fail, invoke a repair step, and stop after the configured iteration budget.

`prepare` uses explicit `.syrus.yml` commands when present and otherwise a
conservative detector. Explicit command failure is fatal; guessed preparation
can soft-fail so an agent can correct repository setup. Formatter, generator,
grader, review, coverage, dependency-audit, summary, PR, and landing Steps each
have handlers under `app/services/steps/`. Operator-facing step configuration
is documented in [Workflow steps](../../../config/syrus_docs/workflow_steps.md)
and [`.syrus.yml`](../../../config/syrus_docs/syrus_yml.md).

## Agent and deterministic execution

`app/jobs/run_job.rb` loads the Step handler and establishes execution context.
Agentic handlers call a provider behind `app/services/agent_providers/` and use
the scoped MCP sidecar. Deterministic commands use the execution request
boundary and `Execution::Router`; enabled `:execution_backend` providers may
claim requests. Confinement and alternate execution belong at that boundary,
not as conditionals in individual callers.

Distributed graders record a `WorkflowSourceSnapshot`, fan out immutable work,
and collect results. The snapshot—not the live workflow checkout—is their
source of truth. See [Workspace lifecycle](workspace-lifecycle.md).

## Polling, GitHub, and landing

Polling entry points under `app/jobs/poll_*` discover issue, PR feedback,
merge-state, CI, and external-PR changes. Watermarks make repeated polls
idempotent. Rebase paths use force-with-lease against an observed remote SHA;
ordinary implementation paths push without rewriting shared history.

Landing services under `app/services/landing_queue/`, `WorkDefinitions`, and
the merge-train workflow own readiness, validation, reconciliation, and merge.
Rebase and landing failures remain durable and visible for recovery rather than
being hidden by an ad hoc retry.

## Coworker review evidence and audit surfaces

Automated review keeps three identities separate: the review kind, an optional
named persistent coworker, and the provider/model executing the read-only Run.
The dedicated coworker gate is enabled by effective repository `.syrus.yml`;
installation-local provider rules choose its coworker or panel. Neither a
provider verdict nor coworker consensus satisfies human approval policy.

`ReviewEvidence` binds each opinion to immutable base/head SHAs and a canonical
diff hash. Job-detail serialization projects this evidence with safe context
manifest metadata, typed terminal state, Run cost, the following repair Run's
response, and the coworker's persistence receipt. Reviewer implementations may
contribute authorization-aware operator links; core UI never constructs plugin
routes. Coworker owners and admins can inspect the single durable journal entry
or the separately labelled restricted context, and both reads are audited.
Stale evidence cannot advance a gate. A coworker verdict succeeds only after
its isolated memory update is durably merged; retry reauthorizes the target and
recaptures evidence, while retention tombstones protected context without
removing the safe audit record.

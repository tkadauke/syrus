# Syrus architecture

_Last reviewed: 2026-11-22._

This is the canonical system-wide overview and routing map. It explains how
Syrus fits together; focused engineering documents own subsystem detail.
Executable code, schema, configuration, and tests remain the final authority.
See the [engineering hierarchy](docs/engineering/README.md) for precedence.
The [detailed system reference](docs/engineering/architecture/system-reference.md)
retains the full model, flow, service, UI, and deployment inventory formerly
kept in this overview.

## System shape

Syrus is a Rails application that turns external work signals and operator
requests into durable, reviewable workflows. Rails owns the domain model,
scheduling, APIs, and orchestration. React provides the browser UI, a Go CLI
and Electron shell use the same API, and plugins supply optional capabilities.
Development and test use SQLite; production uses MySQL. Solid Queue, Solid
Cache, and Solid Cable provide jobs, caching, and live browser events.

GitHub integration is polling-based. Pollers create or advance durable records;
they do not run agents directly.

```text
external signal / operator request
              |
              v
       Job + WorkIntent
              |
       WorkUnit launcher and locks
              |
              v
 Workflow -> Step -> Run -> RunJob
              |             |
              |             +-- agent / deterministic command / sidecar
              v
       graders, review, PR, landing
```

## Core ownership model

- A `Job` is the long-lived work thread. Its kind comes from `Job::Kind`,
  including plugin contributions; investigation is a flag, not a separate
  kind. It owns repository, issue or pull request identity, branch, credentials,
  priority, and lifecycle state.
- An `Epic` coordinates related Jobs and their dependency and landing policy.
- A `Workflow` is one attempt for a Job. `Workflow::TriggerKind` selects its
  definition: implementation, feedback, retry, maintenance, landing, or an
  infrastructure or plugin-provided flow.
- A `Step` is one materialized stage. `Step::Kind` resolves its handler.
- A `Run` is an execution attempt and owns prompts, provider metadata, output,
  artifacts, diffs, and PR copy.
- A `WorkIntent` records that work is desired. A `WorkUnit` is one runtime
  attempt, with members and mutex-like locks. Work definitions own retry,
  locking, and landing policy; execution still enters through `StepDispatcher`.

The AASM machines remain the execution truth:

```text
Job:      triage/backlog/queued -> running -> implemented/approved/landing -> closed
Workflow: queued -> running -> succeeded | failed | cancelled | blocked
Step:     queued -> running -> succeeded | failed | cancelled | skipped | blocked
Run:      queued -> running -> succeeded | failed | cancelled | skipped | blocked
```

Read [Domain model and work engine](docs/engineering/architecture/domain-model-and-work-engine.md).

## Execution and workspace lifecycle

Workflow definitions under `app/services/workflows/` materialize Step chains;
handlers under `app/services/steps/` execute them. `RunJob` delegates agentic
work to provider adapters and deterministic work to step handlers. Review and
grader loops are explicit workflow structures with bounded repair iterations.
Review gates are registry contributions rather than a fixed core sequence.
Required gates bind evidence to an immutable HEAD and prevent later Steps from
advancing an unreviewed repair; optional gates do not become landing barriers.

Most Steps share a mutable checkout at
`$SYRUS_DATA_ROOT/workflows/<workflow_id>/`. Terminal transitions schedule
cleanup. Distributed grader Steps instead consume a recorded immutable source
snapshot in a detached checkout and may reuse a worker-local prepared layer.
Execution routes through `Execution::Router`; enabled backend providers can
claim work, otherwise eligible core workloads use local execution.

Jobs and Workflows carry a `PlannedExecutionRequirement`. `RunQueueResolver`
matches explicit project, target, source, and capability requirements against
live workers, blocking with `no_capable_worker` when none qualifies.

Read [Workflow execution](docs/engineering/architecture/workflow-execution.md)
and [Workspace lifecycle](docs/engineering/architecture/workspace-lifecycle.md).

## Repository content and GitHub

`RepositoryContent` is the core boundary for reading a repository without
cloning it. It resolves an immutable revision and serves trees, files, and
changes through registered providers. Replicas precede upstream providers;
`NotFound` is final, while availability or capability failures may fall
through. Pre-workflow configuration, source browsing, skills, and diff views
all use this boundary.

GitHub credentials are captured on the Job (`app` or `pat`) and reused by its
workflows. GitHub content reads do not bypass `RepositoryContent`.

Read [Repository content](docs/engineering/architecture/repository-content.md)
and the [repository map](docs/engineering/maps/repositories-and-integrations.md).

## Chat, MCP, and sidecars

Chat is a durable conversation surface with provider sessions, tool calls,
attachments, goals, and optional workspaces. The chat sidecar exposes
chat-scoped tools; the workflow MCP sidecar exposes tools appropriate to an
active Run. Sidecars authenticate scoped requests back to Rails. Preview
processes and workspace files live with their owning worker, so Rails routes
access through it. External chat adapters link platform identities without
changing the core ownership model.

Tool exposure and approval flow through the shared permission policy
(`PolicyEvaluator`); `Permissions::Enforcement` is the instance-wide master
switch that disables policy asks and denials without affecting authentication,
repository access, or proposal confirmation cards.

Read [Chat and sidecars](docs/engineering/architecture/chat-and-sidecars.md).

## Plugins and frontend

`Syrus::PluginRegistry` is the extension boundary for providers, workflow
kinds, content sources, execution backends, MCP tools, routes, UI contributions,
runtime services, and other optional capabilities. Bundled plugins live under
`plugins/`; third-party plugins are Rails Engine gems. Plugin-owned code,
data, tests, and operator docs remain in the plugin so it can be removed
cleanly. Core-facing authorization, chat, identity, review, and UI contracts
use generic provider interfaces; plugin-specific records and evidence remain
opaque to core.

Capability families group related extension points behind typed contexts and
declared composition rules (`collect`, `broadcast`, `first_claim`, or `keyed`).
Their contracts define provider availability, decline behavior, and return
shapes; dispatch withholds contributions from disabled or unhealthy plugins.
Stable capabilities require independent implementations and generated contract
tests, while provisional capabilities can evolve without pretending to be a
settled host API.

External plugins cross a separate supply-chain boundary. Registries publish
versioned, deterministic packages and registry-scoped trust metadata. Syrus
verifies package identity, digest, publisher signature, namespace ownership,
compatibility, and revocation before staging an install. The durable lockfile
and desired state drive convergence and restart rather than loading an
unverified download directly into the running process.

The React application consumes Rails JSON APIs and live events. Rails owns SPA
shell routes; React owns client routing and feature surfaces. Shared primitives
cover filters, tables, Markdown, modals, and chat tool cards. The Go CLI and
Electron shell are separate clients of the same authenticated API.

Read [Plugins](docs/engineering/architecture/plugins.md),
[Frontend surfaces](docs/engineering/architecture/frontend.md), and the
[frontend and plugin map](docs/engineering/maps/frontend-and-plugins.md).

## Verification boundary

Rails models, services, schema, and tests remain the executable source of
truth. A separate Lean 4 model under `formal/` specifies selected WorkIntent,
WorkUnit, Workflow, Step, Run, lock, dependency, review-barrier, and reconciler
invariants. Lean proofs check preservation and repair properties, while a
versioned JSON contract corpus and executable oracle are compared with Ruby
simulation scenarios and generated worlds. This is a verification and drift
detection layer, not a runtime scheduler or a replacement for the Rails state
machines.

Read the [formal model guide](formal/README.md) and
[Domain model and work engine](docs/engineering/architecture/domain-model-and-work-engine.md).

## Operations and recovery

Production separates web, worker, runtime, and backing-service responsibilities.
Runtime diagnosis starts with durable Job/Workflow/Step/Run state and worker
ownership, then correlates queue, logs, workspace, and external-provider state.
Recovery uses domain paths: retry, resume, pause, and reconciliation repair
WorkIntents and WorkUnits before dispatching Workflow work. Operators should
not manufacture state transitions directly in the database. Safe recovery can
resume from a published implementation checkpoint, but reconciliation rejects
checkpoints that would bypass an immutable grader or required-review barrier.

Read [Deployment](docs/engineering/operations/deployment.md),
[Production debugging](docs/engineering/operations/production-debugging.md),
and [Workflow recovery](docs/engineering/operations/workflow-recovery.md).

## Navigation and boundaries

- [Architecture](docs/engineering/architecture/README.md): subsystem boundaries.
- [Decisions](docs/engineering/decisions/README.md): accepted records explaining
  why durable architectural choices were made (polling, placement, plugin
  boundaries, permission authority, and others).
- [Operations](docs/engineering/operations/README.md): deploy and recover.
- [Maps](docs/engineering/maps/README.md): files, tests, queues, and databases.
- [Pitfalls](docs/engineering/pitfalls/README.md): recurring failure modes.
- [Conventions](docs/engineering/conventions/README.md): mandatory practices.

Public product documentation belongs in `website/`; searchable operator docs
in `config/syrus_docs/`; plugin docs with their plugin; executable agent
instructions in `.claude/skills/`; plans and instance-specific evidence in
`docs/plans/`.

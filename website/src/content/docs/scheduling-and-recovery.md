---
title: Scheduling and Recovery
description: How Syrus admits work, pauses it, resumes it, retries failures, and repairs stale execution state.
---

# Scheduling and Recovery

Syrus separates the operator-facing Job from the scheduler-owned work needed
to move it forward. This keeps retries, pauses, deploy interruptions, and
preemption visible without turning every internal state into a Job state.

## Work Intents and Work Units

A Work Intent records desired work: implement this Job, land this approved PR,
repair this CI failure, rebase this stack, or run this bundle.

A Work Unit records one attempt to satisfy that intent. It owns or links to
the workflow that is actually executing. A resume or retry-from-failed-step is
a continuation of the same unit when it is safe. A full retry or new landing
attempt is a new unit.

Most users do not need to see Work Intents and Units during normal review. The
admin UI exposes them so operators can debug admission control, dependency
gates, and preemption.

## Admission Control

Admission control decides whether work should start now. It considers current
worker pressure, active high-cost workflows, provider availability, repository
concurrency, and minimum progress floors.

When work cannot safely start, the unit is blocked or paused with a reason and
a next check time. Once resources improve, Syrus should resume the work rather
than leave half-started Jobs behind.

## Pause Reasons

Syrus can pause work for several reasons:

- manual pause by an operator,
- admission-control pressure,
- provider usage or quota limits,
- repository policy such as main-branch health enforcement,
- dependency gates,
- preemption by higher-priority work.

Manual pauses stay paused until an operator unpauses them. Automatic pauses
are reconsidered by the scheduler and reconciler.

## Preemption

Preemption is an intentional interruption. Syrus may stop lower-priority work
when a more important unit needs the same slot or when an epic-wide operation
must prevent conflicting job-level work.

Preempted work should explain what interrupted it and should be resumable or
retryable through the same recovery paths as other non-terminal interruptions.

## Reconciler

The reconciler is the background safety net. It looks for states that should
not persist:

- queued runs with no queue claim,
- queued runs stranded on a worker-specific queue after that worker disappears,
- workflows with no first run,
- stale running runs after worker death or deploy,
- terminal workflows still attached to active Jobs,
- closed Jobs with active workflows,
- paused work that is now eligible to resume.

The reconciler records what it found and what repair it applied. This is the
best audit trail when something gets unstuck without an operator clicking a
button.

After the queued-run grace period, a run stranded on a dead worker-specific
queue is rerouted automatically. Recovery keeps the same Run and priority,
clears the stale worker/storage affinity, and rechecks the queue immediately
before changing it so a returning worker or concurrent recovery wins without
duplicating work.

## Retry Semantics

Syrus prefers the smallest safe retry:

- Retry failed step: continue the current attempt when the workspace and
  branch are still trustworthy. A chat agent's `retry_job` (mode
  `failed_step`) can carry operator guidance with it: the guidance joins the
  attempt's operator context, so the next repair round works on the current
  branch with it. Before a Job reaches implemented, when chat feedback is not
  yet available, this is how to steer it without discarding its branch.
- Resume: continue after a pause or transient failure.
- Retry workflow: start a new workflow for the same desired work.
- Retry implementation: start a new implementation attempt when the previous
  output itself should not be trusted. This is also the way out when the agent
  reported it cannot proceed: the blocked attempt is retired first, so the Job
  does not have to be cancelled.

Cannot-proceed is reserved for permanent environmental or workflow-capability
gaps. Timeout, network/proxy, worker-capacity, dependency-preparation, and
inconclusive-grader reports are treated as retryable failures instead. A Job
with a genuinely blocked attempt is shown as blocked with the reported reason;
retrying it retires that attempt and releases its Job lock.

The operator-confirmed `retry_job` tool makes these choices explicit. Its
`auto` mode preserves the compatible smart-retry behavior and never chooses a
base refresh. `failed_step` keeps the failed workflow's immutable source,
`implementation` starts fresh from the current effective base, and
`refresh_base` restores a published checkpoint onto that base and requires an
audit reason. A multi-Job request is preflighted as a whole, confirmed once,
and launched in dependency order. A selected dependent waits for its upstream
refresh workflow to succeed and is not launched if that upstream refresh
fails. Each Job keeps its own success or failure outcome.

Syrus may initially recommend the narrower failed-step recovery after a
post-implementation failure. If that is insufficient, an operator can
explicitly request and confirm `implementation` as an escalation to a fresh
attempt, even after the in-place retry fails. This does not broaden automatic
retry selection, and the usual conflict, passing-PR, duplicate-retry, and
landing-recovery safety checks still apply. The confirmation and new workflow
retain the requested mode and source failure context in their audit data.

Agent-produced commits can be preserved through checkpoint refs, so a later
retry can recover useful work even if the original workspace disappeared.

### Last-resort authenticated manual repair

Deterministic recovery actions remain the preferred option. For exceptional
repairs they cannot express, an operator can request a manual agentic Run with
break-glass GitHub access. This requires a separate confirmation that names the
repository, GitHub App identity, requested permissions, expected remote
outcomes, and external-write risk; destructive operations require an additional
explicit declaration.

Syrus mints a short-lived credential for that Run and repository only, exposes
authenticated `gh` and Git transport only inside the authorized manual step.
Direct Git pushes require destructive authority; ordinary committed output
continues through Syrus's normal publication step. Syrus audits remote
operations without retaining the secret. Other repositories
are rejected. After publication, Syrus independently reads the provider state
to verify declared branch SHAs, pull-request state/base, labels, or comments.
The agent's summary alone cannot make the Workflow succeed. Failed verification
fails the Workflow while retaining recovery evidence. Ordinary implementation,
grader, reviewer, and manual Runs receive no GitHub credential.
Use `local_head` as the expected branch SHA when the remote branch must equal
the exact implementation commit produced by the manual Run.

When no previous output should survive, an administrator can request a full
Job reset from chat. Confirmation shows and removes the pull request, branch,
checkpoints, and active workflows, while preserving old workflow and run
history as superseded audit evidence. Syrus then evaluates dependencies again:
blocked Jobs remain blocked, while eligible Jobs start fresh from their current
effective base. Landed work, active landing or merge-train work, and stack
parents with live dependent branches must first resolve the named conflict.

Administrators can also replace one Job dependency atomically, preventing the
Job from briefly appearing dependency-free and starting between separate
remove and add operations. The replacement preserves the prior satisfaction
policy by default and validates repository, cycle, and Epic-chain rules.

For a failed workflow whose completed mutations are still useful but whose base
has moved, an operator can confirm a base-refresh retry. Syrus restores the
published checkpoint into a new workflow, resolves the current effective base
(including stacked parent branches) again when the rebase starts, repairs
rebase conflicts when necessary, publishes a new immutable source snapshot,
and reruns setup and validation before the normal PR-publication steps. The
historical workflow stays immutable.

## Provider Availability

Provider availability is tracked per user/provider/account. Usage-limit
signals can pause matching work, while successful evidence can clear a hard
rate-limit circuit. Low remaining quota is a warning unless it crosses the
configured per-agent threshold.

Operators can recheck usage and, when appropriate, override a provider pause.
Overrides should be used when the account situation changed outside Syrus,
such as buying extra credits or switching credentials.
# Correcting execution placement

Operators can correct a Job's execution profile from the Job management page
before work starts. The control shows the current and replacement capabilities,
compatible-worker availability, and requires an audit reason. It is available
for triage/backlog Jobs and queued initial Workflows only while no Run has
started and no mutable workspace exists. Once execution begins, create a fresh
attempt with the required placement instead of moving its workspace between
hosts.

The profiles keep Linux, macOS desktop, and iOS/Xcode distinct: selecting
macOS desktop does not request Xcode or an iOS simulator.

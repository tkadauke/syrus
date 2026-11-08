# Epic Dependency Policy

Epic dependency policy controls the shape Syrus expects for child Job dependencies inside one Epic.

## Values

Repository `epic_dependency_policy` values:

- `linear` (only value) — child Jobs should form one ordered chain.

Epic `epic_dependency_policy` values:

- `linear` (only value) — require one ordered chain for this Epic.

Starting a non-empty, confirmed Epic records operator execution intent by
moving it to `in_progress`, even while Job or Epic execution dependencies are
unresolved. Dependency readiness controls release of child Jobs and Workflows,
not the Epic state transition. Children remain `blocked_by_epic` or queued with
their normal start gate until callbacks on the final dependency wake the Epic
and release the first eligible child. Repeating the start request after the
Epic is already `in_progress` is idempotent.

`EPIC_DEPENDENCY_POLICIES = %w[linear]` on both `Epic` and `Repository` is the
single source of truth for valid values; the presence/inclusion validation on
each model rejects anything else. There is no operator-facing way to choose
anything but `linear` — the field exists mainly so the concept has a stable
place to live if a future, deliberately-designed non-linear structure is ever
added.

## Resolution

Epics store the concrete `linear` policy selected when they are created. Later repository setting changes do not alter an existing Epic. Epics proposed through chat are always linear.

## Execution readiness

Linear Epics can implement down the stack before every parent is approved or landed. The generic Job-to-Job execution rule releases a dependent once its parent reaches `implemented` with a branch, PR number, and captured `head_sha`; it is not limited to same-Epic edges. Same-Epic parents also remain execution-ready after moving on to `approved` or `landing`. This is execution-only readiness: `dependencies_satisfied?` remains strict for landing and requires the parent to close successfully, except for the existing same-Epic approval/landing allowance.

The default-disabled experimental `early_epic_dependency_execution` feature
extends that execution-only rule across an Epic boundary. An unfinished
upstream Epic qualifies only when it is in the same repository, both Epics use
the linear policy, each side has a unique root and tail, and every upstream
work Job has both a PR branch and captured head SHA. Syrus connects the
downstream root to the upstream tail using `parent_job` plus a concrete
Job dependencies; Workflow base artifacts retain the selected parent branch,
Job ID, and head SHA. Epic dependency completion remains the strict landing
gate. Cross-repository, unresolved, multi-upstream, incomplete, and nonlinear
graphs stay blocked.

Failed or cancelled upstream Jobs do not qualify as execution-ready merely
because an earlier Run recorded a branch and head SHA. Once released,
downstream work is not invalidated when an upstream branch moves or receives
feedback; an explicit stack rebase reconciles the continuous stack. When the
upstream Epic completes successfully, the recorded boundary is collapsed and
the downstream root is retargeted to the repository landing branch without
replaying the upstream Epic's obsolete commits.

A handful of older Epics still carry a dependency graph with more than one parent per child (predating the unconditional linear-chain enforcement described below). For those, eager execution first looks for an unambiguous stack base. If a child has multiple approved same-Epic parents and no single downstream parent branch contains every dependency change, Syrus tries to prepare a synthetic execution base branch by merging those dependency PR branches in deterministic dependency order. If that merge is clean, the child starts from the prepared base. If it conflicts or a dependency branch/head SHA is missing, the child stays queued with `stack_fan_in_base_unavailable` and includes the blocking dependency branches plus the operator action: land the siblings, linearize the stack, or resolve the merge conflict. This execution path is driven entirely by the shape of the actual dependency graph, not by the `epic_dependency_policy` field.

## Proposal validation

`propose_epic_with_jobs` requires at least one child and validates the complete child graph before showing a proposal. For a fresh Epic, omitted sibling dependencies default to a top-to-bottom chain. Explicit dependencies are never overwritten. One child or one simple chain is valid; fan-in, fan-out, parallel branches, disconnected children, and redundant transitive edges are rejected.

When extending an existing Epic, new children must connect to its existing chain explicitly. Same-session proposal slugs use `depends_on`; already materialized Jobs use `depends_on_job_ids`. A single `propose_job` added to an existing Epic must name an existing child dependency, while the direct-Job form derives the current tail when the operator selected the Epic without dependency controls.

The same single-chain rule applies no matter whether dependencies come from chat proposals, direct Jobs, admin actions, or GitHub issue markers. Older dependency graphs remain readable and executable, but no current path can create new same-Epic fan-in or fan-out edges.

# Epic Dependency Policy

Epic dependency policy controls the shape Syrus expects for child Job dependencies inside one Epic.

## Values

Repository `epic_dependency_policy` values:

- `linear` (only value) — child Jobs should form one ordered chain.

Epic `epic_dependency_policy` values:

- `linear` (only value) — require one ordered chain for this Epic.

`EPIC_DEPENDENCY_POLICIES = %w[linear]` on both `Epic` and `Repository` is the
single source of truth for valid values; the presence/inclusion validation on
each model rejects anything else. There is no operator-facing way to choose
anything but `linear` — the field exists mainly so the concept has a stable
place to live if a future, deliberately-designed non-linear structure is ever
added.

## History

`epic_dependency_policy` used to support a legacy `"nonlinear"` value for
Epics/Repositories with an older, DAG-capable `JobDependency` graph (branching
or fan-in child Jobs). `"nonlinear"` was already unselectable from every
surface — the App and Admin REST APIs rejected it on create/update, and no
form rendered it as an option — before it was removed outright. A migration
(`RemoveNonlinearEpicDependencyPolicy`) backfilled any repository or Epic rows
still carrying the old value to `"linear"`; this was a no-op in production, since
no `"nonlinear"` rows existed there by the time of removal. The backfill only
relabels those rows — it does not touch their `JobDependency` graph, which
[JobDependency-level enforcement](#jobdependency-level-enforcement) below has
never actually gated on this field.

## Resolution

Epics store concrete policy names. `Epic#resolved_epic_dependency_policy` is kept as the behavior-facing accessor, but it now returns the stored concrete policy rather than resolving through the repository at runtime:

```ruby
epic.epic_dependency_policy          # "linear"
epic.resolved_epic_dependency_policy # same value
```

Epics proposed through chat are always `linear`. Existing Epics that used the retired `inherit` value were backfilled once to the repository policy that was current at migration time, so later repository setting changes do not alter existing Epic behavior.

## Execution readiness

Linear Epics can implement down the stack before every parent is approved or landed. Once a same-Epic parent Job reaches `implemented` with a branch, PR number, and captured `head_sha`, Syrus may start the immediate child Job on that parent branch. This is execution-only readiness: `dependencies_satisfied?` remains strict for landing and still requires the parent to close successfully, or for same-Epic dependencies to reach `approved` or `landing`.

A handful of older Epics still carry a `JobDependency` graph with more than one parent per child (predating the unconditional linear-chain enforcement described below). For those, eager execution first looks for an unambiguous stack base. If a child has multiple approved same-Epic parents and no single downstream parent branch contains every dependency change, Syrus tries to prepare a synthetic execution base branch by merging those dependency PR branches in deterministic dependency order. If that merge is clean, the child starts from the prepared base. If it conflicts or a dependency branch/head SHA is missing, the child stays queued with `stack_fan_in_base_unavailable` and includes the blocking dependency branches plus the operator action: land the siblings, linearize the stack, or resolve the merge conflict. This execution path is driven entirely by the shape of the actual `JobDependency` graph, not by the `epic_dependency_policy` field.

## Proposal validation

The `propose_epic_with_jobs` MCP tool validates the incoming child Job graph as a single linear chain itself, before creating any `ChatProposal` rows for the Epic or its child Jobs — a nonlinear graph never even becomes a proposal card the operator has to notice and reject. `ChatEpicProposalMaterializer` runs the identical check again (via the shared `EpicDependencyPolicy::Linear.validate_chain!` graph algorithm) at confirmation time, as a defense-in-depth safety net. Sibling `depends_on` edges must make every child comparable with every other child: one child, a simple chain, or a chain with redundant transitive edges is valid; fan-in, fan-out, disconnected roots/leaves, and parallel child Jobs are rejected with the offending slugs in the error, at either layer. There is no proposal-time override — `propose_epic_with_jobs` has no field for requesting a nonlinear child graph, and Epics created from chat proposals always persist `linear` before child Job dependencies are materialized.

`ChatEpicProposalMaterializer` also rejects confirming any Epic proposal that would leave the resulting Epic with zero child Jobs: no proposed children on the card, and (when `epic.epic_id` targets an existing Epic) that Epic has no Jobs of its own either. A zero-child Epic would confirm successfully and then implement nothing, which surprises the operator far more than a rejected confirmation does. One child Job is allowed.

This is enforced earlier too: the bare `propose_epic` MCP tool (which used to create an Epic-only proposal card with no child Jobs at all) now always rejects, pointing the caller at `propose_epic_with_jobs` instead — the only remaining way to propose a new Epic, and it requires at least one child Job in the `jobs` array up front. This closes the gap where an agent could leave a zero-child Epic proposal card sitting in the chat that would only fail once the operator tried to confirm it.

When `epic.epic_id` targets an existing Epic that already has child Jobs, both layers fold that Epic's existing Jobs (and their same-epic `JobDependency` edges) into the same reachability graph, keyed alongside the new proposals. A batch of new children that only chains against itself but never references the Epic's existing Jobs is rejected as a disconnected branch — this is the case the direct-edge `JobDependency` check below cannot see, because a brand-new child Job with zero dependency edges never trips a degree-based validation. `jobs[].depends_on_job_ids` on `propose_epic_with_jobs` (existing Job IDs, wired to a real `JobDependency` at confirmation) is the mechanism for chaining a new child onto an Epic's current tail Job; `depends_on` on that same tool only reaches sibling slugs proposed in the same call, not already-materialized Jobs.

The single-Job `propose_job` MCP tool has the same exposure through `epic_id` and closes it with a narrower, existence-only check: if the target Epic already has any Jobs, `depends_on_job_ids` must include at least one of them, or the tool rejects the proposal before creating it. This does not re-run the full reachability algorithm (which needs the whole batch to reason about fan-in/fan-out) — the direct-edge `JobDependency` validation below still catches a `propose_job` call that names an existing Job that already has another same-epic dependent or dependency. The two checks together close both the disconnected-branch case and the fan-in/fan-out case for this tool.

## JobDependency-level enforcement

Independent of the proposal-graph check above, `JobDependency`'s own model validation enforces same-Epic edges unconditionally, in every instance mode (`AppSetting.simple?` and `AppSetting.advanced?` alike) and regardless of any Epic's or Repository's `epic_dependency_policy`: a Job may not have two same-Epic upstream dependencies (no merge/fan-in), and an upstream Job may not have two same-Epic downstream dependents (no fork/fan-out). This is a *direct-edge* count, not a transitive-reachability check, so it is stricter than the proposal-graph validation above — a proposal graph that the linear policy accepts as "a chain with redundant transitive edges" (e.g. `C depends_on B`, `B depends_on A`, and also an explicit `C depends_on A`) still fails at materialization time, because `C` ends up with two direct same-Epic upstream `JobDependency` rows. No code path — the `add_job_dependency` MCP tool, the admin API, chat proposal confirmation, or GitHub issue `Depends-on:` footer parsing — can create a fan-in or fan-out same-Epic `JobDependency` edge, in any instance mode. Existing `JobDependency` rows created before this enforcement are unaffected, since the check only runs on create/update; the DAG-capable services (`JobStackResolver`, `LandingQueueProcessor#dependency_order`, `EpicRestackPlan`, `MergeTrainAssembler`) do not create new `JobDependency` rows, and keep serving whatever fan-in/fan-out structure already exists on those older rows unmodified.

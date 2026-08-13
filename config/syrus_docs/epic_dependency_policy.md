# Epic Dependency Policy

Epic dependency policy controls the shape Syrus expects for child Job dependencies inside one Epic.

## Values

Repository `epic_dependency_policy` values:

- `linear` (default) — child Jobs should form one ordered chain.
- `nonlinear` — child Jobs may branch or fan in.

Epic `epic_dependency_policy` values:

- `linear` (default) — require one ordered chain for this Epic.
- `nonlinear` — allow branching or fan-in dependencies for this Epic.

## Resolution

Epics store concrete policy names. `Epic#resolved_epic_dependency_policy` is kept as the behavior-facing accessor, but it now returns the stored concrete policy rather than resolving through the repository at runtime:

```ruby
epic.epic_dependency_policy          # "linear" or "nonlinear"
epic.resolved_epic_dependency_policy # same concrete value
```

Epics proposed through chat are always `linear` — there is no chat-facing way to opt an Epic into nonlinear dependencies; only the Epic/Repository settings surface can set `nonlinear` (see Values above). Existing Epics that used the retired `inherit` value were backfilled once to the repository policy that was current at migration time, so later repository setting changes do not alter existing Epic behavior.

## Execution readiness

Linear Epics can implement down the stack before every parent is approved or landed. Once a same-Epic parent Job reaches `implemented` with a branch, PR number, and captured `head_sha`, Syrus may start the immediate child Job on that parent branch. This is execution-only readiness: `dependencies_satisfied?` remains strict for landing and still requires the parent to close successfully, or for same-Epic dependencies to reach `approved` or `landing`.

For nonlinear Epics, eager execution first looks for an unambiguous stack base. If a child has multiple approved same-Epic parents and no single downstream parent branch contains every dependency change, Syrus tries to prepare a synthetic execution base branch by merging those dependency PR branches in deterministic dependency order. If that merge is clean, the child starts from the prepared base. If it conflicts or a dependency branch/head SHA is missing, the child stays queued with `stack_fan_in_base_unavailable` and includes the blocking dependency branches plus the operator action: land the siblings, linearize the stack, or resolve the merge conflict.

## Proposal validation

Bundled Epic proposal confirmation always validates proposed child Jobs as a single linear chain before creating the Epic or Jobs, regardless of any policy stored on an existing target Epic. Sibling `depends_on` edges must make every child comparable with every other child: one child, a simple chain, or a chain with redundant transitive edges is valid; fan-in, fan-out, disconnected roots/leaves, and parallel child Jobs are rejected with the offending slugs in the error. There is no proposal-time override — `propose_epic_with_jobs` has no field for requesting a nonlinear child graph, and Epics created from chat proposals always persist `linear` before child Job dependencies are materialized.

## JobDependency-level enforcement

Independent of the proposal-graph check above, `JobDependency`'s own model validation enforces same-Epic edges unconditionally, in every instance mode (`AppSetting.simple?` and `AppSetting.advanced?` alike): a Job may not have two same-Epic upstream dependencies (no merge/fan-in), and an upstream Job may not have two same-Epic downstream dependents (no fork/fan-out). This is a *direct-edge* count, not a transitive-reachability check, so it is stricter than the proposal-graph validation above — a proposal graph that the linear policy accepts as "a chain with redundant transitive edges" (e.g. `C depends_on B`, `B depends_on A`, and also an explicit `C depends_on A`) still fails at materialization time, because `C` ends up with two direct same-Epic upstream `JobDependency` rows. No code path — the `add_job_dependency` MCP tool, the admin API, chat proposal confirmation, or GitHub issue `Depends-on:` footer parsing — can create a fan-in or fan-out same-Epic `JobDependency` edge, in any instance mode. Existing `JobDependency` rows created before this enforcement are unaffected, since the check only runs on create/update; the DAG-capable services (`JobStackResolver`, `LandingQueueProcessor#dependency_order`, `EpicRestackPlan`, `MergeTrainAssembler`) do not create new `JobDependency` rows, and keep serving whatever fan-in/fan-out structure already exists on those older rows unmodified.

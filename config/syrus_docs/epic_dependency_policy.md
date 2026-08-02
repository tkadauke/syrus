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

New Epics are linear unless the operator explicitly opts that Epic into nonlinear dependencies. Existing Epics that used the retired `inherit` value were backfilled once to the repository policy that was current at migration time, so later repository setting changes do not alter existing Epic behavior.

## Execution readiness

Linear Epics can implement down the stack before every parent is approved or landed. Once a same-Epic parent Job reaches `implemented` with a branch, PR number, and captured `head_sha`, Syrus may start the immediate child Job on that parent branch. This is execution-only readiness: `dependencies_satisfied?` remains strict for landing and still requires the parent to close successfully, or for same-Epic dependencies to reach `approved` or `landing`.

For nonlinear Epics, eager execution first looks for an unambiguous stack base. If a child has multiple approved same-Epic parents and no single downstream parent branch contains every dependency change, Syrus tries to prepare a synthetic execution base branch by merging those dependency PR branches in deterministic dependency order. If that merge is clean, the child starts from the prepared base. If it conflicts or a dependency branch/head SHA is missing, the child stays queued with `stack_fan_in_base_unavailable` and includes the blocking dependency branches plus the operator action: land the siblings, linearize the stack, or resolve the merge conflict.

## Proposal validation

Bundled Epic proposal confirmation validates proposed child Jobs against the resolved policy before creating the Epic or Jobs. Under `linear`, sibling `depends_on` edges must make every child comparable with every other child: one child, a simple chain, or a chain with redundant transitive edges is valid; fan-in, fan-out, disconnected roots/leaves, and parallel child Jobs are rejected with the offending slugs in the error.

`propose_epic_with_jobs` accepts `epic.nonlinear_dependency_override: true` as an explicit proposal-time override. Agents should set it only when the operator explicitly requested nonlinear execution. Proposal-created Epics without that override persist `linear` before child Job dependencies are materialized.

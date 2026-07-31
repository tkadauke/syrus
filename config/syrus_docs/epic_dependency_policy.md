# Epic Dependency Policy

Epic dependency policy controls the shape Syrus expects for child Job dependencies inside one Epic.

## Values

Repository `epic_dependency_policy` values:

- `linear` (default) — child Jobs should form one ordered chain.
- `nonlinear` — child Jobs may branch or fan in.

Epic `epic_dependency_policy` values:

- `inherit` (default) — use the repository's `epic_dependency_policy`.
- `linear` — require one ordered chain for this Epic.
- `nonlinear` — allow branching or fan-in dependencies for this Epic.

## Resolution

Use `Epic#resolved_epic_dependency_policy` when behavior needs the effective value:

```ruby
epic.epic_dependency_policy          # "inherit"
epic.resolved_epic_dependency_policy # "linear" or "nonlinear"
```

The built-in repository default is `linear` so new Epics are linear unless the repository or Epic explicitly opts into nonlinear dependencies.

## Execution readiness

Linear Epics can implement down the stack before every parent is approved or landed. Once a same-Epic parent Job reaches `implemented` with a branch, PR number, and captured `head_sha`, Syrus may start the immediate child Job on that parent branch. This is execution-only readiness: `dependencies_satisfied?` remains strict for landing and still requires the parent to close successfully, or for same-Epic dependencies to reach `approved` or `landing`.

For nonlinear Epics, eager execution still requires an unambiguous stack base. A child with multiple open same-Epic parents stays queued until only one unmerged parent branch remains suitable as its stack parent.

## Proposal validation

Bundled Epic proposal confirmation validates proposed child Jobs against the resolved policy before creating the Epic or Jobs. Under `linear`, sibling `depends_on` edges must make every child comparable with every other child: one child, a simple chain, or a chain with redundant transitive edges is valid; fan-in, fan-out, disconnected roots/leaves, and parallel child Jobs are rejected with the offending slugs in the error.

`propose_epic_with_jobs` accepts `epic.nonlinear_dependency_override: true` as an explicit proposal-time override. Agents should set it only when the operator explicitly requested nonlinear execution.

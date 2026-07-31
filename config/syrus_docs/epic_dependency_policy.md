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

## Proposal validation

Bundled Epic proposal confirmation validates proposed child Jobs against the resolved policy before creating the Epic or Jobs. Under `linear`, sibling `depends_on` edges must make every child comparable with every other child: one child, a simple chain, or a chain with redundant transitive edges is valid; fan-in, fan-out, disconnected roots/leaves, and parallel child Jobs are rejected with the offending slugs in the error.

`propose_epic_with_jobs` accepts `epic.nonlinear_dependency_override: true` as an explicit proposal-time override. Agents should set it only when the operator explicitly requested nonlinear execution.

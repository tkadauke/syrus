# Engineering documentation

This directory is the entry point for repository-versioned engineering
knowledge about Syrus. It describes the system as it exists now and routes
readers to the owner of each kind of detail. It is for maintainers, contributors,
and agents alike; no particular agent runtime is assumed.

## Find the right document

| When you need to… | Read | What belongs there |
| --- | --- | --- |
| Understand boundaries, data flow, or lifecycle | [Architecture](architecture/README.md) | Current structural truth and invariants |
| Implement or review a change consistently | [Conventions](conventions/README.md) | Required implementation and testing practices |
| Learn why a durable choice was made | [Decisions](decisions/README.md) | Accepted architecture decision records (ADRs) |
| Run, deploy, recover, or diagnose Syrus | [Operations](operations/README.md) | Maintainer procedures for this repository |
| Locate a subsystem and its important files | [Maps](maps/README.md) | Navigational inventories, not behavioral rules |
| Avoid a recurring failure mode | [Pitfalls](pitfalls/README.md) | Symptoms, causes, and prevention for known traps |

For a code change, start with architecture and conventions, then consult any
relevant decision, map, or pitfall. For an incident, start with operations and
pitfalls, using maps to find the implementation.

## Authority and precedence

When sources disagree, use the first applicable source in this list:

1. **Executable behavior and enforcement:** code, schema, configuration,
   migrations, and tests. These determine what the checked-out revision does.
   A mismatch with prose is documentation drift to fix, not permission to
   ignore a failing executable contract.
2. **Current engineering documentation:** this hierarchy and the current
   detailed references it links. These explain intended present behavior and
   repository-wide engineering policy.
3. **Accepted ADRs:** durable decisions constrain future changes. An ADR may
   deliberately describe a target not fully implemented yet; executable state
   remains the truth about current behavior. Supersede an ADR explicitly
   rather than silently editing its decision.
4. **Searchable harness documentation:** `config/syrus_docs/` describes
   supported behavior and functionality that agents or operators need when
   using core Syrus. It is authoritative for that behavior, but not for
   internal implementation or operating the Syrus service itself.
5. **Repository memory:** the root agent guide and other checked-in agent
   orientation summarize high-frequency rules. They route to, rather than
   override, the fuller sources above.
6. **Plans and proposals:** `docs/plans/` records intended or in-progress work
   and instance-specific evidence. Plans are not evidence that behavior landed.
7. **Historical evidence:** git history, old discussions, archived plans, and
   incident records explain the past but do not override the current tree.

If two sources at the same level conflict, verify the implementation and amend
the owning documents together. Security and safety constraints remain binding
regardless of where they are documented.

## Documentation boundaries

Some documentation intentionally lives outside this hierarchy:

- `config/syrus_docs/` is searchable by chat and implementation agents working
  on any project. It owns only the behavior and functionality needed to use
  core Syrus: `.syrus.yml` keys, operator settings and feature flags, workflow
  steps and trigger kinds, review/grader/landing/merge behavior, MCP tool
  semantics, permission behavior as it affects agents, and user-visible
  features. Internal-only changes such as response compression, payload
  shapes, caching, or polling do not require a page there.
- `plugins/<name>/docs/` owns plugin-specific documentation, including a
  plugin's operator docs. Core may link to it but must not make the plugin
  undeletable by copying it here.
- `website/` owns public product, setup, and user documentation.
- `.claude/skills/` contains executable prompt instructions. A skill is prompt
  source, not a substitute for engineering documentation.
- `docs/plans/` owns proposals, temporary investigations, and historical or
  instance-specific evidence. Promote still-current conclusions into this
  hierarchy or an ADR instead of treating a plan as current truth.

Update the owning source and link to it. Do not maintain a second copy here.

Keep Syrus implementation material in this hierarchy instead: contributor
practices belong in `conventions/`; internal architecture, data models, and
telemetry in `architecture/` (with navigational inventories in `maps/`);
runbooks for running, deploying, scaling, and upgrading Syrus in `operations/`;
plugin-authoring guidance in `conventions/plugins.md`; durable choices in
`decisions/`; and recurring failure modes in `pitfalls/`. Ruby or React class,
file, and database-column names belong here only when needed to explain those
engineering concerns. Internal telemetry and audit tables, internal data APIs,
incident post-mortems, and historical “we used to” accounts do not belong in
`config/syrus_docs/`.

## Ownership

Maintainers of the affected subsystem own updates to its engineering docs in
the same pull request as the code. Reviewers should reject ambiguous placement:
put current facts in architecture, mandatory practice in conventions, durable
rationale in an ADR, procedures in operations, navigation in maps, and
repeatable failure knowledge in pitfalls.

# Architecture decisions

This directory owns architecture decision records (ADRs): durable explanations
of why consequential, cross-cutting choices were made. Architecture pages
describe how the checked-out system works now; an ADR preserves the context,
choice, and tradeoffs that should inform a future change. Executable behavior
and tests remain the source of truth when implementation and prose disagree.
The maintainer accountable for the affected subsystem owns the record and its
evidence links.

## Records

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0002](0002-keep-plugin-documentation-with-its-plugin.md) | accepted | Keep plugin-owned documentation with its plugin |
| [ADR-0003](0003-isolate-workflow-git-state.md) | accepted | Isolate mutable Git state by workflow |
| [ADR-0004](0004-prefer-github-app-identity-with-pat-compatibility.md) | accepted | Prefer GitHub App identity while retaining PAT compatibility |
| [ADR-0005](0005-recheck-safety-before-automated-landing.md) | accepted | Recheck safety before automated landing |
| [ADR-0006](0006-persist-canonical-dependency-graphs.md) | accepted | Persist canonical dependency graphs |
| [ADR-0007](0007-separate-work-admission-from-workflow-execution.md) | accepted | Separate work admission from workflow execution |
| [ADR-0008](0008-declare-worker-placement-explicitly.md) | accepted | Declare worker placement explicitly |
| [ADR-0009](0009-extend-through-acyclic-plugin-boundaries.md) | accepted | Extend Syrus through acyclic plugin boundaries |
| [ADR-0010](0010-record-immutable-workflow-source-snapshots.md) | accepted | Record immutable workflow source snapshots |
| [ADR-0011](0011-centralize-permission-authority.md) | accepted | Centralize permission authority and distinguish harness authorship |
| [ADR-0012](0012-separate-diagnosis-from-repair.md) | accepted | Separate operational diagnosis from repair |
| [ADR-0013](0013-ratchet-semantic-ui-adoption.md) | accepted | Ratchet semantic UI adoption |
| [ADR-0014](0014-use-adapter-specific-schema-authority.md) | accepted | Use adapter-specific schema authority |
| [ADR-0015](0015-own-referential-integrity-in-the-application.md) | accepted | Own referential integrity in the application |
| [ADR-0016](0016-centralize-bounded-retention.md) | accepted | Centralize bounded retention |

## Format and lifecycle

Copy [the template](TEMPLATE.md) to
`NNNN-short-kebab-case-title.md`. Allocate the next four-digit number and keep
both the number and filename forever; the front matter identifier is
`ADR-NNNN`. Required lifecycle states are:

- `proposed`: under review and not yet binding.
- `accepted`: the decision constrains future work.
- `superseded`: replaced by one or more newer ADRs.
- `retired`: deliberately no longer applicable, without a replacement.

Every record has YAML front matter with `id`, `title`, `status`, `date`,
`supersedes`, and `superseded_by`. Link relationships use ADR identifiers. A
superseded ADR names its replacements in `superseded_by`, and each replacement
names it in `supersedes`. Add the replacement and reciprocal links instead of
rewriting the old context, decision, or consequences. Small factual
clarifications and repaired evidence links are fine, but history stays visible.

The index and metadata are validated by
`spec/architecture/engineering_decisions_spec.rb` for stable filenames, unique
identifiers, complete index coverage, lifecycle metadata, and reciprocal links.

## Choosing the durable home for knowledge

When repository memory, an incident, or a historical audit produces a recurring
lesson, verify it against current code, tests, configuration, and canonical
documentation before promoting it. Do not turn ambiguous historical artifacts
into policy.

- Update **architecture** when the result says how the system works now.
- Update a **convention** when contributors must follow a repeatable practice;
  add executable enforcement where reliable.
- Add a **pitfall** when a recurring failure needs symptoms, cause, and
  prevention recorded.
- Add an **ADR** when future maintainers need the rationale and tradeoffs behind
  a consequential choice.

One finding can require more than one synchronized update—for example, an ADR
for rationale and an architecture edit for current mechanics. Put temporary or
instance-specific evidence in `docs/plans/`, cite stable canonical evidence in
the promoted document, and update the owning documentation in the same pull
request as behavior changes.

Return to the [engineering documentation index](../README.md).

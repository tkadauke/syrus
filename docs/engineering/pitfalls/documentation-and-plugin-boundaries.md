# Documentation and plugin boundary pitfalls

## Copying operator or public docs into engineering docs

**Symptom:** two correct-looking pages disagree after a feature changes.
**Cause:** configuration or user instructions were duplicated here.
**Prevention:** keep current implementation structure in engineering docs,
operator instructions in `config/syrus_docs/`, and public guidance in
`website/`; link to the owner.

## Making an optional plugin mandatory

**Symptom:** core fails to boot or tests fail when a bundled plugin is removed.
**Cause:** core referenced plugin constants, routes, tools, docs, or migrations
instead of a registry contract. **Prevention:** discover contributions through
`Syrus::PluginRegistry`, keep plugin-owned code/docs/tests in the plugin, and
run the deletion audit described in plugin conventions.

## Scattering kind lists

**Symptom:** a new Job, Workflow, or Step kind works in one path but disappears
from another. **Cause:** a local constant or conditional duplicated the
registry. **Prevention:** use `Job::Kind`, `Workflow::TriggerKind`, `Step::Kind`,
and plugin contributions as the source of truth.

## Adding a chat tool without a renderer decision

**Symptom:** a working tool renders raw or ambiguous output in chat. **Cause:**
registration omitted a tool card and explicit fallback classification.
**Prevention:** add the core/plugin-owned card or register generic, hidden, or
deferred status; preserve the shared one-line collapsed-card contract.

## Recording private instance identifiers in durable prose

**Symptom:** comments or docs depend on an identifier meaningless outside one
installation. **Cause:** incident shorthand was copied into lasting guidance.
**Prevention:** record the reusable mechanism; keep instance-specific evidence
under `docs/plans/`.

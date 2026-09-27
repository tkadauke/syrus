# Operator Briefing

Operator Briefing is bundled as a disabled-by-default observability plugin.
This initial phase is data-layer only: it adds no `/briefing` page and no
operator workflow yet.

When enabled, the plugin owns three queryable tables:

- `operator_briefing_review_findings` promotes adversarial and visual review
  verdicts out of Workflow artifact JSON while keeping the artifacts for
  existing Job detail rendering.
- `operator_briefing_workflow_notable_changes` stores facts returned by the
  `:notable_change_detector` extension point.
- `operator_briefing_items` is the future briefing item table. `briefing_id`
  is intentionally nullable until the Briefing row ships.

The deterministic detectors cover dependency lockfiles, schema and migration
files, public API surfaces, deleted or weakened tests, overridden review
findings, and security-sensitive paths. Convention-deviation detection flags
changes to repository guidance and convention-sensitive implementation
surfaces as `attention_debt`; later phases can layer an LLM-backed pass over
those candidate facts to decide whether the change truly deviates from the
guidance.

The first "blocked on you" source is
`OperatorBriefing::BlockedDesignDocThreads`: open design-doc threads visible
to an operator whose latest comment is not by that operator.

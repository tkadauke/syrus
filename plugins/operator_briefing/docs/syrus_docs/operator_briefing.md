# Operator Briefing

Operator Briefing is bundled as a disabled-by-default observability plugin.
This initial phase is data-layer only: it adds no `/briefing` page and no
operator workflow yet.

When enabled, the plugin owns one queryable table:

- `operator_briefing_items` is the future briefing item table. `briefing_id`
  is intentionally nullable until the Briefing row ships.

Briefing generation remains agent-driven: the generation agent reads diffs,
workflow history, design docs, and other available context directly before
writing the decision-surface items.

# Operator Briefing

Operator Briefing is the per-repository briefing surface for operators. The
plugin is off by default.

When enabled, it adds a top-level `/briefing` sidebar page, records queryable
briefing items, and synthesizes stored `narrative` and `link_card` blocks
into per-repository briefing revisions.

Scheduled generation is skipped when nothing changed in a repository since its
last closed briefing. Manual regeneration always runs.

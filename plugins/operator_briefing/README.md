# Operator Briefing

Operator Briefing is the per-repository briefing surface for operators. The
plugin is off by default.

When enabled, it adds a top-level `/briefing` sidebar page, records queryable
per-repository `narrative` and `link_card` blocks, and lets the generation
agent judge notable changes directly from the briefing window's repository diff,
Workflow history, artifacts, transcripts, and linked design docs.

Scheduled generation is skipped when nothing changed in a repository since its
last closed briefing. Manual regeneration always runs.

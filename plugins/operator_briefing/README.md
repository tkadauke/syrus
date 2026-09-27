# Operator Briefing

Operator Briefing is the per-repository briefing surface for operators. The
plugin is off by default.

When enabled, it adds a top-level `/briefing` sidebar page, records queryable
per-repository `narrative` and `link_card` blocks, and lets the generation
agent judge notable changes directly from the briefing window's repository diff,
Workflow history, artifacts, transcripts, and linked design docs.

Scheduled generation is skipped when nothing changed in a repository since its
last closed briefing. Manual regeneration always runs.

The plugin also records personalization in Agent Memory. Source preferences
default to every source enabled; AI-created source changes are pending
suggestions until the operator confirms them. Explicit briefing feedback writes
a global `user_pref` memory, and completed dives use the same memory path with
higher confidence.

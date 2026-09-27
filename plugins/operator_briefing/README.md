# Operator Briefing

Operator Briefing is the per-repository briefing surface for operators. The
plugin is off by default.

When enabled, it adds a top-level `/briefing` sidebar page, records queryable
review findings, notable workflow-change facts, and early "blocked on you"
signals from open design-doc discussion threads, then synthesizes stored
`narrative` and `link_card` blocks into per-repository briefing revisions.

Scheduled generation is skipped when nothing changed in a repository since its
last closed briefing. Manual regeneration always runs.

The plugin also records personalization in Agent Memory. Source preferences
default to every source enabled; AI-created source changes are pending
suggestions until the operator confirms them. Explicit briefing feedback writes
a global `user_pref` memory, and completed dives use the same memory path with
higher confidence. Briefing generation reads the effective source preferences
and the operator's Agent Memory context before producing a revision.

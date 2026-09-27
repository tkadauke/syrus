# Operator Briefing

Operator Briefing is the per-repository briefing surface for operators. The
plugin is off by default.

When enabled, it adds a top-level `/briefing` sidebar page, records queryable
review findings, notable workflow-change facts, and early "blocked on you"
signals from open design-doc discussion threads, then synthesizes stored
`narrative`, `chart`, `image`, `artifact`, and `link_card` blocks into
per-repository briefing revisions. Image and artifact blocks render existing
typed artifacts captured by the summarized Workflow; the briefing does not
generate fresh artifacts for the main page.

Scheduled generation is skipped when nothing changed in a repository since its
last closed briefing. Manual regeneration always runs.

The plugin also records personalization in Agent Memory. Source preferences
default to every source enabled; AI-created source changes are pending
suggestions until the operator confirms them. Explicit briefing feedback writes
a global `user_pref` memory, and completed dives use the same memory path with
higher confidence. Briefing generation reads the effective source preferences
and the operator's Agent Memory context before producing a revision.

Briefing narratives can seed a small set of wiki-style dive spans. Operators
can also select arbitrary briefing text and click "More info"; both paths start
a `briefing_dive` follow-up Workflow on the same live Briefing Job and write or
revise a durable repository-scoped topic page.

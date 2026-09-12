# Retire Stale Insight Backlog

Type: one-off cleanup.

This task retires legacy Agent Insights suggestions that no longer need operator review: `revise_existing_insight` cards and informational cards titled `Superseded by #...`.

The task uses the normal audited insight retirement path, so it preserves history instead of deleting rows.

Why you might run it:

- The insights dashboard contains old superseded cards that are not actionable.
- A deployment has moved Agent Insights to the newer update/retire workflow.

Expected load: lightweight database updates only.

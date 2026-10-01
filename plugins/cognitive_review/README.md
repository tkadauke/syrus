# Cognitive Review

Cognitive Review is a bundled Syrus plugin for agent-authored review notes on
changed diff ranges. After implementation-style workflows, it can run a
best-effort review pass that flags code ranges worth operator attention and
surfaces those notes in the Job review tab.

Notes are stored as plugin-owned records scoped to the Job, Workflow, Run, and
DiffReviewVersion that produced them. Open notes count as unresolved PR-level
cognitive review debt; acknowledged or discussed notes count as handled.
Dismissed notes are reported separately in the rollup. Changed lines without a
note do not create debt.

The plugin is disabled by default. When enabled, it contributes a
post-implementation review provider, the `submit_cognitive_review_notes`
workflow MCP tool, review-tab diff annotations, and app API routes for listing,
reading, acknowledging, and discussing notes.

In the review tab, open notes appear as warning-tinted diff ranges plus
agent-authored note cards in the side panel. The plugin status area summarizes
total flagged ranges, open/unhandled notes, handled notes, dismissed notes, and
the zero-note state when the review pass explicitly submitted an empty note
set. Operators can jump to the range, acknowledge a note without replying, or
discuss it; either action marks the note handled.

This plugin only reports PR-level cognitive review debt for the diff version
under review. It is not a repository-wide cognitive coverage metric: unflagged
changed lines are treated as having no PR-level debt, and broader historical or
repository coverage analysis should integrate separately.

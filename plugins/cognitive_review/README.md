# Review Notes

Review Notes is a bundled Syrus plugin for agent-authored review notes on
changed diff ranges. After implementation-style workflows, it can run a review
pass that flags code ranges worth operator attention and surfaces concise notes
in the Job review tab.

Notes are stored as plugin-owned records scoped to the Job, Workflow, Run, and
DiffReviewVersion that produced them. Open notes count as unresolved PR-level
review-note debt; acknowledged notes, discussed notes, and covered ranges with
operator diff comments count as acknowledged. Dismissed notes are reported
separately in the rollup. Changed lines without a note do not create debt.

The plugin is disabled by default. When enabled, it contributes a
post-implementation review provider, the `submit_review_notes`
workflow MCP tool, review-tab diff annotations, and app API routes for listing,
reading, acknowledging, and discussing notes. The legacy
`submit_cognitive_review_notes` tool name remains accepted for compatibility.
Agents must call `submit_review_notes` even when the result is an empty
`notes` array; missing required submission-tool calls fail the review step
rather than producing an indistinguishable empty result.

In the review tab, open notes appear as warning-tinted diff ranges for the
displayed version plus agent-authored note cards in the unified Review
conversation side panel. The plugin status area summarizes
total flagged ranges, open/unacknowledged notes, acknowledged notes, dismissed
notes, and the zero-note state when the review pass explicitly submitted an
empty note set. Operators can jump to the range, acknowledge a note without
replying, or discuss it; either action marks the note acknowledged.

This plugin only reports PR-level review-note debt for the diff version under
review. It is not a repository-wide cognitive coverage metric: unflagged
changed lines are treated as having no PR-level debt, and broader historical
cognitive debt or repository coverage analysis should integrate separately.

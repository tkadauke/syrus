# Review Notes

Review Notes is a bundled Syrus plugin for agent-authored review notes on
changed diff ranges. After implementation-style workflows, it can run a
best-effort review pass that flags code ranges worth operator attention and
surfaces concise notes in the Job review tab.

Notes are stored as plugin-owned records scoped to the Job, Workflow, Run, and
DiffReviewVersion that produced them. Open notes count as unresolved
PR-level review-note debt; acknowledged notes, discussed notes, and
user-commented note ranges count as handled. Changed lines without a note do
not create debt.

The plugin is disabled by default. When enabled, it contributes a
post-implementation review provider, the `submit_review_notes`
workflow MCP tool, review-tab diff annotations, and app API routes for listing,
reading, acknowledging, and discussing notes. The legacy
`submit_cognitive_review_notes` tool name remains accepted for compatibility.

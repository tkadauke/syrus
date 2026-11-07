# Diff review comments

Reviewers can leave comments on a specific diff line or on the review as a
whole. They can reply to existing comments and delete their own drafts before
submitting them.

**Submit feedback** submits the selected draft comments and creates a
`chat_feedback` workflow. Line comments retain their file, side, and line
anchors so the implementation agent can act on the reviewed location; whole
review comments are submitted without a line anchor.

Files classified with `generated: true` remain visible in the review, but the
review UI hides their diff bodies by default. Repository configuration can
classify generated outputs with `.syrus.yml` `generated[].generates` rules.

The persisted `renderable_files` review setting controls which changed files
also offer rendered previews. Reviewers can switch between code and available
Before/After rendered views without changing the underlying diff feedback.

For implementation details, see the repository's engineering documentation at
`docs/engineering/architecture/diff_review_comments.md`.

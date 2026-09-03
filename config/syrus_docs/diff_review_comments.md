# Diff Review Comments

Syrus-owned diff review comments are persisted in `DiffReviewComment`, not
`PrReviewComment`. `PrReviewComment` remains the GitHub PR comment ingestion
audit model; local review UI comments use the generic table so source browser,
job review, and artifact diff surfaces can share the same storage contract.

Each comment belongs to a Job and authoring User, and can optionally point at
the Workflow and Run that produced the diff under review. Anchors store the
review surface, base/head refs, file path, side, old/new line coordinate, a
diff hunk snapshot, and a free-form JSON context hash for nearby symbols or
future re-anchoring metadata. State is one of `draft`, `submitted`,
`resolved`, or `superseded`.

API endpoints live under the user-scoped app API:

- `GET /api/v1/app/jobs/:job_id/diff_review_comments`
- `POST /api/v1/app/jobs/:job_id/diff_review_comments`
- `PATCH /api/v1/app/jobs/:job_id/diff_review_comments/:id`
- `POST /api/v1/app/jobs/:job_id/diff_review_comments/:id/resolve`

Listing follows normal Job visibility. Mutations use the existing Job write
policy: the job owner, a global admin, or a write-tier-or-higher repository
member. The list endpoint accepts `surface`, `base_ref`, `head_ref`, `path`,
and `state` filters and returns both a flat `comments` array and `by_path`,
keyed as `by_path[path][anchor_key]`, where anchor keys are `side:old:new`
with blank coordinates left empty.

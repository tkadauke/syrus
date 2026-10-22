# Workflow artifact storage

`Workflow#artifact(key)`, `Workflow#set_artifact!(key, value)`, and the merged
`Workflow#artifacts` hash are the compatibility API for step and presentation
code. Callers do not choose a persistence backend.

Four growth-bound collection keys are stored one value per row in
`workflow_artifact_values`: `iterations`, `adversarial_review_iterations`,
`visual_review_iterations`, and `typed_artifacts`. These values accumulate
grader output, review findings and evidence, or arbitrary submitted payloads,
so updating one must not rewrite the Workflow row's JSON document. Small
coordination values such as SHAs, reasons, IDs, timestamps, routing decisions,
and other bounded scalars remain inline in `workflows.artifacts`.

The table-creation migration copies existing externalized values without
removing their inline representation. This additive behavior keeps the schema
safe for old processes during a rolling deploy. New code prefers the side-table
value and falls back to inline JSON when a value has not been copied. Bulk
Workflow presentation paths preload `workflow_artifact_values`; use the public
artifact API rather than querying either storage representation directly.

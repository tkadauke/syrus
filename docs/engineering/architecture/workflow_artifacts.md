# Workflow artifact storage

`Workflow#artifact(key)`, `Workflow#set_artifact!(key, value)`, and the merged
`Workflow#artifacts` hash are the compatibility API for step and presentation
code. Callers do not choose a persistence backend.

Every artifact value is stored one value per row in `workflow_artifact_values`.
Values accumulate grader output, review findings and evidence, or arbitrary
submitted payloads, so updating one must not rewrite the Workflow row. The
inline `workflows.artifacts` column has been dropped.

Bulk Workflow presentation paths preload `workflow_artifact_values`; use the
public artifact API rather than querying the side table directly.

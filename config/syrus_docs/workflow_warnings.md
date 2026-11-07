# Workflow Warnings

Warnings are non-fatal findings attached to a Workflow. Current kinds and
their triggers are:

- `grader_side_effect` — a grader changed files outside allowed generated paths.
- `grader_git_metadata_changed` — a grader changed immutable `.git` metadata.
- `formatter_like_grader_failure` — a grader failed with changes that look like
  formatter or autofix output.
- `prepare_target_side_effect` — target preparation changed protected source.
- `implementation_capability_escalation` — implementation discovered that its
  declared mutable-workspace placement is inadequate.
- `agent_cannot_proceed` — an agent reported a concrete environmental blocker.
- `review_execution_skipped` — a review could not execute and was skipped under
  the configured policy.
- `visual_review_blocked` — visual review could not collect required evidence.
- `skipped_target_ci_failure` — target CI reported a failure on a skipped path.
- `coverage_branches_threshold_miss` — branch coverage missed its configured
  threshold while the configured policy allowed the Workflow to continue.
- `insight_job_not_discoverable` — a generated insight Job is not discoverable
  through its expected repository or dashboard surface.

Warnings remain visible on Workflow and Job review surfaces so reviewers can
decide whether a successful Workflow is acceptable. Persistence, recording,
endpoint, React, and immutable-checkout design details live in [workflow-warning
architecture](../../docs/engineering/architecture/workflow-warnings.md).

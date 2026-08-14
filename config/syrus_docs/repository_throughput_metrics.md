# Repository Throughput Metrics

Repository throughput metrics are derived from existing durable Syrus
records first. They are a contract for dashboards, chat answers, and future
rollups; they do not require new persistence unless query cost or historical
stability later demands it.

## Scope

Metrics roll up per `Repository`. Global aggregates may be built by summing
repository windows, but the repository contract is canonical.

The current contract is produced by `RepositoryThroughputMetricContract` and returns:

```ruby
{
  version: 1,
  repository_id: 123,
  generated_at: "2026-07-31T12:00:00Z",
  windows: {
    "1h" => { ... },
    "4h" => { ... },
    "24h" => { ... },
    "7d" => { ... },
    "last_active" => { ... }
  }
}
```

Authenticated app clients can read the same contract for one repository at:

```http
GET /api/v1/app/repositories/:id/throughput_metrics
```

The endpoint is scoped through the signed-in user's repository workspace
memberships and computes directly from durable rows at request time.

The repository overview page also renders this contract as a throughput panel.
It exposes the same window selector, headline rates, confidence labels,
sample counts, merge-train unit/job split, review funnel, and landing
bottleneck signals. UI consumers should keep the API contract as the source of
truth rather than duplicating metric derivation in React.

## Windows

Standard windows are `1h`, `4h`, `24h`, and `7d`, ending at the requested `now`.

`last_active` is a fallback one-hour window ending at the latest observed
repository activity when standard windows are empty. Activity can come from
Job creation, Step completion, Workflow completion, PR feedback comments, or
merge-train completion.

Every rate includes `count`, `per_hour`, `sample_count`, and `confidence`.

Confidence labels:

- `none` - 0 samples
- `low` - 1-4 samples
- `medium` - 5-19 samples
- `high` - 20+ samples

Sparse rates must be displayed with their confidence label rather than presented as stable throughput.

## PR Creation Throughput

`pr_creation.count` counts only Syrus-authored PRs: Jobs whose successful
`pr_open` Step finished in the window and whose Job has `pr_number`.

External and fork-review PRs are not mixed into that headline rate. They are
reported only as explicit separate series:

- `pr_creation.series.syrus_authored`
- `pr_creation.series.external`
- `pr_creation.series.fork_review`

`pr_creation.total_observed_count` is the sum of those observed series. Use it
only when the UI is clearly showing a mixed-source total.

Source fields:

- `steps.kind = "pr_open"`
- `steps.state = "succeeded"`
- `steps.finished_at`
- `jobs.pr_number`
- `jobs.external_pr_number`
- `jobs.fork_review_pr_number`

This avoids inventing a PR-created timestamp. If a PR exists but the original
`pr_open` Step is unavailable, it is not counted as observed PR creation
throughput.

## Output Throughput

`output.commits` counts distinct non-blank `runs.head_sha` values from
succeeded output-producing Runs in the window. It is an observed
committed-output sample, not a full Git commit count, because Syrus does not
currently persist every commit in a typed table.

`output.loc` parses `runs.step_agent_diff` first, then `runs.agent_diff`, and
reports additions, deletions, net LOC, and sample size. Diffs without a
captured patch increase `unavailable_sample_count`.

`output.by_job` exposes per-Job/PR samples where data is available. Each sample
contains the Job id, PR source and PR numbers, observed commit count, run sample
count, diff sample count, unavailable diff count, additions, deletions, and net
LOC. This is still derived from persisted Syrus run snapshots; exact GitHub
commit lists or file-level PR metadata can be added later under a new contract
version if needed.

Output-producing Step kinds:

- `implement`
- `respond`
- `analyze_and_fix`
- `landing_fix`
- `merge_train_build`
- `agent_rebase`
- `stack_agent_rebase`
- `push_agent_rebase`

Source fields:

- `runs.head_sha`
- `runs.step_agent_diff`
- `runs.agent_diff`
- `runs.finished_at`
- `steps.kind`

## Landing Throughput

`landing.landing_units` counts successful landing Workflows. A single
`auto_merge` Workflow is one landing unit; a successful `MergeTrain` row is
also one landing unit. Merge trains are counted from `merge_trains` so the
unit and its member count survive even when the associated Workflow is not the
best source of train shape.

`landing.jobs_landed` counts Jobs landed by successful landing units. A clean
auto-merge contributes one Job; a merge train contributes its member count.

`landing.attempts` separates successful, failed, cancelled, and deferred
landing attempts. Deferred attempts are cancelled landing attempts where the
Job remains approved and will re-enter the landing queue.

`landing.unit_types` splits successful units into `auto_merge` and
`merge_train`, with both landing-unit and jobs-landed counts.

`landing.merge_train_size` reports member counts for successful `MergeTrain`
records in the window.

Latency definitions:

- `approved_to_landing_latency_seconds` - `successful landing workflow.started_at - jobs.approved_at`
- `landing_start_to_closed_latency_seconds` - `jobs.finished_at - successful landing workflow.started_at`
- `grader_phase_duration_seconds` - first landing grader step start through
  last landing grader step finish.
- `mergeability_rebase_wait_seconds` - mergeability preflight and landing
  rebase step time where those steps exist.

Other landing signals:

- `base_moved_regrade_count` - landing units that needed a merge-train
  base-moved regrade/rebase path.
- `reused_landing_validation_count` - attempts where cached landing
  validation skipped the redundant pre-merge grade path.
- `current_optimistic_capacity` - a recent estimate from successful landing
  unit wall time over the trailing 7 days. It includes sample count,
  confidence, average successful unit wall time, estimated landing units/hour,
  estimated jobs landed/hour, and average jobs per landing unit.

Source fields:

- `workflows.trigger_kind IN ("auto_merge", "merge_train")`
- `workflows.state`
- `workflows.started_at`
- `workflows.finished_at`
- `jobs.approved_at`
- `jobs.finished_at`
- `jobs.closure_reason`
- `steps.kind`
- `steps.started_at`
- `steps.finished_at`
- `steps.cancellation_reason`
- `merge_trains.finished_at`
- `merge_trains.failure_reason`
- `merge_train_members`

## Landing Waste

Landing waste separates failed attempts from successful landing latency.

Fields:

- `failed_landing_attempts_per_successful_landing` - failed or cancelled
  landing units divided by succeeded landing units.
- `failed_or_cancelled_landing_workflow_seconds` - duration spent in failed or
  cancelled `auto_merge` and `merge_train` Workflows.
- `failed_or_cancelled_landing_workflow_count` - count of failed or cancelled landing attempts.
- `deferred_landing_attempt_count` - cancelled landing attempts that preserved
  approval and returned to the queue.
- `failed_train_cooldown_seconds` - configured cooldown time attached to
  failed merge trains in the window, excluding stale-base rebuild failures.
- `failed_train_cooldown_remaining_seconds` - current remaining cooldown for
  those failed merge trains.
- `rebase_churn_workflow_count` - count of `rebase` and `stack_rebase` Workflows in the window.
- `rebase_churn_seconds` - duration of `rebase` and `stack_rebase` Workflows in the window.
- `landing_blocking_rebase_count` - failed or cancelled rebase/stack-rebase Workflows, treated as landing blockers.

## Review Funnel

The review funnel tracks PR review flow from durable comments and approvals:

- `jobs_with_pr_feedback` - unique Jobs with actionable
  `PrReviewComment#comment_created_at` in the window.
- `jobs_with_feedback_before_approval` - Jobs approved in the window that
  had at least one actionable PR feedback comment at or before approval.
- `feedback_rounds` - per-Job feedback rounds in the window. Syrus uses the
  larger of feedback Workflow count (`Workflow::TriggerKind.feedback_values`
  — `pr_comment`/`chat_feedback`/`external_pr_feedback`) and actionable
  `PrReviewComment` batches when comments exist without a matching
  Workflow row.
- `feedback_rounds_by_job` - per-Job samples with PR source, PR numbers,
  total round count, Workflow round count, comment counts split by issue,
  review, and fork-review feedback, and first/last feedback and addressed
  timestamps.
- `jobs_approved_immediately_without_feedback` - Jobs approved in the window
  with no PR feedback comment at or before approval.
- `approval_sources` - approval counts by durable source where available:
  `operator` (`operator` and dashboard `bulk`), `auto` (`auto_rule`),
  `github_review`, and `unknown`.
- `approval_count` - Jobs approved in the window, based on `jobs.approved_at`.
- `approval_vote_count` - raw `JobApproval` votes recorded in the window.
- `pr_open_to_first_feedback_seconds` - first PR feedback comment timestamp
  minus successful `pr_open` Step completion.
- `feedback_to_addressed_seconds` - handled feedback timestamp minus feedback
  comment timestamp for actionable comments addressed in the window.
- `pr_open_to_approval_seconds` / `approval_latency_seconds` -
  `jobs.approved_at - successful pr_open step.finished_at`.
- `approval_to_landing_start_seconds` /
  `approval_to_landing_latency_seconds` - landing Workflow start minus
  `jobs.approved_at`.
- `approval_to_landed_seconds` - successful Job close timestamp minus
  `jobs.approved_at`.

Every duration payload includes sample size and confidence. Empty, cancelled,
and no-change Jobs only contribute when the durable timestamp for the measured
funnel stage exists; a cancelled or no-change Job without approval is not
treated as an immediate approval.

Source fields:

- `pr_review_comments.comment_created_at`
- `pr_review_comments.pr_type`
- `pr_review_comments.comment_kind`
- `pr_review_comments.actionable`
- `pr_review_comments.handled_at`
- `pr_review_comments.actioned_at`
- `workflows.trigger_kind IN Workflow::TriggerKind.feedback_values` (`"pr_comment"`, `"chat_feedback"`, `"external_pr_feedback"`)
- `workflows.created_at`
- `jobs.approved_at`
- `jobs.approved_via`
- `job_approvals.approved_at`
- successful `pr_open` Step completion

## Persistence Policy

Do not add metric tables for this contract until a caller demonstrates one of:

- Query cost is too high for dashboard refresh.
- Historical stability requires freezing numbers after mutable source records change.
- External data such as exact GitHub PR creation timestamps, full commit
  lists, or file-level additions/deletions becomes necessary.

If persistence is added later, persisted rollups must keep the same versioned
contract shape or introduce a new `version`.

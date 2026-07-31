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

`pr_creation` counts Jobs whose successful `pr_open` Step finished in the
window and whose Job has `pr_number` or `external_pr_number`.

Source fields:

- `steps.kind = "pr_open"`
- `steps.state = "succeeded"`
- `steps.finished_at`
- `jobs.pr_number`
- `jobs.external_pr_number`

This avoids inventing a PR-created timestamp. If a PR exists but the original
`pr_open` Step is unavailable, it is not counted as observed PR creation
throughput.

## Output Throughput

`output.commits` counts distinct non-blank `runs.head_sha` values from
succeeded output-producing Runs in the window. It is an observed
committed-output sample, not a full Git commit count, because Syrus does not
currently persist every commit in a typed table.

`output.loc` parses `runs.step_agent_diff` first, then `runs.agent_diff`, and
reports additions, deletions, and net LOC. Diffs without a captured patch
increase `unavailable_sample_count`.

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
`auto_merge` Workflow is one landing unit; a successful `merge_train`
Workflow is also one landing unit.

`landing.jobs_landed` counts Jobs closed in the window with `closure_reason` `pr_merged` or `external_pr_merged`.

`landing.merge_train_size` reports member counts for successful `MergeTrain` records in the window.

Latency definitions:

- `approved_to_landing_latency_seconds` - `successful landing workflow.started_at - jobs.approved_at`
- `landing_start_to_closed_latency_seconds` - `jobs.finished_at - successful landing workflow.started_at`

Source fields:

- `workflows.trigger_kind IN ("auto_merge", "merge_train")`
- `workflows.state`
- `workflows.started_at`
- `workflows.finished_at`
- `jobs.approved_at`
- `jobs.finished_at`
- `jobs.closure_reason`
- `merge_trains.finished_at`
- `merge_train_members`

## Landing Waste

Landing waste separates failed attempts from successful landing latency.

Fields:

- `failed_landing_attempts_per_successful_landing` - failed or cancelled
  landing Workflows divided by succeeded landing Workflows.
- `failed_or_cancelled_landing_workflow_seconds` - duration spent in failed or
  cancelled `auto_merge` and `merge_train` Workflows.
- `failed_or_cancelled_landing_workflow_count` - count of those failed or cancelled landing Workflows.
- `rebase_churn_workflow_count` - count of `rebase` and `stack_rebase` Workflows in the window.
- `rebase_churn_seconds` - duration of `rebase` and `stack_rebase` Workflows in the window.
- `landing_blocking_rebase_count` - failed or cancelled rebase/stack-rebase Workflows, treated as landing blockers.

## Review Funnel

The review funnel tracks PR review flow from durable comments and approvals:

- `jobs_with_pr_feedback` - unique Jobs with `PrReviewComment#comment_created_at` in the window.
- `feedback_rounds` - `pr_comment` and `chat_feedback` Workflows created in the window.
- `jobs_approved_immediately_without_feedback` - Jobs approved in the window
  with no PR feedback comment at or before approval.
- `approval_count` - Jobs approved in the window, based on `jobs.approved_at`.
- `approval_vote_count` - raw `JobApproval` votes recorded in the window.
- `approval_latency_seconds` - `jobs.approved_at - successful pr_open step.finished_at`.
- `approval_to_landing_latency_seconds` - same latency used in landing metrics.

Source fields:

- `pr_review_comments.comment_created_at`
- `workflows.trigger_kind IN ("pr_comment", "chat_feedback")`
- `workflows.created_at`
- `jobs.approved_at`
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

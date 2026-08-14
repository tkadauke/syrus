# External PR Ingestion

External PR ingestion lets Syrus discover pull requests filed by contributors or other users against opted-in repositories, and present them to the repository owner as reviewable Jobs.

## Enabling for a repository

Set `external_pr_ingestion_enabled: true` on the Repository record:

```ruby
Repository.find_by(owner: "acme", name: "widgets").update!(external_pr_ingestion_enabled: true)
```

Once enabled, `PollAllExternalOpenPrsJob` fans out to `PollExternalOpenPrsJob` every 5 minutes, which lists all open pull requests and creates an `external_pr` kind Job for any new ones.

## Linked issue PRs

When `PollRepositoryJob` sees a labeled GitHub issue with a linked open PR that Syrus did not create, it records the relationship on the issue-backed Job with `external_pr_number`.

Newly discovered issues with linked external PRs are created as normal `issue` Jobs in `implemented` state. Syrus does not start an agent workflow for them; the external PR is already the implementation under review.

Existing open issue Jobs that later gain a linked external PR are moved to `implemented`, have active Runs cancelled, and keep `external_pr_number` set. This replaces the older `closed` / `preempted` behavior so operators can review the Job instead of losing it to a terminal state.

To backfill older data, run:

```bash
bin/rails syrus:backfill_preempted_external_pr_jobs
```

The task checks each closed `issue` Job with `closure_reason = preempted` and an `external_pr_number` against GitHub. If the external PR is still open and unmerged, the task reopens the Job to `implemented`. It skips PRs that are already merged, closed, or unavailable. Use `DRY_RUN=true` to count the changes without modifying Jobs.

## Filtering

Syrus skips PRs whose head branch starts with `syrus/` — these are Syrus-authored branches and are already tracked by the normal Job pipeline.

Deduplication is based on `external_pr_number` per repository — if a Job already has that PR number, it is not ingested again.

## Grader workflow on ingestion

When a new external PR Job is created, Syrus immediately dispatches an `external_pr_ingest` workflow that runs the repository's configured graders against the PR's code.

**Same-repo PRs** (the head branch lives in the same repository as the base — Syrus can push to it):

- Chain: `prepare → retry_until(graders, repair: landing_fix) → push`
- If graders pass: no action, Job returns to `implemented`.
- If graders fail: a `landing_fix` agent step attempts to repair the code and re-run graders. On exhausted retries, the Job transitions to `failed` and the operator can review or retry.

**Fork PRs** (head is in a contributor's fork — Syrus cannot push):

- Chain: `prepare → grader_fanout → grader_collect`
- If graders pass: no action, Job returns to `implemented`.
- If graders fail: Syrus posts a `REQUEST_CHANGES` review on the PR via the GitHub review API, listing the failing graders and asking the contributor to fix and push an update. The Job returns to `implemented` (not `failed`) so the operator can still approve or close it, and the next poll cycle re-evaluates if the contributor pushes fixes.

If the repository has no graders configured (no `.syrus.yml` `grade:` block), the workflow succeeds immediately as a no-op.

## Recovering from a failed ingestion

When the same-repo grader/repair chain above exhausts its retries, the Job transitions to `failed`. Syrus treats this as an operator-action state, not an input to further automation:

- Automatic rebase dispatch (`PollMergeStateJob`) will not rebase the Job's branch while its most recent `external_pr_ingest` Workflow is failed. Rebasing a branch behind a failed ingestion is not a fix for the underlying grader/application failure — it previously left Jobs in a confusing "failed but rebased" state.
- The work engine's automatic retryable-failure repair loop skips `external_pr_ingest` Runs. The workflow's own bounded `retry_until` chain (capped by `AppSetting.grade_max_iterations`) is the only retry mechanism for these Runs; an individual grader Run that happens to time out or lose its worker is not treated as a signal to keep auto-repairing a deterministic failure.
- The operator uses the **Retry PR Ingestion** action on the Job Details page to recover. It is shown only for external PR Jobs whose latest `external_pr_ingest` Workflow is failed, and dispatches a fresh `external_pr_ingest` Workflow against the PR's current branch (re-fetched by the `prepare` step). Dispatching this clears the automatic-rebase gate above; if the new attempt fails too, the gate re-applies until the operator retries again.

## Job lifecycle

External PR Jobs start in the `implemented` state, bypassing the agent workflow. From there the standard approval and landing pipeline applies:

- The operator reviews and approves the Job
- Auto-merge lands it if enabled on the repository
- If the external PR closes or merges on GitHub, `PollExternalPrJob` closes the Syrus Job accordingly (`external_pr_merged` or `external_pr_closed`)

## PR feedback comments

`PollExternalPrJob` also records issue and review comments left on an `external_pr` Job's PR, using the same pipeline Syrus uses for its own PRs (`PollPullRequestJob`):

- Each new comment is attributed via `PrCommentAttributor` (`job_owner`, `member`, or `external`) and classified as actionable or not via `PrCommentClassifier`.
- Records are stored as `PrReviewComment` rows with `pr_type: "external"`.
- Comments authored by the configured Syrus GitHub App bot (e.g. its own grader-failure review comments) are excluded.
- A `last_seen_comment_at` watermark — the same column `PollPullRequestJob` uses — keeps already-seen comments from being reprocessed on later polls.

This poller never dispatches a follow-up workflow on its own — recording is one effect, the waiting-state reaction below is the other. Actionable comments still surface to the operator through the Job Detail page's pending-feedback panel (Apply/Replace/Ignore), same as for any other Job.

### Fork PR waiting state

For fork PRs (`external_pr_fork: true` — Syrus cannot push to the branch), qualifying comment feedback puts the Job into the same waiting state as a formal GitHub `CHANGES_REQUESTED` review: `needs_attention_reason` is set to `"upstream_pr_changes_requested"`. There is no distinction between a formal review and a plain qualifying comment — per operator decision, only a collaborator can leave either on GitHub, so the nuance doesn't matter in practice.

A comment "qualifies" using the same rule `PollPullRequestJob` uses for Syrus-authored PRs (`PrCommentIngester#qualifies_for_workflow?`): actionable comments from the job owner always qualify; actionable comments from a repository member or an unrelated (`external`) commenter qualify only when the repository's `feedback_policy` is `"auto"`.

Actionable comments from an `external` commenter (no relationship to the repository) that don't clear that bar are not auto-acted on. Instead, Syrus sends the job owner a `external_pr_feedback` notification asking them to review the feedback themselves; the Job's `needs_attention` state is left untouched.

If the fork Job is already `approved` when qualifying feedback arrives, Syrus unapproves it (mirroring `PollPullRequestJob#clear_stale_approval!` for Syrus-authored PRs) so it doesn't land out from under a fresh objection.

### Same-repo PR fix-and-push

For same-repo PRs (`external_pr_fork: false` — e.g. a dependabot branch, or a collaborator's branch on the tracked repository itself), Syrus already has push access to the branch (the same-repo `external_pr_ingest` chain above already pushes fixes to it), so qualifying feedback is treated exactly like feedback on a Syrus-authored PR instead of the fork waiting state:

- If the Job is `approved`, Syrus unapproves it first (same as the fork path), so it doesn't land out from under fresh feedback.
- Syrus dispatches a `Workflows::ExternalPrFeedback` workflow: `prepare → [loop(respond → adversarial_review)] → retry_until(respond → graders) → summarize_amend → try(push)`. It reuses the same `respond`/`adversarial_review`/`summarize_amend`/`push` step handlers as `Workflows::PrFeedback` (Syrus-authored PR feedback), sourced from `job.external_pr_number`/`job.branch_name` instead of `job.pr_number`. It skips `coverage_analyze`/`coverage_pr_comment`/`refresh_job_metadata` — those steps key off `job.pr_number`, which external PR Jobs never set.
- `push` (and workspace checkout) work off `job.branch_name` generically, so this pushes cleanly to any branch name — not just the `syrus/...` convention used by Syrus-authored branches (e.g. a `dependabot/bundler/...` branch).
- If a `external_pr_feedback` Workflow is already `queued`/`running` on the Job, Syrus does not dispatch a second one for a newer qualifying comment — the active workflow's `respond` step sees the full comment thread and addresses everything outstanding.
- Comment qualification and the `external`-attributed non-auto-action + notify rule work identically to the fork path above (same `PrCommentIngester#qualifies_for_workflow?` rule, same `external_pr_feedback` notification for non-qualifying `external` comments under `feedback_policy != "auto"`).
- Unlike the fork path, `needs_attention_reason` is not set — dispatching the fix-and-push workflow (and the resulting unapproval) is itself the signal that landing is paused, matching how `PollPullRequestJob#react_to_pr_comments` behaves for Syrus-authored PRs.

## Dashboard display

Dashboard job lists (table, mobile rows, kanban cards, and landing-queue blocker
rows) mark a PR link with a violet "External" badge whenever the PR shown for a
Job was not opened by Syrus — either an `external_pr` kind Job, or a Syrus-initiated
Job whose own PR was preempted by an externally authored one (`external_pr_number`
set with no `pr_number`). This lets operators tell at a glance which PRs need
review-only handling versus ones Syrus authored itself.

## Job fields

| Field | Source |
|---|---|
| `kind` | Always `external_pr` |
| `external_pr_number` | GitHub PR number |
| `external_pr_author` | GitHub login of the PR author |
| `external_pr_fork` | `true` if the PR head is in a fork; `false` for same-repo PRs |
| `branch_name` | PR head branch ref (used for workspace checkout and same-repo push) |
| `issue_title` | PR title from GitHub |

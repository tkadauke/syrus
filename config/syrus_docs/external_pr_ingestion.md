# External PR Ingestion

External PR ingestion lets Syrus discover pull requests filed by contributors or other users against opted-in repositories, and present them to the repository owner as reviewable Jobs.

## Enabling for a repository

Set `external_pr_ingestion_enabled: true` on the Repository record:

```ruby
Repository.find_by(owner: "acme", name: "widgets").update!(external_pr_ingestion_enabled: true)
```

Once enabled, `PollAllExternalOpenPrsJob` fans out to `PollExternalOpenPrsJob` every 5 minutes, which lists all open pull requests and creates an `external_pr` kind Job for any new ones.

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

## Job lifecycle

External PR Jobs start in the `implemented` state, bypassing the agent workflow. From there the standard approval and landing pipeline applies:

- The operator reviews and approves the Job
- Auto-merge lands it if enabled on the repository
- If the external PR closes or merges on GitHub, `PollExternalPrJob` closes the Syrus Job accordingly (`external_pr_merged` or `external_pr_closed`)

## Job fields

| Field | Source |
|---|---|
| `kind` | Always `external_pr` |
| `external_pr_number` | GitHub PR number |
| `external_pr_author` | GitHub login of the PR author |
| `external_pr_fork` | `true` if the PR head is in a fork; `false` for same-repo PRs |
| `branch_name` | PR head branch ref (used for workspace checkout and same-repo push) |
| `issue_title` | PR title from GitHub |

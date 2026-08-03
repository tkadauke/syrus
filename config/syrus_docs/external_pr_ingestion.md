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
| `issue_title` | PR title from GitHub |

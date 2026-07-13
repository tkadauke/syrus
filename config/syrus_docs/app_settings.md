# AppSetting Reference

`AppSetting` is a singleton configuration row for the Syrus instance. Read it with `AppSetting.current`; update via the admin UI or Rails console: `AppSetting.current.update!(key: value)`.

## Workflow behavior

### grade_max_iterations

**Type:** integer · **Default:** 5 · **Range:** 1–10

Maximum number of repair→check cycles in the grader loop before a workflow fails. Per-repo `.syrus.yml` can override this with `grade.max_iterations`.

### adversarial_review_rounds

**Type:** integer · **Default:** 0 · **Range:** 0–10

Number of implement→adversarial-review iterations run before graders. `0` disables adversarial review instance-wide. Per-repo `.syrus.yml` can override with `adversarial_review.rounds`.

### max_job_failures

**Type:** integer · **Default:** 3 · **Min:** 0

Consecutive failure threshold. When a ScheduledTask accumulates this many consecutive failures it auto-pauses (state `auto_paused`). Also used by `AutoRetryScheduler` as a signal for provider circuit-breaker suppression.

## Landing queue

### merge_train_enabled

**Type:** boolean · **Default:** false

When true, approved Epic child Jobs do not land one-by-one. They wait until every open sibling is approved, then the Epic lands as a single atomic `merge_train` workflow. When false, approved Jobs land individually via `auto_merge`.

### merge_train_max_size

**Type:** integer · **Default:** 20

Maximum number of PRs that can participate in a single merge train. `merge_train_assemble` rejects the train if the member count exceeds this limit.

## Instance operations

### signups_open

**Type:** boolean · **Default:** false

Allow new user registrations. Set to `false` on private instances.

### polling_paused

**Type:** boolean · **Default:** false

Emergency kill switch: pause all polling jobs (`PollAllRepositoriesJob`, `PollAllPullRequestsJob`, etc.). Jobs already running complete normally; no new issues or PR comments are picked up.

### runs_paused

**Type:** boolean · **Default:** false

Emergency kill switch: pause workflow execution. `RunJob` checks this flag and re-enqueues itself if true, so active Runs stay queued without losing state.

### report_issue_repo_slug

**Type:** string · **Default:** "tkadauke/syrus"

GitHub repo slug used for the in-app "Report an issue" link. Change to your own fork slug on self-hosted instances.

## GitHub App

### github_app_id

**Type:** bigint

The numeric ID of the registered GitHub App. Set once during GitHub App setup via the admin UI.

### github_app_private_key_pem

**Type:** text (encrypted)

The RSA private key PEM for the GitHub App. Used to sign JWT tokens for App authentication. Stored encrypted via Active Record Encryption.

### github_app_slug

**Type:** string

The URL slug of the GitHub App (appears in `https://github.com/apps/<slug>`).

### github_app_registered_at

**Type:** datetime

When the GitHub App was registered. Informational; does not affect runtime behavior.

## Video walkthroughs

### video_retention_days

**Type:** integer · **Default:** 7 · **Min:** 1

How long to retain walkthrough video blobs before `VideoWalkthroughPruneJob` deletes them. The analysis and screenshots persist indefinitely; only the raw video blob is pruned.

### video_storage_budget_bytes

**Type:** integer · **Default:** 2,147,483,648 (2 GB) · `0` = unlimited

Instance-wide storage budget for walkthrough video blobs. When the budget is exceeded, `VideoWalkthroughPruneJob` evicts the oldest blobs first (LRU).

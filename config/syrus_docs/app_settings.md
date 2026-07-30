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

## Instance mode

### mode

**Type:** string · **Default:** `"advanced"` · **Values:** `"advanced"`, `"simple"`

Instance-wide experience mode. Set once during first-run onboarding (the "How do you work?" wizard step) or later in Admin → Settings → Instance mode.

- **`advanced`** — full developer experience: manual per-Job approvals, Coding Mode, Local Mode, scheduled tasks, GitHub Issues tab, and all operator controls are available.
- **`simple`** — non-technical solopreneur mode: developer-only surfaces are force-disabled regardless of their feature flag state. Specifically, `Feature.coding_mode_enabled?` and `Feature.local_mode_enabled?` always return `false`. Epic child Job dependency graphs must be strict linear chains (no forks, no merges).

Use `AppSetting.simple?` / `AppSetting.advanced?` in code to branch on mode. Changing mode takes effect immediately (no restart required) because `AppSetting.current` is called at request time.

### mode_configured_at

**Type:** datetime · **Default:** nil

Stamped automatically when an operator first explicitly sets the mode (via the onboarding wizard or Admin Settings). Nil on instances that have never had a mode explicitly set. Used by the onboarding checklist to track whether the mode step is complete.

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

Controls where in-app bug reports are sent. The slug is also used for the "Report an issue" link displayed in the UI.

**Routing logic:** when a user submits a bug report, Syrus checks whether an active `Repository` record exists for this slug (system-wide match) or whether the user has a fork of it (`upstream_owner`/`upstream_name` match). If either is found, the report is filed as a direct Syrus Job against that repository. If neither is found, the report is filed as a plain GitHub issue via the API using the user's PAT; screenshots and attachments are uploaded to GitHub's asset CDN and embedded inline in the issue body.

On self-hosted instances, set this to the `owner/name` of your own Syrus fork. If the fork is tracked in Syrus as a repository, reports will be routed as Jobs; if not, they will be filed as GitHub issues against that slug.

### max_concurrent_agent_runs

**Type:** integer · **Default:** 0 (unlimited)

Global, cluster-wide cap on how many `:runs` queue Runs execute at once, across **all** worker pods. `RunJob` enforces it with a best-effort defer-and-re-enqueue gate (DB-counted, so it holds across pods). Set this when running multiple worker pods so total compute concurrency — and Claude/Codex cost and rate-limit exposure — does not scale with pod count; each pod's `JOB_CONCURRENCY` only bounds that single pod. `0` means no global cap. Main-branch grader Runs are on `:runs` and are counted; landing/merge Runs (`:merges` queue) are not counted, so they can't be starved by a saturated agent cap.

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

### video_storage_budget_mb

**Type:** integer · **Default:** 2048 (2 GB) · `0` = unlimited

Instance-wide storage budget for walkthrough video blobs, measured in megabytes. When the budget is exceeded, `VideoWalkthroughPruneJob` evicts the oldest blobs first (LRU). The class method `AppSetting.video_storage_budget_bytes` converts this to bytes for internal use.

## Coding-Mode workspaces

### chat_coding_workspace_budget_mb

**Type:** integer · **Default:** 0 (unlimited) · `0` = disabled

Instance-wide byte budget for retained Coding-Mode chat checkouts (each is a writable full clone plus installed dependencies, commonly 1–2 GB), measured in megabytes. When retained checkouts exceed the budget, `WorkflowWorkspacePruneJob` calls `ChatWorkspace.reclaim_coding_over_budget!` to LRU-evict the least-recently-active ones until total on-disk size is under budget — after safely backing up any un-pushed / uncommitted work to the remote (see the Coding Mode docs). `0` disables the size cap; the idle-reclaim window (`ChatWorkspace::RECLAIM_IDLE_CODING_AFTER`, 48 h) and reclaim-on-handoff still apply. Set this on busy instances where coding chats would otherwise fill the worker's data volume. `AppSetting.chat_coding_workspace_budget_bytes` converts it to bytes.

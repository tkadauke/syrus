---
title: Configuration
description: .syrus.yml, per-user settings, per-repo settings.
---

# Configuration

Syrus is configured in three layers:

| Layer | Lives in | Controls |
| --- | --- | --- |
| Deployment | Environment variables and Rails credentials | Database access, encryption keys, worker storage, queue sizing |
| User | The credentials/settings UI | GitHub token, agent credentials, preferred provider, max agent turns |
| Repository | Repository settings plus optional `.syrus.yml` in the target repo | Trigger label, polling, default branch, provider override, prepare commands |

For deployment-specific placement, see [Deployment](/docs/deployment).

## `.syrus.yml`

`.syrus.yml` is read from the root of the target repository during the
workflow and by local CLI checkout commands. It configures deterministic
setup commands before the agent runs, optional adversarial review rounds
for Initial workflows, and optional local hooks after an operator checks
out a Syrus branch.

```yaml
prepare:
  - bundle install
  - npm ci

adversarial_review:
  rounds: 2

hooks:
  post_checkout:
    - bundle exec rails db:migrate
```

Schema:

| Key | Type | Meaning |
| --- | --- | --- |
| `prepare` | Array of strings | Shell commands to run in order before agent work starts |
| `prepare` | `[]` | Explicitly run no preparation commands |
| `prepare` | `false` | Opt out of preparation entirely |
| `adversarial_review.rounds` | Integer | Number of adversarial review rounds to run before grading; omit or set `0` to disable |
| `hooks.post_checkout` | Array of strings | Shell commands the CLI runs after `syrus checkout` succeeds |

### `prepare`

`prepare` commands run from the workspace root under `bash -c`, so
quoting, pipes, and `&&` work. Each command has a 10 minute timeout. The
environment is scrubbed to a small safe allowlist so the Syrus worker's
own Bundler, Rails, or production environment settings do not leak into
the target repo's install.

When an **explicit** `.syrus.yml` prepare command fails, Syrus fails the
workflow before starting the agent and records the command, workspace
directory, exit status or timeout state, and a compact tail of command
output on the workflow page. You asked for the command, so a failure is
loud.

If `.syrus.yml` is missing, Syrus auto-detects one setup command from the
first matching file:

| Signal | Command |
| --- | --- |
| `Gemfile` | `bundle install` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `package-lock.json` | `npm ci` |
| `package.json` | `npm install` |

Only the first match is used. A Rails app with both `Gemfile` and
`package-lock.json`, for example, gets `bundle install` unless it provides
an explicit `.syrus.yml`.

Auto-detected commands are a **guess**, so they fail *soft*: if the
inferred command exits non-zero (a stale lockfile, a package manager that
needs build-script approval, a tool the repo doesn't actually use), Syrus
logs a non-fatal warning, records the failure on the workflow page, and
hands the workspace to the agent anyway. This keeps a wrong guess from
wedging onboarding — the very first Job on a repo can still run and add a
`.syrus.yml` or fix the lockfile. Add an explicit `prepare:` list whenever
you want setup to be authoritative (and to fail loudly when it breaks).

### `adversarial_review`

`adversarial_review.rounds` is optional and applies only to Initial
workflows. When it is greater than zero, Syrus runs that many
implementer/reviewer rounds before the normal grade loop, then runs one
final `implement` step to address the last review before grading.

The workflow chain is created before the workspace clone exists, so Syrus
reads this setting from `.syrus.yml` on the repository's default branch. If
the file or setting is absent, adversarial review is disabled.

### `coverage`

`coverage` enables test coverage tracking, threshold enforcement, and PR
comment reporting. Syrus reads coverage artifacts produced by your grader
commands and inserts a `coverage_analyze` step after grading.

```yaml
coverage:
  sources:
    - artifact: coverage/lcov.info
      format: lcov          # lcov | cobertura
  threshold:
    lines: 80               # overall line coverage minimum (%)
    pr_lines: 90            # PR-diff line coverage minimum (%)
  on_miss: warn             # block | warn | schedule
  pr_comment: true          # post a coverage report comment on the PR
  hitmap_ttl_days: 7        # how long to keep the full hit map blob
```

**`sources`** (required) — list of coverage artifact files and their format.
LCOV is the recommended format (supported by SimpleCov, Jest/nyc, coverage.py,
gcov2lcov, and llvm-cov). Cobertura XML is also accepted. Add as many sources
as you have test suites; Syrus merges them before analysis.

**`threshold`** — optional pass/fail gate. `lines` checks overall line
coverage; `pr_lines` checks coverage on lines changed in the PR diff. A miss
triggers `on_miss` behavior:

| `on_miss` | Effect |
|-----------|--------|
| `warn` (default) | Step succeeds; threshold miss is recorded in the artifact |
| `block` | Step fails, stopping the workflow before PR creation |
| `schedule` | Step succeeds; a new coverage-fix Job is enqueued |

**`pr_comment`** — when `true`, Syrus posts (or updates) a coverage report
comment on the PR after each workflow run. The comment includes an overall
summary table with threshold status badges and a collapsible per-file table
for changed files. Syrus upserts the comment — later runs update the existing
comment in place rather than creating duplicates. For initial workflows the
comment is posted by the `pr_open` step; for subsequent workflows
(`pr_comment`, `chat_feedback`) a dedicated `coverage_pr_comment` step handles
it.

**`hitmap_ttl_days`** — how long Syrus retains the full line hit map blob
(default 7 days). The hit map drives source-browser line highlighting and
diff annotations in the UI.

### `hooks.post_checkout`

`hooks.post_checkout` commands are optional shell strings. They run only
in the local operator checkout after `syrus checkout JOB-<id>` or
`syrus checkout EPIC-<id>` successfully switches branches. The CLI runs
each hook in order from the repository root with `sh -c`, streams output
to the terminal, and fails fast on the first non-zero exit. Pass
`--no-hooks` to bypass hooks for one checkout:

```bash
syrus checkout --no-hooks JOB-<id>
syrus checkout --no-hooks EPIC-<id>
```

When a post-checkout hook fails, the CLI prints the failed command and
exit code, then exits non-zero. The checkout itself is not rolled back:
fix the local problem and rerun the command manually, or run checkout
again with `--no-hooks` if you only need the branch.

## Worked Examples

Syrus's own repo uses `.syrus.yml` to pin Bundler output into the cloned
workspace before installing gems:

```yaml
prepare:
  - bundle config set --local path vendor/bundle
  - bundle install --jobs 4
```

A Node repo that needs generated client code before the agent starts:

```yaml
prepare:
  - npm ci
  - npm run generate
```

A Rails app that installs dependencies for the agent and runs local
post-checkout maintenance for the developer:

```yaml
prepare:
  - bundle install
  - yarn install --frozen-lockfile

hooks:
  post_checkout:
    - bundle exec rails db:migrate
    - yarn install --frozen-lockfile
```

A repo with no useful setup step:

```yaml
prepare: []
```

Or, equivalently:

```yaml
prepare: false
```

## Per-User Settings

Each user owns their own profile, credentials, agent preferences, and account preferences.

| Setting | Purpose |
| --- | --- |
| Profile | Display name, name fields, company, location, website, GitHub handle, avatar URL, and bio on `/profile` |
| Role | User-facing role, either `developer` or `product_owner`; users can set their own role on `/profile`, and admins can override it from `/admin/users` |
| GitHub token | Used to list issues, read PRs, push branches, open PRs, and post updates for that user's repositories; configured on `/credentials` |
| Agent provider | Default provider for new Jobs: `claude` or `codex`; configured on `/settings/agent` |
| Chat provider | Optional provider override for chat turns: `claude` or `codex`; when blank, chat follows the user's default agent provider |
| Claude credential | Encrypted long-lived Claude OAuth token from the Claude authorization flow or `claude setup-token`, passed to Claude Code as `CLAUDE_CODE_OAUTH_TOKEN`; configured on `/credentials` |
| Codex credential | Encrypted Codex API key or ChatGPT login auth JSON, depending on auth mode; configured on `/credentials` |
| Agent max turns | Per-run cap for Claude Code tool-use turns; `0` means no `--max-turns` flag; configured on `/settings/agent` |
| Theme | Light or dark app chrome, toggled from the account area and persisted per user |
| Scheduling paused | Skips scheduled task firing for that user; configured on `/settings/preferences` |
| Desktop notifications | Per-type desktop banner toggles for implemented and failed Jobs; configured on `/settings/preferences` |
| Admin API token | Admin-only bearer token for `/api/v1/admin/*` diagnostics, including Jobs, Runs, queue/processes, and chat transcripts; shown once on rotation from `/credentials` |
| Memories | Persistent agent context owned by the user; repository-scoped memories can be published from the Memories settings panel |

The **Credentials** page includes a per-credential **Test** action after a
secret is saved. GitHub PAT tests call GitHub as the user and report the
authenticated login plus token scopes. Claude and Codex tests run short CLI
auth probes through the same credential paths used by Jobs, so expired or
mis-shaped agent credentials surface before a downstream run fails.

For Claude Code, click **Authorize with Claude** in the credentials form,
approve access in the Claude tab, then paste the short code Claude shows
back into Syrus. Syrus exchanges that code for a long-lived token and
tests it before storing it. You can also generate a token with
`claude setup-token` on a machine with a browser and paste the
long-lived token directly into the form. Do not copy the short-lived
token from Claude Code's local credential store; Syrus does not run
Claude Code's local refresh machinery. See Anthropic's
[long-lived token documentation](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).

For Codex ChatGPT login, use **Authorize with ChatGPT** in **Credentials**.
Syrus opens OpenAI's authorization page, accepts the pasted
code, exchanges it for Codex tokens, and stores those tokens encrypted as
Codex auth JSON. The manual `auth.json` textarea remains available for
operators who already have a local Codex credential file.

Provider selection resolves from most specific to least specific:

```text
Workflow override -> Job provider -> Repository override -> User default
```

Budget thresholds are on the
[roadmap](https://github.com/tkadauke/syrus/blob/main/ROADMAP.md#claude-usage-budgets-and-thresholds).
Syrus already records per-run cost and token metadata where the provider
reports it, and the planned model is per-user and per-repo dollar caps over
rolling windows. Until that ships, use provider-side limits and the
per-user max-turns setting as the active safety rails.

## Per-Repository Settings

Repository settings are stored in Syrus, not in `.syrus.yml`.

| Setting | Default | Purpose |
| --- | --- | --- |
| Owner/name | None | GitHub repository to poll |
| Default branch | `main` | Base branch for clones, diffs, PRs, and rebases |
| Trigger label | `syrus` | Label that turns an issue into a Job |
| Polling enabled | `true` | If disabled, scheduled pollers skip the repo |
| Agent provider override | Blank | If set, new Jobs for the repo use this provider instead of the user's default |
| PR cost footer | `true` | Adds or updates a cost footer on PRs when cost data exists |
| Review policy | `self` | Who must approve before a Job lands; see [Review Policies](#review-policies) below |
| Default issue workflow | `initial` | Label-triggered issues currently use the built-in Initial template |

## Review Policies

The `review_policy` setting on each repository controls how many approvals are
required before a Job can enter the landing queue.

| Policy | Who must approve |
| --- | --- |
| `self` (default) | The job owner must add their approval — reviewing your own AI-generated output before it merges |
| `two_person` | The job owner **and** at least one other user must both approve |
| `final_say` | The job owner must approve, plus one user from the repository's designated final-approvers list. If the owner is already a final approver, the policy collapses to `self`. |

### How approvals work

When the repository's review policy is anything other than `self`, the
**Approve** button records the current user's vote without immediately
transitioning the Job. Once the required votes are in, the Job moves to
`:approved` and enters the landing queue.

Approval rules:

- The job **creator** (`user_id`) cannot add a JobApproval unless they are
  also the **owner** (`owner_user_id`). The owner can always approve — that
  step is the primary human review of AI-generated output.
- Any other repository member can add an approval vote.
- Unapproving a Job clears all recorded votes so the full policy must be
  re-satisfied before the Job can land again.

### Final approvers

To designate final approvers for a `final_say` repository, add `RepositoryFinalApprover`
records via the admin console or API. A repository may have any number of
final approvers; only one needs to approve a given Job.

### Auto-approval bypass

`auto_approve_rules` on Epics, repositories, and users bypass the review
policy entirely — the job transitions directly to `:approved` without
creating `JobApproval` records. This is intentional: auto-approval means
Syrus already validated the work through required graders, and requiring
human sign-off on top of that would defeat the purpose.

The default workflow is not a free-form per-repo template yet. In the
current implementation, issue ingestion always starts the `initial`
workflow; scheduled tasks, PR feedback, CI failures, rebases, retries, and
manual actions choose their own trigger-specific templates.

## Feedback Policies

The `feedback_policy` setting on each repository controls whether PR comments
from team members and external reviewers are acted on automatically or require
confirmation.

| Policy | Behavior |
| --- | --- |
| `confirm` (default) | Only the job owner's actionable comments trigger automatic implementation; team member and external actionable comments are recorded but do not queue a workflow until confirmed by the operator |
| `auto` | Actionable comments from all commenter categories queue an implementation workflow automatically |

### Comment attribution

Syrus classifies each new PR comment by commenter:

- **Job owner** — the GitHub handle matches the job's owner user. Owner comments always queue automatically regardless of `feedback_policy`.
- **Team member** — the handle matches a repository membership. Member comments respect `feedback_policy`.
- **External** — the handle is not found in memberships and is not the owner. External comments respect `feedback_policy`.

Syrus also passes each comment through an LLM classifier to determine whether it contains actionable feedback (requests a code change, correction, or improvement) or is a discussion remark, question, or acknowledgement. Non-actionable comments are stored in the `pr_review_comments` audit log but never trigger a workflow.

### Which PRs are polled for comments

Syrus polls all PR surfaces associated with a Job:

- **Direct PR** — the PR Syrus opened against the shared repository (modes 1 and 2a)
- **Upstream PR** — the PR opened against the upstream repository after fork review approval (modes 2b and 3)
- **Fork review PR** — the internal PR from the feature branch to the fork's default branch, polled until the upstream PR is created

All three surfaces use the same attribution and classification pipeline.

### Pending feedback (confirm policy)

When `feedback_policy` is `confirm`, actionable comments from team members and external reviewers appear in a **Pending feedback** section on the job detail page. The job owner can choose one of three actions for each comment:

- **Apply** — use the comment body as-is as the feedback prompt for a new iteration.
- **Ignore** — dismiss the comment without taking action; it is recorded in the audit trail.
- **Replace** — write a custom feedback prompt; the original comment is marked handled and the operator's text drives the next iteration.

All three actions are recorded via the `actioned_by` field on the `pr_review_comments` audit row. The resulting `chat_feedback` workflow artifacts include a `feedback_source` field with the original commenter attribution and the action taken (`apply` or `replace`), visible in the feedback history panel.

## Worker Environment

The web and worker processes share the Rails environment. The worker also
needs durable workspace storage because it manages clones and worktrees.

| Variable | Required | Used by |
| --- | --- | --- |
| `RAILS_MASTER_KEY` | Production yes, unless direct Active Record encryption keys are configured | Decrypts Rails credentials and Active Record encrypted attributes |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Production alternative | Active Record Encryption primary key when not using Rails credentials |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Production alternative | Active Record Encryption deterministic key when not using Rails credentials |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Production alternative | Active Record Encryption key derivation salt when not using Rails credentials |
| `SECRET_KEY_BASE` | Production yes | Rails sessions, signed cookies, message verification |
| `DB_HOST` | Production yes | MySQL host; defaults to `127.0.0.1` |
| `SYRUS_DATABASE_PASSWORD` | Production yes | MySQL password |
| `SYRUS_DATA_ROOT` | Worker recommended | Clone cache and per-workflow workspaces; defaults to `~/.syrus` |
| `SYRUS_GITHUB_REPO` | Yes | GitHub `owner/repo` slug for this Syrus installation's own repository; used for build revision links |
| `SYRUS_BUG_REPORT_OWNER` | Yes | GitHub owner or organization for in-app bug reports; Syrus uses the configured `syrus` repository under that owner |
| `SYRUS_MAILER_FROM` | No | From address for password reset and invitation email; defaults to `Syrus <noreply@$SYRUS_APP_HOST>` |
| `SMTP_ADDRESS` | No | Enables SMTP delivery for password reset and invitation email when set |
| `SMTP_PORT` | No | SMTP port; defaults to `587` |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | No | SMTP credentials, when required by the server |
| `SMTP_AUTHENTICATION` | No | SMTP authentication mode; defaults to `plain` |
| `SMTP_ENABLE_STARTTLS_AUTO` | No | Whether Action Mailer should auto-enable STARTTLS; defaults to `true` |
| `JOB_CONCURRENCY` | No | Solid Queue worker thread count for the `runs` queue; defaults to `3` |
| `RAILS_MAX_THREADS` | No | Rails and database pool sizing |
| `RAILS_LOG_LEVEL` | No | Production log level; defaults to `info` |
| `PORT` | Web only | Rails server port; defaults to `3000` |
| `GIT_SHA` | No | Displayed build revision |

`SYRUS_DATA_ROOT` should point at a persistent volume for worker pods.
Web pods do not need clone storage. The mounted directory must be writable
by the container's `rails` user (`1000:1000`); the published Docker images
create `/home/rails/.syrus` with that ownership so a fresh named volume can
inherit it on first mount.

## Secret Management

Per-user credentials use Active Record Encryption:

- `github_token`
- `claude_oauth_token`
- `codex_api_key`
- `codex_auth_json`
- `api_token`

The encrypted values live in the primary database. The encryption keys can
come from Rails credentials via `RAILS_MASTER_KEY`, or directly from the
`ACTIVE_RECORD_ENCRYPTION_*` environment variables. Any process that reads
or writes users needs one complete, stable key source. This is why smoke
tests or console sessions that create users fail loudly when encryption
keys are missing.

GitHub push tokens are not written into clone remotes. Syrus keeps clone
remotes anonymous and constructs a token-bearing push URL only for the
individual `git push` call.

For token rotation, users update their GitHub and agent credentials in the
credentials UI by submitting a replacement value. Admin API tokens are
rotated separately and displayed only once; admins can also revoke the token
from the same credentials page, which immediately removes API access until a
new token is generated. For Rails encryption key rotation, follow Rails
Active Record Encryption rotation practice: deploy the new scheme while
retaining read access to old ciphertext, rewrite encrypted attributes, then
remove the old scheme after verification.

---
title: Configuration
description: .syrus.yml, per-user settings, per-repo settings.
---

# Configuration

Syrus is configured in three layers:

| Layer | Lives in | Controls |
| --- | --- | --- |
| Deployment | Environment variables and Rails credentials | Database access, encryption keys, worker storage, queue sizing |
| User | The credentials/settings UI | GitHub token, agent credentials, preferred provider, failover policy, max agent turns |
| Repository | Repository settings plus optional `.syrus.yml` in the target repo | Trigger label, polling, default branch, provider override, prepare commands |

For deployment-specific placement, see [Deployment](/docs/deployment). For a
practical staged path from root-only repositories to project-aware monorepos,
see [Monorepo Adoption](/docs/monorepo-adoption).

## `.syrus.yml`

`.syrus.yml` is read from the root of the target repository during the
workflow and by local CLI checkout commands. It configures deterministic
setup commands before the agent runs, preview commands, optional review
rounds, grader commands, and optional local hooks after an operator checks
out a Syrus branch.

Small repositories can keep a single root file. Monorepos can add nested
`.syrus.yml` files and explicit targets deliberately; use
[Monorepo Adoption](/docs/monorepo-adoption) for examples across app, CLI,
desktop, iOS, Android, shared API/client code, and mixed-product layouts.

```yaml
prepare:
  - bundle install
  - npm ci

adversarial_review:
  rounds: 1
  criteria:
    - Check for missing tests and stale docs.

review_notes:
  criteria:
    - Surface shared services and final-diff resolution paths.
  low_signal:
    - Skip ordinary fixture churn unless it changes a test harness.

visual_review:
  enabled: true
  rounds: 1
  when_files_changed:
    - "app/frontend/**/*"
    - "app/views/**/*"

preview:
  setup:
    - bundle install
    - npm ci
  start: bin/rails server -p $PORT -b 0.0.0.0 -e development
  seed: bin/rails db:prepare db:seed
  health_check: /up

grade:
  - type: rspec
    failures: allow_inherited
    tags:
      ci:
        include: [ci_only]

merge_train:
  failure_rungs: [multisect]
  multisect:
    section_width: 4

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
| `grade` | Array or mapping | Required grader commands; each step has `name`, `run`, and optional `phases`, `junit_output`, `failures`, `required`, `timeout_minutes`, and `when_files_changed` |
| `merge_train.failure_rungs` | Array of strings | Repository-local merge-train failure rungs; currently supports `multisect` |
| `merge_train.multisect.section_width` | Integer | Number of sections used by the focused multisect attribution rung; valid range is 2-16 |
| `project.capabilities` / target `capabilities` | Mapping | Execution worker constraints: `os`, `arch`, `toolchain`, and `runtime` |
| `adversarial_review.rounds` | Integer | Number of adversarial review rounds to run before grading; omit or set `0` to disable |
| `review_notes.criteria` | Array of strings | High-signal interests for the Review Notes pass |
| `review_notes.low_signal` | Array of strings | Low-signal guidance for the Review Notes pass |
| `visual_review.enabled` | Boolean | Enable or disable browser-based visual review for this repository |
| `visual_review.rounds` | Integer | Number of visual review rounds to allow before grading |
| `visual_review.when_files_changed` | Array of globs | Only run visual review when matching files changed |
| `preview` | Mapping | Commands and metadata used by the preview action and visual review |
| `hooks.post_checkout` | Array of strings | Shell commands the CLI runs after `syrus checkout` succeeds |

Project and target capabilities are normalized when Syrus plans primary
execution placement before launching a Job's workflow. Jobs store the planned
project or target label when known, the capability requirements, and whether
the placement was inferred, explicitly requested, or defaulted. Each Workflow
snapshots that plan when it is created, so later `.syrus.yml` edits do not move
work that is already in flight. Jobs without a stored plan use the ordinary
Linux/default execution class. Direct Job API calls and chat proposal cards can
set an explicit planned execution requirement, and the chat proposal tools
require one. Capabilities are declared, never guessed from the request text: a
Job created without them runs on the repository's `.syrus.yml` project
capabilities when it declares any, and the ordinary Linux default otherwise.
Supported dimensions are `os`, `arch`, `toolchain`, and `runtime`. `os` accepts
`linux` or `macos`; the other dimensions accept normalized tokens such as
`arm64`, `xcode`, and `ios_simulator`.

For iOS repositories, model the app as a project with `capabilities.os: macos`
plus `arch: arm64`, `toolchain: xcode`, and `runtime: ios_simulator`, then put
`xcodebuild` details in the target or grader command: explicit workspace or
project, scheme, simulator destination, isolated DerivedData, result bundle and
optional JUnit paths, plus no-signing settings for simulator tests.
With the iOS plugin enabled, common patterns can use typed graders instead of
hand-written shell:

```yaml
prepare:
  - swift package resolve

grade:
  - type: xcodebuild
    workspace: apps/ios/MobileApp.xcworkspace
    scheme: MobileApp
    destination: "platform=iOS Simulator,name=iPhone 16,OS=latest"
    derived_data_path: .syrus/DerivedData/ios
    result_bundle_path: build/syrus/ios/MobileApp.xcresult
    junit_output: build/syrus/junit/ios-tests.xml
    timeout_minutes: 45

  - type: swiftpm
    package_path: apps/ios/Packages/Shared
    build_path: .syrus/DerivedData/swiftpm-shared
    timeout_minutes: 20
```

When proposing an iOS-only Job or mixed iOS/backend Job whose implementation
needs Xcode feedback, set primary planned execution to
`{"capabilities":{"os":["macos"],"arch":["arm64"],"toolchain":["xcode"],"runtime":["ios_simulator"]}}`;
backend graders can still declare `capabilities.os: linux` and run on Linux
workers later.

Because nothing is inferred from a Job's wording, mentioning a platform in a
title or description does not move the work — including saying that a platform
is out of scope. Ask for `macos` only when the work genuinely needs a Mac, such
as an Xcode build or an iOS simulator; a Job planned for a host no worker
advertises cannot start at all.

Workers advertise their available host capabilities separately from repository
requirements. Each worker heartbeat includes normalized capabilities plus
diagnostics about host architecture and optional probes for Docker, Xcode, and
iOS simulator runtimes. Android work runs on Linux workers, not an `os:android`
placement class. The published worker image includes the Android SDK
command-line baseline used by the Android plugin, while Java/JDK and Gradle
behavior stay with the JVM plugins and repository wrappers. Set
`SYRUS_WORKER_CAPABILITIES` on a worker to make its placement class explicit:

```dotenv
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
```

Use comma or space separated `dimension:value` pairs if needed, but only
`os:linux` and `os:macos` are admitted for OS placement. Unknown dimensions and
unsupported OS values are ignored for worker advertisements. Linux k3s and
Docker Compose workers normally get `os:linux` and host architecture without
configuration.

Android emulator-backed graders and Runtime Sessions need more than the SDK.
The Linux host must expose CPU virtualization and KVM, and the worker container
or pod must be allowed to read and write `/dev/kvm`. On Docker Compose that is
typically a worker device mapping such as `/dev/kvm:/dev/kvm`; on Kubernetes it
usually means scheduling onto KVM-capable nodes and exposing the device through
your runtime class, device plugin, or pod security policy. If this is missing,
non-emulator Android builds can still pass, but emulator launches fail with
messages like `/dev/kvm: Permission denied`, `KVM is required to run this AVD`,
or `x86 emulation currently requires hardware acceleration`.

After implementation, Syrus compares the actual changed files against the
target graph as a safety net. If the diff affects a more constrained target
than the implementation workflow was planned for, Syrus records an
`implementation_capability_escalation` workflow warning instead of silently
moving the mutable workspace across platforms. Treat that warning as a prompt
to retry or continue through an explicit checkpoint or handoff on a capable
worker, split the work by platform, or confirm that target-specific graders
fully validate the change.

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

`adversarial_review.rounds` is optional and applies to Initial and feedback
workflows. When it is greater than zero, Syrus runs independent review
rounds before the normal grade loop. A reviewer verdict of `needs_work`
feeds another implement/respond iteration; an `approved` verdict exits the
loop early.

`adversarial_review.criteria` adds repository- or project-specific focus
areas to the reviewer prompt. Root `.syrus.yml` criteria apply repo-wide. In
monorepos, nested `.syrus.yml` files can declare their own criteria, and Syrus
adds those project criteria only when the diff under review touches that
project directory. Identical criteria are shown once.

The workflow chain is created before the workspace clone exists, so Syrus
reads this setting from `.syrus.yml` on the repository's default branch. If
the file or setting is absent, adversarial review is disabled.

### `review_notes`

When the Review Notes plugin is enabled, `review_notes.criteria` and
`review_notes.low_signal` tune which changed ranges the reviewer should flag.
The setting changes selection, not the submission contract: the agent should
still submit an empty notes array when nothing deserves attention.

Root `.syrus.yml` Review Notes policy applies repo-wide. In monorepos, nested
`.syrus.yml` files can declare their own policy; Syrus merges the root policy
with every affected nested project touched by the final diff review version
and de-duplicates identical entries.

### `visual_review`

`visual_review` controls the browser-based reviewer. When enabled, Syrus
starts a repository preview, lets a read-only reviewer inspect the changed
UI, captures screenshots, and records a structured verdict. `skipped` is a
successful outcome for changes that are not visually testable.

Use `when_files_changed` to keep visual review focused on UI paths:

```yaml
visual_review:
  enabled: true
  rounds: 1
  when_files_changed:
    - "app/frontend/**/*"
    - "app/views/**/*"
```

### `preview`

`preview` tells Syrus how to boot the repository in development mode for
manual preview and visual review. Syrus assigns `$PORT` dynamically and
proxies preview traffic through the Syrus host.

```yaml
preview:
  setup:
    - bundle install
    - npm ci
  start: bin/rails server -p $PORT -b 0.0.0.0 -e development
  seed: bin/rails db:prepare db:seed
  health_check: /up
```

In monorepos, nested `.syrus.yml` files can define their own `preview` blocks.
Syrus scopes those preview commands to the project directory that declared
them. On a Job detail page, one affected previewable project starts directly;
multiple affected previewable projects show a selector; and changes that do not
touch a previewable project show a clear no-preview message. A root-only
repository keeps the original root preview behavior.

### `grade`

`grade` defines checks Syrus runs after agent work. Syrus runs the command
exactly as configured. Framework plugins can also define typed graders such as
`type: rspec` or `type: minitest`; those expand into focused review, landing, and CI variants with
framework-aware commands and base-revision retry metadata. Use custom
`run:` commands when a plugin-defined grader cannot express a repository's
test command yet.

`phases` controls where a grader runs:

| Phase | Used for |
| --- | --- |
| `review` | Pre-review checks after implementation or feedback |
| `landing` | Final landing checks before merge |
| `ci` | CI-failure repair and main-branch health checks |

If `junit_output` is present, Syrus ingests test cases for the Tests UI and
for failure comparison. `failures: allow_inherited` lets a grader pass when
Syrus can attribute the same test failures to the known base instead of the
current Job branch. Binary graders without test-case output still fail
strictly unless they are explicitly marked optional.

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
`syrus checkout EPIC-<number>` successfully switches branches. The CLI runs
each hook in order from the directory that declares it, uses `sh -c`,
streams output to the terminal, and fails fast on the first non-zero exit. Pass
`--no-hooks` to bypass hooks for one checkout:

```bash
syrus checkout --no-hooks JOB-<id>
syrus checkout --no-hooks EPIC-<number>
```

When a post-checkout hook fails, the CLI prints the failed command and
exit code, then exits non-zero. The checkout itself is not rolled back:
fix the local problem and rerun the command manually, or run checkout
again with `--no-hooks` if you only need the branch.

In monorepos, nested `.syrus.yml` files can declare their own
`hooks.post_checkout` commands. Root hooks always run for the whole
repository. Nested project hooks run only when the checked-out Job or
branch diff touches files under that project directory; if the CLI cannot
compute the diff, it runs all discovered project hooks and logs the
fallback.

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
| GitHub token | Used to list issues, read PRs, push branches, open PRs, edit `.github/workflows/*`, and post updates for that user's repositories. Fine-grained PATs need repository access for the managed repositories with Contents, Pull requests, and Workflows read/write plus Checks read; classic PATs need `repo` for private repositories or `public_repo` for public repositories, plus `workflow` when agents must edit GitHub Actions workflow files through the PAT. Configured on `/credentials` |
| Agent provider | Default provider for new Jobs, selected from enabled agent-provider plugins such as `claude`, `codex`, `agy`, or `muse`; configured on `/settings/agent` |
| Agent provider failover | Disabled-by-default ordered list of alternate agent providers plus eligible causes (`usage_exhausted`, `usage_low`, `rate_limited`, `provider_transient`, `auth_error`); configured on `/settings/agent` |
| Chat provider | Optional provider override for chat turns, selected from enabled chat-provider plugins such as `claude`, `codex`, `agy`, or `muse`; when blank, chat follows the user's default agent provider |
| Claude credential | Encrypted long-lived Claude OAuth token from the Claude authorization flow or `claude setup-token`, passed to Claude Code as `CLAUDE_CODE_OAUTH_TOKEN`; configured on `/credentials` |
| Generic scoped credential | Encrypted write-only payload owned by the `credential_store` plugin, with safe metadata, target constraints, last-used audit metadata, and user/repository/team/instance scope; default type names include `ssh_private_key`, `token`, `json`, `env`, and `file_blob`, while plugins can add names such as `k8s_cluster.kubeconfig`; managed from Credential Store in the sidebar or Admin > Credential Store |
| Codex credential | Encrypted Codex API key or ChatGPT login auth JSON, depending on auth mode; configured on `/credentials` |
| Antigravity credential | Encrypted Gemini API key shared by Antigravity and Gemini-backed features such as walkthrough-video analysis; configured on `/credentials` |
| Muse credential | Encrypted Muse API key, passed to Muse Code on stdin for probes and agent runs; created in the Muse developer dashboard and configured on `/credentials` |
| Agent max turns | Per-run cap for Claude Code tool-use turns; `0` means no `--max-turns` flag; configured on `/settings/agent` |
| Theme | Light or dark app chrome, toggled from the account area and persisted per user |
| Scheduling paused | Skips scheduled task firing for that user; configured on `/settings/preferences` |
| Recent chats group size | Number of chats shown per repository (and General) group in the chat sidebar before "Show more" appears; 1-50, defaults to 10; configured on `/settings/preferences` |
| Desktop notifications | Per-type desktop banner toggles for implemented and failed Jobs; configured on `/settings/preferences` |
| Admin API token | Admin-only bearer token for `/api/v1/admin/*` diagnostics, including Jobs, Runs, queue/processes, and chat transcripts; shown once on rotation from `/credentials` |
| Memories | Persistent agent context owned by the user; repository-scoped memories can be published from the Memories settings panel |

The **Credentials** page includes a per-credential **Test** action after a
secret is saved. GitHub PAT tests call GitHub as the user and report the
authenticated login plus token scopes. Claude, Codex, Antigravity, and Muse
tests run short CLI auth probes through the same credential paths used by Jobs
and chats, so expired or mis-shaped agent credentials surface before a
downstream run fails.

Muse keys begin with `LLM|` and are shown only once at creation, with no later
reveal or rotation. If you signed in with a Muse subscription through `muse
login` and no longer have the key, recover it from the CLI's own credential
store and paste the whole JSON entry into the Muse field; Syrus keeps only the
API key from it and discards any account token stored alongside. The account
login itself cannot be used for agent runs, which is why the key is required
separately.

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

Agent-provider failover is configured separately from provider selection and
applies only when Syrus is about to admit unstarted workflow work. The policy
stores an ordered provider list, but Syrus only considers providers the user has
actually configured credentials for. Auth errors are represented as a cause for
visibility, but they are not enabled in the default automatic failover cause
list. Explicit Job provider pins are respected unless the separate
`override_explicit_pins` policy setting is enabled.

When automatic failover selects another provider, dashboard rows, Job detail,
and Workflow cards show the original unavailable provider and the selected
provider, for example "Claude Code unavailable; running this workflow with
Codex." App payloads expose this as `provider_failover` with `mode`,
`automatic`, original/selected provider labels, decision time, reason, and an
`unavailable` summary containing state, retry/reset timing, evidence source,
and observed time when available. Operator-selected alternate retry providers
use `mode: operator` copy instead of automatic-unavailability copy. Chat
provider failover is out of scope: this policy does not rewrite
`ChatSession#chat_provider` or enqueue chat-provider switch jobs.

Syrus ships with a global concurrency cap for fresh instances:
`AppSetting.max_concurrent_agent_runs` defaults to `3`, so autonomous agent
work cannot scale linearly with worker pods. The optional per-user USD budget,
`AppSetting.user_daily_spend_budget_usd`, defaults to `0` (unlimited). When
set to a positive value, the gate defers queued work until the next day
instead of failing Jobs once provider-reported workflow Run costs and chat turn
costs reach the ceiling. Run accounting uses provider-reported `Run#cost_usd`
when available and leaves cost unset when a provider reports token usage
without a dollar cost, so subscription-based or token-only providers may need
provider-side limits for reliable spend protection. Repo-level and Epic-level
dollar budgets are still roadmap work; use provider-side limits and the
per-user max-turns setting as additional safety rails.

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

The Inbox smart folder on the dashboard follows this policy too: it surfaces
a Job to any user whose approval would actually satisfy the job's review
policy, not just the job's owner. Under `two_person` that means any other
user; under `final_say` that means the owner plus the repository's
designated final approvers.

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

Set a repository's review policy from its settings page (**Repository ->
Edit -> Automation -> Review policy**). Choosing `final_say` reveals a
**Final approvers** section on the same page where a repo admin can add or
remove final approvers by email. A repository may have any number of final
approvers; only one needs to approve a given Job. Managing this list
requires `admin`-tier access on the repository (the same tier required to
edit repository members), and is also available through the
`/api/v1/app/repositories/:id/final_approvers` endpoints.

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
from repository members are acted on automatically or require confirmation.
External reviewers always require confirmation before Syrus spends an owner-billed
workflow on their comment.

| Policy | Behavior |
| --- | --- |
| `confirm` (default) | Only the job owner's actionable comments trigger automatic implementation; team member and external actionable comments are recorded but do not queue a workflow until confirmed by the operator |
| `auto` | Actionable comments from the job owner and repository members queue an implementation workflow automatically; external comments are recorded for operator review |

### Comment attribution

Syrus classifies each new PR comment by commenter:

- **Job owner** — the GitHub handle matches the job's owner user. Owner comments always queue automatically regardless of `feedback_policy`.
- **Team member** — the handle matches a repository membership. Member comments respect `feedback_policy`.
- **External** — the handle is not found in memberships and is not the owner. External comments require operator confirmation.

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
| `SYRUS_WORKER_POOL_NAME` | External worker optional | Operator-facing pool label recorded in worker capability diagnostics, such as `macos-xcode` |
| `SYRUS_WORKER_CAPABILITIES` | Worker optional | Comma or space separated capability advertisement for `os`, `arch`, `toolchain`, and `runtime` |
| `SYRUS_GITHUB_REPO` | Yes | GitHub `owner/repo` slug for this Syrus installation's own repository; used for build revision links |
| `SYRUS_BUG_REPORT_OWNER` | Yes | GitHub owner or organization for in-app bug reports; Syrus uses the configured `syrus` repository under that owner |
| `SYRUS_MAILER_FROM` | No | From address for password reset and invitation email; defaults to `Syrus <noreply@$SYRUS_APP_HOST>` |
| `SYRUS_ALERT_WEBHOOK_URL` | No | JSON webhook URL for alarm-severity SystemAlerts; repeated alerts are deduplicated by dismissal key |
| `SYRUS_ALERT_EMAIL_TO` | No | Comma-separated email recipients for alarm-severity SystemAlerts |
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

Generic plugin-managed credentials live in the bundled `credential_store`
plugin, which stores payloads as encrypted blobs and keeps only safe display
metadata outside the encrypted payload. The plugin also exposes brokered MCP
tools for controlled credential use, including SSH command execution backed by
`ssh_private_key` leases, temporary key files, target constraints, redaction,
and audit rows. The encrypted values live in the primary database. The
encryption keys can come from Rails credentials via `RAILS_MASTER_KEY`, or
directly from the `ACTIVE_RECORD_ENCRYPTION_*` environment variables. Any
process that reads or writes encrypted credentials needs one complete, stable
key source. This is why smoke tests or console sessions that create users fail
loudly when encryption keys are missing.

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

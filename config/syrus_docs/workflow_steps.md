# Workflow Steps

Each Syrus workflow is a chain of steps. Steps are either **agentic** (invoke the agent CLI) or **non-agentic** (run service code directly). Step kinds are registered in `app/models/step/kind.rb`.

## Setup steps

### prepare

Non-agentic. Runs the commands from `.syrus.yml` `prepare:` (or auto-detected from lockfiles) in the cloned workspace. Explicit commands hard-fail on error; auto-detected commands soft-fail with a warning so a wrong guess doesn't block the first run. Per-timeout: 10 minutes per command.

Present in: `initial`, `pr_comment`, `chat_feedback`, `ci_failure`, `retry`, `auto_merge`, `merge_train`, `coding_handoff`.

## Agentic implementation steps

Each Workflow stores a concrete `agent_provider` when Syrus creates it, and
retrying a failed Step inside that Workflow keeps using the pinned provider.
Each Job also has a future-workflow provider setting: `default`, `claude`, or
`codex`. `default` resolves the current repository/user default at workflow
creation time; explicit values pin newly-created workflows for that Job to the
selected provider.

Operator-triggered retry-with-provider actions are one-shot overrides. They
create that retry or follow-up Workflow with the requested provider, but they do
not rewrite the Job's future-workflow provider setting or any existing Workflow
pin.

### implement

Agentic. The primary coding step: the agent reads the issue, explores the repo, writes code, and commits. Used in initial and retry workflows.

**No-change outcome:** When the agent runs successfully but produces no diff (it correctly determined the requested work was already done), the step raises `Steps::Base::NoChangesProduced`. The workflow fails as normal, but `propagate_fail_to_job!` detects this error class and transitions the Job to `:no_change_needed` instead of `:failed`. The `:no_change_needed` state is semi-terminal — the operator can close the Job (the work was indeed already done) or give feedback (the agent may have missed something). Retry actions are suppressed; this outcome is non-retryable by the auto-retry scheduler.

**Provider usage-limit outcome:** If the provider reports exhausted usage, quota, credits, billing balance, or a daily/weekly/monthly/model limit, the run records `agent_outcome=provider_usage_limit` and failure classification `provider_usage_limit`. The provider circuit breaker opens immediately for the affected provider/model when known; if the model cannot be determined, Syrus fails closed at provider scope and shows that reason to the operator. When the provider reports a reset time, Syrus schedules the failed Run's auto-retry for five minutes after that reset; Codex structured usage reset windows are preferred over parsing log text, while provider text such as `resets 7am (America/New_York)` is parsed from the failure time. If no reset is known, Syrus uses the conservative provider-circuit backoff. The app projects current-user provider availability into chat and Job payloads: chats using the exhausted effective chat provider and Jobs using the exhausted agent provider show a red triangle warning until the usage-limit window expires/restores or the operator switches that chat/Job to another configured provider. Transient provider circuits remain separate and use the existing non-red treatment.

### respond

Agentic. Addresses PR review feedback or chat feedback. Reads the new comments and makes the requested changes.

### analyze_and_fix

Agentic. Inspects failing CI checks and fixes the root cause. Used in `ci_failure` workflows.

### landing_fix

Agentic. A focused repair step inside `auto_merge` and `merge_train` workflows. Runs only after final graders fail on the exact PR branch being landed; successful repairs are pushed before the merge API call.

### manual

Agentic. Operator-triggered free-form step; prompt is supplied at dispatch time.

## Review and quality steps

### adversarial_review

Agentic. An independent reviewer agent critiques the implementation, calls `submit_adversarial_review` with a verdict and findings, and any workspace changes it makes are discarded. Runs in a bounded loop before graders when `adversarial_review.rounds > 0`.

### grader_fanout

Non-agentic. Reads grader definitions from `.syrus.yml` and materializes one `grader` Step per configured grader command. Run once at the start of each check cycle.

Grader materialization remains sequential within the current workflow workspace.
Landing-specific fanout is not enabled; any future design needs isolated
workspaces for grader side effects before multiple grader Runs can overlap.

### grader

Non-agentic. Runs a single grader command (e.g., `bin/rspec`). Required graders must pass; non-required graders warn on failure.

Syrus does not mutate grader commands for specific test frameworks. If a command needs multiple formatters, coverage toggles, parallelization, or CI-only filtering, put that policy in `.syrus.yml` or a repository wrapper script such as `bin/rspec-fast`.

When a grader defines a `.syrus.yml` `fast:` command, Syrus uses that alternate command in pass/fail-only validation contexts: `main_branch_repair`, `auto_merge`, `merge_train`, and implementation/feedback/coding grade-loop iterations after the first. If `fast:` is absent, the normal `run:` command is used.

When a grader defines a `.syrus.yml` `ci:` command, Syrus uses it in `ci_failure` workflows so CI-only checks can run when the workflow is specifically repairing a failed CI signal. If `ci:` is absent, `ci_failure` workflows fall back to `run:`, not `fast:`. `main_grader` workflows also prefer `ci:` when it is configured, because main-branch health should match the checks that can fail in GitHub CI; for graders without `ci:`, `main_grader` falls back to `fast:` and then `run:`.

### grader_collect

Non-agentic. Aggregates grader results. Fails the check cycle if any required grader failed; succeeds otherwise.
Failed collect steps still write grader loop timing before raising, so landing
repair loops show whether the failed attempt actually spent time running graders.

### grade

Non-agentic. Legacy single-grader step; prefer `grader_fanout`/`grader`/`grader_collect` for new workflows.

## Summary and PR steps

### summarize

Agentic. Asks the agent to call `submit_summary` with a PR title, body, and operator-facing summary. Skipped if `implement` already called `submit_summary`.

### summarize_amend

Agentic. Same as `summarize` but used after `respond` or `analyze_and_fix` to update the existing PR description.

### test_plan

Agentic. Asks the agent to call `submit_test_plan` with reviewer-facing test steps. Skipped if `implement` already called `submit_test_plan`. Follows `summarize` in initial workflows.

### pr_open

Non-agentic. Pushes the branch and opens the PR using the title/body from workflow artifacts. Falls back to `PrSummarizer`, then to a templated default if no agent-authored copy is available.

## Push and rebase steps

### push

Non-agentic. Pushes the PR branch. On a non-fast-forward rejection, fetches and attempts a deterministic rebase, retrying the push if clean. If the rebase conflicts, dynamically inserts `push_agent_rebase` → grader repair loop → `push_after_rebase`.

### push_agent_rebase

Agentic. Resolves a rebase conflict mid-push-chain.

### push_after_rebase

Non-agentic. Final push after a conflict-resolved rebase.

### auto_rebase

Non-agentic. Attempts a deterministic `git rebase` onto the base branch. On clean rebase, cancels `agent_rebase` and proceeds to `force_push`.

### agent_rebase

Agentic. Resolves rebase conflicts. Runs only when `auto_rebase` encounters conflicts.

### force_push

Non-agentic. Force-pushes with `--force-with-lease=<branch>:<observed_sha>` to prevent clobbering concurrent pushes.

### stack_auto_rebase / stack_agent_rebase / stack_force_push

Non-agentic / Agentic / Non-agentic. Same as the single-PR rebase chain but operates across a dependent PR stack in dependency order.

## Landing steps

### mergeability_preflight

Non-agentic. Refreshes GitHub mergeability, runs a local rebase preflight when GitHub is still computing, dispatches rebase workflows for conflicts, and short-circuits if a prior landing validation is still valid.

### auto_merge

Non-agentic. Calls the GitHub merge API. Transient failures defer the Job back to `approved`; a 405 "can't rebase" dispatches the rebase path instead of treating the attempt as terminal.

When a merge succeeds and GitHub returns a merge commit SHA, Syrus stores it as `Job#landed_sha`. `PollAllDeploymentStagesJob` later uses that SHA to detect configured deployment stages from repository tags.

### merge_train_assemble

Non-agentic. Validates that all open Epic child Jobs are approved and the member count is within `AppSetting.merge_train_max_size`.

### merge_train_build

Agentic. Rebases member branches onto a growing integration branch in dependency order. Tries deterministic `git rebase` first; hands conflicts to the agent on failure.

### merge_train_reconcile

Agentic. Runs on the built merge-train integration branch before prepare, graders, coverage, and landing. Asks the configured agent provider to inspect the integrated tree for cross-Job inconsistencies. No diff is a successful result; focused reconciliation edits are committed onto the integration branch and then the normal gates continue.

### merge_train_land

Non-agentic. Pushes the integration branch, merges one integration PR into base, then comments on and closes the member PRs.

### merge_train_rebase / merge_train_land_after_rebase

Non-agentic. Recovery chain when the base branch moves during merge-train landing.

## Coverage steps

### coverage_analyze

Non-agentic. Parses coverage artifacts produced by graders, merges multiple sources, computes diff annotations against the PR diff, stores a coverage artifact on the workflow, attaches a hit-map blob, creates a `CoverageSnapshot`, and evaluates the configured threshold.

### coverage_pr_comment

Non-agentic. Posts the formatted coverage summary as a PR comment when `pr_comment: true` is set in `.syrus.yml`.

## Preflight grader steps (main_branch_repair)

### preflight_grader_fanout

Non-agentic. Materializes one `preflight_grader` Step per configured grader at the start of a `main_branch_repair` workflow. Unlike `grader_fanout`, this step:

- Runs **all** configured graders regardless of `when_files_changed` (no PR diff exists before the implement step)
- Does **not** check the `GraderConclusionCache` for reuse (always runs fresh)
- Is not inside a retry loop (no `apply_loop_max_iterations!`)

### preflight_grader

Non-agentic. Identical to `grader` but writes logs to `.syrus/grade-output/preflight/<name>.log` to avoid collisions with the main grade loop's per-iteration log files.

### preflight_grader_collect

Non-agentic. Aggregates preflight grader results. Two outcomes:

- **All required graders passed:** Sets the `preflight_passed` workflow artifact, cancels all downstream steps (`prepare`, `implement`, the grade loop, `summarize`, `test_plan`, `pr_open`), and returns. The dispatcher advances past the cancelled steps and marks the workflow succeeded. `Workflows::MainBranchRepair#after_success` detects the artifact and marks the repository healthy without the agent ever running.
- **Any required grader failed:** Logs the failure and returns normally so the chain continues to `prepare → implement`.

Unlike `grader_collect`, this step never raises `StepFailed` — a grader failure here means "proceed to implement", not "fail the workflow."

## Coding handoff steps

### grader_fanout / grader_collect

Same as above, but used in `coding_handoff` workflows without a repair loop — graders must pass on the first attempt.

### apply_suggestions

Non-agentic. Applies structured code-suggestion patches (e.g., from review comments) before the agent responds.

## Step resilience: in-place worker_died retry

When a worker process is killed mid-step (deploy rolling restart, OOM, node eviction), the run is classified as `worker_died`. For **non-agentic** steps (e.g., `prepare`, `push`, `grade`, `auto_merge`), Syrus creates a new Run on the same Step instead of immediately failing it. This repeats up to `Run::WORKER_DIED_STEP_MAX_RETRIES` (3) times before the step fails normally and the operator sees the Retry button.

**Agentic steps** (e.g., `implement`, `respond`) do not use in-place retry. They use `AutoRetryScheduler`'s session-resume path so the agent can pick up where it left off with prior conversation context intact.

When the `unified_work_engine_reconciler` feature flag is enabled,
`AutoRetryScheduler` does not create `AutoRetryAttempt` rows itself. It defers
to `WorkEngine::Reconciler` so retry classification and remediation stay under
the unified work-engine authority. With the flag off, auto-retry behavior is
unchanged.

The in-place retry count is per-step per-workflow, not per-job. Each step failure classification is persisted as a `RunFailureClassification` row so the reaper and `RunJob` can accurately count prior retries.

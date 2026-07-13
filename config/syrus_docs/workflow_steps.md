# Workflow Steps

Each Syrus workflow is a chain of steps. Steps are either **agentic** (invoke the agent CLI) or **non-agentic** (run service code directly). Step kinds are registered in `app/models/step/kind.rb`.

## Setup steps

### prepare

Non-agentic. Runs the commands from `.syrus.yml` `prepare:` (or auto-detected from lockfiles) in the cloned workspace. Explicit commands hard-fail on error; auto-detected commands soft-fail with a warning so a wrong guess doesn't block the first run. Per-timeout: 10 minutes per command.

Present in: `initial`, `pr_comment`, `chat_feedback`, `ci_failure`, `retry`, `auto_merge`, `merge_train`, `coding_handoff`.

## Agentic implementation steps

### implement

Agentic. The primary coding step: the agent reads the issue, explores the repo, writes code, and commits. Used in initial and retry workflows.

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

### grader

Non-agentic. Runs a single grader command (e.g., `bin/rspec`). Required graders must pass; non-required graders warn on failure.

### grader_collect

Non-agentic. Aggregates grader results. Fails the check cycle if any required grader failed; succeeds otherwise.

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

### merge_train_assemble

Non-agentic. Validates that all open Epic child Jobs are approved and the member count is within `AppSetting.merge_train_max_size`.

### merge_train_build

Agentic. Rebases member branches onto a growing integration branch in dependency order. Tries deterministic `git rebase` first; hands conflicts to the agent on failure.

### merge_train_land

Non-agentic. Pushes the integration branch, merges one integration PR into base, then comments on and closes the member PRs.

### merge_train_rebase / merge_train_land_after_rebase

Non-agentic. Recovery chain when the base branch moves during merge-train landing.

## Coverage steps

### coverage_analyze

Non-agentic. Parses coverage artifacts produced by graders, merges multiple sources, computes diff annotations against the PR diff, stores a coverage artifact on the workflow, attaches a hit-map blob, creates a `CoverageSnapshot`, and evaluates the configured threshold.

### coverage_pr_comment

Non-agentic. Posts the formatted coverage summary as a PR comment when `pr_comment: true` is set in `.syrus.yml`.

## Coding handoff steps

### grader_fanout / grader_collect

Same as above, but used in `coding_handoff` workflows without a repair loop — graders must pass on the first attempt.

### apply_suggestions

Non-agentic. Applies structured code-suggestion patches (e.g., from review comments) before the agent responds.

---
title: Troubleshooting
description: Symptoms, likely causes, and fixes for common Syrus failures.
---

# Troubleshooting

Start from the Job page when you can. It shows the Workflow, each Step,
each Run, the live transcript, and the diff Syrus captured.

Use deployment logs for process-level failures:

```bash
# Docker Compose
docker compose logs -f worker
docker compose logs -f web

# Kubernetes
kubectl -n <namespace> logs -f deployment/syrus-worker -c syrus-worker
kubectl -n <namespace> logs -f deployment/syrus-web -c syrus-web
```

The transcript you usually want is in the Syrus UI, not raw container
stdout.

## The poller never picks up my issue

Symptoms:

- No Job appears after you add the trigger label.
- The repository page shows no recent ingestion activity.
- Worker logs do not show a new `PollRepositoryJob` result for the issue.

Likely causes:

- The repository is not registered under the same owner/name as GitHub.
- Repository polling is disabled.
- The issue is closed, is a pull request, has `syrus-skip`, or is missing
  the repository's trigger label.
- The user's GitHub token cannot read the repository.
- The default queue worker is not running.

Fix:

1. Confirm the repository slug and polling setting in Syrus.
2. Confirm the GitHub issue is open and has the configured trigger label.
3. Remove `syrus-skip` if it was added by mistake.
4. Use the repository page's GitHub issues panel to delegate the issue;
   that applies the label through the same token Syrus uses.
5. Check worker logs:

   ```bash
   kubectl -n <namespace> logs deployment/syrus-worker -c syrus-worker --tail=300
   ```

Expected result: Syrus creates a Job and starts an `initial` Workflow.

## The prepare Step fails

Symptoms:

- The Workflow stops before the agent starts.
- The transcript shows dependency installation, build, or database setup
  errors.
- The same repository works locally but fails in Syrus's fresh workspace.

Likely causes:

- `.syrus.yml` is missing a command needed by a fresh clone.
- Auto-detection chose only the first matching command, such as
  `bundle install` in a repo that also needs `npm ci`.
- The command depends on local state, prompts for input, or expects
  secrets that are not available to the worker.
- A Rails command needs `RAILS_MASTER_KEY` because it touches encrypted
  attributes.

Fix:

1. Add explicit setup commands to the target repository's `.syrus.yml`.
2. Keep commands deterministic and non-interactive.
3. Put dependency caches inside the workspace when needed, for example:

   ```yaml
   prepare:
     - bundle config set --local path vendor/bundle
     - bundle install --jobs 4
     - npm ci
   ```

4. If the repository truly needs no setup, use `prepare: []`.
5. Retry the Workflow after the setup change lands.

Expected result: the `prepare` Step succeeds and the agentic Step starts.

## The agent provider cannot start

Symptoms:

- A Run fails immediately, before repository exploration.
- The transcript mentions missing Claude, Codex, API, OAuth, or auth JSON
  credentials.
- Switching providers made new Jobs fail while old Jobs still run.

Likely causes:

- The user has not configured credentials for the selected provider.
- A repository provider override points at a provider the user cannot use.
- `RAILS_MASTER_KEY` is missing, so encrypted provider credentials cannot
  be decrypted.
- The worker image does not include the configured agent CLI.

Fix:

1. Check the user's credentials page for the selected provider.
2. Check the repository's provider override and clear it if the user
   default should apply.
3. Confirm web and worker processes have `RAILS_MASTER_KEY`.
4. Restart the worker after changing deployment-level secrets.
5. Create a small new Job to confirm the provider starts.

Expected result: the Run transcript reaches normal repository discovery
and tool use.

## The agent ran but produced no diff

Symptoms:

- The agentic Step succeeds, but `pr_open` says there is no diff.
- The Job closes as no changes, or no PR is opened.
- The transcript contains a final answer but no file edits.

Likely causes:

- The prompt did not ask for a concrete repository change.
- The agent decided no change was appropriate.
- Setup or test failures consumed the run.
- The requested behavior already exists.

Fix:

1. Read the final answer and last tool calls in the Run transcript.
2. If the prompt was broad, create a narrower follow-up with files,
   behavior, and tests.
3. If setup failed, fix `.syrus.yml` before retrying.
4. For scheduled Jobs, decide whether no changes is an acceptable
   success and phrase the prompt accordingly.

Expected result: a retry or follow-up either produces a diff or records a
clear no-change outcome.

## A grader failed but the Workflow still passed

Symptoms:

- A `grader` Step shows failure output.
- The Workflow still proceeds to summarization or PR opening.
- The agent is not asked to repair the failed check.

Likely causes:

- The grader is marked `required: false`.
- The failure came from an advisory grader.
- The grader configuration is not in the shape Syrus expects.

Fix:

1. Open `.syrus.yml` and inspect the grader entry.
2. Set `required: true` or remove the field, since required is the
   default.
3. Confirm the command is under `grade.steps`:

   ```yaml
   grade:
     steps:
       - name: tests
         run: bin/rspec
         required: true
   ```

4. Trigger a small Job and confirm required failures enter the repair
   loop.

Expected result: required grader failures fail `grader_collect` and
append a bounded repair iteration.

## The agent never handles my failing CI check

Symptoms:

- GitHub Checks fail on a Syrus PR, but no `ci_failure` Workflow appears.
- PR feedback handling still works.
- Worker logs mention check-run permission errors or show no check runs.

Likely causes:

- The PR is not associated with an open Syrus Job.
- The CI provider does not report GitHub Checks for the PR head SHA.
- The check run did not finish with a failed conclusion.
- The user's token cannot read check runs.
- The Job already hit the rolling cap of three `ci_failure` Workflows per
  24 hours.

Fix:

1. Confirm the PR was opened by Syrus or is attached to an open Syrus Job.
2. Confirm GitHub shows a completed failed check on the current PR head.
3. Give the token repository access plus Checks read access.
4. Wait for the PR poller, or use the Job's manual check action when
   available.
5. If the cap was hit, fix the repeated failure manually or wait for the
   24-hour window to move.

Expected result: Syrus creates a `ci_failure` Workflow:

```text
prepare -> analyze_and_fix -> summarize_amend -> push
```

## PR creation failed

Symptoms:

- The agent produced a diff, but no GitHub PR appears.
- The `pr_open` Step fails.
- The transcript shows a Git push or GitHub API error.

Likely causes:

- The GitHub token cannot push to the repository.
- The configured default branch does not exist.
- Branch protection or organization policy blocks the push.
- A branch with the same Syrus branch name already exists in an
  unexpected state.
- The agent produced no diff.

Fix:

1. Open the `pr_open` Step transcript and read the Git or GitHub error.
2. Confirm the user's token can push branches and open PRs.
3. Confirm the repository default branch in Syrus matches GitHub.
4. Resolve stale or conflicting Syrus branches in GitHub if needed.
5. Do not paste raw push logs containing token-bearing URLs into chat or
   tickets.

Expected result: Syrus pushes the branch and opens a PR against the
configured default branch.

## The PR is approved but will not merge

Symptoms:

- The Job is approved, but auto-merge does not land it.
- The PR becomes unmergeable or GitHub reports merge conflicts.
- The `auto_merge` Step fails with a mergeability or branch state error.

Likely causes:

- The base branch moved after the PR was approved.
- Required GitHub checks are still pending or failing.
- Auto-merge is disabled for the repository.
- GitHub branch protection blocks the selected merge path.
- The PR branch no longer matches the branch Syrus controls.

Fix:

1. Confirm repository auto-merge is enabled.
2. Check the PR's required GitHub checks and branch protection state.
3. Let merge-state polling create a `rebase` Workflow if the branch is
   unmergeable.
4. Re-approve or retry landing after rebase or final grader repair.
5. If GitHub returns a non-retryable merge error, resolve it manually and
   run the landing action again.

Expected result: Syrus either lands the PR or leaves the Job in an
operator-visible state with the failed landing Step.

## Rebase finished but force-push failed

Symptoms:

- `auto_rebase` or `agent_rebase` succeeds.
- The `force_push` Step fails.
- The transcript mentions `--force-with-lease` or an unexpected remote
  branch SHA.

Likely causes:

- Someone pushed to the PR branch after Syrus observed it.
- The PR branch is not controlled by Syrus.
- The remote branch was deleted or renamed.
- Repository policy blocks force-pushes for that branch.

Fix:

1. Compare the PR branch's current GitHub SHA with the SHA Syrus logged
   before rebase.
2. If a human pushed intentionally, decide whether to keep that work and
   start a fresh follow-up Workflow.
3. Restore or rename the expected branch if it was deleted.
4. Allow Syrus-controlled branches to be force-pushed, or rebase manually
   outside Syrus.

Expected result: the branch updates with an explicit force-with-lease, and
GitHub recomputes PR mergeability.

## How do I read the transcript?

Symptoms:

- You need to know what the agent did, which command failed, or why a Job
  closed.
- Container logs are too noisy to answer the question.

Where to look:

- The Job page renders each Run's transcript inline.
- Tool calls are hidden by default; use **Show tool calls** when you need
  commands and file edits.
- Admins can use:

  ```text
  /admin/runs/<run_id>/transcript
  /admin/runs/<run_id>/transcript/download
  ```

Notes:

- Inline transcript content is stored as `JobLog` rows.
- Provider JSONL transcripts may be retained while failed or cancelled
  runs are still useful to inspect.
- Succeeded transcripts may be pruned.

## How do I cancel a Job?

Symptoms:

- A Job is going in the wrong direction.
- A Run is consuming budget.
- You want PR comment and CI polling to stop for that Job.

Fix:

1. Open the Job.
2. Click **Cancel & close**.
3. Use the Run-level stop action instead if you want to stop only the
   active Run and keep the Job open for a retry.
4. For PR-level opt-out, add the `syrus-stop` label to the PR.

Expected result: active Runs are cancelled and follow-up polling stops
for the Job. If `syrus-stop` remains on the PR, reopening the Job will
not stick because the next PR poll closes it again.

## How do I retry a failed Workflow?

Symptoms:

- A Workflow failed because of a transient provider, setup, or test issue.
- You want to continue from the same branch.

Fix:

1. Use the failed Workflow's retry action when available.
2. Use **Run again** when you want a fresh follow-up Workflow on the same
   Job and branch.
3. Add replay context if the previous attempt failed for a specific
   reason.
4. If the workspace has already been cleaned up, use Run again or start
   over.

Expected result: retry-in-place reopens the failed Workflow and failed
Step, creates a new Run, and continues from the existing workspace.

## MySQL connection issues

Symptoms:

- Web or worker pods fail on boot.
- `db:prepare` succeeds for one database role but fails for cache, queue,
  or cable.
- Rails errors mention missing credentials, encryption keys, or database
  connections.

Likely causes:

- `DB_HOST` does not resolve inside the container or pod.
- `SYRUS_DATABASE_PASSWORD` is missing.
- `RAILS_MASTER_KEY` is missing.
- MySQL is not accepting connections from web or worker.
- Migrations have not run for primary, cache, queue, and cable.

Fix:

1. Confirm the required environment variables on web and worker.
2. Restart web and worker after the database is healthy:

   ```bash
   docker compose restart web worker
   ```

3. In Kubernetes, run a database check from the web pod:

   ```bash
   kubectl -n <namespace> exec deploy/syrus-web -- bin/rails runner 'puts ActiveRecord::Base.connection.select_value("select 1")'
   ```

4. Fix missing database roles instead of assuming primary migration means
   the whole app is prepared.

Expected result: web and worker boot, all Rails database roles connect,
and Solid Queue jobs can be enqueued and performed.

## Scheduled tasks are not firing

Symptoms:

- A cron or one-shot task does not create Jobs.
- The task previously worked and then stopped.
- The task page shows `paused`, `auto_paused`, `archived`, or `fired`.

Likely causes:

- The task is archived or not in `scheduled` state.
- The owning user's **Pause scheduling** setting is on.
- The cron expression does not match the current UTC hour.
- The previous scheduled PR is still open and `pr_pileup_policy` is
  `skip`.
- Repeated failures auto-paused the task.
- The default queue worker is not running `PollScheduledTasksJob`.

Fix:

1. Unarchive or unpause the task if appropriate.
2. Turn off the user's scheduling pause.
3. Check the cron expression in UTC; cron tasks can fire at most once per
   hour.
4. Close or merge the previous scheduled PR, or change pileup policy.
5. Fix the underlying prompt, credential, or repository failure before
   unpausing an auto-paused task.

Expected result: the next matching poll creates a `cron` Job.

## The agent burned through my Anthropic or OpenAI credits

Symptoms:

- A Run keeps using turns without converging.
- Scheduled tasks create too many PRs.
- Provider usage increases faster than expected.

Likely causes:

- The prompt is too broad.
- Agent max turns is too high for the repository.
- Scheduled tasks are allowed to pile up.
- Setup is under-specified, causing repeated dependency discovery.
- A noisy trigger keeps creating follow-up Workflows.

Fix:

1. Stop active work: cancel the Job or stop the active Run.
2. Lower **Max turns** under **My credentials**. The default is `200`.
3. Keep scheduled tasks on `skip` pileup unless parallel scheduled PRs are
   intentional.
4. Replace broad prompts like "clean up the repo" with a bounded file,
   failing test, warning, or subsystem.
5. Add `.syrus.yml` prepare commands so the agent starts from a prepared
   workspace.
6. Disable repository polling while you investigate noisy triggers.

Expected result: future Runs have a smaller turn budget and fewer
automatic entry points.

Repo-level and account-level dollar budgets are roadmap work. Until they
ship, max-turns, cancellation, prompt scope, and scheduled-task policy
are the practical controls.

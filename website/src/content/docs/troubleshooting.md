---
title: Troubleshooting
description: Common issues and how to debug them.
---

# Troubleshooting

Start from the Job page when you can. It shows the Workflow, each Step,
each Run, the live transcript, and the diff Syrus captured.

## The poller never picks up my issue

Check these in order:

1. The repository is registered in Syrus under the same owner/name as
   the GitHub repo.
2. Repository polling is enabled.
3. The GitHub issue is open. Syrus ignores closed issues and pull
   requests during issue ingestion.
4. The issue has the repository's trigger label. The default is `syrus`,
   but each repo can use a different label.
5. The issue does not have `syrus-skip`.
6. The user's GitHub token is present and can read the repository.
7. A worker is running the default queue, where
   `PollAllRepositoriesJob` and `PollRepositoryJob` run.

To force a quick check from the UI, open the repository in Syrus and use
the GitHub issues panel to delegate the issue. That adds the configured
trigger label through the same GitHub token Syrus will later use.

In Kubernetes, check the worker logs:

```bash
kubectl -n <namespace> logs deployment/syrus-worker -c syrus-worker --tail=300
```

In Docker Compose:

```bash
docker compose logs --tail=300 worker
```

## The agent never handles my failing CI check

Syrus reacts to completed GitHub Check Runs on PRs that belong to open
Syrus Jobs. It does not react to arbitrary PRs unless they are attached
to a Syrus Job.

Check:

1. The PR was opened by Syrus or is associated with an open Syrus Job.
2. The failing CI provider reports GitHub Checks for the PR head SHA.
3. The check run is completed with a failed conclusion such as `failure`,
   `timed_out`, `action_required`, `cancelled`, or `stale`.
4. The user's GitHub token can read check runs.
5. The Job has not already hit the rolling CI failure cap: three
   `ci_failure` Workflows per 24 hours.

If the token lacks Checks read access, PR-comment handling may still
work while CI-failure handling logs a permission warning.

## The agent ran but produced no diff

This usually means one of three things:

- The prompt did not ask for a concrete repository change.
- The agent decided no change was appropriate.
- The agent could not install dependencies, run tests, or write files in
  the workspace.

Open the Run transcript. Look for the last tool calls and the final
answer. If the agent spent most of the run discovering how to install the
project, add a `.syrus.yml` `prepare` section:

```yaml
prepare:
  - npm ci
  - npm test -- --runInBand
```

If the Workflow fails at the `prepare` Step, the agent has not started
yet. Open the prepare Step details to see the failed setup command, its
working directory, exit status, and the final output tail from the
installer or setup command.

For cron Jobs, no diff can be a successful result. Scheduled prompts
should explicitly say what counts as "nothing to do" so the agent can
close cleanly instead of inventing work.

## PR creation failed

Common causes:

- The GitHub token cannot push to the repository.
- The default branch configured in Syrus does not exist.
- Branch protection or organization policy blocks branch creation or
  pushes from the token.
- A branch with the same Syrus branch name already exists and is not in
  the state Syrus expects.
- The agent produced no diff, so there was no PR to open.

Check the `pr_open` Step transcript first. Syrus logs the Git command and
GitHub API error there. Also verify that the token-bearing push URL is
constructed only at push time; do not paste raw logs containing tokens
into chat or tickets.

## How do I read the transcript?

The Job page renders each Run's transcript inline. The full transcript
viewer parses retained Claude and Codex session JSONL into assistant
messages, tool calls, tool results, and system events where possible.
If the provider session is missing or truncated, Syrus includes the
Run's `JobLog` rows as fallback transcript events.

Admins also get a full transcript viewer:

```text
/admin/runs/<run_id>/transcript
/admin/runs/<run_id>/transcript/download
```

The inline transcript is stored as `JobLog` rows. Provider JSONL
transcripts may be retained for debugging while failed or cancelled runs
are still useful to inspect. Succeeded transcripts may be pruned.

For deployment logs, use the platform:

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

## How do I cancel a Job?

Open the Job and click **Cancel & close**. Syrus cancels any active Runs
and closes the Job thread. Follow-up polling for PR comments and CI
failures stops for that Job.

If you want to stop one active Run but keep the Job open for a retry, use
the Run-level stop action on the Job page.

For PR-level opt-out, add the `syrus-stop` label to the PR. The next PR
poll closes the Job with reason `syrus_stop`.

## How do I retry a failed Workflow?

Use the failed Workflow's retry action when it is available. Syrus
reopens the failed Workflow and failed Step, creates a new Run, and
continues from the same workspace.

Use **Run again** when you want a fresh follow-up Workflow on the same
Job and branch. Add replay context if the previous attempt failed for a
specific reason.

If the workspace has already been cleaned up, retry-in-place is no longer
available. Use Run again or start over.

## MySQL connection issues

In production, Syrus uses separate Rails database roles for primary,
cache, queue, and cable. In small deployments these can point at the
same MySQL server, but the environment variables still need to be
available to both web and worker processes.

Check:

- `DB_HOST` resolves from inside the container or pod.
- `SYRUS_DATABASE_PASSWORD` is present.
- The three `ACTIVE_RECORD_ENCRYPTION_*` keys are present, or
  `RAILS_MASTER_KEY` is present for a deploy that keeps those keys in
  Rails credentials. Processes that touch encrypted credentials need one
  stable source of encryption keys.
- MySQL is accepting connections from the web and worker network.
- Migrations have run for primary, cache, queue, and cable databases.

In Docker Compose, the most common mistake is starting the web container
before MySQL is healthy. Restart the web and worker after the database is
ready:

```bash
docker compose restart web worker
```

In Kubernetes, exec into the web pod and run a Rails database check:

```bash
kubectl -n <namespace> exec deploy/syrus-web -- bin/rails runner 'puts ActiveRecord::Base.connection.select_value("select 1")'
```

If `db:prepare` reports errors for cache, queue, or cable while the
primary database migrated, fix the missing database role instead of
assuming the app is fully prepared.

Fresh production installs use MySQL migrations from zero. The
development/test `db/schema.rb` is a SQLite dump and is not the source
of truth for production database initialization.

## Scheduled tasks are not firing

Check:

1. The task is not archived.
2. The task state is `scheduled`, not `paused`, `auto_paused`, or
   `fired`.
3. The owning user's **Pause scheduling** setting is off.
4. The cron expression fires at most once per hour, is interpreted in
   UTC, and produces a future scheduled time.
5. The previous scheduled PR is not still open when
   `pr_pileup_policy` is `skip`.
6. The default queue worker is running `PollScheduledTasksJob`.

If the task repeatedly failed, Syrus may auto-pause it after the
configured failure threshold. Unpause the task after fixing the underlying
prompt, credentials, or repository problem.

## The agent burned through my Anthropic or OpenAI credits

First stop the active work: cancel the Job or stop the active Run.

Then reduce future exposure:

- Lower **Max turns** under **Agent Settings**. The default is `200`.
- Keep scheduled tasks on `skip` pileup unless parallel scheduled PRs are
  intentional.
- Avoid broad prompts like "clean up the repo." Ask for a bounded file,
  failing test, warning, or subsystem.
- Add `.syrus.yml` prepare commands so the agent does not spend turns
  rediscovering dependency setup.
- Disable repository polling while you investigate noisy triggers.

Repo-level and account-level dollar budgets are roadmap work. Until they
ship, max-turns, cancellation, prompt scope, and scheduled-task policy
are the practical controls.

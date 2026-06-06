---
title: How-tos and recipes
description: Task-focused patterns for getting Syrus to do useful work.
---

# How-tos and recipes

These are copy-pasteable patterns for the Jobs people usually want
Syrus to handle. The examples assume you have already registered a
repository in Syrus, configured credentials, and left repository
polling enabled.

## How do I delegate my first GitHub issue?

Use this when you want the basic issue-to-PR loop.

1. Open an issue in the target GitHub repository.
2. Write a narrow request with a clear success condition:

   ```text
   Add a regression spec for the empty-dashboard state and make the
   dashboard show "No runs yet" when the current user has no Jobs.
   ```

3. Add the repository's Syrus trigger label. The default is `syrus`.
4. Wait for the repository poller, or open the repository in Syrus and
   use the GitHub issues panel to delegate it immediately.
5. Open the new Job in Syrus and watch the Workflow:

   ```text
   prepare -> implement -> graders -> summarize -> pr_open
   ```

Expected outcome: Syrus creates a Job, checks out a workflow workspace,
runs the agent, captures a diff, and opens a PR on a branch named for the
Job.

If no Job appears, see
[The poller never picks up my issue](/docs/troubleshooting#the-poller-never-picks-up-my-issue).

## How do I write an issue Syrus can act on?

Good Syrus issues read like scoped engineering tasks, not product epics.
Include the files, behavior, and tests when you know them.

1. Start with the user-visible goal.
2. Add acceptance criteria that can be checked in the repository.
3. Name any tests, commands, screenshots, or docs that should change.
4. Add boundaries for what should not change.
5. Avoid "clean up", "modernize", or "improve everything" unless you
   also define the exact surface area.

Example:

```text
## Goal
Show a "Retry workflow" action on failed Workflows from the Job detail
page.

## Acceptance criteria
- The button appears only for failed Workflows that can retry in place.
- Clicking it calls the existing retry endpoint and refreshes the Job.
- Add a React test for the hidden and visible states.

## Out of scope
- New retry endpoints.
- Retrying succeeded Workflows.
- Changing the admin Workflow page.
```

Expected outcome: the agent can plan against concrete constraints, run a
targeted test, and avoid unrelated refactors.

## How do I configure repository setup commands?

Use `.syrus.yml` when the auto-detected setup command is not enough. The
file belongs at the root of the repository Syrus is working on, not in
the Syrus deployment.

1. Identify the commands a fresh clone needs before tests can run.
2. Put those commands under `prepare`.
3. Keep commands deterministic and non-interactive.
4. Commit the file to the repository.
5. Trigger a small Syrus Job and confirm the `prepare` Step succeeds.

Rails example:

```yaml
prepare:
  - bundle config set --local path vendor/bundle
  - bundle install --jobs 4
  - bin/rails db:prepare
```

Node example:

```yaml
prepare:
  - npm ci
  - npm run build
```

If the repository needs no setup, say that explicitly:

```yaml
prepare: []
```

Expected outcome: every Workflow starts from a prepared workspace, and
agent runs spend their budget on the requested change instead of
rediscovering dependency setup.

If setup fails, see
[The prepare Step fails](/docs/troubleshooting#the-prepare-step-fails).

## How do I add tests or lint as Syrus graders?

Graders are deterministic commands that run after agent work. Required
grader failures send the agent into a bounded repair loop.

1. Choose commands that are meaningful for most Syrus PRs in the repo.
2. Add them to `.syrus.yml` under `grade.steps`.
3. Mark noisy checks as `required: false` until they are stable.
4. Trigger a small Syrus Job and inspect the `grader` Steps.
5. Tighten the command or timeout if it produces too much unrelated
   output.

Example:

```yaml
prepare:
  - npm ci
grade:
  max_iterations: 3
  steps:
    - name: tests
      run: npm test -- --runInBand
    - name: lint
      run: npm run lint
      required: false
      timeout_minutes: 5
```

Expected outcome: the Job page shows one grader Step per configured
command. Required failures are summarized back to the agent for repair;
advisory failures are logged without blocking the Workflow.

If graders run but do not trigger repair, see
[A grader failed but the Workflow still passed](/docs/troubleshooting#a-grader-failed-but-the-workflow-still-passed).

## How do I get Syrus to handle a failing test?

Syrus watches open PRs it created. When GitHub Checks report a completed
failure on the PR head SHA, Syrus creates a `ci_failure` Workflow:

```text
prepare -> analyze_and_fix -> summarize_amend -> push
```

No repo-local trigger config is required. The important setup is:

- The repository has a CI provider that reports GitHub Checks.
- Your GitHub token can read check runs. A classic token needs `repo`;
  a fine-grained token needs repository access plus Checks read access.
- Your repo has a useful `.syrus.yml` `prepare` section if dependencies
  must be installed before tests can run.

Example `.syrus.yml` for a Rails app:

```yaml
prepare:
  - bundle config set --local path vendor/bundle
  - bundle install --jobs 4
  - bin/rails db:prepare
```

Then let Syrus open a PR from a labeled issue. If CI fails on that PR,
the next PR poll, which runs about every five minutes, inspects the
failed checks and asks the agent to diagnose and fix them. Syrus pushes
the fix to the same branch, so GitHub reruns CI on the new commit.

Expected outcome: the Job page shows a new **CI failure** Workflow, the
transcript includes the failed check names and parsed error context, and
the PR receives a follow-up commit.

Troubleshooting: if no follow-up appears, see
[The agent never handles my failing CI check](/docs/troubleshooting#the-agent-never-handles-my-failing-ci-check)
and [PR creation failed](/docs/troubleshooting#pr-creation-failed).

## How do I get Syrus to respond to PR review comments?

Syrus polls PRs it created and reacts to new issue comments, review
comments, and line comments. When it sees new feedback, it creates a
`pr_comment` Workflow:

```text
prepare -> respond -> summarize_amend -> push
```

There is no GitHub inbound callback to install and no per-repo GitHub Action.
Leave polling enabled for the repository and comment on the PR normally:

```text
Could you split the parser into a small object and add a regression spec?
```

Syrus records the comment payload on the Workflow, runs the agent against
the existing branch, and pushes another commit. If you do not want to
wait for the five-minute poller, open the Job in Syrus and click
**Check for PR feedback**.

Expected outcome: the Job page shows a **PR feedback** Workflow, and the
PR branch gets a commit that addresses the comment. Syrus does not post a
bot comment today; the pushed commit is the response.

To customize behavior, put durable repo instructions in the issue body,
review comment, or project docs. For example:

```text
Please keep this as one commit and update the system spec that covers
the changed screen.
```

Troubleshooting: see
[The agent ran but produced no diff](/docs/troubleshooting#the-agent-ran-but-produced-no-diff)
if the follow-up ran but nothing changed.

## How do I run a scheduled cron job through Syrus?

Use **Scheduled tasks** in the Syrus UI. A scheduled task is attached to
one repository and creates normal Syrus Jobs when it fires.

Example task:

```text
Name: Weekly dependency hygiene
Kind: cron
Cron expression: 0 9 * * 1
PR pileup policy: skip
Prompt:
  Review dependency metadata in {{repo_slug}}. If low-risk updates are
  available, make them with tests. If there is nothing worth changing,
  report no changes.
```

Cron expressions are five-field cron in UTC. In the MVP, Syrus treats
cron tasks as hourly windows: the minute field is ignored for matching,
and a task can fire at most once in a matching UTC hour. Syrus stores a
stable per-task minute offset, so many tasks scheduled for the same hour
do not all fire on the same poll tick.

The `pr_pileup_policy` controls what happens when the previous scheduled
PR is still open:

- `skip`: do not fire until the previous PR closes.
- `pile`: create another Job anyway.
- `replace`: close the previous scheduled PR and open a fresh one.

Expected outcome: during the next matching hourly window, Syrus creates a
`cron` Job on a branch like `syrus/scheduled-<task_id>-<job_id>`. If the
agent finds no useful change, "no changes" is a successful outcome and the
Job closes without a PR.

Troubleshooting: see
[Scheduled tasks are not firing](/docs/troubleshooting#scheduled-tasks-are-not-firing).

## How do I add a custom Workflow template?

Workflow templates are Ruby classes today. They are not yet editable from
`.syrus.yml`; YAML-defined templates are roadmap work. To add a template
in a fork or private deployment, create a `Workflows::*` class, register
its trigger kind, and add an entry point that instantiates it.

Example template:

```ruby
# app/services/workflows/dependency_audit.rb
module Workflows
  class DependencyAudit < Base
    steps :prepare, :implement, :summarize, :pr_open

    def self.trigger_kind = "dependency_audit"
  end
end
```

Register the trigger kind:

```ruby
# app/services/workflows.rb
REGISTRY = {
  "initial" => :Initial,
  "dependency_audit" => :DependencyAudit
}.freeze
```

Also add `dependency_audit` to the trigger-kind validations in
`Workflow` and `Run`, then wire a controller, poller, scheduled task, or
Rails runner script to call:

```ruby
workflow = Workflows.for(trigger_kind: "dependency_audit").instantiate(job: job)
StepDispatcher.start_workflow(workflow)
```

Expected outcome: the Job page shows the new trigger kind, executes the
declared steps in order, and uses the same workspace, transcript, diff,
push, and PR-opening machinery as built-in Workflows.

Troubleshooting: if the first Run never starts, check that the trigger
kind was added to both model validation lists and that your entry point
called `StepDispatcher.start_workflow`.

## How do I trigger an ad-hoc Job from the CLI?

The public REST API for creating Jobs is tracked in
[issue #196](https://github.com/tkadauke/syrus/issues/196). Until that
ships, the supported UI path is **New Job**. For local automation inside
your own Syrus deployment, use `bin/rails runner` in the web or worker
container.

Example:

```bash
bin/rails runner <<'RUBY'
user = User.find_by!(email_address: ENV.fetch("SYRUS_USER_EMAIL"))
repo = user.repositories.active.find_by!(
  owner: ENV.fetch("SYRUS_REPO_OWNER"),
  name: ENV.fetch("SYRUS_REPO_NAME")
)

prompt = ENV.fetch("SYRUS_PROMPT")
job = user.jobs.create!(
  repository: repo,
  kind: "direct",
  issue_number: nil,
  issue_title: ENV.fetch("SYRUS_JOB_TITLE", "Direct job"),
  issue_body: prompt,
  agent_provider: repo.effective_agent_provider,
  priority: ENV.fetch("SYRUS_PRIORITY", "medium")
)

workflow = Workflows::Initial.instantiate(job: job, agent_provider: job.agent_provider)
StepDispatcher.start_workflow(workflow, prompt: Prompts::DirectJob.new(prompt: prompt).to_s)

puts "Created Job ##{job.id}"
RUBY
```

In Docker Compose, run the same command inside the web or worker service,
for example:

```bash
docker compose exec web bin/rails runner ./script/create_direct_job.rb
```

Expected outcome: Syrus creates a `direct` Job with no GitHub issue,
starts the normal initial Workflow, and opens a PR if the agent produces
a diff.

Troubleshooting: if the runner cannot decrypt credentials, the process is
missing `RAILS_MASTER_KEY`. If the Job is created but never runs, check
that a worker is running the `runs` queue.

## How do I budget-cap a repo?

Repo-level dollar budgets are not shipped yet. They are planned as part
of the budget-threshold work, where Syrus will hold new runs once a
per-user or per-repo window is exhausted.

Today you can use these controls:

- Set **Max turns** under **My credentials**. The default is `200`; `0`
  disables the turn cap while the per-run timeout still applies.
- Keep scheduled tasks on `pr_pileup_policy: skip` unless you explicitly
  want many open PRs from one recurring prompt.
- Leave the built-in CI failure loop cap in place. Autonomous CI-failure
  retries are capped at three `ci_failure` Workflows per Job per 24-hour
  window.
- Cancel a Job that is going in the wrong direction.

Expected outcome: max-turns limits reduce runaway agent sessions, and
scheduled-task pileup policy prevents recurring work from stacking
unbounded PRs.

Troubleshooting: see
[The agent burned through my Anthropic or OpenAI credits](/docs/troubleshooting#the-agent-burned-through-my-anthropic-or-openai-credits).

## How do I switch a repository between Claude and Codex?

Provider selection is resolved when Syrus creates the Job and Workflow.
Use a repository override when one repo should consistently use a
different provider from the user's default.

1. Confirm the user has configured credentials for the target provider.
2. Open the repository settings page in Syrus.
3. Set **Agent provider override** to `claude` or `codex`.
4. Save the repository.
5. Create a new Job. Existing Jobs keep the provider they already
   captured unless you explicitly run a follow-up with a different
   provider.

Expected outcome: new Jobs for that repository show the selected
provider on their Workflows and Runs.

If a Run fails immediately after switching, see
[The agent provider cannot start](/docs/troubleshooting#the-agent-provider-cannot-start).

## How do I approve and auto-merge a Syrus PR?

Use auto-merge when you want Syrus to run final graders and land an
approved Job without giving the agent more freedom than the PR branch
already has.

1. Enable auto-merge for the repository.
2. Make sure required graders are configured in `.syrus.yml`.
3. Review the Syrus PR and mark the Job approved in Syrus.
4. Let the landing queue create an `auto_merge` Workflow:

   ```text
   prepare -> graders -> landing_fix -> push -> auto_merge
   ```

5. Watch the Job page. If final graders fail, Syrus runs `landing_fix`;
   if the repair succeeds, it pushes the fix and attempts the GitHub
   merge.

Expected outcome: the PR is merged through GitHub's merge API, or the Job
returns to an operator-visible state with the failed Step and reason.

If the PR becomes unmergeable before landing, see
[The PR is approved but will not merge](/docs/troubleshooting#the-pr-is-approved-but-will-not-merge).

## How do I rebase an unmergeable Syrus PR?

Syrus can maintain branches it controls when GitHub reports that a PR is
not mergeable.

1. Confirm the PR branch belongs to the Syrus installation, not a fork or
   manually-created branch.
2. Leave repository polling enabled.
3. Wait for merge-state polling, or use the operator action that checks
   merge state for the Job.
4. Watch for a `rebase` Workflow:

   ```text
   auto_rebase -> agent_rebase -> force_push
   ```

5. If the deterministic rebase is clean, Syrus skips conflict resolution
   and force-pushes with a lease. If conflicts remain, the agent resolves
   them before the force-push Step.

Expected outcome: the PR branch is updated against the base branch and
GitHub can recompute mergeability.

If force-push fails, see
[Rebase finished but force-push failed](/docs/troubleshooting#rebase-finished-but-force-push-failed).

## How do I disable Syrus for a single PR?

Add the `syrus-stop` label to the PR. The next PR poll closes the Syrus
Job with reason `syrus_stop` and cancels active runs for that Job.

With the GitHub CLI:

```bash
gh pr edit 123 --add-label syrus-stop
```

This is the PR-level escape hatch. For issue ingestion before Syrus has
started, add `syrus-skip` to the issue instead:

```bash
gh issue edit 456 --add-label syrus-skip
```

Expected outcome: Syrus stops polling that PR as an open Job. The GitHub
PR remains open unless you close it yourself.

Troubleshooting: if you reopen the Job in Syrus while `syrus-stop` is
still on the PR, the next poll will close it again. Remove the label
before reopening.

## Next

For configuration reference, read [Configuration](/docs/configuration).
For failed runs, missing PRs, provider errors, and runaway usage, continue
to [Troubleshooting](/docs/troubleshooting).

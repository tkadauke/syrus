---
title: How-tos and recipes
description: Task-focused patterns for getting Syrus to do useful work.
---

# How-tos and recipes

These are copy-pasteable patterns for the Jobs people usually want
Syrus to handle. The examples assume you have already registered a
repository in Syrus, configured credentials, and left repository
polling enabled.

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

Cron expressions are five-field cron in UTC and must produce a future
scheduled time. In the MVP, Syrus treats cron tasks as hourly windows:
the entered minute is honored, and a task can fire at most once in a
matching UTC hour.

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
missing the `ACTIVE_RECORD_ENCRYPTION_*` keys, or `RAILS_MASTER_KEY` for
a deploy that keeps encryption keys in Rails credentials. If the Job is
created but never runs, check that a worker is running the `runs` queue.

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

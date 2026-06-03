---
title: Getting Started
description: Get from a fresh Syrus install to the first successful Job and pull request.
---

# Getting Started

Syrus turns GitHub issues, direct prompts, PR feedback, retries, and
rebases into agent runs. It owns the deterministic plumbing: clone the
repository, prepare the workspace, invoke the agent, capture the diff,
push a branch, and open or update the pull request.

This guide gets you from a fresh Syrus instance to one successful Job.
That first success is deliberately small: prove credentials, repository
access, polling, workspace setup, agent invocation, push, and PR creation
before asking Syrus to do bigger work.

## Choose The First Path

Use the path that answers the question you have right now.

| If you want to... | Start here | What you will see |
| --- | --- | --- |
| Evaluate agent behavior against code on your machine | [Try it locally](/docs/deployment/try-it-locally) | One container runs once, prints a local diff, and exits. No GitHub access, database, users, or PR. |
| Try the full product loop for yourself or a small team | [Docker Compose](/docs/deployment/docker-compose) or your operator-provided setup | Web UI, worker, database, repository polling, Job history, and a real GitHub PR. |
| Self-host on shared infrastructure | [Deployment](/docs/deployment) and [Kubernetes](/docs/deployment/kubernetes) | The same app on your own infrastructure, once you have chosen ingress, storage, secrets, backups, and operations. |

:::note
The local evaluation path is useful, but it is not the full product
sequence. It does not create users, poll GitHub, add repositories, or open
pull requests.
:::

:::caution
Some packaging pieces are still landing. The Docker Compose and
Kubernetes pages describe the target operating shape and the honest status
of the published artifacts. If your checkout does not include the Compose
file or cluster packaging yet, use the deployment path your operator
provides rather than filling in missing production decisions from this
guide.
:::

## Local Evaluation

The shortest evaluation is:

1. Open a Git checkout on your machine.
2. Export an agent credential for the local runner.
3. Run the single-container command from
   [Try it locally](/docs/deployment/try-it-locally).
4. Inspect the printed diff or write it to `syrus.diff`.

That path runs a temporary local-dev Job through the standard
`prepare -> implement` work, then stops. Use it to answer "can Syrus make
a plausible change in this codebase?" Continue with the hosted setup when
you want the real `issue -> Job -> Workflow -> PR` loop.

## Hosted Setup

A real Syrus instance needs:

- A web process for signup, credentials, repository settings, dashboards,
  transcripts, and PR links.
- A worker process for pollers, preparation commands, agent runs, pushes,
  PR creation, reapers, and workspace cleanup.
- MySQL for users, encrypted credentials, repositories, Jobs, Workflows,
  Runs, logs, artifacts, and queue state.
- A durable `$SYRUS_DATA_ROOT` volume on workers for clone caches and
  workflow workspaces.
- Stable Rails secrets, especially `RAILS_MASTER_KEY`, so encrypted user
  credentials stay decryptable across restarts.

The first-run checklist in the authenticated UI follows this sequence:
account and admin access, GitHub credentials, agent credentials and
provider, repository, first issue or direct Job, then watching the first
Job until one closes successfully.

## First Successful Run

Keep the first request boring. A typo fix, one tiny docs update, or one
obvious failing test is better than a broad refactor. The goal is to
verify the product sequence.

### 1. Create the first admin

Open the web UI and sign up. The first user becomes an admin and can
complete instance-level setup such as GitHub App registration.

After signup, open **First-run setup** or **My credentials**. The setup
screen should point you at the next missing step until at least one Job
has closed successfully.

### 2. Add credentials and choose a provider

In **My credentials**, choose your default agent provider and add the
matching credential:

- **Claude** uses a Claude OAuth token.
- **Codex** uses either a Codex API key or ChatGPT `auth.json`,
  depending on the selected Codex authentication mode.

Set **Max turns** to the cap you want for agent runs. The default is meant
to prevent runaway loops while still allowing normal implementation work.

Then configure GitHub access. Syrus considers GitHub authentication ready
when either a user PAT exists or a GitHub App is registered for the
instance.

- A **GitHub personal access token** is the fallback credential. It must
  be able to list issues, read PRs and checks, push branches, open pull
  requests, and post updates for the repositories Syrus will manage.
- A **GitHub App installation** is preferred when available. Admins
  register the singleton Syrus GitHub App, then install it on the relevant
  owner or repository. Repositories with an active installation use App
  credentials; repositories without one use the user's PAT fallback.

Syrus records the credential mode on repositories and Jobs so operators
can tell whether a run used App credentials or PAT fallback.

### 3. Add a repository

Open **Repositories** and add the first repository Syrus should manage.
You can pick from GitHub when credentials can list accessible
repositories, or enter the owner and repository name manually.

Confirm these settings:

- **Default branch** is the branch Syrus should clone, diff against, and
  target for PRs.
- **Trigger label** is the issue label that creates Jobs. The default is
  `syrus`.
- **Polling enabled** is on for issue ingestion.
- **Default agent** is blank unless this repository should override your
  user default provider.
- **Run prepare step** is on unless this repository intentionally needs no
  setup.

If the repository needs more than one setup command, add `.syrus.yml` to
the target repository:

```yaml
prepare:
  - bundle config set --local path vendor/bundle
  - bundle install --jobs 4
  - npm ci
```

If `.syrus.yml` is missing, Syrus auto-detects one common setup command
from lockfiles such as `Gemfile`, `yarn.lock`, `pnpm-lock.yaml`,
`package-lock.json`, or `package.json`. Use `prepare: []` or
`prepare: false` only when no setup should run.

### 4. Start the first Job

For the full GitHub loop, create or edit a GitHub issue in the registered
repository and add the trigger label.

Good first issue:

```text
Title: Fix typo in README setup section

The README says "instal" in the setup section. Please correct it and run
the smallest relevant check.
```

Syrus polls GitHub instead of receiving inbound webhooks, so the Job may
not appear immediately.

You can also create a **direct Job** from the web UI after a repository
exists. Direct Jobs are useful for operator-supplied prompts, but a
labelled GitHub issue is the clearest first proof that polling and issue
delegation work.

### 5. Watch the Job, Workflow, and Run

Open the Job from the dashboard or setup screen. The first labelled issue
normally creates an `initial` Workflow with these Steps:

```text
prepare
implement
summarize
pr_open
```

Watch these checkpoints:

- The Job leaves the queue and shows the selected agent provider.
- `prepare` succeeds, skips by configuration, or records a clear setup
  failure.
- `implement` starts a Run, streams transcript output, and captures the
  agent's commits.
- The Run or Workflow shows the captured diff.
- `summarize` records PR title and body.
- `pr_open` pushes the Syrus branch and attaches the GitHub PR number.

If the Job fails, keep the Job page as the starting point. It contains
the Workflow, Step, Run, logs, transcript, diff, and retry actions needed
for diagnosis.

### 6. Review the PR result

Open the PR from the Job page. Review it like any other pull request:
read the diff, check CI, comment, request changes, approve, or merge.

If you comment on the PR, Syrus can pick up feedback on a later PR poll
and create a follow-up Workflow on the same Job. If CI failures are
enabled for your installation, failing checks can also create repair
Workflows on Syrus-owned PRs.

The first-run guide is complete when at least one Job closes successfully.
After that, the dashboard becomes the normal working surface for Jobs,
PRs, retries, schedules, direct Jobs, and operational follow-up.

If no Job appears, start with
[the poller troubleshooting checklist](/docs/troubleshooting#the-poller-never-picks-up-my-issue).
If a Job appears but no PR is created, start with
[PR creation failed](/docs/troubleshooting#pr-creation-failed).

## Tiny Glossary

Syrus uses five core words throughout the UI and API:

| Term | Short version |
| --- | --- |
| **Epic** | A group of related Jobs in one repository, useful when a goal needs several sequenced PRs. |
| **Job** | The thread of work for one source of truth: a GitHub issue, scheduled task, or ad-hoc prompt. |
| **Workflow** | One attempt to handle that Job. |
| **Step** | One stage inside a Workflow, such as prepare, implement, summarize, or push. |
| **Run** | One execution attempt for a Step, carrying prompt, agent metadata, diff, and PR copy. |

For the deeper version, including state machines and trigger kinds,
read [Concepts](/docs/concepts).

## Where To Go Next

- [Evaluate Syrus locally](/docs/deployment/try-it-locally) if you want
  a quick diff before deploying anything.
- [What is Syrus?](/docs/what-is-syrus) for the product model.
- [Why use Syrus?](/docs/why-use-syrus) for fit and trade-offs.
- [Deployment](/docs/deployment) if you are choosing between local,
  Compose, and Kubernetes.
- [Concepts](/docs/concepts) if you want the mental model behind Epics
  and the Job → Workflow → Step → Run vocabulary.

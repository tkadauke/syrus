---
title: Getting Started
description: Understand what Syrus is, decide which deployment path fits, and get to a working setup.
---

# Getting Started

Syrus is a multi-user harness that turns GitHub issues into pull
requests, with the deterministic plumbing — clones, branches, PR
creation, cleanup — owned by the harness so an LLM only has to
write code.

The short version: you register a repository, label an issue, and
Syrus opens the pull request. Pollers notice the outside world,
workers run the agent, and the web UI shows the Job, transcript,
diff, and PR link as the work moves through the pipeline.

:::tip
If you only want to see what the agent does to your own code, start
with the [60-second local evaluation](/docs/deployment/try-it-locally).
It does not require a GitHub app, database, or long-running Syrus install.
:::

## Which Path Is Right For You?

Start with the path that matches what you are trying to learn.

| If you want to... | Use this path | Why |
| --- | --- | --- |
| See Syrus produce a diff against a local checkout | [Try it locally](/docs/deployment/try-it-locally) | Fastest evaluation path; no persistent service. |
| Run Syrus for yourself or a small team | [Docker Compose](/docs/deployment/docker-compose) | Recommended default; runs the web app, worker, and database together. |
| Operate Syrus on real shared infrastructure | [Kubernetes](/docs/deployment/kubernetes) | Production path for teams already comfortable with k3s or Kubernetes. |

:::note
The full deployment overview lives at [Deployment](/docs/deployment).
Docker Compose is the recommended first real setup because it exercises
the actual GitHub polling and PR flow without asking you to design a
cluster on day one.
:::

## First Successful Run

The first useful full-product loop is one boring issue that produces one
pull request. Keep it small: a typo fix, a short docs update, or one
obvious failing test. You are proving credentials, polling, workspace
setup, agent invocation, push, and PR creation before asking for broader
work.

### 1. Start Syrus

Use the [Docker Compose guide](/docs/deployment/docker-compose) once the
published Compose packaging is available, or the deployment path your
operator has provided. You need:

- The web process, so you can configure users, repositories, and Jobs.
- The worker process, so pollers and Runs actually execute.
- MySQL, so Jobs, credentials, logs, and queue state persist.
- `$SYRUS_DATA_ROOT`, so the worker has durable clone and workspace
  storage.

### 2. Create the first admin

Open the web UI and sign up. The first user becomes an admin.

After that, go to **Credentials** and add:

- GitHub credentials that can read issues and PRs, push branches, open PRs,
  and read checks for the repositories Syrus will manage.
- Agent credentials for your chosen provider.
- Your default provider and max-turn setting.

If your deployment supports GitHub App installations, prefer the app for
repository access and keep the PAT fallback narrow. Syrus records the
credential mode on Jobs for operator visibility.

### 3. Register a repository

Add the GitHub repository by owner/name and default branch. Confirm:

- Polling is enabled.
- The trigger label is present or can be created in GitHub. The default
  label is `syrus`.
- The repository provider override is blank unless this repo should use a
  different provider than your user default.
- Preparation is enabled unless you know the repo needs no setup.

For repositories with non-trivial setup, add `.syrus.yml` to the target
repo:

```yaml
prepare:
  - bundle config set --local path vendor/bundle
  - bundle install --jobs 4
  - npm ci
```

Use only the commands the agent needs before it starts. Long, flaky setup
turns a simple first run into an operations problem.

### 4. File the first issue

Create a small GitHub issue in the registered repo and add the trigger
label.

Good first issue:

```text
Title: Fix typo in README setup section

The README says "instal" in the setup section. Please correct it and run
the smallest relevant check.
```

Avoid "refactor the app", "improve performance", and other broad prompts
until the basic loop works.

### 5. Watch the Job

The Job page should show:

```text
initial Workflow
  prepare
  implement
  summarize
  pr_open
```

The useful checkpoints are:

- `prepare` succeeds or records a clear skip.
- `implement` starts an agent Run and captures transcript output.
- The diff appears on the Run or Workflow after the agent commits.
- `summarize` records PR copy.
- `pr_open` pushes a branch and attaches the GitHub PR number.

### 6. Review the PR

Open the PR from the Job page. Review it like any other pull request:
read the diff, check CI, ask for changes, or merge it. If you comment on
the PR, Syrus can pick up the feedback on the next PR poll and create a
follow-up Workflow on the same Job.

If no PR appears, start with
[Troubleshooting](/docs/troubleshooting#the-poller-never-picks-up-my-issue)
or [PR creation failed](/docs/troubleshooting#pr-creation-failed).

## Tiny Glossary

Syrus uses four core words throughout the UI and API:

| Term | Short version |
| --- | --- |
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
- [Concepts](/docs/concepts) if you want the mental model behind the
  Job → Workflow → Step → Run vocabulary.

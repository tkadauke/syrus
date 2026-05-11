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
with the [60-second local evaluation](/evaluate). It does not require
a GitHub app, database, or long-running Syrus install.
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

## First Steps With Docker Compose

Once the Docker Compose path is available in your environment, the
first useful loop is:

1. Start the stack from the [Docker Compose guide](/docs/deployment/docker-compose).
2. Sign up in the web UI. The first user becomes the admin.
3. Add your GitHub token and agent credentials.
4. Register a repository and confirm its trigger label. The default
   label is `syrus`.
5. Create or pick a small GitHub issue in that repository.
6. Add the trigger label.
7. Watch the Job page as Syrus creates a Workflow, runs its Steps,
   captures the transcript, and opens a PR.

Keep the first issue boring: a typo fix, a small docs change, or a
single failing test. You are proving the plumbing before you ask the
agent to perform surgery.

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

- [Evaluate Syrus locally](/evaluate) if you want a quick diff before
  deploying anything.
- [Deployment](/docs/deployment) if you are choosing between local,
  Compose, and Kubernetes.
- [Concepts](/docs/concepts) if you want the mental model behind the
  Job → Workflow → Step → Run vocabulary.

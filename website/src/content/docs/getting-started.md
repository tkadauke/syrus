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
| Install Syrus on your Mac with no terminal | [Desktop app](/docs/desktop) | A DMG download, a guided setup that installs the Docker backend for you, the full web UI in a native window, and a menu-bar inbox. When the app later updates its local backend, a sidebar notice shows the progress (download percentage, restart, database migration) until Syrus is reachable again. |
| Try the full product loop for yourself or a small team | [Docker Compose](/docs/deployment/docker-compose) or your operator-provided setup | Web UI, worker, database, repository polling, Job history, and a real GitHub PR. |
| Develop Syrus itself | The project README | Source checkout, Ruby/Node/Go toolchain, `bin/dev`, and fast reloads. |
| Self-host on shared infrastructure | [Deployment](/docs/deployment) and [Kubernetes](/docs/deployment/kubernetes) | The same app on your own infrastructure, once you have chosen ingress, storage, secrets, backups, and operations. |

:::caution
Some packaging pieces are still landing. The Docker Compose and
Kubernetes pages describe the target operating shape and the honest status
of the published artifacts. If your checkout does not include the Compose
file or cluster packaging yet, use the deployment path your operator
provides rather than filling in missing production decisions from this
guide.
:::

## Hosted Setup

A real Syrus instance needs:

- A web process for signup, credentials, repository settings, dashboards,
  transcripts, and PR links.
- A worker process for pollers, preparation commands, agent runs, pushes,
  PR creation, reapers, and workspace cleanup.
- A database for users, encrypted credentials, repositories, Jobs,
  Workflows, Runs, logs, artifacts, and queue state. Docker Compose uses
  SQLite; clustered production uses MySQL.
- A durable `$SYRUS_DATA_ROOT` volume on workers for clone caches and
  workflow workspaces.
- Stable Rails secrets, especially `RAILS_MASTER_KEY`, so encrypted user
  credentials stay decryptable across restarts.

The first-run checklist in the authenticated UI follows this sequence:
account and admin access, GitHub credentials, agent credentials and
provider, repository, meeting Syrus in chat, then landing your first Epic.
While you are still working through the early steps, the other top-level
tabs are hidden and the **Syrus** brand link returns you to onboarding —
the only tab is **Setup** (which opens the onboarding checklist). The
moment you start the onboarding chat, the rest of the tabs appear and the
**Syrus** brand link opens that chat. Onboarding completes when your first
Epic lands (all of its child Jobs merge), at which point the **Setup** tab
drops off the navigation entirely.

## First Successful Run

Keep the first request boring. A typo fix, one tiny docs update, or one
obvious failing test is better than a broad refactor. The goal is to
verify the product sequence.

### 1. Create the first admin

Open the web UI and sign up. The first user becomes an admin and can
complete instance-level setup such as GitHub App registration.

After signup, open **First-run setup** or **Credentials**. The setup
screen should point you at the next missing step until at least one Job
has closed successfully.

### 2. Add credentials and choose a provider

In **Agent Settings**, choose your default agent provider. Then open
**Credentials** and add the matching credential:

- **Claude** uses a Claude OAuth token. On the **First-run setup**
  checklist, the **Configure agent** step opens a guided modal: it first
  checks whether `claude --print` already works on this machine (common on
  bare-metal installs where you have already run `claude login`), and if not,
  an **Authorize with Claude** button opens the subscription OAuth flow in a
  new tab. Approve access, copy the short code Claude shows you, and paste it
  back into the modal — Syrus exchanges it for a long-lived token and tests it
  on the spot. No terminal needed; requires a Claude Pro, Max, Team, or
  Enterprise plan. The same authorization flow is available later in
  **Credentials**, where you can also paste a `claude setup-token` value
  directly.
- **Codex** uses either a Codex API key or ChatGPT login. In ChatGPT
  login mode, **Authorize with ChatGPT** opens the OpenAI authorization
  page in a new tab; paste the returned code and Syrus stores the resulting
  Codex auth JSON. You can still paste an existing local `auth.json`
  manually from **Credentials**.

Set **Max turns** to the cap you want for agent runs. The default is meant
to prevent runaway loops while still allowing normal implementation work.

Then set up the GitHub integration. To monitor and interact with GitHub,
and to act as an independent contributor, Syrus requires both a Personal
Access Token (PAT) and a custom GitHub App. The **GitHub integration**
step guides you through them one at a time:

1. **Personal access token.** Syrus links straight to
   [github.com/settings/tokens](https://github.com/settings/tokens), tells you
   to create a *classic* token with **No expiration** and the `repo` and
   `workflow` scopes, then verifies the token the moment you paste it — a green
   check confirms it works, while a clear message flags an invalid token or a
   missing scope before you save. The PAT covers private clones and is the
   fallback for repositories without an active App installation.
2. **GitHub App** (admin only). Click the button: your browser opens
   GitHub, GitHub creates the singleton Syrus App from a manifest and sends
   you straight back — Syrus picks up the registration automatically.
3. **Install the App** (recommended, skippable). Right after registration,
   Syrus offers GitHub's install page for the App. Keep GitHub's
   **All repositories** default and every repository you add to Syrus
   connects to the App automatically; Syrus detects the installation by
   itself within seconds and shows *Installed on \<account\>*. If you skip
   it, Syrus works through your PAT and offers a per-repository install
   link whenever you add a repository that isn't covered.

The GitHub step completes once the token is verified and the App is
registered. Repositories work immediately either way: with an active App
installation Syrus acts through its own bot identity (independent rate
limit, auto-refreshing tokens); without one it works through your PAT.

Syrus records the credential mode on repositories and Jobs so operators
can tell whether a run used App credentials or PAT fallback.

One caveat for reinstalls: the App registration lives in your instance's
database, so ordinary updates keep it. Wiping the instance (deleting its
data volume) and reinstalling registers a *new* App — the old one's
private key is not recoverable — and orphaned Syrus Apps from previous
installs can be deleted at
[github.com/settings/apps](https://github.com/settings/apps).

### 3. Add a repository

On the **First-run setup** checklist, the **Add repository** step opens a
guided modal for your *first* repository. It walks you through GitHub
dropdowns: pick a **User/Org**, then the **Repository** dropdown for that owner
appears, and once you choose a repository the **Default branch** dropdown lists
its branches with `main`/`master` pre-selected. (There is no free-text entry —
the dropdowns come from GitHub, so if they can't load you fix **Configure
GitHub** first.) The modal applies the `syrus` trigger label by default,
inherits the default agent you chose earlier, and turns on auto-merge plus the
standard repository defaults. It skips the upstream/fork fields. Additional
repositories — and any fine-tuning, including the trigger label — happen later
from the full **Repositories** page.

After the repository is added, Syrus offers the one optional step that's
now actionable: **installing the Syrus GitHub App on that owner**, via a
link pre-scoped to the repository. Skip it and Syrus works through your
PAT; take it and the modal detects the installation by itself and confirms
when actions will come from the Syrus bot. If the owner already has an
active installation, none of this appears — the repository connects to the
App automatically.

To add more repositories after the first, open **Repositories**. You
can pick from GitHub when credentials can list accessible
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

:::tip
Use `.syrus.yml` `hooks.post_checkout` when developers need local
automation after `syrus checkout`, such as running migrations or
installing frontend packages. See [Configuration](/docs/configuration)
for the hook schema and the `--no-hooks` bypass flag.
:::

### 4. Meet Syrus in chat and land your first Epic

The final first-run step sends you into a **Syrus chat**. Click **Start
Syrus chat** on the checklist; Syrus opens a chat attached to your
repository and greets you. It explains how Jobs and Epics work, then helps
you create your first **Epic**. The recommended first Epic is onboarding
the repository itself to Syrus — for example adding an `AGENTS.md` (an
agent guide) and a `.syrus.yml` with `prepare` commands and `graders`
(test/lint/typecheck commands) that fit the repo — but you can pick a
different first Epic.

Syrus proposes the Epic and its child Jobs as a proposal card you accept.
Once accepted, a **Start** button appears next to the confirmed Epic in the
chat — clicking it moves the Epic to **In Progress**, which is what actually
triggers Syrus to implement the Jobs. Within an Epic, **every** child Job must
be approved before **any** of them land — the Epic lands atomically as a unit.

Once the Jobs run, the GitHub loop is the same as for any Job. You can also
file work directly: create or edit a GitHub issue in the registered
repository and add the trigger label, or create a **direct Job** from the
web UI. Syrus polls GitHub instead of receiving inbound webhooks, so a
labelled issue's Job may not appear immediately.

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
Workflows on Syrus-owned PRs. A Job remains in the landing queue — and
does not merge — until every PR check has passed; if checks are still
running (pending) or any required check has failed, the Job is held with
a status message explaining the specific reason.

The first-run guide is complete when your first Epic lands (all of its
child Jobs merge); the **Setup** tab then drops off the navigation.
After that, the dashboard becomes the normal working surface for Jobs,
PRs, retries, schedules, direct Jobs, and operational follow-up. The Jobs
list opens to the Inbox smart folder by default so actionable work is
first; in the dashboard sidebar, use More -> All jobs when you need the
unfiltered Job list. The Queued smart folder shows how many queued Jobs
are blocked before their first Run, and Job cards explain whether they are
waiting on dependencies, Epic readiness, main branch health, or an active
urgent Job. Dashboard view and sort choices are remembered per
smart folder, so returning to views like Landing queue or All Epics restores
the layout and ordering that fit that folder.

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

- [What is Syrus?](/docs/what-is-syrus) for the product model.
- [Why use Syrus?](/docs/why-use-syrus) for fit and trade-offs.
- [Deployment](/docs/deployment) if you are choosing between local,
  Compose, and Kubernetes.
- [Concepts](/docs/concepts) if you want the mental model behind Epics
  and the Job → Workflow → Step → Run vocabulary.

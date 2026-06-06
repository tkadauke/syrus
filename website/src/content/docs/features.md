---
title: Features
description: Product feature reference for Jobs, Epics, schedules, chats, credentials, and repository automation.
---

# Features

This page is the product-level reference for the current app. Use
[Concepts](/docs/concepts) for the data model and
[Workflows](/docs/workflows) for execution chains.

## Repositories

A repository is the boundary for GitHub automation. Each repository belongs
to one Syrus user and stores the GitHub owner/name, default branch, trigger
label, polling state, provider override, prepare setting, PR cost footer
setting, and auto-merge settings.

When polling is enabled, Syrus periodically lists open GitHub issues for the
repository and ingests issues that have the configured trigger label. The
repository issues panel can also list GitHub issues and delegate work by
adding that label through Syrus. A `syrus-skip` label prevents ingestion;
`syrus-skip-prepare` keeps the Job but skips the preparation Step.

Archived repositories are hidden from active workflows and have polling
disabled. Unarchiving does not silently resume polling; an operator must
turn polling back on.

Repositories can use GitHub App credentials when an active installation is
linked for the repository owner. If not, Syrus uses the owner's PAT. The
selected path is copied onto each Job as `credential_mode`, so operators can
see whether the run used `app` or `pat`.

## Jobs

A Job is the unit operators track in the UI. It represents one thread of
work from a GitHub issue, scheduled task, direct prompt, or chat proposal.

Jobs show the repository, source prompt, state, priority, validity,
credential mode, agent provider, active Workflow, past Workflows,
transcripts, captured diffs, PR link, attachments, tags, dependencies, and
logs. Operators can retry, cancel, run again, change priority, approve,
unapprove, close, inspect the related PR, or override dependency gates when
they have permission.

Job kinds:

| Kind | Source |
| --- | --- |
| `issue` | A GitHub issue selected by trigger label or delegated from the repository issues panel. |
| `cron` | A scheduled task fire. |
| `direct` | An operator-created prompt with no GitHub issue. |

Job states are more detailed than the concept page's thread shorthand:
`triaging`, `blocked_by_epic`, `queued`, `running`, `implemented`,
`failed`, `approved`, `landing`, and `closed`. The common path is
triage to queue to running to implemented, then operator or GitHub approval
can move the Job into the landing queue.

Issue bodies can declare dependencies with lines like `Depends-on: #123` or
`Blocked-by: owner/repo#456`. Syrus resolves those to existing Jobs for the
same user and blocks execution until the dependency reaches an accepted
terminal outcome. Operators can also add manual dependencies from the UI.

Some Jobs are part of PR stacks through a parent Job. Stacked Jobs derive
their base branch from the parent branch unless configured otherwise, and
stack rebases update dependent branches together.

## Issue Ingestion

Issue ingestion is poll-based, not webhook-based. `PollAllRepositoriesJob`
fans out to repository pollers, which list open issues and apply the
repository's ingest policy. A new accepted issue creates a Job, captures the
GitHub issue identifiers, stores the provider and credential choices, and
queues the initial Workflow.

Before execution, the ingestion classifier can attach the Job to an Epic,
mark it as a duplicate or already implemented, or leave it waiting for
operator review when the Epic reference is ambiguous. Issue comments added
before the agent run starts are included in the initial prompt in
chronological order.

Syrus currently ingests GitHub issues and pull-request feedback. It does not
advertise GitLab, Jira, Linear, or inbound webhook ingestion.

## Epics

Epics group related Jobs inside one repository. They are useful when a
goal is larger than one PR but still needs visible sequencing.

An Epic has a board state: `backlog`, `ready`, `in_progress`, `done`, or
`archived`. Child Jobs can be blocked until the Epic starts, and Epics can
depend on other Epics. Syrus can mark an Epic ready when its dependencies
are done and all child Jobs are confirmed, then mark it done when all child
Jobs close through merged PR outcomes.

Epics have list and board views, detail pages, dependency graphs, child Job
lists, and archive controls. Auto-approval rules can also apply at the Epic
level, so trusted Epic work can flow to auto-merge without approving each
child PR separately.

Chats can propose Epics or propose an Epic with child Jobs. The operator
confirms the proposal before Syrus creates the real records.

## Schedules

Scheduled tasks attach a recurring or one-shot prompt to a repository.
When a task fires, Syrus creates a normal `cron` Job and runs the standard
issue-to-PR pipeline on a scheduled branch.

Supported schedule kinds:

| Kind | Meaning |
| --- | --- |
| `cron` | Five-field cron expression interpreted in UTC, limited to at most one fire per hour. |
| `one_shot` | A single future fire time. |

The `pr_pileup_policy` controls what happens if the last scheduled PR is
still open: `skip`, `pile`, or `replace`. Repeated failures can
auto-pause a task until an operator fixes and resumes it.

Cron expressions are evaluated in UTC and are constrained to fire at most
once per hour. Syrus stores a random minute offset per task so multiple
tasks with the same nominal schedule do not all fire on the same minute.
The user-level scheduling pause skips all scheduled-task firing for that
user without changing the tasks themselves.

Scheduled tasks can optionally be based on a Cron Template, which stores a
reusable prompt and schedule policy. Templates are useful when one operator
wants to apply the same recurring maintenance prompt to several
repositories.

## Chats

Chats are operator conversations with repository context. A chat can
attach repositories, Jobs, documents, notes, and whiteboard state. The chat
agent can read selected repository context, propose Jobs, propose Epics,
schedule recurring work, inspect existing Jobs or PRs, and create proposal
cards for the operator to confirm.

Chats do not silently materialize work just because the assistant suggested
it. Proposal tools create cards; confirmation creates the real Job, Epic,
GitHub issue, or scheduled task.

Chats are for planning, inspection, and proposal generation. The confirmed
Job, Epic, issue, or schedule then runs through the same normal product
pipeline and shows up in the same dashboards as work created outside chat.

## Direct Jobs

Direct Jobs are for work that should start from an operator prompt instead
of a GitHub issue. Choose a repository, title, priority, optional provider,
prompt, and attachments. Syrus creates a `direct` Job and runs the normal
Initial workflow.

Use direct Jobs for internal chores, private context, or experiments that
do not need a GitHub issue first. Use GitHub issues when the work should be
visible in the repository's ordinary planning flow.

Direct Jobs still require a repository. They use the repository owner's
credentials and provider resolution, can belong to an Epic, can carry
attachments, and run the normal Initial workflow. They do not create a
GitHub issue automatically.

## PR Feedback, CI, And Rebases

Syrus polls open PRs that belong to Jobs. New PR conversation comments and
inline review comments create a `pr_comment` Workflow on the existing Job
and branch. Syrus tracks both `last_seen_comment_at` and
`last_feedback_addressed_at`, so feedback that has already been handled is
not re-enqueued.

GitHub PR approvals can approve the Syrus Job when the repository's approval
policy allows it, and Syrus-side approvals can optionally be propagated back
to GitHub as review approvals.

Failed GitHub Checks can create a `ci_failure` Workflow that asks the agent
to diagnose and commit a fix. A rolling cap prevents endless CI-repair loops
on the same Job.

When GitHub reports a controlled PR branch as unmergeable, Syrus runs a
rebase Workflow. It first tries a deterministic rebase; if conflicts remain,
the agent resolves them. Stack rebases update parent and child branches in
order.

## Auto-Merge

Repositories can enable auto-merge. Once a Job is approved, Syrus runs the
landing workflow: final graders, optional `landing_fix` repair, push, and a
last GitHub merge-gate check before calling the merge API.

Auto-merge can be paused globally, disabled per repository, blocked by
missing approval, blocked by failed checks, or deferred while rebases and
stack dependencies settle. Operators can inspect the landing state from the
Job and dashboard views.

## Credentials

Each user owns their own credentials and defaults:

- GitHub credential or linked GitHub App access.
- Claude credential.
- Codex credential.
- Default agent provider.
- Max-turn setting.
- Scheduling pause setting.
- Auto-approval mode.
- Admin API token, for admins.

Credentials are stored with Active Record Encryption in the Syrus database,
so every web, worker, console, and migration context that reads users needs
`RAILS_MASTER_KEY`.

## GitHub App And PAT Behavior

Repositories prefer an active GitHub App installation when one is linked
for the repository owner. If no active installation is available, Syrus
falls back to the user's PAT. Jobs persist the selected `credential_mode`
as `app` or `pat` so operators can tell which credential path was used for
that run.

Clone remotes use anonymous GitHub URLs. Token-bearing push URLs are
constructed for the individual push command and are not written into
`.git/config`.

## Multi-User Model

Syrus works well as a single-user deployment for one operator's own
repositories, and it can grow into one deployment serving multiple users.
Users have their own repositories, credentials, provider defaults,
schedules, chats, Epics, Jobs, tags, smart folders, documents, and
admin/API permissions. Repository settings can override the user's provider
default when a codebase needs a specific agent.

That model keeps solo operation simple and team operation centralized
without turning every run into a shared global credential.

For command examples, continue to [Recipes](/docs/recipes). For failure
paths, use [Troubleshooting](/docs/troubleshooting).

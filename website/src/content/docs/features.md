---
title: Features
description: Product feature reference for Jobs, Epics, schedules, chats, credentials, and repository automation.
---

# Features

This page is the product-level reference. Use [Concepts](/docs/concepts)
for the data model and [Workflows](/docs/workflows) for execution chains.

## Jobs

A Job is the unit operators track in the UI. It represents one thread of
work from a GitHub issue, scheduled task, direct prompt, or chat proposal.

Jobs show the repository, source prompt, state, priority, credential mode,
agent provider, active Workflow, past Workflows, transcripts, captured
diffs, PR link, attachments, dependencies, and logs. Operators can retry,
cancel, run again, change priority, approve, or inspect the related PR.
When a Job came from a chat proposal, or belongs to an Epic that came from a
chat proposal, the Jobs UI links back to the originating chat message.

Job kinds:

| Kind | Source |
| --- | --- |
| `issue` | A GitHub issue selected by trigger label or delegated from the repository issues panel. |
| `cron` | A scheduled task fire. |
| `direct` | An operator-created prompt with no GitHub issue. |

## Notifications

Signed-in operators see a bell in the app chrome with the current unread
count. On desktop, the bell opens a recent-notifications panel with Job and
PR outcomes such as failed Jobs, implemented work, addressed PR feedback,
merged PRs, and completed Epics. Job notifications include the Job title;
clicking the row opens the matching Job page, while a separate PR link opens
the pull request. Both actions mark the notification read. The panel also
supports marking all notifications read.

On mobile, the bell opens the full `/notifications` page with the same
recent list and read behavior.

## Terminal

When the `terminal` feature flag is enabled, the V2 sidebar shows a
Terminal item with a live badge for running sessions. The `/terminal` page
lists open sessions as tabs, lets operators start a session from recent
Workflow workspaces or a scratch directory, and keeps the PTY alive while
the browser navigates away. Returning to the page reconnects the xterm.js
pane to the existing session; killing a tab ends that session.

## Epics

Epics group related Jobs inside one repository. They are useful when a
goal is larger than one PR but still needs visible sequencing.

An Epic has a board state: `backlog`, `ready`, `in_progress`, `done`, or
`archived`. Child Jobs can be blocked until the Epic starts, and Epics can
depend on other Epics or Jobs. Jobs can also wait on an Epic to complete.
An Epic that has been created or approved does not run work by itself — a
**Start implementing** action on the Epic detail page (and a
**Create Epic & Start Implementing** button on the new-Epic form and chat
Epic proposal cards) moves the Epic to `in_progress` in one click and
dispatches its ready child Jobs; children with unmet dependencies follow
as those dependencies close.
Syrus can mark an Epic ready when its dependencies are done and all child
Jobs are confirmed, then mark it done automatically when all child Jobs
close through merged PR or no-change outcomes. When every child Job is
closed but at least one did not complete successfully, operators can use
**Mark as done** or drag the Epic to **Done** instead of archiving it.
Product owners can create and refine backlog Epics, but developers own
elaboration: product owners cannot move Epics to `ready`, `in_progress`,
or `done`, and cannot add Jobs to Epics directly.

The Epic detail page shows both sides of the dependency graph: Epics this
Epic depends on, and Epics that depend on it. Operators can add an Epic
dependency by ID or remove an existing dependency from that page; Syrus
rejects changes that would create a cycle. The page also includes a
collapsible history section that records title and description changes with
the actor, timestamp, and before/after text.

Chats can propose Epics or propose an Epic with child Jobs, including
Epic-level dependencies on existing Epics or other chat Epic proposals. Chat
Epic proposals can reference each other by proposal slug, so operators can
review the full plan first; Syrus wires the real Epic dependency once both
proposal cards are confirmed.

When a developer opens chat on a backlog Epic with no child Jobs, Syrus treats
it as product-owner-authored planning input. The chat agent surfaces the
original description, helps elaborate technical decisions, updates the Epic
description first so version history preserves that elaboration step, and then
proposes child Jobs against the existing Epic.

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

## Chats

Chats are operator conversations that can start with or without repository
context. New chats default to the operator's most recently used repository
when one is available, and operators can still choose no repository or attach
one later. A chat can attach repositories, Jobs, documents,
memories, whiteboard state, and message-level image or PDF files. The chat
agent can read selected repository context, propose Jobs, propose Epics,
read user-visible Epics by id, list and
update Epics, add or remove Epic dependencies, move Epics through
their kanban states, schedule recurring work, inspect existing Jobs or PRs,
approve or unapprove
implemented Jobs, change Job priority, move Jobs into or out of Epics, drill
through Job workflow and Run history progressively, search Jobs in the
attached repository, read stored Job diffs, list and create the operator's
tags, attach or remove tags on Jobs, manage repository documents after
confirmation, search prior chat messages for the same user, read
paginated chat transcripts, inspect Solid Queue health, update the chat's
pinned context for future turns, and create proposal cards for the operator
to confirm. New chats use a short interpreted title from the first prompt,
with the repository name as the fallback. The app sidebar groups recent chats
by repository, and each repository group can be collapsed when the operator
wants to fold that section away. Individual chats can be pinned or unpinned
from the sidebar actions menu, renamed through the same menu (or the
`/rename` slash command), hidden from the sidebar and chat search, then
restored from the Hidden chats section in user settings. The sidebar actions
menu can also permanently delete a chat after a confirmation dialog: deletion
removes the conversation, its messages, attachments, proposals, whiteboard,
search-index entries, and the chat workspace on disk, and is refused while a
turn is still running. In the V2 layout, the
sidebar search field opens a dedicated search
page where operators can search Jobs, Epics, and chat messages from
one ranked result list, then narrow results to a single type. Search terms
use Google-style matching: unquoted words are independent required terms, and
quoted words search for an exact phrase. Matching chat messages are grouped
by conversation, with the strongest snippet shown first and additional
matches expandable inline. The older chat search page remains
available for chat-specific repository, Epic, Job, and attachment filters.
Operators can also share a chat with teammates on the same Syrus instance:
the `/share` slash command copies a stable link to a read-only transcript
view that requires normal Syrus sign-in and does not expose compose controls,
pending actions, or agent controls.
At the end of a turn, the chat agent can suggest the operator's likely next
message; the suggestion appears as muted ghost text in the empty composer
with a `tab` hint. Pressing Tab fills the composer with the suggestion,
typing anything hides it, and Escape dismisses it. Suggestions clear
automatically when the operator sends a message or a new turn starts.
The chat composer accepts image and PDF attachments through the plus button
and sends them with the next message. Before sending, operators can click an
image thumbnail in the composer to mark it up with basic shapes, arrows,
freehand strokes, text, and undo; Syrus flattens the result into a PNG
attachment. Image attachments render as inline thumbnails in the transcript
and open in a full-size preview. The chat workspace also includes a Media tab
that gathers image attachments into a downloadable gallery and lists saved
whiteboard snapshots with element counts, relative timestamps, and a Load
action that merges the snapshot back onto the current canvas after preserving
existing work. PDFs are passed to the agent
without an inline preview.
Clearing a non-empty canvas automatically saves the previous scene first.

Chats do not silently materialize work just because the assistant suggested
it. Proposal tools create cards; confirmation creates the real Job, Epic,
GitHub issue, or scheduled task.
Before confirmation, operators can edit a proposal card's title, body, and
dependencies directly. Epic bundle cards let operators edit the top-level
Epic proposal, and each proposed child Job in the bundle has its own editor.
The proposal slug remains stable so dependency references do not break.
When a product owner confirms proposals, Syrus accepts standalone backlog
Epics and non-Epic Jobs, but rejects proposals that would create Jobs inside
an Epic until a developer claims and elaborates that Epic.
Proposal cards can also declare dependency edges up front, including Jobs
blocked on existing Epics, Epics blocked on existing Jobs, and proposed Jobs
blocked on specific Job proposals in other cards from the same chat session.
Actions that need explicit approval, such as
canceling, retrying, reopening, polling feedback, checking mergeability,
delegating GitHub issues, firing scheduled tasks, changing repository
documents, or pausing and resuming the landing queue, also render as inline
confirmation cards in the message stream so operators can review the target
before confirming or rejecting them.
Proposal cards show dependency status before the title: either dependency
proposal links with confirmed or pending badges, resolved Epic proposal links,
or an explicit no-dependencies note.
Grouped Epic cards also label child Job dependencies as sibling or cross-card
references, and resolved cross-card Job references link to the created Job.
Confirmed and discarded proposal and action cards are also written back into the chat
transcript so the next assistant turn can see the created Job, Epic, or
GitHub issue identifiers without asking the operator to repeat them.
When an operator confirms or rejects a proposal, Syrus immediately starts a
system-generated chat turn that tells the agent the outcome.

After discussing changes with an operator, the chat agent can propose
structured feedback on an implemented or approved Job. Operator confirmation
creates a `chat_feedback` Workflow, runs the agent on the existing PR branch,
and unapproves approved Jobs so the follow-up change returns to review before
landing. If the Job is still queued or running, Syrus stores the feedback as
a waiting pending action and promotes it for operator confirmation when the
Job reaches review.
App surfaces, including the Job detail page, can also submit feedback directly
for implemented or failed Jobs, bypassing the chat pending-action confirmation
while creating the same `chat_feedback` Workflow.

Attached repository checkouts are read-only for the chat agent. Chat can run
through Claude or Codex. Each chat can stay on **Default**, which follows the
operator's current chat provider setting and then the default agent provider,
or it can explicitly choose Claude or Codex from chat settings when both are
configured. Branched chats preserve that explicit provider choice, and stored
agent sessions only resume when the next turn uses the same provider. Chat may
read, search, list, and refresh checkouts for context, but code changes must
be drafted as proposals for operator confirmation. Claude chat turns also
deny Claude's file-editing tools (`Write`, `Edit`, `MultiEdit`, and
`NotebookEdit`) so the planning surface does not patch repository files
directly.

When the chat agent is already running, operators can queue follow-up
messages instead of waiting for the turn to finish. Queued messages remain
editable and deletable until Syrus promotes the next one into the transcript
and starts the following turn.

The chat agent can schedule one-shot wakeups for the current chat. At the
requested time, Syrus starts another visible chat turn with the stored prompt,
so the wakeup and any follow-up action remain part of the transcript. The
agent can list pending wakeups for the current chat and cancel any that are
no longer needed.

The chat agent can also ask a blocking inline question when it needs an
operator decision before continuing. Syrus shows the question above the
compose area, renders multiple-choice options as buttons when provided, and
otherwise accepts a short free-form answer.

The chat composer recognizes leading slash commands. Typing `/` opens an
autocomplete palette with system commands handled in the browser and skill
commands that are sent through the normal chat message path for the agent to
interpret. System commands can rename the current chat, clear chat history
after an inline confirmation, start a fresh chat attached to the same
repository, branch the current transcript into a new chat session, open
bookmarks, attach another repository by `owner/repo`, and open chat settings
without sending a message to the agent. `/pin` pins the current chat to the
top of the sidebar, and switches to unpinning when the chat is already pinned.
`/report` opens a small form that files a GitHub issue against the configured
Syrus report repository with the current chat as context. The `/share`
system command copies a same-instance read-only chat link to the clipboard.
Read-only skill
commands include `/jobs [filter]`, `/job <id>`,
`/epic <id>`, `/prs`, `/issues`, `/proposals`, `/canvas`, and
`/bookmark <label>`; Syrus expands each one into a prompt that asks the agent
to call the matching chat MCP tool and format the result. The `/propose` skill
command starts a guided wizard: the agent asks for a Job title, description,
and optional Epic, then creates a proposal card for operator confirmation.
Mutating skill commands such as `/cancel`, `/retry`, `/feedback`, `/discard`,
and `/clear-canvas` show an inline confirmation in the composer before Syrus
sends the command to the agent.

Chat transcripts also surface MCP sidecar health. Syrus distinguishes
available, pending, and unavailable chat tools so operators can tell when
proposal, schedule, bookmark, or whiteboard persistence is not ready and
retry the turn or inspect worker logs instead of chasing blind retries.

Agents can persist structured memories such as user preferences, project
facts, feedback, references, and decisions. Memories are private to their
owner by default; repository-scoped memories can be published to make them
visible to other operators attached to that repository. The **Memories**
settings panel lists, filters, edits, publishes, unpublishes, and deletes
memories, with admins able to manage memories across users.

Admin users also get chat tools for operational diagnostics: overview,
stuck Jobs, queue tabs, spawned processes, Runs, users, and running
instance versions. State-changing admin tools, such as pausing runs,
killing a process, clearing the GitHub cache, or refreshing installations,
create pending actions and wait for operator confirmation before applying.
Non-admin chats do not advertise those tools, and each admin tool repeats
the admin check when it runs.
Admin queue filters can be saved as smart folders from the queue sidebar,
then renamed or deleted inline from the saved-folder list so repeated
operational views stay available beside the built-in queue folders.

Admins can also toggle boolean feature flags from `/admin/features` when
the instance declares features in `config/features.yml`. The page groups
declared flags by category, shows the slug and description for each flag,
and hides the admin navigation item entirely when no flags are declared.

## Direct Jobs

Direct Jobs are for work that should start from an operator prompt instead
of a GitHub issue. Choose a repository, title, priority, optional provider,
prompt, and attachments. Syrus creates a `direct` Job and runs the normal
Initial workflow.

When the creator is a `product_owner`, Syrus holds the Job in
`needs_triage` instead of starting implementation. A developer or admin can
open the repository overview, review Jobs waiting under **Needs triage**,
and release each one into the normal triage flow.

Use direct Jobs for internal chores, private context, or experiments that
do not need a GitHub issue first. Use GitHub issues when the work should be
visible in the repository's ordinary planning flow.

## Account Settings

Each user owns their own profile, credentials, defaults, and preferences:

- **Profile** stores display name, role, GitHub handle, avatar, bio, and public team profile fields.
- **Credentials** stores GitHub PAT fallback, Claude credentials, Codex credentials, and the admin API token panel for admins.
- **Agent Settings** stores the default agent provider, max-turn setting, and auto-approval fallback.
- **Preferences** stores account-level toggles such as scheduling pause.
- Light or dark app theme is toggled from the account area.
- **Language** — operators can select their preferred display language from the profile settings page. Supported locales are English (`en`), German (`de`), and Latin (`la`). The preference is stored per-user and applied to all app chrome and shared UI text.

Credentials are stored with Active Record Encryption in the Syrus database,
so every web, worker, console, and migration context that reads users needs
the same stable `ACTIVE_RECORD_ENCRYPTION_*` keys, or `RAILS_MASTER_KEY`
when those keys live in Rails credentials.

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
Users have their own role, repositories, credentials, provider defaults,
schedules, chats, Epics, Jobs, and admin/API permissions. Repository
settings can override the user's provider default when a codebase needs a
specific agent.

When more than one user exists, the app shows a team directory with each
member's role, profile link, and lightweight workload counts. Single-user
instances keep the primary navigation focused on the solo operator's work.

That model keeps solo operation simple and team operation centralized
without turning every run into a shared global credential.

For team workflows, fork-based development, and open source contributions,
see [Collaboration](/docs/collaboration).

## Spending Insights

The spending dashboard at `/insights/spending` rolls up captured
`runs.cost_usd` into operator-facing cost views. It shows week, month,
lifetime, average Job, and average merged-PR totals, plus breakdowns by
Epic, user, repository, trigger kind, a daily trend chart, and the most
expensive individual Runs. When spending exists across multiple agent
providers, the dashboard can filter those views by model provider such as
Claude Code or Codex.

Chat can query the same spending data for 7-, 30-, or 90-day windows,
optionally narrowed to a repository or Epic, and returns the daily trend,
token totals, and the most expensive Runs for the current operator.

The view respects the same ownership model as the rest of the app:
non-admin users see only their own Run and chat costs, while admins see
global totals across the instance.

## Repository Automation

Repository settings control trigger label, polling, default branch,
provider override, prepare behavior, PR cost footer, auto-merge settings,
and approval behavior. The repository issues panel can list GitHub issues
and delegate work by adding the trigger label through the same credential
path Syrus uses for polling.

If a labeled GitHub issue was created by a Syrus user whose GitHub handle
maps to a `product_owner` account, polling creates the Job in
`needs_triage`. Developers and admins release those held Jobs from the
repository overview before classifier triage or implementation can start.

For command examples, continue to [Recipes](/docs/recipes). For failure
paths, use [Troubleshooting](/docs/troubleshooting).

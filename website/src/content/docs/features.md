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
Clicking an uploaded attachment on the Job detail Attachments tab opens it in
the same file preview popup chat uses for local file references: a Raw button
opens the underlying file in a new tab, markdown files render as markdown
with a Source toggle, and other text files get syntax highlighting. Google
Doc attachments stay a plain external link; binary uploads (images, PDFs,
Office documents) open the popup but show a "cannot be previewed" state with
the Raw button still available.
Dashboard Kanban boards for Jobs, Epics, and Workflows load cards per lane and
show a Load more control whenever older cards exist beyond the loaded window.
The Jobs and Epics dashboards also include a desktop-only Dependencies graph
view for dependency relationships.
For landed Jobs, Syrus can also record configured deployment stage progress
from repository tags, such as staging, production, or public release. The
Jobs dashboard has an optional Deployment column, hidden by default, that
shows the furthest configured stage each Job has reached.
Epic detail pages show those configured stages as columns in the child Jobs
table, so operators can scan which landed Jobs have reached each stage.
When a Job came from a chat proposal, or belongs to an Epic that came from a
chat proposal, the Jobs UI links back to the originating chat message.
If an agent provider hits a current user's usage or quota limit, Jobs that use
that provider show an additive red triangle warning in dashboards, lists, and
the Job header until usage is restored or the Job is retried/switched with
another configured provider. Transient provider outages remain separate from
quota exhaustion and keep the existing non-red circuit treatment.
Repository throughput metrics are available per repository through the app
repository overview and API at
`GET /api/v1/app/repositories/:id/throughput_metrics`, reporting PR creation,
output, landing, and review funnel windows with explicit confidence labels for
sparse samples.

Job kinds:

| Kind | Source |
| --- | --- |
| `issue` | An input-source issue selected by a configured source such as GitHub or Linear. |
| `cron` | A scheduled task fire. |
| `direct` | An operator-created prompt with no GitHub issue. |

## Simple Mode

When the instance is set to simple mode, Syrus assumes the operator reviews
results visually rather than by reading code. Implementation, PR-feedback,
and CI-repair agent prompts tell the agent to ask one focused question only
when the request has multiple substantially different valid interpretations,
use project memory heavily, make technical choices itself, write tests, and
finish the stated sub-task without leaving TODOs for the operator.

Simple-mode chat reads like a conversation: tool call names, JSON inputs, file
paths, commands, and raw outputs are hidden. Running calls show brief progress
text, successful calls leave no transcript entry, failed calls show only "Hit a
snag", and the chat workspace does not show the Context tab.

Admins can switch between simple and advanced mode from Admin Settings. Syrus
shows a confirmation that explains the mode-specific changes, saves only after
confirmation, and reloads the page so the visible navigation and copy match the
new mode.

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

## Coding Mode

When the `coding_mode` feature flag is enabled and a chat session is in coding
mode, the chat agent gains tools to implement changes directly in a repository
checkout and hand them off to Syrus automation.

The coding sidebar includes a file tree, a diff browser, and a compact commit
selector. Operators can inspect the live working tree at HEAD or choose a recent
commit on the checkout branch to view file contents and that commit's diff.

Before each Coding Mode turn, Syrus attempts to create or restore the writable
checkout. When that checkout is first created or restored, repository
preparation runs asynchronously on the chat worker so the agent can begin
inspecting the code while setup is queued or running. The agent-visible context
includes the checkout path, current branch/ref, default branch, and the latest
known prep status or failure.

New chat-authored work starts on the repository default branch unless the agent
intentionally checks out another ref. The `submit_coding_changes` chat tool
creates a new direct Job from the active committed HEAD; after operator
confirmation Syrus captures that HEAD to an immutable
`syrus/chat-<chat_id>-handoff-<pending_action_id>` branch and dispatches the
CodingHandoff workflow. After a successful capture and dispatch, Syrus resets
the chat checkout back to the repository default branch tip and queues
preparation again, so the next unrelated Coding Mode request starts from a
fresh baseline instead of accidentally carrying over handoff commits. The
`complete_implement_step` chat tool signals that a coding session on an
existing Job branch is complete and ready for graders, summarize, and PR open.
The `reset_workspace` chat tool is available for abandoned experiments: without
confirmation it only reports the checkout path, current branch/ref, dirty state,
commits ahead of the default branch, and prep status. When called with explicit
discard confirmation, it resets the checkout to the repository default branch
tip, clears uncommitted work and local-only commits, and queues preparation
again. After that reset, `submit_coding_changes` has no committed changes to
capture until new work is done.

During a handoff, the Job remains linked to the originating chat so it stays
visible in the chat Jobs tab and grader failures can route back to the same
conversation. If a retry is pushed to a replacement branch, pass that branch to
`complete_implement_step`; Syrus updates the Job before rerunning graders.

The handoff tools create a pending action that the operator must confirm before
Syrus dispatches any automation. `reset_workspace` runs immediately, but only
performs destructive cleanup when the call explicitly confirms discard.

If handoff graders fail, Syrus keeps repair inside the CodingHandoff workflow:
a fresh workflow agent fixes the committed handoff branch and graders retry
before the PR opens. The originating chat may receive status notifications, but
it is not queued to repair the grader failure.

## Visual Review

When the `visual_review` feature flag is enabled, Syrus adds a headless-browser
QA pass to the implementation loop. After the agent implements a change, an
independent reviewer agent boots its own preview of the running app, decides
for itself whether the change is even visually testable (skipping invisible or
backend-only diffs), and — if so — drives a real browser against it: clicking
through the actual feature, not just loading the homepage. It captures
screenshots as it goes so operators can see exactly what was tested, then
records a verdict. If it finds a visible defect, the change goes back through
another implementation pass automatically, the same way adversarial review's
findings do; if it looks correct, or isn't visually testable, the loop exits
and grading continues.

Operators can also trigger a visual review pass on demand from the Job detail
page's "Run visual review" action — useful for a fresh look after
implementation, or to cover a pass that was skipped or never configured.

Repositories opt in per repo, or an admin can turn the flag on instance-wide
from Admin → Features. A repository's `.syrus.yml` can override the
instance-wide default, bound how many review rounds run, restrict visual
review to specific changed files, and record seed notes (demo login, a record
to look for) so the reviewer can reach an authenticated or populated view of
the app instead of a blank one.

## Epics

Epics group related Jobs inside one repository. They are useful when a
goal is larger than one PR but still needs visible sequencing.

In simple mode, the Epic is the feature the operator reviews. Child Jobs are
created with automatic approval and auto-merge enabled, so they land after
graders pass without a per-Job approval step. When every child Job in the Epic
has merged, the feature becomes ready for review at the Epic level. From the
Epic page the operator can start a preview, mark the feature as looking good,
or submit plain-text feedback. Feedback creates a new child Job at the end of
the Epic's linear chain and moves the feature back to working status.
The simple-mode dashboard shows only these features, not Jobs or Workflows,
and uses human statuses such as **Working on it**, **Wrapping up**,
**Ready for your review**, **Done**, and **Something went wrong**. The feature
detail page keeps the implementation machinery out of view: no child Job list,
workflow history, diffs, grader output, PR numbers, branch names, commit SHAs,
timeline, or dependency graph. Scheduled tasks and the repository GitHub
Issues tab are also hidden in simple mode.
Simple mode notifications use the feature title only: they announce
ready-for-review, terminal feature problems that need attention, and accepted
review feedback; Job IDs, PR numbers, branch names, commit SHAs, and grader
details are suppressed.

An Epic has a board state: `backlog`, `ready`, `in_progress`, `done`, or
`archived`. Child Jobs can be blocked until the Epic starts, and Epics can
depend on other Epics or Jobs. Jobs can also wait on an Epic to complete.
An Epic that has been created or approved does not run work by itself — a
**Start implementing** action on the Epic detail page (and a
**Create Epic & Start Implementing** button on the new-Epic form and chat
Epic proposal cards) moves the Epic to `in_progress` in one click and
dispatches its ready child Jobs. In linear Epics, children with same-Epic
parents can keep implementing down the stack once the immediate parent has
an implemented PR branch; approval and landing order still waits for the
normal dependency gates.
For nonlinear same-Epic fan-in, Syrus can prepare a combined execution base
from approved dependency PR branches when they merge cleanly; otherwise the
queued child shows an explicit fan-in base blocker with the dependency branches
that need landing, linearizing, or conflict resolution.
Syrus can mark an Epic ready when its dependencies are done and all child
Jobs are confirmed, then mark it done automatically when all child Jobs
close through merged PR or no-change outcomes. When every child Job is
closed but at least one did not complete successfully, operators can use
**Mark as done** or drag the Epic to **Done** instead of archiving it.
Archiving an Epic immediately closes all of its child Jobs with reason
`epic_archived`, cancelling any active workflows. This is irreversible
through the archive action alone — reopen individual Jobs manually if
needed.
Product owners can create and refine backlog Epics, but developers own
elaboration: product owners cannot move Epics to `ready`, `in_progress`,
or `done`, and cannot add Jobs to Epics directly.

The Epic detail page shows both sides of the dependency graph: Epics this
Epic depends on, and Epics that depend on it. Operators can add an Epic
dependency by ID or remove an existing dependency from that page; Syrus
rejects changes that would create a cycle. The page also includes a
collapsible history section that records title and description changes with
the actor, timestamp, and before/after text.

Repositories default new Epics to a linear child-Job dependency policy: child
Jobs should form one ordered chain. Each Epic stores a concrete policy when it
is created: linear by default, or nonlinear when the operator explicitly
overrides it. Bundled Epic proposals are checked at confirmation time and
linear proposals with branching, fan-in, or disconnected child Jobs are rejected
with the offending child slugs unless the proposal used the explicit nonlinear
override.

### Epic reconciliation

When merge trains are enabled, approved child Jobs land atomically only after
the Epic has released its children and all open siblings are approved. Children
blocked by an upstream Epic dependency stay in the queue with a
`waiting for Epic to release` reason instead of dispatching a train early.
After Syrus builds the train's integration branch, it runs an agentic
reconciliation pass on the recorded integrated SHA before prepare, graders,
coverage, and landing. Nonlinear Epics with multiple approved leaves are
assembled into that same combined branch first. A no-diff reconciliation
continues normally; focused fixes are committed to the integration branch
and still pass the normal gates before the Epic lands.
Syrus records landing throughput metrics on workflow artifacts so operators can
see cache skips, rerun reasons, wall-clock grader loop time, summed grader time,
and required-grader failures while the throughput dashboard evolves.

New Epics no longer create a standalone `Reconciliation: ...` child Job just
to review sibling consistency. Existing historical reconciliation Jobs remain
readable and can still close through the successful `no_changes` path when
they produce no patch.

The legacy `reconciliation_mode` setting is retained for compatibility with
older standalone reconciliation Jobs, but current Epics reconcile during
merge-train landing after the integration branch is built.

When reconciliation is a no-op, operators see that the merge train is
continuing through normal gates. If the agent commits reconciliation fixes,
those commits are validated on the integration branch before landing. If
reconciliation fails, operators retry or inspect the merge-train workflow
rather than filing a separate reconciliation Job.

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
| `cron` | Recurring schedule interpreted in UTC, limited to at most one fire per hour. |
| `one_shot` | A single future fire time. |

Cron schedules can be entered as a five-field cron expression (`0 9 * * 1`)
or as simple cadence text (`Every Monday at 9:00 AM`, `Every day at 10 am`,
`daily at 14:30`). If typo-heavy or unusually phrased text doesn't match a
supported cadence, Syrus can optionally hand it to an AI model to produce
structured intent (frequency, day, time), which is then validated and
canonicalized the same deterministic way as any other cadence — the model
never writes the schedule directly, and firing itself never calls an AI
model.

The `pr_pileup_policy` controls what happens if the last scheduled PR is
still open: `skip`, `pile`, or `replace`. Repeated failures can
auto-pause a task until an operator fixes and resumes it.

## Chats

Chats are operator conversations that can start with or without repository
context. New chats default to the operator's most recently used repository
when one is available, and operators can still choose no repository or attach
one later. A chat can attach repositories, Jobs, documents,
memories, whiteboard state, and message-level image or PDF files. The chat
can include one owner participant and additional member participants; every
participant can open the session, post messages, receive live updates, and keep
their own read/unread state. User messages record the sender so multi-person
agent context can identify who spoke. Platform-origin sessions, such as future
Telegram or Slack conversations, are found by platform plus participant
membership and use the current `speak_when_spoken_to` trigger policy. The chat
agent can read selected repository context, propose Jobs, propose Epics,
read user-visible Epics by id, list and
update Epics, add or remove Epic dependencies, move Epics through
their kanban states, schedule recurring work, inspect existing Jobs or PRs,
explain stuck Jobs with structured dependency, Workflow, Run, landing, and PR
evidence,
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
turn is still running. When the `admin_supervisor_chat` operations flag is
enabled, admins also get one durable **Supervisor** chat. Syrus provisions it on
demand, exposes it on the chat index payload, renders it as a distinct admin row
above normal chat groups, keeps it pinned and visible, and blocks ordinary rename,
hide, unpin, or delete actions for that chat while the flag remains enabled. Provisioning
also seeds one canned operations-triage kickoff and starts the initial chat turn
automatically; repeated provisioning or opening reuses the same kickoff instead
of adding duplicate messages or turns. Its composer is oriented around incidents,
stuck Jobs, Workflows, Runs, queues, PRs, and operational state, and it does not
show ordinary repository-attachment hints or coding/local mode controls. Major operational
events, including Job notifications, Epic completion, main-branch health changes,
and new Agent Insight suggestions, are first stored as scoped chat event records.
Scoped events can run through an isolated disposable evaluator before waking the
live chat: Syrus clones the persisted transcript, uses the full context when it
fits and otherwise caps to the latest 10,000 messages plus a byte budget, gives
the evaluator read-only tools, stores its structured `no_op`/`respond`/`act`
decision, and discards the temporary provider session without touching the live
chat session. The same scoped event path wakes ordinary chat threads only for
work that originated in that thread through confirmed proposal lineage: Jobs,
Epics, related Workflows/Runs, and pull requests that map back to those Jobs.
Unrelated Job and Epic events stay out of ordinary chats. `no_op` decisions stay
silent in the transcript, while `respond` and `act` decisions create an
immediate wakeup for the real chat agent with the structured event, evaluator
decision, and handoff prompt. Scoped Supervisor events mark the chat unread in
the sidebar with an unread count and strongest event severity even when no
visible response is created. The admin overview includes operator/debug
visibility for this path: recent scoped events, 24-hour `no_op`/`respond`/`act`
counts, evaluator state counts, and recent failure reasons. Failed evaluator
events can be retried without duplicating already delivered visible wakeups.
When an admin chats in Supervisor, the agent uses admin-oriented guidance:
system event messages are treated as operational context, incident summaries
favor evidence and recommended next steps, live Syrus state is checked before
acting, and risky actions such as retries, cancellations, rebases, pause/unpause,
or cleanup stay behind pending-action confirmation flows. Supervisor does not
receive repository attachment, new-work drafting, work-delegation, recurring-work
creation, or feedback-submission tools. Missing repository attachment is not
treated as a blocker for Supervisor; when code inspection or new implementation
work is needed, it recommends the next step in prose for an ordinary planning
surface instead of initiating it. Supervisor event messages and
pending-action outcome notices are retained in compact history fallback so the
chat remains auditable even when provider resume needs fallback context.
When the `chat_context_compaction` operations flag is enabled, long-running
Supervisor chats also get durable context checkpoints: older raw messages are
summarized for provider replay while the complete stored transcript remains
visible, searchable, and auditable. The live agent receives the summary plus
recent raw messages and can use Syrus tools when exact older details are needed.
In the V2 layout, the
sidebar search field opens a dedicated search
page where operators can search Jobs, Epics, and chat messages from
one ranked result list, then narrow results to a single type. Search terms
use the `query=` URL parameter and Google-style matching: unquoted words are independent required terms, and
quoted words search for an exact phrase. Matching chat messages are grouped
by conversation, with the strongest snippet shown first and additional
matches expandable inline. The global results page also supports the same
predicate FilterBar used on dashboard lists: combined results expose common
repository and timestamp filters, while single-type views expose the relevant
Job or Epic filters. These filters keep the relevance order intact and are
encoded in the `q=` URL parameter; older plain-text `q=` search links still
open as text searches when no `query=` parameter is present. The older chat search page remains
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
existing work.
Once at least one proposal in the current chat session has been confirmed, a
Jobs tab appears in the workspace panel. It groups confirmed proposals into
their respective Epics (collapsible, with a done/total progress pill) and
shows remaining standalone Jobs as a flat list. Each card displays the Job
state, the active workflow step or PR link, and a red blocker banner when
operator action is required (awaiting review, landing failed, or a failed
dependency). Clicking a card navigates to the Job detail page. The feed
updates in real time when any Job originating from this chat session changes. PDFs are passed to the agent
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
Proposal-slug Job dependencies are temporary while a proposal cascade is being
confirmed: Syrus promotes them to concrete Job dependencies when the referenced
proposal creates a Job, and removes them if the referenced proposal is rejected,
withdrawn, deleted, or confirmed without a Job so real Jobs do not stay queued
behind stale proposal slugs.

When a proposal is created, edited, or confirmed, Syrus rejects dependency
targets that are already terminal and cannot satisfy the normal dependency
gate, such as a Job closed as `cancelled` or an archived Epic. Successfully
closed dependencies such as `pr_merged`, `external_pr_merged`, `pr_approved`,
and `no_changes` remain valid and do not block startup.
Manual dependency edits can also mark a cleanup or teardown gate as
wait-until-closed. Those edges start once the target reaches any terminal close;
normal implementation dependencies continue to require successful completion.
Actions that need explicit approval, such as
canceling, closing a Job successfully as `no_changes`, retrying, reopening,
polling feedback, checking mergeability,
delegating GitHub issues, firing scheduled tasks, changing repository
documents, or pausing and resuming the landing queue, also render as inline
confirmation cards in the message stream so operators can review the target
before confirming or rejecting them.
Successful Job close is separate from cancellation: `close_job_successfully`
records a successful closure reason such as `no_changes`, which satisfies
dependencies and Epic progress, while `cancel_job` remains non-successful. When
the Job has a tracked PR, Syrus can post the supplied explanation and close the
PR after confirmation; any GitHub cleanup failure is reported in chat.
On the Job detail page, implementation retries can also be enqueued with any
other agent provider the operator has configured. That retry-with-provider
choice is one-shot for the retry workflow. The Job detail page also has a
provider selector for future workflows: leave it on Default to resolve the
current repository/user provider each time a new workflow is created, or choose
a concrete provider such as Claude Code or Codex for later feedback, rebase, and
retry workflows on that Job. Existing workflow pins are not rewritten.
Dashboard and repository bulk retry choose a narrower recovery path first:
resume a failed agentic step when possible, retry the failed step while its
workspace remains available, retry or rebuild landing workflows for landing
failures, and use a full implementation retry only as the fallback. Bulk retry
responses include action and skipped-reason counts, including active Runs,
already-current passing PRs, duplicate retry workflows, and open provider
circuits. When a short synthesis step cannot resume the provider session,
Syrus can retry it from durable Job, summary, and diff context instead of
discarding the completed implementation.
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
landing. After a successful feedback workflow, Syrus asks the agent whether the
feedback changed the Job's effective intent; when it did, Syrus refreshes the
top-level Job summary, test plan, and managed PR title/body separately from the
follow-up commit message. If the Job is still queued or running, Syrus stores
the feedback as a waiting pending action and promotes it for operator
confirmation when the Job reaches review.
App surfaces, including the Job detail page, can also submit feedback directly
for implemented or failed Jobs, bypassing the chat pending-action confirmation
while creating the same `chat_feedback` Workflow.
If a feedback workflow fails before the comment is addressed, the source PR
comment remains on the Job detail pending-feedback panel with the last failure
reason and a retry action. Retrying reuses the stored comment and workflow
artifacts; the operator does not need to add another GitHub comment.

Attached repository checkouts are read-only for the chat agent. Chat can run
through Claude or Codex. Syrus stores a concrete provider on each chat when it
is created, seeded from the operator's current chat provider setting and then
the default agent provider, so later user-default changes do not silently move
the conversation between Claude and Codex. Operators can still explicitly choose
Claude or Codex from chat settings when both are configured; explicit provider
switching uses the normal rehydration flow. Branched chats preserve the stored
provider choice, and stored agent sessions only resume when the next turn uses
the same provider. Chat may
read, search, list, and refresh checkouts for context, but code changes must
be drafted as proposals for operator confirmation. Claude chat turns also
deny Claude's file-editing tools (`Write`, `Edit`, `MultiEdit`, and
`NotebookEdit`) so the planning surface does not patch repository files
directly.

For Claude-backed chats, the composer toolbar exposes a per-chat **Effort**
selector (None / Medium / High). Selecting a non-None level passes the
corresponding `--effort` flag to Claude, which controls extended thinking depth
for every turn in the session. The setting persists with the chat so operators
can dial reasoning intensity for complex planning sessions without affecting
other chats.

When the chat agent is already running, operators can queue follow-up
messages instead of waiting for the turn to finish. Queued messages remain
editable and deletable until Syrus promotes the next one into the transcript
and starts the following turn.

The chat agent can schedule one-shot wakeups for the current chat. At the
requested time, Syrus starts another visible chat turn with the stored prompt,
so the wakeup and any follow-up action remain part of the transcript. The
agent can list pending wakeups for the current chat and cancel any that are
no longer needed.

Operators can also schedule their own follow-up message directly from the
composer with `/schedule [time] [message]`. When both arguments are present,
Syrus stores the message immediately and sends it at the parsed time; otherwise
the composer opens a small Schedule Message dialog. Supported time forms
include `30m`, `2h`, `1d`, `in 1 hour`, `tomorrow 9am`, and `HH:MM`.

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
system command copies a same-instance read-only chat link to the clipboard,
and `/schedule [time] [message]` stores a one-shot operator message for later.
Navigation system commands include `/jobs [filter]`, `/job [id]`,
`/epic [id]`, `/prs`, `/issues`, `/proposals`, and `/review [id]`; ID commands
without an ID open a picker scoped to the attached repository when possible.
`/review` opens the selected Job's pull request. `/bookmark <label>` stores a
chat bookmark. Job action commands such as `/cancel [id]`, `/retry [id]`,
`/approve [id]`, `/discard`, and `/clear-canvas` show an inline confirmation
before they mutate anything. `/approve` accepts `JOB-123`, `job-123`, or `123`,
opens a picker of implemented Jobs when no ID is provided, and approves the
selected Job for landing after confirmation. Skill commands such as `/canvas`,
`/feedback`, and `/propose` are sent through the normal chat message path for
the agent to interpret. `/feedback` and `/propose` are hidden in Supervisor
chats. In ordinary chats, `/propose` starts a guided wizard: the agent asks for
a Job title, description, and optional Epic, then creates a proposal card for
operator confirmation.

Chat transcripts also surface MCP sidecar health. Syrus distinguishes
available, pending, and unavailable chat tools so operators can tell when
proposal, schedule, bookmark, or whiteboard persistence is not ready and
retry the turn or inspect worker logs instead of chasing blind retries.
Workflow and chat MCP calls are also recorded as durable usage rows so the
admin API can report top tools, unused advertised tools, error rates, and
chat-versus-workflow usage over a time window without reparsing transcripts.
Provider usage-limit and quota-exhaustion failures are surfaced as prominent
chat banners. When Syrus can identify the provider/model, it halts automation
for that scope immediately; when the model is unclear, it fails closed at the
provider level and preserves the underlying provider error in the banner.
Chats that currently use the exhausted provider also show a red warning marker
in the sidebar, chat header, and provider settings until usage resets or the
operator switches the chat to another configured provider.

Agents can persist structured memories such as user preferences, project
facts, feedback, references, and decisions. Memories are private to their
owner by default; repository-scoped memories can be published to make them
visible to other operators attached to that repository. The **Memories**
settings panel lists, filters, edits, publishes, unpublishes, and deletes
memories, with admins able to manage memories across users.

Admin users also get chat tools for operational diagnostics: overview,
stuck Jobs, stuck explanations, queue tabs, spawned processes, Runs, users,
running instance versions, and worker host health. The stuck views and
`explain_stuck_job` tool use the work-engine reconciler's classifications and
repair plans, so they show whether Syrus is waiting on capacity, dependencies,
main health, or rate limits; can safely auto-repair; already repaired the
issue; or needs operator action. Worker health includes live
per-worker warnings, recent CPU/memory/disk/IO samples, and compact trend
windows by hostname. It also exposes bounded one-minute history buckets for
recent per-pod inspection, so operators and agents can inspect pod pressure
without an external metrics system. Run and Job detail payloads also include
compact worker-health correlations, and insight agents can compare retained
host pressure across Runs when filing suggestions about repeated grader or
step behavior. Grader and preflight grader Runs include command spans for
common phases such as dependency checks, installs, database preparation, test
suites, and frontend builds, so slow setup can be separated from slow tests.
The same worker health data is visible
from the Workers tab as a per-host chart dashboard with current status,
quick/custom time ranges, and recent trends for CPU, load, memory, disk, CPU
pressure, and IO pressure. Only fresh heartbeat rows appear in the primary
current-worker tables; hosts that stopped heartbeating remain chartable while
their samples are in the selected range and are labeled historical, and stale
Solid Queue process rows are labeled stale in the process inventory.
Admins can temporarily disable workflow admission control from Admin Settings
during incidents where predicted capacity is blocking useful work. This is a
resource-risk kill switch: it bypasses soft worker pressure and prediction
throttles, but provider circuits, dependencies, landing pauses, archived
repositories, missing PRs, and hard worker memory/disk exhaustion still block
starts. Syrus audits the operator and timestamp, records which admission gates
were bypassed on each admitted Workflow, and wakes delayed Workflows when the
switch changes.
When the switch is enabled, admission control still keeps a minimum-progress
floor of one controlled workflow per healthy worker while running agentic work
is below that floor. Soft pressure and conservative predictions can slow the
queue, but they cannot starve all landing or merge progress; hard worker
memory/disk exhaustion still stops starts.
Admission decisions record a `telemetry_state` of present, stale, or absent
worker host telemetry alongside the pressure numbers, so a monitoring gap
(no recent host samples) is distinguishable from workers that are genuinely
busy or exhausted, instead of both looking like a 0% pressure reading.
When a Job is blocked on admission control, its Job detail page shows an
operator-facing pressure breakdown directly — which dimension tripped, its
current value against the threshold that tripped it, and whether the reading
behind it was actually measured or backed by absent/stale telemetry — without
requiring admin access. Admins additionally see a link out to the full
`/admin/resource_admission` diagnostics page from the same panel.
Operators can also manually pause any Job from the dashboard, including in bulk.
Manual pause lets the current workflow step finish and then prevents Syrus from
starting the next step or workflow for that Job. The Job remains paused until an
operator unpauses it; unpause returns it to normal scheduling, where dependency
checks, provider availability, landing gates, and admission control still apply.
Syrus also stops runaway Jobs automatically: 10 consecutive failed Workflows
close the Job as `too_many_failed_workflows`, and 50 total Workflows close it
as `too_many_workflows`. This prevents repeated queue wakeups or retries from
creating hundreds of attempts for one Job.
State-changing admin tools, such as pausing runs, killing a
process, clearing the GitHub cache, or refreshing installations, create pending
actions and wait for operator confirmation before applying. Non-admin chats do
not advertise those tools, and each admin tool repeats the admin check when it
runs. Admins can also force-fail an open stuck Job from the stuck Jobs page,
admin API, or confirmed chat tool so the normal Retry path becomes available
without closing the Job. The stuck Jobs page and admin stuck APIs paginate
results in 50-item pages, while the admin overview shows the first page and a
total stuck count.
Admin queue filters can be saved as smart folders from the queue sidebar,
then renamed or deleted inline from the saved-folder list so repeated
operational views stay available beside the built-in queue folders.

Admins can also toggle boolean feature flags from `/admin/features` when
the instance declares features in `config/features.yml`. The page groups
declared flags by category, shows the slug and description for each flag,
and hides the admin navigation item entirely when no flags are declared.

The `performance_logging` operations flag records structured slow-request,
slow-SQL, slow application-phase, and selected browser route-load events for production debugging. Slow
request events include request/user context, SQL counters, and top SQL
fingerprints for that request; phase events cover expensive dashboard, chat,
repository, job detail, bootstrap, spending, and admin payload builders.
Browser traces currently cover dashboard loads and include only structural
timing data: route path, browser-observed duration until current rows render,
document visibility state, row counts, and backend request IDs/durations/statuses
for dashboard API calls. They do not include row content, titles, prompts, or
free-form filter text; route paths are sanitized before logging. The
admin performance endpoint returns recent raw events plus grouped summaries for
slow routes, phases, browser traces, and SQL fingerprints. Events are stamped with the running
app revision, and the admin view defaults to the current revision so stale
pre-deploy timings do not hide whether a new deploy helped; admins can switch
to all revisions when investigating rolling-deploy overlap. The in-app
diagnostics buffer is cache-backed, capped at 200 events, and expires after 6
hours; structured log retention follows the deployment's log sink policy.
When the bundled `syrus_dev` plugin is enabled, Admin → Performance and the
admin performance API expose the same diagnostics payload. Implementation
workflow agents working on `tkadauke/syrus` or a registered fork of that
repository also receive the read-only `read_performance_diagnostics` MCP tool
through that plugin. Scheduled prompts that target Syrus performance work can
ask the agent to call it before editing code. The tool uses the same
current-revision/all-revisions filtering as the admin payload, returns bounded
grouped summaries, and only includes sanitized raw recent events when
explicitly requested.

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
- **Connected Platforms** links the Syrus account to external messaging platforms (see below).
- Light or dark app theme is toggled from the account area.
- **Language** — operators can select their preferred display language from the profile settings page. Supported locales are English (`en`), German (`de`), and Latin (`la`). The preference is stored per-user and applied to all app chrome and shared UI text.

## Connected Platforms

Users can link their Syrus account to external messaging platforms such as
Telegram via **Settings → Connected Platforms**. Each linked identity stores
the platform name, the platform's stable user identifier, and an optional
display handle.

The linking flow uses a short-lived signed token (valid 15 minutes). When the
operator clicks **Connect** for a configured platform, Syrus generates a token
and shows instructions — for Telegram, this means messaging the configured bot
with `/start <token>`. Once the platform polling handler verifies and consumes
the token, the UI updates automatically via an ActionCable event without
requiring a page refresh. Operators can **Disconnect** any linked account at
any time.

Platform buttons show as **Not yet available** when the instance administrator
has not yet configured that platform integration. For Telegram, administrators
set the bot handle and bot token in the admin settings page. The bot token is
stored encrypted in the database and is used by the `PollTelegramUpdatesJob`
long-polling worker. The polling worker can be started from the same settings
page via the **Start polling** button, or it starts automatically on application
boot when `SYRUS_ROLE` is set.

**Inbound message routing** — When a platform polling handler receives a
message from an external user, `InboundMessageRouter` looks up the sender's
`PlatformIdentity`, finds or creates a `ChatSession` scoped to that platform
and user, records the message, and enqueues a `ChatTurnJob` when the session
policy is `speak_when_spoken_to`.

**Outbound delivery** — When Syrus replies (an `assistant`-role `ChatMessage`
is created in a platform-origin session), a `PlatformDelivery::Registry`
adapter delivers the message to each participant who has a linked identity
for that platform. Participants with no linked identity receive the reply via
ActionCable on the web UI as usual. Platform adapters are registered at load
time; the `web` adapter is a no-op since ActionCable already handles it.
Beyond the built-in web and Telegram adapters, a plugin gem can register its
own external platform through the `:platform_delivery` plugin extension
point — once registered and enabled, its platform automatically appears as a
Connected Platforms option, with no core code change required. Discord is the
first such plugin (`plugins/discord/`, disabled by default): instead of
long-polling, it holds a persistent, bot-initiated outbound WebSocket
connection to Discord's Gateway, so linking (a DM `/link <token>` command) and
message delivery work the same no-inbound-webhook way as Telegram once an
administrator sets a Discord bot token and enables the plugin.

**Starting the polling worker** — Platform polling workers self-reschedule
after each poll cycle. On application boot, registered workers are started
automatically when `SYRUS_ROLE` is set — core connectors and plugin-provided
connectors both start automatically, but a plugin's connector only starts
while its plugin is enabled. Administrators can also trigger a manual start
of core connectors via the admin API:

```
POST /api/v1/app/admin/platform_polling/start
```

This enqueues any registered platform polling job that is not already running.


Credentials are stored with Active Record Encryption in the Syrus database,
so every web, worker, console, and migration context that reads users needs
the same stable `ACTIVE_RECORD_ENCRYPTION_*` keys, or `RAILS_MASTER_KEY`
when those keys live in Rails credentials.

## Input Sources

Repository settings list installed input source plugins from the Syrus plugin
registry. Bundled installs include GitHub and Linear sources; each source
provides its own settings schema so the repository form can render fields
without hardcoded per-source templates. GitHub keeps the standard trigger-label
flow, while Linear can poll a team and optional label filter.

## Plugin Visibility

Admins can open **Admin → Plugins** to inspect the plugin registry without
checking the Gemfile. The page lists each registered plugin's version,
enabled state, default enabled policy, disableability, category, extension
point classes, and basic author/source metadata when available. Disableable
installed plugins can be toggled live for new requests and sidecars. Installing
or removing plugins still requires changing the Gemfile and restarting Syrus.

## Tailscale

The bundled `tailscale` plugin exposes a Syrus installation on the operator's
Tailscale network, so it can be reached from laptops and phones away from the
local network. It ships installed but disabled by default; enabling it from
**Admin → Plugins** and setting a `TS_AUTHKEY` auth key runs a `tailscaled`
daemon in the worker container (so it keeps working no matter how many web
replicas are running) and forwards Tailscale traffic to the Rails app.

Once enabled, **Admin → Tailscale** shows whether the daemon is running and
connected, a copyable `https://<device>.ts.net` URL, and a short setup
checklist. To reach Syrus from a phone: install the Tailscale app, sign in to
the same tailnet, then open that ts.net URL.

## GitHub App And PAT Behavior

Repositories prefer an active GitHub App installation when one is linked
for the repository owner. If no active installation is available, Syrus
falls back to the user's PAT. Jobs persist the selected `credential_mode`
as `app` or `pat` so operators can tell which credential path was used for
that run.

The admin **Installations** page includes a lightweight GitHub App
diagnostic. It shows recent installation sync status, repository-to-
installation link state, removed installation rows, missing GitHub IDs,
and the concrete reason a repository is falling back to PAT. Admin chat
agents can read the same diagnostic through
`admin_github_app_installation_diagnostic`.

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

## Agent Insights

Agent insight runs inspect recent repository automation history and create
structured suggestions the operator can accept, dismiss, or promote into
follow-up work. Repository pages show per-repository suggestions, while admins
can use the admin insights view to inspect suggestions across the instance.
Insight runs also review pending/accepted/dismissed insights and repository
memories for freshness. If a memory is stale or describes a fixed bug, the
agent proposes a remove-memory insight; accepting it soft-deletes the target
memory through the normal audited memory path instead of letting the analysis
agent delete memory directly.

When the `agent_insights` feature is enabled, regular chat agents can discover
and call `list_insights` and `read_insight` to inspect suggestions for the
chat's attached repositories. Admin chat agents can inspect all repositories and
can narrow broad reads with repository, state, page, and limit filters.
Suggestion creation remains limited to insight workflow agents through
`submit_insight`, so chat access is read-only.

## Repository Throughput Metrics

Repository throughput metrics use a versioned contract derived from
existing Syrus records before adding rollup persistence. Each repository
window reports counts, per-hour rates, sample counts, and confidence labels
for PR creation, committed output, landing throughput, landing waste, and
the review funnel. Landing throughput treats a single auto-merge as one
landing unit with one Job and an Epic merge train as one landing unit with
its full member count, so operators can compare landing units/hour with Jobs
landed/hour.

The canonical windows are 1h, 4h, 24h, and 7d, plus a one-hour
last-active fallback when recent activity is sparse. Low-sample windows are
labelled instead of treated as stable averages, so operators can distinguish
"nothing happened recently" from "the repository is slow."

Landing windows also separate successful, failed, cancelled, and deferred
attempts; report grader-phase time, mergeability/rebase wait, base-moved
regrades, cached validation reuse, failed train cooldown waste, and a current
optimistic capacity estimate from recent successful landing-unit wall time.

Review funnel windows count Jobs that received PR feedback before approval,
Jobs approved without feedback, feedback rounds per Job, and approval sources
where Syrus can distinguish operator, bulk, auto-rule, and GitHub-review
approval. They also report sample-sized latency distributions for PR open to
first feedback, feedback to addressed, PR open to approval, approval to
landing start, and approval to landed.

## Repository Automation

Repository settings control trigger label, polling, default branch,
provider override, prepare behavior, PR cost footer, auto-merge settings,
and approval behavior. The repository issues panel can list GitHub issues
and delegate work by adding the trigger label through the same credential
path Syrus uses for polling.
When approval propagation is enabled, Syrus mirrors eligible Job approvals
as GitHub PR reviews, but skips PAT-created PRs because GitHub treats them
as user-authored and rejects self-approval.

If a labeled GitHub issue was created by a Syrus user whose GitHub handle
maps to a `product_owner` account, polling creates the Job in
`needs_triage`. Developers and admins release those held Jobs from the
repository overview before classifier triage or implementation can start.

When a repository is registered as a fork of an upstream that also lives in
the instance, Jobs on the fork branch off — and open their pull request
against — the upstream's default branch (head = the fork's branch, base =
the upstream's main). A fork can also keep its own default branch in sync
with the upstream on a schedule: toggle **Auto-sync this fork's default
branch from its upstream** in the repository settings, or click **Sync now**
at any time. Auto-sync keeps main-branch health detection on the fork from
going stale and is independent of the per-Job base branch.

For command examples, continue to [Recipes](/docs/recipes). For failure
paths, use [Troubleshooting](/docs/troubleshooting).

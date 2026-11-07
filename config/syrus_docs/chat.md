# Chat

## Repository files and Coding Mode workspaces

With a repository attached, the workspace panel exposes a read-only **Files**
tab outside Coding Mode as soon as the chat's checkout is available. It shows
the live file tree and file contents, but no Diff tab or commit selector.
Allowlisted images, SVGs, and PDFs can be previewed; oversized files and binary
files outside that preview policy are not exposed as text or preview bytes.

Before each Coding Mode turn, Syrus creates or restores the writable checkout
and starts repository preparation when needed. The environment snapshot reports
the checkout path, branch/ref, default branch, and preparation status. A turn
may inspect the checkout while preparation is running, but should not edit or
submit changes until preparation succeeds.

After an accepted `submit_coding_changes`, Syrus commits the captured work and
starts a coding-handoff workflow. The chat checkout remains in place and moves
onto the handoff result, so the next submission stacks on the prior handoff
rather than silently starting again from the default branch. Capture failures
leave the checkout and its uncommitted work intact.

`reset_workspace` is the explicit fresh-default-branch escape hatch. With
`confirm_discard: true`, it discards checkout changes, resets to the current
default branch, clears the submission lineage, and runs preparation again. The
next submission then starts a new independent stack.

For relay and storage implementation details, see
`docs/engineering/architecture/coding_workspace_relay.md`.

Syrus Chat can run turns through Claude, Codex, or any enabled plugin-provided
chat provider such as Muse or Antigravity. Each chat stores a concrete
`chat_provider` when it is created. The seed value comes from the user's chat
provider setting, then the user's default agent provider, then Claude.

Touch and pen users can long-press a live message to reveal the same timestamp,
copy, and applicable pin or bookmark actions available on desktop hover. Run transcript
messages and compact log rows expose Copy through the same gesture. Meaningful
pointer movement or early release cancels the gesture, and opening another
message or tapping elsewhere dismisses the current actions.

The primary new-chat form defaults its repository selector to the same backend
rule as the create endpoint: the most recently created accessible chat with a
repository attached, then the first active accessible repository by owner/name,
then no repository. Operators can pick any active repository they can access,
choose "No repository", or clear the current selector value before creating the
chat. The repository quick-start buttons in the recent-chat sidebar still pass
their repository (or General/no repository) directly.

Chat access comes from participation or an explicit read-only share.
`chat_participants` records every human who can open and post to a session,
with `role` currently either `owner` or `member`; the owner is the convenience
`chat.user` for legacy call sites. `chat_shares` grants a person live access to
the complete transcript without making them a participant: recipients cannot
post or start a turn, and revocation removes access immediately. Shared chats
appear under **Shared with me** in the sidebar.
Typing `@` in the composer opens chat-scoped mention suggestions. The list is
limited to the chat's human participants and rostered agents, the owner's own
not-yet-rostered coworkers in the owner's chats, and Syrus; it never searches
the instance user directory. Suggestions can be filtered by handle, name, or
role and selected with the arrow keys plus Enter or Tab. User handles are
editable in Profile, use 3–32 lowercase letters, numbers, underscores, or
hyphens, and share the same instance-wide registry as coworker handles.

The chat agent can call `withdraw_pending_action` with an action ID and an
optional concise reason when it recognizes that it proposed an action in
error. The tool is scoped to the current chat and its owner, acts immediately
without creating a second confirmation, rejects pending actions, and cancels
queued or otherwise cancellable actions. Repeating the call for an already
rejected or cancelled action returns an unchanged, idempotent result. Grouped
members must be rejected together from their group confirmation card so a
single withdrawal cannot leave a partially active group.

Nine chat-sidecar tools wire into this infrastructure: `reopen_job`,
`retry_job`, `cancel_job`, `close_job_successfully`, `force_landing_recheck`,
`admin_kill_process`, `approve_job`, `unapprove_job`, and `archive_epic`.
`archive_epic` always creates a single pending confirmation because confirming
the archive cancels and closes every still-open child Job. The Job/process
tools each accept either a singular id param (`job_id`/`process_id`) for the
original single-target behavior, or a plural array param
(`job_ids`/`process_ids`) that creates one `PendingActionGroup` instead of one
pending action per id. Passing both or neither is rejected before anything is
created. `close_job_successfully`
takes one `closure_reason` for the whole call, applied identically to every
member's payload -- targets that need different reasons require separate
calls. `approve_job` and `unapprove_job` keep executing immediately and
synchronously for a single `job_id` (unchanged behavior, no pending action
at all), but a `job_ids` array now goes through the same grouped
pending-confirmation path as the other six tools, since batching several
approvals/unapprovals behind one operator confirmation is exactly the
higher-risk case this infrastructure exists for.

`retry_job` accepts an explicit retry mode for both single and grouped calls.
Use `auto` (the default) for the existing smart retry without changing the
base, `failed_step` to rerun the failed step or grader loop against the same
immutable source snapshot, `implementation` to begin a fresh implementation
attempt from the Job's current effective base, and `refresh_base` to restore a
published mutation checkpoint onto the current effective base. Base refresh
requires an audit `reason`. Syrus preflights every selected Job before showing
one confirmation, includes checkpoint and base details in that confirmation,
and durably sequences grouped base refreshes upstream-first. A dependent
refresh remains waiting until every selected upstream refresh workflow
succeeds; an upstream failure fails that dependent without launching it.
Members still report outcomes independently, and a later failure does not
roll back an earlier successful refresh.

Automatic retry selection and Job-page recovery actions still prefer the
narrowest safe retry. An explicitly requested `implementation` mode is an
operator escalation: after confirmation it may start fresh even when a
post-implementation failure would initially recommend `failed_step`, including
when a retry of that step already failed. Active mutation work, duplicate
retries, passing PRs, and landing-specific failures remain ineligible. The
pending action and resulting Workflow record the requested mode plus the source
Workflow and failed Step context for auditability.

`approve_job` uses the same approval-blocking runtime-work policy as the Job
detail approve button, dashboard bulk approval, and app lifecycle endpoint. A
Job can be approved while only non-mutating maintenance/QA work is active
(`rebase`, `stack_rebase`, `manual_visual_review`, or `visual_diff`), but the
tool rejects approval while an implementation, feedback, repair, landing,
deployment, investigation, or unknown/plugin workflow kind still owns active
runtime work. The single-Job path rejects immediately; the grouped path rejects
before creating the pending-action group, and each pending `approve_job`
member re-checks the same predicate when confirmed in case the Job changed
while waiting for the operator.

A second, higher-risk conditional tier reuses the same array-of-ids pattern
for `force_fail_job`, `mark_ci_repair_noop`, `admin_retry_step`,
`reconcile_job_state`, `clear_provider_circuit`,
`repair_provider_circuit_evidence`, `force_rebase`, `cancel_stale_work`,
`admin_pause_user_scheduling`, and `admin_unpause_user_scheduling`. These
tools already take (or now take) a `reason` param; for a plural-id call that
`reason` doubles as the shared root-cause justification for the whole batch:
it must be non-blank or the call is rejected before any `ChatPendingAction`
or `PendingActionGroup` is created, and it is stored both on the group
(`PendingActionGroup#reason`, rendered on the confirmation card) and on every
member (for the per-item audit trail `PendingActions::Base#reason` reads at
confirm time). `reconcile_job_state` additionally rejects a plural `job_ids`
call up front unless `mode` is `auto` -- the constrained explicit
reconciliation modes (`mark_implemented_from_ready_pr`, `mark_failed`,
`mark_queued`) stay single-item. `force_rebase`'s `dry_run` (plan preview,
no pending action) is likewise single-item only and is rejected when
combined with `job_ids`. The remaining strong-tier-adjacent tools --
`replace_pr_branch_with_workflow_output`, `retry_from_current_pr_branch`,
`adopt_current_pr_head`, `manual_agentic_run`, `override_landing_blocker_once`,
`restack_epic`, and `submit_chat_feedback` -- intentionally do not wire into
this infrastructure and stay single-confirm.

`cancel_stale_work` uses a `targets` array rather than a flat `job_ids` array
because each of its members can select different `workflow_ids` and `run_ids`.
Each target contains one distinct `job_id` and its optional selections. The
array is capped at 100 targets, is mutually exclusive with the single-Job
arguments, and shares one `reason`. A top-level `reconcile` supplies the
default while each target may override it. Syrus preflights every
target before creating anything; one missing or ineligible target rejects the
whole request. Once confirmed, grouped members execute independently and the
group reports each member's success or failure.

Incident fan-out operations also accept bounded, deduplicated plural inputs:
`retire_terminal_work_unit` (`work_unit_ids`), `admin_cleanup_workspace`
(`workflow_ids`), and `force_state_transition`,
`override_job_planned_execution`, `rerun_ci_repair`,
`check_job_mergeability`, `poll_job_feedback`, and normal `rebase_job`
(`job_ids`). Shared policy, provider, instructions, event, profile, and reason
fields are copied to each member, while revision-sensitive actions retain an
observation for each target. Normal bulk rebases use the same stack selection
and active rebase/merge-train guards as a single `rebase_job`; they do not use
the force-rebase bypass path. Confirmation revalidates every member
independently, so an ineligible or failed member does not roll back or conceal
the others. The compact completion summary and expanded member list distinguish
applied members, no-op or confirmation-time ineligible members, and execution
failures.

`wake_provider_admission` prepares a single confirmed repair action after
provider evidence has recovered. Its pending-action payload and immediate MCP
result both include an `observed_preview` snapshot with `provider`,
`workflow_ids`, `workflow_count`, `auto_retry_attempt_ids`, and
`auto_retry_count`; confirmation still re-enters the normal provider,
admission, and retry guards rather than promising that every previewed record
will start. The chat card shows the requested provider, linked user scope (or
all users), Markdown audit reason, pending-action state, and the previewed
workflow and delayed-auto-retry counts. Confirmed and rejected actions use the
live pending-action state instead of the original pending result snapshot.

The chat-reading MCP tools return compact navigation payloads intended for
both agent context and chat UI cards. `list_chats` accepts optional `mode`,
`job_id`, and `has_attached_jobs` filters and returns `chats` with `id`,
`title`, `mode` (nil is reported as the effective default `planning`),
`repository`, `message_count`, `attached_jobs_count`, `attached_jobs`, and
`updated_at`, plus pagination metadata. `attached_jobs` is capped to the first
five attached Jobs and includes each Job's `id`, `slug`, `title`, `state`, and
`repository`. `search_chats` returns one row per matching message with
`chat_session_id`, `message_id`, `chat_title`, the same chat mode/attached-Job
summary fields, `repository`, `role`, `snippet`, and `created_at`, so clients
can link directly to `/chats/:chat_session_id#message-:message_id` while still
showing repository context and highlighted snippets. `read_chat_messages`
returns `chat_title`, `page`, `has_more`, `next_page`, and `messages` with each
message's `id`, `role`, `content`, and `created_at`; callers should treat
`has_more` as a neutral "another page is available" signal because page
direction is defined by the tool's ordering contract, not by the field name.

For `list_chats`, `list_repositories`, `read_chat_messages`, and
`read_run_transcript`, one-based page numbers are capped at 10,000 before SQL
offset calculation. A normal page beyond the result set still returns an empty
page; callers should not use the cap as a deep-pagination discovery mechanism.

Sidebar pinning is exposed separately from pinned context. `pin_chat` and
`unpin_chat` mutate `ChatSession#pinned`, the same state the recent-chats
sidebar uses for its pin control; `update_pinned_context` and
`remove_pinned_context` continue to mutate only the per-chat context note.
Both pinning tools default to the current chat session and accept an optional
`chat_session_id` for another visible, active chat in the current chat user's
accessible chat scope, but only the chat owner may change this shared pin
state. They are idempotent: pinning an already-pinned chat or
unpinning an already-unpinned chat succeeds and returns the current `pinned`
state.

`remove_pinned_context` returns the current chat's `chat_id`, the cleared
`pinned_context` value, and the previous text as `removed_pinned_context`.
The chat card links back to that chat and renders the removed text as a
bounded Markdown preview with a full-content dialog. Pending, empty,
malformed, and tool-error responses use explicit card states; raw details
remain available through the standard redacted tool-result disclosure.

Job-navigation MCP tools use the same compact-card posture. `search_jobs`
searches across all repositories visible to the current chat user by Job title
and stored body text, accepts an optional exact `state` filter, defaults to 20
results, and caps `limit` at 100 to match sibling list tools.

Mention gating: `ChatSession#should_trigger_agent?` is computed live
from `chat_participants.count`, not a stored setting — chats with 0-1 human
participants trigger the agent on every message; chats with 2+ require a
resolved mention of Syrus, the chat's implicit coworker, or an agent on the
chat roster in that specific message. Mentions are stored on the
message as `{ kind, id, handle, start, end }`; exact handle resolution prevents
prefix collisions, and rendering uses the mentionable's current handle. Human
mentions are highlighted and create an in-app notification for the mentioned
participant, but never trigger an agent turn. Users can disable mention
notifications in their notification preferences.

An exact structured mention of the chat's implicit coworker or a rostered
coworker runs that coworker with the chat owner's provider settings and spend.
Coworkers that are neither the chat's implicit coworker nor on its roster are
not resolved, rendered, notified, or run. All turns in one chat share the same
serialized chat-turn concurrency lane.

Delete and clear-history mutate the shared conversation and are therefore
owner-only, as is the session-level sidebar pin. Hide/unhide is instead a
per-participant preference stored on `ChatParticipant#hidden_at`: hiding a
group chat removes it only from that participant's sidebar, search, slug
resolution, and chat MCP listings, without changing what other participants
see. The Hidden chats settings list and restore action use the same
participant-local state.

The recent-chat sidebar also summarizes Jobs created from confirmed proposals
in a chat and Jobs for which that chat is the earliest active discussion
attachment. Queued or running implementation work shows a spinner (with a
count for concurrent Jobs); landing and CI-repair workflows are excluded.
Fresh terminal failures and implemented/PR-ready results show failure or
success glyphs until that participant opens the chat. Hovering or focusing a
row's indicator cluster opens a portaled breakdown of agent, Job, Epic, goal,
pending-action, and scratch-pad activity. Collapsed groups roll up Job activity
so work remains visible. Within each running, failed, or PR-ready section, Jobs
from the same Epic share one compact Epic summary with its title, segmented
state progress, and current-step counts. Healthy and finished Epics start
collapsed; Epics with failed or attention-marked Jobs start expanded. Epic and
Job slugs retain their entity preview, copy, and navigation interactions, and
long Job lists scroll inside a bounded popover. Unread messages use the existing
bold title without a separate dot.
The sidebar settings can filter the paginated list to unread chats. The chat
currently open remains visible after it is marked read and drops out when the
operator navigates away.

The normal UI only offers chat provider selection before a chat has started;
after the first message, chat settings show the stored provider as read-only.
Operators can still intentionally switch an existing chat through the chat
provider switch endpoint. That path enqueues `SwitchChatProviderJob`,
rehydrates provider-specific session state, rewrites the stored session
metadata, and updates `chat_provider` deliberately. Direct chat updates cannot
change `chat_provider`; user-level chat/agent provider settings remain
defaults for future chats only.

When the current user's usage is exhausted for a provider, chats whose effective
provider matches that provider include `provider_availability` in list/detail
payloads and show a red triangle warning in the sidebar, header, and chat
settings. Starting a new chat on another configured provider avoids the warning
for that new conversation; an existing chat only clears it after the explicit
provider switch endpoint updates that chat's stored provider. Transient
provider circuits are not treated as usage exhaustion and keep their existing
non-red UI.

## Chat about this

A Job whose page shows no chat link at all -- a bug report or an externally
ingested Job, neither of which was proposed from a chat -- offers a
"Chat about this" action (`POST /api/v1/app/jobs/:job_id/start_chat`,
`Api::V1::App::JobChatsController`). It is hidden once the Job already has
either kind of chat link: the proposal-provenance `source_chat`/`origin_chat`
above, or a discussion chat already started this way.

Starting one creates a fresh ordinary chat scoped to the Job's repository,
seeds a first user turn with only a durable Job reference, pins the chat
provider, and enqueues the title-generation and chat-turn jobs so the agent
responds immediately after redirect. It also attaches the Job via the same
`ChatAttachment` polymorphic join that backs the sidebar attachment lists in
this doc -- so the link is immediately visible both ways: the chat's Jobs
attachment list includes the Job, and the Job detail page's chat link now
points at this chat going forward (`Job#discussion_chat`, the earliest-attached
active chat session; see `App::JobDetailPayload#discussion_chat_json`). Re-running
the action once a discussion chat exists redirects to that chat without creating
a second thread or synthetic turn. Only a participant can continue an existing
discussion chat; repository write access alone cannot post into another user's
private chat. The endpoint itself requires write access to the Job (creator,
write-tier repository member, or admin -- the same
`authorize_job_mutation!` gate other Job actions use); `ChatAttachment`'s
validation only requires read access to the Job's repository, matching the
looser bar Repository attachments already use, so it never blocks the
write-gated action above it. This link is plain conversation, not ownership:
unlike Coding/Local Mode's `linked_chat_id`, it never blocks automation or
takes over the Job's implement step.

The `chat_context_compaction` feature flag currently has no effect: its
algorithm would keep a chat's durable `ChatMessage` transcript while no longer
replaying all older raw messages into the provider session, but its only
consumer (the admin Supervisor chat) has been removed, and
`ChatContextCompactor` is hard-coded off pending a decision on whether to
generalize it to ordinary chats. See `config/syrus_docs/feature_flags.md`.

The chat composer recognizes leading slash commands. Typing `/` opens the
command palette.

System commands run in the browser without sending a message to the agent.
Navigation commands include `/jobs [filter]`, `/job [id]`, `/epic [id]`,
`/prs`, `/issues`, `/proposals`, and `/review [id]`. ID commands without an ID
open the shared Job/Epic picker, scoped to the attached repository when
possible. `/review` opens the selected Job's pull request. `/bookmark <label>`
stores a chat bookmark, and `/schedule [time] [message]` stores a one-shot
operator message for later.

Mutating commands show an inline confirmation before running. `/approve [id]`
approves an implemented Job for landing through `POST /api/v1/app/jobs/:id/approve`.
It accepts `JOB-123`, `job-123`, or `123`; without an ID it opens the Job picker
filtered to `implemented` Jobs.

Skill commands, such as `/canvas`, `/feedback`, `/propose`, and `/remind`, are
sent through the normal chat message path so the agent can interpret them and
call the matching MCP tools. `/remind` routes to `schedule_wakeup`: the agent
uses `delay_minutes` for short relative reminders within 24 hours, or `fire_at`
with an absolute UTC ISO 8601 timestamp for specific dates/times and longer
one-shot reminders.

The wakeup tools have dedicated transcript cards. `list_wakeups` shows each
pending wakeup's prompt and fire time, and `cancel_wakeup` shows a linked wakeup
reference plus the cancelled prompt and fire time. Cancellation failures,
including a wakeup that is missing or no longer pending, render as an explicit
error state rather than generic tool output. A successful `cancel_wakeup` MCP
result includes `cancelled`, `wakeup_id`, `fire_at`, and `prompt`; older
transcripts that only recorded the first two fields can recover the display
context from an earlier `list_wakeups` or `schedule_wakeup` call when present.

Choose a scheduling mechanism by what must execute, before considering whether
the cadence is one-shot or recurring. `schedule_wakeup` continues the current
conversation: it stores a one-shot prompt, needs no confirmation, and starts a
future agent turn in the same chat without creating a repository Job. Use it
for “remind me here,” “wake this chat,” conditional follow-ups, and chained
rechecks. For example, “check every other day; if blocked, set a new reminder
here” is a chain of one-shot wakeups: each turn checks the condition and, only
when needed, schedules the next wakeup.

`schedule_recurring` is unattended repository automation. It proposes a
recurring task for operator confirmation; once confirmed, every fire creates a
new `cron` Job and Workflow against the repository. It never wakes or resumes
the originating chat. Use it for work such as “run the dependency audit every
Monday and open a PR,” not conversational reminders. Its confirmation card
warns about these execution semantics, and obviously chat-directed prompts are
rejected with guidance to use `schedule_wakeup`.

## Coding Mode existing-Job takeover

Coding Mode exposes `open_in_coding_mode(job_id)` to let a chat agent take over
an existing `implemented` or `approved` Job when the operator explicitly asks
for that Job. The tool reuses the same `JobCodingMode::Takeover` service as the
Job detail **Open in Coding Mode** action: approved Jobs are unapproved first,
the Job moves into `coding`, `linked_chat_id` records the owning chat, and the
chat checkout is materialized on the Job branch. If checkout setup fails after
the database claim, the service releases the Job back to `implemented` so there
is no chat-owned Job without a usable checkout.

The takeover service enforces the one-active-Job rule for Coding Mode. It
rejects a takeover when the chat already owns another active coding Job, when
the chat has an active coding checkout for different work, when the target Job
is already linked to a different chat, or when incompatible runtime work owns
the Job. Queued initial workflow work is the explicit exception: the workflow
trigger-kind registry marks it as a coding takeover hold, so a parked first
attempt does not block an operator from taking over implementation in chat.

Canceling a Coding Mode checkout uses `JobCodingMode::CancelTakeover`. For a
taken-over Job, this single backend operation discards the chat checkout and
calls `release_coding_mode_takeover!`, clearing the link and returning the Job
to `implemented`. If the checkout belongs to fresh chat-authored work rather
than a taken-over Job, cancel keeps the existing checkout-discard behavior.
Chat agents can call the `cancel_coding_checkout` MCP primitive for this exact
flow. It is intentionally non-magical: it releases the active checkout/takeover
state and reports before/after status, but it does not preserve, migrate, or
apply code changes. Agents must create a local backup branch or tag first when
the operator wants to recover commits from the current checkout.

The three pieces of state are related but distinct:

- The **git checkout state** is the local branch, HEAD, dirty state, and commits
  ahead of the default branch in the chat workspace.
- The **chat coding checkout state** is the chat session's active checkout
  branch and any linked Coding Mode checkout ownership.
- The **Job lifecycle state** is the Job's state machine value (`implemented`,
  `approved`, `coding`, and so on) plus `linked_chat_id` when a chat owns the
  implement step.

Use `reset_workspace` with no confirmation as the read-only status check. It
reports the active checkout branch, HEAD, dirty/ahead state, linked coding Job
if any, and valid next handoff lanes. `reset_workspace(confirm_discard: true)`
is only the fresh-default-branch escape hatch; it is not the takeover cancel
path.

Recovery recipe for "I committed before opening/taking over the existing Job":

1. Preserve the current local work first, for example with a backup branch or
   tag in the checkout.
2. If the chat has a conflicting active coding checkout, call
   `cancel_coding_checkout` to release it. This may discard the current checkout,
   so step 1 must happen first.
3. Call `open_in_coding_mode(job_id)` for the existing `implemented` or
   `approved` Job.
4. Cherry-pick or apply the saved commits onto the Job branch now checked out by
   Coding Mode.
5. Commit, verify the working tree is clean, and call
   `complete_implement_step(job_id)` when the operator confirms handoff.

Use `submit_coding_changes` only for new chat-authored work with no existing Job
handoff lane. Submitting from a branch that already belongs to a Syrus Job would
create a new CodingHandoff Job rather than update that existing Job, so the
chat MCP tool refuses existing Job branches and points the agent back to
`open_in_coding_mode` plus `complete_implement_step`.

An explicit `submit_coding_changes(branch:)` value names the branch the worker
must find in that repository's chat checkout; request time does not assert that
it is currently checked out. After confirmation, worker-side capture rejects a
missing checkout, a different active branch, a dirty tree, or no committed
changes before creating a Job. Normally the request remains a pending action
for operator confirmation. An active Chat Goal with `auto_submit_jobs` instead
auto-enqueues confirmation immediately, so the tool returns `confirming` and
capture may enter the chat worker queue without a separate operator click.

Repository skill commands, one per skill resolved for the chat's attached
repository (`/skill-name key=value ...`), are appended to the palette
dynamically — they are not part of the fixed command list above and vary per
repository. They execute immediately with no confirmation card, reusing the
chat's own Coding Mode turn rather than a separate execution path. See
`skills.md`'s "Slash-command execution in chat" section for the full
resolution, Coding Mode gating, and handoff-confirmation behavior.

## One-shot shell commands in Coding Mode and Local Mode (the chat shell-command cancellation feature)

Typing `!` as the first character of an empty composer, in a `coding`- or
`local`-mode chat, flips it into command-mode styling (red border/background/
text, like the slash-command derived state; shown every time, no one-time
dismissal) and routes Send to this endpoint instead of the normal
message/enqueue path. Backspacing the draft back to empty reverts to a
normal message. While a command is running, a second `!` submission is
blocked client-side (mirroring the endpoint's one-in-flight rule) and the
composer shows a stop control in place of the normal "stop agent" button,
calling the cancel endpoint below. There is still no dedicated read/poll

Requirements enforced by the endpoint and `ChatShellCommandJob`:

- Gated on the mode's feature flag (`Feature.coding_mode_enabled?` /
  `Feature.local_mode_enabled?`), the chat being in `coding` or `local` mode,
  a repository attached, the same repository write-tier check Job mutations
  use (`RepositoryPolicy#write?` via `BaseController#authorize_repository_write!`),
  and the mode's own readiness check (`ChatShellCommandExecutor#precondition_error_code`)
  — an active coding checkout for Coding Mode, a daemon that has completed the
  real "connect" handshake for Local Mode (`ChatSession#daemon_connected?`,
  not merely `LocalDaemonSession#connected?`'s row-exists/not-yet-disconnected
  check — a session row is minted as soon as the operator requests a connect
  token, before `syrus local` has actually dialed in).
- Only one command may run at a time per chat session, and a command is
  refused while an agent turn already owns the checkout
  (`turn_in_flight?`/`agent_busy?`). `ChatShellCommandJob` also joins
  `ChatTurnJob::CONCURRENCY_GROUP` so a shell command and an agent turn can
  never touch the same checkout concurrently.

- `POST /api/v1/app/chats/:chat_id/shell_commands/:id/cancel` interrupts an
  in-flight command through the mode's executor: Coding Mode stamps the
  associated `SpawnedProcess`'s existing `kill_requested_at` switch (the same
  cross-pod kill mechanism the admin Processes page uses); Local Mode calls
  `LocalToolCall#request_cancel!`, which broadcasts a `"cancel"` message on
  the daemon's tool-call stream that `LocalTunnelChannel` turns into a
  `{ type: "cancel_tool_call", tool_use_id: }` frame over the tunnel — a new
  protocol message type added for this (the tunnel previously had no
  mid-command cancellation). The daemon CLI (`cli/cmd/local.go`) tracks a
  cancel function per in-flight tool call and kills the shell subprocess on
  receipt, replying with its normal `tool_result` frame carrying
  `"killed": true`. If the daemon disconnects entirely while a command is
  outstanding, `LocalDaemonSession#mark_disconnected!` fails any
  pending/dispatched `LocalToolCall`s immediately rather than leaving the
  chat's single-in-flight lock held for the full 24-hour backstop.
- On completion or cancellation, the command and its captured combined
  stdout+stderr (capped at `ChatShellCommand::MAX_OUTPUT_BYTES`) are recorded
  on a `ChatShellCommand` row, and a `role: "user"` `ChatMessage` carrying
  `content["chat_shell_command_id"]` is always posted and a normal
  `ChatTurnJob` is enqueued so the agent sees and responds to the command and
  its output.

Independently of bookmarks, user and assistant messages can be pinned via
`ChatMessagePin` (`POST`/`GET`/`DELETE /api/v1/app/chats/:id/pins`), gated on
the same `pinnable?` role restriction as `bookmarkable?`. Pin state is shared
across all chat participants, not per-user. The SPA shows a hover-revealed
pin toggle on each pinnable message bubble and a top-of-chat bar with the 3
most-recently-pinned messages as truncated single-line previews (newest
first); clicking a preview scrolls to and highlights that message, reusing
the bookmark scroll-to-anchor mechanism. When more than 3 messages are
pinned, the bar's "+N more" affordance opens a "Pinned" tab in the right-side
workspace panel (`availableWorkspaceTabs` in `workspaceTabs.ts`) listing every
pinned message with its sender, a relative timestamp, and the same
click-to-navigate behavior. `ChatMessagePin` broadcasts `upsert_pin`/
`remove_pin` app events (`changed: ["pins"]`) so the bar, panel, and toggle
stay live for every participant.

## Media attachments

The composer accepts raster images (JPEG, PNG, GIF, and WebP), PDFs, and a
conservative allowlist of readable text, markup, structured-data,
configuration, diagnostic, changeset, and source-code files. The shared
`config/chat_attachment_policy.json` policy combines recognized extensions or
extensionless build filenames with compatible MIME types; this permits the
`text/plain` and `application/octet-stream` values browsers commonly assign to
source files without permitting arbitrary binary uploads. Text payloads must
be strictly Base64 encoded, NUL-free valid UTF-8. Each attachment is limited to
5 MB and a message's attachments to 20 MB total.

Every accepted file is materialized under the chat workspace's `attachments/`
directory with a collision-safe prefix and a sanitized recognizable basename.
The agent prompt names the display file and its exact path for every provider.
Provider-native image input and Claude PDF input remain optional optimizations;
they are not the compatibility contract. HTML and SVG remain source text in the
transcript and are offered only as downloads, never rendered in the application
origin.

`propose_job`, `propose_epic_with_jobs`, and `submit_chat_feedback` all accept
an optional `media` array of refs in the form `snapshot:ID` (a whiteboard
snapshot saved via `save_canvas`), `chat_image:ID` (a pasted/attached chat
image), or `preview_panel_version:ID` (a preview panel mockup's published
source files, see `preview_panels.md`; `show_preview`'s response includes
`version_id`). `list_chat_media` lists the refs currently available in the
session and includes chat-scoped image file paths for inline thumbnail preview
in the operator transcript. Its transcript card links image sources and saved
snapshots, opens every media kind in the shared full preview, and displays
scalar context supplied by registered media sources. The refs remain the
stable values to pass back to proposal and feedback tools. The `ChatMediaRef` format is shared across
proposal and feedback validation so a malformed or out-of-session ref is
rejected consistently.

`propose_job` and `propose_epic_with_jobs` also accept `for_active_goal`.
It defaults to false. Set it true only when the proposed work directly advances
the chat's active goal; unrelated or opportunistic follow-up proposals should
remain unlinked so their later Job state changes do not wake the goal loop.

The chat `update_job` tool may change a Job's title or description only before
execution begins. The editable states are `backlog`, `needs_triage`,
`triaging`, `blocked_by_epic`, and `queued`. Once the Job enters `running` (or
any later execution state), its source prompt is immutable; use feedback or a
new Job instead of rewriting the definition that an existing attempt consumed.
Started Workflow, WorkUnit, or Run evidence also freezes the definition when a
Job's denormalized lifecycle state has become stale.
The state check and definition update hold the Job row lock together, so a
concurrent start cannot race a late edit.

Standalone direct Job and Epic bundle proposals accept `route_to_backlog`. It
defaults to false, preserving normal confirmation behavior. For a direct Job,
Backlog creates the owned Job without advancing triage. For an Epic bundle, it
creates the Epic in `backlog` with its complete child Job chain, proposal media,
chat link, and goal link intact. Its children remain blocked by the Epic, and
no initial Workflow or Run is created until an operator starts the Epic through
the normal lifecycle. Grouped Epic proposal children cannot be routed
individually.

The Jobs workspace's Proposed section adds selection checkboxes to these
pending Job and Epic proposals, including a select-all control. Once anything
is selected, operators can backlog, implement, or reject Job-only, Epic-only,
or mixed selections. Implement starts a newly materialized Epic just like the
Epic proposal card's Implement action. Confirmations retain dependency-safe
ordering, and a failure is reported after the remaining selected proposals
have been attempted.

`propose_job` also accepts `investigation` for a read-only "go look into X and
tell me what you find" request (a QA walkthrough, an audit, answering a
question about behavior) where no pull request is expected. It defaults to
false. When true, confirming the proposal creates a Job with `investigation:
true` (see `Job#investigation_launch?`), which dispatches `Workflows::Investigation`
(`prepare -> investigate -> submit_report -> auto_close`) instead of the normal
implement/PR chain, so a thorough answer with no code changes is a fully
successful outcome. The proposal card shows an "Investigation" badge when set.
Unlike `route_to_backlog`, `investigation` is not restricted to the standalone
direct Job proposal card — it can be combined with `epic_id` to target an
existing Epic, and both `ChatProposalFiler` and `ChatEpicProposalMaterializer`
propagate it onto the created Job either way.

Chat is not the only way in. An issue labelled `Workflows::INVESTIGATION_LABEL`
(`syrus-investigation`) is filed as an investigation at ingest, so an
investigation can be requested from GitHub without going through a chat
proposal. The label is read once, when the issue becomes a Job: adding it later
does not convert an existing Job, because the chain is chosen when the first
workflow is instantiated.

Two related notions are deliberately separate:

- `Job::Kind` `investigable` says a kind may carry `investigation: true` at
  all. `direct` and `issue` are investigable; so is the operator-briefing
  plugin's `briefing_generate`.
- `Job#investigation_launch?` says the investigation *chain* should be
  dispatched, and additionally requires the kind to be operator-facing. An
  infrastructure kind such as `briefing_generate` carries the flag
  descriptively while owning its own workflow, and launching the investigation
  chain for it would replace that workflow.

`propose_job` accepts an optional `provider` override, and
`propose_epic_with_jobs` accepts an optional `provider` per child Job
(`jobs[].provider`), to pin the implementing provider for the filed Job
(e.g. `muse`). Omit it (or pass `"default"`) to keep the current behavior:
the Job inherits the repository/user default provider at confirmation time.
Values are validated against `Job::ProviderSetting::Base.values` and unknown
providers are rejected before the proposal card is created. The override is
persisted on `ChatProposal#provider_setting` (default `"default"`) and applied
at filing time: `ChatProposalFiler` and `ChatEpicProposalMaterializer` set
`Job#job_provider_setting` from the proposal and resolve `agent_provider`
through `Job::ProviderSetting::Base`, preserving the existing
advance-after-triage ordering. Proposal payloads and the chat proposal card
surface the override for confirmation display; dependency and linear-chain
validation are unchanged.

`propose_job` accepts `priority`, and `propose_epic_with_jobs` accepts a
`jobs[].priority` for each child. Valid values are `urgent`, `high`, `medium`,
and `low`; omission defaults to `medium`. The proposal card displays the
selected priority, and confirmation copies it onto the Job before the initial
state transition, so admission and the first queued Run use that priority.

`propose_job` requires `planned_execution.capabilities`, and
`propose_epic_with_jobs` requires `jobs[].planned_execution.capabilities` on
every child Job. Callers must choose explicit execution capabilities before the
proposal card is created: `{"os":["linux"]}` or `{"os":["macos"]}`. `os` is
the only permitted dimension; architecture, runtime, toolchain, feature, and
free-form dimensions are rejected with guidance to put dependencies in
repository preparation. Missing or
empty capabilities are rejected instead of being inferred from proposal
title/body text.

## Proposal dependencies

Chat proposal cards can declare dependency edges to existing Jobs/Epics or to
other Job proposal slugs in the same chat. Proposal-slug Job dependencies are
temporary placeholders while a proposal cascade is materializing. Once the
referenced proposal creates a Job, Syrus promotes the placeholder to a concrete
`JobDependency`; if the proposal is rejected, withdrawn, deleted, or confirmed
without a Job, Syrus removes the placeholder and rechecks any queued dependent
Jobs.

Pending dependency payloads include `unresolved_ref_kind` and
`unresolved_ref_state`, allowing operators and tools to distinguish actionable
pending proposal references from stale or orphaned references.

Proposal creation, proposal edits, and confirmation validate dependency targets
before storing proposal dependency fields or materializing Job/Epic dependency
rows. Dependencies on terminal targets that cannot satisfy the same runtime
dependency gate are rejected with an operator-facing message, for example a Job
closed as `cancelled` or an archived Epic. Successfully closed Job dependencies
(`pr_merged`, `external_pr_merged`, `pr_approved`, `no_changes`) are valid and
do not block the new Job from starting.

The chat MCP `add_job_dependency` tool accepts `satisfaction_mode`. The default
`success` mode is for implementation ordering: it can release dependent execution
once an upstream Job has an implemented PR with a durable head, before landing,
while final dependency satisfaction still requires a successful close.
Use `landed` when execution must wait until an upstream Job closes through a
genuine landing outcome with a recorded `landed_sha`. A genuine `no_changes`
close also satisfies `landed`, because there was no repository change to land;
`pr_approved` does not. `landed` accepts only Job targets. Epic completion is not
proof that one individual Job landed, so Epic targets are rejected for this mode.
Use `closed` only for cleanup or teardown gates where the dependent Job should
start once the target Job is terminal even if it was cancelled.
Use `deployment_stage` with `required_deployment_stage_name` only for resolved
Job targets whose upstream repository declares that stage in `deployment_stages`;
Syrus rejects unknown or untracked stages instead of creating a dependency that
cannot unblock.

`propose_job` and `propose_epic_with_jobs` can carry the same per-dependency
gate through `dependency_requirements`. Existing `depends_on_job_ids` and
proposal-slug `depends_on` values still default to `success`; use
`dependency_requirements` only when a specific dependency needs `landed`, `closed`, or
`deployment_stage`. Deployment-stage gates against proposal slugs are accepted
only after that proposal has already materialized to a Job. Sibling or otherwise
unresolved proposal targets are rejected because Syrus cannot validate their
repository stage configuration yet.

A `propose_job` card with `epic_id` set targets an existing Epic — confirming
it adds the Job as that Epic's child instead of creating an epicless direct
Job. The proposal edit modal shows the target Epic as a removable pill; an
operator can clear it before confirming so the Job materializes without an
Epic. There is no UI to assign or change the target Epic to a different one
from the edit modal — only remove it.

## Cross-chat messaging bridge

Chat agents can ask to create a coordinated batch of new threads with the
deferred `spawn_chats` tool. A request contains one to ten initial prompts,
with optional titles, configured chat providers, and accessible repository
slugs. Syrus validates the entire request first and shows one grouped
confirmation; rejecting it creates nothing. Confirmation creates each chat
independently, starts its first agent turn through the normal message path,
pre-opens a zero-hop bridge thread from the originating chat with a coordination
budget of `ChatBridgeThread::DEFAULT_MAX_HOPS` (100), and posts every resulting
`CHAT-<id>` and bridge `thread_id` back into the originating chat. The agent can
then use `send_chat_message(thread_id: ...)` from the confirmation-triggered
turn without repeating the spawned chat's initial prompt. A
failure in one member is reported alongside the successfully created chats
instead of rolling the batch back.

The chat MCP `send_chat_message` tool is the agent-facing entry point.
Supply `target_chat_session_id` to open a brand-new thread, or `thread_id`
to reply within one that is already open — exactly one of the two is
required. Authorization for both the calling chat and the target chat
reuses `find_chat_session!` (`AuthorizationSupport`, the same
same-operator-owns-both-chats check `read_chat_messages` and `search_chats`
use), and `ChatBridgeThread`'s own validation backs that up at the model
layer. Opening a new thread additionally requires that the operator's own
message in the calling chat is what triggered the current turn — checked
via `server_context[:current_message]`, which must be a real `role: "user"`
`ChatMessage` with no `requested_by` marker in its content (every automated
origin -- a wakeup, a scheduled message, a goal continuation, another
cross-chat delivery -- stamps one). This keeps an automated/system-
originated turn, such as one a wakeup fired, from spontaneously opening a
new bridge thread on its own initiative; replying within an already-open
thread has no such restriction, since the second hop of any exchange is
itself always delivered through a `cross_chat` wakeup. Opening a new thread
and its first delivery run inside one transaction, so a failure partway
through never leaves a stray open thread with no first message. The tool
returns the thread's id, `state`, `hop_count`, `max_hops`,
`hops_remaining`, and the recipient chat session id.

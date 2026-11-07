# Chat architecture



If a chat is created through an indirect path that somehow leaves the provider
blank, the first message/admission path pins `chat_sessions.chat_provider`
before title generation or turn execution. Later changes to the user's defaults
do not move that existing conversation between providers. A data migration
backfills older blank-provider chats and the column is non-null afterward.

When a chat turn crashes and Syrus schedules an automatic retry, the retry
status pill includes a manual retry control. It calls
`POST /api/v1/app/chats/:id/retry_turn`, which performs the active pending
retry immediately after re-checking that the chat turn has not moved on and
that no live agent process or pending `ChatTurnJob` is already active. Automatic
and manual retries wake the transcript with a Retry system message and run the
retry against the original operator message instead of appending a duplicate
operator-authored user message.

Per-user read state lives on `chat_participants.last_read_at`, and user-role
messages store `sender_user_id` so multi-human transcripts can attribute who
spoke. When a session has more than one human participant, `ChatTurnJob`
prefixes persisted user messages in fallback context with the sender's first
name.

Browser submissions carry one client idempotency key for the logical Send
action. Syrus durably claims that key per sender before creating a chat,
message, or queued message and replays the original outcome on an equivalent
retry. Reusing it with changed text, command, chat, or attachments returns a
conflict. Persisted user-message events echo the client key so the browser can
treat realtime delivery as acknowledgment and remove a stale failure notice or
automatically restored draft after an ambiguous HTTP failure.

Platform-origin chats use `chat_sessions.origin_platform` plus participant
membership to find the durable conversation for a user's external account.
`ChatSession.for_platform(user:, platform:)` creates that session when missing
and sets `trigger_policy` to `speak_when_spoken_to`; that is the only trigger
policy value today, but the string enum leaves room for future policies.

## Codex session resume and self-repair

A Codex chat turn resumes the provider's own thread by pointing `codex exec
resume` at a *rollout* file under the chat's agent home. Only Codex's on-disk
rollout format is resumable: it opens with a `session_meta` line and carries
`response_item` / `event_msg` entries. That is a different vocabulary from the
event stream Codex prints on stdout (`thread.started`, `item.started`,
`item.completed`), which is what Syrus rehydrates from `ChatMessage` rows.

Syrus therefore never writes a rehydrated transcript over a rollout. It keeps
Codex's own rollout and redacts short-lived MCP invocation tokens out of it in
place (`CodexRolloutSanitizer`), so the file stays both secret-free and
readable. Redaction is structural, so a token is removed wherever it appears;
the identifier *name* showing up in source code or docs the agent read is left
alone, because it is not a secret.

When the stored rollout is not resumable -- it is missing, or it is a
transcript an earlier version wrote in the stdout-event format -- the turn does
not fail. Syrus starts a fresh Codex session and posts a system message saying
so:

```
[codex resume] stored rollout for session <id> is not in Codex's resumable
format; starting a fresh Codex session
```

Operationally that means an affected chat repairs itself on its next message
rather than failing every turn. The conversation is not lost: `ChatMessage`
rows remain the record of it and still feed the prompt's persisted-context
fallback. What does not survive is Codex's own thread continuity for that
chat, so the model starts without its prior in-thread state.

## Which message a turn belongs to

`chat_sessions.turn_in_flight` records only *that* a turn is running.
`chat_sessions.current_turn_message_id` records *which* message it is running
for; `ChatTurnJob` claims it before any MCP token is minted and releases it in
`finalize_turn!`, and only if it still owns the slot.

This matters because MCP invocation tokens are scoped to a turn's message. The
active turn used to be inferred as "the last `user` message", which is wrong
for any turn a non-user message starts -- confirming a proposal, for instance.
Such a turn had its own token rejected as `TurnEnded` and failed during MCP
startup with `required MCP servers failed to initialize`. Tokens from a
genuinely superseded turn are still rejected, because a newer turn overwrites
the recorded id.

If a chat worker disappears, the orphan reaper distinguishes infrastructure
loss from an ordinary job failure. A Solid Queue `ProcessPrunedError` and a
turn whose owning agent process vanished enter the bounded chat-turn retry
path; other failed executions post the terminal failure message and clear the
turn state. Retrying re-runs the same logical turn without duplicating its user
message, resuming persisted provider state when available. The browser polls
active turns every 3 seconds initially, then backs off to 10 and 30 seconds so
a delayed worker-pruning decision cannot cause full-rate polling indefinitely.

## Grouped pending actions

Pending actions are also the durable, surface-neutral foundation for
authorization requests. A legacy chat action still belongs to its chat and
uses the same confirm/reject behavior, but an authorization request may instead
originate from a Job, Workflow, Run, Step, schedule, or another registered
surface without owning a chat. Such a request records its polymorphic origin
and subject, runtime role, stable deduplication key, purpose, actionability,
and delivery attempts. It contains independently decidable capability or
operation items; prerequisite edges prevent an invocation from becoming ready
until every required item is approved. Resource removal or failed
revalidation makes the request and its unresolved items non-actionable without
turning that outcome into a deny decision. Request and item state changes are
recorded as append-only transitions so dismissal and delivery never erase the
authorization history.

Equivalent unattended requests are routed through one active record. Each
origin is associated with that record, so it can be shown both in the central
approval inbox and beside every related Job or schedule fire. A later fire
continues work that does not require the gated operation instead of opening a
second checkpoint. Recently denied equivalents observe a short cooldown, and
active requests are capped per subject and capability to prevent unattended
work from flooding operator attention.

Pending actions keep execution outcome and presentation visibility separate.
Every terminal outcome (`confirmed`, `failed`, `rejected`, or `cancelled`)
creates one durable system outcome message and wakes the chat once. The message
records the action id and kind, execution status, application result, error,
and available resource result. Its id is stored on the action so callback
retries and legacy-outcome recovery cannot duplicate the message or agent
turn. A control-plane recovery job retries fresh terminal outcomes whose wake
could not be enqueued. Pre-existing terminal records are archived during the
schema migration; explicitly recovering one associates its original message
when possible, or backfills the actual outcome without waking the agent again.
Chat payload reads do not create messages or enqueue turns. Once a confirmed,
rejected, or cancelled action has its durable outcome message, its card retires
from the composer-adjacent pending-action carousel automatically and stays
retired after reload. The carousel shows one standalone action or action group
at a time, keeps its selection by record identity across live updates, and
offers arrow, keyboard, and horizontal-swipe navigation. Job and Epic proposal
cards remain inline with their originating assistant messages. Failed actions
remain visible for operator attention until explicitly hidden. Manual hiding
only stamps the presentation dismissal time; it does not change the terminal
state, audit fields, result, or outcome message. Queued and pending actions
retain their existing cancellation/rejection semantics.

A `PendingActionGroup` links several `ChatPendingAction` rows created
together as one batch (e.g. reopening every Job a bad merge-train landing
incorrectly closed) so the chat renders them as a single card instead of one
per action. The card shows the shared action name plus member count (e.g.
"Reopen job (11)"), an expandable list of the affected targets, and one
Confirm all/Reject all control backed by
`POST /api/v1/app/chats/:id/pending_action_groups/:pending_action_group_id/confirm`
and `.../reject`. Confirmed and rejected groups retire automatically once their
durable group outcome is present. Partial outcomes include each failed target
and its error in that durable message before the card retires. The same delete
endpoint remains available to hide a resolved card already present in a stale
client without reusing reject semantics. A member of a group never renders its own standalone pending-action
card — `pending_actions_json` filters out any
`ChatPendingAction` with a `pending_action_group_id` — and the group card
itself occupies one item in the same bottom carousel as an individual pending
action. Message and tool-call identifiers remain execution context, not card
placement instructions.

Confirming applies every still-pending member independently, in its own
transaction, so one member failing (e.g. a Job that no longer meets the
action's precondition) does not block the rest from applying. Each member's
resulting state (`confirmed`/`failed`, with `execution_error` when failed) is
what the card's expandable list renders per target. Lone and grouped terminal
cards stay in the payload until the operator hides them. Confirming or
rejecting the group emits one group outcome chat
message and one follow-up turn, rather than one per successful member.
Rejecting discards every still-pending member without applying any.

## Deleting a chat

`DELETE /api/v1/app/chats/:id` soft-deletes the `ChatSession` row instead of
destroying it: `deleted_at`/`deleted_by_user_id` are set (mirroring the
`AgentMemory::Entry`/`ChatMessage` soft-delete pattern), and dependent rows —
messages, bookmarks, queued messages, attachments, proposals, pending
actions, the whiteboard, and any captured agent session — are left
untouched in the DB for audit. The chat workspace directory, per-chat agent
homes, and FTS search-index rows are still purged post-commit by
`ChatSessionCleanupJob`, since those are local checkout state rather than
audit history. `ChatSession.active`/`.deleted` scopes mirror `ChatMessage`'s.
Every operator-facing lookup (chat index, show, search, participants, local
daemon sessions, the SPA `/chats/:id` gate) and every chat-reading MCP tool
(`list_chats`, `search_chats`, `read_chat_messages`) scope through
`ChatSession.active`, so a deleted chat is invisible to both the operator
and the agent — the same invisibility `ChatMessage.active` already gives
soft-deleted messages after `/clear`. Deletion also requests termination of
an active agent turn or workspace preparation. The cleanup job shares the
per-chat execution lock, so local workspace and search artifacts are removed
only after that background work has stopped.

`read_chat_messages` and `search_chats` are admin-aware (via
`AuthorizationSupport#admin?`): a non-admin caller never sees a trace of
soft-deleted messages or soft-deleted chat sessions, exactly as above. An
admin caller instead sees everything — `read_chat_messages` can resolve a
soft-deleted `chat_session_id` and returns every message including deleted
ones; `search_chats` stops filtering deleted messages/sessions out of its
results — and both tools attach deletion metadata (`deleted_at` plus the
resolved `deleted_by` user's id/name/email, at the message level and, when
the whole chat is gone, at the top level as `chat_session_deleted_at`/
`chat_session_deleted_by`) so the admin can see who deleted what and when.
This mirrors `AdminReadMemoryAuditHistoryTool`'s additive-field precedent
rather than gating the whole tool behind admin status.


`search_chats` normally uses the home worker's ranked SQLite FTS index. A
scheduled workflow may run on a compute worker that deliberately has no local
search index; when SQLite reports that `chat_message_fts` is absent, the tool
falls back to a bounded primary-database text search over the same authorized
chat IDs. Other database failures remain structured `backend_error` responses
with `full_text_backend` diagnostics and a bounded database error message for
operator troubleshooting. Blank queries are distinct
`validation_error` responses, and authorization failures continue to use the
shared `not_authorized` response.

## Group chats

`chat_sessions.conversation_kind` is `direct` (default) or `group`, and is
**immutable after creation** — a model validation rejects any update once the
row is persisted, so a 1:1 chat can never later gain a second human. (The enum
is declared with `scopes: false` because an auto-generated `.group` scope
would shadow ActiveRecord's `group` GROUP BY method, which the admin chat
transcript listing relies on.)

`POST /api/v1/app/chats` accepts an optional `participant_user_ids` array. When
present, every id must resolve to an existing `User` (422 listing any unknown
ids otherwise) and must include at least one user other than the creator (422
if not); the session is created with `conversation_kind: "group"`, the usual
owner `ChatParticipant` is added, and a `member` `ChatParticipant` is created
for each additional requested user. Omitting the param is unchanged
`direct`-chat behavior.

Only `group` chats support participant management:
`POST /api/v1/app/chats/:chat_id/participants` (body `{ user_id }`) adds a
`member`, and `DELETE /api/v1/app/chats/:chat_id/participants/:user_id`
removes one — both 404 for a `direct` chat and require the caller to already
be a current participant (the same `accessible_chat_sessions`-scoped lookup
`find_chat_session` uses elsewhere). Any current participant may add another
participant. The owner may remove members, members may remove only themselves
("leave"), and the owner participant can never be removed. Both
endpoints call `ChatSession#broadcast_participants_update!`, which fans out an
`updated`/`chat`/`participants` app event to the resulting participant set —
`broadcast_to_participants` accepts an explicit `recipients:` override so a
just-removed participant's own client still gets notified even though it is no
longer in `chat.participants` by the time the event fires.

`GET /api/v1/app/users/invitable` powers the add-participant picker: it lists
`{ id, name, avatar_url }` for every user except the caller, and an optional
`exclude_chat_id` param additionally excludes that chat's current
participants. It has no admin gate — Syrus has no team/org scoping anywhere
else in the app, so any authenticated user can see the flat instance user
list here. `ChatSession#participants_payload` (returned by the chat show
payload's `chat.participants`, the two participant endpoints, and the
`update_participants` broadcast event) includes the same `avatar_url` field.


Every mentionable also exposes `avatar_url` and `accent_hex`. Humans use their
uploaded or linked avatar and a neutral highlight. Built-in Syrus uses initials
on Blush, the library color nearest its previous light-mode coral by OKLab
distance. The shared accent library stores one hex per identity and derives
contrast-safe text and display ramps from it. Reusable color and avatar pickers are fixed-choice grids, and the
shared avatar renderer falls back from an uploaded image to a bundled avatar
and then to initials on the mentionable color.

`InboundMessageRouter`, `ChatsController#message`,
`ChatQueuedMessagePromoter`, and `ScheduledChatMessageFireJob` all gate their
`ChatTurnJob` enqueue on this. Unmentioned scheduled group-chat messages are
still delivered as visible user messages without marking a turn in flight.
There is no autocomplete/mention-chip composer UI in this phase.

The web UI's entry point for group chats is a "New group chat" button in the
chat sidebar (`AppChromeV2`), which opens a participant picker
(`ParticipantPickerModal`, shared with the header's "Add participant" flow)
backed by `GET /api/v1/app/users/invitable` and creates the session via
`POST /api/v1/app/chats` with `participant_user_ids`. For an existing
`conversation_kind: "group"` chat, the header (`GroupChatParticipants`) shows
every current participant as a chip with a remove control — removing another
member as the owner reads as "Remove", while a member removing themselves
reads as "Leave" and navigates away once the request succeeds, since
`accessible_chat_sessions` no
longer includes that chat. Both flows patch the chat's `participants` in the
TanStack Query cache directly from each endpoint's response, and also apply
live `update_participants` broadcast events so other open tabs/participants
stay in sync. `App::ChatMessagePayload` adds `sender_user: { id, name }` to
each message (`nil` for non-`role: "user"` messages, or when the message has
no recorded sender); the message stream only renders that name above a human
message when `chat.conversation_kind == "group"`, leaving direct-chat
rendering unlabeled. The composer shows a static hint ("Mention @syrus...")
whenever a group chat currently has 2+ participants, mirroring the backend
gate above without attempting to predict it from `conversation_kind` alone
(a group can be talked down to a single remaining human, at which point the
gate — and the hint — turn off).


Scoped chat events can be evaluated before a live chat turn is woken.
`ChatScopedEventEvaluatorJob` runs a disposable provider session with a fresh
temporary evaluator session id, rehydrated from a cloned persisted transcript.
The clone uses the full chat when it fits; otherwise it keeps the latest 10,000
messages and trims oversized content/tool outputs to a byte budget. Evaluators
see read-only MCP tools plus the narrow `submit_scoped_event_decision` tool,
which stores the structured decision (`no_op`, `respond`, or `act`) on the
`ChatScopedEvent`. If a provider fails to call the tool, Syrus falls back to
strict JSON parsing, retries once with a parse-repair prompt, and only converts
remaining parse failures to `no_op` for low-severity informational events.
Critical or warning events still fail the evaluator so operators can inspect
them. Temporary provider transcript artifacts are removed and the live chat
provider session is left untouched.
`no_op` decisions do not create visible chat messages. `respond` and `act`
decisions create an immediate `ChatWakeup` containing the scoped event,
evaluator decision, and handoff prompt; the live chat turn is instructed to
refresh current Syrus state before relying on event data.
The admin overview includes operator/debug observability for this pipeline:
24-hour `no_op`/`respond`/`act` counts, evaluator state counts, recent scoped
events, and recent evaluator failure reasons. A recurring maintenance job
automatically retries recent failed pending evaluator events; already delivered
actionable events are skipped on retry so visible chat wakeups are not duplicated.

`NotificationService::CHAT_WORK_EVENT_KINDS` (`app/services/notification_service.rb`)
is the allowlist of notification kinds that publish a scoped chat event at all;
everything else is still a regular `Notification` the user sees, it just never
reaches this pipeline. It covers both attention kinds (`job_failed`,
`main_broken`, `main_inconclusive`, `upstream_pr_closed`) and
success-completion kinds (`job_implemented`, `pr_merged`, `epic_completed`,
`main_recovered`). Routine progress kinds that are neither
a failure nor a real completion (`pr_comment_addressed`,
`external_pr_feedback`) are deliberately left out — they fire too often to be
worth a judgment pass. There is no deterministic auto-skip by kind for the
events that do publish: every one of them, including success kinds, reaches the
evaluator agent above, which is the only thing that decides `no_op` vs.
`respond`/`act` for a given event and chat. The evaluator prompt
(`Prompts::ChatEventEvaluator`) specifically tells the judging agent to default
to `no_op` for a routine successful completion, and only choose `respond`/`act`
when the chat's own transcript shows the operator is actually waiting on that
specific outcome (an explicit "let me know when this lands", a direct question
about timing, or the event closing out something they were visibly waiting on).

This scoped event flow applies to ordinary chat threads for work that
originated in that chat. Syrus resolves ordinary chat scope from confirmed
proposal lineage: the materialized proposal itself, its Job or Epic, a Job's
Epic, related Workflows/Runs through their Job, and pull request numbers that
map back to a Syrus Job. Ordinary chats do not receive events for unrelated
Jobs or Epics, and generic chat attachments are not treated as origin
evidence.


`POST /api/v1/app/chats/:chat_id/shell_commands` runs a single, user-supplied
shell command against a Coding Mode or Local Mode chat session's checkout.
`ChatShellCommandExecutor::Base.for(chat_session.mode)` (a policy class per
mode — `Coding`/`Local`, `app/services/chat_shell_command_executor/`) picks
how: Coding Mode runs it directly on the worker against the chat's persistent
`ChatWorkspace` checkout (the same long-lived clone Coding Mode turns edit —
not an ephemeral workspace) via `ProcessRunner`; Local Mode has no Syrus-side
checkout at all and dispatches it over the same reverse WebSocket tunnel
(`LocalTunnelChannel`/`LocalToolCall`/`LocalDaemonSession`) the Local Mode
agent's own `run_command` MCP tool already uses, so it runs against the
operator's own machine and checkout.

endpoint for a running command's status; instead, the chat payload's
`chat_shell_command_in_flight` field (the chat session's current running
`ChatShellCommand`, or `null`, computed only for `coding`- or `local`-mode
chats — `ChatShellCommand#as_command_json`, also reused by the create/cancel
endpoint responses) lets the composer rehydrate its stop control from
whatever payload it mounts with, so a Compose remount mid-command (e.g. a
desktop/mobile layout breakpoint crossing) doesn't silently drop the
control. Moment-to-moment UI state (immediate feedback on submit/cancel)
still comes from local component state; the composer infers completion by
watching for the `chat_shell_command_id`-carrying message below to show up
in the transcript. Chat rendering of the output (`MessageCards.tsx`'s
`ShellCommandCard`, monospace/ANSI-aware via `AnsiText`) is shared by both
modes unchanged.

- Coding Mode execution reuses `ProcessRunner` (env scrubbing, `SpawnedProcess`
  registration) rather than the Terminal plugin's `PTY.spawn` model — this is
  a request/response command, not an interactive shell. There is no enforced
  wall-clock timeout by default (the operator has accepted the same risk
  profile as already running the Terminal plugin), only a very large
  (24-hour) backstop (`ChatShellCommandJob::MAX_RUNTIME_SECONDS`) that also
  bounds how long a Local Mode command's `LocalToolCall#wait_for_result` will
  wait for the daemon's reply.

## Workspace panel tabs are plugin-extensible

The right-side workspace panel's tab set (`WorkspaceTab` in
`app/frontend/routes/chat/workspaceTabs.ts`, rendered by
`WorkspacePanels.tsx`) is not a fixed list. Beyond the built-in singleton tabs
(Whiteboard, Context, Media, Pinned, Files — read/write with a Diff sub-tab in
Coding Mode, read-only tree-and-content in planning mode once a repository is
attached, see [Repository files and Coding Mode workspaces](../../../config/syrus_docs/chat.md#repository-files-and-coding-mode-workspaces) — Local Diff, Jobs) and the
multi-instance preview panel tabs (`preview:<id>`, see `preview_panels.md`), a
plugin can register additional tabs through the `:workspace_tab` extension
point (`Syrus::Plugin::WorkspaceTab`) — declarative id/label/component
metadata resolved into the chat payload's `workspace_tabs` array, rendered as
`plugin:<id>` tabs backed by a lazily-loaded plugin React component. See
`plugins.md`'s `` `workspace_tab` `` section for the full contract and the
declarative-metadata-plus-glob-discovery design rationale.

Resolution and attachment (`ChatMediaAttacher`) is shared too: a `snapshot:ID`
ref resolves against `chat_session.whiteboard_snapshots` and becomes a
`pending_snapshot` `Document`; a `chat_image:ID` ref resolves against
`chat_session.attached_repository_documents` and becomes a `file` `Document`
re-associated with the same uploaded blob; a `preview_panel_version:ID` ref
resolves against `PreviewPanelVersion`s owned by one of the chat session's own
`preview_panels` and becomes one `file` `Document` per file attached to that
version, each re-associated with the version's existing blob — no new zip,
screenshot, or byte-copy path. All share blobs directly rather than
duplicating storage. A ref that no longer resolves (the snapshot, image, or
preview panel version was deleted, or belongs to a different chat session) is
skipped rather than failing the whole request.


Because `Document::MAX_ATTACHMENTS_PER_JOB` caps attachments per Job, repeated
feedback rounds that each attach media can eventually hit the cap. Refs that
would exceed it are skipped (existing attachments are never evicted) and the
skip is logged; the request itself still succeeds. A `preview_panel_version`
ref that has more files than the remaining capacity is a partial case of the
same rule: Syrus attaches as many files as fit and appends a note to the
Job's `issue_body` listing which files were omitted, rather than failing the
whole attach or bumping the cap. Once attached, no further plumbing is needed
to reach the agent — `JobAttachmentContext` re-reads `job.job_attachments` on
every agentic step (including the `respond` step `chat_feedback` workflows
run) and downloads/lists them in the prompt; files sourced from a preview
panel version get an added prompt note framing them as reference material for
the implementing agent to adapt to the target repo's own conventions, not
boilerplate to copy verbatim.


`ChatBridgeThread` tracks a bounded exchange between two of the same
operator's chat sessions: `origin_chat_session`, `target_chat_session`,
`opened_by_user`, an open/closed `state`, and `hop_count`/`max_hops`
(default `ChatBridgeThread::DEFAULT_MAX_HOPS`, 100). A model validation
rejects a `target_chat_session` owned by a different user, since this
feature is same-operator-only for now, any repository. `register_hop!`
increments `hop_count` and auto-closes the thread once it reaches
`max_hops`. `counterpart(chat_session)` returns the other side of the
thread relative to whichever chat session is given, so both delivery and
the MCP tool can find "the other chat" without duplicating the
origin/target ternary.

`ChatSession::CrossChatMessage.new(thread:, text:, from:).deliver!` is the
delivery path: inside one transaction, it posts a `role: "system"`
outbound-bridge message in the sending chat, creates the matching inbound
turn in the other chat via a `ChatWakeup` (`metadata: { "requested_by" =>
"cross_chat", ... }`, so it flows through the existing `ChatWakeup ->
ChatWakeupFireJob -> ChatTurnJob` path and inherits that job's per-chat
concurrency limiting), increments the thread's hop count, and posts a
closure notice to both chats once the hop cap is reached. `from:` defaults
to the thread's origin chat but accepts either side, since a reply can come
from either chat once a thread is open. Delivery on an already-closed
thread raises `ChatSession::CrossChatMessage::ClosedThreadError`.

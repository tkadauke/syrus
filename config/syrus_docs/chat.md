# Chat

Syrus Chat can run turns through Claude or Codex. Each chat stores a concrete
`chat_provider` when it is created. The seed value comes from the user's chat
provider setting, then the user's default agent provider, then Claude.

If a chat is created through an indirect path that somehow leaves the provider
blank, the first message/admission path pins `chat_sessions.chat_provider`
before title generation or turn execution. Later changes to the user's defaults
do not move that existing conversation between providers. A data migration
backfills older blank-provider chats and the column is non-null afterward.

Chat access is participant-based. `chat_participants` records every human who
can open and post to a session, with `role` currently either `owner` or
`member`; the owner is the convenience `chat.user` for legacy call sites.
Per-user read state lives on `chat_participants.last_read_at`, and user-role
messages store `sender_user_id` so multi-human transcripts can attribute who
spoke. When a session has more than one human participant, `ChatTurnJob`
prefixes persisted user messages in fallback context with the sender's first
name.

Platform-origin chats use `chat_sessions.origin_platform` plus participant
membership to find the durable conversation for a user's external account.
`ChatSession.for_platform(user:, platform:)` creates that session when missing
and sets `trigger_policy` to `speak_when_spoken_to`; that is the only trigger
policy value today, but the string enum leaves room for future policies.

Operators can intentionally switch an existing chat through the chat provider
switch endpoint. That path enqueues `SwitchChatProviderJob`, rehydrates
provider-specific session state, rewrites the stored session metadata, and
updates `chat_provider` deliberately. Direct chat updates cannot change
`chat_provider`; user-level chat/agent provider settings remain defaults for
future chats only.

When the current user's usage is exhausted for a provider, chats whose effective
provider matches that provider include `provider_availability` in list/detail
payloads and show a red triangle warning in the sidebar, header, and chat
settings. Switching the chat to another configured provider clears the warning
for that chat immediately. Transient provider circuits are not treated as usage
exhaustion and keep their existing non-red UI.

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

When the `admin_supervisor_chat` feature is enabled, the same scoped event flow
also applies to ordinary chat threads for work that originated in that chat.
Syrus resolves ordinary chat scope from confirmed proposal lineage: the
materialized proposal itself, its Job or Epic, a Job's Epic, related
Workflows/Runs through their Job, and pull request numbers that map back to a
Syrus Job. Ordinary chats do not receive events for unrelated Jobs or Epics, and
generic chat attachments are not treated as origin evidence.

When the `chat_context_compaction` feature is enabled, long-running Supervisor
chats keep their durable `ChatMessage` transcript but stop replaying all older
raw messages into the provider session. `ChatTurnJob` stores
`ChatContextCheckpoint` rows after the chat crosses the compaction threshold,
and provider rehydration sends one synthetic prior-context summary plus the
latest raw messages after the checkpoint. The summary is deterministic and
extractive; exact older details remain available through persisted chat history
and admin/search tools. Ordinary chats are not compacted by this feature.

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

Skill commands, such as `/canvas`, `/feedback`, and `/propose`, are sent through
the normal chat message path so the agent can interpret them and call the
matching MCP tools. `/feedback` and `/propose` are hidden in Supervisor chats,
where the agent recommends operational next steps in prose instead of starting
new work.

Repository skill commands, one per skill resolved for the chat's attached
repository (`/skill-name key=value ...`), are appended to the palette
dynamically — they are not part of the fixed command list above and vary per
repository. They execute immediately with no confirmation card, reusing the
chat's own Coding Mode turn rather than a separate execution path. See
`skills.md`'s "Slash-command execution in chat" section for the full
resolution, Coding Mode gating, and handoff-confirmation behavior.

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
`success` mode is for implementation ordering and waits for a successful close.
Use `closed` only for cleanup or teardown gates where the dependent Job should
start once the target Job is terminal even if it was cancelled.

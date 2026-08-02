# Chat

Syrus Chat can run turns through Claude or Codex. Each chat stores a concrete
`chat_provider` when it is created. The seed value comes from the user's chat
provider setting, then the user's default agent provider, then Claude.

If a chat is created through an indirect path that somehow leaves the provider
blank, the first message/admission path pins `chat_sessions.chat_provider`
before title generation or turn execution. Later changes to the user's defaults
do not move that existing conversation between providers. A data migration
backfills older blank-provider chats and the column is non-null afterward.

Operators can still switch an existing chat explicitly through the chat provider
switch endpoint or chat settings control. That path enqueues
`SwitchChatProviderJob`, rehydrates provider-specific session state, and updates
the stored `chat_provider` deliberately. User-level chat/agent provider settings
remain defaults for future chats only.

When the current user's usage is exhausted for a provider, chats whose effective
provider matches that provider include `provider_availability` in list/detail
payloads and show a red triangle warning in the sidebar, header, and chat
settings. Switching the chat to another configured provider clears the warning
for that chat immediately. Transient provider circuits are not treated as usage
exhaustion and keep their existing non-red UI.

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
matching MCP tools.

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

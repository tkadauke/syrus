# Chat

Syrus Chat can run turns through Claude or Codex. A chat with no messages may
leave `chat_provider` blank, which means **Default**: resolve the provider from
the user's chat provider setting, then the user's default agent provider, then
Claude.

When a chat receives its first message, Syrus persists the resolved provider to
`chat_sessions.chat_provider`. Later changes to the user's defaults do not move
that existing conversation between providers. If an older non-empty chat still
has a blank provider, `ChatTurnJob` pins it before selecting the provider for
the turn.

Operators can still switch a non-empty chat explicitly through the chat provider
switch endpoint. That path enqueues `SwitchChatProviderJob`, rehydrates
provider-specific session state, and updates `chat_provider` deliberately. In
the chat settings update path, selecting **Default** for a non-empty chat stores
the chat's current effective provider instead of writing `nil`, so the next
turn cannot drift because user defaults changed.

When the current user's usage is exhausted for a provider, chats whose effective
provider matches that provider include `provider_availability` in list/detail
payloads and show a red triangle warning in the sidebar, header, and provider
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

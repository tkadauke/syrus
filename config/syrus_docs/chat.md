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

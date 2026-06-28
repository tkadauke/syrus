import type { ChatNavRecord, ChatsIndexPayload } from "../api/chats"

export function firstUnstartedChat(payload: ChatsIndexPayload | undefined): ChatNavRecord | null {
  if (!payload || !Array.isArray(payload.groups)) return null

  return payload.groups.flatMap((group) => group.chats).find((chat) => chat.last_message_at == null) || null
}

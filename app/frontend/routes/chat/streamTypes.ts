// Chat message-stream render-item types extracted from Chat.tsx.
//
// The stream the chat view renders is a mix of message render items and the
// synthetic pending-action / timestamp / day-divider markers the builders
// inject. Lifting these types into a leaf module lets the stream-builder
// helpers (buildMessageStreamItems, injectTemporalMarkers, …) move out of the
// 6k-line Chat.tsx without importing types back from it.
import type { ChatPendingAction, ChatPendingActionGroup, ChatRenderItem } from "../../api/chats"

export type ChatPendingActionStreamItem = {
  type: "pending_action"
  pendingAction: ChatPendingAction
}

export type ChatPendingActionGroupStreamItem = {
  type: "pending_action_group"
  pendingActionGroup: ChatPendingActionGroup
}

export type ChatTimestampItem = { type: "timestamp"; time: string; fullDatetime: string }
export type ChatDayDividerItem = { type: "day_divider"; date: string; label: string }
export type ChatStreamItem = ChatRenderItem | ChatPendingActionStreamItem | ChatPendingActionGroupStreamItem | ChatTimestampItem | ChatDayDividerItem

// Pending-action display helpers extracted from Chat.tsx.
//
// Pure label/title/url/key derivations over a pending action (inline or full),
// used by the pending-action cards and badges. Only touch the chat API types.
import type { ChatPendingAction, ChatPendingActionInline } from "../../api/chats"

export function pendingActionTerminalLabel(state: ChatPendingAction["state"] | ChatPendingActionInline["state"]) {
  if (state === "confirmed") return "Confirmed"
  if (state === "rejected") return "Rejected"
  if (state === "cancelled") return "Cancelled"
  return null
}

export function pendingActionResourceTitle(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  return "resource_title" in pendingAction ? pendingAction.resource_title : null
}

export function pendingActionResourceUrl(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  return "resource_url" in pendingAction ? pendingAction.resource_url : null
}

export function pendingActionKey(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  return pendingAction.action || ("action_type" in pendingAction ? pendingAction.action_type : null)
}

export function pendingActionBadgeLabel(pendingAction: ChatPendingActionInline | ChatPendingAction) {
  const actionKey = pendingActionKey(pendingAction)
  if (actionKey === "submit_chat_feedback") return "Submit feedback"
  if (actionKey === "cancel_job") return "Cancel"
  if (actionKey === "close_job_successfully") return "Close successfully"
  if (actionKey === "retry_job") return "Retry"
  if (actionKey === "rebase_job") return "Rebase"
  if (actionKey === "reopen_job") return "Reopen"
  if ("action_type" in pendingAction && pendingAction.action_type) return pendingAction.action_type.replace(/_/g, " ")
  return "Action"
}

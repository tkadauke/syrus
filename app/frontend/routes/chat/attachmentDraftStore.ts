import type { ChatComposeAttachment } from "./composeTypes"

// In-progress attachment references live in a module-level map. That's enough
// to survive the two
// remounts that were silently discarding them:
//   - crossing the mobile/desktop breakpoint mid-session, where ChatWorkspace
//     renders an entirely different JSX branch and React remounts the
//     ChatColumn/Compose subtree
//   - navigating away from the chat route and back, which unmounts the whole
//     chat tree
// A plain module-level Map survives both because neither unmounts the JS
// module, only the React tree. It does not survive a full page reload.
const draftAttachmentsByChatId = new Map<string, ChatComposeAttachment[]>()

export function getDraftAttachments(chatId: string): ChatComposeAttachment[] {
  return draftAttachmentsByChatId.get(chatId) ?? []
}

export function setDraftAttachments(chatId: string, attachments: ChatComposeAttachment[]): void {
  if (attachments.length === 0) {
    draftAttachmentsByChatId.delete(chatId)
    return
  }

  draftAttachmentsByChatId.set(chatId, attachments)
}

export function clearDraftAttachments(chatId: string): void {
  draftAttachmentsByChatId.delete(chatId)
}

// Test-only: the module-level map otherwise outlives any single test (by
// design — that's what makes it survive a remount), so specs that attach a
// draft must reset it or leak state into later specs reusing the same chat id.
export function __resetDraftAttachmentsForTests(): void {
  draftAttachmentsByChatId.clear()
}
